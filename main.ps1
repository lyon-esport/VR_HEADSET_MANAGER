## -*- coding: utf-8 -*-
# Initialisation du type d'encodage du texte en UTF8
#[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#[Console]::InputEncoding = [System.Text.Encoding]::UTF8


<#
.SYNOPSIS
VR HEADSET MANAGER
Controleur principal pour la gestion des captures VR
#>



<#

Voies d'améliorations :

- Edition du fichier de config à la main
    > Revérif à chaque refresh que le fichiers est bien formaté
    > Simplifier le fichier de config : Name;IP
- Optimisation refresh : lire uniquement les infos du fichier de config, et ne pas lancer un ping + test port à chaque refresh > laisser faire au job en tache de fond
    - Faire un test de ping plus efficace (et pas au chargement du choix des casques à streamer)
    --> Faire un 2eme fichier de HeadsetFollowup rempli automatiquement par le script ci-dessous
    - lancer une fenetre en backgroud qui ping, check le port, et restart le stream automatiquement, et maj le fichier de HeadsetFollowup
    - Lors du scan, vérifier si un stream portant le même nom est déjà lancé

- Au menu principal, taper directement le n° de casque à stream
    - entree pour afficher les infos du HeadsetFollowup
    - ajouter le flag StreamAutoRestart dans le fichier de followup
    - Si on retape le même numéro, ça kill le stream en cours, et ça arrête de le rouvrir automatiquement
- au menu principal > une touche pour activer ADB Wirelss pour un device connecté en usb directement (genre la touche + du clavier...)
- Customiser les paramètres de scrcpy dans le fichier de cfg json et pas dans le script directement
- Lors de l'installation de l'apk ADB Wireless ou de l'activation de stream, ajouter automatiquement le casque si le S/N n'est pas deja connu
    > 0 pour le nom du casque si pas envie de l'ajouter
- touche "+" pour activer le WIFI ADB sur un casque connecté en USB.
- Ajouter une fonction de refresh des paramètres d'entrée (touche R ?) pour prendre en compte les MAJ des fichiers modules et du fichier de cfg json.

- check etat du casque si essaie : wifi unauthorized, pas d'adb activé, mode développeur pas activé...
- Autoriser adb.exe dans le pare-feu Windows au lancement du logiciel (prompt firewall)

- Forcer le démarrage du deamon ADB au lancement du script s'il est arrêté

#>

# Fallback si $PSScriptRoot n'est pas disponible (ex: execution en ligne de commande)
#$global:ScriptPath = if ($PSScriptRoot) {$PSScriptRoot} else {"L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER"}



#Check on startup the main script if it can identify where it is, and make sure it finds the path of $PSScriptRoot. Otherwise, check if the current execution is in a folder whose name contains "VR_HEADSET_MANAGER".
#Load the path into the global variable $global:ScriptPath

#Welcome message
Write-Host "Welcome to VR HEADSET MANAGER!" -ForegroundColor Green
Write-Host "Starting the initialization process..." -ForegroundColor Green

$global:custom_config = $args[0] 
if ($global:custom_config) {
    Write-Host "Custom config file passed as argument: $global:custom_config" -ForegroundColor Green
} else {
    Write-Host "No custom config file passed as argument. Starting process with default config file path." -ForegroundColor Yellow
}

# Get the current script path
$global:ScriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# check if the current folder name is "modules", if yes, move up one level
if ((Split-Path $global:ScriptPath -Leaf) -eq "modules") {
    $global:ScriptPath = Split-Path $global:ScriptPath -Parent
}

if ((Split-Path $global:ScriptPath -Leaf) -notmatch "VR_HEADSET_MANAGER") {
    Write-Host "Error: Please run this script from a folder containing 'VR_HEADSET_MANAGER'." -ForegroundColor Red
    Read-Host "Press enter for exit"
    exit
}


########################## INITIALISATION ##########################


