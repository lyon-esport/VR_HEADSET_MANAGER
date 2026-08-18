
#################
# START SCREEN COPY
#################

<#
start-screenCopy -headsetIP 192.168.1.243 -adbPort 5555 -displayName "Quest 3 Manu"
$headsetIP = "192.168.1.243"
$displayName =  "Quest 3 Manu"
start-screenCopy -displayName $displayName -headsetIP $ip
#>

# Parse a scrcpy profile string into a typed object.
# Format: [view-]EYE-AUDIO-FPS-BW   (view defaults to 'portrait')
#   view  = portrait | square | wide | fullscreen  (fullscreen = crop 0:0:0:0, no angle)
#   EYE   = L | R                     (left or right eye)
#   AUDIO = D | N                     (audio-dup or no-audio)
#   FPS   = integer                   (max-fps)
#   BW    = integer Mbps              (bitrate)
# Returns @{ View; Eye; AudioDup; Fps; BitrateMbps; Raw } or $null on parse failure.
function ConvertFrom-ScrcpyProfile {
    param(
        [string]$Profile = 'portrait-R-N-45-20'
    )
    if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = 'portrait-R-N-45-20' }
    $parts = $Profile -split '-'

    # Backward compat: 4-part legacy format (Eye-Audio-FPS-BW) -> prepend "portrait"
    if ($parts.Count -eq 4 -and $parts[0] -in @('L','R')) {
        $parts = @('portrait') + $parts
    }
    if ($parts.Count -ne 5) { return $null }

    $fps = 0; $bw = 0
    if (-not [int]::TryParse([string]$parts[3], [ref]$fps)) { return $null }
    if (-not [int]::TryParse([string]$parts[4], [ref]$bw))  { return $null }

    return @{
        View        = $parts[0].ToLower()
        Eye         = $parts[1].ToUpper()
        AudioDup    = ($parts[2].ToUpper() -eq 'D')
        Fps         = $fps
        BitrateMbps = $bw
        Raw         = $Profile
    }
}


# Inverse of ConvertFrom-ScrcpyProfile. Builds the canonical "view-EYE-AUDIO-FPS-BW" string.
function ConvertTo-ScrcpyProfile {
    param(
        [string]$View = 'portrait',
        [ValidateSet('L','R')]
        [string]$Eye = 'R',
        [bool]$AudioDup = $false,
        [int]$Fps = 45,
        [int]$BitrateMbps = 20
    )
    $audio = if ($AudioDup) { 'D' } else { 'N' }
    return ("{0}-{1}-{2}-{3}-{4}" -f $View.ToLower(), $Eye.ToUpper(), $audio, $Fps, $BitrateMbps)
}


# Build the scrcpy argument string from a model template (config.json) and a per-headset profile.
# Profile format: [L/R]-[D/N]-FPS-BW  e.g. "R-N-45-20"
#   L/R = Left or Right eye  (selects crop + angle from model template)
#   D/N = audio-dup or no-audio
#   FPS = max-fps value
#   BW  = bitrate in Mbps
function ConvertTo-ScrcpyArguments {
    param(
        [string]$headsetModel,
        [string]$scrcpyProfile = "portrait-R-N-45-20",
        $modelTemplate = $null
    )

    if ([string]::IsNullOrWhiteSpace($scrcpyProfile)) { $scrcpyProfile = "portrait-R-N-45-20" }
    $parts = $scrcpyProfile -split '-'

    # Backward compat: 4-part legacy format (Eye-Audio-FPS-BW) -> prepend "portrait"
    if ($parts.Count -eq 4 -and $parts[0] -in @('L','R')) {
        $parts = @('portrait') + $parts
    }

    if ($parts.Count -ne 5) {
        Write-Log ($msg.ScrcpyInvalidProfile -f $scrcpyProfile) -Level WARNING
        $parts = @('portrait', 'R', 'N', '45', '20')
    }

    $viewName  = $parts[0].ToLower()  # e.g. portrait, square, wide
    $eye       = $parts[1].ToUpper()  # L or R
    $audioPref = $parts[2].ToUpper()  # D=audio-dup, N=no-audio
    $fps       = $parts[3]            # e.g. 45
    $bw        = $parts[4]            # e.g. 20 (Mbps)

    if ($null -eq $modelTemplate) {
        $modelTemplate = $global:scrcpyParameters.$headsetModel
    }

    $audioArg = if ($audioPref -eq 'D') { "--audio-dup" } else { "--no-audio" }

    if ($null -eq $modelTemplate) {
        Write-Log $msg.ScrcpyModelUnknown -Level WARNING
        return "--max-fps=$fps -b ${bw}M $audioArg"
    }

    # Backward compat: if old flat-string format, return as-is
    if ($modelTemplate -is [string]) {
        return $modelTemplate
    }

    # New views-based format: look up named view, fall back to first available view
    $crop  = $null
    $angle = $null
    if ($modelTemplate.views) {
        $view = $modelTemplate.views.$viewName
        if (-not $view) {
            $firstKey = ($modelTemplate.views | Get-Member -MemberType NoteProperty | Select-Object -First 1).Name
            $view = $modelTemplate.views.$firstKey
            Write-Log ($msg.ScrcpyInvalidProfile -f "view '$viewName' not found, using '$firstKey'") -Level WARNING
        }
        if ($view) {
            $eyeObj = if ($eye -eq 'L') { $view.left_eye } else { $view.right_eye }
            if ($eyeObj) {
                $crop  = $eyeObj.crop
                $angle = $eyeObj.angle
            }
        }
    } else {
        # Legacy flat template (crop_left/crop_right/angle_left/angle_right)
        $crop  = if ($eye -eq 'L') { $modelTemplate.crop_left  } else { $modelTemplate.crop_right  }
        $angle = if ($eye -eq 'L') { $modelTemplate.angle_left } else { $modelTemplate.angle_right }
    }

    $argParts = [System.Collections.Generic.List[string]]::new()
    if ($crop -and $crop -ne '0:0:0:0') { $argParts.Add("--crop $crop") }
    if ($null -ne $angle -and "$angle" -ne "" -and [int]"$angle" -ne 0) { $argParts.Add("--angle=$angle") }
    $argParts.Add("--max-fps=$fps")
    $argParts.Add("-b ${bw}M")
    if ($modelTemplate.max_size)       { $argParts.Add("--max-size=$($modelTemplate.max_size)") }
    if ($modelTemplate.video_codec)   { $argParts.Add("--video-codec=$($modelTemplate.video_codec)") }
    if ($modelTemplate.video_encoder -and $modelTemplate.video_encoder -ne "") { $argParts.Add("--video-encoder=$($modelTemplate.video_encoder)") }
    if ($modelTemplate.video_buffer)  {
        $argParts.Add("--video-buffer=$($modelTemplate.video_buffer)")
        $argParts.Add("--audio-buffer=$($modelTemplate.video_buffer)")
    }
    if ($modelTemplate.stay_awake -eq $true) { $argParts.Add("--stay-awake") }
    $argParts.Add($audioArg)

    return ($argParts -join ' ')
}

