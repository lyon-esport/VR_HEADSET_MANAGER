<#
.SYNOPSIS
    Standalone LAN scanner: finds hosts on the local network that accept a
    remote desktop connection (RDP or VNC).

.DESCRIPTION
    Scans every private (RFC 1918) network reachable from this PC for a TCP
    listener on the RDP port (3389) and the VNC port (5900), then confirms
    each open port really is that service (and not some other unrelated
    application squatting the same port number):

      - VNC is confirmed by reading the RFB greeting the server sends on
        connect (for example "RFB 003.008"). Nothing is sent to the server.
      - RDP is confirmed by sending one X.224 Connection Request carrying an
        RDP Negotiation Request and parsing the Connection Confirm reply.
        The reply also says which security layer the server selected
        (plain RDP, TLS, or NLA / CredSSP). No credentials are sent and no
        session is established.

    Confirmed hosts are then resolved to a name by reverse DNS (skippable
    with -NoResolve).

    This script does not depend on any other file from the VR HEADSET
    MANAGER project - it is self-contained and safe to copy and run
    standalone on any Windows PC with PowerShell 5.1+.

.PARAMETER Ports
    TCP ports to sweep. Default 3389 (RDP) and 5900 (VNC). Widen it when a
    VNC server runs on a non-default display, for example
    -Ports 3389,5900,5901,5902.

.PARAMETER TimeoutMs
    Per-host TCP connect timeout in milliseconds during the port scan.
    Default 300.

.PARAMETER MaxThreads
    Maximum number of parallel runspaces used for the port scan. Default 50.

.PARAMETER NoResolve
    Skip the reverse DNS lookup on confirmed hosts. A host with no PTR
    record can stall the lookup for several seconds.

.PARAMETER CsvPath
    Optional path to export the confirmed results as a CSV report.

.EXAMPLE
    .\Find-RemoteAccessHosts.ps1

.EXAMPLE
    .\Find-RemoteAccessHosts.ps1 -Ports 3389,5900,5901 -CsvPath "$env:TEMP\remote_access.csv"

.NOTES
    Safe to run repeatedly. Read-only: it never opens firewall rules, writes
    files, or requires Administrator rights. Intended for inventory of a
    network you are responsible for.
#>

[CmdletBinding()]
param(
    [int[]]$Ports      = @(3389, 5900),
    [int]$TimeoutMs    = 300,
    [int]$MaxThreads   = 50,
    [switch]$NoResolve,
    [string]$CsvPath
)

