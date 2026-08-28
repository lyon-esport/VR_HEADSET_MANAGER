#Requires -Version 5.1
<#
.SYNOPSIS
    Section 60 - end-to-end streaming: scrcpy -> ffmpeg -> mediamtx, verified by
    15 seconds of genuinely flowing video.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    NEEDS HARDWARE. SKIPs (never FAILs) when no headset is reachable.

    The assertion that matters is Test-NrtStreamStable: a mediamtx path that
    merely EXISTS proves nothing - ffmpeg registers the path before a single
    frame arrives, and a broken encoder leaves it open and empty. So every
    streaming case here demands a 15s window in which the path stays ready,
    bytesReceived climbs, and average throughput clears a floor.

    Coverage scales with depth:
      Light     one stream on the headset's configured settings
      Standard  + re-encode ON and OFF (the two branches of Start-FfmpegStreamPush)
                + recording produces a growing file
      Full      + h264 vs h265

    Config changes go through POST /api/config/save, which owns the restart
    choreography (bounce every scrcpy session, then mediamtx) under the VQA lock.
    Doing it by writing config.json directly would leave the running ffmpeg
    processes on the old settings and the test would silently measure nothing.

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$depth   = $global:TestRun.Depth

# Boot BEFORE reading ports. Confirm-SandboxApp is idempotent and is what
# provisions config.json and points Invoke-VrmApi at the sandbox web server, so
# running -Sections 60 on its own works exactly like running it after 50.
# Reading the ports first would silently fall back to defaults and every API call
# would come back HTTP 0.
$appUp      = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot
$ports      = Get-NrtSandboxPorts -TargetRoot $target
$nrtHeadset = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort $ports.Adb
$streamPath = ''
$nrtSafeName = ''
if ($nrtHeadset) {
    $streamPath  = ConvertTo-NrtStreamPath -Name $nrtHeadset.Name
    $nrtSafeName = ConvertTo-NrtSafeName   -Name $nrtHeadset.Name
}

# The operator's original mediamtx settings, restored in the teardown test.
$originalReEncode = $ports.ReEncode
$originalCodec    = $ports.Codec

$stableSeconds = 15

function Assert-NrtStreamHeadsetAvailable {
    if (-not $nrtHeadset) {
        Skip-Test 'no reachable headset in the dev registry (ping + ADB port) - pass -HeadsetName to force one'
    }
}

function Set-NrtMediaMtxSetting {
    <#
    .SYNOPSIS
        Patches one mediamtx setting through /api/config/save so the app performs
        its own scrcpy + mediamtx restart, then waits for the stream to come back.

    .DESCRIPTION
        Reads the live config, changes the requested field, posts the whole
        object back. Returns the parsed response so the caller can report what
        was restarted.

    .EXAMPLE
        Set-NrtMediaMtxSetting -Field 'reencode_in_ffmpeg' -Value $false
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)]$Value
    )

    $cur = Invoke-VrmApi -Path '/api/config'
    if (-not $cur.Ok -or -not $cur.Json) { throw ("GET /api/config returned HTTP {0}" -f $cur.StatusCode) }

    $config = $cur.Json
    if ($config.config) { $config = $config.config }
    $config.mediamtx.$Field = $Value

    $save = Invoke-VrmApi -Path '/api/config/save' -Method POST -Body $config -TimeoutSec 180
    Assert-VrmOk -Result $save -Label ("save mediamtx.{0} = {1}" -f $Field, $Value)
    return $save
}

function Invoke-NrtStreamCase {
    <#
    .SYNOPSIS
        Runs one streaming case: make sure the stream is up, then demand
        -Seconds of stable flow. Adds all the numbers as evidence.

    .EXAMPLE
        Invoke-NrtStreamCase -Label 're-encode ON'
    #>
    param(
        [string]$Label = '',
        [int]$Seconds = 15
    )

    $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
    Assert-True $up.Ok $up.Reason

    Assert-True (Wait-NrtStreamReady -PathName $streamPath -ApiPort $ports.MediaMtxApi -TimeoutSec 90) `
        ("mediamtx path '{0}' never became ready" -f $streamPath)

    $s = Test-NrtStreamStable -PathName $streamPath -ApiPort $ports.MediaMtxApi -Seconds $Seconds
    if ($Label) { Add-TestEvidence ("case: {0}" -f $Label) }
    Add-TestEvidence ("path '{0}': {1}" -f $streamPath, $s.Reason)
    Add-TestEvidence ("bytes {0} -> {1}, avg {2} kbps, {3} stall(s) over {4} samples" -f `
        $s.FirstBytes, $s.LastBytes, $s.AvgKbps, $s.Stalls, $s.Samples)
    Assert-True $s.Stable $s.Reason
    return $s
}

