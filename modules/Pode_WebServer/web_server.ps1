# VR Headset Manager - Static Web Server
# Serves all files under the /website folder over HTTP using System.Net.HttpListener.
# Does NOT require admin - relies on the URL ACL registered once by computer_setup.ps1:
#   netsh http add urlacl url=http://+:<port>/ user=Everyone
# Launched as a standalone PowerShell process (started by Start-WebServer, scripts_init.ps1).
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
    // Writes every character of "text" (each as a down+up pair) plus an optional
    // trailing Enter, as ONE WriteConsoleInput call within a SINGLE
    // AttachConsole/FreeConsole cycle. Doing this in one shot (instead of one
    // InjectKey call per character) avoids the race between repeated
    // attach/detach cycles that can drop or reorder keystrokes when several
    // characters must land together as one line (e.g. "00" + Enter).
    public static bool InjectKeys(uint pid, string text, bool withEnter) {
        FreeConsole();
        if (!AttachConsole(pid)) return false;
        IntPtr hIn = GetStdHandle(-10);
        int charCount = text.Length + (withEnter ? 1 : 0);
        var records = new INPUT_RECORD[charCount * 2];
        int idx = 0;
        for (int i = 0; i < text.Length; i++) {
            char ch = text[i];
            short vk = (short)VkKeyScan(ch);
            records[idx].EventType = 1;
            records[idx].KeyEvent.bKeyDown = 1;
            records[idx].KeyEvent.wRepeatCount = 1;
            records[idx].KeyEvent.wVirtualKeyCode = vk;
            records[idx].KeyEvent.UnicodeChar = ch;
            records[idx + 1] = records[idx];
            records[idx + 1].KeyEvent.bKeyDown = 0;
            idx += 2;
        }
        if (withEnter) {
            records[idx].EventType = 1;
            records[idx].KeyEvent.bKeyDown = 1;
            records[idx].KeyEvent.wRepeatCount = 1;
            records[idx].KeyEvent.wVirtualKeyCode = 0x0D;
            records[idx].KeyEvent.UnicodeChar = (char)13;
            records[idx + 1] = records[idx];
            records[idx + 1].KeyEvent.bKeyDown = 0;
        }
        uint written;
        bool ok = WriteConsoleInput(hIn, records, (uint)records.Length, out written);
        FreeConsole();
        return ok;
    }
    [DllImport("user32.dll")] public static extern short VkKeyScan(char ch);
}
'@

# Read port, enabled flag, and ADB settings from config.json
$port       = 8080
$enabled    = $true
$adbPath    = $null
# Classic WiFi ADB port (ADB.adbPort_default). This literal is ONLY the last-resort value for a
# config.json that cannot be read below: this file runs before Get-Config (and Get-ClassicAdbPort)
# is available, and the read right below replaces it in every normal start.
$adbPort    = 5555
$apkPath    = $null
$apkPackage = 'tdg.oculuswirelessadb'
try {
    $cfg = Get-Content -LiteralPath $ConfigFilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
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
    '.zip'  = 'application/zip'
    # The toolbox downloads: an exe, the Linux kiosk script, the basic Windows
    # kiosk script and its readme are all served straight off website\, so they
    # need a type here or they fall back to application/octet-stream.
    '.exe'  = 'application/octet-stream'
    '.ps1'  = 'text/plain; charset=utf-8'
    '.sh'   = 'text/plain; charset=utf-8'
    '.md'   = 'text/plain; charset=utf-8'
    '.apk'  = 'application/vnd.android.package-archive'
    '.mkv'  = 'video/x-matroska'
    '.mp4'  = 'video/mp4'
}

# The route surface (Invoke-HttpRoute, the response helpers, the lane tables). Dot-sourced here
# AND by the slow-lane worker runspace (ADR-0019): the same code runs on either lane.
$webRoutes = Join-Path $ScriptPath 'modules\Pode_WebServer\web_routes.ps1'
if (Test-Path -LiteralPath $webRoutes) {
    . $webRoutes
} else {
    Write-Host "[WebServer] ERROR: web_routes.ps1 not found at: $webRoutes" -ForegroundColor Red
    exit 1
}









# Show LAN URLs. Reuses Get-PrivateNetworks (network_scanner.ps1, already dot-sourced via
# scripts_init.ps1 above) so this startup log stays consistent with the console menu and
# Wait-ForValidNetwork - excludes APIPA, virtual/hypervisor adapters, and (critically) any
# adapter whose link is actually down, so a disconnected NIC's leftover static IP is never
# logged as a reachable URL.
$lanNetworks = @(Get-PrivateNetworks)

Write-Log ($msg.WebServerStartingOnPort -f $port) -Level INFO
Write-Log ($msg.WebServerServingFrom -f $websitePath) -Level DEBUG
if ($lanNetworks.Count -gt 0) {
    if ($global:MdnsResponder_enabled -and $global:MdnsResponder_hostname) {
        Write-Log ("  http://" + $global:MdnsResponder_hostname + ".local:" + $port + "/ [mDNS]") -Level INFO
    }
    foreach ($net in $lanNetworks) {
        $label = if ($net.IsWifi) { "[WiFi]" } else { "[LAN]" }
        Write-Log ($msg.WebServerLinkLine -f $net.IPAddress, $port, $label) -Level INFO
    }
} else {
    Write-Log $msg.WebServerNoLanAddress -Level WARNING
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
    # Only release the lock if it is OURS. A losing racer must never delete the
    # winner's pid file - that used to leave the running server unclaimed and made
    # the watchdog spawn yet another competitor.
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) {
        $ownedRaw = Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($ownedRaw -and $ownedRaw.Trim() -eq "$PID") {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        }
    }
    exit 1
}