# Returns the running scrcpy process whose window title matches $displayName,
# or $null if none found. $displayName must be in window-title form (spaces -> underscores).
# Only considers processes launched from this app's scrcpy folder to avoid killing foreign scrcpy instances.
function Get-ScrcpyProcess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$displayName,
        [string]$headsetIP = ''
    )
    $ownedProcs = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }

    # Primary: match by window title (works when window is on the active virtual desktop)
    $byTitle = $ownedProcs | Where-Object { $_.MainWindowTitle -eq $displayName } | Select-Object -First 1
    if ($byTitle) { return $byTitle }

    # Fallback: match by command line - handles windows on inactive virtual desktops
    # where MainWindowTitle is empty. Requires either displayName or headsetIP in the cmdline.
    return $ownedProcs | Where-Object {
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue
        $cmdLine = $cimProc.CommandLine
        if ($cimProc) { $cimProc.Dispose() }
        if (-not $cmdLine) { return $false }
        if ($headsetIP -and $cmdLine -match [regex]::Escape($headsetIP)) { return $true }
        if ($cmdLine -match [regex]::Escape($displayName)) { return $true }
        return $false
    } | Select-Object -First 1
}

# -------------------------------------------------------------------
# Pipe-mode streaming pipeline (StreamOnly / StreamAndLocalWindow capture modes)
#
# Architecture: scrcpy records its H.264 stream to a Windows named pipe;
# ffmpeg reads from a paired pipe and pushes RTSP to mediamtx with -c copy.
# A tiny PowerShell background job acts as the named-pipe SERVER on both
# ends (scrcpy and ffmpeg both connect as CLIENTS), so the byte stream
# flows scrcpy -> pipeIn -> bridge -> pipeOut -> ffmpeg -> mediamtx without
# any re-encoding. CPU cost is near-zero compared to the legacy gdigrab+
# libx264 path.
#
# Per-headset state is tracked in $global:HeadsetPipelines keyed by the
# safe display name (spaces -> underscores), so Stop-Scrcpy can tear down
# the trio (scrcpy + bridge + ffmpeg) atomically.
# -------------------------------------------------------------------
if (-not (Get-Variable -Name HeadsetPipelines -Scope Global -ErrorAction SilentlyContinue)) {
    $global:HeadsetPipelines = @{}
}

function Get-HeadsetPipeNames {
    param([Parameter(Mandatory)][string]$SafeName)
    return @{
        In  = "vrm_${SafeName}_in"
        Out = "vrm_${SafeName}_out"
    }
}

# Starts a PowerShell job hosting two named-pipe servers and relaying bytes
# from In (scrcpy writes) to Out (ffmpeg reads). Returns the job object.
# The job blocks on WaitForConnection until both clients are attached, then
# loops on Read/Write. It exits cleanly when the writer (scrcpy) disconnects.
function Start-HeadsetPipeBridge {
    param(
        [Parameter(Mandatory)][string]$SafeName
    )
    $names = Get-HeadsetPipeNames -SafeName $SafeName
    $job = Start-Job -Name "VrmBridge_$SafeName" -ScriptBlock {
        param($pipeIn, $pipeOut)
        try {
            $srvIn  = New-Object System.IO.Pipes.NamedPipeServerStream(
                $pipeIn,  [System.IO.Pipes.PipeDirection]::In,  1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous, 1048576, 1048576)
            $srvOut = New-Object System.IO.Pipes.NamedPipeServerStream(
                $pipeOut, [System.IO.Pipes.PipeDirection]::Out, 1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous, 1048576, 1048576)
            # Accept both connections IN PARALLEL via async begin/end. If we wait
            # sequentially (In first, then Out), scrcpy fills the pipe-in kernel
            # buffer and errors out long before ffmpeg gets a chance to connect.
            $arIn  = $srvIn.BeginWaitForConnection($null, $null)
            $arOut = $srvOut.BeginWaitForConnection($null, $null)
            $srvIn.EndWaitForConnection($arIn)
            $srvOut.EndWaitForConnection($arOut)
            $buf = New-Object byte[] 4096
            while ($true) {
                $n = $srvIn.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                try { $srvOut.Write($buf, 0, $n); $srvOut.Flush() } catch { break }
            }
        } finally {
            try { $srvIn.Dispose()  } catch {}
            try { $srvOut.Dispose() } catch {}
        }
    } -ArgumentList $names.In, $names.Out
    return $job
}

