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

# Read-Host that keeps running -OnIdle (about every -IdleIntervalMs) while it waits.
# A blocking Read-Host stops the main thread, and PowerShell event actions do not run
# during it either, so anything the main process must do on its own (restarting a dead
# VRMonitor job) would wait for the operator's next keypress. This waits for the first
# key with [Console]::KeyAvailable, then hands over to Read-Host, which reads that key
# from the console buffer with normal line editing - keystrokes injected by the web
# server (/api/app-shutdown) go through the same buffer and work the same way.
# Falls back to a plain Read-Host when the input is redirected (KeyAvailable throws).
# Example: $choice = Read-MenuLine -Prompt $msg.EnterChoice -OnIdle { Invoke-VRMonitorSupervision }
function Read-MenuLine {
    param(
        [string]$Prompt,
        [scriptblock]$OnIdle,
        [int]$IdleIntervalMs = 1000
    )
    $canPoll = $true
    try { $null = [Console]::KeyAvailable } catch { $canPoll = $false }
    if (-not $canPoll -or -not $OnIdle) { return (Read-Host $Prompt) }

    $promptText = if ($Prompt) { $Prompt + ': ' } else { '' }
    Write-Host $promptText -NoNewline
    $nextIdle = Get-Date
    while (-not [Console]::KeyAvailable) {
        if ((Get-Date) -ge $nextIdle) {
            $before = try { '{0},{1}' -f [Console]::CursorLeft, [Console]::CursorTop } catch { '' }
            try { & $OnIdle } catch { }
            $after  = try { '{0},{1}' -f [Console]::CursorLeft, [Console]::CursorTop } catch { '' }
            # The idle action printed something (a log line): show the prompt again.
            if ($before -ne $after) { Write-Host ''; Write-Host $promptText -NoNewline }
            $nextIdle = (Get-Date).AddMilliseconds($IdleIntervalMs)
        }
        Start-Sleep -Milliseconds 100
    }
    return (Read-Host)
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
                    $new = Read-ValidPort -Label "$Service port" -Default $CurrentPort -Min $(if ($Service -eq 'WebServer') { 1 } else { 1024 })
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
                    $new = Read-ValidPort -Label "$Service port" -Default $CurrentPort -Min $(if ($Service -eq 'WebServer') { 1 } else { 1024 })
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


# ---------------------------------------------------------------------------
# Main screen ("cockpit"): status header, live headset table, grouped tiles.
# Drawn with the ASCII kit of console_ui.ps1. The header and the table are the
# "dynamic" region: Read-CockpitInput redraws it in place while nothing is typed.
# ---------------------------------------------------------------------------

function Test-CockpitFlag {
    # $true for a live-status flag that reads as on: 1, True, OK (the status table stores
    # booleans as 1/0, the SCRCPY column as "OK"/"-").
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return (([string]$Value).Trim() -in @('1', 'True', 'OK', 'Yes'))
}

function Set-CockpitNotice {
    <#
    .SYNOPSIS
    Sets the one-line result shown under the headset table of the main screen and of the
    headset panel (for 60 s), instead of pausing the screen with a sleep.
    .EXAMPLE
    Set-CockpitNotice -Text 'Recording ON for Q3 RED.' -Kind ok
    #>
    param([string]$Text, [ValidateSet('ok', 'warn', 'err', 'info')] [string]$Kind = 'info')
    $script:CockpitNotice = @{ Text = $Text; Kind = $Kind; At = Get-Date }
}

function Get-CockpitNoticeSegments {
    # Segments of the current notice, or a blank line once it is older than 60 s.
    $n = $script:CockpitNotice
    if (-not $n -or ((Get-Date) - $n.At).TotalSeconds -gt 60) { return @(New-UiSegment '') }
    $tag, $color = switch ($n.Kind) {
        'ok'   { '[OK]', 'Green' }
        'warn' { '[!!]', 'Yellow' }
        'err'  { '[XX]', 'Red' }
        default { '[..]', 'Cyan' }
    }
    return @((New-UiSegment ('  ' + $tag + ' ') $color), (New-UiSegment $n.Text 'White'))
}

function Get-CockpitVersion {
    # version.txt, read once per process ('' when missing).
    if ($null -eq $script:CockpitVersion) {
        $script:CockpitVersion = ''
        try {
            $vf = Join-Path $global:ScriptPath 'version.txt'
            if (Test-Path -LiteralPath $vf) { $script:CockpitVersion = (Get-Content -LiteralPath $vf -Raw -Encoding UTF8).Trim() }
        } catch { }
    }
    return $script:CockpitVersion
}

function Get-CockpitWebUrls {
    <#
    .SYNOPSIS
    Addresses of the web monitor: the mDNS name first, then the interface holding the default
    route, then every other usable LAN interface (Get-PrivateNetworks drops link-down and
    virtual adapters). Returns the URL strings; -Detailed returns @{ Url; Label } where Label
    names the source ('mDNS', or the interface alias + WiFi/LAN + 'default route').
    Cached 30 s: Get-PrivateNetworks calls Get-NetAdapter.
    .EXAMPLE
    Get-CockpitWebUrls -Detailed | Format-Table Url, Label
    #>
    param([switch]$Detailed)
    if (-not $global:WebServer_enabled) { return @() }
    $c = $script:CockpitUrlCache
    if (-not $c -or ((Get-Date) - $c.At).TotalSeconds -ge 30) {
        $list = @()
        if ($global:MdnsResponder_enabled -and $global:MdnsResponder_hostname) {
            $list += @{ Url = ('http://{0}.local:{1}' -f $global:MdnsResponder_hostname, $global:WebServer_port); Label = 'mDNS' }
        }
        try {
            # Default-route interface first; the others keep the order Get-PrivateNetworks gives.
            $nets = @(Get-PrivateNetworks)
            foreach ($n in @($nets | Where-Object { $_.HasDefaultGateway }) + @($nets | Where-Object { -not $_.HasDefaultGateway })) {
                $label = '{0} [{1}]' -f $n.InterfaceAlias, $(if ($n.IsWifi) { 'WiFi' } else { 'LAN' })
                if ($n.HasDefaultGateway) { $label += ' - ' + $msg.Console.HelpWebDefault }
                $list += @{ Url = ('http://{0}:{1}' -f $n.IPAddress, $global:WebServer_port); Label = $label }
            }
        } catch { }
        $c = @{ At = Get-Date; List = $list }
        $script:CockpitUrlCache = $c
    }
    if ($Detailed) { return @($c.List) }
    return @($c.List | ForEach-Object { $_.Url })
}

function Get-CockpitLoadColor {
    # Colour of a load percentage against the VQA thresholds (mitigation = amber, max = red).
    param([AllowNull()] $Percent, [int]$Warn, [int]$High)
    if ($null -eq $Percent) { return 'Gray' }
    if ($Percent -ge $High) { return 'Red' }
    if ($Percent -ge $Warn) { return 'Yellow' }
    return 'White'
}

function Get-CockpitHeaderRows {
    <#
    .SYNOPSIS
    The two rows of the main-screen banner as segment arrays: title + service status, then
    PC load + recording drive + web addresses. Reads only published state (VRMonitor job,
    pid files, the computer_monitoring snapshot): nothing is sampled here.
    #>
    param([int]$Width)
    $inner = $Width - 4
    $c = $msg.Console

    # Row 1: title + version | service badges
    $vrm = Get-VRMonitorStatusText
    $vrmColor = switch ($vrm.Color) { 'Red' { 'Red' } 'Yellow' { 'Yellow' } default { 'Green' } }
    $webColor = 'Gray'; $webText = ' ' + $c.Web
    if ($global:WebServer_enabled) {
        $webColor = if (Get-WebServerProcess) { 'Green' } else { 'Red' }
        $webText = ' {0} :{1}' -f $c.Web, $global:WebServer_port
    }
    $mtxColor = 'Gray'
    if ($global:mediamtxEnabled) { $mtxColor = if (Get-MediaMtxProcess) { 'Green' } else { 'Red' } }
    $right = @(
        (New-UiSegment '[*]' $vrmColor), (New-UiSegment (' ' + $c.Monitor + '  ')),
        (New-UiSegment '[*]' $webColor), (New-UiSegment ($webText + '  ')),
        (New-UiSegment '[*]' $mtxColor), (New-UiSegment (' ' + $c.MediaMtx))
    )
    $rightLen = ($right | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum
    # On a narrow console the badges win: the version goes first, then the title.
    $left = $c.Title
    $ver = Get-CockpitVersion
    if ($ver -and ($left.Length + 2 + $ver.Length + 1 + $rightLen) -le $inner) { $left += '  ' + $ver }
    if (($left.Length + 1 + $rightLen) -gt $inner) { $left = '' }
    $gap = [Math]::Max(1, $inner - $left.Length - $rightLen)
    $row1 = @((New-UiSegment $left 'White'), (New-UiSegment (' ' * $gap))) + $right

    # Row 2: CPU / GPU / RAM + recording drive | web addresses
    $row2 = @()
    $snap = $null
    try { $snap = Get-DbKeyValue -Key 'computer_monitoring' } catch { $snap = $null }
    if ($snap -and $snap.CPU) {
        $cpu = if ($null -ne $snap.CPU.LoadPercent) { [int][Math]::Round([double]$snap.CPU.LoadPercent) } else { $null }
        $ram = if ($snap.RAM -and $null -ne $snap.RAM.UsedPercent) { [int][Math]::Round([double]$snap.RAM.UsedPercent) } else { $null }
        $row2 += New-UiSegment 'CPU ' 'Gray'
        $row2 += New-UiSegment ('{0}%  ' -f $(if ($null -ne $cpu) { $cpu } else { '-' })) (Get-CockpitLoadColor -Percent $cpu -Warn $global:VQA_CpuMitigationThreshold -High $global:VQA_CpuMaxThreshold)
        # One value per GPU, labelled with its index and vendor: "GPU0 (Intel) 3%  GPU1 (NVIDIA) 12%"
        # (a single GPU drops the index). Utilization = busiest engine, as VQA judges it.
        $gpus = @($snap.GPU | Where-Object { $_ })
        foreach ($g in $gpus) {
            $v = if ($null -ne $g.UtilizationPercent) { $g.UtilizationPercent } else { $g.Load3DPercent }
            $pct = if ($null -ne $v) { [int][Math]::Round([double]$v) } else { $null }
            $vendor = ''
            if (Get-Command Get-GpuVendor -ErrorAction SilentlyContinue) { try { $vendor = [string](Get-GpuVendor -Gpu $g) } catch { $vendor = '' } }
            if (-not $vendor -or $vendor -eq 'Unknown') { $vendor = (([string]$g.Model).Trim() -split '\s+')[0] }
            $name = if ($gpus.Count -gt 1) { 'GPU{0}' -f $g.Index } else { 'GPU' }
            if ($vendor) { $name += ' (' + $vendor + ')' }
            $row2 += New-UiSegment ($name + ' ') 'Gray'
            $row2 += New-UiSegment ('{0}%  ' -f $(if ($null -ne $pct) { $pct } else { '-' })) (Get-CockpitLoadColor -Percent $pct -Warn $global:VQA_GpuMitigationThreshold -High $global:VQA_GpuMaxThreshold)
        }
        if ($gpus.Count -eq 0) { $row2 += New-UiSegment 'GPU -  ' 'Gray' }
        $row2 += New-UiSegment 'RAM ' 'Gray'
        $row2 += New-UiSegment ('{0}%  ' -f $(if ($null -ne $ram) { $ram } else { '-' })) 'White'
        $rd = $snap.RecordingDrive
        if ($rd -and $rd.DriveLetter) {
            $free = if ($null -ne $rd.FreeGB) { [Math]::Round([double]$rd.FreeGB) } else { '-' }
            if ($rd.IsLow) { $row2 += New-UiSegment ($c.RecDriveLow -f $rd.DriveLetter, $free) 'Red' }
            else { $row2 += New-UiSegment ($c.RecDrive -f $rd.DriveLetter, $free) 'White' }
        }
    } else {
        $row2 += New-UiSegment $c.LoadUnknown 'Gray'
    }
    $leftLen = ($row2 | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum
    # Web addresses, each its own clickable segment, in Get-CockpitWebUrls order (mDNS name,
    # then the interface holding the default route, then the others), "+N" for those that do
    # not fit; the help screen (F1) lists them all. Right of the load line when the first one
    # fits there, else on a third banner row of their own (several GPUs fill the load line).
    $urls = @(Get-CockpitWebUrls)
    $rows = @(, $row1)
    if ($urls.Count -eq 0) { return $rows + @(, $row2) }
    $onRow2 = ($leftLen + 2 + $urls[0].Length + $(if ($urls.Count -gt 1) { (' +' + ($urls.Count - 1)).Length } else { 0 })) -le $inner
    $room = if ($onRow2) { $inner - $leftLen - 2 } else { $inner - 2 }
    $shown = @()
    $width = 0
    for ($i = 0; $i -lt $urls.Count; $i++) {
        $more = $urls.Count - $i - 1
        $moreText = if ($more -gt 0) { ' +' + $more } else { '' }
        $next = $width + $(if ($shown.Count) { 2 } else { 0 }) + $urls[$i].Length
        if ($next + $moreText.Length -gt $room) { break }
        $shown += $urls[$i]
        $width = $next
    }
    $hidden = $urls.Count - $shown.Count
    $tail = if ($hidden -gt 0) { ' +' + $hidden } else { '' }
    $urlSegs = @()
    for ($i = 0; $i -lt $shown.Count; $i++) {
        if ($i -gt 0) { $urlSegs += New-UiSegment '  ' }
        $urlSegs += New-UiSegment $shown[$i] 'Cyan' $null $shown[$i]
    }
    if ($tail -and ($width + $tail.Length) -le $room) { $urlSegs += New-UiSegment $tail 'Gray' } else { $tail = '' }
    $total = $width + $tail.Length
    if ($onRow2) {
        $row2 += New-UiSegment (' ' * [Math]::Max(2, $inner - $leftLen - $total))
        $row2 += $urlSegs
        return $rows + @(, $row2)
    }
    $row3 = @((New-UiSegment (' ' * [Math]::Max(0, $inner - $total)))) + $urlSegs
    return $rows + @(, $row2) + @(, $row3)
}

function Get-CockpitHeadsetRows {
    # Registry rows with their live status (Get-HeadsetInfosMerged), in display order. A
    # headset whose status row does not exist yet (just added) is kept, with no status.
    $merged = @()
    try { $merged = @(Get-HeadsetInfosMerged) } catch { $merged = @() }
    $known = @()
    try { $known = @(Get-KnownHeadsets) } catch { $known = @() }
    $byId = @{}
    foreach ($m in $merged) { $byId[[string]$m.ID] = $m }
    $rows = @()
    foreach ($k in $known) {
        if ($byId.ContainsKey([string]$k.ID)) { $rows += $byId[[string]$k.ID] } else { $rows += $k }
    }
    return $rows
}

function Get-CockpitLinkSegments {
    # "* WiFi TLS" / "* USB" (green), "* ping, no ADB" (amber), "o offline" (dark gray).
    param($Row, [int]$Width)
    $c = $msg.Console
    # One column of the width is kept as a gap before the next column.
    $Width = [Math]::Max(1, $Width - 1)
    if (Test-UnknownIp $Row.IPAddress) { return @{ Text = (Format-UiCell -Text ('- ' + $c.LinkUnknownIp) -Width $Width) + ' '; Color = 'DarkGray'; Online = $false } }
    if (Test-CockpitFlag $Row.ADBWifi) {
        $t = [string]$Row.AdbTransport
        if (-not $t -or $t -eq '-') { $t = 'ADB' }
        if ($t -eq 'WiFi' -and [string]$Row.AdbWifiMode -eq 'TLS') { $t = 'WiFi TLS' }
        return @{ Text = (Format-UiCell -Text ('* ' + $t) -Width $Width) + ' '; Color = 'Green'; Online = $true }
    }
    if (Test-CockpitFlag $Row.Ping) { return @{ Text = (Format-UiCell -Text ('* ' + $c.LinkPingOnly) -Width $Width) + ' '; Color = 'Yellow'; Online = $true } }
    return @{ Text = (Format-UiCell -Text ('o ' + $c.LinkOffline) -Width $Width) + ' '; Color = 'DarkGray'; Online = $false }
}

function Get-CockpitBatterySegment {
    # "87%" (+ when charging), coloured against Monitoring.thresholds.headset_battery_*.
    param($Row, [int]$Width)
    $b = [string]$Row.Battery
    if ($b -match '^\s*(\d{1,3})') {
        $n = [int]$Matches[1]
        $text = '{0}%' -f $n
        if (Test-CockpitFlag $Row.Charging) { $text += '+' }
        $color = 'White'
        if ($n -le $global:Monitoring_headset_battery_criticalLevel) { $color = 'Red' }
        elseif ($n -lt $global:Monitoring_headset_battery_warningLevel) { $color = 'Yellow' }
        return (New-UiSegment (Format-UiCell -Text $text -Width $Width) $color)
    }
    return (New-UiSegment (Format-UiCell -Text '-' -Width $Width) 'DarkGray')
}

function Write-CockpitDynamic {
    <#
    .SYNOPSIS
    Draws the dynamic region of the main screen - banner, headset table, notice line - and
    returns how many lines it wrote. -Pad pads every line to the width so a redraw in place
    fully replaces the previous content.
    #>
    param([int]$Width, [switch]$Pad)
    $c = $msg.Console
    $lines = Write-UiBanner -Rows (Get-CockpitHeaderRows -Width $Width) -Fg 'White' -Bg 'DarkBlue' -Width $Width

    # Column widths; PROFILE then AUTO are dropped on a narrow console.
    $wId = 4; $wName = 14; $wLink = 12; $wBat = 6; $wCast = 7; $wAuto = 5; $wRec = 4
    $fixed = 2 + $wId + $wName + $wLink + $wBat + $wCast + $wRec
    $showAuto = ($Width -ge $fixed + $wAuto + 1)
    if ($showAuto) { $fixed += $wAuto }
    $wProfile = $Width - $fixed - 1
    $showProfile = ($wProfile -ge 10)

    Write-UiSegments -Segments @(New-UiSegment '') -Width $Width -Pad:$Pad; $lines++
    $hdr = '  ' + (Format-UiCell $c.ColId $wId) + (Format-UiCell $c.ColHeadset $wName) + (Format-UiCell $c.ColLink $wLink) +
           (Format-UiCell $c.ColBattery $wBat) + (Format-UiCell $c.ColCast $wCast)
    if ($showAuto) { $hdr += Format-UiCell $c.ColAuto $wAuto }
    $hdr += Format-UiCell $c.ColRec $wRec
    if ($showProfile) { $hdr += $c.ColProfile }
    Write-UiSegments -Segments @(New-UiSegment $hdr 'Yellow') -Width $Width -Pad:$Pad; $lines++

    $rows = @(Get-CockpitHeadsetRows)
    if ($rows.Count -eq 0) {
        Write-UiSegments -Segments @(New-UiSegment ('  ' + $c.NoHeadsets) 'DarkGray') -Width $Width -Pad:$Pad; $lines++
    } else {
        $starting = @()
        try { $starting = @(Get-ScrcpyStartingIds) } catch { $starting = @() }
        foreach ($r in $rows) {
            $link = Get-CockpitLinkSegments -Row $r -Width $wLink
            $nameColor = if ($link.Online) { 'White' } else { 'DarkGray' }
            $segs = @(
                (New-UiSegment ('  ' + (Format-UiCell ([string]$r.ID) $wId)) 'Cyan'),
                (New-UiSegment (Format-UiCell ([string]$r.Name) ($wName - 1)) $nameColor),
                (New-UiSegment ' '),
                (New-UiSegment $link.Text $link.Color),
                (Get-CockpitBatterySegment -Row $r -Width $wBat)
            )
            if ($starting -contains [int]$r.ID) { $segs += New-UiSegment (Format-UiCell $c.CastStarting $wCast) 'Yellow' }
            elseif (Test-CockpitFlag $r.SCRCPY) { $segs += New-UiSegment (Format-UiCell $c.CastLive $wCast) 'Green' }
            else { $segs += New-UiSegment (Format-UiCell $c.CastIdle $wCast) 'DarkGray' }
            if ($showAuto) {
                if (ConvertTo-BoolField $r.scrcpy_AutoRestart) { $segs += New-UiSegment (Format-UiCell $c.On $wAuto) 'Green' }
                else { $segs += New-UiSegment (Format-UiCell $c.Off $wAuto) 'DarkGray' }
            }
            if (ConvertTo-BoolField $r.Record) { $segs += New-UiSegment (Format-UiCell ' *' $wRec) 'Red' }
            else { $segs += New-UiSegment (Format-UiCell '' $wRec) }
            if ($showProfile) { $segs += New-UiSegment (Format-UiCell ([string]$r.ScrcpyProfile) $wProfile -Dash) 'Gray' }
            Write-UiSegments -Segments $segs -Width $Width -Pad:$Pad; $lines++
        }
    }
    Write-UiSegments -Segments @(New-UiSegment '') -Width $Width -Pad:$Pad; $lines++
    Write-UiSegments -Segments (Get-CockpitNoticeSegments) -Width $Width -Pad:$Pad; $lines++
    return $lines
}

function Get-CockpitKeymap {
    <#
    .SYNOPSIS
    THE shortcut table of the main screen: @(@{ Key; Aliases; Group; Label; Badge; Hidden;
    Action }). Both the tiles / dispatcher (Show-MainMenu) and the help screen
    (Show-ConsoleHelp) read it, so they cannot drift. Built per call because labels come from
    $msg and some entries depend on live state (pending discovered devices, VQA enabled).
    #>
    $c = $msg.Console
    $pending = 0
    if (Get-Command Get-PendingDiscoveredHeadsets -ErrorAction SilentlyContinue) {
        try { $pending = @(Get-PendingDiscoveredHeadsets).Count } catch { $pending = 0 }
    }
    $vqa = [bool]($global:VQA_Enabled -and (Get-Command Show-SubMenu-Monitoring -ErrorAction SilentlyContinue))
    return @(
        @{ Key = 'H'; Group = 'Headsets'; Label = $c.TileHeadsets;   Action = { Show-SubMenu-AddHeadset } },
        @{ Key = 'D'; Group = 'Headsets'; Label = $c.TileDiscovered; Badge = $(if ($pending -gt 0) { [string]$pending } else { '' }); Hidden = ($pending -eq 0); Action = {
            if (@(Get-PendingDiscoveredHeadsets).Count -gt 0) { Show-SubMenu-DiscoveredHeadsets }
            else { Set-CockpitNotice -Text $msg.Console.HsDiscoveredNone -Kind info }
        } },
        @{ Key = 'A'; Group = 'Headsets'; Label = $c.TileApps;       Action = { Show-SubMenu-LaunchApp } },
        @{ Key = 'S'; Group = 'Streams';  Label = $c.TileAutoCast;   Action = { Show-SubMenu-scrcpyTracking } },
        @{ Key = 'P'; Group = 'Streams';  Label = $c.TileProfiles;   Aliases = @('M'); Action = { Show-SubMenu-ScrcpyOptions } },
        @{ Key = 'R'; Group = 'Streams';  Label = $c.TileRecording;  Action = { Show-SubMenu-Recording } },
        @{ Key = 'K'; Group = 'Site';     Label = $c.TileKiosks;     Action = { Show-SubMenu-KioskScreens } },
        @{ Key = 'W'; Group = 'Site';     Label = $c.TileWeb;        Aliases = @('B'); Badge = $(if ($global:WebServer_enabled) { '' } else { $c.Off }); Action = {
            if ($global:WebServer_enabled) {
                Start-Process ("http://localhost:{0}/" -f $global:WebServer_port)
                Set-CockpitNotice -Text $msg.Console.WebOpened -Kind ok
            } else { Set-CockpitNotice -Text $msg.MenuWebServerDisabled -Kind err }
        } },
        @{ Key = 'I'; Group = 'Site';     Label = $c.TileInternet;   Action = {
            if (Test-InternetConnectivity) { Set-CockpitNotice -Text $msg.InternetOK.Trim() -Kind ok }
            else { Set-CockpitNotice -Text $msg.InternetProblem.Trim() -Kind err }
        } },
        @{ Key = 'V'; Group = 'System';   Label = $c.TileServices;   Action = { Show-SubMenu-Services } },
        @{ Key = 'C'; Group = 'System';   Label = $c.TileConfig;     Action = { Show-SubMenu-Config } },
        @{ Key = 'F'; Group = 'System';   Label = $c.TileFiles;      Action = { Show-SubMenu-FilesAndFolders } },
        @{ Key = 'L'; Group = 'System';   Label = $c.FilesLogPick; Hidden = $true; Action = { Show-SubMenu-LogFiles } },
        @{ Key = 'Q'; Group = 'System';   Label = $c.TileQuality;    Hidden = (-not $vqa); InHelp = $vqa; Action = {
            if ($global:VQA_Enabled -and (Get-Command Show-SubMenu-Monitoring -ErrorAction SilentlyContinue)) { Show-SubMenu-Monitoring }
        } }
    )
}

function Get-CockpitTileGroups {
    # The keymap shaped for Write-UiTiles: the visible entries of each group, in order.
    param([array]$Keymap)
    $c = $msg.Console
    $defs = @(
        @{ Id = 'Headsets'; Title = $c.GroupHeadsets; Color = 'Green' },
        @{ Id = 'Streams';  Title = $c.GroupStreams;  Color = 'Cyan' },
        @{ Id = 'Site';     Title = $c.GroupSite;     Color = 'Magenta' },
        @{ Id = 'System';   Title = $c.GroupSystem;   Color = 'Gray' }
    )
    $groups = @()
    foreach ($d in $defs) {
        $items = @($Keymap | Where-Object { $_.Group -eq $d.Id -and -not $_.Hidden } | ForEach-Object {
            @{ Key = $_.Key; Label = $_.Label; Badge = $_.Badge }
        })
        $groups += @{ Title = $d.Title; Color = $d.Color; Items = $items }
    }
    return $groups
}

function Write-CockpitScreen {
    # Full redraw of the main screen. Records in -State where the dynamic region starts and
    # how tall it is, for the in-place refresh of Read-CockpitInput.
    param([hashtable]$State, [array]$Keymap)
    Clear-Host
    $w = Get-UiWidth
    $State.Width = $w
    $State.Top   = 0
    try { $State.Top = [Console]::CursorTop } catch { }
    $State.Lines = Write-CockpitDynamic -Width $w
    [void](Write-UiTiles -Groups (Get-CockpitTileGroups -Keymap $Keymap) -Width $w -MaxTileWidth 22)
    Write-Host ('  ' + $msg.Console.FooterQuick) -ForegroundColor Gray
    Write-Host ('  ' + $msg.Console.FooterSystem) -ForegroundColor Gray -NoNewline
    Write-Host $msg.Console.FooterShutdown -ForegroundColor Red
    Write-Host ''
}

function Read-CockpitInput {
    <#
    .SYNOPSIS
    The input line of the main screen. A small line editor on [Console]::ReadKey instead of
    Read-Host, so F1 / F5 / '?' can be caught. While waiting it runs the VRMonitor supervision
    about once a second (Invoke-VRMonitorSupervision, as Read-MenuLine does) and, while the
    line is empty, redraws the dynamic region in place every Console.live_refresh_sec seconds.
    Returns @{ Kind = 'Line' | 'Key' | 'Redraw'; Value }.

    .DESCRIPTION
    Keystrokes injected by the web server (/api/app-shutdown, /app-restart, /host-shutdown
    write "0" / "00" / "000" + Enter into this console with WriteConsoleInput) are ordinary key
    events here, so they keep working. Redirected input falls back to Read-Host.
    #>
    param([hashtable]$State)
    $canPoll = $true
    try { $null = [Console]::KeyAvailable } catch { $canPoll = $false }
    if (-not $canPoll) { return @{ Kind = 'Line'; Value = [string](Read-Host '>') } }

    $prompt = '  > '
    Write-Host $prompt -NoNewline -ForegroundColor Magenta
    $buf = New-Object System.Text.StringBuilder
    $refreshSec = if ($null -ne $global:Console_live_refresh_sec) { [int]$global:Console_live_refresh_sec } else { 5 }
    $nextIdle = Get-Date
    $nextRefresh = if ($refreshSec -gt 0) { (Get-Date).AddSeconds($refreshSec) } else { [datetime]::MaxValue }

    while ($true) {
        while (-not [Console]::KeyAvailable) {
            $now = Get-Date
            if ($now -ge $nextIdle) {
                $before = try { '{0},{1}' -f [Console]::CursorLeft, [Console]::CursorTop } catch { '' }
                try { Invoke-VRMonitorSupervision } catch { }
                $after = try { '{0},{1}' -f [Console]::CursorLeft, [Console]::CursorTop } catch { '' }
                if ($before -ne $after) {
                    # The supervision printed something (a log line).
                    if ($buf.Length -eq 0) { return @{ Kind = 'Redraw'; Value = $null } }
                    Write-Host ''
                    Write-Host $prompt -NoNewline -ForegroundColor Magenta
                    Write-Host $buf.ToString() -NoNewline
                }
                $nextIdle = $now.AddMilliseconds(1000)
            }
            if ($buf.Length -eq 0 -and $now -ge $nextRefresh) {
                $ok = $false
                if ((Get-UiWidth) -eq $State.Width) {
                    $saveLeft = [Console]::CursorLeft; $saveTop = [Console]::CursorTop
                    try { [Console]::CursorVisible = $false } catch { }
                    try {
                        [Console]::SetCursorPosition(0, $State.Top)
                        $ok = ((Write-CockpitDynamic -Width $State.Width -Pad) -eq $State.Lines)
                        [Console]::SetCursorPosition($saveLeft, $saveTop)
                    } catch { $ok = $false }
                    try { [Console]::CursorVisible = $true } catch { }
                }
                # A different width or a table that grew/shrank: redraw everything.
                if (-not $ok) { return @{ Kind = 'Redraw'; Value = $null } }
                $nextRefresh = (Get-Date).AddSeconds($refreshSec)
            }
            Start-Sleep -Milliseconds 100
        }

        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::F1) { Write-Host ''; return @{ Kind = 'Key'; Value = 'F1' } }
        if ($k.Key -eq [ConsoleKey]::F5) { Write-Host ''; return @{ Kind = 'Key'; Value = 'F5' } }
        if ($k.Key -eq [ConsoleKey]::Enter -or [int]$k.KeyChar -eq 13) {
            Write-Host ''
            return @{ Kind = 'Line'; Value = $buf.ToString() }
        }
        if ($k.Key -eq [ConsoleKey]::Escape) {
            $n = $buf.Length
            if ($n -gt 0) { Write-Host (("`b" * $n) + (' ' * $n) + ("`b" * $n)) -NoNewline; [void]$buf.Clear() }
            continue
        }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($buf.Length -gt 0) { [void]$buf.Remove($buf.Length - 1, 1); Write-Host "`b `b" -NoNewline }
            continue
        }
        $ch = $k.KeyChar
        if ([int]$ch -lt 32) { continue }
        if ($ch -eq '?' -and $buf.Length -eq 0) { Write-Host ''; return @{ Kind = 'Key'; Value = 'F1' } }
        if ($buf.Length -lt 40) {
            [void]$buf.Append($ch)
            Write-Host ([string]$ch) -NoNewline -ForegroundColor White
        }
    }
}

function Invoke-CockpitHeadsetCommand {
    <#
    .SYNOPSIS
    One quick action on a headset, from the main screen ("<id>x" / "<id>s" / "<id>r" /
    "<id>a") or the headset panel: x = kill the capture, s = start it now, r = recording
    on/off, a = auto-cast on/off. The result goes to the notice line (Set-CockpitNotice).
    Uses the same backend as the web buttons (Stop-HeadsetCapture, Set-HeadsetRecording,
    Set-HeadsetAutoCast, Request-StreamRestart).
    .EXAMPLE
    Invoke-CockpitHeadsetCommand -Headset $row -Action 'r'
    #>
    param([Parameter(Mandatory = $true)] $Headset, [string]$Action)
    $c    = $msg.Console
    $name = [string]$Headset.Name
    $id   = [int]$Headset.ID
    switch ($Action.ToLowerInvariant()) {
        'x' {
            Write-Host ('  ' + ($c.Stopping -f $name)) -ForegroundColor DarkGray
            Write-Log ("Stop scrcpy requested for {0} from the console" -f $name) -Level INFO
            $r = Stop-HeadsetCapture -Headset $Headset
            if (-not $r.Ok)         { Set-CockpitNotice -Text ($c.CastStopFailed -f $name) -Kind err }
            elseif ($r.Restarting)  { Set-CockpitNotice -Text ($c.CastStopRestart -f $name, $id) -Kind warn }
            elseif ($r.Stopped)     { Set-CockpitNotice -Text ($c.CastStopped -f $name) -Kind ok }
            else                    { Set-CockpitNotice -Text ($c.CastNotRunning -f $name) -Kind info }
        }
        's' {
            $ip = [string]$Headset.IPAddress
            if ((Test-UnknownIp $ip) -or -not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
                Write-Log ($msg.PingKO -f $ip) -Level WARNING
                Set-CockpitNotice -Text ($c.CastStartPingKo -f $name, $ip) -Kind err
                break
            }
            # VRMonitor owns the pipelines (ADR-0032): it starts the capture on its next fast tick.
            [void](Request-StreamRestart -HeadsetId $id -Start -Reason 'console start')
            Write-Log ($msg.Scrcpy.StartRequested -f $name) -Level INFO
            Set-CockpitNotice -Text ($msg.Scrcpy.StartRequested -f $name) -Kind ok
        }
        'r' {
            $on = -not (ConvertTo-BoolField $Headset.Record)
            $r = Set-HeadsetRecording -Headset $Headset -Enabled $on
            if ($r.StorageLow) { Set-CockpitNotice -Text ($c.RecLow -f $r.DriveLetter, $r.FreeGB, $r.MinFreeGB) -Kind err }
            elseif ($r.Ok) {
                $text = if ($on) { $c.RecOn -f $name } else { $c.RecOff -f $name }
                Write-Log ("Console: " + $text) -Level INFO
                Set-CockpitNotice -Text $text -Kind ok
            }
            else { Set-CockpitNotice -Text ($c.ActionFailed -f $name) -Kind err }
        }
        'a' {
            $on = -not (ConvertTo-BoolField $Headset.scrcpy_AutoRestart)
            if (Set-HeadsetAutoCast -Headset $Headset -Enabled $on) {
                $text = if ($on) { $c.AutoCastOn -f $name } else { $c.AutoCastOff -f $name, $id }
                Write-Log ("Console: " + $text) -Level INFO
                Set-CockpitNotice -Text $text -Kind $(if ($on) { 'ok' } else { 'info' })
            }
            else { Set-CockpitNotice -Text ($c.ActionFailed -f $name) -Kind err }
        }
        default { Set-CockpitNotice -Text ($c.UnknownSuffix -f $id, $Action) -Kind err }
    }
}

function Get-HeadsetPanelKeymap {
    # The single-key actions of Show-HeadsetPanel: @(@{ Key; Group; Label }). Read by the
    # panel itself and by the help screen.
    $c = $msg.Console
    return @(
        @{ Key = '1'; Group = 'Capture'; Label = $c.PanelAutoCast },
        @{ Key = '2'; Group = 'Capture'; Label = $c.PanelStart },
        @{ Key = '3'; Group = 'Capture'; Label = $c.PanelKill },
        @{ Key = '4'; Group = 'Capture'; Label = $c.PanelRecord },
        @{ Key = '5'; Group = 'Setup';   Label = $c.PanelProfileEdit },
        @{ Key = '6'; Group = 'Setup';   Label = $c.PanelEyeMerge },
        @{ Key = '8'; Group = 'Setup';   Label = $c.PanelRefreshRate },
        @{ Key = '9'; Group = 'Setup';   Label = $c.PanelPushWifi },
        @{ Key = 'S'; Group = 'Setup';   Label = $c.PanelSession },
        @{ Key = '7'; Group = 'Device';  Label = $c.PanelLaunchApp },
        @{ Key = 'G'; Group = 'Device';  Label = $c.PanelFrame },
        @{ Key = 'E'; Group = 'Device';  Label = $c.PanelEdit },
        @{ Key = 'B'; Group = 'Device';  Label = $c.PanelDiag },
        @{ Key = 'X'; Group = 'Device';  Label = $c.PanelRemove }
    )
}

function Write-HeadsetPanelCard {
    <#
    .SYNOPSIS
    The status card at the top of the headset panel (6 lines, two columns): model, serial,
    address, link, battery, temperatures, capture, auto-cast, recording, profile, running app.
    Returns the number of lines written. -Pad for the redraw in place.
    #>
    param([int]$Id, [int]$Width, [switch]$Pad)
    $c = $msg.Console
    $row = @(Get-CockpitHeadsetRows | Where-Object { [int]$_.ID -eq $Id }) | Select-Object -First 1
    if (-not $row) { Write-UiSegments -Segments @(New-UiSegment ('  ' + $c.PanelGone) 'Red') -Width $Width -Pad:$Pad; return 1 }
    $half = [Math]::Max(30, [Math]::Floor($Width / 2))
    $lw = 11
    $cell = {
        param($label, $value, $color, $w)
        @((New-UiSegment (Format-UiCell -Text $label -Width $lw) 'DarkGray'),
          (New-UiSegment (Format-UiCell -Text $value -Width ($w - $lw) -Dash) $(if ($color) { $color } else { 'White' })))
    }
    $link = Get-CockpitLinkSegments -Row $row -Width 20
    $bat = Get-CockpitBatterySegment -Row $row -Width 8
    $temp = [string]$row.Temp
    if ($temp -and $temp -ne '-') { $temp = $temp + ' C' }
    if ($row.CpuTemp -and [string]$row.CpuTemp -ne '-') { $temp = ('{0}  (CPU {1} C)' -f $temp, $row.CpuTemp) }
    $starting = @()
    try { $starting = @(Get-ScrcpyStartingIds) } catch { }
    $castText = $c.CastIdle; $castColor = 'DarkGray'
    if ($starting -contains $Id) { $castText = $c.CastStarting; $castColor = 'Yellow' }
    elseif (Test-CockpitFlag $row.SCRCPY) { $castText = $c.CastLive; $castColor = 'Green' }
    $auto = ConvertTo-BoolField $row.scrcpy_AutoRestart
    $rec  = ConvertTo-BoolField $row.Record
    $app  = [string]$row.RunningApp

    $lines = @(
        ((& $cell $c.PanelModel ([string]$row.Model) $null $half) + (& $cell $c.PanelSerial ([string]$row.SerialNumber) 'Gray' ($Width - $half))),
        ((& $cell $c.PanelAddress ([string]$row.IPAddress) $null $half) + (& $cell $c.PanelLink $link.Text.Trim() $link.Color ($Width - $half))),
        ((& $cell $c.PanelBattery $bat.Text.Trim() $bat.Fg $half) + (& $cell $c.PanelTemp $temp $null ($Width - $half))),
        ((& $cell $c.PanelCast $castText $castColor $half) + (& $cell $c.PanelAuto $(if ($auto) { $c.On } else { $c.Off }) $(if ($auto) { 'Green' } else { 'DarkGray' }) ($Width - $half))),
        ((& $cell $c.PanelRec $(if ($rec) { $c.On } else { $c.Off }) $(if ($rec) { 'Red' } else { 'DarkGray' }) $half) + (& $cell $c.PanelProfile ([string]$row.ScrcpyProfile) 'Cyan' ($Width - $half))),
        (& $cell $c.PanelApp $app 'Gray' $Width)
    )
    foreach ($l in $lines) { Write-UiSegments -Segments (@(New-UiSegment '  ') + $l) -Width $Width -Pad:$Pad }
    return $lines.Count
}

function Show-HeadsetPanel {
    <#
    .SYNOPSIS
    Everything about ONE headset on one screen: a live status card and single-key actions
    (auto-cast, start, kill, recording, profile, eye merge, refresh rate, WiFi push, launch
    app, frame capture, edit, DIAG page, remove). Opened by typing the headset ID on the main
    screen. Actions reuse the existing sub-menus with -Headset (no second picker) and the web
    backend for the capture toggles.
    .EXAMPLE
    Show-HeadsetPanel -Headset (Get-KnownHeadsets | Where-Object ID -eq 3)
    #>
    param([Parameter(Mandatory = $true)] $Headset)
    $c = $msg.Console
    $id = [int]$Headset.ID
    $keymap = Get-HeadsetPanelKeymap
    $refreshSec = if ($null -ne $global:Console_live_refresh_sec) { [int]$global:Console_live_refresh_sec } else { 5 }

    while ($true) {
        $row = @(Get-KnownHeadsets | Where-Object { [int]$_.ID -eq $id }) | Select-Object -First 1
        if (-not $row) {
            Set-CockpitNotice -Text $c.PanelGone -Kind warn
            return
        }
        Clear-Host
        $w = Get-UiWidth
        Write-UiTitle -Title ($c.PanelTitle -f $id, $row.Name) -Subtitle ($c.PanelSubtitle -f $row.Name) -Bg 'DarkBlue'
        Write-Host ''
        $cardTop = 0
        try { $cardTop = [Console]::CursorTop } catch { }
        $cardLines = Write-HeadsetPanelCard -Id $id -Width $w
        Write-Host ''
        $groups = @(
            @{ Title = $c.PanelGroupCapture; Color = 'Green';   Items = @($keymap | Where-Object { $_.Group -eq 'Capture' }) },
            @{ Title = $c.PanelGroupSetup;   Color = 'Cyan';    Items = @($keymap | Where-Object { $_.Group -eq 'Setup' }) },
            @{ Title = $c.PanelGroupDevice;  Color = 'Magenta'; Items = @($keymap | Where-Object { $_.Group -eq 'Device' }) }
        )
        [void](Write-UiTiles -Groups $groups -Width $w -MaxTileWidth 26)
        Write-UiSegments -Segments (Get-CockpitNoticeSegments) -Width $w
        Write-Host ('  ' + $c.PanelFooter) -ForegroundColor DarkGray

        $tick = {
            if ((Get-UiWidth) -ne $w) { return }
            $saveLeft = [Console]::CursorLeft; $saveTop = [Console]::CursorTop
            try { [Console]::CursorVisible = $false } catch { }
            try {
                [Console]::SetCursorPosition(0, $cardTop)
                [void](Write-HeadsetPanelCard -Id $id -Width $w -Pad)
                [Console]::SetCursorPosition($saveLeft, $saveTop)
            } catch { }
            try { [Console]::CursorVisible = $true } catch { }
        }
        # $tick reads $w / $cardTop / $id at call time through the caller chain (Read-UiKey is
        # called from here). No GetNewClosure: a closure only sees global commands, and the
        # module functions live in main.ps1's script scope.
        $key = Read-UiKey -OnIdle { Invoke-VRMonitorSupervision } -OnTick $tick -TickSec $refreshSec

        switch ($key) {
            '1' { Invoke-CockpitHeadsetCommand -Headset $row -Action 'a' }
            '2' { Invoke-CockpitHeadsetCommand -Headset $row -Action 's' }
            '3' { Invoke-CockpitHeadsetCommand -Headset $row -Action 'x' }
            '4' { Invoke-CockpitHeadsetCommand -Headset $row -Action 'r' }
            '5' { Show-SubMenu-ScrcpyOptions -HeadsetID $id }
            '6' { Show-SubMenu-EyeMerge -Headset $row }
            '7' { Show-SubMenu-LaunchApp -Headset $row }
            '8' { Show-SubMenu-HeadsetRefreshRate -Headset $row }
            '9' { Show-SubMenu-PushHeadsetWifi -Headset $row }
            'S' { Show-SubMenu-HeadsetSessionSettings -Headset $row }
            'G' { Show-SubMenu-CaptureHeadsetFrame -Headset $row }
            'E' { Show-SubMenu-EditHeadset -Headset $row }
            'B' {
                if ($global:WebServer_enabled) {
                    Start-Process ("http://localhost:{0}/headset_diag.html?id={1}" -f $global:WebServer_port, $id)
                    Set-CockpitNotice -Text $c.WebOpened -Kind ok
                } else { Set-CockpitNotice -Text $c.PanelWebDisabled -Kind err }
            }
            'X' {
                Show-SubMenu-RemoveHeadset -Headset $row
                if (-not @(Get-KnownHeadsets | Where-Object { [int]$_.ID -eq $id })) { return }
            }
            '0'   { return }
            'ESC' { return }
            default { }
        }
    }
}

function Show-ConsoleHelp {
    <#
    .SYNOPSIS
    The shortcut help screen (F1 or ? on the main screen), built from Get-CockpitKeymap and
    Get-HeadsetPanelKeymap so it always lists exactly what the screens accept.
    .EXAMPLE
    Show-ConsoleHelp
    #>
    $c = $msg.Console
    Clear-Host
    Write-UiTitle -Title $c.HelpTitle -Subtitle 'VRHM > Help' -Bg 'DarkBlue'
    $row = {
        param($key, $text, $keyColor)
        Write-UiSegments -Segments @(
            (New-UiSegment '    '),
            (New-UiSegment (Format-UiCell -Text $key -Width 12) $(if ($keyColor) { $keyColor } else { 'Yellow' })),
            (New-UiSegment $text 'White'))
    }
    $section = { param($title) Write-Host ''; Write-Host ('  ' + $title) -ForegroundColor Cyan }

    & $section $c.HelpMain
    foreach ($k in @(Get-CockpitKeymap | Where-Object { $_.InHelp -ne $false })) {
        $keys = @($k.Key) + @($k.Aliases | Where-Object { $_ })
        & $row ($keys -join ' / ') $k.Label
    }
    & $row 'F1 / ?' $c.HelpHelp
    & $row 'F5' $c.HelpReload
    & $row 'Enter' $c.HelpRefresh

    & $section $c.HelpQuick
    & $row '<id>' $c.HelpOpen
    & $row '<id>x' $c.HelpKill
    & $row '<id>s' $c.HelpStart
    & $row '<id>r' $c.HelpRec
    & $row '<id>a' $c.HelpAuto

    & $section $c.HelpPanel
    $panel = @(Get-HeadsetPanelKeymap | Sort-Object { $_.Key })
    for ($i = 0; $i -lt $panel.Count; $i += 2) {
        $a = $panel[$i]
        $line = @((New-UiSegment '    '), (New-UiSegment (Format-UiCell $a.Key 4) 'Yellow'), (New-UiSegment (Format-UiCell $a.Label 28) 'White'))
        if ($i + 1 -lt $panel.Count) {
            $b = $panel[$i + 1]
            $line += New-UiSegment (Format-UiCell $b.Key 4) 'Yellow'
            $line += New-UiSegment $b.Label 'White'
        }
        Write-UiSegments -Segments $line
    }

    & $section $c.HelpSub
    Write-Host ('    ' + $c.HelpSubKeys)
    Write-Host ('    ' + $c.HelpSubBack)
    Write-Host ('    ' + $c.HelpTextInput)
    $refreshSec = if ($null -ne $global:Console_live_refresh_sec) { [int]$global:Console_live_refresh_sec } else { 5 }
    if ($refreshSec -gt 0) { Write-Host ('    ' + ($c.HelpLiveRefresh -f $refreshSec)) -ForegroundColor DarkGray }

    # Every address of the web monitor (the header only has room for the first ones).
    & $section $c.HelpWeb
    $webUrls = @(Get-CockpitWebUrls -Detailed)
    if ($webUrls.Count -eq 0) { Write-Host ('    ' + $c.HelpWebNone) -ForegroundColor DarkGray }
    foreach ($u in $webUrls) {
        Write-UiSegments -Segments @(
            (New-UiSegment '    '),
            (New-UiSegment (Format-UiCell -Text $u.Url -Width 32) 'Cyan' $null $u.Url),
            (New-UiSegment ('  ' + $u.Label) 'Gray'))
    }
    if ($webUrls.Count -gt 0 -and -not (Test-UiHyperlinkSupport)) { Write-Host ('    ' + $c.HelpWebNoLink) -ForegroundColor DarkGray }

    & $section $c.HelpSystem
    & $row '0' $c.HelpQuit
    & $row '00' $c.HelpRestart
    & $row '000' $c.HelpShutdown 'Red'
    Wait-UiKey
}

function Show-MainMenu {
    <#
    .SYNOPSIS
    The main console screen ("cockpit"): status header, live headset table, grouped tiles,
    then one input line. Typed + Enter: a tile letter, a headset ID (opens Show-HeadsetPanel),
    a quick command "<id>x|s|r|a", or 0 / 00 / 000 (quit / restart / host shutdown - also what
    the web server injects). F1 or ? opens the help, F5 reloads modules and configuration.
    #>
    $c = $msg.Console
    do {
        # Prevent the computer from sleeping while the app is running.
        # Awake mode is independent of the dashboard window visibility.
        Set-AwakeMode


        # Start html monitor update
        Write-htmlMonitor $global:knownHeadsets

        # Draw and read until a real command arrives (Enter on an empty line, a resize, a log
        # line or the help screen only redraw).
        $state  = @{ Top = 0; Lines = 0; Width = 0 }
        $keymap = @(Get-CockpitKeymap)
        $redraw = $true
        $line   = $null
        $reload = $false
        while ($true) {
            if ($redraw) { Write-CockpitScreen -State $state -Keymap $keymap; $redraw = $false }
            $in = Read-CockpitInput -State $state
            if ($in.Kind -eq 'Redraw') { $redraw = $true; continue }
            if ($in.Kind -eq 'Key') {
                if ($in.Value -eq 'F1') { Show-ConsoleHelp; $redraw = $true; continue }
                if ($in.Value -eq 'F5') { $reload = $true; break }
                continue
            }
            $line = ([string]$in.Value).Trim()
            if ($line -eq '') { $keymap = @(Get-CockpitKeymap); $redraw = $true; continue }
            break
        }
        if ($reload -or $line -ieq 'U') {
            Write-Host ('  ' + $c.Reloading) -ForegroundColor Yellow
            # Reload all modules and config file
            $scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
            if (Test-Path -LiteralPath $scripts_init) {
                . $scripts_init
            } else {
                Write-Host "Error: The initialization script is missing!" -ForegroundColor Red
                exit
            }
            # Signal main.ps1 to re-enter Show-MainMenu with the freshly loaded definition
            $global:MenuReload = $true
            $c = $msg.Console
            continue
        }

        # System commands first, so "0" / "00" / "000" can never be read as a headset ID.
        # (if/elseif, not switch: a "continue" inside a switch only leaves the switch.)
        $choice = $line.ToUpperInvariant()
        if ($choice -eq '00') {
            Write-Host $msg.Restarting -ForegroundColor Yellow
            $mainScript = Join-Path $global:ScriptPath "main.ps1"
            Start-Process powershell.exe -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy","Bypass",
                "-File","`"$mainScript`"",
                "-WaitForPid",$PID
            ) -WindowStyle Normal
            Invoke-AppShutdown
            return
        }
        elseif ($choice -eq '0') {
            Write-Host $msg.Goodbye -ForegroundColor Yellow
            Invoke-AppShutdown
            return
        }
        elseif ($choice -eq '000') {
            Write-Host $msg.HostShutdownConfirm -ForegroundColor Red
            if ((Read-Host $msg.HostShutdownConfirmPrompt).ToUpper() -eq 'YES') {
                Invoke-HostShutdown -DelaySec 30
                Invoke-AppShutdown
                return
            }
            continue
        }

        # Headset ID, optionally followed by a quick action letter.
        if ($choice -match '^(\d+)([A-Z]?)$') {
            $hid = [int]$Matches[1]
            $act = $Matches[2]
            $headset = @(Get-KnownHeadsets | Where-Object { [int]$_.ID -eq $hid }) | Select-Object -First 1
            if (-not $headset) { Set-CockpitNotice -Text ($c.UnknownHeadset -f $hid) -Kind err; continue }
            if ($act) { Invoke-CockpitHeadsetCommand -Headset $headset -Action $act }
            else { Show-HeadsetPanel -Headset $headset }
            continue
        }

        $entry = $keymap | Where-Object { $_.Key -eq $choice -or (@($_.Aliases) -contains $choice) } | Select-Object -First 1
        if ($entry) {
            & $entry.Action
            continue
        }
        Set-CockpitNotice -Text ($c.UnknownCommand -f $line) -Kind err
    } while ($true)
}




function Show-SubMenu-AddHeadset {
    # "H Headsets" tile of the main screen: add / edit / remove / USB onboarding. One key per
    # option, the menu stays open until 0 or Esc.
    $c = $msg.Console
    while ($true) {
        # Only advertise discovered devices when there are actually some waiting.
        $pendingDiscovered = @()
        if (Get-Command Get-PendingDiscoveredHeadsets -ErrorAction SilentlyContinue) {
            try { $pendingDiscovered = @(Get-PendingDiscoveredHeadsets) } catch { $pendingDiscovered = @() }
        }
        $items = @(
            @{ Key = '1'; Label = $c.HsScan },
            @{ Key = '2'; Label = $c.HsAddManual },
            @{ Key = '3'; Label = $c.HsEdit },
            @{ Key = '4'; Label = $c.HsRemove },
            @{ Key = '5'; Label = $c.HsLaunchApp },
            @{ Separator = $true; Label = 'USB' },
            @{ Key = '6'; Label = $c.HsWifiAdb },
            @{ Key = '7'; Label = $c.HsSerial },
            @{ Key = '9'; Label = $c.HsAutoEnable }
        )
        if ($pendingDiscovered.Count -gt 0) {
            $items += @{ Separator = $true }
            $items += @{ Key = '8'; Label = $c.HsDiscovered; Value = [string]$pendingDiscovered.Count; ValueColor = 'Cyan' }
        }
        Write-UiMenu -Title $c.HeadsetsTitle -Subtitle 'VRHM > Headsets' -Items $items -Footer $c.Back -Bg 'DarkGreen'
        Show-HeadsetsTableColored
        $userInput = Read-UiKey
        if ($userInput -in @('0', 'ESC')) { return }
        if ($userInput -notin @('1', '2', '3', '4', '5', '6', '7', '8', '9')) { continue }
        Write-Host ''
        Invoke-HeadsetsMenuChoice -Choice $userInput
        if ($userInput -in @('1', '6', '7', '9')) { Wait-UiKey }
    }
}

function Invoke-HeadsetsMenuChoice {
    # The actions behind the options of Show-SubMenu-AddHeadset (same numbering as before).
    param([string]$Choice)
    $userInput = $Choice
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
            Write-Host $msg.Wifi.ADBActivation
            Enable-WiFiADB
        }
        '7' {
            Write-Host "Detecting USB headset..."
            $usbInfo = Get-AdbUsbDeviceDetails
            if (-not $usbInfo) {
                Write-Host "No USB headset detected." -ForegroundColor Yellow
            } else {
                if (-not $usbInfo.WifiAdbOpen) {
                    Write-Host "Enabling WiFi ADB..."
                    Enable-AdbTcpIp | Out-Null
                    Start-Sleep -Seconds 1
                    $usbInfo = Get-AdbUsbDeviceDetails
                }
                if (-not $usbInfo.SerialNumber -or -not $usbInfo.IP) {
                    Write-Host "Could not resolve the serial number or WiFi IP for this headset." -ForegroundColor Red
                } else {
                    $defaultName = if ($usbInfo.Model) { $usbInfo.Model } else { "Headset $($usbInfo.SerialNumber)" }
                    $nameInput = Read-Host "Headset name [$defaultName]"
                    if (-not $nameInput) { $nameInput = $defaultName }
                    $result = Set-HeadsetBySerial -SerialNumber $usbInfo.SerialNumber -IPAddress $usbInfo.IP -Name $nameInput -Model $usbInfo.Model
                    if ($result.Ok) {
                        Write-Host "Headset '$($result.Name)' $($result.Action) (ID $($result.ID))." -ForegroundColor Green
                    } else {
                        Write-Host "Failed: $($result.Error)" -ForegroundColor Red
                    }
                }
            }
        }
        '8' {
            Show-SubMenu-DiscoveredHeadsets
        }
        '9' {
            $usbInfo = Get-AdbUsbDeviceDetails
            if (-not $usbInfo) {
                Write-Host $msg.AdbWifi.AutoEnableNoUsb -ForegroundColor Yellow
            } else {
                # Holds the USB claim: the last step (adb tcpip) re-enumerates the transport.
                Set-UsbBusy -Seconds 180
                try {
                    $r = Install-AdbAutoEnableApk -Device $usbInfo
                    foreach ($s in $r.Steps) {
                        $c = if ($s.Ok) { 'Green' } else { 'Red' }
                        Write-Host ("  {0,-22} {1}" -f $s.Name, $s.Detail) -ForegroundColor $c
                    }
                    if ($r.Ok) { Write-Host $msg.AdbWifi.AutoEnableDone -ForegroundColor Green }
                    else { Write-Host $r.Error -ForegroundColor Red }
                } finally {
                    Set-UsbBusy -Seconds 10
                }
            }
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

function Show-SubMenu-DiscoveredHeadsets {
    <#
    .SYNOPSIS
    Console equivalent of the web "Discovered devices" sub-page: lists headsets the
    background LAN sweep found that are not in the registry, and lets the operator add or
    permanently forget each one.
    .DESCRIPTION
    Add prompts for a name and registers by serial, so the headset lands under its
    permanent identity. Forget is keyed on the serial and survives a DHCP change - the
    device is never proposed again unless it is added by hand later.
    .EXAMPLE
    Show-SubMenu-DiscoveredHeadsets      # or option 8 of the Add/modify headset menu
    #>
    while ($true) {
        Clear-Host
        Start-Sleep -Milliseconds 150
        Write-Host $msg.Discovery.MenuTitle -BackgroundColor DarkCyan -ForegroundColor White

        if (-not $global:HeadsetDiscovery_enabled) {
            Write-Host $msg.Discovery.Disabled -ForegroundColor Yellow
        }

        $devices = @()
        try { $devices = @(Get-PendingDiscoveredHeadsets) } catch { $devices = @() }

        if ($devices.Count -eq 0) {
            Write-Host $msg.Discovery.NoPending -ForegroundColor Gray
            Write-Host ""
            Write-Host $msg.Discovery.MenuActions
            $k = Read-Host $msg.YourChoice
            if ($k -eq '0' -or -not $k) { return }
            continue
        }

        Write-Host ""
        Write-Host ("{0,-3} {1,-16} {2,-22} {3,-10} {4}" -f "#", "IP", "Device name", "Type", "Serial") -ForegroundColor Yellow
        for ($i = 0; $i -lt $devices.Count; $i++) {
            $d = $devices[$i]
            # $( ) not ( ): a bare "(if ...)" parses but is treated as a command call at
            # runtime and throws "The term 'if' is not recognized".
            $dName = if ($d.Model) { $d.Model } else { "-" }
            $dType = if ($d.Brand) { $d.Brand } else { "-" }
            Write-Host ("{0,-3} {1,-16} {2,-22} {3,-10} {4}" -f ($i + 1), $d.IPAddress, $dName, $dType, $d.SerialNumber)
        }
        Write-Host ""
        Write-Host $msg.Discovery.MenuActions

        $choice = Read-Host $msg.YourChoice
        if ($choice -eq '0' -or -not $choice) { return }
        if ($choice -match '^(?i)r$') { continue }

        $index = 0
        if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $devices.Count) {
            Write-Host $msg.InvalidOption -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        $device = $devices[$index - 1]
        Write-Host ""
        Write-Host ("{0}  |  {1}  |  {2}  |  {3}" -f $device.IPAddress, $device.Model, $device.Brand, $device.SerialNumber) -ForegroundColor Cyan
        Write-Host $msg.Discovery.MenuDeviceActions
        $action = Read-Host $msg.YourChoice

        switch -Regex ($action) {
            '^(?i)a$' {
                $defaultName = if ($device.Model) { $device.Model } else { "Headset $($device.SerialNumber)" }
                $name = Read-Host ("{0} [{1}]" -f $msg.Discovery.PromptName, $defaultName)
                if (-not $name) { $name = $defaultName }
                # Same name rule as the web UI and /api/addheadset.
                if ($name -notmatch '^[\w\s\-]{1,40}$') {
                    Write-Host $msg.InvalidOption -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    break
                }
                $r = Set-HeadsetBySerial -SerialNumber $device.SerialNumber -IPAddress $device.IPAddress `
                                         -Name $name -Model $device.Model -Brand $device.Brand -Source 'console-discovery'
                if ($r.Ok) {
                    Remove-PendingDiscoveredHeadset -SerialNumber $device.SerialNumber | Out-Null
                    Write-Host ($msg.Discovery.AddedOk -f $r.Name) -ForegroundColor Green
                } else {
                    Write-Host ($msg.Discovery.AddFailed -f $r.Error) -ForegroundColor Red
                }
                Start-Sleep -Seconds 2
            }
            '^(?i)f$' {
                # Irreversible from this menu, so confirm. Accepts Y and O (oui).
                $confirm = Read-Host ($msg.Discovery.ForgetConfirm -f $device.SerialNumber)
                if ($confirm -match '^(?i)(y|o)$') {
                    Add-HeadsetDiscoveryIgnore -SerialNumber $device.SerialNumber | Out-Null
                    Write-Host ($msg.Discovery.Forgotten -f $device.SerialNumber) -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
            }
            default { }
        }
    }
} # OK

function Show-SubMenu-EditHeadset {
    # -Headset (a registry row) skips the picker: used by the headset panel (Show-HeadsetPanel).
    param($Headset = $null)
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.ModifyHeadsetManually -BackgroundColor DarkCyan

    $headsets = @(Get-KnownHeadsets)
    if (-not $headsets -or $headsets.Count -eq 0) {
        Write-Log -Message $msg.NoHeadsetToModify -Level "WARNING"
        Write-Host $msg.NoHeadsetToModify -ForegroundColor Yellow
        return
    }

    if ($Headset) {
        $idInput = [string]$Headset.ID
        Write-Host (" {0} - {1}" -f $Headset.ID, $Headset.Name) -ForegroundColor Cyan
    } else {
        Show-HeadsetsTableColored
        $idInput = Read-Host $msg.EnterIDToModify
    }
    if ($idInput -eq '0') {
        Write-Log $msg.ReturnFromEdit -Level "INFO"
        return
    }

    # Validated against the registry IDs: IDs are permanent and need not be contiguous.
    if (-not ($idInput -match '^\d+$') -or -not ($headsets | Where-Object { [int]$_.ID -eq [int]$idInput })) {
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
    } elseif ($field -eq "IPAddress") {
        # IP edits are validated and routed through the serial-keyed writer, so a manual
        # correction cannot leave two rows on the same address (this path had no validation
        # of any kind before).
        $newValue = Read-Host ($msg.EnterNewValue -f $field)
        if (-not (Test-ValidIPv4 -IPAddress $newValue)) {
            Write-Host ($msg.Discovery.IpInvalid -f $newValue) -ForegroundColor Red
            return
        }
        $row = $headsets | Where-Object { $_.ID -eq [int]$idInput } | Select-Object -First 1
        if ($row -and $row.SerialNumber) {
            $r = Set-HeadsetIdentity -SerialNumber $row.SerialNumber -IPAddress $newValue -Source 'console'
            if (-not $r.Ok) { Write-Host $r.Error -ForegroundColor Red }
            elseif ($r.Released.Count -gt 0) {
                foreach ($rel in $r.Released) {
                    Write-Host ($msg.Discovery.IdentityReleased -f $rel.Name, $rel.OldIP, $row.SerialNumber, 'console') -ForegroundColor Yellow
                }
            }
            return
        }
        # No serial on this row yet (manual IP-only entry): plain field write, but still
        # refuse an address another headset already holds.
        if ($headsets | Where-Object { $_.IPAddress -eq $newValue -and $_.ID -ne [int]$idInput }) {
            Write-Host ($msg.HeadsetIpExists -f $newValue) -ForegroundColor Red
            return
        }
    } else {
        # Ask for the new value for the selected field
        $newValue = Read-Host ($msg.EnterNewValue -f $field)
    }

    # Update the headset with the new parameters
    Update-HeadsetField -ID ([int]$idInput) -Field $field -NewValue $newValue
} # OK

# Get-FavoriteAppsCachePath was removed here. Favourites are the
# headset_favorite_apps table, keyed on the permanent headset id, and the legacy
# importer names the file it reads directly - so nothing called this.

<#
.SYNOPSIS
    Favourite apps of one headset, in the operator's order.
.DESCRIPTION
    Same return shape the CSV gave: rows with PackageName and DisplayName, now
    with LocalIconPath and IconUrl joined in from the catalogue.

    The old no-name form read a global data\favorite_apps.csv left over from
    before favourites were per-headset. Nothing calls it that way and there is no
    headset id to attach such a row to, so it returns empty.
.EXAMPLE
    $favorites = Get-FavoriteApps -headsetName 'Q3 RED'
#>
function Get-FavoriteApps {
    param ([string]$headsetName = '')

    $headsetId = Resolve-HeadsetIdByName -Name $headsetName
    if ($headsetId -le 0) { return @() }
    try {
        return @(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $headsetId })
    }
    catch {
        Write-Log ("Get-FavoriteApps failed for '{0}' - {1}" -f $headsetName, $_.Exception.Message) -Level ERROR
        return @()
    }
}