# Claim the lock file only once the port is actually bound, so data\webserver.pid
# never points at a process that failed to become the web server.
if ($PidFile) {
    $PID | Set-Content -LiteralPath $PidFile -Force -Encoding ASCII -ErrorAction SilentlyContinue
}

Write-Log ($msg.WebServerListening -f $port) -Level SUCCESS

# Tracks active install background jobs by jobId
$script:installJobs = @{}

# mtime-based cache for known_headsets.csv (mirrors $script:headsetInfosCache pattern)
$script:knownHeadsetsCache      = $null
$script:knownHeadsetsCacheMtime = $null

# Live-status cache, keyed by headset ID. Invalidated by the headset_status
# change counter rather than a file mtime (the name of the second variable is
# kept so the two stay obviously paired).
$script:headsetInfosCache      = $null
$script:headsetInfosCacheMtime = $null





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
        # ConvertTo-Json escapes quotes, backslashes (Windows paths) and newlines; the
        # interpolated string used to break on any of them, so the progress file went bad.
        $json = ConvertTo-Json -InputObject ([ordered]@{ step = $step; pct = $pct; file = $file; error = $err; adbPid = $pid2;
                obbMB = $obbMB; totalSec = $totalSec; obbSec = $obbSec; bwMBs = $bwMBs }) -Compress
        try { [System.IO.File]::WriteAllText($progressFile, $json) } catch {}
    }

    function Run-AdbExe {
        # $TimeoutSec bounds the wait. An unbounded WaitForExit() here meant a wedged
        # "adb install" or "shell mkdir" hung the whole install job with nothing able
        # to recover it - the operator saw a progress bar frozen at a step forever and
        # the only way out was /api/install-cancel. 15 minutes is generous enough for a
        # large install over WiFi ADB while still being finite.
        param([string]$args2, [int]$TimeoutSec = 900)
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
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch {}
            return @{ ExitCode = -2; Output = "adb timed out after $TimeoutSec s"; Ok = $false }
        }
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
        Set-InstProg 'error' 0 '' ([string]$_.Exception.Message)
    }
}

# Background job for async online app name resolution (Update-AppCacheOnline).
# Runs in a NEW PowerShell process; dot-sources scripts_init to access module functions.
$resolveJobBlock = {
    param([string]$ScriptPath, [string]$ProgressFile, [string]$ConfigFilePath, [bool]$ForceOnline = $false)
    function Set-ResolveProg {
        param([string]$status)
        try { [System.IO.File]::WriteAllText($ProgressFile, (ConvertTo-Json -InputObject ([ordered]@{ status = $status }) -Compress)) } catch {}
    }
    Set-ResolveProg 'running'
    try {
        $global:ScriptPath         = $ScriptPath
        $global:ConfigFilePath     = $ConfigFilePath
        $global:IsWebServerProcess = $true
        . (Join-Path $ScriptPath 'modules\scripts_init.ps1')
        # No cache path to pass any more: the catalogue is a table. Dot-sourcing
        # scripts_init above with IsWebServerProcess set gives this process its own
        # Worker database connection, so the batch write at the end of the resolve
        # lands through the same retry path as every other writer.
        Update-AppCacheOnline -ProgressFile $ProgressFile -ForceOnline:$ForceOnline
        Set-ResolveProg 'done'
    } catch {
        $err = [string]$_
        try { [System.IO.File]::WriteAllText($ProgressFile, (ConvertTo-Json -InputObject ([ordered]@{ status = 'error'; error = $err }) -Compress)) } catch {}
    }
}

# Background job for the "update versions" action (Update-AppCacheOnline).
# Same preamble as $resolveJobBlock: the role globals MUST be set before dot-sourcing
# scripts_init.ps1, otherwise the job runs the MAIN startup path (Main DB role, relay
# file deletion, VQA recovery, Start-WebServer...).
$updateVersionsJobBlock = {
    param([string]$ScriptPath, [string]$ProgressFile, [string]$ConfigFilePath)
    try {
        $global:ScriptPath         = $ScriptPath
        $global:ConfigFilePath     = $ConfigFilePath
        $global:IsWebServerProcess = $true
        . (Join-Path $ScriptPath 'modules\scripts_init.ps1')
        Update-AppCacheOnline -ProgressFile $ProgressFile
    } catch {
        $err = [string]$_
        try { [System.IO.File]::WriteAllText($ProgressFile, (ConvertTo-Json -InputObject ([ordered]@{ status = 'error'; error = $err }) -Compress)) } catch {}
    }
}

# Active resolve job guard (only one at a time)
$script:resolveJob      = $null
$script:resolveProgFile = Get-JobFilePath -Name 'vrm_resolve.json'
# Reset stale progress file from a previous session (running/queued with no active job)
if (Test-Path -LiteralPath $script:resolveProgFile) {
    try {
        $stale = [System.IO.File]::ReadAllText($script:resolveProgFile) | ConvertFrom-Json
        if ($stale.status -in @('running', 'queued')) {
            [System.IO.File]::WriteAllText($script:resolveProgFile, '{"status":"idle"}')
        }
    } catch { Remove-Item -LiteralPath $script:resolveProgFile -Force -ErrorAction SilentlyContinue }
}

