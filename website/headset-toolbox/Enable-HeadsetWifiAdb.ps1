<#
.SYNOPSIS
    Standalone tool: enables WiFi ADB on a USB-connected Meta Quest / Pico
    headset, then registers it with a VR HEADSET MANAGER server over the LAN.

.DESCRIPTION
    Run this on a technician's PC - NOT on the VR HEADSET MANAGER server itself.
    It waits for a headset to be plugged in via USB, then for each one it finds:
      1. Detect the USB-connected headset via the bundled adb.exe.
      2. Read its serial number, brand and model.
      3. Force the headset to reconnect to its WiFi network using its real
         (non-randomized) MAC address, so its IP address stays stable across
         reconnects/reboots. Prompts once per WiFi network for the password
         (leave blank to skip this step).
      4. Switch it into WiFi ADB mode (adb tcpip <port>) and read its WiFi IP.
      5. Confirm the WiFi ADB session actually comes up (adb connect).
      6. Ask you to confirm a display name, then tell the VR HEADSET MANAGER
         server to add this headset (if new) or update its IP address (if a
         headset with this serial number is already known).
    Once done with a headset, it goes back to waiting so the next one can be
    unplugged and plugged in without relaunching the tool. Press Ctrl+C (or
    close the console window) to stop.

    This script does not depend on any other file from the VR HEADSET MANAGER
    project - it is meant to be copied (with its bundled adb.exe) and run
    standalone on a separate PC. It ships embedded inside the portable
    Start-HeadsetToolbox.exe (self-extracted next to itself on first run),
    part of the VRHM-Headset-Toolbox.zip downloadable from the VR HEADSET
    MANAGER web interface. No server address is ever baked into anything -
    it is fully self-discovering, see Resolve-VrhmServerUrl below.

.PARAMETER ServerUrl
    Base URL of the VR HEADSET MANAGER server, e.g. "http://192.168.1.37:8080".
    Optional manual override/starting point. If it does not answer, or if
    omitted entirely, the script falls back to the last server it successfully
    talked to (the shared cache file - see -ServerCachePath), then to scanning
    the LAN for one.

.PARAMETER ServerPort
    TCP port the VR HEADSET MANAGER web server listens on. Defaults to 8080.
    Used for the LAN scan when no server has been confirmed reachable yet.

.PARAMETER ServerCachePath
    Full path of the shared vrhm_server_cache.json file this tool reads and
    writes the last-known server address to. Defaults to a file named
    vrhm_server_cache.json next to this script. Start-HeadsetToolbox.exe
    overrides this to a single cache file shared with the other toolbox tools
    (Start-Kiosk-Agent.exe, Find-VRHM-Server.exe) at the root of the extracted
    toolbox folder, so finding the server with any one tool benefits the rest.