function Get-IpRangeLocal {
    param([string]$CIDR)

    if ($CIDR -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
        return @()
    }

    $ip = ($CIDR -split '/')[0]
    [int]$prefixLength = ($CIDR -split '/')[1]
    if ($prefixLength -lt 7 -or $prefixLength -gt 30) {
        return @()
    }

    $octets = $ip -split '\.'
    $ipBinary = ''
    foreach ($octet in $octets) {
        $octetBinary = [convert]::ToString([int]$octet, 2).PadLeft(8, '0')
        $ipBinary += $octetBinary
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

function Test-PortsForHostsLocal {
    param(
        [string[]]$IpRange,
        [int[]]$Ports,
        [int]$Timeout,
        [int]$MaxThreads
    )

    if (-not $IpRange -or $IpRange.Count -eq 0) {
        return @()
    }
    if (-not $Ports -or $Ports.Count -eq 0) {
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
        foreach ($port in $Ports) {
            $powershell = [powershell]::Create().AddScript($testPortScript).AddArgument($ip).AddArgument($port).AddArgument($Timeout)
            $powershell.RunspacePool = $runspacePool
            $jobs += [PSCustomObject]@{
                PowerShell  = $powershell
                AsyncResult = $powershell.BeginInvoke()
            }
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

function Connect-WithTimeoutLocal {
    # Opens a TcpClient with a bounded connect time. Returns the connected
    # client, or $null. Caller is responsible for disposing it.
    param([string]$IP, [int]$Port, [int]$TimeoutMs)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($IP, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.Dispose()
            return $null
        }
        $client.EndConnect($async)
        if (-not $client.Connected) {
            $client.Dispose()
            return $null
        }
        return $client
    } catch {
        if ($client) { $client.Dispose() }
        return $null
    }
}

function Confirm-VncService {
    # A VNC server greets the client with "RFB <major>.<minor>\n" as soon as
    # the TCP connection is accepted. Read-only probe: nothing is sent.
    param([string]$IP, [int]$Port, [int]$TimeoutMs = 1500)

    $result = @{ Confirmed = $false; Detail = 'not VNC' }
    $client = $null
    try {
        $client = Connect-WithTimeoutLocal -IP $IP -Port $Port -TimeoutMs $TimeoutMs
        if (-not $client) {
            $result.Detail = 'no response'
            return $result
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs

        $buffer = New-Object byte[] 12
        $read = 0
        while ($read -lt 12) {
            $chunk = $stream.Read($buffer, $read, 12 - $read)
            if ($chunk -le 0) { break }
            $read += $chunk
        }

        if ($read -ge 12) {
            $banner = [System.Text.Encoding]::ASCII.GetString($buffer, 0, 12)
            if ($banner -match '^RFB (\d{3})\.(\d{3})') {
                $result.Confirmed = $true
                $result.Detail    = "RFB $($Matches[1]).$($Matches[2])"
            }
        }
    } catch {
    } finally {
        if ($client) { $client.Dispose() }
    }
    return $result
}

function Confirm-RdpService {
    # Sends one X.224 Connection Request carrying an RDP Negotiation Request
    # (MS-RDPBCGR 2.2.1.1) and parses the Connection Confirm. Stops at the
    # negotiation PDU: no credentials, no session.
    param([string]$IP, [int]$Port, [int]$TimeoutMs = 1500)

    $result = @{ Confirmed = $false; Detail = 'not RDP' }
    $client = $null
    try {
        $client = Connect-WithTimeoutLocal -IP $IP -Port $Port -TimeoutMs $TimeoutMs
        if (-not $client) {
            $result.Detail = 'no response'
            return $result
        }

        $request = [byte[]]@(
            0x03, 0x00, 0x00, 0x13,   # TPKT: version 3, reserved, length 19
            0x0E,                     # X.224 length indicator (14 bytes follow)
            0xE0,                     # X.224 TPDU code: Connection Request
            0x00, 0x00,               # DST-REF
            0x00, 0x00,               # SRC-REF
            0x00,                     # class / options
            0x01,                     # RDP_NEG_REQ type
            0x00,                     # flags
            0x08, 0x00,               # length = 8 (little endian)
            0x03, 0x00, 0x00, 0x00    # requestedProtocols = TLS | CredSSP
        )

        $stream = $client.GetStream()
        $stream.ReadTimeout  = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $stream.Write($request, 0, $request.Length)
        $stream.Flush()

        $buffer = New-Object byte[] 64
        $read = $stream.Read($buffer, 0, $buffer.Length)

        # Minimum valid reply: TPKT header + X.224 Connection Confirm (11 bytes).
        if ($read -ge 11 -and $buffer[0] -eq 0x03 -and $buffer[5] -eq 0xD0) {
            $result.Confirmed = $true
            $result.Detail    = 'RDP (standard security)'

            if ($read -ge 19) {
                $negType = $buffer[11]
                if ($negType -eq 0x02) {
                    # RDP_NEG_RSP: selectedProtocol is a little-endian DWORD at offset 15.
                    $selected = [BitConverter]::ToUInt32($buffer, 15)
                    switch ($selected) {
                        0 { $result.Detail = 'RDP (no TLS)' }
                        1 { $result.Detail = 'TLS' }
                        2 { $result.Detail = 'NLA (CredSSP)' }
                        8 { $result.Detail = 'RDSTLS' }
                        default { $result.Detail = "protocol 0x$('{0:X}' -f $selected)" }
                    }
                } elseif ($negType -eq 0x03) {
                    $result.Detail = 'RDP (negotiation refused)'
                }
            }
        }
    } catch {
    } finally {
        if ($client) { $client.Dispose() }
    }
    return $result
}

function Get-ServiceForPortLocal {
    param([int]$Port)

    if ($Port -eq 3389) { return 'RDP' }
    if ($Port -eq 5800) { return 'VNC-HTTP' }
    if ($Port -ge 5900 -and $Port -le 5905) { return 'VNC' }
    return 'Unknown'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$portList = ($Ports | Sort-Object -Unique) -join ', '

Write-Host ''
Write-Host 'VR HEADSET MANAGER - Remote Access Scanner' -ForegroundColor Cyan
Write-Host "Scanning the local network for open RDP / VNC ports ($portList) ..." -ForegroundColor Cyan
Write-Host ''

$networks = @(Get-PrivateNetworksLocal)
if ($networks.Count -eq 0) {
    Write-Host 'No private network interface found on this PC. Aborting.' -ForegroundColor Red
    exit 1
}

$allIps = @()
foreach ($net in $networks) {
    Write-Host "  Interface: $($net.InterfaceAlias)  Network: $($net.NetworkCIDR)"
    $allIps += Get-IpRangeLocal -CIDR $net.NetworkCIDR
}
$allIps = @($allIps | Select-Object -Unique)

Write-Host ''
Write-Host "Testing $($allIps.Count) address(es) on $($Ports.Count) port(s) (this can take a few seconds) ..."

$openHosts = @(Test-PortsForHostsLocal -IpRange $allIps -Ports $Ports -Timeout $TimeoutMs -MaxThreads $MaxThreads)

if ($openHosts.Count -eq 0) {
    Write-Host ''
    Write-Host "No host with port $portList open was found on the local network." -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host "Found $($openHosts.Count) open port(s). Confirming which ones really are RDP / VNC ..."

$found      = @()
$unconfirmed = 0

foreach ($candidate in $openHosts) {
    $ip      = $candidate.IPAddress
    $port    = [int]$candidate.Port
    $service = Get-ServiceForPortLocal -Port $port

    switch ($service) {
        'RDP'      { $probe = Confirm-RdpService -IP $ip -Port $port }
        'VNC'      { $probe = Confirm-VncService -IP $ip -Port $port }
        'VNC-HTTP' { $probe = @{ Confirmed = $true; Detail = '(no probe)' } }
        default    { $probe = @{ Confirmed = $true; Detail = '(no probe)' } }
    }

    if (-not $probe.Confirmed) {
        $unconfirmed++
        continue
    }

    $hostname = ''
    if (-not $NoResolve) {
        try {
            $hostname = [System.Net.Dns]::GetHostEntry($ip).HostName
        } catch {
            $hostname = '(no PTR)'
        }
    }

    $found += [PSCustomObject]@{
        IPAddress = $ip
        Port      = $port
        Service   = $service
        Detail    = $probe.Detail
        Hostname  = $hostname
    }
}

Write-Host ''
if ($found.Count -eq 0) {
    Write-Host "$($openHosts.Count) open port(s) responded, but none of them answered as RDP or VNC." -ForegroundColor Yellow
    Write-Host 'Another application may be using those ports on the local network.'
    exit 0
}

Write-Host 'Remote access services found:' -ForegroundColor Green
Write-Host ''
$found | Sort-Object Service, IPAddress | Format-Table -AutoSize IPAddress, Port, Service, Detail, Hostname

if ($unconfirmed -gt 0) {
    Write-Host "$unconfirmed host(s) had the port open but did not answer as RDP or VNC (ignored)." -ForegroundColor Yellow
    Write-Host ''
}

if ($CsvPath) {
    try {
        $found | Sort-Object Service, IPAddress |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Report written to $CsvPath" -ForegroundColor Green
    } catch {
        Write-Host "Could not write the report to $CsvPath : $($_.Exception.Message)" -ForegroundColor Red
    }
}

exit 0
