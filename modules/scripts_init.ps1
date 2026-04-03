#Execute everything on the global scope
# Import of module files (must be executed at the global level, and cannot start in a function!)
# Following code should be added in any script that needs to import all modules :
<#
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (Test-Path -Path $scripts_init) {
    . $scripts_init
} else {
    Write-Host "Error: The module initialization script was not found!" -ForegroundColor Red
    exit
}

#>


# Install or import EPS module
    if (-not (Get-Module -ListAvailable -Name EPS)) {
        Install-Module -Name EPS -Scope CurrentUser -Force
    } 
    else {
        Import-Module EPS
    }
# Install or import Pode module
    if (-not (Get-Module -ListAvailable -Name Pode)) {
        Install-Module -Name Pode -Scope CurrentUser -Force
    } 
    else {
        Import-Module Pode
    }


# Get the base path
$global:ScriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Check whether we are in the modules folder and move up one level if necessary
if ((Split-Path $global:ScriptPath -Leaf) -eq "modules") {
    $global:ScriptPath = Split-Path $global:ScriptPath -Parent
}

# Check we are in VR_HEADSET_MANAGER folder
if ((Split-Path $global:ScriptPath -Leaf) -ne "VR_HEADSET_MANAGER") {
    Write-Host "Error: Please run this script from the 'VR_HEADSET_MANAGER' folder." -ForegroundColor Red
    exit 1
}


$ModulesPath = Join-Path -Path $global:ScriptPath -ChildPath "modules"
    if (-not (Test-Path -Path $ModulesPath -PathType Container)) {
            Write-Warning "The script cannot continue without the modules folder $ModulesPath."
            return
    }

$moduleFiles = Get-ChildItem -Path $ModulesPath -Filter "*.ps1" -File | 
    Where-Object { 
        $_.Name -notlike "*_init.ps1" -and 
        $_.Name -notlike "headsets_dashboard.ps1" -and
        $_.Name -notlike "*_test.ps1"
    }

    foreach ($file in $moduleFiles) {
        try {
            # Dot-source the file so its functions become available
            . $file.FullName
            if (-not $global:debugLevelToConsole -or $global:debugLevelToConsole -in @('DEBUG','INFO','SUCCESS')) {
                Write-Host "[OK] Module $($file.Name) loaded" -ForegroundColor Green
            }
        }
        catch {
            if (-not $global:debugLevelToConsole -or $global:debugLevelToConsole -ne 'NONE') {
                Write-Host "[ERROR] Unable to load module $($file.Name)" -BackgroundColor Red -ForegroundColor White
            }
        }
    }

#TODO 
    # install all config files in mydocuments if they do not exist : [environment]::GetFolderPath('MyDocuments')




# Load configuration file
    if ($global:custom_config) {
        $ConfigFilePath = $global:custom_config
        write-Host "WARNING: Using configuration file: $ConfigFilePath" -ForegroundColor Yellow
        pause
    } else {
        $ConfigFilePath = "$ScriptPath\config\config.json"
    }


