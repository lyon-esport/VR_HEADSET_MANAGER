
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

# Import all modules (same pattern as VRMonitor job in headsets_monitoring.ps1)
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

# P/Invoke type for injecting keystrokes into the main process console (used by /api/app-shutdown)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class VrmConsoleInput {
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
    [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")] public static extern bool WriteConsoleInput(
        IntPtr hConsoleInput, INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsWritten);
    [StructLayout(LayoutKind.Explicit, CharSet=CharSet.Unicode)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public short EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct KEY_EVENT_RECORD {
        public int bKeyDown;
        public short wRepeatCount;
        public short wVirtualKeyCode;
        public short wVirtualScanCode;
        public char UnicodeChar;
        public int dwControlKeyState;
    }
    public static bool InjectKey(uint pid, char ch, short vk) {
        FreeConsole();
        if (!AttachConsole(pid)) return false;
        IntPtr hIn = GetStdHandle(-10);
        var records = new INPUT_RECORD[2];
        records[0].EventType = 1;
        records[0].KeyEvent.bKeyDown = 1;
        records[0].KeyEvent.wRepeatCount = 1;
        records[0].KeyEvent.wVirtualKeyCode = vk;
        records[0].KeyEvent.UnicodeChar = ch;
        records[1] = records[0];
        records[1].KeyEvent.bKeyDown = 0;
        uint written;
        bool ok = WriteConsoleInput(hIn, records, 2, out written);
        FreeConsole();
        return ok;
    }
}
'@

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
        $json = if ($Raw) { $Raw } else { ConvertTo-Json -InputObject $Body -Compress -Depth $Depth }
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
    if ($global:MdnsResponder_enabled -and $global:MdnsResponder_hostname) {
        Write-Log ("  http://" + $global:MdnsResponder_hostname + ".local:" + $port + "/ [mDNS]") -Level INFO
    }
    foreach ($ip in $lanIPs) {
        Write-Log ($msg.WebServerLinkLine -f $ip, $port, "") -Level INFO
    }
} else {
    Write-Log $msg.WebServerNoLanAddress -Level WARNING
}

