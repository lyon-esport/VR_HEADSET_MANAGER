# VR Headset Manager - web route surface (ADR-0019).
#
# The whole HTTP route surface lives here so the SAME code can run either inline on the accept
# loop (web_server.ps1) or in the slow-lane worker runspace. Dot-sourced by both; it holds
# functions only - nothing here runs at dot-source time except the lane and route tables,
# which are plain data.
#
# Layout (S9-3): Invoke-HttpRoute is a dispatcher, not a condition chain. Each route is its own
# function Invoke-Route<Name> -Context, found through $script:RouteTable ("<METHOD> <path>" ->
# function name, exact match, checked first), then $script:RoutePrefixes (ordered prefix and
# regex routes), then Invoke-RouteStaticFile. A new route = a new Invoke-Route* function + one
# table line, plus a lane decision in $script:SlowRoutes / $script:PriorityRoutes.
#
# Why a dot-sourced FILE and not a table of scriptblock handlers: a scriptblock carries the
# SessionState it was created in, so passing one across a runspace boundary in PS 5.1 either
# throws or silently binds to the wrong scope. Only the HttpListenerContext (a plain .NET
# object) crosses the boundary; the code is dot-sourced into each runspace independently.
#
# Rules for everything below (see docs\adr\0019-tiered-request-lanes.md and ADR-0033):
#   - A route function leaves with `return`, never `continue`: there is no loop around it,
#     and a stray `continue` would unwind into the CALLER's loop and leave the response
#     unclosed.
#   - Anything a slow route reads must exist in the worker too. The accept loop owns every
#     piece of state that is bound to its own runspace: Start-Job handles ($script:installJobs,
#     resolveJob, updateVersionsJob, benchmarkJob - Receive-Job/Remove-Job only work in the
#     runspace that started the job), the recording download list and the SSE queue. Routes
#     that touch them are therefore FAST, whatever they cost.
#   - $global: state is per runspace too ($global:HeadsetPipelines, $global:DirectRecordings):
#     a route that starts or stops a capture stays on the accept loop.

# --- helpers shared by both lanes (moved verbatim from web_server.ps1) ---------------------
# Helper: send a JSON response with proper status code, content-type and length.
# Replaces dozens of hand-built '{"ok":true,...}' string concatenations.
# - $Response is the [System.Net.HttpListenerResponse].
# - $Body can be a hashtable, PSCustomObject, array, or any ConvertTo-Json target.
#   Use $Raw if you have a pre-built JSON string.
function Send-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]
        $Response,
        $Body = $null,
        [int]$StatusCode = 200,
        [string]$Raw = $null,
        [int]$Depth = 6
    )
    try {
        $json = if ($Raw) { $Raw } else { ConvertTo-Json -InputObject $Body -Compress -Depth $Depth }
        if ($null -eq $json) { $json = 'null' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        $Response.StatusCode      = $StatusCode
        $Response.ContentType     = 'application/json; charset=utf-8'
        $Response.Headers.Add('Access-Control-Allow-Origin', '*')
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        # last-resort: try to set 500 if headers not yet sent
        try { $Response.StatusCode = 500 } catch {}
    }
}

# Helper: close a response without letting the close throw (S1-1).
# HttpListenerResponse.Close() raises HttpListenerException when the client has
# already gone (tab closed, OBS source reloaded mid-transfer). Inside the accept
# loop that exception used to unwind out of the while loop and stop the listener.
function Close-HttpResponse {
    param([Parameter(Mandatory = $true)] $Response)
    try { $Response.Close() } catch {}
}

# Helper: $true when an exception (or any exception it wraps) is a client abort -
# HttpListenerException 64 (network name no longer available), 995 (operation
# aborted) or 1229 (connection reset/closed). PowerShell wraps .NET method errors
# in MethodInvocationException, hence the walk down InnerException.
function Test-HttpClientAbort {
    param($Exception)
    $e = $Exception
    while ($e) {
        if ($e -is [System.Net.HttpListenerException] -and @(64, 995, 1229) -contains $e.ErrorCode) { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Helper: read a request body as UTF-8 text with a hard size cap (S6-2). A cap is robustness,
# not auth (ADR-0014): an unbounded ReadToEnd() on the accept loop let one oversized or
# endless POST pin the loop and the memory. ContentLength64 is checked first; a chunked
# body (length -1) is counted while it is read, in 8 KB blocks. When the cap is exceeded
# and -Response is given, the 413 {"ok":false,"error":"body too large"} answer is sent and
# the response closed here, then an InvalidDataException('BODY_TOO_LARGE') is thrown so the
# route stops (its own catch finds the response already closed and stays silent).
# Example: $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
function Read-RequestBody {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [int]$MaxBytes = 65536,
        $Response = $null
    )
    $reject = {
        if ($Response) {
            Send-JsonResponse -Response $Response -StatusCode 413 -Body @{ ok = $false; error = 'body too large' }
            Close-HttpResponse -Response $Response
        }
        throw [System.IO.InvalidDataException]::new('BODY_TOO_LARGE')
    }
    if ($Request.ContentLength64 -gt $MaxBytes) { & $reject }
    $ms = [System.IO.MemoryStream]::new()
    try {
        $buf = [byte[]]::new(8192)
        $in  = $Request.InputStream
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            if (($ms.Length + $n) -gt $MaxBytes) { & $reject }
            $ms.Write($buf, 0, $n)
        }
        $bytes = $ms.ToArray()
    } finally { $ms.Dispose() }
    $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $skip = 3 }
    return [System.Text.Encoding]::UTF8.GetString($bytes, $skip, $bytes.Length - $skip)
}

