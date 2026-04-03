##################################
# computer_setup.ps1
# Computer-level setup tasks required for the program to operate correctly.
# Called once at startup from scripts_init.ps1 via Initialize-ComputerSetup.
#
# Responsibilities:
#   - Invoke-AsAdmin         : run a script block elevated (UAC prompt if needed)
#   - Unblock-ADBFirewallRule      : ensure adb.exe is allowed through Windows Firewall
#   - Unblock-MediaMtxFirewallRule : ensure mediamtx RTSP/HLS/WebRTC ports are open
#   - Initialize-ComputerSetup     : orchestrate all setup tasks; called at startup
##################################


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

    $scriptBlock_AddFWRules = {
        param($RuleName, $AdbPath)

        Write-Host " Firewall rules will be created for allowing ADB.exe " -ForegroundColor Cyan -BackgroundColor Black
        Write-Host "`t Rule Name: $RuleName"
        Write-Host "`t Program Path: $AdbPath"
        Write-Host "`t Direction: Outbound and Inbound"
        $RuleName_Outbound = $RuleName + '[OUT]'
        $RuleName_Inbound  = $RuleName + '[IN]'
        Write-Host "`t Outbound Rule Name: $RuleName_Outbound"
        Write-Host "`t Inbound Rule Name: $RuleName_Inbound"
        Read-Host "Press Enter to continue... or cancel with Ctrl+C"

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
        $existingPaths = ($firewallRules | Where-Object DisplayName -ilike "*ADB*" | Get-NetFirewallApplicationFilter).Program
        $invalidPaths = $existingPaths | Where-Object { $_ -ne $AdbPath }

        if ((-not $firewallRules) -or ($invalidPaths)) {
            Write-Log $msg.FirewallRuleCreating -Level INFO
            Invoke-AsAdmin -ScriptBlock $scriptBlock_AddFWRules -ruleName $ruleName -AdbPath $AdbPath
            return $true
        }
        else {
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


# Keep Windows awake (no sleep, no screensaver, no screen lock) while the app is running.
# Uses the official SetThreadExecutionState Win32 API via P/Invoke.
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


function Initialize-ComputerSetup {
    <#
    .SYNOPSIS
    Runs all computer-level setup tasks required for the program to operate.
    Called once at startup from scripts_init.ps1.
    #>

    # Firewall - ADB
    if (-not (Unblock-ADBFirewallRule -AdbPath $global:adbPath)) {
        Write-Log $msg.FirewallConfigSkipped -Level WARNING
    }

    # Firewall - mediamtx restream ports (RTSP/HLS/WebRTC)
    # TODO: re-enable once restream feature is validated
    # Unblock-MediaMtxFirewallRule

    # mediamtx restream server auto-start
    # TODO: re-enable once restream feature is validated
    # Start-MediaMtx

    # Keep the PC awake for the duration of the session
    Set-AwakeMode
}
