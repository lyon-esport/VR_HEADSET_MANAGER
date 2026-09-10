
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

# Shared route surface. Dot-sourced here for the fast lane and, independently, inside the
# slow-lane worker runspace below. Also sets $port / $enabled / $adbPath / $adbPort /
# $apkPath / $apkPackage / $mimeTypes from config.json, so it must load before they are used.
$webRoutes = Join-Path $ScriptPath "modules\Pode_WebServer\web_routes.ps1"
if (-not (Test-Path -LiteralPath $webRoutes)) {
    Write-Host "[ERROR] web_routes.ps1 not found at $webRoutes" -ForegroundColor Red
    exit 1
}
. $webRoutes
if (-not $enabled) {
    Write-Log $msg.WebServerDisabled -Level WARNING
    exit 0
}

if (-not (Test-Path -LiteralPath $websitePath)) {
    Write-Log ($msg.WebServerWebsiteFolderNotFound -f $websitePath) -Level ERROR
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
    $PID | Set-Content -LiteralPath $PidFile -Force -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-Log ($msg.WebServerListening -f $port) -Level SUCCESS
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

# ---------------------------------------------------------------------------
# Slow-lane worker runspace (ADR-0019)
#
# The accept loop must return to GetContext() in microseconds, or one slow request
# freezes every open page - and the overlays poll at 1 Hz, so "every open page" is
# a lot of clients. Routes that touch ADB, the LAN, the internet, a child process or
# a human are handed to this worker instead of being run inline.
#
# ONE worker, not a pool: each module-loaded runspace costs roughly 150 MB in
# PowerShell 5.1, and slow operations here are mostly ADB, which contends on a single
# transport anyway. Serialising them is the correct behaviour, not a compromise.
#
# The context object crosses the boundary; the code does not. The worker dot-sources
# web_routes.ps1 itself and opens its own database connection (ADR-0017).
# ---------------------------------------------------------------------------

$script:SlowQueue    = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:SlowState    = [hashtable]::Synchronized(@{ Stop = $false; ConfigGeneration = 0 })
$script:SlowMaxQueue = 64
$script:SlowWorker   = $null

$slowWorkerBlock = {
    param($sp, $cp, $queue, $state)

    $global:ScriptPath         = $sp
    $global:ConfigFilePath     = $cp
    $global:IsWebServerProcess = $true
    $ScriptPath                = $sp
    $ConfigFilePath            = $cp

    try {
        . (Join-Path $sp 'modules\scripts_init.ps1')
        . (Join-Path $sp 'modules\Pode_WebServer\web_routes.ps1')
    } catch {
        return
    }

    try {
        while (-not $state['Stop']) {
            $ctx = $null
            if ($queue.Count -gt 0) {
                try { $ctx = $queue.Dequeue() } catch { $ctx = $null }
            }
            if ($null -eq $ctx) {
                Start-Sleep -Milliseconds 20
                continue
            }

            $path = ''
            try { $path = [string]$ctx.Request.Url.LocalPath } catch { }

            try {
                Invoke-HttpRoute -Context $ctx
            } catch {
                try { Write-Log ("Web slow lane: " + $path + " failed: " + $_.Exception.Message) -Level WARNING } catch { }
                try {
                    $ctx.Response.StatusCode = 500
                    $ctx.Response.Close()
                } catch { }
            }

            # These two rewrite config.json and re-run Get-Config - but only against THIS
            # runspace's globals. Bump the generation so the accept loop refreshes its own,
            # otherwise it keeps serving the previous values with no visible error.
            if ($path -eq '/api/config/save' -or $path -eq '/api/config/reset') {
                try { $state['ConfigGeneration'] = [int]$state['ConfigGeneration'] + 1 } catch { }
            }
        }
    } finally {
        if (Get-Command Close-DbConnection -ErrorAction SilentlyContinue) {
            try { Close-DbConnection } catch { }
        }
    }
}

function Start-SlowLaneWorker {
    # Creates the slow-lane runspace. Returns @{PS;Runspace;Handle} or $null.
    # Mirrors Start-HeadsetRunspace (ADR-0001): shared objects injected by reference
    # through InitialSessionState, never serialised.
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($slowWorkerBlock)
        [void]$ps.AddArgument($ScriptPath)
        [void]$ps.AddArgument($ConfigFilePath)
        [void]$ps.AddArgument($script:SlowQueue)
        [void]$ps.AddArgument($script:SlowState)
        $handle = $ps.BeginInvoke()

        return @{ PS = $ps; Runspace = $rs; Handle = $handle }
    } catch {
        Write-Log ("Web slow lane: worker failed to start: " + $_.Exception.Message) -Level ERROR
        return $null
    }
}