# Background job for the stream benchmark (Invoke-StreamBenchmark, stream_benchmark.ps1).
# A NEW PowerShell process, so it owns the test streams it starts; it writes its own
# progress JSON (Get-StreamBenchmarkProgressPath). The planned tests travel as one JSON string.
$benchmarkJobBlock = {
    param([string]$ScriptPath, [string]$ConfigFilePath, [int]$HeadsetId, [string]$TestsJson, [int]$MeasureSec)
    # Same file as Get-StreamBenchmarkProgressPath (utils.ps1 is not loaded yet at this point).
    $progFile = [System.IO.Path]::Combine($ScriptPath, 'data\jobs\vrm_benchmark.json')
    try {
        $global:ScriptPath         = $ScriptPath
        $global:ConfigFilePath     = $ConfigFilePath
        $global:IsWebServerProcess = $true
        . (Join-Path $ScriptPath 'modules\scripts_init.ps1')
        $benchHeadset = Get-HeadsetDiagTarget -Id $HeadsetId
        if (-not $benchHeadset) { throw ("Unknown headset id {0}" -f $HeadsetId) }
        # Assign BEFORE wrapping: in PS 5.1 ConvertFrom-Json emits a JSON array as ONE Object[], so
        # @($TestsJson | ConvertFrom-Json) is a one-element array holding the whole list.
        $benchTests = $TestsJson | ConvertFrom-Json
        Invoke-StreamBenchmark -Headset $benchHeadset -Tests @($benchTests) -MeasureSec $MeasureSec `
            -ProgressFile (Get-StreamBenchmarkProgressPath) | Out-Null
    } catch {
        $err = [string]$_
        try { [System.IO.File]::WriteAllText($progFile, (ConvertTo-Json -InputObject ([ordered]@{ status = 'error'; error = $err }) -Compress)) } catch {}
    }
}
# Parallel check (Invoke-StreamBenchmarkParallel): the same settings streamed on several headsets at
# once. Same process model and progress file as the benchmark; ids travel as a comma string.
$benchmarkParallelJobBlock = {
    param([string]$ScriptPath, [string]$ConfigFilePath, [string]$IdsCsv, [string]$SettingsJson, [int]$MeasureSec)
    # Same file as Get-StreamBenchmarkProgressPath (utils.ps1 is not loaded yet at this point).
    $progFile = [System.IO.Path]::Combine($ScriptPath, 'data\jobs\vrm_benchmark.json')
    try {
        $global:ScriptPath         = $ScriptPath
        $global:ConfigFilePath     = $ConfigFilePath
        $global:IsWebServerProcess = $true
        . (Join-Path $ScriptPath 'modules\scripts_init.ps1')
        $benchRows = @()
        foreach ($idText in ($IdsCsv -split ',')) {
            if ([string]::IsNullOrWhiteSpace($idText)) { continue }
            $row = Get-HeadsetDiagTarget -Id ([int]$idText)
            if (-not $row) { throw ("Unknown headset id {0}" -f $idText) }
            $benchRows += $row
        }
        # Assign BEFORE any wrapping (PS 5.1 ConvertFrom-Json trap, see $benchmarkJobBlock).
        $benchSet = $SettingsJson | ConvertFrom-Json
        Invoke-StreamBenchmarkParallel -Headsets @($benchRows) -Settings $benchSet -MeasureSec $MeasureSec `
            -ProgressFile (Get-StreamBenchmarkProgressPath) | Out-Null
    } catch {
        $err = [string]$_
        try { [System.IO.File]::WriteAllText($progFile, (ConvertTo-Json -InputObject ([ordered]@{ status = 'error'; error = $err }) -Compress)) } catch {}
    }
}
$script:benchmarkJob = $null
# A progress file left "running" by a previous web server session is stale unless a
# benchmark still holds the pause flag (a console run, for instance).
$script:benchmarkProgFile = Get-JobFilePath -Name 'vrm_benchmark.json'

# Active update-versions job guard (only one at a time)
$script:updateVersionsJob          = $null
$script:updateVersionsProgFile     = Get-JobFilePath -Name 'vrm_update_versions.json'
$script:updateVersionsHeadsetName  = $null

# USB detection is NOT probed here any more.
#
# There used to be a persistent Start-Job at this point - a separate
# powershell.exe that dot-sourced the entire module set and re-ran the full USB
# detail probe every 3 seconds, forever, writing the result to a temp file. It
# cost a measured 137 MB of RAM plus a continuous stream of adb.exe launches
# that duplicated, and raced with, the VRMonitor's own USB probe against the
# same single adb server - all to answer "is a new headset plugged in?" for one
# blinking button on headsets_settings.html.
#
# VRMonitor is now the single USB owner and publishes its snapshot to the
# app_kv row 'usb_device' whenever it changes (ADR-0017). /api/usbdeviceinfo
# reads that row.
$script:usbInfoJob = $null