<#
.SYNOPSIS
    Replace one headset's favourites with the given list, in array order.
.DESCRIPTION
    Array position becomes sort_order, which is what CSV row order used to carry
    implicitly. Clear-then-insert in ONE transaction so a reader never observes a
    half-written list, and so removing a favourite is expressed by its absence -
    the same semantics rewriting the whole CSV gave for free. An empty array
    clears the list, as writing a header-only file did.
.EXAMPLE
    Save-FavoriteApps -favorites $rows -headsetName 'Q3 RED'
#>
function Save-FavoriteApps {
    param ([array]$favorites, [string]$headsetName = '')

    $headsetId = Resolve-HeadsetIdByName -Name $headsetName
    if ($headsetId -le 0) {
        Write-Log ("Save-FavoriteApps: no headset named '{0}'" -f $headsetName) -Level WARNING
        return
    }

    # Bound outside the scriptblock: PowerShell resolves variables against the
    # runtime scope chain when the block runs, so the block must not depend on
    # names the caller might also be using.
    $rowsToSave = @($favorites)
    try {
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Name 'favorites.delete_for_headset' -Parameters @{ headset_id = $headsetId } | Out-Null
            $batch = @()
            $order = 0
            foreach ($f in $rowsToSave) {
                if (-not $f.PackageName) { continue }
                $display = ''
                if ($f.PSObject.Properties['DisplayName']) { $display = [string]$f.DisplayName }
                $batch += @{
                    headset_id   = $headsetId
                    package_name = [string]$f.PackageName
                    display_name = $display
                    sort_order   = $order
                }
                $order++
            }
            # One bound statement reused across the rows, not a call per row.
            Invoke-DbBatch -Name 'favorites.insert' -Rows $batch | Out-Null
        } | Out-Null
    }
    catch {
        Write-Log ("Save-FavoriteApps failed for '{0}' - {1}" -f $headsetName, $_.Exception.Message) -Level ERROR
    }
}