# check if config file exists and load it
    if ( -not (Test-Path $ConfigFilePath)) {
        Write-Host ""
        Write-Host "  *** Configuration file not found! ***" -ForegroundColor Red -BackgroundColor Black
        Write-Host "  Expected : $ConfigFilePath" -ForegroundColor Yellow
        Write-Host ""
        $templatePath = Join-Path -Path $global:ScriptPath -ChildPath "templates\config\config.json"
        if (Test-Path $templatePath) {
            # Ensure the destination directory exists
            $configDir = Split-Path $ConfigFilePath -Parent
            if (-not (Test-Path $configDir)) {
                New-Item -Path $configDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $templatePath -Destination $ConfigFilePath -Force
            Write-Host "  A default configuration file has been created from the template." -ForegroundColor Green
            Write-Host "  Please fill in your settings, save and restart the script." -ForegroundColor Yellow
            Write-Host ""
            Start-Sleep -Seconds 2
            notepad $ConfigFilePath
        }
        else {
            Write-Host "  Template not found at '$templatePath'." -ForegroundColor Red
            Write-Host "  Please create '$ConfigFilePath' manually, then restart." -ForegroundColor Yellow
        }
        exit 1

    } else {
        Get-Config -ConfigFilePath $ConfigFilePath
        Write-Log "Configuration file $ConfigFilePath loaded successfully" -Level DEBUG
        Write-Host "DEBUG global:knownHeadsetsFile = $($global:knownHeadsetsFile)" -ForegroundColor Magenta
        Write-Host "DEBUG global:knownHeadsetsFilePath = $($global:knownHeadsetsFilePath)" -ForegroundColor Magenta
    }

    # Load centralized translations based on selected language.
    # Runs after the config if/else so it also applies when the config file was
    # missing (no language set) — falls back to English in that case.
    $translationsFolder = Join-Path $modulesPath "translations"
    $translationsEn     = Join-Path $translationsFolder "en-US.psd1"
    $translationsLang   = if ($global:SelectedLanguage) {
                              Join-Path $translationsFolder "$($global:SelectedLanguage).psd1"
                          } else { $null }

    if ($translationsLang -and (Test-Path $translationsLang)) {
        $global:msg = Import-PowerShellDataFile -Path $translationsLang
    } elseif (Test-Path $translationsEn) {
        if ($global:SelectedLanguage -and $global:SelectedLanguage -ne 'en-US') {
            Write-Host "Translations for '$($global:SelectedLanguage)' not found, falling back to English." -ForegroundColor Yellow
        }
        $global:msg = Import-PowerShellDataFile -Path $translationsEn
    } else {
        Write-Host "[ERROR] No translation file found in $translationsFolder" -ForegroundColor Red
        Write-Host "[ERROR] a default translation file en-US.psd1 is required for the application to run." -ForegroundColor Red
        Read-Host 'Press Enter to stop the application...'
        exit
    }
    Write-Log ($msg.TranslationsLoaded -f $global:SelectedLanguage) -Level DEBUG







########## ADMIN FUNCTIONS FOR FIREWALL RULES MANAGEMENT ##########

function Invoke-AsAdmin {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(ValueFromRemainingArguments = $true)]
        $Arguments
    )

    # Check if we are already running as administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        $namedParams = @{}
        for ($i = 0; $i -lt $Arguments.Count; $i += 2) {
            $paramName = $Arguments[$i].TrimStart('-')
            $paramValue = $Arguments[$i + 1]
            $namedParams[$paramName] = $paramValue
        }
        & $ScriptBlock @namedParams
    }
    else {
        # Not running as admin, relaunch PowerShell as admin
        $scriptBlockString = $ScriptBlock.ToString()
        
        # Build arguments string with proper escaping
        $argumentPairs = @()
        for ($i = 0; $i -lt $Arguments.Count; $i += 2) {
            $paramName = $Arguments[$i]
            $paramValue = $Arguments[$i + 1]
            
            # Escape single quotes and wrap value in single quotes
            $escapedValue = $paramValue -replace "'", "''"
            $argumentPairs += "$paramName '$escapedValue'"
        }
        $argumentsString = $argumentPairs -join ' '

        # Build the full command with proper quoting
        $command = "& { $scriptBlockString } $argumentsString"
        
        Start-Process -FilePath "powershell.exe" `
                      -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command `
                      -Verb RunAs `
                      -Wait
    }
}


function Unblock-ADBFirewallRule {
    <#
    .SYNOPSIS
    Ensures ADB.exe is allowed through Windows Firewall
    
    .DESCRIPTION
    Checks if a firewall rule exists for ADB.exe and creates one if necessary.
    Requires administrator privileges to create/modify firewall rules.
    
    .PARAMETER AdbPath
    Full path to adb.exe executable
    
    .EXAMPLE
    Unblock-ADBFirewallRule -AdbPath "C:\tools\scrcpy\adb.exe"
    #>
    
    param(
        [Parameter(Mandatory=$true)]
        [string]$AdbPath
    )
    
    # Define firewall rule name
    $ruleName = "_[VR_HEADSET_MANAGER]ADB_Allowed"

    # Verify ADB executable exists
    if (-not (Test-Path -Path $AdbPath)) {
        Write-Log ($msg.ADBExecutableNotFound -f $AdbPath) -Level ERROR
        return $false
    }
    

    # Create script block to create new firewall rules
    # Example usage
    <#
    $scriptBlock = {
        param($param1, $param2)
        Write-Host "Running as admin: $($MyInvocation.MyCommand)"
        Write-Host "Received parameters: $param1, $param2"
        Read-Host "Press Enter to continue..."
        # Your admin code here
    }
    #>
    $scriptBlock_AddFWRules = {
        param($RuleName, $AdbPath)
        
        Write-Host " Firewall rules will be created for allowing ADB.exe " -ForegroundColor Cyan -BackgroundColor Black
        Write-Host "`t Rule Name: $RuleName"
        Write-Host "`t Program Path: $AdbPath"
        Write-Host "`t Direction: Outbound and Inbound"
        $RuleName_Outbound =  $RuleName + '[OUT]'
        $RuleName_Inbound  =  $RuleName + '[IN]'
        Write-Host "`t Outbound Rule Name: $RuleName_Outbound"
        Write-Host "`t Inbound Rule Name: $RuleName_Inbound"
        Read-Host "Press Enter to continue... of cancel with Ctrl+C"
        
        # Remove existing rules if any
        Get-NetFirewallRule | Where-Object DisplayName -ilike "*VR_HEADSET_MANAGER*" | Remove-NetFirewallRule -ErrorAction Continue
        
        # Create outbound rule
        New-NetFirewallRule -DisplayName $($RuleName + ' [OUT]') `
                            -Direction Outbound `
                            -Program $AdbPath `
                            -Action Allow `
                            -Profile Any `
                            -Description 'Allow VR Headset Manager ADB connections' `
                            -ErrorAction Continue `
                            | Out-Null
        
        # Create inbound rule
        New-NetFirewallRule -DisplayName $($RuleName + ' [IN]') `
                            -Direction Inbound `
                            -Program $AdbPath `
                            -Action Allow `
                            -Description 'Allow VR Headset Manager ADB connections' `
                            -ErrorAction Continue `
                            | Out-Null

        Read-Host "Firewall rules created successfully. Press Enter to exit."
    }

    
    # Get current network profile type
    try {
        $currentNetworkProfile = (Get-NetConnectionProfile).NetworkCategory
        Write-Log ($msg.NetworkProfileCurrent -f $currentNetworkProfile) -Level DEBUG
    }
    catch {
        Write-Log ($msg.NetworkProfileFailed -f $_) -Level WARNING
        $currentNetworkProfile = "DomainAuthenticated"
    }
    
    
    try {
        # Check if firewall rule already exists
        $firewallRules = Get-NetFirewallRule | Where-Object DisplayName -ilike "*VR_HEADSET_MANAGER*"
        $existingPaths = ($firewallRules  | Where-Object DisplayName -ilike "*ADB*" | Get-NetFirewallApplicationFilter).Program
        $invalidPaths = $existingPaths | Where-Object { $_ -ne $AdbPath }

        if ((-not $firewallRules) -or ($invalidPaths)) {
            Write-Log $msg.FirewallRuleCreating -Level INFO
            Invoke-AsAdmin -ScriptBlock $scriptBlock_AddFWRules -ruleName $ruleName -AdbPath $AdbPath
            return $true
        }
        else {
            # Rule exists, verify program path is correct
                Write-Log $msg.FirewallRuleExists -Level DEBUG
                return $true
        }
    }
    catch {
        Write-Log ($msg.FirewallRuleFailed -f $_) -Level ERROR
        return $false
    }
}

function Unblock-MediaMtxFirewallRule {
    <#
    .SYNOPSIS
    Ensures Windows Firewall allows inbound connections to mediamtx restream ports.

    .DESCRIPTION
    Creates inbound rules named [VR_HEADSET_MANAGER]MediaMtx_Allowed for:
      - TCP+UDP on the RTSP port (default 8554) for RTSP streaming via VLC / OBS
      - TCP on the HLS port (default 8888) for browser / OBS HLS playback
      - TCP+UDP on the WebRTC port (default 8889) for browser WebRTC playback
    Rules apply to all network profiles (Domain, Private, Public) so remote viewers
    on any network segment can connect. Admin elevation is requested if needed.
    #>
    if (-not $global:mediamtxEnabled) {
        Write-Log $msg.MediaMtxNotEnabled -Level DEBUG
        return
    }
    $ruleName   = "_[VR_HEADSET_MANAGER]MediaMtx_Allowed"
    $rtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort   } else { 8554 }
    $hlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort    } else { 8888 }
    $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }

    $scriptBlock_AddMediaMtxFWRules = {
        param($RuleName, $rtspPort, $hlsPort, $webrtcPort)
        Write-Host " Firewall rules will be created for mediamtx restream " -ForegroundColor Cyan -BackgroundColor Black
        Write-Host "`t Rule base  : $RuleName"
        Write-Host "`t RTSP   port $rtspPort  (TCP+UDP inbound)"
        Write-Host "`t HLS    port $hlsPort   (TCP inbound)"
        Write-Host "`t WebRTC port $webrtcPort (TCP+UDP inbound)"
        Write-Host "`t Profile    : Any (Domain, Private, Public)"
        Read-Host "Press Enter to continue... or cancel with Ctrl+C"
        New-NetFirewallRule -DisplayName ($RuleName + ' RTSP-TCP [IN]') `
                            -Direction Inbound -Protocol TCP -LocalPort $rtspPort `
                            -Action Allow -Profile Any -ErrorAction Continue | Out-Null
        New-NetFirewallRule -DisplayName ($RuleName + ' RTSP-UDP [IN]') `
                            -Direction Inbound -Protocol UDP -LocalPort $rtspPort `
                            -Action Allow -Profile Any -ErrorAction Continue | Out-Null
        New-NetFirewallRule -DisplayName ($RuleName + ' HLS-TCP [IN]') `
                            -Direction Inbound -Protocol TCP -LocalPort $hlsPort `
                            -Action Allow -Profile Any -ErrorAction Continue | Out-Null
        New-NetFirewallRule -DisplayName ($RuleName + ' WebRTC-TCP [IN]') `
                            -Direction Inbound -Protocol TCP -LocalPort $webrtcPort `
                            -Action Allow -Profile Any -ErrorAction Continue | Out-Null
        New-NetFirewallRule -DisplayName ($RuleName + ' WebRTC-UDP [IN]') `
                            -Direction Inbound -Protocol UDP -LocalPort $webrtcPort `
                            -Action Allow -Profile Any -ErrorAction Continue | Out-Null
        Read-Host "MediaMtx firewall rules created. Press Enter to exit."
    }
    try {
        $existing = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*MediaMtx*" }
        if (-not $existing) {
            Write-Log ($msg.MediaMtxFirewallRuleCreating -f $rtspPort, $hlsPort) -Level INFO
            Invoke-AsAdmin -ScriptBlock $scriptBlock_AddMediaMtxFWRules `
                           -ruleName $ruleName -rtspPort $rtspPort `
                           -hlsPort $hlsPort -webrtcPort $webrtcPort
        }
        else {
            Write-Log $msg.MediaMtxFirewallRuleExists -Level DEBUG
        }
    }
    catch {
        Write-Log ($msg.MediaMtxFirewallRuleFailed -f $_) -Level ERROR
    }
}

