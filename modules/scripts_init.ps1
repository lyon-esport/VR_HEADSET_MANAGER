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

# Load EPS from bundled local copy (no NuGet / internet required)
if (-not (Get-Module -Name EPS)) {
    $_epsManifest = Join-Path $ModulesPath "EPS\EPS.psd1"
    if (Test-Path -LiteralPath $_epsManifest) {
        Import-Module -Name $_epsManifest -Global
    } else {
        Write-Host "[ERROR] EPS module not found at $_epsManifest" -ForegroundColor Red
        exit 1
    }
}

# Pre-read config.json (cheap, no globals) to decide whether to load the VQA
# module. When VideoQualityAutomation.enabled is false we skip
# video_quality_automation.ps1 entirely so its functions, sub-menu and
# background work cost zero.
$vqaPreEnabled = $false
$vqaPreConfigPath = if ($global:custom_config) { $global:custom_config } else { Join-Path $global:ScriptPath "config\config.json" }
if (Test-Path -LiteralPath $vqaPreConfigPath) {
    try {
        $vqaPreCfg = Get-Content -LiteralPath $vqaPreConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($vqaPreCfg.VideoQualityAutomation -and $vqaPreCfg.VideoQualityAutomation.enabled) { $vqaPreEnabled = $true }
    } catch { }
}

