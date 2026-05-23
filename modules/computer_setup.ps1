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

        # Encode command as Base64 to avoid quoting/special-character issues
        # when the scriptblock content contains double quotes or newlines.
        $command = "& { $scriptBlockString } $argumentsString"
        $encodedCommand = [Convert]::ToBase64String(
            [System.Text.Encoding]::Unicode.GetBytes($command)
        )

        Start-Process -FilePath "powershell.exe" `
                      -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand `
                      -Verb RunAs `
                      -Wait
    }
}


# ---------------------------------------------------------------------------
# Shared elevated helper: Show-SetupBox
# Defined as a string so it can be prepended to any elevated scriptblock.
# Elevated scriptblocks run in a new process when UAC is needed - they cannot
# call functions defined in the parent module. This string is concatenated with
# each specific scriptblock via [scriptblock]::Create() so Show-SetupBox is
# always available regardless of elevation context.
# ---------------------------------------------------------------------------
$script:SetupPromptFn = @'
function Show-SetupBox {
    param([string]$Title, [string]$Details, [string]$ActionLabel)
    Write-Host ""
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  | {0,-42}|" -f $Title) -ForegroundColor Cyan
    Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
    foreach ($line in ($Details -split "[\r\n]+")) { if ($line.Trim()) { Write-Host "  $line" } }
    Write-Host ""
    Write-Host "  [Y or Enter] $ActionLabel    [any key] Skip" -ForegroundColor Yellow
    $k = [Console]::ReadKey($true)
    return ($k.KeyChar -eq "y" -or $k.KeyChar -eq "Y" -or $k.Key -eq [ConsoleKey]::Enter)
}
'@

# Generic elevated scriptblock: creates inbound firewall port rules.
# Params: RuleName (display name base), Title (box header), Details (description lines),
#         RuleSpec (newline-separated "DisplaySuffix|Protocol|Port" entries)
$script:fwPortRuleBlock = [scriptblock]::Create(@'
param($RuleName, $Title, $Details, $RuleSpec)
'@ + $script:SetupPromptFn + @'
if (-not (Show-SetupBox -Title $Title -Details $Details -ActionLabel "Create rules")) {
    return
}
foreach ($spec in ($RuleSpec -split "[\r\n]+" | Where-Object { $_.Trim() })) {
    $parts = $spec -split "\|"
    New-NetFirewallRule -DisplayName ($RuleName + " " + $parts[0]) `
                        -Direction Inbound -Protocol $parts[1] -LocalPort ([int]$parts[2]) `
                        -Action Allow -Profile Any -ErrorAction Continue | Out-Null
}
Write-Host "  Rules created successfully." -ForegroundColor Green
Start-Sleep -Seconds 1
'@)

# Generic elevated scriptblock: creates inbound + outbound program-based firewall rules.
# Removes existing VR_HEADSET_MANAGER rules first to clear any stale paths.
# Params: RuleName, Program (full exe path), Title, Details
$script:fwProgramRuleBlock = [scriptblock]::Create(@'
param($RuleName, $Program, $Title, $Details)
'@ + $script:SetupPromptFn + @'
if (-not (Show-SetupBox -Title $Title -Details $Details -ActionLabel "Create rules")) {
    return
}
Get-NetFirewallRule | Where-Object DisplayName -ilike "*VR_HEADSET_MANAGER*" | Remove-NetFirewallRule -ErrorAction Continue
New-NetFirewallRule -DisplayName ($RuleName + " [OUT]") -Direction Outbound -Program $Program `
                    -Action Allow -Profile Any -Description "Allow VR Headset Manager ADB connections" `
                    -ErrorAction Continue | Out-Null
New-NetFirewallRule -DisplayName ($RuleName + " [IN]")  -Direction Inbound  -Program $Program `
                    -Action Allow -Description "Allow VR Headset Manager ADB connections" `
                    -ErrorAction Continue | Out-Null
Write-Host "  Rules created successfully." -ForegroundColor Green
Start-Sleep -Seconds 1
'@)

# Elevated scriptblock for MediaMTX: creates inbound port rules (RTSP/HLS/WebRTC)
# AND a program-based inbound+outbound rule for mediamtx.exe in one elevation.
# Params: RuleName, Program (full exe path), Title, Details, RuleSpec
$script:fwMediaMtxBlock = [scriptblock]::Create(@'
param($RuleName, $Program, $Title, $Details, $RuleSpec)
'@ + $script:SetupPromptFn + @'
if (-not (Show-SetupBox -Title $Title -Details $Details -ActionLabel "Create rules")) {
    return
}
foreach ($spec in ($RuleSpec -split "[\r\n]+" | Where-Object { $_.Trim() })) {
    $parts = $spec -split "\|"
    New-NetFirewallRule -DisplayName ($RuleName + " " + $parts[0]) `
                        -Direction Inbound -Protocol $parts[1] -LocalPort ([int]$parts[2]) `
                        -Action Allow -Profile Any -ErrorAction Continue | Out-Null
}
New-NetFirewallRule -DisplayName ($RuleName + " [PROG-OUT]") -Direction Outbound -Program $Program `
                    -Action Allow -Profile Any -Description "Allow MediaMTX outbound" `
                    -ErrorAction Continue | Out-Null
New-NetFirewallRule -DisplayName ($RuleName + " [PROG-IN]")  -Direction Inbound  -Program $Program `
                    -Action Allow -Profile Any -Description "Allow MediaMTX inbound" `
                    -ErrorAction Continue | Out-Null
Write-Host "  Rules created successfully." -ForegroundColor Green
Start-Sleep -Seconds 1
'@)

# Generic elevated scriptblock: registers an HTTP URL ACL via netsh.
# Uses SID S-1-1-0 (Everyone) to avoid locale issues (e.g. French Windows).
# Params: Url
$script:urlAclBlock = [scriptblock]::Create(@'
param($Url)
'@ + $script:SetupPromptFn + @'
$details = @"
Allows the web server to run without admin rights.
URL  : $Url
User : Everyone (locale-independent SID S-1-1-0)
"@
if (-not (Show-SetupBox -Title "HTTP URL RESERVATION REQUIRED" -Details $details -ActionLabel "Register")) {
    return
}
$result = netsh http add urlacl url=$Url sddl="D:(A;;GX;;;S-1-1-0)" 2>&1
Write-Host "  $result" -ForegroundColor Green
Start-Sleep -Seconds 1
'@)


function Unblock-ADBFirewallRule {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AdbPath
    )
    $ruleName = "_[VR_HEADSET_MANAGER]ADB_Allowed"
    if (-not (Test-Path -Path $AdbPath)) {
        Write-Log ($msg.ADBExecutableNotFound -f $AdbPath) -Level ERROR
        return $false
    }
    try {
        $currentNetworkProfile = (Get-NetConnectionProfile).NetworkCategory
        Write-Log ($msg.NetworkProfileCurrent -f $currentNetworkProfile) -Level DEBUG
    } catch {
        Write-Log ($msg.NetworkProfileFailed -f $_) -Level WARNING
    }
    try {
        $rules         = Get-NetFirewallRule | Where-Object DisplayName -ilike "*VR_HEADSET_MANAGER*"
        $existingPaths = ($rules | Where-Object DisplayName -ilike "*ADB*" | Get-NetFirewallApplicationFilter).Program
        $invalidPaths  = $existingPaths | Where-Object { $_ -ne $AdbPath }
        if ((-not $rules) -or $invalidPaths) {
            Write-Log $msg.FirewallRuleCreating -Level INFO
            $title   = "FIREWALL RULE REQUIRED - ADB"
            $details = "Allowing ADB traffic (inbound + outbound)`nProgram : $AdbPath`nProfile : All (Domain, Private, Public)"
            Invoke-AsAdmin -ScriptBlock $script:fwProgramRuleBlock -RuleName $ruleName -Program $AdbPath -Title $title -Details $details
            return $true
        } else {
            Write-Log $msg.FirewallRuleExists -Level DEBUG
            return $true
        }
    } catch {
        Write-Log ($msg.FirewallRuleFailed -f $_) -Level ERROR
        return $false
    }
}


function Get-FwReadyFlagPath {
    return Join-Path $global:ScriptPath "data\fw_ready.flag"
}

# Returns $true if MediaMTX firewall rules exist AND their ports match current config.
# Used to detect port changes in config.json that require rule recreation.
function Test-MediaMtxFirewallCurrent {
    $rtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort   } else { 8554 }
    $hlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort    } else { 8888 }
    $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
    try {
        $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*MediaMtx*" }
        if (-not $rules) { return $false }
        $ports = $rules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                          Select-Object -ExpandProperty LocalPort
        $needed = @([string]$rtspPort, [string]$hlsPort, [string]$webrtcPort)
        foreach ($p in $needed) {
            if ($ports -notcontains $p) { return $false }
        }
        # Also require the program-based rule so mediamtx.exe is not prompted by Windows
        $progRules = $rules | Where-Object { $_.DisplayName -ilike "*PROG*" }
        if (-not $progRules) { return $false }
        $progPaths = $progRules | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
                                  Select-Object -ExpandProperty Program
        if ($progPaths -notcontains $global:mediamtxFilePath) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Unblock-MediaMtxFirewallRule {
    param([switch]$Force)
    if (-not $global:mediamtxEnabled) { Write-Log $msg.MediaMtxNotEnabled -Level DEBUG; return }
    $ruleName   = "_[VR_HEADSET_MANAGER]MediaMtx_Allowed"
    $rtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort   } else { 8554 }
    $hlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort    } else { 8888 }
    $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
    try {
        $existing = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*MediaMtx*" }
        if ($existing -and $Force) {
            Write-Log $msg.MediaMtxFirewallRuleUpdating -Level INFO
            $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            $existing = $null
        }
        if (-not $existing) {
            Write-Log ($msg.MediaMtxFirewallRuleCreating -f $rtspPort, $hlsPort) -Level INFO
            $title   = "FIREWALL RULE REQUIRED - MediaMTX"
            $details = "Allowing inbound streaming ports:`nRTSP   : port $rtspPort  (TCP + UDP)`nHLS    : port $hlsPort  (TCP)`nWebRTC : port $webrtcPort (TCP + UDP)`nProgram: $global:mediamtxFilePath`nProfile: All (Domain, Private, Public)"
            $specs   = "RTSP-TCP [IN]|TCP|$rtspPort`nRTSP-UDP [IN]|UDP|$rtspPort`nHLS-TCP [IN]|TCP|$hlsPort`nWebRTC-TCP [IN]|TCP|$webrtcPort`nWebRTC-UDP [IN]|UDP|$webrtcPort"
            Invoke-AsAdmin -ScriptBlock $script:fwMediaMtxBlock -RuleName $ruleName -Program $global:mediamtxFilePath -Title $title -Details $details -RuleSpec $specs
        } else {
            Write-Log $msg.MediaMtxFirewallRuleExists -Level DEBUG
        }
    } catch {
        Write-Log ($msg.MediaMtxFirewallRuleFailed -f $_) -Level ERROR
    }
}


