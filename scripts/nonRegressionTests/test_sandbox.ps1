#Requires -Version 5.1
<#
.SYNOPSIS
    Sandbox lifecycle for the VR HEADSET MANAGER non-regression test harness:
    preconditions, config seeding, app launch, readiness wait, teardown.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1.

    The sandbox IS the extracted release folder. A release deliberately ships
    no config\config.json and no data\, which would send main.ps1 into the
    interactive first-run wizard - so the harness seeds both before launching.

    Isolation comes from the FOLDER, not from the ports: the harness requires
    an exclusive run (no other VRHM instance alive), which lets the sandbox use
    the default ports. That avoids registering new firewall rules and URL ACLs,
    which would raise a UAC prompt mid-run.

    Nothing here ever writes to the dev folder. The dev data\wifi_networks.dat
    is read once, read-only, because USB onboarding needs real credentials and
    that DPAPI store is decryptable by the same user.

    ASCII only (CLAUDE.md rule 1). -LiteralPath + -Encoding UTF8 on every read,
    Write-TextFileNoBom on every write (CLAUDE.md rule 5).
#>

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
function Get-SandboxPaths {
    <#
    .SYNOPSIS
        Returns every path the harness needs inside the target release folder.
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    return @{
        Root            = $TargetRoot
        MainPs1         = Join-Path $TargetRoot 'main.ps1'
        ConfigFolder    = Join-Path $TargetRoot 'config'
        ConfigFile      = Join-Path $TargetRoot 'config\config.json'
        TemplateConfig  = Join-Path $TargetRoot 'templates\config\config.json'
        DataFolder      = Join-Path $TargetRoot 'data'
        KnownHeadsets   = Join-Path $TargetRoot 'data\known_headsets.csv'
        HeadsetsInfos   = Join-Path $TargetRoot 'data\known_headsets_infos.csv'
        ComputerMonJson = Join-Path $TargetRoot 'data\computer_monitoring.json'
        WebServerPid    = Join-Path $TargetRoot 'data\webserver.pid'
        MediaMtxPid     = Join-Path $TargetRoot 'data\mediamtx.pid'
        DashboardPid    = Join-Path $TargetRoot 'data\dashboard.pid'
        ShutdownFlag    = Join-Path $TargetRoot 'data\shutdown.flag'
        ReaperExitFlag  = Join-Path $TargetRoot 'data\reaper_exit.flag'
        WifiStore       = Join-Path $TargetRoot 'data\wifi_networks.dat'
        LogsFolder      = Join-Path $TargetRoot 'logs'
        SourcesFolder   = Join-Path $TargetRoot 'sources'
        WebsiteFolder   = Join-Path $TargetRoot 'website'
        GeneratedFolder = Join-Path $TargetRoot 'website\generated'
        RecordFolder    = Join-Path $TargetRoot 'data\test_records'
        ScriptsFolder   = Join-Path $TargetRoot 'scripts'
    }
}

function Read-JsonFileUtf8 {
    <#
    .SYNOPSIS
        Reads a UTF-8 (no-BOM) JSON file and returns the parsed object, or
        $null when missing/unparsable. Strips a BOM if one is present.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Ports and processes
# ---------------------------------------------------------------------------
function Test-SandboxPortFree {
    <#
    .SYNOPSIS
        $true when nothing is listening on the given local TCP port.
    #>
    param([Parameter(Mandatory = $true)][int]$Port)

    try {
        $listening = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        return ($listening.Count -eq 0)
    }
    catch {
        # Fall back to a connect probe when the NetTCPIP module is unavailable.
        return (-not (Test-SandboxTcpPort -ComputerName '127.0.0.1' -Port $Port -TimeoutMs 300))
    }
}

function Get-SandboxPortOwner {
    <#
    .SYNOPSIS
        Returns "<name> (PID n)" for whoever is listening on -Port, else ''.
    #>
    param([Parameter(Mandatory = $true)][int]$Port)

    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $conn) { return '' }
        $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) { return ("{0} (PID {1})" -f $proc.ProcessName, $proc.Id) }
        return ("PID {0}" -f $conn.OwningProcess)
    }
    catch {
        return ''
    }
}

