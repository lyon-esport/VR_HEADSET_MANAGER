<#
.SYNOPSIS
    Standalone setup script to run on a kiosk PC (a screen driven remotely by
    VR HEADSET MANAGER via the Chrome DevTools Protocol).

.DESCRIPTION
    Copy this single file to any Windows PC that will act as a kiosk screen.
    Running it will:
      1. Restart itself elevated (as Administrator) if not already elevated.
      2. Open a Windows Firewall inbound rule for the Chrome remote debugging
         port (default 9222), so VR HEADSET MANAGER can reach it over the LAN.
      3. Launch Google Chrome with remote debugging enabled and in kiosk mode,
         pointed at the given start URL (or a blank/default page if omitted).

    This script does not depend on any other file from the VR HEADSET MANAGER
    project - it is meant to be copied and run standalone on a separate PC.

.PARAMETER Url
    The web page to display when Chrome starts (e.g. a VRHM video page, a
    Twitch link, an OBS output page). Defaults to a self-contained "Kiosk
    Mode / Ready to stream" waiting screen (a data: URL, no server needed) -
    VR HEADSET MANAGER can push a real URL afterwards via the Kiosk Screens
    feature, or push the same waiting screen back via its "Waiting screen"
    button.

.PARAMETER Port
    TCP port used for Chrome remote debugging. Must match the port the kiosk
    is registered under in VR HEADSET MANAGER (default 9222).

.PARAMETER ChromePath
    Optional explicit path to chrome.exe. If omitted, the script attempts to
    locate Chrome automatically (Program Files, Program Files (x86), then the
    per-user install location and the Windows App Paths registry key).

.EXAMPLE
    .\Start-KioskChrome.ps1

.EXAMPLE
    .\Start-KioskChrome.ps1 -Url "https://example.com" -Port 9222

.NOTES
    Re-run this script any time (for example after a reboot) to reopen the
    kiosk window - it is safe to run repeatedly; the firewall rule is only
    created if it does not already exist, and any previous kiosk Chrome
    instance using the same debug port is closed first to avoid a port
    conflict (Chrome refuses to open a second remote-debugging listener).

    By default, "--remote-debugging-port" alone makes Chrome listen on
    127.0.0.1 only, so this script also passes
    "--remote-debugging-address=0.0.0.0" to try to bind all network
    interfaces. Recent Chrome releases silently ignore that flag and keep
    the debug listener on 127.0.0.1 regardless, for security reasons, with
    no reliable command-line or policy override. When this script detects
    that (step 6), it automatically sets up an OS-level port forward via
    "netsh interface portproxy" so the kiosk's real IP:Port still relays
    through to Chrome's loopback listener - no extra action needed.
#>

[CmdletBinding()]
param (
    [string]$Url = "data:text/html,%3Chtml%3E%3Chead%3E%3Cmeta%20charset%3D'utf-8'%3E%3Ctitle%3EKiosk%3C%2Ftitle%3E%3Cstyle%3Ehtml%2Cbody%7Bmargin%3A0%3Bheight%3A100%25%3Bbackground%3A%23000%3Bcolor%3A%23fff%3Bdisplay%3Aflex%3Balign-items%3Acenter%3Bjustify-content%3Acenter%3Bfont-family%3Asystem-ui%2Csans-serif%3Bflex-direction%3Acolumn%7Dh1%7Bfont-size%3A3vw%3Bletter-spacing%3A.08em%3Btext-transform%3Auppercase%3Bcolor%3A%23888%3Bmargin%3A0%7Dh2%7Bfont-size%3A5vw%3Bfont-weight%3A700%3Bmargin%3A12px%200%200%7D%3C%2Fstyle%3E%3C%2Fhead%3E%3Cbody%3E%3Ch1%3EKiosk%20Mode%3C%2Fh1%3E%3Ch2%3EReady%20to%20stream%3C%2Fh2%3E%3C%2Fbody%3E%3C%2Fhtml%3E",
    [int]$Port = 9222,
    [string]$ChromePath = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 1. Self-elevate if not already running as Administrator
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "This script needs to run as Administrator (to add a firewall rule)." -ForegroundColor Yellow
    Write-Host "Restarting elevated..." -ForegroundColor Yellow

    $scriptPath = $MyInvocation.MyCommand.Path
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
    $argList += "-Url"; $argList += "`"$Url`""
    $argList += "-Port"; $argList += "$Port"
    if ($ChromePath) {
        $argList += "-ChromePath"; $argList += "`"$ChromePath`""
    }

    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host "Elevation was cancelled or failed. This script cannot continue without admin rights." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    exit 0
}

