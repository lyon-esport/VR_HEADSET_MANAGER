
#################
# START SCREEN COPY
#################

<#
start-screenCopy -headsetIP 192.168.1.243 -adbPort 5555 -displayName "Quest 3 Manu"
$headsetIP = "192.168.1.243"
$displayName =  "Quest 3 Manu"
start-screenCopy -displayName $displayName -headsetIP $ip
#>
function start-screenCopy {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,

        [string]$displayName = [string]$headsetIP,

        [boolean]$recording = $false,

        [int]$adbPort = $global:adbPort_default,

        $scrcpyParameters = $global:scrcpyParameters

    )

    $displayName =  Convert-Displayname($displayName)
    $adb = $global:adbPath
    $adb_device = "$headsetIP`:$adbPort"
    $scrcpy = $global:scrcpyFilePath

    if (-not(test-port -hostname $headsetIP -port $adbPort).open){ # Verifie si le port adb est ouvert
        Write-Log -Message "Le port ADB $adbPort ne repond pas => Connectez d'abord le casque en USB et/ou lancez l'application Oculus Wifi ADB" -Level WARNING
        pause
        return
    }

    # Port ADB ouvert, lancement de la connexion au casque
    try {
        Write-Log -Message "Verification de la connexion ADB pour $adb_device" -Level "INFO"

        $connectedDevices = & $adb devices | Select-String $adb_device -AllMatches
        if ($connectedDevices.Matches.Count -lt 1) {
            Write-Log -Message "Aucune connexion ADB active pour $adb_device, tentative de connexion..." -Level "INFO"
            & $adb connect $adb_device | Out-Null
            Start-Sleep -Seconds 2
        }

    } catch {
        Write-Log -Message "Erreur lors de l'execution : $($_.Exception.Message)" -Level "ERROR"
		return
    }
	
	
	$options = ""
    $headsetModel = Get-HeadsetModel $headsetIP
    Write-Log -Message "Modele detecte : $headsetModel" -Level "INFO"
	<#
    if ($adb_model -like "Quest 2") {
		#$options = "--crop=1550:1250:2000:280 --max-size=800 --video-bit-rate=10M --max-fps 60 --video-buffer=50 --video-codec=h265" #Oeil droit
        $options = "-b10m --max-fps 60 --video-buffer=50 --video-codec=h265" #Oeil droit
	} elseif ($adb_model -like "Quest 3") {
		#crop = "1700:1200:250:500"
        #$options = "--crop=1664:1304:2260:450 --angle=-21 --max-size=800 --video-bit-rate=10M --max-fps=30 --video-codec=h265" #  --video-encoder=OMX.qcom.video.encoder.avc " #Oeil droit  --video-buffer=100
        #$options = "-b10m --max-fps=60 --video-codec=h264" #Oeil droit  --video-buffer=100
        $options = " -b20m --max-fps=30 --video-codec=h264 --video-buffer=100" #  --video-encoder=OMX.qcom.video.encoder.avc " #Oeil droit  --video-buffer=100
	}
    #> 
    
    

    if ($scrcpyParameters.$headsetModel){
        $options =  $scrcpyParameters.$headsetModel
    } else {
		Write-Log -Message "Modele non reconnu, aucun recadrage applique." -Level "WARNING"
	}

    # Verifie que scrcpy existe
    if (-not (Test-Path $scrcpy)) {
        Write-Log -Message "scrcpy.exe introuvable a l'emplacement $scrcpyPath" -Level "ERROR"
        return
    }
    
    # Check if recording is enabled
    if ($recording) {
        $timestamp_Today = Get-Date -Format "yyyy-MM-dd"
        $recordFolder = Join-Path -Path $global:scrcpyRecordFolder -ChildPath ("${timestamp_Today}\${displayName}")

        if (-not (Test-Path $recordFolder)) {
            New-Item -ItemType Directory -Path $recordFolder -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $recordFile = Join-Path -Path $recordFolder -ChildPath "${displayName}_$timestamp.mp4"
        $recordOption = "--record=$recordFile"
        Write-Log -Message "Recording active session in $recordFile" -Level "INFO"
    } else {
        $recordOption = ""
    }
    $arguments = "-s $adb_device $options --no-audio --window-title=$displayName $recordOption"
    #.\scrcpy.exe --crop 1664:1304:2260:450 --angle=-21 --max-fps 45 -b 16M --no-audio --video-buffer=100 --video-codec=h264 --video-encoder=OMX.qcom.video.encoder.avc -s $adb_device
    #.\sources\scrcpy-win64-v3.3\scrcpy.exe -s 192.168.1.243:5555 -b20m --crop=1664:1304:2260:450 --angle=-21 --max-size=800 --max-fps=30 --video-codec=h265 --no-audio --window-title=Q3_BLUE
    
	Write-Log -Message "Lancement de scrcpy avec les arguments : $arguments" -Level "INFO"
    try {
        #$process = 
        Start-Process $scrcpy -ArgumentList $arguments -PassThru `
			-RedirectStandardOutput (Join-Path -Path $global:logFolder -ChildPath ($displayName+"_StandardOutput.txt")) `
			-RedirectStandardError  (Join-Path -Path $global:logFolder -ChildPath ($displayName+"_StandardError.txt")) #-WindowStyle hidden

        
	} catch {
        Write-Log -Message "Erreur lors de l'execution de scrcpy : $($_.Exception.Message)" -Level "ERROR"
		return
    }
}




