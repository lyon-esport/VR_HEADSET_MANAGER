# Affichage du menu principale
function Show-MainMenu {
    do {

         #Check if headsets dashboard is running, if not restart it
        $VRMonitorProcess = Get-WmiObject -Class Win32_Process -Filter "ParentProcessId = $PID" | Where-Object { $_.CommandLine -match "headsets_dashboard.ps1" }
        Write-Log "VRMonitorProcess: $($VRMonitorProcess.ProcessId)" -Level DEBUG
        
        if (-not $VRMonitorProcess) {
            Write-Host "Le processus VR Monitor n'est pas en cours d'execution. Relance..." -ForegroundColor Yellow
            Write-Host "The VR Monitor process is not running. Restarting it..." -ForegroundColor Yellow
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
        Write-Host "=== Menu Principal ===" -ForegroundColor Cyan
        Write-Host " [ID]. Streamer l'ecran d'un casque VR " -BackgroundColor Yellow -ForegroundColor Black
        
        #Write-Host " 3. Supprimer un casque " -BackgroundColor DarkMagenta -ForegroundColor White
        #Write-Host " 4. Gestion USB d'un casque (Activation Wifi ADB et Applications) " -BackgroundColor Blue -ForegroundColor White
        
        #Write-Host " 9. Verifier la connexion a internet " -BackgroundColor White -ForegroundColor Black
        Write-Host " +. Activer Wifi ADB sur un casque connecte en USB " -BackgroundColor White -ForegroundColor Black
        Write-Host " A. Ajouter/modifier un casque " -BackgroundColor Green -ForegroundColor DarkMagenta
        Write-Host " S. Gestion du tracking des process scrcpy " -BackgroundColor DarkRed -ForegroundColor White
        Write-Host " R. Gestion du Recording " -BackgroundColor DarkBlue -ForegroundColor White
        Write-Host " F. Gestion des fichiers et dossiers " -BackgroundColor DarkCyan -ForegroundColor Black 
        Write-Host " 0. Quitter "
        Write-Host " Any other key : Refresh"
        Write-Host
        Write-Host "=== CASQUES CONNUS ==="
        #Start-Sleep -Milliseconds 200
        #Show-HeadsetsTable -FieldsToShow @("ID","Name", "IPAddress", "Ping", "ADBReachable", "SCRCPY")
        #Show-HeadsetsTable
        Show-HeadsetsConfig
        #Show-HeadsetsTableColored -FieldsToShow @("ID","Name", "IPAddress")
        #Write-Host "Nom ; Etat (OK/KO) ; Niveau de batterie ; application en cours"
        $headsets = @(Get-KnownHeadsets)

        $choice = (Read-Host "Entrez votre choix").ToUpper()
        
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

            Write-Log -Message "Essai de connexion a $headsetName - $headsetIPAddress" -Level "INFO"
            #Check ping headset first !
            if (Test-Connection -ComputerName $headsetIPAddress -Count 1 -Quiet){
                start-screenCopy -displayName $headsetName -headsetIP $headsetIPAddress -recording $headsetRecording
            }
            else {
                Write-Log -Message "PING $headsetIPAddress KO -> Retour au menu precedent dans 5s." -Level "WARNING"
                Start-Sleep -Seconds 5
            }
        }
        else {

            switch ($choice) {
                <#'1' { Write-Host "=== Streamer l'ecran d'un casque VR ===" -BackgroundColor Blue
                        Show-SubMenu-StreamHeadset 
                        
                    }#>
                'A' { Write-Host "== AJOUT D'UN CASQUE =="
                        Show-SubMenu-AddHeadset
                    }
                <#'3' { Write-Host "== SUPPRESSION D'UN CASQUE ==" #OK
                        Show-SubMenu-RemoveHeadset 
                    }
                '4' { Write-Host "== GESTION D'UN CASQUE =="
                        Show-SubMenu-ManageHeadset
                    }
                #>
                'S' { Write-Host "== GESTION DU TRACKING DES PROCESS SCRCPY =="
                        Show-SubMenu-scrcpyTracking
                    }
                'R' { Write-Host "== GESTION DU RECORDING DES CASQUES =="
                        Show-SubMenu-Recording
                    }
                'F' { Write-Host "== GESTION DES FICHIERS ET DOSSIERS =="
                        Show-SubMenu-FilesAndFolders
                    }
                '9' {
                    $ping = Test-Connection -ComputerName google.com -Count 2
                    if ($ping) {
                        Write-Host "Connexion reseau internet operationnelle - Ping google.com : $(($ping | Measure-Object -Property ResponseTime -Average).Average) ms" -ForegroundColor Green
                    } else {
                        Write-Host " Probleme de connexion a internet " -ForegroundColor White -BackgroundColor Red
                    }
                    pause
                }
                '+' { Write-Host "== ACTIVATION WIFI ADB DEPUIS L'USB =="
                        Enable-WiFiADB -wifi_ssid $global:WIFI_SSID -wifi_pwd $global:WIFI_PWD
                    }
                '0' {
                    Write-Host "Au revoir !" -ForegroundColor Yellow
                    Stop-VRMonitor
                    Disconnect-ADBConnections
                    break
                }
                default {
                    Write-Host "Refresh" -ForegroundColor Red
                    # Reload all modules and config file
                    . Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
                }
            }
        }
    } while ($choice -ne '0')
} 