# ---------------------------------------------------------------------------
# SSE push channel (ADR-0020)
#
# Pages used to learn about a change only on their next poll (refresh_timer x load
# multiplier: 5 s, up to 25 s), which made the BROWSER the slowest hop: the database
# was always fresher than any page showing it.
#
# This pump holds the /api/events connections open and writes one frame whenever a
# database change counter moves. The frame is an INVALIDATION NUDGE, not data: the
# page reacts by running the fetch it already had, so no render path changes and the
# pump's cost is one indexed read per tick however many clients are attached.
#
# Only the push channel of the reverted commit 7e52019 is restored here - not its
# request-lane refactor. Two guards against what made that commit unusable:
#   - a browser allows only ~6 open connections per server address, shared by every
#     tab, iframe and OBS source. live_events.js therefore opens ONE stream per
#     browser (shared across tabs) and never from an iframe; overlays keep polling.
#   - a client that is gone is detected by the next write (frame or heartbeat) and
#     dropped, and the client count is capped by WebServer.sse.max_clients.
#
# It is a runspace, not a Start-Job: a job is a separate process and an
# HttpListenerContext cannot be serialized. It loads only the four modules it needs
# and opens its own database connection (ADR-0017).
# ---------------------------------------------------------------------------

$script:SseQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:SseState = [hashtable]::Synchronized(@{ Stop = $false; Count = 0 })
$script:SsePump  = $null

$ssePumpBlock = {
    param($sp, $cp, $logFolder, $logFile, $queue, $state, $pollMs, $heartbeatSec)

    $global:ScriptPath         = $sp
    $global:ConfigFilePath     = $cp
    $global:IsWebServerProcess = $true
    if ($logFolder) { $global:logFolder = $logFolder }
    if ($logFile)   { $global:logFile   = $logFile }

    try {
        . (Join-Path $sp 'modules\logging.ps1')
        . (Join-Path $sp 'modules\utils.ps1')
        . (Join-Path $sp 'modules\config_files_loader.ps1')
        . (Join-Path $sp 'modules\database.ps1')
        Get-Config -ConfigFilePath $cp | Out-Null
        # Translations in EVERY runspace that calls module functions: without $global:msg
        # Write-Log throws on an empty string and would kill the pump on its first log line.
        $langFile = Join-Path $sp ('modules\translations\' + $global:SelectedLanguage + '.psd1')
        if (-not (Test-Path -LiteralPath $langFile)) { $langFile = Join-Path $sp 'modules\translations\en-US.psd1' }
        $global:msg = Import-PowerShellDataFile -LiteralPath $langFile
        Initialize-Database -Role Worker | Out-Null
    } catch {
        $state['Error'] = $_.Exception.Message
        $state['Stop']  = $true
        return
    }

    $utf8     = New-Object System.Text.UTF8Encoding($false)
    $clients  = New-Object System.Collections.ArrayList
    $lastMap  = @{}
    $lastBeat = [datetime]::UtcNow

    function Write-SseFrame {
        param($Client, [string]$Text)
        # $false when the socket is gone, so the caller can drop the client.
        try {
            $bytes = $utf8.GetBytes($Text)
            $Client.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $Client.Response.OutputStream.Flush()
            return $true
        } catch {
            return $false
        }
    }

    try {
        while (-not $state['Stop']) {
            # 1. Adopt newly handed-off connections. Held aside for this tick so they get
            #    exactly one baseline frame and not also the change broadcast.
            $fresh = New-Object System.Collections.ArrayList
            while ($queue.Count -gt 0) {
                $ctx = $null
                try { $ctx = $queue.Dequeue() } catch { $ctx = $null }
                if ($null -ne $ctx) { $null = $fresh.Add($ctx) }
            }

            # 2. Every counter in one round trip.
            $map       = Get-DbTableVersionMap
            $frameText = $null
            $changed   = $false
            if ($map.Count -gt 0) {
                $pairs     = foreach ($k in ($map.Keys | Sort-Object)) { '"' + $k + '":' + $map[$k] }
                $frameText = 'data: {"v":{' + ($pairs -join ',') + '}}' + "`n`n"
                foreach ($k in $map.Keys) {
                    if (-not $lastMap.ContainsKey($k) -or $lastMap[$k] -ne $map[$k]) { $changed = $true; break }
                }
                $lastMap = $map
            }

            # 3. Baseline for brand-new connections, so a (re)connecting page resyncs at
            #    once instead of waiting for some counter to move.
            foreach ($c in $fresh) {
                if ($frameText) {
                    if (Write-SseFrame -Client $c -Text $frameText) { $null = $clients.Add($c) }
                    else { try { $c.Response.Close() } catch { } }
                } else {
                    # Database not readable this tick: send a comment so the client knows
                    # the stream is open; the next good tick sends a real frame.
                    if (Write-SseFrame -Client $c -Text ": open`n`n") { $null = $clients.Add($c) }
                    else { try { $c.Response.Close() } catch { } }
                }
            }

            # 4. Heartbeat: keeps proxies from closing an idle stream, and its write is
            #    what detects a client that has gone away.
            $beat = $null
            if (([datetime]::UtcNow - $lastBeat).TotalSeconds -ge $heartbeatSec) {
                $lastBeat = [datetime]::UtcNow
                $beat = ": ping`n`n"
            }
            $frame = if ($changed) { $frameText } else { $null }

            if (($frame -or $beat) -and $clients.Count -gt 0) {
                $dead = New-Object System.Collections.ArrayList
                foreach ($c in $clients) {
                    $ok = $true
                    # A client adopted this tick already received this exact state as its baseline.
                    if ($frame -and -not $fresh.Contains($c)) { $ok = Write-SseFrame -Client $c -Text $frame }
                    if ($ok -and $beat) { $ok = Write-SseFrame -Client $c -Text $beat }
                    if (-not $ok) { $null = $dead.Add($c) }
                }
                foreach ($d in $dead) {
                    $clients.Remove($d)
                    try { $d.Response.Close() } catch { }
                }
            }

            $state['Count'] = $clients.Count
            Start-Sleep -Milliseconds $pollMs
        }
    } finally {
        foreach ($c in $clients) { try { $c.Response.Close() } catch { } }
        $state['Count'] = 0
        if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
            try { Close-DbConnection } catch { }
        }
    }
}

