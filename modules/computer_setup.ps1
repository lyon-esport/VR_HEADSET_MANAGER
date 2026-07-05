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

# Elevated scriptblock used by Resolve-PortConflict when the operator picks
# the "Kill" option and the in-process Stop-Process call returns access-denied.
# Shows a confirmation box in the admin console (Y/Enter = kill, any other key
# = skip) and runs Stop-Process -Force inside the elevated session.
# Params: ProcPid, ProcName, ProcPath, Port, Protocol, Service
$script:killPidBlock = [scriptblock]::Create(@'
param($ProcPid, $ProcName, $ProcPath, $Port, $Protocol, $Service)
'@ + $script:SetupPromptFn + @'
$details = "PID    : $ProcPid`nProcess: $ProcName`nPath   : $ProcPath`nPort   : $Port/$Protocol"
$title   = "KILL PROCESS - $Service"
if (-not (Show-SetupBox -Title $title -Details $details -ActionLabel "Kill process")) {
    return
}
try {
    Stop-Process -Id ([int]$ProcPid) -Force -ErrorAction Stop
    Write-Host "  Process PID $ProcPid terminated." -ForegroundColor Green
} catch {
    Write-Host ("  Failed to kill PID {0}: {1}" -f $ProcPid, $_.Exception.Message) -ForegroundColor Red
}
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


# Public wrapper around $script:killPidBlock so callers outside this module
# (e.g. Resolve-PortConflict in console_manager.ps1) do not need to know
# about the script-scope variable. Opens one elevated console, shows the
# confirmation box, then Stop-Process -Force.
function Invoke-KillProcessElevated {
    param(
        [Parameter(Mandatory=$true)][int]$ProcPid,
        [Parameter(Mandatory=$true)][string]$ProcName,
        [string]$ProcPath = "",
        [Parameter(Mandatory=$true)][int]$Port,
        [string]$Protocol = "TCP",
        [string]$Service  = ""
    )
    Invoke-AsAdmin -ScriptBlock $script:killPidBlock `
        -ProcPid   $ProcPid `
        -ProcName  $ProcName `
        -ProcPath  $ProcPath `
        -Port      $Port `
        -Protocol  $Protocol `
        -Service   $Service
}


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
    # Reading firewall rules requires admin on some Win10 SKUs (CIM access denied
    # for standard users). Treat any read failure as "cannot determine state"
    # and emit the task so the elevated batch handles it. The elevated script
    # already removes stale *VR_HEADSET_MANAGER* rules first, so re-emitting is safe.
    $rules         = $null
    $existingPaths = $null
    $invalidPaths  = $null
    try {
        $rules = Get-NetFirewallRule -ErrorAction Stop | Where-Object DisplayName -ilike "*VR_HEADSET_MANAGER*"
        $existingPaths = ($rules | Where-Object DisplayName -ilike "*ADB*" | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
        $invalidPaths  = $existingPaths | Where-Object { $_ -ne $AdbPath }
    } catch {
        Write-Log ("Unblock-ADBFirewallRule: cannot read firewall state ({0}) - will request rule creation via elevation." -f $_.Exception.Message) -Level DEBUG
        $rules = $null
    }
    try {
        if ((-not $rules) -or $invalidPaths) {
            Write-Log $msg.FirewallRuleCreating -Level INFO
            # Resolve canonical path so Defender's running-process matcher hits the rule
            # even when the on-disk path contains non-ASCII characters (e.g. "partages").
            $adbResolved = try { (Get-Item -LiteralPath $AdbPath -ErrorAction Stop).FullName } catch { $AdbPath }
            $title   = "FIREWALL RULE REQUIRED - ADB"
            $details = "Allowing ADB traffic (inbound + outbound)`nProgram : $adbResolved`nProfile : All (Domain, Private, Public)"
            if ($ReturnTask) {
                $adbEsc = $adbResolved -replace "'", "''"
                return @{
                    Title       = $title
                    Details     = $details
                    ActionLabel = "Create rules"
                    Script      = @"
Get-NetFirewallRule | Where-Object DisplayName -ilike '*VR_HEADSET_MANAGER*ADB*' | Remove-NetFirewallRule -ErrorAction Continue
New-NetFirewallRule -DisplayName '_[VR_HEADSET_MANAGER]ADB_Allowed [OUT]' -Direction Outbound -Program '$adbEsc' -Action Allow -Profile Any -Description 'Allow VR Headset Manager ADB connections' -ErrorAction Continue | Out-Null
New-NetFirewallRule -DisplayName '_[VR_HEADSET_MANAGER]ADB_Allowed [IN]'  -Direction Inbound  -Program '$adbEsc' -Action Allow -Profile Any -Description 'Allow VR Headset Manager ADB connections' -ErrorAction Continue | Out-Null
"@
                }
            } else {
                Invoke-AsAdmin -ScriptBlock $script:fwProgramRuleBlock -RuleName $ruleName -Program $adbResolved -Title $title -Details $details
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
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
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

# Returns $true if the mDNS responder firewall rule exists (UDP 5353 inbound).
# Port 5353 is fixed by the mDNS standard so there is no drift to detect.
function Test-MdnsFirewallCurrent {
    try {
        $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*mDNS*" }
        if (-not $rules) { return $false }
        $filters = $rules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if (-not $filters) { return $false }
        foreach ($f in @($filters)) {
            if ([string]$f.Protocol -ieq 'UDP' -and [string]$f.LocalPort -eq '5353') { return $true }
        }
        return $false
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
    $apiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort    } else { 9997 }
    try {
        $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*MediaMtx*" }
        if (-not $rules) { return $false }
        $ports = $rules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                          Select-Object -ExpandProperty LocalPort
        $needed = @([string]$rtspPort, [string]$hlsPort, [string]$webrtcPort, [string]$apiPort)
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
    $apiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort    } else { 9997 }
    $progPath   = $global:mediamtxFilePath
    # Resolve canonical path so Defender's running-process matcher hits the rule
    # even when the on-disk path contains non-ASCII characters (e.g. "partages").
    $progResolved = try { (Get-Item -LiteralPath $progPath -ErrorAction Stop).FullName } catch { $progPath }
    try {
        if ($ReturnTask) {
            # Caller already determined rules need updating; return task for batch elevation.
            # Script includes removal of stale rules so the elevated process handles everything.
            Write-Log ($msg.MediaMtxFirewallRuleCreating -f $rtspPort, $hlsPort) -Level INFO
            $title   = "FIREWALL RULE REQUIRED - MediaMTX"
            $details = "Allowing inbound streaming ports:`nRTSP   : port $rtspPort  (TCP + UDP)`nHLS    : port $hlsPort  (TCP)`nWebRTC : port $webrtcPort (TCP + UDP)`nAPI    : port $apiPort  (TCP)`nProgram: $progResolved`nProfile: All (Domain, Private, Public)"
            $progEsc = $progResolved -replace "'", "''"
            return @{
                Title       = $title
                Details     = $details
                ActionLabel = "Create rules"
                Script      = @"
Get-NetFirewallRule | Where-Object { `$_.DisplayName -ilike '*VR_HEADSET_MANAGER*MediaMtx*' } | Remove-NetFirewallRule -ErrorAction Continue
`$rn = '_[VR_HEADSET_MANAGER]MediaMtx_Allowed'
foreach (`$spec in @('RTSP-TCP [IN]|TCP|$rtspPort','RTSP-UDP [IN]|UDP|$rtspPort','HLS-TCP [IN]|TCP|$hlsPort','WebRTC-TCP [IN]|TCP|$webrtcPort','WebRTC-UDP [IN]|UDP|$webrtcPort','API-TCP [IN]|TCP|$apiPort')) {
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
            $details = "Allowing inbound streaming ports:`nRTSP   : port $rtspPort  (TCP + UDP)`nHLS    : port $hlsPort  (TCP)`nWebRTC : port $webrtcPort (TCP + UDP)`nAPI    : port $apiPort  (TCP)`nProgram: $progResolved`nProfile: All (Domain, Private, Public)"
            $specs   = "RTSP-TCP [IN]|TCP|$rtspPort`nRTSP-UDP [IN]|UDP|$rtspPort`nHLS-TCP [IN]|TCP|$hlsPort`nWebRTC-TCP [IN]|TCP|$webrtcPort`nWebRTC-UDP [IN]|UDP|$webrtcPort`nAPI-TCP [IN]|TCP|$apiPort"
            Invoke-AsAdmin -ScriptBlock $script:fwMediaMtxBlock -RuleName $ruleName -Program $progResolved -Title $title -Details $details -RuleSpec $specs
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


function Unblock-MdnsFirewallRule {
    param([switch]$ReturnTask)
    if (-not $global:MdnsResponder_enabled) { return }
    try {
        if (Test-MdnsFirewallCurrent) {
            Write-Log $msg.MdnsFirewallRuleExists -Level DEBUG
            return
        }
        $title   = "FIREWALL RULE REQUIRED - mDNS Responder"
        $details = "Allowing inbound mDNS traffic:`nUDP port : 5353 (inbound)`nProfile  : All (Domain, Private, Public)`n(Any previous VR_HEADSET_MANAGER mDNS rule will be removed first.)"
        if ($ReturnTask) {
            return @{
                Title       = $title
                Details     = $details
                ActionLabel = "Create rule"
                Script      = @"
Get-NetFirewallRule | Where-Object { `$_.DisplayName -ilike '*VR_HEADSET_MANAGER*mDNS*' } | Remove-NetFirewallRule -ErrorAction Continue
New-NetFirewallRule -DisplayName '_[VR_HEADSET_MANAGER]mDNS_Responder UDP [IN]' -Direction Inbound -Protocol UDP -LocalPort 5353 -Action Allow -Profile Any -ErrorAction Continue | Out-Null
"@
            }
        } else {
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -ilike "*VR_HEADSET_MANAGER*mDNS*" } |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue
            $specs = "UDP [IN]|UDP|5353"
            Invoke-AsAdmin -ScriptBlock $script:fwPortRuleBlock -RuleName "_[VR_HEADSET_MANAGER]mDNS_Responder" `
                -Title $title -Details $details -RuleSpec $specs
        }
    } catch {
        Write-Log ("Failed to manage mDNS firewall rule: " + $_) -Level ERROR
    }
}


# Returns $true if the Windows DNS Client has mDNS resolution enabled
# (HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\EnableMDNS = 1 or absent).
function Test-MdnsClientEnabled {
    try {
        $val = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' `
            -Name 'EnableMDNS' -ErrorAction SilentlyContinue).EnableMDNS
        # $null means key absent -> default is enabled; 1 = explicitly enabled; 0 = disabled
        return ($null -eq $val -or $val -eq 1)
    } catch {
        return $true  # assume enabled if registry unreadable
    }
}

# Returns a batch task hashtable to enable mDNS in Windows DNS Client (requires elevation).
# Sets EnableMDNS = 1 and restarts the DNS Client service so the change takes effect.
function Enable-WindowsMdnsClient {
    param([switch]$ReturnTask)
    if (-not $global:MdnsResponder_enabled) { return }
    try {
        if (Test-MdnsClientEnabled) {
            Write-Log "Windows mDNS client already enabled" -Level DEBUG
            return
        }
        Write-Log "Windows mDNS client is disabled - will enable it" -Level INFO
        $title   = "WINDOWS mDNS CLIENT REQUIRED"
        $details = "The Windows DNS Client has mDNS disabled (EnableMDNS=0).`nThis prevents .local name resolution (vrhm.local) on the LAN.`nThe following registry change will be applied:`n  HKLM:\...\Dnscache\Parameters\EnableMDNS = 1`nA REBOOT IS REQUIRED for the change to take effect.`n(The DNS Client service is protected and cannot be restarted at runtime.)"
        if ($ReturnTask) {
            return @{
                Title       = $title
                Details     = $details
                ActionLabel = "Enable mDNS (reboot needed)"
                Script      = @"
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableMDNS' -Value 1 -Type DWord -Force
Write-Host 'mDNS enabled in registry. A reboot is required for vrhm.local resolution to work.' -ForegroundColor Yellow
"@
            }
        } else {
            Invoke-AsAdmin -ScriptBlock {
                Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableMDNS' -Value 1 -Type DWord -Force
            }
        }
    } catch {
        Write-Log ("Failed to enable Windows mDNS client: " + $_) -Level ERROR
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


function Register-WindowsDefenderExclusion {
    param(
        [string]$ExclusionPath = $global:ScriptPath,
        # Pass $priorState from Initialize-ComputerSetup to skip live check when
        # fw_state.json already records that the exclusion was confirmed for this path.
        $PriorState = $null,
        [switch]$ReturnTask
    )
    try {
        # If fw_state.json records ANY prior DefenderExclusionPath, the operator has
        # already been prompted at least once - never re-prompt for Defender exclusion.
        # We deliberately do NOT compare paths here: a mismatch can mean (a) the persisted
        # value was corrupted by an old encoding bug, or (b) the app folder was moved.
        # Re-prompting on move would also be wrong - per product rule, ask once ever.
        # The caller (Initialize-ComputerSetup) heals the persisted value by overwriting
        # with the current $global:ScriptPath when this sentinel returns.
        if ($PriorState -and $PriorState.DefenderExclusionPath) {
            Write-Log $msg.DefenderExclusionSkipped -Level DEBUG
            return @{ AlreadyApplied = $true }
        }
        $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not ($mpStatus -and $mpStatus.AntivirusEnabled -and $mpStatus.RealTimeProtectionEnabled)) {
            Write-Log $msg.DefenderExclusionSkipped -Level DEBUG
            return $null
        }
        $mpPref = Get-MpPreference -ErrorAction SilentlyContinue
        $normalizedPath = $ExclusionPath.TrimEnd('\')
        # Also resolve UNC equivalent for mapped network drives: Defender may store
        # \\server\share\... even when we passed L:\... to Add-MpPreference.
        $uncPath = $null
        if ($ExclusionPath -match '^[A-Za-z]:') {
            $drv = Get-PSDrive ($ExclusionPath.Substring(0, 1)) -ErrorAction SilentlyContinue
            if ($drv -and $drv.DisplayRoot -match '^\\\\') {
                $uncPath = ($drv.DisplayRoot.TrimEnd('\') + $ExclusionPath.Substring(2)).TrimEnd('\')
            }
        }
        $alreadyExcluded = $mpPref -and ($mpPref.ExclusionPath | Where-Object {
            $p = $_.TrimEnd('\')
            $p -ieq $normalizedPath -or ($uncPath -and $p -ieq $uncPath)
        })
        if ($alreadyExcluded) {
            Write-Log $msg.DefenderExclusionSkipped -Level DEBUG
            # Sentinel: live check confirmed the exclusion exists. Initialize-ComputerSetup
            # persists this into fw_state.json so the next run's PriorState short-circuit
            # fires and we never hit the brittle path-normalization comparison again.
            return @{ AlreadyApplied = $true }
        }
        Write-Log ($msg.DefenderExclusionPending -f $ExclusionPath) -Level INFO
        $title       = "WINDOWS DEFENDER EXCLUSION"
        $details     = "Windows Defender real-time scanning may cause high CPU usage`nwhile scrcpy, ffmpeg and ADB processes are running.`n`nExcluding the application folder is strongly recommended.`n`nFolder : $ExclusionPath"
        $actionLabel = "Add exclusion for this folder"
        $pathEsc     = $ExclusionPath -replace "'", "''"
        if ($ReturnTask) {
            return @{
                Title       = $title
                Details     = $details
                ActionLabel = $actionLabel
                Script      = "Add-MpPreference -ExclusionPath '$pathEsc' -ErrorAction SilentlyContinue"
            }
        } else {
            Invoke-AsAdmin -ScriptBlock { param($P) Add-MpPreference -ExclusionPath $P -ErrorAction SilentlyContinue } -P $ExclusionPath
        }
    } catch {
        Write-Log ("Register-WindowsDefenderExclusion: {0}" -f $_.Exception.Message) -Level DEBUG
        return $null
    }
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

    if ($global:MdnsResponder_enabled) {
        if (Test-MdnsFirewallCurrent) {
            Write-Log $msg.MdnsFirewallRuleExists -Level DEBUG
        } else {
            $mdnsTask = Unblock-MdnsFirewallRule -ReturnTask
            if ($mdnsTask -is [hashtable]) { $pendingTasks += $mdnsTask }
        }
        $mdnsClientTask = Enable-WindowsMdnsClient -ReturnTask
        if ($mdnsClientTask -is [hashtable]) { $pendingTasks += $mdnsClientTask }
    }

    $aclTask = Register-WebServerUrlAcl -ReturnTask -PriorState $priorState
    if ($aclTask -is [hashtable]) { $pendingTasks += $aclTask }

    $defenderTask = Register-WindowsDefenderExclusion -ReturnTask -PriorState $priorState
    # Only append actual tasks (with a Script payload). The AlreadyApplied sentinel is a
    # hashtable too but carries no Script - it just signals the live check found the exclusion.
    if ($defenderTask -is [hashtable] -and $defenderTask.Script) { $pendingTasks += $defenderTask }

    # Open one admin console for all pending tasks (zero UAC prompts if nothing to do)
    if ($pendingTasks.Count -gt 0) {
        Invoke-BatchAsAdmin -Tasks $pendingTasks
    }

    # Persist Defender exclusion state. We record the path the moment the task was
    # generated (not after the batch) to avoid a race where Get-MpPreference does
    # not reflect the new exclusion immediately after the elevated process exits.
    # The user has been shown the recommendation; we do not re-prompt on restarts.
    # Always persist the CURRENT $global:ScriptPath when we have any indication the
    # exclusion has been applied (prior state recorded it, or this run presented/confirmed
    # the task). Never carry the prior raw string forward - it may be mojibake from the
    # old UTF-8 encoding bug, and the operator should not be re-prompted to heal it.
    $defenderApplied = ($priorState -and $priorState.DefenderExclusionPath) -or
                       ($defenderTask -is [hashtable] -and ($defenderTask.Script -or $defenderTask.AlreadyApplied))
    $defenderExclusionPath = if ($defenderApplied) { $global:ScriptPath } else { $null }

    # Persist what we just (re)applied so the next run can detect drift.
    # Written even when no tasks ran - the values still describe the live OS state.
    Set-FwState -State @{
        AdbPath               = $global:adbPath
        WebServerPort         = $global:WebServer_port
        MediaMtxRtsp          = $global:mediamtxRtspPort
        MediaMtxHls           = $global:mediamtxHlsPort
        MediaMtxWebrtc        = $global:mediamtxWebrtcPort
        MediaMtxApi           = $global:mediamtxApiPort
        MediaMtxProgram       = $global:mediamtxFilePath
        DefenderExclusionPath = $defenderExclusionPath
        MdnsEnabled           = $global:MdnsResponder_enabled
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