.PARAMETER AdbPort
    TCP port to use for WiFi ADB. Defaults to 5555 (the project's standard).

.EXAMPLE
    .\Enable-HeadsetWifiAdb.ps1 -ServerUrl "http://192.168.1.37:8080"

.EXAMPLE
    .\Enable-HeadsetWifiAdb.ps1
    Finds the VR HEADSET MANAGER server on its own (cache, then LAN scan).

.NOTES
    Safe to run repeatedly / leave running. Requires adb.exe (bundled alongside
    this script) and a headset connected via USB with USB Debugging authorized.
#>

[CmdletBinding()]
param(
    [string]$ServerUrl = "",

    [int]$ServerPort = 8080,

    [string]$ServerCachePath = "",

    [int]$AdbPort = 5555
)

function Write-Info { param([string]$Message) Write-Host $Message }
function Write-Ok   { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn2 { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err2 { param([string]$Message) Write-Host $Message -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Server discovery - find the VR HEADSET MANAGER server on the LAN when the
# baked-in/-passed -ServerUrl does not answer, so this tool keeps working
# after a DHCP change on either side. Ported from (and should be kept in sync
# with) the same block in website\kiosk-launcher\Start-KioskAgent.ps1 -
# duplicated here rather than shared via a module, matching this script's own
# "no dependency on any other project file" design.
# ---------------------------------------------------------------------------

function Get-VrhmServerCachePath {
    if ($ServerCachePath) { return $ServerCachePath }
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
    <#
    .SYNOPSIS
    Returns $true only when the given address is genuinely a VR HEADSET
    MANAGER server - not just any web server answering on that port.
    #>
    param([string]$IPAddress, [int]$Port, [int]$TimeoutSec = 2)
    try {
        $uri = "http://${IPAddress}:${Port}/api/version"
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
        return [bool]($response -and $response.app -eq 'VRHM')
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

    Write-Info "Scanning $($allIps.Count) address(es) on port $Port for a VR HEADSET MANAGER server..."
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
        Write-Warn2 "Found multiple VR HEADSET MANAGER servers on the network: $($found -join ', ') - using $($found[0])."
    }
    return @{ IPAddress = $found[0]; Port = $Port }
}

function Resolve-VrhmServerUrl {
    <#
    .SYNOPSIS
    Cascade: explicit -ServerUrl (verified) > cached last-known server
    (verified) > LAN scan > a blocking console menu (retry the scan, type an
    IP manually, or Ctrl+C to give up). Always returns a URL or never returns
    at all (the operator closed the script) - callers never need to handle a
    $null server address. Every candidate is confirmed via Test-VrhmServerAt
    before being trusted, so an unrelated web server on the same port is
    never mistaken for the VR HEADSET MANAGER server.
    #>
    param([string]$ServerUrl, [int]$ServerPort)

    if ($ServerUrl -and $ServerUrl -match '^https?://([^:/]+)(?::(\d+))?') {
        $candidateIp   = $Matches[1]
        $candidatePort = if ($Matches[2]) { [int]$Matches[2] } else { $ServerPort }
        if (Test-VrhmServerAt -IPAddress $candidateIp -Port $candidatePort) {
            Write-VrhmServerCache -IPAddress $candidateIp -Port $candidatePort
            return "http://${candidateIp}:${candidatePort}"
        }
        Write-Warn2 "The server address baked into this toolbox ($ServerUrl) did not answer - looking for another one..."
    }

    $cached = Read-VrhmServerCache
    if ($cached -and (Test-VrhmServerAt -IPAddress $cached.IPAddress -Port $cached.Port)) {
        Write-Ok "Using the last known VR HEADSET MANAGER server at $($cached.IPAddress):$($cached.Port)."
        return "http://$($cached.IPAddress):$($cached.Port)"
    }

    while ($true) {
        $found = Find-VrhmServerOnLan -Port $ServerPort
        if ($found) {
            Write-Ok "Found VR HEADSET MANAGER server at $($found.IPAddress):$($found.Port)."
            Write-VrhmServerCache -IPAddress $found.IPAddress -Port $found.Port
            return "http://$($found.IPAddress):$($found.Port)"
        }

        Write-Info ""
        Write-Warn2 "No VR HEADSET MANAGER server was found on the network."
        Write-Info "  [R] Restart the search"
        Write-Info "  [I] Enter the server IP manually"
        Write-Info "  Ctrl+C to stop this script"
        $choice = Read-Host "Choice"

        if ($choice -match '^(?i)i') {
            $manualIp = Read-Host "Server IP address"
            if ($manualIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                if (Test-VrhmServerAt -IPAddress $manualIp -Port $ServerPort) {
                    Write-VrhmServerCache -IPAddress $manualIp -Port $ServerPort
                    return "http://${manualIp}:${ServerPort}"
                }
                Write-Err2 "No VR HEADSET MANAGER server answered at ${manualIp}:${ServerPort}."
            } else {
                Write-Err2 "'$manualIp' is not a valid IPv4 address."
            }
        }
        # [R], or any other input, or empty input -> restart the search
    }
}

function Set-CurrentServerUrl {
    param([string]$Url)
    $script:CurrentServerUrl = $Url
    if ($Url -match '^https?://([^:/]+)(?::(\d+))?') {
        $script:CurrentServerIp   = $Matches[1]
        $script:CurrentServerPort = if ($Matches[2]) { [int]$Matches[2] } else { $ServerPort }
    }
}

function Get-CurrentServerUrl {
    <#
    .SYNOPSIS
    Returns the currently resolved server URL, re-running the discovery
    cascade first if it has stopped answering since it was last resolved
    (e.g. the server's IP changed mid-session). Called before every headset
    registration so a long-running toolbox session self-heals without a
    restart.
    #>
    if (Test-VrhmServerAt -IPAddress $script:CurrentServerIp -Port $script:CurrentServerPort) {
        return $script:CurrentServerUrl
    }
    Write-Warn2 "The VR HEADSET MANAGER server at $script:CurrentServerUrl is no longer reachable - looking for it again..."
    Set-CurrentServerUrl -Url (Resolve-VrhmServerUrl -ServerUrl '' -ServerPort $script:CurrentServerPort)
    return $script:CurrentServerUrl
}

$adbPath = Join-Path $PSScriptRoot 'adb.exe'
if (-not (Test-Path -LiteralPath $adbPath)) {
    Write-Err2 "adb.exe not found next to this script ($adbPath)."
    Write-Err2 "Re-download the Remote Headset Toolbox package from VR HEADSET MANAGER."
    exit 1
}

$script:AdbServerStopped = $false
function Stop-ToolboxAdbServer {
    if ($script:AdbServerStopped) { return }
    $script:AdbServerStopped = $true
    try { & $adbPath kill-server 2>$null | Out-Null } catch {}
}

[Console]::add_CancelKeyPress({ Stop-ToolboxAdbServer })
Register-EngineEvent -SupportEvent -SourceIdentifier PowerShell.Exiting -Action { Stop-ToolboxAdbServer } | Out-Null

function Invoke-AdbLine {
    <#
    .SYNOPSIS
    Runs "adb -s <serial> <args>" and returns trimmed stdout as a single string.
    Returns an empty string on a non-zero exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$Arguments
    )
    $argList = @('-s', $Serial) + ($Arguments -split '\s+')
    $out = & $adbPath @argList 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out -join "`n").Trim())
}

function Get-UsbHeadsetLines {
    <#
    .SYNOPSIS
    Returns the "adb devices" lines for authorized, USB-connected devices
    (no ":" in the identifier - that would be a WiFi ADB connection).
    #>
    $devicesOutput = & $adbPath devices 2>$null
    return @($devicesOutput | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' })
}

function Wait-ForUsbHeadset {
    <#
    .SYNOPSIS
    Blocks, polling every 2 seconds, until a USB-connected headset is found.
    Returns its serial number.
    #>
    $dots = 0
    while ($true) {
        $line = Get-UsbHeadsetLines | Select-Object -First 1
        if ($line) {
            Write-Host ""
            return ($line -split "`t")[0].Trim()
        }
        $dots = ($dots % 3) + 1
        Write-Host -NoNewline ("`rWaiting for a USB-connected headset" + ('.' * $dots) + '   ')
        Start-Sleep -Seconds 2
    }
}

function Wait-ForUsbHeadsetRemoved {
    <#
    .SYNOPSIS
    Blocks, polling every 2 seconds, until the given serial no longer shows up
    as a USB-connected device (i.e. it was unplugged, or switched fully to WiFi).
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)
    while ($true) {
        $stillPresent = Get-UsbHeadsetLines | Where-Object { ($_ -split "`t")[0].Trim() -eq $Serial }
        if (-not $stillPresent) { return }
        Start-Sleep -Seconds 2
    }
}

$script:WifiPasswordCache = @{}

function ConvertFrom-SecureStringPlain {
    <#
    .SYNOPSIS
    Converts a SecureString (from Read-Host -AsSecureString) back to plain text.
    Needed because the WiFi password has to be embedded in cleartext in the adb
    shell command sent to the headset - there is no way around that here.
    #>
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-HeadsetWifiInfo {
    <#
    .SYNOPSIS
    Returns @{Ssid; Mac} for the headset's current WiFi connection (each is ''
    if not found).

    .DESCRIPTION
    Both come from a single "cmd wifi status" call. The MAC is read from there
    rather than /sys/class/net/wlan0/address or "ip link show wlan0" - both of
    those return "Permission denied" for the shell user on current Quest
    firmware, while "cmd wifi status" (backed by the WiFi system service, not a
    direct netlink/sysfs read) reports it in its "MAC: aa:bb:cc:dd:ee:ff" field.
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)

    $result = [PSCustomObject]@{ Ssid = ''; Mac = '' }
    $status = Invoke-AdbLine -Serial $Serial -Arguments 'shell cmd wifi status'

    if ($status -match '\bssid="([^"]+)"') {
        $result.Ssid = $Matches[1]
    } elseif ($status -match '\bSSID:\s*"([^"]+)"') {
        $result.Ssid = $Matches[1]
    }
    if ($status -match '\bMAC:\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})') {
        $result.Mac = $Matches[1]
    }

    if (-not $result.Ssid) {
        $dump = Invoke-AdbLine -Serial $Serial -Arguments 'shell dumpsys wifi'
        if ($dump -match '\bSSID:\s+"([^"]+)"') { $result.Ssid = $Matches[1] }
    }

    return $result
}

function Test-MacIsRandomized {
    <#
    .SYNOPSIS
    Returns $true if the given MAC address is a randomized (locally-administered)
    one, $false if it looks like a real hardware MAC, or $null if unparsable.

    .DESCRIPTION
    Per IEEE 802, the second-least-significant bit of the first octet (the
    "U/L bit", mask 0x02) is 0 for a globally-unique hardware MAC and 1 for a
    locally-administered one - which is exactly how Android marks the MAC
    addresses it randomizes.
    #>
    param([Parameter(Mandatory = $true)][string]$Mac)

    if ($Mac -notmatch '^([0-9a-fA-F]{2}):') { return $null }
    $firstOctet = [Convert]::ToInt32($Matches[1], 16)
    return (($firstOctet -band 0x02) -ne 0)
}

function Get-HeadsetWifiIp {
    <#
    .SYNOPSIS
    Polls the headset's wlan0 IP address, retrying for a few seconds - a WiFi
    reconnect (e.g. after forcing the real MAC address) needs a moment to settle.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [int]$MaxAttempts = 15,
        [int]$DelaySeconds = 1
    )
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        $ipOutput = Invoke-AdbLine -Serial $Serial -Arguments 'shell ip -f inet addr show wlan0'
        if ($ipOutput -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') { return $Matches[1] }
        Start-Sleep -Seconds $DelaySeconds
    }
    return ''
}

