# VR Headsets Manager - reaper.ps1
# Standalone hidden watchdog: when the main process dies unexpectedly (crash,
# Ctrl+C, X button), reads PID files in data\ and kills any orphan services
# (mediamtx, web server, dashboard) plus any scrcpy launched from this app.
#
# This script intentionally does NOT dot-source the module set. It must stay
# self-contained so a broken module cannot prevent cleanup.
#
# PID-file contract (data\*.pid). Writer / reader / deleter:
#   webserver.pid        web_server.ps1 at start        | reaper, Stop-WebServer, Get-WebServerProcess | web server on exit, reaper
#   mediamtx.pid         Start-MediaMtx                 | reaper, Get-MediaMtxProcess                  | Stop-MediaMtx, reaper
#   dashboard.pid        main.ps1 / Show-MainMenu       | reaper                                       | dashboard on exit, reaper
#   mdns_responder.pid   Start-MdnsResponder            | reaper                                       | Stop-MdnsResponder, reaper
#   bridge_<safe>.pid    the pipe bridge job host itself (Start-HeadsetPipeBridge, its own $PID)
#                        | reaper (kills every bridge_*.pid)                                          | the job's finally, Stop-HeadsetPipeline, reaper
# scrcpy / ffmpeg / adb have no PID file: matched by exe path under sources\.
# Spawned by main.ps1 BEFORE Start-VRMonitor; it needs only the main PID and these paths.

param(
    [Parameter(Mandatory=$true)] [int]   $MainPid,
    [Parameter(Mandatory=$true)] [string]$ScriptPath
)

$dataFolder        = Join-Path $ScriptPath "data"
$sourcesFolder     = Join-Path $ScriptPath "sources"
$reaperExitFlag    = Join-Path $dataFolder "reaper_exit.flag"
$pidFiles          = @(
    (Join-Path $dataFolder "webserver.pid"),
    (Join-Path $dataFolder "mediamtx.pid"),
    (Join-Path $dataFolder "dashboard.pid"),
    (Join-Path $dataFolder "mdns_responder.pid")
)

function Stop-ByPidFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($raw) {
            $procId = [int]($raw.Trim())
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Stop-OrphanBySourcesPrefix {
    param([string]$Name)
    try {
        $prefix = $sourcesFolder.TrimEnd('\') + '\'
        Get-Process -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.Path -and $_.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
    } catch { }
}

while ($true) {
    # Graceful shutdown signaled by Invoke-AppShutdown: nothing left to do.
    if (Test-Path -LiteralPath $reaperExitFlag) {
        Remove-Item -LiteralPath $reaperExitFlag -Force -ErrorAction SilentlyContinue
        break
    }

    if (-not (Get-Process -Id $MainPid -ErrorAction SilentlyContinue)) {
        # Main died ungracefully. Reap and exit.
        foreach ($f in $pidFiles) { Stop-ByPidFile -Path $f }
        # Pipe bridge job hosts (powershell.exe, one per stream) keep the relay file open.
        foreach ($b in @(Get-ChildItem -LiteralPath $dataFolder -Filter 'bridge_*.pid' -File -ErrorAction SilentlyContinue)) {
            Stop-ByPidFile -Path $b.FullName
        }
        # scrcpy, ffmpeg and adb have no PID file (Stop-Scrcpy / Stop-AdbServer tear
        # these down on a graceful exit); on a crash, reap them the same way, by exe
        # path under this install's sources\ folder, so nothing is left holding a
        # stream open or locking this folder on disk (adb.exe's server process
        # otherwise outlives the app indefinitely by design - see Stop-AdbServer).
        Stop-OrphanBySourcesPrefix -Name "scrcpy"
        Stop-OrphanBySourcesPrefix -Name "ffmpeg"
        Stop-OrphanBySourcesPrefix -Name "adb"
        break
    }

    Start-Sleep -Seconds 2
}