# Check and configure firewall for ADB
if (-not (Unblock-ADBFirewallRule -adbPath $global:adbPath)) {
    Write-Log $msg.FirewallConfigSkipped -Level WARNING
}

# Check and configure firewall for mediamtx restream ports (RTSP/HLS/WebRTC)
Unblock-MediaMtxFirewallRule

# Start mediamtx restream server in background (if enabled in config)
Start-MediaMtx

# Prevent Windows from locking the screen / starting screensaver while the app is running
# Uses the official SetThreadExecutionState Win32 API
Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class AwakeMode {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern uint SetThreadExecutionState(uint esFlags);
        public const uint ES_CONTINUOUS       = 0x80000000;
        public const uint ES_SYSTEM_REQUIRED  = 0x00000001;
        public const uint ES_DISPLAY_REQUIRED = 0x00000002;
    }
"@ -ErrorAction SilentlyContinue

function Set-AwakeMode {
    # Prevents sleep, screensaver and screen lock
    [AwakeMode]::SetThreadExecutionState(
        [AwakeMode]::ES_CONTINUOUS -bor
        [AwakeMode]::ES_SYSTEM_REQUIRED -bor
        [AwakeMode]::ES_DISPLAY_REQUIRED
    ) | Out-Null
    Write-Log $msg.AwakeModeActivated -Level DEBUG
}

function Reset-AwakeMode {
    # Restores normal Windows sleep/lock behaviour
    [AwakeMode]::SetThreadExecutionState([AwakeMode]::ES_CONTINUOUS) | Out-Null
    Write-Log $msg.AwakeModeDeactivated -Level DEBUG
}




