#################
# MANAGE KNOWN HEADSET FILE
#################

# Fonction pour recuperer les casques VR depuis le fichier CSV
# Exemple d'utilisation de la fonction Get-KnownHeadsets
# $headsets=Get-KnownHeadsets
function Get-KnownHeadsets {
    param (
        [string]$knownHeadsetsFilePath = $global:knownHeadsetsFilePath 
    )

    # Verifier si la variable globale $knownHeadsetsFilePath est definie
    if (-not $knownHeadsetsFilePath) {
        Write-Log -Message "Le chemin du fichier CSV des casques est vide ou non defini." -Level "ERROR"
        return
    }

    # Verifier si le fichier existe
    if (-not (Test-Path $knownHeadsetsFilePath)) {
        Write-Log -Message "Le fichier CSV specifie n'existe pas : $knownHeadsetsFilePath" -Level "ERROR"
        return
    }

    # Lire le fichier CSV et retourner les donnees sous forme d'objets PowerShell
    try {
        $headsets = @(Import-Csv -Path $knownHeadsetsFilePath)
        return $headsets
    }
    catch {
        Write-Log -Message "Erreur lors de la lecture du fichier CSV." -Level "ERROR"
    } 
} # OK


# AFFICHAGE DE TOUS LES CASQUES
# AJOUT DU TEST DU PING ET DU PORT ADB ET DE L'ETAT DU STREAM DE SCRCPY
#Show-HeadsetsTable -FieldsToShow @("ID", "Name", "Model", "Ping", "ADBReachable", "SCRCPY")
#$FieldsToShow = "all"

#  $headset = $headsets[0]

#Show-HeadsetsTable -FieldsToShow @("ID","Name","Model","IPAddress","Ping","ADBWifi")

function Show-HeadsetsTable {
    param (
        [string]$FilePath = $global:knownHeadsetsInfosFilePath,
        [string[]]$FieldsToShow = @("all")
    )

    # Charger les casques depuis le fichier CSV
    $headsets = @(Import-Csv -Path $FilePath -Delimiter ";" )

    if ($headsets.Count -eq 0) {
        Write-Log "Aucun casque connu a afficher !" -Level "INFO"
        return
    }

    if ($FieldsToShow -contains 'all') {
        $FieldsToShow = @("ID","Name","IPAddress","Ping","ADBWifi","Model","SerialNumber","Battery","Temp","Charging","SCRCPY")
    }

    # Ajouter "Ping", "ADBReachable", "SCRCPY" aux champs valides
    $validFields = $headsets[0].PSObject.Properties.Name.Split(";").replace('"',"") + "SCRCPY"
    $invalidFields = $FieldsToShow | Where-Object { $_ -notin $validFields }

    if ($invalidFields.Count -gt 0) {
        Write-Log "Les champs suivants sont invalides et seront ignores : $($invalidFields -join ', ')" -Level "WARNING"
    }

    $FieldsToShow = $FieldsToShow | Where-Object { $_ -in $validFields }




    # Replace True & False by OK & KO
    foreach ($headset in $headsets) {
        foreach ($field in $FieldsToShow){
            $headset | Add-Member -NotePropertyName $field -NotePropertyValue ($headset.$field -replace '\bTrue\b', 'OK' -replace '\bFalse\b', 'KO') -Force
        }
    }


    if ($headsets.Count -gt 0) {
        $headsets  | Select-Object $FieldsToShow | Format-Table -AutoSize
    } else {
        Write-Log "No headset found to display in $FilePath." -Level WARNING
    }
}


