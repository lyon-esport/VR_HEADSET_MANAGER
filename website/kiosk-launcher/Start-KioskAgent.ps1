<#
.SYNOPSIS
    Advanced kiosk launcher + agent for a Windows PC driven remotely by
    VR HEADSET MANAGER. This is the "v2" companion to Start-KioskChrome.ps1.

.DESCRIPTION
    Copy this single file to any Windows PC that will act as a kiosk screen.
    It does everything Start-KioskChrome.ps1 does:
      1. Restarts itself elevated (as Administrator) if not already elevated.
      2. Opens Windows Firewall inbound rules for the Chrome remote debugging
         port (default 9222) and for inbound ping (ICMP Echo Request).
      3. Launches Google Chrome with remote debugging enabled, in kiosk mode.
      4. Falls back to a netsh portproxy when Chrome binds the debug port to
         loopback only.

    ...and then keeps running as an agent that adds:
      5. Server discovery - unless -ServerUrl or -ServerIp is given, the script
         finds the VR HEADSET MANAGER server on its own by scanning the local
         network, the same way scripts/Tools/Find-VRHM-Server.ps1 does. A
         successful match is cached next to this script, so later reboots
         resolve instantly. If nothing is found, it offers to retry the scan,
         accept a manually typed IP, or be cancelled with Ctrl+C - see
         -ServerIp below for the routed-network case (scanning does not cross
         subnets).
      6. Reporting - every few seconds it tells the VR HEADSET MANAGER server
         this PC's computer name, OS version, Chrome version, and whether the
         connection to the server runs over Ethernet or WiFi. That information
         shows up in the server's Kiosk Screens page and network scan.
      7. Remote power control - the operator can order a reboot, a shutdown, or
         a browser restart from VR HEADSET MANAGER.
      8. Browser watchdog - if Chrome dies or is closed, it is relaunched
         automatically (disable with -NoAutoRestartBrowser).

    IMPORTANT - this script never opens a listening port of its own. It only
    makes OUTBOUND calls: to its own loopback Chrome debug port, and to the
    VR HEADSET MANAGER server. Commands travel back inside the reply to its own
    report, so no inbound firewall rule beyond the existing Chrome debug port is
    needed. (A second, fallback command path also exists, used only if server
    discovery is somehow bypassed: see the notes on kiosk_command.html below.)

    This script does not depend on any other file from the VR HEADSET MANAGER
    project - it is meant to be copied and run standalone on a separate PC.

.PARAMETER Url
    The web page to display when Chrome starts. Defaults to a self-contained
    "Kiosk Mode / Ready to stream" waiting screen (a data: URL, no server
    needed).

.PARAMETER Port
    TCP port used for Chrome remote debugging. Must match the port the kiosk is
    registered under in VR HEADSET MANAGER (default 9222).

.PARAMETER ServerUrl
    Base URL of the VR HEADSET MANAGER web server, for example
    "http://192.168.1.37:8080". Optional - if omitted (and -ServerIp is not
    given either) the script finds the server itself; see -ServerIp and the
    server discovery notes above.

.PARAMETER ServerIp
    Forces the server address to this IP (combined with -ServerPort), skipping
    network discovery entirely. Use this on a routed network, where the server
    is not on the same local subnet and a scan would never reach it.