Write-Host "Running as Administrator - continuing." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Open the firewall for the Chrome remote debugging port
# ---------------------------------------------------------------------------
$ruleName = "VRHM Kiosk Chrome Debug $Port"

$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existingRule) {
    Write-Host "Adding firewall rule '$ruleName' for TCP port $Port..." -ForegroundColor Cyan
    New-NetFirewallRule -DisplayName $ruleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $Port `
        -Action Allow `
        -Profile Any | Out-Null
    Write-Host "Firewall rule created." -ForegroundColor Green
} else {
    Write-Host "Firewall rule '$ruleName' already exists - skipping." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 3. Locate Chrome
# ---------------------------------------------------------------------------
function Find-ChromeExe {
    param([string]$ExplicitPath)

    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) {
        return $ExplicitPath
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    # Fall back to the App Paths registry key
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path -LiteralPath $regPath) {
            $value = (Get-Item -LiteralPath $regPath).GetValue("")
            if ($value -and (Test-Path -LiteralPath $value)) {
                return $value
            }
        }
    }

    return $null
}

$resolvedChromePath = Find-ChromeExe -ExplicitPath $ChromePath
if (-not $resolvedChromePath) {
    Write-Host "Could not find chrome.exe automatically." -ForegroundColor Red
    Write-Host "Re-run this script with -ChromePath pointing at your chrome.exe, for example:" -ForegroundColor Yellow
    Write-Host "  .\Start-KioskChrome.ps1 -ChromePath `"C:\Path\To\chrome.exe`"" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Chrome found at: $resolvedChromePath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Close any previous kiosk Chrome instance using this debug port
#    (Chrome refuses a second remote-debugging listener on the same port)
# ---------------------------------------------------------------------------
$userDataDir = Join-Path $env:LOCALAPPDATA "VRHM_KioskChrome"
$portMarker = "--remote-debugging-port=$Port"

$existingChrome = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$portMarker*" }

if ($existingChrome) {
    Write-Host "Closing previous kiosk Chrome instance on port $Port..." -ForegroundColor Yellow
    foreach ($proc in $existingChrome) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------------------
# 5. Start Chrome in remote-debugging + kiosk mode
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
}

# When Chrome is closed via the CDP "Browser.close" call (the Kiosk Screens
# "Kill kiosk browser" button) instead of Stop-Process, it can leave this
# profile's Singleton* lock files behind. A later launch then silently hands
# off to (or is blocked by) that stale lock instead of starting a genuinely
# fresh, debug-enabled process - Chrome opens and the kiosk display looks
# fine, but the new debug listener never actually comes up, so the server
# can no longer reach it. Clearing these before every launch guarantees a
# real fresh instance each time.
foreach ($lockFile in @("SingletonLock", "SingletonSocket", "SingletonCookie")) {
    $lockPath = Join-Path $userDataDir $lockFile
    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

$chromeArgs = @(
    "--remote-debugging-port=$Port",
    "--remote-debugging-address=0.0.0.0",
    "--remote-allow-origins=*",
    "--user-data-dir=`"$userDataDir`"",
    "--kiosk",
    "--noerrdialogs",
    "--disable-infobars",
    "--no-first-run",
    "--deny-permission-prompts",
    "--disable-notifications",
    "--disable-features=Translate,TranslateUI,PrivacySandboxSettings4,AutofillServerCommunication",
    "--disable-session-crashed-bubble",
    "--no-default-browser-check",
    "--autoplay-policy=no-user-gesture-required",
    "`"$Url`""
)

Write-Host "Starting Chrome in kiosk mode with debug port $Port..." -ForegroundColor Cyan
Write-Host "URL: $Url" -ForegroundColor Cyan

$chromeProcess = Start-Process -FilePath $resolvedChromePath -ArgumentList $chromeArgs -PassThru

# ---------------------------------------------------------------------------
# 6. Verify Chrome actually bound the debug port to a LAN-reachable address.
#    Recent Chrome releases silently ignore "--remote-debugging-address" and
#    hard-lock the DevTools listener to 127.0.0.1 regardless of the flag, for
#    security reasons, with no reliable way to opt back in from the command
#    line. When that happens, fall back to an OS-level port forward
#    (netsh portproxy) that relays the kiosk's real IP:Port straight through
#    to the loopback listener Chrome already has open, bypassing the
#    restriction entirely.
# ---------------------------------------------------------------------------
Write-Host "Verifying the debug port is reachable from the network..." -ForegroundColor Cyan
Start-Sleep -Seconds 2

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1

# Always clear any previous portproxy rule for this port before deciding
# whether a new one is needed, so re-running this script stays idempotent.
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>&1 | Out-Null

if ($listener -and $listener.LocalAddress -eq "127.0.0.1") {
    Write-Host "Chrome is only listening on 127.0.0.1:$Port (LAN binding was ignored by this Chrome build)." -ForegroundColor Yellow
    Write-Host "Setting up a port forward so the LAN can still reach the debug port..." -ForegroundColor Yellow

    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$Port connectaddress=127.0.0.1 connectport=$Port | Out-Null

    $forwardCheck = netsh interface portproxy show v4tov4 | Select-String ":$Port\b"
    if ($forwardCheck) {
        Write-Host "Port forward active: 0.0.0.0:$Port -> 127.0.0.1:$Port" -ForegroundColor Green
    } else {
        Write-Host "Could not confirm the port forward was created. Run 'netsh interface portproxy show v4tov4' to check." -ForegroundColor Red
    }
} elseif ($listener) {
    Write-Host "Chrome is listening on $($listener.LocalAddress):$Port - already reachable from the LAN." -ForegroundColor Green
} else {
    Write-Host "Could not confirm Chrome is listening on port $Port yet. Give it a few seconds and re-check with:" -ForegroundColor Yellow
    Write-Host "  Get-NetTCPConnection -LocalPort $Port -State Listen" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Kiosk Chrome started. This PC can now be discovered and controlled from" -ForegroundColor Green
Write-Host "VR HEADSET MANAGER's Kiosk Screens feature on port $Port." -ForegroundColor Green
Write-Host ""
Write-Host "Watching the kiosk Chrome process - this window will close automatically" -ForegroundColor DarkGray
Write-Host "once Chrome exits (whether closed locally or via 'Kill kiosk browser')." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 7. Watch the kiosk Chrome process and clean up when it exits, instead of
#    blocking on a keypress. Without this, killing the browser remotely (CDP
#    Browser.close) leaves this window open and, more importantly, leaves
#    the port-forward rule from step 6 dangling and pointed at a now-dead
#    listener until the operator manually re-runs the script.
# ---------------------------------------------------------------------------
while ($chromeProcess -and -not $chromeProcess.HasExited) {
    Start-Sleep -Seconds 1
}

Write-Host ""
Write-Host "Kiosk Chrome has exited - cleaning up the port forward." -ForegroundColor Yellow
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>&1 | Out-Null
Write-Host "Done. Re-run this script to start the kiosk again." -ForegroundColor DarkGray
Start-Sleep -Seconds 2