function Show-HeadsetsConfig {
    param (
            #[array]$knownHeadsetsInfosFilePath = $global:knownHeadsetsInfosFilePath,
            [array]$FieldsToShow = @("ID","Name","IPAddress","scrcpy_AutoRestart","Record","SerialNumber"),
            [bool]$UseColors = $true
        )
    $knownHeadsetsConfig = @(Import-Csv -Path $global:knownHeadsetsFilePath -Delimiter "," )

    if (-not $knownHeadsetsConfig -or $knownHeadsetsConfig.Count -eq 0) {
        Write-Log "No headset found to display in $global:knownHeadsetsFilePath." -Level INFO
        return
    }
    # display table formated with "|" as separator and colored if $UseColors is true
    if ($UseColors){

        # Déterminer la largeur de la console
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width - 1
        if ($consoleWidth -lt 0) { $consoleWidth = 80 } # Valeur par défaut

        # Définir les longueurs de padding pour chaque champ et les place dans un tableau
        $Padding = @{
            ID = 2
            Name = 15
            IPAddress = 13
            scrcpy_AutoRestart = 15
            Record = 6
        }
        
        # Créer l'en-tête du tableau
        $header = ""
        foreach ($field in $FieldsToShow) {
            $header += $field.PadRight($Padding[$field]).Substring(0,$Padding[$field]) + " | "
        }
        Write-Host $header.Substring(0, [Math]::Min($header.Length, $consoleWidth))

        # Afficher chaque ligne avec le formatage approprié
        foreach ($headset in $knownHeadsetsConfig) {
            foreach ($field in $FieldsToShow) {
                $value = $headset.$field
                
                if ($null -eq $value) {
                    $value = "-"
                }
                $fgColor = "White"
                if ($value -eq "True") {
                    $value = "OK"
                    $fgColor = "Green" 
                } elseif ($value -eq "False") {
                    $value = "KO" 
                    $fgColor = "Red"
                }

                # Print line with colors (each field with its own color)
                Write-Host "$($value.PadRight($Padding[$field]).Substring(0,$Padding[$field]))" -ForegroundColor $fgColor -NoNewline
                 Write-Host " | " -NoNewline
            }
            Write-Host "" # New line
        }
       
    } else {
        $knownHeadsetsConfig | Select-Object $FieldsToShow | Format-Table -AutoSize
    }
}

# Show-HeadsetsTableColored -FieldsToShow @("ID","Name","Ping","ADBWifi","Battery","Charging","Temp") -UseColors $true 

