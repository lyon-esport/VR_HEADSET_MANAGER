#################
# MANAGE DETAILED INFOS OF KNOWN HEADSETS 
#################

function Test-VRMonitor {

    $job = Get-Job -Name "VRMonitor" 
    Receive-Job -Job $job


    # 2. Stopper le job (si en cours)
    if ($job.State -eq "Running") {
        Stop-Job -Job $job
    }

    # 3. Récupérer les derniers résultats (optionnel)
    $results = Receive-Job -Job $job
    Write-Host $results 
    # 4. Supprimer le job
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
        Write-Log "Job $jobName not found --> Don't need to kill it" -Level INFO
        return $true
    }
    
    if ($job){
        try {
            Stop-Job -Job $job -ErrorAction Stop
            Remove-Job -Job $job -ErrorAction Stop
        }
        catch {
            Write-Log "Job $jobName cannot be stopped" -Level ERROR
            return $false
        }
        
        Write-Log "Job $jobName [ID $($job.ID)] stopped" -Level INFO
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
                Write-Host "Erreur: Le script d'initialisation des modules est introuvable !" -ForegroundColor Red
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
            
            Write-Log "Starting Job $jobName (cycle $i)" DEBUG
            $i++

            Get-Config -ConfigFilePath $global:ConfigFilePath
            
            Write-Log "ConfigFilePath : $($global:ConfigFilePath)" DEBUG
            Write-Log "knownHeadsetsFilePath : $($global:knownHeadsetsFilePath)" DEBUG
            Write-Log "knownHeadsetsInfosFilePath : $($global:knownHeadsetsInfosFilePath)" DEBUG
            
            
            # Check Headstets
            if (Test-Path -Path $global:knownHeadsetsFilePath){
                $knownHeadsets = @(Import-Csv -Path $global:knownHeadsetsFilePath)
            }

            $knownHeadsetsInfo = [System.Collections.ArrayList]@()

            Write-Log "Check for $($knownHeadsets.Count) headsets" DEBUG
            foreach ($headset in $knownHeadsets){
                $knownHeadsetsInfo += Get-KnownHeadsetInfos -knownHeadset $headset
                if ($headset.SerialNumber -ne $knownHeadsetsInfo.SerialNumber){
                    Write-Log "Updating SerialNumber for $($headset.Name) ($($headset.IPAddress)) to $($knownHeadsetsInfo.SerialNumber)" DEBUG
                    Update-HeadsetField -ID $headset.ID -Field "SerialNumber" -NewValue $knownHeadsetsInfo.SerialNumber
                }
            }

            Write-Log "JOB - Detailed info collected for $($knownHeadsetsInfo.Count) headsets" INFO
            # Export vers CSV
            $knownHeadsetsInfo | Export-Csv -Path $global:knownHeadsetsInfosFilePath -Delimiter ";" -Encoding UTF8 -NoTypeInformation
            
            # Update OBS file
            Update-OBSFile -knownHeadsetsInfo $knownHeadsetsInfo #-obsTemplatePath $global:obsTemplatePath -obsOutputPath $global:obsOutputPath


            Write-Log "JOB $jobName - Restarts in $VRMonitor_refresh_timer sec" -Level INFO
           
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
            Write-Log "Found $($scrcpyProcesses.Count) scrcpy processes" DEBUG 
            foreach ($proc in $scrcpyProcesses) {
                Write-Log "Checking scrcpy process ID $($proc.Id) at path $($proc.Path)" DEBUG
                if ($proc.Path -like "$($global:scrcpyFolder)\scrcpy.exe") {
                    $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)").CommandLine
                    write-log "Found scrcpy process with command line: $cmdLine" DEBUG
                    write-log "Looking for IPAddress: $IPAddress and ADBPort: $ADBPort" DEBUG
                    if ($cmdLine -match "$IPAddress(:$ADBPort)?") {
                        $result.SCRCPY = "OK"
                        Write-Log "scrcpy is running for $($knownHeadset.Name) ($IPAddress)" DEBUG
                        break
                    }
                }
            }
        }
    }
    catch {
        Write-Log -Message "Failed to get ADB info for $IPAddress : $_" -Level "ERROR"
    }
    finally {
        # Disconnect ADB
        #& $adb disconnect "${IPAddress}:$ADBPort" | Out-Null
    }
    
    return $result
}

