# Display the main menu

# Translations are loaded centrally in scripts_init.ps1 into $global:msg


# Read a single key and classify it into a structured choice.
# Returns @{ Kind; Value; Raw }:
#   Kind = 'Digit'  -> Value = [int]                   (0..9)
#   Kind = 'F'      -> Value = [int] (function key 1..12)
#   Kind = 'Char'   -> Value = [string] uppercase character
#   Kind = 'Enter'  -> Value = $null
#   Kind = 'Escape' -> Value = $null
#   Kind = 'Other'  -> Value = $null
# $Raw is the underlying [ConsoleKeyInfo].
function Read-MenuChoice {
    param(
        [switch]$NoEcho
    )
    $key = [System.Console]::ReadKey($NoEcho.IsPresent)
    $kind = 'Other'; $val = $null

    if ($key.Key -ge [ConsoleKey]::F1 -and $key.Key -le [ConsoleKey]::F12) {
        $kind = 'F'; $val = [int]($key.Key) - [int]([ConsoleKey]::F1) + 1
    } elseif ($key.Key -eq [ConsoleKey]::Enter) {
        $kind = 'Enter'
    } elseif ($key.Key -eq [ConsoleKey]::Escape) {
        $kind = 'Escape'
    } elseif ($key.KeyChar -match '^\d$') {
        $kind = 'Digit'; $val = [int]([string]$key.KeyChar)
    } elseif ($key.KeyChar -match '^[A-Za-z]$') {
        $kind = 'Char'; $val = ([string]$key.KeyChar).ToUpper()
    }
    return @{ Kind = $kind; Value = $val; Raw = $key }
}


# Operator-facing resolver for a single port conflict.
# Tests whether the port is free; if not, shows the offender + a 3-way menu
# ([1] Increment / [2] Manual / [3] Kill) and applies the chosen action.
# Returns:
#   @{ Resolved=$bool; NewPort=<int>; KilledPid=<int|null>; Action=<string> }
# Where Action is one of 'None','Increment','Manual','Kill','Skip'.
# -AllowIncrement:$false collapses the menu to [1] Kill / [2] Skip (used for ADB,
# which is not currently routable through a non-default port).
function Resolve-PortConflict {
    param(
        [Parameter(Mandatory=$true)][string]$Service,
        [Parameter(Mandatory=$true)][int]$CurrentPort,
        [int[]]$Pool = @(),
        [ValidateSet('TCP','UDP','Both')][string]$Protocol = 'TCP',
        [switch]$AllowIncrement
    )

    # ---- 1. Fast path: port is free, nothing to do ------------------------
    if (Test-LocalPortFree -Port $CurrentPort -Protocol $Protocol) {
        return @{ Resolved = $true; NewPort = $CurrentPort; KilledPid = $null; Action = 'None' }
    }

    # ---- 2. Identify the owner -------------------------------------------
    $owner = Get-LocalPortOwner -Port $CurrentPort -Protocol $Protocol
    if (-not $owner) {
        # Port shows busy but no owner found (rare; possibly TIME_WAIT or driver-level).
        Write-Host ""
        Write-Host ("  PORT CONFLICT - {0}" -f $Service) -ForegroundColor Red
        Write-Host ("  Port {0}/{1} is busy but the owning process could not be identified." -f $CurrentPort, $Protocol) -ForegroundColor Yellow
        $owner = @{ Pid = 0; ProcessName = "<unknown>"; ProcessPath = ""; Port = $CurrentPort; Protocol = $Protocol }
    }

    # ---- 3. Display conflict + pre-compute the [1] increment candidate ----
    $title = if ($global:msg -and $global:msg.PortConflictHeader) { $global:msg.PortConflictHeader -f $Service } else { "PORT CONFLICT - $Service" }
    $line1 = if ($global:msg -and $global:msg.PortConflictDetails) { $global:msg.PortConflictDetails -f $CurrentPort, $Protocol, $owner.ProcessName, $owner.Pid } else { "Port $CurrentPort/$Protocol is used by $($owner.ProcessName) (PID $($owner.Pid))" }
    $line2 = if ($global:msg -and $global:msg.PortConflictPath)    { $global:msg.PortConflictPath    -f ($owner.ProcessPath) }                       else { "Path: $($owner.ProcessPath)" }
    Write-Host ""
    Write-Host ("  +" + ("-" * 62) + "+") -ForegroundColor Red
    Write-Host ("  | {0,-62}|" -f $title) -ForegroundColor Red
    Write-Host ("  +" + ("-" * 62) + "+") -ForegroundColor Red
    Write-Host ("    " + $line1) -ForegroundColor Yellow
    if ($owner.ProcessPath) { Write-Host ("    " + $line2) -ForegroundColor DarkGray }
    Write-Host ""

    $candidate = $null
    if ($AllowIncrement -and $Pool -and $Pool.Count -gt 0) {
        $candidate = Find-NextFreePortInPool -Pool $Pool -SkipPort $CurrentPort -Protocol $Protocol
        if (-not $candidate -and $global:msg -and $global:msg.PortNoFreeInPool) {
            Write-Host ("  " + ($global:msg.PortNoFreeInPool -f $Pool[0], $Pool[-1])) -ForegroundColor Yellow
        } elseif (-not $candidate) {
            Write-Host ("  No free port available in the pool ({0}-{1}). Manual entry only." -f $Pool[0], $Pool[-1]) -ForegroundColor Yellow
        }
    }

    # ---- 4. Print the menu ------------------------------------------------
    if ($AllowIncrement) {
        $m1 = if ($candidate -and $global:msg -and $global:msg.PortMenuIncrement) { $global:msg.PortMenuIncrement -f $candidate } `
              elseif ($candidate)                                                 { "[1] Increment port to $candidate" } `
              else                                                                { "[1] Increment port - (no free port in pool)" }
        $m2 = if ($global:msg -and $global:msg.PortMenuManual) { $global:msg.PortMenuManual }            else { "[2] Define new port manually" }
        $m3 = if ($global:msg -and $global:msg.PortMenuKill)   { $global:msg.PortMenuKill   -f $CurrentPort } else { "[3] Kill the process and keep port $CurrentPort" }
        Write-Host ("  " + $m1) -ForegroundColor White
        Write-Host ("  " + $m2) -ForegroundColor White
        Write-Host ("  " + $m3) -ForegroundColor White
    } else {
        $m1 = if ($global:msg -and $global:msg.PortAdbMenuKill) { $global:msg.PortAdbMenuKill -f $owner.Pid, $CurrentPort } else { "[1] Kill the process (PID $($owner.Pid)) and keep port $CurrentPort" }
        $m2 = if ($global:msg -and $global:msg.PortAdbMenuSkip) { $global:msg.PortAdbMenuSkip }                              else { "[2] Skip and proceed anyway" }
        Write-Host ("  " + $m1) -ForegroundColor White
        Write-Host ("  " + $m2) -ForegroundColor White
    }
    $prompt = if ($global:msg -and $global:msg.PortPromptDefault) { $global:msg.PortPromptDefault } else { "  Choice [1]: " }
    Write-Host $prompt -ForegroundColor Yellow -NoNewline
    $choice = Read-MenuChoice

    # ---- 5. Apply the choice ---------------------------------------------
    # Default (Enter) = [1]. Digit 1/2/3 = same; everything else = default.
    $picked = 1
    if ($choice.Kind -eq 'Digit' -and $choice.Value -ge 1 -and $choice.Value -le 3) { $picked = $choice.Value }
    Write-Host ""

    if ($AllowIncrement) {
        switch ($picked) {
            1 {
                if ($candidate) {
                    if ($global:msg -and $global:msg.PortChanged) {
                        Write-Host ("  " + ($global:msg.PortChanged -f $Service, $CurrentPort, $candidate)) -ForegroundColor Green
                    } else {
                        Write-Host ("  {0}: port changed from {1} to {2}." -f $Service, $CurrentPort, $candidate) -ForegroundColor Green
                    }
                    return @{ Resolved = $true; NewPort = $candidate; KilledPid = $null; Action = 'Increment' }
                }
                # No candidate -> fall through to manual
                $picked = 2
            }
        }
        switch ($picked) {
            2 {
                while ($true) {
                    $new = Read-ValidPort -Label "$Service port" -Default $CurrentPort
                    if ($new -eq $CurrentPort) {
                        Write-Host "  Same port - re-checking..." -ForegroundColor DarkGray
                    }
                    if (Test-LocalPortFree -Port $new -Protocol $Protocol) {
                        if ($global:msg -and $global:msg.PortChanged) {
                            Write-Host ("  " + ($global:msg.PortChanged -f $Service, $CurrentPort, $new)) -ForegroundColor Green
                        } else {
                            Write-Host ("  {0}: port changed from {1} to {2}." -f $Service, $CurrentPort, $new) -ForegroundColor Green
                        }
                        return @{ Resolved = $true; NewPort = $new; KilledPid = $null; Action = 'Manual' }
                    }
                    Write-Host ("  Port {0} is also in use. Try another." -f $new) -ForegroundColor Red
                }
            }
            3 {
                $killed = Invoke-PortConflictKill -Owner $owner -Service $Service
                if ($killed -and (Test-LocalPortFree -Port $CurrentPort -Protocol $Protocol)) {
                    return @{ Resolved = $true; NewPort = $CurrentPort; KilledPid = $owner.Pid; Action = 'Kill' }
                }
                # Kill failed or port still busy -> fall back to manual entry
                Write-Host ("  Falling back to manual port entry.") -ForegroundColor Yellow
                while ($true) {
                    $new = Read-ValidPort -Label "$Service port" -Default $CurrentPort
                    if (Test-LocalPortFree -Port $new -Protocol $Protocol) {
                        return @{ Resolved = $true; NewPort = $new; KilledPid = $null; Action = 'Manual' }
                    }
                    Write-Host ("  Port {0} is also in use. Try another." -f $new) -ForegroundColor Red
                }
            }
        }
    } else {
        # ADB degraded menu: [1] Kill (default) / [2] Skip
        if ($picked -le 1) {
            $killed = Invoke-PortConflictKill -Owner $owner -Service $Service
            if ($killed -and (Test-LocalPortFree -Port $CurrentPort -Protocol $Protocol)) {
                return @{ Resolved = $true; NewPort = $CurrentPort; KilledPid = $owner.Pid; Action = 'Kill' }
            }
            Write-Host ("  Kill did not free port {0} - skipping." -f $CurrentPort) -ForegroundColor Yellow
            return @{ Resolved = $false; NewPort = $CurrentPort; KilledPid = $null; Action = 'Skip' }
        } else {
            return @{ Resolved = $false; NewPort = $CurrentPort; KilledPid = $null; Action = 'Skip' }
        }
    }
}