function Show-HeadsetsTableColored {
    param (
        [array]$knownHeadsetsInfosFilePath = $global:knownHeadsetsInfosFilePath,
        [array]$FieldsToShow = @("ID","Name","IPAddress","Ping","ADBWifi","Battery","Charging","Temp","SCRCPY","Model","SerialNumber"),
        [bool]$UseColors = $true
    )

    $knownHeadsetsInfo = @(Import-Csv -Path $knownHeadsetsInfosFilePath -Delimiter ";" )
    # Vérifier si des données sont présentes
    if (-not $knownHeadsetsInfo -or $knownHeadsetsInfo.Count -eq 0) {
        Write-Log "Aucun casque VR trouve dans le fichier $knownHeadsetsInfosFilePath." -Level WARNING
        return
    }


    if ($UseColors){

        # Déterminer la largeur de la console
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width - 1
        if ($consoleWidth -lt 0) { $consoleWidth = 80 } # Valeur par défaut



        # Définir les longueurs de padding pour chaque champ et les place dans un tableau
        $Padding = @{
            ID = 2
            Name = 15
            IPAddress = 13
            Ping = 4
            ADBWifi = 7
            Model = 7
            SerialNumber = 14
            Battery = 4
            Charging = 10
            Temp = 7
            SCRCPY = 7
        }
        

        # Créer l'en-tête du tableau
        $header = ""
        foreach ($field in $FieldsToShow) {
            $header += $field.PadRight($Padding[$field]).Substring(0,$Padding[$field]) + " | "
        }
        Write-Host $header.Substring(0, [Math]::Min($header.Length, $consoleWidth))

        # Afficher chaque ligne avec le formatage approprié
        foreach ($headset in $knownHeadsetsInfo) {
            # Déterminer la couleur de fond
            $bgColor = "$null"
            
            if ($headset.Ping -eq $False) {
                $bgColor = "DarkGray" # Casque ne répond pas
            }
            elseif ($headset.ADBWifi -eq $False) {
                $bgColor = "Black"  # l'ADB du casque ne répond pas sur le port spécifié
            }
            elseif ($headset.Temp -and [int]($headset.Temp -replace ',','.') -gt 55) {
                $bgColor = "DarkRed" # Température > 50°
            }
            elseif ($headset.Battery -and [int]($headset.Battery -replace '[^\d]','') -lt 40 -and $headset.Charging -eq $False) {
                $bgColor = "DarkRed" # Battery < 40% and not charging
            }
            elseif ($headset.Battery -and [int]($headset.Battery -replace '[^\d]','') -lt 30 -and $headset.Charging -eq $True) {
                $bgColor = "DarkYellow" # Battery < 30% and charging
            }
            elseif ($headset.Charging -eq $False) {
                $bgColor = "DarkYellow" # Casque n'est pas en charge
            }
            elseif ($headset.SCRCPY -eq "OK") {
                $bgColor = "Green" # Scrcpy est lancé
            }
            else {
                $bgColor = "White" # Couleur par défaut (tout va bien)
            }
            

            # Define the foreground color (default White)
            $fgColor = "White"
            if ($headset.SCRCPY -eq "OK" -and $bgColor -ne "Green"){
                $fgColor = "DarkGreen"
            }
            elseif ($bgColor -eq "DarkGray" -or $bgColor -eq "Black") {
                $fgColor = "Gray"
            }
            elseif ($bgColor -eq "Green" -or $bgColor -eq "White") {
                $fgColor = "Black"
            }
            elseif ($bgColor -eq "DarkYellow") {
                $fgColor = "Black"
            }


            # line to display
            $line = ""



            foreach ($field in $FieldsToShow) {
                $value = $headset.$field
                
                #convert value from 42.0 to 42 °c
                if ($field -eq "Temp" -and $value) {
                    $degree = [char]0x00B0
                    $value = $($value -replace '\,0$','')+$degree+'C'
                }
                # Ajouter le champ à la ligne
                if ($null -eq $value) {
                    $value = "-"
                }
                elseif ($value -is [bool]) {
                    $value = if ($value) { "OK" } else { "KO" }
                }
                elseif ($field -eq "ADBWifi") {
                    $value = if ($headset.ADBWifi -eq "True") { "OK" } else { "KO" }
                }
                if ($field -eq "Ping") {
                    $value = if ($headset.Ping -eq "True") { "OK" } else { "KO" }
                }

                $line += "$($value.PadRight($Padding[$field]).Substring(0,$Padding[$field])) | "
            }

            # Afficher la ligne avec les couleurs appropriées

            Write-Host $line.Substring(0, [Math]::Min($line.Length, $consoleWidth)) -BackgroundColor $bgColor -ForegroundColor $fgColor
            
        }
    } else { # Pas de couleurs
        $knownHeadsetsInfo | Select-Object $FieldsToShow | Format-Table -AutoSize
    }
}




#Add-Headset -IPAddress "192.168.1.223" -Name "Q3 Manu"
function Add-Headset {
    param (
        [array]$headsets = (Import-Csv -Path $global:knownHeadsetsFilePath),  # Valeur par defaut : fichier CSV
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$Name = "Nouveau casque"#,
        #[int]$AdbPort = 5555
    )

    #Test si le casque n'existe pas déjà avec la même @IP
    if ( $headsets.IPAddress -contains $IPAddress){
        Write-Log "Le casque avec l'IP $IPAddress existe deja dans la liste !" WARNING
        return
    }
    
    # Ajouter un nouveau casque a la liste
    $newHeadset = [PSCustomObject]@{
        ID          = ($headsets | Measure-Object).Count + 1
        Name         = $Name
        IPAddress    = $IPAddress
        scrcpy_AutoRestart = "False"
        Record       = "False"
        SerialNumber = ""
        #AdbPort      = $AdbPort
    }

    # Ajouter a la liste des casques
    $headsets += $newHeadset

    Write-Log "Ajout d'un nouveau casque : $Name ($IPAddress)" -Level INFO

    # Sauvegarder dans le fichier CSV
    Save-Headsets -headsets $headsets
} # OK

