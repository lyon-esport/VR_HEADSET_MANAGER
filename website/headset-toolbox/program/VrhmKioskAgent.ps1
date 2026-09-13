<#
.SYNOPSIS
    Kiosk Agent - turns this PC into a Chrome kiosk screen managed by a
    VR HEADSET MANAGER server.

.DESCRIPTION
    Dot-sourced by Start-VrhmToolbox.ps1. Launches Chrome in kiosk mode with the
    DevTools port open, then reports to the server every few seconds and carries
    out the commands that ride back in the reply (reboot, shutdown,
    browser-restart, agent-stop).

    The agent NEVER listens on a port of its own: it only talks outbound, to its
    own loopback CDP endpoint and to the server. Commands come back inside the
    heartbeat reply. See ADR-0013 in the server project.

    Order of operations, deliberately:
      1. Chrome is located, and silently installed when missing.
      2. The firewall rules are created (only then - installing Chrome may need
         a reboot-free retry and there is no point opening ports before that).
      3. Chrome starts, the debug port is made reachable, the report loop runs.

.NOTES
    Ported from the former website\kiosk-launcher\Start-KioskAgent.ps1. Server
    discovery and self-elevation were removed: the toolbox resolves the server
    before calling in here, and it relaunches itself elevated for this step.
#>

$script:KioskAgentVersion = "2.0"

$script:KioskRuleNameBase = "_[VR_HEADSET_MANAGER]Kiosk_Allowed"
$script:KioskRuleNameTcp  = "$script:KioskRuleNameBase TCP [IN]"
$script:KioskRuleNameIcmp = "$script:KioskRuleNameBase ICMPv4 [IN]"

$script:KioskPort         = 9222
$script:KioskChromePath   = $null
$script:KioskUserDataDir  = Join-Path $env:LOCALAPPDATA "VRHM_KioskChrome"
$script:KioskUrl          = ""
$script:ChromeProcess     = $null
$script:KioskCleanupDone  = $false

# The default kiosk page: a self-contained waiting screen, so a kiosk with no
# URL pushed to it yet still shows something deliberate.
$script:KioskDefaultUrl = "data:text/html,%3Chtml%3E%3Chead%3E%3Cmeta%20charset%3D'utf-8'%3E%3Ctitle%3EKiosk%3C%2Ftitle%3E%3Cstyle%3Ehtml%2Cbody%7Bmargin%3A0%3Bheight%3A100%25%3Bbackground%3A%23000%3Bcolor%3A%23fff%3Bdisplay%3Aflex%3Balign-items%3Acenter%3Bjustify-content%3Acenter%3Bfont-family%3Asystem-ui%2Csans-serif%3Bflex-direction%3Acolumn%7Dh1%7Bfont-size%3A3vw%3Bletter-spacing%3A.08em%3Btext-transform%3Auppercase%3Bcolor%3A%23888%3Bmargin%3A0%7Dh2%7Bfont-size%3A5vw%3Bfont-weight%3A700%3Bmargin%3A12px%200%200%7D%3C%2Fstyle%3E%3C%2Fhead%3E%3Cbody%3E%3Ch1%3EKiosk%20Mode%3C%2Fh1%3E%3Ch2%3EReady%20to%20stream%3C%2Fh2%3E%3C%2Fbody%3E%3C%2Fhtml%3E"

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Chrome
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
    Write-Host "Please install Google Chrome manually, then start the kiosk again." -ForegroundColor Yellow
    Write-Host "Download page: https://www.google.com/chrome/" -ForegroundColor Yellow
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