function Set-HeadsetRealMacAddress {
    <#
    .SYNOPSIS
    Forces the headset to reconnect to the given SSID using its real (non-random)
    WiFi MAC address, so its IP address stays stable across reconnects/reboots
    instead of Android's default per-network randomized MAC. Requires the WiFi
    password - prompted once per SSID per run and cached for the rest of the
    session (leave blank to skip this step for that network).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$Ssid,
        [string]$CurrentMac = ''
    )

    if ($CurrentMac -and (Test-MacIsRandomized -Mac $CurrentMac) -eq $false) {
        Write-Ok "Headset is already using its real WiFi MAC address ($CurrentMac) on '$Ssid' - no fix needed."
        return
    }

    if (-not $script:WifiPasswordCache.ContainsKey($Ssid)) {
        Write-Info ""
        Write-Info "Headset is on WiFi network '$Ssid'. To keep its IP address stable, it should use its real WiFi MAC address instead of Android's randomized one."
        $secure = Read-Host -AsSecureString -Prompt "WiFi password for '$Ssid' (leave blank to skip this step)"
        $script:WifiPasswordCache[$Ssid] = ConvertFrom-SecureStringPlain -Secure $secure
    }

    $password = $script:WifiPasswordCache[$Ssid]
    if (-not $password) {
        Write-Warn2 "Skipping the MAC address fix - this headset's IP address may change on its next reconnect."
        return
    }

    Write-Info "Forcing the headset to reconnect to '$Ssid' using its real MAC address..."
    $out = Invoke-AdbLine -Serial $Serial -Arguments "shell cmd -w wifi connect-network `"$Ssid`" wpa2 `"$password`" -r none"
    if ($out -match '(?i)error|failed|unknown') {
        Write-Warn2 "Could not force the real MAC address (headset reported: $out). Continuing with the current connection."
        return
    }
    Start-Sleep -Seconds 3
}

