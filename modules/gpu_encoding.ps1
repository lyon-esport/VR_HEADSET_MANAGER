###############################################################
# gpu_encoding.ps1
# ffmpeg encoder probing and selection for the restream push
# (Get-StreamEncoderArgs, Test-FfmpegEncoder, Get-GpuEncoder).
# Needs Get-GpuInfo (hardware_monitoring.ps1). Split out of utils.ps1 (S9-1).
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


# -------------------------------------------------------------------
# GPU encoder resolution and adaptive monitoring interval
# Used by the ffmpeg restream path and the VRMonitor slow path.
# -------------------------------------------------------------------

# Builds the per-encoder low-latency argument list used for the mediamtx RTSP push.
# Lives here (not in scrcpy_launcher.ps1) so Test-FfmpegEncoder probes the EXACT
# configuration the stream will run with. Keeping them in two places is what let the
# h264_amf keyframe bug ship: the probe only ever tried a bare "-c:v h264_amf", which
# works fine, while the stream added "-usage ultralowlatency", which does not.
#
# -bf 0 and -g $Gop are required on EVERY arm: mediamtx WebRTC/WHEP rejects H.264
# streams containing B-frames ("WebRTC doesn't support H264 streams with B-frames"
# closes the session). qsv/amf/mf emit B-frames by default; nvenc and libx264 already
# disable them via tune presets but explicit is safer. A short GOP (= framerate)
# ensures new WHEP subscribers receive a keyframe within ~1s of joining.
#
# Per-encoder low-latency tails disable async pipelining / lookahead so frames flow
# through with minimal in-encoder queuing. qsv defaults to async_depth=4 (~130 ms at
# 30 fps); nvenc has an implicit -delay; the libx264 fallback uses sliced threading to
# avoid frame-level latency.
function Get-StreamEncoderArgs {
    param(
        [Parameter(Mandatory)][string]$EncoderName,
        [Parameter(Mandatory)][string]$Bitrate,
        [Parameter(Mandatory)][string]$Gop
    )
    $bw  = $Bitrate
    $gop = $Gop
    switch ($EncoderName) {
        'h264_nvenc' { @('-c:v','h264_nvenc','-preset','p1','-tune','ll','-rc','cbr','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-delay','0','-rc-lookahead','0') }
        'h264_qsv'   { @('-c:v','h264_qsv','-preset','veryfast','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-async_depth','1','-look_ahead','0') }
        # h264_amf must NOT use -usage ultralowlatency: on AMF the usage preset is
        # applied inside AMFComponent::Init and overwrites IDR_PERIOD, so -g (and
        # -header_spacing / -forced_idr / -force_key_frames) are all silently ignored -
        # the encoder then emits exactly ONE IDR + one SPS/PPS at startup and nothing
        # but P-frames afterwards. Any WHEP viewer that opens the page after that first
        # frame never receives a keyframe and shows a permanent black screen (verified
        # on Radeon 780M / driver 32.0.21020.1007: 90 frames -> 1 IDR with
        # ultralowlatency, 3 IDR + 3 SPS/PPS with the args below). hevc_amf on the same
        # hardware honours -g even with ultralowlatency, which is why h265 looked fine
        # while h264 was black.
        # "-usage transcoding -latency 1" keeps AMF's low-latency mode (no B-frames, no
        # lookahead - measured identical throughput) while leaving IDR_PERIOD under our
        # control. -header_spacing repeats SPS/PPS on every keyframe.
        'h264_amf'   { @('-c:v','h264_amf','-usage','transcoding','-latency','1','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-header_spacing',$gop,'-forced_idr','1','-quality','speed','-rc','cbr','-async_depth','1') }
        'h264_mf'    { @('-c:v','h264_mf','-b:v',$bw,'-bf','0','-g',$gop,'-rc_mode','CBR') }
        'hevc_nvenc' { @('-c:v','hevc_nvenc','-preset','p1','-tune','ll','-rc','cbr','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-delay','0','-rc-lookahead','0','-tag:v','hvc1') }
        'hevc_qsv'   { @('-c:v','hevc_qsv','-preset','veryfast','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-async_depth','1','-look_ahead','0','-tag:v','hvc1') }
        # hevc_amf honours -g under ultralowlatency on every driver tested here, but it
        # gets the same explicit keyframe/header args as h264_amf so a future driver
        # cannot reintroduce the same silent black-screen failure on this arm.
        'hevc_amf'   { @('-c:v','hevc_amf','-usage','transcoding','-latency','1','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-header_spacing',$gop,'-forced_idr','1','-quality','speed','-rc','cbr','-async_depth','1','-tag:v','hvc1') }
        'hevc_mf'    { @('-c:v','hevc_mf','-b:v',$bw,'-bf','0','-g',$gop,'-rc_mode','CBR','-tag:v','hvc1') }
        'libx265'    { @('-c:v','libx265','-preset','ultrafast','-tune','zerolatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-x265-params','force-cfr=1','-tag:v','hvc1','-threads','4') }
        default      { @('-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-x264-params','nal-hrd=cbr:force-cfr=1:sliced-threads=1','-threads','4') }
    }
}

