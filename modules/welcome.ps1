Add-Type -AssemblyName System.Security

function Show-WelcomeBanner {
    $line = "=" * 62
    Write-Host ""
    Write-Host "  $line" -ForegroundColor Cyan
    Write-Host "  ||                                                          ||" -ForegroundColor Cyan
    Write-Host "  ||           VR HEADSET MANAGER - Setup Wizard              ||" -ForegroundColor White
    Write-Host "  ||                    First-time setup                      ||" -ForegroundColor Yellow
    Write-Host "  ||                                                          ||" -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor Cyan
    Write-Host ""
}

function Show-WizardStep {
    param([int]$Step, [int]$Total, [string]$Title)
    $separator = "-" * 50
    Write-Host ""
    Write-Host "  [$Step/$Total] $Title" -ForegroundColor Cyan
    Write-Host "  $separator" -ForegroundColor DarkCyan
}

function Read-WizardKey {
    param(
        [hashtable]$EchoMap,
        [string]$DefaultLabel
    )
    $k = [Console]::ReadKey($true).KeyChar
    $shown = "$k"
    if ([string]::IsNullOrWhiteSpace($shown)) { $shown = "<Enter>" }
    $label = $null
    if ($EchoMap) {
        if ($EchoMap.ContainsKey([string]$k)) { $label = $EchoMap[[string]$k] }
        elseif ($EchoMap.ContainsKey([string]([char]::ToLower($k)))) { $label = $EchoMap[[string]([char]::ToLower($k))] }
    }
    if (-not $label -and $DefaultLabel) { $label = $DefaultLabel }
    if ($label) {
        Write-Host ("  Pressed: [{0}] -> {1}" -f $shown, $label) -ForegroundColor Cyan
    } else {
        Write-Host ("  Pressed: [{0}]" -f $shown) -ForegroundColor Cyan
    }
    return $k
}

function Write-WizardAction {
    param([string]$Message)
    Write-Host ("  > " + $Message) -ForegroundColor DarkGray
}

function Get-DefaultRecordingFolder {
    return (Join-Path ([Environment]::GetFolderPath('MyVideos')) "VR_Records")
}

# Read-ValidPort lives in modules/utils.ps1 (dot-sourced at wizard startup).


function Invoke-FfmpegDownload {
    param([string]$SourcesFolder)

    Write-Host ""
    Write-Host "  [1] Download automatically from GitHub (recommended)" -ForegroundColor White
    Write-Host "  [2] Set path to an existing ffmpeg.exe" -ForegroundColor White
    Write-Host "  [3] Skip - configure later" -ForegroundColor White
    Write-Host ""
    Write-Host "  Choice [1]: " -ForegroundColor Yellow -NoNewline
    $key = Read-WizardKey -EchoMap @{
        '1' = 'Download ffmpeg automatically from GitHub'
        '2' = 'Use existing ffmpeg.exe'
        '3' = 'Skip ffmpeg configuration'
    } -DefaultLabel 'Download ffmpeg automatically from GitHub (default)'

    if ($key -eq '3') {
        Write-Host "  Skipped. Edit ffmpeg.folder in config\config.json to set it later." -ForegroundColor Yellow
        return "ffmpeg"
    } elseif ($key -eq '2') {
        Write-Host ""
        Write-Host "  Enter the full path to ffmpeg.exe:" -ForegroundColor White
        Write-Host "  > " -ForegroundColor Yellow -NoNewline
        $ffmpegExe = Read-Host
        if ((Test-Path -LiteralPath $ffmpegExe) -and $ffmpegExe -like "*.exe") {
            $folder = Split-Path $ffmpegExe -Parent
            Write-Host "  ffmpeg folder set to: $folder" -ForegroundColor Green
            return $folder
        } elseif ((Test-Path -LiteralPath $ffmpegExe -PathType Container) -and (Test-Path -LiteralPath (Join-Path $ffmpegExe "ffmpeg.exe"))) {
            Write-Host "  ffmpeg folder set to: $ffmpegExe" -ForegroundColor Green
            return $ffmpegExe
        } else {
            Write-Host "  Invalid path. Skipping." -ForegroundColor Red
            return "ffmpeg"
        }
    }

    Write-Host ""
    Write-WizardAction "Querying GitHub API for latest ffmpeg release (this may take a few seconds)..."
    try {
        $apiUrl = "https://api.github.com/repos/GyanD/codexffmpeg/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager-Setup' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*essentials_build-www.zip" } | Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        }
        if (-not $asset) {
            Write-Host "  No suitable zip found in release. Skipping." -ForegroundColor Red
            return "ffmpeg"
        }
        $zipPath = Join-Path $env:TEMP "vrm_ffmpeg_download.zip"
        $destFolder = Join-Path $SourcesFolder "ffmpeg"
        Write-Host "  Downloading $($asset.name) ..." -ForegroundColor Yellow
        $bitsOk = $false
        try {
            $bits = Get-Service -Name BITS -ErrorAction Stop
            if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                Write-WizardAction "Using BITS background transfer (progress shown in status bar)..."
                Start-BitsTransfer -Source $asset.browser_download_url -Destination $zipPath -Description "Downloading ffmpeg..." -ErrorAction Stop
                $bitsOk = $true
            }
        } catch { }
        if (-not $bitsOk) {
            Write-WizardAction "Download in progress (no progress bar - please wait, this can take 1-2 minutes)..."
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('User-Agent', 'VR-Headset-Manager-Setup')
            $wc.DownloadFile($asset.browser_download_url, $zipPath)
            $wc.Dispose()
        }
        Write-WizardAction "Extracting ffmpeg.exe from the archive..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry = $zip.Entries | Where-Object { $_.FullName -like "*/bin/ffmpeg.exe" } | Select-Object -First 1
        if (-not $entry) {
            $zip.Dispose()
            Write-Host "  Could not find bin\ffmpeg.exe in archive. Skipping." -ForegroundColor Red
            return "ffmpeg"
        }
        if (-not (Test-Path -LiteralPath $destFolder)) {
            New-Item -ItemType Directory -Path $destFolder | Out-Null
        }
        $destExe = Join-Path $destFolder "ffmpeg.exe"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destExe, $true)
        $zip.Dispose()
        Write-Host "  ffmpeg installed to: sources\ffmpeg" -ForegroundColor Green
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        return "ffmpeg"
    } catch {
        Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Skipping. You can install ffmpeg manually later." -ForegroundColor Yellow
        return "ffmpeg"
    }
}

