#Execute everything on the global scope
# Import of module files (must be executed at the global level, and cannot start in a function!)
# Following code should be added in any script that needs to import all modules :
<#
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (Test-Path -Path $scripts_init) {
    . $scripts_init
} else {
    Write-Host "Error: The module initialization script was not found!" -ForegroundColor Red
    exit
}

#>


# Install or import EPS module
    if (-not (Get-Module -ListAvailable -Name EPS)) {
        Install-Module -Name EPS -Scope CurrentUser -Force
    } 
    else {
        Import-Module EPS
    }
# Install or import Pode module
    if (-not (Get-Module -ListAvailable -Name Pode)) {
        Install-Module -Name Pode -Scope CurrentUser -Force
    } 
    else {
        Import-Module Pode
    }


# Get the base path
$global:ScriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Check whether we are in the modules folder and move up one level if necessary
if ((Split-Path $global:ScriptPath -Leaf) -eq "modules") {
    $global:ScriptPath = Split-Path $global:ScriptPath -Parent
}

# Check we are in VR_HEADSET_MANAGER folder
if ((Split-Path $global:ScriptPath -Leaf) -ne "VR_HEADSET_MANAGER") {
    Write-Host "Error: Please run this script from the 'VR_HEADSET_MANAGER' folder." -ForegroundColor Red
    exit 1
}


$ModulesPath = Join-Path -Path $global:ScriptPath -ChildPath "modules"
    if (-not (Test-Path -Path $ModulesPath -PathType Container)) {
            Write-Warning "The script cannot continue without the modules folder $ModulesPath."
            return
    }

$moduleFiles = Get-ChildItem -Path $ModulesPath -Filter "*.ps1" -File | Sort-Object Name | 
    Where-Object { 
        $_.Name -notlike "*_init.ps1" -and 
        $_.Name -notlike "headsets_dashboard.ps1" -and
        $_.Name -notlike "*_test.ps1"
    }

    if (-not $global:moduleSnapshots) { $global:moduleSnapshots = @{} }

    foreach ($file in $moduleFiles) {
        try {
            # Skip if already loaded and not modified since last load
            $lastWrite = $file.LastWriteTime
            if ($global:moduleSnapshots.ContainsKey($file.FullName) -and
                $global:moduleSnapshots[$file.FullName] -eq $lastWrite) {
                Write-Host "[SKIP] Module $($file.Name) unchanged" -ForegroundColor DarkGray
                continue
            }
            # Dot-source the file so its functions become available
            . $file.FullName
            
            $global:moduleSnapshots[$file.FullName] = $lastWrite
            if ($global:debugLevelToConsole -in @('DEBUG','INFO','SUCCESS')) {
                Write-Host "[OK] Module $($file.Name) loaded" -ForegroundColor Green
            }
        }
        catch {
            if ($global:debugLevelToConsole -ne 'NONE') {
                Write-Host "[ERROR] Unable to load module $($file.Name)" -BackgroundColor Red -ForegroundColor White
            }
        }
    }

#TODO 
    # install all config files in mydocuments if they do not exist : [environment]::GetFolderPath('MyDocuments')




# Load configuration file
    if ($global:custom_config) {
        $ConfigFilePath = $global:custom_config
        write-Host "WARNING: Using configuration file: $ConfigFilePath" -ForegroundColor Yellow
        pause
    } else {
        $ConfigFilePath = "$ScriptPath\config\config.json"
    }