# Probe a single ffmpeg encoder in two stages:
#  Stage 1 - open check: does the encoder session even open and accept a frame?
#            (1-frame smoke test against a black source, discarded to -f null -)
#  Stage 2 - output check: run the REAL streaming configuration (via
#            Get-StreamEncoderArgs) over a few GOPs of a non-black synthetic pattern,
#            decode the result back, and verify two things:
#              a) the frames did not come back black - some GPU/driver stacks accept
#                 the session and exit 0 but silently emit black/corrupt frames (seen
#                 with h264_amf on some AMD Z1 Extreme / Radeon 780M driver builds,
#                 while hevc_amf on the SAME hardware works fine). Stage 1 alone
#                 cannot catch this since its source is already black.
#              b) the encoder actually honours -g and emits periodic keyframes. An
#                 encoder that emits a single IDR at startup looks perfectly healthy
#                 on disk but leaves every WHEP viewer that joins later on a black
#                 page forever, because WebRTC cannot start decoding without one.
# Returns @{Ok; Reason} - Reason is 'open-failed', 'black-output' or 'no-keyframes'
# when Ok=$false, $null when Ok=$true.
function Test-FfmpegEncoder {
    param(
        [Parameter(Mandatory)] [string] $Encoder,
        [string[]] $ExtraArgs = @()
    )
    if (-not (Test-Path -LiteralPath $global:ffmpegFilePath)) { return @{ Ok = $false; Reason = 'open-failed' } }

    $openArgs = @('-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=black:s=320x240:r=10:d=0.1')
    $openArgs += $ExtraArgs
    $openArgs += @('-c:v',$Encoder,'-frames:v','1','-f','null','-')
    try {
        $null = & $global:ffmpegFilePath @openArgs 2>&1
        if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = 'open-failed' } }
    } catch {
        return @{ Ok = $false; Reason = 'open-failed' }
    }

    # 3 s at 10 fps with -g 10 -> 30 frames, 3 expected keyframes. Deliberately short:
    # this runs on every scrcpy (re)start before the stream can come up.
    $probeGop = 10
    $probeSrc = 'testsrc2=size=320x240:rate={0}:duration=3' -f $probeGop
    $tmpFile  = Join-Path $env:TEMP ("vrhm_encprobe_{0}.mkv" -f ([guid]::NewGuid().ToString('N')))
    try {
        $encArgs = @('-hide_banner','-loglevel','error','-f','lavfi','-i',$probeSrc)
        $encArgs += $ExtraArgs
        $encArgs += (Get-StreamEncoderArgs -EncoderName $Encoder -Bitrate '2M' -Gop ([string]$probeGop))
        $encArgs += @('-y',$tmpFile)
        $null = & $global:ffmpegFilePath @encArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpFile)) { return @{ Ok = $false; Reason = 'open-failed' } }

        # One decode pass yields both checks: blackframe reports black frames, showinfo
        # reports the picture type of every frame.
        $checkArgs = @('-hide_banner','-loglevel','info','-i',$tmpFile,'-vf','blackframe=98:32,showinfo','-f','null','-')
        $checkOut = & $global:ffmpegFilePath @checkArgs 2>&1
        $blackFrames = 0
        $keyFrames   = 0
        foreach ($line in $checkOut) {
            if ($line -match 'blackframe.*pblack:') { $blackFrames++ }
            if ($line -match 'showinfo.*type:I')    { $keyFrames++ }
        }
        # ~30 encoded frames; treat as broken when nearly all come back black.
        if ($blackFrames -ge 24) { return @{ Ok = $false; Reason = 'black-output' } }
        # 3 keyframes expected; require at least 2 so a one-IDR-only encoder is rejected
        # while slightly different GOP placement still passes.
        if ($keyFrames -lt 2) { return @{ Ok = $false; Reason = 'no-keyframes' } }
        return @{ Ok = $true; Reason = $null }
    } catch {
        return @{ Ok = $false; Reason = 'black-output' }
    } finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

