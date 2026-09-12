<#
.SYNOPSIS
    Enable or disable Windows automatic updates / automatic reboots (non-domain PC).
    Self-elevates to Administrator if needed, then shows an interactive menu.

.DESCRIPTION
    Sets/removes the WindowsUpdate\AU policy registry keys:
      - NoAutoUpdate
      - NoAutoRebootWithLoggedOnUsers
      - AUOptions
    Manual "Check for updates" in Settings always keeps working, regardless of mode.

.NOTES
    Just run this script as a normal user (double-click, or "Run with PowerShell").
    It will prompt for elevation (UAC) automatically if it isn't already admin.
#>

param(
    [switch]$Elevated
)

# ---------- Self-elevation ----------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Administrator privileges required - requesting elevation (UAC prompt)..." -ForegroundColor Yellow
    $scriptPath = $MyInvocation.MyCommand.Path
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @(
                "-NoExit",
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$scriptPath`"",
                "-Elevated"
            ) `
            -Verb RunAs
    }
    catch {
        Write-Host "Elevation was cancelled or failed. Cannot continue without admin rights." -ForegroundColor Red
        Read-Host "Press Enter to exit"
    }
    exit
}

# ---------- From here on, we are Administrator ----------
$RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"

function Disable-AutoUpdates {
    Write-Host "Disabling automatic Windows Update scan/download/install/reboot..." -ForegroundColor Cyan
    New-Item -Path $RegPath -Force | Out-Null
    Set-ItemProperty -Path $RegPath -Name "NoAutoUpdate" -Value 1 -Type DWord
    Set-ItemProperty -Path $RegPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
    Set-ItemProperty -Path $RegPath -Name "AUOptions" -Value 2 -Type DWord

    gpupdate /force | Out-Null
    Restart-Service wuauserv -Force -ErrorAction SilentlyContinue

    Write-Host "Done. Automatic updates and forced reboots are now disabled." -ForegroundColor Green
    Write-Host "You can still update manually via Settings > Windows Update > Check for updates." -ForegroundColor Green
}

function Enable-AutoUpdates {
    Write-Host "Re-enabling default automatic Windows Update behavior..." -ForegroundColor Cyan
    Remove-ItemProperty -Path $RegPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegPath -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegPath -Name "AUOptions" -ErrorAction SilentlyContinue

    if ((Get-Item -Path $RegPath -ErrorAction SilentlyContinue) -and
        -not (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).PSObject.Properties.Name.Where({$_ -notlike "PS*"})) {
        Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
    }

    gpupdate /force | Out-Null
    Restart-Service wuauserv -Force -ErrorAction SilentlyContinue

    Write-Host "Done. Windows Update is back to default (automatic) behavior." -ForegroundColor Green
}

function Show-CurrentStatus {
    Write-Host "`nCurrent registry state ($RegPath):" -ForegroundColor Yellow
    if (Test-Path $RegPath) {
        Get-ItemProperty -Path $RegPath | Select-Object NoAutoUpdate, NoAutoRebootWithLoggedOnUsers, AUOptions |
            Format-List
    } else {
        Write-Host "  (key does not exist - default Windows behavior is active)"
    }
    Write-Host ""
}

# ---------- Interactive menu ----------
Write-Host "Running with Administrator privileges." -ForegroundColor Green
Show-CurrentStatus

Write-Host "Select an option:"
Write-Host "  1) Disable automatic updates and automatic reboots (manual updates still work)"
Write-Host "  2) Enable automatic updates and automatic reboots (default Windows behavior)"
Write-Host "  3) Show current status only"
Write-Host "  0) Exit"

$choice = Read-Host "`nEnter choice (0-3)"

switch ($choice) {
    "1" { Disable-AutoUpdates; Show-CurrentStatus }
    "2" { Enable-AutoUpdates; Show-CurrentStatus }
    "3" { }
    "0" { Write-Host "Exiting without changes." }
    default { Write-Host "Invalid choice. Exiting without changes." -ForegroundColor Red }
}

Read-Host "`nPress Enter to close this window"
