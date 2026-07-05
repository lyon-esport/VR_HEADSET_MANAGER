# VR Headsets Manager - reaper.ps1
# Standalone hidden watchdog: when the main process dies unexpectedly (crash,
# Ctrl+C, X button), reads PID files in data\ and kills any orphan services
# (mediamtx, web server, dashboard) plus any scrcpy launched from this app.
#
# This script intentionally does NOT dot-source the module set. It must stay
# self-contained so a broken module cannot prevent cleanup.

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
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $procId = [int]($raw.Trim())
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Stop-OrphanScrcpy {
    try {
        $prefix = $sourcesFolder.TrimEnd('\') + '\'
        Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue | ForEach-Object {
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
        Stop-OrphanScrcpy
        break
    }

    Start-Sleep -Seconds 2
}
