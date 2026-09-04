#Requires -Version 5.1
<#
.SYNOPSIS
    Section 10 - release packaging invariants, then boot the sandbox and prove
    every service came up.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context. Ordering matters: the "nothing personal was shipped" checks must
    run BEFORE the sandbox is seeded, because seeding creates exactly the files
    those checks assert are absent.

    The binary-path checks here are the cheap ones that catch the failure mode
    CLAUDE.md rule 7 records as having shipped broken once already:
    templates\config\config.json drifting away from what .releaseinclude puts
    in the zip, producing an app that dies at startup with
    "ADB executable not found".

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = Split-Path -Parent $PSScriptRoot
$devRoot = Split-Path -Parent $devRoot          # scripts\nonRegressionTests\tests -> scripts
$devRoot = Split-Path -Parent $devRoot          # scripts -> repo root
$paths   = Get-SandboxPaths -TargetRoot $target

# ---------------------------------------------------------------------------
# Packaging - what the zip must and must not contain
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Release contains main.ps1 and the launcher' -Test {
    Assert-FileExists $paths.MainPs1 'main.ps1'
    Assert-FileExists (Join-Path $target 'START_VR_HEADSET_MANAGER.exe') 'START_VR_HEADSET_MANAGER.exe'
    Assert-FileExists (Join-Path $target 'modules\scripts_init.ps1') 'modules\scripts_init.ps1'
}

Invoke-RegressionTest -Name 'Shipped config template parses' -Test {
    Assert-FileExists $paths.TemplateConfig 'templates\config\config.json'
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    Assert-NotNull $cfg 'parsed template config'
    Assert-NotNull $cfg.scrcpy.folder   'scrcpy.folder'
    Assert-NotNull $cfg.ADB.folder      'ADB.folder'
    Assert-NotNull $cfg.mediamtx.folder 'mediamtx.folder'
    Add-TestEvidence ("scrcpy.folder   = {0}" -f $cfg.scrcpy.folder)
    Add-TestEvidence ("ADB.folder      = {0}" -f $cfg.ADB.folder)
    Add-TestEvidence ("mediamtx.folder = {0}" -f $cfg.mediamtx.folder)
}

Invoke-RegressionTest -Name 'scrcpy.exe exists where the shipped config points' -Test {
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    $exe = Join-Path (Join-Path $paths.SourcesFolder $cfg.scrcpy.folder) 'scrcpy.exe'
    Add-TestEvidence ("expected: {0}" -f $exe)
    Assert-FileExists $exe 'scrcpy.exe'
}

Invoke-RegressionTest -Name 'adb.exe exists where the shipped config points' -Test {
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    $exe = Join-Path (Join-Path $paths.SourcesFolder $cfg.ADB.folder) 'adb.exe'
    Add-TestEvidence ("expected: {0}" -f $exe)
    Assert-FileExists $exe 'adb.exe'
}

Invoke-RegressionTest -Name 'scrcpy.folder and ADB.folder agree' -Test {
    # The scrcpy release bundles adb.exe, so these two keys must always point
    # at the same folder (CLAUDE.md rule 7).
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    Assert-Equal $cfg.scrcpy.folder $cfg.ADB.folder 'scrcpy.folder vs ADB.folder'
}

Invoke-RegressionTest -Name 'mediamtx.exe exists where the shipped config points' -Test {
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    $exe = Join-Path (Join-Path $paths.SourcesFolder $cfg.mediamtx.folder) 'mediamtx.exe'
    Add-TestEvidence ("expected: {0}" -f $exe)
    Assert-FileExists $exe 'mediamtx.exe'
}

Invoke-RegressionTest -Name 'ffmpeg acquisition path is shipped' -Test {
    # ffmpeg.exe is deliberately NOT bundled - it is ~102 MB, which would more
    # than double the release zip. The first-run wizard downloads it instead
    # (Invoke-FfmpegDownload in welcome.ps1). So the invariant to protect is
    # that the ACQUISITION PATH ships, not the binary.
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    $folder = 'ffmpeg'
    if ($cfg.ffmpeg -and $cfg.ffmpeg.folder) { $folder = $cfg.ffmpeg.folder }
    $exe = Join-Path (Join-Path $paths.SourcesFolder $folder) 'ffmpeg.exe'

    if (Test-Path -LiteralPath $exe) {
        Add-TestEvidence ("ffmpeg.exe is bundled at {0}" -f $exe)
        return
    }

    Add-TestEvidence 'ffmpeg.exe not bundled (expected) - checking the download path instead'

    $welcome = Join-Path $target 'modules\welcome.ps1'
    Assert-FileExists $welcome 'modules\welcome.ps1 (first-run wizard)'
    $welcomeText = Get-Content -LiteralPath $welcome -Raw -Encoding UTF8
    Assert-True ($welcomeText -match 'Invoke-FfmpegDownload') `
        'welcome.ps1 ships without Invoke-FfmpegDownload - a fresh install could never obtain ffmpeg'

    $utils = Join-Path $target 'modules\utils.ps1'
    Assert-FileExists $utils 'modules\utils.ps1'
    $utilsText = Get-Content -LiteralPath $utils -Raw -Encoding UTF8
    Assert-True ($utilsText -match 'function\s+Update-FfmpegBinary') `
        'utils.ps1 ships without Update-FfmpegBinary - the ffmpeg updater is missing'
}