function Stop-SlowLaneWorker {
    # Signals the worker to exit, drains anything still queued with a 503 so no client
    # is left hanging on a socket that will never be answered, then disposes.
    if (-not $script:SlowWorker) { return }
    try { $script:SlowState['Stop'] = $true } catch { }
    try {
        $deadline = (Get-Date).AddSeconds(5)
        while (-not $script:SlowWorker.Handle.IsCompleted -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    } catch { }
    while ($script:SlowQueue.Count -gt 0) {
        try {
            $pending = $script:SlowQueue.Dequeue()
            $pending.Response.StatusCode = 503
            $pending.Response.Close()
        } catch { }
    }
    try { $script:SlowWorker.PS.Stop()      } catch { }
    try { $script:SlowWorker.PS.Dispose()   } catch { }
    try { $script:SlowWorker.Runspace.Close()   } catch { }
    try { $script:SlowWorker.Runspace.Dispose() } catch { }
    $script:SlowWorker = $null
}

$script:SlowWorker = Start-SlowLaneWorker
if ($script:SlowWorker) {
    Write-Log "Web server: slow-lane worker started" -Level INFO
} else {
    Write-Log "Web server: slow-lane worker unavailable - slow routes will run inline" -Level WARNING
}

# ---------------------------------------------------------------------------
# SSE push channel (ADR-0019 / ADR-0020)
#
# Browsers used to poll /api/headsets-status on a timer indexed to
# VRMonitor.refresh_timer, which made the BROWSER the slowest hop in the chain:
# the database was consistently fresher than any page showing it. Every overlay
# also polled at 1 Hz, so the request rate scaled with headsets x open pages.
#
# This pump holds the /api/events connections open and writes one frame whenever a
# database change counter moves. It sends an INVALIDATION NUDGE, not data: the page
# reacts by running the fetch it already had, hitting the same counter-keyed caches.
# That keeps every rendering path unchanged and keeps the pump's cost at one
# indexed read per tick no matter how many clients are attached.
#
# It is a runspace, not a Start-Job: a job is a separate process and an
# HttpListenerContext is not serializable. It also loads only logging / utils /
# config_files_loader / database rather than the whole module set, because all it
# ever calls is Get-DbTableVersionMap. It opens its own connection (ADR-0017).
# ---------------------------------------------------------------------------

$script:SseQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$script:SseState = [hashtable]::Synchronized(@{ Stop = $false; Count = 0 })
$script:SsePump  = $null

$ssePumpBlock = {
    param($sp, $cp, $queue, $state, $pollMs, $heartbeatSec)

    $global:ScriptPath         = $sp
    $global:ConfigFilePath     = $cp
    $global:IsWebServerProcess = $true
    $ScriptPath                = $sp
    $ConfigFilePath            = $cp

    try {
        . (Join-Path $sp 'modules\logging.ps1')
        . (Join-Path $sp 'modules\utils.ps1')
        . (Join-Path $sp 'modules\config_files_loader.ps1')
        . (Join-Path $sp 'modules\database.ps1')
        Get-Config -ConfigFilePath $ConfigFilePath | Out-Null
        # Translations must be loaded in EVERY runspace that calls module functions:
        # without $global:msg every $msg.Key is $null and Write-Log throws on the
        # empty string, which would kill this pump on its first log line.
        $langFile = Join-Path $sp ('modules\translations\' + $global:SelectedLanguage + '.psd1')
        if (-not (Test-Path -LiteralPath $langFile)) { $langFile = Join-Path $sp 'modules\translations\en-US.psd1' }
        $global:msg = Import-PowerShellDataFile -LiteralPath $langFile
        Initialize-Database -Role Worker | Out-Null
    } catch {
        return
    }

    $utf8      = New-Object System.Text.UTF8Encoding($false)
    $clients   = New-Object System.Collections.ArrayList
    $lastMap   = @{}
    $lastBeat  = [datetime]::UtcNow

    function Write-SseFrame {
        param($Client, [string]$Text)
        # Returns $false when the socket is gone, so the caller can drop the client.
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

            # 1. Adopt newly handed-off connections. They are held aside for this tick so
            #    they get exactly one baseline frame (below) and are not also included in
            #    the change broadcast, which would send the same frame twice.
            $fresh = New-Object System.Collections.ArrayList
            while ($queue.Count -gt 0) {
                $ctx = $null
                try { $ctx = $queue.Dequeue() } catch { $ctx = $null }
                if ($null -eq $ctx) { continue }
                $null = $fresh.Add($ctx)
            }

            # 2. Read every counter in one round trip.
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

            # 3. Baseline for brand-new connections. Without this a client would see
            #    nothing until some counter happened to move, which makes reconnect
            #    resync non-deterministic - exactly when a client most needs to catch up.
            if ($fresh.Count -gt 0) {
                foreach ($c in $fresh) {
                    if ($frameText) {
                        if (Write-SseFrame -Client $c -Text $frameText) { $null = $clients.Add($c) }
                        else { try { $c.Response.Close() } catch { } }
                    } else {
                        $null = $clients.Add($c)
                    }
                }
            }

            # 4. Heartbeat. A comment line keeps proxies from closing an idle stream,
            #    and its write is what detects a client that has gone away.
            $beat = $null
            if (([datetime]::UtcNow - $lastBeat).TotalSeconds -ge $heartbeatSec) {
                $lastBeat = [datetime]::UtcNow
                $beat = ": ping`n`n"
            }

            $frame = $null
            if ($changed) { $frame = $frameText }

            if (($frame -or $beat) -and $clients.Count -gt 0) {
                $dead = New-Object System.Collections.ArrayList
                foreach ($c in $clients) {
                    $ok = $true
                    if ($frame) { $ok = Write-SseFrame -Client $c -Text $frame }
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

function Add-SseClient {
    # Hands one already-headered /api/events context to the pump. Returns $false when
    # the client cap is reached, so the accept loop can answer 503 instead of letting
    # an unbounded number of sockets be held open.
    param($Context)
    $max = if ($global:WebServer_sse_max_clients) { [int]$global:WebServer_sse_max_clients } else { 32 }
    if ([int]$script:SseState['Count'] + $script:SseQueue.Count -ge $max) { return $false }
    $script:SseQueue.Enqueue($Context)
    return $true
}

function Start-SsePumpRunspace {
    # Creates the SSE pump runspace. Returns @{PS;Runspace;Handle} or $null.
    # $null is a soft failure: /api/events then answers 404 and every page keeps
    # using the polling cadence it already had.
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
        [void]$ps.AddArgument($script:SseQueue)
        [void]$ps.AddArgument($script:SseState)
        [void]$ps.AddArgument($(if ($global:WebServer_sse_poll_ms) { [int]$global:WebServer_sse_poll_ms } else { 250 }))
        [void]$ps.AddArgument($(if ($global:WebServer_sse_heartbeat_sec) { [int]$global:WebServer_sse_heartbeat_sec } else { 15 }))
        $handle = $ps.BeginInvoke()

        return @{ PS = $ps; Runspace = $rs; Handle = $handle }
    } catch {
        Write-Log ("Web server: SSE pump failed to start: " + $_.Exception.Message) -Level ERROR
        return $null
    }
}

function Stop-SsePumpRunspace {
    # Signals the pump to exit; its own finally closes every held connection, so
    # browsers see a clean disconnect and reconnect rather than hanging.
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
        Write-Log ("Web server: SSE pump started (poll " + $global:WebServer_sse_poll_ms + "ms, max " + $global:WebServer_sse_max_clients + " clients)") -Level INFO
    } else {
        Write-Log "Web server: SSE pump unavailable - browsers will fall back to polling" -Level WARNING
    }
} else {
    Write-Log "Web server: SSE disabled by config - browsers will poll" -Level INFO
}

try {
    $lastConfigGeneration = 0

    while ($listener.IsListening) {
        # GetContext() blocks until a request arrives. Everything below it must be
        # cheap: this loop is the only thing accepting connections.
        $context = $listener.GetContext()

        # Pick up a config change applied by a slow route in the worker runspace.
        try {
            $gen = [int]$script:SlowState['ConfigGeneration']
            if ($gen -ne $lastConfigGeneration) {
                $lastConfigGeneration = $gen
                Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null
            }
        } catch { }

        # SSE: hand the connection to the pump and DO NOT close it here. Holding an
        # event-stream open on this loop would freeze every other page - the exact
        # failure the lanes exist to prevent.
        if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.Url.LocalPath -eq '/api/events') {
            if (-not $script:SsePump) {
                # 404, not 500: it is the signal live_events.js uses to stop retrying
                # and leave the page on the polling cadence it already had.
                try { $context.Response.StatusCode = 404; $context.Response.Close() } catch { }
                continue
            }
            # Capacity is checked BEFORE the headers are set, so a refusal is a plain
            # 503 rather than a half-opened event stream.
            $sseMax = if ($global:WebServer_sse_max_clients) { [int]$global:WebServer_sse_max_clients } else { 32 }
            if ([int]$script:SseState['Count'] + $script:SseQueue.Count -ge $sseMax) {
                try { $context.Response.StatusCode = 503; $context.Response.Close() } catch { }
                continue
            }
            try {
                $r = $context.Response
                $r.StatusCode  = 200
                $r.ContentType = 'text/event-stream; charset=utf-8'
                $r.Headers.Add('Cache-Control', 'no-cache')
                $r.Headers.Add('Access-Control-Allow-Origin', '*')
                # No ContentLength64: the body is an open-ended stream.
                $r.SendChunked = $true
                $r.KeepAlive   = $true
                # Enqueue LAST. The pump writes as soon as it sees the context, so the
                # headers have to be in place before it can be dequeued.
                [void](Add-SseClient -Context $context)
            } catch {
                try { $context.Response.Close() } catch { }
            }
            continue
        }

        $lane = 'fast'
        try { $lane = Get-WebRouteLane ([string]$context.Request.Url.LocalPath) } catch { }

        if ($lane -eq 'slow' -and $script:SlowWorker) {
            if ($script:SlowQueue.Count -ge $script:SlowMaxQueue) {
                # Backpressure. Better an explicit 503 than an unbounded queue of held
                # sockets that the client has long since given up on.
                try {
                    Send-JsonResponse -Response $context.Response -StatusCode 503 -Body @{ ok = $false; error = 'server busy' }
                } catch { }
                try { $context.Response.Close() } catch { }
            } else {
                $script:SlowQueue.Enqueue($context)
            }
            continue
        }

        Invoke-HttpRoute -Context $context
    }
} finally {
    Stop-SsePumpRunspace
    Stop-SlowLaneWorker
    $listener.Stop()
    $listener.Close()
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