function Test-SandboxTcpPort {
    <#
    .SYNOPSIS
        Raw TCP connect probe. Deliberately TCP and not HTTP: the app's web
        server request loop is single-threaded and some endpoints block for
        minutes, exactly as Get-WebServerProcess documents in scripts_init.ps1.
    #>
    param(
        [string]$ComputerName = '127.0.0.1',
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 800
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-VrmProcessInventory {
    <#
    .SYNOPSIS
        Every process that belongs to a VR HEADSET MANAGER instance, anywhere
        on the machine. Used both for the exclusive-run precondition and for
        the orphan scan after shutdown.

    .PARAMETER UnderRoot
        When given, only processes whose command line references that folder
        are returned (used to scope teardown to the sandbox).
    #>
    param([string]$UnderRoot = '')

    $found = New-Object System.Collections.Generic.List[object]

    try {
        $psProcs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue)
        foreach ($p in $psProcs) {
            if ($p.ProcessId -eq $PID) { continue }
            $cmd = $p.CommandLine
            if (-not $cmd) { continue }

            $role = ''
            if ($cmd -match 'main\.ps1')                { $role = 'main' }
            elseif ($cmd -match 'web_server\.ps1')      { $role = 'webserver' }
            elseif ($cmd -match 'reaper\.ps1')          { $role = 'reaper' }
            elseif ($cmd -match 'headsets_dashboard\.ps1') { $role = 'dashboard' }
            if (-not $role) { continue }

            if ($UnderRoot -and ($cmd -notlike "*$UnderRoot*")) { continue }

            $found.Add([PSCustomObject]@{
                Role = $role; Id = $p.ProcessId; Name = $p.Name; CommandLine = $cmd
            }) | Out-Null
        }

        foreach ($name in @('mediamtx', 'scrcpy', 'ffmpeg', 'adb')) {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name = '$name.exe'" -ErrorAction SilentlyContinue)
            foreach ($p in $procs) {
                $path = $p.ExecutablePath
                if ($UnderRoot) {
                    $matchesRoot = ($path -and $path -like "*$UnderRoot*") -or ($p.CommandLine -and $p.CommandLine -like "*$UnderRoot*")
                    if (-not $matchesRoot) { continue }
                }
                $found.Add([PSCustomObject]@{
                    Role = $name; Id = $p.ProcessId; Name = $p.Name; CommandLine = $p.CommandLine
                }) | Out-Null
            }
        }
    }
    catch { }

    return $found
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
function Test-SandboxPreconditions {
    <#
    .SYNOPSIS
        Verifies the machine is ready for an exclusive sandbox run. Prints one
        PASS/FAIL line per check. Returns $false if anything blocks.

    .DESCRIPTION
        Checks, in order:
          1. target folder looks like a VRHM install
          2. no other VRHM instance is alive anywhere (main.ps1 refuses to
             start quietly otherwise - it blocks on "Start anyway? [Y/N]")
          3. the default ports are free
          4. adb.exe exists where the template config says it does
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    Write-Host ''
    Write-Host '=== Preconditions ===' -ForegroundColor Cyan

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot
    $ok = $true

    # 1. Target sanity
    if (Test-Path -LiteralPath $paths.MainPs1) {
        Write-Host '  [PASS] Target contains main.ps1' -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] Target has no main.ps1: $($paths.MainPs1)" -ForegroundColor Red
        $ok = $false
    }

    # 2. Exclusive run
    $running = @(Get-VrmProcessInventory)
    $blockers = @($running | Where-Object { $_.Role -in @('main', 'webserver', 'reaper', 'dashboard', 'mediamtx', 'scrcpy') })
    if ($blockers.Count -eq 0) {
        Write-Host '  [PASS] No other VR HEADSET MANAGER instance is running' -ForegroundColor Green
    }
    else {
        Write-Host '  [FAIL] Another VR HEADSET MANAGER instance is running:' -ForegroundColor Red
        foreach ($b in $blockers) {
            Write-Host ("         {0,-10} PID {1}" -f $b.Role, $b.Id) -ForegroundColor DarkGray
        }
        Write-Host '         Close the dev app (menu option 0) and re-run.' -ForegroundColor DarkGray
        Write-Host '         The harness needs an exclusive run so the sandbox can use the' -ForegroundColor DarkGray
        Write-Host '         default ports without triggering firewall/UAC prompts.' -ForegroundColor DarkGray
        $ok = $false
    }

    # 3. Ports
    $template = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    if ($null -eq $template) {
        Write-Host "  [FAIL] Cannot read template config: $($paths.TemplateConfig)" -ForegroundColor Red
        return $false
    }

    $portChecks = @(
        @{ Name = 'WebServer';      Port = [int]$template.WebServer.port }
        @{ Name = 'mediamtx RTSP';  Port = [int]$template.mediamtx.rtsp_port }
        @{ Name = 'mediamtx HLS';   Port = [int]$template.mediamtx.hls_port }
        @{ Name = 'mediamtx WebRTC';Port = [int]$template.mediamtx.webrtc_port }
        @{ Name = 'mediamtx API';   Port = [int]$template.mediamtx.api_port }
    )
    foreach ($check in $portChecks) {
        if (Test-SandboxPortFree -Port $check.Port) {
            Write-Host ("  [PASS] Port {0} free ({1})" -f $check.Port, $check.Name) -ForegroundColor Green
        }
        else {
            $owner = Get-SandboxPortOwner -Port $check.Port
            Write-Host ("  [FAIL] Port {0} in use by {1} ({2})" -f $check.Port, $owner, $check.Name) -ForegroundColor Red
            $ok = $false
        }
    }

    # 4. adb.exe present where the SHIPPED config points - the exact drift that
    #    CLAUDE.md rule 7 records as having shipped broken once already.
    $adbPath = Join-Path (Join-Path $paths.SourcesFolder $template.ADB.folder) 'adb.exe'
    if (Test-Path -LiteralPath $adbPath) {
        Write-Host '  [PASS] adb.exe found at the path the shipped config points to' -ForegroundColor Green
    }
    else {
        Write-Host "  [FAIL] adb.exe not found at: $adbPath" -ForegroundColor Red
        Write-Host '         templates\config\config.json ADB.folder does not match sources\.' -ForegroundColor DarkGray
        $ok = $false
    }

    # 5. Heads-up, not a check. Firewall rules, the URL ACL and the Defender
    #    exclusion are all keyed on the PROGRAM PATH, and a freshly extracted
    #    release is a new path - so Initialize-ComputerSetup will want to
    #    elevate once. Better to say so now than to surprise the operator with
    #    a UAC dialog in the middle of an unattended run.
    if ($ok) {
        Write-Host ''
        Write-Host '  NOTE: this release folder is a new program path, so Windows will ask' -ForegroundColor Yellow
        Write-Host '        once for elevation to register its firewall rules, URL ACL and' -ForegroundColor Yellow
        Write-Host '        Defender exclusion. Accept the UAC prompt when it appears -' -ForegroundColor Yellow
        Write-Host '        the app cannot serve or stream without it.' -ForegroundColor Yellow
    }

    return $ok
}

# ---------------------------------------------------------------------------
# Provisioning
# ---------------------------------------------------------------------------
function Initialize-SandboxConfig {
    <#
    .SYNOPSIS
        Seeds config\config.json and data\ inside the target so main.ps1 boots
        straight into the app instead of the interactive first-run wizard.

    .DESCRIPTION
        Starts from templates\config\config.json - which IS what a fresh
        install runs on, since config\ is never shipped - then applies the
        overrides a test run needs. Returns the parsed sandbox config.

    .PARAMETER DevRoot
        Dev folder to copy data\wifi_networks.dat from, when present.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$DevRoot = ''
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot

    foreach ($folder in @($paths.ConfigFolder, $paths.DataFolder, $paths.LogsFolder, $paths.GeneratedFolder, $paths.RecordFolder)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }

    $config = Read-JsonFileUtf8 -Path $paths.TemplateConfig
    if ($null -eq $config) {
        throw "Cannot read template config: $($paths.TemplateConfig)"
    }

    # --- Test overrides -----------------------------------------------------
    # Keep the browser and the dashboard window out of the way, make the
    # monitoring loop responsive, and keep recordings inside the sandbox.
    $config.WebServer.openBrowserOnStartup = $false
    $config.VRMonitor.showConsole          = $false
    $config.VRMonitor.refresh_timer        = 5
    $config.Logging.debugLevelToFile       = 'DEBUG'
    $config.Logging.debugLevelToConsole    = 'ERROR'
    $config.scrcpy.recordFolder            = $paths.RecordFolder
    $config.ComputerMonitoring.refresh_timer_sec = 15

    # VQA rewrites config.json and scrcpy profiles underneath the tests, which
    # would make streaming assertions non-deterministic. Section 60 owns those
    # settings for the duration of the run.
    $config.VideoQualityAutomation.enabled             = $false
    $config.VideoQualityAutomation.auto_apply_profiles = $false
    $config.VideoQualityAutomation.auto_apply_headsets = $false
    $config.VideoQualityAutomation.auto_apply_mediamtx = $false

    $json = $config | ConvertTo-Json -Depth 20
    Write-TextFileNoBom -Path $paths.ConfigFile -Content $json

    # --- Seed data\ ---------------------------------------------------------
    if (-not (Test-Path -LiteralPath $paths.KnownHeadsets)) {
        $header = '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"'
        Write-TextFileNoBom -Path $paths.KnownHeadsets -Content ($header + "`r`n")
    }

    # WiFi credentials: DPAPI store, same user, so a straight copy works.
    if ($DevRoot) {
        $devWifi = Join-Path $DevRoot 'data\wifi_networks.dat'
        if ((Test-Path -LiteralPath $devWifi) -and (-not (Test-Path -LiteralPath $paths.WifiStore))) {
            Copy-Item -LiteralPath $devWifi -Destination $paths.WifiStore -Force
        }
    }

    # ffmpeg is deliberately not in the release zip (~102 MB); a real first run
    # downloads it via the welcome wizard. The sandbox does the offline
    # equivalent by copying the dev folder's copy, so the streaming sections
    # have something to run. Section 10 separately asserts that the download
    # path itself ships.
    $ffmpegFolder = 'ffmpeg'
    if ($config.ffmpeg -and $config.ffmpeg.folder) { $ffmpegFolder = $config.ffmpeg.folder }
    $targetFfmpeg = Join-Path (Join-Path $paths.SourcesFolder $ffmpegFolder) 'ffmpeg.exe'

    if (-not (Test-Path -LiteralPath $targetFfmpeg) -and $DevRoot) {
        $devFfmpeg = Join-Path $DevRoot ('sources\' + $ffmpegFolder + '\ffmpeg.exe')
        if (Test-Path -LiteralPath $devFfmpeg) {
            $destFolder = Split-Path -Parent $targetFfmpeg
            if (-not (Test-Path -LiteralPath $destFolder)) {
                New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
            }
            Write-Host '  Supplying ffmpeg.exe to the sandbox (a real first run downloads it)...' -ForegroundColor DarkGray
            Copy-Item -LiteralPath $devFfmpeg -Destination $targetFfmpeg -Force
        }
        else {
            Write-Host '  WARNING: no ffmpeg.exe available - streaming sections will fail.' -ForegroundColor Yellow
        }
    }

    return $config
}

function Get-SandboxWebPort {
    <#
    .SYNOPSIS
        Web server port from the sandbox config, falling back to the template
        and then to 8080.
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot
    foreach ($candidate in @($paths.ConfigFile, $paths.TemplateConfig)) {
        $cfg = Read-JsonFileUtf8 -Path $candidate
        if ($null -ne $cfg -and $cfg.WebServer -and $cfg.WebServer.port) {
            return [int]$cfg.WebServer.port
        }
    }
    return 8080
}

# ---------------------------------------------------------------------------
# Launch / readiness / shutdown
# ---------------------------------------------------------------------------
function Start-SandboxApp {
    <#
    .SYNOPSIS
        Launches main.ps1 in the target folder and waits until every service
        is up. Returns the main Process object, or $null on timeout.

    .DESCRIPTION
        The console window is deliberately left visible and stdin is NOT
        redirected: Show-MainMenu uses [Console]::ReadKey() and
        RawUI.FlushInputBuffer(), both of which break under redirection.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [int]$TimeoutSeconds = 180
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot

    # Refuse to create a second instance. main.ps1 detects duplicates by
    # scanning for any powershell whose command line mentions main.ps1 and then
    # blocks on "Start anyway? [Y/N]", so a second launch deadlocks both.
    $existing = @(Get-VrmProcessInventory -UnderRoot $TargetRoot | Where-Object { $_.Role -eq 'main' })
    if ($existing.Count -gt 0) {
        Write-Host ("  An instance is already running (PID {0}) - not launching another." -f $existing[0].Id) -ForegroundColor Yellow
        if (Wait-SandboxReady -TargetRoot $TargetRoot -TimeoutSeconds $TimeoutSeconds) {
            return (Get-Process -Id $existing[0].Id -ErrorAction SilentlyContinue)
        }
        return $null
    }

    # Clear stale signal files so the ready-wait cannot latch onto an old run.
    foreach ($stale in @($paths.ShutdownFlag, $paths.ReaperExitFlag, $paths.WebServerPid, $paths.MediaMtxPid, $paths.DashboardPid)) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
    }

    # First boot of a NEW release folder needs one elevation: firewall rules,
    # the URL ACL and the Defender exclusion are all keyed on the program path.
    # fw_state.json is written once that has succeeded, so its absence is a
    # reliable "expect UAC" signal.
    $fwState = Join-Path $paths.DataFolder 'fw_state.json'
    if (-not (Test-Path -LiteralPath $fwState)) {
        Write-Host ''
        Write-Host '  +-------------------------------------------------------------+' -ForegroundColor Yellow
        Write-Host '  | FIRST BOOT OF THIS RELEASE FOLDER - UAC PROMPT INCOMING      |' -ForegroundColor Yellow
        Write-Host '  +-------------------------------------------------------------+' -ForegroundColor Yellow
        Write-Host '  Windows will ask once to register this folder firewall rules,' -ForegroundColor White
        Write-Host '  URL ACL and Defender exclusion. Approve it or the app cannot' -ForegroundColor White
        Write-Host '  finish starting and every later section will fail.' -ForegroundColor White
        Write-Host ''
    }

    Write-Host '  Launching the app under test...' -ForegroundColor DarkGray
    $proc = Start-Process powershell.exe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $paths.MainPs1 + '"')) `
        -PassThru

    $global:SandboxMainProcess = $proc

    if (Wait-SandboxReady -TargetRoot $TargetRoot -TimeoutSeconds $TimeoutSeconds -MainProcess $proc) {
        return $proc
    }
    return $null
}

function Wait-SandboxReady {
    <#
    .SYNOPSIS
        Polls until the app is fully up, or the timeout expires. Prints which
        service it is still waiting for so a hang is diagnosable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [int]$TimeoutSeconds = 180,
        $MainProcess = $null
    )

    $paths   = Get-SandboxPaths -TargetRoot $TargetRoot
    $webPort = Get-SandboxWebPort -TargetRoot $TargetRoot
    $config  = Read-JsonFileUtf8 -Path $paths.ConfigFile
    $wantMediaMtx = $true
    if ($null -ne $config -and $config.mediamtx) { $wantMediaMtx = [bool]$config.mediamtx.enabled }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastWaitingFor = ''
    $stalledSince = $null
    $uacHintShown = $false

    while ((Get-Date) -lt $deadline) {
        if ($MainProcess -and $MainProcess.HasExited) {
            Write-Host '  [FAIL] The app exited during startup.' -ForegroundColor Red
            return $false
        }

        $waitingFor = ''
        if (-not (Test-Path -LiteralPath $paths.WebServerPid))            { $waitingFor = 'webserver.pid' }
        elseif (-not (Test-SandboxTcpPort -Port $webPort -TimeoutMs 500)) { $waitingFor = "web server port $webPort" }
        elseif ($wantMediaMtx -and -not (Test-Path -LiteralPath $paths.MediaMtxPid)) { $waitingFor = 'mediamtx.pid' }
        elseif (-not (Test-Path -LiteralPath $paths.HeadsetsInfos))       { $waitingFor = 'known_headsets_infos.csv' }

        if (-not $waitingFor) {
            Write-Host ("  App is up (web server on port {0})." -f $webPort) -ForegroundColor DarkGray
            return $true
        }

        if ($waitingFor -ne $lastWaitingFor) {
            Write-Host ("    waiting for {0}..." -f $waitingFor) -ForegroundColor DarkGray
            $lastWaitingFor = $waitingFor
            $stalledSince = Get-Date
        }

        # A first boot that has not moved in 40s is almost always sitting on an
        # unanswered UAC dialog. Say so instead of silently burning the timeout.
        if ($null -ne $stalledSince -and ((Get-Date) - $stalledSince).TotalSeconds -gt 40 -and -not $uacHintShown) {
            $fwState = Join-Path $paths.DataFolder 'fw_state.json'
            if (-not (Test-Path -LiteralPath $fwState)) {
                Write-Host '    Still waiting. Check for a pending Windows UAC prompt and approve it.' -ForegroundColor Yellow
                $uacHintShown = $true
            }
        }

        Start-Sleep -Milliseconds 750
    }

    Write-Host ("  [FAIL] Timed out after {0}s waiting for {1}." -f $TimeoutSeconds, $lastWaitingFor) -ForegroundColor Red
    if (-not (Test-Path -LiteralPath (Join-Path $paths.DataFolder 'fw_state.json'))) {
        Write-Host '         data\fw_state.json was never written, so Initialize-ComputerSetup did not' -ForegroundColor DarkGray
        Write-Host '         complete - the elevation prompt was most likely declined or missed.' -ForegroundColor DarkGray
    }
    return $false
}

function Invoke-InTargetModules {
    <#
    .SYNOPSIS
        Runs a scriptblock with the TARGET release's modules loaded, in a child
        PowerShell, without booting the app. Returns the deserialized result.

    .DESCRIPTION
        This is the "modules for the gaps" half of the hybrid strategy: some
        behaviour has no HTTP endpoint (profile parsing, ffmpeg argument
        building, encoder probing) and must be called directly.

        The child sets $global:IsWebServerProcess = $true before dot-sourcing
        scripts_init.ps1. That is the app's own established "load the module set
        but do not boot" flag - the same one web_server.ps1, headsets_dashboard.ps1
        and headsets_monitoring.ps1 use - and it suppresses
        Confirm-AppPortsAvailable, Initialize-ComputerSetup, Start-WebServer and
        the browser launcher.

        The modules under test are always the TARGET's, never the dev folder's:
        the artifact is what is being tested.

        The scriptblock must emit an object; it is round-tripped as JSON, so
        only data survives - no live handles.

    .EXAMPLE
        $r = Invoke-InTargetModules -TargetRoot $target -Body {
            ConvertFrom-ScrcpyProfile -Profile 'max-R-D-60-10'
        }
        Assert-Equal 'max' $r.View 'parsed view'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [int]$TimeoutSeconds = 120
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot
    if (-not (Test-Path -LiteralPath $paths.ConfigFile)) {
        throw 'Invoke-InTargetModules: the sandbox config has not been provisioned yet'
    }

    $scratch = Join-Path $env:TEMP ('vrm_nrt_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $runner = Join-Path $scratch 'runner.ps1'
    $outFile = Join-Path $scratch 'out.json'

    # $ErrorActionPreference is deliberately Continue while dot-sourcing: the
    # module set prints warnings on a headless load that must not abort the run.
    $runnerText = @'
param([string]$TargetRoot, [string]$OutFile)
$global:IsWebServerProcess = $true
$ErrorActionPreference = 'Continue'
$result = [PSCustomObject]@{ Ok = $false; Value = $null; Error = '' }
try {
    Set-Location -LiteralPath $TargetRoot
    . (Join-Path $TargetRoot 'modules\scripts_init.ps1')
    $ErrorActionPreference = 'Stop'
    $value = & {
__BODY__
    }
    $result.Ok = $true
    $result.Value = $value
}
catch {
    $result.Error = $_.Exception.Message
}
$json = $result | ConvertTo-Json -Depth 12 -Compress
[System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
'@

    $runnerText = $runnerText -replace '__BODY__', $Body.ToString()
    Write-TextFileNoBom -Path $runner -Content $runnerText

    try {
        $proc = Start-Process powershell.exe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runner + '"'),
                            '-TargetRoot', ('"' + $TargetRoot + '"'), '-OutFile', ('"' + $outFile + '"')) `
            -WindowStyle Hidden -PassThru

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            throw ("Invoke-InTargetModules: timed out after {0}s" -f $TimeoutSeconds)
        }

        if (-not (Test-Path -LiteralPath $outFile)) {
            throw 'Invoke-InTargetModules: the child produced no output (module load probably failed)'
        }

        $raw = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        if (-not $parsed.Ok) {
            throw ('in target modules: ' + $parsed.Error)
        }
        return $parsed.Value
    }
    finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-SandboxApp {
    <#
    .SYNOPSIS
        Ensures the sandbox app is running, provisioning and booting it if it
        is not. Idempotent, so every section can call it and still be runnable
        on its own via -Sections.

    .DESCRIPTION
        Returns $true when the app is up. Also points the API client at the
        sandbox web server, so callers get a usable Invoke-VrmApi afterwards.

    .EXAMPLE
        if (-not (Confirm-SandboxApp -TargetRoot $target)) { Skip-Test 'app is not running' }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$DevRoot = '',
        [int]$TimeoutSeconds = 180
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot

    if (-not (Test-Path -LiteralPath $paths.ConfigFile)) {
        Initialize-SandboxConfig -TargetRoot $TargetRoot -DevRoot $DevRoot | Out-Null
    }

    $webPort = Get-SandboxWebPort -TargetRoot $TargetRoot
    if (Get-Command Set-VrmApiBase -ErrorAction SilentlyContinue) {
        Set-VrmApiBase -Port $webPort | Out-Null
    }

    $running = @(Get-VrmProcessInventory -UnderRoot $TargetRoot | Where-Object { $_.Role -eq 'main' })

    if ($running.Count -gt 0) {
        # Already up and serving - nothing to do.
        if (Test-SandboxTcpPort -Port $webPort -TimeoutMs 1000) { return $true }

        # An instance exists but is not serving yet. NEVER launch a second one:
        # main.ps1's duplicate-instance check would block the newcomer on
        # "Start anyway? [Y/N]", and two half-started instances deadlock against
        # each other. Wait for the one we already have instead.
        Write-Host '  An instance is already starting - waiting for it rather than launching another.' -ForegroundColor DarkGray
        return (Wait-SandboxReady -TargetRoot $TargetRoot -TimeoutSeconds $TimeoutSeconds)
    }

    $proc = Start-SandboxApp -TargetRoot $TargetRoot -TimeoutSeconds $TimeoutSeconds
    return ($null -ne $proc)
}