# Write own PID to lock file so scripts_init.ps1 can detect us across reloads
if ($PidFile) {
    $PID | Set-Content -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

# Boost this process priority above Normal so the single-threaded request loop
# is not starved when scrcpy/ffmpeg/mediamtx saturate the host. AboveNormal (not
# High) preserves scheduling fairness for the streaming workload.
try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch {}

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

# mtime-based cache for known_headsets.csv (mirrors $script:headsetInfosCache pattern)
$script:knownHeadsetsCache      = $null
$script:knownHeadsetsCacheMtime = $null

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

# Background job for async online app name resolution (Update-AppCacheOnline).
# Runs in a NEW PowerShell process; dot-sources scripts_init to access module functions.
$resolveJobBlock = {
    param([string]$ScriptPath, [string]$ProgressFile, [string]$ConfigFilePath, [bool]$ForceOnline = $false)
    function Set-ResolveProg {
        param([string]$status)
        $safe = $status -replace '"', "'"
        try { [System.IO.File]::WriteAllText($ProgressFile, "{`"status`":`"$safe`"}") } catch {}
    }
    Set-ResolveProg 'running'
    try {
        $global:ScriptPath         = $ScriptPath
        $global:ConfigFilePath     = $ConfigFilePath
        $global:IsWebServerProcess = $true
        . (Join-Path $ScriptPath 'modules\scripts_init.ps1')
        Update-AppCacheOnline -AppCacheFilePath (Join-Path $ScriptPath 'data\known_apps.csv') -ProgressFile $ProgressFile -ForceOnline:$ForceOnline
        Set-ResolveProg 'done'
    } catch {
        $err = ($_.ToString() -replace '"', "'") -replace '[^\x20-\x7E]', ''
        try { [System.IO.File]::WriteAllText($ProgressFile, "{`"status`":`"error`",`"error`":`"$err`"}") } catch {}
    }
}

# Active resolve job guard (only one at a time)
$script:resolveJob      = $null
$script:resolveProgFile = [System.IO.Path]::Combine($env:TEMP, 'vrm_resolve.json')
# Reset stale progress file from a previous session (running/queued with no active job)
if (Test-Path -LiteralPath $script:resolveProgFile) {
    try {
        $stale = [System.IO.File]::ReadAllText($script:resolveProgFile) | ConvertFrom-Json
        if ($stale.status -in @('running', 'queued')) {
            [System.IO.File]::WriteAllText($script:resolveProgFile, '{"status":"idle"}')
        }
    } catch { Remove-Item -LiteralPath $script:resolveProgFile -Force -ErrorAction SilentlyContinue }
}

# Active update-versions job guard (only one at a time)
$script:updateVersionsJob          = $null
$script:updateVersionsProgFile     = [System.IO.Path]::Combine($env:TEMP, 'vrm_update_versions.json')
$script:updateVersionsHeadsetName  = $null

# Background USB detection - single persistent job, loads modules once, polls every 3 seconds
$script:usbInfoResultFile = [System.IO.Path]::Combine($env:TEMP, 'vrm_usb_info.json')
$script:usbInfoJob = $null

if ($adbPath -and (Test-Path -LiteralPath $adbPath)) {
    $uvSp = $ScriptPath; $uvCp = $ConfigFilePath; $uvExe = $adbPath; $uvPort = $adbPort; $uvPkg = $apkPackage
    $uvOut = $script:usbInfoResultFile
    $script:usbInfoJob = Start-Job -ScriptBlock {
        param($sp, $cp, $exe, $port, $pkg, $outFile)
        $global:ScriptPath = $sp; $global:ConfigFilePath = $cp; $global:IsWebServerProcess = $true
        . (Join-Path $sp 'modules\scripts_init.ps1')
        while ($true) {
            try {
                $result = Get-AdbUsbDeviceDetails -adb $exe -AdbPort $port -PackageName $pkg
                $json = if ($result) { $result | ConvertTo-Json -Compress } else { 'null' }
            } catch {
                $json = 'null'
            }
            try { [System.IO.File]::WriteAllText($outFile, $json) } catch {}
            Start-Sleep -Seconds 3
        }
    } -ArgumentList $uvSp, $uvCp, $uvExe, $uvPort, $uvPkg, $uvOut
}

try {
    while ($listener.IsListening) {
        # GetContext() blocks until a request arrives
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        # USB probe runs in a persistent background job - result read from temp file on demand

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
        # Delegates to Set-HeadsetsOrder (headsets_manager.ps1) which saves CSV and regenerates HTML monitors.
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

                Set-HeadsetsOrder -OrderedDisplayNames ([string[]]$json.order)

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

                    # Guard: block enabling when recording drive space is low
                    if ($newVal -eq 'True') {
                        $rdInfo = $null
                        try {
                            if (Test-Path -LiteralPath $global:computerMonitoringFilePath) {
                                $monJson = Get-Content -LiteralPath $global:computerMonitoringFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
                                $rdInfo  = $monJson.RecordingDrive
                            }
                        } catch {}
                        if (-not $rdInfo) {
                            try { $rdInfo = Get-RecordingDriveInfo } catch {}
                        }
                        if ($rdInfo -and $rdInfo.IsLow) {
                            $lowBody = ('{"ok":false,"storageLow":true,"freeGB":' + $rdInfo.FreeGB + ',"minFreeGB":' + $rdInfo.MinFreeGB + ',"driveLetter":"' + $rdInfo.DriveLetter + '"}')
                            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($lowBody)
                            $response.StatusCode      = 200
                            $response.ContentType     = 'application/json; charset=utf-8'
                            $response.Headers.Add('Access-Control-Allow-Origin', '*')
                            $response.ContentLength64 = $respBytes.Length
                            $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                            $response.Close()
                            continue
                        }
                    }

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

        # API: GET /api/recording-drive  - returns RecordingDrive node from computer_monitoring.json
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/recording-drive') {
            try {
                $rdInfo = $null
                try {
                    if (Test-Path -LiteralPath $global:computerMonitoringFilePath) {
                        $monJson = Get-Content -LiteralPath $global:computerMonitoringFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
                        $rdInfo  = $monJson.RecordingDrive
                    }
                } catch {}
                if (-not $rdInfo) {
                    try { $rdInfo = Get-RecordingDriveInfo } catch {}
                }
                if ($rdInfo) {
                    Send-JsonResponse -Response $response -Body $rdInfo
                } else {
                    Send-JsonResponse -Response $response -Body @{ error = 'unavailable' }
                }
            } catch {
                try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/load-tier  - returns the current adaptive-monitoring tier so the
        # browser can scale its own polling intervals (status, computer-stats) up under load.
        # Tier and multiplier come from Get-LoadTier / Get-LoadMultiplier in utils.ps1; base
        # values come from the live config-driven globals so the operator can re-tune in one place.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/load-tier') {
            try {
                $tier = try { Get-LoadTier } catch { 'idle' }
                $mult = try { Get-LoadMultiplier } catch { 1 }
                $vrm  = if ($null -ne $global:VRMonitor_refresh_timer) { [int]$global:VRMonitor_refresh_timer } else { 5 }
                $cm   = if ($null -ne $global:ComputerMonitoring_refresh_timer_sec) { [int]$global:ComputerMonitoring_refresh_timer_sec } else { 60 }
                Send-JsonResponse -Response $response -Body @{
                    ok       = $true
                    loadTier = @{
                        tier       = "$tier"
                        multiplier = [int]$mult
                        base       = @{ vrmonitor = $vrm; computer_monitoring = $cm }
                    }
                }
            } catch {
                try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/capture-mode  - returns the current global capture mode
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/capture-mode') {
            try {
                Send-JsonResponse -Response $response -Body @{ ok = $true; mode = "$global:CaptureMode" }
            } catch {
                try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/capture-mode  body: {"mode":"StreamOnly|StreamAndLocalWindow|LocalWindow"}
        # Switches global capture mode, persists to config.json, restarts any running
        # scrcpy session in the new mode. Mirrors the CLI Config -> V sub-menu.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/capture-mode') {
            try {
                $body = (New-Object System.IO.StreamReader($request.InputStream)).ReadToEnd()
                $j = $body | ConvertFrom-Json -ErrorAction Stop
                $mode = "$($j.mode)"
                if ($mode -notin @('StreamOnly','StreamAndLocalWindow','LocalWindow')) {
                    Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'invalid mode' }
                } else {
                    $ok = [bool](Set-CaptureMode -Mode $mode)
                    Send-JsonResponse -Response $response -Body @{ ok = $ok; mode = "$global:CaptureMode" }
                }
            } catch {
                try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = "$($_.Exception.Message)" } } catch {}
            } finally { $response.Close() }
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

        # API: POST /api/shutdown-all  - shuts down selected (or all) ADB-reachable headsets
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/shutdown-all') {
            try {
                $filter          = $null
                $alsoShutdownApp = $false
                if ($request.HasEntityBody) {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyStr = $reader.ReadToEnd()
                    $reader.Close()
                    if ($bodyStr -and $bodyStr.Trim() -ne '') {
                        try {
                            $parsed = $bodyStr | ConvertFrom-Json
                            if ($parsed.headsets) { $filter = @($parsed.headsets) }
                            if ($parsed.PSObject.Properties.Name -contains 'alsoShutdownApp') {
                                $alsoShutdownApp = [bool]$parsed.alsoShutdownApp
                            }
                        } catch {}
                    }
                }
                $rows = Get-KnownHeadsets
                if ($filter) { $rows = $rows | Where-Object { $filter -contains ($_.Name -replace ' ', '_') } }
                $results = @()
                foreach ($h in $rows) {
                    $device = Get-BestAdbDevice -Headset $h -AdbPort $adbPort -adb $adbPath
                    if ($device) {
                        $ok = Invoke-HeadsetShutdown -Device $device -adb $adbPath
                        Write-Log "Shutdown-all: $($h.Name) => ok=$ok" -Level INFO
                        $results += @{ name = ($h.Name -replace ' ', '_'); ok = [bool]$ok }
                    } else {
                        $results += @{ name = ($h.Name -replace ' ', '_'); ok = $false }
                    }
                }
                $respJson  = if ($results.Count -gt 0) { ConvertTo-Json -InputObject @($results) -Compress } else { '[]' }
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"results`":$respJson}")
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
                    $alsoShutdownApp = $false
                } catch {}
            } finally {
                $response.Close()
                # App shutdown injected AFTER response is flushed so the browser receives
                # the JSON before the web server process begins its own teardown.
                if ($alsoShutdownApp) {
                    try {
                        $mainProc = Get-WmiObject Win32_Process |
                            Where-Object { $_.CommandLine -match 'main\.ps1' } |
                            Select-Object -First 1
                        if ($mainProc) {
                            $mainPid = [uint32]$mainProc.ProcessId
                            [void][VrmConsoleInput]::InjectKey($mainPid, '0', 0x30)
                            [void][VrmConsoleInput]::InjectKey($mainPid, [char]13, 0x0D)
                        }
                    } catch {}
                }
            }
            continue
        }

        # API: GET /api/headset-status?name=<DisplayName>
        # Lightweight status endpoint: reads known_headsets_infos.csv (written by VRMonitor) and
        # returns the live data for one headset as JSON. No ADB call. Used by the monitoring overlay
        # JS to update the DOM every second without re-downloading the full HTML page.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/headset-status') {
            try {
                $rawName = $request.QueryString['name']
                if (-not $rawName) { throw "Missing name parameter" }

                $infosPath = $global:knownHeadsetsInfosFilePath
                if (-not (Test-Path -LiteralPath $infosPath)) {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = 'No monitoring data yet' }
                    continue
                }

                # Cache the parsed CSV per file-mtime so N concurrent pollers
                # (each headset monitoring overlay polls 1Hz) share a single disk
                # read. Otherwise the single-threaded request loop spends most of
                # its time doing redundant Import-Csv calls on the same file.
                $infosMtime = (Get-Item -LiteralPath $infosPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
                if (-not $script:headsetInfosCache -or
                    $script:headsetInfosCacheMtime -ne $infosMtime) {
                    $rows = Import-Csv -LiteralPath $infosPath -Delimiter ";"
                    $script:headsetInfosCache       = @{}
                    foreach ($r in $rows) { $script:headsetInfosCache[$r.Name] = $r }
                    $script:headsetInfosCacheMtime  = $infosMtime
                }
                $row = $script:headsetInfosCache[$rawName]

                if (-not $row) {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = 'Headset not found' }
                    continue
                }

                # Parse raw CSV strings into typed values for the JS consumer
                $battery    = if ($row.Battery -and $row.Battery -ne '-') { [int]($row.Battery -replace '\s*%','') } else { $null }
                $battLeft   = if ($row.BatteryControllerLeft  -and $row.BatteryControllerLeft  -ne '-') { [int]($row.BatteryControllerLeft  -replace '\s*%','') } else { $null }
                $battRight  = if ($row.BatteryControllerRight -and $row.BatteryControllerRight -ne '-') { [int]($row.BatteryControllerRight -replace '\s*%','') } else { $null }
                $temp       = if ($row.Temp -and $row.Temp -ne '-') { [int]($row.Temp -replace ',','.') } else { $null }
                $timeMin    = if ($row.TimeRemainingMin -and $row.TimeRemainingMin -ne '-' -and $row.TimeRemainingMin -ne '') { [int]$row.TimeRemainingMin } else { $null }

                $result = @{
                    ping                 = [bool]($row.Ping -eq 'True')
                    battery              = $battery
                    battery_ctrl_left    = $battLeft
                    battery_ctrl_right   = $battRight
                    charging             = [bool]($row.Charging -eq 'True')
                    temp                 = $temp
                    power_state          = if ($row.PowerState -and $row.PowerState -ne '-') { $row.PowerState } else { '' }
                    time_remaining_min   = $timeMin
                    running_app          = if ($row.RunningApp)     { $row.RunningApp }     else { '' }
                    running_app_icon     = if ($row.RunningAppIcon) { $row.RunningAppIcon } else { '' }
                }
                Send-JsonResponse -Response $response -Body $result
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
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

                $brand = if ($headset.PSObject.Properties['Brand'] -and $headset.Brand) { $headset.Brand } else { (Get-HeadsetBrandModel -Device $device -adb $adbPath).Brand }
                $screenTimeout    = Get-HeadsetScreenTimeout    -Device $device -adb $adbPath -Brand $brand
                $sleepTimeout     = Get-HeadsetSleepTimeout     -Device $device -adb $adbPath -Brand $brand
                $soundLevel       = Get-HeadsetSoundLevel       -Device $device -adb $adbPath
                $brightness       = Get-HeadsetBrightness       -Device $device -adb $adbPath -Brand $brand
                $blockUpdates     = Get-HeadsetUpdateBlockStatus -Device $device -adb $adbPath -Brand $brand

                Send-JsonResponse -Response $response -Body @{
                    ok               = $true
                    screenTimeout    = $screenTimeout
                    sleepTimeout     = $sleepTimeout
                    soundLevel       = $soundLevel
                    brightness       = $brightness
                    blockUpdates     = $blockUpdates
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/headset-firmware?name=Q3_BLUE  - returns firmware version, build, and pending OTA
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/headset-firmware') {
            try {
                $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device  = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }

                $brand = if ($headset.PSObject.Properties['Brand'] -and $headset.Brand) { $headset.Brand } else { (Get-HeadsetBrandModel -Device $device -adb $adbPath).Brand }
                $fw = Get-HeadsetFirmwareInfo -Device $device -adb $adbPath -Brand $brand
                Send-JsonResponse -Response $response -Body @{
                    ok            = $true
                    version       = $fw.Version
                    build         = $fw.Build
                    updateVersion = $fw.UpdateVersion
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/companion-info?name=Q3_BLUE
        # Calls GET http://<IP>:8765/info on the VRHM Companion app and returns the result.
        # Returns {"ok":false,"companion":false} when the companion app is not running.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/companion-info') {
            try {
                $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $info = Get-CompanionInfo -IP $headset.IPAddress
                if ($null -ne $info) {
                    Send-JsonResponse -Response $response -Body @{ ok = $true; companion = $true; data = $info }
                } else {
                    Send-JsonResponse -Response $response -Body @{ ok = $true; companion = $false }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/companion-settings?name=Q3_BLUE  body: {"auto_adb_wifi":bool}
        # Forwards settings to the Companion app running on the headset.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/companion-settings') {
            try {
                $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }

                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $bodyRaw = $reader.ReadToEnd()
                $reader.Close()
                $json = $bodyRaw | ConvertFrom-Json

                $url  = "http://$($headset.IPAddress):8765/settings"
                $resp2 = Invoke-RestMethod -Uri $url -Method POST -Body $bodyRaw `
                             -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
                Send-JsonResponse -Response $response -Body @{ ok = [bool]$resp2.ok }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally {
                $response.Close()
            }
            continue
        }

        # API: GET /api/headset-storage?name=Q3_BLUE  - returns storage info via df /sdcard
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/headset-storage') {
            try {
                $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device  = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                if (-not $device) { throw "Could not connect to headset via ADB" }

                $s = Get-HeadsetStorageInfo -Device $device -adb $adbPath
                if (-not $s) { throw "Could not read storage info" }
                Send-JsonResponse -Response $response -Body @{
                    ok          = $true
                    totalGB     = $s.TotalGB
                    usedGB      = $s.UsedGB
                    freeGB      = $s.FreeGB
                    usedPercent = $s.UsedPercent
                    freePercent = $s.FreePercent
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
                $brand = if ($headset.PSObject.Properties['Brand'] -and $headset.Brand) { $headset.Brand } else { (Get-HeadsetBrandModel -Device $device -adb $adbPath).Brand }
                if ($null -ne $s.guardianMode) {
                    Set-HeadsetGuardian -Device $device -adb $adbPath -Brand $brand | Out-Null
                }

                if ($null -ne $s.guardianPause) {
                    Set-HeadsetGuardianPause -Device $device -Pause ([bool]$s.guardianPause) -adb $adbPath -Brand $brand | Out-Null
                }

                if ($null -ne $s.soundLevel) {
                    Set-HeadsetSoundLevel -Device $device -Percent ([int]$s.soundLevel) -adb $adbPath | Out-Null
                }

                if ($null -ne $s.brightness) {
                    Set-HeadsetBrightness -Device $device -Percent ([int]$s.brightness) -adb $adbPath -Brand $brand | Out-Null
                }

                if ($null -ne $s.proxOverride) {
                    Set-HeadsetProximitySensorOverride -Device $device -adb $adbPath | Out-Null
                }

                if ($null -ne $s.displaySizeReset) {
                    Reset-HeadsetDisplaySize -Device $device -adb $adbPath | Out-Null
                }

                if ($null -ne $s.blockUpdates) {
                    Set-HeadsetUpdateBlocked -Device $device -Block ([bool]$s.blockUpdates) -adb $adbPath -Brand $brand | Out-Null
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
                try {
                    $liveConfig = Get-Content -LiteralPath $global:configFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($modelParam -and $liveConfig.scrcpy.parameters.$modelParam -and $liveConfig.scrcpy.parameters.$modelParam.views) {
                        $views = @($liveConfig.scrcpy.parameters.$modelParam.views.PSObject.Properties | Select-Object -ExpandProperty Name)
                    }
                } catch {}
                # Built-in non-removable view available on every model.
                if ('fullscreen' -notin $views) { $views += 'fullscreen' }
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

        # API: POST /api/stop-scrcpy  body: {"name":"Q3_BLUE"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/stop-scrcpy') {
            try {
                $reader   = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body     = $reader.ReadToEnd()
                $reader.Close()
                $json     = $body | ConvertFrom-Json
                $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }
                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if ($headset) {
                    $ok        = Stop-Scrcpy -HeadsetName $headset.Name -HeadsetIP $headset.IPAddress
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":' + ($ok.ToString().ToLower()) + '}')
                } else {
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
                }
                Send-JsonResponse -Response $response -Body $respBytes -StatusCode 200
            } catch {
                try { Send-JsonResponse -Response $response -Body ([System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')) -StatusCode 500 } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/start-scrcpy-all - enables autorestart for all headsets (VRMonitor starts scrcpy)
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/start-scrcpy-all') {
            try {
                $rows = Get-KnownHeadsets
                foreach ($row in $rows) {
                    Update-HeadsetField -Id $row.ID -Field 'scrcpy_AutoRestart' -NewValue 'True'
                }
                Send-JsonResponse -Response $response -Raw '{"ok":true}'
            } catch {
                try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
            } finally {
                $response.Close()
            }
            continue
        }

        # API: POST /api/stop-scrcpy-all - disables autorestart for all headsets then kills all scrcpy
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/stop-scrcpy-all') {
            try {
                $rows = Get-KnownHeadsets
                foreach ($row in $rows) {
                    Update-HeadsetField -Id $row.ID -Field 'scrcpy_AutoRestart' -NewValue 'False'
                }
                Stop-Scrcpy
                Send-JsonResponse -Response $response -Raw '{"ok":true}'
            } catch {
                try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
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
                    ',"Brand":' + ($row.Brand         | ConvertTo-Json) +
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

        # API: GET /api/headsets-status  - all headsets combined status (ping/scrcpy/adb/runningApp/model/autoRestart)
        # Shared by video_monitor, headsets_monitoring, headsets_settings. Uses mtime caches so at most
        # one CSV read per write cycle regardless of how many pages poll simultaneously.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/headsets-status') {
            try {
                # Refresh infos cache (reuse existing $script:headsetInfosCache pattern)
                $infosPath = $global:knownHeadsetsInfosFilePath
                if ($infosPath -and (Test-Path -LiteralPath $infosPath)) {
                    $infosMtime = (Get-Item -LiteralPath $infosPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
                    if (-not $script:headsetInfosCache -or $script:headsetInfosCacheMtime -ne $infosMtime) {
                        $rows = Import-Csv -LiteralPath $infosPath -Delimiter ";"
                        $script:headsetInfosCache      = @{}
                        foreach ($r in $rows) { $script:headsetInfosCache[$r.Name] = $r }
                        $script:headsetInfosCacheMtime = $infosMtime
                    }
                }

                # Refresh known headsets config cache
                $headsetsPath = $global:knownHeadsetsFilePath
                $headsetsMtime = (Get-Item -LiteralPath $headsetsPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
                if (-not $script:knownHeadsetsCache -or $script:knownHeadsetsCacheMtime -ne $headsetsMtime) {
                    $script:knownHeadsetsCache      = @{}
                    foreach ($h in (Get-KnownHeadsets)) { $script:knownHeadsetsCache[$h.Name] = $h }
                    $script:knownHeadsetsCacheMtime = $headsetsMtime
                }

                # Build response: one entry per known headset joined with live infos
                $items = @($script:knownHeadsetsCache.Values |
                    Sort-Object { [int]$_.ID } |
                    ForEach-Object {
                        $h    = $_
                        $info = if ($script:headsetInfosCache) { $script:headsetInfosCache[$h.Name] } else { $null }
                        @{
                            display_name          = Convert-Displayname $h.Name
                            name                  = $h.Name
                            id                    = [int]$h.ID
                            ip_address            = if ($h.IPAddress) { $h.IPAddress } else { '' }
                            ping                  = [bool]($info.Ping    -eq 'True')
                            scrcpy                = [bool]($info.SCRCPY  -eq 'ok')
                            adb                   = [bool]($info.ADBWifi -eq 'True')
                            charging              = [bool]($info.Charging -eq 'True')
                            charging_wattage      = if ($info.ChargingWattage -and $info.ChargingWattage -ne '-') { $info.ChargingWattage } else { '' }
                            power_state           = if ($info.PowerState -and $info.PowerState -ne '-') { $info.PowerState } else { '' }
                            time_remaining_min    = if ($info.TimeRemainingMin -and $info.TimeRemainingMin -ne '-') { $info.TimeRemainingMin } else { '' }
                            battery               = if ($info.Battery -and $info.Battery -ne '-') { $info.Battery } else { '-' }
                            battery_ctrl_left     = if ($info.BatteryControllerLeft  -and $info.BatteryControllerLeft  -ne '-') { $info.BatteryControllerLeft  } else { '-' }
                            battery_ctrl_right    = if ($info.BatteryControllerRight -and $info.BatteryControllerRight -ne '-') { $info.BatteryControllerRight } else { '-' }
                            temp                  = if ($info.Temp -and $info.Temp -ne '-') { $info.Temp } else { '-' }
                            running_app           = if ($info.RunningApp)     { $info.RunningApp }     else { '' }
                            running_app_icon      = if ($info.RunningAppIcon) { $info.RunningAppIcon } else { '' }
                            model                 = if ($info.Model -and $info.Model -ne '-') { $info.Model } elseif ($h.Model) { $h.Model } else { '' }
                            scrcpy_auto_restart   = [bool]($h.scrcpy_AutoRestart -eq 'True')
                        }
                    }
                )
                Send-JsonResponse -Response $response -Body $items
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
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

                $favList = @()
                $favRows = Get-FavoriteApps -headsetName $safeName
                foreach ($r in $favRows) {
                    if ($r.PackageName) {
                        $favList += @{ package = $r.PackageName; displayName = $r.DisplayName }
                    }
                }
                $appNamesPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else { [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv")) }
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

                $appNamesPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else { [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv")) }
                $cachePath    = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\${safeName}_installed_apps.csv"))
                $metaHomePkg  = 'com.oculus.vrshell'

                # Load favorites
                $favPkgs = @(Get-FavoriteApps -headsetName $safeName | Select-Object -ExpandProperty PackageName)

                # Load known_apps.csv as the live source of truth for display names and icons
                $appNamesLookup = @{}
                if (Test-Path -LiteralPath $appNamesPath) {
                    @(Import-Csv -LiteralPath $appNamesPath -Delimiter ",") | ForEach-Object {
                        if ($_.PackageName) { $appNamesLookup[$_.PackageName] = $_ }
                    }
                }

                # Refresh cache from headset when requested (covers both includeSystem and default)
                if ($refresh) {
                    $rows    = Get-KnownHeadsets
                    $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                    if (-not $headset) { throw "Headset not found" }
                    $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
                    if (-not $device) { throw "Could not connect to headset via ADB" }
                    Update-InstalledAppsCache -Device $device -headsetName $headset.Name
                }

                if (Test-Path -LiteralPath $cachePath) {
                    # Read lean cache (PackageName, Version) and enrich from known_apps.csv
                    $cachedRows = @(Import-Csv -LiteralPath $cachePath -Delimiter ",")
                    $appList = @($cachedRows | ForEach-Object {
                        $pkg   = $_.PackageName
                        $entry = if ($appNamesLookup.ContainsKey($pkg)) { $appNamesLookup[$pkg] } else { $null }
                        $dn    = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } else { $pkg }
                        $icon  = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } else { '' }
                        $tp    = if ($entry) { ConvertTo-ThirdPartyBool $entry } else { $true }
                        @{ package = $pkg; displayName = $dn; localIconPath = $icon; version = $_.Version; pendingVersion = if ($_.PSObject.Properties['PendingVersion']) { $_.PendingVersion } else { '' }; storeVersion = if ($_.PSObject.Properties['StoreVersion']) { $_.StoreVersion } else { '' }; sizeBytes = if ($_.PSObject.Properties['SizeBytes'] -and $_.SizeBytes -match '^\d+$') { [long]$_.SizeBytes } else { 0L }; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = $tp }
                    } | Where-Object { $includeSystem -or $_.thirdParty } | Sort-Object { $_.displayName })
                } else {
                    # Fallback: live ADB call (no cache yet)
                    $rows    = Get-KnownHeadsets
                    $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                    if (-not $headset) { throw "Headset not found" }
                    $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                    if (-not $device) { throw "Could not connect to headset via ADB" }
                    $installedApps = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly:(-not $includeSystem) -adb $adbPath
                    $appList = @($installedApps | ForEach-Object {
                        $pkg   = $_.PackageName
                        $entry = if ($appNamesLookup.ContainsKey($pkg)) { $appNamesLookup[$pkg] } else { $null }
                        $dn    = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } elseif ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                        $icon  = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } elseif ($_.LocalIconPath) { $_.LocalIconPath } else { '' }
                        @{ package = $pkg; displayName = $dn; localIconPath = $icon; version = $_.Version; pendingVersion = ''; storeVersion = ''; sizeBytes = 0L; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = [bool]$_.ThirdParty }
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

        # API: POST /api/update-app  body: {"name":"Q3_RED","package":"com.beatgames.beatsaber"}
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/update-app') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd()
                $reader.Close()
                $parsed   = $body | ConvertFrom-Json
                $safeName = [regex]::Match(($parsed.name -replace ' ','_'), '^[\w\-]+$').Value
                $safePkg  = [regex]::Match($parsed.package, '^[\w\.\-]+$').Value
                if (-not $safeName -or -not $safePkg) { throw "Invalid parameters" }

                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }
                $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
                if (-not $device) { throw "Could not connect to headset via ADB" }
                $ok = Start-HeadsetAppUpdate -Device $device -PackageName $safePkg -headsetName $headset.Name
                Send-JsonResponse -Response $response -Body @{ ok = $ok }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
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

        # API: POST /api/resolve-app-names
        # Starts a background job that fetches app metadata from MetaMetadata (GitHub).
        # Guard: returns {status:"already_running"} if a job is active.
        # Returns {status:"no_internet"} when github.com is unreachable.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/resolve-app-names') {
            try {
                # Guard: one job at a time
                if ($script:resolveJob -and $script:resolveJob.State -in @('Running', 'NotStarted')) {
                    Send-JsonResponse -Response $response -Body @{ status = 'already_running' }
                    continue
                }
                # Clean up finished job
                if ($script:resolveJob) {
                    try { Remove-Job -Job $script:resolveJob -Force -ErrorAction SilentlyContinue } catch {}
                    $script:resolveJob = $null
                }
                # Internet check
                if (-not (Test-InternetConnectivity)) {
                    Send-JsonResponse -Response $response -Body @{ status = 'no_internet' }
                    continue
                }
                # Start background job
                [System.IO.File]::WriteAllText($script:resolveProgFile, '{"status":"queued"}')
                $bodyRaw    = (New-Object System.IO.StreamReader($request.InputStream)).ReadToEnd()
                $bodyObj    = try { $bodyRaw | ConvertFrom-Json } catch { $null }
                $forceOnline = [bool]($bodyObj.forceOnline)
                $script:resolveJob = Start-Job -ScriptBlock $resolveJobBlock -ArgumentList $ScriptPath, $script:resolveProgFile, $ConfigFilePath, $forceOnline
                Send-JsonResponse -Response $response -Body @{ status = 'started' }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error'; error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/resolve-progress
        # Returns the current status of the background app name resolution job.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/resolve-progress') {
            try {
                if (-not $script:resolveJob -and -not (Test-Path -LiteralPath $script:resolveProgFile)) {
                    Send-JsonResponse -Response $response -Body @{ status = 'idle' }
                } else {
                    $raw = try { [System.IO.File]::ReadAllText($script:resolveProgFile) } catch { '{"status":"idle"}' }
                    # No active job — only trust terminal statuses; stale running/queued → idle
                    if (-not $script:resolveJob) {
                        $parsed = try { $raw | ConvertFrom-Json } catch { $null }
                        if (-not $parsed -or $parsed.status -in @('running', 'queued')) { $raw = '{"status":"idle"}' }
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error' }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/update-app-versions
        # Starts a background job that fetches LatestVersion from MetaMetadata for all packages in known_apps.csv.
        # Returns {status:"started"|"already_running"|"no_internet"|"error"}.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/update-app-versions') {
            try {
                if ($script:updateVersionsJob -and $script:updateVersionsJob.State -in @('Running', 'NotStarted')) {
                    Send-JsonResponse -Response $response -Body @{ status = 'already_running' }
                    continue
                }
                if ($script:updateVersionsJob) {
                    try { Remove-Job -Job $script:updateVersionsJob -Force -ErrorAction SilentlyContinue } catch {}
                    $script:updateVersionsJob = $null
                }
                if (-not (Test-InternetConnectivity)) {
                    Send-JsonResponse -Response $response -Body @{ status = 'no_internet' }
                    continue
                }
                $bodyRaw = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $bodyJson = $bodyRaw.ReadToEnd()
                try { $bodyObj = $bodyJson | ConvertFrom-Json } catch { $bodyObj = $null }
                $script:updateVersionsHeadsetName = if ($bodyObj -and $bodyObj.headsetName) { $bodyObj.headsetName } else { $null }
                [System.IO.File]::WriteAllText($script:updateVersionsProgFile, '{"status":"queued"}')
                $uvProgFile  = $script:updateVersionsProgFile
                $uvScriptPath = $ScriptPath
                $uvConfigPath = $ConfigFilePath
                $script:updateVersionsJob = Start-Job -ScriptBlock {
                    param($sp, $pf, $cf)
                    . (Join-Path $sp 'modules\scripts_init.ps1')
                    Update-AppCacheOnline -ProgressFile $pf
                } -ArgumentList $uvScriptPath, $uvProgFile, $uvConfigPath
                Send-JsonResponse -Response $response -Body @{ status = 'started' }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error'; error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/update-app-versions-progress
        # Returns current status of the background update-versions job from progress file.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/update-app-versions-progress') {
            try {
                if (-not $script:updateVersionsJob -and -not (Test-Path -LiteralPath $script:updateVersionsProgFile)) {
                    Send-JsonResponse -Response $response -Body @{ status = 'idle' }
                } else {
                    # Clean up finished job
                    if ($script:updateVersionsJob -and $script:updateVersionsJob.State -notin @('Running', 'NotStarted')) {
                        try { Remove-Job -Job $script:updateVersionsJob -Force -ErrorAction SilentlyContinue } catch {}
                        $script:updateVersionsJob = $null
                    }
                    $raw = try { [System.IO.File]::ReadAllText($script:updateVersionsProgFile) } catch { '{"status":"idle"}' }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
                    $response.StatusCode      = 200
                    $response.ContentType     = 'application/json; charset=utf-8'
                    $response.Headers.Add('Access-Control-Allow-Origin', '*')
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error' }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/refresh-headset-apps-cache
        # Calls Update-InstalledAppsCache for a given headset. Used after update-app-versions completes.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/refresh-headset-apps-cache') {
            try {
                $bodyRaw  = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $bodyJson = $bodyRaw.ReadToEnd()
                $bodyObj  = try { $bodyJson | ConvertFrom-Json } catch { $null }
                $hn = if ($bodyObj -and $bodyObj.headsetName) { [string]$bodyObj.headsetName } else { $null }
                if (-not $hn) {
                    Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'headsetName required' }
                    continue
                }
                $headset = Get-KnownHeadsets | Where-Object { $_.Name -eq $hn } | Select-Object -First 1
                if (-not $headset) {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'headset not found' }
                    continue
                }
                $device = try { Get-BestAdbDevice -headset $headset } catch { $null }
                if (-not $device) {
                    $device = try { Get-AdbWifiDevice -headsetIP $headset.IP } catch { $null }
                }
                if (-not $device) {
                    Send-JsonResponse -Response $response -StatusCode 503 -Body @{ ok = $false; error = 'device not reachable' }
                    continue
                }
                Update-InstalledAppsCache -Device $device -headsetName $hn
                Send-JsonResponse -Response $response -Body @{ ok = $true }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
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

        # API: GET /api/foregroundapp?name=Q3_BLUE  - returns the package + display name + icon of the running app
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/foregroundapp') {
            try {
                $rawQuery  = $request.Url.Query.TrimStart('?')
                $nameParam = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
                $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid headset name" }

                $rows    = Get-KnownHeadsets
                $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
                if (-not $headset) { throw "Headset not found" }

                $device  = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
                $pkg     = if ($device) { Get-HeadsetForegroundApp -Device $device -adb $adbPath } else { $null }

                $result  = @{ package = ''; displayName = ''; localIconPath = '' }
                if ($pkg) {
                    $result.package = $pkg
                    $appCsvPath = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else { [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv")) }
                    if (Test-Path -LiteralPath $appCsvPath) {
                        $entry = Import-Csv -LiteralPath $appCsvPath -Delimiter "," | Where-Object { $_.PackageName -eq $pkg } | Select-Object -First 1
                        if ($entry) {
                            if ($entry.DisplayName) { $result.displayName   = $entry.DisplayName }
                            if ($entry.LocalIconPath) { $result.localIconPath = $entry.LocalIconPath }
                        }
                    }
                    if (-not $result.displayName) { $result.displayName = $pkg }
                }
                $json      = $result | ConvertTo-Json -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"package":"","displayName":"","localIconPath":""}')
                    $response.StatusCode = 200; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
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
                        $result.error = 'No WiFi network configured. Add one in vrhm_config.'
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
                        $usbBrand  = (Get-HeadsetBrandModel -Device $usbDev -adb $adbPath).Brand
                        $result.ok = Connect-HeadsetToWifi -Device $usbDev -Ssid $wifiSsid -Password $wifiPwd -Brand $usbBrand
                        if (-not $result.ok) {
                            if ($usbBrand -eq 'Pico') {
                                $result.error = "WiFi picker opened on Pico headset - automated push is not supported (uid 2000 SecurityException). Complete the join on the headset for SSID '$wifiSsid'."
                            } else {
                                $result.error = 'WiFi connection failed.'
                            }
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
        # API: GET /api/wifi-detect  - returns the PC's currently connected WiFi SSID and password
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/wifi-detect') {
            try {
                $detectedSsid = Get-ComputerWifiSSID
                $detectedPwd  = if ($detectedSsid) { Get-ComputerWifiPassword -SSID $detectedSsid } else { $null }
                $payload = @{ ok = $true; ssid = $detectedSsid; password = $detectedPwd }
                Send-JsonResponse -Response $response -Body $payload
            } catch {
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500
            }
            continue
        }

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
                # Build response from last result written by the persistent USB probe job
                $details = try {
                    $raw = [System.IO.File]::ReadAllText($script:usbInfoResultFile)
                    if ($raw -and $raw -ne 'null') { $raw | ConvertFrom-Json } else { $null }
                } catch { $null }
                $result  = @{ found = $false; ip = ''; brand = ''; model = ''; serialNumber = ''; ssid = ''; expectedSsid = ''; ssidMatch = $false; wifiAdbOpen = $false; apkInstalled = $false; alreadyRegistered = $false }
                if ($details) {
                    $knownNetworks   = Get-WifiNetworks
                    $preferredWifi   = $knownNetworks | Where-Object { $_.Preferred } | Select-Object -First 1
                    if (-not $preferredWifi) { $preferredWifi = $knownNetworks | Select-Object -First 1 }
                    $expectedSsidVal = if ($preferredWifi) { $preferredWifi.SSID } else { '' }
                    $rows       = Get-KnownHeadsets
                    $alreadyReg = $false
                    if ($details.SerialNumber) { $alreadyReg = [bool]($rows | Where-Object { $_.SerialNumber -eq $details.SerialNumber }) }
                    if (-not $alreadyReg -and $details.IP) { $alreadyReg = [bool]($rows | Where-Object { $_.IPAddress -eq $details.IP }) }
                    $result = @{
                        found = $true; ip = $details.IP
                        brand = if ($details.PSObject.Properties['Brand']) { $details.Brand } else { '' }
                        model = $details.Model
                        serialNumber = $details.SerialNumber; ssid = $details.WiFiSSID
                        expectedSsid = $expectedSsidVal
                        ssidMatch = (Test-SsidMatch -Reported $details.WiFiSSID -Expected $expectedSsidVal)
                        wifiAdbOpen = $details.WifiAdbOpen
                        apkInstalled = $details.ApkInstalled; alreadyRegistered = $alreadyReg
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

        # API: POST /api/addheadset  body: {"name":"Q3 Blue","ip":"192.168.1.243","model":"Quest 3","serialNumber":"ABC123"}
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

                $safeModel  = if ($json.model)        { ([string]$json.model).Trim().Substring(0, [Math]::Min(([string]$json.model).Trim().Length, 60)) } else { '' }
                $safeSerial = if ($json.serialNumber) { ([string]$json.serialNumber).Trim().Substring(0, [Math]::Min(([string]$json.serialNumber).Trim().Length, 40)) } else { '' }
                Add-Headset -headsets $rows -IPAddress $safeIp -Name $safeName -Model $safeModel -SerialNumber $safeSerial

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

        # API: POST /api/app-shutdown
        # Injects '0' + Enter into the main process console input so Show-MainMenu triggers Invoke-AppShutdown.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/app-shutdown') {
            try {
                $mainProc = Get-WmiObject Win32_Process |
                    Where-Object { $_.CommandLine -match 'main\.ps1' } |
                    Select-Object -First 1
                if (-not $mainProc) { throw 'Main process not found' }
                $mainPid = [uint32]$mainProc.ProcessId
                [void][VrmConsoleInput]::InjectKey($mainPid, '0', 0x30)
                [void][VrmConsoleInput]::InjectKey($mainPid, [char]13, 0x0D)
                Send-JsonResponse -Response $response -Raw '{"ok":true}'
            } catch {
                try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/restartwebserver
        # Sends a success response then spawns a delayed process that kills and restarts this server.
        # Uses a temp script file in $env:TEMP (ASCII path) to avoid encoding issues with accented
        # characters in the project path when passing args through powershell -Command.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/restartwebserver') {
            try {
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $response.Close()

                $helperScript = Join-Path $env:TEMP "vrm_restart_ws_$PID.ps1"
                [System.IO.File]::WriteAllText($helperScript, @'
param([int]$SelfPid,[string]$Script,[string]$ScriptPath,[string]$Config,[string]$PidFile,[string]$LogFolder,[string]$LogFile)
Start-Sleep -Seconds 2
Stop-Process -Id $SelfPid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Start-Process powershell.exe -ArgumentList @('-File',$Script,'-ScriptPath',$ScriptPath,'-ConfigFilePath',$Config,'-PidFile',$PidFile,'-LogFolder',$LogFolder,'-LogFile',$LogFile) -WindowStyle Hidden
'@)
                Start-Process powershell.exe -ArgumentList @(
                    '-NoProfile', '-File', $helperScript,
                    '-SelfPid',   $PID,
                    '-Script',    $PSCommandPath,
                    '-ScriptPath',  $ScriptPath,
                    '-Config',      $ConfigFilePath,
                    '-PidFile',     $PidFile,
                    '-LogFolder',   $LogFolder,
                    '-LogFile',     $LogFile
                ) -WindowStyle Hidden
                continue
            } catch {
                try { $response.Close() } catch {}
            }
            continue
        }

        # API: GET /api/vqa/status - returns whether Video Quality Automation is enabled and the 3 per-section
        # auto-apply flags. The legacy enabled_vqo is included as a derived OR for any consumer that still reads it.
        # Always available so the web UI can decide whether to render the VQA section, even when VQA is disabled.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/vqa/status') {
            try {
                $derivedVqo = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
                Send-JsonResponse -Response $response -Body @{
                    enabled              = [bool]$global:VQA_Enabled
                    auto_apply_profiles  = [bool]$global:VQA_AutoApplyProfiles
                    auto_apply_headsets  = [bool]$global:VQA_AutoApplyHeadsets
                    auto_apply_mediamtx  = [bool]$global:VQA_AutoApplyMediaMtx
                    enabled_vqo          = [bool]$derivedVqo
                    cpu_max_threshold    = if ($global:VQA_Enabled) { [int]$global:VQA_CpuMaxThreshold }        else { $null }
                    gpu_max_threshold    = if ($global:VQA_Enabled) { [int]$global:VQA_GpuMaxThreshold }        else { $null }
                    cpu_mitigation       = if ($global:VQA_Enabled) { [int]$global:VQA_CpuMitigationThreshold } else { $null }
                    gpu_mitigation       = if ($global:VQA_Enabled) { [int]$global:VQA_GpuMitigationThreshold } else { $null }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/vqa/apply  - Applies the latest VQR recommendation. Body: { scope, target }.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/vqa/apply') {
            try {
                if (-not $global:VQA_Enabled) {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'VQA disabled' }
                } else {
                    $bodyText = (New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)).ReadToEnd()
                    $body  = if ($bodyText) { try { $bodyText | ConvertFrom-Json } catch { $null } } else { $null }
                    $scope = if ($body -and $body.scope)  { [string]$body.scope }  else { 'all' }
                    $target= if ($body -and $body.target) { [string]$body.target } else { '' }
                    $ok = Invoke-VqaApply -Scope $scope -Target $target
                    Send-JsonResponse -Response $response -Body @{ ok = [bool]$ok }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/vqa/restore  - Reverts to operator baseline, skipping fields edited manually since apply.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/vqa/restore') {
            try {
                if (-not $global:VQA_Enabled) {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'VQA disabled' }
                } else {
                    $ok = Reset-VqaToOriginals
                    Send-JsonResponse -Response $response -Body @{ ok = [bool]$ok }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/vqa/toggle-auto-apply
        # Body: { section: "profiles" | "headsets" | "mediamtx", enabled: bool }
        # Persists to config.json via Set-VqaAutoApply (which also arms the cooldown).
        # Returns the full 3-section state + derived_vqo so the UI can paint all buttons at once.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/vqa/toggle-auto-apply') {
            try {
                if (-not $global:VQA_Enabled) {
                    Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'VQA disabled' }
                } else {
                    $bodyText = (New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)).ReadToEnd()
                    $body = if ($bodyText) { try { $bodyText | ConvertFrom-Json } catch { $null } } else { $null }
                    $section = if ($body -and $body.section) { [string]$body.section } else { '' }
                    if ($section -notin @('profiles','headsets','mediamtx')) {
                        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = "section must be 'profiles', 'headsets' or 'mediamtx'" }
                    } else {
                        $current = switch ($section) {
                            'profiles' { $global:VQA_AutoApplyProfiles }
                            'headsets' { $global:VQA_AutoApplyHeadsets }
                            'mediamtx' { $global:VQA_AutoApplyMediaMtx }
                        }
                        $newVal = if ($body -and $null -ne $body.enabled) { [bool]$body.enabled } else { -not [bool]$current }
                        Set-VqaAutoApply -Section $section -Enabled $newVal | Out-Null
                        $derivedVqo = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
                        Send-JsonResponse -Response $response -Body @{
                            ok                  = $true
                            auto_apply_profiles = [bool]$global:VQA_AutoApplyProfiles
                            auto_apply_headsets = [bool]$global:VQA_AutoApplyHeadsets
                            auto_apply_mediamtx = [bool]$global:VQA_AutoApplyMediaMtx
                            derived_vqo         = [bool]$derivedVqo
                        }
                    }
                }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/vqa/toggle-vqo  - DEPRECATED. The single master VQO flag has been
        # replaced by 3 per-section flags. The header badge is now derived from those.
        # Returns 410 Gone with a hint so old clients fail loudly.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/vqa/toggle-vqo') {
            try {
                Send-JsonResponse -Response $response -StatusCode 410 -Body @{
                    ok    = $false
                    error = 'toggle-vqo is deprecated; use POST /api/vqa/toggle-auto-apply with { section, enabled }'
                }
            } catch { } finally { $response.Close() }
            continue
        }

        # API: POST /api/computer-monitoring/force-refresh
        # Creates a flag file read by the VRMonitor loop (separate process) to trigger an immediate refresh.
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/computer-monitoring/force-refresh') {
            try {
                $flagFile = Join-Path -Path $global:ScriptPath -ChildPath "data\computer_monitoring_forcerefresh.flag"
                [System.IO.File]::WriteAllText($flagFile, '')
                Send-JsonResponse -Response $response -Body @{ ok = $true }
            } catch {
                Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
            } finally { $response.Close() }
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
                # HttpWebRequest with hard timeouts so a stalled mediamtx cannot
                # freeze the single-threaded request loop for the OS default ~100s.
                $req = [System.Net.HttpWebRequest]::Create($mtxUrl)
                $req.Method            = 'GET'
                $req.Accept            = 'application/json'
                $req.Timeout           = 1500
                $req.ReadWriteTimeout  = 1500
                $resp   = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $body   = $reader.ReadToEnd()
                $reader.Close(); $stream.Close(); $resp.Close()
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

        # API: GET /api/version  - returns the application version string from version.txt
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/version') {
            try {
                $versionFile = Join-Path $global:ScriptPath 'version.txt'
                $versionStr  = if (Test-Path -LiteralPath $versionFile) {
                    (Get-Content -LiteralPath $versionFile -Raw).Trim()
                } else { 'unknown' }
                Send-JsonResponse -Response $response -Body @{ version = $versionStr }
            } catch {
                try { Send-JsonResponse -Response $response -Body @{ version = 'unknown' } } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/appinfo  - returns port info and useful URLs for the topbar Help section
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/appinfo') {
            try {
                # Cache for 10s - Get-Process is slow under high CPU load and this
                # endpoint is polled by the topbar from every open page.
                if (-not $script:appInfoCache -or
                    ((Get-Date) - $script:appInfoCacheAt).TotalSeconds -gt 10) {
                    $script:appInfoCache = @{
                        webServerPort      = $port
                        mediamtxHlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort }    else { 8888 }
                        mediamtxRtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort }   else { 8554 }
                        mediamtxWebrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
                        mediamtxApiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort }    else { 9997 }
                        webServerPid       = $PID
                        mediamtxPid        = (Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id)
                    }
                    $script:appInfoCacheAt = Get-Date
                }
                $info      = $script:appInfoCache
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
                # HttpWebRequest with hard timeouts so a stalled mediamtx cannot
                # freeze the single-threaded request loop for the OS default ~100s.
                $req = [System.Net.HttpWebRequest]::Create($mtxUrl)
                $req.Method            = 'GET'
                $req.Accept            = 'application/json'
                $req.Timeout           = 1500
                $req.ReadWriteTimeout  = 1500
                $resp   = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $body   = $reader.ReadToEnd()
                $reader.Close(); $stream.Close(); $resp.Close()
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

        # API: GET /api/version  - returns the application version string from version.txt
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/version') {
            try {
                $versionFile = Join-Path $global:ScriptPath 'version.txt'
                $versionStr  = if (Test-Path -LiteralPath $versionFile) {
                    (Get-Content -LiteralPath $versionFile -Raw).Trim()
                } else { 'unknown' }
                Send-JsonResponse -Response $response -Body @{ version = $versionStr }
            } catch {
                try { Send-JsonResponse -Response $response -Body @{ version = 'unknown' } } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: GET /api/appinfo  - returns port info and useful URLs for the topbar Help section
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/appinfo') {
            try {
                # Cache for 10s - Get-Process is slow under high CPU load and this
                # endpoint is polled by the topbar from every open page.
                if (-not $script:appInfoCache -or
                    ((Get-Date) - $script:appInfoCacheAt).TotalSeconds -gt 10) {
                    $script:appInfoCache = @{
                        webServerPort      = $port
                        mediamtxHlsPort    = if ($global:mediamtxHlsPort)    { $global:mediamtxHlsPort }    else { 8888 }
                        mediamtxRtspPort   = if ($global:mediamtxRtspPort)   { $global:mediamtxRtspPort }   else { 8554 }
                        mediamtxWebrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
                        mediamtxApiPort    = if ($global:mediamtxApiPort)    { $global:mediamtxApiPort }    else { 9997 }
                        webServerPid       = $PID
                        mediamtxPid        = (Get-Process -Name "mediamtx" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id)
                    }
                    $script:appInfoCacheAt = Get-Date
                }
                $info      = $script:appInfoCache
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
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv"))
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
                                ThirdParty    = ConvertTo-ThirdPartyBool $_
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
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv"))
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
                    ThirdParty    = [bool]$json.ThirdParty
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
                    [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv"))
                }

                if (Test-Path -LiteralPath $appCsvPath) {
                    $rows = @(Import-Csv -LiteralPath $appCsvPath -Delimiter ",") |
                            Where-Object { $_.PackageName -ne $pkg }
                    if ($rows.Count -gt 0) {
                        $rows | Export-Csv -LiteralPath $appCsvPath -NoTypeInformation -Encoding UTF8 -Force
                    } else {
                        '"PackageName","DisplayName","IconUrl","LocalIconPath","Type"' |
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
                $ok = Clear-AppNamesCache
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($ok) { '{"ok":true}' } else { '{"ok":false,"error":"Clear failed - check server logs"}' }))
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

        # API: GET /api/defaultfavorites  - returns ordered rows from the default favorites template
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/defaultfavorites') {
            try {
                $templatePath = Join-Path $ScriptPath "templates\data\default_favorite_apps.csv"
                $appCsvPath   = if ($global:AppCacheFilePath) { $global:AppCacheFilePath } else { [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "data\known_apps.csv")) }
                $appNames     = @{}
                if (Test-Path -LiteralPath $appCsvPath) {
                    Import-Csv -LiteralPath $appCsvPath -Delimiter "," | ForEach-Object { if ($_.PackageName) { $appNames[$_.PackageName] = $_ } }
                }
                $result = @()
                if (Test-Path -LiteralPath $templatePath) {
                    Import-Csv -LiteralPath $templatePath -Delimiter "," | ForEach-Object {
                        if ($_.PackageName) {
                            $entry  = $appNames[$_.PackageName]
                            $result += @{
                                package       = $_.PackageName
                                displayName   = if ($entry -and $entry.DisplayName) { $entry.DisplayName } else { $_.DisplayName }
                                localIconPath = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } else { '' }
                            }
                        }
                    }
                }
                $json      = ConvertTo-Json @($result) -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('[]')
                    $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
                    $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
                } catch {}
            } finally { $response.Close() }
            continue
        }

        # API: POST /api/defaultfavorites/toggle  - add or remove a package from the default favorites template
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/defaultfavorites/toggle') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd(); $reader.Close()
                $json    = $body | ConvertFrom-Json
                $safePkg = [regex]::Match($json.package, '^[\w\.\-]+$').Value
                if (-not $safePkg) { throw "Invalid package" }
                $templatePath = Join-Path $ScriptPath "templates\data\default_favorite_apps.csv"
                $rows = @()
                if (Test-Path -LiteralPath $templatePath) {
                    $rows = @(Import-Csv -LiteralPath $templatePath -Delimiter ",")
                }
                $addFav = [string]$json.favorite -eq 'True' -or [string]$json.favorite -eq 'true'
                if ($addFav) {
                    if (-not ($rows | Where-Object { $_.PackageName -eq $safePkg })) {
                        $rows += [PSCustomObject]@{ PackageName = $safePkg; DisplayName = [string]$json.displayName }
                    }
                } else {
                    $rows = @($rows | Where-Object { $_.PackageName -ne $safePkg })
                }
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                $sb = [System.Text.StringBuilder]::new()
                $null = $sb.AppendLine('"PackageName","DisplayName"')
                foreach ($r in $rows) { $null = $sb.AppendLine('"' + ($r.PackageName -replace '"','""') + '","' + ($r.DisplayName -replace '"','""') + '"') }
                [System.IO.File]::WriteAllText($templatePath, $sb.ToString().TrimEnd(), $utf8NoBom)
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

        # API: POST /api/defaultfavorites/reorder  - reorder rows in the default favorites template
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/defaultfavorites/reorder') {
            try {
                $reader  = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body    = $reader.ReadToEnd(); $reader.Close()
                $json    = $body | ConvertFrom-Json
                $templatePath = Join-Path $ScriptPath "templates\data\default_favorite_apps.csv"
                $rowMap = @{}
                if (Test-Path -LiteralPath $templatePath) {
                    Import-Csv -LiteralPath $templatePath -Delimiter "," | ForEach-Object { if ($_.PackageName) { $rowMap[$_.PackageName] = $_ } }
                }
                $ordered = @()
                foreach ($pkg in $json.packages) {
                    $safePkg = [regex]::Match($pkg, '^[\w\.\-]+$').Value
                    if ($safePkg -and $rowMap.ContainsKey($safePkg)) { $ordered += $rowMap[$safePkg] }
                }
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                $sb = [System.Text.StringBuilder]::new()
                $null = $sb.AppendLine('"PackageName","DisplayName"')
                foreach ($r in $ordered) { $null = $sb.AppendLine('"' + ($r.PackageName -replace '"','""') + '","' + ($r.DisplayName -replace '"','""') + '"') }
                [System.IO.File]::WriteAllText($templatePath, $sb.ToString().TrimEnd(), $utf8NoBom)
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

        # API: POST /api/favorites/reorder  - reorder per-headset favorites
        if ($request.HttpMethod -eq 'POST' -and $request.Url.LocalPath -eq '/api/favorites/reorder') {
            try {
                $reader   = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $body     = $reader.ReadToEnd(); $reader.Close()
                $json     = $body | ConvertFrom-Json
                $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
                if (-not $safeName) { throw "Invalid name" }
                $favMap = @{}
                @(Get-FavoriteApps -headsetName $safeName) | ForEach-Object { if ($_.PackageName) { $favMap[$_.PackageName] = $_ } }
                $ordered = @()
                foreach ($pkg in $json.packages) {
                    $safePkg = [regex]::Match($pkg, '^[\w\.\-]+$').Value
                    if ($safePkg -and $favMap.ContainsKey($safePkg)) { $ordered += $favMap[$safePkg] }
                }
                Save-FavoriteApps -favorites $ordered -headsetName $safeName
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

        # API: GET /api/config/defaults  - returns templates/config/config.json content as JSON
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/config/defaults') {
            try {
                $tplFile = Join-Path $ScriptPath "templates\config\config.json"
                if (Test-Path -LiteralPath $tplFile) {
                    $raw = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8
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

        # API: GET /api/server-info  - returns server local IPs so the client can detect local access
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/server-info') {
            try {
                $ips = @('127.0.0.1', 'localhost') + @($lanIPs | Where-Object { $_ })
                $ipJson = ($ips | ForEach-Object { '"' + $_ + '"' }) -join ','
                $rb = [System.Text.Encoding]::UTF8.GetBytes("{`"localIPs`":[$ipJson]}")
                $response.StatusCode = 200
                $response.ContentType = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $rb.Length
                $response.OutputStream.Write($rb, 0, $rb.Length)
            } catch {
                try {
                    $eb = [System.Text.Encoding]::UTF8.GetBytes('{"localIPs":["127.0.0.1","localhost"]}')
                    $response.StatusCode = 200; $response.ContentType = 'application/json; charset=utf-8'
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
                $newCfg = $body | ConvertFrom-Json
                $cfgFile = Join-Path $ScriptPath "config\config.json"

                # Snapshot the three live-applicable mediamtx streaming fields
                # against the in-memory globals BEFORE writing. If any change,
                # we mirror the VQA restart sequence (running scrcpy + mediamtx)
                # so the new framerate / bitrate / re-encode flag take effect
                # without an app restart.
                $oldFps      = $global:mediamtxFramerate
                $oldBw       = $global:mediamtxBitrate
                $oldReencode = [bool]$global:mediamtxReencode
                $oldCodec    = if ($global:mediamtxCodec) { $global:mediamtxCodec } else { 'h264' }
                $newFps      = $null; $newBw = $null; $newReencode = $false; $newCodec = 'h264'
                if ($newCfg -and $newCfg.mediamtx) {
                    $newFps      = $newCfg.mediamtx.stream_framerate
                    $newBw       = $newCfg.mediamtx.stream_bitrate
                    $newReencode = [bool]$newCfg.mediamtx.reencode_in_ffmpeg
                    $newCodec    = if ($newCfg.mediamtx.codec) { $newCfg.mediamtx.codec } else { 'h264' }
                }
                $streamingChanged = ($newFps -ne $oldFps) -or ($newBw -ne $oldBw) -or ($newReencode -ne $oldReencode) -or ($newCodec -ne $oldCodec)

                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($cfgFile, $body, $utf8NoBom)

                $restarted = @{ mediamtx = $false; scrcpy = @(); pending = $false }
                if ($streamingChanged) {
                    $lock = Enter-VqaLock -TimeoutMs 3000
                    if (-not $lock) {
                        # VQA is busy applying a change. Skipping in-band restart
                        # keeps us from racing on mediamtx / scrcpy lifecycles.
                        $restarted.pending = $true
                        Write-Log "config/save: mediamtx streaming fields changed but VQA lock contended - restart deferred to operator." -Level WARNING
                    } else {
                        try {
                            $null = Get-Config -ConfigFilePath $cfgFile
                            # Order matters: restart mediamtx FIRST, then scrcpy.
                            # If we restart scrcpy first, the freshly-spawned ffmpeg
                            # pusher connects to the *old* mediamtx, then Stop-MediaMtx
                            # kills it underneath, the RTSP push dies with a broken
                            # pipe, and nothing respawns ffmpeg (Watch-ScrcpyProcesses
                            # only watches scrcpy itself). Bouncing mediamtx first
                            # ensures every new ffmpeg push connects to a healthy
                            # server it will keep talking to.
                            try {
                                Stop-MediaMtx
                                Start-Sleep -Seconds 1
                                Start-MediaMtx
                                # Brief settle so mediamtx is accepting RTSP before
                                # ffmpeg pushers try to connect.
                                Start-Sleep -Milliseconds 800
                                $restarted.mediamtx = $true
                            } catch {
                                Write-Log ("config/save: mediamtx restart failed: " + $_.Exception.Message) -Level WARNING
                            }
                            # Restart any scrcpy session that is currently running so
                            # Start-FfmpegStreamPush re-reads the new globals and
                            # connects to the freshly-restarted mediamtx.
                            $runningNames = @()
                            foreach ($row in (Get-KnownHeadsets)) {
                                $safe = Convert-Displayname $row.Name
                                if (Get-ScrcpyProcess -displayName $safe -headsetIP $row.IPAddress) {
                                    try {
                                        Stop-Scrcpy -HeadsetName $row.Name -HeadsetIP $row.IPAddress | Out-Null
                                        Start-Sleep -Milliseconds 500
                                        start-screenCopy -headsetIP $row.IPAddress -displayName $row.Name -scrcpyProfile $row.ScrcpyProfile
                                        $runningNames += $row.Name
                                    } catch {
                                        Write-Log ("config/save: scrcpy restart failed for " + $row.Name + ": " + $_.Exception.Message) -Level WARNING
                                    }
                                }
                            }
                            $restarted.scrcpy = $runningNames
                        } finally {
                            Exit-VqaLock -Stream $lock
                        }
                    }
                }

                $respObj = @{ ok = $true; restarted = $restarted }
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Compress -Depth 4))
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
                if (-not $resolvedFile.StartsWith($resolvedBase) -or ($allowedExt -ne '.csv' -and $allowedExt -ne '.json')) {
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
                # Transparent fallback: if not found at website root, try website/generated/
                if (-not [System.IO.File]::Exists($resolvedFile)) {
                    $generatedBase = [System.IO.Path]::GetFullPath((Join-Path $websitePath "generated"))
                    $fallback      = [System.IO.Path]::GetFullPath((Join-Path $generatedBase $urlPath))
                    if ($fallback.StartsWith($generatedBase) -and [System.IO.File]::Exists($fallback)) {
                        $resolvedFile = $fallback
                    }
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
    if ($script:usbInfoJob) {
        Stop-Job  $script:usbInfoJob -ErrorAction SilentlyContinue
        Remove-Job $script:usbInfoJob -Force -ErrorAction SilentlyContinue
    }
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) {
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log $msg.WebServerStopped -Level INFO
}
