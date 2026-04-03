# Display the main menu

# Translations are loaded centrally in scripts_init.ps1 into $global:msg

function Show-MainMenu {
    do {

         #Check if headsets dashboard is running, if not restart it
        $VRMonitorProcess = Get-WmiObject -Class Win32_Process -Filter "ParentProcessId = $PID" | Where-Object { $_.CommandLine -match "headsets_dashboard.ps1" }
        Write-Log ($msg.VRMonitorProcessId -f $VRMonitorProcess.ProcessId) -Level DEBUG
        
        if (-not $VRMonitorProcess) {
            Write-Host $msg.VRMonitorNotRunning -ForegroundColor Yellow
            $headsets_dashboard_script = Join-Path -Path $scriptPath -ChildPath "modules\headsets_dashboard.ps1"

            Start-Process powershell.exe -ArgumentList @(
                "-NoExit",
                "-File",
                "`"$headsets_dashboard_script`"",
                "-ScriptPath",
                "`"$scriptPath`"",
                "-ConfigFilePath", 
                "`"$configFilePath`""
            )
            
            #Prevent the computer from sleeping while the dashboard is running
            Set-AwakeMode
        }

        # Start html monitor update
        Write-htmlMonitor $global:knownHeadsets


        Clear-Host
        Start-Sleep -Milliseconds 200
        Write-Host $msg.MainMenuTitle -ForegroundColor Cyan
        Write-Host $msg.StreamHeadset -BackgroundColor Yellow -ForegroundColor Black
        
        #Write-Host " 3. Remove a headset " -BackgroundColor DarkMagenta -ForegroundColor White
        #Write-Host " 4. USB headset management (Enable Wifi ADB and Applications) " -BackgroundColor Blue -ForegroundColor White
        
        #Write-Host " 9. Check internet connection " -BackgroundColor White -ForegroundColor Black
        Write-Host $msg.EnableWifiADB -BackgroundColor White -ForegroundColor Black
        Write-Host $msg.AddModifyHeadset -BackgroundColor Green -ForegroundColor DarkMagenta
        Write-Host $msg.ScrcpyTracking -BackgroundColor DarkRed -ForegroundColor White
        Write-Host $msg.ScrcpyOptions -BackgroundColor DarkCyan -ForegroundColor Yellow
        Write-Host $msg.RecordingManagement -BackgroundColor DarkBlue -ForegroundColor White
        Write-Host $msg.FilesFolders -BackgroundColor DarkCyan -ForegroundColor Black 
        Write-Host $msg.Quit
        Write-Host $msg.AnyOtherKey
        Write-Host
        Write-Host $msg.KnownHeadsets
        #Start-Sleep -Milliseconds 200
        #Show-HeadsetsTable -FieldsToShow @("ID","Name", "IPAddress", "Ping", "ADBReachable", "SCRCPY")
        #Show-HeadsetsTable
        Show-HeadsetsConfig
        #Show-HeadsetsTableColored -FieldsToShow @("ID","Name", "IPAddress")
        #Write-Host "Name ; Status (OK/KO) ; Battery level ; current application"
        $headsets = @(Get-KnownHeadsets)

        $choice = (Read-Host $msg.EnterChoice).ToUpper()
        
        if ($choice -in $headsets.ID){
            $headsetName = ($headsets | Where-Object { $_.ID -eq $choice }).Name
            $headsetIPAddress = ($headsets | Where-Object { $_.ID -eq $choice }).IPAddress
            $headsetRecording = ($headsets | Where-Object { $_.ID -eq $choice }).Record
            #convert $headsetRecording to boolean
            if ($headsetRecording -in @("True", "true", $true)) {
                $headsetRecording = $true
            } else {
                $headsetRecording = $false
            }

            Write-Log -Message ($msg.TryingConnection -f $headsetName, $headsetIPAddress) -Level "INFO"
            #Check ping headset first !
            if (Test-Connection -ComputerName $headsetIPAddress -Count 1 -Quiet){
                start-screenCopy -displayName $headsetName -headsetIP $headsetIPAddress -recording $headsetRecording
            }
            else {
                Write-Log -Message ($msg.PingKO -f $headsetIPAddress) -Level "WARNING"
                Start-Sleep -Seconds 5
            }
        }
        else {

            switch ($choice) {
                'A' { Write-Host $msg.AddHeadsetTitle
                        Show-SubMenu-AddHeadset
                    }

                'S' { Write-Host $msg.ScrcpyTrackingTitle
                        Show-SubMenu-scrcpyTracking
                    }
                'M' { Write-Host $msg.ScrcpyOptionsTitle
                        Show-SubMenu-ScrcpyOptions
                    }
                'R' { Write-Host $msg.RecordingTitle
                        Show-SubMenu-Recording
                    }
                'F' { Write-Host $msg.FilesFoldersTitle
                        Show-SubMenu-FilesAndFolders
                    }
                '9' {
                    $ping = Test-Connection -ComputerName google.com -Count 2
                    if ($ping) {
                        Write-Host ($msg.InternetOK -f (($ping | Measure-Object -Property ResponseTime -Average).Average)) -ForegroundColor Green
                    } else {
                        Write-Host $msg.InternetProblem -ForegroundColor White -BackgroundColor Red
                    }
                    pause
                }
                '+' { Write-Host $msg.WifiADBActivation
                        Enable-WiFiADB -wifi_ssid $global:WIFI_SSID -wifi_pwd $global:WIFI_PWD
                    }
                '0' {
                    Write-Host $msg.Goodbye -ForegroundColor Yellow
                    Reset-AwakeMode
                    Stop-VRMonitor
                    Disconnect-ADBConnections
                    break
                }
                default {
                    Write-Host $msg.Refresh -ForegroundColor Red
                    # Reload all modules and config file
                    . Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
                }
            }
        }
    } while ($choice -ne '0')
} 




function Show-SubMenu-StreamHeadset { # CHOICE 1
    Clear-Host
    Write-Host $msg.SelectHeadsetToStream -BackgroundColor Yellow -ForegroundColor Black
    $headsets = @(get-knownHeadsets)
    if ($headsets.Count -eq 0){
        Write-Host $msg.AddHeadsetFirst -ForegroundColor DarkRed -BackgroundColor White
    }
    else {
        #Show-HeadsetsTable
        Show-HeadsetsTableColored -FieldsToShow @("ID","Name","IPAddress","Ping","ADBWifi","SCRCPY")
        $userInput = $(Read-Host $msg.YourChoiceCancel).ToUpper()
        
        if ($userInput -eq '0') {
            Write-Log -Message $msg.ReturnPrevious -Level "INFO"
        }
        elseif ($userInput -match '^\d+$' -and  $userInput -ge 0 -and $userInput -le $headsets.count) {
            $headsetName = ($headsets | Where-Object { $_.ID -eq $userInput }).Name
            $headsetIPAddress = ($headsets | Where-Object { $_.ID -eq $userInput }).IPAddress
            $headsetRecording = ($headsets | Where-Object { $_.ID -eq $userInput }).Record
            #convert $headsetRecording to boolean
            if ($headsetRecording -in @("True", "true", $true)) {
                $headsetRecording = $true
            } else {
                $headsetRecording = $false
            }
            Write-Log -Message ($msg.TryingConnection -f $headsetName, $headsetIPAddress) -Level "INFO"
            #Check ping headset first !
            if (Test-Connection -ComputerName $headsetIPAddress -Count 1 -Quiet){
                start-screenCopy -displayName $headsetName  -headsetIP $headsetIPAddress -recording $headsetRecording
            }
            else {
                Write-Log -Message ($msg.PingKO -f $headsetIPAddress) -Level "WARNING"
                Start-Sleep -Seconds 5
            }
        }
        else {
            Write-Log -Message ($msg.InvalidID -f $userInput) -Level "ERROR"
        }
    }
    
} # TODO


function Show-SubMenu-AddHeadset { #CHOICE 2
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.AddOrModifyHeadset -BackgroundColor Green -ForegroundColor DarkMagenta
    Write-Host $msg.ScanNetworkAdd
    Write-Host $msg.AddManually
    Write-Host $msg.ModifyManually
    Write-Host $msg.RemoveFromList
                    
    Write-Host $msg.ReturnPreviousMenu

    $userInput = Read-Host $msg.YourChoice

    switch ($userInput) {
        '1' {
            Write-Log -Message $msg.NetworkScanLaunch -Level "INFO"
            Add-Headset-ScanNetwork #-port 
        }

        '2' {
            Write-Log -Message $msg.ManualAdd -Level "INFO"
            Add-Headset-Manually
        }

        '3' {
            Write-Log -Message $msg.ManualModify -Level "INFO"
            Show-SubMenu-EditHeadset
        }
        '4' {
            Write-Host $msg.RemoveHeadset #OK
            Show-SubMenu-RemoveHeadset 
        }
        '0' {
            Write-Log -Message $msg.ReturnPrevious -Level "INFO"
        }

        default {
            Write-Log -Message $msg.InvalidOptionAdd -Level "ERROR"
            Write-Host $msg.InvalidOption -ForegroundColor Yellow
        }
    }
}  # PARTIAL

function Show-SubMenu-EditHeadset { #CHOICE 3
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.ModifyHeadsetManually -BackgroundColor DarkCyan

    $headsets = @(Get-KnownHeadsets)
    if (-not $headsets -or $headsets.Count -eq 0) {
        Write-Log -Message $msg.NoHeadsetToModify -Level "WARNING"
        Write-Host $msg.NoHeadsetToModify -ForegroundColor Yellow
        return
    }

    Show-HeadsetsTableColored

    $idInput = Read-Host $msg.EnterIDToModify
    if ($idInput -eq '0') {
        Write-Log $msg.ReturnFromEdit -Level "INFO"
        return
    }

    if (-not ($idInput -match '^\d+$') -or [int]$idInput -lt 1 -or [int]$idInput -gt $headsets.Count) {
        Write-Log ($msg.InvalidIDModification -f $idInput) -Level "ERROR"
        Write-Host $msg.InvalidIDRetry -ForegroundColor Red
        return
    }

    # List of modifiable fields with numbers
    $availableFields = @(
        $msg.FieldName,
        $msg.FieldIPAddress,
        $msg.FieldScrcpyAutoRestart,
        $msg.FieldRecording,
        $msg.FieldScrcpyProfile
    )

    Write-Host $msg.ModifiableFields
    $availableFields | ForEach-Object { Write-Host $_ }

    # Ask the user to enter the field number
    $fieldNum = Read-Host $msg.EnterFieldNumber
    if ($fieldNum -eq '1') {
        $field = "Name"
    } elseif ($fieldNum -eq '2') {
        $field = "IPAddress"
    } elseif ($fieldNum -eq '3') {
        $field = "scrcpy_AutoRestart"
    } elseif ($fieldNum -eq '4') {
        $field = "Record"
    } elseif ($fieldNum -eq '5') {
        $field = "ScrcpyProfile"
    } elseif ($fieldNum -eq '6') {
        $field = "SerialNumber"
    } else {
        Write-Log ($msg.InvalidFieldNumberEntered -f $fieldNum) -Level "ERROR"
        Write-Host $msg.InvalidFieldNumber -ForegroundColor Red
        return
    }

    if ($field -in @("scrcpy_AutoRestart", "Record")) {
        $currentValue = ($headsets | Where-Object { $_.ID -eq [int]$idInput }).$field
        Write-Host ($msg.CurrentValue -f $field, $currentValue)
        $newValueInput = Read-Host ($msg.EnterNewValueBool -f $field)
        if ($newValueInput -in @("True", "true", "False", "false")) {
            $newValue = [System.Convert]::ToBoolean($newValueInput)
        } else {
            Write-Log ($msg.InvalidBoolValueField -f $field, $newValueInput) -Level "ERROR"
            Write-Host $msg.InvalidBoolValue -ForegroundColor Red
            return
        }
    } elseif ($field -eq "ScrcpyProfile") {
        $currentValue = ($headsets | Where-Object { $_.ID -eq [int]$idInput }).$field
        Write-Host ($msg.CurrentValue -f $field, $currentValue)
        $newValue = Read-Host ($msg.EnterNewValue -f $field)
        if ($newValue -notmatch '^[LR]-[DN]-\d+-\d+$') {
            Write-Log $msg.InvalidScrcpyProfileFormat -Level "ERROR"
            Write-Host $msg.InvalidScrcpyProfileFormat -ForegroundColor Red
            return
        }
    } else {
        # Ask for the new value for the selected field
        $newValue = Read-Host ($msg.EnterNewValue -f $field)
    }
    

    # Update the headset with the new parameters
    Update-HeadsetField -ID ([int]$idInput) -Field $field -NewValue $newValue
} # OK

function Show-SubMenu-RemoveHeadset { 
    # Check whether headsets exist in the file
    Clear-Host
    Start-Sleep -Milliseconds 200
    $headsets = @(get-knownHeadsets) # @() ensures the object is an array so .Count works
    if (-not $headsets) {
        Write-Log -Message $msg.NoHeadsetFound -Level "INFO"
        Write-Host "There is no headset to delete." -ForegroundColor Yellow
        return
    }

    Write-Host $msg.RemoveHeadsetTitle -BackgroundColor DarkMagenta
    Show-HeadsetsTableColored
    Write-Host ($msg.EnterIDToDelete -f $headsets.Count)
    Write-Host $msg.DeleteAll
    Write-Host $msg.ReturnPreviousOption
    # Ask the user to enter an ID, 'ALL', or '0' to return
    $userInput = $(Read-Host " Your choice >>").ToUpper() #ToUpper = Convert user input to uppercase for case-insensitive comparison

    # If the user enters 'ALL', delete all headsets
    if ($userInput -eq 'ALL') {
        # Ask for confirmation before deleting all headsets
        $confirmation = $(Read-Host $msg.ConfirmDeleteAll).ToUpper()
        if ($confirmation -eq 'Y') {
            # Delete all headsets by calling Remove-KnownHeadset without specifying criteria
            Clear-Content -Path $global:knownHeadsetsFilePath -Force
            Write-Log -Message $msg.AllDeleted -Level "INFO"
            Write-Host $msg.AllDeletedMsg -ForegroundColor green
        } else {
            Write-Log -Message $msg.DeletionCancelled -Level "INFO"
        }
    }
    # If the user enters '0', return to the previous menu
    elseif ($userInput -eq '0') {
        Write-Log -Message $msg.ReturnPrevious -Level "INFO"
    }
        # If the user enters a specific ID, call Remove-Headset
    elseif ($userInput -match '^\d+$' -and $userInput -ge 0 -and $userInput -le $headsets.Count) {
        Remove-Headset -ID $userInput
    }
    else {
        Write-Log -Message $msg.InvalidIDOrOption -Level "ERROR"
    }
} # OK

function Show-SubMenu-ManageHeadset { #CHOICE 4
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.ManageHeadset -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host $msg.InstallOculusApp
    Write-Host $msg.EnableWifiADBOnly
    Write-Host $msg.InstallApp
    Write-Host $msg.LaunchApp
    Write-Host $msg.KillApp
    Write-Host $msg.UninstallApp

    Write-Host $msg.ReturnPreviousMenu
    $userInput = $(Read-Host $msg.YourChoice).ToUpper() #ToUpper = Convert user input to uppercase for case-insensitive comparison

    if ($userInput -eq '1') {
        Write-Host $msg.InstallOculusTitle
        Install-OculusWirelessAdbApk
    }
    
    elseif ($userInput -eq '2') {
        Write-Host $msg.StartWifiADB
        Enable-WiFiADB
    }
    elseif ($userInput -in ('3','4','5','6')) {
        Write-Host $msg.AppManager
        Write-Log $msg.NotDeveloped -Level WARNING
                    #list headsets
                    #create a function get-headsetInstalledApps
                    #create a function start-headsetInstalledApp
    }
    elseif ($userInput -eq '0') {
        Write-Log -Message $msg.ReturnPrevious -Level "INFO"
    }
    else {
        Write-Log -Message $msg.UnrecognizedOption -Level "ERROR"
        Write-Log -Message $msg.ReturnMainMenu -Level "INFO"
    }
} # TODO

function Show-SubMenu-scrcpyTracking { #CHOICE 5
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host $msg.SwitchScrcpyTracking -ForegroundColor Cyan
    #Write-Host "Menu disabled for now!"
    Write-Host $msg.EnterNumberToModify
    #Write-Host "1. Enable automatic scrcpy restart"
    #Write-Host "2. Disable automatic scrcpy restart"
    #Write-Host "3. Launch active monitoring of running windows"
    
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
    }
    else {
        write-host $msg.IDNameAutoRestart
        Write-Host $msg.Separator
        $headsets | ForEach-Object {
            $autoRestartText = $_.scrcpy_AutoRestart
            $autoRestartColor = if ($autoRestartText -eq $true) { "Green" } else { "Red" }
            
            Write-Host "$($_.ID) `t $($_.Name) `t`t " -NoNewline
            Write-Host $autoRestartText -ForegroundColor $autoRestartColor
        }
    }
    Write-Host $msg.Return
    Write-Host ""
    
    $choice = Read-Host $msg.Choice

    if ($choice -in $headsets.ID){
        if ($headsets[$choice-1].scrcpy_AutoRestart -eq $true) {
            Write-Log -Message ($msg.DeactivateAutoTracking -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].scrcpy_AutoRestart = $false
        } else {
            Write-Log -Message ($msg.ActivateAutoTracking -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].scrcpy_AutoRestart = $true
        }
        # Save changes to the CSV file
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
}

function Show-SubMenu-Recording { #CHOICE 6
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host $msg.SwitchRecording -ForegroundColor Cyan
    Write-Host $msg.EnterNumberToModify
    
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
    }
    else {
        write-host $msg.IDNameRecording
        Write-Host $msg.Separator
        $headsets | ForEach-Object {
            $recordingText = $_.Record
            $recordingColor = if ($recordingText -eq $true) { "Green" } else { "Red" }
            
            Write-Host "$($_.ID) `t $($_.Name) `t " -NoNewline
            Write-Host $recordingText -ForegroundColor $recordingColor
        }
    }
    Write-Host $msg.Return
    Write-Host ""
    
    $choice = Read-Host $msg.Choice

    if ($choice -in $headsets.ID){
        if ($headsets[$choice-1].Record -eq $true) {
            Write-Log -Message ($msg.DeactivateRecording -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].Record = $false
        } else {
            Write-Log -Message ($msg.ActivateRecording -f $choice, $headsets[$choice-1].Name) -Level "INFO"
            $headsets[$choice-1].Record = $true
        }
        # Save changes to the CSV file
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
} # OK


function Show-SubMenu-ScrcpyOptions {
    $headsets = @(Get-KnownHeadsets)
    if ($headsets.Count -eq 0) {
        Write-Host $msg.NoHeadsetInFile -ForegroundColor Yellow
        return
    }

    do {
        Clear-Host
        Start-Sleep -Milliseconds 100
        Write-Host $msg.ScrcpyOptionsTitle -ForegroundColor Cyan
        Write-Host $msg.ScrcpyOptionsSelectHeadset
        Write-Host $msg.IDNameScrcpyProfile
        Write-Host $msg.Separator
        $headsets | ForEach-Object {
            $profileText = if ($_.ScrcpyProfile) { $_.ScrcpyProfile } else { "R-N-45-20" }
            Write-Host "$($_.ID)`t$($_.Name.PadRight(16))`t$profileText"
        }
        Write-Host $msg.Return
        Write-Host ""

        $idInput = Read-Host $msg.Choice
        if ($idInput -eq '0') { return }

        $headset = $headsets | Where-Object { $_.ID -eq $idInput }
        if (-not $headset) {
            Write-Log ($msg.InvalidID -f $idInput) -Level WARNING
            Start-Sleep -Seconds 2
            continue
        }

        # Inner loop: edit individual profile fields for the selected headset
        do {
            $profile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
            $parts = $profile -split '-'
            if ($parts.Count -ne 4) { $parts = @('R','N','45','20') }
            $eye  = $parts[0].ToUpper()
            $audio = $parts[1].ToUpper()
            $fps  = $parts[2]
            $bw   = $parts[3]
            $eyeLabel   = if ($eye   -eq 'L') { 'Left'      } else { 'Right' }
            $audioLabel = if ($audio -eq 'D') { 'Duplicate' } else { 'No audio' }

            Clear-Host
            Write-Host "$($msg.ScrcpyOptionsTitle) - $($headset.Name)" -ForegroundColor Cyan
            Write-Host $msg.Separator
            Write-Host " [#]  $($msg.ScrcpyOptTableHeader)"
            Write-Host $msg.Separator
            Write-Host " [1]  $($msg.ScrcpyOptEyeLabel.PadRight(16)) : $eyeLabel"
            Write-Host " [2]  $($msg.ScrcpyOptAudioLabel.PadRight(16)) : $audioLabel"
            Write-Host " [3]  $($msg.ScrcpyOptFPSLabel.PadRight(16)) : $fps"
            Write-Host " [4]  $($msg.ScrcpyOptBitrateLabel.PadRight(16)) : $bw"
            Write-Host " [0]  $($msg.Return)"

            $opt = Read-Host $msg.ScrcpyOptionsEnterOption

            switch ($opt) {
                '1' {
                    $val = (Read-Host ($msg.ScrcpyOptionsEye -f $eye)).ToUpper()
                    if ($val -in @('L','R')) {
                        $parts[0] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidEye -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '2' {
                    $val = (Read-Host ($msg.ScrcpyOptionsAudio -f $audio)).ToUpper()
                    if ($val -in @('D','N')) {
                        $parts[1] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidAudio -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '3' {
                    $val = Read-Host ($msg.ScrcpyOptionsFPS -f $fps)
                    if ($val -match '^\d+$' -and [int]$val -gt 0) {
                        $parts[2] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidNumber -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '4' {
                    $val = Read-Host ($msg.ScrcpyOptionsBitrate -f $bw)
                    if ($val -match '^\d+$' -and [int]$val -gt 0) {
                        $parts[3] = $val
                    } else {
                        Write-Host $msg.ScrcpyOptionsInvalidNumber -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
                '0' { break }
                default { }
            }

            if ($opt -in @('1','2','3','4')) {
                $newProfile = $parts -join '-'
                $headset.ScrcpyProfile = $newProfile
                Update-HeadsetField -ID ([int]$headset.ID) -Field "ScrcpyProfile" -NewValue $newProfile
                # Refresh local array so the outer list reflects the change
                $headsets = @(Get-KnownHeadsets)
                $headset = $headsets | Where-Object { $_.ID -eq $idInput }
                Write-Log ($msg.ScrcpyOptionsSaved -f $headset.Name, $newProfile) -Level INFO
            }
        } while ($opt -ne '0')

    } while ($true)
}


function Show-SubMenu-FilesAndFolders{
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.FilesAndFoldersManagement -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host $msg.OpenRecordingsFolder
    Write-Host $msg.OpenLogsFolder
    Write-Host $msg.OpenAppFolder
    Write-Host $msg.EditConfigFile
    Write-Host $msg.EditKnownHeadsetsConfig

    Write-Host $msg.ReturnPreviousMenu
    $userInput = $(Read-Host $msg.YourChoice).ToUpper() #ToUpper = Convert user input to uppercase for case-insensitive comparison
    switch ($userInput) {
        '1' {
            Write-Log -Message $msg.OpenRecordings -Level "INFO"
            Open-Folder -folderPath $global:scrcpyRecordFolder
        }

        '2' {
            Write-Log -Message $msg.OpenLogs -Level "INFO"
            Open-Folder -folderPath $global:logFolder
        }

        '3' {
            Write-Log -Message $msg.OpenApp -Level "INFO"
            Open-Folder -folderPath $global:scriptPath
        }
        '4' {
            Write-Log -Message $msg.OpenConfig -Level "INFO"
            Open-File -filePath $global:configFilePath
        }
        '5' {
            Write-Log -Message $msg.OpenKnownHeadsets -Level "INFO"
            Open-File -filePath $global:knownHeadsetsFilePath
        }
        '0' {
            Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
            Start-Sleep -seconds 2
            break 
        }

        default {
            Write-Log -Message $msg.InvalidOptionFileMenu -Level "ERROR"
            Write-Host $msg.InvalidOptionFiles -ForegroundColor Yellow
        }
    }
}

function Open-Folder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )
    
    # Normalize path and ensure it's treated as a directory
    $normalizedPath = (Resolve-Path $FolderPath -ErrorAction SilentlyContinue).Path
    
    if ($normalizedPath -and (Test-Path $normalizedPath -PathType Container)) {
        # Use Start-Process with explorer.exe to reliably open the folder
        Start-Process explorer.exe -ArgumentList $normalizedPath
    }
    else {
        Write-Log ($msg.FolderNotExist -f $FolderPath) -Level ERROR
    }
}


function Open-File {
    param (
        [string]$filePath
    )

    if (Test-Path -Path $filePath) {
        Start-Process notepad.exe -ArgumentList "`"$filePath`""
    } else {
        Write-Log -Message ($msg.FileNotExist -f $filePath) -Level "ERROR"
        Write-Host ($msg.FileNotExist -f $filePath) -ForegroundColor Red
    }
}