.PARAMETER ServerPort
    Port to use with -ServerIp, and the port scanned during automatic server
    discovery (default 8080 - the VR HEADSET MANAGER web server's default).

.PARAMETER ReportIntervalSec
    How often to report to the server, in seconds (default 5). This also bounds
    how long a reboot/shutdown order takes to arrive.

.PARAMETER NoAutoRestartBrowser
    Do not relaunch Chrome automatically when it exits. Without this switch the
    kiosk recovers on its own from a browser crash or a manual close.

.PARAMETER ChromePath
    Optional explicit path to chrome.exe. If omitted, the script locates Chrome
    automatically.

.EXAMPLE
    .\Start-KioskAgent.ps1

.EXAMPLE
    .\Start-KioskAgent.ps1 -ServerUrl "http://192.168.1.37:8080" -Port 9222 -ReportIntervalSec 10

.EXAMPLE
    .\Start-KioskAgent.ps1 -ServerIp 10.0.5.12 -ServerPort 8080

.NOTES
    Re-run this script any time (for example after a reboot) - it is safe to run
    repeatedly. To start it automatically at boot, see README-KioskChrome.md.

    Reboot and shutdown run as this elevated process, so they need no extra
    privilege setup on Windows.
#>

[CmdletBinding()]
param (
    [string]$Url = "data:text/html,%3Chtml%3E%3Chead%3E%3Cmeta%20charset%3D'utf-8'%3E%3Ctitle%3EKiosk%3C%2Ftitle%3E%3Cstyle%3Ehtml%2Cbody%7Bmargin%3A0%3Bheight%3A100%25%3Bbackground%3A%23000%3Bcolor%3A%23fff%3Bdisplay%3Aflex%3Balign-items%3Acenter%3Bjustify-content%3Acenter%3Bfont-family%3Asystem-ui%2Csans-serif%3Bflex-direction%3Acolumn%7Dh1%7Bfont-size%3A3vw%3Bletter-spacing%3A.08em%3Btext-transform%3Auppercase%3Bcolor%3A%23888%3Bmargin%3A0%7Dh2%7Bfont-size%3A5vw%3Bfont-weight%3A700%3Bmargin%3A12px%200%200%7D%3C%2Fstyle%3E%3C%2Fhead%3E%3Cbody%3E%3Ch1%3EKiosk%20Mode%3C%2Fh1%3E%3Ch2%3EReady%20to%20stream%3C%2Fh2%3E%3C%2Fbody%3E%3C%2Fhtml%3E",
    [int]$Port = 9222,
    [string]$ServerUrl = "",
    [string]$ServerIp = "",
    [int]$ServerPort = 8080,
    [int]$ReportIntervalSec = 5,
    [switch]$NoAutoRestartBrowser,
    [string]$ChromePath = ""
)

$ErrorActionPreference = "Stop"

$AgentVersion = "1.0"

# ---------------------------------------------------------------------------
# 1. Self-elevate if not already running as Administrator
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "This script needs to run as Administrator (firewall rules, reboot/shutdown)." -ForegroundColor Yellow
    Write-Host "Restarting elevated..." -ForegroundColor Yellow

    $scriptPath = $MyInvocation.MyCommand.Path
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"")
    $argList += "-Url"; $argList += "`"$Url`""
    $argList += "-Port"; $argList += "$Port"
    $argList += "-ReportIntervalSec"; $argList += "$ReportIntervalSec"
    if ($ServerUrl) {
        $argList += "-ServerUrl"; $argList += "`"$ServerUrl`""
    }
    if ($ServerIp) {
        $argList += "-ServerIp"; $argList += "`"$ServerIp`""
    }
    $argList += "-ServerPort"; $argList += "$ServerPort"
    if ($NoAutoRestartBrowser) {
        $argList += "-NoAutoRestartBrowser"
    }
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
# 2. Open the firewall for the Chrome remote debugging port and for inbound
#    ping (ICMP Echo Request), so the server's reachability check can reach
#    this PC. Rule names match the convention used by the server-side rules
#    in computer_setup.ps1, and are shared with Start-KioskChrome.ps1 so the
#    two launchers never create duplicate rules.
# ---------------------------------------------------------------------------
$ruleNameBase = "_[VR_HEADSET_MANAGER]Kiosk_Allowed"
$ruleNameTcp  = "$ruleNameBase TCP [IN]"
$ruleNameIcmp = "$ruleNameBase ICMPv4 [IN]"

Get-NetFirewallRule -DisplayName "VRHM Kiosk Chrome Debug $Port" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# -DisplayName on Get-NetFirewallRule treats its value as a wildcard pattern, and "[" / "]"
# are wildcard character-class metacharacters - passing $ruleNameTcp/$ruleNameIcmp there
# directly never matches their own literal brackets, so the exists-check always says "not
# found" and the rule gets recreated (and never found again for removal) on every run.
# Fetching all rules and filtering with -eq does a real literal comparison instead.
if (-not (Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $ruleNameTcp)) {
    Write-Host "Adding firewall rule '$ruleNameTcp' for TCP port $Port..." -ForegroundColor Cyan
    New-NetFirewallRule -DisplayName $ruleNameTcp `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $Port `
        -Action Allow `
        -Profile Any `
        -Description "Allow VR Headset Manager to reach this kiosk's Chrome remote debugging port" | Out-Null
    Write-Host "Firewall rule created." -ForegroundColor Green
} else {
    Write-Host "Firewall rule '$ruleNameTcp' already exists - skipping." -ForegroundColor DarkGray
}

if (-not (Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $ruleNameIcmp)) {
    Write-Host "Adding firewall rule '$ruleNameIcmp' for inbound ping..." -ForegroundColor Cyan
    New-NetFirewallRule -DisplayName $ruleNameIcmp `
        -Direction Inbound `
        -Protocol ICMPv4 `
        -IcmpType 8 `
        -Action Allow `
        -Profile Any `
        -Description "Allow VR Headset Manager to ping this kiosk for reachability checks" | Out-Null
    Write-Host "Firewall rule created." -ForegroundColor Green
} else {
    Write-Host "Firewall rule '$ruleNameIcmp' already exists - skipping." -ForegroundColor DarkGray
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

function Show-ManualInstallInstructions {
    Write-Host "Please install Google Chrome manually, then re-run this script." -ForegroundColor Yellow
    Write-Host "Download page: https://www.google.com/chrome/" -ForegroundColor Yellow
    Write-Host "Or, once installed, re-run with -ChromePath pointing at your chrome.exe, for example:" -ForegroundColor Yellow
    Write-Host "  .\Start-KioskAgent.ps1 -ChromePath `"C:\Path\To\chrome.exe`"" -ForegroundColor Yellow
    try {
        Start-Process "https://www.google.com/chrome/" | Out-Null
    } catch {
        # No default browser available - the operator already has the URL printed above.
    }
}