function Get-KnownHeadsetsCached {
    # Cached @(Get-KnownHeadsets). Kept as an ORDERED ARRAY (not a hashtable) so the
    # registry's own row order - the drag-and-drop display order set by Set-HeadsetsOrder -
    # is preserved. ID is a stable identity, not a position, so it must not re-derive that
    # order. Cached because the status endpoints resolve every request through the registry
    # now that live status carries no identity columns (ADR-0016), and each headset overlay
    # polls continuously.
    #
    # Keyed on the headsets change counter, NOT on a file mtime. This used to stat
    # data\known_headsets.csv, and after the registry moved into the database
    # (ADR-0017) that was wrong twice over: the mtime never changed again because
    # nothing writes the file, so the cache could never refresh - and once the file
    # stopped being created at all, the existence guard returned an empty list on
    # every call, so the web UI showed no headsets whatsoever.
    try {
        $version = Get-DbTableVersion -Name 'headsets'
    }
    catch {
        return @()
    }

    if (-not $script:knownHeadsetsCache -or $script:knownHeadsetsCacheMtime -ne $version) {
        $script:knownHeadsetsCache      = @(Get-KnownHeadsets)
        $script:knownHeadsetsCacheMtime = $version
    }
    return $script:knownHeadsetsCache
}

function Get-HeadsetInfosCache {
    # Returns a hashtable of live-status rows keyed by headset ID as a string
    # ($null when the status table cannot be read).
    #
    # Keyed on ID, never on Name (ADR-0016): status rows carry no identity columns, and a
    # display name is a mutable label - joining on it made a rename or a DHCP address swap
    # attach one headset's live status to another row until the next write cycle.
    #
    # The cache key is the table's change counter instead of a file mtime. Same purpose:
    # every headset monitoring overlay polls at 1Hz, and the request loop is
    # single-threaded, so without this it would spend most of its time re-reading rows
    # that did not change. Get-DbTableVersion is one indexed scalar read, and the counter
    # only moves when a trigger fires on an actual write.
    try {
        $version = Get-DbTableVersion -Name 'headset_status'
    }
    catch {
        return $null
    }

    if (-not $script:headsetInfosCache -or $script:headsetInfosCacheMtime -ne $version) {
        try {
            $rows = @(Invoke-DbQuery -Name 'status.list')
        }
        catch {
            return $null
        }
        $cache = @{}
        foreach ($r in $rows) {
            $key = [string]$r.ID
            if (-not [string]::IsNullOrWhiteSpace($key)) { $cache[$key] = $r }
        }
        $script:headsetInfosCache      = $cache
        $script:headsetInfosCacheMtime = $version
    }
    return $script:headsetInfosCache
}

