## -*- coding: utf-8 -*-
# Initialization of the text encoding type to UTF8
#[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#[Console]::InputEncoding = [System.Text.Encoding]::UTF8


<#
.SYNOPSIS
VR HEADSET MANAGER
Main controller for VR capture management
#>



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


# Check if folders exists in the same folder as the script, otherwise create them
$requiredFolders = @("config","data","logs","OBS")
foreach ($folder in $requiredFolders) {
    $folderPath = Join-Path -Path $global:ScriptPath -ChildPath $folder
    if (-not (Test-Path -Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath | Out-Null
        Write-Host "Created missing folder: $folder" -ForegroundColor Yellow
    }
}

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

if (-not (Test-Path -Path $global:configFilePath)) {
    $templateConfigPath = Join-Path -Path $global:ScriptPath -ChildPath "template\config\config.json"
    if (Test-Path -Path $templateConfigPath) {
        Copy-Item -Path $templateConfigPath -Destination $global:configFilePath
        Write-Host "Config file created from template at: $global:configFilePath" -ForegroundColor Green
        
        Write-Host "Do you want to edit the config file now with your default file editor? (Y/N)" -ForegroundColor Yellow
        $REPLY = Read-Host
        
        if ($REPLY -match '^[Yy]$') {
            # Open the config file in the default text editor
            Start-Process -FilePath $global:configFilePath
        } else {
            Write-Host "You can edit the config file later at: $global:configFilePath" -ForegroundColor Green
        }

    } else {
        Write-Host "Error: Template config file is missing!" -ForegroundColor Red
        Read-Host "Press enter for exit"
        exit 1
    }
} else {
    Write-Host "Config file found at: $global:configFilePath" -ForegroundColor Green
}


#Unblock all scripts in the module folder (in case they were blocked by Windows)
Get-ChildItem -Path $global:ScriptPath -Filter "*.ps1" -Recurse | Unblock-File

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

# Data file initialization of the headsets infos file
$global:knownHeadsetsInfosFilePath = "$ScriptPath\data\known_headsets_infos.csv"
$global:knownHeadsetsInfos = @()
$headerLine = '"ID","Name","IPAddress","AdbPort","Ping","ADBWifi","Brand","Model","SerialNumber","BatteryLevel","Charging","Scrcpy","LastUpdateTimeStamp"'
$headerLine | Out-File -FilePath $global:knownHeadsetsInfosFilePath -Encoding UTF8



######################
######## MAIN ########
######################

# Stard ADB Server if not already started
$null = Start-AdbServer -adbPath $global:adbPath

#Start auto checks of headsets details
Start-VRMonitor -VRMonitor_refresh_timer $global:VRMonitor_refresh_timer

# Open the VR Monitor in a new PowerShell window
$headsets_dashboard_script = Join-Path -Path $scriptPath -ChildPath "modules\headsets_dashboard.ps1"

Start-Process powershell.exe -ArgumentList @(
    "-NoExit",
    "-File",
    "`"$headsets_dashboard_script`"",
    "-ScriptPath",
    "`"$scriptPath`"",
    "-ConfigFilePath", 
    "`"$configFilePath`""
)

Write-Host "Waiting 5 seconds before showing the main menu... " -ForegroundColor Yellow -NoNewline
    for ($i = 4; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
Write-Host "`n"


# Starting the main menu function that will show the different options to the user
Show-MainMenu




