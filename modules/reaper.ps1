# VR Headsets Manager - reaper.ps1
# Standalone hidden watchdog: when the main process dies unexpectedly (crash,
# Ctrl+C, X button), reads PID files in data\ and kills any orphan services
# (mediamtx, web server, mDNS responder) plus any scrcpy launched from this app.
#
# This script intentionally does NOT dot-source the module set. It must stay
# self-contained so a broken module cannot prevent cleanup.
#
# PID-file contract (data\*.pid). Writer / reader / deleter:
#   webserver.pid        web_server.ps1 at start        | reaper, Stop-WebServer, Get-WebServerProcess | web server on exit, reaper
#   mediamtx.pid         Start-MediaMtx                 | reaper, Get-MediaMtxProcess                  | Stop-MediaMtx, reaper

#   mdns_responder.pid   Start-MdnsResponder            | reaper                                       | Stop-MdnsResponder, reaper
# scrcpy / ffmpeg / adb have no PID file: matched by exe path under sources\.
# The pipe bridge is a thread of the process that started the stream (ADR-0035): it dies with
# that process, so there is nothing to reap. A bridge_<safe>.pid left by an older build is only
# deleted, never used to kill (its PID may have been recycled).
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
        # Leftover pid files of the former per-stream bridge process: delete only (see header).
        foreach ($b in @(Get-ChildItem -LiteralPath $dataFolder -Filter 'bridge_*.pid' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $b.FullName -Force -ErrorAction SilentlyContinue
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
