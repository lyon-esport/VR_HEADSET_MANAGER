
# VR Headset Manager - Static Web Server
# Serves all files under the /website folder over HTTP using System.Net.HttpListener.
# Does NOT require admin - relies on the URL ACL registered once by computer_setup.ps1:
#   netsh http add urlacl url=http://+:<port>/ user=Everyone
# Launched as a standalone PowerShell process (same pattern as headsets_dashboard.ps1).
#
# URL: http://<host-ip>:<port>/video_monitor.html

param(
    [string]$ScriptPath,
    [string]$ConfigFilePath,
    [string]$PidFile
)

# Resolve project root: prefer passed -ScriptPath, otherwise navigate up from this script's location
if (-not $ScriptPath) {
    # This file is at modules\Pode_WebServer\web_server.ps1 -> go up 2 levels
    $ScriptPath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

if (-not $ConfigFilePath) {
    $ConfigFilePath = Join-Path $ScriptPath "config\config.json"
}

$websitePath = Join-Path $ScriptPath "website"

# Read port and enabled flag from config.json
$port    = 8080
$enabled = $true
try {
    $cfg = Get-Content $ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($null -ne $cfg.WebServer.port)    { $port    = [int]$cfg.WebServer.port }
    if ($null -ne $cfg.WebServer.enabled) { $enabled = [bool]$cfg.WebServer.enabled }
} catch {
    Write-Host "[WebServer] Could not read config.json, using default port $port." -ForegroundColor Yellow
}

if (-not $enabled) {
    Write-Host "[WebServer] Web server is disabled in config.json. Exiting." -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path $websitePath)) {
    Write-Host "[WebServer] ERROR: website folder not found at: $websitePath" -ForegroundColor Red
    exit 1
}

# MIME type map
$mimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
    '.ttf'  = 'font/ttf'
    '.txt'  = 'text/plain; charset=utf-8'
}

# Show LAN URLs - RFC 1918 private ranges only
$lanIPs = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -match '^10\.' -or
        $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or
        $_.IPAddress -match '^192\.168\.'
    }).IPAddress

Write-Host ""
Write-Host "[WebServer] Starting on port $port..." -ForegroundColor Cyan
Write-Host "[WebServer] Serving files from: $websitePath" -ForegroundColor Cyan
if ($lanIPs) {
    foreach ($ip in $lanIPs) {
        Write-Host "[WebServer]   http://${ip}:${port}/video_monitor.html" -ForegroundColor Green
    }
} else {
    Write-Host "[WebServer] WARNING: No RFC 1918 LAN address found. Server listening on all interfaces." -ForegroundColor Yellow
}
Write-Host ""

# Write own PID to lock file so scripts_init.ps1 can detect us across reloads
if ($PidFile) {
    $PID | Set-Content $PidFile -Force -ErrorAction SilentlyContinue
}

# Start HttpListener
# Requires URL ACL pre-registered by computer_setup.ps1:
#   netsh http add urlacl url=http://+:<port>/ user=Everyone
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$port/")
try {
    $listener.Start()
} catch {
    Write-Host "[WebServer] ERROR: Failed to start listener on port $port." -ForegroundColor Red
    Write-Host "[WebServer] Ensure the URL ACL is registered (run the app once as admin, or see computer_setup.ps1)." -ForegroundColor Yellow
    Write-Host "[WebServer] $_" -ForegroundColor Red
    if ($PidFile -and (Test-Path $PidFile)) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Host "[WebServer] Listening on http://+:$port/ - press Ctrl+C to stop." -ForegroundColor Green

try {
    while ($listener.IsListening) {
        # GetContext() blocks until a request arrives
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        try {
            # Resolve URL path to a file under websitePath
            $urlPath = $request.Url.LocalPath.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrEmpty($urlPath)) { $urlPath = 'video_monitor.html' }

            $filePath = Join-Path $websitePath $urlPath

            # Prevent path traversal outside websitePath
            $resolvedFile    = [System.IO.Path]::GetFullPath($filePath)
            $resolvedWebsite = [System.IO.Path]::GetFullPath($websitePath)
            if (-not $resolvedFile.StartsWith($resolvedWebsite)) {
                $response.StatusCode = 403
                $response.Close()
                continue
            }

            if ([System.IO.File]::Exists($resolvedFile)) {
                $ext      = [System.IO.Path]::GetExtension($resolvedFile).ToLower()
                $mime     = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
                $bytes    = [System.IO.File]::ReadAllBytes($resolvedFile)

                $response.StatusCode        = 200
                $response.ContentType       = $mime
                $response.ContentLength64   = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $response.StatusCode = 404
                $msg404 = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $urlPath")
                $response.ContentType     = 'text/plain; charset=utf-8'
                $response.ContentLength64 = $msg404.Length
                $response.OutputStream.Write($msg404, 0, $msg404.Length)
            }
        } catch {
            $response.StatusCode = 500
        } finally {
            $response.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    if ($PidFile -and (Test-Path $PidFile)) {
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[WebServer] Stopped." -ForegroundColor Yellow
}
