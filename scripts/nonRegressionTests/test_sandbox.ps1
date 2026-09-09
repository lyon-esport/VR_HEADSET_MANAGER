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
        Database        = Join-Path $TargetRoot 'data\vrhm.db'
    }
}

function Get-SandboxDbRows {
    <#
    .SYNOPSIS
        Runs a read-only query against the target install's vrhm.db and returns
        the rows as PSCustomObjects. @() on any failure.
    .DESCRIPTION
        The harness used to read data\*.csv directly. Those files are gone: the
        registry, live status, kiosks, timers, apps and snapshots are all tables
        now. This is the replacement, and it deliberately does NOT dot-source the
        application's database.ps1 - the harness must observe the app from the
        outside, exactly as it did when it parsed the app's CSV output.

        Opened Read Only against a WAL database, so it never blocks the running
        application and the application never blocks it. Pooling is off so the
        file handle is released the moment the connection closes, which matters
        because Reset-SandboxTarget deletes the whole data folder afterwards.
    .EXAMPLE
        Get-SandboxDbRows -TargetRoot $root -Sql 'SELECT * FROM v_headsets ORDER BY SortOrder;'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Sql,
        [hashtable]$Parameters
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot
    if (-not (Test-Path -LiteralPath $paths.Database)) { return @() }

    $dllFolder = Join-Path $paths.SourcesFolder 'sqlite\System.Data.SQLite-1.0.119'
    $dll       = Join-Path $dllFolder 'System.Data.SQLite.dll'
    if (-not (Test-Path -LiteralPath $dll)) { return @() }

    $connection = $null
    try {
        # SQLite.Interop.dll is found through this, not through the PATH.
        $env:PreLoadSQLite_BaseDirectory = $dllFolder
        [void][Reflection.Assembly]::LoadFrom($dll)

        $cs = "Data Source=`"{0}`";Version=3;Read Only=True;Pooling=False;" -f $paths.Database
        $connection = New-Object System.Data.SQLite.SQLiteConnection $cs
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        if ($Parameters) {
            foreach ($key in $Parameters.Keys) {
                $name  = if ([string]$key -like '@*') { [string]$key } else { '@' + [string]$key }
                $value = $Parameters[$key]
                if ($null -eq $value) { $value = [DBNull]::Value }
                [void]$command.Parameters.AddWithValue($name, $value)
            }
        }

        $reader = $command.ExecuteReader()
        $rows   = New-Object System.Collections.Generic.List[object]
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $value = $reader.GetValue($i)
                if ($value -is [DBNull]) { $value = $null }
                $row[$reader.GetName($i)] = $value
            }
            $rows.Add([PSCustomObject]$row) | Out-Null
        }
        $reader.Close()
        $command.Dispose()
        return $rows.ToArray()
    }
    catch { return @() }
    finally {
        if ($connection) {
            try { $connection.Close() } catch { }
            try { $connection.Dispose() } catch { }
        }
    }
}

function Get-SandboxFwStateJson {
    <#
    .SYNOPSIS
        The app's persisted firewall/URL-ACL/Defender state as raw JSON text,
        or $null when it has never been written.
    .DESCRIPTION
        This used to be data\fw_state.json. It is the app_kv row 'fw_state' now
        (ADR-0017), which matters to this harness for one reason: it is the
        app's record that it has ALREADY registered the firewall rules, the URL
        ACL and the Defender exclusion for this folder path. Without it,
        Initialize-ComputerSetup raises a UAC prompt and an elevated console on
        every boot, and an unattended run simply hangs there until it times out.
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $rows = @(Get-SandboxDbRows -TargetRoot $TargetRoot -Sql "SELECT value_json FROM app_kv WHERE key = 'fw_state';")
    if ($rows.Count -eq 0) { return $null }
    $value = [string]$rows[0].value_json
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Restore-SandboxFwStateJson {
    <#
    .SYNOPSIS
        Recreates the target's database and writes the fw_state row back into it.
    .DESCRIPTION
        Called by Reset-SandboxTarget after the data folder has been wiped, so
        the next boot does not demand a fresh elevation. The row has to exist
        BEFORE the app starts, because the app reads it during its own startup -
        there is no window between the app creating the database and reading the
        value in which the harness could inject it.

        Runs in a short-lived process using the TARGET's own modules\database.ps1
        and its public API, so the row is written exactly the way the app writes
        it. The side effect is that the database and its schema exist before the
        first boot; the app opening an existing database is the normal case
        anyway, and the create-from-nothing path is covered by the Failure layer
        of the database suite.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$ValueJson
    )

    $paths = Get-SandboxPaths -TargetRoot $TargetRoot
    $dbModule = Join-Path $TargetRoot 'modules\database.ps1'
    if (-not (Test-Path -LiteralPath $dbModule)) { return $false }

    $valueFile  = Join-Path ([System.IO.Path]::GetTempPath()) ("vrhm_fwstate_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("vrhm_fwrestore_{0}.ps1" -f ([guid]::NewGuid().ToString('N')))

    $bootstrap = @'
param([string]$Root, [string]$ValueFile)
$ErrorActionPreference = 'Stop'
$global:ScriptPath              = $Root
$global:databaseFolder          = Join-Path $Root 'sources\sqlite\System.Data.SQLite-1.0.119'
$global:databaseAssemblyPath    = Join-Path $global:databaseFolder 'System.Data.SQLite.dll'
$global:databaseInteropPath     = Join-Path (Join-Path $global:databaseFolder 'x64') 'SQLite.Interop.dll'
$global:databaseFilePath        = Join-Path (Join-Path $Root 'data') 'vrhm.db'
$global:databaseBusyTimeoutMs   = 5000
$global:databaseRetryMax        = 6
$global:databaseIntegrityCheck  = 'quick'
$global:databaseBackupKeep      = 3
$global:databaseBackupOnStartup = $false
$global:debugLevelToConsole     = 'NONE'
$global:debugLevelToFile        = 'NONE'
$global:logFile                 = Join-Path (Join-Path $Root 'logs') 'fwrestore.log'
. (Join-Path $Root 'modules\logging.ps1')
. (Join-Path $Root 'modules\database.ps1')
Initialize-Database -Role Main -SkipBackup | Out-Null
$json = [System.IO.File]::ReadAllText($ValueFile, [System.Text.Encoding]::UTF8)
Set-DbKeyValue -Key 'fw_state' -Value $json
Close-DbConnection -Checkpoint
'@

    try {
        [System.IO.File]::WriteAllText($valueFile, $ValueJson, (New-Object System.Text.UTF8Encoding $false))
        [System.IO.File]::WriteAllText($scriptFile, $bootstrap, (New-Object System.Text.UTF8Encoding $false))

        $bootstrapArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $scriptFile),
                           '-Root', ('"{0}"' -f $TargetRoot), '-ValueFile', ('"{0}"' -f $valueFile))
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $bootstrapArgs -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -ne 0) { return $false }
        return (Test-Path -LiteralPath $paths.Database)
    }
    catch { return $false }
    finally {
        foreach ($f in @($valueFile, $scriptFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-SandboxHeadsets {
    <#
    .SYNOPSIS
        Every registry row of the target install, in display order, with the
        legacy CSV column names. The replacement for
        Import-Csv data\known_headsets.csv.
    .EXAMPLE
        $rows = Get-SandboxHeadsets -TargetRoot $root
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)
    return @(Get-SandboxDbRows -TargetRoot $TargetRoot -Sql @'
SELECT ID, Name, IPAddress, scrcpy_AutoRestart, Record, ScrcpyProfile,
       Brand, Model, SerialNumber
FROM v_headsets
ORDER BY SortOrder, CAST(ID AS INTEGER);
'@)
}

function Get-SandboxHeadsetInfoRow {
    <#
    .SYNOPSIS
        Returns the live-status row of one headset, located by display name.
        $null when not found.
    .DESCRIPTION
        Live status is id-keyed and carries no identity columns (ADR-0016), so the
        name has to be resolved through the registry. v_headset_full is exactly
        that join, so the lookup is one query instead of two file reads.

        Matching on Name here is the harness's own choice, not the application's:
        a test knows the name it just created. The application itself never joins
        status on a name - that is the defect ADR-0016 removes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $rows = @(Get-SandboxDbRows -TargetRoot $TargetRoot -Sql 'SELECT * FROM v_headset_full WHERE Name = @name;' -Parameters @{ name = $Name })
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
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
    # No known_headsets.csv is seeded any more. The registry is a table, and the
    # app creates the database itself on first start. Writing an empty CSV here
    # would be worse than useless: the legacy importer is no longer wired into
    # startup, so the file would simply sit there unread.

    # WiFi credentials: DPAPI store, same user, so a straight copy works. Safe
    # even in self-test mode (DevRoot equal to TargetRoot): the destination-
    # missing check below is then checking the SAME path as the source, so the
    # branch is never entered when the file already exists there.
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
    # path itself ships. Safe in self-test mode (DevRoot equal to TargetRoot):
    # $targetFfmpeg and $devFfmpeg are then the identical path, so the
    # destination-missing check never opens the branch when it already exists.
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
    # The app records that it has done so in the app_kv row 'fw_state'
    # (ADR-0017; it was data\fw_state.json before), so the absence of that row
    # is a reliable "expect UAC" signal. Reset-SandboxTarget carries the row
    # across a reset, so this should fire once per release folder, not per run.
    $fwStateJson = $null
    try { $fwStateJson = Get-SandboxFwStateJson -TargetRoot $TargetRoot } catch { }
    if ($null -eq $fwStateJson) {
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
        elseif (-not (Test-Path -LiteralPath $paths.Database))            { $waitingFor = 'data\vrhm.db' }

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
            $pending = $null
            try { $pending = Get-SandboxFwStateJson -TargetRoot $TargetRoot } catch { }
            if ($null -eq $pending) {
                Write-Host '    Still waiting. Check for a pending Windows UAC prompt and approve it.' -ForegroundColor Yellow
                $uacHintShown = $true
            }
        }

        Start-Sleep -Milliseconds 750
    }

    Write-Host ("  [FAIL] Timed out after {0}s waiting for {1}." -f $TimeoutSeconds, $lastWaitingFor) -ForegroundColor Red
    $finalFwState = $null
    try { $finalFwState = Get-SandboxFwStateJson -TargetRoot $TargetRoot } catch { }
    if ($null -eq $finalFwState) {
        Write-Host '         The fw_state row was never written, so Initialize-ComputerSetup did not' -ForegroundColor DarkGray
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

function Save-SandboxLogs {
    <#
    .SYNOPSIS
        Copies the tested app's latest log file into the current run's
        ArtifactFolder before Reset-SandboxTarget deletes logs\ entirely.

    .DESCRIPTION
        Section 10 already reads this same file to assert on its content, but
        never preserves a copy anywhere. Called once from the harness's
        finally block, after Stop-SandboxApp and before Reset-SandboxTarget.
        Best-effort: never throws, since teardown must complete even when
        nothing was ever logged (e.g. the app never got past provisioning).

    .EXAMPLE
        Save-SandboxLogs -TargetRoot $target
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    if (-not (Get-Command Add-TestArtifact -ErrorAction SilentlyContinue)) { return }

    $paths   = Get-SandboxPaths -TargetRoot $TargetRoot
    $logRoot = Join-Path $paths.LogsFolder $env:COMPUTERNAME
    if (-not (Test-Path -LiteralPath $logRoot)) { return }

    try {
        $logFile = Get-ChildItem -LiteralPath $logRoot -Filter 'log_*.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($logFile) {
            Add-TestArtifact -SourcePath $logFile.FullName -Category app_logs
        }
    }
    catch { }
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

    # The app's firewall / URL-ACL / Defender record survives the reset on
    # purpose. It is the app's proof that it has ALREADY registered all three
    # for THIS folder path; without it Initialize-ComputerSetup sees drift,
    # raises a UAC prompt and an interactive elevated console on every boot, and
    # an unattended run hangs there until it times out. Approving that once per
    # release folder is expected. Approving it on every reset is not.
    #
    # It used to be data\fw_state.json and survived simply by not being deleted.
    # It is the app_kv row 'fw_state' now (ADR-0017), so it has to be read out
    # of the database before the wipe and written back into a fresh one after.
    $keep = $null
    try { $keep = Get-SandboxFwStateJson -TargetRoot $TargetRoot } catch { }

    foreach ($folder in @($paths.DataFolder, $paths.LogsFolder)) {
        if (Test-Path -LiteralPath $folder) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($null -ne $keep) {
        New-Item -ItemType Directory -Path $paths.DataFolder -Force | Out-Null
        if (-not (Restore-SandboxFwStateJson -TargetRoot $TargetRoot -ValueJson $keep)) {
            Write-Host '  Could not carry the firewall state across the reset - expect a UAC prompt on the next boot.' -ForegroundColor Yellow
        }
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
