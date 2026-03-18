# Display the main menu

# Translations are loaded centrally in scripts_init.ps1 into $global:msg

function Show-MainMenu {
    do {

         #Check if headsets dashboard is running, if not restart it
        $VRMonitorProcess = Get-WmiObject -Class Win32_Process -Filter "ParentProcessId = $PID" | Where-Object { $_.CommandLine -match "headsets_dashboard.ps1" }
        Write-Log "VRMonitorProcess: $($VRMonitorProcess.ProcessId)" -Level DEBUG
        
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
        }

        # Start html monitor update
        Write-htmlMonitor $global:knownHeadsets


        Clear-Host
        Start-Sleep -Milliseconds 200
        Write-Host $msg.MainMenuTitle -ForegroundColor Cyan
        Write-Host $msg.StreamHeadset -BackgroundColor Yellow -ForegroundColor Black
        
        #Write-Host " 3. Supprimer un casque " -BackgroundColor DarkMagenta -ForegroundColor White
        #Write-Host " 4. Gestion USB d'un casque (Activation Wifi ADB et Applications) " -BackgroundColor Blue -ForegroundColor White
        
        #Write-Host " 9. Verifier la connexion a internet " -BackgroundColor White -ForegroundColor Black
        Write-Host $msg.EnableWifiADB -BackgroundColor White -ForegroundColor Black
        Write-Host $msg.AddModifyHeadset -BackgroundColor Green -ForegroundColor DarkMagenta
        Write-Host $msg.ScrcpyTracking -BackgroundColor DarkRed -ForegroundColor White
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
        #Write-Host "Nom ; Etat (OK/KO) ; Niveau de batterie ; application en cours"
        $headsets = @(Get-KnownHeadsets)

        $choice = (Read-Host $msg.EnterChoice).ToUpper()
        
        if ($choice -in $headsets.ID){
            $headsetName = ($headsets | Where-Object { $_.ID -eq $choice }).Name
            $headsetIPAddress = ($headsets | Where-Object { $_.ID -eq $choice }).IPAddress
            $headsetRecording = ($headsets | Where-Object { $_.ID -eq $choice }).Record
            #convertion de $headsetRecording en boolean
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
                <#'1' { Write-Host "=== Streamer l'ecran d'un casque VR ===" -BackgroundColor Blue
                        Show-SubMenu-StreamHeadset 
                        
                    }#>
                'A' { Write-Host $msg.AddHeadsetTitle
                        Show-SubMenu-AddHeadset
                    }
                <#'3' { Write-Host "== SUPPRESSION D'UN CASQUE ==" #OK
                        Show-SubMenu-RemoveHeadset 
                    }
                '4' { Write-Host "== GESTION D'UN CASQUE =="
                        Show-SubMenu-ManageHeadset
                    }
                #>
                'S' { Write-Host $msg.ScrcpyTrackingTitle
                        Show-SubMenu-scrcpyTracking
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




function Show-SubMenu-StreamHeadset { # CHOIX 1
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
            #convertion de $headsetRecording en boolean
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


function Show-SubMenu-AddHeadset { #CHOIX 2
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
            Write-Log -Message "Option invalide saisie dans le menu d'ajout." -Level "ERROR"
            Write-Host $msg.InvalidOption -ForegroundColor Yellow
        }
    }
}  # PARTIEL

function Show-SubMenu-EditHeadset { #CHOIX 3
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host $msg.ModifyHeadsetManually -BackgroundColor DarkCyan

    $headsets = @(Get-KnownHeadsets)
    if (-not $headsets -or $headsets.Count -eq 0) {
        Write-Log -Message "Aucun casque a modifier." -Level "WARNING"
        Write-Host $msg.NoHeadsetToModify -ForegroundColor Yellow
        return
    }

    Show-HeadsetsTableColored

    $idInput = Read-Host $msg.EnterIDToModify
    if ($idInput -eq '0') {
        Write-Log "Retour au menu precedent depuis l'edition." -Level "INFO"
        return
    }

    if (-not ($idInput -match '^\d+$') -or [int]$idInput -lt 1 -or [int]$idInput -gt $headsets.Count) {
        Write-Log "ID invalide saisi pour modification : $idInput" -Level "ERROR"
        Write-Host $msg.InvalidIDRetry -ForegroundColor Red
        return
    }

    # Liste des champs modifiables avec numeros
    $availableFields = @(
        $msg.FieldName,
        $msg.FieldIPAddress,
        $msg.FieldScrcpyAutoRestart,
        $msg.FieldRecording
    )

    Write-Host $msg.ModifiableFields
    $availableFields | ForEach-Object { Write-Host $_ }

    # Demander a l'utilisateur de saisir le numero du champ
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
        $field = "SerialNumber"
    } else {
        Write-Log "Numero de champ invalide saisi : $fieldNum" -Level "ERROR"
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
            Write-Log "Valeur invalide pour le champ boolean '$field' : $newValueInput" -Level "ERROR"
            Write-Host $msg.InvalidBoolValue -ForegroundColor Red
            retourn
        }
    } else {
        # Demander la nouvelle valeur pour le champ selectionne
        $newValue = Read-Host ($msg.EnterNewValue -f $field)
    }
    

    # Mettre a jour le casque avec les nouveaux parametres
    Update-HeadsetField -ID ([int]$idInput) -Field $field -NewValue $newValue
} # OK

