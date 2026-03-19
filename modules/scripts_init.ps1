#Execute everything on the global scope
# Import of module files (must be executed at the global level, and cannot start in a function!)
# Following code should be added in any script that needs to import all modules :
<#
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (Test-Path -Path $scripts_init) {
    . $scripts_init
} else {
    Write-Host "Erreur: Le script d'initialisation des modules est introuvable !" -ForegroundColor Red
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

# Vérifier si on est dans le dossier modules et remonter d'un niveau si nécessaire
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
            # On "dot-source" le fichier pour que ses fonctions soient disponibles
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
        Write-Host "Error: The configuration file does not exist or the path is not defined!" -ForegroundColor Red
        #copy template default config file
        $templateConfigFile = Join-Path -Path $global:ScriptPath -ChildPath "sources\templates\TEMPLATE_config.json"
        Copy-Item -Path $templateConfigFile -Destination $ConfigFilePath -Force
        #rename it to config.json
        #Rename-Item -Path $ConfigFilePath -NewName "config.json" -Force
        Write-Host "A default configuration file has been created at $ConfigFilePath. Please review and modify it as needed, then restart the script." -ForegroundColor Yellow
        #wait 4 seconds
        Start-Sleep -Seconds 4
        #open the config file in notepad
        notepad $ConfigFilePath
        Write-Host "Press any key to exit..." -ForegroundColor Yellow
        # exit the script
        exit 1

    } else {
        Get-Config -ConfigFilePath $ConfigFilePath
        Write-Log "Configuration file $ConfigFilePath loaded successfully" -Level DEBUG

        # Load centralized translations based on selected language
        $translationsFolder = Join-Path $modulesPath "translations"
        $translationsLang = Join-Path $translationsFolder "$($global:SelectedLanguage).psd1"
        $translationsEn   = Join-Path $translationsFolder "en-US.psd1"
        if (Test-Path $translationsLang) {
            $global:msg = Import-PowerShellDataFile -Path $translationsLang
        } elseif (Test-Path $translationsEn) {
            if ($global:SelectedLanguage -ne 'en-US') {
                Write-Host "Translations for '$($global:SelectedLanguage)' not found, falling back to English." -ForegroundColor Yellow
            }
            $global:msg = Import-PowerShellDataFile -Path $translationsEn
        } else {
            Write-Host "[WARNING] No translation file found in $translationsFolder" -ForegroundColor Yellow
        }
        Write-Log "Translations loaded for language: $($global:SelectedLanguage)" -Level DEBUG
        Write-Host "DEBUG global:knownHeadsetsFile = $($global:knownHeadsetsFile)" -ForegroundColor Magenta
        Write-Host "DEBUG global:knownHeadsetsFilePath = $($global:knownHeadsetsFilePath)" -ForegroundColor Magenta
    }







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
        Write-Log "ADB executable not found at $AdbPath" -Level ERROR
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
        Write-Log "Current network profile: $currentNetworkProfile" -Level DEBUG
    }
    catch {
        Write-Log "Failed to retrieve network profile: $_" -Level WARNING
        $currentNetworkProfile = "DomainAuthenticated"
    }
    
    
    try {
        # Check if firewall rule already exists
        $firewallRules = Get-NetFirewallRule | Where-Object DisplayName -ilike "*VR_HEADSET_MANAGER*"
        $existingPaths = ($firewallRules  | Where-Object DisplayName -ilike "*ADB*" | Get-NetFirewallApplicationFilter).Program
        $invalidPaths = $existingPaths | Where-Object { $_ -ne $AdbPath }

        if ((-not $firewallRules) -or ($invalidPaths)) {
            Write-Log "Creating firewall rule for ADB.exe" -Level INFO
            Invoke-AsAdmin -ScriptBlock $scriptBlock_AddFWRules -ruleName $ruleName -AdbPath $AdbPath
            return $true
        }
        else {
            # Rule exists, verify program path is correct
                Write-Log "Firewall rule already exists and is correctly configured" -Level DEBUG
                return $true
        }
    }
    catch {
        Write-Log "Failed to manage firewall rule: $_" -Level ERROR
        return $false
    }
}

# Check and configure firewall for ADB
if (-not (Unblock-ADBFirewallRule -adbPath $global:adbPath)) {
    Write-Log "Firewall configuration for ADB failed or skipped" -Level WARNING
}



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
    Write-Log "Awake mode activated: screen lock and sleep are disabled." -Level DEBUG
}

function Reset-AwakeMode {
    # Restores normal Windows sleep/lock behaviour
    [AwakeMode]::SetThreadExecutionState([AwakeMode]::ES_CONTINUOUS) | Out-Null
    Write-Log "Awake mode deactivated: normal sleep/lock behaviour restored." -Level DEBUG
}




