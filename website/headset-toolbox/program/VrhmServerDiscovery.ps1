<#
.SYNOPSIS
    VR HEADSET MANAGER server discovery - the single shared copy.

.DESCRIPTION
    Dot-sourced by Start-VrhmToolbox.ps1. Finds a VR HEADSET MANAGER server on
    the LAN, confirms its identity, remembers it in vrhm_server_cache.json and
    lets the operator pick between several servers or type an address by hand.

    This file replaces the three near-identical copies that used to live in
    website\headset-toolbox\Enable-HeadsetWifiAdb.ps1,
    website\kiosk-launcher\Start-KioskAgent.ps1 and
    scripts\Tools\Find-VRHM-Server.ps1.

    It depends on nothing else from the VR HEADSET MANAGER project - the whole
    toolbox is meant to be copied onto a technician's PC and run there.

.NOTES
    Identity check: a candidate is only accepted when GET /api/version answers
    with {"app":"VRHM",...}. An unrelated web server on the same port is
    therefore never mistaken for a VR HEADSET MANAGER server.

    Cache file contract (shared with every tool that ever wrote it):
        {"IPAddress":"192.168.1.37","Port":8080}
    UTF-8, no trailing newline.
#>

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------

$script:VrhmCachePath   = ""
$script:VrhmDefaultPort = 8080

function Set-VrhmDiscoveryContext {
    <#
    .SYNOPSIS
    Sets the cache file path and the default port used by the rest of this file.

    .EXAMPLE
    Set-VrhmDiscoveryContext -CachePath "C:\Tools\vrhm_server_cache.json" -DefaultPort 8080
    #>
    param(
        [string]$CachePath = "",
        [int]$DefaultPort = 8080
    )

    if ($CachePath) {
        $script:VrhmCachePath = $CachePath
    } else {
        $scriptDir = $null
        if ($PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
        if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
        if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
        $script:VrhmCachePath = Join-Path $scriptDir "vrhm_server_cache.json"
    }

    if ($DefaultPort -gt 0) { $script:VrhmDefaultPort = $DefaultPort }
}

function Get-VrhmServerCachePath {
    if (-not $script:VrhmCachePath) { Set-VrhmDiscoveryContext }
    return $script:VrhmCachePath
}

function Read-VrhmServerCache {
    <#
    .SYNOPSIS
    Returns @{IPAddress;Port} from the cache file, or $null when there is no
    usable cache. Never throws - a corrupt cache is simply ignored.
    #>
    $path = Get-VrhmServerCachePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data.IPAddress -and $data.Port) {
            return @{ IPAddress = [string]$data.IPAddress; Port = [int]$data.Port }
        }
    } catch { }
    return $null
}

