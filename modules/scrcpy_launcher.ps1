
#################
# START SCREEN COPY
#################

<#
start-screenCopy -headsetIP 192.168.1.243 -adbPort 5555 -displayName "Quest 3 Manu"
$headsetIP = "192.168.1.243"
$displayName =  "Quest 3 Manu"
start-screenCopy -displayName $displayName -headsetIP $ip
#>

# Build the scrcpy argument string from a model template (config.json) and a per-headset profile.
# Profile format: [L/R]-[D/N]-FPS-BW  e.g. "R-N-45-20"
#   L/R = Left or Right eye  (selects crop + angle from model template)
#   D/N = audio-dup or no-audio
#   FPS = max-fps value
#   BW  = bitrate in Mbps
function ConvertTo-ScrcpyArguments {
    param(
        [string]$headsetModel,
        [string]$scrcpyProfile = "R-N-45-20",
        $modelTemplate = $null
    )

    if ([string]::IsNullOrWhiteSpace($scrcpyProfile)) { $scrcpyProfile = "R-N-45-20" }
    $parts = $scrcpyProfile -split '-'
    if ($parts.Count -ne 4) {
        Write-Log ($msg.ScrcpyInvalidProfile -f $scrcpyProfile) -Level WARNING
        $parts = @('R', 'N', '45', '20')
    }
    $eye       = $parts[0].ToUpper()  # L or R
    $audioPref = $parts[1].ToUpper()  # D=audio-dup, N=no-audio
    $fps       = $parts[2]            # e.g. 45
    $bw        = $parts[3]            # e.g. 20 (Mbps)

    if ($null -eq $modelTemplate) {
        $modelTemplate = $global:scrcpyParameters.$headsetModel
    }

    $audioArg = if ($audioPref -eq 'D') { "--audio-dup" } else { "--no-audio" }

    if ($null -eq $modelTemplate) {
        Write-Log $msg.ScrcpyModelUnknown -Level WARNING
        return "--max-fps=$fps -b ${bw}M $audioArg"
    }

    # Backward compat: if old flat-string format, return as-is
    if ($modelTemplate -is [string]) {
        return $modelTemplate
    }

    # New object format: combine template with per-headset profile
    $crop  = if ($eye -eq 'L') { $modelTemplate.crop_left  } else { $modelTemplate.crop_right  }
    $angle = if ($eye -eq 'L') { $modelTemplate.angle_left } else { $modelTemplate.angle_right }

    $argParts = [System.Collections.Generic.List[string]]::new()
    if ($crop)  { $argParts.Add("--crop $crop") }
    if ($null -ne $angle -and "$angle" -ne "" -and [int]"$angle" -ne 0) { $argParts.Add("--angle=$angle") }
    $argParts.Add("--max-fps=$fps")
    $argParts.Add("-b ${bw}M")
    if ($modelTemplate.max_size)       { $argParts.Add("--max-size=$($modelTemplate.max_size)") }
    if ($modelTemplate.video_codec)   { $argParts.Add("--video-codec=$($modelTemplate.video_codec)") }
    if ($modelTemplate.video_encoder -and $modelTemplate.video_encoder -ne "") { $argParts.Add("--video-encoder=$($modelTemplate.video_encoder)") }
    if ($modelTemplate.video_buffer)  {
        $argParts.Add("--video-buffer=$($modelTemplate.video_buffer)")
        $argParts.Add("--audio-buffer=$($modelTemplate.video_buffer)")
    }
    if ($modelTemplate.stay_awake -eq $true) { $argParts.Add("--stay-awake") }
    $argParts.Add($audioArg)

    return ($argParts -join ' ')
}

# Returns the running scrcpy process whose window title matches $displayName,
# or $null if none found. $displayName must be in window-title form (spaces -> underscores).
function Get-ScrcpyProcess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$displayName
    )
    return Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq $displayName } |
        Select-Object -First 1
}

function start-screenCopy {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,

        [string]$displayName = [string]$headsetIP,

        [boolean]$recording = $false,

        [int]$adbPort = $global:adbPort_default,

        [string]$scrcpyProfile = "R-N-45-20"

    )

    $displayName =  Convert-Displayname($displayName)

    # Guard: skip if a scrcpy window for this headset is already running
    if (Get-ScrcpyProcess -displayName $displayName) {
        Write-Log -Message ($msg.ScrcpyAlreadyRunning -f $displayName) -Level WARNING
        Start-Sleep -Seconds 5
        return
    }

    $adb = $global:adbPath
    $adb_device = "$headsetIP`:$adbPort"
    $scrcpy = $global:scrcpyFilePath

    if (-not(test-port -hostname $headsetIP -port $adbPort).open){ # Check if the ADB port is open
        Write-Log -Message ($msg.AdbPortNotResponding -f $adbPort) -Level WARNING
        pause
        return
    }

    # ADB port open, initiating connection to the headset
    try {
        Write-Log -Message ($msg.ScrcpyCheckingAdb -f $adb_device) -Level "INFO"

        $connectedDevices = & $adb devices | Select-String $adb_device -AllMatches
        if ($connectedDevices.Matches.Count -lt 1) {
            Write-Log -Message ($msg.NoActiveAdbConnection -f $adb_device) -Level "INFO"
            & $adb connect $adb_device | Out-Null
            Start-Sleep -Seconds 2
        }

    } catch {
        Write-Log -Message ($msg.ScrcpyExecError -f $_.Exception.Message) -Level "ERROR"
		return
    }
	
	
	$options = ""
    $headsetModel = Get-HeadsetModel $headsetIP
    Write-Log -Message ($msg.ScrcpyModelDetected -f $headsetModel) -Level "INFO"
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
    
    

    $options = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $scrcpyProfile

    # Check that scrcpy exists
    if (-not (Test-Path $scrcpy)) {
        Write-Log -Message ($msg.ScrcpyNotFound -f $scrcpyPath) -Level "ERROR"
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
        Write-Log -Message ($msg.ScrcpyRecording -f $recordFile) -Level "INFO"
    } else {
        $recordOption = ""
    }
    $arguments = "-s $adb_device $options --window-title=$displayName $recordOption"
    #.\scrcpy.exe --crop 1664:1304:2260:450 --angle=-21 --max-fps 45 -b 16M --no-audio --video-buffer=100 --video-codec=h264 --video-encoder=OMX.qcom.video.encoder.avc -s $adb_device
    #.\sources\scrcpy-win64-v3.3\scrcpy.exe -s 192.168.1.243:5555 -b20m --crop=1664:1304:2260:450 --angle=-21 --max-size=800 --max-fps=30 --video-codec=h265 --no-audio --window-title=Q3_BLUE
    
	Write-Log -Message ($msg.ScrcpyLaunching -f $arguments) -Level "INFO"
    try {
        #$process = 
        Start-Process $scrcpy -ArgumentList $arguments -PassThru -NoNewWindow `
			-RedirectStandardOutput (Join-Path -Path $global:logFolder -ChildPath ($displayName+"_StandardOutput.txt")) `
			-RedirectStandardError  (Join-Path -Path $global:logFolder -ChildPath ($displayName+"_StandardError.txt"))
        
	} catch {
        Write-Log -Message ($msg.ScrcpyLaunchError -f $_.Exception.Message) -Level "ERROR"
		return
    }
}