# Quotes/escapes a single argument for ProcessStartInfo.Arguments (a single
# command-line string), following the same rules the Win32 CRT / CommandLineToArgvW
# parser expects: wrap in quotes if it contains whitespace or a quote, double any
# backslashes that immediately precede a quote (or the closing quote), and escape
# embedded quotes. Needed because ProcessStartInfo.ArgumentList is unavailable on
# some PowerShell 5.1 / .NET runtimes (evaluates to $null there).
function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Launches ffmpeg as a pipe-reader -> RTSP-publisher to mediamtx, and optionally
# a second output that writes the H.264 stream to a recording file. Both outputs
# use -c copy so the cost is one extra muxer (no re-encode).
function Start-FfmpegStreamPush {
    param(
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][string]$RtspUrl,
        [string]$RecordFile = '',
        [string]$SourceCodec = 'h264'
    )
    $names = Get-HeadsetPipeNames -SafeName $SafeName
    $logErr = Join-Path $global:logFolder ("${SafeName}_ffmpegPush_stderr.txt")
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('-hide_banner','-loglevel','warning'))
    # Passthrough needs the bitstream filter matching the actual stream codec
    # (mkv/AVCC -> Annex-B for RTSP). An unrecognized codec cannot be safely
    # passed through - force re-encode for this stream so it doesn't die like
    # the h265-with-h264-filter bug this branch was fixed for.
    $forceReencode = $global:mediamtxReencode
    $passthroughArgs = $null
    if (-not $forceReencode) {
        $passthroughArgs = switch ($SourceCodec) {
            'h264'  { @('-bsf:v','h264_mp4toannexb') }
            'h265'  { @('-bsf:v','hevc_mp4toannexb','-tag:v','hvc1') }
            default {
                Write-Log ("Start-FfmpegStreamPush: unknown SourceCodec '{0}' for {1} - passthrough bitstream filter unknown, forcing re-encode for this stream" -f $SourceCodec, $SafeName) -Level ERROR
                $forceReencode = $true
                $null
            }
        }
    }
    # Low-latency input flags applied ONLY when we are going to re-encode. They
    # cut libavformat's default 5s analyzeduration / 5MB probesize down to the
    # minimum the matroska demuxer needs to identify the H.264 stream (without
    # this it cannot fulfil -map 0:v:0 and ffmpeg exits immediately). 100ms /
    # 32KB is enough in practice while still saving ~400-700ms vs the defaults.
    # -fflags +nobuffer + -flags low_delay disable libavformat's read-ahead and
    # frame-reorder delay. -avioflags direct is intentionally NOT used: it
    # bypasses I/O buffering for the named pipe which proved unstable.
    if ($forceReencode) {
        $argList.AddRange([string[]]@(
            '-fflags','+nobuffer','-flags','low_delay',
            '-analyzeduration','100000','-probesize','32768'))
    }
    $argList.AddRange([string[]]@('-f','matroska','-i',"\\.\pipe\$($names.Out)"))
    # Output 1: RTSP push into mediamtx. mediamtx remuxes this single source into
    # RTSP / HLS / WebRTC (WHEP) for downstream viewers, so re-encoding here caps
    # bandwidth on every viewer protocol (including the video_monitor web page).
    # The optional file recording output below stays -c copy regardless, so on-disk
    # captures keep source quality.
    if ($forceReencode) {
        $enc = Get-GpuEncoder
        $bw  = [string]$global:mediamtxBitrate
        # config.mediamtx.stream_bitrate is expected in "<n>M" form (see templates\config\config.json,
        # video_quality_automation.ps1's Set-VqaAutoApply/Restore-VqaOriginals writers). Guard against a
        # bare digit value (e.g. manually edited/saved without the unit) being passed straight to -b:v -
        # ffmpeg then interprets it as bits/sec, which is too low for the encoder to open at all.
        if ($bw -match '^\d+$') { $bw = "${bw}M" }
        $fps = $global:mediamtxFramerate
        # -bf 0 and -g $fps are required on EVERY arm: mediamtx WebRTC/WHEP rejects
        # H.264 streams containing B-frames ("WebRTC doesn't support H264 streams
        # with B-frames" closes the session). qsv/amf/mf emit B-frames by default;
        # nvenc and libx264 already disable them via tune presets but explicit is
        # safer. Short GOP (= framerate) ensures new WHEP subscribers receive a
        # keyframe within ~1s of joining.
        $gop = [string]$fps
        # Per-encoder low-latency tails: disable async pipelining / lookahead so
        # frames flow through with minimal in-encoder queuing. qsv defaults to
        # async_depth=4 (~130 ms at 30 fps); nvenc has an implicit -delay; the
        # libx264 fallback uses sliced threading to avoid frame-level latency.
        $encParams = switch ($enc.Name) {
            'h264_nvenc' { @('-c:v','h264_nvenc','-preset','p1','-tune','ll','-rc','cbr','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-delay','0','-rc-lookahead','0') }
            'h264_qsv'   { @('-c:v','h264_qsv','-preset','veryfast','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-async_depth','1','-look_ahead','0') }
            'h264_amf'   { @('-c:v','h264_amf','-usage','ultralowlatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-quality','speed','-rc','cbr','-async_depth','1') }
            'h264_mf'    { @('-c:v','h264_mf','-b:v',$bw,'-bf','0','-g',$gop,'-rc_mode','CBR') }
            'hevc_nvenc' { @('-c:v','hevc_nvenc','-preset','p1','-tune','ll','-rc','cbr','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-delay','0','-rc-lookahead','0','-tag:v','hvc1') }
            'hevc_qsv'   { @('-c:v','hevc_qsv','-preset','veryfast','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-async_depth','1','-look_ahead','0','-tag:v','hvc1') }
            'hevc_amf'   { @('-c:v','hevc_amf','-usage','ultralowlatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-quality','speed','-rc','cbr','-async_depth','1','-tag:v','hvc1') }
            'hevc_mf'    { @('-c:v','hevc_mf','-b:v',$bw,'-bf','0','-g',$gop,'-rc_mode','CBR','-tag:v','hvc1') }
            'libx265'    { @('-c:v','libx265','-preset','ultrafast','-tune','zerolatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-x265-params','force-cfr=1','-tag:v','hvc1','-threads','4') }
            default      { @('-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-b:v',$bw,'-maxrate',$bw,'-bufsize',$bw,'-bf','0','-g',$gop,'-x264-params','nal-hrd=cbr:force-cfr=1:sliced-threads=1','-threads','4') }
        }
        $rtspOut = [System.Collections.Generic.List[string]]::new()
        $rtspOut.AddRange([string[]]@('-map','0:v:0'))
        $rtspOut.AddRange([string[]]$encParams)
        if ($enc.ExtraArgs -and $enc.ExtraArgs.Count -gt 0) { $rtspOut.AddRange([string[]]$enc.ExtraArgs) }
        # -flush_packets / -muxdelay / -muxpreload: tell the RTSP muxer to push
        # every packet immediately and not pre-buffer any startup interval.
        $rtspOut.AddRange([string[]]@('-r',[string]$fps,'-pix_fmt','yuv420p',
            '-pkt_size','1316','-flush_packets','1','-muxdelay','0','-muxpreload','0',
            '-f','rtsp','-rtsp_transport','tcp',$RtspUrl))
        $argList.AddRange([string[]]$rtspOut.ToArray())
        Write-Log ("Start-FfmpegStreamPush: {0} re-encoding with {1} @ {2}fps / {3} (low-latency tuning on)" -f $SafeName, $enc.Name, $fps, $bw) -Level DEBUG
    } else {
        # Passthrough (Annex-B is required by mediamtx; MKV stores AVCC)
        $argList.AddRange([string[]](@('-map','0','-c','copy') + $passthroughArgs +
            @('-f','rtsp','-rtsp_transport','tcp',$RtspUrl)))
    }
    # Optional output 2: file recording (MKV/MP4 - ffmpeg picks from extension).
    # Passed unquoted - manually quoted/escaped below by ConvertTo-ProcessArgument,
    # same as every other path-bearing argument in this list (e.g. the -i pipe path).
    # Manually pre-quoting here would double-quote the value.
    if ($RecordFile) {
        $argList.AddRange([string[]]@('-map','0','-c','copy','-y',$RecordFile))
    }
    # Started via raw Process/ProcessStartInfo (not Start-Process) so we retain a live,
    # writable StandardInput stream - needed to ask ffmpeg to quit gracefully ("q") on
    # stop, so it flushes/finalises the -c copy recording output instead of losing
    # buffered but unwritten data to a hard kill. RedirectStandardError must then be
    # drained asynchronously ourselves (Start-Process did this for us via its file
    # redirection) or ffmpeg can block once its stderr pipe buffer fills.
    # NOTE: ProcessStartInfo.ArgumentList is unusable here - on this host/PowerShell 5.1
    # runtime it evaluates to $null (pre-.NET-4.7.2 behavior of the loaded CLR), so
    # arguments are joined into a single quoted command-line string instead.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = $global:ffmpegFilePath
    $psi.Arguments = ($argList | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()

    $errWriter = [System.IO.StreamWriter]::new($logErr, $false, [System.Text.Encoding]::UTF8)
    $errWriter.AutoFlush = $true
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $errWriter -Action {
        if ($EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) }
    }
    $proc.BeginErrorReadLine()

    return @{
        Process              = $proc
        ErrorWriter          = $errWriter
        ErrorSubscriptionId  = $errSub.Id
    }
}