function Install-ChromeSilently {
    Write-Host "Downloading the official Chrome installer..." -ForegroundColor Cyan
    $installerPath = Join-Path $env:TEMP "chrome_installer.exe"
    try {
        try {
            Start-BitsTransfer -Source "https://dl.google.com/chrome/install/chrome_installer.exe" -Destination $installerPath -ErrorAction Stop
        } catch {
            Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/chrome_installer.exe" -OutFile $installerPath -UseBasicParsing
        }
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        return $false
    }

    Write-Host "Running the Chrome installer silently..." -ForegroundColor Cyan
    try {
        $proc = Start-Process -FilePath $installerPath -ArgumentList "/silent", "/install" -PassThru -Wait
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        return ($proc.ExitCode -eq 0)
    } catch {
        Write-Host "Silent install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Install-ChromeViaWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget is not available on this PC." -ForegroundColor Yellow
        return $false
    }

    Write-Host "Installing Chrome via winget..." -ForegroundColor Cyan
    try {
        & winget install --id Google.Chrome -e --silent --accept-package-agreements --accept-source-agreements
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Host "winget install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

$resolvedChromePath = Find-ChromeExe -ExplicitPath $ChromePath
if (-not $resolvedChromePath) {
    Write-Host "Could not find chrome.exe automatically." -ForegroundColor Yellow
    $choice = Read-Host "Install Google Chrome now? [A] Auto-install (recommended) / [M] I'll install it manually"

    if ($choice -match '^(?i)a') {
        $installed = Install-ChromeSilently
        if (-not $installed) {
            Write-Host "Direct download install did not succeed. Trying winget..." -ForegroundColor Yellow
            $installed = Install-ChromeViaWinget
        }

        if ($installed) {
            $resolvedChromePath = Find-ChromeExe -ExplicitPath $ChromePath
        }

        if (-not $resolvedChromePath) {
            Write-Host "Automatic install did not succeed." -ForegroundColor Red
            Show-ManualInstallInstructions
            Read-Host "Press Enter to exit"
            exit 1
        }
    } else {
        Show-ManualInstallInstructions
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host "Chrome found at: $resolvedChromePath" -ForegroundColor Green

$userDataDir = Join-Path $env:LOCALAPPDATA "VRHM_KioskChrome"
$portMarker  = "--remote-debugging-port=$Port"

# ---------------------------------------------------------------------------
# 4. Browser lifecycle. Factored into functions because - unlike the basic
#    launcher - this script relaunches Chrome on its own when the watchdog or
#    the operator asks for it.
# ---------------------------------------------------------------------------
function Stop-ExistingKioskChrome {
    # Chrome refuses a second remote-debugging listener on the same port, so any
    # previous instance using it has to go first.
    $existingChrome = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$portMarker*" }

    if ($existingChrome) {
        Write-Host "Closing previous kiosk Chrome instance on port $Port..." -ForegroundColor Yellow
        foreach ($proc in $existingChrome) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}

function Start-KioskBrowser {
    param([string]$StartUrl)

    if (-not (Test-Path -LiteralPath $userDataDir)) {
        New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
    }

    # When Chrome is closed via the CDP "Browser.close" call instead of
    # Stop-Process, it can leave this profile's Singleton* lock files behind. A
    # later launch then silently hands off to (or is blocked by) that stale lock
    # instead of starting a genuinely fresh, debug-enabled process - Chrome opens
    # and the kiosk display looks fine, but the new debug listener never actually
    # comes up, so the server can no longer reach it. Clearing these before every
    # launch guarantees a real fresh instance each time. This matters far more
    # here than in the basic launcher, because the watchdog relaunches often.
    foreach ($lockFile in @("SingletonLock", "SingletonSocket", "SingletonCookie")) {
        $lockPath = Join-Path $userDataDir $lockFile
        if (Test-Path -LiteralPath $lockPath) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }

    # A hard power loss (unplugging the kiosk instead of a clean shutdown) leaves
    # this profile's Preferences file with exit_type=Crashed. Recent Chrome builds
    # ignore --disable-session-crashed-bubble and always show the "Restore pages?"
    # popup based on that stored exit_type, regardless of CLI flags. Rewrite it to
    # a clean state before every launch so the popup never appears.
    $prefsPath = Join-Path $userDataDir "Default\Preferences"
    if (Test-Path -LiteralPath $prefsPath) {
        try {
            $prefsRaw = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8
            $prefsJson = $prefsRaw | ConvertFrom-Json
            if ($prefsJson.profile) {
                $prefsJson.profile.exit_type = "Normal"
                $prefsJson.profile.exited_cleanly = $true
                ($prefsJson | ConvertTo-Json -Depth 100 -Compress) | Set-Content -LiteralPath $prefsPath -Encoding UTF8 -NoNewline
            }
        } catch {
            Write-Host "Could not clear crash state in Chrome profile Preferences - the restore-pages popup may appear." -ForegroundColor Yellow
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
        "`"$StartUrl`""
    )

    Write-Host "Starting Chrome in kiosk mode with debug port $Port..." -ForegroundColor Cyan
    return (Start-Process -FilePath $resolvedChromePath -ArgumentList $chromeArgs -PassThru)
}

function Update-DebugPortForward {
    <#
        Recent Chrome releases silently ignore "--remote-debugging-address" and
        hard-lock the DevTools listener to 127.0.0.1, with no reliable way to opt
        back in from the command line. When that happens, fall back to an OS-level
        port forward that relays the kiosk's real IP:Port through to the loopback
        listener Chrome already has open.
    #>
    Write-Host "Verifying the debug port is reachable from the network..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1

    # Always clear any previous rule for this port first, so repeated relaunches
    # stay idempotent and never stack rules.
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>&1 | Out-Null

    if ($listener -and $listener.LocalAddress -eq "127.0.0.1") {
        Write-Host "Chrome is only listening on 127.0.0.1:$Port (LAN binding was ignored by this Chrome build)." -ForegroundColor Yellow

        # netsh portproxy is implemented by the "IP Helper" service (iphlpsvc) - if it is not
        # running, "netsh ... add" and "show v4tov4" both succeed and report the mapping, but
        # no listener is ever actually bound to the external interface, so the kiosk silently
        # stays unreachable from the LAN. Seen on a fresh/locked-down Windows image where this
        # service ships disabled.
        $ipHelper = Get-Service -Name iphlpsvc -ErrorAction SilentlyContinue
        if ($ipHelper -and $ipHelper.Status -ne 'Running') {
            Write-Host "The 'IP Helper' service (iphlpsvc) is not running - it is required for the port forward to work. Starting it..." -ForegroundColor Yellow
            try {
                Set-Service -Name iphlpsvc -StartupType Automatic -ErrorAction Stop
                Start-Service -Name iphlpsvc -ErrorAction Stop
                Write-Host "IP Helper service started." -ForegroundColor Green
            } catch {
                Write-Host "Could not start the IP Helper service: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "The port forward below will likely not be reachable from the LAN until this service can run." -ForegroundColor Red
            }
        }

        Write-Host "Setting up a port forward so the LAN can still reach the debug port..." -ForegroundColor Yellow
        netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$Port connectaddress=127.0.0.1 connectport=$Port | Out-Null

        Start-Sleep -Seconds 1
        # Confirm an actual listening socket on the external interface rather than trusting the
        # portproxy config table, which reports the mapping regardless of whether iphlpsvc could
        # bind it (see above).
        $externalListener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -ne '127.0.0.1' } | Select-Object -First 1
        if ($externalListener) {
            Write-Host "Port forward active: $($externalListener.LocalAddress):$Port -> 127.0.0.1:$Port" -ForegroundColor Green
        } else {
            Write-Host "Port forward was configured but no external listener came up - the kiosk will NOT be reachable from the LAN." -ForegroundColor Red
            Write-Host "Check 'Get-Service iphlpsvc' and 'Get-NetTCPConnection -LocalPort $Port' on this PC." -ForegroundColor Red
        }
    } elseif ($listener) {
        Write-Host "Chrome is listening on $($listener.LocalAddress):$Port - already reachable from the LAN." -ForegroundColor Green
    } else {
        Write-Host "Could not confirm Chrome is listening on port $Port yet." -ForegroundColor Yellow
    }
}

function Restart-KioskBrowser {
    param([string]$Reason = "operator request")

    Write-Host "Restarting the kiosk browser ($Reason)..." -ForegroundColor Yellow
    Remove-DebugPortForward
    Stop-ExistingKioskChrome
    $script:ChromeProcess = Start-KioskBrowser -StartUrl $Url
    Update-DebugPortForward

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Get-LocalCdpVersion) {
            Write-Host "Chrome debug endpoint is online after restart." -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "Chrome restarted, but the local debug endpoint did not answer yet." -ForegroundColor Yellow
    return $false
}

function Remove-DebugPortForward {
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>&1 | Out-Null
}

# ---------------------------------------------------------------------------
# 5. Agent helpers - local machine facts
# ---------------------------------------------------------------------------

# Machine identity and OS description never change while the script runs, so
# they are resolved once at startup rather than on every report.
function Get-MachineIdentifier {
    try {
        $uuid = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID
        if ($uuid -and $uuid -notmatch '^0{8}-0{4}') { return $uuid }
    } catch { }
    try {
        return (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
    } catch { }
    return $env:COMPUTERNAME
}

function Get-OsDescription {
    try {
        $os      = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = ($os.Caption -replace '^Microsoft\s+', '').Trim()
        $display = ""
        try {
            $display = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
                            -Name DisplayVersion -ErrorAction Stop).DisplayVersion
        } catch { }
        if ($display) {
            return "$caption $display (build $($os.BuildNumber))"
        }
        return "$caption (build $($os.BuildNumber))"
    } catch {
        return [string][System.Environment]::OSVersion.VersionString
    }
}

# Cache of local-IP -> interface facts. The mapping only changes when the PC
# moves between adapters, and the CIM lookups behind it are not free at a 5s
# cadence.
$script:InterfaceCache = @{}

function Get-SessionInterface {
    <#
        Reports the interface that actually carries the session with the server,
        rather than guessing at "the primary adapter". A UDP socket is connected
        to the server address - which sends nothing on the wire - purely to make
        the OS routing table pick the outbound interface, then its local address
        is mapped back to an adapter.
        Returns @{Type; Name; SpeedMbps; LocalIP}.
    #>
    param([string]$ServerHost)

    $unknown = @{ Type = "Unknown"; Name = $null; SpeedMbps = $null; LocalIP = $null }
    if (-not $ServerHost) { return $unknown }

    $localIp = $null
    try {
        $targetIp = $ServerHost
        if ($ServerHost -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            $addr = [System.Net.Dns]::GetHostAddresses($ServerHost) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if (-not $addr) { return $unknown }
            $targetIp = $addr.IPAddressToString
        }

        $sock = New-Object System.Net.Sockets.UdpClient
        try {
            # Port 9 (discard) - Connect() on a UDP socket only sets the peer, it
            # does not transmit anything.
            $sock.Connect($targetIp, 9)
            $localIp = $sock.Client.LocalEndPoint.Address.ToString()
        } finally {
            $sock.Close()
        }
    } catch {
        return $unknown
    }

    if (-not $localIp) { return $unknown }
    if ($script:InterfaceCache.ContainsKey($localIp)) { return $script:InterfaceCache[$localIp] }

    $result = @{ Type = "Unknown"; Name = $null; SpeedMbps = $null; LocalIP = $localIp }
    try {
        $ipCfg = Get-NetIPAddress -IPAddress $localIp -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        $adapter = Get-NetAdapter -InterfaceIndex $ipCfg.InterfaceIndex -ErrorAction Stop | Select-Object -First 1

        $result.Name = $adapter.Name

        # NetworkInterfaceType is the framework's own classification and is far
        # more dependable than string-matching an adapter description.
        $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.Id -eq $adapter.InterfaceGuid } | Select-Object -First 1

        $nicType = if ($nic) { [string]$nic.NetworkInterfaceType } else { "" }
        switch -Regex ($nicType) {
            'Wireless80211' { $result.Type = "WiFi" }
            'Ethernet|GigabitEthernet|FastEthernet' { $result.Type = "Ethernet" }
            default {
                # Fall back to the adapter's own media type when the framework
                # reports something unhelpful (some USB and virtual NICs do).
                if ($adapter.PhysicalMediaType -match '802\.11') { $result.Type = "WiFi" }
                elseif ($adapter.PhysicalMediaType -match '802\.3') { $result.Type = "Ethernet" }
                elseif ($nicType) { $result.Type = $nicType }
            }
        }

        if ($nic -and $nic.Speed -gt 0) {
            $result.SpeedMbps = [int]($nic.Speed / 1000000)
        } elseif ($adapter.LinkSpeed) {
            $result.SpeedMbps = $null
        }
    } catch {
        # Leave Type as Unknown - a missing link type must never stop a report.
    }

    $script:InterfaceCache[$localIp] = $result
    return $result
}

function Get-LocalCdpVersion {
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -Method GET -TimeoutSec 2 -ErrorAction Stop
        return $resp.Browser
    } catch {
        return $null
    }
}

function Get-LocalCdpCurrentUrl {
    try {
        $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -Method GET -TimeoutSec 2 -ErrorAction Stop
        $tab  = @($tabs) | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        if ($tab) { return $tab.url }
        return $null
    } catch {
        return $null
    }
}

function Get-ChromeFileVersion {
    try {
        return "Chrome/" + [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedChromePath).FileVersion
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# 6. Agent helpers - talking to the server
# ---------------------------------------------------------------------------

function Get-ServerHostFromUrl {
    param([string]$BaseUrl)
    try {
        return ([Uri]$BaseUrl).Host
    } catch {
        return $null
    }
}

function Send-AgentReport {
    <#
        POSTs one report to the server and returns the parsed reply, or $null if
        the server could not be reached. The reply carries any pending command.
        The server's request loop is single-threaded and a few of its endpoints
        block for a long time (a network scan, for example), so a timeout here is
        expected occasionally and must not be treated as fatal - the next tick
        simply tries again.
    #>
    param(
        [string]$BaseUrl,
        [hashtable]$Report
    )

    if (-not $BaseUrl) { return $null }

    try {
        $body = $Report | ConvertTo-Json -Depth 4 -Compress
        return Invoke-RestMethod -Uri ("{0}/api/kiosks/agent-report" -f $BaseUrl.TrimEnd('/')) `
            -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return $null
    }
}

function New-AgentReport {
    param(
        [string]$BaseUrl,
        [bool]$BrowserRunning,
        [string]$CurrentUrl,
        [hashtable]$Ack
    )

    $iface   = Get-SessionInterface -ServerHost (Get-ServerHostFromUrl -BaseUrl $BaseUrl)
    $browser = Get-LocalCdpVersion
    if (-not $browser) { $browser = Get-ChromeFileVersion }

    $report = @{
        type               = "VRHM_KIOSK_AGENT"
        version            = $AgentVersion
        machineId          = $script:MachineId
        hostname           = $env:COMPUTERNAME
        os                 = $script:OsDescription
        osFamily           = "Windows"
        interfaceType      = $iface.Type
        interfaceName      = $iface.Name
        linkSpeedMbps      = $iface.SpeedMbps
        browser            = $browser
        browserRunning     = $BrowserRunning
        cdpPort            = $Port
        currentUrl         = $CurrentUrl
        uptimeSec          = [int64]((Get-Date) - $script:StartedAt).TotalSeconds
        autoRestartBrowser = (-not $NoAutoRestartBrowser.IsPresent)
    }
    if ($Ack) { $report.ack = $Ack }
    return $report
}

function Invoke-KioskCommand {
    <#
        Executes one operator command. The caller has already acknowledged it to
        the server - deliberately, because a reboot leaves no opportunity to do so
        afterwards.
    #>
    param(
        [string]$Cmd,
        [int]$DelaySec = 5
    )

    switch ($Cmd) {
        'reboot' {
            Write-Host ""
            Write-Host "REBOOT ordered by VR HEADSET MANAGER - restarting in $DelaySec seconds." -ForegroundColor Red
            Remove-DebugPortForward
            & shutdown.exe /r /t $DelaySec /c "Reboot ordered by VR HEADSET MANAGER"
            return $true
        }
        'shutdown' {
            Write-Host ""
            Write-Host "SHUTDOWN ordered by VR HEADSET MANAGER - powering off in $DelaySec seconds." -ForegroundColor Red
            Remove-DebugPortForward
            & shutdown.exe /s /t $DelaySec /c "Shutdown ordered by VR HEADSET MANAGER"
            return $true
        }
        'browser-restart' {
            Write-Host ""
            Write-Host "BROWSER RESTART ordered by VR HEADSET MANAGER." -ForegroundColor Yellow
            $script:BrowserRestartRequested = $true
            return $true
        }
        'agent-stop' {
            Write-Host ""
            Write-Host "STOP ordered by VR HEADSET MANAGER - closing Chrome and stopping the agent." -ForegroundColor Yellow
            $script:AgentStopRequested = $true
            return $true
        }
        default {
            Write-Host "Ignoring unknown command '$Cmd' from the server." -ForegroundColor Yellow
            return $false
        }
    }
}

# ---------------------------------------------------------------------------
# 6b. Server discovery - find the VR HEADSET MANAGER server on the LAN when
#     neither -ServerUrl nor -ServerIp was given, so a kiosk works out of the
#     box after a DHCP change on either side. This logic is ported from (and
#     should be kept in sync with) scripts/Tools/Find-VRHM-Server.ps1 -
#     duplicated here rather than shared via a module, matching this script's
#     own "no dependency on any other project file" design.
# ---------------------------------------------------------------------------

function Get-VrhmServerCachePath {
    $scriptDir = $null
    if ($PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    return (Join-Path $scriptDir "vrhm_server_cache.json")
}

function Read-VrhmServerCache {
    $path = Get-VrhmServerCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($data.IPAddress -and $data.Port) {
            return @{ IPAddress = [string]$data.IPAddress; Port = [int]$data.Port }
        }
    } catch { }
    return $null
}

function Write-VrhmServerCache {
    param([string]$IPAddress, [int]$Port)
    try {
        $path = Get-VrhmServerCachePath
        (@{ IPAddress = $IPAddress; Port = $Port } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $path -Encoding UTF8 -NoNewline
    } catch { }
}

function Test-VrhmServerAt {
    param([string]$IPAddress, [int]$Port, [int]$TimeoutSec = 2)
    try {
        $uri = "http://${IPAddress}:${Port}/api/version"
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [bool]($response -and $response.version)
    } catch {
        return $false
    }
}

function Get-IpRangeLocal {
    param([string]$CIDR)

    if ($CIDR -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') { return @() }

    $ip = ($CIDR -split '/')[0]
    [int]$prefixLength = ($CIDR -split '/')[1]
    if ($prefixLength -lt 7 -or $prefixLength -gt 30) { return @() }

    $octets = $ip -split '\.'
    $ipBinary = ''
    foreach ($octet in $octets) {
        $ipBinary += [convert]::ToString([int]$octet, 2).PadLeft(8, '0')
    }

    $hostBits = 32 - $prefixLength
    $networkBinary = $ipBinary.Substring(0, $prefixLength)
    $maxHostValue = [convert]::ToInt32(('1' * $hostBits), 2) - 1

    $ips = @()
    for ($i = 1; $i -le $maxHostValue; $i++) {
        $hostBinary = [convert]::ToString($i, 2).PadLeft($hostBits, '0')
        $fullBinary = $networkBinary + $hostBinary
        $ipParts = @()
        for ($x = 0; $x -lt 4; $x++) {
            $octetBinary = $fullBinary.Substring($x * 8, 8)
            $ipParts += [convert]::ToInt32($octetBinary, 2)
        }
        $ips += ($ipParts -join '.')
    }
    return $ips
}

function ConvertTo-CIDRLocal {
    param([string]$IPAddress, [int]$PrefixLength)

    $binaryMask = ('1' * $PrefixLength).PadRight(32, '0')
    $maskBytes = $binaryMask -split '(.{8})' | Where-Object { $_ -ne '' } | ForEach-Object { [Convert]::ToInt32($_, 2) }
    $ipBytes = $IPAddress.Split('.') | ForEach-Object { [int]$_ }

    $networkBytes = for ($i = 0; $i -lt 4; $i++) {
        $ipBytes[$i] -band $maskBytes[$i]
    }

    return "$($networkBytes -join '.')/$PrefixLength"
}

function Get-PrivateNetworksLocal {
    $defaultRouteIfIndex = $null
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($route) { $defaultRouteIfIndex = $route.InterfaceIndex }
    } catch { }

    $adapterByIndex = @{}
    try {
        Get-NetAdapter -ErrorAction Stop | ForEach-Object {
            $adapterByIndex[$_.InterfaceIndex] = $_
        }
    } catch { }

    $virtualPattern = 'Hyper-V|VMware|VirtualBox|WSL|vEthernet|Pseudo|TAP|WAN Miniport'

    $networkInterfaces = Get-NetIPAddress | Where-Object {
        $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -match '\d+\.\d+\.\d+\.\d+' -and
        $_.IPAddress -notlike '169.254.*'
    }

    $privateIPs = $networkInterfaces | Where-Object {
        ($_).IPAddress -match '^10\.' -or
        ($_).IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.' -or
        ($_).IPAddress -match '^192\.168\.'
    }

    $privateIPs = $privateIPs | Where-Object {
        if ($defaultRouteIfIndex -and $_.InterfaceIndex -eq $defaultRouteIfIndex) {
            return $true
        }
        $adapter     = $adapterByIndex[$_.InterfaceIndex]
        $description = if ($adapter) { $adapter.InterfaceDescription } else { $null }
        $isVirtual   = ($adapter -and $adapter.Virtual) -or
                       ($description -and $description -match $virtualPattern) -or
                       ($_.InterfaceAlias -match $virtualPattern)
        -not $isVirtual
    }

    $privateIPs | ForEach-Object {
        [PSCustomObject]@{
            InterfaceAlias = $_.InterfaceAlias
            IPAddress      = $_.IPAddress
            PrefixLength   = $_.PrefixLength
            NetworkCIDR    = ConvertTo-CIDRLocal -IPAddress $_.IPAddress -PrefixLength $_.PrefixLength
        }
    }
}

function Test-PortForCidrLocal {
    param(
        [string[]]$IpRange,
        [int]$Port,
        [int]$Timeout,
        [int]$MaxThreads
    )

    if (-not $IpRange -or $IpRange.Count -eq 0) {
        return @()
    }

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $runspacePool.Open()
    $jobs = @()

    $testPortScript = {
        param($ip, $port, $timeout)

        $result = [PSCustomObject]@{
            IPAddress = $ip
            Port      = $port
            Open      = $false
        }

        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect($ip, $port, $null, $null)
            $connected = $asyncResult.AsyncWaitHandle.WaitOne($timeout, $false)

            if ($connected -and $tcpClient.Connected) {
                $result.Open = $true
                $tcpClient.EndConnect($asyncResult)
            }
        } catch {
        } finally {
            if ($tcpClient) { $tcpClient.Dispose() }
        }
        return $result
    }

    foreach ($ip in $IpRange) {
        $powershell = [powershell]::Create().AddScript($testPortScript).AddArgument($ip).AddArgument($Port).AddArgument($Timeout)
        $powershell.RunspacePool = $runspacePool
        $jobs += [PSCustomObject]@{
            PowerShell  = $powershell
            AsyncResult = $powershell.BeginInvoke()
        }
    }

    Start-Sleep -Milliseconds ([Math]::Min(20 * $Timeout, 10000))

    $results = do {
        foreach ($job in $jobs) {
            if ($job.AsyncResult.IsCompleted) {
                $job.PowerShell.EndInvoke($job.AsyncResult)
                $job.PowerShell.Dispose()
            }
        }
        $jobs = $jobs | Where-Object { -not $_.AsyncResult.IsCompleted }
    } while ($jobs.Count -gt 0)

    $runspacePool.Close()
    $runspacePool.Dispose()

    return $results | Where-Object Open
}

function Find-VrhmServerOnLan {
    param([int]$Port, [int]$TimeoutMs = 300, [int]$MaxThreads = 50)

    $networks = Get-PrivateNetworksLocal
    if (-not $networks -or $networks.Count -eq 0) { return $null }

    $allIps = @()
    foreach ($net in $networks) { $allIps += Get-IpRangeLocal -CIDR $net.NetworkCIDR }
    $allIps = $allIps | Select-Object -Unique
    if ($allIps.Count -eq 0) { return $null }

    Write-Host "Scanning $($allIps.Count) address(es) on port $Port for a VR HEADSET MANAGER server..." -ForegroundColor Cyan
    $openHosts = Test-PortForCidrLocal -IpRange $allIps -Port $Port -Timeout $TimeoutMs -MaxThreads $MaxThreads
    if (-not $openHosts -or $openHosts.Count -eq 0) { return $null }

    $found = @()
    foreach ($candidate in $openHosts) {
        if (Test-VrhmServerAt -IPAddress $candidate.IPAddress -Port $Port) {
            $found += $candidate.IPAddress
        }
    }

    if ($found.Count -eq 0) { return $null }
    if ($found.Count -gt 1) {
        Write-Host "Found multiple VR HEADSET MANAGER servers on the network: $($found -join ', ') - using $($found[0])." -ForegroundColor Yellow
    }
    return @{ IPAddress = $found[0]; Port = $Port }
}

function Resolve-VrhmServerUrl {
    <#
        Cascade: explicit -ServerUrl > explicit -ServerIp > cached last-known
        server > LAN scan > a blocking console menu (retry the scan, type an
        IP manually, or Ctrl+C to give up). Always returns a URL or never
        returns at all (the operator closed the script) - callers downstream
        never need to handle a $null server address.
    #>
    param([string]$ServerUrl, [string]$ServerIp, [int]$ServerPort)

    if ($ServerUrl) { return $ServerUrl }
    if ($ServerIp)  { return "http://${ServerIp}:${ServerPort}" }

    $cached = Read-VrhmServerCache
    if ($cached -and (Test-VrhmServerAt -IPAddress $cached.IPAddress -Port $cached.Port)) {
        Write-Host "Using the last known VR HEADSET MANAGER server at $($cached.IPAddress):$($cached.Port)." -ForegroundColor Green
        return "http://$($cached.IPAddress):$($cached.Port)"
    }

    while ($true) {
        $found = Find-VrhmServerOnLan -Port $ServerPort
        if ($found) {
            Write-Host "Found VR HEADSET MANAGER server at $($found.IPAddress):$($found.Port)." -ForegroundColor Green
            Write-VrhmServerCache -IPAddress $found.IPAddress -Port $found.Port
            return "http://$($found.IPAddress):$($found.Port)"
        }

        Write-Host ""
        Write-Host "No VR HEADSET MANAGER server was found on the network." -ForegroundColor Yellow
        Write-Host "  [R] Restart the search"
        Write-Host "  [I] Enter the server IP manually"
        Write-Host "  Ctrl+C to stop this script"
        $choice = Read-Host "Choice"

        if ($choice -match '^(?i)i') {
            $manualIp = Read-Host "Server IP address"
            if ($manualIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                Write-VrhmServerCache -IPAddress $manualIp -Port $ServerPort
                return "http://${manualIp}:${ServerPort}"
            }
            Write-Host "'$manualIp' is not a valid IPv4 address." -ForegroundColor Red
        }
        # [R], or any other input, or empty input -> restart the search
    }
}

# ---------------------------------------------------------------------------
# 7. Start the browser
# ---------------------------------------------------------------------------
Stop-ExistingKioskChrome
$script:ChromeProcess = Start-KioskBrowser -StartUrl $Url
Update-DebugPortForward

$script:StartedAt               = Get-Date
$script:MachineId               = Get-MachineIdentifier
$script:OsDescription           = Get-OsDescription
$script:BrowserRestartRequested = $false
$script:AgentStopRequested      = $false
$script:LastCommandNonce        = $null

Write-Host ""
Write-Host "Kiosk Chrome started. This PC can be discovered and controlled from" -ForegroundColor Green
Write-Host "VR HEADSET MANAGER's Kiosk Screens feature on port $Port." -ForegroundColor Green
Write-Host ""
Write-Host "Computer name : $env:COMPUTERNAME" -ForegroundColor DarkGray
Write-Host "OS            : $script:OsDescription" -ForegroundColor DarkGray

$currentServerUrl = Resolve-VrhmServerUrl -ServerUrl $ServerUrl -ServerIp $ServerIp -ServerPort $ServerPort
Write-Host "Server        : $currentServerUrl (reporting every ${ReportIntervalSec}s)" -ForegroundColor DarkGray

if ($NoAutoRestartBrowser) {
    Write-Host "Browser watch : auto-restart DISABLED" -ForegroundColor DarkGray
} else {
    Write-Host "Browser watch : auto-restart enabled" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Agent running. Keep this window open - closing it stops the reporting" -ForegroundColor DarkGray
Write-Host "and the browser watchdog. Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# 8. Agent loop. One tick per second: browser watchdog every tick, report to
#    the server every -ReportIntervalSec.
# ---------------------------------------------------------------------------
$ticksUntilReport   = 0
$reportFailures     = 0
$lastReportOk       = $true
$browserDeadSince   = $null
$maxReportBackoff   = 60

# Sentinel fallback: kept as defense-in-depth for the case reporting to
# $currentServerUrl is failing (e.g. it went stale after this ran) - a page
# pushed to this screen over CDP still carries a command, and matching its URL
# re-teaches us the server address too.
$sentinelPattern = '(?i)^(https?://[^/]+)/kiosk_command\.html\?.*\bcmd=([a-z\-]+).*\bnonce=(\d+)'

try {
    while ($true) {
        if ($script:AgentStopRequested) {
            break
        }

        # ---- Browser watchdog ----
        $processAlive = ($script:ChromeProcess -and -not $script:ChromeProcess.HasExited)
        $cdpAlive     = $false
        if (-not $processAlive) {
            # Chrome can hand a launch off to an existing process, which retires
            # the object we hold while the browser itself is perfectly alive. Only
            # a dead debug endpoint proves the browser is really gone.
            $cdpAlive = ($null -ne (Get-LocalCdpVersion))
        }
        $browserAlive = $processAlive -or $cdpAlive

        if ($script:BrowserRestartRequested) {
            $script:BrowserRestartRequested = $false
            Restart-KioskBrowser -Reason "operator request" | Out-Null
            $browserDeadSince = $null
        }
        elseif (-not $browserAlive) {
            if ($NoAutoRestartBrowser) {
                Write-Host ""
                Write-Host "Kiosk Chrome has exited and auto-restart is disabled - cleaning up." -ForegroundColor Yellow
                break
            }

            # Short grace period: a browser-initiated restart, or a slow shutdown,
            # should not race the watchdog into launching a second instance.
            if (-not $browserDeadSince) {
                $browserDeadSince = Get-Date
                Write-Host "Kiosk Chrome is not running - relaunching shortly..." -ForegroundColor Yellow
            } elseif (((Get-Date) - $browserDeadSince).TotalSeconds -ge 3) {
                Restart-KioskBrowser -Reason "watchdog" | Out-Null
                $browserDeadSince = $null
                Write-Host "Kiosk Chrome relaunched by the watchdog." -ForegroundColor Green
            }
        } else {
            $browserDeadSince = $null
        }

        # ---- Report + command collection ----
        $ticksUntilReport--
        if ($ticksUntilReport -le 0) {
            $backoff = [Math]::Min($maxReportBackoff, [Math]::Max(1, $ReportIntervalSec) * [Math]::Pow(2, [Math]::Min($reportFailures, 4)))
            $jitter = if ($reportFailures -gt 0) { Get-Random -Minimum 0 -Maximum 4 } else { 0 }
            $ticksUntilReport = [int]([Math]::Min($maxReportBackoff, $backoff + $jitter))

            $currentUrl = Get-LocalCdpCurrentUrl

            if ($currentServerUrl) {
                $reply = Send-AgentReport -BaseUrl $currentServerUrl `
                            -Report (New-AgentReport -BaseUrl $currentServerUrl -BrowserRunning $browserAlive -CurrentUrl $currentUrl -Ack $null)

                if ($reply -and $reply.ok) {
                    if (-not $lastReportOk) {
                        Write-Host "Reporting to $currentServerUrl restored." -ForegroundColor Green
                    }
                    $lastReportOk   = $true
                    $reportFailures = 0
                    $ticksUntilReport = [Math]::Max(1, $ReportIntervalSec)

                    if ($reply.command -and $reply.command.cmd) {
                        $cmd   = [string]$reply.command.cmd
                        $nonce = [string]$reply.command.nonce
                        $delay = if ($reply.command.delaySec) { [int]$reply.command.delaySec } else { 5 }

                        if ($nonce -ne $script:LastCommandNonce) {
                            $script:LastCommandNonce = $nonce

                            # Acknowledge BEFORE acting: a reboot gives no second chance.
                            Send-AgentReport -BaseUrl $currentServerUrl -Report (
                                New-AgentReport -BaseUrl $currentServerUrl -BrowserRunning $browserAlive -CurrentUrl $currentUrl `
                                    -Ack @{ cmd = $cmd; nonce = $nonce; result = "ok" }
                            ) | Out-Null

                            Invoke-KioskCommand -Cmd $cmd -DelaySec $delay | Out-Null
                        }
                    }
                } else {
                    $reportFailures++
                    if ($lastReportOk) {
                        Write-Host "Cannot reach the VR HEADSET MANAGER server at $currentServerUrl - will keep retrying." -ForegroundColor Yellow
                        $lastReportOk = $false
                    }
                }
            }

            # ---- Sentinel fallback ----
            if ($currentUrl -and $currentUrl -match $sentinelPattern) {
                $sentinelBase  = $Matches[1]
                $sentinelCmd   = $Matches[2]
                $sentinelNonce = $Matches[3]

                if ($sentinelNonce -ne $script:LastCommandNonce) {
                    $script:LastCommandNonce = $sentinelNonce
                    if (-not $currentServerUrl) {
                        $currentServerUrl = $sentinelBase
                        Write-Host "Learned the VR HEADSET MANAGER server address: $currentServerUrl" -ForegroundColor Green
                    }
                    Write-Host "Command '$sentinelCmd' received on the fallback channel." -ForegroundColor Yellow
                    Invoke-KioskCommand -Cmd $sentinelCmd -DelaySec 5 | Out-Null
                }
            }
        }

        Start-Sleep -Seconds 1
    }
} finally {
    # Single cleanup path for every exit - Ctrl+C, remote agent-stop, and the
    # browser-watchdog give-up all reach here. Same end state as the operator
    # sending "Stop kiosk" from the server: browser closed, port forward and
    # firewall rules removed, window closes.
    Write-Host ""
    Write-Host "Kiosk agent stopping - cleaning up." -ForegroundColor Yellow
    Stop-ExistingKioskChrome
    Remove-DebugPortForward
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $ruleNameTcp  | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $ruleNameIcmp | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Write-Host "Done. Re-run this script to start the kiosk again." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}