function Watch-ScrcpyProcesses {
    
    # Step 1: Retrieve scrcpy processes running on the machine

    $knownHeadsets_with_autorestart = Get-KnownHeadsets | Where-Object { $_.scrcpy_AutoRestart -eq $True }

    # For each headset with autorestart, ensure there's a scrcpy process started

    foreach ($headset in $knownHeadsets_with_autorestart) {
        Write-Log ($msg.ScrcpyCheckHeadset -f $headset.Name, $headset.IPAddress) -Level DEBUG

        $headsetInfos = Get-KnownHeadsetInfos $headset
        if ($headsetInfos.ADBWifi -eq $true) {
            Write-Log ($msg.ScrcpyCheckProcess -f $headset.Name, $headset.IPAddress) -Level DEBUG
            $runningScrcpyProcess_forThisheadset = Get-ScrcpyProcess -displayName (Convert-Displayname $headset.Name)
            
            Write-Log ($msg.ScrcpyProcessFound -f $runningScrcpyProcess_forThisheadset) -Level DEBUG
            if (-not $runningScrcpyProcess_forThisheadset) {
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording ($headset.Record -eq "True") -scrcpyProfile $headsetProfile
            } else {
                # scrcpy is running - check if parameters have changed
                $shouldRestart = $false
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                $expectedRecording = ($headset.Record -eq "True")

                $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($runningScrcpyProcess_forThisheadset.Id)").CommandLine

                # Check recording option mismatch
                $hasRecord = $cmdLine -match "--record="
                if ($hasRecord -ne $expectedRecording) {
                    Write-Log ($msg.ScrcpyRecordingChanged -f $headset.Name) -Level INFO
                    $shouldRestart = $true
                }

                # Check scrcpy options and profile mismatch
                if (-not $shouldRestart) {
                    $headsetModel = $headsetInfos.Model
                    $expectedOptions = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $headsetProfile
                    if ($expectedOptions -ne "") {
                        $normalizedCmdLine = ($cmdLine -replace '\s+', ' ').Trim()
                        $normalizedOptions = ($expectedOptions -replace '\s+', ' ').Trim()
                        if ($normalizedCmdLine -notlike "*$normalizedOptions*") {
                            Write-Log ($msg.ScrcpyOptionsChanged -f $headset.Name, $headsetModel) -Level INFO
                            $shouldRestart = $true
                        }
                    }
                }

                if ($shouldRestart) {
                    Write-Log ($msg.ScrcpyRestarting -f $headset.Name) -Level INFO
                    # Send WM_CLOSE so scrcpy can finalise any recording file before exiting
                    $closed = $runningScrcpyProcess_forThisheadset.CloseMainWindow()
                    if ($closed) {
                        $runningScrcpyProcess_forThisheadset.WaitForExit(10000) | Out-Null
                    }
                    if (-not $runningScrcpyProcess_forThisheadset.HasExited) {
                        Write-Log ($msg.ScrcpyStopTimeout -f $headset.Name) -Level WARNING
                        Stop-Process -Id $runningScrcpyProcess_forThisheadset.Id -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 1
                    }
                    start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording $expectedRecording -scrcpyProfile $headsetProfile
                }
            }
        }
    }
}


# Gracefully stops all running scrcpy processes launched from this app's scrcpy folder.
# Sends WM_CLOSE first so active recordings are finalised, then force-kills after timeout.
function Stop-AllScrcpy {
    $procs = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }
    if (-not $procs) { return }
    foreach ($proc in $procs) {
        $closed = $proc.CloseMainWindow()
        if ($closed) { $proc.WaitForExit(5000) | Out-Null }
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log "All scrcpy processes stopped." -Level INFO
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
        Write-Log $msg.ScrcpyServerFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy server file already exists." -Level DEBUG
    }
    # scrcpy.png
    $destinationPath = "C:/msys64/mingw64/share/icons/hicolor/256x256/apps/scrcpy.png"
    if (-not (Test-Path -Path $destinationPath)) {
        New-Item -Path ([System.IO.Path]::GetDirectoryName($destinationPath)) -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\icon.png" -Destination $destinationPath -Force
        Write-Log $msg.ScrcpyIconFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy icon file already exists." -Level DEBUG
    }
}
