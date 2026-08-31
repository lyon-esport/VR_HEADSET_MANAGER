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



<#

Improvement areas:

- Manual editing of the config file
    > Re-verify at each refresh that the file is correctly formatted
    > Simplify the config file: Name;IP
- Refresh optimization: only read info from the config file, do not ping + test port on every refresh; let the background job handle it
    - Perform a more efficient ping test (not at headset selection time)
    --> Create a second HeadsetFollowup file auto-populated by the script below
    - Launch a background window that pings, checks the port, auto-restarts the stream, and updates the HeadsetFollowup file
    - During scan, check whether a stream with the same name is already running

- From the main menu, type the headset number directly to stream it
    - Enter key to display HeadsetFollowup info
    - Add the StreamAutoRestart flag to the followup file
    - If the same number is entered again, kill the running stream and stop auto-reopening it
- From main menu > a key to enable ADB Wireless for a USB-connected device (e.g. the + key)
- Customize scrcpy parameters in the JSON config file rather than directly in the script
- When installing the ADB Wireless APK or activating a stream, automatically add the headset if its serial number is not already known
    > Enter 0 for the headset name if you don't want to add it
- "+" key to enable WiFi ADB on a USB-connected headset.
- Add an input-parameter refresh function (R key?) to reload updated module files and the JSON config file.

- Check headset state on attempt: wifi unauthorized, ADB not enabled, developer mode not enabled...
- Allow adb.exe through the Windows Firewall on application startup (firewall prompt)

- Force the ADB daemon to start when the script launches if it is stopped

#>

# Fallback if $PSScriptRoot is not available (e.g. command-line execution)
#$global:ScriptPath = if ($PSScriptRoot) {$PSScriptRoot} else {"L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER"}



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

# check if the current folder name is "modules", if yes, move up one level
if ((Split-Path $global:ScriptPath -Leaf) -eq "modules") {
    $global:ScriptPath = Split-Path $global:ScriptPath -Parent
}