# Return the vendor tag for a Get-GpuInfo entry.
function Get-GpuVendor {
    param([Parameter(Mandatory)] $Gpu)
    $m = $Gpu.Model
    if     ($m -match '(?i)nvidia|geforce|quadro|rtx|gtx') { return 'NVIDIA' }
    elseif ($m -match '(?i)intel')                         { return 'Intel' }
    elseif ($m -match '(?i)amd|radeon')                    { return 'AMD' }
    else                                                   { return 'Unknown' }
}

# Build the priority list of GPU encoders ordered by the selected GPU's vendor.
# Returns an array of @{Name; ExtraArgs; Vendor} (libx264 is always last).
#
# Important: ffmpeg's `-gpu` (nvenc) and `-init_hw_device qsv=hw:N` flags use
# vendor-local enumeration (Nth NVIDIA / Intel device), NOT the system-wide
# index. We translate $GpuIndex (system-wide, from Get-GpuInfo) to a vendor-
# local index, and omit the flag entirely when only one device of that vendor
# is present - it's both unnecessary and rejected by some driver builds.
function Get-GpuEncoderCandidates {
    param([int]$GpuIndex = 0, [string]$Codec = 'h264')
    $gpus = @(); try { $gpus = @(Get-GpuInfo) } catch { $gpus = @() }
    $selected = $null
    if ($gpus.Count -gt 0) {
        if ($GpuIndex -ge 0 -and $GpuIndex -lt $gpus.Count) { $selected = $gpus[$GpuIndex] }
        else { $selected = $gpus[0] }
    }
    $vendor = if ($selected) { Get-GpuVendor -Gpu $selected } else { 'Unknown' }

    # Per-vendor device counts and vendor-local index of the selected GPU
    function _LocalIndex { param($gpus,$vendor,$selected)
        $count = 0; $idx = -1
        for ($i=0; $i -lt $gpus.Count; $i++) {
            if ((Get-GpuVendor -Gpu $gpus[$i]) -eq $vendor) {
                if ($selected -and $gpus[$i].Index -eq $selected.Index) { $idx = $count }
                $count++
            }
        }
        return @{ Count=$count; Local=$idx }
    }
    $nv = _LocalIndex $gpus 'NVIDIA' $selected
    $it = _LocalIndex $gpus 'Intel'  $selected

    $nvencArgs = @()
    if ($vendor -eq 'NVIDIA' -and $nv.Count -gt 1 -and $nv.Local -ge 0) { $nvencArgs = @('-gpu',"$($nv.Local)") }
    $qsvArgs = @()
    if ($vendor -eq 'Intel' -and $it.Count -gt 1 -and $it.Local -ge 0) { $qsvArgs = @('-init_hw_device',"qsv=hw:$($it.Local)",'-filter_hw_device','hw') }

    $isHevc = ($Codec -eq 'h265')
    $nvencName = if ($isHevc) { 'hevc_nvenc' } else { 'h264_nvenc' }
    $qsvName   = if ($isHevc) { 'hevc_qsv' }   else { 'h264_qsv' }
    $amfName   = if ($isHevc) { 'hevc_amf' }   else { 'h264_amf' }
    $mfName    = if ($isHevc) { 'hevc_mf' }    else { 'h264_mf' }
    $x264Name  = if ($isHevc) { 'libx265' }    else { 'libx264' }

    $nvenc = @{ Name=$nvencName; Vendor='NVIDIA'; ExtraArgs=$nvencArgs; Codec=$Codec }
    $qsv   = @{ Name=$qsvName;   Vendor='Intel';  ExtraArgs=$qsvArgs;   Codec=$Codec }
    $amf   = @{ Name=$amfName;   Vendor='AMD';    ExtraArgs=@();        Codec=$Codec }
    $mf    = @{ Name=$mfName;    Vendor='Any';    ExtraArgs=@();        Codec=$Codec }
    $x264  = @{ Name=$x264Name;  Vendor='CPU';    ExtraArgs=@();        Codec=$Codec }

    switch ($vendor) {
        'NVIDIA' { return @($nvenc,$qsv,$amf,$mf,$x264) }
        'Intel'  { return @($qsv,$nvenc,$amf,$mf,$x264) }
        'AMD'    { return @($amf,$nvenc,$qsv,$mf,$x264) }
        default  { return @($nvenc,$qsv,$amf,$mf,$x264) }
    }
}

