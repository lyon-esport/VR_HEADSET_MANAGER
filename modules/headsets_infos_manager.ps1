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

        #Keep write-host for display to job output
        Write-Host "Starting VRMonitor global:ConfigFilePath = $($global:ConfigFilePath)" -ForegroundColor Magenta 
        
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
            if (Test-Path -Path $global:knownHeadsetsFilePath){
                $knownHeadsets = @(Import-Csv -Path $global:knownHeadsetsFilePath)
            }

            $knownHeadsetsInfo = [System.Collections.ArrayList]@()

            Write-Log ($msg.CheckingHeadsets -f $knownHeadsets.Count) -Level DEBUG
            foreach ($headset in $knownHeadsets){
                $headsetInfo = Get-KnownHeadsetInfos -knownHeadset $headset
                $knownHeadsetsInfo += $headsetInfo

                # Update Model in known_headsets.csv if ADB is reachable and the value has changed
                $fetchedModel = $headsetInfo.Model
                if ($headsetInfo.ADBWifi -eq $true `
                    -and -not [string]::IsNullOrWhiteSpace($fetchedModel) `
                    -and $fetchedModel -ne "-" `
                    -and $fetchedModel -ne $headset.Model) {
                    Write-Log ($msg.UpdatingModel -f $headset.Name, $headset.IPAddress, $fetchedModel) -Level INFO
                    Update-HeadsetField -ID $headset.ID -Field "Model" -NewValue $fetchedModel
                }

                # Update SerialNumber in known_headsets.csv if ADB is reachable and the value has changed
                $fetchedSerial = $headsetInfo.SerialNumber
                if ($headsetInfo.ADBWifi -eq $true `
                    -and -not [string]::IsNullOrWhiteSpace($fetchedSerial) `
                    -and $fetchedSerial -ne "-" `
                    -and $fetchedSerial -ne $headset.SerialNumber) {
                    Write-Log ($msg.UpdatingSerialNumber -f $headset.Name, $headset.IPAddress, $fetchedSerial) -Level INFO
                    Update-HeadsetField -ID $headset.ID -Field "SerialNumber" -NewValue $fetchedSerial
                }


            }

            Write-Log ($msg.JobInfoCollected -f $knownHeadsetsInfo.Count) -Level INFO
            # Export vers CSV
            $knownHeadsetsInfo | Export-Csv -Path $global:knownHeadsetsInfosFilePath -Delimiter ";" -Encoding UTF8 -NoTypeInformation
            
            # Update OBS status file
            Update-OBSFile -knownHeadsetsInfo $knownHeadsetsInfo

            # Update OBS video HTML files (WHEP player per headset, static - only changes when headset list changes)
            Update-OBSVideoFile -knownHeadsetsInfo $knownHeadsetsInfo

            # Sync mediamtx restream paths with current headsets
            Sync-RestreamPaths

            Write-Log ($msg.JobRestartsIn -f $jobName, $VRMonitor_refresh_timer) -Level INFO
           
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
        SCRCPY          = "-"
        Model           = "-"
        SerialNumber    = "-"
        RunningApp      = "-"
        RunningAppIcon  = ""
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
        # Connect to device
        & $adb connect "${IPAddress}:$ADBPort" | Out-Null
        
        # Get device model - If it takes too long, it will timeout and go to catch
        
        $model = & $adb -s "${IPAddress}:$ADBPort" shell "getprop ro.product.model"
        if ($model) { $result.Model = $model.Trim() }
        
        # Get serial number
        $serial = & $adb -s "${IPAddress}:$ADBPort" shell "getprop ro.serialno" 
        if ($serial) { $result.SerialNumber = $serial.Trim() }
        
        # Get battery info (headset + controllers)
        $batteryInfo = Get-HeadsetBatteryStatus -headsetIP $IPAddress -adb $adb -AdbPort $ADBPort
        if ($batteryInfo) {
            if ($null -ne $batteryInfo.Level)    { $result.Battery  = "$($batteryInfo.Level) %" }
            if ($null -ne $batteryInfo.Charging) { $result.Charging = $batteryInfo.Charging }
            if ($null -ne $batteryInfo.MaxChargingWattageW -and $batteryInfo.Charging -eq $true) { $result.ChargingWattage = "$($batteryInfo.MaxChargingWattageW)" }
            if ($null -ne $batteryInfo.TempC)    { $result.Temp     = $batteryInfo.TempC.ToString("0.0") }
            $result.BatteryControllerLeft  = if ($null -ne $batteryInfo.BatteryControllerLeft)  { "$($batteryInfo.BatteryControllerLeft) %" }  else { "-" }
            $result.BatteryControllerRight = if ($null -ne $batteryInfo.BatteryControllerRight) { "$($batteryInfo.BatteryControllerRight) %" } else { "-" }
        }
        # Get running app
        $pkg = Get-HeadsetForegroundApp -headsetIP $IPAddress -adb $adb -AdbPort $ADBPort
        if ($pkg) {
            $appInfo = Get-AppDisplayName -PackageName $pkg
            $result.RunningApp   = $appInfo.DisplayName
            $result.RunningAppIcon = $appInfo.IconUrl
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
                    if ($cmdLine -match "$IPAddress(:$ADBPort)?") {
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