function Show-SubMenu-LaunchApp {
    # -Headset (a registry row) skips the picker: used by the headset panel (Show-HeadsetPanel).
    param($Headset = $null)
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

    if ($Headset) {
        $headset = $Headset
    } else {
        Write-Host ""
        Write-Host $msg.LaunchAppSelectHeadset -ForegroundColor Cyan
        Show-HeadsetsConfig
        Write-Host $msg.ReturnPreviousMenu
        $headsetChoice = Read-Host $msg.YourChoice
        if ($headsetChoice -eq '0') { return }
        $headset = $headsets | Where-Object { $_.ID -eq $headsetChoice }
    }
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
    # DisplayName and IconUrl are joined in from the catalogue rather than read
    # off the cache row. The per-headset CSV used to carry its own copy of both,
    # but the cache moved to a lean schema and stopped writing them, so this menu
    # has been listing blank names since. The catalogue is the only place that
    # owns that metadata, so read it from there.
    $installedApps = @(Get-HeadsetInstalledAppsCached -headsetName $headset.Name -ThirdPartyOnly)
    if ($installedApps.Count -eq 0) {
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


function Show-SubMenu-RemoveHeadset {
    # -Headset (a registry row) removes that one headset after a Y/O confirmation: used by the
    # headset panel (Show-HeadsetPanel). Without it, the operator picks an ID or ALL.
    param($Headset = $null)
    Clear-Host
    Start-Sleep -Milliseconds 200
    $headsets = @(get-knownHeadsets) # @() ensures the object is an array so .Count works
    if (-not $headsets) {
        Write-Log -Message $msg.NoHeadsetFound -Level "INFO"
        Write-Host "There is no headset to delete." -ForegroundColor Yellow
        return
    }

    if ($Headset) {
        Write-Host $msg.RemoveHeadsetTitle -BackgroundColor DarkMagenta
        Write-Host (" {0} - {1}  ({2})" -f $Headset.ID, $Headset.Name, $Headset.IPAddress) -ForegroundColor Cyan
        $confirm = ([string](Read-Host ($msg.Console.RemoveConfirm -f $Headset.Name))).Trim().ToUpper()
        if ($confirm -in @('Y', 'O')) { Remove-Headset -ID ([int]$Headset.ID) }
        else { Write-Log -Message $msg.DeletionCancelled -Level "INFO" }
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
            # Save an empty list. This used to Clear-Content the registry CSV,
            # which after the database migration truncated a file nothing reads:
            # the operator confirmed the deletion, saw "all deleted", and every
            # headset was still there. Save-Headsets deletes the rows the caller
            # left out, so an empty array IS "remove everything", and it takes
            # the per-headset status, timers, apps and favourites with it through
            # ON DELETE CASCADE.
            Save-Headsets -headsets @()
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

function Show-SubMenu-PushHeadsetWifi {
    <#
    .SYNOPSIS
    Console counterpart of POST /api/headsets/push-wifi: pushes one of the
    server's known WiFi networks onto a headset, over the server's own ADB
    connection (ADR-0012 - same Invoke-HeadsetWifiPush behind both).

    .DESCRIPTION
    The SSID is checked against what the HEADSET can see before anything is
    pushed, so a network the headset has no radio for (6 GHz on an older model)
    is refused instead of stranding it off the network.

    .EXAMPLE
    Show-SubMenu-PushHeadsetWifi
    Show-SubMenu-PushHeadsetWifi -Headset $row   # from the headset panel, no picker
    #>
    param($Headset = $null)
    $headsets = @(Get-KnownHeadsets)
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    $networks = @(Get-WifiNetworks)
    if ($networks.Count -eq 0) {
        Write-Log $msg.Headset.WifiNoNetworks -Level WARNING
        Start-Sleep -Seconds 3
        return
    }

    if ($Headset) {
        $headset = $Headset
    } else {
        Show-HeadsetsTable
        Write-Host ""
        $headsetChoice = Read-Host $msg.Headset.WifiPickHeadset
        if ($headsetChoice -eq '0' -or -not $headsetChoice) { return }
        $headset = $headsets | Where-Object { [string]$_.ID -eq [string]$headsetChoice } | Select-Object -First 1
    }
    if (-not $headset) {
        Write-Log $msg.UnrecognizedOption -Level ERROR
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    for ($i = 0; $i -lt $networks.Count; $i++) {
        $tag = if ($networks[$i].Preferred) { " " + $msg.Headset.WifiPreferredTag } else { "" }
        Write-Host ("{0}. {1}{2}" -f ($i + 1), $networks[$i].SSID, $tag)
    }
    Write-Host ""
    $netChoice = Read-Host $msg.Headset.WifiPickNetwork
    $netIndex = 0
    if (-not [int]::TryParse($netChoice, [ref]$netIndex) -or $netIndex -lt 1 -or $netIndex -gt $networks.Count) { return }
    $ssid = $networks[$netIndex - 1].SSID

    Write-Log $msg.Headset.WifiScanning -Level INFO
    $result = Invoke-HeadsetWifiPush -Headset $headset -Ssid $ssid

    if ($result.Pushed) {
        Write-Log ($msg.Headset.WifiPushOk -f $headset.Name, $ssid) -Level SUCCESS
    } elseif ($result.Visible -eq $false) {
        Write-Log ($msg.Headset.WifiNotVisible -f $ssid) -Level WARNING
        if (@($result.VisibleKnown).Count -gt 0) {
            Write-Log ($msg.Headset.WifiVisibleKnown -f (@($result.VisibleKnown) -join ', ')) -Level INFO
        }
    } else {
        Write-Log ($msg.Headset.WifiPushFailed -f $result.Error) -Level ERROR
    }
    Start-Sleep -Seconds 3
}

function Show-SubMenu-HeadsetRefreshRate {
    <#
    .SYNOPSIS
    Console counterpart of the "Refresh Rate" row of the web Configure modal: forces the
    display refresh rate of a Meta Quest (Set-HeadsetRefreshRate). Session only.

    .EXAMPLE
    Show-SubMenu-HeadsetRefreshRate
    Show-SubMenu-HeadsetRefreshRate -Headset $row   # from the headset panel, no picker
    #>
    param($Headset = $null)
    $headsets = @(Get-KnownHeadsets)
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    if ($Headset) {
        $headset = $Headset
    } else {
        Show-HeadsetsTable
        Write-Host ""
        $headsetChoice = Read-Host $msg.Headset.RefreshPickHeadset
        if ($headsetChoice -eq '0' -or -not $headsetChoice) { return }
        $headset = $headsets | Where-Object { [string]$_.ID -eq [string]$headsetChoice } | Select-Object -First 1
    }
    if (-not $headset) {
        Write-Log $msg.UnrecognizedOption -Level ERROR
        Start-Sleep -Seconds 2
        return
    }

    $device = Get-BestAdbDevice -Headset $headset
    if (-not $device) {
        Write-Log ($msg.Headset.RefreshFailed -f 'ADB connection') -Level ERROR
        Start-Sleep -Seconds 3
        return
    }

    $current = Get-HeadsetRefreshRate -Device $device
    $currentText = if ($current) { "$current Hz" } else { '-' }
    Write-Log ($msg.Headset.RefreshCurrent -f $headset.Name, $currentText) -Level INFO

    $rates = @(Get-HeadsetRefreshRateChoices)
    Write-Host ""
    for ($i = 0; $i -lt $rates.Count; $i++) {
        Write-Host ("{0}. {1} Hz" -f ($i + 1), $rates[$i])
    }
    Write-Host ""
    $rateChoice = Read-Host $msg.Headset.RefreshPickRate
    $rateIndex = 0
    if (-not [int]::TryParse($rateChoice, [ref]$rateIndex) -or $rateIndex -lt 1 -or $rateIndex -gt $rates.Count) { return }
    $hz = [int]$rates[$rateIndex - 1]

    if (Set-HeadsetRefreshRate -Device $device -Hz $hz) {
        Write-Log ($msg.Headset.RefreshApplied -f $headset.Name, $hz) -Level SUCCESS
    } else {
        Write-Log ($msg.Headset.RefreshFailed -f $headset.Name) -Level ERROR
    }
    Start-Sleep -Seconds 3
}

function Show-SubMenu-HeadsetSessionSettings {
    <#
    .SYNOPSIS
    Console counterpart of the session-only rows of the web Configure modal (ADR-0040, ADR-0012):
    the "re-apply after reboot" switch, the side double tap (passthrough), the hand tracking
    wide-motion mode, the Guardian pause and the proximity override of a Meta Quest. Every
    change is remembered, so the re-apply after a headset restart can put it back.

    .EXAMPLE
    Show-SubMenu-HeadsetSessionSettings
    Show-SubMenu-HeadsetSessionSettings -Headset $row   # from the headset panel, no picker
    #>
    param($Headset = $null)
    $c = $msg.Console
    $headsets = @(Get-KnownHeadsets)
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }
    if ($Headset) {
        $headset = $Headset
    } else {
        Show-HeadsetsTable
        Write-Host ""
        $headsetChoice = Read-Host $msg.Headset.RefreshPickHeadset
        if ($headsetChoice -eq '0' -or -not $headsetChoice) { return }
        $headset = $headsets | Where-Object { [string]$_.ID -eq [string]$headsetChoice } | Select-Object -First 1
    }
    if (-not $headset) {
        Write-Log $msg.UnrecognizedOption -Level ERROR
        Start-Sleep -Seconds 2
        return
    }
    $brand = [string]$headset.Brand
    if ($brand -eq 'Pico') {
        Write-UiMessage -Text $c.SessionPico -Kind warn
        Start-Sleep -Seconds 2
        return
    }
    $device = Get-BestAdbDevice -Headset $headset
    if (-not $device) {
        Write-UiMessage -Text ($c.SessionNoAdb -f $headset.Name) -Kind err
        Start-Sleep -Seconds 3
        return
    }
    $id = [int]$headset.ID

    $onOff = {
        param($v)
        if ($null -eq $v) { return @{ Text = $c.SessionUnknown; Color = 'DarkGray' } }
        if ($v) { return @{ Text = $c.On; Color = 'Green' } }
        return @{ Text = $c.Off; Color = 'DarkGray' }
    }

    do {
        $saved = Get-HeadsetSessionSettings -HeadsetId $id -NoMemo
        $dt = Get-HeadsetDoubleTapDisabled -Device $device -Brand $brand
        $wm = Get-HeadsetWideMotionMode    -Device $device -Brand $brand
        $gp = Get-HeadsetGuardianPause     -Device $device -Brand $brand
        $px = [bool]$saved.desired.proxKeepAwake
        $re = & $onOff ([bool]$saved.reapply)
        $dtv = if ($null -eq $dt) { @{ Text = $c.SessionUnknown; Color = 'DarkGray' } } elseif ($dt) { @{ Text = $c.SessionDisabled; Color = 'Yellow' } } else { @{ Text = $c.SessionEnabled; Color = 'Green' } }
        $wmv = & $onOff $wm
        $gpv = & $onOff $gp
        $pxv = & $onOff (-not $px)   # On = the sensor works, Off = bypassed (headset stays awake)
        $sh = Get-HeadsetSharpening -Device $device -Brand $brand
        $shv = switch ($sh) {
            'none' { @{ Text = $c.SessionSharpOff;  Color = 'DarkGray' } }
            'fcas' { @{ Text = $c.SessionSharpFcas; Color = 'Green' } }
            'mqsr' { @{ Text = $c.SessionSharpMqsr; Color = 'Green' } }
            'custom' { @{ Text = $c.SessionSharpOther; Color = 'Yellow' } }
            default { @{ Text = $c.SessionUnknown; Color = 'DarkGray' } }
        }
        $items = @(
            @{ Separator = $true; Label = $c.SessionNote },
            @{ Separator = $true },
            @{ Key = '1'; Label = $c.SessionReapply;    Value = $re.Text;  ValueColor = $re.Color },
            @{ Separator = $true },
            @{ Key = '2'; Label = $c.SessionDoubleTap;  Value = $dtv.Text; ValueColor = $dtv.Color },
            @{ Key = '3'; Label = $c.SessionWideMotion; Value = $wmv.Text; ValueColor = $wmv.Color },
            @{ Key = '4'; Label = $c.SessionGuardian;   Value = $gpv.Text; ValueColor = $gpv.Color },
            @{ Key = '5'; Label = $c.SessionProx;       Value = $pxv.Text; ValueColor = $pxv.Color },
            @{ Key = '6'; Label = $c.SessionSharpening; Value = $shv.Text; ValueColor = $shv.Color }
        )
        Write-UiMenu -Title $c.SessionTitle -Subtitle ($c.SessionSubtitle -f $headset.Name) -Items $items -Footer $c.Back -Bg 'DarkBlue'
        $choice = Read-UiKey
        if ($choice -in @('0', 'ESC')) { return }

        $label = $null; $ok = $null; $after = $null
        switch ($choice) {
            '1' {
                $label = $c.SessionReapply
                $new = -not [bool]$saved.reapply
                $ok = Set-HeadsetSessionSettings -HeadsetId $id -Reapply $new
                $after = $(if ($new) { $c.On } else { $c.Off })
            }
            '2' {
                $label = $c.SessionDoubleTap
                $new = -not ($dt -eq $true)
                $ok = Set-HeadsetDoubleTapDisabled -Device $device -Disabled $new -Brand $brand
                if ($ok) { [void](Set-HeadsetSessionSettings -HeadsetId $id -Desired @{ doubleTapOff = $new }) }
                $after = $(if ($new) { $c.SessionDisabled } else { $c.SessionEnabled })
            }
            '3' {
                $label = $c.SessionWideMotion
                $new = -not ($wm -eq $true)
                $ok = Set-HeadsetWideMotionMode -Device $device -Enabled $new -Brand $brand
                if ($ok) { [void](Set-HeadsetSessionSettings -HeadsetId $id -Desired @{ wideMotion = $new }) }
                $after = $(if ($new) { $c.On } else { $c.Off })
            }
            '4' {
                $label = $c.SessionGuardian
                $new = -not ($gp -eq $true)
                $ok = Set-HeadsetGuardianPause -Device $device -Pause $new -Brand $brand
                if ($ok) { [void](Set-HeadsetSessionSettings -HeadsetId $id -Desired @{ guardianPause = $new }) }
                $after = $(if ($new) { $c.On } else { $c.Off })
            }
            '5' {
                $label = $c.SessionProx
                $new = -not $px
                $ok = $(if ($new) { Set-HeadsetProximitySensorOverride -Device $device } else { Set-HeadsetProximitySensorOverride -Device $device -Clear })
                if ($ok) { [void](Set-HeadsetSessionSettings -HeadsetId $id -Desired @{ proxKeepAwake = $new }) }
                $after = $(if ($new) { $c.On } else { $c.Off })
            }
            '6' {
                $label = $c.SessionSharpening
                # none -> FidelityFX CAS -> Meta Quest Super Resolution -> none
                $newMode = switch ($sh) { 'none' { 'fcas' } 'fcas' { 'mqsr' } default { 'none' } }
                $ok = Set-HeadsetSharpening -Device $device -Mode $newMode -Brand $brand
                if ($ok) { [void](Set-HeadsetSessionSettings -HeadsetId $id -Desired @{ sharpening = $newMode }) }
                $after = switch ($newMode) { 'fcas' { $c.SessionSharpFcas } 'mqsr' { $c.SessionSharpMqsr } default { $c.SessionSharpOff } }
            }
            default { }
        }
        if ($label) {
            if ($ok) { Write-UiMessage -Text ($c.SessionDone -f $label, $after) -Kind ok }
            else     { Write-UiMessage -Text $c.SessionFailed -Kind err }
            Wait-UiKey
        }
    } while ($true)
}


function Show-SubMenu-CaptureHeadsetFrame {
    <#
    .SYNOPSIS
    Console counterpart of POST /api/headset-screen-frame: captures one full, uncropped
    scrcpy frame of a headset (Get-HeadsetScreenFrame) and opens the PNG.

    .DESCRIPTION
    Drawing the crop rectangles is web-only (Configuration -> Headset Profiles -> Visual
    editor); from the console the operator reads the pixel positions in an image viewer and
    types the w:h:x:y values into the profile.

    .EXAMPLE
    Show-SubMenu-CaptureHeadsetFrame
    Show-SubMenu-CaptureHeadsetFrame -Headset $row   # from the headset panel, no picker
    #>
    param($Headset = $null)
    $headsets = @(Get-KnownHeadsets)
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    if ($Headset) {
        $headset = $Headset
    } else {
        Show-HeadsetsTable
        Write-Host ""
        $headsetChoice = Read-Host $msg.Headset.FramePickHeadset
        if ($headsetChoice -eq '0' -or -not $headsetChoice) { return }
        $headset = $headsets | Where-Object { [string]$_.ID -eq [string]$headsetChoice } | Select-Object -First 1
    }
    if (-not $headset) {
        Write-Log $msg.UnrecognizedOption -Level ERROR
        Start-Sleep -Seconds 2
        return
    }

    Write-Log ($msg.Headset.FrameCapturing -f $headset.Name) -Level INFO
    $frame = Get-HeadsetScreenFrame -Headset $headset
    if ($frame.Ok) {
        Write-Log ($msg.Headset.FrameSaved -f $frame.Path, $frame.Width, $frame.Height, $frame.Transport) -Level SUCCESS
        # Default image viewer - Open-File would open the PNG in notepad.
        try { Start-Process -FilePath $frame.Path } catch { Write-Log $_.Exception.Message -Level WARNING }
    } else {
        Write-Log ($msg.Headset.FrameFailed -f $frame.Error) -Level ERROR
    }
    Start-Sleep -Seconds 3
}

function Show-HeadsetToggleList {
    <#
    .SYNOPSIS
    The "S Auto-cast" and "R Recording" lists of the main screen: every headset with the
    current state of one flag; typing an ID + Enter toggles it (IDs can have two digits, so
    this list keeps line input), Enter alone goes back. Goes through the web backend
    (Set-HeadsetAutoCast / Set-HeadsetRecording), so a toggle starts / restarts the capture
    at once and the low-disk guard applies.
    .EXAMPLE
    Show-HeadsetToggleList -Field Record
    #>
    param([ValidateSet('scrcpy_AutoRestart', 'Record')] [string]$Field)
    $c = $msg.Console
    $title = if ($Field -eq 'Record') { $c.RecordingTitle } else { $c.AutoCastTitle }
    while ($true) {
        $headsets = @(Get-KnownHeadsets)
        Write-UiMenu -Title $title -Subtitle ('VRHM > ' + $title) -Items @() -Bg 'DarkCyan'
        if ($headsets.Count -eq 0) {
            Write-Host ('  ' + $c.NoHeadsets) -ForegroundColor Yellow
            Wait-UiKey
            return
        }
        Write-Host ('  ' + (Format-UiCell $c.ColId 5) + (Format-UiCell $c.ColHeadset 20) + $title) -ForegroundColor Yellow
        foreach ($h in $headsets) {
            $on = ConvertTo-BoolField $h.$Field
            Write-UiSegments -Segments @(
                (New-UiSegment ('  ' + (Format-UiCell ([string]$h.ID) 5)) 'Cyan'),
                (New-UiSegment (Format-UiCell ([string]$h.Name) 20) 'White'),
                (New-UiSegment $(if ($on) { $c.On } else { $c.Off }) $(if ($on) { 'Green' } else { 'DarkGray' })))
        }
        Write-Host ''
        Write-UiSegments -Segments (Get-CockpitNoticeSegments)
        Write-Host ('  ' + $c.ToggleHint) -ForegroundColor DarkGray
        $choice = ([string](Read-Host '  >')).Trim()
        if (-not $choice -or $choice -eq '0') { return }
        $h = $headsets | Where-Object { [string]$_.ID -eq $choice } | Select-Object -First 1
        if (-not $h) { Set-CockpitNotice -Text ($c.UnknownHeadset -f $choice) -Kind err; continue }
        Invoke-CockpitHeadsetCommand -Headset $h -Action $(if ($Field -eq 'Record') { 'r' } else { 'a' })
    }
}

function Show-SubMenu-scrcpyTracking {
    # "S Auto-cast" tile: auto-restart (scrcpy_AutoRestart) on/off per headset.
    Show-HeadsetToggleList -Field 'scrcpy_AutoRestart'
}

function Show-SubMenu-Recording {
    # "R Recording" tile: recording on/off per headset (refused when the drive is low).
    Show-HeadsetToggleList -Field 'Record'
}


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
            Write-Host $msg.Scrcpy.OptionsTitle -ForegroundColor Cyan
            Write-Host $msg.Scrcpy.OptionsSelectHeadset
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
            if ($parts.Count -eq 4 -and $parts[0] -in @('L','R','M')) { $parts = @('portrait') + $parts }
            if ($parts.Count -ne 5) { $parts = @('portrait','R','N','45','20') }
            $view  = $parts[0].ToLower()
            $eye   = $parts[1].ToUpper()
            $audio = $parts[2].ToUpper()
            $fps   = $parts[3]
            $bw    = $parts[4]
            $eyeLabel   = switch ($eye) { 'L' { 'Left' } 'M' { $msg.EyeMerge.EyeMergedLabel } default { 'Right' } }
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
            $defaultView = Get-ScrcpyDefaultView -Model $headsetModel

            Clear-Host
            Write-Host "$($msg.Scrcpy.OptionsTitle) - $($headset.Name)" -ForegroundColor Cyan
            Write-Host $msg.Separator
            Write-Host " [#]  $($msg.Scrcpy.OptTableHeader)"
            Write-Host $msg.Separator
            Write-Host " [1]  $("View".PadRight(16)) : $view  ($viewList)"
            Write-Host " [2]  $($msg.Scrcpy.OptEyeLabel.PadRight(16)) : $eyeLabel"
            Write-Host " [3]  $($msg.Scrcpy.OptAudioLabel.PadRight(16)) : $audioLabel"
            Write-Host " [4]  $($msg.Scrcpy.OptFPSLabel.PadRight(16)) : $fps"
            Write-Host " [5]  $($msg.Scrcpy.OptBitrateLabel.PadRight(16)) : $bw"
            Write-Host " [6]  $($msg.Headset.ScrcpyOptSetDefaultView)"
            Write-Host " [7]  $(($msg.EyeMerge.Title -f $(if ($headsetModel) { $headsetModel } else { '?' })))"
            $viewObjNow = if ($headsetModel -and $global:scrcpyParameters.$headsetModel -and $global:scrcpyParameters.$headsetModel.views) { $global:scrcpyParameters.$headsetModel.views.$view } else { $null }
            $transpNow  = [bool]($viewObjNow -and $viewObjNow.transparent_corners -eq $true)
            Write-Host " [8]  $(($msg.EyeMerge.TransparentOption -f $view, $(if ($transpNow) { 'ON' } else { 'OFF' })))"
            Write-Host " [0]  $($msg.Return)"

            $opt = Read-Host $msg.Scrcpy.OptionsEnterOption

            switch ($opt) {
                '1' {
                    Write-Host "  Available views:"
                    for ($vi = 0; $vi -lt $availableViews.Count; $vi++) {
                        $marker = if ($availableViews[$vi] -eq $view) { '*' } else { ' ' }
                        $defTag = if ($availableViews[$vi] -eq $defaultView) { ' (default)' } else { '' }
                        Write-Host ("    {0}. {1} {2}{3}" -f ($vi + 1), $availableViews[$vi], $marker, $defTag)
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
                    $val = (Read-Host ($msg.Scrcpy.OptionsEye -f $eye)).ToUpper()
                    if ($val -eq 'M' -and -not (Test-EyeMergeSupported -Model $headsetModel)) {
                        # Merged view only for models with an enabled calibration (option 7).
                        Write-Host ($msg.EyeMerge.NotSupported -f $headsetModel) -ForegroundColor Yellow
                        Start-Sleep -Seconds 3
                    } elseif ($val -in @('L','R','M')) {
                        # Switching to a merged view sets 30 fps (the merge's CPU cost follows the frame rate).
                        if ($val -eq 'M' -and $parts[1] -ne 'M' -and [int]$parts[3] -gt 30) {
                            $parts[3] = '30'
                            Write-Host ($msg.EyeMerge.FpsSetTo30) -ForegroundColor Cyan
                            Start-Sleep -Seconds 2
                        }
                        $parts[1] = $val
                    } else {
                        Write-Host $msg.Scrcpy.OptionsInvalidEye -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '3' {
                    $val = (Read-Host ($msg.Scrcpy.OptionsAudio -f $audio)).ToUpper()
                    if ($val -in @('D','N')) {
                        $parts[2] = $val
                    } else {
                        Write-Host $msg.Scrcpy.OptionsInvalidAudio -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '4' {
                    $val = Read-Host ($msg.Scrcpy.OptionsFPS -f $fps)
                    if ($val -match '^\d+$' -and [int]$val -gt 0) {
                        # Merged view above 30 fps: warn about the CPU cost and ask for confirmation.
                        $advice = Get-EyeMergeFpsAdvice -ScrcpyProfile ('{0}-{1}-{2}-{3}-{4}' -f $parts[0], $parts[1], $parts[2], $val, $parts[4])
                        if ($advice.Warn) {
                            Write-Host ($msg.EyeMerge.FpsWarning -f $val) -ForegroundColor Yellow
                            if ((Read-Host $msg.EyeMerge.FpsConfirm).Trim().ToUpper() -notin @('Y', 'O')) { continue }
                        }
                        $parts[3] = $val
                    } else {
                        Write-Host $msg.Scrcpy.OptionsInvalidNumber -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '5' {
                    $val = Read-Host ($msg.Scrcpy.OptionsBitrate -f $bw)
                    if ($val -match '^\d+$' -and [int]$val -gt 0) {
                        $parts[4] = $val
                    } else {
                        Write-Host $msg.Scrcpy.OptionsInvalidNumber -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '6' {
                    if (-not $headsetModel) {
                        Write-Host "  This headset has no known Model yet - it must be connected at least once." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    } else {
                        # 'fullscreen' is synthesized in code, not a real config.json key - it
                        # can never be persisted as a model's default view.
                        $settableViews = @($availableViews | Where-Object { $_ -ne 'fullscreen' })
                        Write-Host ("  Available views for model '{0}':" -f $headsetModel)
                        for ($vi = 0; $vi -lt $settableViews.Count; $vi++) {
                            $defTag = if ($settableViews[$vi] -eq $defaultView) { ' (current default)' } else { '' }
                            Write-Host ("    {0}. {1}{2}" -f ($vi + 1), $settableViews[$vi], $defTag)
                        }
                        $numInput = Read-Host ("  Select the new default view (1-{0})" -f $settableViews.Count)
                        if ($numInput -match '^\d+$') {
                            $numIdx = [int]$numInput - 1
                            if ($numIdx -ge 0 -and $numIdx -lt $settableViews.Count) {
                                if (Set-ScrcpyDefaultView -Model $headsetModel -View $settableViews[$numIdx]) {
                                    Write-Host ("  '{0}' is now the default view for model '{1}'." -f $settableViews[$numIdx], $headsetModel) -ForegroundColor Green
                                } else {
                                    Write-Host "  Failed to set default view - see log for details." -ForegroundColor Red
                                }
                                Start-Sleep -Seconds 2
                            } else {
                                Write-Host ("  Invalid choice. Enter a number between 1 and {0}." -f $settableViews.Count) -ForegroundColor Red
                                Start-Sleep -Seconds 2
                            }
                        } else {
                            Write-Host "  Invalid input. Enter a number." -ForegroundColor Red
                            Start-Sleep -Seconds 2
                        }
                    }
                }
                '7' {
                    if (-not $headsetModel) {
                        Write-Host "  $($msg.EyeMerge.NoModel)" -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    } else {
                        Show-SubMenu-EyeMerge -Headset $headset
                    }
                }
                '8' {
                if ($p) {
                    $views = @()
                    if ($global:scrcpyParameters.$model.views) { $views = @($global:scrcpyParameters.$model.views.PSObject.Properties.Name) }
                    for ($i = 0; $i -lt $views.Count; $i++) {
                        Write-Host ($msg.EyeMerge.DepthLine -f ($i + 1), $views[$i], (Get-EyeMergeViewBaseEye -Model $model -View $views[$i] -MergeProfile $p))
                    }
                    $n = Read-Host $msg.EyeMerge.ViewPrompt
                    if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $views.Count) {
                        $viewName = $views[[int]$n - 1]
                        $newEye = if ((Get-EyeMergeViewBaseEye -Model $model -View $viewName -MergeProfile $p) -eq 'L') { 'R' } else { 'L' }
                        if (Set-EyeMergeBaseEye -Model $model -View $viewName -BaseEye $newEye) { Write-Host ($msg.EyeMerge.BaseEyeSaved -f $viewName, $newEye) -ForegroundColor Green }
                    }
                    Start-Sleep -Seconds 2
                }
            }
            default { }
            }

            if ($opt -in @('1','2','3','4','5')) {
                $newProfile = $parts -join '-'
                $headset.ScrcpyProfile = $newProfile
                Update-HeadsetField -ID ([int]$headset.ID) -Field "ScrcpyProfile" -NewValue $newProfile
                # Refresh local array so the outer list reflects the change
                $headsets = @(Get-KnownHeadsets)
                $headset = $headsets | Where-Object { $_.ID -eq $idInput }
                Write-Log ($msg.Scrcpy.OptionsSaved -f $headset.Name, $newProfile) -Level INFO
            }
        } while ($opt -ne '0')

        # When called with a specific HeadsetID, return after editing that headset
        if ($HeadsetID -gt 0) { return }
        $idInput = $null

    } while ($true)
}


# Console counterpart of the web "Eye merge" card (vrhm_config.html, Headset Profiles) for the model
# of one headset: calibrate, enable/disable, export / import the shareable snippet, set the merged
# crop and the merge depth of a view as text, switch the main eye (L/R). Drawing the crop stays web-only (visual view editor), like the eye crops.
# Example: Show-SubMenu-EyeMerge -Headset (Get-KnownHeadsets | Select-Object -First 1)
function Show-SubMenu-EyeMerge {
    param([Parameter(Mandatory)] $Headset)
    $model = [string]$Headset.Model
    if (-not $model) { Write-Host "  $($msg.EyeMerge.NoModel)" -ForegroundColor Red; Start-Sleep -Seconds 2; return }
    # Models with lens positions (Quest 2: 58 / 63 / 68 mm): every action below applies to the
    # selected position, which starts at the one the headset is at (ADR-0030).
    $ipdCfg = Get-ModelIpdConfig -Model $model
    $selIpd = if ($ipdCfg) { Get-HeadsetIpdValue -Headset $Headset } else { '' }
    do {
        $p = Get-EyeMergeProfile -Model $model -IncludeDisabled -Ipd $selIpd
        Clear-Host
        Write-Host ($msg.EyeMerge.Title -f $model) -ForegroundColor Cyan
        if ($ipdCfg) {
            $ipdInfo = Get-HeadsetIpdInfo -Headset $Headset
            Write-Host ($msg.EyeMerge.IpdLine -f $selIpd, $ipdInfo.Ipd, $ipdInfo.Source) -ForegroundColor Cyan
        }
        Write-Host $msg.Separator
        if (-not $p) {
            Write-Host $msg.EyeMerge.StatusNone -ForegroundColor Yellow
        } else {
            if ($p.enabled -eq $false) { Write-Host $msg.EyeMerge.StatusDisabled -ForegroundColor Yellow }
            else { Write-Host $msg.EyeMerge.StatusEnabled -ForegroundColor Green }
            Write-Host ($msg.EyeMerge.CalibrationLine -f $p.relative_angle, $p.shift_x, $p.shift_y, $p.score, $p.canvas_width, $p.canvas_height, $p.calibrated_at)
        }
        Write-Host $msg.Separator
        Write-Host " [1]  $($msg.EyeMerge.OptCalibrate)"
        if ($p) {
            Write-Host " [2]  $($msg.EyeMerge.OptToggle)"
            Write-Host " [3]  $($msg.EyeMerge.OptExport)"
        }
        Write-Host " [4]  $($msg.EyeMerge.OptImportClipboard)"
        Write-Host " [5]  $($msg.EyeMerge.OptImportFile)"
        if ($p) {
            Write-Host " [6]  $($msg.EyeMerge.OptViewCrop)"
            if ($null -ne $p.lens_focal_px) { Write-Host " [7]  $($msg.EyeMerge.OptViewDepth)" }
            Write-Host " [8]  $($msg.EyeMerge.OptBaseEye)"
        }
        if ($ipdCfg) { Write-Host " [9]  $($msg.EyeMerge.OptIpd)" }
        Write-Host " [0]  $($msg.Return)"
        $opt = Read-Host $msg.Choice

        switch ($opt) {
            '1' {
                Write-Host "  $($msg.EyeMerge.CalibrateHint)" -ForegroundColor Cyan
                $nFrames = 1
                $ansF = (Read-Host $msg.EyeMerge.CalibrateFramesPrompt).Trim()
                if ($ansF -match '^[1-5]$') { $nFrames = [int]$ansF }
                Write-Host "  $($msg.EyeMerge.CalibrateRunning)"
                $cal = Invoke-EyeMergeCalibration -Headset $Headset -Save -Ipd $selIpd -Frames $nFrames
                if ($cal.Ok -and $cal.Saved) {
                    Write-Host ($msg.EyeMerge.CalibrateOk -f $cal.Profile.relative_angle, $cal.Profile.shift_x, $cal.Profile.shift_y, $cal.Score, $cal.PreviewPath) -ForegroundColor Green
                    if ($cal.PreviewPath) { Open-File -filePath $cal.PreviewPath }
                } else {
                    Write-Host ($msg.EyeMerge.CalibrateFailed -f $cal.Error) -ForegroundColor Red
                }
                Read-Host $msg.PressEnterToContinue | Out-Null
            }
            '2' {
                if ($p) {
                    $newState = ($p.enabled -eq $false)
                    if (Set-EyeMergeEnabled -Model $model -Enabled $newState) {
                        Write-Host ($msg.EyeMerge.Toggled -f $model, $(if ($newState) { 'ON' } else { 'OFF' })) -ForegroundColor Green
                    }
                    Start-Sleep -Seconds 2
                }
            }
            '3' {
                if ($p) {
                    $snippet = Export-EyeMergeProfile -Model $model
                    Write-Host $snippet
                    try { Set-Clipboard -Value $snippet; Write-Host $msg.EyeMerge.ExportCopied -ForegroundColor Green } catch {}
                    Read-Host $msg.PressEnterToContinue | Out-Null
                }
            }
            { $_ -in @('4','5') } {
                $json = $null
                if ($opt -eq '4') {
                    try { $json = Get-Clipboard -Raw } catch { $json = $null }
                } else {
                    $file = (Read-Host $msg.EyeMerge.ImportFilePrompt).Trim('"', ' ')
                    if ($file -and (Test-Path -LiteralPath $file)) { $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 }
                }
                if (-not $json) {
                    Write-Host ($msg.EyeMerge.ImportFailed -f 'empty') -ForegroundColor Red
                } else {
                    $withCrops = (Read-Host $msg.EyeMerge.ImportCropsPrompt).Trim().ToUpper() -in @('Y','O')
                    # Imported into THIS headset's model, whatever model the snippet names.
                    $imp = Import-EyeMergeProfile -Json $json -Model $model -IncludeViewCrops:$withCrops
                    if ($imp.Ok) { Write-Host ($msg.EyeMerge.ImportOk -f $imp.Model, $imp.CropsApplied) -ForegroundColor Green }
                    else { Write-Host ($msg.EyeMerge.ImportFailed -f $imp.Error) -ForegroundColor Red }
                }
                Read-Host $msg.PressEnterToContinue | Out-Null
            }
            '6' {
                if ($p) {
                    $views = @()
                    if ($global:scrcpyParameters.$model.views) { $views = @($global:scrcpyParameters.$model.views.PSObject.Properties.Name) }
                    for ($i = 0; $i -lt $views.Count; $i++) {
                        $c = Get-EyeMergeViewCrop -Model $model -View $views[$i] -Ipd $selIpd
                        $txt = if ($c) { "{0}:{1}:{2}:{3}" -f $c.W, $c.H, $c.X, $c.Y } else { '-' }
                        Write-Host ($msg.EyeMerge.CropLine -f ($i + 1), $views[$i], $txt, $(if ($c -and $c.Auto) { $msg.EyeMerge.CropAuto } else { '' }))
                    }
                    $n = Read-Host $msg.EyeMerge.ViewPrompt
                    if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $views.Count) {
                        $viewName = $views[[int]$n - 1]
                        $val = (Read-Host $msg.EyeMerge.CropPrompt).Trim()
                        $done = $false
                        if ($val -eq 'A' -or $val -eq 'a') { $done = Set-EyeMergeViewCrop -Model $model -View $viewName -Reset -Ipd $selIpd }
                        elseif ($val -match '^\d+:\d+:\d+:\d+$') { $done = Set-EyeMergeViewCrop -Model $model -View $viewName -Crop $val -Ipd $selIpd }
                        elseif ($val) { Write-Host $msg.EyeMerge.CropInvalid -ForegroundColor Red }
                        if ($done) { Write-Host ($msg.EyeMerge.CropSaved -f $viewName) -ForegroundColor Green }
                    }
                    Start-Sleep -Seconds 2
                }
            }
            '7' {
                if ($p -and $null -ne $p.lens_focal_px) {
                    $views = @()
                    if ($global:scrcpyParameters.$model.views) { $views = @($global:scrcpyParameters.$model.views.PSObject.Properties.Name) }
                    for ($i = 0; $i -lt $views.Count; $i++) {
                        $d = Get-EyeMergeViewDepth -Model $model -View $views[$i] -MergeProfile $p -Ipd $selIpd
                        Write-Host ($msg.EyeMerge.DepthLine -f ($i + 1), $views[$i], $(if ($d -gt 0) { "$d m" } else { $msg.EyeMerge.DepthFar }))
                    }
                    $n = Read-Host $msg.EyeMerge.ViewPrompt
                    if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $views.Count) {
                        $viewName = $views[[int]$n - 1]
                        $val = (Read-Host $msg.EyeMerge.DepthPrompt).Trim().Replace(',', '.')
                        $dv = 0.0
                        $done = $false
                        if ($val -in @('F','f','0')) { $done = Set-EyeMergeViewDepth -Model $model -View $viewName -Far -Ipd $selIpd }
                        elseif ([double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dv) -and $dv -ge 0.3 -and $dv -le 100) {
                            $done = Set-EyeMergeViewDepth -Model $model -View $viewName -DepthM $dv -Ipd $selIpd
                        }
                        elseif ($val) { Write-Host $msg.EyeMerge.DepthInvalid -ForegroundColor Red }
                        if ($done) { Write-Host ($msg.EyeMerge.DepthSaved -f $viewName) -ForegroundColor Green }
                    }
                    Start-Sleep -Seconds 2
                }
            }
            '8' {
                if ($p) {
                    $newEye = if ($p.base_eye -eq 'L') { 'R' } else { 'L' }
                    if (Set-EyeMergeBaseEye -Model $model -BaseEye $newEye) { Write-Host ($msg.EyeMerge.BaseEyeSaved -f $model, $newEye) -ForegroundColor Green }
                    Start-Sleep -Seconds 2
                }
            }
            '9' {
                if ($ipdCfg) {
                    $positions = @($ipdCfg.positions | ForEach-Object { [string]$_ })
                    Write-Host ($msg.EyeMerge.IpdCurrent -f $ipdInfo.Ipd, $ipdInfo.Source)
                    for ($i = 0; $i -lt $positions.Count; $i++) { Write-Host (" [{0}] {1} mm" -f ($i + 1), $positions[$i]) }
                    $ans = (Read-Host $msg.EyeMerge.IpdPrompt).Trim()
                    if ($ans -in @('A','a')) {
                        $dev = Resolve-HeadsetAdbDevice -Headset $Headset
                        try { Remove-DbKeyValue -Key ("headset_ipd_{0}" -f [int]$Headset.ID) } catch { }
                        if ($script:HeadsetIpdMemo) { $script:HeadsetIpdMemo.Remove([int]$Headset.ID) }
                        $upd = if ($dev) { Update-HeadsetIpd -Headset $Headset -Device $dev } else { @{ Ipd = ''; Reason = 'unreachable' } }
                        if ($dev -and -not $upd.Ipd) {
                            # No lens event left in the headset log: measure the lens pictures (about 4 s).
                            $ff = Find-HeadsetIpdFromFrame -Headset $Headset
                            if ($ff.Ok) { [void](Set-HeadsetIpd -HeadsetId ([int]$Headset.ID) -Ipd $ff.Ipd -Source auto); $upd = @{ Ipd = $ff.Ipd; Reason = '' } }
                            else { $upd = @{ Ipd = ''; Reason = $ff.Error } }
                        }
                        if ($upd.Ipd) { $selIpd = [string]$upd.Ipd; Write-Host ($msg.EyeMerge.IpdAutoOk -f $selIpd) -ForegroundColor Green }
                        else { Write-Host ($msg.EyeMerge.IpdAutoFailed -f $upd.Reason) -ForegroundColor Red }
                        Start-Sleep -Seconds 2
                    } elseif ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $positions.Count) {
                        $selIpd = $positions[[int]$ans - 1]
                        $dev = Resolve-HeadsetAdbDevice -Headset $Headset
                        [void](Set-HeadsetIpd -HeadsetId ([int]$Headset.ID) -Ipd $selIpd -Source manual -Device $dev)
                        Write-Host ($msg.EyeMerge.IpdSet -f $selIpd) -ForegroundColor Green
                        Start-Sleep -Seconds 2
                    }
                }
            }
            default { }
        }
    } while ($opt -ne '0')
}


function Show-SubMenu-Services {
    $c = $msg.Console
    do {
        # Get-WebServerProcess (scripts_init.ps1) is the single source of truth: it
        # verifies PID + process identity + port, so this display always matches the
        # VRMonitor watchdog's verdict.
        $wsProc    = Get-WebServerProcess
        $wsStatus  = if ($wsProc) { $msg.ServicesRunning -f $wsProc.Id } else { $msg.ServicesStopped }
        $mtxProc   = Get-MediaMtxProcess
        $mtxStatus = if ($mtxProc) { $msg.ServicesRunning -f $mtxProc.Id } else { $msg.ServicesStopped }
        $items = @(
            @{ Separator = $true; Label = ('{0}: {1}' -f $c.SvcStatusWeb, $wsStatus) },
            @{ Key = '1'; Label = $c.SvcWebRestart },
            @{ Key = '2'; Label = $c.SvcWebStop },
            @{ Separator = $true },
            @{ Separator = $true; Label = ('{0}: {1}' -f $c.SvcStatusMtx, $mtxStatus) },
            @{ Key = '3'; Label = $c.SvcMtxRestart },
            @{ Key = '4'; Label = $c.SvcMtxStop },
            @{ Separator = $true },
            @{ Key = 'V'; Label = $c.SvcRecast },
            @{ Key = 'B'; Label = $c.SvcBenchmark }
        )
        Write-UiMenu -Title $c.ServicesTitle -Subtitle 'VRHM > Services' -Items $items -Footer $c.Back -Bg 'DarkGray'

        $choice = Read-UiKey
        if ($choice -eq 'ESC') { $choice = '0' }

        switch ($choice) {
            'V' { Show-SubMenu-VideoRecast }
            'B' { Show-SubMenu-Benchmark }
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
            # mediamtx and the captures belong to VRMonitor (ADR-0032): ask, do not do.
            '3' {
                [void](Request-StreamRestart -MediaMtx -Reason 'mediamtx restart (console)')
                Write-Log $msg.ServicesMediaMtxRestarted -Level SUCCESS
                Start-Sleep -Seconds 1
            }
            '4' {
                # The slow-tick mediamtx watchdog starts it again, as it always did.
                [void](Request-StreamRestart -StopMediaMtx -NoHeadsets -Reason 'mediamtx stop (console)')
                Write-Log $msg.ServicesMediaMtxStopped -Level INFO
                Start-Sleep -Seconds 1
            }
        }
    } while ($choice -ne '0')
}


function Read-BenchmarkIndexList {
    <#
    .SYNOPSIS
    Prints a numbered list (defaults marked *) and reads a comma-separated list of numbers.
    Returns the 0-based indexes chosen; Enter or an invalid answer gives -DefaultIndex.
    .EXAMPLE
    Read-BenchmarkIndexList -Title 'Codec' -Labels @('H264','H265') -DefaultIndex @(0)
    #>
    param(
        [string]$Title,
        [string[]]$Labels,
        [int[]]$DefaultIndex = @(0),
        [switch]$Single,
        # Index of the value the application config uses today: printed red (ADR-0039).
        [int]$CurrentIndex = -1
    )
    Write-Host ""
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $mark = if ($DefaultIndex -contains $i) { '*' } else { ' ' }
        if ($i -eq $CurrentIndex) { Write-Host ("   {0} [{1}] {2} {3}" -f $mark, ($i + 1), $Labels[$i], $msg.Benchmark.ConfigTag) -ForegroundColor Red }
        else { Write-Host ("   {0} [{1}] {2}" -f $mark, ($i + 1), $Labels[$i]) }
    }
    $hint = if ($Single) { $msg.Benchmark.HintSingle } else { $msg.Benchmark.HintMulti }
    $raw = (Read-Host $hint).Trim()
    if (-not $raw) { return @($DefaultIndex) }
    $picked = @()
    foreach ($t in ($raw -split '[,; ]+')) {
        $n = 0
        if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $Labels.Count -and ($picked -notcontains ($n - 1))) { $picked += ($n - 1) }
    }
    if ($picked.Count -eq 0) { return @($DefaultIndex) }
    if ($Single) { return @($picked[0]) }
    return @($picked)
}


function Read-BenchmarkNumberList {
    <#
    .SYNOPSIS
    Shows the offered values and the defaults, then reads values typed by the operator
    (comma-separated, any number inside -Min..-Max). Enter or nothing valid gives -Default.
    .EXAMPLE
    Read-BenchmarkNumberList -Title 'FPS' -Choices @(15,30,45,60) -Default @(45) -Min 5 -Max 120
    #>
    param(
        [string]$Title,
        [int[]]$Choices = @(),
        [int[]]$Default = @(),
        [switch]$Single,
        [int]$Min = 0,
        [int]$Max = 100000,
        # The value the application config uses today: printed red (ADR-0039). Empty = not shown.
        [string]$Current = ''
    )
    Write-Host ""
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ("   " + ($msg.Benchmark.ValuesLine -f (@($Choices) -join ', '), (@($Default) -join ', ')))
    if ($Current -ne '') { Write-Host ("   " + ($msg.Benchmark.CurrentLine -f $Current)) -ForegroundColor Red }
    $hint = if ($Single) { $msg.Benchmark.HintValueSingle } else { $msg.Benchmark.HintValueMulti }
    $raw = (Read-Host $hint).Trim()
    if (-not $raw) { return @($Default) }
    $vals = @()
    foreach ($t in ($raw -split '[,; ]+')) {
        $n = 0
        if ([int]::TryParse($t, [ref]$n) -and $n -ge $Min -and $n -le $Max -and ($vals -notcontains $n)) { $vals += $n }
    }
    if ($vals.Count -eq 0) { return @($Default) }
    if ($Single) { return @($vals[0]) }
    return @($vals)
}


function Resolve-BenchmarkModel {
    <#
    .SYNOPSIS
    Which headset model a stored-result action is about: the model of the last benchmark by
    default (Enter), or the model of a registered headset whose id is typed. '' when none.
    #>
    $last = Get-StreamBenchmarkResult
    $model = if ($last) { [string]$last.Model } else { '' }
    $known = @(Get-KnownHeadsets)
    Write-Host ""
    foreach ($h in $known) { Write-Host ("   {0,3}  {1}  ({2})" -f $h.ID, $h.Name, $h.Model) }
    if ($model) { Write-Host ($msg.Benchmark.ModelLine -f $model) -ForegroundColor Cyan }
    $raw = (Read-Host $msg.Benchmark.ModelPrompt).Trim()
    if ($raw) {
        $picked = $known | Where-Object { [string]$_.ID -eq $raw } | Select-Object -First 1
        if ($picked) { $model = [string]$picked.Model }
    }
    return $model
}


function Start-BenchmarkRunFlow {
    <#
    .SYNOPSIS
    Option [1] of Show-SubMenu-Benchmark for one headset: choose the grid of options, confirm,
    run Invoke-StreamBenchmark in the foreground (Q cancels), print this run's table and
    offer the CSV export of the stored model result.
    #>
    param([Parameter(Mandatory = $true)]$Headset)

    # Reachability from the live status (no ADB call here).
    $live = @(Get-HeadsetInfosMerged) | Where-Object { [string]$_.ID -eq [string]$Headset.ID } | Select-Object -First 1
    $pingOk = $live -and (ConvertTo-BoolField $live.Ping)
    $adbOk  = $live -and (ConvertTo-BoolField $live.ADBWifi)
    if (-not ($pingOk -and $adbOk)) {
        Write-Host ($msg.Benchmark.NotReady -f $Headset.Name, $pingOk, $adbOk) -ForegroundColor Red
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }

    $opt = Get-StreamBenchmarkOptions -Headset $Headset
    if (-not $opt) {
        Write-Host ($msg.Benchmark.Failed -f 'options') -ForegroundColor Red
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }
    $def = $opt.Defaults
    $ch  = $opt.Choices

    # Test set: a preset (one change at a time) or the custom grid.
    Write-Host ""
    Write-Host ("  " + $msg.Benchmark.PromptSet) -ForegroundColor Cyan
    Write-Host ("   " + $msg.Benchmark.SetTypical)
    Write-Host ("   " + $msg.Benchmark.SetQuick)
    Write-Host ("   " + $msg.Benchmark.SetCustom)
    $preset = switch ((Read-Host $msg.Benchmark.SetChoice).Trim()) { '1' { 'typical' } '3' { '' } default { 'typical-quick' } }

    $cur = $opt.Current
    $selection = @{}
    if ($preset) {
        # A preset decides every value (Low / Mid / High scenarios + variants, ADR-0039).
        $selection.Preset = $preset
    }
    else {
    # ---- General: encodings, codec (capture AND re-encode) ----
    Write-Host ""
    Write-Host ("  == " + $msg.Benchmark.SecGeneral) -ForegroundColor White
    $encVals   = @('cpu')
    $encLabels = @($msg.Benchmark.EncCpu)
    foreach ($g in @($opt.Gpus)) {
        $encVals   += ('gpu:' + [int]$g.Index)
        $encLabels += ('GPU {0} - {1}' -f $g.Index, $g.Model)
    }
    $encDef = @(0..($encVals.Count - 1) | Where-Object { @($def.Encodings) -contains $encVals[$_] })
    if ($encDef.Count -eq 0) { $encDef = @(0) }
    $encIdx = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptEncodings -Labels $encLabels -DefaultIndex $encDef -CurrentIndex ([Array]::IndexOf($encVals, [string]$cur.Encoding)))

    $codVals = @('h264', 'h265')
    $codDef  = @(0..1 | Where-Object { @($def.Codecs) -contains $codVals[$_] })
    if ($codDef.Count -eq 0) { $codDef = @(0) }
    $codIdx = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptCodecs -Labels @('H264', 'H265') -DefaultIndex $codDef -CurrentIndex ([Array]::IndexOf($codVals, [string]$cur.Codec)))

    # ---- Headset capture (scrcpy) ----
    Write-Host ""
    Write-Host ("  == " + $msg.Benchmark.SecCapture) -ForegroundColor White
    $maxSizes = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptMaxSize -Choices @($ch.MaxSizes) -Default @([int]$def.MaxSize) -Min 0 -Max 16384 -Current ([string]$cur.MaxSize))
    $bitrates = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptBitrates -Choices @($ch.Bitrates) -Default @($def.Bitrates) -Min 1 -Max 100 -Current ([string]$cur.Mbps))
    $fpsList  = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptFps -Choices @($ch.Fps) -Default @($def.Fps) -Min 5 -Max 120 -Current ([string]$cur.Fps))
    $viewNames = @($opt.Views | ForEach-Object { [string]$_.Name })
    $view = [string]$def.View
    if ($viewNames.Count -gt 0) {
        $viewDef = @(0..($viewNames.Count - 1) | Where-Object { $viewNames[$_] -eq [string]$def.View })
        if ($viewDef.Count -eq 0) { $viewDef = @(0) }
        $viewIdx = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptView -Labels $viewNames -DefaultIndex $viewDef -Single -CurrentIndex ([Array]::IndexOf($viewNames, [string]$cur.View)))
        $view = $viewNames[$viewIdx[0]]
    }
    # Eyes: merged only when the model is calibrated (always CPU-encoded).
    $eyeVals   = @('R')
    $eyeLabels = @($msg.Benchmark.EyeSingle)
    if ($opt.MergeSupported) { $eyeVals += 'M'; $eyeLabels += $msg.Benchmark.EyeMerged }
    $eyeDef = @(0..($eyeVals.Count - 1) | Where-Object { @($def.Eyes) -contains $eyeVals[$_] })
    if ($eyeDef.Count -eq 0) { $eyeDef = @(0) }
    $eyeIdx = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptEyes -Labels $eyeLabels -DefaultIndex $eyeDef -CurrentIndex ([Array]::IndexOf($eyeVals, [string]$cur.Eye)))
    # Parallel captures of the same headset (simulates N headsets), capped in total capture bitrate.
    $lvls = @($ch.Streams | ForEach-Object { [int]$_ })
    $strIdx = @(Read-BenchmarkIndexList -Title ($msg.Benchmark.PromptStreams -f $opt.NetworkCapMbps) -Labels @($lvls | ForEach-Object { [string]$_ }) -DefaultIndex @(0) -Single)

    # ---- Re-encoding and streaming (ffmpeg): swapped without restarting the capture ----
    Write-Host ""
    Write-Host ("  == " + $msg.Benchmark.SecReencode) -ForegroundColor White
    $reencs = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptReencode -Choices @($ch.ReencodeMbps) -Default @([int]$def.ReencodeMbps) -Min 1 -Max 100 -Current ([string]$cur.ReencodeMbps))
    $refps  = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptReencodeFps -Choices @($ch.ReencodeFps) -Default @([int]$def.ReencodeFps) -Min 5 -Max 120 -Current ([string]$cur.ReencodeFps))

    $selection.Encodings    = @($encIdx | ForEach-Object { $encVals[$_] })
    $selection.Codecs       = @($codIdx | ForEach-Object { $codVals[$_] })
    $selection.MaxSize      = $maxSizes
    $selection.Bitrates     = $bitrates
    $selection.Fps          = $fpsList
    $selection.View         = $view
    $selection.Eyes         = @($eyeIdx | ForEach-Object { $eyeVals[$_] })
    $selection.ReencodeMbps = $reencs
    $selection.ReencodeFps  = $refps
    $selection.Streams      = [int]$lvls[$strIdx[0]]
    }
    Write-Host ""
    Write-Host $msg.Benchmark.MeasureChoice
    $measure = switch ((Read-Host $msg.EnterChoice).Trim()) { '1' { 10 } '3' { 40 } default { 20 } }
    $running = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count

    $plan = New-StreamBenchmarkPlan -Headset $Headset -Selection $selection -MeasureSec $measure -RunningStreams $running
    if (-not $plan.Ok) {
        Write-Host ($msg.Benchmark.PlanFailed -f $plan.Error) -ForegroundColor Red
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }

    Write-Host ""
    Write-Host ($msg.Benchmark.Estimate -f $plan.Count, $Headset.Name, (Get-FormattedUptime -Seconds $plan.EstimateSec)) -ForegroundColor Cyan
    # One line per capture group: inside a group only ffmpeg is swapped (ADR-0039).
    Write-Host ($msg.Benchmark.EstimateCaptures -f $plan.Captures) -ForegroundColor DarkGray
    foreach ($g in @($plan.Groups)) { Write-Host ("   - {0}  ({1}, {2})" -f $g.Label, $g.Count, (Get-FormattedUptime -Seconds $g.EstimateSec)) -ForegroundColor DarkGray }
    Write-Host ($msg.Benchmark.StopWarning -f $running) -ForegroundColor Yellow
    $answer = (Read-Host $msg.Benchmark.Confirm).Trim().ToUpper()
    if ($answer -notin @('Y', 'O')) { return }

    Write-Host $msg.Benchmark.CancelHint -ForegroundColor DarkGray
    $global:BenchCancelAsked = $false
    $onProgress = {
        param($state)
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Q' -and -not $global:BenchCancelAsked) {
                    $global:BenchCancelAsked = $true
                    Stop-StreamBenchmark | Out-Null
                    Write-Host $msg.Benchmark.Cancelling -ForegroundColor Yellow
                }
            }
        } catch { }
        if ($state.index -gt 0 -and $state.phase -ne 'done') {
            $line = $msg.Benchmark.Progress -f $state.index, $state.total, $state.current, $state.phase, (Get-FormattedUptime -Seconds $state.etaSec)
            Write-Host ("`r" + $line.PadRight([Math]::Max(1, [Console]::WindowWidth - 1)).Substring(0, [Math]::Max(1, [Console]::WindowWidth - 1))) -NoNewline
        }
    }
    $result = Invoke-StreamBenchmark -Headset $Headset -Tests $plan.Tests -MeasureSec $measure `
        -ProgressFile (Get-StreamBenchmarkProgressPath) -OnProgress $onProgress
    Write-Host ""
    if ($result.Status -eq 'error') { Write-Host ($msg.Benchmark.Failed -f $result.Error) -ForegroundColor Red }
    else { Write-Host ($msg.Benchmark.Finished -f $result.Status, @($result.Results).Count) -ForegroundColor Green }

    # This run's table: one line per test, one utilisation column per GPU.
    $gpuIdx = @(@($result.Gpus) | ForEach-Object { [int]$_.Index })
    $rows = foreach ($r in @($result.Results)) {
        $l = $r.Load
        $capTxt = if ($r.Encoding -eq 'none') { '' } else { '{0} {1} {2}fps {3}M{4}' -f $r.View, $(if ([int]$r.MaxSize -eq 0) { 'native' } elseif ([int]$r.MaxSize -lt 0) { 'full' } else { $r.MaxSize }), $r.Fps, $r.Mbps, $(if ([int]$r.Streams -gt 1) { ' x' + $r.Streams } else { '' }) }
        $row = [ordered]@{
            Capture = $capTxt
            Test   = $r.Label
            Swap   = if ($r.Swapped) { 'yes' } else { '' }
            Status = $r.Status
            'CPU%' = if ($l) { $l.CpuAvg } else { $null }
            'StreamCPU%' = if ($l) { $l.StreamCpuAvg } else { $null }
        }
        foreach ($gi in $gpuIdx) {
            $g = if ($l) { @($l.Gpus) | Where-Object { [int]$_.Index -eq $gi } | Select-Object -First 1 } else { $null }
            $row[('GPU{0}%' -f $gi)] = if ($g) { $g.UtilAvg } else { $null }
        }
        $row['RAM GB']   = if ($l) { $l.RamUsedGB } else { $null }
        $row['FPS']      = if ($r.Stream -and $r.Stream.Fps) { '{0}/{1}' -f $r.Stream.Fps, $r.Stream.TargetFps } else { '' }
        $row['Drop/Dup'] = if ($r.Stream -and $null -ne $r.Stream.Drop) { '{0}/{1}' -f $r.Stream.Drop, $r.Stream.Dup } else { '' }
        [PSCustomObject]$row
    }
    if ($rows) { $rows | Format-Table -AutoSize | Out-Host } else { Write-Host $msg.Benchmark.NoResult }

    $stored = Get-StreamBenchmarkResult -Model ([string]$Headset.Model)
    if ($stored) {
        $exp = (Read-Host $msg.Benchmark.ExportPrompt).Trim().ToUpper()
        if ($exp -in @('Y', 'O')) {
            $safeModel = ([string]$Headset.Model -replace '[^A-Za-z0-9]+', '_').Trim('_')
            $csvPath = Join-Path $global:ScriptPath ("data\benchmark_{0}_{1}.csv" -f $safeModel, (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Write-FileWithoutBom -Path $csvPath -Content (ConvertTo-StreamBenchmarkCsv -Result $stored)
            Write-Host ($msg.Benchmark.Exported -f $csvPath) -ForegroundColor Green
        }
    }
    Read-Host $msg.PressEnterToContinue | Out-Null
}


function Show-BenchmarkRecommendation {
    <#
    .SYNOPSIS
    Option [R] of Show-SubMenu-Benchmark: asks the headset count and the settings, prints the
    estimated PC load and up to 3 proposals, and can apply one (with a preview first).
    #>
    $model = Resolve-BenchmarkModel
    $result = if ($model) { Get-StreamBenchmarkResult -Model $model } else { $null }
    if (-not $result) {
        Write-Host $msg.Benchmark.NeedBenchmark -ForegroundColor Yellow
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }

    $n = 1
    $rawN = (Read-Host $msg.Benchmark.RecoHeadsets).Trim()
    if ($rawN) { $t = 0; if ([int]::TryParse($rawN, [ref]$t) -and $t -ge 1 -and $t -le 64) { $n = $t } }

    $first = Get-StreamBenchmarkRecommendation -Result $result -Headsets $n
    if (-not $first.Ok) {
        Write-Host ([string]$first.Error) -ForegroundColor Yellow
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }
    $c = $first.Choices
    $s = $first.Settings
    $isModel = ([string]$first.Mode -eq 'model')
    Write-Host ""
    if ($isModel) { Write-Host $msg.Benchmark.ModeModel -ForegroundColor Cyan }
    else { Write-Host $msg.Benchmark.ModeMeasured -ForegroundColor Cyan }
    if ($isModel -and $first.Model) {
        Write-Host $msg.Benchmark.ModelHeader -ForegroundColor DarkGray
        foreach ($f in @($first.Model.Families)) {
            $gfit = (@($f.GpuRmse) | ForEach-Object { 'GPU{0} {1:N1}' -f $_.Index, [double]$_.Rmse }) -join ' '
            $mtxt = if ($f.Merged) { $msg.Benchmark.ModelMerged } else { '' }
            Write-Host ($msg.Benchmark.ModelFamily -f $f.Key, $f.Points, $mtxt, ('{0:N1}' -f [double]$f.CpuRmse), $gfit) -ForegroundColor DarkGray
        }
    }

    $idxOf = {
        param($values, $current)
        $vals = @($values | ForEach-Object { [string]$_ })
        $i = [Array]::IndexOf($vals, [string]$current)
        if ($i -lt 0) { 0 } else { $i }
    }
    # Index of the configured value in a list, -1 when absent (printed red, ADR-0039).
    $cfgIdx = { param($values, $current) [Array]::IndexOf(@($values | ForEach-Object { [string]$_ }), [string]$current) }
    $cfgCodec = if ([string]$global:mediamtxCodec -eq 'h265') { 'h265' } else { 'h264' }
    $cfgEnc = if ($global:GPU_Acceleration) { 'gpu:' + [int]$global:GPU_Index } else { 'cpu' }
    $cfgReMb = ConvertTo-StreamBenchmarkMbps $global:mediamtxBitrate
    $cfgReFps = [int]$global:mediamtxFramerate
    $tplNow = Get-StreamBenchmarkModelTemplate -Model $model
    $cfgSize = if ($tplNow -and $null -ne $tplNow.max_size) { [int]$tplNow.max_size } else { 0 }

    # ---- General ----
    Write-Host ""
    Write-Host ("  == " + $msg.Benchmark.SecGeneral) -ForegroundColor White
    $encV = @($c.Encodings)
    $encL = @($encV | ForEach-Object { if ($_ -eq 'cpu') { $msg.Benchmark.EncCpu } else { 'GPU ' + ([string]$_ -replace '^gpu:', '') } })
    $encI = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptEncodings -Labels $encL -DefaultIndex @(& $idxOf $encV $s.Encoding) -Single -CurrentIndex (& $cfgIdx $encV $cfgEnc))
    $codV = @($c.Codecs)
    $codI = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptCodecs -Labels @($codV | ForEach-Object { ([string]$_).ToUpper() }) -DefaultIndex @(& $idxOf $codV $s.Codec) -Single -CurrentIndex (& $cfgIdx $codV $cfgCodec))

    # ---- Headset capture (scrcpy) ----
    Write-Host ""
    Write-Host ("  == " + $msg.Benchmark.SecCapture) -ForegroundColor White
    $szV = @($c.MaxSizes | ForEach-Object { [int]$_ })
    $szI = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptMaxSize -Labels @($szV | ForEach-Object { if ($_ -eq 0) { $msg.Benchmark.NativeSize } else { [string]$_ } }) -DefaultIndex @(& $idxOf $szV $s.MaxSize) -Single -CurrentIndex (& $cfgIdx $szV $cfgSize))
    $fpsC = @($c.Fps | ForEach-Object { [int]$_ })
    $mbpC = @($c.Mbps | ForEach-Object { [int]$_ })
    $fpsMin = if ($fpsC.Count) { ($fpsC | Measure-Object -Minimum).Minimum } else { 5 }
    $fpsMax = if ($fpsC.Count) { ($fpsC | Measure-Object -Maximum).Maximum } else { 120 }
    $mbpMin = if ($mbpC.Count) { ($mbpC | Measure-Object -Minimum).Minimum } else { 1 }
    $mbpMax = if ($mbpC.Count) { ($mbpC | Measure-Object -Maximum).Maximum } else { 100 }
    # Model mode predicts any value: FPS and Mb/s are free numbers, the choices are only suggestions.
    if ($isModel) { $fpsMin = 5; $fpsMax = 120; $mbpMin = 1; $mbpMax = 100 }
    $mbp = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptBitrates -Choices $mbpC -Default @([int]$s.Mbps) -Single -Min $mbpMin -Max $mbpMax)
    $fps = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptFps -Choices $fpsC -Default @([int]$s.Fps) -Single -Min $fpsMin -Max $fpsMax)
    $viewV = @($c.Views)
    $viewI = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptView -Labels @($viewV | ForEach-Object { [string]$_ }) -DefaultIndex @(& $idxOf $viewV $s.View) -Single)
    $eyeV = @($c.Eyes)
    $eyeL = @($eyeV | ForEach-Object { if ($_ -eq 'M') { $msg.Benchmark.EyeMerged } else { $msg.Benchmark.EyeSingle } })
    $eyeI = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptEyes -Labels $eyeL -DefaultIndex @(& $idxOf $eyeV $s.Eye) -Single)

    # ---- Re-encoding and streaming (ffmpeg) ----
    Write-Host ""
    Write-Host ("  == " + $msg.Benchmark.SecReencode) -ForegroundColor White
    $reV = @($c.ReencodeMbps | ForEach-Object { [int]$_ })
    if ($isModel) {
        $reN = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptReencode -Choices $reV -Default @([int]$s.ReencodeMbps) -Single -Min 1 -Max 100 -Current ([string]$cfgReMb))
        $reValue = [int]$reN[0]
    }
    else {
        $reI = @(Read-BenchmarkIndexList -Title $msg.Benchmark.PromptReencode -Labels @($reV | ForEach-Object { [string]$_ }) -DefaultIndex @(& $idxOf $reV $s.ReencodeMbps) -Single -CurrentIndex (& $cfgIdx $reV $cfgReMb))
        $reValue = [int]$reV[$reI[0]]
    }
    $refpsDef = if ($s.ReencodeFps) { [int]$s.ReencodeFps } else { [int]$s.Fps }
    $refpsN = @(Read-BenchmarkNumberList -Title $msg.Benchmark.PromptReencodeFps -Choices @(15, 30, 45, 60) -Default @($refpsDef) -Single -Min 5 -Max 120 -Current ([string]$cfgReFps))

    $maxCpu = [double]$first.Limits.Cpu
    $maxGpu = [double]$first.Limits.Gpu
    Write-Host ""
    $rc = (Read-Host ($msg.Benchmark.RecoMaxCpu -f $maxCpu)).Trim()
    $d = 0.0
    if ($rc -and [double]::TryParse($rc, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { $maxCpu = $d }
    $rg = (Read-Host ($msg.Benchmark.RecoMaxGpu -f $maxGpu)).Trim()
    if ($rg -and [double]::TryParse($rg, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { $maxGpu = $d }

    $settings = @{
        Eye          = [string]$eyeV[$eyeI[0]]
        View         = [string]$viewV[$viewI[0]]
        Encoding     = [string]$encV[$encI[0]]
        Codec        = [string]$codV[$codI[0]]
        Fps          = [int]$fps[0]
        Mbps         = [int]$mbp[0]
        ReencodeFps  = [Math]::Min([int]$refpsN[0], [int]$fps[0])
        ReencodeMbps = $reValue
        MaxSize      = [int]$szV[$szI[0]]
    }

    # Scenario loop: estimate, Low / Mid / High proposals; a proposal only becomes the scenario,
    # [A] is the one config write (ADR-0039).
    while ($true) {
        $rec = Get-StreamBenchmarkRecommendation -Result $result -Headsets $n -Settings $settings -MaxCpu $maxCpu -MaxGpu $maxGpu
        if (-not $rec.Ok) {
            Write-Host ([string]$rec.Error) -ForegroundColor Yellow
            Read-Host $msg.PressEnterToContinue | Out-Null
            return
        }
        $settings = $rec.Settings
        $st = $settings
        Write-Host ""
        Write-Host ($msg.Benchmark.EstHeader -f $n, $model) -ForegroundColor Cyan
        Write-Host ("   " + ($msg.Benchmark.ScenarioLine -f $st.View, $(if ([int]$st.MaxSize -eq 0) { $msg.Benchmark.NativeSize } elseif ([int]$st.MaxSize -lt 0) { 'full frame' } else { $st.MaxSize }), $st.Fps, $st.Mbps, $st.ReencodeFps, $st.ReencodeMbps, $st.Encoding, ([string]$st.Codec).ToUpper())) -ForegroundColor White
        $e = $rec.Estimate
        if ($e.NotMeasured) {
            Write-Host ([string]$e.Message) -ForegroundColor Yellow
        }
        else {
            $verdict = { param($fits) if ($fits) { @($msg.Benchmark.Ok, 'Green') } else { @($msg.Benchmark.Over, 'Red') } }
            $v = & $verdict $e.CpuFits
            if ($null -ne $e.CpuBand) {
                Write-Host ($msg.Benchmark.EstResourceBand -f 'CPU', ('{0:N1}' -f [double]$e.Cpu), ('{0:N1}' -f [double]$e.CpuBand), $rec.Limits.Cpu, $v[0]) -ForegroundColor $v[1]
            }
            else {
                Write-Host ($msg.Benchmark.EstResource -f 'CPU', ('{0:N1}' -f [double]$e.Cpu), $rec.Limits.Cpu, $v[0]) -ForegroundColor $v[1]
            }
            foreach ($g in @($e.Gpus)) {
                $v = & $verdict $g.Fits
                $gname = 'GPU {0} ({1})' -f $g.Index, $g.Model
                if ($null -ne $g.Band) {
                    Write-Host ($msg.Benchmark.EstResourceBand -f $gname, ('{0:N1}' -f [double]$g.Pct), ('{0:N1}' -f [double]$g.Band), $rec.Limits.Gpu, $v[0]) -ForegroundColor $v[1]
                }
                else {
                    Write-Host ($msg.Benchmark.EstResource -f $gname, ('{0:N1}' -f [double]$g.Pct), $rec.Limits.Gpu, $v[0]) -ForegroundColor $v[1]
                }
            }
            if ($e.W -and $e.H) { Write-Host ($msg.Benchmark.EstPicture -f $e.W, $e.H) }
            if ($e.InRange -eq $false) { Write-Host $msg.Benchmark.WarnRange -ForegroundColor Yellow }
            if ($e.FpsRisk) { Write-Host $msg.Benchmark.WarnFps -ForegroundColor Yellow }
            if ($e.SessionCap -and [int]$e.SessionCap -gt 0) { Write-Host ($msg.Benchmark.WarnCap -f $e.SessionCap) -ForegroundColor Yellow }
            Write-Host ($msg.Benchmark.EstRam -f ('{0:N1}' -f [double]$e.RamGB))
            Write-Host ($msg.Benchmark.EstMax -f $e.MaxHeadsets)
            Write-Host ($msg.Benchmark.EstWifi -f ('{0:N0}' -f [double]$e.CaptureMbpsTotal), ('{0:N0}' -f [double]$e.ReencodeMbpsPerViewer))
            $how = if ($e.Measured) { $msg.Benchmark.EstMeasured } elseif ($e.Interpolated) { $msg.Benchmark.EstInterpolated } else { '' }
            if ($how) { Write-Host $how -ForegroundColor DarkGray }
        }
        if ($rec.Note) { Write-Host ([string]$rec.Note) -ForegroundColor DarkGray }

        $props = @($rec.Proposals)
        Write-Host ""
        Write-Host $msg.Benchmark.ProposalsHeader -ForegroundColor Cyan
        if ($props.Count -eq 0) { Write-Host $msg.Benchmark.NoProposal -ForegroundColor Yellow }
        for ($i = 0; $i -lt $props.Count; $i++) {
            $p = $props[$i]
            $pe = $p.Estimate
            Write-Host ("  [{0}] {1}" -f ($i + 1), $p.Label) -ForegroundColor White
            if ($null -ne $pe.CpuBand) {
                $gtxt = (@($pe.Gpus) | ForEach-Object { 'GPU{0} {1:N0}% +/- {2:N0}%' -f $_.Index, [double]$_.Pct, [double]$_.Band }) -join '  '
                Write-Host ($msg.Benchmark.ProposalLineBand -f $p.Encoder, ('{0:N0}' -f [double]$pe.Cpu), ('{0:N0}' -f [double]$pe.CpuBand), $gtxt, ('{0:N1}' -f [double]$pe.RamGB), $pe.MaxHeadsets)
            }
            else {
                $gtxt = (@($pe.Gpus) | ForEach-Object { 'GPU{0} {1:N0}%' -f $_.Index, [double]$_.Pct }) -join '  '
                Write-Host ($msg.Benchmark.ProposalLine -f $p.Encoder, ('{0:N0}' -f [double]$pe.Cpu), $gtxt, ('{0:N1}' -f [double]$pe.RamGB), $pe.MaxHeadsets)
            }
            if ($pe.InRange -eq $false) { Write-Host ("      " + $msg.Benchmark.WarnRange.Trim()) -ForegroundColor Yellow }
            if ($pe.FpsRisk) { Write-Host ("      " + $msg.Benchmark.WarnFps.Trim()) -ForegroundColor Yellow }
        }
        $pick = (Read-Host ($msg.Benchmark.ScenarioPick -f $props.Count)).Trim().ToUpper()
        $pi = 0
        if ([int]::TryParse($pick, [ref]$pi) -and $pi -ge 1 -and $pi -le $props.Count) { $settings = $props[$pi - 1].Settings; continue }
        if ($pick -eq 'A') { break }
        return
    }

    # ---- Apply the scenario to the global configuration (preview, then confirm) ----
    $ofModel = @(Get-KnownHeadsets | Where-Object { [string]$_.Model -eq $model })
    $ids = @()
    if ($ofModel.Count -gt 0) {
        Write-Host ""
        foreach ($h in $ofModel) { Write-Host ("   {0,3}  {1}" -f $h.ID, $h.Name) }
        $rawIds = (Read-Host $msg.Benchmark.WhichHeadsets).Trim()
        $ids = @($ofModel | ForEach-Object { [int]$_.ID })
        if ($rawIds) {
            $want = @()
            foreach ($t in ($rawIds -split '[,; ]+')) { $x = 0; if ([int]::TryParse($t, [ref]$x) -and ($ids -contains $x) -and ($want -notcontains $x)) { $want += $x } }
            if ($want.Count -gt 0) { $ids = $want }
        }
    }
    else { Write-Host ($msg.Benchmark.NoHeadsetOfModel -f $model) -ForegroundColor Yellow }

    $prev = Set-StreamBenchmarkRecommendation -Model $model -Settings $settings -HeadsetIds $ids -Preview
    if (-not $prev.Ok) {
        Write-Host ($msg.Benchmark.ApplyFailed -f $prev.Error) -ForegroundColor Red
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }
    Write-Host $msg.Benchmark.Changes -ForegroundColor Cyan
    foreach ($line in @($prev.Changes)) { Write-Host ("   - " + $line) }
    if (@($prev.Changes).Count -eq 0) { Write-Host ("   " + $msg.Benchmark.NoChange) }
    $ok = (Read-Host $msg.Benchmark.ApplyConfirm).Trim().ToUpper()
    if ($ok -notin @('Y', 'O')) { return }
    $done = Set-StreamBenchmarkRecommendation -Model $model -Settings $settings -HeadsetIds $ids
    if ($done.Ok) { Write-Host $msg.Benchmark.Applied -ForegroundColor Green }
    else { Write-Host ($msg.Benchmark.ApplyFailed -f $done.Error) -ForegroundColor Red }
    Read-Host $msg.PressEnterToContinue | Out-Null
}


function Show-BenchmarkParallelResult {
    <#
    .SYNOPSIS
    Prints a parallel check result (Invoke-StreamBenchmarkParallel / Get-StreamBenchmarkParallelResult):
    resource | idle | measured above idle | predicted | ratio, then the delivered fps per headset.
    .EXAMPLE
    Show-BenchmarkParallelResult -Result (Get-StreamBenchmarkParallelResult)
    #>
    param($Result)
    if (-not $Result) { Write-Host $msg.Benchmark.ParNoResult -ForegroundColor Yellow; return }
    if ($Result.Error) { Write-Host ($msg.Benchmark.Failed -f $Result.Error) -ForegroundColor Red }
    $s = $Result.Settings
    if ($s) {
        Write-Host ($msg.Benchmark.ParSettingsLine -f $s.Encoding, $s.Codec, $s.Fps, $s.Mbps, $s.ReencodeMbps, $Result.Timestamp) -ForegroundColor Cyan
    }
    $fmt = { param($v, $f) if ($null -eq $v) { '-' } else { $f -f [double]$v } }
    $ratioOf = {
        param($ratio, $idx)
        if (-not $ratio -or -not $ratio.Gpu) { return $null }
        if ($ratio.Gpu -is [System.Collections.IDictionary]) { return $ratio.Gpu[[string]$idx] }
        $p = $ratio.Gpu.PSObject.Properties[[string]$idx]
        if ($p) { return $p.Value } else { return $null }
    }
    $base = $Result.Baseline
    $meas = $Result.Measured
    $pred = $Result.Predicted
    $rows = @()
    $rows += [PSCustomObject][ordered]@{
        Resource = 'CPU (stream)'
        Idle = (& $fmt $base.StreamCpu '{0:N1}%'); 'Above idle' = (& $fmt $meas.Cpu '{0:N1}%')
        Predicted = (& $fmt $pred.Cpu '{0:N1}%'); Ratio = (& $fmt $Result.Ratio.Cpu '{0:N2}')
    }
    foreach ($g in @($meas.Gpus)) {
        $bg = @($base.Gpus) | Where-Object { [int]$_.Index -eq [int]$g.Index } | Select-Object -First 1
        $pg = @($pred.Gpus) | Where-Object { [int]$_.Index -eq [int]$g.Index } | Select-Object -First 1
        $rows += [PSCustomObject][ordered]@{
            Resource = ('GPU {0}' -f $g.Index)
            Idle = $(if ($bg) { & $fmt $bg.Pct '{0:N1}%' } else { '-' }); 'Above idle' = (& $fmt $g.Pct '{0:N1}%')
            Predicted = $(if ($pg) { & $fmt $pg.Pct '{0:N1}%' } else { '-' }); Ratio = (& $fmt (& $ratioOf $Result.Ratio $g.Index) '{0:N2}')
        }
    }
    $rows += [PSCustomObject][ordered]@{
        Resource = 'RAM GB'
        Idle = (& $fmt $base.RamGB '{0:N1}'); 'Above idle' = (& $fmt $meas.RamGB '{0:N1}')
        Predicted = (& $fmt $pred.RamGB '{0:N1}'); Ratio = '-'
    }
    $rows | Format-Table -AutoSize | Out-Host
    if ($meas.WholeCpu) { Write-Host ($msg.Benchmark.ParWholeCpu -f ('{0:N1}' -f [double]$meas.WholeCpu)) }
    foreach ($h in @($Result.Headsets)) {
        $state = if ($h.Started) { '{0}/{1} fps' -f $h.Fps, $h.TargetFps } else { $msg.Benchmark.ParNotStarted }
        Write-Host ("   {0}: {1}" -f $h.Name, $state)
    }
    if ($pred -and -not $pred.Ok -and $pred.Note) { Write-Host ([string]$pred.Note) -ForegroundColor Yellow }
    Write-Host $msg.Benchmark.ParRatioHint -ForegroundColor DarkGray
}


function Start-BenchmarkParallelFlow {
    <#
    .SYNOPSIS
    Option [P] of Show-SubMenu-Benchmark: streams the same settings on several ready headsets at
    once (Invoke-StreamBenchmarkParallel, Q cancels) and compares the PC load with the model.
    #>
    $live = @(Get-HeadsetInfosMerged | Where-Object { (ConvertTo-BoolField $_.Ping) -and (ConvertTo-BoolField $_.ADBWifi) })
    if ($live.Count -eq 0) {
        Write-Host $msg.Benchmark.ParNoneReady -ForegroundColor Yellow
        Read-Host $msg.PressEnterToContinue | Out-Null
        return
    }
    Write-Host ""
    Write-Host ("  " + $msg.Benchmark.ParTitle) -ForegroundColor Cyan
    foreach ($h in $live) { Write-Host ("   {0,3}  {1}  ({2})" -f $h.ID, $h.Name, $h.Model) }
    $ids = @($live | ForEach-Object { [int]$_.ID })
    $raw = (Read-Host $msg.Benchmark.ParWhich).Trim()
    if ($raw) {
        $want = @()
        foreach ($t in ($raw -split '[,; ]+')) { $x = 0; if ([int]::TryParse($t, [ref]$x) -and ($ids -contains $x) -and ($want -notcontains $x)) { $want += $x } }
        if ($want.Count -gt 0) { $ids = $want }
    }
    $rows = @($ids | ForEach-Object { Get-HeadsetDiagTarget -Id $_ } | Where-Object { $_ })
    if ($rows.Count -eq 0) { return }

    # Default settings: a recommendation for the model of the first headset, else the benchmark defaults.
    $set = $null
    $model = [string]$rows[0].Model
    $stored = Get-StreamBenchmarkResult -Model $model
    if ($stored) {
        $rec = Get-StreamBenchmarkRecommendation -Result $stored -Headsets $rows.Count
        if ($rec -and $rec.Ok -and $rec.Settings) { $set = $rec.Settings }
    }
    if (-not $set) {
        $opt = Get-StreamBenchmarkOptions -Headset $rows[0]
        if (-not $opt) { Write-Host ($msg.Benchmark.Failed -f 'options') -ForegroundColor Red; Read-Host $msg.PressEnterToContinue | Out-Null; return }
        $d = $opt.Defaults
        $set = [PSCustomObject]@{
            Eye = [string]@($d.Eyes)[0]; Encoding = [string]@($d.Encodings)[0]; Codec = [string]@($d.Codecs)[0]
            Fps = [int]@($d.Fps)[0]; Mbps = [int]@($d.Bitrates)[0]; ReencodeMbps = [int]$d.ReencodeMbps; MaxSize = [int]$d.MaxSize
        }
    }
    $settings = @{
        Eye = [string]$set.Eye; Encoding = [string]$set.Encoding; Codec = [string]$set.Codec
        Fps = [int]$set.Fps; Mbps = [int]$set.Mbps; ReencodeMbps = [int]$set.ReencodeMbps; MaxSize = [int]$set.MaxSize
    }
    Write-Host ""
    Write-Host ($msg.Benchmark.ParDefaults -f $settings.Encoding, $settings.Codec, $settings.Fps, $settings.Mbps) -ForegroundColor Cyan
    $custom = (Read-Host $msg.Benchmark.ParCustomize).Trim().ToUpper()
    if ($custom -eq 'C') {
        $v = (Read-Host ($msg.Benchmark.ParAskEncoding -f $settings.Encoding)).Trim().ToLower()
        if ($v -match '^(cpu|gpu:\d+)$') { $settings.Encoding = $v }
        $v = (Read-Host ($msg.Benchmark.ParAskCodec -f $settings.Codec)).Trim().ToLower()
        if ($v -in @('h264', 'h265')) { $settings.Codec = $v }
        $n = 0
        $v = (Read-Host ($msg.Benchmark.ParAskFps -f $settings.Fps)).Trim()
        if ([int]::TryParse($v, [ref]$n) -and $n -ge 5 -and $n -le 120) { $settings.Fps = $n }
        $v = (Read-Host ($msg.Benchmark.ParAskMbps -f $settings.Mbps)).Trim()
        if ([int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 100) { $settings.Mbps = $n }
    }

    Write-Host ""
    Write-Host $msg.Benchmark.MeasureChoice
    $measure = switch ((Read-Host $msg.EnterChoice).Trim()) { '1' { 10 } '3' { 40 } default { 20 } }
    $running = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count
    Write-Host ($msg.Benchmark.ParEstimate -f $rows.Count) -ForegroundColor Cyan
    Write-Host ($msg.Benchmark.StopWarning -f $running) -ForegroundColor Yellow
    $answer = (Read-Host $msg.Benchmark.ParConfirm).Trim().ToUpper()
    if ($answer -notin @('Y', 'O')) { return }
    if (Test-StreamBenchmarkActive) { Write-Host $msg.Benchmark.AlreadyRunning -ForegroundColor Yellow; Start-Sleep -Seconds 2; return }

    Write-Host $msg.Benchmark.CancelHint -ForegroundColor DarkGray
    $global:BenchCancelAsked = $false
    $onProgress = {
        param($state)
        try {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Q' -and -not $global:BenchCancelAsked) {
                    $global:BenchCancelAsked = $true
                    Stop-StreamBenchmark | Out-Null
                    Write-Host $msg.Benchmark.Cancelling -ForegroundColor Yellow
                }
            }
        } catch { }
        if ($state.phase -and $state.phase -ne 'done') {
            $line = $msg.Benchmark.ParProgress -f $state.index, $state.total, $state.phase
            Write-Host ("`r" + $line.PadRight([Math]::Max(1, [Console]::WindowWidth - 1)).Substring(0, [Math]::Max(1, [Console]::WindowWidth - 1))) -NoNewline
        }
    }
    $result = Invoke-StreamBenchmarkParallel -Headsets $rows -Settings $settings -MeasureSec $measure `
        -ProgressFile (Get-StreamBenchmarkProgressPath) -OnProgress $onProgress
    Write-Host ""
    Show-BenchmarkParallelResult -Result $result
    Read-Host $msg.PressEnterToContinue | Out-Null
}


function Show-SubMenu-Benchmark {
    <#
    .SYNOPSIS
    Console counterpart of the Benchmark section of headsets_monitoring.html (ADR-0026):
    [1] run a benchmark (grid of options, foreground run, Q cancels), [R] recommendations
    from the stored results, [X] clear the stored results of a model.
    #>
    do {
        Clear-Host
        Write-UiTitle -Title $msg.Console.BenchmarkTitle -Subtitle 'VRHM > Services > Benchmark' -Bg 'DarkGray'
        Write-Host ""
        Write-Host ("  " + $msg.Benchmark.Intro)
        Write-Host ""
        Write-Host ("  " + $msg.Benchmark.MenuRun)
        Write-Host ("  " + $msg.Benchmark.MenuReco)
        Write-Host ("  " + $msg.Benchmark.MenuParallel)
        Write-Host ("  " + $msg.Benchmark.MenuParallelLast)
        Write-Host ("  " + $msg.Benchmark.MenuClear)
        Write-Host ("  " + $msg.Benchmark.MenuBack)
        Write-Host ""
        $choice = Read-UiKey
        if ($choice -eq 'ESC') { $choice = '0' }
        switch ($choice) {
            '1' {
                if (Test-StreamBenchmarkActive) {
                    Write-Host $msg.Benchmark.AlreadyRunning -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
                else {
                    Show-HeadsetPickerMenu -Title ("`n  " + $msg.Benchmark.Title + "`n  " + $msg.Benchmark.PickHeadset + "`n") -OnPick {
                        param($Headset)
                        Start-BenchmarkRunFlow -Headset $Headset
                    }
                }
            }
            'R' { Show-BenchmarkRecommendation }
            'P' {
                if (Test-StreamBenchmarkActive) {
                    Write-Host $msg.Benchmark.AlreadyRunning -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
                else { Start-BenchmarkParallelFlow }
            }
            'L' {
                Write-Host ""
                Show-BenchmarkParallelResult -Result (Get-StreamBenchmarkParallelResult)
                Read-Host $msg.PressEnterToContinue | Out-Null
            }
            'X' {
                $model = Resolve-BenchmarkModel
                if ($model -and (Get-StreamBenchmarkResult -Model $model)) {
                    $ok = (Read-Host ($msg.Benchmark.ClearConfirm -f $model)).Trim().ToUpper()
                    if ($ok -in @('Y', 'O')) {
                        if (Clear-StreamBenchmarkResult -Model $model) { Write-Host ($msg.Benchmark.Cleared -f $model) -ForegroundColor Green }
                        else { Write-Host $msg.Benchmark.ClearFailed -ForegroundColor Red }
                        Start-Sleep -Seconds 1
                    }
                }
                else {
                    Write-Host $msg.Benchmark.NoResult -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
            }
        }
    } while ($choice -ne '0')
}


