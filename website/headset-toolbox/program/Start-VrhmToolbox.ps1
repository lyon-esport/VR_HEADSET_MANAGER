<#
.SYNOPSIS
    VRHM Headset Toolbox - one portable tool for everything a technician's PC
    needs to do with a VR HEADSET MANAGER server.

.DESCRIPTION
    Run this on a technician's or a kiosk PC - NOT on the VR HEADSET MANAGER
    server itself. It finds the server on its own, then offers:

      [1] Headset Toolbox      - onboard a USB headset (WiFi ADB, register,
                                 server-side WiFi push, WiFi ADB app install)
      [2] Kiosk Agent          - turn this PC into a managed Chrome kiosk
      [3] Change VRHM server   - search again, or type an address

    Nothing about a server is ever baked in: the toolbox scans the LAN, confirms
    a candidate really is a VR HEADSET MANAGER server (GET /api/version answering
    {"app":"VRHM",...}), and remembers the choice in vrhm_server_cache.json next
    to itself.

    adb.exe is not shipped inside the binary either - it is downloaded from the
    server on first use. Option [1] is therefore shown as unavailable when adb
    was never downloaded and no server can be reached.

    This script depends on nothing from the VR HEADSET MANAGER project other
    than the three files next to it, so the whole folder can be copied anywhere.
    It is also perfectly runnable on its own from PowerShell or the ISE.

.PARAMETER autodiscover
    Run the network discovery, write the cache (asking which server to use when
    several answer), then carry on to the menu.

.PARAMETER kiosk
    Go straight to the Kiosk Agent. Discovery runs first when no server is known.

.PARAMETER toolbox
    Go straight to the Headset Toolbox. Discovery runs first when no server is
    known.

.PARAMETER vrhm_ip
    Force the server address, bypassing the cache and the scan. Accepts "ip",
    "ip:port" or "http://host:port" - useful for a server outside this LAN.

.PARAMETER vrhm_port
    Force the server port (default 8080).

.PARAMETER ServerCachePath
    Where to read/write vrhm_server_cache.json. VRHM-Headset-Toolbox.exe points
    this at its own folder, so the cache sits next to the binary rather than
    inside the extracted program folder.

.EXAMPLE
    .\Start-VrhmToolbox.ps1
    Finds the server (cache, then LAN scan) and shows the menu.

.EXAMPLE
    .\Start-VrhmToolbox.ps1 -kiosk -vrhm_ip 192.168.1.37 -vrhm_port 8080
    Starts the kiosk agent against that exact server, no scan.

.NOTES
    Press Ctrl + C at any time to close the toolbox. Everything it started -
    the adb server, the kiosk browser, the port forward and the firewall rules -
    is cleaned up on the way out.
#>

[CmdletBinding()]
param(
    [switch]$autodiscover,
    [switch]$kiosk,
    [switch]$toolbox,
    [string]$vrhm_ip = "",
    [int]$vrhm_port = 0,

    [string]$ServerCachePath = "",
    [int]$AdbPort = 5555,
    [int]$KioskPort = 9222,
    [string]$KioskUrl = "",
    [string]$ChromePath = "",
    [int]$ReportIntervalSec = 5,
    [switch]$NoAutoRestartBrowser
)

# DO NOT set $ErrorActionPreference = "Stop" here.
#
# Preference variables are dynamically scoped, so a Stop here reaches every adb
# call in VrhmHeadsetOnboard.ps1 - and in Windows PowerShell 5.1 a NATIVE command
# writing to stderr is surfaced as an ErrorRecord, which Stop turns into a
# terminating error even when the exit code is fine and stderr was redirected.
# `adb tcpip 5555` re-enumerates the USB transport for about ten seconds, so the
# IP poll that follows it legitimately prints "error: closed" for a few attempts
# before the device comes back. With Stop, the first of those aborted the whole
# headset and the operator saw "Unexpected error while processing this headset:
# error: closed" on every single headset.
#
# Everything that genuinely needs a throw passes -ErrorAction Stop explicitly.
$script:ToolFolder = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

