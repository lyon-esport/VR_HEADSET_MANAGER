# VR Headsets Monitor - headsets_dashboard.ps1
# Display-only window: reads CSV data and renders the colored headsets table.
# Service supervision (scrcpy / mediamtx / web server restarts) lives in
# Start-VRMonitor; shutdown is handled by the main process and reaper.ps1.

param(
    [string]$ScriptPath,
    [string]$ConfigFilePath
)
Write-Host "Starting a new window for VR Headsets Monitor..." -ForegroundColor Green

Write-Host "ScriptPath received : $ScriptPath" -ForegroundColor Green
Write-Host "ConfigFilePath received : $ConfigFilePath" -ForegroundColor Cyan

$currentProcess = Get-WmiObject -Class Win32_Process -Filter "ProcessId = $PID"
$parentPID = $currentProcess.ParentProcessId
Write-Host "ID du process parent: $parentPID"

# One-time module + config load. The dashboard is display-only and uses
# already-imported functions (e.g. Show-HeadsetsTableColored) that re-read
# the CSVs from disk on each call, so there is no need to dot-source modules
# every iteration.
$global:ScriptPath = $ScriptPath
$global:IsDashboardProcess = $true
$scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
if (-not (Test-Path -Path $scripts_init)) {
    Write-Host "Error: The initialization script is missing!" -ForegroundColor Red
    exit
}
. $scripts_init

while ($true) {
    # Self-terminate if the parent (main) process is gone.
    if (-not (Get-Process -Id $parentPID -ErrorAction SilentlyContinue)) {
        Write-Host "Caller script has ended. Exiting VR Headsets Monitor..." -ForegroundColor Red
        break
    }

    Clear-Host
    Write-Host "VR Headsets Monitor (display)" -ForegroundColor Green
    Write-Host "=== KNOWN HEADSETS MONITORING ==="
    Show-HeadsetsTableColored

    Write-host "Refresh in $global:VRMonitor_refresh_timer seconds... " -ForegroundColor Yellow -NoNewline
    Start-Sleep -Seconds 1
    for ($i = $global:VRMonitor_refresh_timer - 1; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host "`n"
}

# Best-effort cleanup of our PID file on self-exit; reaper will clean up
# if we were killed without reaching this point.
try {
    $dashboardPidFile = Join-Path $global:ScriptPath "data\dashboard.pid"
    if (Test-Path -LiteralPath $dashboardPidFile) {
        Remove-Item -LiteralPath $dashboardPidFile -Force -ErrorAction SilentlyContinue
    }
} catch { }

Write-Host "Closing dashboard window." -ForegroundColor Red
Start-Sleep -Seconds 1
Stop-Process -Id $PID -Force