function Resolve-KioskChrome {
    <#
    .SYNOPSIS
    Returns the path to chrome.exe, installing Chrome silently when it is not
    there yet. $null when Chrome could not be made available.
    #>
    param([string]$ChromePath = "")

    $resolved = Find-ChromeExe -ExplicitPath $ChromePath
    if ($resolved) { return $resolved }

    Write-Host "Google Chrome is required for kiosk mode and was not found on this PC." -ForegroundColor Yellow
    $choice = Read-Host "Install it now? [A] Auto-install (recommended) / [M] I will install it manually"

    if ($choice -notmatch '^(?i)m') {
        $installed = Install-ChromeSilently
        if (-not $installed) {
            Write-Host "Direct download install did not succeed. Trying winget..." -ForegroundColor Yellow
            $installed = Install-ChromeViaWinget
        }
        if ($installed) {
            $resolved = Find-ChromeExe -ExplicitPath $ChromePath
        }
        if ($resolved) { return $resolved }
        Write-Host "Automatic install did not succeed." -ForegroundColor Red
    }

    Show-ManualInstallInstructions
    return $null
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

function Test-FirewallEnabled {
    <#
    .SYNOPSIS
    $true when at least one firewall profile is on. When the firewall is off
    there is nothing to open, so the rules are skipped entirely.
    #>
    try {
        return [bool](@(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.Enabled }).Count -gt 0)
    } catch {
        # Unreadable state: assume it is on, creating the rules is harmless.
        return $true
    }
}

function Add-KioskFirewallRules {
    <#
    .SYNOPSIS
    Opens the Chrome debug port and inbound ping, so the server's reachability
    check can reach this PC.
    #>
    param([int]$Port)

    if (-not (Test-FirewallEnabled)) {
        Write-Host "Windows Firewall is disabled on every profile - no rule needed." -ForegroundColor DarkGray
        return
    }

    Get-NetFirewallRule -DisplayName "VRHM Kiosk Chrome Debug $Port" -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    # -DisplayName on Get-NetFirewallRule treats its value as a wildcard pattern, and "[" / "]"
    # are wildcard character-class metacharacters - passing the rule names there directly never
    # matches their own literal brackets, so the exists-check always says "not found" and the
    # rule gets recreated (and never found again for removal) on every run. Fetching all rules
    # and filtering with -eq does a real literal comparison instead.
    if (-not (Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $script:KioskRuleNameTcp)) {
        Write-Host "Adding firewall rule '$script:KioskRuleNameTcp' for TCP port $Port..." -ForegroundColor Cyan
        New-NetFirewallRule -DisplayName $script:KioskRuleNameTcp `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $Port `
            -Action Allow `
            -Profile Any `
            -Description "Allow VR Headset Manager to reach this kiosk's Chrome remote debugging port" | Out-Null
    } else {
        Write-Host "Firewall rule '$script:KioskRuleNameTcp' already exists - skipping." -ForegroundColor DarkGray
    }

    if (-not (Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $script:KioskRuleNameIcmp)) {
        Write-Host "Adding firewall rule '$script:KioskRuleNameIcmp' for inbound ping..." -ForegroundColor Cyan
        New-NetFirewallRule -DisplayName $script:KioskRuleNameIcmp `
            -Direction Inbound `
            -Protocol ICMPv4 `
            -IcmpType 8 `
            -Action Allow `
            -Profile Any `
            -Description "Allow VR Headset Manager to ping this kiosk for reachability checks" | Out-Null
    } else {
        Write-Host "Firewall rule '$script:KioskRuleNameIcmp' already exists - skipping." -ForegroundColor DarkGray
    }
}

