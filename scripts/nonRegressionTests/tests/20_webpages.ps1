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

Invoke-RegressionTest -Name 'data\ route serves monitoring JSON' -Test {
    $r = Invoke-VrmApi -Path '/data/computer_monitoring.json'
    Assert-Equal 200 $r.StatusCode 'GET /data/computer_monitoring.json'
    Assert-NotNull $r.Json 'computer_monitoring.json parses over HTTP'
}

Invoke-RegressionTest -Name 'data\ route refuses non-CSV/JSON extensions' -Test {
    $r = Invoke-VrmApi -Path '/data/webserver.pid'
    Add-TestEvidence ("GET /data/webserver.pid -> HTTP {0}" -f $r.StatusCode)
    Assert-True ($r.StatusCode -eq 403 -or $r.StatusCode -eq 404) `
        ("expected 403/404 for a non-whitelisted extension, got {0}" -f $r.StatusCode)
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

Invoke-RegressionTest -Name '/api/headsets matches known_headsets.csv' -Test {
    $r = Invoke-VrmApi -Path '/api/headsets'
    Assert-True $r.Ok 'GET /api/headsets'

    $api = @($r.Json)
    $csv = @(Import-Csv -LiteralPath $paths.KnownHeadsets -Encoding UTF8)
    Add-TestEvidence ("api rows={0}  csv rows={1}" -f $api.Count, $csv.Count)
    Assert-Equal $csv.Count $api.Count 'headset row count'

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
    $csv = @(Import-Csv -LiteralPath $paths.KnownHeadsets -Encoding UTF8)
    Assert-Equal $csv.Count $api.Count 'status row count'

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

Invoke-RegressionTest -Name '/api/appnames returns the known-apps catalog' -Test {
    $r = Invoke-VrmApi -Path '/api/appnames'
    Assert-Equal 200 $r.StatusCode 'GET /api/appnames'
    $apps = @($r.Json.apps)
    Add-TestEvidence ("catalog holds {0} app(s)" -f $apps.Count)
    Assert-True ($apps.Count -gt 0) 'known-apps catalog is empty - templates\data\known_apps.csv may not be shipped'
}