function Get-CaptureModeLabel {
    # Readable name of a Performance.Capture_Mode value (Console.Capture* strings).
    param([string]$Mode = $global:CaptureMode)
    switch ($Mode) {
        'StreamOnly'           { return $msg.Console.CaptureStreamOnly }
        'StreamAndLocalWindow' { return $msg.Console.CaptureBoth }
        'LocalWindow'          { return $msg.Console.CaptureLocal }
        default                { return [string]$Mode }
    }
}

function Show-SubMenu-Config {
    $c = $msg.Console
    do {
        $adbPref = switch ([string]$global:ADB_wifi_effective_preferred) { 'tls' { 'TLS' } 'classic' { 'classic' } default { $msg.AdbWifi.MenuNoPreference } }
        $items = @(
            @{ Key = 'W'; Label = $c.CfgWifi },
            @{ Key = 'A'; Label = $c.CfgAdbWifi;   Value = $adbPref },
            @{ Key = 'V'; Label = $c.CfgCapture;   Value = (Get-CaptureModeLabel) }
        )
        if ($global:VQA_Enabled) { $items += @{ Key = 'Q'; Label = $c.CfgQuality } }
        Write-UiMenu -Title $c.ConfigTitle -Subtitle 'VRHM > Config' -Items $items -Footer $c.Back -Bg 'DarkBlue'
        $choice = Read-UiKey
        if ($choice -eq 'ESC') { $choice = '0' }
        switch ($choice) {
            'W' { Show-SubMenu-WifiNetworks }
            'V' { Show-SubMenu-CaptureMode }
            'A' { Show-SubMenu-AdbWifiModes }
            'Q' {
                if ($global:VQA_Enabled -and (Get-Command Show-SubMenu-Monitoring -ErrorAction SilentlyContinue)) {
                    Show-SubMenu-Monitoring
                }
            }
            '0' { return }
        }
    } while ($true)
}


