#Load-Config -ConfigFilePath $ConfigFilePath
# Fonction pour charger les variables de configuration depuis un fichier JSON
function Get-Config {
    param (
        [string]$ConfigFilePath
    )
    
    Write-Host "DEBUG ConfigFilePath = $ConfigFilePath" -ForegroundColor Magenta
    
    # Verifier si le fichier existe
    if (-not (Test-Path $ConfigFilePath)) {
        Write-Host "Configuration file does not exist..." -ForegroundColor Red
        return $false
    }

    # Lire le contenu du fichier JSON
    #$configContent = Get-Content -Path $ConfigFilePath | Out-String | ConvertFrom-Json
    $configContent = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $sourcesPath = Join-Path -Path $global:ScriptPath -ChildPath "sources"


    # Charger les variables globales obligatoires a partir du fichier JSON
    $global:knownHeadsetsFile = $configContent.Paths.knownHeadsetsFile
    Write-Host "DEBUG global:knownHeadsetsFile = $($global:knownHeadsetsFile)" -ForegroundColor Magenta
    
    $global:knownHeadsetsFilePath       = Join-Path -Path $(Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath $global:knownHeadsetsFile
    $global:knownHeadsetsInfosFilePath  = Join-Path -Path $(Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath $($global:knownHeadsetsFile).Replace(".csv","_infos.csv")

    $global:knownHeadsetsSCRCPYFilePath = Join-Path -Path $(Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath $($global:knownHeadsetsFile).Replace(".csv","_SCRCPY.csv")
    $global:scrcpyFolder = Join-Path -Path $sourcesPath -ChildPath $configContent.scrcpy.folder
    $global:scrcpyFilePath = Join-Path -Path $global:scrcpyFolder -ChildPath "scrcpy.exe" 
    [PSCustomObject]$global:scrcpyParameters = @($configContent.scrcpy.parameters)
    if ($configContent.scrcpy.recordFolder -contains "\" -or "/" ) {
        $global:scrcpyRecordFolder = $configContent.scrcpy.recordFolder
    } else {
        $global:scrcpyRecordFolder = Join-Path -Path $global:ScriptPath -ChildPath $configContent.scrcpy.recordFolder
    }
   

    $global:ADBWirelessActivatorAPK = Join-Path -Path $(Join-Path -Path $sourcesPath -ChildPath $configContent.apk.adbWirelessActivatorFolder) -ChildPath $configContent.apk.adbWirelessActivatorApk
    $global:ADBWirelessActivatorPackageName = $configContent.apk.adbWirelessActivatorPackageName

    $global:WIFI_SSID = $configContent.WIFI.wifi_ssid
    $global:WIFI_PWD = $configContent.WIFI.wifi_pwd

    $global:VRMonitor_refresh_timer = $configContent.VRMonitor.refresh_timer

    $global:adbFolder = Join-Path -Path $sourcesPath -ChildPath $configContent.ADB.folder
    $global:adbPath = Join-Path -Path $global:adbFolder -ChildPath "adb.exe"
    $global:adbPort_default = $configContent.ADB.adbPort_default


    $global:OBS_headsetTemplate = Join-Path -Path $global:ScriptPath -ChildPath ("\OBS\template\"+$configContent.OBS.HeadsetTemplate)
    $global:OBS_battery_lowLevel = $configContent.OBS.headsets_triggers.battery_lowLevel
    $global:OBS_temperature_highLevel = $configContent.OBS.headsets_triggers.temperature_highLevel

   
    # Charge of logging configuration variables with validation and default values
    #get computer name
    $global:computerName = $env:COMPUTERNAME
    $global:logFolder = $(Join-Path -Path $global:ScriptPath -ChildPath "Logs\$($global:computerName)")
    #create log folder if it does not exist
    if (-not (Test-Path $global:logFolder)) {
        New-Item -Path $global:logFolder -ItemType Directory -Force | Out-Null
    }
    # Generate log file name with current date
    $dateString = Get-Date -Format "yyyy-MM-dd"
    $global:logFile = Join-Path -Path $global:logFolder -ChildPath "log_$dateString.txt"
    
    $global:debugLevelToFile = $configContent.Logging.debugLevelToFile
    $global:debugLevelToConsole = $configContent.Logging.debugLevelToConsole



    $validLogLevels = @("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "NONE")
    if ($global:debugLevelToFile -notin $validLogLevels) {
        Write-Host "Unknown display log level: $global:debugLevelToFile. Set 'DEBUG' as default." -ForegroundColor Yellow
        $global:debugLevelToConsole = "DEBUG"
    }
    if ($global:debugLevelToConsole -notin $validLogLevels) {
        Write-Host "Unknown console log level: $global:debugLevelToConsole. Set 'DEBUG' as default." -ForegroundColor Yellow
        $global:debugLevelToConsole = "DEBUG"
    }


    # Verifier les variables chargees
    Write-Log "ScriptFolder: $global:ScriptPath" -Level DEBUG
    Write-Log "adbPort_default: $global:adbPort_default" -Level DEBUG
    Write-Log "adbFolder: $global:adbFolder" -Level DEBUG
    Write-Log "scrcpyFolder: $global:scrcpyFolder" -Level DEBUG
    Write-Log "ADBWirelessActivator APK path  $global:ADBWirelessActivator" -Level DEBUG
    Write-Log "debugLevelToFile: $global:debugLevelToFile" -Level DEBUG
    Write-Log "debugLevelToConsole: $global:debugLevelToConsole" -Level DEBUG
    Write-Log "logFolder: $global:logFolder" -Level DEBUG
    Write-Log "logFile: $global:logFile" -Level DEBUG

    $requiredVars = @("knownHeadsetsFile", "adbPort_default", "adbFolder", "scrcpyFolder","logFolder", "logFile")
   
    foreach ($var in $requiredVars) {
        if (-not (Get-Variable -Name $var -ErrorAction SilentlyContinue)) {
            Write-Host "Error : Variable $var is incorrectly set in the configuration file !" -ForegroundColor Red
        }
    }

    # VARIABLES GLOBALES POUR LE SUIVI DES PROCESS SCRCPY ET RELANCEMENT AUTOMATIQUE
    $global:scrcpyProcesses = @() #permettra de conserver une trace des process scrcpy lances
    $global:scrcpyRestartAuto = $true
    
    Write-Log "Configuration variables successfully loaded" -Level DEBUG
} # OK

# Vérifie que le fichier de casques connus est OK
function Test-KnownHeadsetsFile {
    [CmdletBinding()]
    param (
        [string]$FilePath = $global:knownHeadsetsFilePath
    )

    # Check if file exists
    if (-not (Test-Path -Path $FilePath)) {
        Write-Log -Message "Headset CSV file does not exist at path: $FilePath" -Level WARNING
        return $false
    }

    try {
        # Attempt to import CSV
        $content = Import-Csv -Path $FilePath
        if (-not $content){
            Write-Log -Message "CSV file empty or do not match requirements." -Level WARNING
            return $false
        }
        # Check headers
        $requiredHeaders = @("ID", "Name", "IPAddress","scrcpy_AutoRestart","Record","SerialNumber")
        $actualHeaders = $content | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name

        $headerMatch = Compare-Object -ReferenceObject $requiredHeaders -DifferenceObject $actualHeaders -PassThru
        if ($headerMatch) {
            Write-Log -Message "CSV file headers do not match requirements. Missing or extra headers detected." -Level WARNING
            return $false
        }

        # Check at least one data row exists
        if ($content.Count -eq 0) {
            Write-Log -Message "CSV file exists with correct headers but contains no data rows." -Level WARNING
            return $false
        }

        Write-Log -Message "CSV file validation passed: correct headers and contains data." -Level INFO
        return $true
    }
    catch {
        Write-Log -Message "Error validating headset CSV file: $_" -Level ERROR
        return $false
    }
}