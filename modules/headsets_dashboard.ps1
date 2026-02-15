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

Write-Host "Starting loop until Caller script is closed..." -ForegroundColor Green
#sleep for 10s to let the caller script finish its initialization
Start-Sleep -Seconds 10

while ($true) {
    # Check if caller script is still running
    if (-not (Get-Process -Id $parentPID -ErrorAction SilentlyContinue)) {
        Write-Host "Caller script has ended. Exiting VR Headsets Monitor..." -ForegroundColor Red
        break
    }

#IMPORT ALL FUNCITONS...
    $global:ScriptPath = $ScriptPath
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

    Write-host "Refesh in $global:VRMonitor_refresh_timer seconds... " -ForegroundColor Yellow -NoNewline
    Start-Sleep -Seconds 1
    for ($i = $global:VRMonitor_refresh_timer - 1; $i -ge 1; $i--) {
        Write-Host "$i " -ForegroundColor Cyan -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host "`n"  # Return to line
  
}

#kill VRMonitor process
Stop-VRMonitor

#kill this process
Stop-Process -Id $PID