# Sets the global capture mode, persists it to config.json, and restarts any
# currently-running scrcpy session that's affected by the change. Used by the
# CLI Config sub-menu and the web settings page so the operator can toggle
# window visibility live without bouncing the app.
function Set-CaptureMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('StreamOnly','StreamAndLocalWindow','LocalWindow')]
        [string]$Mode
    )
    if ($global:CaptureMode -eq $Mode) {
        Write-Log ("CaptureMode unchanged ({0})" -f $Mode) -Level DEBUG
        return $true
    }
    $previous = $global:CaptureMode

    # Persist to config.json (the source of truth across restarts)
    $cfgPath = Join-Path $global:ScriptPath "config\config.json"
    try {
        $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
        if (-not $cfg) { Write-Log "Set-CaptureMode: could not read config.json" -Level ERROR; return $false }
        if ($null -eq $cfg.Performance) {
            $cfg | Add-Member -NotePropertyName Performance -NotePropertyValue ([PSCustomObject]@{ GPU_Acceleration = $true; GPU_Index = 0; Capture_Mode = $Mode })
        } else {
            if ($cfg.Performance.PSObject.Properties.Name -contains 'Capture_Mode') {
                $cfg.Performance.Capture_Mode = $Mode
            } else {
                $cfg.Performance | Add-Member -NotePropertyName Capture_Mode -NotePropertyValue $Mode
            }
        }
        Write-FileWithoutBom -Path $cfgPath -Content ($cfg | ConvertTo-Json -Depth 20)
    } catch {
        Write-Log ("Set-CaptureMode: failed to update config.json: {0}" -f $_.Exception.Message) -Level ERROR
        return $false
    }
    $global:CaptureMode = $Mode

    # mediamtx YAML structure depends on the mode (paths: {} vs all_others:).
    # LocalWindow uses paths: {} (no publishers accepted),
    # pipe modes (StreamOnly/StreamAndLocalWindow) need all_others:. Restart mediamtx
    # only when crossing that boundary.
    $crossedBoundary = (($previous -eq 'LocalWindow') -ne ($Mode -eq 'LocalWindow'))
    if ($crossedBoundary) {
        try { Stop-MediaMtx; Start-Sleep -Milliseconds 500; Start-MediaMtx } catch {
            Write-Log ("Set-CaptureMode: mediamtx restart failed: {0}" -f $_.Exception.Message) -Level WARNING
        }
    }

    # Kill every owned scrcpy process so they get restarted in the new mode.
    # We deliberately do NOT call start-screenCopy here:
    #  - This helper is called both from the web server (separate process - it does
    #    not own the running pipelines) and from the CLI menu (main process).
    #    Restarting from the wrong process would orphan the bridge job and lose
    #    track of the pipeline.
    #  - The VRMonitor background job reloads config.json on every slow cycle
    #    (refresh_timer), then Watch-ScrcpyProcesses sees a headset with
    #    AutoRestart=True and no running scrcpy, and respawns it with the freshly
    #    loaded $global:CaptureMode. That is the single owner of restarts.
    $owned = @(Get-Process -Name scrcpy -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" })
    foreach ($p in $owned) {
        $title = if ($p.MainWindowTitle) { $p.MainWindowTitle } else { '' }
        $headset = $null
        if ($title) {
            $headset = Get-KnownHeadsets | Where-Object { (Convert-Displayname $_.Name) -eq $title } | Select-Object -First 1
        }
        if ($headset) {
            Write-Log ("Set-CaptureMode: stopping {0} so VRMonitor restarts it in {1} mode" -f $headset.Name, $Mode) -Level INFO
            Stop-Scrcpy -HeadsetName $headset.Name | Out-Null
        } else {
            # Headless scrcpy has no window title - fall back to direct PID kill.
            Write-Log ("Set-CaptureMode: stopping scrcpy pid={0} (no window title, headless) so VRMonitor restarts it" -f $p.Id) -Level INFO
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
        }
    }
    # Local registry cleanup (web/main may both hold dead entries after a kill)
    foreach ($key in @($global:HeadsetPipelines.Keys)) { Stop-HeadsetPipeline -SafeName $key }

    Write-Log ("CaptureMode set to {0} (was {1}); VRMonitor will respawn on next cycle" -f $Mode, $previous) -Level SUCCESS
    return $true
}