function Remove-KioskFirewallRules {
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $script:KioskRuleNameTcp  | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $script:KioskRuleNameIcmp | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Browser lifecycle
# ---------------------------------------------------------------------------

function Stop-ExistingKioskChrome {
    # Chrome refuses a second remote-debugging listener on the same port, so any
    # previous instance using it has to go first.
    $portMarker = "--remote-debugging-port=$script:KioskPort"
    $existingChrome = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$portMarker*" }

    if ($existingChrome) {
        Write-Host "Closing previous kiosk Chrome instance on port $script:KioskPort..." -ForegroundColor Yellow
        foreach ($proc in $existingChrome) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}

function Start-KioskBrowser {
    param([string]$StartUrl)

    $userDataDir = $script:KioskUserDataDir
    if (-not (Test-Path -LiteralPath $userDataDir)) {
        New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
    }

    # When Chrome is closed via the CDP "Browser.close" call instead of
    # Stop-Process, it can leave this profile's Singleton* lock files behind. A
    # later launch then silently hands off to (or is blocked by) that stale lock
    # instead of starting a genuinely fresh, debug-enabled process - Chrome opens
    # and the kiosk display looks fine, but the new debug listener never actually
    # comes up, so the server can no longer reach it.
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
            $prefsRaw  = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8
            $prefsJson = $prefsRaw | ConvertFrom-Json
            if ($prefsJson.profile) {
                $prefsJson.profile.exit_type      = "Normal"
                $prefsJson.profile.exited_cleanly = $true
                ($prefsJson | ConvertTo-Json -Depth 100 -Compress) | Set-Content -LiteralPath $prefsPath -Encoding UTF8 -NoNewline
            }
        } catch {
            Write-Host "Could not clear crash state in Chrome profile Preferences - the restore-pages popup may appear." -ForegroundColor Yellow
        }
    }

    $chromeArgs = @(
        "--remote-debugging-port=$script:KioskPort",
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

    Write-Host "Starting Chrome in kiosk mode with debug port $script:KioskPort..." -ForegroundColor Cyan
    return (Start-Process -FilePath $script:KioskChromePath -ArgumentList $chromeArgs -PassThru)
}

function Remove-DebugPortForward {
    # Both families, because the forward may have been created either way - see
    # Update-DebugPortForward. Deleting one that does not exist is harmless.
    $port = $script:KioskPort
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port 2>&1 | Out-Null
    netsh interface portproxy delete v4tov6 listenaddress=0.0.0.0 listenport=$port 2>&1 | Out-Null
}

function Update-DebugPortForward {
    <#
        Recent Chrome releases silently ignore "--remote-debugging-address" and
        hard-lock the DevTools listener to 127.0.0.1, with no reliable way to opt
        back in from the command line. When that happens, fall back to an OS-level
        port forward that relays the kiosk's real IP:Port through to the loopback
        listener Chrome already has open.
    #>
    $port = $script:KioskPort

    Write-Host "Verifying the debug port is reachable from the network..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    # EVERY listener, not just the first one. Chrome may bind IPv4 loopback, IPv6
    # loopback, or both, and the order Get-NetTCPConnection returns them in is not
    # meaningful - taking [0] and testing it against "127.0.0.1" reported a kiosk
    # bound to ::1 as "already reachable from the LAN", skipped the forward, and
    # left the server showing "Chrome debug closed" with the kiosk looking
    # perfectly fine on its own screen. Observed on Chrome 152, which binds ::1
    # ONLY - not 127.0.0.1 - so even a v4tov4 forward to 127.0.0.1 would have had
    # nothing to connect to.
    $listeners      = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    $nonLoopback    = @($listeners | Where-Object { $_.LocalAddress -ne '::1' -and $_.LocalAddress -notlike '127.*' })
    $hasV4Loopback  = [bool](@($listeners | Where-Object { $_.LocalAddress -like '127.*' }).Count)
    $hasV6Loopback  = [bool](@($listeners | Where-Object { $_.LocalAddress -eq '::1' }).Count)

    # Always clear any previous rule for this port first, so repeated relaunches
    # stay idempotent and never stack rules.
    Remove-DebugPortForward

    if ($listeners.Count -gt 0 -and $nonLoopback.Count -eq 0) {
        $boundTo = (($listeners | ForEach-Object { $_.LocalAddress }) -join ', ')
        Write-Host "Chrome is only listening on loopback ($boundTo):$port - this Chrome build ignored the LAN binding." -ForegroundColor Yellow

        # netsh portproxy is implemented by the "IP Helper" service (iphlpsvc) - if it is not
        # running, "netsh ... add" and "show v4tov4" both succeed and report the mapping, but
        # no listener is ever actually bound to the external interface, so the kiosk silently
        # stays unreachable from the LAN.
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

        # The forward has to target the family Chrome ACTUALLY bound. A v4tov4
        # forward to 127.0.0.1 is useless when Chrome only listens on ::1 - netsh
        # accepts it, the table shows it, and every connection is refused.
        # IPv4 loopback wins when both are present: it is the older, better-tested
        # path through iphlpsvc.
        if ($hasV4Loopback) {
            $family  = 'v4tov4'
            $connect = '127.0.0.1'
        } elseif ($hasV6Loopback) {
            $family  = 'v4tov6'
            $connect = '::1'
        } else {
            $family  = 'v4tov4'
            $connect = '127.0.0.1'
        }

        Write-Host "Setting up a port forward ($family -> ${connect}:$port) so the LAN can still reach the debug port..." -ForegroundColor Yellow
        netsh interface portproxy add $family listenaddress=0.0.0.0 listenport=$port connectaddress=$connect connectport=$port | Out-Null

        Start-Sleep -Seconds 1
        # Confirm an actual listening socket on the external interface rather than trusting the
        # portproxy config table, which reports the mapping regardless of whether iphlpsvc could
        # bind it (see above).
        $externalListener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -ne '::1' -and $_.LocalAddress -notlike '127.*' } | Select-Object -First 1
        if ($externalListener) {
            Write-Host "Port forward active: $($externalListener.LocalAddress):$port -> ${connect}:$port" -ForegroundColor Green
        } else {
            Write-Host "Port forward was configured but no external listener came up - the kiosk will NOT be reachable from the LAN." -ForegroundColor Red
            Write-Host "Check 'Get-Service iphlpsvc' and 'netsh interface portproxy show all' on this PC." -ForegroundColor Red
        }
    } elseif ($listeners.Count -gt 0) {
        Write-Host "Chrome is listening on $($nonLoopback[0].LocalAddress):$port - already reachable from the LAN." -ForegroundColor Green
    } else {
        Write-Host "Could not confirm Chrome is listening on port $port yet." -ForegroundColor Yellow
    }
}

