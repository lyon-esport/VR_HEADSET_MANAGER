<#
.SYNOPSIS
    Standalone LAN scanner: finds any VR HEADSET MANAGER web server currently
    running on the local network.

.DESCRIPTION
    Scans every private (RFC 1918) network reachable from this PC for a TCP
    listener on the VR HEADSET MANAGER web server port, then confirms each
    open port really is a VR HEADSET MANAGER instance (and not some other
    unrelated service on the same port) by calling its GET /api/version
    endpoint.

    This script does not depend on any other file from the VR HEADSET
    MANAGER project - it is self-contained and safe to copy and run
    standalone on any Windows PC with PowerShell 5.1+.

.PARAMETER Port
    TCP port the VR HEADSET MANAGER web server listens on. If omitted, the
    script makes a best-effort attempt to read WebServer.port from
    ..\config\config.json relative to its own location (useful when run from
    inside the project working copy); if that file is missing or unreadable,
    it falls back to the default port 8080.

.PARAMETER TimeoutMs
    Per-host TCP connect timeout in milliseconds during the port scan.
    Default 300.

.PARAMETER MaxThreads
    Maximum number of parallel runspaces used for the port scan. Default 50.

.EXAMPLE
    .\Find-VRHM-Server.ps1

.EXAMPLE
    .\Find-VRHM-Server.ps1 -Port 8090

.NOTES
    Safe to run repeatedly. Read-only: it never opens firewall rules, writes
    files, or requires Administrator rights.
#>

[CmdletBinding()]
param(
    [int]$Port,
    [int]$TimeoutMs = 300,
    [int]$MaxThreads = 50
)

$DefaultPort = 8080

if (-not $Port) {
    $Port = $DefaultPort
    try {
        $configPath = Join-Path $PSScriptRoot '..\config\config.json'
        if (Test-Path -LiteralPath $configPath) {
            $configJson = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($configJson.WebServer.port) {
                $Port = [int]$configJson.WebServer.port
            }
        }
    } catch {
        $Port = $DefaultPort
    }
}

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

Write-Host ''
Write-Host 'VR HEADSET MANAGER - Network Finder' -ForegroundColor Cyan
Write-Host "Scanning the local network for a VRHM web server on port $Port ..." -ForegroundColor Cyan
Write-Host ''

$networks = Get-PrivateNetworksLocal
if (-not $networks -or $networks.Count -eq 0) {
    Write-Host 'No private network interface found on this PC. Aborting.' -ForegroundColor Red
    exit 1
}

$allIps = @()
foreach ($net in $networks) {
    Write-Host "  Interface: $($net.InterfaceAlias)  Network: $($net.NetworkCIDR)"
    $allIps += Get-IpRangeLocal -CIDR $net.NetworkCIDR
}
$allIps = $allIps | Select-Object -Unique

Write-Host ''
Write-Host "Testing $($allIps.Count) address(es) on port $Port (this can take a few seconds) ..."

$openHosts = Test-PortForCidrLocal -IpRange $allIps -Port $Port -Timeout $TimeoutMs -MaxThreads $MaxThreads

if (-not $openHosts -or $openHosts.Count -eq 0) {
    Write-Host ''
    Write-Host "No host with port $Port open was found on the local network." -ForegroundColor Yellow
    Write-Host 'Make sure the VR HEADSET MANAGER app is running and check the port with -Port if it uses a non-default one.'
    exit 0
}

Write-Host ''
Write-Host "Found $($openHosts.Count) host(s) with port $Port open. Confirming which ones are VR HEADSET MANAGER ..."

$found = @()
foreach ($candidate in $openHosts) {
    $ip = $candidate.IPAddress
    try {
        $uri = "http://${ip}:${Port}/api/version"
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec 2 -ErrorAction Stop
        if ($response -and $response.version) {
            $found += [PSCustomObject]@{
                IPAddress = $ip
                Port      = $Port
                Version   = $response.version
                Url       = "http://${ip}:${Port}/video_monitor.html"
            }
        }
    } catch {
    }
}

Write-Host ''
if ($found.Count -eq 0) {
    Write-Host "Port $Port responded on $($openHosts.Count) host(s), but none of them identified as VR HEADSET MANAGER." -ForegroundColor Yellow
    Write-Host 'Another application may be using that port on the local network.'
    exit 0
}

Write-Host "VR HEADSET MANAGER instance(s) found:" -ForegroundColor Green
Write-Host ''
$found | Format-Table -AutoSize IPAddress, Port, Version, Url
