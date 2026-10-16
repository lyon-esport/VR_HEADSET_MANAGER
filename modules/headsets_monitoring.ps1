#################
# MANAGE DETAILED INFOS OF KNOWN HEADSETS
#################

$script:ScrcpyPidCache = @{}   # keyed by IP; value: scrcpy PID. Persists for runspace lifetime.




function Stop-VRMonitor {
    param (
            $jobName = "VRMonitor"
        )
    try {
        $job = Get-Job -Name $jobName -ErrorAction Stop
    }
    catch {
        Write-Log ($msg.JobNotFound -f $jobName) -Level INFO
        return $true
    }

    if ($job){
        try {
            Stop-Job -Job $job -ErrorAction Stop
            Remove-Job -Job $job -ErrorAction Stop
        }
        catch {
            Write-Log ($msg.JobCannotBeStopped -f $jobName) -Level ERROR
            return $false
        }

        Write-Log ($msg.JobStopped -f $jobName, $job.ID) -Level INFO
        return $true
    }
}

<#
.SYNOPSIS
    One-line description of a tick failure for the VRMonitor log: the message, the
    command that threw and the statement it was running.
.EXAMPLE
    try { Get-KnownHeadsets } catch { Write-Log (Get-VRMonitorTickErrorText -ErrorRecord $_) -Level ERROR }
#>
function Get-VRMonitorTickErrorText {
    param($ErrorRecord)
    try {
        $text = [string]$ErrorRecord.Exception.Message
        $inv  = $ErrorRecord.InvocationInfo
        if ($inv) {
            $cmd = if ($inv.MyCommand) { [string]$inv.MyCommand.Name } else { '' }
            $line = if ($inv.Line) { ([string]$inv.Line).Trim() } else { '' }
            if ($line.Length -gt 120) { $line = $line.Substring(0, 120) + '...' }
            if ($cmd)  { $text += " [in $cmd]" }
            if ($line) { $text += " at: $line" }
        }
        return $text
    } catch {
        return [string]$ErrorRecord
    }
}

<#
.SYNOPSIS
    Restarts the VRMonitor job when it has died, from the main process.
.DESCRIPTION
    Called about once a second by the main menu while it waits for a key
    (Read-MenuLine -OnIdle). A job event (Register-ObjectEvent StateChanged) or a
    System.Timers.Timer event would be the obvious hook, but neither -Action runs
    while the console host blocks in Read-Host (measured on Windows PowerShell 5.1,
    ConsoleHost: neither the job state change nor ~8 timer ticks ran an action in
    16 s), so the menu polls instead.

    A dead job (Failed / Completed / Stopped, or gone) is logged at ERROR with its
    reason on first sight and restarted with Start-VRMonitor once it has been dead
    for -RestartDelaySec, at most -MaxRestarts times per -WindowMin minutes; past
    that it logs one ERROR and stops trying. Does nothing while the application is
    shutting down (data\shutdown.flag or $global:AppShutdownInProgress).

    The job's host process exits with the job, taking its per-headset runspaces
    with it (measured), so a restart never doubles the runspaces.

    While the job runs, also empties the record collections nobody receives (Output,
    Information, Warning, Verbose, Debug, Progress) and keeps only the last 20 errors,
    so the main process does not grow with them. State is kept in
    $global:VRMonitorSupervision for Get-VRMonitorStatusText.
.EXAMPLE
    Invoke-VRMonitorSupervision
#>
function Invoke-VRMonitorSupervision {
    param(
        [string]$JobName         = 'VRMonitor',
        [int]$RestartDelaySec    = 5,
        [int]$MaxRestarts        = 5,
        [int]$WindowMin          = 10
    )
    try {
        if ($global:IsVRMonitorJob -or $global:AppShutdownInProgress) { return }
        if (-not $global:VRMonitorSupervision) {
            $global:VRMonitorSupervision = @{ RestartCount = 0; RestartTimes = @(); DeadSince = $null; GaveUp = $false; LastRestartAt = $null; LastDrainAt = [datetime]::MinValue }
        }
        $sup = $global:VRMonitorSupervision
        if ($global:ScriptPath -and (Test-Path -LiteralPath (Join-Path $global:ScriptPath 'data\shutdown.flag'))) { return }

        $job = Get-Job -Name $JobName -ErrorAction SilentlyContinue | Select-Object -Last 1
        $now = Get-Date

        if ($job -and $job.State -notin @('Failed', 'Completed', 'Stopped')) {
            $sup.DeadSince = $null
            if (($now - $sup.LastDrainAt).TotalSeconds -ge 30) {
                $sup.LastDrainAt = $now
                foreach ($j in @($job) + @($job.ChildJobs)) {
                    foreach ($stream in 'Output', 'Information', 'Warning', 'Verbose', 'Debug', 'Progress') {
                        try { if ($j.$stream.Count -gt 0) { $j.$stream.Clear() } } catch { }
                    }
                    try { while ($j.Error.Count -gt 20) { $j.Error.RemoveAt(0) } } catch { }
                }
            }
            return
        }

        if ($sup.GaveUp) { return }

        if (-not $sup.DeadSince) {
            $sup.DeadSince = $now
            $state  = if ($job) { [string]$job.State } else { 'missing' }
            $reason = ''
            if ($job) {
                $child = $job.ChildJobs | Select-Object -First 1
                if ($child -and $child.JobStateInfo.Reason) { $reason = [string]$child.JobStateInfo.Reason.Message }
                if (-not $reason -and $job.JobStateInfo.Reason) { $reason = [string]$job.JobStateInfo.Reason.Message }
                if (-not $reason -and $child) {
                    $lastErr = $child.Error | Select-Object -Last 1
                    if ($lastErr) { $reason = [string]$lastErr }
                }
            }
            if (-not $reason) { $reason = 'no error recorded' }
            Write-Log ("VRMonitor job is not running (state {0}): {1}. Restarting it in {2} s." -f $state, $reason, $RestartDelaySec) -Level ERROR
            return
        }
        if (($now - $sup.DeadSince).TotalSeconds -lt $RestartDelaySec) { return }

        $recent = @($sup.RestartTimes | Where-Object { ($now - $_).TotalMinutes -lt $WindowMin })
        if ($recent.Count -ge $MaxRestarts) {
            $sup.GaveUp = $true
            Write-Log ("VRMonitor job restarted {0} times in {1} minutes - automatic restart stopped. Restart the application." -f $recent.Count, $WindowMin) -Level ERROR
            return
        }

        if ($job) { try { Remove-Job -Job $job -Force -ErrorAction Stop } catch { } }
        $null = Start-VRMonitor -VRMonitor_refresh_timer $global:VRMonitor_refresh_timer -jobName $JobName
        $sup.RestartTimes  = @($recent) + $now
        $sup.RestartCount++
        $sup.LastRestartAt = $now
        $sup.DeadSince     = $null
        Write-Log ("VRMonitor job restarted (restart #{0})." -f $sup.RestartCount) -Level WARNING
    } catch {
        try { Write-Log ("VRMonitor supervision failed: " + $_.Exception.Message) -Level ERROR } catch { }
    }
}

<#
.SYNOPSIS
    The VRMonitor line of the main menu header: @{ Text; Color }.
.DESCRIPTION
    Running, running after N automatic restarts, waiting for a restart, or given up
    (see Invoke-VRMonitorSupervision). Strings come from $msg.Headset.Monitor*.
.EXAMPLE
    $s = Get-VRMonitorStatusText; Write-Host $s.Text -ForegroundColor $s.Color
#>
function Get-VRMonitorStatusText {
    param([string]$JobName = 'VRMonitor')
    $sup = $global:VRMonitorSupervision
    $job = Get-Job -Name $JobName -ErrorAction SilentlyContinue | Select-Object -Last 1
    $alive = $job -and $job.State -notin @('Failed', 'Completed', 'Stopped')
    if (-not $alive) {
        if ($sup -and $sup.GaveUp) { return @{ Text = $msg.Headset.MonitorGaveUp; Color = 'Red' } }
        return @{ Text = $msg.Headset.MonitorDown; Color = 'Red' }
    }
    if ($sup -and $sup.RestartCount -gt 0) {
        return @{ Text = ($msg.Headset.MonitorRestarted -f $sup.RestartCount, $sup.LastRestartAt.ToString('HH:mm:ss')); Color = 'Yellow' }
    }
    return @{ Text = $msg.Headset.MonitorRunning; Color = 'DarkGreen' }
}

<#
.SYNOPSIS
    Runs one stream restart request (Request-StreamRestart) INSIDE VRMonitor, the process that
    owns the pipelines (ADR-0027, ADR-0032). Called by the Start-VRMonitor fast path on a new id.
.DESCRIPTION
    Order: reload config, stop the targeted captures that run, then mediamtx (restart or stop),
    then restart. A headset with auto-restart ON is NOT started here: its id is returned in
    EdgeIds (or All = $true) and the caller drops it from the watchdog edge memory, so the edge
    trigger on the same tick starts it once its ADB is up. A headset with auto-restart OFF is
    started here when it was running (or the request says -Start), since nothing else would.
    Missing request fields (older writer) mean: every capture, no mediamtx, no start.
    Returns @{All;EdgeIds;Stopped;Started;MediaMtx}. Never throws.
.EXAMPLE
    $r = Invoke-StreamRestartRequest -Request (Get-StreamRestartRequest) -KnownHeadsets @(Get-KnownHeadsets)
#>
function Invoke-StreamRestartRequest {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [object[]]$KnownHeadsets = @()
    )
    $res = @{ All = $false; EdgeIds = @(); Stopped = @(); Started = @(); MediaMtx = '' }
    try {
        $scope    = $Request.headsets
        $all      = ($null -eq $scope) -or (($scope -is [string]) -and $scope -eq 'all')
        $wantMtx  = ConvertTo-BoolField $Request.mediamtx
        $stopMtx  = ConvertTo-BoolField $Request.mediamtxStop
        $forceRun = ConvertTo-BoolField $Request.start
        $res.All  = $all

        $targets = @($KnownHeadsets | Where-Object { $_ -and -not (Test-UnknownIp $_.IPAddress) })
        if (-not $all) {
            $ids = @(@($scope) | ForEach-Object { [int]$_ })
            $targets = @($targets | Where-Object { $ids -contains [int]$_.ID })
        }

        Write-Log ("VRMonitor: stream restart requested ({0}) - captures: {1}, mediamtx: {2}" -f `
            $Request.reason, $(if ($all) { 'all' } else { (@($targets | ForEach-Object { $_.Name }) -join ', ') }), `
            $(if ($stopMtx) { 'stop' } elseif ($wantMtx) { 'restart' } else { 'no' })) -Level INFO
        try { Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null } catch { Write-Log ("VRMonitor: config reload failed: " + $_.Exception.Message) -Level WARNING }

        # Which targets run now (decides who is started again when auto-restart is off).
        $wasRunning = @{}
        foreach ($h in $targets) {
            $p = $null
            try { $p = Get-ScrcpyProcess -displayName (Convert-Displayname $h.Name) -headsetIP $h.IPAddress -headsetSerial $h.SerialNumber } catch { }
            $wasRunning[[string]$h.ID] = [bool]$p
        }

        if ($all) {
            # No argument: also ends an owned scrcpy no registry row matches, and tears down every pipeline.
            try { Stop-Scrcpy | Out-Null } catch { Write-Log ("VRMonitor: stopping streams for the restart failed: " + $_.Exception.Message) -Level WARNING }
            $res.Stopped = @($targets | Where-Object { $wasRunning[[string]$_.ID] } | ForEach-Object { $_.Name })
        } else {
            foreach ($h in $targets) {
                if (-not $wasRunning[[string]$h.ID]) { continue }
                try { Stop-Scrcpy -HeadsetName $h.Name -HeadsetIP $h.IPAddress | Out-Null; $res.Stopped += $h.Name }
                catch { Write-Log ("VRMonitor: stopping {0} for the restart failed: {1}" -f $h.Name, $_.Exception.Message) -Level WARNING }
            }
        }

        # mediamtx after the captures: a push started before the bounce would lose its RTSP session.
        if ($stopMtx) {
            try { Stop-MediaMtx; $res.MediaMtx = 'stopped' } catch { Write-Log ("VRMonitor: mediamtx stop failed: " + $_.Exception.Message) -Level WARNING }
        } elseif ($wantMtx) {
            try {
                Stop-MediaMtx
                Start-Sleep -Seconds 1
                Start-MediaMtx
                # Let mediamtx accept RTSP before the first push connects.
                Start-Sleep -Milliseconds 800
                $res.MediaMtx = 'restarted'
            } catch { Write-Log ("VRMonitor: mediamtx restart failed: " + $_.Exception.Message) -Level WARNING }
        }

        foreach ($h in $targets) {
            if (ConvertTo-BoolField $h.scrcpy_AutoRestart) { $res.EdgeIds += [int]$h.ID; continue }
            if (-not ($wasRunning[[string]$h.ID] -or $forceRun)) { continue }
            try {
                $prof = if ($h.ScrcpyProfile) { $h.ScrcpyProfile } else { 'R-N-45-20' }
                start-screenCopy -displayName $h.Name -headsetIP $h.IPAddress -recording (ConvertTo-BoolField $h.Record) -scrcpyProfile $prof
                $res.Started += $h.Name
            } catch {
                Write-Log ("VRMonitor: restarting {0} failed: {1}" -f $h.Name, $_.Exception.Message) -Level WARNING
            }
        }
    } catch {
        Write-Log ("VRMonitor: stream restart request failed: " + $_.Exception.Message) -Level WARNING
    }
    return $res
}

# --- TESTS  ---
<#
    Start-VRMonitor
    $job = Get-Job -Name "VRMonitor"
    Receive-Job -Job $job

    Stop-Job -Job $job
    Remove-Job -Job $job
#>
# --- /TESTS  ---

function Start-HeadsetRunspace {
    <#
    .SYNOPSIS
    Creates and starts a persistent per-headset polling runspace.
    $sharedState is injected via InitialSessionState so the runspace shares the same
    synchronized hashtable object reference - no serialization needed.
    Returns @{PS; Runspace; Handle}.
    #>
    param(
        [PSCustomObject]$headset,
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
        'sharedState', $sharedState, ''))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($pollBlock).AddArgument($headset).AddArgument($scriptPath).AddArgument($configFilePath) | Out-Null
    $handle = $ps.BeginInvoke()
    return @{ PS = $ps; Runspace = $rs; Handle = $handle }
}