# check if config file exists and load it
    if ( -not (Test-Path $ConfigFilePath)) {
        Write-Host ""
        Write-Host "  *** Configuration file not found! ***" -ForegroundColor Red -BackgroundColor Black
        Write-Host "  Expected : $ConfigFilePath" -ForegroundColor Yellow
        Write-Host ""
        $templatePath = Join-Path -Path $global:ScriptPath -ChildPath "templates\config\config.json"
        if (Test-Path $templatePath) {
            # Ensure the destination directory exists
            $configDir = Split-Path $ConfigFilePath -Parent
            if (-not (Test-Path $configDir)) {
                New-Item -Path $configDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $templatePath -Destination $ConfigFilePath -Force
            Write-Host "  A default configuration file has been created from the template." -ForegroundColor Green
            Write-Host "  Please fill in your settings, save and restart the script." -ForegroundColor Yellow
            Write-Host ""
            Start-Sleep -Seconds 2
            notepad $ConfigFilePath
        }
        else {
            Write-Host "  Template not found at '$templatePath'." -ForegroundColor Red
            Write-Host "  Please create '$ConfigFilePath' manually, then restart." -ForegroundColor Yellow
        }
        exit 1

    } else {
        Get-Config -ConfigFilePath $ConfigFilePath
        Write-Log "Configuration file $ConfigFilePath loaded successfully" -Level DEBUG
        Write-Host "DEBUG global:knownHeadsetsFile = $($global:knownHeadsetsFile)" -ForegroundColor Magenta
        Write-Host "DEBUG global:knownHeadsetsFilePath = $($global:knownHeadsetsFilePath)" -ForegroundColor Magenta
    }

    # Load centralized translations based on selected language.
    # Runs after the config if/else so it also applies when the config file was
    # missing (no language set) — falls back to English in that case.
    $translationsFolder = Join-Path $modulesPath "translations"
    $translationsEn     = Join-Path $translationsFolder "en-US.psd1"
    $translationsLang   = if ($global:SelectedLanguage) {
                              Join-Path $translationsFolder "$($global:SelectedLanguage).psd1"
                          } else { $null }

    if ($translationsLang -and (Test-Path $translationsLang)) {
        $global:msg = Import-PowerShellDataFile -Path $translationsLang
    } elseif (Test-Path $translationsEn) {
        if ($global:SelectedLanguage -and $global:SelectedLanguage -ne 'en-US') {
            Write-Host "Translations for '$($global:SelectedLanguage)' not found, falling back to English." -ForegroundColor Yellow
        }
        $global:msg = Import-PowerShellDataFile -Path $translationsEn
    } else {
        Write-Host "[ERROR] No translation file found in $translationsFolder" -ForegroundColor Red
        Write-Host "[ERROR] a default translation file en-US.psd1 is required for the application to run." -ForegroundColor Red
        Read-Host 'Press Enter to stop the application...'
        exit
    }
    Write-Log ($msg.TranslationsLoaded -f $global:SelectedLanguage) -Level DEBUG


function Invoke-AppShutdown {
    <#
    .SYNOPSIS
    Gracefully shuts down all app services.

    .DESCRIPTION
    Stops scrcpy processes, resets awake mode, disconnects ADB, stops the web server,
    cleans up the PID file, and stops mediamtx. Designed to be called both from the
    main menu quit handler ('0') and from headsets_dashboard.ps1 when the parent process
    exits. Each step is wrapped defensively so a missing $msg or failed function does
    not prevent the remaining steps from running.
    #>
    try { Stop-AllScrcpy }            catch { }
    try { Reset-AwakeMode }           catch { }
    try { Disconnect-ADBConnections }  catch { }

    # Stop web server - try process object first, then PID file as cross-process fallback
    $webServerPidFile = Join-Path $global:ScriptPath "data\webserver.pid"
    $wsPid = $null
    if ($global:WebServerProcess -and -not $global:WebServerProcess.HasExited) {
        $wsPid = $global:WebServerProcess.Id
    } elseif (Test-Path $webServerPidFile) {
        $wsPid = [int](Get-Content $webServerPidFile -Raw -ErrorAction SilentlyContinue)
    }
    if ($wsPid -and (Get-Process -Id $wsPid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $wsPid -Force -ErrorAction SilentlyContinue
        try { Write-Log $msg.WebServerStopped -Level INFO } catch { Write-Host "[App] Web server stopped." }
    }
    Remove-Item $webServerPidFile -Force -ErrorAction SilentlyContinue

    try { Stop-MediaMtx } catch { }
}





# Run all computer-level setup tasks (firewall rules, service auto-starts, etc.)
if (-not $global:IsWebServerProcess) {
    Initialize-ComputerSetup
}

function Start-WebServer {
    param(
        [switch]$Restart
    )

    if (-not $global:WebServer_enabled) { return }

    $webServerPidFile = Join-Path $global:ScriptPath "data\webserver.pid"

    # -- Stop phase (only when -Restart is requested) -------------------------
    if ($Restart) {
        $wsPid = $null
        if ($global:WebServerProcess -and -not $global:WebServerProcess.HasExited) {
            $wsPid = $global:WebServerProcess.Id
        } elseif (Test-Path $webServerPidFile) {
            $wsPid = [int](Get-Content $webServerPidFile -Raw -ErrorAction SilentlyContinue)
        }
        if ($wsPid -and (Get-Process -Id $wsPid -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $wsPid -Force -ErrorAction SilentlyContinue
            Write-Log $msg.WebServerStopped -Level INFO
        }
        Remove-Item $webServerPidFile -Force -ErrorAction SilentlyContinue
        $global:WebServerProcess = $null

        # Regenerate video monitor page from template before restart
        if ($global:knownHeadsets) {
            Write-VideoMonitor $global:knownHeadsets
        }
    }

    # -- Start phase ----------------------------------------------------------
    # PID-file lock: a single file in the data folder records the running server PID.
    # Written before Start-Process so any concurrent caller (dashboard loop, module
    # reload) sees it immediately and skips the launch. Stale entries are cleaned up
    # by verifying the stored PID is still alive.
    $webServerRunning = $false

    # 1. In-process guard (fastest path - same PS session)
    if ($global:WebServerProcess -and -not $global:WebServerProcess.HasExited) {
        $webServerRunning = $true
        Write-Log ($msg.WebServerAlreadyRunning -f $global:WebServer_port) -Level DEBUG
    }

    # 2. PID-file guard (cross-process: dashboard loop, module reload, parallel calls)
    if (-not $webServerRunning -and (Test-Path $webServerPidFile)) {
        $storedPid = [int](Get-Content $webServerPidFile -Raw -ErrorAction SilentlyContinue)
        if ($storedPid -and (Get-Process -Id $storedPid -ErrorAction SilentlyContinue)) {
            $webServerRunning = $true
            $global:WebServerProcess = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
            Write-Log ($msg.WebServerAlreadyRunning -f $global:WebServer_port) -Level DEBUG
        } else {
            # Stale PID file from a previous crashed run - remove it
            Remove-Item $webServerPidFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $webServerRunning) {
        $web_server_script = Join-Path $global:ScriptPath "modules\Pode_WebServer\web_server.ps1"

        # Write a placeholder PID entry BEFORE launching so concurrent callers
        # see the file and skip. Use current PID as sentinel; overwritten by
        # web_server.ps1 once it has its own PID.
        $PID | Set-Content $webServerPidFile -Force -ErrorAction SilentlyContinue

        $global:WebServerProcess = Start-Process powershell.exe -ArgumentList @(
            "-NoExit",
            "-File",
            "`"$web_server_script`"",
            "-ScriptPath",
            "`"$global:ScriptPath`"",
            "-ConfigFilePath",
            "`"$ConfigFilePath`"",
            "-PidFile",
            "`"$webServerPidFile`"",
            "-LogFolder",
            "`"$global:logFolder`"",
            "-LogFile",
            "`"$global:logFile`""
        ) -WindowStyle Hidden -PassThru
        Write-Log ($msg.WebServerStarted -f $global:WebServer_port) -Level INFO
    }
}

# Start the Pode web server in a separate PowerShell window (guarded: skip if already running)
if (-not $global:IsWebServerProcess) {
    Start-WebServer
}