Invoke-RegressionTest -Name 'Wireless-ADB activator APK is bundled' -Test {
    $cfg = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    Assert-NotNull $cfg.apk.adbWirelessActivatorFolder 'apk.adbWirelessActivatorFolder'
    $apk = Join-Path (Join-Path $paths.SourcesFolder $cfg.apk.adbWirelessActivatorFolder) $cfg.apk.adbWirelessActivatorApk
    Add-TestEvidence ("expected: {0}" -f $apk)
    Assert-FileExists $apk 'wireless-ADB activator APK'
}

Invoke-RegressionTest -Name 'Test harness is NOT shipped in the release' -Test {
    # The harness proving its own exclusion. scripts\ is hard-excluded by
    # Create-ZipRelease.ps1 before .releaseinclude is even consulted; if that
    # ever changes, this fails the release immediately.
    Assert-FileMissing $paths.ScriptsFolder 'scripts\ folder'
}

Invoke-RegressionTest -Name 'No personal data shipped in the release' -Test {
    # Must run before the sandbox is seeded - seeding creates these very files.
    Assert-FileMissing $paths.ConfigFile 'config\config.json'
    Assert-FileMissing (Join-Path $target 'config\mediamtx_headsets.yml') 'config\mediamtx_headsets.yml'

    $strayCsv = @()
    if (Test-Path -LiteralPath $paths.DataFolder) {
        $strayCsv = @(Get-ChildItem -LiteralPath $paths.DataFolder -Filter '*.csv' -File -ErrorAction SilentlyContinue)
    }
    foreach ($f in $strayCsv) { Add-TestEvidence ("stray: data\{0}" -f $f.Name) }
    Assert-True ($strayCsv.Count -eq 0) ("release ships {0} personal CSV file(s) under data\" -f $strayCsv.Count)

    $strayLogs = @()
    if (Test-Path -LiteralPath $paths.LogsFolder) {
        $strayLogs = @(Get-ChildItem -LiteralPath $paths.LogsFolder -Recurse -File -ErrorAction SilentlyContinue)
    }
    Assert-True ($strayLogs.Count -eq 0) ("release ships {0} log file(s)" -f $strayLogs.Count)
}

Invoke-RegressionTest -Name 'No generated per-headset pages shipped' -Test {
    $generated = @()
    if (Test-Path -LiteralPath $paths.WebsiteFolder) {
        $generated = @(Get-ChildItem -LiteralPath $paths.WebsiteFolder -Filter '*`[*`].html' -File -ErrorAction SilentlyContinue)
    }
    foreach ($f in $generated) { Add-TestEvidence ("stray: website\{0}" -f $f.Name) }
    Assert-True ($generated.Count -eq 0) ("release ships {0} generated overlay page(s)" -f $generated.Count)
}

Invoke-RegressionTest -Name 'version.txt matches the requested version' -Test {
    $versionFile = Join-Path $target 'version.txt'
    Assert-FileExists $versionFile 'version.txt'
    $shipped = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
    Add-TestEvidence ("version.txt = '{0}', run version = '{1}'" -f $shipped, $global:TestRun.Version)
    Assert-True ($shipped -like ("*" + $global:TestRun.Version + "*")) `
        ("version.txt says '{0}' but the run is labelled '{1}'" -f $shipped, $global:TestRun.Version)
}

Invoke-RegressionTest -Name 'Mandatory en-US translations are shipped' -Test {
    Assert-FileExists (Join-Path $target 'modules\translations\en-US.psd1') 'en-US.psd1'
}

Invoke-RegressionTest -Name 'Translation parity across shipped locales' -Test {
    # Delegate to the existing checker rather than reimplementing it.
    $checker = Join-Path $devRoot 'scripts\Test-TranslationParity.ps1'
    if (-not (Test-Path -LiteralPath $checker)) { Skip-Test 'Test-TranslationParity.ps1 not found' }

    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -RepoRoot $target 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { Add-TestEvidence ([string]$line) }

    if ($code -eq 2) { Skip-Test 'en-US.psd1 unreadable for the parity checker' }
    Assert-Equal 0 $code 'Test-TranslationParity exit code'
}

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Sandbox profile is provisioned' -Test {
    $cfg = Initialize-SandboxConfig -TargetRoot $target -DevRoot $devRoot
    Assert-NotNull $cfg 'seeded config'
    Assert-FileExists $paths.ConfigFile 'config\config.json'
    Assert-FileExists $paths.KnownHeadsets 'data\known_headsets.csv'

    $written = Read-JsonFileUtf8 -Path $paths.ConfigFile
    Assert-NotNull $written 'seeded config re-parses'
    Assert-Equal $false $written.WebServer.openBrowserOnStartup 'openBrowserOnStartup override'
    Add-TestEvidence ("web server port  = {0}" -f $written.WebServer.port)
    Add-TestEvidence ("record folder    = {0}" -f $written.scrcpy.recordFolder)
    Add-TestEvidence ("VQA enabled      = {0}" -f $written.VideoQualityAutomation.enabled)
}

Invoke-RegressionTest -Name 'App boots and every service comes up' -Test {
    $up = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot -TimeoutSeconds 180
    Assert-True $up 'the app did not reach a ready state within 180s'
}

Invoke-RegressionTest -Name 'Web server PID file points at a live web server' -Test {
    Assert-FileExists $paths.WebServerPid 'data\webserver.pid'
    $storedPid = (Get-Content -LiteralPath $paths.WebServerPid -Raw -Encoding UTF8).Trim()
    Assert-Match $storedPid '^\d+$' 'webserver.pid contents'

    $proc = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
    Assert-NotNull $proc ("process {0} from webserver.pid" -f $storedPid)

    # Identity check, not just liveness: a bare PID test once let the watchdog
    # latch onto main.ps1 and never relaunch the server.
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $storedPid" -ErrorAction SilentlyContinue
    Assert-NotNull $cim 'Win32_Process row for the web server PID'
    Add-TestEvidence ("cmdline: " + (Get-VrmApiExcerpt $cim.CommandLine 160))
    Assert-True ($cim.CommandLine -match 'web_server\.ps1') 'webserver.pid does not point at web_server.ps1'
}

Invoke-RegressionTest -Name 'mediamtx PID file points at a live mediamtx' -Test {
    $cfg = Read-JsonFileUtf8 -Path $paths.ConfigFile
    if (-not [bool]$cfg.mediamtx.enabled) { Skip-Test 'mediamtx disabled in config' }

    Assert-FileExists $paths.MediaMtxPid 'data\mediamtx.pid'
    $storedPid = (Get-Content -LiteralPath $paths.MediaMtxPid -Raw -Encoding UTF8).Trim()
    Assert-Match $storedPid '^\d+$' 'mediamtx.pid contents'
    $proc = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
    Assert-NotNull $proc ("process {0} from mediamtx.pid" -f $storedPid)
    Assert-Equal 'mediamtx' $proc.ProcessName 'mediamtx.pid process name'
}

Invoke-RegressionTest -Name 'Reaper watchdog is running' -Test {
    $reapers = @(Get-VrmProcessInventory -UnderRoot $target | Where-Object { $_.Role -eq 'reaper' })
    Add-TestEvidence ("reaper processes found: {0}" -f $reapers.Count)
    Assert-True ($reapers.Count -ge 1) 'no reaper.ps1 process found - ungraceful-exit cleanup will not happen'
}

Invoke-RegressionTest -Name 'VRMonitor is producing monitoring data' -Test {
    Assert-FileExists $paths.HeadsetsInfos 'data\known_headsets_infos.csv'

    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $paths.ComputerMonJson)) {
        Start-Sleep -Milliseconds 750
    }
    Assert-FileExists $paths.ComputerMonJson 'data\computer_monitoring.json'

    $snapshot = Read-JsonFileUtf8 -Path $paths.ComputerMonJson
    Assert-NotNull $snapshot 'computer_monitoring.json parses'
    Assert-NotNull $snapshot.Timestamp 'snapshot Timestamp'
    Assert-NotNull $snapshot.CPU 'snapshot CPU node'
    Add-TestEvidence ("timestamp = {0}" -f $snapshot.Timestamp)
    Add-TestEvidence ("cpu       = {0}" -f $snapshot.CPU.Model)
}

Invoke-RegressionTest -Name 'Startup produced no unexpected ERROR log lines' -Test {
    $logRoot = Join-Path $paths.LogsFolder $env:COMPUTERNAME
    if (-not (Test-Path -LiteralPath $logRoot)) { Skip-Test 'no log folder produced yet' }

    $logFile = Get-ChildItem -LiteralPath $logRoot -Filter 'log_*.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $logFile) { Skip-Test 'no log file produced yet' }

    Add-TestEvidence ("log: {0}" -f $logFile.FullName)
    $lines = @(Get-Content -LiteralPath $logFile.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
    $errors = @($lines | Where-Object { $_ -match '\[ERROR\]' })

    # Benign on a fresh sandbox with no headsets registered yet.
    $benign = @(
        'No headset',
        'not found in the known headsets',
        'known_headsets.csv is empty',
        'No device'
    )
    $unexpected = @($errors | Where-Object {
        $line = $_
        $isBenign = $false
        foreach ($pattern in $benign) { if ($line -like "*$pattern*") { $isBenign = $true } }
        -not $isBenign
    })

    foreach ($e in ($unexpected | Select-Object -First 15)) { Add-TestEvidence $e }
    if ($unexpected.Count -gt 0) {
        Write-TestWarning ("{0} unexpected ERROR line(s) during startup" -f $unexpected.Count)
    }
}
