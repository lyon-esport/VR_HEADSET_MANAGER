#Requires -Version 5.1
<#
.SYNOPSIS
    Section 20 - every web page is served, and the read-only API reports what
    the on-disk state says it should.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context.

    Two kinds of check here:
      - reachability: each page and asset returns 200 with plausible content
        and no server-side error trace leaked into the body
      - cross-validation: the API's answers are compared against the files the
        app itself wrote (pid files, config.json, known_headsets.csv,
        version.txt), so a handler that quietly returns stale or invented data
        is caught rather than merely "returning 200"

    Also pins the security-relevant behaviour of the static file route
    (traversal and extension filtering), since that route serves from data\.

    ASCII only (CLAUDE.md rule 1).
#>

$target = $global:TestRun.TargetRoot
$paths  = Get-SandboxPaths -TargetRoot $target

# Core pages that must always exist. Any additional page found on disk is
# also fetched, so a newly added page is covered without editing this list.
$corePages = @(
    'video_monitor.html'
    'headsets_monitoring.html'
    'headsets_settings.html'
    'headsets_apps_manager.html'
    'known_apps_manager.html'
    'vrhm_config.html'
    'timer_control.html'
    'help.html'
)

Invoke-RegressionTest -Name 'App is running and reachable' -Test {
    $up = Confirm-SandboxApp -TargetRoot $target
    Assert-True $up 'the sandbox app is not running'

    $r = Invoke-VrmApi -Path '/api/version' -TimeoutSec 20
    Add-TestEvidence ("base = {0}" -f (Get-VrmApiBase))
    Assert-True $r.Ok ("GET /api/version returned HTTP {0} {1}" -f $r.StatusCode, $r.Error)
}

# ---------------------------------------------------------------------------
# Pages and assets
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'All core pages exist on disk' -Test {
    foreach ($page in $corePages) {
        Assert-FileExists (Join-Path $paths.WebsiteFolder $page) $page
    }
}

Invoke-RegressionTest -Name 'Root URL serves the video monitor' -Test {
    $page = Assert-VrmPageServed -Path '/' -MustContain '<html' -MinLength 500
    Add-TestEvidence ("root served {0} bytes" -f $page.Length)
}

# No GetNewClosure() here on purpose: it would rebind the scriptblock into a new
# dynamic module scope, whose function lookup goes module -> global and skips the
# script scope this harness is dot-sourced into, so Assert-VrmPageServed would not
# resolve. Not needed either - Invoke-RegressionTest runs the block synchronously
# within this same loop iteration, so $pageName still holds the current value.
foreach ($pageName in $corePages) {
    Invoke-RegressionTest -Name ("Page is served: {0}" -f $pageName) -Test {
        Assert-VrmPageServed -Path ('/' + $pageName) -MustContain '<html' -MinLength 500 | Out-Null
    }
}