function Get-PublishedUsbSnapshot {
    # Returns the last USB snapshot VRMonitor published, or $null when nothing is
    # cabled / nothing has been published yet. Never throws: a USB read must not
    # be able to take down a request handler.
    try {
        $raw = Get-DbKeyValue -Key 'usb_device'
        if (-not $raw) { return $null }
        if ($raw -is [string]) {
            if ($raw -eq 'null' -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
            return ($raw | ConvertFrom-Json)
        }
        return $raw
    } catch {
        return $null
    }
}


# --- lane tables ---------------------------------------------------------------------------
# 'slow'     : handed to the single worker runspace. Everything here touches ADB, the LAN, the
#              internet, a child process or a human, and none of it keeps loop-bound state.
# 'priority' : an operator "stop / kill / shutdown" command. NEVER queued behind slow work: it
#              runs inline on the accept loop, and its handler must stay short (no waits on a
#              human, no unbounded adb call).
# anything else is 'fast' (inline). The default is deliberately fast, so a route added without
# thinking about it keeps the pre-lane behaviour instead of queueing behind a download.
$script:SlowRoutes = @{
    '/api/browse-folder'                 = $true   # FolderBrowserDialog: waits for a human
    '/api/ffmpeg-update'                 = $true   # GitHub download + unzip
    '/api/mediamtx-update'               = $true
    '/api/scrcpy-update'                 = $true
    '/api/ffmpeg-check-update'           = $true   # GitHub API
    '/api/mediamtx-check-update'         = $true
    '/api/scrcpy-check-update'           = $true
    '/api/gpu-list'                      = $true   # WMI + perf counters
    '/api/wifi-detect'                   = $true   # netsh
    '/api/kiosks/scan'                   = $true   # subnet sweep
    '/api/kiosks/push'                   = $true   # CDP over HTTP
    '/api/kiosks/kill-browser'           = $true
    '/api/kiosks/cdp-info'               = $true
    '/api/kiosks/power'                  = $true
    '/api/companion-info'                = $true   # HTTP to the headset
    '/api/companion-settings'            = $true
    '/api/headset-screen-frame'          = $true   # scrcpy capture, 3-5 s
    '/api/eye-merge/frame'               = $true
    '/api/eye-merge/calibrate'           = $true
    '/api/headset-diag'                  = $true   # adb sections, up to 7 s
    '/api/headset-diag/action'           = $true
    '/api/headset-diag/command'          = $true   # up to 20 s
    '/api/headset-ipd'                   = $true   # may capture a frame
    '/api/headset-settings'              = $true   # GET: adb reads, up to ~45 s when adb hangs
    '/api/headset-settings/apply'        = $true
    '/api/headset-firmware'              = $true
    '/api/headset-storage'               = $true
    '/api/foregroundapp'                 = $true
    '/api/launchapp'                     = $true
    '/api/uninstallapp'                  = $true
    '/api/update-app'                    = $true
    '/api/installedapps'                 = $true   # ?refresh=1 pulls the package list over adb
    '/api/refresh-headset-apps-cache'    = $true
    '/api/reboot'                        = $true
    '/api/connectwifi'                   = $true
    '/api/enablewifiadb'                 = $true   # adb tcpip re-enumerates USB, ~10 s
    '/api/installadbwifiapk'             = $true
    '/api/headsets/push-wifi'            = $true
}

$script:PriorityRoutes = @{
    '/api/shutdown-all'    = $true   # power off the headsets (parallel adb, bounded)
    '/api/shutdown'        = $true   # power off one headset
    '/api/app-shutdown'    = $true   # -> Invoke-AppShutdown in the main process
    '/api/app-restart'     = $true
    '/api/host-shutdown'   = $true
    '/api/restartwebserver' = $true
    '/api/stop-scrcpy'     = $true   # the kill button
    '/api/stop-scrcpy-all' = $true
}

# Paths after which config\config.json may have changed and Get-Config re-ran in the runspace
# that served them. The OTHER runspace's $global: values are then stale (adb path after a
# scrcpy update, streaming settings after a save): see Set-WebRouteConfigWritten.
$script:ConfigWriterPattern = '^/api/(config/|[a-z]+-update$|[a-z]+-switch-version$|vqa/|eye-merge/|capture-mode$|benchmark/apply$|appnames/clear$)'

function Get-MainProcessList {
    # The main.ps1 console process(es): the one whose menu loop owns Invoke-AppShutdown, and
    # the target of the keystroke injection behind /api/app-shutdown, /api/app-restart,
    # /api/host-shutdown and shutdown-all's "also stop the app".
    #
    # It used to be a full Win32_Process table scan on EVERY such request (1-3 s of the accept
    # loop, right when the operator asked to stop the app). The match is now done by WMI
    # (a LIKE filter), and the answer is cached for the life of this runspace and re-validated
    # by process id + start time, so the second call costs a Get-Process.
    # Returns objects with a ProcessId property, oldest first. Never throws.
    try {
        if ($script:MainProcCache) {
            $alive = $true
            $p = Get-Process -Id $script:MainProcCache.ProcessId -ErrorAction SilentlyContinue
            if (-not $p) { $alive = $false }
            else { try { if ($p.StartTime -ne $script:MainProcCache.StartTime) { $alive = $false } } catch { $alive = $false } }
            if ($alive) { return $script:MainProcCache }
            $script:MainProcCache = $null
        }
        $found = @(Get-WmiObject Win32_Process -Filter "CommandLine LIKE '%main.ps1%'" -ErrorAction Stop |
                   Where-Object { $_.CommandLine -match 'main\.ps1' -and [int]$_.ProcessId -ne $PID } |
                   Sort-Object { $_.CreationDate })
        if ($found.Count -gt 0) {
            $st = $null
            try { $st = (Get-Process -Id $found[0].ProcessId -ErrorAction Stop).StartTime } catch { }
            if ($st) { $script:MainProcCache = [PSCustomObject]@{ ProcessId = [int]$found[0].ProcessId; StartTime = $st } }
        }
        return $found
    } catch {
        return @()
    }
}

function Get-WebRouteLane {
    # 'fast' | 'slow' | 'priority' for one request. Method is not part of the key - no path in
    # the tables is fast under one verb and slow under another. A CORS preflight is always fast.
    param(
        [string]$Method,
        [string]$Path
    )
    if ($Method -eq 'OPTIONS') { return 'fast' }
    if ($script:PriorityRoutes.ContainsKey($Path)) { return 'priority' }
    if ($script:SlowRoutes.ContainsKey($Path)) { return 'slow' }
    return 'fast'
}

function Sync-WebRouteConfig {
    # Called by a lane BEFORE it runs a request. Re-runs Get-Config when the OTHER lane changed
    # the config since this one last looked. -State is the synchronized hashtable both lanes
    # share (keys ConfigGeneration, ConfigWriter); -Lane is 'loop' or 'worker'.
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [string]$Lane
    )
    try {
        $gen = [int]$State['ConfigGeneration']
        if ($gen -eq [int]$script:WebRouteConfigSeen) { return }
        $script:WebRouteConfigSeen = $gen
        if ([string]$State['ConfigWriter'] -eq $Lane) { return }
        Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null
    } catch { }
}