function Restart-KioskBrowser {
    param([string]$Reason = "operator request")

    Write-Host "Restarting the kiosk browser ($Reason)..." -ForegroundColor Yellow
    Remove-DebugPortForward
    Stop-ExistingKioskChrome
    $script:ChromeProcess = Start-KioskBrowser -StartUrl $script:KioskUrl
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

function Stop-VrhmKioskAgent {
    <#
    .SYNOPSIS
    The single cleanup path: closes the kiosk browser, removes the port forward
    and deletes both firewall rules. Idempotent, so Ctrl+C, a remote agent-stop
    and the exit handler can all call it.
    #>
    if ($script:KioskCleanupDone) { return }
    $script:KioskCleanupDone = $true
    try { Stop-ExistingKioskChrome } catch { }
    try { Remove-DebugPortForward } catch { }
    try { Remove-KioskFirewallRules } catch { }
}

# ---------------------------------------------------------------------------
# Local machine facts
# ---------------------------------------------------------------------------

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
        $ipCfg   = Get-NetIPAddress -IPAddress $localIp -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
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
        }
    } catch {
        # Leave Type as Unknown - a missing link type must never stop a report.
    }

    $script:InterfaceCache[$localIp] = $result
    return $result
}

$script:CdpLoopbackBase = $null

function Get-CdpLoopbackBase {
    <#
    .SYNOPSIS
    The loopback base URL Chrome's DevTools endpoint actually answers on, or
    $null when it answers on neither.

    .DESCRIPTION
    Not always 127.0.0.1: Chrome 152 binds IPv6 loopback (::1) ONLY. Hardcoding
    the v4 address made every local CDP call fail, so the watchdog saw a dead
    browser and the agent reported no current URL - which is what the server
    displays as "Chrome debug closed" even though the kiosk is running fine on
    its own screen.

    The working base is cached and only re-probed when it stops answering, so
    the once-per-second watchdog stays a single request.
    #>
    $port = $script:KioskPort

    if ($script:CdpLoopbackBase) {
        try {
            Invoke-RestMethod -Uri "$script:CdpLoopbackBase/json/version" -Method GET -TimeoutSec 2 -ErrorAction Stop | Out-Null
            return $script:CdpLoopbackBase
        } catch {
            $script:CdpLoopbackBase = $null
        }
    }

    foreach ($candidate in @("http://127.0.0.1:$port", "http://[::1]:$port")) {
        try {
            Invoke-RestMethod -Uri "$candidate/json/version" -Method GET -TimeoutSec 2 -ErrorAction Stop | Out-Null
            $script:CdpLoopbackBase = $candidate
            return $candidate
        } catch { }
    }
    return $null
}

