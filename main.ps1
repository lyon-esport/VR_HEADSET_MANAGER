## -*- coding: utf-8 -*-
# Initialization of the text encoding type to UTF8
#[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#[Console]::InputEncoding = [System.Text.Encoding]::UTF8


<#
.SYNOPSIS
VR HEADSET MANAGER
Main controller for VR capture management
#>

param (
    # PID of a previous instance to wait for before running the duplicate-instance
    # check. Used by the console menu's "00. Restart application" option so the
    # relaunched process does not trip the "already running" prompt against the
    # instance that spawned it.
    [int]$WaitForPid = 0
)



#Check on startup the main script if it can identify where it is, and make sure it finds the path of $PSScriptRoot. Otherwise, check if the current execution is in a folder whose name contains "VR_HEADSET_MANAGER".
#Load the path into the global variable $global:ScriptPath

#Welcome message
Write-Host "Welcome to VR HEADSET MANAGER!" -ForegroundColor Green
Write-Host "Starting the initialization process..." -ForegroundColor Green

# If relaunched by the "Restart application" menu option, wait for the previous
# instance to fully exit before running the duplicate-instance check below.
if ($WaitForPid -gt 0) {
    Write-Host "Waiting for the previous instance (PID $WaitForPid) to close..." -ForegroundColor Yellow
    $waitDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $waitDeadline) {
        if (-not (Get-Process -Id $WaitForPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
}

# Check if another instance of this script is already running
$thisScriptName = "main.ps1"
$currentPID     = $PID
$otherInstances = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
    Where-Object {
        $_.ProcessId -ne $currentPID -and
        $_.CommandLine -match [regex]::Escape($thisScriptName)
    }

if ($otherInstances) {
    Write-Host ""
    Write-Host "  *** WARNING: VR HEADSET MANAGER is already running! ***" -ForegroundColor Yellow -BackgroundColor DarkRed
    foreach ($inst in $otherInstances) {
        Write-Host ("  PID {0} - started {1}" -f $inst.ProcessId, $inst.CreationDate) -ForegroundColor Yellow
    }
    Write-Host ""
    $confirm = (Read-Host "  Start anyway? [Y / N]").Trim().ToUpper()
    if ($confirm.ToUpper() -ne 'Y') {
        Write-Host "  Launch cancelled." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# Get the current script path
$global:ScriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

if ((Split-Path $global:ScriptPath -Leaf) -notmatch "VR_HEADSET_MANAGER") {
    Write-Host "Error: Please run this script from a folder named 'VR_HEADSET_MANAGER'." -ForegroundColor Red
    Read-Host "Press enter for exit"
    exit
}
# check if the current folder name is "modules", if yes, move up one level
if ((Split-Path $global:ScriptPath -Leaf) -eq "modules") {
    $global:ScriptPath = Split-Path $global:ScriptPath -Parent
}

# Startup stage timing (S8-4). One INFO line listing every stage is written just before the
# main menu. Stages are recorded by Add-StartupStage; scripts_init.ps1 calls it when present
# (only this main process defines it - workers dot-sourcing scripts_init.ps1 skip it).
$global:StartupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$global:StartupStages     = New-Object System.Collections.Generic.List[object]
$global:StartupLastMs     = 0
$global:StartupReported   = $false
function Add-StartupStage {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($global:StartupReported -or -not $global:StartupStopwatch) { return }
    $nowMs = $global:StartupStopwatch.ElapsedMilliseconds
    $global:StartupStages.Add(@{ Name = $Name; Ms = ($nowMs - $global:StartupLastMs) })
    $global:StartupLastMs = $nowMs
}
Add-StartupStage -Name 'pre-checks'

# Unblock the scripts and binaries we execute (in case Windows blocked them: Mark-Of-The-Web
# from a downloaded zip). Scoped to what we run - modules\, scripts\, main.ps1, the root .cmd,
# the toolbox folder and the ACTIVE scrcpy/adb, mediamtx and ffmpeg folders - instead of walking
# the whole tree (sources\ versions, logs\ ~1 GB, worktrees). .dll is included for the bundled
# SQLite engine: a managed assembly still carrying the Mark-Of-The-Web fails to load with an
# opaque loadFromRemoteSources error that names nothing useful.
# A marker (data\unblock.marker = version + root + active binary folders) skips the whole pass
# on later starts; a new extraction, a new version or a binary switch changes/removes it.
$unblockExtensions = @('.ps1', '.psd1', '.psm1', '.dll', '.exe')
$unblockVersion    = ''
$unblockVersionFile = Join-Path -Path $global:ScriptPath -ChildPath 'version.txt'
if (Test-Path -LiteralPath $unblockVersionFile) {
    try { $unblockVersion = (Get-Content -LiteralPath $unblockVersionFile -Raw -Encoding UTF8).Trim() } catch { }
}
# Active binary folders, read straight from config.json (Get-Config is not loaded yet).
$unblockBinFolders = @()
$unblockConfigFile = if ($args[0]) { [string]$args[0] } else { Join-Path -Path $global:ScriptPath -ChildPath 'config\config.json' }
# First start of a fresh extraction: no config.json yet, but the run is about to load the
# SQLite engine and start the binaries named by the template - unblock those folders.
if (-not (Test-Path -LiteralPath $unblockConfigFile)) {
    $unblockConfigFile = Join-Path -Path $global:ScriptPath -ChildPath 'templates\config\config.json'
}
if (Test-Path -LiteralPath $unblockConfigFile) {
    try {
        $unblockCfg = Get-Content -LiteralPath $unblockConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        # database.folder = the SQLite engine (System.Data.SQLite.dll + x64\SQLite.Interop.dll):
        # a blocked copy fails to load with the opaque loadFromRemoteSources error.
        foreach ($rel in @($unblockCfg.scrcpy.folder, $unblockCfg.ADB.folder, $unblockCfg.mediamtx.folder, $unblockCfg.ffmpeg.folder, $unblockCfg.database.folder)) {
            if ($rel -and ($unblockBinFolders -notcontains [string]$rel)) { $unblockBinFolders += [string]$rel }
        }
    } catch { }
}
$unblockMarkerFile = Join-Path -Path $global:ScriptPath -ChildPath 'data\unblock.marker'
$unblockMarkerText = ($unblockVersion + '|' + $global:ScriptPath + '|' + ($unblockBinFolders -join ';'))
$unblockUpToDate = $false
if (Test-Path -LiteralPath $unblockMarkerFile) {
    try { $unblockUpToDate = ((Get-Content -LiteralPath $unblockMarkerFile -Raw -Encoding UTF8).Trim() -ceq $unblockMarkerText) } catch { }
}
if (-not $unblockUpToDate) {
    $unblockTargets = @()
    foreach ($sub in @('modules', 'scripts', 'website\headset-toolbox')) {
        $unblockTargets += @{ Path = (Join-Path -Path $global:ScriptPath -ChildPath $sub); Recurse = $true }
    }
    foreach ($rel in $unblockBinFolders) {
        $unblockTargets += @{ Path = (Join-Path -Path (Join-Path -Path $global:ScriptPath -ChildPath 'sources') -ChildPath $rel); Recurse = $true }
    }
    $unblockTargets += @{ Path = $global:ScriptPath; Recurse = $false }   # main.ps1 + root .cmd
    $unblockFailed = 0
    foreach ($target in $unblockTargets) {
        if (-not (Test-Path -LiteralPath $target.Path -PathType Container)) { continue }
        try {
            $gci = @{ LiteralPath = $target.Path; File = $true; ErrorAction = 'SilentlyContinue' }
            if ($target.Recurse) { $gci.Recurse = $true }
            Get-ChildItem @gci |
                Where-Object { $unblockExtensions -contains $_.Extension.ToLowerInvariant() -or $_.Extension -ieq '.cmd' } |
                ForEach-Object {
                    try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop } catch { $unblockFailed++ }
                }
        } catch { $unblockFailed++ }
    }
    if ($unblockFailed -gt 0) {
        Write-Host "WARNING: Unblock-File failed on $unblockFailed item(s); the unblock pass will be retried at next start." -ForegroundColor Yellow
    } else {
        try {
            $unblockMarkerDir = Split-Path -Path $unblockMarkerFile -Parent
            if (-not (Test-Path -LiteralPath $unblockMarkerDir)) { New-Item -ItemType Directory -Path $unblockMarkerDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($unblockMarkerFile, $unblockMarkerText, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
}
Add-StartupStage -Name 'unblock'


########################## INITIALISATION ##########################

# Load Test-FolderWriteAccess early (utils.ps1 is re-dot-sourced later by
# scripts_init.ps1 along with the rest of the modules - harmless).
. (Join-Path -Path $global:ScriptPath -ChildPath "modules\utils.ps1")

# Unconditional root write-access check. Catches the case where the app
# folder (and its subfolders) already exist - e.g. created during a prior
# elevated run - but the CURRENT (non-admin) user has no write access to
# them. Test-Path/the per-folder loop below only guards folder CREATION,
# so without this check an already-existing-but-unwritable folder would
# pass silently and only fail much later (e.g. VQA writing vqa_history.csv).
$rootDiag = Test-FolderWriteAccess -Path $global:ScriptPath
if (-not $rootDiag.Writable) {
    Write-Host "Error: Cannot write to the app folder '$global:ScriptPath'." -ForegroundColor Red
    Write-Host $rootDiag.Reason -ForegroundColor Red
    Write-Host "Fix: move the app folder to a location you can write to (e.g. Documents or a dedicated D:\Apps\... folder), or always run this app as Administrator." -ForegroundColor Yellow
    Read-Host "Press enter to exit"
    exit 1
}

# Check if folders exists in the same folder as the script, otherwise create them
$requiredFolders = @("config","data","logs","website","website\generated")
foreach ($folder in $requiredFolders) {
    $folderPath = Join-Path -Path $global:ScriptPath -ChildPath $folder
    if (-not (Test-Path -LiteralPath $folderPath)) {
        try {
            New-Item -ItemType Directory -Path $folderPath -ErrorAction Stop | Out-Null
            Write-Host "Created missing folder: $folder" -ForegroundColor Yellow
        } catch {
            $diag = Test-FolderWriteAccess -Path $folderPath
            Write-Host "Error: Could not create required folder '$folderPath'." -ForegroundColor Red
            Write-Host $diag.Reason -ForegroundColor Red
            Write-Host "Fix: move the app folder to a location you can write to (e.g. Documents or a dedicated D:\Apps\... folder), or run this app as Administrator." -ForegroundColor Yellow
            Read-Host "Press enter to exit"
            exit 1
        }
    } else {
        $diag = Test-FolderWriteAccess -Path $folderPath
        if (-not $diag.Writable) {
            Write-Host "Error: Cannot write to existing folder '$folderPath'." -ForegroundColor Red
            Write-Host $diag.Reason -ForegroundColor Red
            Write-Host "Fix: move the app folder to a location you can write to (e.g. Documents or a dedicated D:\Apps\... folder), or run this app as Administrator." -ForegroundColor Yellow
            Read-Host "Press enter to exit"
            exit 1
        }
    }
}

# No registry file is pre-seeded here any more.
#
# This used to create data\known_headsets.csv with a header, claiming
# Write-MediaMtxYml needed it before modules loaded. Nothing read it: the
# registry is the headsets table, created with the rest of the schema by
# Initialize-Database (ADR-0017), and the header it wrote had not matched the
# real column set for a long time. All it produced was an empty, misleading CSV
# in every install, pointing a future maintainer at the wrong place.
#
# The data\ folder itself is created and write-checked by the loop above, so
# the failure diagnostic that used to live here is not lost.
#
# The kiosk registry needs no pre-boot seeding either, for the same reason. Nor
# does the data\kiosk_commands folder, which held one file per queued command
# only because there was no cross-process lock to share a single queue file.


# If custom config file is set as an argument, use it otherwise user the default config.json file
$custom_config = $args[0]
if ($custom_config) {
    $global:configFilePath = $custom_config
    Write-Host "Custom config file passed as argument: $custom_config" -ForegroundColor Green
} else {
    $global:configFilePath = Join-Path -Path $global:ScriptPath -ChildPath "config\config.json"
}

if (-not (Test-Path -LiteralPath $global:configFilePath)) {
    $templateConfigPath = Join-Path -Path $global:ScriptPath -ChildPath "templates\config\config.json"
    if (-not (Test-Path -LiteralPath $templateConfigPath)) {
        Write-Host "Error: Template config file is missing!" -ForegroundColor Red
        Read-Host "Press enter to exit"
        exit 1
    }
    $welcomeModule = Join-Path $global:ScriptPath "modules\welcome.ps1"
    . $welcomeModule
    Invoke-WelcomeSetup -ConfigTemplatePath $templateConfigPath -ConfigOutputPath $global:configFilePath
} else {
    Write-Host "Config file found at: $global:configFilePath" -ForegroundColor Green
}

# Import modules files (must be executed at global level, and cannot start in a function !)
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (Test-Path -LiteralPath $scripts_init) {
    . $scripts_init
    Add-StartupStage -Name 'scripts_init (total)'
} else {
    Write-Host "Error: The initialization modules script is missing!" -ForegroundColor Red
    Read-Host "Press enter for exit"
    exit
}


# The registry is a table, created with the rest of the schema by
# Initialize-Database, so there is no file to seed or validate here any more.
# An empty registry is a normal first-run state rather than a fault.
    $global:knownHeadsets = @(Get-KnownHeadsets)

# Live headset status is a database table now (ADR-0016), reset and seeded by
# scripts_init.ps1 right after the database opens - before this line runs. The
# per-startup CSV seed that used to live here is gone with it.
#
# The path global is kept only so the legacy importer can still name the file it
# reads when migrating another installation. Nothing live reads it.
$global:knownHeadsetsInfosFilePath = "$ScriptPath\data\known_headsets_infos.csv"
$global:knownHeadsetsInfos = @()



######################
######## MAIN ########
######################

# Stard ADB Server if not already started
$null = Start-AdbServer -adbPath $global:adbPath

# Clean stale shutdown / reaper flags from a previous run before VRMonitor starts.
foreach ($staleFlag in @("data\shutdown.flag","data\reaper_exit.flag")) {
    $staleFlagPath = Join-Path $global:ScriptPath $staleFlag
    if (Test-Path -LiteralPath $staleFlagPath) {
        Remove-Item -LiteralPath $staleFlagPath -Force -ErrorAction SilentlyContinue
    }
}

# Spawn the standalone reaper BEFORE VRMonitor, so a crash between the two cannot
# leave orphans. It only needs the main PID and the data\ folder (flags and pid
# files are read when main dies, not at spawn). Hidden background watchdog that
# kills orphan services (mediamtx / web server / dashboard / scrcpy / bridge jobs)
# if main dies without running Invoke-AppShutdown (X button, crash, kill from
# Task Manager).
# Ctrl+C is handled below by the try/finally around the menu loop instead -
# PowerShell still runs a wrapping finally block when Ctrl+C stops the
# pipeline, so that path now goes through the same graceful Invoke-AppShutdown
# as the menu's own "0. Quit", and the reaper finds data\reaper_exit.flag
# already set and exits without having to kill anything.
$reaperScript = Join-Path -Path $scriptPath -ChildPath "modules\reaper.ps1"
if (Test-Path -LiteralPath $reaperScript) {
    Start-Process powershell.exe -ArgumentList @(
        "-NoProfile",
        "-WindowStyle","Hidden",
        "-File","`"$reaperScript`"",
        "-MainPid",$PID,
        "-ScriptPath","`"$global:ScriptPath`""
    ) -WindowStyle Hidden | Out-Null
}

Add-StartupStage -Name 'adb server + reaper'

#Start auto checks of headsets details
Start-VRMonitor -VRMonitor_refresh_timer $global:VRMonitor_refresh_timer
Add-StartupStage -Name 'VRMonitor start'

# Dashboard is a pure DISPLAY window now. Only spawn it when actually visible.
if ($global:Dashboard_showConsole) {
    $headsets_dashboard_script = Join-Path -Path $scriptPath -ChildPath "modules\headsets_dashboard.ps1"
    $dashProc = Start-Process powershell.exe -ArgumentList @(
        "-NoExit",
        "-File",
        "`"$headsets_dashboard_script`"",
        "-ScriptPath",
        "`"$scriptPath`"",
        "-ConfigFilePath",
        "`"$configFilePath`""
    ) -WindowStyle Normal -PassThru
    if ($dashProc) {
        $dashPidFile = Join-Path $global:ScriptPath "data\dashboard.pid"
        $dashProc.Id | Set-Content -LiteralPath $dashPidFile -Encoding ASCII -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Waiting 5 seconds before showing the main menu... " -ForegroundColor Yellow -NoNewline
    for ($i = 4; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
Write-Host "`n"
Add-StartupStage -Name 'dashboard + 5s countdown'

# One INFO line with every startup stage (S8-4). The fixed countdown is part of the last
# stage, so read the real startup cost from the stages before it.
if (-not $global:StartupReported) {
    $stageText  = ($global:StartupStages | ForEach-Object { '{0}={1}ms' -f $_.Name, $_.Ms }) -join ', '
    $totalMs    = $global:StartupStopwatch.ElapsedMilliseconds
    Write-Log ("Startup stages: {0}; total={1}ms" -f $stageText, $totalMs) -Level INFO
    $global:StartupReported = $true
}

# Starting the main menu function that will show the different options to the user
# Loop re-enters Show-MainMenu whenever a module reload is triggered (any-key refresh).
# Drain any keystrokes buffered during startup (welcome wizard, firewall window, countdown)
# so the first Read-Host in Show-MainMenu does not auto-fire the reload default case.
$Host.UI.RawUI.FlushInputBuffer()
$global:MenuReload = $false
try {
    do {
        $global:MenuReload = $false
        Show-MainMenu
    } while ($global:MenuReload)
} finally {
    # Runs on normal loop exit AND on Ctrl+C (PowerShell still executes a
    # wrapping finally block when Ctrl+C stops the pipeline). Invoke-AppShutdown
    # is idempotent, so this is a no-op if the menu's own "0. Quit" already ran it.
    Invoke-AppShutdown
}