function Unblock-WebServerFirewallRule {
    if (-not $global:WebServer_enabled) { return }
    $port     = if ($global:WebServer_port) { $global:WebServer_port } else { 8080 }
    $ruleName = "_[VR_HEADSET_MANAGER]WebServer_Allowed"
    try {
        $existing = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*WebServer*" }
        if (-not $existing) {
            Write-Log ($msg.WebServerFirewallRuleCreating -f $port) -Level INFO
            $title   = "FIREWALL RULE REQUIRED - Web Server"
            $details = "Allowing inbound web server connections:`nTCP port : $port (inbound)`nProfile  : All (Domain, Private, Public)"
            $specs   = "TCP [IN]|TCP|$port"
            Invoke-AsAdmin -ScriptBlock $script:fwPortRuleBlock -RuleName $ruleName -Title $title -Details $details -RuleSpec $specs
        } else {
            Write-Log $msg.WebServerFirewallRuleExists -Level DEBUG
        }
    } catch {
        Write-Log ($msg.WebServerFirewallRuleFailed -f $_) -Level ERROR
    }
}


function Register-WebServerUrlAcl {
    if (-not $global:WebServer_enabled) { return }
    $port = if ($global:WebServer_port) { $global:WebServer_port } else { 8080 }
    $url  = "http://+:$port/"
    try {
        $existing = netsh http show urlacl url=$url 2>&1
        if ($existing -match [regex]::Escape($url)) {
            Write-Log ($msg.WebServerUrlAclExists -f $port) -Level DEBUG
        } else {
            Write-Log ($msg.WebServerUrlAclRegistering -f $port) -Level INFO
            Invoke-AsAdmin -ScriptBlock $script:urlAclBlock -Url $url
        }
    } catch {
        Write-Log ($msg.WebServerUrlAclFailed -f $_) -Level ERROR
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

    # Guard: scripts_init.ps1 is dot-sourced on every module reload AND by
    # headsets_dashboard.ps1 in its refresh loop. Only run setup tasks once
    # per PowerShell process to avoid duplicate firewall prompts and UAC windows.
    if ($global:ComputerSetupDone) { return }
    $global:ComputerSetupDone = $true

    # Remove stale flag from a previous run so headsets_dashboard.ps1 waits for
    # this run's setup to complete before starting MediaMTX.
    $flagPath = Get-FwReadyFlagPath
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    if (Test-Path -LiteralPath $flagPath) {
        Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
    }

    # Firewall - ADB
    if (-not (Unblock-ADBFirewallRule -AdbPath $global:adbPath)) {
        Write-Log $msg.FirewallConfigSkipped -Level WARNING
    }

    # Firewall - mediamtx: recreate rules if ports changed since last setup
    $mediamtxRulesOk = Test-MediaMtxFirewallCurrent
    if ($mediamtxRulesOk) {
        Write-Log $msg.MediaMtxFirewallRuleExists -Level DEBUG
    } else {
        Unblock-MediaMtxFirewallRule -Force
    }

    # Firewall - web server port
    Unblock-WebServerFirewallRule

    # HTTP URL ACL - allows Pode to bind on all interfaces without running as admin
    Register-WebServerUrlAcl

    # Write the ready flag so headsets_dashboard.ps1 knows firewall setup is done.
    # Content is the port fingerprint - dashboard deletes the file after reading it.
    $rtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort   } else { 8554 }
    $hlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort    } else { 8888 }
    $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
    [System.IO.File]::WriteAllText($flagPath, "rtsp=$rtspPort;hls=$hlsPort;webrtc=$webrtcPort", $utf8NoBom)

    # Keep the PC awake for the duration of the session
    Set-AwakeMode
}