function Get-LocalCdpVersion {
    $base = Get-CdpLoopbackBase
    if (-not $base) { return $null }
    try {
        $resp = Invoke-RestMethod -Uri "$base/json/version" -Method GET -TimeoutSec 2 -ErrorAction Stop
        return $resp.Browser
    } catch {
        return $null
    }
}

function Get-LocalCdpCurrentUrl {
    $base = Get-CdpLoopbackBase
    if (-not $base) { return $null }
    try {
        $tabs = Invoke-RestMethod -Uri "$base/json/list" -Method GET -TimeoutSec 2 -ErrorAction Stop
        $tab  = @($tabs) | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        if ($tab) { return $tab.url }
        return $null
    } catch {
        return $null
    }
}

function Get-ChromeFileVersion {
    try {
        return "Chrome/" + [System.Diagnostics.FileVersionInfo]::GetVersionInfo($script:KioskChromePath).FileVersion
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Talking to the server
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
        A timeout here is expected occasionally and must not be treated as fatal.
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
        version            = $script:KioskAgentVersion
        machineId          = $script:MachineId
        hostname           = $env:COMPUTERNAME
        os                 = $script:OsDescription
        osFamily           = "Windows"
        interfaceType      = $iface.Type
        interfaceName      = $iface.Name
        linkSpeedMbps      = $iface.SpeedMbps
        browser            = $browser
        browserRunning     = $BrowserRunning
        cdpPort            = $script:KioskPort
        currentUrl         = $CurrentUrl
        uptimeSec          = [int64]((Get-Date) - $script:StartedAt).TotalSeconds
        autoRestartBrowser = $script:AutoRestartBrowser
    }
    if ($Ack) { $report.ack = $Ack }
    return $report
}

function Show-ShutdownWarning {
    <#
    .SYNOPSIS
    Prints the impossible-to-miss banner that tells whoever is standing in front
    of this PC that it is about to power off or restart.
    #>
    param([string]$Action, [int]$DelaySec)

    $minutes = [Math]::Round($DelaySec / 60.0, 1)
    Write-Host ""
    Write-Host "***********************************************************" -ForegroundColor Red
    if ($Action -eq 'reboot') {
        Write-Host ("  THIS COMPUTER WILL RESTART IN {0} SECOND(S)" -f $DelaySec) -ForegroundColor Red
    } else {
        Write-Host ("  THIS COMPUTER WILL SHUT DOWN IN {0} SECOND(S)" -f $DelaySec) -ForegroundColor Red
    }
    Write-Host ("  (about {0} minute(s)) - ordered by VR HEADSET MANAGER." -f $minutes) -ForegroundColor Red
    Write-Host "  Save your work now." -ForegroundColor Red
    Write-Host "***********************************************************" -ForegroundColor Red
    Write-Host ""
}