function Show-SubMenu-AdbWifiModes {
    # Console counterpart of the ADB WiFi modes card of vrhm_config.html (ADR-0034, ADR-0012):
    # toggle classic / TLS and pick the preferred mode. Writes config.json like the web save
    # (VQA lock + Write-ConfigJson) and reloads the globals; VRMonitor follows on its next slow
    # tick (Test-ConfigChanged), no restart.
    do {
        Clear-Host
        Write-UiTitle -Title $msg.Console.AdbWifiTitle -Subtitle 'VRHM > Config > ADB WiFi modes' -Bg 'DarkBlue'
        Write-Host ""
        $onText = { param($v) if ($v) { $msg.AdbWifi.MenuEnabled } else { $msg.AdbWifi.MenuDisabled } }
        Write-Host ($msg.AdbWifi.MenuClassic -f (& $onText $global:ADB_wifi_classic_enabled), (Get-ClassicAdbPort))
        Write-Host ($msg.AdbWifi.MenuTls -f (& $onText $global:ADB_wifi_tls_enabled))
        # auto = no preference (ADR-0037); the "in use" value is auto too when one mode is disabled.
        $modeText = { param($v) switch ([string]$v) { 'tls' { 'TLS' } 'classic' { 'classic' } default { $msg.AdbWifi.MenuNoPreference } } }
        $prefText = & $modeText $global:ADB_wifi_preferred_mode
        $effText  = & $modeText $global:ADB_wifi_effective_preferred
        Write-Host ($msg.AdbWifi.MenuPreferred -f $prefText, $effText)
        Write-Host ""
        Write-Host $msg.AdbWifi.MenuHint -ForegroundColor DarkGray
        Write-Host ""
        Write-Host ('  ' + $msg.Console.Back) -ForegroundColor DarkGray
        $choice = Read-UiKey
        if ($choice -in @('0', 'ESC')) { return }
        if ($choice -notin @('1', '2', '3')) { continue }

        $cfgPath = if ($global:ConfigFilePath) { $global:ConfigFilePath } else { Join-Path $global:ScriptPath "config\config.json" }
        $saved = $false
        $cfgLock = Enter-VqaLock -TimeoutMs 5000
        try {
            $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
            if ($cfg) {
                if ($null -eq $cfg.ADB) { $cfg | Add-Member -NotePropertyName ADB -NotePropertyValue ([PSCustomObject]@{}) }
                # Toggle from the file just read (the web page may have changed it since this
                # process last ran Get-Config), with the loader's defaults when a key is absent.
                $curClassic = if ($null -ne $cfg.ADB.wifi_classic_enabled) { [bool]$cfg.ADB.wifi_classic_enabled } else { $true }
                $curTls     = if ($null -ne $cfg.ADB.wifi_tls_enabled)     { [bool]$cfg.ADB.wifi_tls_enabled }     else { $true }
                $curPref    = if ($cfg.ADB.wifi_preferred_mode) { ([string]$cfg.ADB.wifi_preferred_mode).Trim().ToLowerInvariant() } else { 'auto' }
                switch ($choice) {
                    '1' { $cfg.ADB | Add-Member -NotePropertyName wifi_classic_enabled -NotePropertyValue (-not $curClassic) -Force }
                    '2' { $cfg.ADB | Add-Member -NotePropertyName wifi_tls_enabled     -NotePropertyValue (-not $curTls) -Force }
                    '3' {
                        # Cycles auto -> classic -> tls -> auto.
                        $nextPref = switch ($curPref) { 'auto' { 'classic' } 'classic' { 'tls' } default { 'auto' } }
                        $cfg.ADB | Add-Member -NotePropertyName wifi_preferred_mode -NotePropertyValue $nextPref -Force
                    }
                }
                Write-ConfigJson -Object $cfg -Path $cfgPath -Depth 20
                $saved = $true
            }
        } catch {
            Write-Host ($msg.AdbWifi.MenuSaveFailed -f $_.Exception.Message) -ForegroundColor Red
        } finally {
            if ($cfgLock) { Exit-VqaLock -Stream $cfgLock }
        }
        if ($saved) {
            Get-Config -ConfigFilePath $cfgPath | Out-Null
            Write-Host ""
            Write-Host $msg.AdbWifi.MenuSaved -ForegroundColor Green
            Read-Host $msg.PressEnterToContinue | Out-Null
        }
    } while ($true)
}