function Show-SubMenu-StreamHeadset { # CHOIX 1
    Clear-Host
    Write-Host "=== [1] SELECTIONNER LE CASQUE A STREAMER ===" -BackgroundColor Yellow -ForegroundColor Black
    $headsets = @(get-knownHeadsets)
    if ($headsets.Count -eq 0){
        Write-Host " Ajoutez d'abord un casque ! " -ForegroundColor DarkRed -BackgroundColor White
    }
    else {
        #Show-HeadsetsTable
        Show-HeadsetsTableColored -FieldsToShow @("ID","Name","IPAddress","Ping","ADBWifi","SCRCPY")
        $userInput = $(Read-Host " Votre choix (0 pour annuler) >>").ToUpper()
        
        if ($userInput -eq '0') {
            Write-Log -Message "Retour au menu precedent." -Level "INFO"
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
            Write-Log -Message "Essai de connexion a $headsetName - $headsetIPAddress" -Level "INFO"
            #Check ping headset first !
            if (Test-Connection -ComputerName $headsetIPAddress -Count 1 -Quiet){
                start-screenCopy -displayName $headsetName  -headsetIP $headsetIPAddress -recording $headsetRecording
            }
            else {
                Write-Log -Message "PING $headsetIPAddress KO -> Retour au menu precedent dans 5s." -Level "WARNING"
                Start-Sleep -Seconds 5
            }
        }
        else {
            Write-Log -Message "ID '$userInput' invalide ou option non reconnue. Veuillez entrer un ID valide, ou '0' pour annuler." -Level "ERROR"
        }
    }
    
} # TODO


function Show-SubMenu-AddHeadset { #CHOIX 2
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== [2] AJOUT OU MODIFICATION D'UN CASQUE ===" -BackgroundColor Green -ForegroundColor DarkMagenta
    Write-Host "`t 1. Scan du reseau pour ajouter un casque"
    Write-Host "`t 2. Ajouter un casque manuellement a la liste"
    Write-Host "`t 3. Modifier un casque manuellement a la liste"
    Write-Host "`t 4. Suppression d'un casque de la liste"
                    
    Write-Host "`t 0. Revenir au menu precedent"

    $userInput = Read-Host " Votre choix >>"

    switch ($userInput) {
        '1' {
            Write-Log -Message "Lancement du scan reseau pour ajout de casque." -Level "INFO"
            Add-Headset-ScanNetwork #-port 
        }

        '2' {
            Write-Log -Message "Ajout manuel d’un casque." -Level "INFO"
            Add-Headset-Manually
        }

        '3' {
            Write-Log -Message "Modification manuelle d’un casque." -Level "INFO"
            Show-SubMenu-EditHeadset
        }
        '4' {
            Write-Host "== SUPPRESSION D'UN CASQUE ==" #OK
            Show-SubMenu-RemoveHeadset 
        }
        '0' {
            Write-Log -Message "Retour au menu precedent." -Level "INFO"
        }

        default {
            Write-Log -Message "Option invalide saisie dans le menu d'ajout." -Level "ERROR"
            Write-Host "Option invalide. Veuillez entrer 1, 2, 3 ou 0." -ForegroundColor Yellow
        }
    }
}  # PARTIEL

