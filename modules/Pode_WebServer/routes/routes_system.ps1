# VR Headset Manager - web routes: system (S9-3).
#
# Route handlers for the application itself: shutdown/restart (app, host, web server), version, app info and logs.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: POST /api/app-shutdown
# Injects '0' + Enter into the main process console input so Show-MainMenu triggers Invoke-AppShutdown.
function Invoke-RouteAppShutdown {
    # POST /api/app-shutdown
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $mainProcs = @(Get-MainProcessList)
        if ($mainProcs.Count -eq 0) { throw 'Main process not found' }
        if ($mainProcs.Count -gt 1) { Write-Log "app-shutdown: multiple main.ps1 processes found ($($mainProcs.Count)), using first" -Level WARNING }
        $mainPid = [uint32]$mainProcs[0].ProcessId
        [void][VrmConsoleInput]::InjectKeys($mainPid, '0', $true)
        Send-JsonResponse -Response $response -Raw '{"ok":true}'
    } catch {
        try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/app-restart
# Injects '00' + Enter into the main process console input so Show-MainMenu
# triggers the '00' case (relaunch main.ps1, then Invoke-AppShutdown on the old instance).
function Invoke-RouteAppRestart {
    # POST /api/app-restart
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $mainProcs = @(Get-MainProcessList)
        if ($mainProcs.Count -eq 0) { throw 'Main process not found' }
        if ($mainProcs.Count -gt 1) { Write-Log "app-restart: multiple main.ps1 processes found ($($mainProcs.Count)), using first" -Level WARNING }
        $mainPid = [uint32]$mainProcs[0].ProcessId
        $injected = [VrmConsoleInput]::InjectKeys($mainPid, '00', $true)
        if (-not $injected) { throw "Could not attach to the console of main.ps1 (PID $mainPid)" }
        Write-Log "app-restart: '00' injected into main.ps1 console (PID $mainPid)" -Level INFO
        Send-JsonResponse -Response $response -Raw '{"ok":true}'
    } catch {
        Write-Log ("app-restart failed: " + $_.Exception.Message) -Level ERROR
        try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/host-shutdown
# Injects '000' + Enter into the main process console input so Show-MainMenu triggers the
# '000' case (schedule shutdown.exe on the host PC, then Invoke-AppShutdown), followed by
# 'YES' + Enter for that case's own confirmation prompt. The browser-side modal already
# collected an explicit, dedicated confirmation before calling this endpoint, so the console
# prompt here is only a safety net for someone at the physical keyboard - not a second gate
# for the web operator.
function Invoke-RouteHostShutdown {
    # POST /api/host-shutdown
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $mainProcs = @(Get-MainProcessList)
        if ($mainProcs.Count -eq 0) { throw 'Main process not found' }
        if ($mainProcs.Count -gt 1) { Write-Log "host-shutdown: multiple main.ps1 processes found ($($mainProcs.Count)), using first" -Level WARNING }
        $mainPid = [uint32]$mainProcs[0].ProcessId
        [void][VrmConsoleInput]::InjectKeys($mainPid, '000', $true)
        [void][VrmConsoleInput]::InjectKeys($mainPid, 'YES', $true)
        Write-Log "host-shutdown: requested via web API" -Level WARNING
        Send-JsonResponse -Response $response -Raw '{"ok":true}'
    } catch {
        try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/restartwebserver
# Sends a success response then kills this server process after a short delay.
# Does NOT relaunch itself: Start-VRMonitor's watchdog already calls Start-WebServer
# on every slow-path tick (modules/headsets_monitoring.ps1) and detects/relaunches a
# dead server through its own single, already-guarded code path (the same mechanism
# that makes the server come back after a main-menu reload). Having this endpoint also
# relaunch directly used to race that watchdog: both sides could see the pid file as
# dead at the same time and each spawn a competing process, and the loser's
# HttpListener.Start() would fail while deleting the pid file behind the winner,
# causing the watchdog to spawn yet another competitor in a loop that never settled.
# Killing only, and letting the watchdog be the sole relauncher, removes that race.
function Invoke-RouteRestartwebserver {
    # POST /api/restartwebserver
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
        Close-HttpResponse -Response $response

        # The killer also releases data\webserver.pid once the process is gone:
        # Stop-Process -Force skips our finally block, so nobody else would.
        # A stale lock is no longer fatal (Start-WebServer identity-checks it),
        # but clearing it lets the watchdog relaunch on its very next tick
        # without logging a stale-PID warning.
        $killCmd = "Start-Sleep -Milliseconds 800; " +
                   "Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue"
        if ($PidFile) {
            $killCmd += "; Start-Sleep -Milliseconds 200; " +
                        "if (-not (Get-Process -Id $PID -ErrorAction SilentlyContinue)) { " +
                        "Remove-Item -LiteralPath '$PidFile' -Force -ErrorAction SilentlyContinue }"
        }
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-Command', $killCmd
        ) -WindowStyle Hidden
        return
    } catch {
        try { $response.Close() } catch {}
    }
    return
}

# API: GET /api/logs/sources - every log file in the log folder, classified by
# family (main program / mediamtx / web server / scrcpy / ffmpeg push / kiosk).
# Feeds the log-type and log-file dropdowns on help.html. Sorted by family, then
# newest first, so the first entry of a type is the one to select by default.
function Invoke-RouteLogsSources {
    # GET /api/logs/sources
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $sourceRows = @(Get-LogSources | ForEach-Object {
            @{
                id        = $_.Id
                type      = $_.Type
                typeLabel = $_.TypeLabel
                label     = $_.Label
                size      = $_.SizeBytes
                lastWrite = $_.LastWrite
            }
        })
        Send-JsonResponse -Response $response -Body @{ ok = $true; sources = $sourceRows }
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'server error' } -StatusCode 500
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/logs?file=<name>&n=200
# Returns the last N lines of one log file as a bare JSON array (the shape
# help.html and the non-regression suite already expect).
# 'file' is a source id from /api/logs/sources; without it the newest main
# program log is served, which is the original file-less behaviour.
# Get-LogTail reads from the END of the file - the log folder holds files of
# hundreds of MB and this request loop is single-threaded.
function Invoke-RouteLogs {
    # GET /api/logs
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $logQuery = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
        $qn       = $logQuery['n']
        $maxLines = if ($qn -and $qn -match '^\d+$') { [int]$qn } else { 200 }
        if ($maxLines -gt 2000) { $maxLines = 2000 }

        $logSources = @(Get-LogSources)
        $logSource  = $null
        $qFile      = $logQuery['file']
        if ($qFile) {
            # Only ids the enumerator itself produced are accepted, so an
            # arbitrary path can never reach Get-LogTail.
            $logSource = $logSources | Where-Object { $_.Id -eq $qFile } | Select-Object -First 1
        }
        if (-not $logSource) {
            $logSource = $logSources | Where-Object { $_.Type -eq 'main' } | Select-Object -First 1
        }

        # NOT '$lines = if (...) { @(...) }': an if-block unrolls its output, so a
        # single-line result would arrive as a bare string and $lines[0] would be
        # its first character. Assign the wrapped call directly.
        $lines = @()
        if ($logSource) {
            $lines = @(Get-LogTail -Name $logSource.Id -MaxLines $maxLines -Encoding $logSource.Encoding)
        }

        # ConvertTo-Json emits a bare string for a one-element array, and
        # help.html requires Array.isArray - so wrap that case by hand.
        $rawJson = if ($lines.Count -eq 0) { '[]' }
                   elseif ($lines.Count -eq 1) { '[' + (ConvertTo-Json -InputObject $lines[0] -Compress) + ']' }
                   else { ConvertTo-Json -InputObject $lines -Compress }
        Send-JsonResponse -Response $response -Raw $rawJson
    } catch {
        Send-JsonResponse -Response $response -Raw '[]' -StatusCode 500
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/version  - returns the application version string from version.txt
function Invoke-RouteVersion {
    # GET /api/version
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $versionFile = Join-Path $global:ScriptPath 'version.txt'
        $versionStr  = if (Test-Path -LiteralPath $versionFile) {
            (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
        } else { 'unknown' }
        Send-JsonResponse -Response $response -Body @{ app = 'VRHM'; version = $versionStr }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ app = 'VRHM'; version = 'unknown' } } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/appinfo  - returns port info and useful URLs for the topbar Help section
function Invoke-RouteAppinfo {
    # GET /api/appinfo
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Cache for 10s - Get-Process is slow under high CPU load and this
        # endpoint is polled by the topbar from every open page.
        if (-not $script:appInfoCache -or
            ((Get-Date) - $script:appInfoCacheAt).TotalSeconds -gt 10) {
            $script:appInfoCache = @{
                webServerPort      = $port
                mediamtxHlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort }    else { 8888 }
                mediamtxRtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort }   else { 8554 }
                mediamtxWebrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
                mediamtxApiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort }    else { 9997 }
                webServerPid       = $PID
                mediamtxPid        = (Get-MediaMtxProcess | Select-Object -First 1 -ExpandProperty Id)
            }
            $script:appInfoCacheAt = Get-Date
        }
        $info      = $script:appInfoCache
        $jsonOut   = ConvertTo-Json $info -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}
