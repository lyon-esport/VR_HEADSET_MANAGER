Add-Type -AssemblyName System.Security

function Show-WelcomeBanner {
    $line = "=" * 62
    Write-Host ""
    Write-Host "  $line" -ForegroundColor Cyan
    Write-Host "  ||                                                          ||" -ForegroundColor Cyan
    Write-Host "  ||           VR HEADSET MANAGER - Setup Wizard             ||" -ForegroundColor White
    Write-Host "  ||                    First-time setup                     ||" -ForegroundColor Yellow
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
    return [Console]::ReadKey($true).KeyChar
}

function Get-DefaultRecordingFolder {
    return (Join-Path ([Environment]::GetFolderPath('MyVideos')) "VR_Records")
}

function Read-ValidPort {
    param([string]$Label, [int]$Default)
    while ($true) {
        Write-Host "  $Label [default: $Default]: " -ForegroundColor White -NoNewline
        $raw = Read-Host
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -ge 1024 -and $val -le 65535) {
            return $val
        }
        Write-Host "  Invalid. Enter a number between 1024 and 65535." -ForegroundColor Red
    }
}

function Save-WifiNetworkWizard {
    param([string]$DataFolder, [string]$Ssid, [string]$Password)
    $wifiPath = Join-Path $DataFolder "wifi_networks.dat"
    $networks = @([PSCustomObject]@{ SSID = $Ssid; Password = $Password })
    $json = $networks | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.IO.File]::WriteAllBytes($wifiPath, $encrypted)
}

function Invoke-FfmpegDownload {
    param([string]$SourcesFolder)

    Write-Host ""
    Write-Host "  [1] Download automatically from GitHub (recommended)" -ForegroundColor White
    Write-Host "  [2] Set path to an existing ffmpeg.exe" -ForegroundColor White
    Write-Host "  [3] Skip - configure later" -ForegroundColor White
    Write-Host ""
    Write-Host "  Choice [3]: " -ForegroundColor Yellow -NoNewline
    $key = Read-WizardKey
    Write-Host $key

    if ($key -eq '1') {
        Write-Host ""
        Write-Host "  Fetching latest ffmpeg release info..." -ForegroundColor Yellow
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
            $extractPath = Join-Path $env:TEMP "vrm_ffmpeg_extract"
            $destFolder = Join-Path $SourcesFolder "ffmpeg"
            Write-Host "  Downloading $($asset.name) ..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers $headers -TimeoutSec 300
            Write-Host "  Extracting..." -ForegroundColor Yellow
            if (Test-Path -LiteralPath $extractPath) { Remove-Item $extractPath -Recurse -Force }
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
            $binFolder = Get-ChildItem $extractPath -Recurse -Directory |
                         Where-Object { $_.Name -eq "bin" } |
                         Select-Object -First 1
            if (-not $binFolder) {
                Write-Host "  Could not find bin\ folder in archive. Skipping." -ForegroundColor Red
                return "ffmpeg"
            }
            if (-not (Test-Path -LiteralPath $destFolder)) {
                New-Item -ItemType Directory -Path $destFolder | Out-Null
            }
            Copy-Item -LiteralPath (Join-Path $binFolder.FullName "ffmpeg.exe") -Destination $destFolder -Force
            Write-Host "  ffmpeg installed to: sources\ffmpeg" -ForegroundColor Green
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
            return "ffmpeg"
        } catch {
            Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Skipping. You can install ffmpeg manually later." -ForegroundColor Yellow
            return "ffmpeg"
        }
    } elseif ($key -eq '2') {
        Write-Host ""
        Write-Host "  Enter the full path to ffmpeg.exe:" -ForegroundColor White
        Write-Host "  > " -ForegroundColor Yellow -NoNewline
        $ffmpegExe = Read-Host
        # Accept either a direct path to ffmpeg.exe or a folder containing it
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
    } else {
        Write-Host "  Skipped. Edit ffmpeg.folder in config\config.json to set it later." -ForegroundColor Yellow
        return "ffmpeg"
    }
}