function Write-VrhmServerCache {
    param([string]$IPAddress, [int]$Port)
    try {
        (@{ IPAddress = $IPAddress; Port = $Port } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath (Get-VrhmServerCachePath) -Encoding UTF8 -NoNewline
    } catch { }
}

function Clear-VrhmServerCache {
    try {
        $path = Get-VrhmServerCachePath
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# ---------------------------------------------------------------------------
# Identity check
# ---------------------------------------------------------------------------

function Get-VrhmServerInfo {
    <#
    .SYNOPSIS
    Probes one address and returns @{Ok;Version;LatencyMs}. Ok is $true only
    when the answer is genuinely a VR HEADSET MANAGER server.

    .EXAMPLE
    $info = Get-VrhmServerInfo -IPAddress 192.168.1.37 -Port 8080
    if ($info.Ok) { "VRHM $($info.Version)" }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSec = 2
    )

    $result = @{ Ok = $false; Version = $null; LatencyMs = $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $uri = "http://${IPAddress}:${Port}/api/version"
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
        $sw.Stop()
        if ($response -and $response.app -eq 'VRHM') {
            $result.Ok        = $true
            $result.Version   = [string]$response.version
            $result.LatencyMs = [int]$sw.ElapsedMilliseconds
        }
    } catch {
        $sw.Stop()
    }
    return $result
}

function Test-VrhmServerAt {
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSec = 2
    )
    return (Get-VrhmServerInfo -IPAddress $IPAddress -Port $Port -TimeoutSec $TimeoutSec).Ok
}

# ---------------------------------------------------------------------------
# LAN scan
# ---------------------------------------------------------------------------

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
    <#
    .SYNOPSIS
    Local RFC1918 IPv4 interfaces worth scanning. Virtual/hypervisor adapters
    are dropped, except the one holding the default route (a real bridged
    setup), mirroring Get-PrivateNetworks in the server's network_scanner.ps1.
    #>
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
    <#
    .SYNOPSIS
    Parallel TCP connect test over a list of addresses. Returns only the ones
    with the port open.
    #>
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

function Find-VrhmServersOnLan {
    <#
    .SYNOPSIS
    Scans every local private network for VR HEADSET MANAGER servers and
    returns ALL of them as @(@{IPAddress;Port;Version}), newest scan each time.

    .DESCRIPTION
    Unlike the older per-tool copies, this one does not silently take the first
    hit when several servers answer - the caller decides (see Select-VrhmServer).

    .EXAMPLE
    $servers = @(Find-VrhmServersOnLan -Port 8080)
    #>
    param([int]$Port, [int]$TimeoutMs = 300, [int]$MaxThreads = 50)

    if (-not $Port -or $Port -le 0) { $Port = $script:VrhmDefaultPort }

    $networks = @(Get-PrivateNetworksLocal)
    if ($networks.Count -eq 0) {
        Write-Host "No usable local network was found on this PC." -ForegroundColor Yellow
        return @()
    }

    $allIps = @()
    foreach ($net in $networks) { $allIps += Get-IpRangeLocal -CIDR $net.NetworkCIDR }
    $allIps = @($allIps | Select-Object -Unique)
    if ($allIps.Count -eq 0) { return @() }

    Write-Host "Scanning $($allIps.Count) address(es) on port $Port for a VR HEADSET MANAGER server..." -ForegroundColor Cyan
    $openHosts = @(Test-PortForCidrLocal -IpRange $allIps -Port $Port -Timeout $TimeoutMs -MaxThreads $MaxThreads)
    if ($openHosts.Count -eq 0) { return @() }

    $found = @()
    foreach ($candidate in $openHosts) {
        $info = Get-VrhmServerInfo -IPAddress $candidate.IPAddress -Port $Port
        if ($info.Ok) {
            $found += @{
                IPAddress = $candidate.IPAddress
                Port      = $Port
                Version   = $info.Version
                LatencyMs = $info.LatencyMs
            }
        }
    }
    return $found
}

function Select-VrhmServer {
    <#
    .SYNOPSIS
    Picks one server out of a scan result.

    .DESCRIPTION
    Returns either a server entry, or an action the caller must carry out:
    @{Action='manual'} (type an address) or @{Action='rescan'} (search again).
    $null means there was nothing to choose from.

    A lone hit is taken automatically UNLESS -AlwaysPrompt is passed. That switch
    is what the main menu's "Change VRHM server" uses: an operator who explicitly
    asked to change server must always get the choice, including the manual entry
    - otherwise a LAN with exactly one server offers no way to reach a server
    somewhere else. Startup keeps the silent auto-pick, so an unattended kiosk is
    never left waiting at a prompt.
    #>
    param([array]$Servers, [switch]$AlwaysPrompt)

    $list = @($Servers)
    if ($list.Count -eq 0) { return $null }
    if (-not [Environment]::UserInteractive) { return $list[0] }
    if ($list.Count -eq 1 -and -not $AlwaysPrompt) { return $list[0] }

    Write-Host ""
    if ($list.Count -eq 1) {
        Write-Host "One VR HEADSET MANAGER server answered on this network:" -ForegroundColor Yellow
    } else {
        Write-Host "Several VR HEADSET MANAGER servers answered on this network:" -ForegroundColor Yellow
    }
    for ($i = 0; $i -lt $list.Count; $i++) {
        $entry = $list[$i]
        $ver   = if ($entry.Version) { $entry.Version } else { "unknown version" }
        Write-Host ("  [{0}] {1}:{2}   {3}" -f ($i + 1), $entry.IPAddress, $entry.Port, $ver)
    }
    Write-Host "  [M] Enter an IP address and port manually"
    Write-Host "      (a server on another port, or outside this network)"
    Write-Host "  [S] Search again"
    Write-Host ""

    while ($true) {
        $answer = Read-Host "Which server do you want to use? [1-$($list.Count), M, S]"
        if (-not $answer) { return $list[0] }
        if ($answer -match '^(?i)m') { return @{ Action = 'manual' } }
        if ($answer -match '^(?i)s') { return @{ Action = 'rescan' } }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $list.Count) {
            return $list[$index - 1]
        }
        Write-Host "Type a number between 1 and $($list.Count), M to enter an address, or S to search again." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# The resolution cascade
# ---------------------------------------------------------------------------

function ConvertFrom-VrhmAddressInput {
    <#
    .SYNOPSIS
    Parses what the operator typed: "192.168.1.37", "192.168.1.37:8081" or a
    full "http://host:port" URL. Returns @{IPAddress;Port} or $null.

    .DESCRIPTION
    Accepting "ip:port" is what lets the operator reach a server that does not
    run on the default port - including one outside this LAN, which the scan
    could never find.
    #>
    param([string]$Text, [int]$DefaultPort)

    if (-not $Text) { return $null }
    $value = $Text.Trim()
    if (-not $DefaultPort -or $DefaultPort -le 0) { $DefaultPort = $script:VrhmDefaultPort }

    if ($value -match '^https?://([^:/]+)(?::(\d+))?') {
        $host2 = $Matches[1]
        $port2 = if ($Matches[2]) { [int]$Matches[2] } else { $DefaultPort }
        return @{ IPAddress = $host2; Port = $port2 }
    }

    if ($value -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?::(\d+))?$') {
        $host2 = $Matches[1]
        $port2 = if ($Matches[2]) { [int]$Matches[2] } else { $DefaultPort }
        return @{ IPAddress = $host2; Port = $port2 }
    }

    return $null
}

function Read-VrhmManualServer {
    <#
    .SYNOPSIS
    Asks the operator for a server address and port, verifies it, caches it and
    returns @{IPAddress;Port;Url;Version} - or $null when nothing usable was
    given, so the caller goes back to whatever menu it came from.

    .DESCRIPTION
    The port is asked separately, defaulting to the one in play, because typing
    "192.168.1.50" and being silently given :8080 is the most common way to end
    up hunting a server that was never on that port. An "ip:port" or a full URL
    typed into the address prompt is still honoured and skips the port question.

    Shared by both entry points: the [M] option in the server list, and the [I]
    option shown when the scan found nothing.
    #>
    param([int]$DefaultPort)

    if (-not $DefaultPort -or $DefaultPort -le 0) { $DefaultPort = $script:VrhmDefaultPort }

    $typed = Read-Host "Server IP address (or IP:port, or http://host:port)"
    if (-not $typed) { return $null }

    $parsed = ConvertFrom-VrhmAddressInput -Text $typed -DefaultPort $DefaultPort
    if (-not $parsed) {
        Write-Host "'$typed' is not a valid address." -ForegroundColor Red
        return $null
    }

    # Only ask for the port when the address did not already carry one.
    if ($typed -notmatch ':\d+') {
        $portAnswer = Read-Host "Server port [$DefaultPort]"
        if ($portAnswer) {
            $portValue = 0
            if ([int]::TryParse($portAnswer, [ref]$portValue) -and $portValue -ge 1 -and $portValue -le 65535) {
                $parsed.Port = $portValue
            } else {
                Write-Host "'$portAnswer' is not a valid port - using $DefaultPort." -ForegroundColor Yellow
            }
        }
    }

    Write-Host "Checking $($parsed.IPAddress):$($parsed.Port)..." -ForegroundColor Cyan
    $info = Get-VrhmServerInfo -IPAddress $parsed.IPAddress -Port $parsed.Port -TimeoutSec 4
    if ($info.Ok) {
        Write-VrhmServerCache -IPAddress $parsed.IPAddress -Port $parsed.Port
        return @{
            IPAddress = $parsed.IPAddress
            Port      = $parsed.Port
            Url       = "http://$($parsed.IPAddress):$($parsed.Port)"
            Version   = $info.Version
        }
    }

    Write-Host "No VR HEADSET MANAGER server answered at $($parsed.IPAddress):$($parsed.Port)." -ForegroundColor Red
    # A server behind a VPN or on a slow link may still be the right one even
    # though it did not answer in time, so the operator is allowed to insist.
    $useAnyway = Read-Host "Use this address anyway? [y/N]"
    if ($useAnyway -match '^(?i)(y|o)') {
        Write-VrhmServerCache -IPAddress $parsed.IPAddress -Port $parsed.Port
        return @{
            IPAddress = $parsed.IPAddress
            Port      = $parsed.Port
            Url       = "http://$($parsed.IPAddress):$($parsed.Port)"
            Version   = $null
        }
    }

    return $null
}

function Resolve-VrhmServer {
    <#
    .SYNOPSIS
    Returns @{IPAddress;Port;Url;Version} for the server to work with. Blocks
    until one is defined - it never returns $null.

    .DESCRIPTION
    Cascade:
      1. -ForcedIp (with -ForcedPort) - verified, then cached.
      2. The cache file, when -IgnoreCache was not passed - verified.
      3. A LAN scan; the hits go through Select-VrhmServer, which also offers
         [M] manual entry and [S] search again.
      4. When the scan found nothing, a menu that loops for as long as needed:
         search again, or type an address (ip, ip:port or a URL).

    -AlwaysPrompt forces the selection menu even when exactly one server
    answered; the main menu's "Change VRHM server" passes it, so that choice
    always reaches the manual entry.

    .EXAMPLE
    $server = Resolve-VrhmServer -ForcedIp '' -ForcedPort 8080
    #>
    param(
        [string]$ForcedIp = "",
        [int]$ForcedPort = 0,
        [switch]$IgnoreCache,
        [switch]$AlwaysPrompt
    )

    $port = if ($ForcedPort -gt 0) { $ForcedPort } else { $script:VrhmDefaultPort }

    if ($ForcedIp) {
        $parsed = ConvertFrom-VrhmAddressInput -Text $ForcedIp -DefaultPort $port
        if ($parsed) {
            if ($ForcedPort -gt 0) { $parsed.Port = $ForcedPort }
            $info = Get-VrhmServerInfo -IPAddress $parsed.IPAddress -Port $parsed.Port
            if ($info.Ok) {
                Write-VrhmServerCache -IPAddress $parsed.IPAddress -Port $parsed.Port
                return @{
                    IPAddress = $parsed.IPAddress
                    Port      = $parsed.Port
                    Url       = "http://$($parsed.IPAddress):$($parsed.Port)"
                    Version   = $info.Version
                }
            }
            Write-Host "No VR HEADSET MANAGER server answered at $($parsed.IPAddress):$($parsed.Port)." -ForegroundColor Yellow
        } else {
            Write-Host "'$ForcedIp' is not a valid address." -ForegroundColor Yellow
        }
    }

    if (-not $IgnoreCache) {
        $cached = Read-VrhmServerCache
        if ($cached) {
            $info = Get-VrhmServerInfo -IPAddress $cached.IPAddress -Port $cached.Port
            if ($info.Ok) {
                Write-Host "Using the last known VR HEADSET MANAGER server at $($cached.IPAddress):$($cached.Port)." -ForegroundColor Green
                return @{
                    IPAddress = $cached.IPAddress
                    Port      = $cached.Port
                    Url       = "http://$($cached.IPAddress):$($cached.Port)"
                    Version   = $info.Version
                }
            }
        }
    }

    while ($true) {
        $servers  = @(Find-VrhmServersOnLan -Port $port)
        $selected = Select-VrhmServer -Servers $servers -AlwaysPrompt:$AlwaysPrompt

        if ($selected -and $selected.Action -eq 'rescan') { continue }

        if ($selected -and $selected.Action -eq 'manual') {
            $manual = Read-VrhmManualServer -DefaultPort $port
            if ($manual) { return $manual }
            continue
        }

        if ($selected) {
            Write-Host "Using VR HEADSET MANAGER server at $($selected.IPAddress):$($selected.Port)." -ForegroundColor Green
            Write-VrhmServerCache -IPAddress $selected.IPAddress -Port $selected.Port
            return @{
                IPAddress = $selected.IPAddress
                Port      = $selected.Port
                Url       = "http://$($selected.IPAddress):$($selected.Port)"
                Version   = $selected.Version
            }
        }

        Write-Host ""
        Write-Host "No VR HEADSET MANAGER server was found on this network." -ForegroundColor Yellow
        Write-Host "  [S] Search again"
        Write-Host "  [I] Enter a server address (IP, IP:port, or http://host:port)"
        Write-Host "      Use IP:port to reach a server on another port, or outside this network."
        Write-Host "  Close the app by pressing Ctrl + C at any time"
        $choice = Read-Host "Choice"

        if ($choice -match '^(?i)i') {
            $manual = Read-VrhmManualServer -DefaultPort $port
            if ($manual) { return $manual }
        }
        # [S], anything else, or an empty answer -> search again
    }
}