function Start-SsePumpRunspace {
    # Creates the SSE pump runspace. Returns @{PS;Runspace;Handle} or $null.
    # $null is a soft failure: /api/events then answers 404 and every page keeps the
    # polling cadence it already had.
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($ssePumpBlock)
        [void]$ps.AddArgument($ScriptPath)
        [void]$ps.AddArgument($ConfigFilePath)
        [void]$ps.AddArgument($global:logFolder)
        [void]$ps.AddArgument($global:logFile)
        [void]$ps.AddArgument($script:SseQueue)
        [void]$ps.AddArgument($script:SseState)
        [void]$ps.AddArgument([int]$global:WebServer_sse_poll_ms)
        [void]$ps.AddArgument([int]$global:WebServer_sse_heartbeat_sec)
        $handle = $ps.BeginInvoke()
        return @{ PS = $ps; Runspace = $rs; Handle = $handle }
    } catch {
        Write-Log ("Web server: SSE pump failed to start: " + $_.Exception.Message) -Level ERROR
        return $null
    }
}

function Stop-SsePumpRunspace {
    # Signals the pump to exit; its own finally closes every held connection, so
    # browsers see a clean disconnect (and fall back to polling) rather than a hang.
    if (-not $script:SsePump) { return }
    try { $script:SseState['Stop'] = $true } catch { }
    try {
        $deadline = (Get-Date).AddSeconds(5)
        while (-not $script:SsePump.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    } catch { }
    while ($script:SseQueue.Count -gt 0) {
        try { $script:SseQueue.Dequeue().Response.Close() } catch { }
    }
    try { $script:SsePump.PS.Stop()          } catch { }
    try { $script:SsePump.PS.Dispose()       } catch { }
    try { $script:SsePump.Runspace.Close()   } catch { }
    try { $script:SsePump.Runspace.Dispose() } catch { }
    $script:SsePump = $null
}

if ($global:WebServer_sse_enabled) {
    $script:SsePump = Start-SsePumpRunspace
    if ($script:SsePump) {
        Write-Log ("Web server: SSE pump started (poll {0} ms, max {1} clients)" -f $global:WebServer_sse_poll_ms, $global:WebServer_sse_max_clients) -Level INFO
    } else {
        Write-Log "Web server: SSE pump unavailable - browsers will fall back to polling" -Level WARNING
    }
} else {
    Write-Log "Web server: SSE disabled by config - browsers will poll" -Level INFO
}

# Recording downloads in flight (ADR-0029): @{Task;Stream;Response;File}. The copy runs
# asynchronously so a multi-GB file never holds the accept loop; finished entries are closed here.
$script:RecordingDownloads = New-Object System.Collections.ArrayList

function Complete-PendingRecordingDownloads {
    param([switch]$All)
    for ($i = $script:RecordingDownloads.Count - 1; $i -ge 0; $i--) {
        $d = $script:RecordingDownloads[$i]
        if (-not $All -and -not $d.Task.IsCompleted) { continue }
        try { $d.Stream.Dispose() } catch { }
        if ($d.Task.IsCompleted -and -not $d.Task.IsFaulted) {
            try { $d.Response.Close() } catch { }
        } else {
            # client went away, or shutting down mid-transfer
            try { $d.Response.Abort() } catch { }
        }
        $script:RecordingDownloads.RemoveAt($i)
    }
}

# Housekeeping (S6-5): nothing a request leaves behind may accumulate. Install jobs are
# released (Receive-Job + Remove-Job) as soon as they finish, their progress file is kept
# $script:InstallFileKeepSec so the client can read the final status, and files older than a
# day are swept. Idle playback sessions and finished downloads are reaped here too, instead of
# waiting for the next /api/recordings request. Throttled by a Stopwatch; runs at the top of
# a loop iteration, so it needs one request per interval (any polling page provides it).
$script:InstallFileKeepSec     = 60
$script:InstallFileMaxAgeSec   = 86400
$script:HousekeepingIntervalMs = 10000
$script:HousekeepingWatch      = [System.Diagnostics.Stopwatch]::StartNew()
$script:installJobFinished     = @{}   # jobId -> DateTime the finished job was released

function Remove-FinishedWebJob {
    # Receives (discards) the output of a finished job and removes it. $true when removed.
    param($Job)
    if (-not $Job) { return $false }
    if ($Job.State -in @('Running', 'NotStarted')) { return $false }
    try { Receive-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
    return $true
}

function Invoke-WebHousekeeping {
    if ($script:HousekeepingWatch.ElapsedMilliseconds -lt $script:HousekeepingIntervalMs) { return }
    $script:HousekeepingWatch.Restart()
    $now = Get-Date
    try {
        # 1. install jobs: release finished ones, then their progress file after the keep window
        foreach ($id in @($script:installJobs.Keys)) {
            if (Remove-FinishedWebJob -Job $script:installJobs[$id]) {
                $script:installJobs.Remove($id)
                $script:installJobFinished[$id] = $now
            }
        }
        foreach ($id in @($script:installJobFinished.Keys)) {
            if (($now - $script:installJobFinished[$id]).TotalSeconds -ge $script:InstallFileKeepSec) {
                $f = Get-JobFilePath -Name "vrm_install_$id.json"
                try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
                $script:installJobFinished.Remove($id)
            }
        }
        # orphan progress files (previous run, cancelled job) older than a day
        foreach ($f in @(Get-ChildItem -LiteralPath (Split-Path -Parent (Get-JobFilePath -Name 'x')) -Filter 'vrm_install_*.json' -File -ErrorAction SilentlyContinue)) {
            if (($now - $f.LastWriteTime).TotalSeconds -ge $script:InstallFileMaxAgeSec) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        # 2. single-slot jobs: progress is file based, so a finished job holds nothing useful
        if (Remove-FinishedWebJob -Job $script:resolveJob)        { $script:resolveJob = $null }
        if (Remove-FinishedWebJob -Job $script:updateVersionsJob) { $script:updateVersionsJob = $null }
        if (Remove-FinishedWebJob -Job $script:benchmarkJob)      { $script:benchmarkJob = $null }
        # 3. recording playback sessions and finished downloads
        try { Remove-IdleRecordingPlayback | Out-Null } catch { }
        if ($script:RecordingDownloads.Count -gt 0) { Complete-PendingRecordingDownloads }
    } catch {
        Write-Log ("Web server: housekeeping failed: " + $_.Exception.Message) -Level DEBUG
    }
}

# ---------------------------------------------------------------------------
# Slow-lane worker (ADR-0019, ADR-0033)
#
# ONE runspace inside this process runs every route in $script:SlowRoutes so a download, a
# subnet scan or a folder dialog can no longer stall the accept loop. One thread on purpose:
# slow work here is mostly ADB, and two concurrent ADB sessions on one transport contend for
# nothing. It mirrors Start-HeadsetRunspace (ADR-0001): the queue and state are injected by
# reference, only the HttpListenerContext crosses the boundary, and the worker opens its own
# database connection (ADR-0017) because it dot-sources scripts_init.ps1 itself.
#
# What makes it safe to rely on (the reverted version had none of this):
#   - $state.Ready is set only after the modules and web_routes.ps1 loaded. Until then, and
#     whenever the worker is dead, slow routes run INLINE on the accept loop - exactly the
#     behaviour before lanes - instead of piling up in a queue nobody drains.
#   - A worker that died is noticed through its Handle, its queue is run inline, and it is
#     restarted (bounded: see Restore-SlowLaneWorker).
#   - Config changes made by either lane are picked up by the other (Sync-WebRouteConfig).
#   - 'priority' routes (shutdown, kill, app stop) never enter this queue.
# ---------------------------------------------------------------------------
$script:SlowQueue        = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:SlowState        = [hashtable]::Synchronized(@{ Stop = $false; Ready = $false; Error = ''; ConfigGeneration = 0; ConfigWriter = '' })
$script:SlowMaxQueue     = 64
$script:SlowWorker       = $null
$script:SlowRestarts     = 0
$script:SlowMaxRestarts  = 3
$script:SlowRestartAfter = [datetime]::MinValue

$slowWorkerBlock = {
    param($sp, $cp, $queue, $state, $ctx)

    # What Write-Log and the modules read as globals (same as the web server process sets).
    $global:ScriptPath         = $sp
    $global:ConfigFilePath     = $cp
    $global:IsWebServerProcess = $true
    if ($ctx.LogFolder) { $global:logFolder = $ctx.LogFolder }
    if ($ctx.LogFile)   { $global:logFile   = $ctx.LogFile }

    # What the route handlers read from their caller's scope (list in Invoke-HttpRoute). $port
    # is not set here: its only reader, /api/appinfo, is a fast route and never runs in the worker.
    $ScriptPath     = $sp
    $ConfigFilePath = $cp
    $PidFile        = $ctx.PidFile
    $adbPath        = $ctx.AdbPath
    $adbPort        = $ctx.AdbPort
    $apkPath        = $ctx.ApkPath
    $apkPackage     = $ctx.ApkPackage
    $websitePath    = $ctx.WebsitePath
    $mimeTypes      = $ctx.MimeTypes
    $lanNetworks    = $ctx.LanNetworks

    try {
        . (Join-Path $sp 'modules\scripts_init.ps1')
        . (Join-Path $sp 'modules\Pode_WebServer\web_routes.ps1')
        $state['Ready'] = $true
    } catch {
        $state['Error'] = [string]$_.Exception.Message
        return
    }

    try {
        while (-not $state['Stop']) {
            $item = $null
            if ($queue.Count -gt 0) {
                try { $item = $queue.Dequeue() } catch { $item = $null }
            }
            if ($null -eq $item) {
                Start-Sleep -Milliseconds 20
                continue
            }
            $itemPath = ''
            try { $itemPath = [string]$item.Request.Url.LocalPath } catch { }
            Sync-WebRouteConfig -State $state -Lane 'worker'
            Invoke-HttpRouteGuarded -Context $item
            Set-WebRouteConfigWritten -State $state -Lane 'worker' -Path $itemPath
        }
    } finally {
        if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
            try { Close-DbConnection } catch { }
        }
    }
}

function Start-SlowLaneWorker {
    # Creates the slow-lane runspace. Returns @{PS;Runspace;Handle} or $null (the accept loop
    # then runs slow routes inline: degraded, not broken).
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()

        $ctx = @{
            LogFolder   = $global:logFolder
            LogFile     = $global:logFile
            PidFile     = $PidFile
            AdbPath     = $adbPath
            AdbPort     = $adbPort
            ApkPath     = $apkPath
            ApkPackage  = $apkPackage
            WebsitePath = $websitePath
            MimeTypes   = $mimeTypes
            LanNetworks = $lanNetworks
        }

        $script:SlowState['Ready'] = $false
        $script:SlowState['Error'] = ''
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($slowWorkerBlock)
        [void]$ps.AddArgument($ScriptPath)
        [void]$ps.AddArgument($ConfigFilePath)
        [void]$ps.AddArgument($script:SlowQueue)
        [void]$ps.AddArgument($script:SlowState)
        [void]$ps.AddArgument($ctx)
        $handle = $ps.BeginInvoke()
        return @{ PS = $ps; Runspace = $rs; Handle = $handle }
    } catch {
        Write-Log ("Web server: slow lane worker failed to start: " + $_.Exception.Message) -Level ERROR
        return $null
    }
}

function Remove-SlowLaneWorker {
    # Disposes the worker object. Does not touch the queue.
    if (-not $script:SlowWorker) { return }
    try { $script:SlowWorker.PS.Stop() }          catch { }
    try { $script:SlowWorker.PS.Dispose() }       catch { }
    try { $script:SlowWorker.Runspace.Close() }   catch { }
    try { $script:SlowWorker.Runspace.Dispose() } catch { }
    $script:SlowWorker = $null
}

function Stop-SlowLaneWorker {
    # Signals the worker to leave its loop, drains anything still queued with a 503 so no
    # client is left on a socket that will never be answered, then disposes it.
    if ($script:SlowWorker) {
        try { $script:SlowState['Stop'] = $true } catch { }
        try {
            $deadline = (Get-Date).AddSeconds(5)
            while (-not $script:SlowWorker.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
        } catch { }
    }
    while ($script:SlowQueue.Count -gt 0) {
        try {
            $pending = $script:SlowQueue.Dequeue()
            $pending.Response.StatusCode = 503
            $pending.Response.Close()
        } catch { }
    }
    Remove-SlowLaneWorker
}

function Test-SlowLaneUsable {
    # $true when a slow route may be queued. Cheap (a few property reads): called per slow
    # request on the accept loop. Notices a dead worker, runs what it left queued inline and
    # restarts it with a cooldown (3 restarts, 15 s apart) - after that the lane stays inline.
    if ($script:SlowWorker -and $script:SlowWorker.Handle.IsCompleted) {
        $why = [string]$script:SlowState['Error']
        if (-not $why) { $why = 'the worker runspace ended' }
        Write-Log ("Web server: slow lane worker stopped ($why) - slow routes run inline until it is restarted") -Level ERROR
        Remove-SlowLaneWorker
        $script:SlowState['Ready'] = $false
        $script:SlowRestartAfter = (Get-Date).AddSeconds(15)
        # Nobody is left to drain the queue: serve those requests here rather than hang them.
        while ($script:SlowQueue.Count -gt 0) {
            $stranded = $null
            try { $stranded = $script:SlowQueue.Dequeue() } catch { }
            if ($stranded) { Invoke-HttpRouteGuarded -Context $stranded }
        }
    }
    if (-not $script:SlowWorker) {
        if ($script:SlowRestarts -lt $script:SlowMaxRestarts -and (Get-Date) -ge $script:SlowRestartAfter -and -not $script:SlowState['Stop']) {
            $script:SlowRestarts++
            $script:SlowRestartAfter = (Get-Date).AddSeconds(15)
            $script:SlowWorker = Start-SlowLaneWorker
            if ($script:SlowWorker) {
                Write-Log ("Web server: slow lane worker restarted ({0}/{1})" -f $script:SlowRestarts, $script:SlowMaxRestarts) -Level WARNING
            }
        }
        return $false
    }
    return [bool]$script:SlowState['Ready']
}

$script:SlowWorker = Start-SlowLaneWorker
if ($script:SlowWorker) {
    Write-Log "Web server: slow lane worker started" -Level INFO
} else {
    Write-Log "Web server: slow lane worker unavailable - slow routes run inline" -Level WARNING
}

try {
    while ($listener.IsListening) {
        # GetContext() blocks until a request arrives. Guarded (S1-1): it throws when the
        # listener is stopped (leave the loop) and, rarely, on a transient socket error
        # (log it and keep listening).
        $context  = $null
        $request  = $null
        $response = $null
        try {
            $context = $listener.GetContext()
        } catch {
            if (-not $listener.IsListening) { break }
            Write-Log ("Web server: GetContext failed: " + $_.Exception.Message) -Level WARNING
            continue
        }

        # ---- per-request guard (S1-1) - closes at the end of the static-file fallback ----
        # One failed request must never stop the listener. Handlers leave their branch
        # with `continue`, which still targets this while loop from inside the try (and
        # is never intercepted by the catch below - verified on PS 5.1). The body below
        # keeps its original indentation on purpose, so this guard stays a small diff.
        try {
        $request  = $context.Request
        $response = $context.Response
        if ($script:RecordingDownloads.Count -gt 0) { Complete-PendingRecordingDownloads }
        Invoke-WebHousekeeping

        # API: GET /api/events - Server-Sent Events (ADR-0020). The ONLY route that does
        # not close its response: the context is handed to the pump runspace, which owns
        # it from then on. Holding the stream on this loop would freeze every other page.
        if ($request.HttpMethod -eq 'GET' -and $request.Url.LocalPath -eq '/api/events') {
            $pumpAlive = $script:SsePump -and -not $script:SsePump.Handle.IsCompleted -and -not $script:SseState['Stop']
            if (-not $pumpAlive) {
                # 404, not 500: the signal live_events.js uses to stop retrying and keep
                # the page on its polling cadence.
                try { $response.StatusCode = 404; $response.Close() } catch { }
                continue
            }
            # Capacity is checked BEFORE the headers are set, so a refusal is a plain 503
            # rather than a half-opened event stream.
            if ([int]$script:SseState['Count'] + $script:SseQueue.Count -ge [int]$global:WebServer_sse_max_clients) {
                try { $response.StatusCode = 503; $response.Close() } catch { }
                continue
            }
            try {
                $response.StatusCode  = 200
                $response.ContentType = 'text/event-stream; charset=utf-8'
                $response.Headers.Add('Cache-Control', 'no-cache')
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                # No ContentLength64: the body is an open-ended stream.
                $response.SendChunked = $true
                $response.KeepAlive   = $true
                # Enqueue LAST: the pump writes as soon as it dequeues, so the headers
                # must already be in place.
                $script:SseQueue.Enqueue($context)
            } catch {
                try { $response.Close() } catch { }
            }
            continue
        }

        # ---- route dispatch: lanes (ADR-0019) ----
        # fast / priority : run here, inline. A priority route (shutdown, kill, app stop) is
        #                   never queued, so it cannot wait behind a download or a scan.
        # slow            : queued for the worker runspace; this loop is back in GetContext()
        #                   within microseconds. While no worker is usable (starting, dead)
        #                   it runs here too - the behaviour before lanes, not a hang.
        $reqPath = [string]$request.Url.LocalPath
        Sync-WebRouteConfig -State $script:SlowState -Lane 'loop'

        $lane = 'fast'
        try { $lane = Get-WebRouteLane -Method $request.HttpMethod -Path $reqPath } catch { }

        if ($lane -eq 'slow' -and (Test-SlowLaneUsable)) {
            if ($script:SlowQueue.Count -ge $script:SlowMaxQueue) {
                # Backpressure: an explicit 503 beats an unbounded queue of sockets the
                # clients gave up on long ago.
                Send-JsonResponse -Response $response -StatusCode 503 -Body @{ ok = $false; error = 'server busy' }
                Close-HttpResponse -Response $response
            } else {
                $script:SlowQueue.Enqueue($context)
            }
            continue
        }

        Invoke-HttpRouteGuarded -Context $context
        Set-WebRouteConfigWritten -State $script:SlowState -Lane 'loop' -Path $reqPath
        } catch {
            # ---- end of the per-request guard (S1-1) ----
            # A client abort (64/995/1229) is routine - OBS reload, tab closed mid-transfer.
            $reqMethod = if ($request) { $request.HttpMethod } else { '?' }
            $reqPath   = if ($request) { $request.Url.LocalPath } else { '?' }
            $reqLine   = "Web server: request failed ($reqMethod $reqPath): " + $_.Exception.Message
            if (Test-HttpClientAbort -Exception $_.Exception) {
                Write-Log $reqLine -Level DEBUG
            } else {
                Write-Log $reqLine -Level WARNING
            }
            # Abort, not Close: the response state is unknown at this point.
            if ($response) { try { $response.Abort() } catch {} }
        }
    }
} finally {
    # Before the listener goes: the pump's finally closes every held event stream, and the
    # slow lane answers whatever is still queued with a 503.
    Stop-SsePumpRunspace
    Stop-SlowLaneWorker
    try { Stop-RecordingPlayback -All | Out-Null } catch {}
    try { Complete-PendingRecordingDownloads -All } catch {}
    $listener.Stop()
    $listener.Close()
    # $script:usbInfoJob is retained as $null so this teardown stays harmless if
    # anything else ever sets it; the USB probe job itself is gone (see the note
    # where it used to be created).
    if ($script:usbInfoJob) {
        Stop-Job  $script:usbInfoJob -ErrorAction SilentlyContinue
        Remove-Job $script:usbInfoJob -Force -ErrorAction SilentlyContinue
    }
    # Release this process's database connection. Not checkpointed: the main
    # process owns that on its way out, and a worker doing it too would just
    # contend with the writers still running.
    if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
        try { Close-DbConnection } catch { }
    }
    # Release the lock only if it still points at us (see the bind-failure branch).
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) {
        $ownedRaw = Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($ownedRaw -and $ownedRaw.Trim() -eq "$PID") {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log ($msg.WebServerStopped -f $PID) -Level INFO
}