. (Join-Path $script:ToolFolder 'VrhmServerDiscovery.ps1')
. (Join-Path $script:ToolFolder 'VrhmHeadsetOnboard.ps1')
. (Join-Path $script:ToolFolder 'VrhmKioskAgent.ps1')

$defaultPort = if ($vrhm_port -gt 0) { $vrhm_port } else { 8080 }
Set-VrhmDiscoveryContext -CachePath $ServerCachePath -DefaultPort $defaultPort
Set-VrhmHeadsetContext   -ToolFolder $script:ToolFolder -AdbPort $AdbPort

# ---------------------------------------------------------------------------
# Shutdown - one cleanup path for Ctrl+C, for the menu's exit and for a remote
# agent-stop. Everything in it is idempotent.
# ---------------------------------------------------------------------------
$script:ToolboxCleanupDone = $false
$script:QuitRequested      = $false

function Stop-VrhmToolbox {
    if ($script:ToolboxCleanupDone) { return }
    $script:ToolboxCleanupDone = $true
    try { Stop-VrhmAdbServer } catch { }
    try { Stop-VrhmKioskAgent } catch { }
}

[Console]::add_CancelKeyPress({ Stop-VrhmToolbox })
Register-EngineEvent -SupportEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-VrhmToolbox } | Out-Null

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

function Show-VrhmBanner {
    <#
    .SYNOPSIS
    Prints the server header: address, version and live reachability.
    #>
    param([hashtable]$Server)

    $info = Get-VrhmServerInfo -IPAddress $Server.IPAddress -Port $Server.Port
    if ($info.Ok -and $info.Version) { $Server.Version = $info.Version }

    $version = if ($Server.Version) { $Server.Version } else { "unknown" }
    $reach   = if ($info.Ok) { "yes ($($info.LatencyMs) ms)" } else { "NO - the server did not answer" }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  VRHM HEADSET TOOLBOX" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host ("  VRHM Server   {0}:{1}" -f $Server.IPAddress, $Server.Port)
    Write-Host ("  Version       {0}" -f $version)
    if ($info.Ok) {
        Write-Host ("  Reachable     {0}" -f $reach) -ForegroundColor Green
    } else {
        Write-Host ("  Reachable     {0}" -f $reach) -ForegroundColor Red
    }
    Write-Host "=========================================================" -ForegroundColor Cyan

    return $info.Ok
}

# ---------------------------------------------------------------------------
# Kiosk step - needs Administrator for the firewall rules and the port forward,
# so it relaunches the toolbox elevated rather than asking for UAC at startup.
# A technician registering a headset should never see a UAC prompt.
# ---------------------------------------------------------------------------