function Set-WebRouteConfigWritten {
    # Called by a lane AFTER a request: when the path can write config, bump the shared
    # generation and record who did, so the other lane refreshes and this one does not.
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [string]$Lane,
        [string]$Path
    )
    try {
        if ($Path -and $Path -match $script:ConfigWriterPattern) {
            $State['ConfigWriter']     = $Lane
            $State['ConfigGeneration'] = [int]$State['ConfigGeneration'] + 1
            $script:WebRouteConfigSeen = [int]$State['ConfigGeneration']
        }
    } catch { }
}

function Invoke-HttpRouteGuarded {
    # Per-request guard (S1-1) for BOTH lanes: one failed request must never stop the listener
    # or the worker. A client abort (64/995/1229) is routine and logged at DEBUG.
    param([Parameter(Mandatory = $true)] $Context)
    try {
        Invoke-HttpRoute -Context $Context
    } catch {
        $reqMethod = '?'
        $reqPath   = '?'
        try { $reqMethod = $Context.Request.HttpMethod; $reqPath = $Context.Request.Url.LocalPath } catch { }
        $reqLine = "Web server: request failed ($reqMethod $reqPath): " + $_.Exception.Message
        if ($_.Exception -is [System.IO.InvalidDataException] -and $_.Exception.Message -eq 'BODY_TOO_LARGE') {
            # Read-RequestBody already answered 413 and closed the response.
            Write-Log $reqLine -Level DEBUG
            return
        }
        if (Test-HttpClientAbort -Exception $_.Exception) {
            Write-Log $reqLine -Level DEBUG
        } else {
            Write-Log $reqLine -Level WARNING
        }
        # Abort, not Close: the response state is unknown at this point.
        try { $Context.Response.Abort() } catch { }
    }
}