Invoke-RegressionTest -Name 'A real headset is available for streaming tests' -Test {
    Assert-NrtStreamHeadsetAvailable
    Add-TestEvidence ("headset: {0}  ->  mediamtx path '{1}'" -f $nrtHeadset.Name, $streamPath)
    Add-TestEvidence ("re-encode: {0}   codec: {1}" -f $originalReEncode, $originalCodec)
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'mediamtx API is answering' -Test {
    Assert-NrtStreamHeadsetAvailable
    $r = Invoke-VrmApi -Path '/api/appinfo'
    Assert-True $r.Ok ('GET /api/appinfo returned HTTP ' + $r.StatusCode)

    # Reached directly, not through the app: this is the interface the tests below
    # rely on. Assert that it ANSWERS - an empty path list is the correct response
    # here, because nothing is streaming yet.
    $url = "http://127.0.0.1:{0}/v3/paths/list" -f $ports.MediaMtxApi
    $code = 0
    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $code = [int]$resp.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    $count = @(Get-NrtMediaMtxPaths -ApiPort $ports.MediaMtxApi).Count
    Add-TestEvidence ("{0} -> HTTP {1}, {2} path(s) currently registered" -f $url, $code, $count)
    Assert-Equal 200 $code 'mediamtx /v3/paths/list must answer'
}

# ---------------------------------------------------------------------------
# The core case - runs at every depth
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name "Stream is stable for $stableSeconds seconds" -Test {
    Assert-NrtStreamHeadsetAvailable
    Invoke-NrtStreamCase -Label ("configured settings (re-encode {0}, codec {1})" -f $originalReEncode, $originalCodec) `
                         -Seconds $stableSeconds | Out-Null
}

Invoke-RegressionTest -Name 'Stream carries at least one video track' -Test {
    Assert-NrtStreamHeadsetAvailable

    $p = Get-NrtMediaMtxPath -PathName $streamPath -ApiPort $ports.MediaMtxApi
    Assert-NotNull $p ("mediamtx path '{0}'" -f $streamPath)

    $tracks = @()
    if ($p.tracks) { $tracks = @($p.tracks) }
    Add-TestEvidence ("tracks: {0}" -f (($tracks -join ', ')))
    Assert-True ($tracks.Count -gt 0) 'a published path must expose at least one track'
}

Invoke-RegressionTest -Name 'Viewer endpoints are reachable while streaming' -Test {
    Assert-NrtStreamHeadsetAvailable

    # HLS: mediamtx serves the playlist only once the stream is publishing.
    $hlsUrl = "http://127.0.0.1:{0}/{1}/index.m3u8" -f $ports.Hls, $streamPath
    $hls = 0
    try {
        $resp = Invoke-WebRequest -Uri $hlsUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $hls = [int]$resp.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $hls = [int]$_.Exception.Response.StatusCode }
    }
    Add-TestEvidence ("HLS  {0} -> HTTP {1}" -f $hlsUrl, $hls)
    Assert-Equal 200 $hls 'HLS playlist status'

    # WHEP: a bare GET is not a valid WHEP handshake, so anything other than a
    # connection failure proves the endpoint is listening and routed.
    $whepUrl = "http://127.0.0.1:{0}/{1}/whep" -f $ports.WebRtc, $streamPath
    $whep = 0
    try {
        $resp = Invoke-WebRequest -Uri $whepUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $whep = [int]$resp.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $whep = [int]$_.Exception.Response.StatusCode }
    }
    Add-TestEvidence ("WHEP {0} -> HTTP {1}" -f $whepUrl, $whep)
    Assert-True ($whep -gt 0) 'the WebRTC/WHEP endpoint must answer rather than refuse the connection'

    # RTSP is not HTTP - just prove the port accepts a TCP connection.
    $rtspOpen = Test-SandboxTcpPort -Port $ports.Rtsp
    Add-TestEvidence ("RTSP port {0} open: {1}" -f $ports.Rtsp, $rtspOpen)
    Assert-True $rtspOpen 'the RTSP port must be listening'
}

# ---------------------------------------------------------------------------
# Standard and Full - re-encode matrix and recording
# ---------------------------------------------------------------------------

if ($depth -ne 'Light') {

    Invoke-RegressionTest -Name 'Stream is stable with re-encode toggled' -Test {
        Assert-NrtStreamHeadsetAvailable

        $flipped = -not $originalReEncode
        Add-TestEvidence ("flipping mediamtx.reencode_in_ffmpeg {0} -> {1}" -f $originalReEncode, $flipped)

        $save = Set-NrtMediaMtxSetting -Field 'reencode_in_ffmpeg' -Value $flipped
        if ($save.Json -and $save.Json.restarted) {
            Add-TestEvidence ("app restarted: mediamtx={0} scrcpy=[{1}]" -f `
                $save.Json.restarted.mediamtx, (@($save.Json.restarted.scrcpy) -join ', '))
            if ($save.Json.restarted.pending) {
                Skip-Test 'config save could not take the VQA lock - restart pending, cannot measure'
            }
        }

        Invoke-NrtStreamCase -Label ("re-encode {0}" -f $flipped) -Seconds $stableSeconds | Out-Null
    }

    Invoke-RegressionTest -Name 'Recording produces a growing file while streaming' -Test {
        Assert-NrtStreamHeadsetAvailable

        $paths = Get-SandboxPaths -TargetRoot $target
        $recordFolder = $paths.RecordFolder

        $r = Invoke-VrmApi -Path '/api/recording' -Method POST -Body @{ name = $nrtSafeName; value = $true }
        Assert-True $r.Ok ('POST /api/recording returned HTTP ' + $r.StatusCode)
        if ($r.Json -and $r.Json.PSObject.Properties.Name -contains 'storageLow' -and $r.Json.storageLow) {
            Skip-Test ('recording refused - record drive low on space (free {0} GB)' -f $r.Json.freeGB)
        }

        try {
            # Recording is applied by relaunching scrcpy with the record argument,
            # so the session has to be bounced for the flag to take effect.
            Stop-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset | Out-Null
            $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
            Add-TestEvidence ("restart with recording: {0}" -f $up.Reason)
            Assert-True $up.Ok $up.Reason

            # Slower than the plain case: ffmpeg now opens a second (-c copy)
            # output onto disk before the RTSP side starts publishing.
            $ready = Wait-NrtStreamReady -PathName $streamPath -ApiPort $ports.MediaMtxApi -TimeoutSec 150
            if (-not $ready) {
                $p = Get-NrtMediaMtxPath -PathName $streamPath -ApiPort $ports.MediaMtxApi
                if ($p) { Add-TestEvidence ("path exists but ready={0}, tracks=[{1}]" -f $p.ready, (@($p.tracks) -join ', ')) }
                else    { Add-TestEvidence ("mediamtx has no path '{0}' at all" -f $streamPath) }
                Add-TestEvidence ("mediamtx paths seen: {0}" -f ((Get-NrtMediaMtxPaths -ApiPort $ports.MediaMtxApi | ForEach-Object { $_.name }) -join ', '))
            }
            Assert-True $ready 'stream must come back up with recording enabled'

            $deadline = (Get-Date).AddSeconds(45)
            $recFile  = $null
            while ((Get-Date) -lt $deadline -and -not $recFile) {
                if (Test-Path -LiteralPath $recordFolder) {
                    $recFile = Get-ChildItem -LiteralPath $recordFolder -File -Recurse -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -like ("*{0}*" -f $nrtSafeName) } |
                               Sort-Object LastWriteTime -Descending | Select-Object -First 1
                }
                if (-not $recFile) { Start-Sleep -Milliseconds 1000 }
            }
            Assert-NotNull $recFile ("a recording file for '{0}' under {1}" -f $nrtSafeName, $recordFolder)
            Add-TestEvidence ("recording: {0}" -f $recFile.FullName)

            $size1 = (Get-Item -LiteralPath $recFile.FullName).Length
            Start-Sleep -Seconds 8
            $size2 = (Get-Item -LiteralPath $recFile.FullName).Length
            Add-TestEvidence ("size {0} -> {1} bytes over 8s" -f $size1, $size2)
            Assert-True ($size2 -gt $size1) 'the recording file must grow while the headset is streaming'
        }
        finally {
            Invoke-VrmApi -Path '/api/recording' -Method POST -Body @{ name = $nrtSafeName; value = $false } | Out-Null
        }
    }
}