function Stop-SandboxApp {
    <#
    .SYNOPSIS
        Graceful shutdown via POST /api/app-shutdown, which the server already
        implements by injecting '0' + Enter into the main console. Falls back
        to a forced teardown if the app does not exit in time.

    .DESCRIPTION
        Returns $true when the app exited gracefully. Safe to call when nothing
        is running - it is invoked from the harness finally block.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [int]$TimeoutSeconds = 45
    )

    $mainProcs = @(Get-VrmProcessInventory -UnderRoot $TargetRoot | Where-Object { $_.Role -eq 'main' })
    if ($mainProcs.Count -eq 0) {
        Remove-SandboxArtifacts -TargetRoot $TargetRoot -Quiet
        return $true
    }

    Write-Host '  Shutting the app down...' -ForegroundColor DarkGray
    $webPort = Get-SandboxWebPort -TargetRoot $TargetRoot
    try {
        Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/app-shutdown" -f $webPort) `
            -Method POST -TimeoutSec 10 -UseBasicParsing | Out-Null
    }
    catch { }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $still = @(Get-VrmProcessInventory -UnderRoot $TargetRoot | Where-Object { $_.Role -eq 'main' })
        if ($still.Count -eq 0) {
            Start-Sleep -Seconds 2   # let the reaper finish its own cleanup
            Remove-SandboxArtifacts -TargetRoot $TargetRoot -Quiet
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    Write-Host '  Graceful shutdown timed out - forcing teardown.' -ForegroundColor Yellow
    Remove-SandboxArtifacts -TargetRoot $TargetRoot
    return $false
}