function Show-SubMenu-EditHeadset { #CHOIX 3
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== [3] MODIFIER UN CASQUE MANUELLEMENT ===" -BackgroundColor DarkCyan

    $headsets = @(Get-KnownHeadsets)
    if (-not $headsets -or $headsets.Count -eq 0) {
        Write-Log -Message "Aucun casque a modifier." -Level "WARNING"
        Write-Host "Aucun casque a modifier." -ForegroundColor Yellow
        return
    }

    Show-HeadsetsTableColored

    $idInput = Read-Host "Entrez l'ID du casque a modifier (ou 0 pour revenir au menu)"
    if ($idInput -eq '0') {
        Write-Log "Retour au menu precedent depuis l'edition." -Level "INFO"
        return
    }

    if (-not ($idInput -match '^\d+$') -or [int]$idInput -lt 1 -or [int]$idInput -gt $headsets.Count) {
        Write-Log "ID invalide saisi pour modification : $idInput" -Level "ERROR"
        Write-Host "ID invalide. Veuillez recommencer." -ForegroundColor Red
        return
    }

    # Liste des champs modifiables avec numeros
    $availableFields = @(
        "1. Name",
        "2. IPAddress",
        "3. scrcpy_AutoRestart",
        "4. Recording"
    )

    Write-Host "Champs modifiables :"
    $availableFields | ForEach-Object { Write-Host $_ }

    # Demander a l'utilisateur de saisir le numero du champ
    $fieldNum = Read-Host "Entrez le numero du champ a modifier (1-6)"
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
        Write-Host "Numero de champ invalide. Veuillez recommencer." -ForegroundColor Red
        return
    }

    if ($field -in @("scrcpy_AutoRestart", "Record")) {
        $currentValue = ($headsets | Where-Object { $_.ID -eq [int]$idInput }).$field
        Write-Host "Valeur actuelle de '$field' : $currentValue"
        $newValueInput = Read-Host "Entrez la nouvelle valeur pour '$field' (True/False)"
        if ($newValueInput -in @("True", "true", "False", "false")) {
            $newValue = [System.Convert]::ToBoolean($newValueInput)
        } else {
            Write-Log "Valeur invalide pour le champ boolean '$field' : $newValueInput" -Level "ERROR"
            Write-Host "Valeur invalide. Veuillez entrer True ou False." -ForegroundColor Red
            retourn
        }
    } else {
        # Demander la nouvelle valeur pour le champ selectionne
        $newValue = Read-Host "Nouvelle valeur pour le champ '$field'"
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

    Write-Host "=== [3] SUPPRESSION D'UN CASQUE ===" -BackgroundColor DarkMagenta
    Show-HeadsetsTableColored
    Write-Host "`t [1-$($headsets.Count)] : Saisir l'ID du casque a supprimer "
    Write-Host "`t ALL : Supprimer TOUS les casques"
    Write-Host "`t 0   : Revenir au menu precedent"
    # Demander a l'utilisateur de saisir un ID ou 'ALL' ou '0' pour revenir
    $userInput = $(Read-Host " Votre choix >>").ToUpper() #ToUpper = Convertir l'entree de l'utilisateur en majuscule pour la comparaison insensible a la casse

    # Si l'utilisateur entre 'ALL', supprimer tous les casques
    if ($userInput -eq 'ALL') {
        # Demander une confirmation avant de supprimer tous les casques
        $confirmation = $(Read-Host "Êtes-vous sûr de vouloir supprimer tous les casques ? (y/n)").ToUpper()
        if ($confirmation -eq 'Y') {
            # Supprimer tous les casques en appelant Remove-KnownHeadset sans specifier de criteres
            Clear-Content -Path $global:knownHeadsetsFilePath -Force
            Write-Log -Message "Tous les casques ont ete supprimes du fichier." -Level "INFO"
            Write-Host "Tous les casques ont ete supprimes" -ForegroundColor green
        } else {
            Write-Log -Message "Suppression annulee." -Level "INFO"
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
        Write-Log -Message "ID invalide ou option non reconnue. Veuillez entrer un ID valide, 'ALL' ou '0'." -Level "ERROR"
    }
} # OK

function Show-SubMenu-ManageHeadset { #CHOIX 4
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== [4] GESTION D'UN CASQUE ===" -BackgroundColor Green -ForegroundColor DarkBlue
    Write-Host "`t 1. Installer l'application Oculus Wifi ADB sur un casque (USB + mode developpeur obligatoire)"
    Write-Host "`t 2. Activer le Wifi ADB sur un casque uniquement (USB + mode developpeur obligatoire)"
    Write-Host "`t 3. Installation d'une application (Not available)"
    Write-Host "`t 4. Lancement d'une application dans le casque(Not available)"
    Write-Host "`t 5. Kill d'une application dans le casque (Not available)"
    Write-Host "`t 6. Desinstallation d'une application dans le casque (Not available)"

    Write-Host "`t 0. Revenir au menu precedent"
    $userInput = $(Read-Host " Votre choix >>").ToUpper() #ToUpper = Convertir l'entree de l'utilisateur en majuscule pour la comparaison insensible a la casse

    if ($userInput -eq '1') {
        Write-Host "== INSTALLATION DE L'APPLICATION OCULUS WIFI ADB (USB CONNECTION REQUISE) =="
        Install-Apk-OculusWirelessAdb
    }
    
    elseif ($userInput -eq '2') {
        Write-Host "== DEMARRAGE DU WIFI ADB (USB CONNECTION REQUISE) =="
        Enable-WiFiADB
    }
    elseif ($userInput -in ('3','4','5','6')) {
        Write-Host "== GESTIONNAIRE D'APPLICATION =="
        Write-Log "Cette fonctionnalite n'est pas encore developpee" -Level WARNING
                    #list headsets
                    #create a function get-headsetInstalledApps
                    #create a function start-headsetInstalledApp
    }
    elseif ($userInput -eq '0') {
        Write-Log -Message "Retour au menu precedent." -Level "INFO"
    }
    else {
        Write-Log -Message "0ption non reconnue. Veuillez entrer un ID valide, ou '0'." -Level "ERROR"
        Write-Log -Message "Retour au menu principale" -Level "INFO"
    }
} # TODO

function Show-SubMenu-scrcpyTracking { #CHOIX 5
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host "=== [5] SWITCH DU SUIVI DES FENÊTRES SCRCPY ===" -ForegroundColor Cyan
    #Write-Host "Menu désactivé pour le moment !"
    Write-Host "Saisir le numero du casque a modifier"
    #Write-Host "1. Activer le restart automatique des scrcpy"
    #Write-Host "2. Desactiver le restart automatique des scrcpy"
    #Write-Host "3. Lancer un monitoring actif des fenêtres lancees"
    
    if ($headsets.Count -eq 0) {
        Write-Host "Aucun casque trouve dans le fichier de casques connus." -ForegroundColor Yellow
    }
    else {
        write-host "[ID] `t NAME `t`t AutoRestart"
        Write-Host "------------------------------------------"
        $headsets | ForEach-Object {
            $autoRestartText = $_.scrcpy_AutoRestart
            $autoRestartColor = if ($autoRestartText -eq $true) { "Green" } else { "Red" }
            
            Write-Host "$($_.ID) `t $($_.Name) `t`t " -NoNewline
            Write-Host $autoRestartText -ForegroundColor $autoRestartColor
        }
    }
    Write-Host "0. Retour"
    Write-Host ""
    
    $choice = Read-Host "Choix"

    if ($choice -in $headsets.ID){
        if ($headsets[$choice-1].scrcpy_AutoRestart -eq $true) {
            Write-Log -Message "Desactivation du suivi automatique des scrcpy pour le casque ID $choice ($($headsets[$choice-1].Name))." -Level "INFO"
            $headsets[$choice-1].scrcpy_AutoRestart = $false
        } else {
            Write-Log -Message "Activation du suivi automatique des scrcpy pour le casque ID $choice ($($headsets[$choice-1].Name))." -Level "INFO"
            $headsets[$choice-1].scrcpy_AutoRestart = $true
        }
        # Sauvegarder les modifications dans le fichier csv
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message "Retour au menu precedent..." -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
}

function Show-SubMenu-Recording { #CHOIX 6
    Clear-Host
    $headsets = @(Get-KnownHeadsets)

    Start-Sleep -Milliseconds 200
    Write-Host "=== [6] SWITCH DU RECORDING DES CASQUES ===" -ForegroundColor Cyan
    Write-Host "Saisir le numero du casque a modifier"
    
    if ($headsets.Count -eq 0) {
        Write-Host "Aucun casque trouve dans le fichier de casques connus." -ForegroundColor Yellow
    }
    else {
        write-host "[ID] `t NAME `t`t Recording"
        Write-Host "------------------------------------------"
        $headsets | ForEach-Object {
            $recordingText = $_.Record
            $recordingColor = if ($recordingText -eq $true) { "Green" } else { "Red" }
            
            Write-Host "$($_.ID) `t $($_.Name) `t " -NoNewline
            Write-Host $recordingText -ForegroundColor $recordingColor
        }
    }
    Write-Host "0. Retour"
    Write-Host ""
    
    $choice = Read-Host "Choix"

    if ($choice -in $headsets.ID){
        if ($headsets[$choice-1].Record -eq $true) {
            Write-Log -Message "Desactivation du recording pour le casque ID $choice ($($headsets[$choice-1].Name))." -Level "INFO"
            $headsets[$choice-1].Record = $false
        } else {
            Write-Log -Message "Activation du recording pour le casque ID $choice ($($headsets[$choice-1].Name))." -Level "INFO"
            $headsets[$choice-1].Record = $true
        }
        # Sauvegarder les modifications dans le fichier csv
        Save-Headsets -headsets $headsets
    }
    else {
        Write-Log -Message "Retour au menu precedent..." -Level "INFO"
        Start-Sleep -seconds 2
        break 
    }
} # OK


function Show-SubMenu-FilesAndFolders{
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== GESTION DES FICHIERS ET DOSSIERS ===" -BackgroundColor DarkCyan -ForegroundColor White
    Write-Host "`t 1. Ouvrir le dossier des enregistrements"
    Write-Host "`t 2. Ouvrir le dossier des logs"
    Write-Host "`t 3. Ouvrir le dossier de l'application"
    Write-Host "`t 4. Editer le fichier de configuration"
    Write-Host "`t 5. Editer le fichier de config des casques connus"

    Write-Host "`t 0. Revenir au menu precedent"
    $userInput = $(Read-Host " Votre choix >>").ToUpper() #ToUpper = Convertir l'entree de l'utilisateur en majuscule pour la comparaison insensible a la casse
    switch ($userInput) {
        '1' {
            Write-Log -Message "Ouverture du dossier des enregistrements." -Level "INFO"
            Open-Folder -folderPath $global:scrcpyRecordFolder
        }

        '2' {
            Write-Log -Message "Ouverture du dossier des logs." -Level "INFO"
            Open-Folder -folderPath $global:logFolder
        }

        '3' {
            Write-Log -Message "Ouverture du dossier de l'application." -Level "INFO"
            Open-Folder -folderPath $global:scriptPath
        }
        '4' {
            Write-Log -Message "Ouverture du fichier de configuration." -Level "INFO"
            Open-File -filePath $global:configFilePath
        }
        '5' {
            Write-Log -Message "Ouverture du fichier de configuration des casques connus." -Level "INFO"
            Open-File -filePath $global:knownHeadsetsFilePath
        }
        '0' {
            Write-Log -Message "Retour au menu precedent..." -Level "INFO"
            Start-Sleep -seconds 2
            break 
        }

        default {
            Write-Log -Message "Option invalide saisie dans le menu de gestion des fichiers." -Level "ERROR"
            Write-Host "Option invalide. Veuillez entrer 1, 2, 3, 4, 5 ou 0." -ForegroundColor Yellow
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
        Write-Log -Message "Le fichier '$filePath' n'existe pas." -Level "ERROR"
        Write-Host "Le fichier '$filePath' n'existe pas." -ForegroundColor Red
    }
}