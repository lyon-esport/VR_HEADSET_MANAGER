# VR Headsets Monitor - headsets_dashboard.ps1
# This script opens a new PowerShell window to display the status of known VR headsets.

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


#get callerscript identifier
$callerScript = (Get-Process -Id $parentPID)
Write-Host "Caller script : $callerScript" -ForegroundColor Yellow

Write-Host "Starting VR Headsets Monitor until Caller script is closed..." -ForegroundColor Green

# Wait for the main process to finish firewall setup before starting MediaMTX.
# Initialize-ComputerSetup writes data\fw_ready.flag once all rules are confirmed.
# This prevents the Windows "allow network access?" dialog on first run or after port changes.
$flagPath = Join-Path $ScriptPath "data\fw_ready.flag"
Write-Host "Waiting for firewall setup to complete..." -ForegroundColor Yellow -NoNewline
$timeout = 120
$elapsed = 0
while (-not (Test-Path -LiteralPath $flagPath) -and $elapsed -lt $timeout) {
    Write-Host "." -ForegroundColor Cyan -NoNewline
    Start-Sleep -Seconds 1
    $elapsed++
}
if (Test-Path -LiteralPath $flagPath) {
    Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
    Write-Host " ready." -ForegroundColor Green
} else {
    Write-Host " timed out, continuing anyway." -ForegroundColor Yellow
}
Write-Host ""

while ($true) {
    # Check if caller script is still running
    if (-not (Get-Process -Id $parentPID -ErrorAction SilentlyContinue)) {
        Write-Host "Caller script has ended. Exiting VR Headsets Monitor..." -ForegroundColor Red
        break
    }

#IMPORT ALL FUNCITONS...
    $global:ScriptPath = $ScriptPath
    $global:IsDashboardProcess = $true
    $scripts_init = Join-Path -Path $global:ScriptPath -ChildPath "\modules\scripts_init.ps1"
    if (Test-Path -Path $scripts_init) {
        . $scripts_init
    } else {
        Write-Host "Error: The initialization script is missing!" -ForegroundColor Red
        exit
    }

# Display the headsets table
    Clear-Host
    Write-Host "VR Headsets Monitor started..." -ForegroundColor Green

    Write-Host "=== KNOWN HEADSETS MONITORING ==="
    Show-HeadsetsTableColored
    
    Watch-ScrcpyProcesses # Restart scrcpy window if it was closed
    Start-MediaMtx        # Restart mediamtx if it has stopped

    Write-host "Refesh in $global:VRMonitor_refresh_timer seconds... " -ForegroundColor Yellow -NoNewline
    Start-Sleep -Seconds 1
    for ($i = $global:VRMonitor_refresh_timer - 1; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host "`n"  # Return to line
  
}

# Parent process has exited - perform cleanup and close this window.
# Note: $msg and other globals may not be available here (loop already exited),
# so use Write-Host directly and call functions defensively.
Write-Host "Stopping application services..." -ForegroundColor Yellow
try { Stop-VRMonitor } catch { }
try { Stop-MediaMtx  } catch { }

Write-Host "Closing dashboard window." -ForegroundColor Red
Start-Sleep -Seconds 2
Stop-Process -Id $PID -Force