# Resolve the best GPU encoder once per session. Cached in $global:GpuEncoder.
# Pass -Force to re-probe (e.g. after the operator changed GPU_Index at runtime).
# Returns @{Name; ExtraArgs; Vendor} - never $null (libx264 is the guaranteed last resort).
function Get-GpuEncoder {
    param([switch]$Force)
    $codec = if ($global:mediamtxCodec) { $global:mediamtxCodec } else { 'h264' }
    # Everything that can change which encoder works. A cached result is reused only while
    # all of it is unchanged, so a GPU / codec / ffmpeg version change in config re-probes.
    $cacheKey = '{0}|{1}|{2}|{3}' -f $codec, $global:GPU_Index, [bool]$global:GPU_Acceleration, $global:ffmpegFilePath
    if (-not $Force -and $null -ne $global:GpuEncoder -and $global:GpuEncoder.CacheKey -eq $cacheKey) { return $global:GpuEncoder }

    $x264Name = if ($codec -eq 'h265') { 'libx265' } else { 'libx264' }

    # GPU acceleration disabled -> always CPU software encoder
    if (-not $global:GPU_Acceleration) {
        $global:GpuEncoder = @{ Name=$x264Name; Vendor='CPU'; ExtraArgs=@(); Codec=$codec; CacheKey=$cacheKey }
        return $global:GpuEncoder
    }

    # Enumerate encoders actually built into the bundled ffmpeg
    $available = @()
    try {
        $out = & $global:ffmpegFilePath -hide_banner -encoders 2>&1
        foreach ($line in $out) {
            if ($line -match '^\s*V[\.A-Z]+\s+(\S+)\s+') { $available += $Matches[1] }
        }
    } catch { }

    $candidates = Get-GpuEncoderCandidates -GpuIndex $global:GPU_Index -Codec $codec
    foreach ($c in $candidates) {
        $c.CacheKey = $cacheKey
        if ($c.Name -eq $x264Name) {
            # No probe needed - the software encoder is always present in the bundled ffmpeg.
            $global:GpuEncoder = $c
            try { Write-Log ("GpuEncoder resolved: {0} (vendor {1}) - fallback" -f $c.Name, $c.Vendor) -Level INFO } catch {}
            return $c
        }
        if ($available -notcontains $c.Name) { continue }
        $probe = Test-FfmpegEncoder -Encoder $c.Name -ExtraArgs $c.ExtraArgs
        if ($probe.Ok) {
            $global:GpuEncoder = $c
            try { Write-Log ("GpuEncoder resolved: {0} (vendor {1}) GpuIndex={2}" -f $c.Name, $c.Vendor, $global:GPU_Index) -Level SUCCESS } catch {}
            return $c
        } else {
            $reasonText = switch ($probe.Reason) {
                'black-output' { 'produced black output' }
                'no-keyframes' { 'ignored -g and emitted no periodic keyframes (WHEP viewers would see a black page)' }
                default         { 'failed to open' }
            }
            try { Write-Log ("GpuEncoder probe failed for {0} ({1}), trying next" -f $c.Name, $reasonText) -Level DEBUG } catch {}
        }
    }
    # Should never reach here (the software encoder is in the list and returned unconditionally above).
    $global:GpuEncoder = @{ Name=$x264Name; Vendor='CPU'; ExtraArgs=@(); Codec=$codec; CacheKey=$cacheKey }
    return $global:GpuEncoder
}
