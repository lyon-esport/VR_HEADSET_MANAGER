#################
# MANAGE DETAILED INFOS OF KNOWN HEADSETS
#################

$script:ScrcpyPidCache = @{}   # keyed by IP; value: scrcpy PID. Persists for runspace lifetime.

function Test-VRMonitor { #For tests purpose only
Copilot: Check Status

    $job = Get-Job -Name "VRMonitor"
    Receive-Job -Job $job


    # 2. Stop the job (if running)
    if ($job.State -eq "Running") {
        Stop-Job -Job $job
    }

    # 3. Retrieve the latest results (optional)
    $results = Receive-Job -Job $job
    Write-Host $results
    # 4. Remove the job
    Remove-Job -Job $job
}



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
    Start-Job -Name $jobName -ScriptBlock {
        $global:ScriptPath              = $using:ScriptPath
        $global:ConfigFilePath          = $using:ConfigFilePath
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
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","network_scanner.ps1","adb_functions.ps1","database.ps1","headsets_monitoring.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath | Out-Null

            # Load translations so $msg.* calls in functions do not throw
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -Path $transFile }

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

            # try/finally around the whole loop: the stop flags exit via return,
            # and this runspace owns a database connection that must be released
            # or its file handles keep the data folder locked after shutdown.
            try {
            while ($true) {
                if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }

                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    # --- Stage 1: reachability (every tick) ---
                    $s1 = Get-HeadsetInfoStage1Reachability -knownHeadset $headset
                    foreach ($k in $s1.Keys) { $workingInfo.$k = $s1[$k] }

                    # --- Stage 2/3: identity, battery, foreground app (every refresh_timer) ---
                    $timer = if ($sharedState["_refresh_timer"]) { [int]$sharedState["_refresh_timer"] } else { 5 }
                    if ([datetime]::Now -ge $nextStatsAt) {
                        $nextStatsAt = [datetime]::Now.AddSeconds($timer)

                        if ($workingInfo.ADBWifi) {
                            $device = Get-AdbWifiDevice -headsetIP $ip
                            if (-not $device) {
                                $workingInfo.ADBWifi = $false
                            } else {
                                # --- Stage 2: identity + battery ---
                                $s2 = Get-HeadsetInfoStage2Identity -knownHeadset $headset -Device $device
                                foreach ($k in $s2.Keys) { $workingInfo.$k = $s2[$k] }

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
                                $s3 = Get-HeadsetInfoStage3App -knownHeadset $headset -Device $device
                                foreach ($k in $s3.Keys) { $workingInfo.$k = $s3[$k] }
                                if ($appsCacheCounter % $appsCacheEvery -eq 0) {
                                    Update-InstalledAppsCache -Device $device -headsetName $headset.Name
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
                        $workingInfo.Battery                = "-"
                        $workingInfo.Charging               = "-"
                        $workingInfo.ChargingWattage        = "-"
                        $workingInfo.Temp                   = "-"
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
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -Path $transFile }

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
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -Path $transFile }

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
                try { Get-Config -ConfigFilePath $configFilePath | Out-Null } catch {}
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

        # Two-speed loop: 500ms fast tick for CSV/HTML, slow tick (refresh_timer) for heavy ops
        $slowEvery       = [Math]::Max(1, [int]($global:VRMonitor_refresh_timer / 0.5))
        $slowCounter     = $slowEvery  # trigger slow path immediately on first tick
        # VQR tick counter: incremented once per slow-path tick. Used to gate
        # Invoke-VideoQualityRecommendation so it runs every Nth tick based on
        # the current load tier (1=every tick, 2=every 2nd, 5=every 5th).
        $vqrTickCounter  = 0
        $lastFingerprint = ""
        $lastKioskFingerprint = ""
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

        # Fire service watchdogs eagerly so scrcpy / mediamtx / web server start at the same
        # time as the runspaces, instead of waiting one full slow-tick (~refresh_timer seconds)
        # after the job has finished bootstrapping.
        # ORDER MATTERS: mediamtx MUST be up before Watch-ScrcpyProcesses - the scrcpy
        # pipe pipeline spawns an ffmpeg RTSP publisher a few seconds after scrcpy, and
        # if mediamtx starts (or restarts) after that publish, the session is lost and
        # the ffmpeg pusher goes zombie (stream serves 404 while scrcpy looks healthy).
        try { Start-MediaMtx }         catch { Write-Log ("VRMonitor: mediamtx watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }
        try { Watch-ScrcpyProcesses } catch { Write-Log ("VRMonitor: scrcpy watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }
        try { Start-WebServer }        catch { Write-Log ("VRMonitor: web server watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }

        while ($true) {

            # Cooperative shutdown and parent-process-gone detection
            $shuttingDown = (Test-Path -LiteralPath $shutdownFlagPath) -or
                            (-not (Get-Process -Id $parentPID -ErrorAction SilentlyContinue))
            if ($shuttingDown) {
                if (-not (Test-Path -LiteralPath $shutdownFlagPath)) {
                    Write-Host "VRMonitor: parent process ($parentPID) has exited - signaling reaper"
                    try { New-Item -ItemType File -Path $shutdownFlagPath -Force | Out-Null } catch {}
                } else {
                    Write-Host "VRMonitor: shutdown flag detected, exiting"
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
                # Release the job's own connection last, after every runspace it
                # supervises has released theirs.
                if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
                    try { Close-DbConnection } catch { }
                }
                return
            }

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

            # Fingerprint of key display fields - triggers CSV/HTML write on any change.
            # Keyed on ID (the exported key). Brand/Model/SerialNumber are NOT exported any
            # more but stay in the fingerprint: they gate the Update-HeadsetField write-back
            # and the Set-HeadsetIdentity queueing in the block below.
            $fp = ($knownHeadsetsInfo | ForEach-Object {
                "$($_.ID)|$($_.Ping)|$($_.ADBWifi)|$($_.Battery)|$($_.Charging)|$($_.ChargingWattage)|$($_.Temp)|$($_.BatteryControllerLeft)|$($_.BatteryControllerRight)|$($_.PowerState)|$($_.TimeRemainingMin)|$($_.SCRCPY)|$($_.Brand)|$($_.Model)|$($_.SerialNumber)|$($_.RunningApp)"
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
                            BatteryControllerLeft  = [string](Get-StatusFieldOrDash $info.BatteryControllerLeft)
                            BatteryControllerRight = [string](Get-StatusFieldOrDash $info.BatteryControllerRight)
                            PowerState             = [string](Get-StatusFieldOrDash $info.PowerState)
                            TimeRemainingMin       = [string](Get-StatusFieldOrDash $info.TimeRemainingMin)
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

                    Update-HeadsetMonitoringFile -knownHeadsetsInfo $knownHeadsetsInfo

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

            # ---- SLOW PATH (every refresh_timer seconds) ----
            $slowCounter++
            if ($slowCounter -ge $slowEvery) {
                $slowCounter = 0

                Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null
                $sharedState["_refresh_timer"] = $global:VRMonitor_refresh_timer
                $slowEvery = [Math]::Max(1, [int]($global:VRMonitor_refresh_timer / 0.5))

                Write-Log ($msg.DebugConfigFilePath -f $global:ConfigFilePath) -Level DEBUG
                Write-Log ($msg.DebugKnownHeadsetsPath -f $global:knownHeadsetsFilePath) -Level DEBUG

                $knownHeadsets = @(Get-KnownHeadsets)

                # Guarded like the discovery/companion calls below it: anything that
                # escapes here would abort the rest of the slow tick (service
                # watchdogs, Update-ComputerMonitoring, VQA) for every headset.
                try {
                    Invoke-UsbHeadsetActions | Out-Null
                } catch {
                    Write-Log ("VRMonitor: USB tick failed: " + $_.Exception.Message) -Level WARNING
                }

                # Discover companion apps: heals IP drift silently and returns companion states
                try {
                    if (Get-Command Invoke-CompanionDiscovery -ErrorAction SilentlyContinue) {
                        Invoke-CompanionDiscovery -TimeoutMs 1500 | Out-Null
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

                Sync-HeadsetRunspaces -knownHeadsets $knownHeadsets -runspaceRegistry ([ref]$runspaceRegistry) `
                    -sharedState $sharedState -scriptPath $global:ScriptPath `
                    -configFilePath $global:ConfigFilePath -pollBlock $headsetPollBlock

                try {
                    Sync-KioskRunspaces -runspaceRegistry ([ref]$kioskRunspaceRegistry) `
                        -sharedState $sharedState -scriptPath $global:ScriptPath `
                        -configFilePath $global:ConfigFilePath -pollBlock $kioskPollBlock
                } catch { Write-Log ("VRMonitor: kiosk sync failed: " + $_.Exception.Message) -Level WARNING }

                Update-HeadsetVideoFile
                Update-HeadsetTimerFile
                Sync-RestreamPaths

                # mediamtx before scrcpy watchdog (publisher ordering - see eager block above)
                try { Start-MediaMtx }         catch { Write-Log ("VRMonitor: mediamtx watchdog failed: " + $_.Exception.Message) -Level WARNING }
                try { Watch-ScrcpyProcesses } catch { Write-Log ("VRMonitor: scrcpy watchdog failed: " + $_.Exception.Message) -Level WARNING }
                try { Start-WebServer }        catch { Write-Log ("VRMonitor: web server watchdog failed: " + $_.Exception.Message) -Level WARNING }

                Update-ComputerMonitoring

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

                if ($global:VQA_Enabled -and (Get-Command Invoke-VideoQualityRecommendation -ErrorAction SilentlyContinue)) {
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
            }

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
        "BatteryControllerLeft",
        "BatteryControllerRight",
        "PowerState",
        "TimeRemainingMin",
        # No BatteryHistory: the samples are rows in battery_history now
        # (migration 005), written by a trigger on the Battery column above.
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
        BatteryControllerLeft  = "-"
        BatteryControllerRight = "-"
        PowerState       = "-"
        TimeRemainingMin = "-"
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
    $out = @{ Ping = $false; ADBWifi = $false; SCRCPY = "-" }
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

    if ($out.Ping) {
        if ((Test-Port -hostname $IPAddress -port $ADBPort -timeout 400).open) {
            $out.ADBWifi = $true
        }
    }

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
                            if ($cmdLine -match ([regex]::Escape($IPAddress) + "(:$ADBPort)?")) {
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

function Get-HeadsetInfoStage2Identity {
    # Stage 2 (medium): model + serial + battery dumpsys. Requires a connected $Device.
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$knownHeadset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath
    )
    $out = @{
        Brand = ""; Model = "-"; SerialNumber = "-"
        Battery = "-"; Charging = "-"; ChargingWattage = "-"; Temp = "-"
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

        $batteryInfo = Get-HeadsetBatteryStatus -Device $Device -adb $adb -Brand $out.Brand
        if ($batteryInfo) {
            if ($null -ne $batteryInfo.Level)    { $out.Battery  = "$($batteryInfo.Level) %" }
            if ($null -ne $batteryInfo.Charging) { $out.Charging = $batteryInfo.Charging }
            if ($null -ne $batteryInfo.MaxChargingWattageW -and $batteryInfo.Charging -eq $true) { $out.ChargingWattage = "$($batteryInfo.MaxChargingWattageW)" }
            if ($null -ne $batteryInfo.TempC)    { $out.Temp     = $batteryInfo.TempC.ToString("0.0") }
            $out.BatteryControllerLeft  = if ($null -ne $batteryInfo.BatteryControllerLeft)  { "$($batteryInfo.BatteryControllerLeft) %" }  else { "-" }
            $out.BatteryControllerRight = if ($null -ne $batteryInfo.BatteryControllerRight) { "$($batteryInfo.BatteryControllerRight) %" } else { "-" }
        }
    } catch {
        Write-Log -Message ($msg.AdbInfoFailed -f $knownHeadset.IPAddress, $_) -Level "ERROR"
    }
    return $out
}

function Get-HeadsetInfoStage3App {
    # Stage 3 (slowest): foreground app + display-name/icon resolution.
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$knownHeadset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath
    )
    $out = @{ RunningApp = "-"; RunningAppIcon = "" }
    try {
        $pkg = Get-HeadsetForegroundApp -Device $Device -adb $adb
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

    $device = Get-AdbWifiDevice -headsetIP $knownHeadset.IPAddress -AdbPort $ADBPort -adb $adb
    if (-not $device) {
        $result.ADBWifi = $false
        return $result
    }

    $s2 = Get-HeadsetInfoStage2Identity -knownHeadset $knownHeadset -Device $device -adb $adb
    foreach ($k in $s2.Keys) { $result.$k = $s2[$k] }

    $s3 = Get-HeadsetInfoStage3App -knownHeadset $knownHeadset -Device $device -adb $adb
    foreach ($k in $s3.Keys) { $result.$k = $s3[$k] }

    return $result
}