# Tears down the bridge job + ffmpeg push for one headset. Called by Stop-Scrcpy.
function Stop-HeadsetPipeline {
    param([Parameter(Mandatory)][string]$SafeName)
    $entry = $global:HeadsetPipelines[$SafeName]
    if (-not $entry) { return }
    if ($entry.FfmpegProcess) {
        $ff = $entry.FfmpegProcess
        try {
            if (-not $ff.HasExited) {
                # Ask ffmpeg to quit gracefully ("q" on stdin) so the -c copy recording
                # output gets flushed/finalised instead of losing buffered frames to a
                # hard kill. Only force-kill if it doesn't exit within the timeout.
                try {
                    $ff.StandardInput.WriteLine('q')
                    $ff.StandardInput.Flush()
                    $ff.StandardInput.Close()
                } catch {}
                if (-not $ff.WaitForExit(5000)) {
                    Write-Log ("Stop-HeadsetPipeline: ffmpeg for {0} did not exit gracefully within timeout - forcing kill" -f $SafeName) -Level WARNING
                    try { Stop-Process -Id $ff.Id -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        } catch {}
        try { $ff.CancelErrorRead() } catch {}
    }
    if ($entry.FfmpegErrorSubId) {
        try { Unregister-Event -SubscriptionId $entry.FfmpegErrorSubId -ErrorAction SilentlyContinue } catch {}
    }
    if ($entry.FfmpegErrorWriter) {
        try { $entry.FfmpegErrorWriter.Dispose() } catch {}
    }
    if ($entry.Bridge) {
        try { Stop-Job   $entry.Bridge -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $entry.Bridge -Force -ErrorAction SilentlyContinue } catch {}
    }
    $global:HeadsetPipelines.Remove($SafeName)
}

function start-screenCopy {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,

        [string]$displayName = [string]$headsetIP,

        [boolean]$recording = $false,

        [int]$adbPort = $global:adbPort_default,

        [string]$scrcpyProfile = "R-N-45-20"

    )

    $displayName =  Convert-Displayname($displayName)

    # Guard: skip if a scrcpy window for this headset is already running
    if (Get-ScrcpyProcess -displayName $displayName) {
        Write-Log -Message ($msg.ScrcpyAlreadyRunning -f $displayName) -Level WARNING
        Start-Sleep -Seconds 5
        return
    }

    $adb = $global:adbPath
    $adb_device = "$headsetIP`:$adbPort"
    $scrcpy = $global:scrcpyFilePath

    if (-not(test-port -hostname $headsetIP -port $adbPort).open){ # Check if the ADB port is open
        Write-Log -Message ($msg.AdbPortNotResponding -f $adbPort) -Level WARNING
        return
    }

    # ADB port open, initiating connection to the headset
    try {
        Write-Log -Message ($msg.ScrcpyCheckingAdb -f $adb_device) -Level "INFO"

        $connectedDevices = & $adb devices | Select-String $adb_device -AllMatches
        if ($connectedDevices.Matches.Count -lt 1) {
            Write-Log -Message ($msg.NoActiveAdbConnection -f $adb_device) -Level "INFO"
            & $adb connect $adb_device | Out-Null
            Start-Sleep -Seconds 2
        }

    } catch {
        Write-Log -Message ($msg.ScrcpyExecError -f $_.Exception.Message) -Level "ERROR"
		return
    }


	$options = ""
    $wifiDevice     = Get-AdbWifiDevice -headsetIP $headsetIP
    $headsetModel   = if ($wifiDevice) { Get-HeadsetModel -Device $wifiDevice } else { $null }
    Write-Log -Message ($msg.ScrcpyModelDetected -f $headsetModel) -Level "INFO"
    $modelTemplate  = $global:scrcpyParameters.$headsetModel
    $sourceCodec    = if ($modelTemplate -and $modelTemplate.video_codec) { $modelTemplate.video_codec } else { 'h264' }
	<#
    if ($adb_model -like "Quest 2") {
		#$options = "--crop=1550:1250:2000:280 --max-size=800 --video-bit-rate=10M --max-fps 60 --video-buffer=50 --video-codec=h265" #Oeil droit
        $options = "-b10m --max-fps 60 --video-buffer=50 --video-codec=h265" #Oeil droit
	} elseif ($adb_model -like "Quest 3") {
		#crop = "1700:1200:250:500"
        #$options = "--crop=1664:1304:2260:450 --angle=-21 --max-size=800 --video-bit-rate=10M --max-fps=30 --video-codec=h265" #  --video-encoder=OMX.qcom.video.encoder.avc " #Oeil droit  --video-buffer=100
        #$options = "-b10m --max-fps=60 --video-codec=h264" #Oeil droit  --video-buffer=100
        $options = " -b20m --max-fps=30 --video-codec=h264 --video-buffer=100" #  --video-encoder=OMX.qcom.video.encoder.avc " #Oeil droit  --video-buffer=100
	}
    #>



    $options = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $scrcpyProfile

    # Check that scrcpy exists
    if (-not (Test-Path $scrcpy)) {
        Write-Log -Message ($msg.ScrcpyNotFound -f $scrcpyPath) -Level "ERROR"
        return
    }

    # Check if recording is enabled
    if ($recording) {
        $timestamp_Today = Get-Date -Format "yyyy-MM-dd"
        $recordFolder = Join-Path -Path $global:scrcpyRecordFolder -ChildPath ("${timestamp_Today}\${displayName}")

        if (-not (Test-Path $recordFolder)) {
            New-Item -ItemType Directory -Path $recordFolder -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $recordFile = Join-Path -Path $recordFolder -ChildPath "${displayName}_$timestamp.mp4"
        $recordOption = "--record=`"$recordFile`""
        Write-Log -Message ($msg.ScrcpyRecording -f $recordFile) -Level "INFO"
    } else {
        $recordOption = ""
    }
    # Dispatch on capture mode:
    #   StreamOnly          -> --no-window + record-to-pipe + ffmpeg push to RTSP
    #   StreamAndLocalWindow-> visible window + record-to-pipe + ffmpeg push to RTSP (no GDI)
    #   LocalWindow         -> visible window only, no streaming pipeline (file recording via scrcpy)
    $captureMode = if ($global:CaptureMode) { $global:CaptureMode } else { 'StreamAndLocalWindow' }
    $usePipe = ($captureMode -in @('StreamOnly','StreamAndLocalWindow'))

    if ($captureMode -eq 'LocalWindow') {
        # No streaming - GPU SDL is fine here. File recording (if any)
        # uses scrcpy's native --record directly.
        $arguments = "-s $adb_device $options --window-title=$displayName $recordOption"
    } else {
        $names    = Get-HeadsetPipeNames -SafeName $displayName
        # Pipe mode forces periodic IDR frames so late RTSP subscribers can start decoding immediately.
        $pipeArgs = "--record=\\.\pipe\$($names.In) --record-format=mkv --video-codec-options=i-frame-interval=1"
        if ($captureMode -eq 'StreamOnly') { $pipeArgs += " --no-window --no-playback" }
        # In window-visible mode, prefer GPU SDL rendering when GPU is on.
        $renderArg = if ($captureMode -eq 'StreamAndLocalWindow' -and -not $global:GPU_Acceleration) { "--render-driver=software" } else { "" }
        # In pipe mode scrcpy can only have ONE --record target (the pipe), so we
        # do not pass the file-record option here. ffmpeg writes the recording
        # file as a second -c copy output below.
        $arguments = "-s $adb_device $options --window-title=$displayName $renderArg $pipeArgs"
    }
    #.\scrcpy.exe --crop 1664:1304:2260:450 --angle=-21 --max-fps 45 -b 16M --no-audio --video-buffer=100 --video-codec=h264 --video-encoder=OMX.qcom.video.encoder.avc -s $adb_device
    #.\sources\scrcpy-win64-v3.3\scrcpy.exe -s 192.168.1.243:5555 -b20m --crop=1664:1304:2260:450 --angle=-21 --max-size=800 --max-fps=30 --video-codec=h265 --no-audio --window-title=Q3_BLUE

	Write-Log -Message ($msg.ScrcpyLaunching -f $arguments) -Level "SUCCESS"

    # Pipe modes: start the bridge BEFORE scrcpy so the pipe-in server is listening.
    # Defensively clear any leftover pipeline entry first - if a previous scrcpy died
    # but its bridge job or ffmpeg push was still tracked, the named-pipe server names
    # would still be in use and a fresh bridge would fail to create.
    $bridgeJob = $null
    if ($usePipe) {
        Stop-HeadsetPipeline -SafeName $displayName
        try {
            $bridgeJob = Start-HeadsetPipeBridge -SafeName $displayName
            Start-Sleep -Milliseconds 500   # let the job create both pipe-server objects
        } catch {
            Write-Log -Message ("Failed to start pipe bridge for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            return
        }
    }

    try {
        $scrcpyProc = Start-Process $scrcpy -ArgumentList $arguments -PassThru -NoNewWindow `
			-RedirectStandardOutput (Join-Path -Path $global:logFolder -ChildPath ($displayName+"_StandardOutput.txt")) `
			-RedirectStandardError  (Join-Path -Path $global:logFolder -ChildPath ($displayName+"_StandardError.txt"))
	} catch {
        Write-Log -Message ($msg.ScrcpyLaunchError -f $_.Exception.Message) -Level "ERROR"
        if ($bridgeJob) { try { Stop-Job $bridgeJob -EA SilentlyContinue; Remove-Job $bridgeJob -Force -EA SilentlyContinue } catch {} }
		return
    }

    if ($usePipe) {
        # Wait for scrcpy to open its record file (connect to pipe-in) and produce the first
        # video packets so the H.264 extradata is available - ffmpeg needs it for the RTSP
        # PUBLISH SDP, otherwise mediamtx rejects with 400 Bad Request.
        Start-Sleep -Milliseconds 3000
        try {
            $pathName = (ConvertTo-RestreamPathName -HeadsetName $displayName)
            $rtspUrl  = "rtsp://127.0.0.1:$($global:mediamtxRtspPort)/$pathName"
            # In pipe mode, ffmpeg handles file recording instead of scrcpy
            # (scrcpy can only have one --record target, already taken by the pipe).
            # Switch the file extension to mkv to avoid moov-atom-at-end issues with
            # streaming-style writes - mkv finalises incrementally and survives kills.
            $ffmpegRecord = ''
            if ($recording -and $recordFile) {
                $ffmpegRecord = [System.IO.Path]::ChangeExtension($recordFile, '.mkv')
            }
            $ffmpegPush = Start-FfmpegStreamPush -SafeName $displayName -RtspUrl $rtspUrl -RecordFile $ffmpegRecord -SourceCodec $sourceCodec
            $global:HeadsetPipelines[$displayName] = @{
                Bridge              = $bridgeJob
                ScrcpyProcess       = $scrcpyProc
                FfmpegProcess       = $ffmpegPush.Process
                FfmpegErrorWriter   = $ffmpegPush.ErrorWriter
                FfmpegErrorSubId    = $ffmpegPush.ErrorSubscriptionId
                PipeInName     = (Get-HeadsetPipeNames -SafeName $displayName).In
                PipeOutName    = (Get-HeadsetPipeNames -SafeName $displayName).Out
                RtspUrl        = $rtspUrl
                CaptureMode    = $captureMode
                Recording      = [bool]$recording
                RecordFile     = $ffmpegRecord
                StartedAt      = (Get-Date)
            }
            Write-Log ("Pipe pipeline up for {0}: mode={1} rtsp={2}" -f $displayName, $captureMode, $rtspUrl) -Level SUCCESS
        } catch {
            Write-Log ("Failed to start ffmpeg push for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            try { Stop-Process -Id $scrcpyProc.Id -Force -EA SilentlyContinue } catch {}
            if ($bridgeJob) { try { Stop-Job $bridgeJob -EA SilentlyContinue; Remove-Job $bridgeJob -Force -EA SilentlyContinue } catch {} }
        }
    }
}




function Watch-ScrcpyProcesses {

    # Step 1: Retrieve scrcpy processes running on the machine

    $knownHeadsets_with_autorestart = Get-KnownHeadsets | Where-Object { ConvertTo-BoolField $_.scrcpy_AutoRestart }

    # For each headset with autorestart, ensure there's a scrcpy process started

    foreach ($headset in $knownHeadsets_with_autorestart) {
        Write-Log ($msg.ScrcpyCheckHeadset -f $headset.Name, $headset.IPAddress) -Level DEBUG

        $headsetInfos = Get-KnownHeadsetInfos $headset
        if (ConvertTo-BoolField $headsetInfos.ADBWifi) {
            Write-Log ($msg.ScrcpyCheckProcess -f $headset.Name, $headset.IPAddress) -Level DEBUG
            $runningScrcpyProcess_forThisheadset = Get-ScrcpyProcess -displayName (Convert-Displayname $headset.Name) -headsetIP $headset.IPAddress

            Write-Log ($msg.ScrcpyProcessFound -f $runningScrcpyProcess_forThisheadset) -Level DEBUG
            if (-not $runningScrcpyProcess_forThisheadset) {
                # Re-read capture mode from config.json to avoid a stale mode when
                # Set-CaptureMode fires between the slow-path Get-Config and this watchdog.
                # Uses -LiteralPath and -Encoding UTF8 (mandatory for the accented project root).
                try {
                    $freshJson = Get-Content -LiteralPath (Join-Path $global:ScriptPath "config\config.json") -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if ($freshJson -and $freshJson.Performance -and $freshJson.Performance.Capture_Mode) {
                        $global:CaptureMode = $freshJson.Performance.Capture_Mode
                    }
                } catch {}
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording (ConvertTo-BoolField $headset.Record) -scrcpyProfile $headsetProfile
            } else {
                # scrcpy is running - check if parameters have changed
                $shouldRestart = $false
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                $expectedRecording = ($headset.Record -eq "True")

                $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($runningScrcpyProcess_forThisheadset.Id)" -ErrorAction SilentlyContinue
                $cmdLine = $cimProc.CommandLine
                if ($cimProc) { $cimProc.Dispose() }

                # Check recording option mismatch only when we could actually read the command line.
                # If $cmdLine is null (process vanished from WMI), skip the check to avoid a
                # spurious restart caused by $false -ne $true when recording is expected.
                # In pipe mode, scrcpy's --record always points to a named pipe (streaming);
                # the recording file is written by ffmpeg as a second output. The cmdline does
                # NOT carry that file, so we compare against the pipeline registry instead.
                $inPipeMode = $cmdLine -and ($cmdLine -match '--record=\\\\\.\\pipe\\')
                if ($inPipeMode) {
                    $safeName = Convert-Displayname $headset.Name
                    $pipeline = $global:HeadsetPipelines[$safeName]
                    $currentRecording = if ($pipeline) { [bool]$pipeline.Recording } else { $false }
                    if ($currentRecording -ne $expectedRecording) {
                        Write-Log ($msg.ScrcpyRecordingChanged -f $headset.Name) -Level INFO
                        $shouldRestart = $true
                    }
                } else {
                    $hasRecord = if ($cmdLine) { [bool]($cmdLine -match '--record=(?!\\\\\.\\pipe\\)') } else { $expectedRecording }
                    if ($hasRecord -ne $expectedRecording) {
                        Write-Log ($msg.ScrcpyRecordingChanged -f $headset.Name) -Level INFO
                        $shouldRestart = $true
                    }
                }

                # Check scrcpy options and profile mismatch
                if (-not $shouldRestart) {
                    $headsetModel = $headsetInfos.Model
                    $expectedOptions = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $headsetProfile
                    if ($expectedOptions -ne "") {
                        # Strip pipe-mode args (added by start-screenCopy on top of ConvertTo-ScrcpyArguments
                        # output) from the cmdline before comparison, otherwise the watchdog will see them as
                        # "options changed" and restart-loop every cycle.
                        $cmdLineForCompare = $cmdLine
                        $cmdLineForCompare = $cmdLineForCompare -replace '--record=\\\\\.\\pipe\\\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--record-format=\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--video-codec-options=\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--no-window', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--no-playback', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--render-driver=\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--window-title=\S+', ''
                        $normalizedCmdLine = ($cmdLineForCompare -replace '\s+', ' ').Trim()
                        $normalizedOptions = ($expectedOptions -replace '\s+', ' ').Trim()
                        if ($normalizedCmdLine -notlike "*$normalizedOptions*") {
                            Write-Log ($msg.ScrcpyOptionsChanged -f $headset.Name, $headsetModel) -Level INFO
                            $shouldRestart = $true
                        }
                    }
                }

                if ($shouldRestart) {
                    Write-Log ($msg.ScrcpyRestarting -f $headset.Name) -Level INFO
                    # Send WM_CLOSE so scrcpy can finalise any recording file before exiting
                    $closed = $runningScrcpyProcess_forThisheadset.CloseMainWindow()
                    if ($closed) {
                        $runningScrcpyProcess_forThisheadset.WaitForExit(10000) | Out-Null
                    }
                    if (-not $runningScrcpyProcess_forThisheadset.HasExited) {
                        Write-Log ($msg.ScrcpyStopTimeout -f $headset.Name) -Level WARNING
                        Stop-Process -Id $runningScrcpyProcess_forThisheadset.Id -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 1
                    }
                    start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording $expectedRecording -scrcpyProfile $headsetProfile
                }
            }
        }
    }
}


# Gracefully stops scrcpy processes launched from this app's scrcpy folder.
# No argument: stops all owned scrcpy processes (shutdown path).
# -HeadsetName: stops only the process for that specific headset.
function Stop-Scrcpy {
    param(
        [string]$HeadsetName = '',
        [string]$HeadsetIP   = ''
    )

    if ($HeadsetName) {
        $displayName = Convert-Displayname $HeadsetName
        $procs = @(Get-ScrcpyProcess -displayName $displayName -headsetIP $HeadsetIP)
        if (-not $procs) {
            # scrcpy already gone (crashed or exited on its own) - still tear
            # down any leftover pipe-bridge/ffmpeg-push trio for this headset
            # before returning, so the registry doesn't leak.
            Stop-HeadsetPipeline -SafeName $displayName
            if ($msg.ScrcpyNotRunning) { Write-Log ($msg.ScrcpyNotRunning -f $displayName) -Level WARNING }
            return $false
        }
    } else {
        $procs = @(Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
                   Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" })
        if (-not $procs) { return $true }
    }

    foreach ($proc in $procs) {
        $closed = $proc.CloseMainWindow()
        if ($closed) { $proc.WaitForExit(10000) | Out-Null }
        if (-not $proc.HasExited) {
            Write-Log ($msg.ScrcpyStopTimeout -f $proc.MainWindowTitle) -Level WARNING
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    # Tear down pipe-mode bridge + ffmpeg push for the targeted scope.
    if ($HeadsetName) {
        $safe = Convert-Displayname $HeadsetName
        Stop-HeadsetPipeline -SafeName $safe
    } else {
        foreach ($key in @($global:HeadsetPipelines.Keys)) { Stop-HeadsetPipeline -SafeName $key }
    }

    if ($HeadsetName) {
        Write-Log ($msg.ScrcpyStopForHeadset -f (Convert-Displayname $HeadsetName)) -Level INFO
    } else {
        Write-Log "All scrcpy processes stopped." -Level INFO
    }
    return $true
}


function Convert-Displayname {
    param(
             [Parameter(Mandatory=$true)]
             [string]$displayName
        )
    $displayName =  $displayName.replace(" ","_") # convert displayname
    return $displayName
}


function Install-ScrcpyDependencies {
    param (
        [string]$scrcpyFolder
    )
    # Create the scrcpy folder if it doesn't exist
    # scrcpy-server
    if (-not (Test-Path -Path "C:\msys64\mingw64\share\scrcpy\scrcpy-server")) {
        New-Item -Path "C:/msys64/mingw64/share/scrcpy/" -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\scrcpy-server" -Destination "C:\msys64\mingw64\share\scrcpy\" -Force
        Write-Log $msg.ScrcpyServerFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy server file already exists." -Level DEBUG
    }
    # scrcpy.png
    $destinationPath = "C:/msys64/mingw64/share/icons/hicolor/256x256/apps/scrcpy.png"
    if (-not (Test-Path -Path $destinationPath)) {
        New-Item -Path ([System.IO.Path]::GetDirectoryName($destinationPath)) -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\icon.png" -Destination $destinationPath -Force
        Write-Log $msg.ScrcpyIconFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy icon file already exists." -Level DEBUG
    }
}
