#Load-Config -ConfigFilePath $ConfigFilePath
# Function to load configuration variables from a JSON file
function Get-Config {
    param (
        [string]$ConfigFilePath
    )
    
    Write-Host "DEBUG ConfigFilePath = $ConfigFilePath" -ForegroundColor Magenta
    
    # Check whether the file exists
    if (-not (Test-Path $ConfigFilePath)) {
        Write-Host "Configuration file does not exist..." -ForegroundColor Red
        return $false
    }

    # Read and validate the JSON file content
    $configContent = $null
    $jsonValid = $false
    while (-not $jsonValid) {
        try {
            $jsonRaw = Get-Content -Path $ConfigFilePath -Raw -ErrorAction Stop
            $configContent = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
            $jsonValid = $true
        }
        catch {
            Write-Host ""
            Write-Host "  *** INVALID JSON: The configuration file contains a syntax error! ***" -ForegroundColor Red -BackgroundColor Black
            Write-Host "  File  : $ConfigFilePath" -ForegroundColor Yellow
            Write-Host "  Error : $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Opening an online JSON validator in your default browser..." -ForegroundColor Cyan
            Start-Process "https://jsonlint.com"
            Write-Host ""
            Write-Host "  What do you want to do?" -ForegroundColor White
            Write-Host "    [R] Reload   - Edit and save the file, then press R to retry" -ForegroundColor White
            Write-Host "    [T] Template - Overwrite config.json with the default template" -ForegroundColor White
            Write-Host "                   (WARNING: your current config will be lost!)" -ForegroundColor DarkYellow
            Write-Host "    [Q] Quit     - Exit the application" -ForegroundColor White
            Write-Host ""
            $choice = (Read-Host "  Your choice [R/T/Q]").Trim().ToUpper()
            switch ($choice) {
                'R' {
                    Write-Host "  Retrying to load '$ConfigFilePath'..." -ForegroundColor Cyan
                    # Loop will re-read the file on the next iteration
                }
                'T' {
                    $templatePath = Join-Path -Path $global:ScriptPath -ChildPath "templates\config\config.json"
                    if (Test-Path $templatePath) {
                        Copy-Item -Path $templatePath -Destination $ConfigFilePath -Force
                        Write-Host "  Default template restored to '$ConfigFilePath'." -ForegroundColor Green
                        Write-Host "  Opening the file in Notepad — please fill in your settings, then restart." -ForegroundColor Yellow
                        notepad $ConfigFilePath
                        Start-Sleep -Seconds 3
                    }
                    else {
                        Write-Host "  Template not found at '$templatePath'. Cannot restore." -ForegroundColor Red
                        Write-Host "  Please fix '$ConfigFilePath' manually, then restart." -ForegroundColor Yellow
                    }
                    exit 1
                }
                'Q' {
                    Write-Host "  Exiting..." -ForegroundColor Yellow
                    exit 1
                }
                default {
                    Write-Host "  Unknown option '$choice'. Please enter R, T or Q." -ForegroundColor Yellow
                    # Loop again without counting it as a new attempt
                }
            }
        }
    }
    $sourcesPath = Join-Path -Path $global:ScriptPath -ChildPath "sources"


    # Load mandatory global variables from the JSON file
    $global:SelectedLanguage = $configContent.language
    Write-Host "DEBUG global:SelectedLanguage = $($global:SelectedLanguage)" -Level DEBUG
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


    # Verify the loaded variables
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

    # GLOBAL VARIABLES FOR SCRCPY PROCESS TRACKING AND AUTO-RESTART
    $global:scrcpyProcesses = @() #will keep track of launched scrcpy processes
    $global:scrcpyRestartAuto = $true
    
    Write-Log "Configuration variables successfully loaded" -Level DEBUG
} # OK

# Verifies that the known headsets file is valid
function Test-KnownHeadsetsFile {
    [CmdletBinding()]
    param (
        [string]$FilePath = $global:knownHeadsetsFilePath
    )

    # Check if file exists
    if (-not (Test-Path -Path $FilePath)) {
        Write-Log -Message ($msg.CsvFileNotFound -f $FilePath) -Level WARNING
        return $false
    }

    try {
        # Attempt to import CSV
        $content = Import-Csv -Path $FilePath
        if (-not $content){
            Write-Log -Message $msg.CsvFileEmpty -Level WARNING
            return $false
        }
        # Check headers
        $requiredHeaders = @("ID", "Name", "IPAddress","scrcpy_AutoRestart","Record","SerialNumber")
        $actualHeaders = $content | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name

        $headerMatch = Compare-Object -ReferenceObject $requiredHeaders -DifferenceObject $actualHeaders -PassThru
        if ($headerMatch) {
            Write-Log -Message $msg.CsvHeadersMismatch -Level WARNING
            return $false
        }

        # Check at least one data row exists
        if ($content.Count -eq 0) {
            Write-Log -Message $msg.CsvNoDataRows -Level WARNING
            return $false
        }

        Write-Log -Message $msg.CsvValidationPassed -Level INFO
        return $true
    }
    catch {
        Write-Log -Message ($msg.CsvValidationError -f $_) -Level ERROR
        return $false
    }
}