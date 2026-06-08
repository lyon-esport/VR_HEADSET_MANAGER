##################################
# computer_setup.ps1
# Computer-level setup tasks required for the program to operate correctly.
# Called once at startup from scripts_init.ps1 via Initialize-ComputerSetup.
#
# Responsibilities:
#   - Invoke-AsAdmin              : run a script block elevated (UAC prompt if needed)
#   - Invoke-BatchAsAdmin         : run multiple tasks in a single elevated console
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


function Invoke-BatchAsAdmin {
    <#
    .SYNOPSIS
    Runs multiple firewall/setup tasks in a single elevated console.
    Each task is shown individually so the user can confirm or skip it.
    Tasks are passed as @{Title; Details; ActionLabel; Script} hashtables.
    #>
    param([array]$Tasks)
    if (-not $Tasks -or $Tasks.Count -eq 0) { return }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Serialize tasks to a temp JSON file to avoid Base64/quoting limits
    $tasksFile = Join-Path $env:TEMP ("vrm_fw_tasks_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    $json = $Tasks | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($tasksFile, $json, [System.Text.UTF8Encoding]::new($false))

    if ($isAdmin) {
        & $script:fwBatchBlock -TasksFile $tasksFile
    } else {
        $scriptBlockString = $script:fwBatchBlock.ToString()
        $tasksFileEsc = $tasksFile -replace "'", "''"
        $command = "& { $scriptBlockString } -TasksFile '$tasksFileEsc'"
        $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
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

# Elevated scriptblock used by Invoke-BatchAsAdmin.
# Reads a JSON task file, prompts for each task, runs approved ones in sequence.
$script:fwBatchBlock = [scriptblock]::Create(@'
param($TasksFile)
'@ + $script:SetupPromptFn + @'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$json = [System.IO.File]::ReadAllText($TasksFile, $utf8)
$tasks = $json | ConvertFrom-Json
foreach ($task in $tasks) {
    if (Show-SetupBox -Title $task.Title -Details $task.Details -ActionLabel $task.ActionLabel) {
        Invoke-Expression $task.Script
        Write-Host "  Rules created successfully." -ForegroundColor Green
        Start-Sleep -Seconds 1
    }
}
Remove-Item -LiteralPath $TasksFile -Force -ErrorAction SilentlyContinue
'@)

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
        [string]$AdbPath,
        # When set, returns a task hashtable instead of opening an admin console directly.
        # Used by Initialize-ComputerSetup to batch all tasks into one elevation.
        [switch]$ReturnTask
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
            if ($ReturnTask) {
                $adbEsc = $AdbPath -replace "'", "''"
                return @{
                    Title       = $title
                    Details     = $details
                    ActionLabel = "Create rules"
                    Script      = @"
Get-NetFirewallRule | Where-Object DisplayName -ilike '*VR_HEADSET_MANAGER*' | Remove-NetFirewallRule -ErrorAction Continue
New-NetFirewallRule -DisplayName '_[VR_HEADSET_MANAGER]ADB_Allowed [OUT]' -Direction Outbound -Program '$adbEsc' -Action Allow -Profile Any -Description 'Allow VR Headset Manager ADB connections' -ErrorAction Continue | Out-Null
New-NetFirewallRule -DisplayName '_[VR_HEADSET_MANAGER]ADB_Allowed [IN]'  -Direction Inbound  -Program '$adbEsc' -Action Allow -Description 'Allow VR Headset Manager ADB connections' -ErrorAction Continue | Out-Null
"@
                }
            } else {
                Invoke-AsAdmin -ScriptBlock $script:fwProgramRuleBlock -RuleName $ruleName -Program $AdbPath -Title $title -Details $details
                return $true
            }
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

# ---------------------------------------------------------------------------
# Persistent firewall state (data\fw_state.json)
# Records the values we last successfully applied so a future run can detect
# drift (e.g. user changed WebServer.port) and clean up the previous entries.
# ---------------------------------------------------------------------------
function Get-FwStatePath {
    return Join-Path $global:ScriptPath "data\fw_state.json"
}

function Get-FwState {
    $path = Get-FwStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Set-FwState {
    param([Parameter(Mandatory=$true)] $State)
    $path = Get-FwStatePath
    $json = $State | ConvertTo-Json -Depth 4
    try {
        Write-FileWithoutBom -Path $path -Content $json
    } catch {
        try { Write-Log ("Set-FwState: failed to write fw_state.json: " + $_.Exception.Message) -Level WARNING } catch {}
    }
}

# Returns $true if the WebServer firewall rule(s) exist AND every matching
# rule's LocalPort matches the current $global:WebServer_port.
# Mirror of Test-MediaMtxFirewallCurrent.
function Test-WebServerFirewallCurrent {
    $port = if ($global:WebServer_port) { [string]$global:WebServer_port } else { "8080" }
    try {
        $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*WebServer*" }
        if (-not $rules) { return $false }
        $ports = $rules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                          Select-Object -ExpandProperty LocalPort
        if (-not $ports) { return $false }
        foreach ($p in @($ports)) {
            if ([string]$p -ne $port) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

# Returns $true iff a URL ACL is registered for the current WebServer port.
function Test-WebServerUrlAclCurrent {
    $port = if ($global:WebServer_port) { $global:WebServer_port } else { 8080 }
    $url  = "http://+:$port/"
    try {
        $existing = netsh http show urlacl url=$url 2>&1
        return ($existing -match [regex]::Escape($url))
    } catch {
        return $false
    }
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
    param(
        [switch]$Force,
        # When set, returns a task hashtable instead of opening an admin console directly.
        # Used by Initialize-ComputerSetup to batch all tasks into one elevation.
        [switch]$ReturnTask
    )
    if (-not $global:mediamtxEnabled) { Write-Log $msg.MediaMtxNotEnabled -Level DEBUG; return }
    $ruleName   = "_[VR_HEADSET_MANAGER]MediaMtx_Allowed"
    $rtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort   } else { 8554 }
    $hlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort    } else { 8888 }
    $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
    $progPath   = $global:mediamtxFilePath
    try {
        if ($ReturnTask) {
            # Caller already determined rules need updating; return task for batch elevation.
            # Script includes removal of stale rules so the elevated process handles everything.
            Write-Log ($msg.MediaMtxFirewallRuleCreating -f $rtspPort, $hlsPort) -Level INFO
            $title   = "FIREWALL RULE REQUIRED - MediaMTX"
            $details = "Allowing inbound streaming ports:`nRTSP   : port $rtspPort  (TCP + UDP)`nHLS    : port $hlsPort  (TCP)`nWebRTC : port $webrtcPort (TCP + UDP)`nProgram: $progPath`nProfile: All (Domain, Private, Public)"
            $progEsc = $progPath -replace "'", "''"
            return @{
                Title       = $title
                Details     = $details
                ActionLabel = "Create rules"
                Script      = @"
Get-NetFirewallRule | Where-Object { `$_.DisplayName -ilike '*VR_HEADSET_MANAGER*MediaMtx*' } | Remove-NetFirewallRule -ErrorAction Continue
`$rn = '_[VR_HEADSET_MANAGER]MediaMtx_Allowed'
foreach (`$spec in @('RTSP-TCP [IN]|TCP|$rtspPort','RTSP-UDP [IN]|UDP|$rtspPort','HLS-TCP [IN]|TCP|$hlsPort','WebRTC-TCP [IN]|TCP|$webrtcPort','WebRTC-UDP [IN]|UDP|$webrtcPort')) {
    `$parts = `$spec -split '\|'
    New-NetFirewallRule -DisplayName (`$rn + ' ' + `$parts[0]) -Direction Inbound -Protocol `$parts[1] -LocalPort ([int]`$parts[2]) -Action Allow -Profile Any -ErrorAction Continue | Out-Null
}
New-NetFirewallRule -DisplayName (`$rn + ' [PROG-OUT]') -Direction Outbound -Program '$progEsc' -Action Allow -Profile Any -Description 'Allow MediaMTX outbound' -ErrorAction Continue | Out-Null
New-NetFirewallRule -DisplayName (`$rn + ' [PROG-IN]')  -Direction Inbound  -Program '$progEsc' -Action Allow -Profile Any -Description 'Allow MediaMTX inbound'  -ErrorAction Continue | Out-Null
"@
            }
        }

        # Standalone path (called directly from menus, not via batch)
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
            $details = "Allowing inbound streaming ports:`nRTSP   : port $rtspPort  (TCP + UDP)`nHLS    : port $hlsPort  (TCP)`nWebRTC : port $webrtcPort (TCP + UDP)`nProgram: $progPath`nProfile: All (Domain, Private, Public)"
            $specs   = "RTSP-TCP [IN]|TCP|$rtspPort`nRTSP-UDP [IN]|UDP|$rtspPort`nHLS-TCP [IN]|TCP|$hlsPort`nWebRTC-TCP [IN]|TCP|$webrtcPort`nWebRTC-UDP [IN]|UDP|$webrtcPort"
            Invoke-AsAdmin -ScriptBlock $script:fwMediaMtxBlock -RuleName $ruleName -Program $progPath -Title $title -Details $details -RuleSpec $specs
        } else {
            Write-Log $msg.MediaMtxFirewallRuleExists -Level DEBUG
        }
    } catch {
        Write-Log ($msg.MediaMtxFirewallRuleFailed -f $_) -Level ERROR
    }
}


function Unblock-WebServerFirewallRule {
    param(
        # When set, returns a task hashtable instead of opening an admin console directly.
        # Used by Initialize-ComputerSetup to batch all tasks into one elevation.
        [switch]$ReturnTask
    )
    if (-not $global:WebServer_enabled) { return }
    $port     = if ($global:WebServer_port) { $global:WebServer_port } else { 8080 }
    $ruleName = "_[VR_HEADSET_MANAGER]WebServer_Allowed"
    try {
        if (Test-WebServerFirewallCurrent) {
            Write-Log $msg.WebServerFirewallRuleExists -Level DEBUG
            return
        }
        # Drift detected (no rule OR LocalPort != current $port) - rebuild.
        Write-Log ($msg.WebServerFirewallRuleCreating -f $port) -Level INFO
        $title   = "FIREWALL RULE REQUIRED - Web Server"
        $details = "Allowing inbound web server connections:`nTCP port : $port (inbound)`nProfile  : All (Domain, Private, Public)`n(Any previous VR_HEADSET_MANAGER WebServer rule will be removed first.)"
        if ($ReturnTask) {
            return @{
                Title       = $title
                Details     = $details
                ActionLabel = "Create rules"
                Script      = @"
Get-NetFirewallRule | Where-Object { `$_.DisplayName -ilike '*VR_HEADSET_MANAGER*WebServer*' } | Remove-NetFirewallRule -ErrorAction Continue
New-NetFirewallRule -DisplayName '_[VR_HEADSET_MANAGER]WebServer_Allowed TCP [IN]' -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any -ErrorAction Continue | Out-Null
"@
            }
        } else {
            # Standalone (non-batch) path: drop stale rules first, then create the new one.
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*WebServer*" } |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue
            $specs = "TCP [IN]|TCP|$port"
            Invoke-AsAdmin -ScriptBlock $script:fwPortRuleBlock -RuleName $ruleName -Title $title -Details $details -RuleSpec $specs
        }
    } catch {
        Write-Log ($msg.WebServerFirewallRuleFailed -f $_) -Level ERROR
    }
}


function Register-WebServerUrlAcl {
    param(
        # When set, returns a task hashtable instead of opening an admin console directly.
        # Used by Initialize-ComputerSetup to batch all tasks into one elevation.
        [switch]$ReturnTask,
        # Optional persisted state from a previous run. Used to know which old
        # port's URL ACL must be cleaned up when the port has changed.
        $PriorState = $null
    )
    if (-not $global:WebServer_enabled) { return }
    $port = if ($global:WebServer_port) { $global:WebServer_port } else { 8080 }
    $url  = "http://+:$port/"
    try {
        if (Test-WebServerUrlAclCurrent) {
            Write-Log ($msg.WebServerUrlAclExists -f $port) -Level DEBUG
            return
        }
        Write-Log ($msg.WebServerUrlAclRegistering -f $port) -Level INFO

        $priorPort = $null
        if ($PriorState -and $PriorState.WebServerPort -and ([int]$PriorState.WebServerPort -ne [int]$port)) {
            $priorPort = [int]$PriorState.WebServerPort
        }

        if ($ReturnTask) {
            $cleanupLine = ""
            $details     = "Allows the web server to run without admin rights.`nURL  : $url`nUser : Everyone (locale-independent SID S-1-1-0)"
            if ($priorPort) {
                $cleanupLine = "netsh http delete urlacl url=http://+:$priorPort/ | Out-Null`r`n"
                $details    += "`n(The previous reservation on port $priorPort will be removed first.)"
            }
            return @{
                Title       = "HTTP URL RESERVATION REQUIRED"
                Details     = $details
                ActionLabel = "Register"
                Script      = $cleanupLine + "netsh http add urlacl url=$url sddl=`"D:(A;;GX;;;S-1-1-0)`" | Out-Null"
            }
        } else {
            if ($priorPort) {
                try { netsh http delete urlacl url=("http://+:" + $priorPort + "/") 2>&1 | Out-Null } catch {}
            }
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

    # Load the persisted state from the previous successful run so per-rule
    # drift detection (port changed, program path changed) can also clean up
    # the previously-applied entries instead of leaking them.
    $priorState = Get-FwState

    # Collect all pending firewall/ACL tasks, then open a single admin console for all of them.
    $pendingTasks = @()

    $adbTask = Unblock-ADBFirewallRule -AdbPath $global:adbPath -ReturnTask
    if ($adbTask -is [hashtable]) {
        $pendingTasks += $adbTask
    } elseif ($adbTask -eq $false) {
        Write-Log $msg.FirewallConfigSkipped -Level WARNING
    }

    if (Test-MediaMtxFirewallCurrent) {
        Write-Log $msg.MediaMtxFirewallRuleExists -Level DEBUG
    } else {
        $mtxTask = Unblock-MediaMtxFirewallRule -ReturnTask
        if ($mtxTask -is [hashtable]) { $pendingTasks += $mtxTask }
    }

    $wsTask = Unblock-WebServerFirewallRule -ReturnTask
    if ($wsTask -is [hashtable]) { $pendingTasks += $wsTask }

    $aclTask = Register-WebServerUrlAcl -ReturnTask -PriorState $priorState
    if ($aclTask -is [hashtable]) { $pendingTasks += $aclTask }

    # Open one admin console for all pending tasks (zero UAC prompts if nothing to do)
    if ($pendingTasks.Count -gt 0) {
        Invoke-BatchAsAdmin -Tasks $pendingTasks
    }

    # Persist what we just (re)applied so the next run can detect drift.
    # Written even when no tasks ran - the values still describe the live OS state.
    Set-FwState -State @{
        AdbPath         = $global:adbPath
        WebServerPort   = $global:WebServer_port
        MediaMtxRtsp    = $global:mediamtxRtspPort
        MediaMtxHls     = $global:mediamtxHlsPort
        MediaMtxWebrtc  = $global:mediamtxWebrtcPort
        MediaMtxProgram = $global:mediamtxFilePath
    }

    # Write the ready flag so headsets_dashboard.ps1 knows firewall setup is done.
    # Content is the port fingerprint - dashboard deletes the file after reading it.
    $rtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort   } else { 8554 }
    $hlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort    } else { 8888 }
    $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
    [System.IO.File]::WriteAllText($flagPath, "rtsp=$rtspPort;hls=$hlsPort;webrtc=$webrtcPort", $utf8NoBom)

    # Keep the PC awake for the duration of the session
    Set-AwakeMode
}
