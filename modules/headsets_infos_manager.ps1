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

        Write-Host "Starting VRMonitor global:ConfigFilePath = $($global:ConfigFilePath)" -ForegroundColor Magenta 
        
        while($true) {
            #IMPORT ALL FUNCITONS...
            $scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
            if (Test-Path -Path $scripts_init) {
                . $scripts_init
            } else {
                Write-Host "Error: The module initialization script was not found!" -ForegroundColor Red
                exit
            }

            
            <#
            $ModulesPath = "$global:ScriptPath\modules"
                if (-not (Test-Path -Path $ModulesPath -PathType Container)) {
                        #Write-Warning "Le dossier des modules n'existe pas : $ModulesPath"
                        return
                }
            $moduleFiles = Get-ChildItem -Path $ModulesPath -Filter "*.ps1" -File
                foreach ($file in $moduleFiles) {
                    try {
                        # On "dot-source" le fichier pour que ses fonctions soient disponibles
                        . $file.FullName
                        #Write-Host "[OK] Module $($file.Name) charge" -ForegroundColor Green
                    }
                    catch {
                        #Write-Host "echec de l'import de $($file.Name) : $_" -BackgroundColor Red -ForegroundColor White
                    }
                }
            #>
            
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
                $knownHeadsetsInfo += Get-KnownHeadsetInfos -knownHeadset $headset
                if ($headset.SerialNumber -ne $knownHeadsetsInfo.SerialNumber){
                    Write-Log ($msg.UpdatingSerialNumber -f $headset.Name, $headset.IPAddress, $knownHeadsetsInfo.SerialNumber) -Level DEBUG
                    Update-HeadsetField -ID $headset.ID -Field "SerialNumber" -NewValue $knownHeadsetsInfo.SerialNumber
                }
            }

            Write-Log ($msg.JobInfoCollected -f $knownHeadsetsInfo.Count) -Level INFO
            # Export vers CSV
            $knownHeadsetsInfo | Export-Csv -Path $global:knownHeadsetsInfosFilePath -Delimiter ";" -Encoding UTF8 -NoTypeInformation
            
            # Update OBS file
            Update-OBSFile -knownHeadsetsInfo $knownHeadsetsInfo #-obsTemplatePath $global:obsTemplatePath -obsOutputPath $global:obsOutputPath


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
        ID            = $knownHeadset.ID
        Name          = $knownHeadset.Name
        IPAddress     = $knownHeadset.IPAddress
        Ping          = $false
        ADBWifi       = $false
        Battery       = "-"
        Charging      = "-"
        Temp          = "-"
        SCRCPY        = "-"
        Model         = "-"
        SerialNumber  = "-"
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
        
        # Get battery info
        $batteryInfo = & $adb -s "${IPAddress}:$ADBPort" shell "dumpsys battery"
        if ($batteryInfo) {
            $level = $batteryInfo | Select-String "level:\s+(\d+)"
            if ($level) { 
                $result.Battery = $level.Matches.Groups[1].Value + " %"
            }
            
            $charging = $batteryInfo | Select-String "AC powered:\s+(\w+)"
            if ($charging) {
                $result.Charging = $charging.Matches.Groups[1].Value -eq "true"
            }
            # Temperature
            $BatteryTemp = $batteryInfo | Select-String "temperature:\s+(\d+)"
            if ($BatteryTemp) {
                $result.Temp = [math]::Round($BatteryTemp.Matches.Groups[1].Value/10, 1).ToString("0.0") #+ "°C"
            }
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