function Invoke-KioskCommand {
    <#
        Executes one operator command. The caller has already acknowledged it to
        the server - deliberately, because a reboot leaves no opportunity to do so
        afterwards.
    #>
    param(
        [string]$Cmd,
        [int]$DelaySec = 60
    )

    # A person may be standing in front of this screen, so a power action always
    # gets a full minute of warning even if the server asked for less.
    $powerDelay = [Math]::Max(60, $DelaySec)

    switch ($Cmd) {
        'reboot' {
            Show-ShutdownWarning -Action 'reboot' -DelaySec $powerDelay
            Stop-VrhmKioskAgent
            & shutdown.exe /r /t $powerDelay /c "Reboot ordered by VR HEADSET MANAGER"
            return $true
        }
        'shutdown' {
            Show-ShutdownWarning -Action 'shutdown' -DelaySec $powerDelay
            Stop-VrhmKioskAgent
            & shutdown.exe /s /t $powerDelay /c "Shutdown ordered by VR HEADSET MANAGER"
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
# The agent
# ---------------------------------------------------------------------------

function Start-VrhmKioskAgent {
    <#
    .SYNOPSIS
    Runs the kiosk agent until the operator stops it (Ctrl+C), the server sends
    agent-stop, or the browser dies with auto-restart disabled.

    .EXAMPLE
    Start-VrhmKioskAgent -ServerUrl 'http://192.168.1.37:8080'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ServerUrl,
        [int]$Port = 9222,
        [string]$Url = "",
        [int]$ReportIntervalSec = 5,
        [string]$ChromePath = "",
        [switch]$NoAutoRestartBrowser
    )

    $script:KioskPort          = $Port
    $script:KioskUrl           = if ($Url) { $Url } else { $script:KioskDefaultUrl }
    $script:AutoRestartBrowser = (-not $NoAutoRestartBrowser.IsPresent)
    $script:KioskCleanupDone   = $false

    # 1. Chrome first - there is no point opening firewall ports for a browser
    #    that is not installed.
    $script:KioskChromePath = Resolve-KioskChrome -ChromePath $ChromePath
    if (-not $script:KioskChromePath) {
        Write-Host "Kiosk mode cannot start without Google Chrome." -ForegroundColor Red
        return
    }
    Write-Host "Chrome found at: $script:KioskChromePath" -ForegroundColor Green

    # 2. Firewall.
    Add-KioskFirewallRules -Port $Port

    # 3. Browser + agent loop.
    Stop-ExistingKioskChrome
    $script:ChromeProcess = Start-KioskBrowser -StartUrl $script:KioskUrl
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
    Write-Host "Server        : $ServerUrl (reporting every ${ReportIntervalSec}s)" -ForegroundColor DarkGray
    if ($script:AutoRestartBrowser) {
        Write-Host "Browser watch : auto-restart enabled" -ForegroundColor DarkGray
    } else {
        Write-Host "Browser watch : auto-restart DISABLED" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Agent running. Close the app by pressing Ctrl + C at any time." -ForegroundColor DarkGray
    Write-Host ""

    $ticksUntilReport = 0
    $reportFailures   = 0
    $lastReportOk     = $true
    $browserDeadSince = $null
    $maxReportBackoff = 60
    $currentServerUrl = $ServerUrl

    # Sentinel fallback: defense-in-depth for the case reporting is failing (the
    # server moved, say) - a page pushed to this screen over CDP still carries a
    # command, and matching its URL re-teaches us the server address too.
    $sentinelPattern = '(?i)^(https?://[^/]+)/kiosk_command\.html\?.*\bcmd=([a-z\-]+).*\bnonce=(\d+)'

    try {
        while ($true) {
            if ($script:AgentStopRequested) { break }

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
                if (-not $script:AutoRestartBrowser) {
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
                $jitter  = if ($reportFailures -gt 0) { Get-Random -Minimum 0 -Maximum 4 } else { 0 }
                $ticksUntilReport = [int]([Math]::Min($maxReportBackoff, $backoff + $jitter))

                $currentUrl = Get-LocalCdpCurrentUrl

                if ($currentServerUrl) {
                    $reply = Send-AgentReport -BaseUrl $currentServerUrl `
                                -Report (New-AgentReport -BaseUrl $currentServerUrl -BrowserRunning $browserAlive -CurrentUrl $currentUrl -Ack $null)

                    if ($reply -and $reply.ok) {
                        if (-not $lastReportOk) {
                            Write-Host "Reporting to $currentServerUrl restored." -ForegroundColor Green
                        }
                        $lastReportOk     = $true
                        $reportFailures   = 0
                        $ticksUntilReport = [Math]::Max(1, $ReportIntervalSec)

                        if ($reply.command -and $reply.command.cmd) {
                            $cmd   = [string]$reply.command.cmd
                            $nonce = [string]$reply.command.nonce
                            $delay = if ($reply.command.delaySec) { [int]$reply.command.delaySec } else { 60 }

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
                        Invoke-KioskCommand -Cmd $sentinelCmd -DelaySec 60 | Out-Null
                    }
                }
            }

            Start-Sleep -Seconds 1
        }
    } finally {
        Write-Host ""
        Write-Host "Kiosk agent stopping - cleaning up." -ForegroundColor Yellow
        Stop-VrhmKioskAgent
        Write-Host "Done." -ForegroundColor DarkGray
    }
}