function Remove-SandboxArtifacts {
    <#
    .SYNOPSIS
        Force-kills anything still alive under the target folder and clears its
        pid files and signal flags. Used as the last-resort teardown and by
        Invoke-NonRegressionTests.ps1 -RestoreOnly after a crashed run.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [switch]$Quiet
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot

    $leftovers = @(Get-VrmProcessInventory -UnderRoot $TargetRoot)
    foreach ($p in $leftovers) {
        if (-not $Quiet) {
            Write-Host ("    killing leftover {0} (PID {1})" -f $p.Role, $p.Id) -ForegroundColor DarkGray
        }
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }

    foreach ($f in @($paths.WebServerPid, $paths.MediaMtxPid, $paths.DashboardPid, $paths.ShutdownFlag, $paths.ReaperExitFlag)) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    $global:SandboxMainProcess = $null
}

function Test-SandboxIsReleaseFolder {
    <#
    .SYNOPSIS
        Safety gate for Reset-SandboxTarget. Returns $true only when TargetRoot is
        an extracted RELEASE folder that is safe to wipe back to pristine.

    .DESCRIPTION
        Two independent guards, both must hold:
          - the target is not the dev folder (compared as resolved full paths)
          - the target has no scripts\ folder - releases never ship one
            (Create-ZipRelease.ps1 hard-excludes it, and section 10 asserts it),
            so its presence means we are looking at a dev tree
        This exists because -Force lets TargetRoot point at the dev folder, and
        wiping data\ + logs\ there would destroy the operator's real registry.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$DevRoot = ''
    )

    if ($DevRoot) {
        $t = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
        $d = [System.IO.Path]::GetFullPath($DevRoot).TrimEnd('\')
        if ($t -eq $d) { return $false }
    }

    if (Test-Path -LiteralPath (Join-Path $TargetRoot 'scripts')) { return $false }

    return $true
}

