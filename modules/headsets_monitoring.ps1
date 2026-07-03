#################
# MANAGE DETAILED INFOS OF KNOWN HEADSETS
#################

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
    $currentIPs = @($knownHeadsets | ForEach-Object { $_.IPAddress })

    foreach ($ip in @($runspaceRegistry.Value.Keys)) {
        if ($ip -notin $currentIPs) {
            $sharedState["_stop_$ip"] = $true
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $runspaceRegistry.Value[$ip].Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            try { $runspaceRegistry.Value[$ip].PS.Dispose() }       catch {}
            try { $runspaceRegistry.Value[$ip].Runspace.Dispose() } catch {}
            $runspaceRegistry.Value.Remove($ip)
            $sharedState.Remove("_stop_$ip")
            $sharedState.Remove($ip)
            Write-Log ("VRMonitor: stopped runspace for $ip") -Level INFO
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
            $runspaceRegistry.Value[$headset.IPAddress] = Start-HeadsetRunspace `
                -headset $headset -sharedState $sharedState `
                -scriptPath $scriptPath -configFilePath $configFilePath -pollBlock $pollBlock
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
            foreach ($mod in @("logging.ps1","config_files_loader.ps1","utils.ps1","network_scanner.ps1","adb_functions.ps1","headsets_monitoring.ps1")) {
                $f = Join-Path $modPath $mod
                if (Test-Path -LiteralPath $f) { . $f }
            }
            Get-Config -ConfigFilePath $configFilePath

            # Load translations so $msg.* calls in functions do not throw
            $transFolder = Join-Path $scriptPath "modules\translations"
            $transFile   = Join-Path $transFolder "$($global:SelectedLanguage).psd1"
            if (-not (Test-Path -LiteralPath $transFile)) { $transFile = Join-Path $transFolder "en-US.psd1" }
            if (Test-Path -LiteralPath $transFile) { $global:msg = Import-PowerShellDataFile -Path $transFile }

            $ip      = $headset.IPAddress
            $stopKey = "_stop_$ip"

            # Pre-load battery history from existing CSV so time-remaining estimates survive restarts
            $localBattHistory = ""
            if (Test-Path -LiteralPath $global:knownHeadsetsInfosFilePath) {
                try {
                    $row = Import-Csv -LiteralPath $global:knownHeadsetsInfosFilePath -Delimiter ";" |
                           Where-Object { $_.IPAddress -eq $ip } | Select-Object -First 1
                    if ($row -and $row.BatteryHistory) { $localBattHistory = $row.BatteryHistory }
                } catch {}
            }

            # Progressive publishing only on the very first cycle (fast initial UX);
            # subsequent cycles build the full record locally then publish atomically once
            # so the dashboard never renders a half-filled row.
            $firstCycle = $true
            # Installed-apps cache is heavy (dumpsys package list + per-app sizes) and not
            # latency-critical. Refresh on first cycle, then every N cycles afterward.
            $appsCacheEvery   = 100
            $appsCacheCounter = 0

            while ($true) {
                if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }

                try {
                    $headsetInfo = New-DefaultHeadsetInfo -knownHeadset $headset

                    # --- Stage 1: reachability ---
                    $s1 = Get-HeadsetInfoStage1Reachability -knownHeadset $headset
                    foreach ($k in $s1.Keys) { $headsetInfo.$k = $s1[$k] }
                    if ($firstCycle) { $sharedState[$ip] = $headsetInfo }

                    if ($headsetInfo.ADBWifi) {
                        $device = Get-AdbWifiDevice -headsetIP $ip
                        if (-not $device) {
                            $headsetInfo.ADBWifi = $false
                        } else {
                            # --- Stage 2: identity + battery ---
                            $s2 = Get-HeadsetInfoStage2Identity -knownHeadset $headset -Device $device
                            foreach ($k in $s2.Keys) { $headsetInfo.$k = $s2[$k] }

                            # Battery history + time estimate (local var persists across cycles)
                            if ($headsetInfo.Battery -ne "-") {
                                $currentLevel = [int]($headsetInfo.Battery -replace ' %','')
                                $allEntries   = @($localBattHistory -split '\|' | Where-Object { $_ -match '=' })
                                $lastLevel    = if ($allEntries.Count -gt 0) { [int](($allEntries[-1] -split '=')[1]) } else { -1 }
                                if ($currentLevel -ne $lastLevel) { $allEntries += "$([datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss'))=$currentLevel" }
                                $localBattHistory           = ($allEntries | Select-Object -Last 3) -join '|'
                                $headsetInfo.BatteryHistory = $localBattHistory
                                $estimate = Get-BatteryTimeEstimate -HistoryString $localBattHistory
                                if ($null -ne $estimate.PowerState)       { $headsetInfo.PowerState = $estimate.PowerState }
                                $headsetInfo.TimeRemainingMin = if ($null -ne $estimate.MinutesRemaining) { $estimate.MinutesRemaining } else { "-" }
                            }
                            if ($firstCycle) { $sharedState[$ip] = $headsetInfo }

                            # --- Stage 3: foreground app + installed-apps cache ---
                            $s3 = Get-HeadsetInfoStage3App -knownHeadset $headset -Device $device
                            foreach ($k in $s3.Keys) { $headsetInfo.$k = $s3[$k] }
                            if ($firstCycle -or ($appsCacheCounter % $appsCacheEvery -eq 0)) {
                                Update-InstalledAppsCache -Device $device -headsetName $headset.Name
                            }
                            $appsCacheCounter++
                        }
                    }

                    # Final atomic publish (every cycle, including first)
                    $sharedState[$ip] = $headsetInfo
                    $firstCycle = $false
                } catch {
                    Write-Log ("VRMonitor[" + $ip + "]: poll cycle failed: " + $_.Exception.Message) -Level WARNING
                }

                # Sleep refresh_timer seconds with per-second stop-flag checks
                $timer = if ($sharedState["_refresh_timer"]) { [int]$sharedState["_refresh_timer"] } else { 5 }
                for ($s = 0; $s -lt $timer; $s++) {
                    Start-Sleep -Seconds 1
                    if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }
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
        $knownHeadsets   = @()

        # Eager first load + immediate runspace start so the first real poll lands within
        # a few seconds of job start instead of waiting one full slow-tick.
        if (Test-Path -LiteralPath $global:knownHeadsetsFilePath) {
            $knownHeadsets = @(Import-Csv -LiteralPath $global:knownHeadsetsFilePath)
        }
        if ($knownHeadsets.Count -gt 0) {
            Sync-HeadsetRunspaces -knownHeadsets $knownHeadsets -runspaceRegistry ([ref]$runspaceRegistry) `
                -sharedState $sharedState -scriptPath $global:ScriptPath `
                -configFilePath $global:ConfigFilePath -pollBlock $headsetPollBlock
        }

        # Fire service watchdogs eagerly so scrcpy / mediamtx / web server start at the same
        # time as the runspaces, instead of waiting one full slow-tick (~refresh_timer seconds)
        # after the job has finished bootstrapping.
        try { Watch-ScrcpyProcesses } catch { Write-Log ("VRMonitor: scrcpy watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }
        try { Start-MediaMtx }         catch { Write-Log ("VRMonitor: mediamtx watchdog (eager) failed: " + $_.Exception.Message) -Level WARNING }
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
                return
            }

            # ---- FAST PATH (every 500ms) ----
            # Build knownHeadsetsInfo from sharedState; use a default placeholder until first poll
            $knownHeadsetsInfo = [System.Collections.ArrayList]@()
            foreach ($h in $knownHeadsets) {
                $info = $sharedState[$h.IPAddress]
                if ($info) {
                    [void]$knownHeadsetsInfo.Add($info)
                } else {
                    [void]$knownHeadsetsInfo.Add((New-DefaultHeadsetInfo -knownHeadset $h))
                }
            }

            # Fingerprint of key display fields - triggers CSV/HTML write on any change
            $fp = ($knownHeadsetsInfo | ForEach-Object {
                "$($_.IPAddress)|$($_.Ping)|$($_.ADBWifi)|$($_.Battery)|$($_.Charging)|$($_.ChargingWattage)|$($_.Temp)|$($_.BatteryControllerLeft)|$($_.BatteryControllerRight)|$($_.PowerState)|$($_.TimeRemainingMin)|$($_.SCRCPY)|$($_.Brand)|$($_.Model)|$($_.SerialNumber)|$($_.RunningApp)"
            }) -join '~'

            if ($fp -ne $lastFingerprint -and $knownHeadsets.Count -gt 0) {
                $lastFingerprint = $fp

                # Model/Serial CSV updates must be serialized in the main thread
                foreach ($headsetInfo in $knownHeadsetsInfo) {
                    $headset = $knownHeadsets | Where-Object { $_.ID -eq $headsetInfo.ID } | Select-Object -First 1
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
                    $fetchedSerial = $headsetInfo.SerialNumber
                    if ((ConvertTo-BoolField $headsetInfo.ADBWifi) `
                        -and -not [string]::IsNullOrWhiteSpace($fetchedSerial) `
                        -and $fetchedSerial -ne "-" -and $fetchedSerial -ne $headset.SerialNumber) {
                        Write-Log ($msg.UpdatingSerialNumber -f $headset.Name, $headset.IPAddress, $fetchedSerial) -Level INFO
                        Update-HeadsetField -ID $headset.ID -Field "SerialNumber" -NewValue $fetchedSerial
                    }
                }

                $knownHeadsetsInfo |
                    Export-Csv -Path $global:knownHeadsetsInfosFilePath -Delimiter ";" -Encoding UTF8 -NoTypeInformation

                Update-HeadsetMonitoringFile -knownHeadsetsInfo $knownHeadsetsInfo

                Write-Log ($msg.JobInfoCollected -f $knownHeadsetsInfo.Count) -Level DEBUG
            }

            # ---- SLOW PATH (every refresh_timer seconds) ----
            $slowCounter++
            if ($slowCounter -ge $slowEvery) {
                $slowCounter = 0

                Get-Config -ConfigFilePath $global:ConfigFilePath
                $sharedState["_refresh_timer"] = $global:VRMonitor_refresh_timer
                $slowEvery = [Math]::Max(1, [int]($global:VRMonitor_refresh_timer / 0.5))

                Write-Log ($msg.DebugConfigFilePath -f $global:ConfigFilePath) -Level DEBUG
                Write-Log ($msg.DebugKnownHeadsetsPath -f $global:knownHeadsetsFilePath) -Level DEBUG

                if (Test-Path -LiteralPath $global:knownHeadsetsFilePath) {
                    $knownHeadsets = @(Import-Csv -LiteralPath $global:knownHeadsetsFilePath)
                }

                Invoke-UsbHeadsetActions | Out-Null

                # Discover companion apps: heals IP drift silently and returns companion states
                try {
                    if (Get-Command Invoke-CompanionDiscovery -ErrorAction SilentlyContinue) {
                        Invoke-CompanionDiscovery -TimeoutMs 1500 | Out-Null
                    }
                } catch {
                    Write-Log ("VRMonitor: companion discovery failed: " + $_.Exception.Message) -Level DEBUG
                }

                Sync-HeadsetRunspaces -knownHeadsets $knownHeadsets -runspaceRegistry ([ref]$runspaceRegistry) `
                    -sharedState $sharedState -scriptPath $global:ScriptPath `
                    -configFilePath $global:ConfigFilePath -pollBlock $headsetPollBlock

                Update-HeadsetVideoFile
                Sync-RestreamPaths

                try { Watch-ScrcpyProcesses } catch { Write-Log ("VRMonitor: scrcpy watchdog failed: " + $_.Exception.Message) -Level WARNING }
                try { Start-MediaMtx }         catch { Write-Log ("VRMonitor: mediamtx watchdog failed: " + $_.Exception.Message) -Level WARNING }
                try { Start-WebServer }        catch { Write-Log ("VRMonitor: web server watchdog failed: " + $_.Exception.Message) -Level WARNING }

                Update-ComputerMonitoring

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


function New-DefaultHeadsetInfo {
    # Canonical schema for the per-headset info record stored in $sharedState and exported
    # to known_headsets_infos.csv. Single source of truth - reused by Get-KnownHeadsetInfos
    # and by the main-loop placeholder.
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

    # Local scrcpy process scan (no ADB dependency)
    $scrcpyProcesses = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue
    if ($scrcpyProcesses) {
        foreach ($proc in $scrcpyProcesses) {
            if ($proc.Path -like "$($global:scrcpyFolder)\scrcpy.exe") {
                $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)"
                $cmdLine = $cimProc.CommandLine
                $cimProc.Dispose()
                if ($cmdLine -match ([regex]::Escape($IPAddress) + "(:$ADBPort)?")) {
                    $out.SCRCPY = "OK"
                    break
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
        $bm = Get-HeadsetBrandModel -Device $Device -adb $adb
        if ($bm) {
            if ($bm.Brand) { $out.Brand = $bm.Brand }
            if (-not [string]::IsNullOrWhiteSpace($bm.Model)) { $out.Model = $bm.Model }
        }
        $serial = Invoke-AdbCmd -Device $Device -Command "shell getprop ro.serialno" -adb $adb
        if ($serial) { $out.SerialNumber = ($serial -join '').Trim() }

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