function Show-SubMenu-CaptureMode {
    $c = $msg.Console
    do {
        $items = @(
            @{ Separator = $true; Label = ('{0}: {1}' -f $c.CaptureCurrent, (Get-CaptureModeLabel)) },
            @{ Separator = $true },
            @{ Key = '1'; Label = $c.CaptureOpt1 },
            @{ Key = '2'; Label = $c.CaptureOpt2 },
            @{ Key = '3'; Label = $c.CaptureOpt3 },
            @{ Separator = $true },
            @{ Separator = $true; Label = $c.CaptureNote }
        )
        Write-UiMenu -Title $c.CaptureTitle -Subtitle 'VRHM > Config > Capture mode' -Items $items -Footer $c.Back -Bg 'DarkBlue'
        $choice = Read-UiKey
        if ($choice -in @('0', 'ESC')) { return }
        $newMode = switch ($choice) {
            '1' { 'StreamOnly' }
            '2' { 'StreamAndLocalWindow' }
            '3' { 'LocalWindow' }
            default { $null }
        }
        if ($newMode) {
            # Warn before switching to LocalWindow - no stream/web/restream
            if ($newMode -eq 'LocalWindow' -and $global:CaptureMode -ne 'LocalWindow') {
                Write-Host ""
                Write-UiMessage -Text $c.CaptureLocalWarn -Kind warn
                $ack = ([string](Read-Host ('  ' + $c.CaptureConfirm))).Trim().ToUpper()
                if ($ack -notin @('Y', 'O')) {
                    Write-Host ('  ' + $c.Cancelled) -ForegroundColor DarkGray
                    Start-Sleep -Seconds 1
                    continue
                }
            }
            if (Set-CaptureMode -Mode $newMode) {
                Write-UiMessage -Text ($c.CaptureSet -f (Get-CaptureModeLabel -Mode $newMode)) -Kind ok
                Wait-UiKey
            }
        }
    } while ($true)
}


