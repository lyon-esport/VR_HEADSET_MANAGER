#Load-Config -ConfigFilePath $ConfigFilePath

function Read-ConfigJson {
    <#
    .SYNOPSIS
    Reads and validates a JSON config file interactively.

    .DESCRIPTION
    Attempts to parse the file as JSON. On failure, shows the parse error,
    opens an online validator, and prompts the user to [R]eload, restore
    the [T]emplate, or [Q]uit. Loops until valid JSON is obtained.
    Returns the parsed object on success.

    .PARAMETER NonInteractive
    When set, returns $null on parse failure instead of prompting. Use for
    callers that cannot block on console input (web request handlers, jobs).
    #>
    param (
        [string]$ConfigFilePath,
        [switch]$NonInteractive
    )

    $configContent = $null
    $jsonValid = $false
    while (-not $jsonValid) {
        try {
            $jsonRaw = Get-Content -Path $ConfigFilePath -Raw -ErrorAction Stop
            $configContent = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
            $jsonValid = $true
        }
        catch {
            if ($NonInteractive) {
                try { Write-Log ("Read-ConfigJson: parse failed in non-interactive mode: " + $_.Exception.Message) -Level WARNING } catch { }
                return $null
            }
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
                        Write-Host "  Opening the file in Notepad - please fill in your settings, then restart." -ForegroundColor Yellow
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
    return $configContent
}

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
    $configContent = Read-ConfigJson -ConfigFilePath $ConfigFilePath
    $sourcesPath = Join-Path -Path $global:ScriptPath -ChildPath "sources"


    # Load mandatory global variables from the JSON file
    $global:SelectedLanguage = $configContent.language
    Write-Host "Config: SelectedLanguage = $($global:SelectedLanguage)"
    $global:knownHeadsetsFile = $configContent.Paths.knownHeadsetsFile
    Write-Host "Config: knownHeadsetsFile = $($global:knownHeadsetsFile)"
    
    $global:knownHeadsetsFilePath       = Join-Path -Path $(Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath $global:knownHeadsetsFile
    $global:knownHeadsetsInfosFilePath  = Join-Path -Path $(Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath $($global:knownHeadsetsFile).Replace(".csv","_infos.csv")
    
    $global:AppCacheFileName = $configContent.Paths.AppCacheFileName
    $global:AppCacheFilePath = Join-Path -Path $(Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath $global:AppCacheFileName

    # Migrate app_names.csv -> known_apps.csv automatically
    if ($global:AppCacheFilePath -like "*app_names.csv") {
        $newPath = $global:AppCacheFilePath -replace 'app_names\.csv$', 'known_apps.csv'
        if ((Test-Path -LiteralPath $global:AppCacheFilePath) -and -not (Test-Path -LiteralPath $newPath)) {
            Rename-Item -LiteralPath $global:AppCacheFilePath -NewName (Split-Path $newPath -Leaf) -ErrorAction SilentlyContinue
        }
        $configContent.Paths.AppCacheFileName = 'known_apps.csv'
        try { $configContent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigFilePath -Encoding UTF8 } catch {}
        $global:AppCacheFileName = 'known_apps.csv'
        $global:AppCacheFilePath = $newPath
        Write-Host "Config: migrated app_names.csv to known_apps.csv"
    }


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

    $global:VRMonitor_refresh_timer = $configContent.VRMonitor.refresh_timer

    # ComputerMonitoring
    $global:ComputerMonitoring_refresh_timer_sec = if ($null -ne $configContent.ComputerMonitoring.refresh_timer_sec) { [int]$configContent.ComputerMonitoring.refresh_timer_sec } else { 60 }
    $computerMonitoringFileName = if ($configContent.ComputerMonitoring.file_name) { $configContent.ComputerMonitoring.file_name } else { "computer_monitoring.json" }
    $global:computerMonitoringFilePath = Join-Path -Path $global:ScriptPath -ChildPath "data\$computerMonitoringFileName"

    # VideoQualityAutomation (VQA) - master switch + VQO sub-flag + thresholds
    if ($null -ne $configContent.VideoQualityAutomation) {
        $vqa = $configContent.VideoQualityAutomation
        $global:VQA_Enabled                = [bool]$vqa.enabled
        # Per-section auto-apply flags (replace legacy enabled_VQO). When the legacy
        # field is still present and a per-section flag is missing, the legacy value
        # is mirrored - keeps behaviour identical on upgrade.
        $legacyVqo = if ($null -ne $vqa.enabled_VQO) { [bool]$vqa.enabled_VQO } else { $null }
        $global:VQA_AutoApplyProfiles = if ($null -ne $vqa.auto_apply_profiles) { [bool]$vqa.auto_apply_profiles } elseif ($null -ne $legacyVqo) { $legacyVqo } else { $false }
        $global:VQA_AutoApplyHeadsets = if ($null -ne $vqa.auto_apply_headsets) { [bool]$vqa.auto_apply_headsets } elseif ($null -ne $legacyVqo) { $legacyVqo } else { $false }
        $global:VQA_AutoApplyMediaMtx = if ($null -ne $vqa.auto_apply_mediamtx) { [bool]$vqa.auto_apply_mediamtx } elseif ($null -ne $legacyVqo) { $legacyVqo } else { $false }
        $global:VQA_CooldownCycles    = if ($null -ne $vqa.cooldown_cycles) { [int]$vqa.cooldown_cycles } else { 5 }
        $global:VQA_CooldownFilePath  = Join-Path -Path $global:ScriptPath -ChildPath "data\vqa_cooldown.json"
        # Derived OR for any old call site still reading the legacy global.
        $global:VQA_EnabledVQO        = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
        $global:VQA_CpuMaxThreshold        = if ($null -ne $vqa.cpu_max_threshold_percent) { [int]$vqa.cpu_max_threshold_percent } else { 80 }
        $global:VQA_GpuMaxThreshold        = if ($null -ne $vqa.gpu_max_threshold_percent) { [int]$vqa.gpu_max_threshold_percent } else { 80 }
        $global:VQA_CpuMitigationThreshold = if ($null -ne $vqa.cpu_mitigation_threshold_percent) { [int]$vqa.cpu_mitigation_threshold_percent } else { 60 }
        $global:VQA_GpuMitigationThreshold = if ($null -ne $vqa.gpu_mitigation_threshold_percent) { [int]$vqa.gpu_mitigation_threshold_percent } else { 60 }
        $global:VQA_DownscaleStepPercent   = if ($null -ne $vqa.downscale_step_percent) { [int]$vqa.downscale_step_percent } else { 20 }
        $global:VQA_FpsRoundStep           = if ($null -ne $vqa.fps_round_step) { [int]$vqa.fps_round_step } else { 5 }
        $global:VQA_MinMaxSize             = if ($null -ne $vqa.min_max_size_px) { [int]$vqa.min_max_size_px } else { 480 }
        $global:VQA_MinFps                 = if ($null -ne $vqa.min_fps) { [int]$vqa.min_fps } else { 15 }
        $global:VQA_MinBitrateMbps         = if ($null -ne $vqa.min_bitrate_mbps) { [int]$vqa.min_bitrate_mbps } else { 2 }
        $global:VQA_DefaultUncappedMaxSize = if ($null -ne $vqa.default_uncapped_max_size_px) { [int]$vqa.default_uncapped_max_size_px } else { 1280 }
        $global:VQA_VqoConsecutiveCount    = if ($null -ne $vqa.vqo_consecutive_count) { [int]$vqa.vqo_consecutive_count } else { 5 }
        $historyName        = if ($vqa.history_file_name)        { $vqa.history_file_name }        else { "vqa_history.csv" }
        $recommendationName = if ($vqa.recommendation_file_name) { $vqa.recommendation_file_name } else { "vqa_recommendation.json" }
        $originalsName      = if ($vqa.originals_file_name)      { $vqa.originals_file_name }      else { "vqa_originals.json" }
        $appliedName        = if ($vqa.applied_file_name)        { $vqa.applied_file_name }        else { "vqa_applied.json" }
        $global:VQA_HistoryFilePath        = Join-Path -Path $global:ScriptPath -ChildPath "data\$historyName"
        $global:VQA_RecommendationFilePath = Join-Path -Path $global:ScriptPath -ChildPath "data\$recommendationName"
        $global:VQA_OriginalsFilePath      = Join-Path -Path $global:ScriptPath -ChildPath "data\$originalsName"
        $global:VQA_AppliedFilePath        = Join-Path -Path $global:ScriptPath -ChildPath "data\$appliedName"
    } else {
        $global:VQA_Enabled           = $false
        $global:VQA_EnabledVQO        = $false
        $global:VQA_AutoApplyProfiles = $false
        $global:VQA_AutoApplyHeadsets = $false
        $global:VQA_AutoApplyMediaMtx = $false
        $global:VQA_CooldownCycles    = 5
        $global:VQA_CooldownFilePath  = Join-Path -Path $global:ScriptPath -ChildPath "data\vqa_cooldown.json"
    }

    $global:adbFolder = Join-Path -Path $sourcesPath -ChildPath $configContent.ADB.folder
    $global:adbPath = Join-Path -Path $global:adbFolder -ChildPath "adb.exe"
    $global:adbPort_default = $configContent.ADB.adbPort_default


    $global:Monitoring_headsetTemplate = Join-Path -Path $global:ScriptPath -ChildPath ("\website\template\"+$configContent.Monitoring.HeadsetTemplate)
    $videoTemplateName = if ($configContent.Monitoring.VideoTemplate) { $configContent.Monitoring.VideoTemplate } else { "headset_scrcpy.pshtml" }
    $global:Monitoring_videoTemplate    = Join-Path -Path $global:ScriptPath -ChildPath ("\website\template\"+$videoTemplateName)
    $global:Monitoring_temperature_highLevel = $configContent.Monitoring.thresholds.temperature_highLevel
    $global:Monitoring_headset_battery_warningLevel      = if ($null -ne $configContent.Monitoring.thresholds.headset_battery_warningLevel)      { [int]$configContent.Monitoring.thresholds.headset_battery_warningLevel      } else { 40 }
    $global:Monitoring_headset_battery_criticalLevel     = if ($null -ne $configContent.Monitoring.thresholds.headset_battery_criticalLevel)     { [int]$configContent.Monitoring.thresholds.headset_battery_criticalLevel     } else { 30 }
    $global:Monitoring_controllers_battery_warningLevel  = if ($null -ne $configContent.Monitoring.thresholds.controllers_battery_warningLevel)  { [int]$configContent.Monitoring.thresholds.controllers_battery_warningLevel  } else { 30 }
    $global:Monitoring_controllers_battery_criticalLevel = if ($null -ne $configContent.Monitoring.thresholds.controllers_battery_criticalLevel) { [int]$configContent.Monitoring.thresholds.controllers_battery_criticalLevel } else { 20 }

    # mediamtx restream server
    if ($configContent.mediamtx) {
        $global:mediamtxEnabled      = [bool]$configContent.mediamtx.enabled
        $global:mediamtxLogLevel     = if ($configContent.mediamtx.log_level) { $configContent.mediamtx.log_level } else { 'info' }
        $global:mediamtxFolder       = Join-Path -Path $sourcesPath -ChildPath $configContent.mediamtx.folder
        $global:mediamtxFilePath     = Join-Path -Path $global:mediamtxFolder -ChildPath "mediamtx.exe"
        $global:mediamtxYmlPath      = Join-Path -Path $global:ScriptPath -ChildPath "config\mediamtx_headsets.yml"
        $global:mediamtxRtspPort     = $configContent.mediamtx.rtsp_port
        $global:mediamtxHlsPort      = $configContent.mediamtx.hls_port
        $global:mediamtxWebrtcPort   = $configContent.mediamtx.webrtc_port
        $global:mediamtxApiPort      = $configContent.mediamtx.api_port
        $global:mediamtxFramerate    = $configContent.mediamtx.stream_framerate
        $global:mediamtxBitrate      = $configContent.mediamtx.stream_bitrate
    } else {
        $global:mediamtxEnabled = $false
    }
    # ffmpeg.exe
    $ffmpegFolder = if ($configContent.ffmpeg) { $configContent.ffmpeg.folder } else { "ffmpeg" }
    $global:ffmpegFilePath = Join-Path -Path $sourcesPath -ChildPath "$ffmpegFolder\ffmpeg.exe"

    # Web server
    $global:WebServer_enabled = if ($null -ne $configContent.WebServer.enabled) { [bool]$configContent.WebServer.enabled } else { $false }
    $global:WebServer_port    = if ($configContent.WebServer.port)               { [int]$configContent.WebServer.port }    else { 8080 }

    # VR Monitor console visibility
    $global:Dashboard_showConsole = if ($null -ne $configContent.VRMonitor.showConsole) { [bool]$configContent.VRMonitor.showConsole } else { $false }

   
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

    # Log files retention policy (days). Default 30; clamp invalid values.
    $parsedRetention = $null
    if ($null -ne $configContent.Logging.logRetentionDays) {
        $parsedRetention = $configContent.Logging.logRetentionDays -as [int]
    }
    if ($null -eq $parsedRetention -or $parsedRetention -lt 1) {
        if ($null -ne $configContent.Logging.logRetentionDays) {
            Write-Host "Invalid Logging.logRetentionDays value: '$($configContent.Logging.logRetentionDays)'. Using default of 30 days." -ForegroundColor Yellow
        }
        $global:logRetentionDays = 30
    } else {
        $global:logRetentionDays = [int]$parsedRetention
    }



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

    # Battery config
    $global:headset_charging_power_W = 13
    if ($null -ne $configContent.Battery.headset_charging_power_W) {
        $global:headset_charging_power_W = [double]$configContent.Battery.headset_charging_power_W
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