function Start-KioskStep {
    param([hashtable]$Server)

    if (-not (Test-IsAdmin)) {
        Write-Host ""
        Write-Host "Kiosk mode needs Administrator rights (firewall rules, port forward, power commands)." -ForegroundColor Yellow
        Write-Host "Restarting the toolbox elevated..." -ForegroundColor Yellow

        $argList = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-kiosk",
            "-vrhm_ip", $Server.IPAddress,
            "-vrhm_port", $Server.Port,
            "-KioskPort", $KioskPort,
            "-ReportIntervalSec", $ReportIntervalSec
        )
        if ($ServerCachePath)      { $argList += @("-ServerCachePath", "`"$ServerCachePath`"") }
        if ($KioskUrl)             { $argList += @("-KioskUrl", "`"$KioskUrl`"") }
        if ($ChromePath)           { $argList += @("-ChromePath", "`"$ChromePath`"") }
        if ($NoAutoRestartBrowser) { $argList += "-NoAutoRestartBrowser" }

        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs | Out-Null
            Write-Host "The kiosk agent now runs in its own elevated window." -ForegroundColor Green
        } catch {
            Write-Host "Elevation was cancelled - the kiosk agent cannot run without admin rights." -ForegroundColor Red
        }
        return
    }

    Start-VrhmKioskAgent -ServerUrl $Server.Url `
                         -Port $KioskPort `
                         -Url $KioskUrl `
                         -ReportIntervalSec $ReportIntervalSec `
                         -ChromePath $ChromePath `
                         -NoAutoRestartBrowser:$NoAutoRestartBrowser
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

function Show-VrhmMenu {
    param([hashtable]$Server, [bool]$ServerReachable)

    $adbReady = [bool](Get-VrhmAdbPath)
    $headsetAvailable = $adbReady -or $ServerReachable

    Write-Host ""
    if ($headsetAvailable) {
        Write-Host "  [1] Headset Toolbox      - onboard a USB headset"
    } else {
        Write-Host "  [1] Headset Toolbox      - unavailable (adb not downloaded, server unreachable)" -ForegroundColor DarkGray
    }
    Write-Host "  [2] Kiosk Agent          - turn this PC into a Chrome kiosk"
    Write-Host "  [3] Change VRHM server   - search again / enter an address"
    Write-Host "  [0] Quit"
    Write-Host ""
    Write-Host "  Close the app with [0], or by pressing Ctrl + C at any time" -ForegroundColor DarkGray
    Write-Host ""

    return $headsetAvailable
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Host "VR HEADSET MANAGER - Headset Toolbox" -ForegroundColor Cyan

    $server = Resolve-VrhmServer -ForcedIp $vrhm_ip -ForcedPort $vrhm_port -IgnoreCache:$autodiscover

    # Direct-start switches: do the one job asked for, then stop. This is what a
    # kiosk PC's autostart shortcut uses.
    if ($kiosk) {
        Show-VrhmBanner -Server $server | Out-Null
        Start-KioskStep -Server $server
        return
    }
    if ($toolbox) {
        Show-VrhmBanner -Server $server | Out-Null
        Invoke-VrhmHeadsetOnboarding -ServerUrl $server.Url
        return
    }

    while ($true) {
        $reachable        = Show-VrhmBanner -Server $server
        $headsetAvailable = Show-VrhmMenu -Server $server -ServerReachable $reachable

        $choice = Read-Host "Choice"

        switch -Regex ($choice) {
            '^1$' {
                if (-not $headsetAvailable) {
                    Write-Host "adb has never been downloaded and the server is not reachable - connect to a server first." -ForegroundColor Yellow
                    break
                }
                Invoke-VrhmHeadsetOnboarding -ServerUrl $server.Url
                break
            }
            '^2$' {
                Start-KioskStep -Server $server
                break
            }
            '^3$' {
                # A deliberate change of server: ignore the cache, so this always
                # means "look again", never "hand me back the same one" - and
                # -AlwaysPrompt so the choice is offered even when a single server
                # answers, which is the only way to reach the manual entry for a
                # server that is not on this LAN.
                $server = Resolve-VrhmServer -ForcedIp '' -ForcedPort $server.Port -IgnoreCache -AlwaysPrompt
                break
            }
            '^(0|q|quit|exit)$' {
                # Same end state as Ctrl+C: the finally below runs Stop-VrhmToolbox,
                # so the adb server, the kiosk browser, the port forward and the
                # firewall rules are torn down exactly as they would be on a break.
                Write-Host ""
                Write-Host "Closing the toolbox..." -ForegroundColor DarkGray
                $script:QuitRequested = $true
                break
            }
            default {
                Write-Host "Type 1, 2, 3 or 0 - or press Ctrl + C to close the toolbox." -ForegroundColor Yellow
            }
        }

        # A `break` inside a switch only leaves the switch, never the loop, so the
        # quit has to be carried out here.
        if ($script:QuitRequested) { break }
    }
} finally {
    Stop-VrhmToolbox
}