function Watch-ScrcpyProcesses {
    
    # Etape 1 : Recuperation des process scrcpy tournant sur le poste

    $knownHeadsets_with_autorestart = Get-KnownHeadsets | Where-Object { $_.scrcpy_AutoRestart -eq $True }

    $runningScrcpyProcess = @(Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue)
    #$runningScrcpyProcess | Format-List *
    
    # For each headset with autorestart, ensure there's a scrcpy process started

    foreach ($headset in $knownHeadsets_with_autorestart) {
        Write-Log "Checking if the headset is connected and ready to start scrcpy: $($headset.Name) ($($headset.IPAddress))" -Level DEBUG

        if ((Get-KnownHeadsetInfos $headset).ADBWifi -eq $true) {
            write-log "Checking scrcpy process for headset $($headset.Name) ($($headset.IPAddress))" -Level DEBUG
            $runningScrcpyProcess_forThisheadset = $runningScrcpyProcess | Where-Object {$_.MainWindowTitle -eq (Convert-Displayname($headset.Name))}
            
            write-log "Scrcpy process Found for this headset: $($runningScrcpyProcess_forThisheadset)" -Level DEBUG
            if (-not $runningScrcpyProcess_forThisheadset) {
                #Write-Log "No scrcpy process found for headset $($headset.Name) ($($headset.IPAddress)). Starting scrcpy..." -Level INFO
                start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording ($headset.Record -eq "True")
            }
        }
    }
}




function Convert-Displayname {
    param(
             [Parameter(Mandatory=$true)]
             [string]$displayName
        )
    $displayName =  $displayName.replace(" ","_") # convert displayname
    return $displayName
}


function Install-ScrcpyDependencies {
    param (
        [string]$scrcpyFolder
    )
    # Create the scrcpy folder if it doesn't exist
    # scrcpy-server
    if (-not (Test-Path -Path "C:\msys64\mingw64\share\scrcpy\scrcpy-server")) {
        New-Item -Path "C:/msys64/mingw64/share/scrcpy/" -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\scrcpy-server" -Destination "C:\msys64\mingw64\share\scrcpy\" -Force
        Write-Log "Scrcpy server file copied." -Level INFO
    } else {
        #Write-Log "Scrcpy server file already exists." -Level DEBUG
    }
    # scrcpy.png
    $destinationPath = "C:/msys64/mingw64/share/icons/hicolor/256x256/apps/scrcpy.png"
    if (-not (Test-Path -Path $destinationPath)) {
        New-Item -Path ([System.IO.Path]::GetDirectoryName($destinationPath)) -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\icon.png" -Destination $destinationPath -Force
        Write-Log "Scrcpy icon file copied." -Level INFO
    } else {
        #Write-Log "Scrcpy icon file already exists." -Level DEBUG
    }
}
