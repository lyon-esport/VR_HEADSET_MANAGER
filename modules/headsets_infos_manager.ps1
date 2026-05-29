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

# Start a job that runs every 10s, and fill the details file 
function Start-VRMonitor {
  param (
        $VRMonitor_refresh_timer = 15 ,
        $jobName = "VRMonitor"
    )
    Stop-VRMonitor $jobName
    Start-Job -Name $jobName -ScriptBlock {
        # INIT OF ALL VARIABLES GRAB FROM THE MAIN SCRIPT ($using)
        $global:ScriptPath              = $using:ScriptPath
        $global:ConfigFilePath          = $using:ConfigFilePath
        $global:logFolder               = $using:logFolder
        $global:logFile                 = $using:logFile
        $global:VRMonitor_refresh_timer = $using:VRMonitor_refresh_timer

        $i=1
        # Hashtable: IP -> serialized history string, persists across loop iterations
        $script:batteryHistory = @{}
        # Pre-load history from existing CSV so estimates survive VRMonitor restarts
        if (Test-Path -LiteralPath $global:knownHeadsetsInfosFilePath) {
            try {
                $prevCsv = Import-Csv -LiteralPath $global:knownHeadsetsInfosFilePath -Delimiter ";"
                foreach ($row in $prevCsv) {
                    if ($row.IPAddress -and $row.BatteryHistory) {
                        $script:batteryHistory[$row.IPAddress] = $row.BatteryHistory
                    }
                }
            } catch {}
        }

        #Keep write-host for display to job output
        Write-Host "Starting VRMonitor global:ConfigFilePath = $($global:ConfigFilePath)" -ForegroundColor Magenta

        $global:IsVRMonitorJob = $true
        while($true) {
            #IMPORT ALL FUNCITONS...
            $scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
            if (Test-Path -Path $scripts_init) {
                . $scripts_init
            } else {
                #Keep write-host for display to job output
                Write-Host "Error: The module initialization script was not found!" -ForegroundColor Red
                exit
            }

            
            Write-Log ($msg.JobStarting -f $jobName, $i) -Level DEBUG
            $i++

            Get-Config -ConfigFilePath $global:ConfigFilePath
            
            Write-Log ($msg.DebugConfigFilePath -f $global:ConfigFilePath) -Level DEBUG
            Write-Log ($msg.DebugKnownHeadsetsPath -f $global:knownHeadsetsFilePath) -Level DEBUG
            Write-Log ($msg.DebugKnownHeadsetsInfosPath -f $global:knownHeadsetsInfosFilePath) -Level DEBUG
            
            
            # Check Headstets
            if (Test-Path -LiteralPath $global:knownHeadsetsFilePath){
                $knownHeadsets = @(Import-Csv -LiteralPath $global:knownHeadsetsFilePath)
            }

            $knownHeadsetsInfo = [System.Collections.ArrayList]@()

            # Run background actions on any USB-connected headset (no prompts)
            Invoke-UsbHeadsetActions | Out-Null

            Write-Log ($msg.CheckingHeadsets -f $knownHeadsets.Count) -Level DEBUG
            foreach ($headset in $knownHeadsets){
                $headsetInfo = Get-KnownHeadsetInfos -knownHeadset $headset
                $knownHeadsetsInfo += $headsetInfo

                # Update Model in known_headsets.csv if ADB is reachable and the value has changed
                $fetchedModel = $headsetInfo.Model
                if ((ConvertTo-BoolField $headsetInfo.ADBWifi) `
                    -and -not [string]::IsNullOrWhiteSpace($fetchedModel) `
                    -and $fetchedModel -ne "-" `
                    -and $fetchedModel -ne $headset.Model) {
                    Write-Log ($msg.UpdatingModel -f $headset.Name, $headset.IPAddress, $fetchedModel) -Level INFO
                    Update-HeadsetField -ID $headset.ID -Field "Model" -NewValue $fetchedModel
                }

                # Update SerialNumber in known_headsets.csv if ADB is reachable and the value has changed
                $fetchedSerial = $headsetInfo.SerialNumber
                if ((ConvertTo-BoolField $headsetInfo.ADBWifi) `
                    -and -not [string]::IsNullOrWhiteSpace($fetchedSerial) `
                    -and $fetchedSerial -ne "-" `
                    -and $fetchedSerial -ne $headset.SerialNumber) {
                    Write-Log ($msg.UpdatingSerialNumber -f $headset.Name, $headset.IPAddress, $fetchedSerial) -Level INFO
                    Update-HeadsetField -ID $headset.ID -Field "SerialNumber" -NewValue $fetchedSerial
                }

                if (ConvertTo-BoolField $headsetInfo.ADBWifi) {
                    $device = Get-AdbWifiDevice -headsetIP $headset.IPAddress
                    if ($device) { Update-InstalledAppsCache -Device $device -headsetName $headset.Name }
                }

                # Battery history tracking and time estimate
                $ip = $headset.IPAddress
                if ((ConvertTo-BoolField $headsetInfo.ADBWifi) -and $headsetInfo.Battery -ne "-") {
                    $currentLevel = [int]($headsetInfo.Battery -replace ' %','')
                    $nowStr       = [datetime]::Now.ToString("yyyy-MM-ddTHH:mm:ss")
                    $newEntry     = "$nowStr=$currentLevel"

                    # Append new reading only if battery % changed since last recorded entry
                    $prevHistory = if ($script:batteryHistory.ContainsKey($ip)) { $script:batteryHistory[$ip] } else { "" }
                    $allEntries  = @($prevHistory -split '\|' | Where-Object { $_ -match '=' })
                    $lastLevel   = if ($allEntries.Count -gt 0) { [int](($allEntries[-1] -split '=')[1]) } else { -1 }
                    if ($currentLevel -ne $lastLevel) { $allEntries += $newEntry }
                    $updatedHistory = ($allEntries | Select-Object -Last 3) -join '|'

                    $script:batteryHistory[$ip] = $updatedHistory
                    $headsetInfo.BatteryHistory  = $updatedHistory

                    $estimate = Get-BatteryTimeEstimate -HistoryString $updatedHistory
                    if ($null -ne $estimate.PowerState) {
                        $headsetInfo.PowerState = $estimate.PowerState
                        Write-Log ($msg.BatteryPowerState -f $headset.Name, $headsetInfo.PowerState) -Level DEBUG
                    }
                    $headsetInfo.TimeRemainingMin = if ($null -ne $estimate.MinutesRemaining) { $estimate.MinutesRemaining } else { "-" }
                }

            }

            Write-Log ($msg.JobInfoCollected -f $knownHeadsetsInfo.Count) -Level DEBUG
            # Export vers CSV (exclude internal fields prefixed with _)
            $knownHeadsetsInfo |
                Export-Csv -Path $global:knownHeadsetsInfosFilePath -Delimiter ";" -Encoding UTF8 -NoTypeInformation
            
            # Update headset monitoring status files
            Update-HeadsetMonitoringFile -knownHeadsetsInfo $knownHeadsetsInfo

            # Update headset video HTML files (WHEP player per headset, static - only changes when headset list changes)
            Update-HeadsetVideoFile -knownHeadsetsInfo $knownHeadsetsInfo

            # Sync mediamtx restream paths with current headsets
            Sync-RestreamPaths

            Write-Log ($msg.JobRestartsIn -f $jobName, $VRMonitor_refresh_timer) -Level DEBUG
           
            Start-Sleep -Seconds $VRMonitor_refresh_timer
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
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $pingReply = $ping.Send($knownHeadset.IPAddress, $PingTimeout)
        $result.Ping = $pingReply.Status -eq "Success"
        
        if (-not $result.Ping) {
            return $result
        }
    }
    catch {
        return $result
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
                    $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)").CommandLine
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