function Start-ComputerMonitorRunspace {
    <#
    .SYNOPSIS
    Starts the computer monitoring runspace if absent, or respawns it if it died (S3-2).
    .DESCRIPTION
    The CPU/RAM/GPU/workload/recording-drive snapshot (Update-ComputerMonitoring) used to
    run on the VRMonitor thread and froze the 500 ms fast path for 6-19 s per run. It now
    runs in this runspace, which mirrors Start-HeadsetRunspace: $sharedState is injected
    via InitialSessionState (shared reference), and the poll block opens its own database
    connection (Worker role, ADR-0017). It publishes to the same app_kv row as before.
    Idempotent: called once at VRMonitor start and on every slow tick.
    Shared state keys: _benchmark_active (read; written by the fast path, ADR-0026),
    _recording_drive_low (written; drained by the slow tick), _stop_computer_monitor
    (stop flag; _stop_all also stops it).
    .EXAMPLE
    Start-ComputerMonitorRunspace -registry ([ref]$computerMonitorRunspace) -sharedState $sharedState `
        -scriptPath $global:ScriptPath -configFilePath $global:ConfigFilePath -pollBlock $computerMonitorPollBlock
    #>
    param(
        [ref]$registry,
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )
    $entry = $registry.Value
    if ($entry -and -not $entry.Handle.IsCompleted) { return }
    if ($entry) {
        $why = ''
        try {
            if ($entry.PS.InvocationStateInfo.Reason) { $why = $entry.PS.InvocationStateInfo.Reason.Message }
            elseif ($entry.PS.Streams.Error.Count -gt 0) { $why = [string]$entry.PS.Streams.Error[-1] }
        } catch { }
        Write-Log ("VRMonitor: computer monitoring runspace died, restarting. " + $why) -Level WARNING
        try { $entry.PS.Dispose() }       catch {}
        try { $entry.Runspace.Dispose() } catch {}
        $registry.Value = $null
    }
    $sharedState.Remove('_stop_computer_monitor')
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
        'sharedState', $sharedState, ''))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($pollBlock).AddArgument($scriptPath).AddArgument($configFilePath) | Out-Null
    $handle = $ps.BeginInvoke()
    $registry.Value = @{ PS = $ps; Runspace = $rs; Handle = $handle }
    Write-Log "VRMonitor: started computer monitoring runspace" -Level INFO
}

function Stop-ComputerMonitorRunspace {
    <#
    .SYNOPSIS
    Signals the computer monitoring runspace to exit, waits up to -TimeoutSec, then disposes
    it (a run still sampling past the timeout is stopped by the dispose). No-op when absent.
    .EXAMPLE
    Stop-ComputerMonitorRunspace -registry ([ref]$computerMonitorRunspace) -sharedState $sharedState
    #>
    param(
        [ref]$registry,
        [hashtable]$sharedState,
        [int]$TimeoutSec = 5
    )
    $entry = $registry.Value
    if (-not $entry) { return }
    $sharedState['_stop_computer_monitor'] = $true
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $entry.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    try { $entry.PS.Dispose() }       catch {}
    try { $entry.Runspace.Dispose() } catch {}
    $registry.Value = $null
}

function Start-KioskRunspace {
    <#
    .SYNOPSIS
    Creates and starts a persistent per-kiosk polling runspace.
    $sharedState is injected via InitialSessionState so the runspace shares the same
    synchronized hashtable object reference - no serialization needed.
    Returns @{PS; Runspace; Handle}.
    #>
    param(
        [string]$IPAddress,
        [int]$Port,
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
        'sharedState', $sharedState, ''))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($pollBlock).AddArgument($IPAddress).AddArgument($Port).AddArgument($scriptPath).AddArgument($configFilePath) | Out-Null
    $handle = $ps.BeginInvoke()
    return @{ PS = $ps; Runspace = $rs; Handle = $handle }
}

function Sync-KioskRunspaces {
    <#
    .SYNOPSIS
    Diffs $runspaceRegistry against Get-KnownKiosks.
    Stops runspaces for removed kiosks (signal + wait up to 5s + dispose).
    Starts runspaces for new kiosks. Uses "_stop_kiosk_$ip" as the stop-signal key
    (distinct from headset runspaces' "_stop_$ip") to avoid any possible IPC collision.
    #>
    param(
        [ref]$runspaceRegistry,
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )

    $knownKiosks = @()
    if (Get-Command Get-KnownKiosks -ErrorAction SilentlyContinue) {
        $knownKiosks = @(Get-KnownKiosks)
    }
    $currentIPs = @($knownKiosks | ForEach-Object { $_.IPAddress })

    foreach ($ip in @($runspaceRegistry.Value.Keys)) {
        if ($ip -notin $currentIPs) {
            $sharedState["_stop_kiosk_$ip"] = $true
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $runspaceRegistry.Value[$ip].Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            try { $runspaceRegistry.Value[$ip].PS.Dispose() }       catch {}
            try { $runspaceRegistry.Value[$ip].Runspace.Dispose() } catch {}
            $runspaceRegistry.Value.Remove($ip)
            $sharedState.Remove("_stop_kiosk_$ip")
            $sharedState.Remove("kiosk_$ip")
            Write-Log ("VRMonitor: stopped kiosk runspace for $ip") -Level INFO
        }
    }

    # Detect dead runspaces (uncaught exception in poll loop) and remove their registry
    # entry so the start-new loop below will respawn them.
    foreach ($ip in @($runspaceRegistry.Value.Keys)) {
        $entry = $runspaceRegistry.Value[$ip]
        if ($entry.Handle.IsCompleted) {
            Write-Log ("VRMonitor: detected dead kiosk runspace for $ip, restarting") -Level WARNING
            try { $entry.PS.Dispose() }       catch {}
            try { $entry.Runspace.Dispose() } catch {}
            $runspaceRegistry.Value.Remove($ip)
        }
    }

    foreach ($kiosk in $knownKiosks) {
        if (-not $runspaceRegistry.Value.ContainsKey($kiosk.IPAddress)) {
            $kioskPort = if ($kiosk.Port) { [int]$kiosk.Port } else { 9222 }
            $runspaceRegistry.Value[$kiosk.IPAddress] = Start-KioskRunspace `
                -IPAddress $kiosk.IPAddress -Port $kioskPort -sharedState $sharedState `
                -scriptPath $scriptPath -configFilePath $configFilePath -pollBlock $pollBlock
            Write-Log ("VRMonitor: started kiosk runspace for " + $kiosk.Name + " (" + $kiosk.IPAddress + ")") -Level INFO
        }
    }
}

function Sync-HeadsetRunspaces {
    <#
    .SYNOPSIS
    Diffs $runspaceRegistry against $knownHeadsets.
    Stops runspaces for removed headsets (signal + wait up to 5s + dispose).
    Starts runspaces for new headsets.
    #>
    param(
        [object[]]$knownHeadsets,
        [ref]$runspaceRegistry,
        [hashtable]$sharedState,
        [string]$scriptPath,
        [string]$configFilePath,
        [scriptblock]$pollBlock
    )
    # A row whose address is unknown (released to a 127.0.0.x placeholder by
    # Set-HeadsetIdentity, or never filled in) has nothing to poll. Filtering it out here
    # means no runspace is spawned for it at all - no ping, no port test, no ADB.
    $knownHeadsets = @($knownHeadsets | Where-Object { -not (Test-UnknownIp $_.IPAddress) })
    $currentIPs = @($knownHeadsets | ForEach-Object { $_.IPAddress })

    # Which headset owns each address right now. The registry is keyed by IP, but a poll
    # runspace captures its $headset ONCE at startup and never refreshes it - so when an
    # address changes owner (Set-HeadsetIdentity healing a DHCP swap) the existing runspace
    # keeps stamping the PREVIOUS headset's ID/Name into $sharedState[$ip]. That produced
    # two info rows for the old headset and none for the new one, and the web UI - which
    # joins status by display name - showed the healed headset as offline.
    $ownerById = @{}
    foreach ($h in $knownHeadsets) { $ownerById[[string]$h.IPAddress] = [string]$h.ID }

    foreach ($ip in @($runspaceRegistry.Value.Keys)) {
        $entry = $runspaceRegistry.Value[$ip]
        $gone  = $ip -notin $currentIPs
        # Identity drift: same address, different headset -> the runspace must be respawned
        # so it captures the new owner (its name also drives Update-InstalledAppsCache).
        $drifted = (-not $gone) -and $entry.OwnerID -and ($ownerById[[string]$ip] -ne $entry.OwnerID)

        if ($gone -or $drifted) {
            $sharedState["_stop_$ip"] = $true
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $entry.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            try { $entry.PS.Dispose() }       catch {}
            try { $entry.Runspace.Dispose() } catch {}
            $runspaceRegistry.Value.Remove($ip)
            $sharedState.Remove("_stop_$ip")
            $sharedState.Remove($ip)
            if ($drifted) {
                Write-Log ("VRMonitor: $ip changed owner, restarting its runspace") -Level INFO
            } else {
                Write-Log ("VRMonitor: stopped runspace for $ip") -Level INFO
            }
        }
    }

    # Detect dead runspaces (uncaught exception in poll loop) and remove their registry
    # entry so the start-new loop below will respawn them.
    foreach ($ip in @($runspaceRegistry.Value.Keys)) {
        $entry = $runspaceRegistry.Value[$ip]
        if ($entry.Handle.IsCompleted) {
            Write-Log ("VRMonitor: detected dead runspace for $ip, restarting") -Level WARNING
            try { $entry.PS.Dispose() }       catch {}
            try { $entry.Runspace.Dispose() } catch {}
            $runspaceRegistry.Value.Remove($ip)
        }
    }

    foreach ($headset in $knownHeadsets) {
        if (-not $runspaceRegistry.Value.ContainsKey($headset.IPAddress)) {
            $entry = Start-HeadsetRunspace `
                -headset $headset -sharedState $sharedState `
                -scriptPath $scriptPath -configFilePath $configFilePath -pollBlock $pollBlock
            # Remember which headset this runspace captured, so the drift check above can
            # tell "same address, same headset" from "same address, new owner".
            $entry.OwnerID = [string]$headset.ID
            $runspaceRegistry.Value[$headset.IPAddress] = $entry
            Write-Log ("VRMonitor: started runspace for " + $headset.Name + " (" + $headset.IPAddress + ")") -Level INFO
        }
    }
}

# Starts the VRMonitor background job.
# Architecture: one persistent runspace per headset writes into a shared synchronized
# hashtable ($sharedState). The main job loop reads from that hashtable at 500ms
# intervals and writes the CSV/HTML immediately when data changes.
# Heavy ops (config reload, service watchdogs, VQA) run on a slower cadence
# determined by $VRMonitor_refresh_timer from config.
function Start-VRMonitor {
  param (
        $VRMonitor_refresh_timer = 5 ,
        $jobName = "VRMonitor"
    )
    Stop-VRMonitor $jobName
    $parentPID = $PID
    # main.ps1 holds the config path in its script scope (scripts_init.ps1 is dot-sourced
    # there); a restart by Invoke-VRMonitorSupervision may run from another call stack.
    $vrmConfigFilePath = if ($ConfigFilePath) { $ConfigFilePath } else { $global:ConfigFilePath }
    Start-Job -Name $jobName -ScriptBlock {
        # Nobody receives this job's output, and a job keeps every record it writes in the
        # PARENT process until Receive-Job: Write-Host (which Write-Log uses for the console)
        # goes to the Information stream, so main.ps1 grew without bound (~70k records a
        # day). Measured on PS 5.1: $InformationPreference = 'SilentlyContinue' does NOT
        # stop the retention (500 of 500 records kept); InformationAction Ignore keeps 0.
        # The job has no visible console, so nothing is lost; the log file is unaffected.
        $global:PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'

        $global:ScriptPath              = $using:ScriptPath
        $global:ConfigFilePath          = $using:vrmConfigFilePath
        $global:logFolder               = $using:logFolder
        $global:logFile                 = $using:logFile
        $global:VRMonitor_refresh_timer = $using:VRMonitor_refresh_timer
        $parentPID                      = $using:parentPID
        $jobName                        = $using:jobName

        $global:IsVRMonitorJob = $true
        $shutdownFlagPath = Join-Path $global:ScriptPath "data\shutdown.flag"

        $scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
        if (Test-Path -LiteralPath $scripts_init) {
            . $scripts_init
        } else {
            Write-Host "Error: The module initialization script was not found!" -ForegroundColor Red
            exit
        }

        Write-Host "Starting VRMonitor global:ConfigFilePath = $($global:ConfigFilePath)" -ForegroundColor Magenta

        # Shared state: synchronized hashtable written by headset runspaces, read by main loop.
        # Keys: $ip (headsetInfo PSCustomObject), "_refresh_timer", "_stop_all", "_stop_$ip"
        $sharedState      = [hashtable]::Synchronized(@{})
        $runspaceRegistry = @{}
        $kioskRunspaceRegistry = @{}
        # Single optional runspace (not a per-device registry): @{PS;Runspace;Handle} or $null
        $discoveryRunspace = $null
        $companionRunspace = $null
        $computerMonitorRunspace = $null
        $sharedState["_refresh_timer"] = $global:VRMonitor_refresh_timer

        # Poll scriptblock executed inside each per-headset runspace.
        # $sharedState is injected via InitialSessionState (shared reference, no serialization).
        # Imports 6 required modules, loads config + translations once, then loops indefinitely.
        $headsetPollBlock = {
            param(
                [PSCustomObject]$headset,
                [string]$scriptPath,
                [string]$configFilePath
            )
            # $sharedState available via InitialSessionState injection
            $global:ScriptPath     = $scriptPath
            $global:ConfigFilePath = $configFilePath
            $modPath = Join-Path $scriptPath "modules"
            # database.ps1 is in the list so this runspace can open a connection
            # OF ITS OWN. A connection is never shared between runspaces - the
            # module refuses that explicitly, because a native SQLite handle used
            # from two threads corrupts memory silently.
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","network_scanner.ps1","adb_functions.ps1","database.ps1","usb_manager.ps1","headset_diag.ps1","headsets_monitoring.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath | Out-Null

            # Load translations so $msg.* calls in functions do not throw
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -LiteralPath $transFile }

            # Worker role: open only, never migrate. Get-Config must have run
            # first - it is what sets the database paths.
            if (Get-Command Initialize-Database -ErrorAction SilentlyContinue) {
                try { Initialize-Database -Role Worker | Out-Null } catch { }
            }

            $ip      = $headset.IPAddress
            $stopKey = "_stop_$ip"

            # Pre-load battery history so time-remaining estimates survive a restart.
            #
            # From the battery_history TABLE now, not from a packed cell on the status
            # row (migration 005). The cell was truncated at every startup along with
            # the rest of the status row, so the estimate never actually survived a
            # restart despite the comment here claiming it did. These rows do.
            #
            # Fetched by ID: the address is volatile, so a headset that moved would
            # otherwise inherit the previous occupant's history.
            #
            # The working string stays the compact "ts=pct|ts=pct" form because that is
            # what Get-BatteryTimeEstimate parses; only its storage changed. Three
            # samples is all the estimate needs to compute a slope.
            $localBattHistory = ""
            try {
                $samples = @(Invoke-DbQuery -Name 'battery.recent' -Parameters @{ headset_id = [int]$headset.ID; limit = 3 })
                if ($samples.Count -gt 0) {
                    $localBattHistory = ($samples | ForEach-Object { "{0}={1}" -f $_.ts, $_.pct }) -join '|'
                }
            } catch {}

            # Two-speed poll (ADR-0015). Stage 1 is cheap (ping + TCP probe + local process scan,
            # no adb.exe spawn) and is the only thing the UI reacts to for "is it up / is it
            # streaming", so it runs on its own fixed 1s tick. Stage 2/3 are ADB-bound - seconds
            # per adb.exe round-trip, worse while scrcpy saturates the same transport - so they
            # stay on the refresh_timer cadence and never gate a Stage 1 publish.
            $statusTickSec = 1
            # The record is built ONCE and merged into, never rebuilt per cycle: republishing a
            # half-filled record every tick would flip the main loop's fingerprint on unchanged
            # data and rewrite the CSV plus every HTML overlay continuously (ADR-0002).
            $workingInfo = New-DefaultHeadsetInfo -knownHeadset $headset
            # Installed-apps cache is heavy (dumpsys package list + per-app sizes) and not
            # latency-critical. Refresh on the first stats cycle, then every N stats cycles.
            $appsCacheEvery   = 100
            $appsCacheCounter = 0
            $nextStatsAt      = [datetime]::MinValue   # first tick collects stats immediately
            # Firmware version is read over ADB far less often than battery: it only changes
            # on an OTA, so a 10 minute cadence is plenty and keeps it off the hot cycle.
            $nextFirmwareAt   = [datetime]::MinValue
            $nextIpdAt        = [datetime]::MinValue
            # The serial this runspace learned from the headset itself. $headset was captured
            # at startup, so a row added from an IP alone has no serial in it - without this
            # the USB-first transport could not tell the headset is cabled.
            $learnedSerial    = ''
            # Memo of the resolved ADB device (Get-HeadsetPollDevice, S5-1).
            $pollDeviceCache  = @{}

            # try/finally around the whole loop: the stop flags exit via return,
            # and this runspace owns a database connection that must be released
            # or its file handles keep the data folder locked after shutdown.
            try {
            while ($true) {
                if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }

                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    # The registry row as captured at startup, with the serial this runspace
                    # has learned since filled in when the row never had one.
                    $liveHeadset = $headset
                    if ([string]::IsNullOrWhiteSpace([string]$headset.SerialNumber) -and $learnedSerial) {
                        $liveHeadset = $headset.PSObject.Copy()
                        $liveHeadset.SerialNumber = $learnedSerial
                    }

                    # --- Stage 1: reachability (every tick) ---
                    $s1 = Get-HeadsetInfoStage1Reachability -knownHeadset $liveHeadset
                    foreach ($k in $s1.Keys) { $workingInfo.$k = $s1[$k] }

                    # --- Stage 2/3: identity, battery, foreground app (every refresh_timer) ---
                    $timer = if ($sharedState["_refresh_timer"]) { [int]$sharedState["_refresh_timer"] } else { 5 }
                    if ([datetime]::Now -ge $nextStatsAt) {
                        $nextStatsAt = [datetime]::Now.AddSeconds($timer)

                        if ($workingInfo.ADBWifi) {
                            # USB when the headset is cabled here, WiFi otherwise (and WiFi
                            # again the moment the cable drops - Invoke-AdbCmd retries once).
                            # The resolved device is memoised for 2 x refresh_timer (S5-1): no
                            # "adb devices" per cycle; any failure below drops the memo.
                            $device = Get-HeadsetPollDevice -Headset $liveHeadset -Cache $pollDeviceCache -MaxAgeSec ($timer * 2)
                            if (-not $device) {
                                $workingInfo.ADBWifi      = $false
                                $workingInfo.AdbTransport = "-"
                            } else {
                                $workingInfo.AdbTransport = $device.ConnectionType

                                # --- Stage 2: identity + battery ---
                                $pollData = @{}
                                $s2 = Get-HeadsetInfoStage2Identity -knownHeadset $liveHeadset -Device $device -PollData $pollData
                                foreach ($k in $s2.Keys) { $workingInfo.$k = $s2[$k] }
                                # The combined read failed (transport gone, timeout): resolve again next cycle.
                                if ($pollData.CallFailed) { $pollDeviceCache.Clear() }
                                if ($workingInfo.SerialNumber -and $workingInfo.SerialNumber -ne "-") { $learnedSerial = [string]$workingInfo.SerialNumber }

                                # --- Firmware history (slow cadence, one adb call) ---
                                if ([datetime]::Now -ge $nextFirmwareAt) {
                                    $nextFirmwareAt = [datetime]::Now.AddMinutes(10)
                                    if (Get-Command Update-HeadsetFirmwareHistory -ErrorAction SilentlyContinue) {
                                        try { Update-HeadsetFirmwareHistory -Device $device -HeadsetId ([int]$headset.ID) -Brand $workingInfo.Brand | Out-Null } catch { }
                                    }
                                }

                                # --- Lens position (IPD, ADR-0030): models with an `ipd` block only,
                                # one filtered logcat read, at most every 10 s ---
                                if ([datetime]::Now -ge $nextIpdAt) {
                                    $nextIpdAt = [datetime]::Now.AddSeconds(10)
                                    if (Get-Command Update-HeadsetIpd -ErrorAction SilentlyContinue) {
                                        try { Update-HeadsetIpd -Headset $liveHeadset -Device $device -Model ([string]$workingInfo.Model) | Out-Null } catch { }
                                    }
                                }

                                # Battery history + time estimate (local var persists across cycles)
                                if ($workingInfo.Battery -ne "-") {
                                    $currentLevel = [int]($workingInfo.Battery -replace ' %','')
                                    $allEntries   = @($localBattHistory -split '\|' | Where-Object { $_ -match '=' })
                                    $lastLevel    = if ($allEntries.Count -gt 0) { [int](($allEntries[-1] -split '=')[1]) } else { -1 }
                                    if ($currentLevel -ne $lastLevel) { $allEntries += "$([datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss'))=$currentLevel" }
                                    $localBattHistory           = ($allEntries | Select-Object -Last 3) -join '|'
                                    $workingInfo.BatteryHistory = $localBattHistory
                                    $estimate = Get-BatteryTimeEstimate -HistoryString $localBattHistory
                                    if ($null -ne $estimate.PowerState)       { $workingInfo.PowerState = $estimate.PowerState }
                                    $workingInfo.TimeRemainingMin = if ($null -ne $estimate.MinutesRemaining) { $estimate.MinutesRemaining } else { "-" }
                                }

                                # --- Stage 3: foreground app + installed-apps cache ---
                                $s3 = Get-HeadsetInfoStage3App -knownHeadset $headset -Device $device -PollData $pollData
                                foreach ($k in $s3.Keys) { $workingInfo.$k = $s3[$k] }
                                if ($appsCacheCounter % $appsCacheEvery -eq 0) {
                                    Update-InstalledAppsCache -Device $device -headsetName $headset.Name -HeadsetId ([int]$headset.ID)
                                }
                                $appsCacheCounter++
                            }
                        }
                    }

                    # An unreachable headset must not keep republishing its last known identity.
                    # The main loop treats a serial published alongside ADBWifi=$true as proof of
                    # which device answers at this address; a stale one would queue a bogus
                    # Set-HeadsetIdentity fix that rewrites the whole registry. Clearing here also
                    # reproduces the old build-from-defaults-every-cycle semantics.
                    if (-not $workingInfo.ADBWifi) {
                        $pollDeviceCache.Clear()
                        $workingInfo.Battery                = "-"
                        $workingInfo.Charging               = "-"
                        $workingInfo.ChargingWattage        = "-"
                        $workingInfo.Temp                   = "-"
                        $workingInfo.CpuTemp                = "-"
                        $workingInfo.GpuTemp                = "-"
                        $workingInfo.SkinTemp               = "-"
                        $workingInfo.AdbTransport           = "-"
                        $workingInfo.BatteryControllerLeft  = "-"
                        $workingInfo.BatteryControllerRight = "-"
                        $workingInfo.PowerState             = "-"
                        $workingInfo.TimeRemainingMin       = "-"
                        $workingInfo.Brand                  = ""
                        $workingInfo.Model                  = "-"
                        $workingInfo.SerialNumber           = "-"
                        $workingInfo.RunningApp             = "-"
                        $workingInfo.RunningAppIcon         = ""
                    }

                    # Publish a COPY: the main loop takes this object by reference and re-stamps
                    # ID/Name onto it, so handing out the live object would let it read a record
                    # this runspace is midway through merging.
                    $sharedState[$ip] = $workingInfo.PSObject.Copy()
                } catch {
                    Write-Log ("VRMonitor[" + $ip + "]: poll cycle failed: " + $_.Exception.Message) -Level WARNING
                }

                # Sleep the remainder of the status tick. Stage 1 can burn most of it on an
                # unreachable headset (1s ping timeout) and a stats cycle can overrun it
                # entirely, so subtract the elapsed time instead of always sleeping a full tick.
                $sw.Stop()
                $remainMs = ($statusTickSec * 1000) - [int]$sw.Elapsed.TotalMilliseconds
                if ($remainMs -gt 0) { Start-Sleep -Milliseconds $remainMs }
            }
            } finally {
                if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
                    try { Close-DbConnection } catch { }
                }
            }
        }

        # Poll scriptblock executed inside each per-kiosk runspace. Kept lightweight and
        # separate from $headsetPollBlock: kiosks only need cheap reachability + CDP-open
        # polling, no ADB/battery/app stages.
        $kioskPollBlock = {
            param(
                [string]$ip,
                [int]$port,
                [string]$scriptPath,
                [string]$configFilePath
            )
            # $sharedState available via InitialSessionState injection
            $global:ScriptPath     = $scriptPath
            $global:ConfigFilePath = $configFilePath
            $modPath = Join-Path $scriptPath "modules"
            # database.ps1: this runspace opens a connection of its own (never shared).
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","network_scanner.ps1","database.ps1","kiosk_functions.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath | Out-Null

            # Load translations so $msg.* calls in functions do not throw
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -LiteralPath $transFile }

            if (Get-Command Initialize-Database -ErrorAction SilentlyContinue) {
                try { Initialize-Database -Role Worker | Out-Null } catch { }
            }

            $stopKey = "_stop_kiosk_$ip"

            # try/finally: the stop flags exit via return, and this runspace's
            # database connection must be released or its handles keep the data
            # folder locked after shutdown.
            try {
            while ($true) {
                if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }

                try {
                    $reach = Get-KioskReachability -IP $ip -Port $port
                    $sharedState["kiosk_$ip"] = @{
                        IPAddress   = $ip
                        Port        = $port
                        Reachable   = $reach.Reachable
                        LatencyMs   = $reach.LatencyMs
                        CdpOpen     = $reach.CdpOpen
                        CurrentUrl  = $reach.CurrentUrl
                        LastChecked = (Get-Date)
                    }
                } catch {
                    Write-Log ("VRMonitor[kiosk " + $ip + "]: poll cycle failed: " + $_.Exception.Message) -Level WARNING
                }

                # Sleep refresh_timer seconds with per-second stop-flag checks
                $timer = if ($sharedState["_refresh_timer"]) { [int]$sharedState["_refresh_timer"] } else { 5 }
                for ($s = 0; $s -lt $timer; $s++) {
                    Start-Sleep -Seconds 1
                    if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }
                }
            }
            } finally {
                if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
                    try { Close-DbConnection } catch { }
                }
            }
        }

        # LAN discovery scriptblock. Runs in its own runspace because a full /24 ADB sweep
        # takes seconds and must never stall the 500ms fast loop. It only PUBLISHES what it
        # found - the registry is written by the main thread when it drains the results.
        $discoveryPollBlock = {
            param(
                [string]$scriptPath,
                [string]$configFilePath
            )
            # $sharedState available via InitialSessionState injection
            $global:ScriptPath     = $scriptPath
            $global:ConfigFilePath = $configFilePath
            $modPath = Join-Path $scriptPath "modules"
            # database.ps1: this runspace opens a connection of its own (never shared).
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","network_scanner.ps1","adb_functions.ps1","database.ps1","headsets_discovery.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath | Out-Null

            # Load translations so $msg.* calls in functions do not throw
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -LiteralPath $transFile }

            if (Get-Command Initialize-Database -ErrorAction SilentlyContinue) {
                try { Initialize-Database -Role Worker | Out-Null } catch { }
            }

            # try/finally: the stop flags exit via return, and this runspace's
            # database connection must be released or its handles keep the data
            # folder locked after shutdown.
            try {
            while ($true) {
                # Checked here only: a sweep already under way always runs to completion.
                if ($sharedState["_stop_all"] -or $sharedState["_stop_discovery"]) { return }

                $started = Get-Date
                $sharedState["_discovery_status"] = @{ Running = $true; LastSweepAt = $started; LastDurationSec = 0; Found = 0 }
                $found = @()
                try {
                    $found = @(Invoke-HeadsetNetworkSweep)
                } catch {
                    Write-Log ($msg.Discovery.SweepFailed -f $_.Exception.Message) -Level WARNING
                }
                $duration = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)

                # Append rather than overwrite: the main loop may not have drained the
                # previous batch yet, and losing a hit would delay healing by a full cycle.
                $pendingResults = @()
                if ($sharedState["_discovery_results"]) { $pendingResults = @($sharedState["_discovery_results"]) }
                $sharedState["_discovery_results"] = @($pendingResults + $found)
                $sharedState["_discovery_status"]  = @{ Running = $false; LastSweepAt = $started; LastDurationSec = $duration; Found = $found.Count }
                Write-Log ($msg.Discovery.SweepDone -f $found.Count, $duration) -Level DEBUG

                # Config is re-read every cycle so an interval change from the web config
                # page applies on the next sweep without an application restart.
                try { if (Test-ConfigChanged -ConfigFilePath $configFilePath) { Get-Config -ConfigFilePath $configFilePath | Out-Null } } catch {}
                $interval = if ($global:HeadsetDiscovery_interval_sec) { [int]$global:HeadsetDiscovery_interval_sec } else { 60 }
                if ($interval -lt 10) { $interval = 10 }
                for ($s = 0; $s -lt $interval; $s++) {
                    Start-Sleep -Seconds 1
                    if ($sharedState["_stop_all"] -or $sharedState["_stop_discovery"]) { return }
                }
            }
            } finally {
                if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
                    try { Close-DbConnection } catch { }
                }
            }
        }

        # Companion discovery (UDP 5556 broadcast + up to 1.5 s receive) runs here, never on the
        # VRMonitor thread (S3-1). It only COLLECTS: replies go to _companion_results and the
        # main loop heals IPs through Set-HeadsetIdentity (registry writes stay on main).
        $companionPollBlock = {
            param(
                [string]$scriptPath,
                [string]$configFilePath
            )
            $global:ScriptPath     = $scriptPath
            $global:ConfigFilePath = $configFilePath
            $modPath = Join-Path $scriptPath "modules"
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","network_scanner.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath | Out-Null
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -LiteralPath $transFile }

            while ($true) {
                if ($sharedState["_stop_all"] -or $sharedState["_stop_companion"]) { return }
                try {
                    $found = @(Invoke-CompanionDiscovery -TimeoutMs 1500 -NoHeal)
                    if ($found.Count -gt 0) {
                        $pending = @()
                        if ($sharedState["_companion_results"]) { $pending = @($sharedState["_companion_results"]) }
                        $sharedState["_companion_results"] = @($pending + $found)
                    }
                } catch {
                    Write-Log ("Companion discovery runspace: " + $_.Exception.Message) -Level DEBUG
                }
                try { if (Test-ConfigChanged -ConfigFilePath $configFilePath) { Get-Config -ConfigFilePath $configFilePath | Out-Null } } catch {}
                $interval = [Math]::Max(5, [int]$global:VRMonitor_refresh_timer)
                for ($s = 0; $s -lt $interval; $s++) {
                    Start-Sleep -Seconds 1
                    if ($sharedState["_stop_all"] -or $sharedState["_stop_companion"]) { return }
                }
            }
        }

        # Computer monitoring (S3-2): the CPU/RAM/GPU/workload snapshot runs here, never on
        # the VRMonitor thread. It keeps a sampler (New-ComputerMonitorSampler) for its whole
        # life, so a sample is a few hundred ms with no sleep instead of 6-19 s. Schedule:
        # one sample every Get-AdaptiveMonitorInterval seconds, or within $windowSec of a
        # force-refresh flag (VQA apply, /api/computer-monitoring/force-refresh). Each sample
        # measures the $windowSec since its baseline (Reset-ComputerMonitorBaseline), like the
        # old 5 s CPU average. Paused while a stream benchmark runs (ADR-0026: the fast path
        # mirrors its pause into _benchmark_active). A low recording drive is PUBLISHED, not
        # acted on: the main loop owns registry writes (Disable-RecordingOnLowDisk).
        $computerMonitorPollBlock = {
            param(
                [string]$scriptPath,
                [string]$configFilePath
            )
            # This runspace has no host: Write-Host records (Write-Log console output) would
            # pile up in its PowerShell.Streams.Information for the life of the process.
            $global:PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'
            $global:ScriptPath     = $scriptPath
            $global:ConfigFilePath = $configFilePath
            $modPath = Join-Path $scriptPath "modules"
            # database.ps1: this runspace opens a connection of its own (never shared).
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","database.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath | Out-Null
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -LiteralPath $transFile }
            if (Get-Command Initialize-Database -ErrorAction SilentlyContinue) {
                try { Initialize-Database -Role Worker | Out-Null } catch { }
            }

            $stopNow  = { [bool]($sharedState["_stop_all"] -or $sharedState["_stop_computer_monitor"]) }
            $flagFile = Join-Path $scriptPath "data\computer_monitoring_forcerefresh.flag"
            $windowSec = 5
            try {
                $sampler  = New-ComputerMonitorSampler
                $nextDue  = [DateTime]::UtcNow.AddSeconds($windowSec)
                $haveBase = $true
                $paused   = $false
                $lastErrorLogAt = [DateTime]::MinValue
                while ($true) {
                    if (& $stopNow) { return }
                    $now = [DateTime]::UtcNow
                    # One failed sample (SQLITE_BUSY after retries, a WMI hiccup) must not end the
                    # runspace: a respawn rebuilds the sampler, whose first counter read is the slow one.
                    try {
                        if ($sharedState["_benchmark_active"]) {
                            $paused = $true
                        } else {
                            if ($paused) {
                                # The baseline predates the benchmark: retake it so its load is not averaged in.
                                $paused = $false
                                Reset-ComputerMonitorBaseline -Sampler $sampler
                                $haveBase = $true
                                if ($nextDue -lt $sampler.BaselineAt.AddSeconds($windowSec)) { $nextDue = $sampler.BaselineAt.AddSeconds($windowSec) }
                            }
                            if (Test-Path -LiteralPath $flagFile) {
                                if (-not $haveBase) { Reset-ComputerMonitorBaseline -Sampler $sampler; $haveBase = $true }
                                $forcedAt = $sampler.BaselineAt.AddSeconds($windowSec)
                                if ($forcedAt -lt $nextDue) { $nextDue = $forcedAt }
                            }
                            if (-not $haveBase -and $now -ge $nextDue.AddSeconds(-$windowSec)) {
                                Reset-ComputerMonitorBaseline -Sampler $sampler
                                $haveBase = $true
                            }
                            if ($haveBase -and $now -ge $nextDue) {
                                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                                $snap = Update-ComputerMonitoring -Sampler $sampler -Force -NoRegistryWrite
                                Write-Log ("Computer monitoring sample took {0} ms" -f $sw.ElapsedMilliseconds) -Level DEBUG
                                if ($snap -and $snap.RecordingDrive -and $snap.RecordingDrive.IsLow) {
                                    $sharedState["_recording_drive_low"] = $snap.RecordingDrive
                                }
                                $haveBase = $false
                                $interval = 60
                                try { $interval = [int](Get-AdaptiveMonitorInterval) } catch { }
                                $nextDue = [DateTime]::UtcNow.AddSeconds([Math]::Max($windowSec, $interval))
                            }
                        }
                    } catch {
                        # Rate-limited; the next attempt waits a full window with a fresh baseline.
                        if (($now - $lastErrorLogAt).TotalSeconds -ge 60) {
                            Write-Log ("Computer monitoring sample failed: " + $_.Exception.Message) -Level WARNING
                            $lastErrorLogAt = $now
                        }
                        $haveBase = $false
                        $nextDue  = [DateTime]::UtcNow.AddSeconds($windowSec)
                    }
                    try { if (Test-ConfigChanged -ConfigFilePath $configFilePath) { Get-Config -ConfigFilePath $configFilePath | Out-Null } } catch {}
                    Start-Sleep -Seconds 1
                }
            } finally {
                if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
                    try { Close-DbConnection } catch { }
                }
            }
        }

        # Two-speed loop: 500ms fast tick for CSV/HTML, slow tick (refresh_timer) for heavy ops
        $slowEvery       = [Math]::Max(1, [int]($global:VRMonitor_refresh_timer / 0.5))
        $slowCounter     = $slowEvery  # trigger slow path immediately on first tick
        # VQR tick counter: incremented once per slow-path tick. Used to gate
        # Invoke-VideoQualityRecommendation so it runs every Nth tick based on
        # the current load tier (1=every tick, 2=every 2nd, 5=every 5th).
        $vqrTickCounter  = 0
        $lastFingerprint = ""
        $lastKioskFingerprint = ""
        # Headset ID -> "auto-restart on AND ADB up" as of the previous fast tick. A false->true
        # transition is what starts scrcpy at once instead of on the next slow tick.
        $scrcpyEdgeState = @{}
        # Headset ID -> "ScrcpyProfile|Record" as last seen, so a view or recording change on
        # a running capture is applied at once (see the fast-path trigger below).
        $scrcpyCfgState  = @{}
        # Run id of the stream benchmark this loop has paused for ('' = none). See the
        # benchmark block at the top of the fast path (ADR-0026).
        $benchRunId      = ''
        # Last stream restart request handled (Request-StreamRestart, ADR-0027). Seeded with
        # the one already stored so a request older than this process is never replayed.
        $restartReqId    = ''
        if (Get-Command Get-StreamRestartRequest -ErrorAction SilentlyContinue) {
            $seedReq = Get-StreamRestartRequest
            if ($seedReq) { $restartReqId = [string]$seedReq.id }
        }
        # Last scrcpy "check now" request handled (Request-ScrcpyCheck): seeded the same way, so a
        # request older than this process is never replayed.
        $checkReqId      = ''
        if (Get-Command Get-ScrcpyCheckRequest -ErrorAction SilentlyContinue) {
            $seedCheck = Get-ScrcpyCheckRequest
            if ($seedCheck) { $checkReqId = [string]$seedCheck.id }
        }
        $infoByIp        = @{}
        $knownHeadsets   = @()
        # Registry change counter last seen by the fast path. -1 rather than 0 so
        # the very first tick always reloads, whatever the counter happens to be.
        $lastRegistryVersion = -1

        # Eager first load + immediate runspace start so the first real poll lands within
        # a few seconds of job start instead of waiting one full slow-tick.
        $knownHeadsets = @(Get-KnownHeadsets)
        if ($knownHeadsets.Count -gt 0) {
            Sync-HeadsetRunspaces -knownHeadsets $knownHeadsets -runspaceRegistry ([ref]$runspaceRegistry) `
                -sharedState $sharedState -scriptPath $global:ScriptPath `
                -configFilePath $global:ConfigFilePath -pollBlock $headsetPollBlock
        }
        try {
            Sync-KioskRunspaces -runspaceRegistry ([ref]$kioskRunspaceRegistry) `
                -sharedState $sharedState -scriptPath $global:ScriptPath `
                -configFilePath $global:ConfigFilePath -pollBlock $kioskPollBlock
        } catch { Write-Log ("VRMonitor: eager kiosk sync failed: " + $_.Exception.Message) -Level WARNING }
        # Computer monitoring runs in its own runspace (S3-2); started now so the first snapshot
        # does not wait for a slow tick. The slow tick respawns it if it dies.
        try {
            Start-ComputerMonitorRunspace -registry ([ref]$computerMonitorRunspace) -sharedState $sharedState `
                -scriptPath $global:ScriptPath -configFilePath $global:ConfigFilePath -pollBlock $computerMonitorPollBlock
        } catch { Write-Log ("VRMonitor: computer monitoring runspace start failed: " + $_.Exception.Message) -Level WARNING }

        # Fire service watchdogs eagerly so scrcpy / mediamtx / web server start at the same
        # time as the runspaces, instead of waiting one full slow-tick (~refresh_timer seconds)
        # after the job has finished bootstrapping.
        # ORDER MATTERS: mediamtx MUST be up before Watch-ScrcpyProcesses - the scrcpy
        # pipe pipeline spawns an ffmpeg RTSP publisher a few seconds after scrcpy, and
        # if mediamtx starts (or restarts) after that publish, the session is lost and
        # the ffmpeg pusher goes zombie (stream serves 404 while scrcpy looks healthy).
        try { Start-MediaMtx }         catch { Write-Log ("VRMonitor: mediamtx watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }
        # The eager watchdog gets the live records the poll runspaces have already published, so it
        # does not run a synchronous Get-KnownHeadsetInfos (ping + ADB) per headset. The runspaces
        # have only just started, so wait a bounded time (3 s, 250 ms polls) for the first record of
        # each auto-restart headset with a usable address. A headset still without a record is left
        # out; the fast-path edge trigger starts it as soon as its runspace reports ADB up.
        $eagerWaitRows = @($knownHeadsets | Where-Object {
            (ConvertTo-BoolField $_.scrcpy_AutoRestart) -and -not (Test-UnknownIp $_.IPAddress) })
        $eagerDeadline = (Get-Date).AddSeconds(3)
        $eagerIds      = @()
        $eagerInfoByIp = @{}
        do {
            $eagerIds      = @()
            $eagerInfoByIp = @{}
            foreach ($h in $eagerWaitRows) {
                $rec = $sharedState[[string]$h.IPAddress]
                if ($rec) { $eagerInfoByIp[[string]$h.IPAddress] = $rec; $eagerIds += [int]$h.ID }
            }
            if ($eagerIds.Count -eq $eagerWaitRows.Count) { break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $eagerDeadline)
        if ($eagerIds.Count -gt 0) {
            try { Watch-ScrcpyProcesses -HeadsetId $eagerIds -HeadsetInfo $eagerInfoByIp } catch { Write-Log ("VRMonitor: scrcpy watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }
        }
        try { Start-WebServer }        catch { Write-Log ("VRMonitor: web server watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }

        # NOTE: no GPU encoder pre-warm here. It was tried and removed: the probe has no
        # timeout and took 60 s on a fresh release (Intel QSV), holding this loop - and so
        # the computer-monitoring snapshot, the status export and every watchdog - for that
        # whole minute. Get-GpuEncoder now caches its result for the life of the process
        # (utils.ps1), so only the first capture pays for the probe.

        # Tick guard bookkeeping. The fast and slow paths each run inside a try/catch so one
        # terminating error (SQLITE_BUSY after retries, a module bug) loses one tick instead
        # of ending this job - which used to stop live status, the watchdogs, USB onboarding
        # and stream restarts silently. The shutdown check and the sleep stay OUTSIDE the
        # guards, so the loop always paces itself and always exits on shutdown.
        # Counted per guarded step ("fast tick", "slow tick", and the sub-steps with their own
        # guard): a fault on the slow path alone is separated by clean fast ticks, which must
        # not reset its count.
        $tickFailures       = @{}   # step -> consecutive failed runs
        $tickFailureLogMax  = 20    # logged every run up to this many in a row...
        $lastTickErrorLogAt = @{}   # step -> last time it was logged (then once a minute)

        while ($true) {

            # Cooperative shutdown and parent-process-gone detection
            $shuttingDown = (Test-Path -LiteralPath $shutdownFlagPath) -or
                            (-not (Get-Process -Id $parentPID -ErrorAction SilentlyContinue))
            if ($shuttingDown) {
                if (-not (Test-Path -LiteralPath $shutdownFlagPath)) {
                    Write-Host "VRMonitor: parent process ($parentPID) has exited - signaling reaper"
                    try { New-Item -ItemType File -Path $shutdownFlagPath -Force | Out-Null } catch {}
                    # Main died without Invoke-AppShutdown. The reaper only cleans what exists
                    # when it notices (it polls every 2 s, then exits), so anything this job
                    # started after that - typically mediamtx from the startup watchdog when
                    # main is killed during boot - would be orphaned with its pid file. Stop
                    # our own services here; both helpers are no-ops when nothing runs.
                    try { Stop-Scrcpy }   catch {}
                    try { Stop-MediaMtx } catch {}
                } else {
                    Write-Host "VRMonitor: shutdown flag detected, exiting"
                    # Graceful shutdown: the pipelines (ffmpeg, bridge, recording) live in THIS
                    # job's $global:HeadsetPipelines, so main's own Stop-Scrcpy sees none. Tear
                    # them down here, through their owner, so recordings are finalised (S4-5).
                    # mediamtx is left to Invoke-AppShutdown.
                    try { Stop-Scrcpy | Out-Null } catch { Write-Host ("VRMonitor: Stop-Scrcpy at shutdown failed: " + $_.Exception.Message) }
                }
                $sharedState["_stop_all"] = $true
                $deadline = (Get-Date).AddSeconds(5)
                foreach ($entry in $runspaceRegistry.Values) {
                    while (-not $entry.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 200
                    }
                    try { $entry.PS.Dispose() }       catch {}
                    try { $entry.Runspace.Dispose() } catch {}
                }
                foreach ($entry in $kioskRunspaceRegistry.Values) {
                    while (-not $entry.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 200
                    }
                    try { $entry.PS.Dispose() }       catch {}
                    try { $entry.Runspace.Dispose() } catch {}
                }
                if ($discoveryRunspace) {
                    # Longer grace than the others: a sweep in progress is allowed to finish
                    # rather than be aborted mid-scan (it only checks the flag between sweeps).
                    $discoveryDeadline = (Get-Date).AddSeconds(30)
                    while (-not $discoveryRunspace.Handle.IsCompleted -and (Get-Date) -lt $discoveryDeadline) {
                        Start-Sleep -Milliseconds 500
                    }
                    try { $discoveryRunspace.PS.Dispose() }       catch {}
                    try { $discoveryRunspace.Runspace.Dispose() } catch {}
                }
                if ($companionRunspace) {
                    $companionDeadline = (Get-Date).AddSeconds(5)
                    while (-not $companionRunspace.Handle.IsCompleted -and (Get-Date) -lt $companionDeadline) {
                        Start-Sleep -Milliseconds 200
                    }
                    try { $companionRunspace.PS.Dispose() }       catch {}
                    try { $companionRunspace.Runspace.Dispose() } catch {}
                }
                try { Stop-ComputerMonitorRunspace -registry ([ref]$computerMonitorRunspace) -sharedState $sharedState } catch {}
                # Release the job's own connection last, after every runspace it
                # supervises has released theirs.
                if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
                    try { Close-DbConnection } catch { }
                }
                return
            }

            $tickErrors = @{ 'fast tick' = $null }   # guarded step -> error text, $null = ran cleanly
            try {
                # ---- FAST PATH (every 500ms) ----
                # Pick up registry changes immediately instead of waiting for the slow
                # tick. The registry is reloaded below only when its change counter has
                # actually moved, which is one indexed scalar read (~0.3 ms) on a tick
                # that already does more than that.
                #
                # This is not an optimisation, it is a correctness fix. headset_status
                # has a foreign key to headsets(id), and the fast path writes a row for
                # every headset in the snapshot it holds. Remove a headset through the
                # web UI or the console and, until the next slow tick, this loop was
                # still writing a status row for an id that no longer exists - which
                # SQLite rejects, and because every headset is written in ONE batch
                # transaction, the whole tick was lost for everyone. Observed in
                # production: adding a discovered headset (which removed and recreated
                # a row) froze live status for all five headsets.
                try {
                    $registryVersion = Get-DbTableVersion -Name 'headsets'
                    if ($registryVersion -ne $lastRegistryVersion) {
                        $knownHeadsets       = @(Get-KnownHeadsets)
                        $lastRegistryVersion = $registryVersion
                        $lastFingerprint     = ""
                    }
                } catch { }

                # Build knownHeadsetsInfo from sharedState; use a default placeholder until first poll
                $knownHeadsetsInfo = [System.Collections.ArrayList]@()
                foreach ($h in $knownHeadsets) {
                    $info = $sharedState[$h.IPAddress]
                    if ($info) {
                        # Re-stamp the authoritative identity from the registry row onto the record,
                        # on EVERY tick - not only when the fingerprint moved. The runspace that
                        # produced this record captured its $headset once at startup, so right after
                        # an address changes owner it still carries the PREVIOUS headset's identity.
                        # ID is the exported key (ADR-0016), so a stale one would attach this
                        # headset's live status to another row. Sync-HeadsetRunspaces respawns the
                        # drifted runspace on the next slow tick; this keeps the export correct
                        # until it does.
                        if ($info.ID        -ne $h.ID)        { $info.ID        = $h.ID }
                        if ($info.Name      -ne $h.Name)      { $info.Name      = $h.Name }
                        if ($info.IPAddress -ne $h.IPAddress) { $info.IPAddress = $h.IPAddress }
                        [void]$knownHeadsetsInfo.Add($info)
                    } else {
                        [void]$knownHeadsetsInfo.Add((New-DefaultHeadsetInfo -knownHeadset $h))
                    }
                }

                # ---- FAST PATH: stream benchmark pause (ADR-0026) ----
                # A benchmark (stream_benchmark.ps1, another process) raises an expiring app_kv
                # flag. This process owns the running pipelines, so IT stops them, on the flag's
                # rising edge, then acknowledges so the benchmark can start its own test stream
                # without the watchdog killing it. Watch-ScrcpyProcesses returns at once while the
                # flag is set. On the falling edge the edge memory is wiped so every headset with
                # auto-restart counts as a fresh "ready" edge below and restarts on this very tick.
                $benchState = $null
                if (Get-Command Get-StreamBenchmarkState -ErrorAction SilentlyContinue) { $benchState = Get-StreamBenchmarkState }
                if ($benchState) {
                    if ($benchState.RunId -ne $benchRunId) {
                        Write-Log ("VRMonitor: stream benchmark {0} started - stopping every stream until it ends." -f $benchState.RunId) -Level INFO
                        try { Stop-Scrcpy | Out-Null } catch { Write-Log ("VRMonitor: stopping streams for the benchmark failed: " + $_.Exception.Message) -Level WARNING }
                        Confirm-StreamBenchmarkPause -RunId $benchState.RunId
                        $benchRunId = $benchState.RunId
                    }
                } elseif ($benchRunId) {
                    Write-Log "VRMonitor: stream benchmark over - restarting the normal streams." -Level INFO
                    $benchRunId      = ''
                    $scrcpyEdgeState = @{}
                }
                # The computer monitoring runspace pauses on this (its WMI/counter reads would land
                # inside the benchmark's measures). Mirrored here so it needs no stream_benchmark.ps1.
                $sharedState["_benchmark_active"] = [bool]$benchRunId

                # ---- FAST PATH: stream restart request (ADR-0027, ADR-0032) ----
                # Every planned restart of a capture or of mediamtx is a request from another
                # process (config save, capture mode, VQA, benchmark apply, console Services menu)
                # or from this one (VQO). This process owns the pipelines, so it runs it here:
                # reload config, stop the targeted captures, restart mediamtx when asked, restart
                # the captures (Invoke-StreamRestartRequest). The auto-restart ones are dropped
                # from the edge memory so the watchdog trigger below restarts them on this tick.
                if (-not $benchState -and (Get-Command Get-StreamRestartRequest -ErrorAction SilentlyContinue)) {
                    $restartReq = Get-StreamRestartRequest
                    if ($restartReq -and [string]$restartReq.id -and [string]$restartReq.id -ne $restartReqId) {
                        $restartReqId = [string]$restartReq.id
                        $restartRes = Invoke-StreamRestartRequest -Request $restartReq -KnownHeadsets $knownHeadsets
                        if ($restartRes.All) { $scrcpyEdgeState = @{} }
                        else { foreach ($eid in $restartRes.EdgeIds) { $scrcpyEdgeState.Remove([string]$eid) } }
                    }
                }

                # ---- FAST PATH: scrcpy start trigger (edge only) ----
                # Watch-ScrcpyProcesses otherwise runs only on the slow tick, so a click on the
                # auto-restart button (or ADB coming back on a headset that has it on) waited a
                # full refresh_timer plus the whole slow-path work before scrcpy even launched.
                # The registry change counter above already reloaded $knownHeadsets on this tick
                # if /api/autorestart just wrote, and the runspaces refresh ADBWifi every second.
                # Only a false->true transition fires, so the steady state costs no process scan;
                # crash restarts and transport switches stay on the slow tick.
                $infoByIp = @{}
                foreach ($i in $knownHeadsetsInfo) { if ($i.IPAddress) { $infoByIp[[string]$i.IPAddress] = $i } }
                #
                # Same for a SETTING change on a headset that is already capturing: a new view
                # (ScrcpyProfile, e.g. the view picker on the settings page) or a recording toggle
                # (Record). Those are registry writes too, so they land here on this tick; without
                # this the running session was only compared with its new settings on the next
                # slow tick, after all the slow-path work. Only the IDs whose settings actually
                # changed are passed - Watch-ScrcpyProcesses' existing comparison (options,
                # recording, merged view) still decides whether a restart is needed.
                $scrcpyEdgeIds = @()
                foreach ($h in $knownHeadsets) {
                    $info  = $infoByIp[[string]$h.IPAddress]
                    $ready = (ConvertTo-BoolField $h.scrcpy_AutoRestart) -and -not (Test-UnknownIp $h.IPAddress) `
                             -and $info -and (ConvertTo-BoolField $info.ADBWifi)
                    $edgeKey = [string]$h.ID
                    $cfgSig  = '{0}|{1}' -f $h.ScrcpyProfile, $h.Record
                    $cfgChanged = $scrcpyCfgState.ContainsKey($edgeKey) -and $scrcpyCfgState[$edgeKey] -ne $cfgSig
                    if ($ready -and (-not $scrcpyEdgeState[$edgeKey] -or $cfgChanged)) { $scrcpyEdgeIds += [int]$h.ID }
                    $scrcpyEdgeState[$edgeKey] = [bool]$ready
                    $scrcpyCfgState[$edgeKey]  = $cfgSig
                }

                # An explicit "check these headsets now" (Request-ScrcpyCheck): the kill button, a
                # profile / recording / capture-mode / view / calibration change made by another
                # process. Those leave the registry untouched or change it in a way the edge above
                # cannot see (the capture is simply gone, or its options changed in config.json), so
                # they used to wait for the slow tick. Config is reloaded first: the running session
                # is compared with the NEW view definitions. Watch-ScrcpyProcesses then decides
                # (start / restart / nothing) and clears the "starting" mark when nothing is needed.
                if (-not $benchState -and (Get-Command Get-ScrcpyCheckRequest -ErrorAction SilentlyContinue)) {
                    $checkReq = Get-ScrcpyCheckRequest
                    if ($checkReq -and [string]$checkReq.id -and [string]$checkReq.id -ne $checkReqId) {
                        $checkReqId = [string]$checkReq.id
                        $knownIds = @($knownHeadsets | ForEach-Object { [int]$_.ID })
                        $checkIds = @($checkReq.ids | ForEach-Object { [int]$_ } | Where-Object { $knownIds -contains $_ })
                        if ($checkIds.Count -gt 0) {
                            Write-Log ("VRMonitor: capture check requested ({0}) for headset id(s) {1}" -f $checkReq.reason, ($checkIds -join ',')) -Level DEBUG
                            try { Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null } catch { Write-Log ("VRMonitor: config reload failed: " + $_.Exception.Message) -Level WARNING }
                            $scrcpyEdgeIds = @($scrcpyEdgeIds + $checkIds | Select-Object -Unique)
                        }
                    }
                }
                if ($scrcpyEdgeIds.Count -gt 0) {
                    Write-Log ("VRMonitor: capture requested or settings changed for headset id(s) {0} - checking scrcpy now" -f ($scrcpyEdgeIds -join ',')) -Level DEBUG
                    # mediamtx before scrcpy (publisher ordering - see the eager block above).
                    try { Start-MediaMtx } catch { Write-Log ("VRMonitor: mediamtx watchdog (trigger) failed: " + $_.Exception.Message) -Level WARNING }
                    try { Watch-ScrcpyProcesses -HeadsetId $scrcpyEdgeIds -HeadsetInfo $infoByIp } catch { Write-Log ("VRMonitor: scrcpy start trigger failed: " + $_.Exception.Message) -Level WARNING }
                }

                # Fingerprint of key display fields - triggers CSV/HTML write on any change.
                # Keyed on ID (the exported key). Brand/Model/SerialNumber are NOT exported any
                # more but stay in the fingerprint: they gate the Update-HeadsetField write-back
                # and the Set-HeadsetIdentity queueing in the block below.
                $fp = ($knownHeadsetsInfo | ForEach-Object {
                    "$($_.ID)|$($_.Ping)|$($_.ADBWifi)|$($_.Battery)|$($_.Charging)|$($_.ChargingWattage)|$($_.Temp)|$($_.CpuTemp)|$($_.GpuTemp)|$($_.SkinTemp)|$($_.BatteryControllerLeft)|$($_.BatteryControllerRight)|$($_.PowerState)|$($_.TimeRemainingMin)|$($_.AdbTransport)|$($_.SCRCPY)|$($_.Brand)|$($_.Model)|$($_.SerialNumber)|$($_.RunningApp)"
                }) -join '~'

                if ($fp -ne $lastFingerprint -and $knownHeadsets.Count -gt 0) {
                    $lastFingerprint = $fp

                    # Identity mismatches found this tick: the headset answering at a row's
                    # address reports a DIFFERENT serial than the row holds. Collected here and
                    # applied after the loop, because each fix rewrites the whole registry.
                    $identityFixes = @()

                    # Model/Serial CSV updates must be serialized in the main thread
                    foreach ($headsetInfo in $knownHeadsetsInfo) {
                        # Resolve by IP, not by ID: $headsetInfo.ID is a value the per-headset
                        # runspace captured once at startup and never refreshes, while ID can be
                        # reassigned on a reorder. IP is the loop's own stable join key (see
                        # $sharedState[$h.IPAddress] above), so it is safe against ID recycling.
                        $headset = $knownHeadsets | Where-Object { $_.IPAddress -eq $headsetInfo.IPAddress } | Select-Object -First 1
                        if (-not $headset) { continue }

                        $fetchedModel = $headsetInfo.Model
                        if ((ConvertTo-BoolField $headsetInfo.ADBWifi) `
                            -and -not [string]::IsNullOrWhiteSpace($fetchedModel) `
                            -and $fetchedModel -ne "-" -and $fetchedModel -ne $headset.Model) {
                            Write-Log ($msg.UpdatingModel -f $headset.Name, $headset.IPAddress, $fetchedModel) -Level INFO
                            Update-HeadsetField -ID $headset.ID -Field "Model" -NewValue $fetchedModel
                        }
                        $fetchedBrand = $headsetInfo.Brand
                        $currentBrand = if ($headset.PSObject.Properties['Brand']) { $headset.Brand } else { "" }
                        if ((ConvertTo-BoolField $headsetInfo.ADBWifi) `
                            -and -not [string]::IsNullOrWhiteSpace($fetchedBrand) `
                            -and $fetchedBrand -ne $currentBrand) {
                            Write-Log ("Updating brand for headset {0} ({1}): {2}" -f $headset.Name, $headset.IPAddress, $fetchedBrand) -Level INFO
                            Update-HeadsetField -ID $headset.ID -Field "Brand" -NewValue $fetchedBrand
                        }
                        # SerialNumber is the headset's permanent identity, so it is NEVER
                        # blindly overwritten with whatever answers at this address. Doing so
                        # is what used to make a DHCP lease swap permanent: headset A's row
                        # would silently inherit headset B's serial, destroying the only key
                        # capable of healing it.
                        $fetchedSerial = $headsetInfo.SerialNumber
                        if ((ConvertTo-BoolField $headsetInfo.ADBWifi) `
                            -and -not [string]::IsNullOrWhiteSpace($fetchedSerial) `
                            -and $fetchedSerial -ne "-") {

                            if ([string]::IsNullOrWhiteSpace($headset.SerialNumber)) {
                                # Learning: a row created from an IP alone (manual add) gets
                                # keyed on first contact. Safe - there is nothing to contradict.
                                Write-Log ($msg.UpdatingSerialNumber -f $headset.Name, $headset.IPAddress, $fetchedSerial) -Level INFO
                                Update-HeadsetField -ID $headset.ID -Field "SerialNumber" -NewValue $fetchedSerial
                            }
                            elseif (([string]$headset.SerialNumber).Trim() -ne $fetchedSerial.Trim()) {
                                # Mismatch: this address now belongs to a different headset.
                                # Hand it to Set-HeadsetIdentity, which moves the address to its
                                # rightful owner and releases this row.
                                $identityFixes += @{
                                    Serial = $fetchedSerial.Trim()
                                    IP     = $headsetInfo.IPAddress
                                    Model  = $headsetInfo.Model
                                    Brand  = $headsetInfo.Brand
                                }
                            }
                        }
                    }

                    # Apply identity fixes. Convergence for a crossed pair: row A=.10 / row B=.11
                    # with the real headsets swapped - polling .10 returns B's serial, so B takes
                    # .10 and A is released to an unknown address; the next tick polls .11,
                    # returns A's serial, and A takes .11. At most two ticks, no operator action.
                    $identityChanged = $false
                    foreach ($fix in $identityFixes) {
                        try {
                            $r = Set-HeadsetIdentity -SerialNumber $fix.Serial -IPAddress $fix.IP `
                                                     -Model $fix.Model -Brand $fix.Brand -Source 'adb-poll'
                            if ($r.Ok -and $r.Action -ne 'unchanged') {
                                $identityChanged = $true
                                # Drop cached poll results for every address that moved, so a
                                # stale record is never joined onto the row that now owns it.
                                $staleIps = @($fix.IP) + @($r.Released | ForEach-Object { $_.OldIP })
                                foreach ($staleIp in ($staleIps | Select-Object -Unique)) {
                                    if ($staleIp -and $sharedState.ContainsKey($staleIp)) { $sharedState.Remove($staleIp) }
                                }
                            }
                        } catch {
                            Write-Log ("VRMonitor: identity fix failed for serial " + $fix.Serial + ": " + $_.Exception.Message) -Level WARNING
                        }
                    }

                    if ($identityChanged) {
                        # The registry moved under us. Re-read it and force a full recompute on
                        # the next tick instead of exporting a snapshot built on stale rows.
                        $knownHeadsets = @(Get-KnownHeadsets)
                        $lastFingerprint = ""
                    }
                    else {
                        # Write ID + live status only (ADR-0016). Name/IPAddress/Brand/Model/
                        # SerialNumber are authoritative in the registry and are deliberately
                        # NOT duplicated here - a rename or an IP change must not touch a
                        # status row.
                        #
                        # One batch = one transaction. The CSV rewrite this replaces was the
                        # most frequent write in the application (up to 2 Hz behind the
                        # fingerprint gate) and it rewrote every row to change one.
                        #
                        # Rows are built explicitly rather than piped through Select-Object:
                        # ping/adb_wifi are INTEGER columns with CHECK (x IN (0,1)), so a .NET
                        # bool has to become 0/1, and every text column is NOT NULL, so a $null
                        # from a headset that never answered has to become the '-' placeholder
                        # the CSV era wrote. Binding the record as-is would fail the constraint
                        # on the first offline headset.
                        $statusRows = @()
                        foreach ($info in $knownHeadsetsInfo) {
                            $statusRows += @{
                                ID                     = [int]$info.ID
                                Ping                   = (ConvertTo-DbBool $info.Ping)
                                ADBWifi                = (ConvertTo-DbBool $info.ADBWifi)
                                Battery                = [string](Get-StatusFieldOrDash $info.Battery)
                                Charging               = [string](Get-StatusFieldOrDash $info.Charging)
                                ChargingWattage        = [string](Get-StatusFieldOrDash $info.ChargingWattage)
                                Temp                   = [string](Get-StatusFieldOrDash $info.Temp)
                                CpuTemp                = [string](Get-StatusFieldOrDash $info.CpuTemp)
                                GpuTemp                = [string](Get-StatusFieldOrDash $info.GpuTemp)
                                SkinTemp               = [string](Get-StatusFieldOrDash $info.SkinTemp)
                                BatteryControllerLeft  = [string](Get-StatusFieldOrDash $info.BatteryControllerLeft)
                                BatteryControllerRight = [string](Get-StatusFieldOrDash $info.BatteryControllerRight)
                                PowerState             = [string](Get-StatusFieldOrDash $info.PowerState)
                                TimeRemainingMin       = [string](Get-StatusFieldOrDash $info.TimeRemainingMin)
                                AdbTransport           = [string](Get-StatusFieldOrDash $info.AdbTransport)
                                SCRCPY                 = [string](Get-StatusFieldOrDash $info.SCRCPY)
                                RunningApp             = [string](Get-StatusFieldOrDash $info.RunningApp)
                                RunningAppIcon         = [string]$(if ($null -eq $info.RunningAppIcon) { '' } else { $info.RunningAppIcon })
                            }
                        }
                        try {
                            Invoke-DbBatch -Name 'status.upsert' -Rows $statusRows | Out-Null
                        } catch {
                            Write-Log ("VRMonitor: live status write failed - " + $_.Exception.Message) -Level WARNING
                        }

                        # Own guard: an overlay write failure must not skip the kiosk snapshot below.
                        $tickErrors['monitoring overlay update'] = $null
                        try { Update-HeadsetMonitoringFile -knownHeadsetsInfo $knownHeadsetsInfo }
                        catch { $tickErrors['monitoring overlay update'] = Get-VRMonitorTickErrorText -ErrorRecord $_ }

                        Write-Log ($msg.JobInfoCollected -f $knownHeadsetsInfo.Count) -Level DEBUG
                    }
                }

                # ---- FAST PATH: kiosk status snapshot (write-on-change, mirrors above) ----
                $kioskKeys = @($sharedState.Keys | Where-Object { $_ -like "kiosk_*" })
                if ($kioskKeys.Count -gt 0) {
                    $kioskStatuses = @($kioskKeys | ForEach-Object { $sharedState[$_] } | Where-Object { $_ })
                    $kioskFp = ($kioskStatuses | ForEach-Object {
                        "$($_.IPAddress)|$($_.Port)|$($_.Reachable)|$($_.LatencyMs)|$($_.CdpOpen)|$($_.CurrentUrl)"
                    }) -join '~'
                    if ($kioskFp -ne $lastKioskFingerprint) {
                        $lastKioskFingerprint = $kioskFp
                        try {
                            # One transaction for the whole snapshot, behind the same
                            # fingerprint gate as before. LastChecked is gone: it used
                            # to serialise as a culture-dependent DateTime blob that
                            # nothing ever read, and the table's own updated_at says
                            # the same thing.
                            $kioskRows = @($kioskStatuses | ForEach-Object {
                                @{
                                    ip_address  = [string]$_.IPAddress
                                    port        = [int]$_.Port
                                    reachable   = (ConvertTo-DbBool $_.Reachable)
                                    latency_ms  = $(if ($null -ne $_.LatencyMs) { [int]$_.LatencyMs } else { $null })
                                    cdp_open    = (ConvertTo-DbBool $_.CdpOpen)
                                    current_url = [string]$_.CurrentUrl
                                    extra_json  = '{}'
                                }
                            })
                            Invoke-DbBatch -Name 'kiosk_status.upsert' -Rows $kioskRows | Out-Null
                        } catch {
                            Write-Log ("VRMonitor: failed to store kiosk status: " + $_.Exception.Message) -Level WARNING
                        }
                    }
                }
            } catch {
                $tickErrors['fast tick'] = Get-VRMonitorTickErrorText -ErrorRecord $_
                # Inside a try, an error that used to skip ONE statement aborts the rest of
                # the block - possibly after the fingerprint was taken and before the status
                # write. Forget the fingerprints so the next tick redoes that work.
                $lastFingerprint      = ""
                $lastKioskFingerprint = ""
            }

            # ---- SLOW PATH (every refresh_timer seconds) ----
            $slowCounter++
            if ($slowCounter -ge $slowEvery) {
                $slowCounter = 0
                $tickErrors['slow tick'] = $null
                # DEBUG timing (S3-2 / S0-1): the fast path waits for the whole slow tick.
                $slowTickSw = [System.Diagnostics.Stopwatch]::StartNew()

                # Liveness for other processes (web server, NR harness): the loop reached a
                # slow tick. Written first and on its own, so a slow tick that fails further
                # down still says the loop is alive - the failure itself is logged as ERROR.
                # A quoted JSON string, like usb_busy_until: app_kv values are JSON documents.
                try {
                    Set-DbKeyValue -Key 'vrmonitor_heartbeat' -Value ('"' + (Get-Date).ToUniversalTime().ToString('o') + '"')
                } catch { }

                try {
                    if (Test-ConfigChanged -ConfigFilePath $global:ConfigFilePath) {
                        Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null
                    }
                    $sharedState["_refresh_timer"] = $global:VRMonitor_refresh_timer
                    $slowEvery = [Math]::Max(1, [int]($global:VRMonitor_refresh_timer / 0.5))

                    Write-Log ($msg.DebugConfigFilePath -f $global:ConfigFilePath) -Level DEBUG
                    Write-Log ($msg.DebugKnownHeadsetsPath -f $global:knownHeadsetsFilePath) -Level DEBUG

                    $knownHeadsets = @(Get-KnownHeadsets)

                    # Guarded like the discovery/companion calls below it: anything that
                    # escapes here would abort the rest of the slow tick (service
                    # watchdogs, computer monitoring respawn, VQA) for every headset.
                    try {
                        Invoke-UsbHeadsetActions | Out-Null
                    } catch {
                        Write-Log ("VRMonitor: USB tick failed: " + $_.Exception.Message) -Level WARNING
                    }

                    # Companion apps: discovery runs in its own runspace (S3-1, no blocking UDP
                    # receive here). Apply what it published: heals IP drift by serial.
                    try {
                        Sync-CompanionDiscoveryRunspace -registry ([ref]$companionRunspace) -sharedState $sharedState `
                            -scriptPath $global:ScriptPath -configFilePath $global:ConfigFilePath `
                            -pollBlock $companionPollBlock
                        if ($sharedState["_companion_results"]) {
                            $companions = @($sharedState["_companion_results"])
                            $sharedState["_companion_results"] = $null
                            foreach ($c in $companions) {
                                if ($c.Serial -and $c.IP) {
                                    Set-HeadsetIdentity -SerialNumber $c.Serial -IPAddress $c.IP `
                                                        -Model $c.Model -Source 'companion' | Out-Null
                                }
                            }
                        }
                    } catch {
                        Write-Log ("VRMonitor: companion discovery failed: " + $_.Exception.Message) -Level DEBUG
                    }

                    # Background LAN discovery: start/stop to match the config toggle, then
                    # drain whatever the sweep runspace published. Applying the results here
                    # keeps every registry write in the main thread, like the fast path above.
                    try {
                        Sync-HeadsetDiscoveryRunspace -registry ([ref]$discoveryRunspace) -sharedState $sharedState `
                            -scriptPath $global:ScriptPath -configFilePath $global:ConfigFilePath `
                            -pollBlock $discoveryPollBlock

                        if ($sharedState["_discovery_results"]) {
                            $discovered = @($sharedState["_discovery_results"])
                            $sharedState["_discovery_results"] = $null
                            if ($discovered.Count -gt 0) {
                                if ((Update-HeadsetsFromDiscovery -Devices $discovered) -gt 0) {
                                    # Rows moved - reload and force a fast-path recompute.
                                    $knownHeadsets = @(Get-KnownHeadsets)
                                    $lastFingerprint = ""
                                }
                            }
                        }
                    } catch {
                        Write-Log ("VRMonitor: headset discovery failed: " + $_.Exception.Message) -Level WARNING
                    }

                    # Each sub-step below has its own guard so one failure does not skip the
                    # service watchdogs and the computer monitoring that follow it. Their failures go
                    # through the same rate-limited report as the tick guards (below the slow path).
                    foreach ($step in 'headset runspace sync', 'video overlay update', 'timer overlay update', 'restream path sync') { $tickErrors[$step] = $null }
                    try {
                        Sync-HeadsetRunspaces -knownHeadsets $knownHeadsets -runspaceRegistry ([ref]$runspaceRegistry) `
                            -sharedState $sharedState -scriptPath $global:ScriptPath `
                            -configFilePath $global:ConfigFilePath -pollBlock $headsetPollBlock
                    } catch { $tickErrors['headset runspace sync'] = Get-VRMonitorTickErrorText -ErrorRecord $_ }

                    try {
                        Sync-KioskRunspaces -runspaceRegistry ([ref]$kioskRunspaceRegistry) `
                            -sharedState $sharedState -scriptPath $global:ScriptPath `
                            -configFilePath $global:ConfigFilePath -pollBlock $kioskPollBlock
                    } catch { Write-Log ("VRMonitor: kiosk sync failed: " + $_.Exception.Message) -Level WARNING }

                    try { Update-HeadsetVideoFile } catch { $tickErrors['video overlay update'] = Get-VRMonitorTickErrorText -ErrorRecord $_ }
                    try { Update-HeadsetTimerFile } catch { $tickErrors['timer overlay update'] = Get-VRMonitorTickErrorText -ErrorRecord $_ }
                    try { Sync-RestreamPaths }      catch { $tickErrors['restream path sync']   = Get-VRMonitorTickErrorText -ErrorRecord $_ }

                    # mediamtx before scrcpy watchdog (publisher ordering - see eager block above).
                    # Only this slow-tick pass checks pipeline health: a capture whose ffmpeg push,
                    # bridge or mediamtx publisher died under a running scrcpy is restarted here.
                    try { Start-MediaMtx }         catch { Write-Log ("VRMonitor: mediamtx watchdog failed: " + $_.Exception.Message) -Level WARNING }
                    try { Watch-ScrcpyProcesses -HeadsetInfo $infoByIp -CheckPipelineHealth } catch { Write-Log ("VRMonitor: scrcpy watchdog failed: " + $_.Exception.Message) -Level WARNING }
                    try { Start-WebServer }        catch { Write-Log ("VRMonitor: web server watchdog failed: " + $_.Exception.Message) -Level WARNING }

                    # Computer monitoring runs in its own runspace (S3-2), which also honours the
                    # benchmark pause. Here: respawn it if it died, and apply what only this thread
                    # may do - the registry write that turns recording off on a low drive.
                    $tickErrors['computer monitoring'] = $null
                    try {
                        Start-ComputerMonitorRunspace -registry ([ref]$computerMonitorRunspace) -sharedState $sharedState `
                            -scriptPath $global:ScriptPath -configFilePath $global:ConfigFilePath -pollBlock $computerMonitorPollBlock
                        $lowDrive = $sharedState["_recording_drive_low"]
                        if ($lowDrive) {
                            $sharedState["_recording_drive_low"] = $null
                            [void](Disable-RecordingOnLowDisk -RecordingDrive $lowDrive)
                        }
                    } catch { $tickErrors['computer monitoring'] = Get-VRMonitorTickErrorText -ErrorRecord $_ }

                    # Database housekeeping - currently the battery-history retention
                    # window. Called on every slow tick but self-throttled to
                    # database.maintenance_interval_min, so this is a cheap comparison
                    # almost every time. It lives here, on the slow loop, precisely so
                    # it stays off the fast path's batched status write: anything that
                    # throws in that transaction loses every headset's status for the
                    # tick, not just one row's.
                    if (Get-Command Invoke-DbMaintenance -ErrorAction SilentlyContinue) {
                        try { Invoke-DbMaintenance | Out-Null }
                        catch { Write-Log ("VRMonitor: database maintenance failed: " + $_.Exception.Message) -Level WARNING }
                    }

                    # Recordings catalogue: sweep for stale records and missing files. Self-throttles.
                    if (Get-Command Sync-RecordingCatalog -ErrorAction SilentlyContinue) { try { [void](Sync-RecordingCatalog) } catch {} }
                    # Interrupted recordings (writer killed, app crash): one background remux at a time,
                    # never blocking this loop (Update-RecordingRepair only starts or collects it).
                    if (Get-Command Update-RecordingRepair -ErrorAction SilentlyContinue) { try { [void](Update-RecordingRepair) } catch {} }

                    # VQA neither recommends from benchmark load nor rewrites config during a run.
                    if (-not $benchRunId -and $global:VQA_Enabled -and (Get-Command Invoke-VideoQualityRecommendation -ErrorAction SilentlyContinue)) {
                        # Tier-gated: idle=every tick (m=1), mitigation=every 2nd (m=2), max=every 5th (m=5).
                        # Increment first so the first tick always runs (counter % 1 == 0).
                        $vqrTickCounter++
                        $m = try { Get-LoadMultiplier } catch { 1 }
                        if ($vqrTickCounter % $m -eq 0) {
                            try {
                                Invoke-VideoQualityRecommendation | Out-Null
                                if ($global:VQA_EnabledVQO) { Invoke-VideoQualityOptimizer }
                            } catch {
                                Write-Log ("VQA: cycle failed: " + $_.Exception.Message) -Level WARNING
                            }
                        } else {
                            Write-Log ("VQA: skipped tick (multiplier={0}, counter={1})" -f $m, $vqrTickCounter) -Level DEBUG
                        }
                    }

                    Write-Log ($msg.JobRestartsIn -f $jobName, $global:VRMonitor_refresh_timer) -Level DEBUG
                } catch {
                    $tickErrors['slow tick'] = Get-VRMonitorTickErrorText -ErrorRecord $_
                }
                Write-Log ("VRMonitor slow tick took {0} ms" -f $slowTickSw.ElapsedMilliseconds) -Level DEBUG
            }

            # Report this tick's failures, per guarded step. Every failed run is logged up to
            # $tickFailureLogMax in a row; past that a persistent fault would write a line every
            # tick, so it is summarised once a minute until a clean run of that step resets its
            # count. A step that did not run this tick (the slow ones) keeps its count. Guarded:
            # the report itself must never be what ends the loop.
            try {
                $now = Get-Date
                foreach ($step in @($tickErrors.Keys)) {
                    $tickError = $tickErrors[$step]
                    if (-not $tickFailures.ContainsKey($step)) { $tickFailures[$step] = 0; $lastTickErrorLogAt[$step] = [datetime]::MinValue }
                    if ($tickError) {
                        $tickFailures[$step]++
                        if ($tickFailures[$step] -le $tickFailureLogMax) {
                            Write-Log ("VRMonitor {0} failed: {1}" -f $step, $tickError) -Level ERROR
                            $lastTickErrorLogAt[$step] = $now
                        } elseif (($now - $lastTickErrorLogAt[$step]).TotalSeconds -ge 60) {
                            Write-Log ("VRMonitor {0} failed {1} times in a row, still failing: {2}" -f $step, $tickFailures[$step], $tickError) -Level ERROR
                            $lastTickErrorLogAt[$step] = $now
                        }
                    } elseif ($tickFailures[$step] -gt 0) {
                        if ($tickFailures[$step] -gt $tickFailureLogMax) {
                            Write-Log ("VRMonitor {0} recovered after {1} consecutive failures" -f $step, $tickFailures[$step]) -Level INFO
                        }
                        $tickFailures[$step] = 0
                    }
                }
            } catch { }

            Start-Sleep -Milliseconds 500
        }
    }
}


<#
.SYNOPSIS
    A live-status text field, with '-' standing in for "nothing known yet".
.DESCRIPTION
    Every text column of headset_status is NOT NULL, and the CSV era's own
    placeholder for an unanswered field was the single character '-' (see
    New-DefaultHeadsetInfo). This keeps that convention at the write boundary so
    a headset that has never answered still produces a valid row instead of
    failing the insert.
.EXAMPLE
    Get-StatusFieldOrDash $info.Battery
#>
function Get-StatusFieldOrDash {
    param($Value)
    if ($null -eq $Value) { return '-' }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '-' }
    return $text
}

<#
.SYNOPSIS
    The metrics that metric_history records, and how each one is presented.
.DESCRIPTION
    Single source of truth for the metric list on the PowerShell side. Every key
    here has a matching sampling trigger in migration 006 and a matching entry in
    the METRICS registry in website\assets\battery_chart.js - all three must be
    changed together when a metric is added, and this one is what the web API
    validates against, so an unknown key can never reach a query.

    Percent metrics are drawn on a pinned 0..100 axis; the others are auto-scaled,
    because pinning a temperature to 0..100 flattens a 30->45 C swing into a
    straight line.
.EXAMPLE
    (Get-HeadsetMetricDefinition).Keys
.EXAMPLE
    (Get-HeadsetMetricDefinition)['temp'].Unit
#>
function Get-HeadsetMetricDefinition {
    return [ordered]@{
        battery    = @{ Label = 'Battery';        Unit = '%'; Column = 'battery';                  IsPercent = $true  }
        temp       = @{ Label = 'Temperature';    Unit = 'C'; Column = 'temp';                     IsPercent = $false }
        ctrl_left  = @{ Label = 'Controller L';   Unit = '%'; Column = 'battery_controller_left';  IsPercent = $true  }
        ctrl_right = @{ Label = 'Controller R';   Unit = '%'; Column = 'battery_controller_right'; IsPercent = $true  }
        wattage    = @{ Label = 'Charging power'; Unit = 'W'; Column = 'charging_wattage';         IsPercent = $false }
        cpu_temp   = @{ Label = 'CPU temperature'; Unit = 'C'; Column = 'cpu_temp';                IsPercent = $false }
        gpu_temp   = @{ Label = 'GPU temperature'; Unit = 'C'; Column = 'gpu_temp';                IsPercent = $false }
        skin_temp  = @{ Label = 'Skin temperature'; Unit = 'C'; Column = 'skin_temp';              IsPercent = $false }
    }
}

<#
.SYNOPSIS
    Samples of one metric for one headset over a time window, oldest first.
.DESCRIPTION
    The shared backend behind the metric-history graph: the web API
    (GET /api/metric-history) and any console caller both go through here, so the
    window clamping and the timestamp format live in exactly one place.

    Reads the metric_history table through the named query 'metric.window'. Rows
    are only written when the value CHANGES (the trg_status_*_sample triggers), so
    a stable headset legitimately returns very few rows - the query seeds the
    series with the last sample before the window precisely so a flat line is
    still drawable. Callers must treat the series as a STEP function: each value
    holds until the next sample.

    Retention is database.metric_history_hours (default 24), swept by
    Invoke-DbMaintenance, so asking for more hours than that returns only what
    survived the sweep.

    Never throws - returns an empty array on any failure, like the rest of the
    monitoring read paths.
.PARAMETER HeadsetId
    Permanent headset id (ADR-0016). Not the name, not the address.
.PARAMETER Metric
    One of the keys of Get-HeadsetMetricDefinition. Anything else returns @().
.PARAMETER Hours
    Size of the window ending now, in hours. Clamped to 0.25 .. the retention
    period (never below 168, so the four fixed windows always work).
.EXAMPLE
    Get-MetricHistory -HeadsetId 1 -Metric temp -Hours 24 | Format-Table
.EXAMPLE
    (Get-MetricHistory -HeadsetId 3 -Metric battery -Hours 1).Count
#>
function Get-MetricHistory {
    param (
        [Parameter(Mandatory = $true)][int]$HeadsetId,
        [string]$Metric = 'battery',
        [double]$Hours = 24
    )

    if ($HeadsetId -le 0) { return @() }

    # Whitelist, not a pass-through: @metric reaches a query, and an unknown key
    # would silently return an empty graph rather than saying anything.
    $defs = Get-HeadsetMetricDefinition
    if (-not $defs.Contains($Metric)) { return @() }

    # Clamp rather than reject: this is a display window, and a caller asking for
    # something silly should get a sane graph, not an error page. The ceiling
    # follows the retention period - a fixed 168 would silently truncate the
    # "all records" window on any install keeping more than 7 days.
    $retention = if ($global:databaseMetricHistoryHours) { [double]$global:databaseMetricHistoryHours } else { 24 }
    $ceiling   = [Math]::Max(168, $retention)
    if ($Hours -lt 0.25)     { $Hours = 0.25 }
    if ($Hours -gt $ceiling) { $Hours = $ceiling }

    try {
        # Same ISO-8601 UTC shape the sampling triggers write and Invoke-DbMaintenance
        # prunes on, so the comparison stays a plain string compare on an indexed column.
        $since = [datetime]::UtcNow.AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
        return @(Invoke-DbQuery -Name 'metric.window' -Parameters @{
            headset_id = $HeadsetId
            metric     = $Metric
            since      = $since
        })
    } catch {
        Write-Log ("Get-MetricHistory failed for headset {0} metric {1}: {2}" -f $HeadsetId, $Metric, $_.Exception.Message) -Level DEBUG
        return @()
    }
}

<#
.SYNOPSIS
    Battery samples for one headset over a time window, oldest first.
.DESCRIPTION
    Thin wrapper over Get-MetricHistory -Metric battery, kept for its existing
    { ts; pct } contract - GET /api/battery-history and any console caller still
    consume that shape. New callers should use Get-MetricHistory directly.
.EXAMPLE
    Get-BatteryHistory -HeadsetId 1 -Hours 24 | Format-Table
#>
function Get-BatteryHistory {
    param (
        [Parameter(Mandatory = $true)][int]$HeadsetId,
        [double]$Hours = 24
    )

    return @(Get-MetricHistory -HeadsetId $HeadsetId -Metric 'battery' -Hours $Hours |
        ForEach-Object { [PSCustomObject]@{ ts = $_.ts; pct = [int]$_.value } })
}

function Get-HeadsetInfosCsvColumn {
    # Canonical column list of data\known_headsets_infos.csv, in export order (ADR-0016).
    # ID is the ONLY key; Name / IPAddress / Brand / Model / SerialNumber are authoritative
    # in known_headsets.csv and are deliberately not duplicated here, so a rename, a reorder
    # or an IP change never requires this file to be rewritten.
    # In-memory records (New-DefaultHeadsetInfo) still carry those fields - they hold the
    # live ADB values that drive the registry write-back - they are just not exported.
    return @(
        "ID",
        "Ping",
        "ADBWifi",
        "Battery",
        "Charging",
        "ChargingWattage",
        "Temp",
        "CpuTemp",
        "GpuTemp",
        "SkinTemp",
        "BatteryControllerLeft",
        "BatteryControllerRight",
        "PowerState",
        "TimeRemainingMin",
        # No BatteryHistory: the samples are rows in metric_history now
        # (migrations 005/006), written by a trigger on the Battery column above.
        # AdbTransport (migration 007): USB or WiFi - which transport the monitor
        # is using for this headset right now, a dash when neither answers.
        "AdbTransport",
        "SCRCPY",
        "RunningApp",
        "RunningAppIcon"
    )
}

function New-DefaultHeadsetInfo {
    # Canonical schema for the per-headset info record stored in $sharedState. A superset of
    # the exported CSV columns (see Get-HeadsetInfosCsvColumn) - single source of truth,
    # reused by Get-KnownHeadsetInfos and by the main-loop placeholder.
    param([Parameter(Mandatory=$true)][PSCustomObject]$knownHeadset)
    return [PSCustomObject]@{
        ID              = $knownHeadset.ID
        Name            = $knownHeadset.Name
        IPAddress       = $knownHeadset.IPAddress
        Ping            = $false
        ADBWifi         = $false
        Battery         = "-"
        Charging        = "-"
        ChargingWattage = "-"
        Temp            = "-"
        CpuTemp         = "-"
        GpuTemp         = "-"
        SkinTemp        = "-"
        BatteryControllerLeft  = "-"
        BatteryControllerRight = "-"
        PowerState       = "-"
        TimeRemainingMin = "-"
        AdbTransport     = "-"
        BatteryHistory   = ""
        SCRCPY           = "-"
        Brand            = ""
        Model            = "-"
        SerialNumber     = "-"
        RunningApp       = "-"
        RunningAppIcon   = ""
    }
}

function Get-HeadsetInfoStage1Reachability {
    # Stage 1 (fast, no ADB connection): ping + ADB port + local scrcpy process scan.
    # Target latency: <2s. Lets the UI flip Ping/ADBWifi/SCRCPY immediately.
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$knownHeadset,
        [int]$ADBPort = 5555,
        [int]$PingTimeout = 1000
    )
    $out = @{ Ping = $false; ADBWifi = $false; AdbTransport = "-"; SCRCPY = "-" }
    $IPAddress = $knownHeadset.IPAddress

    # Defensive: Sync-HeadsetRunspaces already skips rows with an unknown address, but a
    # direct caller must never generate traffic for one. 127.0.0.x would answer a local
    # ping instantly and report a headset as reachable when it is not.
    if (Test-UnknownIp $IPAddress) { return $out }

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $pingReply = $ping.Send($IPAddress, $PingTimeout)
        $out.Ping = $pingReply.Status -eq "Success"
    } catch {
        $out.Ping = $false
    } finally {
        $ping.Dispose()
    }

    $wifiOpen = $false
    if ($out.Ping) {
        if ((Test-Port -hostname $IPAddress -port $ADBPort -timeout 400).open) {
            $wifiOpen = $true
        }
    }

    # USB-first transport: a headset cabled to this PC is reachable over ADB even when its
    # WiFi is off or the ping fails, so ADB reachable is true if EITHER transport is up.
    # The cabled set is what VRMonitor published (no adb.exe spawn here - this runs every
    # second per headset). AdbTransport names the one Resolve-HeadsetAdbDevice will pick.
    $usbCabled = $false
    $usbSerial = if ($knownHeadset.SerialNumber) { ([string]$knownHeadset.SerialNumber).Trim() } else { '' }
    if ($usbSerial -and $usbSerial -ne '-' -and (Get-Command Get-PublishedUsbDevices -ErrorAction SilentlyContinue)) {
        $usbCabled = [bool](@(Get-PublishedUsbDevices | Where-Object { $_.Serial -eq $usbSerial }).Count)
    }
    $preferUsb = if ($null -ne $global:ADB_prefer_usb) { [bool]$global:ADB_prefer_usb } else { $true }
    if ($usbCabled -and ($preferUsb -or -not $wifiOpen)) { $out.AdbTransport = "USB" }
    elseif ($wifiOpen)                                  { $out.AdbTransport = "WiFi" }
    $out.ADBWifi = ($usbCabled -or $wifiOpen)

    # Fast path: check cached scrcpy PID (avoids WMI on every cycle)
    $cachedPid = $script:ScrcpyPidCache[$IPAddress]
    if ($cachedPid) {
        $alive = Get-Process -Id $cachedPid -ErrorAction SilentlyContinue
        if ($alive -and -not $alive.HasExited) {
            $out.SCRCPY = "OK"
        } else {
            $script:ScrcpyPidCache.Remove($IPAddress)
        }
    }

    # Slow path: full scan only on cache miss or after PID death
    if ($out.SCRCPY -ne "OK") {
        $safeName = $knownHeadset.Name -replace ' ', '_'
        $scrcpyProcesses = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue
        if ($scrcpyProcesses) {
            foreach ($proc in $scrcpyProcesses) {
                if ($proc.Path -like "$($global:scrcpyFolder)\scrcpy.exe") {
                    $matched = $false
                    # No-WMI path: scrcpy sets --window-title to the safe display name
                    if ($proc.MainWindowTitle -eq $safeName) {
                        $matched = $true
                    }
                    # WMI fallback: StreamOnly uses --no-window so title is always empty
                    if (-not $matched -and -not $proc.MainWindowTitle) {
                        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
                        if ($cimProc) {
                            $cmdLine = $cimProc.CommandLine
                            $cimProc.Dispose()
                            # A WiFi launch carries -s ip:port; a USB launch carries
                            # -s <serial>. Either one means this headset session.
                            if ($cmdLine -match ([regex]::Escape($IPAddress) + "(:$ADBPort)?") -or
                                ($usbSerial -and $usbSerial -ne '-' -and $cmdLine -match ('-s\s+\x22?' + [regex]::Escape($usbSerial) + '(?:\x22|\s|$)'))) {
                                $matched = $true
                            }
                        }
                    }
                    if ($matched) {
                        $script:ScrcpyPidCache[$IPAddress] = $proc.Id
                        $out.SCRCPY = "OK"
                        break
                    }
                }
            }
        }
    }
    return $out
}

function Get-HeadsetPollSnapshot {
    <#
    .SYNOPSIS
    Battery, controller batteries and foreground app of one headset in ONE adb call.

    .DESCRIPTION
    Replaces three separate "adb shell dumpsys" spawns per poll cycle (battery,
    OVRRemoteService, activity activities) with one script whose segments are split on an
    echoed marker (Invoke-HeadsetDiagShell) and fed to the existing parsers
    (ConvertFrom-BatteryDump, ConvertFrom-ControllerDump, ConvertFrom-ForegroundActivityLines).
    The device-side grep keeps the output small: the full "dumpsys activity activities" is
    hundreds of KB. OVRRemoteService is skipped on Pico (Meta only).

    Returns @{ Ok; Battery; ForegroundPackage }. Ok = $false when the call itself failed
    (transport gone, timeout): Battery and ForegroundPackage are then $null, i.e. the same
    "unknown" the separate calls gave. Battery is a Get-HeadsetBatteryStatus-shaped object
    (controller fields filled on Meta) or $null when the headset returned no battery data.
    Falls back to the separate calls when Invoke-HeadsetDiagShell is not loaded.

    .EXAMPLE
    $snap = Get-HeadsetPollSnapshot -Device $device -Brand 'Meta'
    #>
    param(
        [Parameter(Mandatory=$true)]$Device,
        [string]$Brand = "",
        [string]$adb = $global:adbPath
    )
    $res = @{ Ok = $false; Battery = $null; ForegroundPackage = $null }

    if (-not (Get-Command Invoke-HeadsetDiagShell -ErrorAction SilentlyContinue)) {
        $res.Battery = Get-HeadsetBatteryStatus -Device $Device -adb $adb -Brand $Brand
        $res.ForegroundPackage = Get-HeadsetForegroundApp -Device $Device -adb $adb
        $res.Ok = $true
        return $res
    }

    $isPico = ($Brand -eq "Pico")
    $cmds = @(
        'dumpsys battery',
        $(if ($isPico) { 'true' } else { 'dumpsys OVRRemoteService | grep "Paired device:"' }),
        'dumpsys activity activities | grep -E -A1 "topResumedActivity=|mResumedActivity"'
    )
    $seg = Invoke-HeadsetDiagShell -Device $Device -Commands $cmds -TimeoutSeconds 15
    if ($null -eq $seg) { return $res }
    $res.Ok = $true

    $battLines = @($seg[0] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($battLines.Count -gt 0) {
        $b = ConvertFrom-BatteryDump -Lines $battLines
        if (-not $isPico) {
            $c = ConvertFrom-ControllerDump -Lines $seg[1] -DeviceId $Device.DeviceId
            $b.BatteryControllerLeft  = $c.Left.Battery
            $b.BatteryControllerRight = $c.Right.Battery
        }
        $res.Battery = $b
    } else {
        Write-Log ($msg.NoBatteryData -f $Device.DeviceId) -Level WARNING
    }
    $res.ForegroundPackage = ConvertFrom-ForegroundActivityLines -Lines $seg[2]
    return $res
}

function Get-HeadsetPollDevice {
    <#
    .SYNOPSIS
    The ADB device object of a headset for the poll runspace, memoised in -Cache.

    .DESCRIPTION
    Resolve-HeadsetAdbDevice runs "adb devices" for a WiFi headset, i.e. one adb.exe spawn
    per poll cycle just to learn what the previous cycle already knew. The resolved object
    is kept in -Cache (a hashtable owned by the runspace) for -MaxAgeSec and re-resolved
    when: it is older than that, -Reset was passed (the caller saw a transport failure or
    the headset unreachable), a cached USB device is no longer in the published cabled set
    or USB is held by an operator action (Test-UsbBusy), or a cached WiFi device now has a
    cable and ADB.prefer_usb is on. Invoke-AdbCmd updates the device object in place on its
    USB->WiFi fallback, so the cached object always names the transport that last answered.
    The "adb connect" of an offline headset still happens: a failed call clears the cache
    and the next cycle goes through Resolve-HeadsetAdbDevice -> Get-AdbWifiDevice again.

    .EXAMPLE
    $device = Get-HeadsetPollDevice -Headset $liveHeadset -Cache $deviceCache -MaxAgeSec 10
    #>
    param(
        [Parameter(Mandatory=$true)]$Headset,
        [Parameter(Mandatory=$true)][hashtable]$Cache,
        [int]$MaxAgeSec = 10,
        [switch]$Reset
    )

    if ($Reset) { $Cache.Clear() }

    $dev = $Cache.Device
    if ($dev) {
        $serial = if ($Headset.SerialNumber) { ([string]$Headset.SerialNumber).Trim() } else { '' }
        if ($serial -eq '-') { $serial = '' }
        $age     = ([datetime]::UtcNow - $Cache.At).TotalSeconds
        $cabled  = $false
        if ($serial -and (Get-Command Get-PublishedUsbDevices -ErrorAction SilentlyContinue)) {
            $cabled = [bool](@(Get-PublishedUsbDevices | Where-Object { $_.Serial -eq $serial }).Count)
        }
        $busy = $false
        if (Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) { $busy = [bool](Test-UsbBusy) }
        $preferUsb = if ($null -ne $global:ADB_prefer_usb) { [bool]$global:ADB_prefer_usb } else { $true }

        $valid = ($age -ge 0 -and $age -lt $MaxAgeSec)
        if ($valid -and $dev.ConnectionType -eq 'USB'  -and (-not $cabled -or $busy)) { $valid = $false }
        if ($valid -and $dev.ConnectionType -eq 'WiFi' -and $cabled -and $preferUsb -and -not $busy) { $valid = $false }
        if ($valid -and $Cache.IP -ne [string]$Headset.IPAddress) { $valid = $false }
        if ($valid) { return $dev }
        $Cache.Clear()
    }

    $dev = Resolve-HeadsetAdbDevice -Headset $Headset
    if ($dev) {
        $Cache.Device = $dev
        $Cache.At     = [datetime]::UtcNow
        $Cache.IP     = [string]$Headset.IPAddress
    }
    return $dev
}

function Get-HeadsetInfoStage2Identity {
    # Stage 2 (medium): model + serial + battery dumpsys. Requires a connected $Device.
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$knownHeadset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath,
        # Filled with what the combined read also fetched (ForegroundRead, ForegroundPackage)
        # so Stage 3 does not run a second adb call for the foreground app.
        [hashtable]$PollData
    )
    $out = @{
        Brand = ""; Model = "-"; SerialNumber = "-"
        Battery = "-"; Charging = "-"; ChargingWattage = "-"; Temp = "-"
        CpuTemp = "-"; GpuTemp = "-"; SkinTemp = "-"
        BatteryControllerLeft = "-"; BatteryControllerRight = "-"
    }
    try {
        # -IncludeSerial folds ro.serialno into the same batched getprop call, so brand,
        # model and serial cost ONE adb round-trip instead of two.
        $bm = Get-HeadsetBrandModel -Device $Device -IncludeSerial -adb $adb
        if ($bm) {
            if ($bm.Brand) { $out.Brand = $bm.Brand }
            if (-not [string]::IsNullOrWhiteSpace($bm.Model)) { $out.Model = $bm.Model }
            if (-not [string]::IsNullOrWhiteSpace($bm.Serial)) { $out.SerialNumber = $bm.Serial }
        }

        # Battery, controllers and foreground app in ONE adb call (S5-1).
        $snap = Get-HeadsetPollSnapshot -Device $Device -Brand $out.Brand -adb $adb
        $batteryInfo = $snap.Battery
        if ($PollData -ne $null) {
            # A failed call is final for this cycle: Stage 3 reports "-", no second attempt.
            $PollData.ForegroundRead    = $true
            $PollData.ForegroundPackage = $snap.ForegroundPackage
            $PollData.CallFailed        = -not [bool]$snap.Ok
        }
        if ($batteryInfo) {
            if ($null -ne $batteryInfo.Level)    { $out.Battery  = "$($batteryInfo.Level) %" }
            if ($null -ne $batteryInfo.Charging) { $out.Charging = $batteryInfo.Charging }
            if ($null -ne $batteryInfo.MaxChargingWattageW -and $batteryInfo.Charging -eq $true) { $out.ChargingWattage = "$($batteryInfo.MaxChargingWattageW)" }
            if ($null -ne $batteryInfo.TempC)    { $out.Temp     = $batteryInfo.TempC.ToString("0.0") }
            $out.BatteryControllerLeft  = if ($null -ne $batteryInfo.BatteryControllerLeft)  { "$($batteryInfo.BatteryControllerLeft) %" }  else { "-" }
            $out.BatteryControllerRight = if ($null -ne $batteryInfo.BatteryControllerRight) { "$($batteryInfo.BatteryControllerRight) %" } else { "-" }
        }

        # CPU / GPU / skin temperatures from thermalservice, throttled to one read per 30 s
        # per headset (Get-HeadsetThermalCached). The dumpsys is one adb round-trip and the
        # readings move slowly, so reading it on every stage-2 cycle would only add process
        # churn. Between reads the LAST values are returned: stage 2 returns every key on
        # every call and the caller copies them all over the working record, so a key left
        # at a dash would blank the columns - and the metric graph - until the next read.
        $thermal = Get-HeadsetThermalCached -Device $Device -Key $knownHeadset.IPAddress -adb $adb
        if ($thermal) {
            if ($thermal.CpuTemp)  { $out.CpuTemp  = $thermal.CpuTemp }
            if ($thermal.GpuTemp)  { $out.GpuTemp  = $thermal.GpuTemp }
            if ($thermal.SkinTemp) { $out.SkinTemp = $thermal.SkinTemp }
        }
    } catch {
        Write-Log -Message ($msg.AdbInfoFailed -f $knownHeadset.IPAddress, $_) -Level "ERROR"
    }
    return $out
}

function Get-HeadsetThermalCached {
    <#
    .SYNOPSIS
    CPU/GPU/skin temperatures of one headset, read at most once per -EverySec seconds.

    .DESCRIPTION
    Wraps one "dumpsys thermalservice" (parsed by ConvertFrom-ThermalService) in a
    per-key memo that lives as long as the calling runspace. Returns the cached values
    between reads. Each value is a string formatted with the invariant culture (36.4),
    matching what the status columns and the sampling triggers expect; an absent sensor
    is $null, not a dash, so the caller decides the placeholder.

    A failed read keeps the previous values and still advances the clock, so a headset
    that does not answer is not asked again on every cycle.

    .EXAMPLE
    $t = Get-HeadsetThermalCached -Device $device -Key $ip
    $t.CpuTemp
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string]$Key,
        [int]$EverySec = 30,
        [string]$adb = $global:adbPath
    )

    if (-not $script:ThermalState) { $script:ThermalState = @{} }
    $st  = $script:ThermalState[$Key]
    $now = [datetime]::UtcNow
    if ($st -and (($now - $st.At).TotalSeconds -lt $EverySec)) { return $st }

    $prev = $st
    $st = @{ At = $now; CpuTemp = $null; GpuTemp = $null; SkinTemp = $null }
    if ($prev) { $st.CpuTemp = $prev.CpuTemp; $st.GpuTemp = $prev.GpuTemp; $st.SkinTemp = $prev.SkinTemp }

    try {
        $lines = Invoke-AdbCmd -Device $Device -Command "shell dumpsys thermalservice" -TimeoutSeconds 10 -adb $adb -SilentOnFail
        if ($lines) {
            $t   = ConvertFrom-ThermalService -Lines $lines
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $st.CpuTemp  = if ($null -ne $t.Cpu)  { ([double]$t.Cpu).ToString('0.0', $inv) }  else { $null }
            $st.GpuTemp  = if ($null -ne $t.Gpu)  { ([double]$t.Gpu).ToString('0.0', $inv) }  else { $null }
            $st.SkinTemp = if ($null -ne $t.Skin) { ([double]$t.Skin).ToString('0.0', $inv) } else { $null }
        }
    } catch { }

    $script:ThermalState[$Key] = $st
    return $st
}