if ((Split-Path $global:ScriptPath -Leaf) -notmatch "VR_HEADSET_MANAGER") {
    Write-Host "Error: Please run this script from a folder containing 'VR_HEADSET_MANAGER'." -ForegroundColor Red
    Read-Host "Press enter for exit"
    exit
}


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
$requiredFolders = @("config","data","data\kiosk_commands","logs","website","website\generated")
foreach ($folder in $requiredFolders) {
    $folderPath = Join-Path -Path $global:ScriptPath -ChildPath $folder
    if (-not (Test-Path -Path $folderPath)) {
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

# Pre-boot: ensure known_headsets.csv exists before modules load (Write-MediaMtxYml reads it)
$_csvPath = Join-Path $global:ScriptPath "data\known_headsets.csv"
if (-not (Test-Path -LiteralPath $_csvPath)) {
    Write-Host "Initializing known_headsets.csv..." -ForegroundColor Yellow
    try {
        "ID,Name,IPAddress,scrcpy_AutoRestart,Record,SerialNumber" | Out-File -LiteralPath $_csvPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        $diag = Test-FolderWriteAccess -Path $_csvPath
        Write-Host "Error: Could not create '$_csvPath'." -ForegroundColor Red
        Write-Host $diag.Reason -ForegroundColor Red
        Write-Host "Fix: move the app folder to a location you can write to (e.g. Documents or a dedicated D:\Apps\... folder), or run this app as Administrator." -ForegroundColor Yellow
        Read-Host "Press enter to exit"
        exit 1
    }
}
Remove-Variable _csvPath

# Pre-boot: ensure known_kiosks.csv exists before modules load
$_kioskCsvPath = Join-Path $global:ScriptPath "data\known_kiosks.csv"
if (-not (Test-Path -LiteralPath $_kioskCsvPath)) {
    Write-Host "Initializing known_kiosks.csv..." -ForegroundColor Yellow
    try {
        Set-Content -LiteralPath $_kioskCsvPath -Value '"ID","Name","IPAddress","Port","PushedURL","LastPushedAt"' -Encoding UTF8 -ErrorAction Stop
    } catch {
        $diag = Test-FolderWriteAccess -Path $_kioskCsvPath
        Write-Host "Error: Could not create '$_kioskCsvPath'." -ForegroundColor Red
        Write-Host $diag.Reason -ForegroundColor Red
        Write-Host "Fix: move the app folder to a location you can write to (e.g. Documents or a dedicated D:\Apps\... folder), or run this app as Administrator." -ForegroundColor Yellow
        Read-Host "Press enter to exit"
        exit 1
    }
}
Remove-Variable _kioskCsvPath

$custom_config = $args[0]
if ($custom_config) {
    Write-Host "Custom config file passed as argument: $custom_config" -ForegroundColor Green
} else {
    Write-Host "No custom config file passed as argument. Starting process with default config file path." -ForegroundColor Yellow
}
# Check if config file exists, if not create it from template file and open it for edit
if ($custom_config) {
    $global:configFilePath = $custom_config
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


#Unblock all scripts in the module folder (in case they were blocked by Windows)
Get-ChildItem -Path $global:ScriptPath -Include "*.ps1","*.psd1" -Recurse -File | Unblock-File

# Import modules files (must be executed at global level, and cannot start in a function !)
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (Test-Path -Path $scripts_init) {
    . $scripts_init
} else {
    Write-Host "Error: The initialization modules script is missing!" -ForegroundColor Red
    Read-Host "Press enter for exit"
    exit
}


# File initialization of the known headsets list file
    #$global:knownHeadsetsFilePath = "$ScriptPath\data\known_headsets.csv"
    $global:knownHeadsets = @()
    if ((Test-Path $global:knownHeadsetsFilePath) -or (Test-KnownHeadsetsFile($global:knownHeadsetsFilePath))) {
        $global:knownHeadsets = @(Import-Csv -Path $global:knownHeadsetsFilePath)
    } else {
        Write-Log "The known headsets file does not exist or is not correct, initializing!" -Level WARNING
        $headers = "ID","Name","IPAddress","scrcpy_AutoRestart","Record","SerialNumber"
        $headers -join "," | Out-File -FilePath $global:knownHeadsetsFilePath -Encoding UTF8
    }

# Data file initialization of the headsets infos file.
# Seed one row per known headset using the same default shape that
# Get-KnownHeadsetInfos returns when a headset is offline, so the UI
# renders the full list immediately instead of waiting for the first
# VRMonitor poll cycle (~10-20s with several headsets).
$global:knownHeadsetsInfosFilePath = "$ScriptPath\data\known_headsets_infos.csv"
$global:knownHeadsetsInfos = @()
$seedRows = @()
foreach ($h in $global:knownHeadsets) {
    $seedRows += [PSCustomObject]@{
        ID                     = $h.ID
        Name                   = $h.Name
        IPAddress              = $h.IPAddress
        Ping                   = $false
        ADBWifi                = $false
        Battery                = "-"
        Charging               = "-"
        ChargingWattage        = "-"
        Temp                   = "-"
        BatteryControllerLeft  = "-"
        BatteryControllerRight = "-"
        PowerState             = "-"
        TimeRemainingMin       = "-"
        BatteryHistory         = ""
        SCRCPY                 = "-"
        Model                  = "-"
        SerialNumber           = if ($h.PSObject.Properties.Name -contains 'SerialNumber' -and $h.SerialNumber) { $h.SerialNumber } else { "-" }
        RunningApp             = "-"
        RunningAppIcon         = ""
    }
}
if ($seedRows.Count -gt 0) {
    $seedRows | Export-Csv -LiteralPath $global:knownHeadsetsInfosFilePath -Delimiter ";" -Encoding UTF8 -NoTypeInformation
} else {
    $headerLine = '"ID";"Name";"IPAddress";"Ping";"ADBWifi";"Battery";"Charging";"ChargingWattage";"Temp";"BatteryControllerLeft";"BatteryControllerRight";"PowerState";"TimeRemainingMin";"BatteryHistory";"SCRCPY";"Model";"SerialNumber";"RunningApp";"RunningAppIcon"'
    $headerLine | Out-File -LiteralPath $global:knownHeadsetsInfosFilePath -Encoding UTF8
}



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

#Start auto checks of headsets details
Start-VRMonitor -VRMonitor_refresh_timer $global:VRMonitor_refresh_timer

# Spawn the standalone reaper. Hidden background watchdog that kills orphan
# services (mediamtx / web server / dashboard / scrcpy) if main dies without
# running Invoke-AppShutdown (Ctrl+C, X button, crash).
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
        $dashProc.Id | Set-Content -LiteralPath $dashPidFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Waiting 5 seconds before showing the main menu... " -ForegroundColor Yellow -NoNewline
    for ($i = 4; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
Write-Host "`n"


# Starting the main menu function that will show the different options to the user
# Loop re-enters Show-MainMenu whenever a module reload is triggered (any-key refresh).
# Drain any keystrokes buffered during startup (welcome wizard, firewall window, countdown)
# so the first Read-Host in Show-MainMenu does not auto-fire the reload default case.
$Host.UI.RawUI.FlushInputBuffer()
$global:MenuReload = $false
do {
    $global:MenuReload = $false
    Show-MainMenu
} while ($global:MenuReload)