function Invoke-WelcomeSetup {
    param(
        [string]$ConfigTemplatePath,
        [string]$ConfigOutputPath
    )

    $totalSteps = 5

    # Early-load the modules needed for port-conflict resolution during the
    # port prompts (steps 3-4). The auth phase (step 6) re-uses the same
    # modules. Order matters: utils -> logging -> console_manager -> computer_setup.
    . (Join-Path $global:ScriptPath "modules\utils.ps1")
    . (Join-Path $global:ScriptPath "modules\logging.ps1")
    . (Join-Path $global:ScriptPath "modules\console_manager.ps1")
    . (Join-Path $global:ScriptPath "modules\computer_setup.ps1")

    # Default port pools used by Resolve-PortConflict in the wizard. Mirrors
    # the values set by Get-Config; declared here because Get-Config has not
    # run yet (config.json does not exist on first launch).
    if (-not $global:AppPortPools) {
        $global:AppPortPools = @{
            WebServer       = @{ Default = 8080;  Pool = (8080..8099);  Protocol = 'TCP';  AllowIncrement = $true  }
            MediaMtxRtsp    = @{ Default = 8554;  Pool = (8554..8574);  Protocol = 'Both'; AllowIncrement = $true  }
            MediaMtxHls     = @{ Default = 8888;  Pool = (8888..8908);  Protocol = 'TCP';  AllowIncrement = $true  }
            MediaMtxWebrtc  = @{ Default = 8889;  Pool = (8889..8909);  Protocol = 'Both'; AllowIncrement = $true  }
            MediaMtxApi     = @{ Default = 9997;  Pool = (9997..10017); Protocol = 'TCP';  AllowIncrement = $true  }
            AdbServer       = @{ Default = 5037;  Pool = @();           Protocol = 'TCP';  AllowIncrement = $false }
        }
    }

    Show-WelcomeBanner

    Write-Host "  Welcome! This wizard will configure VR Headset Manager." -ForegroundColor White
    Write-Host "  All settings can be changed later in config\config.json." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Press any key to begin..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null

    # Load template as base
    $templateRaw = Get-Content -LiteralPath $ConfigTemplatePath -Raw -Encoding UTF8
    $config = $templateRaw | ConvertFrom-Json

    # ------------------------------------------------------------------
    # Step 1 - Language
    # ------------------------------------------------------------------
    # HIDDEN FOR NOW - fr-FR not production-ready. Re-enable this block and
    # remove the hardcoded $config.language line below once French is ready.
    # Show-WizardStep -Step 1 -Total $totalSteps -Title "Language"
    # Write-Host "  [1] English (en-US)" -ForegroundColor White
    # Write-Host "  [2] Francais (fr-FR)" -ForegroundColor White
    # Write-Host ""
    # Write-Host "  Choice [1]: " -ForegroundColor Yellow -NoNewline
    # $key = Read-WizardKey -EchoMap @{
    #     '1' = 'English (en-US)'
    #     '2' = 'Francais (fr-FR)'
    # } -DefaultLabel 'English (en-US) (default)'
    # if ($key -eq '2') {
    #     $config.language = "fr-FR"
    #     Write-Host "  Language: fr-FR" -ForegroundColor Green
    # } else {
    #     $config.language = "en-US"
    #     Write-Host "  Language: en-US" -ForegroundColor Green
    # }
    $config.language = "en-US"

    # ------------------------------------------------------------------
    # Step 1 - Recording folder
    # ------------------------------------------------------------------
    Show-WizardStep -Step 1 -Total $totalSteps -Title "Recording Folder"
    $defaultFolder = Get-DefaultRecordingFolder
    Write-Host "  Where should scrcpy save screen recordings?" -ForegroundColor White
    Write-Host "  Default: $defaultFolder" -ForegroundColor DarkGray
    Write-Host "  Press Enter to use default, or type a custom path:" -ForegroundColor White
    Write-Host "  > " -ForegroundColor Yellow -NoNewline
    $recordFolder = Read-Host
    if ([string]::IsNullOrWhiteSpace($recordFolder)) {
        $recordFolder = $defaultFolder
    }
    if (-not (Test-Path -LiteralPath $recordFolder)) {
        try {
            Write-WizardAction "Creating folder $recordFolder ..."
            New-Item -ItemType Directory -Path $recordFolder -Force | Out-Null
            Write-Host "  Folder created: $recordFolder" -ForegroundColor Green
        } catch {
            Write-Host "  Could not create folder. Using default path (will be created on first recording)." -ForegroundColor Yellow
            $recordFolder = $defaultFolder
        }
    } else {
        Write-Host "  Folder set to: $recordFolder" -ForegroundColor Green
    }
    $config.scrcpy.recordFolder = $recordFolder

    # ------------------------------------------------------------------
    # Step 2 - Web server port
    # ------------------------------------------------------------------
    Show-WizardStep -Step 2 -Total $totalSteps -Title "Web Server Port"
    Write-Host "  The built-in web server shows headset status in your browser." -ForegroundColor White
    $wsPort = Read-ValidPort -Label "Web server port" -Default 8080
    $wsPool = $global:AppPortPools.WebServer
    $wsRes  = Resolve-PortConflict -Service 'WebServer' -CurrentPort $wsPort -Pool $wsPool.Pool -Protocol $wsPool.Protocol -AllowIncrement:$wsPool.AllowIncrement
    $wsPort = [int]$wsRes.NewPort
    $config.WebServer.port = $wsPort
    Write-Host "  Web server: http://localhost:$wsPort" -ForegroundColor Green

    # ------------------------------------------------------------------
    # Step 3 - MediaMTX ports
    # ------------------------------------------------------------------
    Show-WizardStep -Step 3 -Total $totalSteps -Title "MediaMTX Streaming Ports"
    Write-Host "  MediaMTX streams headset video to OBS and the web dashboard." -ForegroundColor White
    Write-Host "  Default ports: RTSP 8554 | HLS 8888 | WebRTC 8889 | API 9997" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Customize ports? [Y/N, default N]: " -ForegroundColor Yellow -NoNewline
    $key = Read-WizardKey -EchoMap @{
        'y' = 'Customize MediaMTX ports'
        'n' = 'Keep default MediaMTX ports'
    } -DefaultLabel 'Keep default MediaMTX ports (default)'
    if ($key -eq 'Y' -or $key -eq 'y') {
        $config.mediamtx.rtsp_port   = Read-ValidPort -Label "RTSP port"   -Default 8554
        $config.mediamtx.hls_port    = Read-ValidPort -Label "HLS port"    -Default 8888
        $config.mediamtx.webrtc_port = Read-ValidPort -Label "WebRTC port" -Default 8889
        $config.mediamtx.api_port    = Read-ValidPort -Label "API port"    -Default 9997
        Write-Host "  MediaMTX ports configured." -ForegroundColor Green
    } else {
        Write-Host "  Keeping default MediaMTX ports." -ForegroundColor Yellow
    }

    # Validate every MediaMTX port (whether default or custom) against the
    # local port-availability check. Conflicts trigger Resolve-PortConflict.
    $mtxChecks = @(
        @{ Service='MediaMTX RTSP';   ConfigKey='rtsp_port';   PoolKey='MediaMtxRtsp'   }
        @{ Service='MediaMTX HLS';    ConfigKey='hls_port';    PoolKey='MediaMtxHls'    }
        @{ Service='MediaMTX WebRTC'; ConfigKey='webrtc_port'; PoolKey='MediaMtxWebrtc' }
        @{ Service='MediaMTX API';    ConfigKey='api_port';    PoolKey='MediaMtxApi'    }
    )
    foreach ($m in $mtxChecks) {
        $pool   = $global:AppPortPools[$m.PoolKey]
        $curVal = [int]$config.mediamtx.($m.ConfigKey)
        $res    = Resolve-PortConflict -Service $m.Service -CurrentPort $curVal -Pool $pool.Pool -Protocol $pool.Protocol -AllowIncrement:$pool.AllowIncrement
        $config.mediamtx.($m.ConfigKey) = [int]$res.NewPort
    }

    # ------------------------------------------------------------------
    # Step 4 - FFmpeg
    # ------------------------------------------------------------------
    Show-WizardStep -Step 4 -Total $totalSteps -Title "FFmpeg"
    Write-Host "  FFmpeg is used by MediaMTX to capture and re-encode streams." -ForegroundColor White
    $sourcesFolder = Join-Path $global:ScriptPath "sources"
    $ffmpegFolder = Invoke-FfmpegDownload -SourcesFolder $sourcesFolder
    $config.ffmpeg.folder = $ffmpegFolder

    # ------------------------------------------------------------------
    # Write config.json
    # ------------------------------------------------------------------
    Write-Host ""
    Write-WizardAction "Writing config\config.json ..."
    $outputJson = $config | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfigOutputPath, $outputJson, $utf8NoBom)

    # ------------------------------------------------------------------
    # Step 6 - System authorizations (firewall rules + URL ACL)
    # Bundled into ONE elevated console so the operator deals with admin
    # rights once before the app launches.
    # ------------------------------------------------------------------
    Show-WizardStep -Step 5 -Total $totalSteps -Title "System Authorizations"
    Write-Host "  The next step will request administrator rights once to register:" -ForegroundColor White
    Write-Host "    - ADB firewall rule" -ForegroundColor DarkGray
    Write-Host "    - MediaMTX firewall rules (RTSP/HLS/WebRTC ports)" -ForegroundColor DarkGray
    Write-Host "    - Web server firewall rule (port " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($config.WebServer.port)" -ForegroundColor DarkGray -NoNewline
    Write-Host ")" -ForegroundColor DarkGray
    Write-Host "    - HTTP URL reservation (so the web server runs without admin)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  A Windows UAC prompt will appear, then a console window will" -ForegroundColor White
    Write-Host "  ask Y/N for each rule. Press any key to continue..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null

    try {
        Write-WizardAction "Loading setup modules..."
        . (Join-Path $global:ScriptPath "modules\logging.ps1")
        . (Join-Path $global:ScriptPath "modules\config_files_loader.ps1")
        . (Join-Path $global:ScriptPath "modules\computer_setup.ps1")

        Write-WizardAction "Loading translation strings..."
        $lang = $config.language
        $translationsFolder = Join-Path $global:ScriptPath "modules\translations"
        $langFile = Join-Path $translationsFolder "$lang.psd1"
        if (-not (Test-Path -LiteralPath $langFile)) {
            $langFile = Join-Path $translationsFolder "en-US.psd1"
        }
        if (Test-Path -LiteralPath $langFile) {
            $global:msg = Import-PowerShellDataFile -LiteralPath $langFile
        } else {
            $global:msg = @{}
        }

        Write-WizardAction "Loading config values into runtime globals..."
        Get-Config -ConfigFilePath $ConfigOutputPath | Out-Null

        Write-WizardAction "Requesting administrator rights and opening the batch authorization console..."
        Initialize-ComputerSetup
        Write-Host "  System authorizations completed." -ForegroundColor Green
    } catch {
        Write-Host "  System authorizations step failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  The app will retry at startup; you may see additional UAC prompts." -ForegroundColor Yellow
    }

    # Summary
    $line = "=" * 62
    Write-Host ""
    Write-Host "  $line" -ForegroundColor Cyan
    Write-Host "  Setup complete! Summary:" -ForegroundColor Green
    Write-Host ""
    Write-Host ("  Language    : " + $config.language) -ForegroundColor White
    Write-Host ("  Records     : " + $config.scrcpy.recordFolder) -ForegroundColor White
    Write-Host ("  Web server  : http://localhost:" + $config.WebServer.port) -ForegroundColor White
    Write-Host ("  RTSP stream : rtsp://localhost:" + $config.mediamtx.rtsp_port) -ForegroundColor White
    Write-Host ("  ffmpeg      : " + $config.ffmpeg.folder) -ForegroundColor White
    Write-Host "  $line" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Press any key to launch VR Headset Manager..." -ForegroundColor Yellow
    [Console]::ReadKey($true) | Out-Null
}
