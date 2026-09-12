<#
.SYNOPSIS
    Enable or disable Windows automatic updates / automatic reboots (non-domain PC).

.DESCRIPTION
    Sets/removes the WindowsUpdate\AU policy registry keys:
      - NoAutoUpdate
      - NoAutoRebootWithLoggedOnUsers
      - AUOptions
    Manual "Check for updates" in Settings always keeps working, regardless of mode.

.PARAMETER Action
    Disable  -> turn off automatic updates/reboots
    Enable   -> restore default Windows Update behavior
    Status   -> just show current registry state (default if omitted)

.EXAMPLE
    .\Toggle-WindowsUpdateAuto.ps1 -Action Disable
.EXAMPLE
    .\Toggle-WindowsUpdateAuto.ps1 -Action Enable
.EXAMPLE
    .\Toggle-WindowsUpdateAuto.ps1
    (shows an interactive menu, only used when no -Action is given AND the host supports Read-Host)

.NOTES
    Must be run as Administrator.
#>

#Requires -RunAsAdministrator

param(
    [ValidateSet("Enable", "Disable", "Status")]
    [string]$Action
)

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

# ---- Main ----
Show-CurrentStatus

if ($Action) {
    switch ($Action) {
        "Disable" { Disable-AutoUpdates; Show-CurrentStatus }
        "Enable"  { Enable-AutoUpdates; Show-CurrentStatus }
        "Status"  { } # already shown above
    }
    return
}

# No -Action supplied: try interactive menu, but don't crash hosts that can't prompt (e.g. some ISE contexts)
try {
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
}
catch {
    Write-Host "`nInteractive input is not available in this host." -ForegroundColor Red
    Write-Host "Run the script with a parameter instead, e.g.:" -ForegroundColor Yellow
    Write-Host "  .\Toggle-WindowsUpdateAuto.ps1 -Action Disable"
    Write-Host "  .\Toggle-WindowsUpdateAuto.ps1 -Action Enable"
    Write-Host "  .\Toggle-WindowsUpdateAuto.ps1 -Action Status"
}