function Get-KnownHeadsetBySerial {
    <#
    .SYNOPSIS
    Looks up this serial number in the VR HEADSET MANAGER server's known
    headsets (GET /api/headsets). Returns the matching entry, or $null if not
    found or the server could not be reached.
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)

    try {
        $headsets = Invoke-RestMethod -Uri ("{0}/api/headsets" -f (Get-CurrentServerUrl).TrimEnd('/')) -Method Get -TimeoutSec 10
    } catch {
        return $null
    }
    if (-not $headsets) { return $null }
    return @($headsets) | Where-Object { $_.SerialNumber -eq $Serial } | Select-Object -First 1
}

function Invoke-HeadsetRegistration {
    <#
    .SYNOPSIS
    Runs the full detect -> WiFi ADB -> register sequence for one already-detected
    USB serial number. Reports its own errors and returns - never exits the script.
    #>
    param([Parameter(Mandatory = $true)][string]$Serial)

    Write-Ok "USB headset detected (serial: $Serial)."

    $manufacturer = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop ro.product.manufacturer'
    $model = ''
    if ($manufacturer -match '(?i)pico') {
        $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop pxr.vendorhw.product.model'
        if (-not $model) { $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop sys.pxr.product.name' }
        if (-not $model) { $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop ro.product.model' }
    } else {
        $model = Invoke-AdbLine -Serial $Serial -Arguments 'shell getprop ro.product.model'
    }
    if (-not $model) { $model = 'Unknown model' }
    Write-Info "Model: $model"

    $wifiInfo = Get-HeadsetWifiInfo -Serial $Serial
    if ($wifiInfo.Ssid) {
        Write-Info "Connected to WiFi network: $($wifiInfo.Ssid)"
        Set-HeadsetRealMacAddress -Serial $Serial -Ssid $wifiInfo.Ssid -CurrentMac $wifiInfo.Mac
    } else {
        Write-Warn2 "Could not determine the headset's WiFi network name - skipping the MAC address fix."
    }

    Write-Info "Enabling WiFi ADB (tcpip $AdbPort)..."
    Invoke-AdbLine -Serial $Serial -Arguments "tcpip $AdbPort" | Out-Null

    Write-Info "Checking the headset's WiFi IP address..."
    $ip = Get-HeadsetWifiIp -Serial $Serial

    if (-not $ip) {
        Write-Err2 "Could not read the headset's WiFi IP address."
        Write-Err2 "Make sure the headset is connected to a WiFi network, then try again."
        return
    }

    Write-Ok "WiFi IP: $ip"
    Write-Info "Confirming the WiFi ADB session..."
    & $adbPath connect "${ip}:${AdbPort}" 2>$null | Out-Null
    Start-Sleep -Seconds 1
    $connected = & $adbPath devices 2>$null | Where-Object { $_ -match ("^" + [regex]::Escape("${ip}:${AdbPort}") + "\s+device$") }
    if (-not $connected) {
        Write-Warn2 "WiFi ADB did not come up on ${ip}:${AdbPort} yet. It may need a few more seconds - the headset will still be registered with the IP found."
    } else {
        Write-Ok "WiFi ADB confirmed on ${ip}:${AdbPort}."
    }

    $known = Get-KnownHeadsetBySerial -Serial $Serial
    if ($known) {
        Write-Info "Headset already known to VR HEADSET MANAGER as '$($known.Name)' - only its IP address will be updated."
        $nameInput = $known.Name
    } else {
        $defaultName = if ($model -and $model -ne 'Unknown model') { $model } else { "Headset $Serial" }
        $nameInput = Read-Host "Headset display name [$defaultName]"
        if (-not $nameInput) { $nameInput = $defaultName }
    }

    $payload = @{
        serialNumber = $Serial
        ip           = $ip
        name         = $nameInput
        model        = $model
    } | ConvertTo-Json -Compress

    $registerUrl = Get-CurrentServerUrl
    Write-Info "Registering with the VR HEADSET MANAGER server ($registerUrl)..."
    try {
        $response = Invoke-RestMethod -Uri ("{0}/api/headsets/register-by-serial" -f $registerUrl.TrimEnd('/')) `
                                       -Method Post -ContentType 'application/json; charset=utf-8' `
                                       -Body $payload -TimeoutSec 10
    } catch {
        Write-Err2 "Could not reach the VR HEADSET MANAGER server at $registerUrl."
        Write-Err2 $_.Exception.Message
        return
    }

    if ($response.ok) {
        if ($response.action -eq 'added') {
            Write-Ok "Headset '$($response.name)' added to VR HEADSET MANAGER (ID $($response.id))."
        } else {
            Write-Ok "Headset '$($response.name)' already known - IP address updated (ID $($response.id))."
        }
    } else {
        Write-Err2 "Server rejected the request: $($response.error)"
    }
}

Write-Info "VR HEADSET MANAGER - Remote Headset Toolbox"
Write-Info "Looking for the VR HEADSET MANAGER server..."
Set-CurrentServerUrl -Url (Resolve-VrhmServerUrl -ServerUrl $ServerUrl -ServerPort $ServerPort)
Write-Info "Server: $script:CurrentServerUrl"
Write-Info ""

try {
    while ($true) {
        $serial = Wait-ForUsbHeadset

        try {
            Invoke-HeadsetRegistration -Serial $serial
        } catch {
            Write-Err2 "Unexpected error while processing this headset: $($_.Exception.Message)"
        }

        Write-Info ""
        Write-Info "Done with this headset. Unplug it to continue..."
        Wait-ForUsbHeadsetRemoved -Serial $serial
        Write-Info ""
    }
} finally {
    Stop-ToolboxAdbServer
}
