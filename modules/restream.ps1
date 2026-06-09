####################################
# MEDIAMTX RESTREAM SERVER        #
####################################

# Translations loaded centrally in scripts_init.ps1 into $global:msg
# Requires: scrcpy_launcher.ps1 (Convert-Displayname)


function ConvertTo-RestreamPathName {
    <#
    .SYNOPSIS
    Converts a headset name to a URL-safe mediamtx path identifier.
    Uses the same normalization as scrcpy window titles (spaces -> underscores), then lowercased.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$HeadsetName
    )
    return (Convert-Displayname -displayName $HeadsetName).ToLower()
}


function Write-MediaMtxYml {
    <#
    .SYNOPSIS
    Writes the base mediamtx YAML configuration file.
    Individual headset paths are added at runtime via the mediamtx REST API.
    #>
    param (
        [string]$YmlPath = $global:mediamtxYmlPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build the log file path inside the global log folder.
    # Use forward slashes: mediamtx (Go) handles them on Windows and they are
    # unambiguous in YAML without needing escaping.
    # The YAML is written as UTF-8 without BOM so non-ASCII chars (e.g. accented
    # letters in the path) are preserved correctly. PS5 Set-Content -Encoding UTF8
    # adds a BOM which breaks YAML parsers, so we use .NET directly.
    $mediamtxLogFile = (Join-Path $global:logFolder "mediamtx.log").Replace('\', '/')

    $yaml = @"
# VR_HEADSET_MANAGER - mediamtx configuration
# Auto-generated: $timestamp - do not edit manually

logLevel: $($global:mediamtxLogLevel)
logDestinations: [stdout, file]
logFile: $mediamtxLogFile

rtsp: true
rtspAddress: :$($global:mediamtxRtspPort)

hls: true
hlsAddress: :$($global:mediamtxHlsPort)

webrtc: true
webrtcAddress: :$($global:mediamtxWebrtcPort)
webrtcICEUDPMuxAddress: :$($global:mediamtxWebrtcPort)

api: true
apiAddress: :$($global:mediamtxApiPort)

paths: {}
"@
    # Write UTF-8 without BOM - required for YAML and to preserve non-ASCII path chars.
    [System.IO.File]::WriteAllText($YmlPath, $yaml, [System.Text.UTF8Encoding]::new($false))
}


function Start-MediaMtx {
    <#
    .SYNOPSIS
    Starts the mediamtx restream server in the background if not already running.

    .DESCRIPTION
    Generates a fresh base YAML config then launches mediamtx.exe as a detached hidden
    background process. Safe to call multiple times - returns immediately if mediamtx
    is already running or if restream is disabled in config (mediamtx.enabled = false).
    #>
    if (-not $global:mediamtxEnabled) {
        Write-Log $msg.MediaMtxNotEnabled -Level DEBUG
        return
    }
    if (-not (Test-Path $global:mediamtxFilePath)) {
        Write-Log ($msg.MediaMtxNotFound -f $global:mediamtxFilePath) -Level ERROR
        return
    }
    $mediamtxPidFile = Join-Path $global:ScriptPath "data\mediamtx.pid"
    $running = Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Log ($msg.MediaMtxAlreadyRunning -f $running.Id) -Level DEBUG
        # Refresh stale PID file (e.g. crash + restart by user)
        $running.Id | Set-Content -LiteralPath $mediamtxPidFile -Force -ErrorAction SilentlyContinue
        return
    }
    Write-Log $msg.MediaMtxStarting -Level INFO
    try {
        Unblock-File -LiteralPath $global:mediamtxFilePath -ErrorAction SilentlyContinue
        Write-MediaMtxYml
        $proc = Start-Process -FilePath $global:mediamtxFilePath `
                              -ArgumentList "`"$($global:mediamtxYmlPath)`"" `
                              -WorkingDirectory $global:mediamtxFolder `
                              -WindowStyle Hidden `
                              -PassThru `
                              -ErrorAction Stop
        Start-Sleep -Milliseconds 1500   # give mediamtx time to bind ports
        $proc.Id | Set-Content -LiteralPath $mediamtxPidFile -Force -ErrorAction SilentlyContinue
        Write-Log ($msg.MediaMtxStarted -f $proc.Id) -Level SUCCESS
    }
    catch {
        Write-Log ($msg.MediaMtxStartFailed -f $_) -Level ERROR
    }
}


function Stop-MediaMtx {
    <#
    .SYNOPSIS
    Stops the mediamtx process if it is running.
    #>
    try {
        $procs = Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction Stop
            Write-Log $msg.MediaMtxStopped -Level INFO
        }
    }
    catch {
        Write-Log ($msg.MediaMtxStopFailed -f $_) -Level ERROR
    }
    finally {
        $mediamtxPidFile = Join-Path $global:ScriptPath "data\mediamtx.pid"
        if (Test-Path -LiteralPath $mediamtxPidFile) {
            Remove-Item -LiteralPath $mediamtxPidFile -Force -ErrorAction SilentlyContinue
        }
    }
}


function Add-RestreamPath {
    <#
    .SYNOPSIS
    Registers a mediamtx path for one headset via the mediamtx REST API.

    .DESCRIPTION
    Uses the mediamtx runOnDemand feature: when a remote viewer connects to the path,
    mediamtx starts ffmpeg to capture the corresponding scrcpy window (matched by its
    window title) using Windows GDI grab, encodes to H.264 and publishes the stream
    back to mediamtx as RTSP. The capture starts on demand and stops when no viewers
    remain.

    .PARAMETER HeadsetName
    Headset name as stored in known_headsets.csv.

    .PARAMETER HeadsetIP
    IP address of the headset (used for logging only).
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$HeadsetName,
        [Parameter(Mandatory=$true)]
        [string]$HeadsetIP
    )

    if (-not (Test-Path $global:ffmpegFilePath)) {
        Write-Log ($msg.MediaMtxFfmpegNotFound -f $global:ffmpegFilePath) -Level WARNING
        return
    }

    $pathName    = ConvertTo-RestreamPathName -HeadsetName $HeadsetName
    $windowTitle = Convert-Displayname -displayName $HeadsetName
    # Wrap ffmpeg path in double-quotes: the sources path contains spaces.
    $ffmpegFwd   = "`"" + $global:ffmpegFilePath.Replace('\', '/') + "`""
    $rtspUrl     = "rtsp://127.0.0.1:$($global:mediamtxRtspPort)/$pathName"

    # ffmpeg captures the scrcpy window by its exact title using Windows GDI grab,
    # encodes to H.264 with low-latency settings, and pushes RTSP to mediamtx.
    # -pix_fmt yuv420p: GDI grab outputs BGR0 which makes libx264 pick yuv444p by default;
    #   mediamtx and most RTSP clients only accept standard yuv420p H.264 - must be explicit.
    # -rtsp_transport tcp: avoids UDP hole-punching issues on loopback.
    # -pkt_size 1316: keeps RTP packets within Ethernet MTU (mediamtx warns at >1440).
    $cmd = "$ffmpegFwd -f gdigrab -framerate $($global:mediamtxFramerate) -draw_mouse 0" +
           " -i title=$windowTitle -vf scale=trunc(iw/2)*2:trunc(ih/2)*2 -pix_fmt yuv420p -c:v libx264 -preset ultrafast" +
           " -tune zerolatency -b:v $($global:mediamtxBitrate)" +
           " -maxrate $($global:mediamtxBitrate) -bufsize $($global:mediamtxBitrate)" +
           " -pkt_size 1316 -rtsp_transport tcp -f rtsp $rtspUrl"

    $body = @{
        runOnDemand             = $cmd
        runOnDemandRestart      = $true
        runOnDemandStartTimeout = "15s"
        runOnDemandCloseAfter   = "30s"
    } | ConvertTo-Json -Compress

    $apiUrl = "http://localhost:$($global:mediamtxApiPort)/v3/config/paths/add/$pathName"
    try {
        # Send as explicit UTF-8 bytes: PowerShell 5 Invoke-RestMethod defaults to
        # Windows-1252 for string bodies, which corrupts non-ASCII chars (e.g. accented
        # letters in the file path). Encoding the body manually guarantees correct UTF-8.
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri $apiUrl -Method Post `
                                  -Body $bodyBytes -ContentType "application/json" `
                                  -ErrorAction Stop
        Write-Log ($msg.MediaMtxPathAdded -f $HeadsetName, $rtspUrl) -Level INFO
    }
    catch {
        Write-Log ($msg.MediaMtxPathSyncFailed -f $HeadsetName, $_) -Level WARNING
    }
}


function Remove-RestreamPath {
    <#
    .SYNOPSIS
    Removes a mediamtx path via the REST API.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$PathName
    )
    $apiUrl = "http://localhost:$($global:mediamtxApiPort)/v3/config/paths/delete/$PathName"
    try {
        $null = Invoke-RestMethod -Uri $apiUrl -Method Delete -ErrorAction Stop
        Write-Log ($msg.MediaMtxPathRemoved -f $PathName) -Level INFO
    }
    catch {
        Write-Log ($msg.MediaMtxPathSyncFailed -f $PathName, $_) -Level WARNING
    }
}


function Sync-RestreamPaths {
    <#
    .SYNOPSIS
    Synchronises mediamtx stream paths with the current known headsets list.

    .DESCRIPTION
    Called from the VRMonitor background job on every monitoring cycle.
    - Ensures mediamtx is running; starts it if not.
    - Queries the mediamtx REST API for currently configured paths.
    - Adds a runOnDemand path for each known headset that does not already have one.
    Stale paths for removed headsets are left in place by default (they fail silently
    when a viewer connects and the scrcpy window no longer exists). Uncomment the
    removal block below to enable automatic cleanup.
    #>
    if (-not $global:mediamtxEnabled) { return }

    # Ensure mediamtx is running
    if (-not (Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue)) {
        Start-MediaMtx
        Start-Sleep -Seconds 2
    }

    # Verify the REST API is responsive before attempting path sync
    $apiBase = "http://localhost:$($global:mediamtxApiPort)"
    try {
        $null = Invoke-RestMethod -Uri "$apiBase/v3/config/global/get" `
                                  -Method Get -ErrorAction Stop -TimeoutSec 3
    }
    catch {
        Write-Log ($msg.MediaMtxApiNotReachable -f $apiBase) -Level WARNING
        return
    }

    # Retrieve currently configured paths
    $currentPaths = @()
    try {
        $resp = Invoke-RestMethod -Uri "$apiBase/v3/config/paths/list" -Method Get -ErrorAction Stop
        $currentPaths = $resp.items | ForEach-Object { $_.name }
    }
    catch { }

    if (-not (Test-Path $global:knownHeadsetsFilePath)) { return }
    $headsets = @(Import-Csv -Path $global:knownHeadsetsFilePath)

    # Add a path for every headset not yet registered in mediamtx
    foreach ($headset in $headsets) {
        $pathName = ConvertTo-RestreamPathName -HeadsetName $headset.Name
        if ($pathName -notin $currentPaths) {
            Add-RestreamPath -HeadsetName $headset.Name -HeadsetIP $headset.IPAddress
        }
    }

    # Remove paths for headsets that no longer exist in the known headsets list.
    $expectedPaths = $headsets | ForEach-Object { ConvertTo-RestreamPathName -HeadsetName $_.Name }
    foreach ($path in $currentPaths) {
        if ($path -notin $expectedPaths) { Remove-RestreamPath -PathName $path }
    }
}


function Get-MediaMtxClientCount {
    <#
    .SYNOPSIS
    GET /v3/paths/list against the mediamtx HTTP API and sum readers across paths.

    .DESCRIPTION
    Returns the total active reader count, or 0 if mediamtx is disabled, the API
    is unreachable, or the response cannot be parsed.
    #>
    if (-not $global:mediamtxEnabled) { return 0 }
    $port = $global:mediamtxApiPort
    if (-not $port) { return 0 }
    $url = "http://localhost:$port/v3/paths/list"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 2 -ErrorAction Stop
    } catch {
        return 0
    }
    $count = 0
    if ($resp -and $resp.items) {
        foreach ($p in $resp.items) {
            if ($p.readers) { $count += @($p.readers).Count }
        }
    }
    return [int]$count
}


function Get-RestreamUrl {
    <#
    .SYNOPSIS
    Returns the URL a remote viewer should use to watch a headset restream.

    .DESCRIPTION
    Use rtsp:// for VLC or OBS. Use hls (http://...m3u8) for browser playback.
    Replace YOUR_PC_IP with the actual IP of this machine on the local network,
    or pass it via the -LocalIP parameter.

    .PARAMETER HeadsetName
    Headset name as stored in known_headsets.csv.

    .PARAMETER Protocol
    Output protocol: rtsp (default), hls, or webrtc.

    .PARAMETER LocalIP
    IP address of this PC on the LAN. Defaults to a placeholder.

    .EXAMPLE
    Get-RestreamUrl -HeadsetName "Quest 3 Manu" -Protocol rtsp -LocalIP "192.168.1.10"
    # -> rtsp://192.168.1.10:8554/quest_3_manu
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$HeadsetName,
        [ValidateSet("rtsp","hls","webrtc")]
        [string]$Protocol = "rtsp",
        [string]$LocalIP = "YOUR_PC_IP"
    )
    $pathName = ConvertTo-RestreamPathName -HeadsetName $HeadsetName
    switch ($Protocol) {
        "rtsp"   { return "rtsp://${LocalIP}:$($global:mediamtxRtspPort)/$pathName" }
        "hls"    { return "http://${LocalIP}:$($global:mediamtxHlsPort)/$pathName/index.m3u8" }
        "webrtc" { return "http://${LocalIP}:$($global:mediamtxWebrtcPort)/$pathName" }
    }
}