Invoke-RegressionTest -Name 'Any extra page on disk is also served' -Test {
    $onDisk = @(Get-ChildItem -LiteralPath $paths.WebsiteFolder -Filter '*.html' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*[[]*[]]*' })
    $extra = @($onDisk | Where-Object { $corePages -notcontains $_.Name })

    if ($extra.Count -eq 0) { Skip-Test 'no pages beyond the core set' }
    foreach ($f in $extra) {
        Add-TestEvidence ("extra page: {0}" -f $f.Name)
        Assert-VrmPageServed -Path ('/' + $f.Name) -MinLength 100 | Out-Null
    }
}

Invoke-RegressionTest -Name 'Shared assets are served' -Test {
    $assets = @(
        @{ Path = '/assets/topbar.js';       Type = 'javascript' }
        @{ Path = '/assets/topbar.css';      Type = 'css' }
        @{ Path = '/assets/app_launcher.js'; Type = 'javascript' }
        @{ Path = '/assets/favicon.svg';     Type = 'svg' }
    )
    foreach ($asset in $assets) {
        $onDisk = Join-Path $paths.WebsiteFolder ($asset.Path -replace '^/', '' -replace '/', '\')
        if (-not (Test-Path -LiteralPath $onDisk)) {
            Add-TestEvidence ("skipped (not shipped): {0}" -f $asset.Path)
            continue
        }
        Assert-VrmPageServed -Path $asset.Path -ExpectContentType $asset.Type -MinLength 20 | Out-Null
    }
}

Invoke-RegressionTest -Name 'Generated per-headset pages are served' -Test {
    $headsets = Get-VrmHeadsets
    if ($headsets.Count -eq 0) { Skip-Test 'no headsets registered yet (section 40 adds one)' }

    foreach ($h in $headsets) {
        $safe = ConvertTo-VrmSafeName $h.Name
        foreach ($kind in @('monitoring', 'video', 'timer')) {
            $url = "/{0}[{1}].html" -f $safe, $kind
            Add-TestEvidence ("checking {0}" -f $url)
            Assert-VrmPageServed -Path $url -MinLength 100 | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# Static route security
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'data\ route is refused entirely' -Test {
    # INVERTED deliberately. This used to assert that GET /data/computer_monitoring.json
    # returned 200. The data folder is no longer web-readable at all - web_server.ps1
    # refuses the whole "data/" prefix with 403 before any file lookup:
    #
    #   "The data folder is no longer web-readable. It used to serve .csv/.json
    #    straight off disk, which is how the monitoring and VQA pages read their
    #    state; both now go through an API that returns the same shape from the
    #    database. Refusing the whole prefix keeps a stale legacy_* copy from
    #    being served too."
    #
    # So the security property to protect is that the prefix stays closed, for a
    # real file as well as a missing one - a 403 on a file that exists is what
    # proves the refusal happens before the lookup, not just as a side effect of
    # the file being absent.
    $probe = Join-Path $paths.DataFolder 'nrt_route_probe.json'
    try {
        Set-Content -LiteralPath $probe -Value '{"nrt":true}' -Encoding UTF8
        $r = Invoke-VrmApi -Path '/data/nrt_route_probe.json'
        Add-TestEvidence ("GET /data/nrt_route_probe.json (file EXISTS) -> HTTP {0}" -f $r.StatusCode)
        Assert-Equal 403 $r.StatusCode 'an existing file under data\ is still refused'
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }

    $r2 = Invoke-VrmApi -Path '/data/known_headsets.csv'
    Add-TestEvidence ("GET /data/known_headsets.csv -> HTTP {0}" -f $r2.StatusCode)
    Assert-Equal 403 $r2.StatusCode 'the legacy CSV export path is refused too'
}

Invoke-RegressionTest -Name 'data\ route refuses an operational file' -Test {
    # Renamed: the old name ('refuses non-CSV/JSON extensions') implied that CSV and
    # JSON under data\ ARE served. They are not any more - the whole prefix is
    # refused, see the test above. The assertion is unchanged and still worth
    # keeping: a PID file is the case that would matter most if the prefix were
    # ever reopened.
    $r = Invoke-VrmApi -Path '/data/webserver.pid'
    Add-TestEvidence ("GET /data/webserver.pid -> HTTP {0}" -f $r.StatusCode)
    Assert-True ($r.StatusCode -eq 403 -or $r.StatusCode -eq 404) `
        ("expected 403/404 for a file under data\, got {0}" -f $r.StatusCode)
}

Invoke-RegressionTest -Name 'Static route blocks path traversal' -Test {
    foreach ($attack in @('/../config/config.json', '/..%2fconfig%2fconfig.json', '/data/../config/config.json')) {
        $r = Invoke-VrmApi -Path $attack
        Add-TestEvidence ("{0} -> HTTP {1}" -f $attack, $r.StatusCode)
        Assert-True ($r.StatusCode -ne 200) ("traversal was served: {0}" -f $attack)
        Assert-True ($r.Raw -notlike '*adbWirelessActivator*') ("traversal leaked config content: {0}" -f $attack)
    }
}

Invoke-RegressionTest -Name 'Unknown path returns a plain 404' -Test {
    $r = Invoke-VrmApi -Path '/definitely_not_a_real_page.html'
    Assert-Equal 404 $r.StatusCode 'unknown page status'
    Add-TestEvidence ("content-type: {0}" -f $r.ContentType)
}

Invoke-RegressionTest -Name 'CORS preflight is answered' -Test {
    $r = Invoke-VrmApi -Path '/api/headsets' -Method OPTIONS
    Add-TestEvidence ("OPTIONS -> HTTP {0}" -f $r.StatusCode)
    Assert-Equal 204 $r.StatusCode 'OPTIONS status'
}

# ---------------------------------------------------------------------------
# API contract - cross-validated against on-disk state
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name '/api/version matches version.txt' -Test {
    $r = Invoke-VrmApi -Path '/api/version'
    Assert-True $r.Ok 'GET /api/version'
    Assert-NotNull $r.Json.version 'version field'

    $onDisk = (Get-Content -LiteralPath (Join-Path $target 'version.txt') -Raw -Encoding UTF8).Trim()
    Add-TestEvidence ("api='{0}'  version.txt='{1}'" -f $r.Json.version, $onDisk)
    Assert-Equal $onDisk $r.Json.version 'reported version'
}

Invoke-RegressionTest -Name '/api/appinfo agrees with the pid files and config' -Test {
    $r = Invoke-VrmApi -Path '/api/appinfo'
    Assert-True $r.Ok 'GET /api/appinfo'
    Assert-NotNull $r.Json 'appinfo body'

    $cfg = Read-JsonFileUtf8 -Path $paths.ConfigFile
    Assert-Equal ([int]$cfg.WebServer.port)      ([int]$r.Json.webServerPort)    'webServerPort'
    Assert-Equal ([int]$cfg.mediamtx.hls_port)   ([int]$r.Json.mediamtxHlsPort)  'mediamtxHlsPort'
    Assert-Equal ([int]$cfg.mediamtx.rtsp_port)  ([int]$r.Json.mediamtxRtspPort) 'mediamtxRtspPort'
    Assert-Equal ([int]$cfg.mediamtx.api_port)   ([int]$r.Json.mediamtxApiPort)  'mediamtxApiPort'

    $storedWebPid = (Get-Content -LiteralPath $paths.WebServerPid -Raw -Encoding UTF8).Trim()
    Add-TestEvidence ("webserver.pid={0}  api reports {1}" -f $storedWebPid, $r.Json.webServerPid)
    Assert-Equal ([int]$storedWebPid) ([int]$r.Json.webServerPid) 'webServerPid'

    if (Test-Path -LiteralPath $paths.MediaMtxPid) {
        $storedMtxPid = (Get-Content -LiteralPath $paths.MediaMtxPid -Raw -Encoding UTF8).Trim()
        Add-TestEvidence ("mediamtx.pid={0}  api reports {1}" -f $storedMtxPid, $r.Json.mediamtxPid)
        Assert-Equal ([int]$storedMtxPid) ([int]$r.Json.mediamtxPid) 'mediamtxPid'
    }
}

Invoke-RegressionTest -Name '/api/headsets matches the registry table' -Test {
    $r = Invoke-VrmApi -Path '/api/headsets'
    Assert-True $r.Ok 'GET /api/headsets'

    $api = @($r.Json)
    $stored = @(Get-SandboxHeadsets -TargetRoot $target)
    Add-TestEvidence ("api rows={0}  db rows={1}" -f $api.Count, $stored.Count)
    Assert-Equal $stored.Count $api.Count 'headset row count'

    if ($api.Count -gt 0) {
        $required = @('ID', 'Name', 'IPAddress', 'Model', 'ScrcpyProfile', 'scrcpy_AutoRestart', 'Record')
        $actual = $api[0].PSObject.Properties.Name
        foreach ($field in $required) {
            Assert-Contains $actual $field 'headset object fields'
        }
    }
}

Invoke-RegressionTest -Name '/api/headsets-status returns one entry per headset' -Test {
    $r = Invoke-VrmApi -Path '/api/headsets-status'
    Assert-True $r.Ok 'GET /api/headsets-status'

    $api = @($r.Json)
    $stored = @(Get-SandboxHeadsets -TargetRoot $target)
    Assert-Equal $stored.Count $api.Count 'status row count'

    if ($api.Count -gt 0) {
        foreach ($field in @('display_name', 'ip_address', 'ping', 'adb', 'scrcpy', 'battery')) {
            Assert-Contains $api[0].PSObject.Properties.Name $field 'status object fields'
        }
    }
}

Invoke-RegressionTest -Name '/api/config round-trips the sandbox config' -Test {
    $r = Invoke-VrmApi -Path '/api/config'
    Assert-Equal 200 $r.StatusCode 'GET /api/config'
    Assert-NotNull $r.Json 'config body parses'

    $onDisk = Read-JsonFileUtf8 -Path $paths.ConfigFile
    Assert-Equal ([int]$onDisk.WebServer.port) ([int]$r.Json.WebServer.port) 'WebServer.port via API'
    Assert-Equal $onDisk.mediamtx.codec $r.Json.mediamtx.codec 'mediamtx.codec via API'
}

Invoke-RegressionTest -Name '/api/config/defaults serves the shipped template' -Test {
    $r = Invoke-VrmApi -Path '/api/config/defaults'
    Assert-Equal 200 $r.StatusCode 'GET /api/config/defaults'
    Assert-NotNull $r.Json.WebServer 'defaults WebServer node'
}

Invoke-RegressionTest -Name '/api/capture-mode reports a valid mode' -Test {
    $r = Invoke-VrmApi -Path '/api/capture-mode'
    Assert-VrmOk -Result $r -Label 'GET /api/capture-mode'
    Add-TestEvidence ("mode = {0}" -f $r.Json.mode)
    Assert-Contains @('StreamOnly', 'StreamAndLocalWindow', 'LocalWindow') $r.Json.mode 'capture mode value'
}

Invoke-RegressionTest -Name 'Tool versions are reported and match the config folders' -Test {
    $cfg = Read-JsonFileUtf8 -Path $paths.ConfigFile

    $scrcpy = Invoke-VrmApi -Path '/api/scrcpy-version'
    Assert-VrmOk -Result $scrcpy -Label 'GET /api/scrcpy-version'
    Add-TestEvidence ("scrcpy   = {0}  (folder {1})" -f $scrcpy.Json.installedVersion, $cfg.scrcpy.folder)
    Assert-NotNull $scrcpy.Json.installedVersion 'scrcpy installedVersion'
    Assert-True ($cfg.scrcpy.folder -like ("*" + $scrcpy.Json.installedVersion + "*")) `
        'reported scrcpy version does not appear in the configured folder name'

    $mtx = Invoke-VrmApi -Path '/api/mediamtx-version'
    Assert-VrmOk -Result $mtx -Label 'GET /api/mediamtx-version'
    Add-TestEvidence ("mediamtx = {0}  (folder {1})" -f $mtx.Json.installedVersion, $cfg.mediamtx.folder)
    Assert-True ($cfg.mediamtx.folder -like ("*" + $mtx.Json.installedVersion + "*")) `
        'reported mediamtx version does not appear in the configured folder name'

    $ff = Invoke-VrmApi -Path '/api/ffmpeg-version'
    Assert-VrmOk -Result $ff -Label 'GET /api/ffmpeg-version'
    Add-TestEvidence ("ffmpeg   = {0}" -f $ff.Json.installedVersion)
    Assert-NotNull $ff.Json.installedVersion 'ffmpeg installedVersion'
}

Invoke-RegressionTest -Name 'Installed tool versions list marks the active one' -Test {
    foreach ($endpoint in @('/api/scrcpy-list-versions', '/api/mediamtx-list-versions')) {
        $r = Invoke-VrmApi -Path $endpoint
        Assert-VrmOk -Result $r -Label ("GET " + $endpoint)
        $versions = @($r.Json.versions)
        Add-TestEvidence ("{0} -> {1} version(s)" -f $endpoint, $versions.Count)
        Assert-True ($versions.Count -ge 1) ("{0} returned no versions" -f $endpoint)

        $active = @($versions | Where-Object { $_.active })
        Assert-Equal 1 $active.Count ("{0}: exactly one version must be active" -f $endpoint)
    }
}

Invoke-RegressionTest -Name '/api/load-tier reports a tier' -Test {
    $r = Invoke-VrmApi -Path '/api/load-tier'
    Assert-VrmOk -Result $r -Label 'GET /api/load-tier'
    Assert-NotNull $r.Json.loadTier.tier 'loadTier.tier'
    Add-TestEvidence ("tier = {0}, multiplier = {1}" -f $r.Json.loadTier.tier, $r.Json.loadTier.multiplier)
}

Invoke-RegressionTest -Name '/api/recording-drive reports the sandbox record drive' -Test {
    $r = Invoke-VrmApi -Path '/api/recording-drive'
    Assert-Equal 200 $r.StatusCode 'GET /api/recording-drive'
    Assert-NotNull $r.Json 'recording drive body'
    if ($r.Json.PSObject.Properties.Name -contains 'error') {
        Skip-Test ('recording drive unavailable: ' + $r.Json.error)
    }
    Add-TestEvidence ("drive {0}  free {1} GB  low={2}" -f $r.Json.DriveLetter, $r.Json.FreeGB, $r.Json.IsLow)
    Assert-NotNull $r.Json.DriveLetter 'DriveLetter'
}

Invoke-RegressionTest -Name '/api/server-info lists local addresses' -Test {
    $r = Invoke-VrmApi -Path '/api/server-info'
    Assert-Equal 200 $r.StatusCode 'GET /api/server-info'
    $ips = @($r.Json.localIPs)
    Add-TestEvidence ("localIPs = {0}" -f ($ips -join ', '))
    Assert-Contains $ips '127.0.0.1' 'localIPs'
}

Invoke-RegressionTest -Name '/api/vqa/status reflects the sandbox setting' -Test {
    $r = Invoke-VrmApi -Path '/api/vqa/status'
    Assert-Equal 200 $r.StatusCode 'GET /api/vqa/status'
    $cfg = Read-JsonFileUtf8 -Path $paths.ConfigFile
    Add-TestEvidence ("api enabled={0}  config enabled={1}" -f $r.Json.enabled, $cfg.VideoQualityAutomation.enabled)
    Assert-Equal ([bool]$cfg.VideoQualityAutomation.enabled) ([bool]$r.Json.enabled) 'VQA enabled flag'
}

Invoke-RegressionTest -Name 'VQA ships enabled in recommendation-only mode' -Test {
    # The release default (templates\config\config.json): VQA on, so the operator gets
    # recommendations, but NOTHING applied automatically - an auto-apply flag that slipped
    # to true would rewrite profiles and the mediamtx settings on a live show.
    $tpl = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    $v = $tpl.VideoQualityAutomation
    Add-TestEvidence ("template: enabled={0} auto_apply profiles={1} headsets={2} mediamtx={3}" -f $v.enabled, $v.auto_apply_profiles, $v.auto_apply_headsets, $v.auto_apply_mediamtx)
    Assert-True ([bool]$v.enabled) 'templates\config\config.json: VideoQualityAutomation.enabled must be true'
    Assert-False ([bool]$v.auto_apply_profiles) 'template auto_apply_profiles must be false'
    Assert-False ([bool]$v.auto_apply_headsets) 'template auto_apply_headsets must be false'
    Assert-False ([bool]$v.auto_apply_mediamtx) 'template auto_apply_mediamtx must be false'

    # And the running app agrees: VQA loaded, VQO (auto-apply) off.
    $r = Invoke-VrmApi -Path '/api/vqa/status'
    Assert-Equal 200 $r.StatusCode 'GET /api/vqa/status'
    Add-TestEvidence ("running app: enabled={0} enabled_vqo={1}" -f $r.Json.enabled, $r.Json.enabled_vqo)
    Assert-True ([bool]$r.Json.enabled) 'the running app reports VQA disabled'
    Assert-False ([bool]$r.Json.enabled_vqo) 'the running app reports an auto-apply (VQO) flag on'
}

Invoke-RegressionTest -Name 'Deprecated /api/vqa/toggle-vqo still reports as deprecated' -Test {
    $r = Invoke-VrmApi -Path '/api/vqa/toggle-vqo' -Method POST
    Add-TestEvidence ("POST /api/vqa/toggle-vqo -> HTTP {0}: {1}" -f $r.StatusCode, (Get-VrmApiExcerpt $r.Raw 120))
    # 410 Gone when VQA is on; 404 when the whole VQA surface is disabled.
    Assert-True ($r.StatusCode -eq 410 -or $r.StatusCode -eq 404) `
        ("expected 410 (deprecated) or 404 (VQA off), got {0}" -f $r.StatusCode)
}

Invoke-RegressionTest -Name '/api/logs returns recent log lines' -Test {
    $r = Invoke-VrmApi -Path '/api/logs?n=50'
    Assert-True $r.Ok 'GET /api/logs'
    $lines = @($r.Json)
    Add-TestEvidence ("returned {0} line(s)" -f $lines.Count)
    Assert-True ($lines.Count -gt 0) 'log endpoint returned nothing'
}

Invoke-RegressionTest -Name '/api/logs/sources lists log files by type' -Test {
    $r = Invoke-VrmApi -Path '/api/logs/sources'
    Assert-True $r.Ok 'GET /api/logs/sources'
    $sources = @($r.Json.sources)
    Add-TestEvidence ("{0} source(s), types: {1}" -f $sources.Count, (($sources.type | Select-Object -Unique) -join ', '))
    Assert-True ($sources.Count -gt 0) 'no log sources returned'
    # The main program log must always be offered - it is the picker's default.
    Assert-True (($sources.type) -contains 'main') "no 'main' log type in the source list"
}

Invoke-RegressionTest -Name '/api/logs serves a selected log file' -Test {
    $r = Invoke-VrmApi -Path '/api/logs/sources'
    Assert-True $r.Ok 'GET /api/logs/sources'
    $main = @($r.Json.sources | Where-Object { $_.type -eq 'main' })[0]
    Assert-True ($null -ne $main) 'no main log source to request'
    $r2 = Invoke-VrmApi -Path ('/api/logs?n=25&file=' + [uri]::EscapeDataString($main.id))
    Assert-True $r2.Ok 'GET /api/logs?file='
    $lines = @($r2.Json)
    Add-TestEvidence ("{0} returned {1} line(s)" -f $main.id, $lines.Count)
    Assert-True ($lines.Count -gt 0) 'selected log file returned nothing'
    # A bogus id must fall back to the main log, never read outside the log folder.
    $r3 = Invoke-VrmApi -Path '/api/logs?n=5&file=..%2F..%2Fconfig%2Fconfig.json'
    Assert-True $r3.Ok 'GET /api/logs with a traversal attempt'
    $fallback = @($r3.Json)
    Add-TestEvidence ("traversal attempt fell back to {0} line(s)" -f $fallback.Count)
    Assert-True (($fallback -join '') -notmatch '"WebServer"') 'traversal attempt leaked config.json'
}

# ---------------------------------------------------------------------------
# Push channel (SSE, ADR-0020)
#
# /api/events holds a connection open for good. The first attempt at this feature
# (commit 7e52019) was reverted because the web server "broke": these tests pin the
# properties whose absence looks exactly like that - the stream starts, a change is
# pushed, and above all ORDINARY requests keep answering while many streams are open.
# Raw sockets are used because Invoke-WebRequest waits for a body that never ends.
# ---------------------------------------------------------------------------

function Open-NrtEventStream {
    $u = [uri](Get-VrmApiBase)
    $client = New-Object System.Net.Sockets.TcpClient($u.Host, $u.Port)
    $stream = $client.GetStream()
    $req = [System.Text.Encoding]::ASCII.GetBytes(("GET /api/events HTTP/1.1`r`nHost: {0}:{1}`r`nAccept: text/event-stream`r`n`r`n" -f $u.Host, $u.Port))
    $stream.Write($req, 0, $req.Length)
    return [PSCustomObject]@{ Client = $client; Stream = $stream; Text = '' }
}

# Reads until $Pattern matches the text received AFTER $FromIndex, or the timeout.
# Returns the elapsed ms, or -1 on timeout.
function Read-NrtEventStream {
    param($Es, [string]$Pattern, [int]$TimeoutMs = 5000, [int]$FromIndex = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $buf = New-Object byte[] 8192
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Es.Text.Length -gt $FromIndex -and $Es.Text.Substring($FromIndex) -match $Pattern) { return [int]$sw.ElapsedMilliseconds }
        try {
            if ($Es.Stream.DataAvailable) {
                $n = $Es.Stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { return -1 }
                $Es.Text += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            } else { Start-Sleep -Milliseconds 25 }
        } catch { return -1 }
    }
    return -1
}

function Close-NrtEventStream { param($Es) try { $Es.Client.Close() } catch { } }

function Test-NrtSseEnabled {
    $cfg = Read-JsonFileUtf8 -Path $paths.ConfigFile
    return -not ($cfg.WebServer.sse -and $null -ne $cfg.WebServer.sse.enabled -and -not [bool]$cfg.WebServer.sse.enabled)
}

Invoke-RegressionTest -Name 'Push channel: live_events.js is served' -Test {
    Assert-VrmPageServed -Path '/assets/live_events.js' -ExpectContentType 'javascript' -MustContain 'LiveEvents' -MinLength 500 | Out-Null
}

Invoke-RegressionTest -Name 'Push channel: /api/events opens a stream with a baseline frame' -Test {
    if (-not (Test-NrtSseEnabled)) { Skip-Test 'WebServer.sse.enabled is false in the sandbox config' }
    $es = Open-NrtEventStream
    try {
        $ms = Read-NrtEventStream -Es $es -Pattern 'data: \{"v":\{' -TimeoutMs 5000
        $head = ($es.Text -split "`r`n")[0]
        Add-TestEvidence ("status line: {0}" -f $head)
        Add-TestEvidence ("baseline frame after {0} ms" -f $ms)
        Assert-Match $head '^HTTP/1\.1 200' '/api/events status'
        Assert-Match $es.Text '(?i)content-type: text/event-stream' '/api/events content type'
        Assert-True ($ms -ge 0) 'no baseline frame within 5 s'
        Assert-Match $es.Text '"headset_status":\d+' 'baseline frame carries the headset_status counter'
    } finally { Close-NrtEventStream $es }
}

Invoke-RegressionTest -Name 'Push channel: web server keeps answering with 10 streams open' -Test {
    if (-not (Test-NrtSseEnabled)) { Skip-Test 'WebServer.sse.enabled is false in the sandbox config' }
    $streams = @()
    try {
        for ($i = 0; $i -lt 10; $i++) { $streams += Open-NrtEventStream }
        $opened = @($streams | Where-Object { (Read-NrtEventStream -Es $_ -Pattern 'data: \{"v":\{' -TimeoutMs 5000) -ge 0 }).Count
        Add-TestEvidence ("{0}/10 streams received their baseline frame" -f $opened)
        Assert-Equal 10 $opened 'streams with a baseline frame'

        foreach ($path in @('/api/version', '/api/headsets-status', '/api/headsets', '/headsets_settings.html', '/api/load-tier')) {
            $r = Invoke-VrmApi -Path $path -TimeoutSec 10
            Add-TestEvidence ("{0} -> HTTP {1} in {2} ms" -f $path, $r.StatusCode, [int]$r.Elapsed.TotalMilliseconds)
            Assert-True $r.Ok ("{0} failed while streams are open: HTTP {1} {2}" -f $path, $r.StatusCode, $r.Error)
            Assert-True ($r.Elapsed.TotalMilliseconds -lt 3000) ("{0} took {1} ms with streams open" -f $path, [int]$r.Elapsed.TotalMilliseconds)
        }
    } finally {
        foreach ($s in $streams) { Close-NrtEventStream $s }
    }
    # And after the clients are gone (dropped without a clean close), still fine.
    Start-Sleep -Seconds 1
    $r2 = Invoke-VrmApi -Path '/api/headsets-status' -TimeoutSec 10
    Add-TestEvidence ("after closing: /api/headsets-status -> HTTP {0} in {1} ms" -f $r2.StatusCode, [int]$r2.Elapsed.TotalMilliseconds)
    Assert-True $r2.Ok 'status endpoint after the streams were closed'
}

Invoke-RegressionTest -Name 'Push channel: a database change is pushed within 2 s' -Test {
    if (-not (Test-NrtSseEnabled)) { Skip-Test 'WebServer.sse.enabled is false in the sandbox config' }
    # A kiosk row on a TEST-NET address (RFC 5737, never routed) is the most harmless
    # write available: it bumps the 'kiosks' counter and is removed right after.
    $probeIp = '192.0.2.250'
    $es = Open-NrtEventStream
    $kioskId = $null
    try {
        Assert-True ((Read-NrtEventStream -Es $es -Pattern 'data: \{"v":\{' -TimeoutMs 5000) -ge 0) 'no baseline frame'
        $before = [int64]([regex]::Match($es.Text, '"kiosks":(\d+)').Groups[1].Value)
        $mark = $es.Text.Length

        $add = Invoke-VrmApi -Path '/api/kiosks/add-manual' -Method POST -Body @{ ip = $probeIp; name = 'NRT SSE probe'; port = 9222 }
        Assert-VrmOk -Result $add -Label 'POST /api/kiosks/add-manual'
        # Other counters (live status written by the monitor) may push frames first, still
        # carrying the old kiosks value - wait for the frame where kiosks actually moved.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $after = $before
        while ($sw.ElapsedMilliseconds -lt 2000 -and $after -le $before) {
            [void](Read-NrtEventStream -Es $es -Pattern '"kiosks":\d+' -TimeoutMs 200 -FromIndex $mark)
            foreach ($m in [regex]::Matches($es.Text.Substring($mark), '"kiosks":(\d+)')) {
                if ([int64]$m.Groups[1].Value -gt $after) { $after = [int64]$m.Groups[1].Value }
            }
        }
        Add-TestEvidence ("kiosks counter {0} -> {1}, pushed after {2} ms" -f $before, $after, $sw.ElapsedMilliseconds)
        Assert-True ($after -gt $before) 'no frame with the new kiosks counter was pushed within 2 s of the database write'
    } finally {
        Close-NrtEventStream $es
        $list = Invoke-VrmApi -Path '/api/kiosks'
        foreach ($k in @($list.Json.kiosks) + @($list.Json)) {
            if ($k -and $k.IPAddress -eq $probeIp -and $k.ID) { $kioskId = $k.ID }
        }
        if ($kioskId) {
            $rm = Invoke-VrmApi -Path '/api/kiosks/remove' -Method POST -Body @{ id = [int]$kioskId }
            Add-TestEvidence ("probe kiosk id {0} removed: HTTP {1}" -f $kioskId, $rm.StatusCode)
        }
    }
}

Invoke-RegressionTest -Name '/api/appnames returns the known-apps catalog' -Test {
    $r = Invoke-VrmApi -Path '/api/appnames'
    Assert-Equal 200 $r.StatusCode 'GET /api/appnames'
    $apps = @($r.Json.apps)
    Add-TestEvidence ("catalog holds {0} app(s)" -f $apps.Count)
    Assert-True ($apps.Count -gt 0) 'known-apps catalog is empty - templates\data\known_apps.csv may not be shipped'
}