# Internal helper used by Resolve-PortConflict for the "Kill" branch.
# Tries Stop-Process in-process first. On Access-Denied, falls back to
# Invoke-KillProcessElevated (which opens one UAC prompt + confirmation box).
# Returns $true when Stop-Process succeeded somewhere along the chain.
function Invoke-PortConflictKill {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Owner,
        [Parameter(Mandatory=$true)][string]$Service
    )
    if (-not $Owner.Pid -or [int]$Owner.Pid -le 0) {
        Write-Host "  Cannot kill: no PID available." -ForegroundColor Red
        return $false
    }
    # ---- Attempt 1: in-process kill ----
    try {
        Stop-Process -Id ([int]$Owner.Pid) -Force -ErrorAction Stop
        $okMsg = if ($global:msg -and $global:msg.PortKillSucceeded) { $global:msg.PortKillSucceeded -f $Owner.Pid } else { "Process PID $($Owner.Pid) terminated." }
        Write-Host ("  " + $okMsg) -ForegroundColor Green
        return $true
    } catch {
        $needAdmin = $true   # any failure -> try elevation
        $errMsg = $_.Exception.Message
        $warn = if ($global:msg -and $global:msg.PortKillNeedsAdmin) { $global:msg.PortKillNeedsAdmin -f $Owner.Pid, $Owner.ProcessName } else { "Killing PID $($Owner.Pid) ($($Owner.ProcessName)) requires admin rights. A UAC prompt will appear." }
        Write-Host ("  " + $warn) -ForegroundColor Yellow
        try {
            Invoke-KillProcessElevated -ProcPid ([int]$Owner.Pid) `
                                        -ProcName $Owner.ProcessName `
                                        -ProcPath ([string]$Owner.ProcessPath) `
                                        -Port     ([int]$Owner.Port) `
                                        -Protocol ([string]$Owner.Protocol) `
                                        -Service  $Service
            # Re-check: if Get-Process still finds the PID, kill failed (operator skipped, etc.)
            $stillThere = Get-Process -Id ([int]$Owner.Pid) -ErrorAction SilentlyContinue
            if (-not $stillThere) { return $true }
            $failMsg = if ($global:msg -and $global:msg.PortKillFailed) { $global:msg.PortKillFailed -f $Owner.Pid, "operator skipped or process respawned" } else { "Could not kill PID $($Owner.Pid): operator skipped or process respawned" }
            Write-Host ("  " + $failMsg) -ForegroundColor Red
            return $false
        } catch {
            $failMsg = if ($global:msg -and $global:msg.PortKillFailed) { $global:msg.PortKillFailed -f $Owner.Pid, $_.Exception.Message } else { "Could not kill PID $($Owner.Pid): $($_.Exception.Message)" }
            Write-Host ("  " + $failMsg) -ForegroundColor Red
            return $false
        }
    }
}


# Picker scaffolding shared by every "show table -> pick a headset -> do action" sub-menu.
# - Calls $RenderTable to draw the headset list (defaults to Show-HeadsetsTable).
# - Reads a single key. Digits 1..9 select the matching headset (1-based ID).
# - Escape / Q exits the loop; any other key triggers $RenderTable again.
# - On a valid pick, $OnPick is invoked with the selected headset row as -Headset.
# Returns when the user exits.
function Show-HeadsetPickerMenu {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$OnPick,
        [string]$Title = '',
        [scriptblock]$RenderTable = $null
    )
    if (-not $RenderTable) { $RenderTable = { Show-HeadsetsTable } }

    while ($true) {
        Clear-Host
        if ($Title) { Write-Host $Title }
        & $RenderTable | Out-Null

        $headsets = Get-KnownHeadsets
        if (-not $headsets -or $headsets.Count -eq 0) {
            Write-Host $msg.NoKnownHeadsets
            Start-Sleep -Seconds 2
            return
        }

        $choice = Read-MenuChoice
        if ($choice.Kind -eq 'Escape' -or ($choice.Kind -eq 'Char' -and $choice.Value -eq 'Q')) {
            return
        }
        if ($choice.Kind -eq 'Digit' -and $choice.Value -ge 1 -and $choice.Value -le $headsets.Count) {
            $row = $headsets | Where-Object { [int]$_.ID -eq [int]$choice.Value } | Select-Object -First 1
            if ($row) {
                & $OnPick -Headset $row
            }
        }
    }
}


function Show-MainMenu {
    do {

        # Prevent the computer from sleeping while the app is running.
        # Awake mode is independent of the dashboard window visibility.
        Set-AwakeMode

        # Only spawn / respawn the dashboard window when the operator wants it visible.
        # Service supervision is owned by Start-VRMonitor, not the dashboard.
        if ($global:Dashboard_showConsole) {
            $VRMonitorProcess = Get-WmiObject -Class Win32_Process -Filter "ParentProcessId = $PID" | Where-Object { $_.CommandLine -match "headsets_dashboard.ps1" }
            Write-Log ($msg.VRMonitorProcessId -f $VRMonitorProcess.ProcessId) -Level DEBUG

            if (-not $VRMonitorProcess) {
                Write-Host $msg.VRMonitorNotRunning -ForegroundColor Yellow
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
        }

        # Start html monitor update
        Write-htmlMonitor $global:knownHeadsets


        Clear-Host
        Start-Sleep -Milliseconds 200
        Write-Host $msg.MainMenuTitle -ForegroundColor Cyan
        Write-Host $msg.StreamHeadset -BackgroundColor Yellow -ForegroundColor Black
        #Write-Host " I. Check internet connection " -BackgroundColor White -ForegroundColor Black
        Write-Host $msg.AddModifyHeadset -BackgroundColor Green -ForegroundColor DarkMagenta
        Write-Host $msg.ScrcpyTracking -BackgroundColor DarkRed -ForegroundColor White
        Write-Host $msg.ScrcpyOptions -BackgroundColor DarkCyan -ForegroundColor Yellow
        Write-Host $msg.RecordingManagement -BackgroundColor DarkBlue -ForegroundColor White
        Write-Host $msg.FilesFolders -BackgroundColor DarkCyan -ForegroundColor Black
        Write-Host $msg.ServicesManagement -BackgroundColor DarkGray -ForegroundColor White
        Write-Host "C. Configuration" -BackgroundColor DarkBlue -ForegroundColor Cyan
        Write-Host $msg.Quit
        Write-Host $msg.AnyOtherKey
        Write-Host
        Write-Host $msg.KnownHeadsets
        #Start-Sleep -Milliseconds 200
        #Show-HeadsetsTable -FieldsToShow @("ID","Name", "IPAddress", "Ping", "ADBReachable", "SCRCPY")
        #Show-HeadsetsTable
        Show-HeadsetsConfig
        #Show-HeadsetsTableColored -FieldsToShow @("ID","Name", "IPAddress")
        #Write-Host "Name ; Status (OK/KO) ; Battery level ; current application"

        # Show web server LAN URLs if enabled
        if ($global:WebServer_enabled) {
            $lanEntries = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -match '^10\.' -or
                    $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or
                    $_.IPAddress -match '^192\.168\.'
                } | ForEach-Object {
                    $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
                    $isInternalVEthernet = $_.InterfaceAlias -match '^vEthernet\s*\((Default Switch|WSL|NAT)\)'
                    if ($adapter -and -not $isInternalVEthernet) {
                        $isWifi = $adapter.PhysicalMediaType -eq 'Native 802.11' -or $_.InterfaceAlias -match 'Wi-?Fi'
                        $label = if ($isWifi) { '[WiFi]' } else { '[LAN]' }
                        [PSCustomObject]@{ IPAddress = $_.IPAddress; Label = $label }
                    }
                } | Where-Object { $_ }
            if ($lanEntries) {
                Write-Host ""
                Write-Host $msg.WebServerLinksHeader -ForegroundColor DarkCyan
                if ($global:MdnsResponder_enabled -and $global:MdnsResponder_hostname) {
                    Write-Host ("  http://{0}.local/ [mDNS]" -f $global:MdnsResponder_hostname) -ForegroundColor Cyan
                }
                foreach ($entry in $lanEntries) {
                    Write-Host ($msg.WebServerLinkLine -f $entry.IPAddress, $global:WebServer_port, $entry.Label) -ForegroundColor Cyan
                }
            }
        }

        $headsets = @(Get-KnownHeadsets)

        $choice = (Read-Host $msg.EnterChoice).ToUpper()
        
        if ($choice -in $headsets.ID){
            $headsetName = ($headsets | Where-Object { $_.ID -eq $choice }).Name
            $headsetIPAddress = ($headsets | Where-Object { $_.ID -eq $choice }).IPAddress
            $headsetRecording = ($headsets | Where-Object { $_.ID -eq $choice }).Record
            $headsetProfile = ($headsets | Where-Object { $_.ID -eq $choice }).ScrcpyProfile
            if (-not $headsetProfile) { $headsetProfile = "portrait-R-N-45-20" }
            #convert $headsetRecording to boolean
            if ($headsetRecording -in @("True", "true", $true)) {
                $headsetRecording = $true
            } else {
                $headsetRecording = $false
            }

            Write-Log -Message ($msg.TryingConnection -f $headsetName, $headsetIPAddress) -Level "INFO"
            #Check ping headset first !
            if (Test-Connection -ComputerName $headsetIPAddress -Count 1 -Quiet){
                start-screenCopy -displayName $headsetName -headsetIP $headsetIPAddress -recording $headsetRecording -scrcpyProfile $headsetProfile
            }
            else {
                Write-Log -Message ($msg.PingKO -f $headsetIPAddress) -Level "WARNING"
                Start-Sleep -Seconds 5
            }
        }
        else {

            switch ($choice) {
                'A' { Write-Host $msg.AddHeadsetTitle
                        Show-SubMenu-AddHeadset
                    }

                'S' { Write-Host $msg.ScrcpyTrackingTitle
                        Show-SubMenu-scrcpyTracking
                    }
                'M' { Write-Host $msg.ScrcpyOptionsTitle
                        Show-SubMenu-ScrcpyOptions
                    }
                'R' { Write-Host $msg.RecordingTitle
                        Show-SubMenu-Recording
                    }
                'F' { Write-Host $msg.FilesFoldersTitle
                        Show-SubMenu-FilesAndFolders
                    }
                'W' { Show-SubMenu-Services }
                'C' { Show-SubMenu-Config }
                'I' {
                    if (Test-InternetConnectivity) {
                        Write-Host $msg.InternetOK -ForegroundColor Green
                    } else {
                        Write-Host $msg.InternetProblem -ForegroundColor White -BackgroundColor Red
                    }
                    pause
                }
                '0' {
                    Write-Host $msg.Goodbye -ForegroundColor Yellow
                    Invoke-AppShutdown
                    return
                }
                default {
                    Write-Host $msg.Refresh -ForegroundColor Red
                    # Reload all modules and config file
                    $scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
                    if (Test-Path -Path $scripts_init) {
                        . $scripts_init
                    } else {
                        Write-Host "Error: The initialization script is missing!" -ForegroundColor Red
                        exit
                    }
                    # Signal main.ps1 to re-enter Show-MainMenu with the freshly loaded definition
                    $global:MenuReload = $true
                    break
                }
            }
        }
    } while ($choice -ne '0')
} 




function Show-SubMenu-StreamHeadset { # CHOICE 1
    Clear-Host
    Write-Host $msg.SelectHeadsetToStream -BackgroundColor Yellow -ForegroundColor Black
    $headsets = @(get-knownHeadsets)
    if ($headsets.Count -eq 0){
        Write-Host $msg.AddHeadsetFirst -ForegroundColor DarkRed -BackgroundColor White
    }
    else {
        #Show-HeadsetsTable
        Show-HeadsetsTableColored -FieldsToShow @("ID","Name","IPAddress","Ping","ADBWifi","SCRCPY")
        $userInput = $(Read-Host $msg.YourChoiceCancel).ToUpper()
        
        if ($userInput -eq '0') {
            Write-Log -Message $msg.ReturnPrevious -Level "INFO"
        }
        elseif ($userInput -match '^\d+$' -and  $userInput -ge 0 -and $userInput -le $headsets.count) {
            $headsetName = ($headsets | Where-Object { $_.ID -eq $userInput }).Name
            $headsetIPAddress = ($headsets | Where-Object { $_.ID -eq $userInput }).IPAddress
            $headsetRecording = ($headsets | Where-Object { $_.ID -eq $userInput }).Record
            $headsetProfile = ($headsets | Where-Object { $_.ID -eq $userInput }).ScrcpyProfile
            if (-not $headsetProfile) { $headsetProfile = "portrait-R-N-45-20" }
            #convert $headsetRecording to boolean
            if ($headsetRecording -in @("True", "true", $true)) {
                $headsetRecording = $true
            } else {
                $headsetRecording = $false
            }
            Write-Log -Message ($msg.TryingConnection -f $headsetName, $headsetIPAddress) -Level "INFO"
            #Check ping headset first !
            if (Test-Connection -ComputerName $headsetIPAddress -Count 1 -Quiet){
                start-screenCopy -displayName $headsetName  -headsetIP $headsetIPAddress -recording $headsetRecording -scrcpyProfile $headsetProfile
            }
            else {
                Write-Log -Message ($msg.PingKO -f $headsetIPAddress) -Level "WARNING"
                Start-Sleep -Seconds 5
            }
        }
        else {
            Write-Log -Message ($msg.InvalidID -f $userInput) -Level "ERROR"
        }
    }
    
} # TODO


function Show-SubMenu-AddHeadset { #CHOICE 2
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.AddOrModifyHeadset -BackgroundColor Green -ForegroundColor DarkMagenta
    Write-Host $msg.ScanNetworkAdd
    Write-Host $msg.AddManually
    Write-Host $msg.ModifyManually
    Write-Host $msg.RemoveFromList
    Write-Host $msg.LaunchAppMenu
    Write-Host "`t 6. Enable Wifi ADB on a connected headset"
    Write-Host $msg.ReturnPreviousMenu

    $userInput = Read-Host $msg.YourChoice

    switch ($userInput) {
        '1' {
            Write-Log -Message $msg.NetworkScanLaunch -Level "INFO"
            Add-Headset-ScanNetwork #-port 
        }

        '2' {
            Write-Log -Message $msg.ManualAdd -Level "INFO"
            Add-Headset-Manually
        }

        '3' {
            Write-Log -Message $msg.ManualModify -Level "INFO"
            Show-SubMenu-EditHeadset
        }
        '4' {
            Write-Host $msg.RemoveHeadset #OK
            Show-SubMenu-RemoveHeadset 
        }
        '5' {
            Show-SubMenu-LaunchApp
        }
        '6' {
            Write-Host $msg.WifiADBActivation
            Enable-WiFiADB
        }
        '0' {
            Write-Log -Message $msg.ReturnPrevious -Level "INFO"
        }

        default {
            Write-Log -Message $msg.InvalidOptionAdd -Level "ERROR"
            Write-Host $msg.InvalidOption -ForegroundColor Yellow
        }
    }
}  # PARTIAL

function Show-SubMenu-EditHeadset { #CHOICE 3
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.ModifyHeadsetManually -BackgroundColor DarkCyan

    $headsets = @(Get-KnownHeadsets)
    if (-not $headsets -or $headsets.Count -eq 0) {
        Write-Log -Message $msg.NoHeadsetToModify -Level "WARNING"
        Write-Host $msg.NoHeadsetToModify -ForegroundColor Yellow
        return
    }

    Show-HeadsetsTableColored

    $idInput = Read-Host $msg.EnterIDToModify
    if ($idInput -eq '0') {
        Write-Log $msg.ReturnFromEdit -Level "INFO"
        return
    }

    if (-not ($idInput -match '^\d+$') -or [int]$idInput -lt 1 -or [int]$idInput -gt $headsets.Count) {
        Write-Log ($msg.InvalidIDModification -f $idInput) -Level "ERROR"
        Write-Host $msg.InvalidIDRetry -ForegroundColor Red
        return
    }

    # List of modifiable fields with numbers
    $availableFields = @(
        $msg.FieldName,
        $msg.FieldIPAddress,
        $msg.FieldScrcpyAutoRestart,
        $msg.FieldRecording,
        $msg.FieldScrcpyProfile
    )

    Write-Host $msg.ModifiableFields
    $availableFields | ForEach-Object { Write-Host $_ }

    # Ask the user to enter the field number
    $fieldNum = Read-Host $msg.EnterFieldNumber
    if ($fieldNum -eq '1') {
        $field = "Name"
    } elseif ($fieldNum -eq '2') {
        $field = "IPAddress"
    } elseif ($fieldNum -eq '3') {
        $field = "scrcpy_AutoRestart"
    } elseif ($fieldNum -eq '4') {
        $field = "Record"
    } elseif ($fieldNum -eq '5') {
        $field = "ScrcpyProfile"
    } elseif ($fieldNum -eq '6') {
        $field = "SerialNumber"
    } else {
        Write-Log ($msg.InvalidFieldNumberEntered -f $fieldNum) -Level "ERROR"
        Write-Host $msg.InvalidFieldNumber -ForegroundColor Red
        return
    }

    if ($field -in @("scrcpy_AutoRestart", "Record")) {
        $currentValue = ($headsets | Where-Object { $_.ID -eq [int]$idInput }).$field
        Write-Host ($msg.CurrentValue -f $field, $currentValue)
        $newValueInput = Read-Host ($msg.EnterNewValueBool -f $field)
        if ($newValueInput -in @("True", "true", "False", "false")) {
            $newValue = [System.Convert]::ToBoolean($newValueInput)
        } else {
            Write-Log ($msg.InvalidBoolValueField -f $field, $newValueInput) -Level "ERROR"
            Write-Host $msg.InvalidBoolValue -ForegroundColor Red
            return
        }
    } elseif ($field -eq "ScrcpyProfile") {
        Show-SubMenu-ScrcpyOptions -HeadsetID ([int]$idInput)
        return
    } else {
        # Ask for the new value for the selected field
        $newValue = Read-Host ($msg.EnterNewValue -f $field)
    }

    # Update the headset with the new parameters
    Update-HeadsetField -ID ([int]$idInput) -Field $field -NewValue $newValue
} # OK

function Get-FavoriteAppsCachePath {
    param ([string]$headsetName)
    return Join-Path $global:ScriptPath "data\$(Convert-Displayname $headsetName)_favorite_apps.csv"
}

function Get-FavoriteApps {
    param ([string]$headsetName = '')
    $csvPath = if ($headsetName) { Get-FavoriteAppsCachePath $headsetName } else { Join-Path $global:ScriptPath "data\favorite_apps.csv" }
    if (-not (Test-Path -LiteralPath $csvPath)) { return @() }
    return @(Import-Csv -LiteralPath $csvPath -Delimiter ",")
}

function Save-FavoriteApps {
    param ([array]$favorites, [string]$headsetName = '')
    $csvPath = if ($headsetName) { Get-FavoriteAppsCachePath $headsetName } else { Join-Path $global:ScriptPath "data\favorite_apps.csv" }
    if ($favorites.Count -eq 0) {
        Set-Content -LiteralPath $csvPath -Value '"PackageName","DisplayName"' -Encoding UTF8
    } else {
        $favorites | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Force
    }
}

function Show-SubMenu-LaunchApp {
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.LaunchAppTitle -BackgroundColor DarkCyan -ForegroundColor White

    # Step 1: select headset
    $headsets = @(Get-KnownHeadsets)
    if (-not $headsets -or $headsets.Count -eq 0) {
        Write-Host $msg.LaunchAppNoHeadsets -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return
    }

    Write-Host ""
    Write-Host $msg.LaunchAppSelectHeadset -ForegroundColor Cyan
    Show-HeadsetsConfig
    Write-Host $msg.ReturnPreviousMenu
    $headsetChoice = Read-Host $msg.YourChoice
    if ($headsetChoice -eq '0') { return }

    $headset = $headsets | Where-Object { $_.ID -eq $headsetChoice }
    if (-not $headset) {
        Write-Log ($msg.InvalidID -f $headsetChoice) -Level WARNING
        Start-Sleep -Seconds 2
        return
    }

    # Step 2: load installed apps - from per-headset cache file first, live ADB fallback
    Clear-Host
    Write-Host $msg.LaunchAppTitle -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host ""
    Write-Host ($msg.LaunchAppLoadingApps -f $headset.Name) -ForegroundColor DarkGray
    $safeName  = Convert-Displayname $headset.Name
    $cachePath = Join-Path $global:ScriptPath "data\${safeName}_installed_apps.csv"
    if (Test-Path $cachePath) {
        $installedApps = @(Import-Csv -Path $cachePath -Delimiter "," | ForEach-Object {
            [PSCustomObject]@{ PackageName = $_.PackageName; DisplayName = $_.DisplayName; IconUrl = $_.IconUrl }
        })
    } else {
        $wifiDevice = Get-BestAdbDevice -Headset $headset
        $installedApps = if ($wifiDevice) { @(Get-HeadsetInstalledApps -Device $wifiDevice -ThirdPartyOnly) } else { @() }
    }
    if ($installedApps.Count -eq 0) {
        Write-Host $msg.LaunchAppNoApps -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return
    }

    do {
        $favorites = @(Get-FavoriteApps -headsetName $headset.Name)
        $favPkgs   = $favorites | Select-Object -ExpandProperty PackageName

        # Build display list: Meta Home always first, then other favorites, then the rest
        $metaHomePkg = 'com.oculus.vrshell'
        $metaHomeApp = $installedApps | Where-Object { $_.PackageName -eq $metaHomePkg }
        if (-not $metaHomeApp) {
            $metaHomeApp = [PSCustomObject]@{ PackageName = $metaHomePkg; DisplayName = 'Meta Home'; IconUrl = '' }
        }
        $favApps    = @($installedApps | Where-Object { $_.PackageName -ne $metaHomePkg -and $favPkgs -contains $_.PackageName })
        $nonFavApps = @($installedApps | Where-Object { $_.PackageName -ne $metaHomePkg -and $favPkgs -notcontains $_.PackageName })
        $displayList = @($metaHomeApp) + @($favApps) + @($nonFavApps)

        Clear-Host
        Write-Host $msg.LaunchAppTitle -BackgroundColor DarkCyan -ForegroundColor White
        Write-Host " Headset: $($headset.Name) [$($headset.IPAddress)]" -ForegroundColor Gray
        Write-Host ""
        Write-Host $msg.LaunchAppSelectApp -ForegroundColor Cyan
        Write-Host ""

        $index = 1
        $metaSectionShown = $false
        $favSectionShown  = $false
        $allSectionShown  = $false

        foreach ($app in $displayList) {
            $isMetaHome = $app.PackageName -eq $metaHomePkg
            $isFav      = $favPkgs -contains $app.PackageName

            if ($isMetaHome -and -not $metaSectionShown) {
                Write-Host "  [Meta Home]" -ForegroundColor Cyan
                $metaSectionShown = $true
            }
            if (-not $isMetaHome -and $isFav -and -not $favSectionShown) {
                Write-Host ""
                Write-Host "  $($msg.LaunchAppFavorites)" -ForegroundColor Yellow
                $favSectionShown = $true
            }
            if (-not $isMetaHome -and -not $isFav -and -not $allSectionShown) {
                Write-Host ""
                Write-Host "  $($msg.LaunchAppAllApps)" -ForegroundColor DarkGray
                $allSectionShown = $true
            }

            $star  = if ($isMetaHome) { 'H' } elseif ($isFav) { '*' } else { ' ' }
            $label = if ($app.DisplayName -and $app.DisplayName -ne $app.PackageName) { $app.DisplayName } else { $app.PackageName }
            $color = if ($isMetaHome) { 'Cyan' } elseif ($isFav) { 'Yellow' } else { 'Gray' }
            Write-Host ("  [{0,3}] {1} {2}" -f $index, $star, $label) -ForegroundColor $color
            $index++
        }

        Write-Host ""
        Write-Host "  [0]   Return" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Enter a number to launch, F<n> to toggle favorite (e.g. F1, F12):" -ForegroundColor White
        $menuInput = (Read-Host " >>").Trim()

        if ($menuInput -eq '0') { return }

        # Toggle favorite: F<number>
        if ($menuInput -match '^[Ff](\d+)$') {
            $favIdx = [int]$Matches[1] - 1
            if ($favIdx -lt 0 -or $favIdx -ge $displayList.Count) {
                Write-Log ($msg.LaunchAppInvalidChoice -f $menuInput) -Level WARNING
                Start-Sleep -Seconds 2
                continue
            }
            $targetApp = $displayList[$favIdx]
            if ($favPkgs -contains $targetApp.PackageName) {
                # Remove from favorites
                $favorites = @($favorites | Where-Object { $_.PackageName -ne $targetApp.PackageName })
                Save-FavoriteApps -favorites $favorites -headsetName $headset.Name
                Write-Log ($msg.LaunchAppFavRemoved -f $targetApp.DisplayName) -Level INFO
                Write-Host ($msg.LaunchAppFavRemoved -f $targetApp.DisplayName) -ForegroundColor DarkGray
            } else {
                # Add to favorites
                $favorites += [PSCustomObject]@{ PackageName = $targetApp.PackageName; DisplayName = $targetApp.DisplayName }
                Save-FavoriteApps -favorites $favorites -headsetName $headset.Name
                Write-Log ($msg.LaunchAppFavAdded -f $targetApp.DisplayName) -Level INFO
                Write-Host ($msg.LaunchAppFavAdded -f $targetApp.DisplayName) -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 800
            continue
        }

        # Launch: plain number
        if ($menuInput -match '^\d+$') {
            $launchIdx = [int]$menuInput - 1
            if ($launchIdx -lt 0 -or $launchIdx -ge $displayList.Count) {
                Write-Log ($msg.LaunchAppInvalidChoice -f $menuInput) -Level WARNING
                Start-Sleep -Seconds 2
                continue
            }
            $targetApp = $displayList[$launchIdx]
            Write-Host ($msg.LaunchAppLaunching -f $targetApp.DisplayName, $headset.Name) -ForegroundColor Cyan
            $wifiDevice = Get-BestAdbDevice -Headset $headset
            $ok = if ($wifiDevice) { Invoke-HeadsetApp -Device $wifiDevice -PackageName $targetApp.PackageName } else { $false }
            if ($ok) {
                Write-Host $msg.LaunchAppSuccess -ForegroundColor Green
            } else {
                Write-Host $msg.LaunchAppFailed -ForegroundColor Red
            }
            Start-Sleep -Seconds 2
            continue
        }

        Write-Log ($msg.LaunchAppInvalidChoice -f $menuInput) -Level WARNING
        Start-Sleep -Seconds 2

    } while ($true)
}


function Show-SubMenu-RemoveHeadset {     # Check whether headsets exist in the file
    Clear-Host
    Start-Sleep -Milliseconds 200
    $headsets = @(get-knownHeadsets) # @() ensures the object is an array so .Count works
    if (-not $headsets) {
        Write-Log -Message $msg.NoHeadsetFound -Level "INFO"
        Write-Host "There is no headset to delete." -ForegroundColor Yellow
        return
    }

    Write-Host $msg.RemoveHeadsetTitle -BackgroundColor DarkMagenta
    Show-HeadsetsTableColored
    Write-Host ($msg.EnterIDToDelete -f $headsets.Count)
    Write-Host $msg.DeleteAll
    Write-Host $msg.ReturnPreviousOption
    # Ask the user to enter an ID, 'ALL', or '0' to return
    $userInput = $(Read-Host " Your choice >>").ToUpper() #ToUpper = Convert user input to uppercase for case-insensitive comparison

    # If the user enters 'ALL', delete all headsets
    if ($userInput -eq 'ALL') {
        # Ask for confirmation before deleting all headsets
        $confirmation = $(Read-Host $msg.ConfirmDeleteAll).ToUpper()
        if ($confirmation -eq 'Y') {
            # Delete all headsets by calling Remove-KnownHeadset without specifying criteria
            Clear-Content -Path $global:knownHeadsetsFilePath -Force
            Write-Log -Message $msg.AllDeleted -Level "INFO"
            Write-Host $msg.AllDeletedMsg -ForegroundColor green
        } else {
            Write-Log -Message $msg.DeletionCancelled -Level "INFO"
        }
    }
    # If the user enters '0', return to the previous menu
    elseif ($userInput -eq '0') {
        Write-Log -Message $msg.ReturnPrevious -Level "INFO"
    }
        # If the user enters a specific ID, call Remove-Headset
    elseif ($userInput -match '^\d+$' -and $userInput -ge 0 -and $userInput -le $headsets.Count) {
        Remove-Headset -ID $userInput
    }
    else {
        Write-Log -Message $msg.InvalidIDOrOption -Level "ERROR"
    }
} # OK

function Show-SubMenu-ManageHeadset { #CHOICE 4
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.ManageHeadset -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host $msg.InstallOculusApp
    Write-Host $msg.EnableWifiADBOnly
    Write-Host $msg.InstallApp
    Write-Host $msg.LaunchApp
    Write-Host $msg.KillApp
    Write-Host $msg.UninstallApp

    Write-Host $msg.ReturnPreviousMenu
    $userInput = $(Read-Host $msg.YourChoice).ToUpper() #ToUpper = Convert user input to uppercase for case-insensitive comparison

    if ($userInput -eq '1') {
        Write-Host $msg.InstallOculusTitle
        Install-OculusWirelessAdbApk
    }
    
    elseif ($userInput -eq '2') {
        Write-Host $msg.StartWifiADB
        Enable-WiFiADB
    }
    elseif ($userInput -in ('3','4','5','6')) {
        Write-Host $msg.AppManager
        Write-Log $msg.NotDeveloped -Level WARNING
                    #list headsets
                    #create a function get-headsetInstalledApps
                    #create a function start-headsetInstalledApp
    }
    elseif ($userInput -eq '0') {
        Write-Log -Message $msg.ReturnPrevious -Level "INFO"
    }
    else {
        Write-Log -Message $msg.UnrecognizedOption -Level "ERROR"
        Write-Log -Message $msg.ReturnMainMenu -Level "INFO"
    }
} # TODO

function Show-SubMenu-scrcpyTracking { #CHOICE 5
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host $msg.SwitchScrcpyTracking -ForegroundColor Cyan
    #Write-Host "Menu disabled for now!"
    Write-Host $msg.EnterNumberToModify
    #Write-Host "1. Enable automatic scrcpy restart"
    #Write-Host "2. Disable automatic scrcpy restart"
    #Write-Host "3. Launch active monitoring of running windows"
    
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
    }
    else {
        write-host $msg.IDNameAutoRestart
        Write-Host $msg.Separator
        $headsets | ForEach-Object {
            $autoRestartText = $_.scrcpy_AutoRestart
            $autoRestartColor = if (ConvertTo-BoolField $autoRestartText) { "Green" } else { "Red" }
            
            Write-Host "$($_.ID) `t $($_.Name) `t`t " -NoNewline
            Write-Host $autoRestartText -ForegroundColor $autoRestartColor
        }
    }
    Write-Host $msg.Return
    Write-Host ""
    
    $choice = Read-Host $msg.Choice

    if ($choice -in $headsets.ID){
        if (ConvertTo-BoolField $headsets[$choice-1].scrcpy_AutoRestart) {
            Write-Log -Message ($msg.DeactivateAutoTracking -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].scrcpy_AutoRestart = $false
        } else {
            Write-Log -Message ($msg.ActivateAutoTracking -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].scrcpy_AutoRestart = $true
        }
        # Save changes to the CSV file
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
}

function Show-SubMenu-Recording { #CHOICE 6
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host $msg.SwitchRecording -ForegroundColor Cyan
    Write-Host $msg.EnterNumberToModify
    
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
    }
    else {
        write-host $msg.IDNameRecording
        Write-Host $msg.Separator
        $headsets | ForEach-Object {
            $recordingText = $_.Record
            $recordingColor = if (ConvertTo-BoolField $recordingText) { "Green" } else { "Red" }
            
            Write-Host "$($_.ID) `t $($_.Name) `t " -NoNewline
            Write-Host $recordingText -ForegroundColor $recordingColor
        }
    }
    Write-Host $msg.Return
    Write-Host ""
    
    $choice = Read-Host $msg.Choice

    if ($choice -in $headsets.ID){
        if (ConvertTo-BoolField $headsets[$choice-1].Record) {
            Write-Log -Message ($msg.DeactivateRecording -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].Record = $false
        } else {
            $driveInfo = Get-RecordingDriveInfo
            if ($driveInfo -and $driveInfo.IsLow) {
                Write-Host ""
                Write-Host ("[WARNING] Recording drive {0}: only {1} GB free (minimum: {2} GB). Recording cannot be enabled." -f $driveInfo.DriveLetter, $driveInfo.FreeGB, $driveInfo.MinFreeGB) -ForegroundColor Red
                Write-Host "Options: [C] Change record folder   [L] Change minimum space limit   [Enter] Cancel" -ForegroundColor Yellow
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'C') {
                    Write-Host "Edit 'scrcpy.recordFolder' in config.json to point to a drive with more space." -ForegroundColor Cyan
                } elseif ($key.Key -eq 'L') {
                    Write-Host "Edit 'scrcpy.recordMinFreeSpaceGB' in config.json to lower the required free space." -ForegroundColor Cyan
                }
                Start-Sleep -Seconds 2
                break
            }
            Write-Log -Message ($msg.ActivateRecording -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].Record = $true
        }
        # Save changes to the CSV file
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
} # OK


function Show-SubMenu-ScrcpyOptions {
    param (
        [int]$HeadsetID = 0
    )
    $headsets = @(Get-KnownHeadsets)
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
        return
    }

    # If a specific headset ID was passed, skip the picker and go straight to edit
    if ($HeadsetID -gt 0) {
        $headset = $headsets | Where-Object { $_.ID -eq $HeadsetID }
        if (-not $headset) {
            Write-Log ($msg.InvalidID -f $HeadsetID) -Level WARNING
            return
        }
        $idInput = "$HeadsetID"
        # Jump directly into the inner edit loop below
    } else {
        $idInput = $null
    }

    do {
        if (-not $idInput) {
            Clear-Host
            Start-Sleep -Milliseconds 100
            Write-Host $msg.ScrcpyOptionsTitle -ForegroundColor Cyan
            Write-Host $msg.ScrcpyOptionsSelectHeadset
            Write-Host $msg.IDNameScrcpyProfile
            Write-Host $msg.Separator
            $headsets | ForEach-Object {
                $profileText = if ($_.ScrcpyProfile) { $_.ScrcpyProfile } else { "R-N-45-20" }
                Write-Host "$($_.ID)`t$($_.Name.PadRight(16))`t$profileText"
            }
            Write-Host $msg.Return
            Write-Host ""

            $idInput = Read-Host $msg.Choice
            if ($idInput -eq '0') { return }

            $headset = $headsets | Where-Object { $_.ID -eq $idInput }
            if (-not $headset) {
                Write-Log ($msg.InvalidID -f $idInput) -Level WARNING
                Start-Sleep -Seconds 2
                $idInput = $null
                continue
            }
        }

        # Inner loop: edit individual profile fields for the selected headset
        do {
            $scrcpyProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "portrait-R-N-45-20" }
            $parts = $scrcpyProfile -split '-'
            # Backward compat: 4-part legacy (Eye-Audio-FPS-BW) -> prepend "portrait"
            if ($parts.Count -eq 4 -and $parts[0] -in @('L','R')) { $parts = @('portrait') + $parts }
            if ($parts.Count -ne 5) { $parts = @('portrait','R','N','45','20') }
            $view  = $parts[0].ToLower()
            $eye   = $parts[1].ToUpper()
            $audio = $parts[2].ToUpper()
            $fps   = $parts[3]
            $bw    = $parts[4]
            $eyeLabel   = if ($eye   -eq 'L') { 'Left'      } else { 'Right' }
            $audioLabel = if ($audio -eq 'D') { 'Duplicate' } else { 'No audio' }

            # Collect available view names for the headset model
            $headsetModel   = ($headsets | Where-Object { $_.ID -eq $idInput }).Model
            $availableViews = @()
            if ($headsetModel -and $global:scrcpyParameters.$headsetModel -and $global:scrcpyParameters.$headsetModel.views) {
                $availableViews = @($global:scrcpyParameters.$headsetModel.views | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
            }
            if ($availableViews.Count -eq 0) { $availableViews = @('portrait','square','wide') }
            # Built-in non-removable view: works on any headset, no per-model crop entry needed.
            if ('fullscreen' -notin $availableViews) { $availableViews += 'fullscreen' }
            $viewList = $availableViews -join ', '

            Clear-Host
            Write-Host "$($msg.ScrcpyOptionsTitle) - $($headset.Name)" -ForegroundColor Cyan
            Write-Host $msg.Separator
            Write-Host " [#]  $($msg.ScrcpyOptTableHeader)"
            Write-Host $msg.Separator
            Write-Host " [1]  $("View".PadRight(16)) : $view  ($viewList)"
            Write-Host " [2]  $($msg.ScrcpyOptEyeLabel.PadRight(16)) : $eyeLabel"
            Write-Host " [3]  $($msg.ScrcpyOptAudioLabel.PadRight(16)) : $audioLabel"
            Write-Host " [4]  $($msg.ScrcpyOptFPSLabel.PadRight(16)) : $fps"
            Write-Host " [5]  $($msg.ScrcpyOptBitrateLabel.PadRight(16)) : $bw"
            Write-Host " [0]  $($msg.Return)"

            $opt = Read-Host $msg.ScrcpyOptionsEnterOption

            switch ($opt) {
                '1' {
                    Write-Host "  Available views:"
                    for ($vi = 0; $vi -lt $availableViews.Count; $vi++) {
                        $marker = if ($availableViews[$vi] -eq $view) { '*' } else { ' ' }
                        Write-Host ("    {0}. {1} {2}" -f ($vi + 1), $availableViews[$vi], $marker)
                    }
                    $numInput = Read-Host ("  Select view (1-{0}, current: {1})" -f $availableViews.Count, $view)
                    if ($numInput -match '^\d+$') {
                        $numIdx = [int]$numInput - 1
                        if ($numIdx -ge 0 -and $numIdx -lt $availableViews.Count) {
                            $parts[0] = $availableViews[$numIdx]
                        } else {
                            Write-Host ("  Invalid choice. Enter a number between 1 and {0}." -f $availableViews.Count) -ForegroundColor Red
                            Start-Sleep -Seconds 2
                        }
                    } else {
                        Write-Host "  Invalid input. Enter a number." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '2' {
                    $val = (Read-Host ($msg.ScrcpyOptionsEye -f $eye)).ToUpper()
                    if ($val -in @('L','R')) {
                        $parts[1] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidEye -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '3' {
                    $val = (Read-Host ($msg.ScrcpyOptionsAudio -f $audio)).ToUpper()
                    if ($val -in @('D','N')) {
                        $parts[2] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidAudio -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '4' {
                    $val = Read-Host ($msg.ScrcpyOptionsFPS -f $fps)
                    if ($val -match '^\d+$' -and [int]$val -gt 0) {
                        $parts[3] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidNumber -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '5' {
                    $val = Read-Host ($msg.ScrcpyOptionsBitrate -f $bw)
                    if ($val -match '^\d+$' -and [int]$val -gt 0) {
                        $parts[4] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidNumber -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '0' { break }
                default { }
            }

            if ($opt -in @('1','2','3','4','5')) {
                $newProfile = $parts -join '-'
                $headset.ScrcpyProfile = $newProfile
                Update-HeadsetField -ID ([int]$headset.ID) -Field "ScrcpyProfile" -NewValue $newProfile
                # Refresh local array so the outer list reflects the change
                $headsets = @(Get-KnownHeadsets)
                $headset = $headsets | Where-Object { $_.ID -eq $idInput }
                Write-Log ($msg.ScrcpyOptionsSaved -f $headset.Name, $newProfile) -Level INFO
            }
        } while ($opt -ne '0')

        # When called with a specific HeadsetID, return after editing that headset
        if ($HeadsetID -gt 0) { return }
        $idInput = $null

    } while ($true)
}


function Show-SubMenu-Services {
    do {
        Clear-Host
        Write-Host $msg.ServicesTitle -ForegroundColor Cyan

        # --- Web server status ---
        $wsPidFile = Join-Path $global:ScriptPath "data\webserver.pid"
        $wsPid     = $null
        if (Test-Path $wsPidFile) {
            $wsPid = [int](Get-Content $wsPidFile -Raw -ErrorAction SilentlyContinue)
        }
        $wsRunning = $wsPid -and (Get-Process -Id $wsPid -ErrorAction SilentlyContinue)
        $wsStatus  = if ($wsRunning) { $msg.ServicesRunning -f $wsPid } else { $msg.ServicesStopped }
        Write-Host ($msg.ServicesWebServerStatus -f $wsStatus) -ForegroundColor $(if ($wsRunning) { 'Green' } else { 'Red' })

        # --- MediaMtx status ---
        $mtxProc   = Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue | Select-Object -First 1
        $mtxStatus = if ($mtxProc) { $msg.ServicesRunning -f $mtxProc.Id } else { $msg.ServicesStopped }
        Write-Host ($msg.ServicesMediaMtxStatus -f $mtxStatus) -ForegroundColor $(if ($mtxProc) { 'Green' } else { 'Red' })

        Write-Host ""
        Write-Host $msg.VideoRecast              -BackgroundColor DarkMagenta -ForegroundColor White
        Write-Host $msg.ServicesChoiceWebServer  -BackgroundColor DarkBlue -ForegroundColor White
        Write-Host $msg.ServicesChoiceStopWS     -BackgroundColor DarkBlue -ForegroundColor White
        Write-Host $msg.ServicesChoiceMediaMtx   -BackgroundColor DarkMagenta -ForegroundColor White
        Write-Host $msg.ServicesChoiceStopMtx    -BackgroundColor DarkMagenta -ForegroundColor White
        Write-Host $msg.ServicesChoiceBack

        $choice = Read-Host $msg.EnterChoice

        switch ($choice.ToUpper()) {
            'V' { Show-SubMenu-VideoRecast }
            '1' {
                Start-WebServer -Restart
                Write-Log $msg.ServicesWebServerRestarted -Level SUCCESS
                Start-Sleep -Seconds 1
            }
            '2' {
                Stop-WebServer
                Write-Log $msg.ServicesWebServerStopped -Level INFO
                Start-Sleep -Seconds 1
            }
            '3' {
                Stop-MediaMtx
                Start-Sleep -Milliseconds 500
                Start-MediaMtx
                Write-Log $msg.ServicesMediaMtxRestarted -Level SUCCESS
                Start-Sleep -Seconds 1
            }
            '4' {
                Stop-MediaMtx
                Write-Log $msg.ServicesMediaMtxStopped -Level INFO
                Start-Sleep -Seconds 1
            }
        }
    } while ($choice -ne '0')
}


function Show-SubMenu-Config {
    do {
        Clear-Host
        Write-Host ""
        Write-Host "  === Configuration ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  W. WiFi Networks  - List, add, edit, delete, set preferred"
        $dashboardStatus = if ($global:Dashboard_showConsole) { "Shown" } else { "Hidden" }
        Write-Host "  D. VR Headset Monitoring Console  - Currently: $dashboardStatus"
        $captureLabel = switch ($global:CaptureMode) {
            'StreamOnly'           { "Stream only" }
            'StreamAndLocalWindow' { "Stream + local scrcpy window" }
            'LocalWindow'          { "Local scrcpy window only" }
            default                { "$global:CaptureMode" }
        }
        Write-Host "  V. Video Capture Mode  - Currently: $captureLabel"
        if ($global:VQA_Enabled) {
            Write-Host "  Q. Video Quality Automation (VQR / VQO)"
        }
        Write-Host ""
        Write-Host "  0. Back"
        Write-Host ""
        $choice = (Read-Host $msg.EnterChoice).Trim().ToUpper()
        switch ($choice) {
            'W' { Show-SubMenu-WifiNetworks }
            'V' { Show-SubMenu-CaptureMode }
            'Q' {
                if ($global:VQA_Enabled -and (Get-Command Show-SubMenu-Monitoring -ErrorAction SilentlyContinue)) {
                    Show-SubMenu-Monitoring
                }
            }
            'D' {
                $cfgPath = if ($global:configFilePath) { $global:configFilePath } else { Join-Path $global:ScriptPath "config\config.json" }
                $cfg = Read-ConfigJson -ConfigFilePath $cfgPath
                if ($cfg) {
                    if ($null -eq $cfg.VRMonitor) {
                        $cfg | Add-Member -NotePropertyName VRMonitor -NotePropertyValue ([PSCustomObject]@{ showConsole = $false })
                    }
                    $newVal = -not [bool]$cfg.VRMonitor.showConsole
                    $cfg.VRMonitor.showConsole = $newVal
                    $global:Dashboard_showConsole = $newVal
                    $json = $cfg | ConvertTo-Json -Depth 10
                    Write-FileWithoutBom -Path $cfgPath -Content $json
                    if (-not $newVal) {
                        # Toggled OFF: kill any running dashboard now so it does
                        # not linger. Show-MainMenu's gate prevents a respawn.
                        try {
                            Get-WmiObject -Class Win32_Process -Filter "ParentProcessId = $PID" |
                                Where-Object { $_.CommandLine -match "headsets_dashboard\.ps1" } |
                                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                        } catch { }
                        $dashPidFile = Join-Path $global:ScriptPath "data\dashboard.pid"
                        if (Test-Path -LiteralPath $dashPidFile) { Remove-Item -LiteralPath $dashPidFile -Force -ErrorAction SilentlyContinue }
                    }
                    $statusLabel = if ($newVal) { "Shown" } else { "Hidden" }
                    Write-Host ""
                    Write-Host "  VR Headset Monitoring Console set to: $statusLabel" -ForegroundColor Green
                    Write-Host ""
                    Read-Host $msg.PressEnterToContinue | Out-Null
                }
            }
            '0' { return }
        }
    } while ($true)
}


function Show-SubMenu-CaptureMode {
    do {
        Clear-Host
        Write-Host ""
        Write-Host "  === Video Capture Mode ===" -ForegroundColor Cyan
        Write-Host ""
        $captureCurrentLabel = switch ($global:CaptureMode) {
            'StreamOnly'           { "Stream only" }
            'StreamAndLocalWindow' { "Stream + local scrcpy window" }
            'LocalWindow'          { "Local scrcpy window only" }
            default                { "$global:CaptureMode" }
        }
        Write-Host "  Current: $captureCurrentLabel"
        Write-Host ""
        Write-Host "  1. Stream only                  - No scrcpy window. Lowest CPU. Stream available on the website."
        Write-Host "  2. Stream + local scrcpy window - scrcpy window visible + stream via named pipe (GPU rendering)."
        Write-Host "  3. Local scrcpy window only     - Window only. No streaming pipeline (lowest CPU when no viewer)."
        Write-Host ""
        Write-Host "  Switching restarts any running scrcpy session in the new mode."
        Write-Host ""
        Write-Host "  0. Back"
        Write-Host ""
        $choice = (Read-Host $msg.EnterChoice).Trim()
        $newMode = switch ($choice) {
            '1' { 'StreamOnly' }
            '2' { 'StreamAndLocalWindow' }
            '3' { 'LocalWindow' }
            '0' { return }
            default { $null }
        }
        if ($newMode) {
            # Warn before switching to LocalWindow - no stream/web/restream
            if ($newMode -eq 'LocalWindow' -and $global:CaptureMode -ne 'LocalWindow') {
                Write-Host ""
                Write-Host "  WARNING: Only the local scrcpy windows will open." -ForegroundColor Yellow
                Write-Host "  Video capture will NOT be available on the web interface or via restream links." -ForegroundColor Yellow
                Write-Host ""
                $ack = (Read-Host "  Continue? [Y/N]").Trim().ToUpper()
                if ($ack -ne 'Y') {
                    Write-Host "  Cancelled." -ForegroundColor DarkGray
                    Start-Sleep -Seconds 1
                    continue
                }
            }
            if (Set-CaptureMode -Mode $newMode) {
                Write-Host ""
                Write-Host "  CaptureMode set to $newMode" -ForegroundColor Green
                Write-Host ""
                Read-Host $msg.PressEnterToContinue | Out-Null
            }
        }
    } while ($true)
}


function Show-SubMenu-WifiNetworks {
    do {
        Clear-Host
        Write-Host $msg.WifiNetworksTitle -ForegroundColor Cyan
        Write-Host ""
        $networks = @(Get-WifiNetworks)
        if ($networks.Count -eq 0) {
            Write-Host $msg.WifiNetworksEmpty -ForegroundColor Yellow
        } else {
            $i = 1
            foreach ($n in $networks) {
                $flag = if ($n.Preferred) { '[*]' } else { '[ ]' }
                $color = if ($n.Preferred) { 'Yellow' } else { 'Gray' }
                Write-Host ("  {0} {1}. {2}" -f $flag, $i, $n.SSID) -ForegroundColor $color
                $i++
            }
        }
        Write-Host ""
        Write-Host "  A. Add a network"
        if ($networks.Count -gt 0) {
            Write-Host "  [1-$($networks.Count)]. Edit / Delete a network"
        }
        Write-Host "  0. Back"
        Write-Host ""

        $choice = (Read-Host $msg.EnterChoice).Trim()

        if ($choice.ToUpper() -eq 'A') {
            $ssid = (Read-Host $msg.WifiNetworkSsidPrompt).Trim()
            if (-not $ssid) { continue }
            $wifiPassword  = (Read-Host $msg.WifiNetworkPasswordPrompt).Trim()
            $existing = $networks | Where-Object { $_.SSID -eq $ssid }
            if ($existing) {
                $existing.Password = $wifiPassword
                Write-Log ($msg.WifiNetworkUpdated -f $ssid) -Level SUCCESS
            } else {
                $isFirst = ($networks.Count -eq 0)
                $networks += [PSCustomObject]@{ SSID = $ssid; Password = $wifiPassword; Preferred = $isFirst }
                Write-Log ($msg.WifiNetworkAdded -f $ssid) -Level SUCCESS
            }
            Save-WifiNetworks -Networks $networks
            Start-Sleep -Seconds 1
            continue
        }

        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $networks.Count) {
                $target = $networks[$idx]
                Write-Host ""
                $prefLabel = if ($target.Preferred) { '[already preferred]' } else { $msg.WifiNetworkSetPref }
                Write-Host ("  Selected: {0}" -f $target.SSID)
                Write-Host ("  E. Edit password    P. {0}    D. Delete    0. Cancel" -f $prefLabel)
                $action = (Read-Host $msg.EnterChoice).Trim().ToUpper()
                if ($action -eq 'E') {
                    $wifiPwdInput = (Read-Host $msg.WifiNetworkPasswordPrompt).Trim()
                    $target.Password = $wifiPwdInput
                    Save-WifiNetworks -Networks $networks
                    Write-Log ($msg.WifiNetworkUpdated -f $target.SSID) -Level SUCCESS
                    Start-Sleep -Seconds 1
                } elseif ($action -eq 'P') {
                    if ($target.Preferred) {
                        Write-Log ($msg.WifiNetworkAlreadyPref -f $target.SSID) -Level INFO
                    } else {
                        foreach ($n in $networks) { $n.Preferred = ($n.SSID -eq $target.SSID) }
                        Save-WifiNetworks -Networks $networks
                        Write-Log ($msg.WifiNetworkPreferred -f $target.SSID) -Level SUCCESS
                    }
                    Start-Sleep -Seconds 1
                } elseif ($action -eq 'D') {
                    $wasPreferred = $target.Preferred
                    $networks = @($networks | Where-Object { $_.SSID -ne $target.SSID })
                    if ($wasPreferred -and $networks.Count -gt 0) { $networks[0].Preferred = $true }
                    Save-WifiNetworks -Networks $networks
                    Write-Log ($msg.WifiNetworkRemoved -f $target.SSID) -Level SUCCESS
                    Start-Sleep -Seconds 1
                }
            }
        }
    } while ($choice -ne '0')
}


function Show-SubMenu-VideoRecast {
    # Available protocols in rotation order
    $protocols = @("rtsp", "hls", "webrtc")
    $protocolIndex = 0

    do {
        $protocol = $protocols[$protocolIndex]
        $headsets = @(Get-KnownHeadsets)

        Clear-Host
        Write-Host $msg.VideoRecastTitle -BackgroundColor DarkMagenta -ForegroundColor White
        Write-Host ($msg.VideoRecastProtocol -f $protocol.ToUpper())
        Write-Host ""

        # Build URL list - use localhost for clipboard (viewer opens on this PC)
        $urls = @{}
        foreach ($h in $headsets) {
            $url = Get-RestreamUrl -HeadsetName $h.Name -Protocol $protocol -LocalIP "localhost"
            $urls[$h.ID] = $url
            Write-Host ($msg.VideoRecastURLLine -f $h.ID, $h.Name, $url)
        }

        Write-Host ""
        Write-Host $msg.VideoRecastHeader -ForegroundColor Cyan
        Write-Host " 0. Return to main menu" -ForegroundColor Gray
        Write-Host ""

        $choiceInput = (Read-Host $msg.EnterChoice).ToUpper()

        if ($choiceInput -eq '0') {
            return
        }
        elseif ($choiceInput -eq 'P') {
            # Cycle to next protocol
            $protocolIndex = ($protocolIndex + 1) % $protocols.Count
        }
        elseif ($urls.ContainsKey($choiceInput)) {
            $selectedUrl = $urls[$choiceInput]
            Set-Clipboard -Value $selectedUrl
            Write-Host ($msg.VideoRecastCopied -f $selectedUrl) -ForegroundColor Green
            Start-Sleep -Seconds 2
            return
        }
        else {
            Write-Host $msg.VideoRecastInvalidChoice -ForegroundColor Red
            Start-Sleep -Seconds 2
        }

    } while ($true)
}


function Show-SubMenu-FilesAndFolders{
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.FilesAndFoldersManagement -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host $msg.OpenRecordingsFolder
    Write-Host $msg.OpenLogsFolder
    Write-Host $msg.OpenAppFolder
    Write-Host $msg.EditConfigFile
    Write-Host $msg.EditKnownHeadsetsConfig

    Write-Host $msg.ReturnPreviousMenu
    $userInput = $(Read-Host $msg.YourChoice).ToUpper() #ToUpper = Convert user input to uppercase for case-insensitive comparison
    switch ($userInput) {
        '1' {
            Write-Log -Message $msg.OpenRecordings -Level "INFO"
            Open-Folder -folderPath $global:scrcpyRecordFolder
        }

        '2' {
            Write-Log -Message $msg.OpenLogs -Level "INFO"
            Open-Folder -folderPath $global:logFolder
        }

        '3' {
            Write-Log -Message $msg.OpenApp -Level "INFO"
            Open-Folder -folderPath $global:scriptPath
        }
        '4' {
            Write-Log -Message $msg.OpenConfig -Level "INFO"
            Open-File -filePath $global:configFilePath
        }
        '5' {
            Write-Log -Message $msg.OpenKnownHeadsets -Level "INFO"
            Open-File -filePath $global:knownHeadsetsFilePath
        }
        '0' {
            Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
            Start-Sleep -seconds 2
            break 
        }

        default {
            Write-Log -Message $msg.InvalidOptionFileMenu -Level "ERROR"
            Write-Host $msg.InvalidOptionFiles -ForegroundColor Yellow
        }
    }
}

function Open-Folder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )
    
    # Normalize path and ensure it's treated as a directory
    $normalizedPath = (Resolve-Path $FolderPath -ErrorAction SilentlyContinue).Path
    
    if ($normalizedPath -and (Test-Path $normalizedPath -PathType Container)) {
        # Use Start-Process with explorer.exe to reliably open the folder
        Start-Process explorer.exe -ArgumentList $normalizedPath
    }
    else {
        Write-Log ($msg.FolderNotExist -f $FolderPath) -Level ERROR
    }
}


function Open-File {
    param (
        [string]$filePath
    )

    if (Test-Path -Path $filePath) {
        Start-Process notepad.exe -ArgumentList "`"$filePath`""
    } else {
        Write-Log -Message ($msg.FileNotExist -f $filePath) -Level "ERROR"
        Write-Host ($msg.FileNotExist -f $filePath) -ForegroundColor Red
    }
}


# [Q] Quality Monitoring sub-menu. Gated by $global:VQA_Enabled in Show-MainMenu;
# the VQA-specific commands it calls (Set-VqaAutoApply, Invoke-VqaApply, etc.)
# only exist when modules/video_quality_automation.ps1 is loaded, which itself
# only happens when VQA is enabled.
function Show-SubMenu-Monitoring {
    do {
        Clear-Host
        Write-Host ""
        Write-Host " ==========================================================" -ForegroundColor Cyan
        Write-Host "   $($msg.MonitoringMenuTitle)" -ForegroundColor Cyan
        Write-Host " ==========================================================" -ForegroundColor Cyan
        Write-Host ""

        $rec = Get-LatestVqaRecommendation
        if ($rec) {
            $color = if ($rec.Direction -eq 'down') { 'Yellow' } elseif ($rec.Direction -eq 'up') { 'Green' } else { 'Gray' }
            Write-Host ("   CPU: {0}%   GPU: {1}%   scrcpy: {2}   clients: {3}" -f $rec.Cpu, $rec.Gpu, $rec.ScrcpyCount, $rec.ClientCount) -ForegroundColor White
            Write-Host ("   Direction: {0}   Reason: {1}" -f $rec.Direction, $rec.Reason) -ForegroundColor $color
        } else {
            Write-Host "   No recommendation yet." -ForegroundColor DarkGray
        }
        $p = if ($global:VQA_AutoApplyProfiles) { 'ON' } else { 'OFF' }
        $h = if ($global:VQA_AutoApplyHeadsets) { 'ON' } else { 'OFF' }
        $m = if ($global:VQA_AutoApplyMediaMtx) { 'ON' } else { 'OFF' }
        $cd = Get-VqaCooldownRemaining
        Write-Host ("   Auto-apply:  Profiles [{0}]   Headsets [{1}]   MediaMTX [{2}]" -f $p, $h, $m) -ForegroundColor White
        Write-Host ("   Cooldown:    {0} cycles remaining" -f $cd) -ForegroundColor White
        Write-Host ""
        Write-Host "   [1] Toggle Profiles auto-apply"
        Write-Host "   [2] Toggle Headsets auto-apply"
        Write-Host "   [3] Toggle MediaMTX auto-apply"
        Write-Host "   [4] Apply current recommendation now"
        Write-Host "   [5] Restore originals"
        Write-Host "   [6] Show full recommendation JSON"
        Write-Host "   [0] Back"
        Write-Host ""
        $choice = Read-Host "   Choice"

        switch ($choice) {
            '1' { Set-VqaAutoApply -Section 'profiles' -Enabled (-not $global:VQA_AutoApplyProfiles) | Out-Null; Start-Sleep -Milliseconds 500 }
            '2' { Set-VqaAutoApply -Section 'headsets' -Enabled (-not $global:VQA_AutoApplyHeadsets) | Out-Null; Start-Sleep -Milliseconds 500 }
            '3' { Set-VqaAutoApply -Section 'mediamtx' -Enabled (-not $global:VQA_AutoApplyMediaMtx) | Out-Null; Start-Sleep -Milliseconds 500 }
            '4' { Invoke-VqaApply -Scope 'all' | Out-Null; Read-Host "Press Enter" }
            '5' { Restore-VqaOriginals | Out-Null; Read-Host "Press Enter" }
            '6' {
                if (Test-Path -LiteralPath $global:VQA_RecommendationFilePath) {
                    Get-Content -LiteralPath $global:VQA_RecommendationFilePath -Raw | Write-Host
                } else {
                    Write-Host "No recommendation file yet."
                }
                Read-Host "Press Enter"
            }
        }
    } while ($choice -ne '0')
}


function Add-Headset-Manually {
    # Clear the screen
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== MANUAL HEADSET ADDITION ===" -BackgroundColor Green -ForegroundColor Black

    # Ask for the required information
    $name = Read-Host "Headset name (mandatory)"
    if (-not $name) {

        Write-Log "The name is mandatory. Aborting." -Level ERROR
        return
    }

    $ip = Read-Host "Headset IP address (mandatory)"
    if (-not (Test-ValidIPv4 $ip)) {
        Write-Host "A valid IP address is mandatory. Aborting." -ForegroundColor Red
        return
    }

    # Optional fields
    # Call the main function
    Add-Headset -IPAddress $ip -Name $name

    Write-Host "Headset added successfully!" -ForegroundColor Cyan
} #OK