if ($depth -eq 'Full') {

    Invoke-RegressionTest -Name 'Stream is stable on the alternate codec' -Test {
        Assert-NrtStreamHeadsetAvailable

        $altCodec = 'h265'
        if ($originalCodec -eq 'h265') { $altCodec = 'h264' }
        Add-TestEvidence ("switching mediamtx.codec {0} -> {1}" -f $originalCodec, $altCodec)

        # Re-encoding must be on for the codec setting to have any effect: the
        # passthrough branch always ships the headset's native codec.
        Set-NrtMediaMtxSetting -Field 'reencode_in_ffmpeg' -Value $true | Out-Null
        $save = Set-NrtMediaMtxSetting -Field 'codec' -Value $altCodec
        if ($save.Json -and $save.Json.restarted -and $save.Json.restarted.pending) {
            Skip-Test 'config save could not take the VQA lock - restart pending, cannot measure'
        }

        Invoke-NrtStreamCase -Label ("codec {0}" -f $altCodec) -Seconds $stableSeconds | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Teardown - restore the operator's settings and stop the stream
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Restore mediamtx settings and stop streaming' -Test {
    Assert-NrtStreamHeadsetAvailable

    $errors = @()
    if ($depth -ne 'Light') {
        try { Set-NrtMediaMtxSetting -Field 'reencode_in_ffmpeg' -Value $originalReEncode | Out-Null }
        catch { $errors += ("reencode_in_ffmpeg: " + $_.Exception.Message) }
    }
    if ($depth -eq 'Full') {
        try { Set-NrtMediaMtxSetting -Field 'codec' -Value $originalCodec | Out-Null }
        catch { $errors += ("codec: " + $_.Exception.Message) }
    }

    $stopped = Stop-NrtHeadsetStream -TargetRoot $target -Headset $nrtHeadset
    Add-TestEvidence ("scrcpy stopped: {0}" -f $stopped)
    Add-TestEvidence ("restored re-encode={0} codec={1}" -f $originalReEncode, $originalCodec)

    if ($errors.Count -gt 0) { Write-TestWarning ("restore issues: " + ($errors -join '; ')) }
    Assert-True $stopped 'scrcpy must be stopped at the end of section 60'
}