# Update-HeadsetField -ID ([int]"1") -Field "SerialNumber" -NewValue "ABC123"
function Update-HeadsetField {
    param (
        [array]$headsets = (Import-Csv -Path $global:knownHeadsetsFilePath),  # Valeur par defaut : fichier CSV
        [int]$ID,
        [string]$Field,
        [string]$NewValue
    )

    $headset = $headsets | Where-Object { $_.ID -eq $ID }

    if ($headset) {
        if ($headset.PSObject.Properties.Name -contains $Field) {
            $headset.$Field = $NewValue
            Write-Log "Champ '$Field' mis a jour pour l'ID $ID avec la valeur '$NewValue'" -Level INFO
        } else {
            Write-Log "Erreur : Le champ '$Field' n'existe pas dans la liste." -Level ERROR
        }
    } else {
        Write-Log "Erreur : Aucun casque trouve avec l'ID $ID." -Level ERROR
    }
    # Sauvegarder les modifications dans le fichier CSV
    Save-Headsets -headsets $headsets
    #return $headsets
} # OK

function Remove-Headset {
    param (
        [array]$headsets = (Import-Csv -Path $global:knownHeadsetsFilePath),
        [int]$ID
    )

    # Recherche du casque avec l'ID specifie
    $headsetToRemove = $headsets | Where-Object { $_.ID -eq $ID }

    if ($headsetToRemove) {
        # Supprimer le casque de la liste
        $headsets = $headsets | Where-Object { $_.ID -ne $ID }
        Write-Log "Le casque avec l'ID $ID $($headsetToRemove.Name) a ete supprime." -Level INFO
    } else {
        Write-Log "Erreur : Aucun casque trouve avec l'ID $ID." -Level ERROR
    }
    # Sauvegarder les modifications dans le fichier CSV
    Save-Headsets -headsets $headsets
    #return $headsets
} #OK

function Save-Headsets {
    param (
        [Parameter(Mandatory = $true)][array]$headsets,
        [string]$FilePath = $global:knownHeadsetsFilePath 
    )

    # Reorganiser les ID a partir de 1
    $newHeadsets = $headsets | Sort-Object ID
    $newID = 1
    foreach ($headset in $newHeadsets) {
        $headset.ID = $newID
        $newID++
    }

    # Sauvegarder dans le fichier CSV
    $newHeadsets | Export-Csv -Path $FilePath -NoTypeInformation -Encoding UTF8
    Write-Log "Les casques ont ete reorganises et enregistres dans '$FilePath'." -Level INFO
    Write-htmlMonitor $newHeadsets
} #OK


function Add-Headset-Manually {
    # Effacer l'ecran
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== AJOUT MANUEL D'UN CASQUE ===" -BackgroundColor Green -ForegroundColor Black

    # Demander les informations necessaires
    $name = Read-Host "Nom du casque (obligatoire)"
    if (-not $name) {
        Write-Host "Le nom est obligatoire. Abandon." -ForegroundColor Red
        return
    }

    $ip = Read-Host "Adresse IP du casque (obligatoire)"
    if (-not (Test-ValidIPv4 $ip)) {
        Write-Host "Une adresse IP valide est obligatoire. Abandon." -ForegroundColor Red
        return
    }

    # Champs facultatifs
    #$adbPortInput = Read-Host "Port ADB (optionnel, defaut: 5555)"

    # Traitement des valeurs par defaut
<#
    if ([string]::IsNullOrWhiteSpace($adbPortInput)) {
        $adbPort = 5555
    } else {
        $adbPort = [int]$adbPortInput
    }
 #>
    # Appel de la fonction principale
    Add-Headset -IPAddress $ip -Name $name #-adbPort $adbPort

    Write-Host "Casque ajoute avec succes !" -ForegroundColor Cyan
} #OK