# Adds or updates one entry in the encrypted WiFi store, applying the same
# duplicate guard the web UI enforces:
#   - unknown SSID              -> added
#   - known SSID, same password -> no write at all, informational message
#   - known SSID, new password  -> WARNING + explicit Y/N confirmation
# Returns $true when the store was written, $false otherwise.
function Set-WifiNetworkEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SSID,
        [string]$Password
    )
    $networks = @(Get-WifiNetworks)
    # -eq is case-insensitive in PowerShell (SSID match); -ceq below is not
    # (passwords are case-sensitive).
    $existing = $networks | Where-Object { $_.SSID -eq $SSID }

    if ($existing) {
        if ($existing.Password -ceq $Password) {
            Write-Log ($msg.Wifi.NetworkUnchanged -f $SSID) -Level INFO
            return $false
        }
        Write-Log ($msg.Wifi.NetworkDuplicate -f $SSID) -Level WARNING
        $confirm = (Read-Host $msg.Wifi.NetworkOverwritePrompt).Trim().ToUpper()
        if ($confirm -ne 'Y' -and $confirm -ne 'O') { return $false }
        $existing.Password = $Password
        Save-WifiNetworks -Networks $networks
        Write-Log ($msg.Wifi.NetworkUpdated -f $SSID) -Level SUCCESS
        return $true
    }

    $isFirst   = ($networks.Count -eq 0)
    $networks += [PSCustomObject]@{ SSID = $SSID; Password = $Password; Preferred = $isFirst }
    Save-WifiNetworks -Networks $networks
    Write-Log ($msg.Wifi.NetworkAdded -f $SSID) -Level SUCCESS
    return $true
}


