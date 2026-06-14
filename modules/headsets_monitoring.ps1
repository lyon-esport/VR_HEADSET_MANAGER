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

            while ($true) {
                if ($sharedState["_stop_all"] -or $sharedState[$stopKey]) { return }

                $headsetInfo = Get-KnownHeadsetInfos -knownHeadset $headset

                # Battery history and time estimate (local variable persists across runspace cycles)
                if ((ConvertTo-BoolField $headsetInfo.ADBWifi) -and $headsetInfo.Battery -ne "-") {
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

                # Installed apps cache (per-headset file - safe to write from runspace)
                if (ConvertTo-BoolField $headsetInfo.ADBWifi) {
                    $device = Get-AdbWifiDevice -headsetIP $ip
                    if ($device) { Update-InstalledAppsCache -Device $device -headsetName $headset.Name }
                }

                $sharedState[$ip] = $headsetInfo

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
                    [void]$knownHeadsetsInfo.Add([PSCustomObject]@{
                        ID="$($h.ID)"; Name=$h.Name; IPAddress=$h.IPAddress
                        Ping=$false; ADBWifi=$false; Battery="-"; Charging="-"; ChargingWattage="-"
                        Temp="-"; BatteryControllerLeft="-"; BatteryControllerRight="-"
                        PowerState="-"; TimeRemainingMin="-"; BatteryHistory=""
                        SCRCPY="-"; Model="-"; SerialNumber="-"; RunningApp="-"; RunningAppIcon=""
                    })
                }
            }

            # Fingerprint of key display fields - triggers CSV/HTML write on any change
            $fp = ($knownHeadsetsInfo | ForEach-Object {
                "$($_.IPAddress)|$($_.Battery)|$($_.Charging)|$($_.Ping)|$($_.ADBWifi)|$($_.SCRCPY)|$($_.RunningApp)|$($_.Temp)"
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


function Get-KnownHeadsetInfos {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$knownHeadset,

        [int]$ADBPort = 5555,

        [int]$PingTimeout = 1000,

        [string]$adb = $global:adbPath
    )


    #$result = @()
    $result = [PSCustomObject]@{
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
        Model            = "-"
        SerialNumber     = "-"
        RunningApp       = "-"
        RunningAppIcon   = ""
    }
    $IPAddress = $knownHeadset.IPAddress

    # 1. Test ping
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $pingReply = $ping.Send($knownHeadset.IPAddress, $PingTimeout)
        $result.Ping = $pingReply.Status -eq "Success"

        if (-not $result.Ping) {
            return $result
        }
    }
    catch {
        return $result
    }
    finally {
        $ping.Dispose()
    }

    # 2. Check ADB port
    if (-not (Test-Port -hostname $IPAddress -port $ADBPort -timeout 400).open) {
        return $result
    }
    $result.ADBWifi = $true

    # 3. Get device info via ADB
    try {
        # Connect to device and get a device object for subsequent calls
        $device = Get-AdbWifiDevice -headsetIP $IPAddress -AdbPort $ADBPort -adb $adb
        if (-not $device) {
            $result.ADBWifi = $false
            return $result
        }

        # Get device model
        $model = Invoke-AdbCmd -Device $device -Command "shell getprop ro.product.model" -adb $adb
        if ($model) { $result.Model = ($model -join '').Trim() }

        # Get serial number
        $serial = Invoke-AdbCmd -Device $device -Command "shell getprop ro.serialno" -adb $adb
        if ($serial) { $result.SerialNumber = ($serial -join '').Trim() }

        # Get battery info (headset + controllers)
        $batteryInfo = Get-HeadsetBatteryStatus -Device $device -adb $adb
        if ($batteryInfo) {
            if ($null -ne $batteryInfo.Level)    { $result.Battery  = "$($batteryInfo.Level) %" }
            if ($null -ne $batteryInfo.Charging) { $result.Charging = $batteryInfo.Charging }
            if ($null -ne $batteryInfo.MaxChargingWattageW -and $batteryInfo.Charging -eq $true) { $result.ChargingWattage = "$($batteryInfo.MaxChargingWattageW)" }
            if ($null -ne $batteryInfo.TempC)    { $result.Temp     = $batteryInfo.TempC.ToString("0.0") }
            $result.BatteryControllerLeft  = if ($null -ne $batteryInfo.BatteryControllerLeft)  { "$($batteryInfo.BatteryControllerLeft) %" }  else { "-" }
            $result.BatteryControllerRight = if ($null -ne $batteryInfo.BatteryControllerRight) { "$($batteryInfo.BatteryControllerRight) %" } else { "-" }
        }
        # Get running app
        $pkg = Get-HeadsetForegroundApp -Device $device -adb $adb
        if ($pkg) {
            $appInfo = Get-AppInfo -PackageName $pkg -searchOnline $false
            $result.RunningApp   = if ($appInfo.DisplayName) { $appInfo.DisplayName } else { $pkg }
            $result.RunningAppIcon = if ($appInfo.LocalIconPath) { $appInfo.LocalIconPath } elseif ($appInfo.IconUrl) { $appInfo.IconUrl } else { "" }
        }

        # Check if scrcpy is running
        $scrcpyProcesses = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue
        if ($scrcpyProcesses) {
            Write-Log ($msg.ScrcpyProcessesFound -f $scrcpyProcesses.Count) -Level DEBUG
            foreach ($proc in $scrcpyProcesses) {
                Write-Log ($msg.ScrcpyProcessChecking -f $proc.Id, $proc.Path) -Level DEBUG
                if ($proc.Path -like "$($global:scrcpyFolder)\scrcpy.exe") {
                    $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)"
                    $cmdLine = $cimProc.CommandLine
                    $cimProc.Dispose()
                    Write-Log ($msg.ScrcpyProcessCmdLine -f $cmdLine) -Level DEBUG
                    Write-Log ($msg.ScrcpyLookingFor -f $IPAddress, $ADBPort) -Level DEBUG
                    if ($cmdLine -match ([regex]::Escape($IPAddress) + "(:$ADBPort)?")) {
                        $result.SCRCPY = "OK"
                        Write-Log ($msg.ScrcpyRunningFor -f $knownHeadset.Name, $IPAddress) -Level DEBUG
                        break
                    }
                }
            }
        }
    }
    catch {
        Write-Log -Message ($msg.AdbInfoFailed -f $IPAddress, $_) -Level "ERROR"
    }
    finally {
        # Disconnect ADB
        #& $adb disconnect "${IPAddress}:$ADBPort" | Out-Null
    }

    return $result
}
