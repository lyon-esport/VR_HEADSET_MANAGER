
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
if (Test-Path -LiteralPath $scripts_init) {
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
} catch {
    Write-Log ($msg.WebServerConfigReadFailed -f $port) -Level WARNING
}

if (-not $enabled) {
    Write-Log $msg.WebServerDisabled -Level WARNING
    exit 0
}

if (-not (Test-Path -LiteralPath $websitePath)) {
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


# Helper: send a JSON response with proper status code, content-type and length.
# Replaces dozens of hand-built '{"ok":true,...}' string concatenations.
# - $Response is the [System.Net.HttpListenerResponse].
# - $Body can be a hashtable, PSCustomObject, array, or any ConvertTo-Json target.
#   Use $Raw if you have a pre-built JSON string.
function Send-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]
        $Response,
        $Body = $null,
        [int]$StatusCode = 200,
        [string]$Raw = $null,
        [int]$Depth = 6
    )
    try {
        $json = if ($Raw) { $Raw } else { $Body | ConvertTo-Json -Compress -Depth $Depth }
        if ($null -eq $json) { $json = 'null' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        $Response.StatusCode      = $StatusCode
        $Response.ContentType     = 'application/json; charset=utf-8'
        $Response.Headers.Add('Access-Control-Allow-Origin', '*')
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        # last-resort: try to set 500 if headers not yet sent
        try { $Response.StatusCode = 500 } catch {}
    }
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
    $PID | Set-Content -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
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
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Log ($msg.WebServerListening -f $port) -Level SUCCESS

# Tracks active install background jobs by jobId
$script:installJobs = @{}

# Background job script block for async app installs.
# Runs in a NEW PowerShell process - no access to web server functions.
# Calls adb.exe directly and writes progress JSON to a temp file.
$installJobBlock = {
    param(
        [string]$adbExe,
        [string]$deviceId,
        [string]$installPath,
        [bool]$isFolder,
        [string]$obbPath,
        [string]$pkgName,
        [string]$progressFile,
        [bool]$cleanupApk
    )

    function Set-InstProg {
        param([string]$step, [int]$pct=0, [string]$file='', [string]$err='', [int]$pid2=0,
              [double]$obbMB=0, [double]$totalSec=0, [double]$obbSec=0, [double]$bwMBs=0)
        $safeErr  = ($err  -replace '"',"'") -replace '[^\x20-\x7E]',''
        $safeFile = ($file -replace '"',"'") -replace '[^\x20-\x7E]',''
        $json = "{`"step`":`"$step`",`"pct`":$pct,`"file`":`"$safeFile`",`"error`":`"$safeErr`",`"adbPid`":$pid2," +
                "`"obbMB`":$obbMB,`"totalSec`":$totalSec,`"obbSec`":$obbSec,`"bwMBs`":$bwMBs}"
        try { [System.IO.File]::WriteAllText($progressFile, $json) } catch {}
    }

    function Run-AdbExe {
        param([string]$args2)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $adbExe
        $psi.Arguments              = $args2
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $out = $outTask.GetAwaiter().GetResult()
        $err = $errTask.GetAwaiter().GetResult()
        return @{ ExitCode = $proc.ExitCode; Output = "$out $err".Trim(); Ok = ($proc.ExitCode -eq 0) }
    }

    try {
        $installStart = [datetime]::UtcNow
        Set-InstProg 'apk_installing' 0

        # Resolve APK path
        $apkPath = if ($isFolder) {
            $apks = @(Get-ChildItem -LiteralPath $installPath -Filter '*.apk' -File -ErrorAction SilentlyContinue)
            if ($apks.Count -eq 0) { Set-InstProg 'error' 0 '' 'No APK file found in folder'; return }
            $apks[0].FullName
        } else { $installPath }

        # Install APK
        $r = Run-AdbExe "-s `"$deviceId`" install -r `"$apkPath`""
        if (-not $r.Ok -or $r.Output -match 'Failure|INSTALL_FAILED') {
            $detail = if ($r.Output -match '(INSTALL_FAILED_\S+)') { $Matches[1] } else { 'APK install failed' }
            Set-InstProg 'error' 0 '' $detail
            if ($cleanupApk -and (Test-Path -LiteralPath $installPath)) { Remove-Item -LiteralPath $installPath -Force -ErrorAction SilentlyContinue }
            return
        }
        if ($cleanupApk -and (Test-Path -LiteralPath $installPath)) { Remove-Item -LiteralPath $installPath -Force -ErrorAction SilentlyContinue }

        Set-InstProg 'apk_done' 100

        # OBB push (folder mode only, when OBB subfolder exists)
        $obbMB   = 0
        $obbSec  = 0
        $bwMBs   = 0
        if ($isFolder -and $obbPath -and (Test-Path -LiteralPath $obbPath -PathType Container)) {
            $obbSizeBytes = (Get-ChildItem -LiteralPath $obbPath -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            $obbMB = [math]::Round($obbSizeBytes / 1MB, 1)

            Run-AdbExe "-s `"$deviceId`" shell mkdir -p /sdcard/Android/obb/$pkgName" | Out-Null

            $psi2 = [System.Diagnostics.ProcessStartInfo]::new()
            $psi2.FileName               = $adbExe
            $psi2.Arguments              = "-s `"$deviceId`" push `"$obbPath`" /sdcard/Android/obb/$pkgName"
            $psi2.UseShellExecute        = $false
            $psi2.RedirectStandardOutput = $true
            $psi2.RedirectStandardError  = $true
            $psi2.CreateNoWindow         = $true
            $pushProc = [System.Diagnostics.Process]::new()
            $pushProc.StartInfo = $psi2
            $pushProc.Start() | Out-Null

            $obbStart = [datetime]::UtcNow
            Set-InstProg 'obb_push' 0 '' '' $pushProc.Id -obbMB $obbMB

            $outTask2 = $pushProc.StandardOutput.ReadToEndAsync()
            $errTask2 = $pushProc.StandardError.ReadToEndAsync()
            $pushProc.WaitForExit()
            $outTask2.GetAwaiter().GetResult() | Out-Null
            $errTask2.GetAwaiter().GetResult() | Out-Null

            if ($pushProc.ExitCode -ne 0) {
                Set-InstProg 'error' 0 '' 'OBB data push failed'
                return
            }

            $obbSec = [math]::Round(([datetime]::UtcNow - $obbStart).TotalSeconds, 1)
            $bwMBs  = if ($obbSec -gt 0) { [math]::Round($obbMB / $obbSec, 1) } else { 0 }
        }

        $totalSec = [math]::Round(([datetime]::UtcNow - $installStart).TotalSeconds, 1)
        Set-InstProg 'done' 100 '' '' 0 -obbMB $obbMB -totalSec $totalSec -obbSec $obbSec -bwMBs $bwMBs

    } catch {
        $m = ($_.Exception.Message -replace '"',"'") -replace '[^\x20-\x7E]',''
        Set-InstProg 'error' 0 '' $m
    }
}

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

        # API: POST /api/reorderheadsets  body: {"order":["Q3_BLUE","Q3_RED",...]}
        # Delegates to Reorder-Headsets (headsets_manager.ps1) which saves CSV and regenerates HTML monitors.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/reorderheadsets') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                if (-not $json.order -or $json.order.Count -eq 0) { throw "Empty order" }

                # Validate each name token
                foreach ($tok in $json.order) {
                    if ($tok -notmatch '^[\w\-]+$') { throw "Invalid name token: $tok" }
                }

                Reorder-Headsets -OrderedDisplayNames ([string[]]$json.order)

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

        # API: POST /api/updateip  body: {"name":"Q3_BLUE","ip":"192.168.1.99"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/updateip') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $parsedIp = $null
                if (-not [System.Net.IPAddress]::TryParse([string]$json.ip, [ref]$parsedIp) -or
                    $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    throw "Invalid IP address"
                }
                $safeIp = $parsedIp.ToString()

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

                $rows = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if ($headset) {
                    $newVal = if ([string]$json.value -eq 'True' -or [string]$json.value -eq 'true') { 'True' } else { 'False' }
                    Update-HeadsetField -headsets $rows -ID ([int]$headset.ID) -Field "Record" -NewValue $newVal
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

                $rows  = Get-KnownHeadsets
                $match = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $match) { throw "Headset not found" }
                Remove-Headset -ID ([int]$match.ID)

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
                $rows = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }
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
                $rows = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }
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

        # API: GET /api/headset-settings?name=Q3_BLUE  - reads current headset parameters via ADB
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/headset-settings') {
            try {
                $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }

                $screenTimeout    = Get-HeadsetScreenTimeout    -Device $device -adb $adbPath
                $sleepTimeout     = Get-HeadsetSleepTimeout     -Device $device -adb $adbPath
                $brightness       = Get-HeadsetBrightness       -Device $device -adb $adbPath

                Send-JsonResponse -Response $response -Body @{
                    ok               = $true
                    screenTimeout    = $screenTimeout
                    sleepTimeout     = $sleepTimeout
                    brightness       = $brightness
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/headset-settings/apply  body: {"name":"Q3_BLUE","settings":{...}}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/headset-settings/apply') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd()
                $reader.Close()
                $json     = $body | ConvertFrom-Json
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }

                $s = $json.settings
                if ($null -ne $s.guardianMode) {
                    Set-HeadsetGuardian -Device $device -adb $adbPath | Out-Null
                }

                if ($null -ne $s.brightness) {
                    Set-HeadsetBrightness -Device $device -Percent ([int]$s.brightness) -adb $adbPath | Out-Null
                }
                Send-JsonResponse -Response $response -Body @{ ok = $true }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/updateprofile  body: {"name":"Q3_BLUE","profile":"portrait-R-N-45-20"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/updateprofile') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json    = $body | ConvertFrom-Json

                # Validate headset name
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                # Validate profile format: <viewname>-[L/R]-[D/N]-<posint>-<posint>
                # Also accept legacy 4-part format [L/R]-[D/N]-<posint>-<posint>
                $safeProfile = [regex]::Match($json.profile, '^[\w]+-[LR]-[DN]-\d+-\d+$').Value
                if (-not $safeProfile) {
                    # Try legacy format and auto-upgrade
                    $legacy = [regex]::Match($json.profile, '^[LR]-[DN]-\d+-\d+$').Value
                    if ($legacy) { $safeProfile = "portrait-$legacy" } else { throw "Invalid profile format" }
                }
                $parts = $safeProfile -split '-'
                if ([int]$parts[3] -lt 1 -or [int]$parts[4] -lt 1) { throw "FPS and bitrate must be positive" }

                $rows = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if ($headset) {
                    Update-HeadsetField -headsets $rows -ID ([int]$headset.ID) -Field "ScrcpyProfile" -NewValue $safeProfile
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

        # API: GET /api/scrcpyviews?model=Quest+3  - returns view names for a headset model
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/scrcpyviews') {
            try {
                $modelParam = $request.QueryString['model']
                $views = @('portrait','square','wide')
                if ($modelParam -and $global:scrcpyParameters.$modelParam -and $global:scrcpyParameters.$modelParam.views) {
                    $views = @($global:scrcpyParameters.$modelParam.views | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
                }
                $json = $views | ConvertTo-Json -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('["portrait","square","wide"]')
                    $response.StatusCode      = 200
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

                $rows = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if ($headset) {
                    $newVal = if ([string]$json.value -eq 'True' -or [string]$json.value -eq 'true') { 'True' } else { 'False' }
                    Update-HeadsetField -headsets $rows -ID ([int]$headset.ID) -Field "scrcpy_AutoRestart" -NewValue $newVal
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
                $favList     = @($metaHomeObj)
                $favRows     = Get-FavoriteApps -headsetName $safeName
                foreach ($r in $favRows) {
                    if ($r.PackageName -and $r.PackageName -ne $metaHomePkg) {
                        $favList += @{ package = $r.PackageName; displayName = $r.DisplayName }
                    }
                }
                $appNamesPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                if (Test-Path -LiteralPath $appNamesPath) {
                    $appNames = @{}
                    Import-Csv -LiteralPath $appNamesPath -Delimiter "," | ForEach-Object { $appNames[$_.PackageName] = $_ }
                    $favList = $favList | ForEach-Object {
                        $entry = $appNames[$_.package]
                        $dn    = if ($entry -and $entry.DisplayName) { $entry.DisplayName } else { $_.displayName }
                        $icon  = if ($entry) { $entry.LocalIconPath } else { '' }
                        @{ package = $_.package; displayName = $dn; localIconPath = $icon }
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


        # API: GET /api/installedapps?name=Q3_BLUE[&refresh=1][&resolveMissing=1][&includeSystem=1]
        # Returns installed apps as JSON. Default: third-party only (cached). includeSystem=1: all apps (live).
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/installedapps') {
            try {
                $rawQuery       = $request.Url.Query.TrimStart('?')
                $nameParam      = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
                $refresh        = ($rawQuery -match '(?:^|&)refresh=1')
                $resolveMissing = ($rawQuery -match '(?:^|&)resolveMissing=1')
                $includeSystem  = ($rawQuery -match '(?:^|&)includeSystem=1')
                $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $appNamesPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                $cachePath    = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_installed_apps.csv"))
                $metaHomePkg  = 'com.oculus.vrshell'

                # Load favorites
                $favPkgs = @(Get-FavoriteApps -headsetName $safeName | Select-Object -ExpandProperty PackageName)

                # Load app_names.csv as the live source of truth for display names and icons
                $appNamesLookup = @{}
                if (Test-Path -LiteralPath $appNamesPath) {
                    @(Import-Csv -LiteralPath $appNamesPath -Delimiter ",") | ForEach-Object {
                        if ($_.PackageName) { $appNamesLookup[$_.PackageName] = $_ }
                    }
                }

                if ($includeSystem) {
                    # All apps (third-party + built-in) -- always a live call, no cache
                    $rows    = Get-KnownHeadsets
                    $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                    if (-not $headset) { throw "Headset not found" }
                    $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
                    if (-not $device) { throw "Could not connect to headset via ADB" }
                    $installedApps = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly:$false

                    # Build version lookup from the per-headset cache (has ADB-reported versions)
                    $versionLookup = @{}
                    if (Test-Path -LiteralPath $cachePath) {
                        @(Import-Csv -LiteralPath $cachePath -Delimiter ",") | ForEach-Object {
                            if ($_.PackageName -and $_.Version) { $versionLookup[$_.PackageName] = $_.Version }
                        }
                    }

                    $appList = @($installedApps | ForEach-Object {
                        $pkg    = $_.PackageName
                        $entry  = if ($appNamesLookup.ContainsKey($pkg)) { $appNamesLookup[$pkg] } else { $null }
                        $dn     = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } elseif ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                        $icon   = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } elseif ($_.LocalIconPath) { $_.LocalIconPath } else { '' }
                        $ver    = if ($versionLookup.ContainsKey($pkg)) { $versionLookup[$pkg] } elseif ($_.Version) { $_.Version } else { '' }
                        @{ package = $pkg; displayName = $dn; localIconPath = $icon; version = $ver; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = [bool]$_.ThirdParty }
                    } | Sort-Object { $_.displayName })
                } else {
                    # Third-party apps only

                    # If refresh requested, update cache from headset
                    if ($refresh) {
                        $rows    = Get-KnownHeadsets
                        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                        if (-not $headset) { throw "Headset not found" }
                        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
                        if (-not $device) { throw "Could not connect to headset via ADB" }
                        if ($resolveMissing) {
                            Update-InstalledAppsCache -Device $device -headsetName $headset.Name -ResolveMissing
                        } else {
                            Update-InstalledAppsCache -Device $device -headsetName $headset.Name
                        }
                    }

                    # Use cache if available
                    if (Test-Path -LiteralPath $cachePath) {
                        $cachedRows = @(Import-Csv -LiteralPath $cachePath -Delimiter ",")
                        $appList = @($cachedRows | ForEach-Object {
                            $pkg   = $_.PackageName
                            # Prefer live app_names.csv for display name and icon (stays current without a cache refresh)
                            $entry = if ($appNamesLookup.ContainsKey($pkg)) { $appNamesLookup[$pkg] } else { $null }
                            $dn    = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } elseif ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                            $icon  = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } elseif ($_.LocalIconPath) { $_.LocalIconPath } else { '' }
                            $ver   = if ($_.Version) { $_.Version } else { '' }
                            @{ package = $pkg; displayName = $dn; localIconPath = $icon; version = $ver; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = $true }
                        } | Sort-Object { $_.displayName })
                    } else {
                        # Fallback: live ADB call
                        $rows    = Get-KnownHeadsets
                        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                        if (-not $headset) { throw "Headset not found" }

                        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                        if (-not $device) { throw "Could not connect to headset via ADB" }

                        $installedApps = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly -adb $adbPath
                        $appList = @($installedApps | ForEach-Object {
                            $pkg   = $_.PackageName
                            $entry = if ($appNamesLookup.ContainsKey($pkg)) { $appNamesLookup[$pkg] } else { $null }
                            $dn    = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } elseif ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                            $icon  = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } elseif ($_.LocalIconPath) { $_.LocalIconPath } else { '' }
                            @{ package = $pkg; displayName = $dn; localIconPath = $icon; version = $_.Version; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = $true }
                        } | Sort-Object { $_.displayName })
                    }
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

        # API: POST /api/uninstallapp  body: {"name":"Q3_BLUE","package":"com.beatgames.beatsaber"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/uninstallapp') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $json     = $body | ConvertFrom-Json
                $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
                $safePkg  = [regex]::Match($json.package, '^[\w\.\-]+$').Value
                if (-not $safeName -or -not $safePkg) { throw "Invalid input" }

                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
                if (-not $device) { throw "Could not connect to headset via ADB" }
                $ok = Uninstall-HeadsetApp -Device $device -PackageName $safePkg
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($ok) { '{"ok":true}' } else { '{"ok":false,"error":"Uninstall failed or app not found"}' }))
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errJson  = '{"ok":false,"error":' + ($_.Exception.Message | ConvertTo-Json) + '}'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
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

        # API: POST /api/headset-connection-check  body: {"name":"Q3_Blue"}
        # Returns: {"usb":bool,"wifi":bool}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/headset-connection-check') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd(); $reader.Close()
                $json = $body | ConvertFrom-Json
                $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }

                $usbAvailable = $false
                $usbSpeed     = $null
                if ($headset.SerialNumber -and $adbPath -and (Test-Path -LiteralPath $adbPath)) {
                    try {
                        $usbLine = & $adbPath devices 2>$null | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' }
                        if ($usbLine) {
                            $serial = ($usbLine -split "`t")[0].Trim()
                            if ($serial -eq $headset.SerialNumber) {
                                $usbAvailable = $true
                                $usbSpeed     = Get-UsbDeviceSpeed -Serial $serial
                            }
                        }
                    } catch {}
                }

                $wifiAvailable = $false
                if ($headset.IPAddress) {
                    $wifiAvailable = (Test-Port -hostname $headset.IPAddress -port $adbPort).open
                }

                Send-JsonResponse -Response $response -Body @{ usb = $usbAvailable; usbSpeed = $usbSpeed; wifi = $wifiAvailable }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/install-progress?jobId=xxx
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/install-progress') {
            try {
                $jobId = [regex]::Match($request.Url.Query, '[?&]?jobId=([a-f0-9]+)').Groups[1].Value
                if (-not $jobId) { throw "Missing jobId" }
                $pFile = [System.IO.Path]::Combine($env:TEMP, "vrm_install_$jobId.json")
                if (Test-Path -LiteralPath $pFile) {
                    $raw = [System.IO.File]::ReadAllText($pFile)
                    Send-JsonResponse -Response $response -Raw $raw
                } else {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = "Job not found" }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/install-cancel  body: {"jobId":"xxx"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/install-cancel') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd(); $reader.Close()
                $json  = $body | ConvertFrom-Json
                $jobId = [regex]::Match([string]$json.jobId, '^[a-f0-9]+$').Value
                if (-not $jobId) { throw "Invalid jobId" }

                if ($script:installJobs.ContainsKey($jobId)) {
                    $j = $script:installJobs[$jobId]
                    try { Stop-Job  -Job $j -ErrorAction SilentlyContinue } catch {}
                    try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
                    $script:installJobs.Remove($jobId)
                }

                $pFile = [System.IO.Path]::Combine($env:TEMP, "vrm_install_$jobId.json")
                if (Test-Path -LiteralPath $pFile) {
                    try {
                        $prog = [System.IO.File]::ReadAllText($pFile) | ConvertFrom-Json
                        if ($prog.adbPid -and $prog.adbPid -gt 0) {
                            Stop-Process -Id $prog.adbPid -Force -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    [System.IO.File]::WriteAllText($pFile, '{"step":"cancelled","pct":0,"file":"","error":"","adbPid":0}')
                }

                Send-JsonResponse -Response $response -Body @{ ok = $true }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/installapk
        # Mode A (binary upload): Content-Type: application/octet-stream, headers X-Headset-Name + X-File-Name
        # Mode B (overwrite confirm): JSON body {"name","tempId","overwrite":true}
        # Mode C (local folder path): JSON body {"name","path"[,"overwrite":true]}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/installapk') {
            try {
                $contentType = $request.ContentType -replace ';.*','' | ForEach-Object { $_.Trim() }
                $transport   = $request.Headers['X-Transport']  # 'usb', 'wifi', or empty (auto)

                # Helper: resolve device by transport preference
                $resolveDevice = {
                    param($headset2)
                    if ($transport -eq 'usb' -and $headset2.SerialNumber -and $adbPath -and (Test-Path -LiteralPath $adbPath)) {
                        $usbLine = & $adbPath devices 2>$null | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' }
                        $serial  = if ($usbLine) { ($usbLine -split "`t")[0].Trim() } else { $null }
                        if ($serial -eq $headset2.SerialNumber) {
                            return [PSCustomObject]@{ DeviceId = $serial; ConnectionType = 'USB'; IP = $null; Port = $null }
                        }
                    } elseif ($transport -eq 'wifi') {
                        return Get-AdbWifiDevice -headsetIP $headset2.IPAddress -AdbPort $adbPort -adb $adbPath
                    }
                    return Get-BestAdbDevice -Headset $headset2 -AdbPort $adbPort -adb $adbPath
                }

                # Helper: start the install background job and respond with jobId
                $startJob = {
                    param($deviceId2, $installPath2, $isFolder2, $obbPath2, $pkgName2, $cleanupApk2)
                    $jobId    = [guid]::NewGuid().ToString('N')
                    $pFile    = [System.IO.Path]::Combine($env:TEMP, "vrm_install_$jobId.json")
                    [System.IO.File]::WriteAllText($pFile, '{"step":"queued","pct":0,"file":"","error":"","adbPid":0}')
                    $job = Start-Job -ScriptBlock $installJobBlock -ArgumentList $adbPath, $deviceId2, $installPath2, $isFolder2, $obbPath2, $pkgName2, $pFile, $cleanupApk2
                    $script:installJobs[$jobId] = $job
                    Send-JsonResponse -Response $response -Body @{ ok = $true; jobId = $jobId }
                }

                if ($contentType -eq 'application/octet-stream') {
                    # Mode A: binary APK upload
                    $safeNameRaw  = $request.Headers['X-Headset-Name']
                    $safeFileName = [regex]::Match($request.Headers['X-File-Name'], '^[\w\.\-]+\.apk$').Value
                    $safeName     = [regex]::Match(($safeNameRaw -replace ' ','_'), '^[\w\-]+$').Value
                    if (-not $safeName -or -not $safeFileName) { throw "Invalid upload headers" }

                    $rows    = Get-KnownHeadsets
                    $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                    if (-not $headset) { throw "Headset not found" }
                    $device = & $resolveDevice $headset
                    if (-not $device) { throw "Could not connect to headset via ADB" }

                    # Read and save binary body
                    $ms     = [System.IO.MemoryStream]::new()
                    $buf    = [byte[]]::new(65536)
                    $stream = $request.InputStream
                    while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $read) }
                    $tempPath = [System.IO.Path]::Combine($env:TEMP, "vrmapk_${safeName}_${safeFileName}")
                    [System.IO.File]::WriteAllBytes($tempPath, $ms.ToArray())

                    $pkgName     = [System.IO.Path]::GetFileNameWithoutExtension($safeFileName)
                    $pmOut       = Invoke-AdbCmd -Device $device -Command "shell pm list packages $pkgName"
                    $isInstalled = $pmOut -ne $false -and ($pmOut -match "package:$([regex]::Escape($pkgName))")
                    if ($isInstalled) {
                        $verLine = (Invoke-AdbCmd -Device $device -Command "shell dumpsys package $pkgName" | Select-String 'versionName') | Select-Object -First 1
                        $curVer  = if ($verLine -match 'versionName=(\S+)') { $Matches[1] } else { '' }
                        $tempId  = "vrmapk_${safeName}_${safeFileName}"
                        Send-JsonResponse -Response $response -Body @{ ok = $false; alreadyInstalled = $true; package = $pkgName; installedVersion = $curVer; tempId = $tempId }
                    } else {
                        & $startJob $device.DeviceId $tempPath $false '' $pkgName $true
                    }

                } else {
                    # Mode B or C: JSON body
                    $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                    $body   = $reader.ReadToEnd(); $reader.Close()
                    $json     = $body | ConvertFrom-Json
                    $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
                    if (-not $safeName) { throw "Invalid headset name" }

                    $rows    = Get-KnownHeadsets
                    $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                    if (-not $headset) { throw "Headset not found" }
                    $device = & $resolveDevice $headset
                    if (-not $device) { throw "Could not connect to headset via ADB" }

                    if ($json.tempId) {
                        # Mode B: overwrite-confirmed APK (temp file already on disk)
                        $safeTempId = [regex]::Match($json.tempId, '^vrmapk_[\w\-]+_[\w\.\-]+\.apk$').Value
                        if (-not $safeTempId) { throw "Invalid tempId" }
                        $tempPath = [System.IO.Path]::Combine($env:TEMP, $safeTempId)
                        if (-not (Test-Path -LiteralPath $tempPath)) { throw "Temp file not found or expired" }
                        $pkgName  = [System.IO.Path]::GetFileNameWithoutExtension(([System.IO.Path]::GetFileName($safeTempId) -replace '^vrmapk_[\w\-]+_',''))
                        & $startJob $device.DeviceId $tempPath $false '' $pkgName $true

                    } elseif ($json.path) {
                        # Mode C: local folder/file path
                        $rawPath = [string]$json.path
                        if ($rawPath -match "`0" -or $rawPath.Trim() -eq '') { throw "Invalid path" }
                        try { $safePath = [System.IO.Path]::GetFullPath($rawPath) } catch { throw "Invalid path" }
                        if (-not $safePath) { throw "Invalid path" }
                        $overwrite = [bool]$json.overwrite
                        $isFolder  = Test-Path -LiteralPath $safePath -PathType Container

                        # Find APK to determine package name
                        $pkgName = if ($isFolder) {
                            $apks = @(Get-ChildItem -LiteralPath $safePath -Filter '*.apk' -File -ErrorAction SilentlyContinue)
                            if ($apks.Count -eq 0) { throw "No APK file found in folder" }
                            [System.IO.Path]::GetFileNameWithoutExtension($apks[0].Name)
                        } else {
                            [System.IO.Path]::GetFileNameWithoutExtension($safePath)
                        }

                        # Pre-check: already installed?
                        if (-not $overwrite) {
                            $allApps     = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly:$false -adb $adbPath
                            $isInstalled = [bool]($allApps | Where-Object { $_.PackageName -eq $pkgName })
                            if ($isInstalled) {
                                $verMatch = Invoke-AdbCmd -Device $device -Command "shell dumpsys package $pkgName" -adb $adbPath | Select-String 'versionName' | Select-Object -Last 1
                                $curVer   = if ($verMatch -and "$verMatch" -match 'versionName=(\S+)') { $Matches[1] } else { '' }
                                Send-JsonResponse -Response $response -Body @{ ok = $false; alreadyInstalled = $true; package = $pkgName; installedVersion = $curVer }
                                continue  # finally will close response
                            }
                        }

                        $obbPath = if ($isFolder) { Join-Path $safePath $pkgName } else { '' }

                        & $startJob $device.DeviceId $safePath $isFolder $obbPath $pkgName $false

                    } else {
                        throw "Missing tempId or path"
                    }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
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

                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }
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
                $favRows = @(Get-FavoriteApps -headsetName $safeName)
                $addFav  = [string]$json.favorite -eq 'True' -or [string]$json.favorite -eq 'true'
                if ($addFav) {
                    if (-not ($favRows | Where-Object { $_.PackageName -eq $safePkg })) {
                        $favRows += [PSCustomObject]@{ PackageName = $safePkg; DisplayName = $json.displayName }
                    }
                } else {
                    $favRows = @($favRows | Where-Object { $_.PackageName -ne $safePkg })
                }
                Save-FavoriteApps -favorites $favRows -headsetName $safeName
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
                $usbInfo = Get-AdbUsbDeviceDetails -adb $adbPath
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
                    $response.StatusCode      = 500
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
                $device = Get-AdbUsbDeviceDetails -adb $adbPath
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
                    $ipOutput = Invoke-AdbCmd -Device $device -Command "shell ip -f inet addr show wlan0" -adb $adbPath
                    foreach ($line in $ipOutput) {
                        if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') { $ip = $Matches[1]; break }
                    }
                    $model = ((Invoke-AdbCmd -Device $device -Command "shell getprop ro.product.model" -adb $adbPath) -join '').Trim()
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
                if (-not ($adbPath -and (Test-Path -LiteralPath $adbPath))) {
                    $result.error = 'ADB not found.'
                } else {
                    $knownNetworks = Get-WifiNetworks
                    $preferredNet  = $knownNetworks | Where-Object { $_.Preferred } | Select-Object -First 1
                    if (-not $preferredNet) { $preferredNet = $knownNetworks | Select-Object -First 1 }
                    if (-not $preferredNet) {
                        $result.error = 'No WiFi network configured. Add one in app_config.'
                    } else {
                    $wifiSsid = $preferredNet.SSID
                    $wifiPwd  = $preferredNet.Password
                    # Find USB device
                    $usbDeviceId = (& $adbPath devices 2>&1 |
                        Where-Object { $_ -match '^\S+\s+device$' -and $_ -notmatch '^\*' -and $_ -notmatch '^\d+\.\d+' } |
                        Select-Object -First 1) -replace '\s+device$', ''
                    if (-not $usbDeviceId) {
                        $result.error = 'No USB device found.'
                    } else {
                        $usbDev    = [PSCustomObject]@{ DeviceId = $usbDeviceId; ConnectionType = 'USB'; IP = $null; Port = $null }
                        $result.ok = Connect-HeadsetToWifi -Device $usbDev -Ssid $wifiSsid -Password $wifiPwd
                        if (-not $result.ok) { $result.error = 'WiFi connection failed.' }
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
                    $response.StatusCode      = 500
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

        # API: GET /api/wifi-networks  - returns known WiFi networks (SSIDs only, passwords masked)
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/wifi-networks') {
            try {
                $networks  = @(Get-WifiNetworks)
                $result    = @($networks | ForEach-Object { @{ ssid = $_.SSID; passwordHint = '****'; preferred = $_.Preferred } })
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
                    $response.StatusCode      = 500
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

        # API: POST /api/wifi-networks/upsert  - add or update a WiFi network {ssid, password}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/wifi-networks/upsert') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd(); $reader.Close()
                $json   = $body | ConvertFrom-Json
                $ssid        = ([string]$json.ssid).Trim()
                $wifiPassword = ([string]$json.password).Trim()
                if (-not $ssid) { throw "SSID is required" }
                $networks  = @(Get-WifiNetworks)
                $existing  = $networks | Where-Object { $_.SSID -eq $ssid }
                if ($existing) {
                    $existing.Password = $wifiPassword
                    $message = "updated"
                } else {
                    $isFirst = ($networks.Count -eq 0)
                    $networks += [PSCustomObject]@{ SSID = $ssid; Password = $wifiPassword; Preferred = $isFirst }
                    $message = "added"
                }
                Save-WifiNetworks -Networks $networks
                $jsonOut   = ConvertTo-Json @{ ok = $true; message = $message } -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errMsg    = $_.Exception.Message
                    $errBytes  = [System.Text.Encoding]::UTF8.GetBytes(("{`"ok`":false,`"error`":`"$errMsg`"}"))
                    $response.StatusCode      = 400
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

        # API: POST /api/wifi-networks/delete  - remove a WiFi network {ssid}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/wifi-networks/delete') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd(); $reader.Close()
                $json   = $body | ConvertFrom-Json
                $ssid   = ([string]$json.ssid).Trim()
                if (-not $ssid) { throw "SSID is required" }
                $all      = @(Get-WifiNetworks)
                $wasPreferred = [bool]($all | Where-Object { $_.SSID -eq $ssid -and $_.Preferred })
                $networks = @($all | Where-Object { $_.SSID -ne $ssid })
                if ($wasPreferred -and $networks.Count -gt 0) { $networks[0].Preferred = $true }
                Save-WifiNetworks -Networks $networks
                $jsonOut   = ConvertTo-Json @{ ok = $true } -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errMsg    = $_.Exception.Message
                    $errBytes  = [System.Text.Encoding]::UTF8.GetBytes(("{`"ok`":false,`"error`":`"$errMsg`"}"))
                    $response.StatusCode      = 400
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

        # API: POST /api/wifi-networks/set-preferred  - marks one SSID as preferred {ssid}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/wifi-networks/set-preferred') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd(); $reader.Close()
                $json   = $body | ConvertFrom-Json
                $ssid   = ([string]$json.ssid).Trim()
                if (-not $ssid) { throw "SSID is required" }
                $networks = @(Get-WifiNetworks)
                $found = $false
                foreach ($n in $networks) { $n.Preferred = ($n.SSID -eq $ssid); if ($n.SSID -eq $ssid) { $found = $true } }
                if (-not $found) { throw "SSID not found" }
                Save-WifiNetworks -Networks $networks
                $jsonOut   = ConvertTo-Json @{ ok = $true } -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errMsg    = $_.Exception.Message
                    $errBytes  = [System.Text.Encoding]::UTF8.GetBytes(("{`"ok`":false,`"error`":`"$errMsg`"}"))
                    $response.StatusCode      = 400
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
                $knownNetworks   = Get-WifiNetworks
                $preferredWifi   = $knownNetworks | Where-Object { $_.Preferred } | Select-Object -First 1
                if (-not $preferredWifi) { $preferredWifi = $knownNetworks | Select-Object -First 1 }
                $expectedSsidVal = if ($preferredWifi) { $preferredWifi.SSID } else { '' }
                if ($adbPath -and (Test-Path -LiteralPath $adbPath)) {
                    $details = Get-AdbUsbDeviceDetails -adb $adbPath -AdbPort $adbPort -PackageName $apkPackage
                    if ($details) {
                        $alreadyReg = $false
                        if ($details.SerialNumber) {
                            $rows = Get-KnownHeadsets
                            $alreadyReg = [bool]($rows | Where-Object { $_.SerialNumber -eq $details.SerialNumber })
                        }
                        $result = @{
                            found             = $true
                            ip                = $details.IP
                            model             = $details.Model
                            serialNumber      = $details.SerialNumber
                            ssid              = $details.WiFiSSID
                            expectedSsid      = $expectedSsidVal
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
                    $response.StatusCode      = 500
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
                $parsedIp2 = $null
                if (-not [System.Net.IPAddress]::TryParse([string]$json.ip, [ref]$parsedIp2) -or
                    $parsedIp2.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    throw "INVALID_IP"
                }
                $safeIp = $parsedIp2.ToString()

                $rows = @(Get-KnownHeadsets)

                if ($rows | Where-Object { $_.IPAddress -eq $safeIp })   { throw "IP_DUPLICATE" }
                if ($rows | Where-Object { $_.Name      -eq $safeName }) { throw "NAME_DUPLICATE" }

                Add-Headset -headsets $rows -IPAddress $safeIp -Name $safeName

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

        # API: POST /api/restartmediamtx
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/restartmediamtx') {
            try {
                Stop-MediaMtx
                Start-Sleep -Milliseconds 800
                Start-MediaMtx
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
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/restartwebserver
        # Sends a success response then spawns a delayed process that kills and restarts this server.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/restartwebserver') {
            try {
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $response.Close()
                $thisScript = $PSCommandPath
                $spScriptPath = $ScriptPath
                $spConfig     = $ConfigFilePath
                $spPidFile    = $PidFile
                $spLogFolder  = $LogFolder
                $spLogFile    = $LogFile
                $selfPid      = $PID
                $cmd = "Start-Sleep -Seconds 2;" +
                       "Stop-Process -Id $selfPid -Force -ErrorAction SilentlyContinue;" +
                       "Start-Sleep -Milliseconds 500;" +
                       "Start-Process powershell.exe -ArgumentList @('-NoExit','-File','`"$thisScript`"'," +
                       "'-ScriptPath','`"$spScriptPath`"','-ConfigFilePath','`"$spConfig`"'," +
                       "'-PidFile','`"$spPidFile`"','-LogFolder','`"$spLogFolder`"','-LogFile','`"$spLogFile`"') -WindowStyle Hidden"
                Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', $cmd) -WindowStyle Hidden
                continue
            } catch {
                try { $response.Close() } catch {}
            }
            continue
        }

        # API: GET /api/openconfig  - opens config.json in the default editor (Notepad)
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/openconfig') {
            try {
                $cfgFile = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "config\config.json"))
                if (Test-Path -LiteralPath $cfgFile) {
                    Start-Process notepad.exe -ArgumentList "`"$cfgFile`""
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"config.json not found"}')
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
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/openfolder?target=logs|config|records  - opens folder in Explorer
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/openfolder') {
            try {
                $target = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)['target']
                $recordsFolder = try {
                    $c = Get-Content -LiteralPath $global:ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($c.scrcpy -and $c.scrcpy.recordFolder) { [string]$c.scrcpy.recordFolder } else { $null }
                } catch { $null }
                $folderMap = @{
                    'logs'    = (Join-Path $global:ScriptPath "logs")
                    'config'  = (Join-Path $global:ScriptPath "config")
                    'records' = $recordsFolder
                }
                $folder = $folderMap[$target]
                if ($folder -and [System.IO.Directory]::Exists($folder)) {
                    Start-Process explorer.exe -ArgumentList "`"$folder`""
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"folder not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $dbgMsg = $_.Exception.Message -replace '"',"'" -replace '[^\x20-\x7E]','?'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":false,`"error`":`"$dbgMsg`"}")
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/browse-folder  - opens native Windows folder picker, returns selected path
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/browse-folder') {
            try {
                $tmp = [System.IO.Path]::GetTempFileName()
                $ps  = "Add-Type -AssemblyName System.Windows.Forms;" +
                       "`$d = New-Object System.Windows.Forms.FolderBrowserDialog;" +
                       "`$d.Description = 'Select recording folder';" +
                       "`$d.ShowNewFolderButton = `$true;" +
                       "if (`$d.ShowDialog() -eq 'OK') { [System.IO.File]::WriteAllText('$tmp', `$d.SelectedPath, [System.Text.Encoding]::UTF8) } " +
                       "else { [System.IO.File]::WriteAllText('$tmp', '', [System.Text.Encoding]::UTF8) }"
                Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', $ps) -WindowStyle Hidden -Wait
                $chosen = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8).Trim()
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                if ($chosen) {
                    $escaped = $chosen.Replace('\','\\').Replace('"','\"')
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"$escaped`"}")
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"cancelled":true,"path":""}')
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
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/logs?n=200  - returns last N lines of today's log file as JSON array
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/logs') {
            try {
                $qn      = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)['n']
                $maxLines = if ($qn -and $qn -match '^\d+$') { [int]$qn } else { 200 }
                if ($maxLines -gt 2000) { $maxLines = 2000 }
                $lines   = @()
                $logPath = $null
                if ($global:logFile -and (Test-Path -LiteralPath $global:logFile)) {
                    $logPath = $global:logFile
                } elseif ($global:logFolder -and (Test-Path -LiteralPath $global:logFolder)) {
                    $latest  = Get-ChildItem -LiteralPath $global:logFolder -Filter 'log_*.txt' |
                               Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($latest) { $logPath = $latest.FullName }
                }
                if ($logPath) {
                    $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open,
                          [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::Default)
                    try {
                        $all = [System.Collections.Generic.List[string]]::new()
                        while (-not $sr.EndOfStream) { $all.Add($sr.ReadLine()) }
                        $slice = if ($all.Count -le $maxLines) { $all.ToArray() } else { $all.GetRange($all.Count - $maxLines, $maxLines).ToArray() }
                        $lines = $slice -replace '\\', '\\\\' -replace '"', '\"'
                    } finally { $sr.Close(); $fs.Close() }
                }
                $jsonLines = '[' + (($lines | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonLines)
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
            } finally { $response.Close() }
            continue
        }

        # Proxy: GET /proxy/mediamtx/* -> forwards to localhost MediaMTX API (avoids CORS/auth)
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -match '^/proxy/mediamtx(/.*)$') {
            try {
                $mtxPath  = $Matches[1]
                $mtxQuery = $request.Url.Query
                $mtxPort  = if ($global:mediamtxApiPort) { $global:mediamtxApiPort } else { 9997 }
                $mtxUrl   = "http://127.0.0.1:$mtxPort$mtxPath$mtxQuery"
                $wc = [System.Net.WebClient]::new()
                $wc.Headers.Add('Accept', 'application/json')
                $body = $wc.DownloadString($mtxUrl)
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errMsg = '{"error":"mediamtx unreachable or returned an error"}'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                    $response.StatusCode      = 502
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/appinfo  - returns port info and useful URLs for the topbar Help section
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/appinfo') {
            try {
                $info = @{
                    webServerPort      = $port
                    mediamtxHlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort }    else { 8888 }
                    mediamtxRtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort }   else { 8554 }
                    mediamtxWebrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
                    mediamtxApiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort }    else { 9997 }
                }
                $jsonOut   = ConvertTo-Json $info -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/restartwebserver
        # Sends a success response then spawns a delayed process that kills and restarts this server.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/restartwebserver') {
            try {
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $response.Close()
                $thisScript = $PSCommandPath
                $spScriptPath = $ScriptPath
                $spConfig     = $ConfigFilePath
                $spPidFile    = $PidFile
                $spLogFolder  = $LogFolder
                $spLogFile    = $LogFile
                $selfPid      = $PID
                $cmd = "Start-Sleep -Seconds 2;" +
                       "Stop-Process -Id $selfPid -Force -ErrorAction SilentlyContinue;" +
                       "Start-Sleep -Milliseconds 500;" +
                       "Start-Process powershell.exe -ArgumentList @('-NoExit','-File','`"$thisScript`"'," +
                       "'-ScriptPath','`"$spScriptPath`"','-ConfigFilePath','`"$spConfig`"'," +
                       "'-PidFile','`"$spPidFile`"','-LogFolder','`"$spLogFolder`"','-LogFile','`"$spLogFile`"') -WindowStyle Hidden"
                Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', $cmd) -WindowStyle Hidden
                continue
            } catch {
                try { $response.Close() } catch {}
            }
            continue
        }

        # API: GET /api/openconfig  - opens config.json in the default editor (Notepad)
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/openconfig') {
            try {
                $cfgFile = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "config\config.json"))
                if (Test-Path -LiteralPath $cfgFile) {
                    Start-Process notepad.exe -ArgumentList "`"$cfgFile`""
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"config.json not found"}')
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
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/openfolder?target=logs|config|records  - opens folder in Explorer
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/openfolder') {
            try {
                $target = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)['target']
                $recordsFolder = try {
                    $c = Get-Content -LiteralPath $global:ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($c.scrcpy -and $c.scrcpy.recordFolder) { [string]$c.scrcpy.recordFolder } else { $null }
                } catch { $null }
                $folderMap = @{
                    'logs'    = (Join-Path $global:ScriptPath "logs")
                    'config'  = (Join-Path $global:ScriptPath "config")
                    'records' = $recordsFolder
                }
                $folder = $folderMap[$target]
                if ($folder -and [System.IO.Directory]::Exists($folder)) {
                    Start-Process explorer.exe -ArgumentList "`"$folder`""
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"folder not found"}')
                }
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $dbgMsg = $_.Exception.Message -replace '"',"'" -replace '[^\x20-\x7E]','?'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":false,`"error`":`"$dbgMsg`"}")
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/browse-folder  - opens native Windows folder picker, returns selected path
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/browse-folder') {
            try {
                $tmp = [System.IO.Path]::GetTempFileName()
                $ps  = "Add-Type -AssemblyName System.Windows.Forms;" +
                       "`$d = New-Object System.Windows.Forms.FolderBrowserDialog;" +
                       "`$d.Description = 'Select recording folder';" +
                       "`$d.ShowNewFolderButton = `$true;" +
                       "if (`$d.ShowDialog() -eq 'OK') { [System.IO.File]::WriteAllText('$tmp', `$d.SelectedPath, [System.Text.Encoding]::UTF8) } " +
                       "else { [System.IO.File]::WriteAllText('$tmp', '', [System.Text.Encoding]::UTF8) }"
                Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', $ps) -WindowStyle Hidden -Wait
                $chosen = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8).Trim()
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                if ($chosen) {
                    $escaped = $chosen.Replace('\','\\').Replace('"','\"')
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"$escaped`"}")
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"cancelled":true,"path":""}')
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
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/logs?n=200  - returns last N lines of today's log file as JSON array
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/logs') {
            try {
                $qn      = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)['n']
                $maxLines = if ($qn -and $qn -match '^\d+$') { [int]$qn } else { 200 }
                if ($maxLines -gt 2000) { $maxLines = 2000 }
                $lines   = @()
                $logPath = $null
                if ($global:logFile -and (Test-Path -LiteralPath $global:logFile)) {
                    $logPath = $global:logFile
                } elseif ($global:logFolder -and (Test-Path -LiteralPath $global:logFolder)) {
                    $latest  = Get-ChildItem -LiteralPath $global:logFolder -Filter 'log_*.txt' |
                               Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($latest) { $logPath = $latest.FullName }
                }
                if ($logPath) {
                    $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open,
                          [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::Default)
                    try {
                        $all = [System.Collections.Generic.List[string]]::new()
                        while (-not $sr.EndOfStream) { $all.Add($sr.ReadLine()) }
                        $slice = if ($all.Count -le $maxLines) { $all.ToArray() } else { $all.GetRange($all.Count - $maxLines, $maxLines).ToArray() }
                        $lines = $slice -replace '\\', '\\\\' -replace '"', '\"'
                    } finally { $sr.Close(); $fs.Close() }
                }
                $jsonLines = '[' + (($lines | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonLines)
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
            } finally { $response.Close() }
            continue
        }

        # Proxy: GET /proxy/mediamtx/* -> forwards to localhost MediaMTX API (avoids CORS/auth)
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -match '^/proxy/mediamtx(/.*)$') {
            try {
                $mtxPath  = $Matches[1]
                $mtxQuery = $request.Url.Query
                $mtxPort  = if ($global:mediamtxApiPort) { $global:mediamtxApiPort } else { 9997 }
                $mtxUrl   = "http://127.0.0.1:$mtxPort$mtxPath$mtxQuery"
                $wc = [System.Net.WebClient]::new()
                $wc.Headers.Add('Accept', 'application/json')
                $body = $wc.DownloadString($mtxUrl)
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errMsg = '{"error":"mediamtx unreachable or returned an error"}'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                    $response.StatusCode      = 502
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/appinfo  - returns port info and useful URLs for the topbar Help section
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/appinfo') {
            try {
                $info = @{
                    webServerPort      = $port
                    mediamtxHlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort }    else { 8888 }
                    mediamtxRtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort }   else { 8554 }
                    mediamtxWebrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
                    mediamtxApiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort }    else { 9997 }
                }
                $jsonOut   = ConvertTo-Json $info -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
                    $response.StatusCode      = 500
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # ── Known Apps Management API ─────────────────────────────────────────────

        # API: GET /api/appnames  - returns all rows from app_names.csv as JSON
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/appnames') {
            try {
                $appCsvPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else {
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                }
                $appObjects = @()
                if (Test-Path -LiteralPath $appCsvPath) {
                    $appObjects = @(Import-Csv -LiteralPath $appCsvPath -Delimiter "," |
                        ForEach-Object {
                            [PSCustomObject]@{
                                PackageName   = [string]$_.PackageName
                                DisplayName   = [string]$_.DisplayName
                                IconUrl       = [string]$_.IconUrl
                                LocalIconPath = [string]$_.LocalIconPath
                            }
                        })
                }
                $appsJson = $appObjects | ConvertTo-Json -Compress -Depth 2
                if ($appObjects.Count -eq 0) { $appsJson = '[]' }
                elseif ($appObjects.Count -eq 1) { $appsJson = '[' + $appsJson + ']' }
                $json = '{"apps":' + $appsJson + '}'
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"apps":[]}')
                    $response.StatusCode = 200; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/appnames/save  - upsert a row (key = PackageName)
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/appnames/save') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd(); $reader.Close()
                $json   = $body | ConvertFrom-Json

                $pkg = ($json.PackageName -replace '[^\w\.\-]','').Trim()
                if (-not $pkg) { throw "Invalid PackageName" }

                $appCsvPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else {
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                }

                $rows  = @()
                $cache = [ordered]@{}
                if (Test-Path -LiteralPath $appCsvPath) {
                    foreach ($r in @(Import-Csv -LiteralPath $appCsvPath -Delimiter ",")) {
                        $cache[$r.PackageName] = $r
                    }
                }
                $cache[$pkg] = [PSCustomObject]@{
                    PackageName   = $pkg
                    DisplayName   = [string]$json.DisplayName
                    IconUrl       = [string]$json.IconUrl
                    LocalIconPath = [string]$json.LocalIconPath
                }
                $cache.Values | Sort-Object DisplayName |
                    Export-Csv -LiteralPath $appCsvPath -NoTypeInformation -Encoding UTF8 -Force

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/appnames/delete  - remove a row by PackageName
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/appnames/delete') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd(); $reader.Close()
                $json   = $body | ConvertFrom-Json

                $pkg = ($json.PackageName -replace '[^\w\.\-]','').Trim()
                if (-not $pkg) { throw "Invalid PackageName" }

                $appCsvPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else {
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                }

                if (Test-Path -LiteralPath $appCsvPath) {
                    $rows = @(Import-Csv -LiteralPath $appCsvPath -Delimiter ",") |
                            Where-Object { $_.PackageName -ne $pkg }
                    if ($rows.Count -gt 0) {
                        $rows | Export-Csv -LiteralPath $appCsvPath -NoTypeInformation -Encoding UTF8 -Force
                    } else {
                        '"PackageName","DisplayName","IconUrl","LocalIconPath"' |
                            Set-Content -LiteralPath $appCsvPath -Encoding UTF8 -Force
                    }
                }

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/appnames/clear  - archive current file, create empty replacement
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/appnames/clear') {
            try {
                $appCsvPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else {
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                }

                if (Test-Path -LiteralPath $appCsvPath) {
                    $stamp   = Get-Date -Format 'yyyy.MM.dd-HH.mm'
                    $dir     = Split-Path $appCsvPath -Parent
                    $base    = [System.IO.Path]::GetFileNameWithoutExtension($appCsvPath)
                    $ext     = [System.IO.Path]::GetExtension($appCsvPath)
                    $archive = Join-Path $dir ($base + '_old_' + $stamp + $ext)
                    Rename-Item -LiteralPath $appCsvPath -NewName $archive -Force -ErrorAction Stop
                }

                '"PackageName","DisplayName","IconUrl","LocalIconPath"' |
                    Set-Content -LiteralPath $appCsvPath -Encoding UTF8 -Force

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + ($_ -replace '"',"'") + '"}')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/appnames/refresh - call Get-AppInfo for apps missing display name or icon
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/appnames/refresh') {
            try {
                $appCsvPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else {
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\app_names.csv"))
                }
                $updated = 0
                if (Test-Path -LiteralPath $appCsvPath) {
                    $rows = @(Import-Csv -LiteralPath $appCsvPath -Delimiter ",")
                    foreach ($row in $rows) {
                        $needsUpdate = ([string]::IsNullOrWhiteSpace($row.DisplayName) -or
                                        $row.DisplayName -eq ($row.PackageName -replace '^com\.','') -or
                                        [string]::IsNullOrWhiteSpace($row.IconUrl))
                        if ($needsUpdate) {
                            try {
                                $info = Get-AppInfo -PackageName $row.PackageName -AppCacheFilePath $appCsvPath -searchOnline $true
                                if ($info) { $updated++ }
                            } catch {}
                        }
                    }
                }
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"updated":' + $updated + '}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/config  - returns config.json content as JSON
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/config') {
            try {
                $cfgFile = Join-Path $ScriptPath "config\config.json"
                if (Test-Path -LiteralPath $cfgFile) {
                    $raw = Get-Content -LiteralPath $cfgFile -Raw
                    # Strip UTF-8 BOM if present so JSON.parse() succeeds in the browser
                    if ($raw -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
                    $response.StatusCode = 200
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
                    $response.StatusCode = 404
                }
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{}')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/config/save  - validates and writes the posted JSON as config.json
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/config/save') {
            try {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body   = $reader.ReadToEnd(); $reader.Close()
                # Validate JSON before touching disk
                $null   = $body | ConvertFrom-Json
                $cfgFile = Join-Path $ScriptPath "config\config.json"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($cfgFile, $body, $utf8NoBom)
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $errMsg = ($_ -replace '"',"'") -replace '[\r\n]',' '
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + $errMsg + '"}')
                    $response.StatusCode = 400; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/config/reset  - archives config.json with timestamp, copies template
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/config/reset') {
            try {
                $cfgFile = Join-Path $ScriptPath "config\config.json"
                $tplFile = Join-Path $ScriptPath "templates\config\config.json"
                if (-not (Test-Path -LiteralPath $tplFile)) { throw "Template file not found" }
                if (Test-Path -LiteralPath $cfgFile) {
                    $stamp   = Get-Date -Format 'yyyy.MM.dd-HH.mm'
                    $cfgDir  = [System.IO.Path]::GetDirectoryName($cfgFile)
                    $archive = Join-Path $cfgDir "config_$stamp.json"
                    Copy-Item -LiteralPath $cfgFile -Destination $archive -Force
                }
                Copy-Item -LiteralPath $tplFile -Destination $cfgFile -Force
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # ── /end Known Apps Management API ───────────────────────────────────────

        # API: GET /api/timer?id=<headsetID>&action=... OR ?name=<displayName>&action=...
        # All actions use GET so Stream Deck and browser links work without POST/CORS setup.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/timer') {
            try {
                $rawQuery = $request.Url.Query.TrimStart('?')
                $qParams  = @{}
                foreach ($pair in $rawQuery -split '&') {
                    $kv = $pair -split '=', 2
                    if ($kv.Count -eq 2) { $qParams[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1]) }
                }

                $headsetId = 0
                if ($qParams.ContainsKey('id') -and $qParams['id'] -match '^\d+$') {
                    $headsetId = [int]$qParams['id']
                } elseif ($qParams.ContainsKey('name') -and $qParams['name'] -ne '') {
                    $safeName = Convert-Displayname $qParams['name']
                    $matched = @(Get-KnownHeadsets) | Where-Object { (Convert-Displayname $_.Name) -eq $safeName } | Select-Object -First 1
                    if ($matched) { $headsetId = [int]$matched.ID }
                }
                $action = if ($qParams.ContainsKey('action')) { $qParams['action'].ToLower() } else { '' }

                if ($headsetId -le 0 -or -not $action) { throw 'Missing id or action' }

                $respJson = '{"ok":false,"error":"unknown action"}'

                switch ($action) {
                    'start' {
                        Start-HeadsetTimer -headsetId $headsetId
                        $respJson = '{"ok":true}'
                    }
                    'stop' {
                        Stop-HeadsetTimer -headsetId $headsetId
                        $respJson = '{"ok":true}'
                    }
                    'pause' {
                        $pauseOk = Suspend-HeadsetTimer -headsetId $headsetId
                        $respJson = if ($pauseOk -ne $false) { '{"ok":true}' } else { '{"ok":false,"error":"timer not found"}' }
                    }
                    'resume' {
                        $resumeOk = Resume-HeadsetTimer -headsetId $headsetId
                        $respJson = if ($resumeOk -ne $false) { '{"ok":true}' } else { '{"ok":false,"error":"timer not found or not paused"}' }
                    }
                    'reset' {
                        Stop-HeadsetTimer -headsetId $headsetId
                        $respJson = '{"ok":true}'
                    }
                    'status' {
                        $st = Get-TimerStatus -headsetId $headsetId
                        $activeStr = if ($st.active)  { 'true' } else { 'false' }
                        $pausedStr = if ($st.paused)  { 'true' } else { 'false' }
                        $valueJson = $st.value  | ConvertTo-Json
                        $modeJson  = $st.mode   | ConvertTo-Json
                        $respJson  = '{"ok":true,"active":' + $activeStr +
                                     ',"paused":' + $pausedStr +
                                     ',"value":'   + $valueJson +
                                     ',"minutes":' + $st.minutes +
                                     ',"seconds":' + $st.seconds +
                                     ',"mode":'    + $modeJson + '}'
                    }
                    'config' {
                        $min  = if ($qParams.ContainsKey('minutes') -and $qParams['minutes'] -match '^\d+$') { [int]$qParams['minutes'] } else { 5 }
                        $sec  = if ($qParams.ContainsKey('seconds') -and $qParams['seconds'] -match '^\d+$') { [int]$qParams['seconds'] } else { 0 }
                        $mode = if ($qParams.ContainsKey('mode')    -and $qParams['mode'] -match '^(dec|inc)$') { $qParams['mode'] } else { 'dec' }
                        Set-TimerConfig -headsetId $headsetId -minutes $min -seconds $sec -mode $mode
                        $respJson = '{"ok":true}'
                    }
                }

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + ($_.Exception.Message -replace '"',"'") + '"}')
                    $response.StatusCode = 400; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        try {
            # Resolve URL path to a file.
            # /data/*.csv  -> served from <ScriptPath>\data\  (read-only CSV export)
            # everything else -> served from <ScriptPath>\website\
            $urlPath = [Uri]::UnescapeDataString($request.Url.LocalPath).TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
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
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) {
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log $msg.WebServerStopped -Level INFO
}