function Show-SubMenu-RemoveHeadset { 
    # Verifier s'il existe des casques dans le fichier
    Clear-Host
    Start-Sleep -Milliseconds 200
    $headsets = @(get-knownHeadsets) # @() pour s'assurer que l'objet est bien de type array, et qu'on peut faire un .Count !
    if (-not $headsets) {
        Write-Log -Message "Aucun casque trouve dans le fichier. Aucune suppression possible." -Level "INFO"
        Write-Host "Il n'y a aucun casque a supprimer." -ForegroundColor Yellow
        return
    }

    Write-Host $msg.RemoveHeadsetTitle -BackgroundColor DarkMagenta
    Show-HeadsetsTableColored
    Write-Host ($msg.EnterIDToDelete -f $headsets.Count)
    Write-Host $msg.DeleteAll
    Write-Host $msg.ReturnPreviousOption
    # Demander a l'utilisateur de saisir un ID ou 'ALL' ou '0' pour revenir
    $userInput = $(Read-Host " Votre choix >>").ToUpper() #ToUpper = Convertir l'entree de l'utilisateur en majuscule pour la comparaison insensible a la casse

    # Si l'utilisateur entre 'ALL', supprimer tous les casques
    if ($userInput -eq 'ALL') {
        # Demander une confirmation avant de supprimer tous les casques
        $confirmation = $(Read-Host $msg.ConfirmDeleteAll).ToUpper()
        if ($confirmation -eq 'Y') {
            # Supprimer tous les casques en appelant Remove-KnownHeadset sans specifier de criteres
            Clear-Content -Path $global:knownHeadsetsFilePath -Force
            Write-Log -Message $msg.AllDeleted -Level "INFO"
            Write-Host $msg.AllDeletedMsg -ForegroundColor green
        } else {
            Write-Log -Message $msg.DeletionCancelled -Level "INFO"
        }
    }
    # Si l'utilisateur entre '0', revenir au menu precedent
    elseif ($userInput -eq '0') {
        Write-Log -Message "Retour au menu precedent." -Level "INFO"
    }
        # Si l'utilisateur entre un ID specifique, appeler Remove-KnownHeadset
    elseif ($userInput -match '^\d+$' -and $userInput -ge 0 -and $userInput -le $headsets.Count) {
        Remove-Headset -ID $userInput
    }
    else {
        Write-Log -Message $msg.InvalidIDOrOption -Level "ERROR"
    }
} # OK

function Show-SubMenu-ManageHeadset { #CHOIX 4
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
    $userInput = $(Read-Host $msg.YourChoice).ToUpper() #ToUpper = Convertir l'entree de l'utilisateur en majuscule pour la comparaison insensible a la casse

    if ($userInput -eq '1') {
        Write-Host $msg.InstallOculusTitle
        Install-Apk-OculusWirelessAdb
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

function Show-SubMenu-scrcpyTracking { #CHOIX 5
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host $msg.SwitchScrcpyTracking -ForegroundColor Cyan
    #Write-Host "Menu désactivé pour le moment !"
    Write-Host $msg.EnterNumberToModify
    #Write-Host "1. Activer le restart automatique des scrcpy"
    #Write-Host "2. Desactiver le restart automatique des scrcpy"
    #Write-Host "3. Lancer un monitoring actif des fenêtres lancees"
    
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
        # Sauvegarder les modifications dans le fichier csv
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
}

function Show-SubMenu-Recording { #CHOIX 6
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
        # Sauvegarder les modifications dans le fichier csv
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message $msg.ReturnPreviousDots -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
} # OK


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
    $userInput = $(Read-Host $msg.YourChoice).ToUpper() #ToUpper = Convertir l'entree de l'utilisateur en majuscule pour la comparaison insensible a la casse
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
            Write-Log -Message "Option invalide saisie dans le menu de gestion des fichiers." -Level "ERROR"
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
        Write-Log "Folder path does not exist or is not a directory: $FolderPath" -Level ERROR
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