# --- route table (S9-3) ------------------------------------------------------------------
# Exact routes, one row per (method, path, handler), folded into "<METHOD> <path>" -> handler
# function and checked first. The @{} literal is case-insensitive, as the -eq comparisons of
# the former if-chain were. Keep the path a quoted literal: the S0-3 route census searches
# the router source for it. A route answering several verbs or paths has one row per pair.
# Lanes are NOT decided here: web_server.ps1 picks the lane from the path
# ($script:SlowRoutes / $script:PriorityRoutes) before dispatch.
$script:RouteTable = @{}
foreach ($routeRow in @(
    ,@('POST',  '/api/renameheadset',                     'Invoke-RouteRenameheadset')
    ,@('POST',  '/api/reorderheadsets',                   'Invoke-RouteReorderheadsets')
    ,@('POST',  '/api/updateip',                          'Invoke-RouteUpdateip')
    ,@('POST',  '/api/recording',                         'Invoke-RouteRecording')
    ,@('GET',   '/api/recording-drive',                   'Invoke-RouteRecordingDrive')
    ,@('GET',   '/api/load-tier',                         'Invoke-RouteLoadTier')
    ,@('GET',   '/api/capture-mode',                      'Invoke-RouteCaptureModeGet')
    ,@('POST',  '/api/capture-mode',                      'Invoke-RouteCaptureModePost')
    ,@('POST',  '/api/removeheadset',                     'Invoke-RouteRemoveheadset')
    ,@('POST',  '/api/reboot',                            'Invoke-RouteReboot')
    ,@('POST',  '/api/shutdown',                          'Invoke-RouteShutdown')
    ,@('POST',  '/api/shutdown-all',                      'Invoke-RouteShutdownAll')
    ,@('GET',   '/api/headset-status',                    'Invoke-RouteHeadsetStatus')
    ,@('GET',   '/api/headset-settings',                  'Invoke-RouteHeadsetSettings')
    ,@('GET',   '/api/headset-firmware',                  'Invoke-RouteHeadsetFirmware')
    ,@('GET',   '/api/headset-diag',                      'Invoke-RouteHeadsetDiag')
    ,@('POST',  '/api/headset-screen-frame',              'Invoke-RouteHeadsetScreenFrame')
    ,@('GET',   '/api/eye-merge',                         'Invoke-RouteEyeMerge')
    ,@('GET',   '/api/stream-mask',                       'Invoke-RouteStreamMask')
    ,@('POST',  '/api/eye-merge/frame',                   'Invoke-RouteEyeMergeFrameOrCalibrate')
    ,@('POST',  '/api/eye-merge/calibrate',               'Invoke-RouteEyeMergeFrameOrCalibrate')
    ,@('POST',  '/api/eye-merge/import',                  'Invoke-RouteEyeMergeImportOrEnable')
    ,@('POST',  '/api/eye-merge/enable',                  'Invoke-RouteEyeMergeImportOrEnable')
    ,@('GET',   '/api/headset-ipd',                       'Invoke-RouteHeadsetIpd')
    ,@('POST',  '/api/headset-ipd',                       'Invoke-RouteHeadsetIpd')
    ,@('POST',  '/api/headset-diag/action',               'Invoke-RouteHeadsetDiagAction')
    ,@('POST',  '/api/headset-diag/command',              'Invoke-RouteHeadsetDiagCommand')
    ,@('GET',   '/api/headset-diag/presets',              'Invoke-RouteHeadsetDiagPresets')
    ,@('GET',   '/api/companion-info',                    'Invoke-RouteCompanionInfo')
    ,@('POST',  '/api/companion-settings',                'Invoke-RouteCompanionSettings')
    ,@('GET',   '/api/kiosks',                            'Invoke-RouteKiosks')
    ,@('POST',  '/api/kiosks/add-manual',                 'Invoke-RouteKiosksAddManual')
    ,@('POST',  '/api/kiosks/scan',                       'Invoke-RouteKiosksScan')
    ,@('GET',   '/api/kiosks/networks',                   'Invoke-RouteKiosksNetworks')
    ,@('POST',  '/api/kiosks/update',                     'Invoke-RouteKiosksUpdate')
    ,@('POST',  '/api/kiosks/remove',                     'Invoke-RouteKiosksRemove')
    ,@('POST',  '/api/kiosks/push',                       'Invoke-RouteKiosksPush')
    ,@('POST',  '/api/kiosks/kill-browser',               'Invoke-RouteKiosksKillBrowser')
    ,@('GET',   '/api/kiosks/cdp-info',                   'Invoke-RouteKiosksCdpInfo')
    ,@('POST',  '/api/kiosks/agent-report',               'Invoke-RouteKiosksAgentReport')
    ,@('POST',  '/api/kiosks/power',                      'Invoke-RouteKiosksPower')
    ,@('GET',   '/api/headset-storage',                   'Invoke-RouteHeadsetStorage')
    ,@('POST',  '/api/headset-settings/apply',            'Invoke-RouteHeadsetSettingsApply')
    ,@('POST',  '/api/updateprofile',                     'Invoke-RouteUpdateprofile')
    ,@('GET',   '/api/scrcpyviews',                       'Invoke-RouteScrcpyviews')
    ,@('POST',  '/api/autorestart',                       'Invoke-RouteAutorestart')
    ,@('POST',  '/api/stop-scrcpy',                       'Invoke-RouteStopScrcpy')
    ,@('POST',  '/api/start-scrcpy-all',                  'Invoke-RouteStartScrcpyAll')
    ,@('POST',  '/api/stop-scrcpy-all',                   'Invoke-RouteStopScrcpyAll')
    ,@('GET',   '/api/headsets',                          'Invoke-RouteHeadsets')
    ,@('GET',   '/api/headsets-status',                   'Invoke-RouteHeadsetsStatus')
    ,@('GET',   '/api/battery-history',                   'Invoke-RouteBatteryHistory')
    ,@('GET',   '/api/metric-history',                    'Invoke-RouteMetricHistory')
    ,@('GET',   '/api/favoriteapps',                      'Invoke-RouteFavoriteapps')
    ,@('GET',   '/api/installedapps',                     'Invoke-RouteInstalledapps')
    ,@('POST',  '/api/uninstallapp',                      'Invoke-RouteUninstallapp')
    ,@('POST',  '/api/update-app',                        'Invoke-RouteUpdateApp')
    ,@('POST',  '/api/headset-connection-check',          'Invoke-RouteHeadsetConnectionCheck')
    ,@('GET',   '/api/install-progress',                  'Invoke-RouteInstallProgress')
    ,@('POST',  '/api/install-cancel',                    'Invoke-RouteInstallCancel')
    ,@('POST',  '/api/resolve-app-names',                 'Invoke-RouteResolveAppNames')
    ,@('GET',   '/api/resolve-progress',                  'Invoke-RouteResolveProgress')
    ,@('GET',   '/api/benchmark/options',                 'Invoke-RouteBenchmarkOptions')
    ,@('POST',  '/api/benchmark/plan',                    'Invoke-RouteBenchmarkPlan')
    ,@('POST',  '/api/benchmark/start',                   'Invoke-RouteBenchmarkStart')
    ,@('POST',  '/api/benchmark/parallel',                'Invoke-RouteBenchmarkParallel')
    ,@('GET',   '/api/benchmark/parallel/result',         'Invoke-RouteBenchmarkParallelResult')
    ,@('GET',   '/api/benchmark/progress',                'Invoke-RouteBenchmarkProgress')
    ,@('POST',  '/api/benchmark/cancel',                  'Invoke-RouteBenchmarkCancel')
    ,@('GET',   '/api/benchmark/result',                  'Invoke-RouteBenchmarkResult')
    ,@('GET',   '/api/benchmark/result.csv',              'Invoke-RouteBenchmarkResultCsv')
    ,@('POST',  '/api/benchmark/clear',                   'Invoke-RouteBenchmarkClear')
    ,@('POST',  '/api/benchmark/recommend',               'Invoke-RouteBenchmarkRecommend')
    ,@('POST',  '/api/benchmark/apply',                   'Invoke-RouteBenchmarkApply')
    ,@('POST',  '/api/update-app-versions',               'Invoke-RouteUpdateAppVersions')
    ,@('GET',   '/api/update-app-versions-progress',      'Invoke-RouteUpdateAppVersionsProgress')
    ,@('POST',  '/api/refresh-headset-apps-cache',        'Invoke-RouteRefreshHeadsetAppsCache')
    ,@('POST',  '/api/installapk',                        'Invoke-RouteInstallapk')
    ,@('GET',   '/api/foregroundapp',                     'Invoke-RouteForegroundapp')
    ,@('POST',  '/api/launchapp',                         'Invoke-RouteLaunchapp')
    ,@('POST',  '/api/togglefavorite',                    'Invoke-RouteTogglefavorite')
    ,@('GET',   '/api/detectusbheadset',                  'Invoke-RouteDetectusbheadset')
    ,@('POST',  '/api/enablewifiadb',                     'Invoke-RouteEnablewifiadb')
    ,@('POST',  '/api/installadbwifiapk',                 'Invoke-RouteInstalladbwifiapk')
    ,@('POST',  '/api/connectwifi',                       'Invoke-RouteConnectwifi')
    ,@('GET',   '/api/wifi-detect',                       'Invoke-RouteWifiDetect')
    ,@('GET',   '/api/wifi-networks',                     'Invoke-RouteWifiNetworks')
    ,@('POST',  '/api/wifi-networks/upsert',              'Invoke-RouteWifiNetworksUpsert')
    ,@('POST',  '/api/wifi-networks/delete',              'Invoke-RouteWifiNetworksDelete')
    ,@('POST',  '/api/wifi-networks/set-preferred',       'Invoke-RouteWifiNetworksSetPreferred')
    ,@('GET',   '/api/usbdeviceinfo',                     'Invoke-RouteUsbdeviceinfo')
    ,@('POST',  '/api/addheadset',                        'Invoke-RouteAddheadset')
    ,@('POST',  '/api/headsets/register-by-serial',       'Invoke-RouteHeadsetsRegisterBySerial')
    ,@('POST',  '/api/headsets/push-wifi',                'Invoke-RouteHeadsetsPushWifi')
    ,@('GET',   '/api/adb-tools',                         'Invoke-RouteAdbTools')
    ,@('GET',   '/api/adb-wifi-apk/info',                 'Invoke-RouteAdbWifiApkInfo')
    ,@('GET',   '/api/adb-wifi-apk',                      'Invoke-RouteAdbWifiApk')
    ,@('GET',   '/api/headsets/discovered',               'Invoke-RouteHeadsetsDiscovered')
    ,@('POST',  '/api/headsets/discovered/forget',        'Invoke-RouteHeadsetsDiscoveredForget')
    ,@('POST',  '/api/restartmediamtx',                   'Invoke-RouteRestartmediamtx')
    ,@('POST',  '/api/app-shutdown',                      'Invoke-RouteAppShutdown')
    ,@('POST',  '/api/app-restart',                       'Invoke-RouteAppRestart')
    ,@('POST',  '/api/host-shutdown',                     'Invoke-RouteHostShutdown')
    ,@('POST',  '/api/restartwebserver',                  'Invoke-RouteRestartwebserver')
    ,@('GET',   '/api/vqa/status',                        'Invoke-RouteVqaStatus')
    ,@('POST',  '/api/vqa/apply',                         'Invoke-RouteVqaApply')
    ,@('POST',  '/api/vqa/restore',                       'Invoke-RouteVqaRestore')
    ,@('POST',  '/api/vqa/toggle-auto-apply',             'Invoke-RouteVqaToggleAutoApply')
    ,@('POST',  '/api/vqa/toggle-vqo',                    'Invoke-RouteVqaToggleVqo')
    ,@('GET',   '/api/computer-monitoring',               'Invoke-RouteComputerMonitoring')
    ,@('GET',   '/api/vqa/recommendation',                'Invoke-RouteVqaRecommendation')
    ,@('POST',  '/api/computer-monitoring/force-refresh', 'Invoke-RouteComputerMonitoringForceRefresh')
    ,@('GET',   '/api/openconfig',                        'Invoke-RouteOpenconfig')
    ,@('GET',   '/api/openfolder',                        'Invoke-RouteOpenfolder')
    ,@('POST',  '/api/browse-folder',                     'Invoke-RouteBrowseFolder')
    ,@('GET',   '/api/logs/sources',                      'Invoke-RouteLogsSources')
    ,@('GET',   '/api/logs',                              'Invoke-RouteLogs')
    ,@('GET',   '/api/version',                           'Invoke-RouteVersion')
    ,@('GET',   '/api/appinfo',                           'Invoke-RouteAppinfo')
    ,@('GET',   '/api/appnames',                          'Invoke-RouteAppnames')
    ,@('POST',  '/api/appnames/save',                     'Invoke-RouteAppnamesSave')
    ,@('POST',  '/api/appnames/delete',                   'Invoke-RouteAppnamesDelete')
    ,@('POST',  '/api/appnames/clear',                    'Invoke-RouteAppnamesClear')
    ,@('GET',   '/api/defaultfavorites',                  'Invoke-RouteDefaultfavorites')
    ,@('POST',  '/api/defaultfavorites/toggle',           'Invoke-RouteDefaultfavoritesToggle')
    ,@('POST',  '/api/defaultfavorites/reorder',          'Invoke-RouteDefaultfavoritesReorder')
    ,@('POST',  '/api/favorites/reorder',                 'Invoke-RouteFavoritesReorder')
    ,@('GET',   '/api/config',                            'Invoke-RouteConfig')
    ,@('GET',   '/api/config/defaults',                   'Invoke-RouteConfigDefaults')
    ,@('GET',   '/api/server-info',                       'Invoke-RouteServerInfo')
    ,@('GET',   '/api/gpu-list',                          'Invoke-RouteGpuList')
    ,@('POST',  '/api/config/save',                       'Invoke-RouteConfigSave')
    ,@('POST',  '/api/config/reset',                      'Invoke-RouteConfigReset')
    ,@('GET',   '/api/ffmpeg-version',                    'Invoke-RouteFfmpegVersion')
    ,@('POST',  '/api/ffmpeg-check-update',               'Invoke-RouteFfmpegCheckUpdate')
    ,@('POST',  '/api/ffmpeg-update',                     'Invoke-RouteFfmpegUpdate')
    ,@('GET',   '/api/ffmpeg-list-versions',              'Invoke-RouteFfmpegListVersions')
    ,@('POST',  '/api/ffmpeg-switch-version',             'Invoke-RouteFfmpegSwitchVersion')
    ,@('GET',   '/api/mediamtx-version',                  'Invoke-RouteMediamtxVersion')
    ,@('POST',  '/api/mediamtx-check-update',             'Invoke-RouteMediamtxCheckUpdate')
    ,@('GET',   '/api/mediamtx-list-versions',            'Invoke-RouteMediamtxListVersions')
    ,@('POST',  '/api/mediamtx-switch-version',           'Invoke-RouteMediamtxSwitchVersion')
    ,@('POST',  '/api/mediamtx-update',                   'Invoke-RouteMediamtxUpdate')
    ,@('GET',   '/api/scrcpy-version',                    'Invoke-RouteScrcpyVersion')
    ,@('POST',  '/api/scrcpy-check-update',               'Invoke-RouteScrcpyCheckUpdate')
    ,@('GET',   '/api/scrcpy-list-versions',              'Invoke-RouteScrcpyListVersions')
    ,@('POST',  '/api/scrcpy-switch-version',             'Invoke-RouteScrcpySwitchVersion')
    ,@('POST',  '/api/scrcpy-update',                     'Invoke-RouteScrcpyUpdate')
    ,@('GET',   '/api/timer',                             'Invoke-RouteTimer')
)) { $script:RouteTable[$routeRow[0] + ' ' + $routeRow[1]] = $routeRow[2] }