$moduleFiles = Get-ChildItem -Path $ModulesPath -Filter "*.ps1" -File | Sort-Object Name |
    Where-Object {
        $_.Name -notlike "*_init.ps1" -and
        $_.Name -notlike "headsets_dashboard.ps1" -and
        $_.Name -notlike "reaper.ps1" -and
        $_.Name -notlike "*_test.ps1" -and
        ($vqaPreEnabled -or $_.Name -ne "video_quality_automation.ps1")
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

#TODO IDEA : install all config files in mydocuments or in local or roaming if they do not exist : [environment]::GetFolderPath('MyDocuments')



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

        # Log files retention purge - main process only, once per startup.
        if (-not $global:IsVRMonitorJob -and -not $global:IsDashboardProcess -and -not $global:IsWebServerProcess) {
            if (Get-Command Remove-OldLogFiles -ErrorAction SilentlyContinue) {
                try { Remove-OldLogFiles } catch { Write-Log ("Log retention purge failed: " + $_.Exception.Message) -Level WARNING }
            }
            # Stale scrcpy relay files from a previous (crashed) run
            try {
                Get-ChildItem -LiteralPath (Join-Path $global:ScriptPath "data") -Filter "vrm_relay_*.mkv" -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            } catch { }
        }
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

# Initialize known_apps.csv from template on first startup
if ($global:AppCacheFilePath -and -not (Test-Path -LiteralPath $global:AppCacheFilePath)) {
    if (Get-Command Initialize-AppNamesCache -ErrorAction SilentlyContinue) {
        Initialize-AppNamesCache -AppCacheFilePath $global:AppCacheFilePath
    }
}

# Video Quality Automation startup: crash-recovery + history truncation.
# Skipped inside the VRMonitor job and the dashboard process (they only need
# the runtime functions, not the per-session reset).
if ($global:VQA_Enabled -and -not $global:IsVRMonitorJob -and -not $global:IsDashboardProcess -and -not $global:IsWebServerProcess) {
    if (Get-Command Initialize-VideoQualityAutomation -ErrorAction SilentlyContinue) {
        try { Initialize-VideoQualityAutomation } catch { Write-Log ("VQA init failed: " + $_.Exception.Message) -Level WARNING }
    }
}


function Stop-WebServer {
    $webServerPidFile = Join-Path $global:ScriptPath "data\webserver.pid"
    $wsPid = $null
    try {
        if ($global:WebServerProcess -and -not $global:WebServerProcess.HasExited) {
            $wsPid = $global:WebServerProcess.Id
        }
    } catch { }
    if (-not $wsPid -and (Test-Path $webServerPidFile)) {
        $rawPid = Get-Content $webServerPidFile -Raw -ErrorAction SilentlyContinue
        if ($rawPid) { $wsPid = [int]$rawPid }
    }
    if ($wsPid -and (Get-Process -Id $wsPid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $wsPid -Force -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline -and (Get-Process -Id $wsPid -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 100
        }
        try { Write-Log $msg.WebServerStopped -Level INFO } catch { Write-Host "[App] Web server stopped." }
    }
    Remove-Item $webServerPidFile -Force -ErrorAction SilentlyContinue
    $global:WebServerProcess = $null
}


function Invoke-AppShutdown {
    <#
    .SYNOPSIS
    Gracefully shuts down all app services.

    .DESCRIPTION
    Race-free shutdown:
      1. Writes data\shutdown.flag so Start-VRMonitor exits cooperatively at the
         top of its next loop iteration (no more service restarts).
      2. Waits up to ~VRMonitor refresh interval + 2s for the job to leave Running
         state, then proceeds with ordered teardown.
      3. Stops scrcpy, web server, mediamtx, dashboard.
      4. Drops data\reaper_exit.flag so the standalone reaper exits without doing
         anything (services are already cleanly stopped).
    #>
    $shutdownFlagPath   = Join-Path $global:ScriptPath "data\shutdown.flag"
    $reaperExitFlagPath = Join-Path $global:ScriptPath "data\reaper_exit.flag"

    # 1. Signal VRMonitor to exit its loop before we tear down services.
    try { New-Item -ItemType File -Path $shutdownFlagPath -Force | Out-Null } catch { }

    # 2. Wait for the job to leave Running. Refresh-timer + a small grace period.
    try {
        $job = Get-Job -Name "VRMonitor" -ErrorAction SilentlyContinue
        if ($job) {
            $waitSec  = [int]$global:VRMonitor_refresh_timer + 2
            if ($waitSec -lt 4) { $waitSec = 4 }
            $deadline = (Get-Date).AddSeconds($waitSec)
            while ((Get-Date) -lt $deadline) {
                $state = (Get-Job -Name "VRMonitor" -ErrorAction SilentlyContinue).State
                if (-not $state -or $state -ne 'Running') { break }
                Start-Sleep -Milliseconds 250
            }
        }
    } catch { }

    try { Stop-VRMonitor }            catch { }
    try { Stop-Scrcpy }               catch { }
    try { Reset-AwakeMode }           catch { }
    try { Disconnect-ADBConnections } catch { }

    # Kill the dashboard (if any) before stopping services so its self-exit
    # parent-PID check does not race against us.
    try {
        $dashProcs = Get-WmiObject -Class Win32_Process -Filter "ParentProcessId = $PID" |
            Where-Object { $_.CommandLine -match "headsets_dashboard\.ps1" }
        foreach ($dp in $dashProcs) {
            Stop-Process -Id $dp.ProcessId -Force -ErrorAction SilentlyContinue
        }
        $dashPidFile = Join-Path $global:ScriptPath "data\dashboard.pid"
        if (Test-Path -LiteralPath $dashPidFile) { Remove-Item -LiteralPath $dashPidFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    try { Stop-WebServer    } catch { }
    try { Stop-MdnsResponder } catch { }
    try { Stop-MediaMtx    } catch { }

    # Restore any VQA-applied parameters back to operator originals before exit.
    if ($global:VQA_Enabled -and (Get-Command Restore-VqaOriginals -ErrorAction SilentlyContinue)) {
        try { Restore-VqaOriginals | Out-Null } catch { }
    }

    # 4. Tell the reaper graceful shutdown is done so it exits without acting.
    try { New-Item -ItemType File -Path $reaperExitFlagPath -Force | Out-Null } catch { }

    # Clean up our own signaling flag.
    if (Test-Path -LiteralPath $shutdownFlagPath) {
        Remove-Item -LiteralPath $shutdownFlagPath -Force -ErrorAction SilentlyContinue
    }

    Remove-Variable moduleSnapshots -Scope Global -ErrorAction SilentlyContinue
    exit 0
}





# Verify that no other process is holding the ports we are about to bind
# (mediamtx RTSP/HLS/WebRTC/API, the built-in WebServer, the ADB server).
# Must run BEFORE Initialize-ComputerSetup so firewall rules see the final ports.
function Confirm-AppPortsAvailable {
    <#
    .SYNOPSIS
    Pre-flight port-availability check at every startup.

    For each port the app intends to bind, calls Resolve-PortConflict to surface
    the offender and let the operator pick increment / manual / kill. When a
    port changes, the new value is written back to config.json and the affected
    $global:* variables are refreshed via Get-Config.
    #>
    # Guard: scripts_init.ps1 is dot-sourced on every module reload (the main
    # menu loop re-runs the auto-reload check). Only run the check once per
    # PowerShell process - the app would otherwise detect ITS OWN listening
    # WebServer / mediamtx as a conflict and re-prompt forever.
    if ($global:PortsConfirmedDone) { return }
    $global:PortsConfirmedDone = $true

    if (-not $global:AppPortPools) {
        Write-Log "Confirm-AppPortsAvailable: \$global:AppPortPools not set - skipping." -Level DEBUG
        return
    }

    $checks = @()

    if ($global:WebServer_enabled -and $global:WebServer_port) {
        $checks += @{
            Service    = 'WebServer'
            Port       = [int]$global:WebServer_port
            PoolKey    = 'WebServer'
            ConfigPath = 'WebServer.port'
        }
    }
    if ($global:mediamtxEnabled) {
        if ($global:mediamtxRtspPort)   { $checks += @{ Service='MediaMTX RTSP';   Port=[int]$global:mediamtxRtspPort;   PoolKey='MediaMtxRtsp';   ConfigPath='mediamtx.rtsp_port'   } }
        if ($global:mediamtxHlsPort)    { $checks += @{ Service='MediaMTX HLS';    Port=[int]$global:mediamtxHlsPort;    PoolKey='MediaMtxHls';    ConfigPath='mediamtx.hls_port'    } }
        if ($global:mediamtxWebrtcPort) { $checks += @{ Service='MediaMTX WebRTC'; Port=[int]$global:mediamtxWebrtcPort; PoolKey='MediaMtxWebrtc'; ConfigPath='mediamtx.webrtc_port' } }
        if ($global:mediamtxApiPort)    { $checks += @{ Service='MediaMTX API';    Port=[int]$global:mediamtxApiPort;    PoolKey='MediaMtxApi';    ConfigPath='mediamtx.api_port'    } }
    }
    # ADB server (port 5037) is intentionally NOT pre-checked: `adb start-server`
    # is idempotent - if another adb.exe (Android Studio, a previous session,
    # etc.) is already running on 5037, our adb client just talks to that
    # existing server. Pre-checking would surface a fake conflict every launch.

    $changes = @{}
    $anyConflict = $false
    foreach ($c in $checks) {
        $poolDef = $global:AppPortPools[$c.PoolKey]
        if (-not $poolDef) { continue }
        $result = Resolve-PortConflict -Service $c.Service `
                                       -CurrentPort $c.Port `
                                       -Pool        $poolDef.Pool `
                                       -Protocol    $poolDef.Protocol `
                                       -AllowIncrement:$poolDef.AllowIncrement
        if ($result.Action -ne 'None') { $anyConflict = $true }
        if ($result.NewPort -ne $c.Port -and $c.ConfigPath) {
            $changes[$c.ConfigPath] = $result.NewPort
            Write-Log ("Confirm-AppPortsAvailable: {0} port {1} -> {2} (Action={3})" -f $c.Service, $c.Port, $result.NewPort, $result.Action) -Level INFO
        }
        if (-not $result.Resolved) {
            Write-Log ("Confirm-AppPortsAvailable: {0} port {1} left unresolved (operator chose Skip)." -f $c.Service, $c.Port) -Level WARNING
        }
    }

    # If any port changed, persist the new values to config.json then refresh
    # the in-process globals so the rest of startup (firewall rules, mediamtx
    # YAML, web server bind) sees the final ports.
    if ($changes.Count -gt 0) {
        try {
            $cfg = Read-ConfigJson
            if ($null -eq $cfg) {
                Write-Log "Confirm-AppPortsAvailable: cannot reload config.json - changes not persisted." -Level ERROR
                return
            }
            foreach ($k in $changes.Keys) {
                $parts = $k -split '\.'
                $node  = $cfg
                for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                    $node = $node.($parts[$i])
                    if ($null -eq $node) { break }
                }
                if ($null -ne $node) {
                    $node.($parts[-1]) = [int]$changes[$k]
                }
            }
            $json = $cfg | ConvertTo-Json -Depth 10
            Write-FileWithoutBom -Path $global:configFilePath -Content $json
            Write-Log ("Confirm-AppPortsAvailable: {0} port(s) updated in config.json." -f $changes.Count) -Level SUCCESS
            # Refresh $global:* ports
            Get-Config | Out-Null
        } catch {
            Write-Log ("Confirm-AppPortsAvailable: failed to persist port changes: " + $_.Exception.Message) -Level ERROR
        }
    } elseif (-not $anyConflict) {
        $msgTxt = if ($global:msg -and $global:msg.PortAllClear) { $global:msg.PortAllClear } else { "All required ports are available." }
        Write-Log $msgTxt -Level DEBUG
    }
}


# Run all computer-level setup tasks (firewall rules, service auto-starts, etc.)
if (-not $global:IsWebServerProcess -and -not $global:IsDashboardProcess -and -not $global:IsVRMonitorJob) {
    Confirm-AppPortsAvailable
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
        Stop-WebServer


    }

    # -- Start phase ----------------------------------------------------------
    # PID-file lock: a single file in the data folder records the running server PID.
    # Written before Start-Process so any concurrent caller (dashboard loop, module
    # reload) sees it immediately and skips the launch. Stale entries are cleaned up
    # by verifying the stored PID is still alive.
    $webServerRunning = $false

    # 1. In-process guard (fastest path - same PS session)
    try {
        if ($global:WebServerProcess -and -not $global:WebServerProcess.HasExited) {
            $webServerRunning = $true
            Write-Log ($msg.WebServerAlreadyRunning -f $global:WebServer_port) -Level DEBUG
        }
    } catch { }

    # 2. PID-file guard (cross-process: dashboard loop, module reload, parallel calls)
    # NOTE: Get-NetTCPConnection cannot be used to detect the web server - HttpListener
    # uses HTTP.sys which always shows as PID 4 (System), not the powershell.exe process.
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
        $PID | Set-Content -LiteralPath $webServerPidFile -Force -ErrorAction SilentlyContinue

        $dateStamp      = Get-Date -Format 'yyyy-MM-dd'
        $wsOutLog       = Join-Path $global:logFolder "webserver_${dateStamp}_out.log"
        $wsErrLog       = Join-Path $global:logFolder "webserver_${dateStamp}_err.log"

        $global:WebServerProcess = Start-Process powershell.exe -ArgumentList @(
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
        ) -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput $wsOutLog `
          -RedirectStandardError  $wsErrLog
        Write-Log ($msg.WebServerStarted -f $global:WebServer_port) -Level INFO
    }
}

# Only run at startup (main process or web server), never inside VRMonitor job loop or dashboard
if (-not $global:IsVRMonitorJob -and -not $global:IsDashboardProcess) {
    Initialize-TimerFiles
    if (-not $global:IsWebServerProcess) {
        Update-HeadsetMonitoringFile
        Update-HeadsetVideoFile
        Update-HeadsetTimerFile
    }
}

# Start the Pode web server in a separate PowerShell window (guarded: skip if already running)
if (-not $global:IsWebServerProcess -and -not $global:IsDashboardProcess) {
    Start-WebServer
    Start-MdnsResponder
}