function Reset-SandboxTarget {
    <#
    .SYNOPSIS
        Restores an extracted release folder to its pristine, just-unzipped state
        by deleting everything the harness seeded and the app generated.

    .DESCRIPTION
        Without this, a target can only be tested ONCE: Initialize-SandboxConfig
        seeds config\config.json and data\, and section 10's packaging assertions
        ("No personal data shipped in the release") then fail on every re-run
        against that same folder - they are only meaningful on a clean extraction.

        Removes: config\config.json, config\mediamtx_headsets.yml, data\, logs\,
        and the contents of website\generated\. All of these are created at
        runtime; a release ships none of them.

        Deliberately does NOT remove sources\ffmpeg\ffmpeg.exe. The sandbox copies
        it in (a real first run downloads it), it is ~102 MB, and section 10's
        ffmpeg assertion passes whether or not it is present - so re-copying it on
        every run would be pure cost.

        No-ops with a warning when Test-SandboxIsReleaseFolder rejects the target.

    .EXAMPLE
        Reset-SandboxTarget -TargetRoot $target -DevRoot $devRoot
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$DevRoot = '',
        [switch]$Quiet
    )

    if (-not (Test-SandboxIsReleaseFolder -TargetRoot $TargetRoot -DevRoot $DevRoot)) {
        if (-not $Quiet) {
            Write-Host '  Sandbox reset SKIPPED - target is not an extracted release folder.' -ForegroundColor Yellow
        }
        return $false
    }

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot

    $files = @(
        $paths.ConfigFile
        (Join-Path $TargetRoot 'config\mediamtx_headsets.yml')
    )
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    # data\fw_state.json survives the reset on purpose. It is the app's record of
    # the firewall rules / URL ACL / Defender exclusion it already applied for
    # THIS folder. Deleting it makes Initialize-ComputerSetup see drift on the
    # next run and raise a UAC prompt plus an interactive elevated console every
    # single time - which is exactly what an unattended harness must not do.
    # Section 10 only asserts that data\*.csv are absent, so keeping this one
    # JSON does not weaken the packaging check.
    $keep = $null
    $fwState = Join-Path $paths.DataFolder 'fw_state.json'
    if (Test-Path -LiteralPath $fwState) {
        try { $keep = Get-Content -LiteralPath $fwState -Raw -Encoding UTF8 } catch { }
    }

    foreach ($folder in @($paths.DataFolder, $paths.LogsFolder)) {
        if (Test-Path -LiteralPath $folder) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -ne $keep) {
        try {
            New-Item -ItemType Directory -Path $paths.DataFolder -Force | Out-Null
            [System.IO.File]::WriteAllText($fwState, $keep, [System.Text.UTF8Encoding]::new($false))
        }
        catch { }
    }

    # Keep website\generated\ itself - only its runtime contents are ours.
    if (Test-Path -LiteralPath $paths.GeneratedFolder) {
        Get-ChildItem -LiteralPath $paths.GeneratedFolder -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (-not $Quiet) {
        Write-Host '  Sandbox reset - target restored to its just-extracted state.' -ForegroundColor DarkGray
    }
    return $true
}