# Check if folders exists in the same folder as the script, otherwise create them
$requiredFolders = @("config","data","logs","OBS")
foreach ($folder in $requiredFolders) {
    $folderPath = Join-Path -Path $global:ScriptPath -ChildPath $folder
    if (-not (Test-Path -Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath | Out-Null
        Write-Host "Created missing folder: $folder" -ForegroundColor Yellow
    }
}


# Check if config file exists, if not create it from template file and open it for edit
if $custom_config {
    $configFilePath = $custom_config
} else {
    $configFilePath = Join-Path -Path $global:ScriptPath -ChildPath "config\config.json"
}

if (-not (Test-Path -Path $configFilePath)) {
    $templateConfigPath = Join-Path -Path $global:ScriptPath -ChildPath "template\config.json"
    if (Test-Path -Path $templateConfigPath) {
        Copy-Item -Path $templateConfigPath -Destination $configFilePath
        Write-Host "Config file created from template at: $configFilePath" -ForegroundColor Green
        
        $REPLY = Read-Host "Do you want to edit the config file now with your default file editor? (Y/N)" -ForegroundColor Yellow
        if ($REPLY -match '^[Yy]$') {
            # Open the config file in the default text editor
            Start-Process -FilePath $configFilePath
        } else {
            Write-Host "You can edit the config file later at: $configFilePath" -ForegroundColor Green
        }

    } else {
        Write-Host "Error: Template config file is missing!" -ForegroundColor Red
        Read-Host "Press enter for exit"
        exit 1
    }
} else {
    Write-Host "Config file found at: $configFilePath" -ForegroundColor Green
}


#Unblock all scripts in the module folder (in case they were blocked by Windows)
Get-ChildItem -Path $global:ScriptPath -Filter "*.ps1" -Recurse | Unblock-File

# Import modules files (must be executed at global level, and cannot start in a function !)
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (Test-Path -Path $scripts_init) {
    . $scripts_init
} else {
    Write-Host "Error: The initialization modules script is missing!" -ForegroundColor Red
    Read-Host "Press enter for exit"
    exit
}


# File initialization of the known headsets list file
    #$global:knownHeadsetsFilePath = "$ScriptPath\data\known_headsets.csv"
    $global:knownHeadsets = @()
    if ((Test-Path $global:knownHeadsetsFilePath) -or (Test-KnownHeadsetsFile($global:knownHeadsetsFilePath))) {
        $global:knownHeadsets = @(Import-Csv -Path $global:knownHeadsetsFilePath)
    } else {
        Write-Log "The known headsets file does not exist or is not correct, initializing!" -Level WARNING
        $headers = "ID","Name","IPAddress","scrcpy_AutoRestart","Record","SerialNumber"
        $headers -join "," | Out-File -FilePath $global:knownHeadsetsFilePath -Encoding UTF8
    }

# Data file initialization of the headsets infos file
$global:knownHeadsetsInfosFilePath = "$ScriptPath\data\known_headsets_infos.csv"
$global:knownHeadsetsInfos = @()
$headerLine = '"ID","Name","IPAddress","AdbPort","Ping","ADBWifi","Brand","Model","SerialNumber","BatteryLevel","Charging","Scrcpy","LastUpdateTimeStamp"'
$headerLine | Out-File -FilePath $global:knownHeadsetsInfosFilePath -Encoding UTF8



######################
######## MAIN ########
######################

# Stard ADB Server if not already started
$null = Start-AdbServer -adbPath $global:adbPath

#Start auto checks of headsets details
Start-VRMonitor -VRMonitor_refresh_timer $global:VRMonitor_refresh_timer

# Open the VR Monitor in a new PowerShell window
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

Write-Host "Waiting 5 seconds before showing the main menu... " -ForegroundColor Yellow -NoNewline
    for ($i = 4; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
Write-Host "`n"


# Starting the main menu function that will show the different options to the user
Show-MainMenu