function Show-SubMenu-WifiNetworks {
    do {
        Clear-Host
        Write-Host $msg.Wifi.NetworksTitle -ForegroundColor Cyan
        Write-Host ""
        $networks = @(Get-WifiNetworks)
        if ($networks.Count -eq 0) {
            Write-Host $msg.Wifi.NetworksEmpty -ForegroundColor Yellow
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
        Write-Host $msg.Wifi.PcCopyOption
        if ($networks.Count -gt 0) {
            Write-Host "  [1-$($networks.Count)]. Edit / Delete a network"
        }
        Write-Host "  0. Back"
        Write-Host ""

        $choice = (Read-Host $msg.EnterChoice).Trim()

        if ($choice.ToUpper() -eq 'A') {
            $ssid = (Read-Host $msg.Wifi.NetworkSsidPrompt).Trim()
            if (-not $ssid) { continue }
            $wifiPassword = (Read-Host $msg.Wifi.NetworkPasswordPrompt).Trim()
            Set-WifiNetworkEntry -SSID $ssid -Password $wifiPassword | Out-Null
            Start-Sleep -Seconds 1
            continue
        }

        # Copy the SSID + password of the WiFi this computer is connected to -
        # console equivalent of the web UI's "Copy Wifi parameters from the host
        # computer" button. Both paths share Get-ComputerWifiInfo.
        if ($choice.ToUpper() -eq 'P') {
            $pcWifi = Get-ComputerWifiInfo
            if (-not $pcWifi -or -not $pcWifi.Ssid) {
                Write-Log $msg.Wifi.PcNotDetected -Level WARNING
                Start-Sleep -Seconds 2
                continue
            }
            Write-Host ""
            Write-Log ($msg.Wifi.PcDetected -f $pcWifi.Ssid) -Level INFO
            $wifiPassword = $pcWifi.Password
            if (-not $wifiPassword) {
                Write-Log ($msg.Wifi.PcPasswordMissing -f $pcWifi.Ssid) -Level WARNING
                $wifiPassword = (Read-Host $msg.Wifi.NetworkPasswordPrompt).Trim()
            }
            $confirm = (Read-Host $msg.Wifi.PcUseConfirm).Trim().ToUpper()
            if ($confirm -ne 'Y' -and $confirm -ne 'O') { continue }
            Set-WifiNetworkEntry -SSID $pcWifi.Ssid -Password $wifiPassword | Out-Null
            Start-Sleep -Seconds 2
            continue
        }

        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $networks.Count) {
                $target = $networks[$idx]
                Write-Host ""
                $prefLabel = if ($target.Preferred) { '[already preferred]' } else { $msg.Wifi.NetworkSetPref }
                Write-Host ("  Selected: {0}" -f $target.SSID)
                Write-Host ("  E. Edit password    P. {0}    D. Delete    0. Cancel" -f $prefLabel)
                $action = (Read-Host $msg.EnterChoice).Trim().ToUpper()
                if ($action -eq 'E') {
                    $wifiPwdInput = (Read-Host $msg.Wifi.NetworkPasswordPrompt).Trim()
                    $target.Password = $wifiPwdInput
                    Save-WifiNetworks -Networks $networks
                    Write-Log ($msg.Wifi.NetworkUpdated -f $target.SSID) -Level SUCCESS
                    Start-Sleep -Seconds 1
                } elseif ($action -eq 'P') {
                    if ($target.Preferred) {
                        Write-Log ($msg.Wifi.NetworkAlreadyPref -f $target.SSID) -Level INFO
                    } else {
                        foreach ($n in $networks) { $n.Preferred = ($n.SSID -eq $target.SSID) }
                        Save-WifiNetworks -Networks $networks
                        Write-Log ($msg.Wifi.NetworkPreferred -f $target.SSID) -Level SUCCESS
                    }
                    Start-Sleep -Seconds 1
                } elseif ($action -eq 'D') {
                    $wasPreferred = $target.Preferred
                    $networks = @($networks | Where-Object { $_.SSID -ne $target.SSID })
                    if ($wasPreferred -and $networks.Count -gt 0) { $networks[0].Preferred = $true }
                    Save-WifiNetworks -Networks $networks
                    Write-Log ($msg.Wifi.NetworkRemoved -f $target.SSID) -Level SUCCESS
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


function Show-SubMenu-FilesAndFolders {
    $c = $msg.Console
    while ($true) {
        $items = @(
            @{ Key = '1'; Label = $c.FilesRec },
            @{ Key = '2'; Label = $c.FilesLogs },
            @{ Key = '3'; Label = $c.FilesApp },
            @{ Key = '4'; Label = $c.FilesConfig },
            @{ Key = '5'; Label = $c.FilesExport },
            @{ Key = '6'; Label = $c.FilesLogPick }
        )
        Write-UiMenu -Title $c.FilesTitle -Subtitle 'VRHM > Files & logs' -Items $items -Footer $c.Back -Bg 'DarkGray'
        $userInput = Read-UiKey
        if ($userInput -in @('0', 'ESC')) { return }
        Invoke-FilesMenuChoice -Choice $userInput
    }
}

function Invoke-FilesMenuChoice {
    # The actions behind the options of Show-SubMenu-FilesAndFolders.
    param([string]$Choice)
    $userInput = $Choice
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
            # The registry is a table now (ADR-0017), so there is no file to
            # open - this used to hand Open-File a path that does not exist.
            # Export it instead, which is the operator's sanctioned way to see
            # and edit the registry as a spreadsheet, and open the result.
            Write-Log -Message $msg.OpenKnownHeadsets -Level "INFO"
            $exportPath = Join-Path $global:ScriptPath ("data\known_headsets_export_{0}.csv" -f (Get-Date -Format 'yyyy.MM.dd-HH.mm'))
            try {
                Export-HeadsetsCsv -Path $exportPath | Out-Null
                Write-Host ((Get-MessageString -Key 'Headset.ExportedTo') -f $exportPath) -ForegroundColor Green
                Open-File -filePath $exportPath
            }
            catch {
                Write-Log ("Headset export failed: " + $_.Exception.Message) -Level ERROR
            }
            Wait-UiKey
        }
        '6' {
            Show-SubMenu-LogFiles
        }
        # Any other key: single-key menu, nothing to do (the menu is simply drawn again).
        default { }
    }
}


function Show-SubMenu-LogFiles {
    <#
    .SYNOPSIS
    Console log picker: choose a log type, then a file, and open it.

    .DESCRIPTION
    The CLI counterpart of the log-type / log-file dropdowns on help.html - both are
    driven by the same Get-LogSources enumeration, so they always offer the same list.
    The folder holds well over a hundred files, which is why the type comes first.
    #>
    $sources = @(Get-LogSources)
    if ($sources.Count -eq 0) {
        Write-Host ((Get-MessageString -Key 'Logs.NoFiles') -f $global:logFolder) -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    # Types in Get-LogSources order (families first, newest file first inside each).
    $types = @()
    foreach ($source in $sources) {
        if ($types.Id -notcontains $source.Type) {
            $types += [PSCustomObject]@{ Id = $source.Type; Label = $source.TypeLabel }
        }
    }

    Write-Host ''
    Write-Host (Get-MessageString -Key 'Logs.SelectType') -ForegroundColor Cyan
    for ($i = 0; $i -lt $types.Count; $i++) {
        $count = @($sources | Where-Object { $_.Type -eq $types[$i].Id }).Count
        Write-Host ("`t {0}. {1} ({2})" -f ($i + 1), $types[$i].Label, $count)
    }
    Write-Host (Get-MessageString -Key 'Logs.Cancel')
    $typeChoice = Read-Host $msg.YourChoice
    if ($typeChoice -eq '0' -or -not ($typeChoice -match '^\d+$')) { return }
    $typeIndex = [int]$typeChoice - 1
    if ($typeIndex -lt 0 -or $typeIndex -ge $types.Count) { return }

    $files = @($sources | Where-Object { $_.Type -eq $types[$typeIndex].Id })

    Write-Host ''
    Write-Host (Get-MessageString -Key 'Logs.SelectFile') -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) {
        $sizeMb = [Math]::Round($files[$i].SizeBytes / 1MB, 1)
        Write-Host ("`t {0}. {1,-34} {2,8} MB   {3}" -f ($i + 1), $files[$i].Label, $sizeMb, $files[$i].LastWrite)
    }
    Write-Host (Get-MessageString -Key 'Logs.Cancel')
    $fileChoice = Read-Host $msg.YourChoice
    if ($fileChoice -eq '0' -or -not ($fileChoice -match '^\d+$')) { return }
    $fileIndex = [int]$fileChoice - 1
    if ($fileIndex -lt 0 -or $fileIndex -ge $files.Count) { return }

    $selected = $files[$fileIndex]
    Write-Log ((Get-MessageString -Key 'Logs.Opening') -f $selected.Id) -Level INFO
    Open-File -filePath (Join-Path $global:logFolder $selected.Id)
}

function Open-Folder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )
    
    # Normalize path and ensure it's treated as a directory
    $normalizedPath = (Resolve-Path -LiteralPath $FolderPath -ErrorAction SilentlyContinue).Path
    
    if ($normalizedPath -and (Test-Path -LiteralPath $normalizedPath -PathType Container)) {
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

    if (Test-Path -LiteralPath $filePath) {
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
        Write-UiTitle -Title $msg.Console.QualityTitle -Subtitle 'VRHM > Quality' -Bg 'DarkGray'
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
        Write-Host ""
        Write-Host ('   ' + $msg.Console.Back) -ForegroundColor DarkGray
        $choice = Read-UiKey
        if ($choice -eq 'ESC') { $choice = '0' }

        switch ($choice) {
            '1' { Set-VqaAutoApply -Section 'profiles' -Enabled (-not $global:VQA_AutoApplyProfiles) | Out-Null; Start-Sleep -Milliseconds 500 }
            '2' { Set-VqaAutoApply -Section 'headsets' -Enabled (-not $global:VQA_AutoApplyHeadsets) | Out-Null; Start-Sleep -Milliseconds 500 }
            '3' { Set-VqaAutoApply -Section 'mediamtx' -Enabled (-not $global:VQA_AutoApplyMediaMtx) | Out-Null; Start-Sleep -Milliseconds 500 }
            '4' { Invoke-VqaApply -Scope 'all' | Out-Null; Read-Host "Press Enter" }
            '5' { Restore-VqaOriginals | Out-Null; Read-Host "Press Enter" }
            '6' {
                $rec = Get-LatestVqaRecommendation
                if ($rec) {
                    ($rec | ConvertTo-Json -Depth 6) | Write-Host
                } else {
                    Write-Host "No recommendation yet."
                }
                Read-Host "Press Enter"
            }
        }
    } while ($choice -ne '0')
}


function Show-SubMenu-KioskScreens {
    do {
        Clear-Host
        Start-Sleep -Milliseconds 200
        Write-Host $msg.Kiosk.ScreensTitle -BackgroundColor DarkMagenta -ForegroundColor White
        Write-Host ""

        $kiosks = @(Get-KnownKiosks)
        if ($kiosks.Count -eq 0) {
            Write-Log $msg.NoKiosksFound -Level INFO
            Write-Host $msg.NoKiosksFound -ForegroundColor Yellow
        } else {
            $i = 1
            foreach ($k in $kiosks) {
                $reach = Get-KioskReachability -IP $k.IPAddress -Port $k.Port
                if ($reach -and $reach.Reachable -and $reach.CdpOpen) {
                    $statusColor = 'Green'
                    $statusLabel = $msg.Kiosk.StatusOK
                } elseif ($reach -and $reach.Reachable) {
                    $statusColor = 'Yellow'
                    $statusLabel = $msg.Kiosk.StatusCdpClosed
                } else {
                    $statusColor = 'Red'
                    $statusLabel = $msg.Kiosk.StatusUnreachable
                }

                # Advanced kiosks (Start-KioskAgent.*) report their computer name
                # and link type; a basic kiosk shows nothing extra.
                $agent = Get-KioskAgentInfo -IPAddress $k.IPAddress
                $deviceLabel = ""
                if ($agent) {
                    $deviceLabel = "  $($msg.Kiosk.AgentBadge) $($agent.Hostname)"
                    if ($agent.InterfaceType) { $deviceLabel += " / $($agent.InterfaceType)" }
                    if ($agent.IsStale)       { $deviceLabel += " (stale)" }
                }

                Write-Host ("  {0}. {1,-20} {2,-15} {3,-6} " -f $i, $k.Name, $k.IPAddress, $k.Port) -NoNewline
                Write-Host $statusLabel -ForegroundColor $statusColor -NoNewline
                if ($deviceLabel) {
                    $deviceColor = if ($agent.IsStale) { 'DarkYellow' } else { 'Cyan' }
                    Write-Host $deviceLabel -ForegroundColor $deviceColor -NoNewline
                }
                Write-Host ""
                $i++
            }
        }

        Write-Host ""
        Write-Host $msg.Kiosk.MenuAdd
        Write-Host $msg.Kiosk.MenuScan
        if ($kiosks.Count -gt 0) {
            Write-Host ($msg.Kiosk.MenuSelectRow -f $kiosks.Count)
        }
        Write-Host $msg.Kiosk.MenuBack
        Write-Host ""

        $choice = (Read-Host $msg.EnterChoice).Trim()

        if ($choice.ToUpper() -eq 'A') {
            $ip = (Read-Host $msg.Kiosk.AddIPPrompt).Trim()
            if (-not $ip) {
                Write-Log $msg.Kiosk.AddIPInvalid -Level ERROR
                Write-Host $msg.Kiosk.AddIPInvalid -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }
            $name = (Read-Host $msg.Kiosk.AddNamePrompt).Trim()
            $portInput = (Read-Host $msg.Kiosk.AddPortPrompt).Trim()
            $port = 9222
            if ($portInput) {
                if ($portInput -match '^\d+$') {
                    $port = [int]$portInput
                } else {
                    Write-Host $msg.Kiosk.AddPortInvalid -ForegroundColor Yellow
                }
            }
            Add-Kiosk -IPAddress $ip -Name $name -Port $port
            # $( ) is required here: a bare "(if ...)" parses fine but is treated as a
            # command call at runtime and throws "The term 'if' is not recognized".
            $kioskLabel = if ($name) { $name } else { $ip }
            Write-Log ($msg.Kiosk.AddSuccess -f $kioskLabel) -Level SUCCESS
            Write-KioskLog "console add ip=$ip name=$name port=$port result=success" -Level SUCCESS
            Start-Sleep -Seconds 1
            continue
        }

        if ($choice.ToUpper() -eq 'S') {
            Show-SubMenu-KioskScan
            continue
        }

        if ($choice -match '^\d+$') {
            $idx = [int]$choice - 1
            if ($idx -ge 0 -and $idx -lt $kiosks.Count) {
                $target = $kiosks[$idx]
                Write-Host ""
                Write-Host ("  {0}: {1} [{2}:{3}]" -f $msg.Kiosk.Selected, $target.Name, $target.IPAddress, $target.Port)
                Write-Host $msg.Kiosk.ActionPush
                Write-Host $msg.Kiosk.ActionEdit
                Write-Host $msg.Kiosk.ActionInfo
                Write-Host $msg.Kiosk.ActionReboot
                Write-Host $msg.Kiosk.ActionShutdown
                Write-Host $msg.Kiosk.ActionDelete
                Write-Host $msg.Kiosk.ActionCancel
                $action = (Read-Host $msg.EnterChoice).Trim().ToUpper()

                if ($action -eq 'P') {
                    $url = (Read-Host $msg.Kiosk.PushUrlPrompt).Trim()
                    if ($url.ToUpper() -eq 'W') {
                        # Custom wall: ordered headset IDs -> ?filterid= (same as the web checklist)
                        Write-Host ""
                        foreach ($h in @(Get-KnownHeadsets)) { Write-Host ("  {0,3}  {1}" -f $h.ID, $h.Name) }
                        $idsRaw = (Read-Host $msg.Kiosk.PushWallIdsPrompt).Trim()
                        $wallIds = @($idsRaw -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                        $url = Get-KioskWallUrl -HeadsetId $wallIds
                    }
                    if (-not $url) {
                        Write-Host $msg.Kiosk.PushCancelled -ForegroundColor DarkGray
                        Start-Sleep -Seconds 1
                        continue
                    }
                    $finalUrl = $url
                    $replacement = Resolve-LocalhostReplacement -Url $url
                    if ($replacement -and $replacement.NeedsReplacement) {
                        Write-Host ""
                        Write-Host ($msg.Kiosk.LocalhostWarning -f $replacement.SuggestedUrl) -ForegroundColor Yellow
                        $confirm = (Read-Host $msg.Kiosk.LocalhostConfirm).Trim().ToUpper()
                        if ($confirm -eq 'Y' -or $confirm -eq 'O') {
                            $finalUrl = $replacement.SuggestedUrl
                        } else {
                            Write-Host $msg.Kiosk.PushCancelled -ForegroundColor DarkGray
                            Start-Sleep -Seconds 1
                            continue
                        }
                    }
                    $navResult = Invoke-CdpNavigate -IP $target.IPAddress -Port $target.Port -Url $finalUrl
                    if ($navResult -and $navResult.Success) {
                        Update-KioskField -ID ([int]$target.ID) -Field 'PushedURL' -NewValue $finalUrl
                        Update-KioskField -ID ([int]$target.ID) -Field 'LastPushedAt' -NewValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        Write-Log ($msg.Kiosk.PushSuccess -f $target.Name) -Level SUCCESS
                        Write-KioskLog "console push id=$($target.ID) name=$($target.Name) ip=$($target.IPAddress) result=success url=$finalUrl" -Level SUCCESS
                        Write-Host ($msg.Kiosk.PushSuccess -f $target.Name) -ForegroundColor Green
                    } else {
                        $errText = if ($navResult) { $navResult.Error } else { '' }
                        Write-Log ($msg.Kiosk.PushFailed -f $target.Name, $errText) -Level ERROR
                        Write-KioskLog "console push id=$($target.ID) name=$($target.Name) ip=$($target.IPAddress) result=failed error=$errText" -Level ERROR
                        Write-Host ($msg.Kiosk.PushFailed -f $target.Name, $errText) -ForegroundColor Red
                    }
                    Start-Sleep -Seconds 2
                }
                elseif ($action -eq 'E') {
                    Write-Host ""
                    Write-Host $msg.Kiosk.EditFieldName
                    Write-Host $msg.Kiosk.EditFieldIP
                    Write-Host $msg.Kiosk.EditFieldPort
                    $fieldNum = Read-Host $msg.Kiosk.EditFieldPrompt
                    $field = switch ($fieldNum) {
                        '1' { 'Name' }
                        '2' { 'IPAddress' }
                        '3' { 'Port' }
                        default { $null }
                    }
                    if (-not $field) {
                        Write-Host $msg.Kiosk.InvalidChoice -ForegroundColor Red
                        Start-Sleep -Seconds 1
                        continue
                    }
                    $currentValue = $target.$field
                    $newValue = Read-Host ($msg.Kiosk.EditNewValuePrompt -f $field, $currentValue)
                    if ($newValue) {
                        Update-KioskField -ID ([int]$target.ID) -Field $field -NewValue $newValue
                        Write-Log ($msg.Kiosk.EditSuccess -f $target.Name) -Level SUCCESS
                        Write-KioskLog "console update id=$($target.ID) name=$($target.Name) ip=$($target.IPAddress) field=$field result=success" -Level SUCCESS
                    }
                    Start-Sleep -Seconds 1
                }
                elseif ($action -eq 'I') {
                    Write-Host ""
                    $agentInfo = Get-KioskAgentInfo -IPAddress $target.IPAddress
                    if (-not $agentInfo) {
                        Write-Host ($msg.Kiosk.AgentNone) -ForegroundColor Yellow
                        Write-Host ($msg.Kiosk.AgentNoneHint) -ForegroundColor DarkGray
                    } else {
                        Write-Host ($msg.Kiosk.InfoTitle -f $target.Name) -ForegroundColor Cyan
                        if ($agentInfo.IsStale) {
                            Write-Host ($msg.Kiosk.AgentStale) -ForegroundColor Yellow
                        }
                        $linkText = $agentInfo.InterfaceType
                        if ($agentInfo.InterfaceName)  { $linkText += " ($($agentInfo.InterfaceName))" }
                        if ($agentInfo.LinkSpeedMbps)  { $linkText += " - $($agentInfo.LinkSpeedMbps) Mbps" }

                        Write-Host ($msg.Kiosk.InfoComputer   -f $agentInfo.Hostname)
                        Write-Host ($msg.Kiosk.InfoOS         -f $agentInfo.OS)
                        Write-Host ($msg.Kiosk.InfoLink       -f $linkText)
                        Write-Host ($msg.Kiosk.InfoBrowser    -f $agentInfo.Browser)
                        Write-Host ($msg.Kiosk.InfoAgent      -f $agentInfo.AgentVersion)
                        Write-Host ($msg.Kiosk.InfoUptime     -f (Get-FormattedUptime -Seconds $agentInfo.UptimeSec))
                        Write-Host ($msg.Kiosk.InfoLastReport -f $agentInfo.LastReportAt)
                        Write-Host ($msg.Kiosk.InfoCurrentUrl -f $agentInfo.CurrentUrl)
                    }
                    Write-Host ""
                    [void](Read-Host $msg.PressEnterToContinue)
                }
                elseif ($action -eq 'R' -or $action -eq 'H') {
                    $powerAction  = if ($action -eq 'R') { 'reboot' } else { 'shutdown' }
                    $confirmMsg   = if ($action -eq 'R') { $msg.Kiosk.PowerRebootConfirm } else { $msg.Kiosk.PowerShutdownConfirm }

                    # Only an advanced kiosk has an agent able to receive the order.
                    $agentInfo = Get-KioskAgentInfo -IPAddress $target.IPAddress
                    if (-not $agentInfo) {
                        Write-Host ""
                        Write-Host ($msg.Kiosk.PowerNotAdvanced -f $target.Name) -ForegroundColor Yellow
                        Write-Host ($msg.Kiosk.AgentNoneHint) -ForegroundColor DarkGray
                        Start-Sleep -Seconds 3
                        continue
                    }

                    Write-Host ""
                    $confirm = (Read-Host ($confirmMsg -f $target.Name)).Trim().ToUpper()
                    if ($confirm -ne 'Y' -and $confirm -ne 'O') {
                        Write-Host $msg.Kiosk.PowerCancelled -ForegroundColor DarkGray
                        Start-Sleep -Seconds 1
                        continue
                    }

                    $powerResult = Invoke-KioskPowerAction -IPAddress $target.IPAddress -Port ([int]$target.Port) -Action $powerAction
                    if ($powerResult.Success) {
                        Write-Log ($msg.Kiosk.PowerSent -f $powerAction, $target.Name) -Level SUCCESS
                        Write-KioskLog "console power id=$($target.ID) name=$($target.Name) ip=$($target.IPAddress) action=$powerAction result=success method=$($powerResult.Method) nonce=$($powerResult.Nonce)" -Level SUCCESS
                        Write-Host ($msg.Kiosk.PowerSent -f $powerAction, $target.Name) -ForegroundColor Green
                    } else {
                        Write-Log ($msg.Kiosk.PowerFailed -f $powerAction, $target.Name, $powerResult.Error) -Level ERROR
                        Write-KioskLog "console power id=$($target.ID) name=$($target.Name) ip=$($target.IPAddress) action=$powerAction result=failed method=$($powerResult.Method) error=$($powerResult.Error)" -Level ERROR
                        Write-Host ($msg.Kiosk.PowerFailed -f $powerAction, $target.Name, $powerResult.Error) -ForegroundColor Red
                    }
                    Start-Sleep -Seconds 2
                }
                elseif ($action -eq 'D') {
                    $confirm = (Read-Host ($msg.Kiosk.DeleteConfirm -f $target.Name)).Trim().ToUpper()
                    if ($confirm -eq 'Y' -or $confirm -eq 'O') {
                        Remove-Kiosk -ID ([int]$target.ID)
                        Write-Log ($msg.Kiosk.DeleteSuccess -f $target.Name) -Level SUCCESS
                        Write-KioskLog "console remove id=$($target.ID) name=$($target.Name) ip=$($target.IPAddress) result=success" -Level SUCCESS
                        Write-Host ($msg.Kiosk.DeleteSuccess -f $target.Name) -ForegroundColor Green
                    } else {
                        Write-Host $msg.Kiosk.DeleteCancelled -ForegroundColor DarkGray
                    }
                    Start-Sleep -Seconds 1
                }
            }
        }
    } while ($choice -ne '0')
}


function Show-SubMenu-KioskScan {
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.Kiosk.ScanTitle -ForegroundColor Cyan

    $networks = @(Get-PrivateNetworks)
    if (-not $networks -or $networks.Count -eq 0) {
        Write-Host $msg.Kiosk.ScanNoNetworks -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    $i = 1
    foreach ($net in $networks) {
        Write-Host "$i. $($net.InterfaceAlias) - IP $($net.IPAddress) ($($net.NetworkCIDR))"
        $i++
    }

    do {
        $selection = Read-Host ($msg.Kiosk.ScanSelectInterface -f $networks.Count)
    } while (-not ($selection -match '^\d+$') -or [int]$selection -lt 1 -or [int]$selection -gt $networks.Count)

    $selectedNetwork = $networks[[int]$selection - 1].NetworkCIDR

    Write-Host ""
    Write-Host ($msg.Kiosk.ScanScanning -f $selectedNetwork) -ForegroundColor Yellow
    $found = @(Invoke-KioskScan -CIDR $selectedNetwork)

    if (-not $found -or $found.Count -eq 0) {
        Write-Host $msg.Kiosk.ScanNoneFound -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    Write-Host $msg.Kiosk.ScanResultsHeader -ForegroundColor Cyan
    $i = 1
    foreach ($dev in $found) {
        if ($dev.AlreadyKnown) {
            Write-Host ("  {0}. {1}  [{2}]  {3}" -f $i, $dev.IPAddress, $dev.Browser, $msg.Kiosk.ScanAlreadyAdded) -ForegroundColor DarkGray
        } else {
            Write-Host ("  {0}. {1}  [{2}]" -f $i, $dev.IPAddress, $dev.Browser)
        }
        $i++
    }

    Write-Host ""
    $selections = Read-Host $msg.Kiosk.ScanSelectPrompt
    $indices = $selections -split ',' | ForEach-Object { ($_ -replace '\s','') } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }

    $selectedDevices = @()
    foreach ($index in $indices) {
        if ($index -ge 0 -and $index -lt $found.Count) {
            $selectedDevices += $found[$index]
        }
    }

    if ($selectedDevices.Count -eq 0) {
        Write-Host $msg.Kiosk.ScanNoneSelected -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    Write-Host ""
    foreach ($dev in $selectedDevices) {
        Write-Host "- $($dev.IPAddress)"
    }
    $confirm = (Read-Host $msg.Kiosk.ScanConfirm).Trim().ToUpper()
    if ($confirm -ne 'Y' -and $confirm -ne 'O') {
        Write-Host $msg.Kiosk.ScanCancelled -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }

    foreach ($dev in $selectedDevices) {
        $name = (Read-Host ($msg.Kiosk.ScanNamePrompt -f $dev.IPAddress)).Trim()
        Add-Kiosk -IPAddress $dev.IPAddress -Name $name
    }
    Write-Log $msg.Kiosk.ScanAddSuccess -Level SUCCESS
    Write-Host $msg.Kiosk.ScanAddSuccess -ForegroundColor Green
    Start-Sleep -Seconds 2
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