function Invoke-WelcomeSetup {
    param(
        [string]$ConfigTemplatePath,
        [string]$ConfigOutputPath
    )

    $totalSteps = 6

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
    Show-WizardStep -Step 1 -Total $totalSteps -Title "Language"
    Write-Host "  [1] English (en-US)" -ForegroundColor White
    Write-Host "  [2] Francais (fr-FR)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Choice [1]: " -ForegroundColor Yellow -NoNewline
    $key = Read-WizardKey
    Write-Host $key
    if ($key -eq '2') {
        $config.language = "fr-FR"
        Write-Host "  Language: fr-FR" -ForegroundColor Green
    } else {
        $config.language = "en-US"
        Write-Host "  Language: en-US" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Step 2 - Recording folder
    # ------------------------------------------------------------------
    Show-WizardStep -Step 2 -Total $totalSteps -Title "Recording Folder"
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
    # Step 3 - WiFi
    # ------------------------------------------------------------------
    Show-WizardStep -Step 3 -Total $totalSteps -Title "WiFi Network"
    Write-Host "  Enter the WiFi SSID and password your headsets connect to." -ForegroundColor White
    Write-Host "  This is saved encrypted. Press Enter to skip." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  SSID: " -ForegroundColor Yellow -NoNewline
    $ssid = Read-Host
    if (-not [string]::IsNullOrWhiteSpace($ssid)) {
        Write-Host "  Password: " -ForegroundColor Yellow -NoNewline
        $securePass = Read-Host -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $dataFolder = Join-Path $global:ScriptPath "data"
        if (-not (Test-Path -LiteralPath $dataFolder)) {
            New-Item -ItemType Directory -Path $dataFolder | Out-Null
        }
        try {
            Save-WifiNetworkWizard -DataFolder $dataFolder -Ssid $ssid -Password $plainPass
            Write-Host "  WiFi network saved (encrypted with Windows DPAPI)." -ForegroundColor Green
        } catch {
            Write-Host "  Could not save WiFi credentials: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  Skipped. Add WiFi networks later via the main menu." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Step 4 - Web server port
    # ------------------------------------------------------------------
    Show-WizardStep -Step 4 -Total $totalSteps -Title "Web Server Port"
    Write-Host "  The built-in web server shows headset status in your browser." -ForegroundColor White
    $wsPort = Read-ValidPort -Label "Web server port" -Default 8080
    $config.WebServer.port = $wsPort
    Write-Host "  Web server: http://localhost:$wsPort" -ForegroundColor Green

    # ------------------------------------------------------------------
    # Step 5 - MediaMTX ports
    # ------------------------------------------------------------------
    Show-WizardStep -Step 5 -Total $totalSteps -Title "MediaMTX Streaming Ports"
    Write-Host "  MediaMTX streams headset video to OBS and the web dashboard." -ForegroundColor White
    Write-Host "  Default ports: RTSP 8554 | HLS 8888 | WebRTC 8889 | API 9997" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Customize ports? [Y/N, default N]: " -ForegroundColor Yellow -NoNewline
    $key = Read-WizardKey
    Write-Host $key
    if ($key -eq 'Y' -or $key -eq 'y') {
        $config.mediamtx.rtsp_port   = Read-ValidPort -Label "RTSP port"   -Default 8554
        $config.mediamtx.hls_port    = Read-ValidPort -Label "HLS port"    -Default 8888
        $config.mediamtx.webrtc_port = Read-ValidPort -Label "WebRTC port" -Default 8889
        $config.mediamtx.api_port    = Read-ValidPort -Label "API port"    -Default 9997
        Write-Host "  MediaMTX ports configured." -ForegroundColor Green
    } else {
        Write-Host "  Keeping default MediaMTX ports." -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------
    # Step 6 - FFmpeg
    # ------------------------------------------------------------------
    Show-WizardStep -Step 6 -Total $totalSteps -Title "FFmpeg"
    Write-Host "  FFmpeg is used by MediaMTX to capture and re-encode streams." -ForegroundColor White
    $sourcesFolder = Join-Path $global:ScriptPath "sources"
    $ffmpegFolder = Invoke-FfmpegDownload -SourcesFolder $sourcesFolder
    $config.ffmpeg.folder = $ffmpegFolder

    # ------------------------------------------------------------------
    # Write config.json
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "  Writing config\config.json ..." -ForegroundColor Yellow
    $outputJson = $config | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfigOutputPath, $outputJson, $utf8NoBom)

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