# Prefix routes, tried in this order after an exact miss. Method '' = any verb. Each entry
# carries either Like (a -like pattern) or Match (a -match regex), the operator the former
# chain used for it. Anything still unmatched is a static file (Invoke-RouteStaticFile).
$script:RoutePrefixes = @(
    @{ Method = '';    Like = '/api/recordings/*';      Handler = 'Invoke-RouteRecordings' }
    @{ Method = 'GET'; Match = '^/proxy/mediamtx(/.*)$'; Handler = 'Invoke-RouteMediaMtxProxy' }
)

function Invoke-HttpRoute {
    # Dispatch one request (S9-3): CORS preflight, then the exact table, then the prefix list,
    # then the static files. Each handler owns $response.Close() and leaves with `return`.
    # Handlers read these from the caller's scope (web_server.ps1's script scope on the accept
    # loop, the worker block's locals in the slow lane), never through a parameter:
    #   $adbPath $adbPort $apkPath $apkPackage $websitePath $mimeTypes $lanNetworks $PidFile
    #   $ScriptPath $ConfigFilePath $port (web server port, /api/appinfo only), and - for the
    #   fast-only job routes - $installJobBlock $resolveJobBlock $updateVersionsJobBlock
    #   $benchmarkJobBlock $benchmarkParallelJobBlock.
    # Script-scope state they own (loop-bound, hence fast routes): $script:installJobs,
    #   resolveJob/resolveProgFile, updateVersionsJob/ProgFile/HeadsetName, benchmarkJob/
    #   benchmarkProgFile, RecordingDownloads; per-runspace caches: appInfoCache/At,
    #   HeadsetIpdMemo, timerStatusMemo.
    param([Parameter(Mandatory = $true)] $Context)

    # Locals are $route* on purpose: handlers see this scope (dynamic scoping), so a plain
    # $path or $method here could leak into a handler that reads one before assigning it.
    $routeMethod = $Context.Request.HttpMethod
    $routePath   = $Context.Request.Url.LocalPath
    if ($routeMethod -eq 'OPTIONS') { Invoke-RouteCorsPreflight -Context $Context; return }

    $routeHandler = $script:RouteTable[$routeMethod + ' ' + $routePath]
    if (-not $routeHandler) {
        foreach ($routeEntry in $script:RoutePrefixes) {
            if ($routeEntry.Method -and $routeMethod -ne $routeEntry.Method) { continue }
            if ($routeEntry.Like) { $routeHit = $routePath -like $routeEntry.Like } else { $routeHit = $routePath -match $routeEntry.Match }
            if ($routeHit) { $routeHandler = $routeEntry.Handler; break }
        }
    }
    if (-not $routeHandler) { $routeHandler = 'Invoke-RouteStaticFile' }
    & $routeHandler -Context $Context
}

