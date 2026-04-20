
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
    [string]$PidFile,
    [string]$LogFolder,
    [string]$LogFile
)

# Resolve project root: prefer passed -ScriptPath, otherwise navigate up from this script's location
if (-not $ScriptPath) {
    # This file is at modules\Pode_WebServer\web_server.ps1 -> go up 2 levels
    $ScriptPath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

if (-not $ConfigFilePath) {
    $ConfigFilePath = Join-Path $ScriptPath "config\config.json"
}

# Set globals needed by Write-Log and other modules before dot-sourcing scripts_init
$global:ScriptPath      = $ScriptPath
$global:ConfigFilePath  = $ConfigFilePath
if ($LogFolder) { $global:logFolder = $LogFolder }
if ($LogFile)   { $global:logFile   = $LogFile   }

# Import all modules (same pattern as VRMonitor job in headsets_infos_manager.ps1)
# Flag prevents scripts_init from launching another web server or running computer setup
$global:IsWebServerProcess = $true
$scripts_init = Join-Path $ScriptPath "modules\scripts_init.ps1"
if (Test-Path $scripts_init) {
    . $scripts_init
} else {
    Write-Host "[WebServer] ERROR: scripts_init.ps1 not found at: $scripts_init" -ForegroundColor Red
    exit 1
}

$websitePath = Join-Path $ScriptPath "website"

# Read port, enabled flag, and ADB settings from config.json
$port       = 8080
$enabled    = $true
$adbPath    = $null
$adbPort    = 5555
$apkPath    = $null
$apkPackage = 'tdg.oculuswirelessadb'
$wifiSsid   = ''
$wifiPwd    = ''
try {
    $cfg = Get-Content $ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($null -ne $cfg.WebServer.port)        { $port    = [int]$cfg.WebServer.port }
    if ($null -ne $cfg.WebServer.enabled)     { $enabled = [bool]$cfg.WebServer.enabled }
    if ($cfg.ADB.folder) {
        $adbPath = Join-Path (Join-Path $ScriptPath 'sources') $cfg.ADB.folder | Join-Path -ChildPath 'adb.exe'
    }
    if ($null -ne $cfg.ADB.adbPort_default)   { $adbPort = [int]$cfg.ADB.adbPort_default }
    if ($cfg.apk.adbWirelessActivatorFolder -and $cfg.apk.adbWirelessActivatorApk) {
        $apkPath = Join-Path (Join-Path $ScriptPath 'sources') $cfg.apk.adbWirelessActivatorFolder |
                   Join-Path -ChildPath $cfg.apk.adbWirelessActivatorApk
    }
    if ($cfg.apk.adbWirelessActivatorPackageName) { $apkPackage = $cfg.apk.adbWirelessActivatorPackageName }
    if ($cfg.WIFI.wifi_ssid) { $wifiSsid = $cfg.WIFI.wifi_ssid }
    if ($cfg.WIFI.wifi_pwd)  { $wifiPwd  = $cfg.WIFI.wifi_pwd  }
} catch {
    Write-Log ($msg.WebServerConfigReadFailed -f $port) -Level WARNING
}

if (-not $enabled) {
    Write-Log $msg.WebServerDisabled -Level WARNING
    exit 0
}

if (-not (Test-Path $websitePath)) {
    Write-Log ($msg.WebServerWebsiteFolderNotFound -f $websitePath) -Level ERROR
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

Write-Log ($msg.WebServerStartingOnPort -f $port) -Level INFO
Write-Log ($msg.WebServerServingFrom -f $websitePath) -Level DEBUG
if ($lanIPs) {
    foreach ($ip in $lanIPs) {
        Write-Log ($msg.WebServerLinkLine -f $ip, $port) -Level INFO
    }
} else {
    Write-Log $msg.WebServerNoLanAddress -Level WARNING
}

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
    Write-Log ($msg.WebServerListenerFailed -f $port) -Level ERROR
    Write-Log $msg.WebServerUrlAclHint -Level WARNING
    Write-Log ($msg.WebServerListenerError -f $_) -Level ERROR
    if ($PidFile -and (Test-Path $PidFile)) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Log ($msg.WebServerListening -f $port) -Level SUCCESS

try {
    while ($listener.IsListening) {
        # GetContext() blocks until a request arrives
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        # CORS preflight
        if ($request.HttpMethod -eq 'OPTIONS') {
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            $response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        # API: POST /api/renameheadset  body: {"name":"Q3_BLUE","newname":"Q3 Red"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/renameheadset') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                # name is the internal display_name (underscores), newname is raw
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $newName = $json.newname.Trim()
                # Allow letters, digits, spaces, hyphens, underscores (1-40 chars)
                if (-not ($newName -match '^[\w\s\-]{1,40}$')) { throw "Invalid new name" }

                # Resolve old (display) name from the CSV and delegate to Rename-Headset
                $rows   = Get-KnownHeadsets
                $oldRow = $rows | Where-Object { ($_.Name -replace ' ', '_') -eq $safeName } | Select-Object -First 1
                if (-not $oldRow) { throw "Headset not found" }

                $ok = Rename-Headset -OldName $oldRow.Name -NewName $newName -headsets $rows
                if ($ok) {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes(('{"ok":true,"newname":' + ($newName | ConvertTo-Json -Compress) + '}'))
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/updateip  body: {"name":"Q3_BLUE","ip":"192.168.1.99"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/updateip') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $safeIp = [regex]::Match($json.ip, '^(\d{1,3}\.){3}\d{1,3}$').Value
                if (-not $safeIp) { throw "Invalid IP address" }

                $rows = Get-KnownHeadsets
                $updated = $false
                foreach ($row in $rows) {
                    if (($row.Name -replace ' ', '_') -eq $safeName) {
                        $row.IPAddress = $safeIp
                        $updated = $true
                        break
                    }
                }
                if ($updated) {
                    Save-Headsets -headsets $rows
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/recording  body: {"name":"Q3_BLUE","value":true}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/recording') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $csvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                $rows = Import-Csv -Path $csvPath
                $updated = $false
                foreach ($row in $rows) {
                    $dn = ($row.Name -replace ' ', '_')
                    if ($dn -eq $safeName) {
                        $row.Record = if ([string]$json.value -eq 'True' -or [string]$json.value -eq 'true') { 'True' } else { 'False' }
                        $updated = $true
                        break
                    }
                }
                if ($updated) {
                    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/removeheadset  body: {"name":"Q3_BLUE"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/removeheadset') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $csvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                $rows = @(Import-Csv -Path $csvPath)
                $match = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName }
                if (-not $match) { throw "Headset not found" }

                # Remove the matching row and reassign IDs
                $rows = @($rows | Where-Object { ($_.Name -replace ' ','_') -ne $safeName })
                $newId = 1
                foreach ($row in $rows) { $row.ID = $newId; $newId++ }

                $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force

                # Delete installed apps cache for this headset
                $appsCachePath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_installed_apps.csv"))
                if ($appsCachePath.StartsWith($dataRoot) -and (Test-Path $appsCachePath)) {
                    Remove-Item $appsCachePath -Force -ErrorAction SilentlyContinue
                }
                # Delete per-headset favorites file
                $favCacheP = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_favorite_apps.csv"))
                if ($favCacheP.StartsWith($dataRoot) -and (Test-Path $favCacheP)) {
                    Remove-Item $favCacheP -Force -ErrorAction SilentlyContinue
                }

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/reboot  body: {"name":"Q3_BLUE"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/reboot') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $rows = Import-Csv -Path $csvPath
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName }
                if (-not $headset) { throw "Headset not found" }
                $device = Get-AdbWifiDevice -headsetIP $headset.IPAddress -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB WiFi" }
                Invoke-HeadsetReboot -Device $device -adb $adbPath | Out-Null
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/shutdown  body: {"name":"Q3_BLUE"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/shutdown') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $rows = Import-Csv -Path $csvPath
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName }
                if (-not $headset) { throw "Headset not found" }
                $device = Get-AdbWifiDevice -headsetIP $headset.IPAddress -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB WiFi" }
                Invoke-HeadsetShutdown -Device $device -adb $adbPath | Out-Null
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/updateprofile  body: {"name":"Q3_BLUE","profile":"R-N-45-20"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/updateprofile') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                # Validate headset name
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                # Validate profile format: [L/R]-[D/N]-<posint>-<posint>
                $safeProfile = [regex]::Match($json.profile, '^[LR]-[DN]-\d+-\d+$').Value
                if (-not $safeProfile) { throw "Invalid profile format" }
                $parts = $safeProfile -split '-'
                if ([int]$parts[2] -lt 1 -or [int]$parts[3] -lt 1) { throw "FPS and bitrate must be positive" }

                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $csvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                $rows = Import-Csv -Path $csvPath
                $updated = $false
                foreach ($row in $rows) {
                    $dn = ($row.Name -replace ' ', '_')
                    if ($dn -eq $safeName) {
                        $row.ScrcpyProfile = $safeProfile
                        $updated = $true
                        break
                    }
                }
                if ($updated) {
                    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/autorestart  body: {"name":"Q3_BLUE","value":true}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/autorestart') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                # Validate input - name must be a simple identifier (no path chars)
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $csvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                $rows = Import-Csv -Path $csvPath
                $updated = $false
                foreach ($row in $rows) {
                    $dn = ($row.Name -replace ' ', '_')
                    if ($dn -eq $safeName) {
                        $row.scrcpy_AutoRestart = if ([string]$json.value -eq 'True' -or [string]$json.value -eq 'true') { 'True' } else { 'False' }
                        $updated = $true
                        break
                    }
                }
                if ($updated) {
                    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/headsets  - returns all known headsets as JSON (from Get-KnownHeadsets)
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/headsets') {
            try {
                $rows = Get-KnownHeadsets
                $jsonItems = @($rows | ForEach-Object {
                    $row = $_
                    '{"ID":' + [int]$row.ID +
                    ',"Name":' + ($row.Name         | ConvertTo-Json) +
                    ',"IPAddress":' + ($row.IPAddress  | ConvertTo-Json) +
                    ',"Model":' + ($row.Model         | ConvertTo-Json) +
                    ',"SerialNumber":' + ($row.SerialNumber | ConvertTo-Json) +
                    ',"ScrcpyProfile":' + ($row.ScrcpyProfile | ConvertTo-Json) +
                    ',"scrcpy_AutoRestart":' + ($row.scrcpy_AutoRestart | ConvertTo-Json) +
                    ',"Record":' + ($row.Record       | ConvertTo-Json) +
                    '}'
                })
                $json = '[' + ($jsonItems -join ',') + ']'
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/favoriteapps?name=Q3_BLUE  - returns Meta Home + per-headset favorites as JSON
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/favoriteapps') {
            try {
                $rawQuery  = $request.Url.Query.TrimStart('?')
                $nameParam = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
                $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $metaHomePkg = 'com.oculus.vrshell'
                $metaHomeObj = @{ package = $metaHomePkg; displayName = 'Meta Home' }
                $favCsvPath  = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_favorite_apps.csv"))
                $dataRoot    = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $favCsvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }
                $favList     = @($metaHomeObj)
                if (Test-Path $favCsvPath) {
                    $favRows = Import-Csv -Path $favCsvPath -Delimiter ","
                    foreach ($r in $favRows) {
                        if ($r.PackageName -and $r.PackageName -ne $metaHomePkg) {
                            $favList += @{ package = $r.PackageName; displayName = $r.DisplayName }
                        }
                    }
                }
                $appNamesPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                if (Test-Path $appNamesPath) {
                    $appNames = @{}
                    Import-Csv -Path $appNamesPath -Delimiter "," | ForEach-Object { $appNames[$_.PackageName] = $_.DisplayName }
                    $favList = $favList | ForEach-Object {
                        $dn = if ($appNames.ContainsKey($_.package) -and $appNames[$_.package]) { $appNames[$_.package] } else { $_.displayName }
                        @{ package = $_.package; displayName = $dn }
                    }
                }
                $json = ConvertTo-Json @($favList) -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/installedapps?name=Q3_BLUE  - returns installed third-party apps as JSON
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/installedapps') {
            try {
                $rawQuery  = $request.Url.Query.TrimStart('?')
                $nameParam = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
                $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $dataRoot     = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                $appNamesPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                $cachePath    = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_installed_apps.csv"))
                $favCsvPath   = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_favorite_apps.csv"))
                $metaHomePkg  = 'com.oculus.vrshell'

                if (-not $cachePath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                # Load favorites
                $favPkgs = @()
                if (Test-Path $favCsvPath) {
                    $favPkgs = @(Import-Csv -Path $favCsvPath -Delimiter "," | Select-Object -ExpandProperty PackageName)
                }

                # Use cache if available
                if (Test-Path $cachePath) {
                    $cachedRows = @(Import-Csv -Path $cachePath -Delimiter ",")
                    $appList = @($cachedRows | ForEach-Object {
                        $pkg = $_.PackageName
                        $dn  = if ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                        @{ package = $pkg; displayName = $dn; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg) }
                    } | Sort-Object { $_.displayName })
                } else {
                    # Fallback: live ADB call
                    $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                    $rows    = Import-Csv -Path $csvPath
                    $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName }
                    if (-not $headset) { throw "Headset not found" }

                    $device = Get-AdbWifiDevice -headsetIP $headset.IPAddress -AdbPort $adbPort -adb $adbPath
                    if (-not $device) { throw "Could not connect to headset via ADB WiFi" }

                    $installedApps = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly -adb $adbPath
                    $appList = @($installedApps | ForEach-Object {
                        @{ package = $_.PackageName; displayName = $_.DisplayName; favorite = ($favPkgs -contains $_.PackageName -or $_.PackageName -eq $metaHomePkg) }
                    } | Sort-Object { $_.displayName })
                }

                $json = ConvertTo-Json @($appList) -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('[]')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/launchapp  body: {"name":"Q3_BLUE","package":"com.beatgames.beatsaber"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/launchapp') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json     = $body | ConvertFrom-Json
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                $safePkg  = [regex]::Match($json.package, '^[\w\.\-]+$').Value
                if (-not $safeName -or -not $safePkg) { throw "Invalid input" }

                $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $rows    = Import-Csv -Path $csvPath
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName }
                if (-not $headset) { throw "Headset not found" }
                $device = Get-AdbWifiDevice -headsetIP $headset.IPAddress -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB WiFi" }
                $ok = Invoke-HeadsetApp -Device $device -PackageName $safePkg -adb $adbPath
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($ok) { '{"ok":true}' } else { '{"ok":false}' }))
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/togglefavorite  body: {"name":"Q3_BLUE","package":"com.pkg","displayName":"App","favorite":true}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/togglefavorite') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json     = $body | ConvertFrom-Json
                $safePkg  = [regex]::Match($json.package, '^[\w\.\-]+$').Value
                $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safePkg -or -not $safeName) { throw "Invalid input" }
                # Protect Meta Home from being unfavorited
                if ($safePkg -eq 'com.oculus.vrshell') {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $respBytes.Length
                    $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                    continue
                }
                $favCsvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_favorite_apps.csv"))
                $dataRoot   = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $favCsvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                $favRows = @()
                if (Test-Path $favCsvPath) { $favRows = @(Import-Csv -Path $favCsvPath -Delimiter ",") }
                $addFav = [string]$json.favorite -eq 'True' -or [string]$json.favorite -eq 'true'
                if ($addFav) {
                    if (-not ($favRows | Where-Object { $_.PackageName -eq $safePkg })) {
                        $favRows += [PSCustomObject]@{ PackageName = $safePkg; DisplayName = $json.displayName }
                    }
                } else {
                    $favRows = @($favRows | Where-Object { $_.PackageName -ne $safePkg })
                }
                if ($favRows.Count -eq 0) {
                    Set-Content -Path $favCsvPath -Value '"PackageName","DisplayName"' -Encoding UTF8
                } else {
                    $favRows | Export-Csv -Path $favCsvPath -NoTypeInformation -Encoding UTF8 -Force
                }
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/detectusbheadset  - detects a USB-connected ADB device and returns its WiFi IP
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/detectusbheadset') {
            try {
                $usbInfo = Get-AdbUsbDeviceInfo -adb $adbPath
                $result = if ($usbInfo -and $usbInfo.IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    @{ found = $true; ip = $usbInfo.IP; model = $usbInfo.Model }
                } else {
                    @{ found = $false; ip = ''; model = '' }
                }
                $jsonOut   = ConvertTo-Json $result -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"found":false}')
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/enablewifiadb  - runs adb tcpip 5555 on the USB-connected headset
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/enablewifiadb') {
            try {
                $result = Enable-AdbTcpIp -AdbPort $adbPort -adb $adbPath
                $json   = ConvertTo-Json $result -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/installadbwifiapk  - installs the WiFi ADB APK on the USB-connected headset
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/installadbwifiapk') {
            try {
                $device = Get-AdbUsbDeviceInfo -adb $adbPath
                if (-not $device) {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"No USB headset detected"}')
                    $response.StatusCode = 200
                    $response.ContentType = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $respBytes.Length
                    $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                } else {
                    $ok = Install-OculusWirelessAdbApk -Device $device -adb $adbPath
                    # Retrieve IP after install (tcpip was run inside Install-OculusWirelessAdbApk)
                    $ip    = ''
                    $model = ''
                    $portOpen = $false
                    $ipOutput = & $adbPath -s $device.DeviceId shell ip -f inet addr show wlan0 2>$null
                    foreach ($line in $ipOutput) {
                        if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') { $ip = $Matches[1]; break }
                    }
                    $model = ((& $adbPath -s $device.DeviceId shell getprop ro.product.model 2>$null) -join '').Trim()
                    if ($ip) { $portOpen = (Test-Port -hostname $ip -port $adbPort).open }
                    $resultObj = @{ ok = [bool]$ok; model = $model; ip = $ip; port = $adbPort; portOpen = $portOpen; reinstalled = $true }
                    $json = ConvertTo-Json $resultObj -Compress
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $respBytes.Length
                    $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                }
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/connectwifi  - connects USB device to the configured WiFi network
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/connectwifi') {
            try {
                $result = @{ ok = $false; error = '' }
                if (-not ($adbPath -and (Test-Path $adbPath))) {
                    $result.error = 'ADB not found.'
                } elseif (-not $wifiSsid) {
                    $result.error = 'No WiFi SSID configured.'
                } else {
                    # Find USB device
                    $usbDeviceId = (& $adbPath devices 2>&1 |
                        Where-Object { $_ -match '^\S+\s+device$' -and $_ -notmatch '^\*' -and $_ -notmatch '^\d+\.\d+' } |
                        Select-Object -First 1) -replace '\s+device$', ''
                    if (-not $usbDeviceId) {
                        $result.error = 'No USB device found.'
                    } else {
                        $connectOut = & $adbPath -s $usbDeviceId shell cmd wifi connect-network `"$wifiSsid`" wpa2 `"$wifiPwd`" 2>&1
                        if ($connectOut -match 'successfully|connected|Network connection initiated') {
                            $result.ok = $true
                        } else {
                            # Try alternate: still mark ok if no error returned
                            if ($LASTEXITCODE -eq 0 -and $connectOut -notmatch 'error|failed|unknown') {
                                $result.ok = $true
                            } else {
                                $result.error = ($connectOut -join ' ').Trim()
                                if (-not $result.error) { $result.error = 'Connection command failed.' }
                            }
                        }
                    }
                }
                $jsonOut   = ConvertTo-Json $result -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Internal error"}')
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/usbdeviceinfo  - returns full details of USB-connected ADB device
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/usbdeviceinfo') {
            try {
                $result = @{ found = $false; ip = ''; model = ''; serialNumber = ''; ssid = ''; wifiAdbOpen = $false; apkInstalled = $false; alreadyRegistered = $false }
                if ($adbPath -and (Test-Path $adbPath)) {
                    $details = Get-AdbUsbDeviceDetails -adb $adbPath -AdbPort $adbPort -PackageName $apkPackage
                    if ($details) {
                        $alreadyReg = $false
                        $csvPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                        if ((Test-Path $csvPath) -and $details.SerialNumber) {
                            $rows = Import-Csv -Path $csvPath
                            $alreadyReg = [bool]($rows | Where-Object { $_.SerialNumber -eq $details.SerialNumber })
                        }
                        $result = @{
                            found             = $true
                            ip                = $details.IP
                            model             = $details.Model
                            serialNumber      = $details.SerialNumber
                            ssid              = $details.WiFiSSID
                            expectedSsid      = $wifiSsid
                            wifiAdbOpen       = $details.WifiAdbOpen
                            apkInstalled      = $details.ApkInstalled
                            alreadyRegistered = $alreadyReg
                        }
                    }
                }
                $jsonOut   = ConvertTo-Json $result -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"found":false}')
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/addheadset  body: {"name":"Q3 Blue","ip":"192.168.1.243"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/addheadset') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                # Validate name: letters, numbers, spaces, hyphens, underscores (1-40 chars)
                $safeName = [regex]::Match($json.name.Trim(), '^[\w\s\-]{1,40}$').Value
                if (-not $safeName) { throw "INVALID_NAME" }

                # Validate IP format and octet range
                $safeIp = [regex]::Match($json.ip, '^(\d{1,3}\.){3}\d{1,3}$').Value
                if (-not $safeIp) { throw "INVALID_IP" }
                $octets = $safeIp -split '\.'
                if ($octets | Where-Object { [int]$_ -gt 255 }) { throw "INVALID_IP" }

                $csvPath  = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_headsets.csv"))
                $dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data"))
                if (-not $csvPath.StartsWith($dataRoot)) { throw "Path traversal denied" }

                $rows = @()
                if (Test-Path $csvPath) { $rows = @(Import-Csv -Path $csvPath) }

                if ($rows | Where-Object { $_.IPAddress -eq $safeIp })   { throw "IP_DUPLICATE" }
                if ($rows | Where-Object { $_.Name      -eq $safeName }) { throw "NAME_DUPLICATE" }

                $newId  = if ($rows.Count -gt 0) { $rows.Count + 1 } else { 1 }
                $newRow = [PSCustomObject]@{
                    ID                 = $newId
                    Name               = $safeName
                    IPAddress          = $safeIp
                    scrcpy_AutoRestart = 'False'
                    Record             = 'False'
                    ScrcpyProfile      = 'R-N-45-20'
                    Model              = ''
                    SerialNumber       = ''
                }
                $rows += $newRow
                $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                $errMsg = switch -Regex ($_.Exception.Message) {
                    'IP_DUPLICATE'   { '{"ok":false,"error":"This IP address is already registered."}' }
                    'NAME_DUPLICATE' { '{"ok":false,"error":"A headset with this name already exists."}' }
                    'INVALID_NAME'   { '{"ok":false,"error":"Invalid name. Use letters, numbers, spaces or hyphens."}' }
                    'INVALID_IP'     { '{"ok":false,"error":"Invalid IP address."}' }
                    default          { '{"ok":false,"error":"Server error."}' }
                }
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        try {
            # Resolve URL path to a file.
            # /data/*.csv  -> served from <ScriptPath>\data\  (read-only CSV export)
            # everything else -> served from <ScriptPath>\website\
            $urlPath = $request.Url.LocalPath.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrEmpty($urlPath)) { $urlPath = 'video_monitor.html' }

            $dataPath = Join-Path $ScriptPath "data"
            if ($urlPath.StartsWith("data" + [System.IO.Path]::DirectorySeparatorChar)) {
                # Only allow .csv files from the data folder - no traversal
                $fileRelative = $urlPath.Substring(5)  # strip "data\"
                $resolvedFile    = [System.IO.Path]::GetFullPath((Join-Path $dataPath $fileRelative))
                $resolvedBase    = [System.IO.Path]::GetFullPath($dataPath)
                $allowedExt      = [System.IO.Path]::GetExtension($resolvedFile).ToLower()
                if (-not $resolvedFile.StartsWith($resolvedBase) -or $allowedExt -ne '.csv') {
                    $response.StatusCode = 403
                    $response.Close()
                    continue
                }
            } else {
                $resolvedFile    = [System.IO.Path]::GetFullPath((Join-Path $websitePath $urlPath))
                $resolvedBase    = [System.IO.Path]::GetFullPath($websitePath)
                # Prevent path traversal outside websitePath
                if (-not $resolvedFile.StartsWith($resolvedBase)) {
                    $response.StatusCode = 403
                    $response.Close()
                    continue
                }
            }

            if ([System.IO.File]::Exists($resolvedFile)) {
                $ext      = [System.IO.Path]::GetExtension($resolvedFile).ToLower()
                $mime     = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
                $bytes    = [System.IO.File]::ReadAllBytes($resolvedFile)
                $lastMod  = [System.IO.File]::GetLastWriteTimeUtc($resolvedFile).ToString('R')

                $response.StatusCode        = 200
                $response.ContentType       = $mime
                $response.ContentLength64   = $bytes.Length
                $response.Headers.Add('Last-Modified', $lastMod)
                $response.Headers.Add('Cache-Control', 'no-cache')
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
    Write-Log $msg.WebServerStopped -Level INFO
}