function Get-HeadsetInfoStage3App {
    # Stage 3 (slowest): foreground app + display-name/icon resolution.
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$knownHeadset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath,
        # From Stage 2 when it already read the foreground app with the battery (S5-1).
        [hashtable]$PollData
    )
    $out = @{ RunningApp = "-"; RunningAppIcon = "" }
    try {
        $pkg = if ($PollData -ne $null -and $PollData.ForegroundRead) { $PollData.ForegroundPackage }
               else { Get-HeadsetForegroundApp -Device $Device -adb $adb }
        if ($pkg) {
            $appInfo = Get-AppInfo -PackageName $pkg -searchOnline $false
            $out.RunningApp     = if ($appInfo.DisplayName) { $appInfo.DisplayName } else { $pkg }
            $out.RunningAppIcon = if ($appInfo.LocalIconPath) { $appInfo.LocalIconPath } elseif ($appInfo.IconUrl) { $appInfo.IconUrl } else { "" }
        }
    } catch {
        Write-Log -Message ($msg.AdbInfoFailed -f $knownHeadset.IPAddress, $_) -Level "ERROR"
    }
    return $out
}

function Get-KnownHeadsetInfos {
    # Thin orchestrator preserved for public callers (web API, CLI). Runs all three
    # stages back-to-back into one PSCustomObject. The VRMonitor runspace bypasses this
    # and calls the stage helpers directly so it can publish partial results to
    # $sharedState between stages.
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$knownHeadset,

        [int]$ADBPort = 5555,

        [int]$PingTimeout = 1000,

        [string]$adb = $global:adbPath
    )

    $result = New-DefaultHeadsetInfo -knownHeadset $knownHeadset

    $s1 = Get-HeadsetInfoStage1Reachability -knownHeadset $knownHeadset -ADBPort $ADBPort -PingTimeout $PingTimeout
    foreach ($k in $s1.Keys) { $result.$k = $s1[$k] }
    if (-not $result.ADBWifi) { return $result }

    $device = Resolve-HeadsetAdbDevice -Headset $knownHeadset -AdbPort $ADBPort -adb $adb
    if (-not $device) {
        $result.ADBWifi = $false
        $result.AdbTransport = "-"
        return $result
    }
    $result.AdbTransport = $device.ConnectionType

    $pollData = @{}
    $s2 = Get-HeadsetInfoStage2Identity -knownHeadset $knownHeadset -Device $device -adb $adb -PollData $pollData
    foreach ($k in $s2.Keys) { $result.$k = $s2[$k] }

    $s3 = Get-HeadsetInfoStage3App -knownHeadset $knownHeadset -Device $device -adb $adb -PollData $pollData
    foreach ($k in $s3.Keys) { $result.$k = $s3[$k] }

    return $result
}