function Invoke-RouteCorsPreflight {
    # OPTIONS on any path (CORS preflight)
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    $response.Headers.Add('Access-Control-Allow-Origin', '*')
    $response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    $response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $response.StatusCode = 204
    Close-HttpResponse -Response $response
    return
}

# --- route handlers (S9-3) -----------------------------------------------------------------
# The Invoke-Route* handlers live in per-domain files under routes\, dot-sourced HERE so they
# land in the same scope as the dispatcher on either lane (web_server.ps1 and the slow-lane
# worker both dot-source this file). Dot-sourcing adds no scope: a handler still reads the
# $script:* state and the caller's $adbPath / $PidFile / ... exactly as before the split.
# An explicit list, not a glob: a missing file must fail the load loudly (web_server.ps1 stops,
# the worker reports $state.Error and slow routes run inline) rather than answer 404s. The
# S0-3 route census (20_webpages.ps1) reads every .ps1 under modules\Pode_WebServer.
foreach ($routeFileName in @(
    'routes_headsets.ps1'
    'routes_streams.ps1'
    'routes_diag.ps1'
    'routes_eye_merge.ps1'
    'routes_kiosks.ps1'
    'routes_apps.ps1'
    'routes_usb.ps1'
    'routes_wifi.ps1'
    'routes_benchmark.ps1'
    'routes_recordings.ps1'
    'routes_vqa.ps1'
    'routes_config.ps1'
    'routes_binaries.ps1'
    'routes_timer.ps1'
    'routes_system.ps1'
    'routes_static.ps1'
)) {
    $routeFilePath = Join-Path (Join-Path $PSScriptRoot 'routes') $routeFileName
    if (-not (Test-Path -LiteralPath $routeFilePath)) { throw "Web route file not found: $routeFilePath" }
    . $routeFilePath
}
# Every handler the tables name must exist now, or a request would fail at dispatch time.
foreach ($routeHandlerName in @(@($script:RouteTable.Values) + @($script:RoutePrefixes | ForEach-Object { $_.Handler }) + 'Invoke-RouteStaticFile')) {
    if (-not (Test-Path -LiteralPath ('function:' + $routeHandlerName))) { throw "Web route handler not defined: $routeHandlerName" }
}
Remove-Variable -Name routeFileName, routeFilePath, routeHandlerName -ErrorAction SilentlyContinue
