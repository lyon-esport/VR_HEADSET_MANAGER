
##########################
# NETWORK SEARCH #
##########################

function Get-Test {
    param (
        $message
    )
    Write-Host "This is a test! $message"
} 



function Add-Headset-ScanNetwork {
    [CmdletBinding()]
    param (
        [int]$port = $global:adbPort_default,       # Port to test
        [int]$timeout = 200 # Wait timeout in milliseconds
    )
    
    $adbPath = Join-Path -Path $global:adbFolder -ChildPath "adb.exe"
    
    Clear-Host
    Start-Sleep -Milliseconds 200
    Write-Host "=== NETWORK SCAN FOR HEADSETS ===" -ForegroundColor Cyan

    # Step 1: Select the network interface
    $networks = Get-PrivateNetworks
    if (-not $networks) {
        Write-Host "No private network detected." -ForegroundColor Red
        return
    }

    Write-Host "`nDetected network interfaces:"
    $i = 1
    foreach ($net in $networks) {
        Write-Host "$i. $($net.InterfaceAlias) - IP $($net.IPAddress) ($($net.NetworkCIDR))"
        $i++
    }

    do {
        $selection = Read-Host "Select a network interface (1-$(@($networks).Count))"
    } while (-not ($selection -match '^\d+$') -or [int]$selection -lt 1 -or [int]$selection -gt $(@($networks).Count))

    $selectedNetwork = $networks[[int]$selection - 1].NetworkCIDR

    # Step 2: ADB port to scan

    Write-Host "`nScanning network $selectedNetwork on port $port ..." -ForegroundColor Yellow
    $foundDevices = Test-PortForCidr -CIDR $selectedNetwork -port $port

    if (-not $foundDevices -or $foundDevices.Count -eq 0) {
        Write-Host "No headset detected on the network." -ForegroundColor Red
        return
    }


    # Step 3.5: ADB connection and info retrieval
    Start-Sleep -Milliseconds 200
    foreach ($device in $foundDevices) {
        $adbTarget = "$($device.hostname):$port"
        Write-Log ($msg.ScanConnecting -f $adbTarget) -Level INFO

        $connectOutput = & $adbPath connect $adbTarget 2>&1
        if ($connectOutput -match 'connected to') {
            $model  = (Invoke-AdbCmd -Device $adbTarget -Command "shell getprop ro.product.model"  -adb $adbPath) -join ''
            $serial = (Invoke-AdbCmd -Device $adbTarget -Command "shell getprop ro.serialno"        -adb $adbPath) -join ''
            if (-not $serial -or $serial.Trim() -eq "") {
                $serial = (Invoke-AdbCmd -Device $adbTarget -Command "shell getprop ro.boot.serialno" -adb $adbPath) -join ''
            }

            # Clean up the data
            $device | Add-Member -NotePropertyName "Model" -NotePropertyValue ($model.Trim()) -Force
            $device | Add-Member -NotePropertyName "Serial" -NotePropertyValue ($serial.Trim()) -Force

            Write-Log ($msg.ScanConnected -f $adbTarget, $device.Model, $device.Serial) -Level INFO
            & $adbPath disconnect $adbTarget | Out-Null
        } else {
            Write-Log ($msg.ScanConnectionFailed -f $adbTarget) -Level WARNING
            $device | Add-Member -NotePropertyName "Model" -NotePropertyValue "UNKNOWN" -Force
            $device | Add-Member -NotePropertyName "Serial" -NotePropertyValue "UNKNOWN" -Force
        }
    }




    <# Step 4: Display detected headsets
    Write-Host "`nDetected headsets:"
    $i = 1
    foreach ($dev in $foundDevices) {
        Write-Host "$i. [$($dev.hostname)]`t [$($dev.Model)]`t [$($dev.Serial)]"
        $i++
    }#>

    # Duplicate check
    $knownHeadsets = Get-KnownHeadsets
    $knownIPs = $knownHeadsets | ForEach-Object { $_.IPAddress }

    # Step 4: Display detected headsets
    Write-Host "`nDetected headsets:"
    $i = 1
    foreach ($dev in $foundDevices) {
        $isKnown = $knownIPs -contains $dev.hostname
        if ($isKnown) {
            Write-Host "$i. [$($dev.hostname)]`t [$($dev.Model)]`t [$($dev.Serial)]  (already added)" -ForegroundColor DarkGray
            $dev | Add-Member -NotePropertyName "AlreadyAdded" -NotePropertyValue $true -Force
        } else {
            Write-Host "$i. [$($dev.hostname)]`t [$($dev.Model)]`t [$($dev.Serial)]"
            $dev | Add-Member -NotePropertyName "AlreadyAdded" -NotePropertyValue $false -Force
        }
        $i++
    }

    # Step 5: Select which ones to add
    $selections = Read-Host "Enter the numbers of headsets to add (e.g.: 1,3,5)"
    $indices = $selections -split ',' | ForEach-Object { ($_ -replace '\s','') } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }

    $selectedDevices = @()
    foreach ($index in $indices) {
        if ($index -ge 0 -and $index -lt @($foundDevices).Count) {
            $selectedDevices += $foundDevices[$index]
        }
    }

    if (-not $selectedDevices) {
        Write-Host "No headset selected." -ForegroundColor Yellow
        return
    }

    # Step 6: Confirmation & headset addition
    Write-Host "`nHeadsets to add:"
    foreach ($dev in $selectedDevices) {
        Write-Host "- $($dev.hostname)"
    }

    $confirm = Read-Host "Confirm adding these headsets? (y/n)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Addition cancelled." -ForegroundColor Red
        return
    }

    foreach ($dev in $selectedDevices) {
        $name = Read-Host "Name to assign to $($dev.hostname)"
        if (-not $name) {
            $name = "Headset_$($dev.hostname.Replace('.', '_'))"
        }

        Write-Log ($msg.ScanAddingHeadset -f $name, $dev.hostname, $model, $serial) -Level INFO
        Add-Headset -IPAddress $dev.hostname -Name $name
    }

    Write-Host "`nAll selected headsets have been added!" -ForegroundColor Green
}



function Get-IpRange {
<#
.SYNOPSIS
    Given a subnet in CIDR format, get all of the valid IP addresses in that range.
.DESCRIPTION
    Given a subnet in CIDR format, get all of the valid IP addresses in that range.
.PARAMETER Subnets
    The subnet written in CIDR format 'a.b.c.d/#' and an example would be '192.168.1.24/27'. Can be a single value, an
    array of values, or values can be taken from the pipeline.
.EXAMPLE
    Get-IpRange -Subnets '192.168.1.24/30'
 
    192.168.1.25
    192.168.1.26
.EXAMPLE
    (Get-IpRange -Subnets '10.100.10.0/24').count
 
    254
.EXAMPLE
    '192.168.1.128/30' | Get-IpRange
 
    192.168.1.129
    192.168.1.130
.NOTES
    Inspired by https://gallery.technet.microsoft.com/PowerShell-Subnet-db45ec74
 
    * Added comment help
#>

    [CmdletBinding(ConfirmImpact = 'None')]
    Param(
        [Parameter(Mandatory, HelpMessage = 'Please enter a subnet in the form a.b.c.d/#', ValueFromPipeline, Position = 0)]
        [string[]] $Subnets
    )

    begin {
        Write-Verbose -Message "Starting [$($MyInvocation.Mycommand)]"
    }

    process {
        foreach ($subnet in $subnets) {
            if ($subnet -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
                #Split IP and subnet
                $IP = ($Subnet -split '\/')[0]
                [int] $SubnetBits = ($Subnet -split '\/')[1]
                if ($SubnetBits -lt 7 -or $SubnetBits -gt 30) {
                    Write-Error -Message 'The number following the / must be between 7 and 30'
                    break
                }
                #Convert IP into binary
                #Split IP into different octects and for each one, figure out the binary with leading zeros and add to the total
                $Octets = $IP -split '\.'
                $IPInBinary = @()
                foreach ($Octet in $Octets) {
                    #convert to binary
                    $OctetInBinary = [convert]::ToString($Octet, 2)
                    #get length of binary string add leading zeros to make octet
                    $OctetInBinary = ('0' * (8 - ($OctetInBinary).Length) + $OctetInBinary)
                    $IPInBinary = $IPInBinary + $OctetInBinary
                }
                $IPInBinary = $IPInBinary -join ''
                #Get network ID by subtracting subnet mask
                $HostBits = 32 - $SubnetBits
                $NetworkIDInBinary = $IPInBinary.Substring(0, $SubnetBits)
                #Get host ID and get the first host ID by converting all 1s into 0s
                $HostIDInBinary = $IPInBinary.Substring($SubnetBits, $HostBits)
                $HostIDInBinary = $HostIDInBinary -replace '1', '0'
                #Work out all the host IDs in that subnet by cycling through $i from 1 up to max $HostIDInBinary (i.e. 1s stringed up to $HostBits)
                #Work out max $HostIDInBinary
                $imax = [convert]::ToInt32(('1' * $HostBits), 2) - 1
                $IPs = @()
                #Next ID is first network ID converted to decimal plus $i then converted to binary
                For ($i = 1 ; $i -le $imax ; $i++) {
                    #Convert to decimal and add $i
                    $NextHostIDInDecimal = ([convert]::ToInt32($HostIDInBinary, 2) + $i)
                    #Convert back to binary
                    $NextHostIDInBinary = [convert]::ToString($NextHostIDInDecimal, 2)
                    #Add leading zeros
                    #Number of zeros to add
                    $NoOfZerosToAdd = $HostIDInBinary.Length - $NextHostIDInBinary.Length
                    $NextHostIDInBinary = ('0' * $NoOfZerosToAdd) + $NextHostIDInBinary
                    #Work out next IP
                    #Add networkID to hostID
                    $NextIPInBinary = $NetworkIDInBinary + $NextHostIDInBinary
                    #Split into octets and separate by . then join
                    $IP = @()
                    For ($x = 1 ; $x -le 4 ; $x++) {
                        #Work out start character position
                        $StartCharNumber = ($x - 1) * 8
                        #Get octet in binary
                        $IPOctetInBinary = $NextIPInBinary.Substring($StartCharNumber, 8)
                        #Convert octet into decimal
                        $IPOctetInDecimal = [convert]::ToInt32($IPOctetInBinary, 2)
                        #Add octet to IP
                        $IP += $IPOctetInDecimal
                    }
                    #Separate by .
                    $IP = $IP -join '.'
                    $IPs += $IP
                }
                Write-Output -InputObject $IPs
            } else {
                Write-Error -Message "Subnet [$subnet] is not in a valid format"
            }
        }
    }

    end {
        Write-Verbose -Message "Ending [$($MyInvocation.Mycommand)]"
    }
}

# Function to test a port on a specific IP address

#test-port -hostname "192.168.1.243"
function Test-Port {
    param (
        [Parameter(Mandatory=$true)]
        [string]$hostname,  # Hostname or IP address
        [int]$port = $Global:adbPort_default,         # Port to test
        [int]$timeout = 200 # Wait timeout in milliseconds
    )

    $requestCallback = $state = $null
    $client = New-Object System.Net.Sockets.TcpClient

    # Start the connection attempt
    $beginConnect = $client.BeginConnect($hostname, $port, $requestCallback, $state)

    # Wait for the specified timeout duration
    $startTime = Get-Date
    while (-not $client.Connected -and ((Get-Date) - $startTime).TotalMilliseconds -lt $timeout) {
        Start-Sleep -Milliseconds 10  # Wait 10ms to avoid overloading the CPU
    }

    # Check whether the connection succeeded
    if ($client.Connected) {
        $open = $true
    } else {
        $open = $false
    }

    # Close the connection
    $client.Close()
    Remove-Variable $beginConnect -ErrorAction SilentlyContinue

    # Return the object with the test result
    return [pscustomobject]@{
        hostname = $hostname
        port     = $port
        open     = $open
    }
}


#Test-PortInternal -hostname "192.168.1.243"
#$hostname = $ip =  "192.168.1.243"
#$port = 5555
#$timeout = 200
function Test-PortInternal {
    param($hostname, $port, $timeout)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($hostname, $port, $null, $null)
        $wait = $async.AsyncWaitHandle.WaitOne($timeout, $false)
        if (-not $wait) {
            return @{ hostname = $hostname; open = $false }
        }
        $tcp.EndConnect($async)
        return @{ hostname = $hostname; open = $true }
    } catch {
        return @{ hostname = $hostname; open = $false }
    } finally {
        if ($tcp) { $tcp.Close() }
    }
}


# Function to get all IP addresses from a CIDR and test the port in PARALLEL
<#
$test = Test-PortForCidr -CIDR $selectedNetwork -port $port
$CIDR = $selectedNetwork
Test-port -hostname "192.168.1.243" -port 5555 
Test-port -hostname "192.168.1.243" -port 46801

#$CIDR = $($net.NetworkCIDR)
# Test-PortForCidr -CIDR "192.168.1.0/24" -timeout 200
#$CIDR = "192.168.1.0/24"
#$ip = "192.168.1.243"
#>
function Test-PortForCidr {
    <#
    .SYNOPSIS
    Tests the availability of a port on all IP addresses of a CIDR network in parallel.
    
    .PARAMETER CIDR
    The CIDR notation of the network to scan (e.g.: "192.168.1.0/24")
    
    .PARAMETER Port
    The port to test (default: 5555)
    
    .PARAMETER Timeout
    Timeout in milliseconds (default: 500ms)
    
    .PARAMETER MaxThreads
    Maximum number of parallel threads (default: 50)
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$CIDR,
        
        [int]$Port = 5555,
        
        [ValidateRange(100,5000)]
        [int]$Timeout = 500,
        
        [int]$MaxThreads = 50
    )

    # Retrieve all IPs from the CIDR
    $ipRange = Get-IpRange $CIDR
    $totalIPs = $ipRange.Count
    Write-Log ($msg.ScanStarting -f $totalIPs, $Port) -Level INFO

    # Configure the runspace pool
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $runspacePool.Open()
    $jobs = @()

    # ScriptBlock to test a port
    $testPortScript = {
        param($ip, $port, $timeout)
        
        $result = [PSCustomObject]@{
                IPAddress   = $ip
                Port        = $port
                Open        = $false
        }
        
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $tcpClient.BeginConnect($ip, $port, $null, $null)
            $connectionStatus = $asyncResult.AsyncWaitHandle.WaitOne($timeout, $false)

            if ($connectionStatus -and $tcpClient.Connected) {
                $result.Open = $true
                $tcpClient.EndConnect($asyncResult)
            }
        }
        catch {}
        finally {
            if ($tcpClient) { $tcpClient.Dispose() }
        }
        return $result
    }

    # Launch jobs in parallel
    foreach ($ip in $ipRange) {
        $powershell = [powershell]::Create().AddScript($testPortScript).AddArgument($ip).AddArgument($Port).AddArgument($Timeout)
        $powershell.RunspacePool = $runspacePool
        $jobs += [PSCustomObject]@{
            PowerShell = $powershell
            AsyncResult = $powershell.BeginInvoke()
        }
    }
    Start-Sleep -Milliseconds $(20*$timeout)
    # Collect results
    $results = do {
        foreach ($job in $jobs) {
            if ($job.AsyncResult.IsCompleted) {
                $job.PowerShell.EndInvoke($job.AsyncResult)
                $job.PowerShell.Dispose()
            }
        }
        $jobs = $jobs | Where-Object { -not $_.AsyncResult.IsCompleted }
    } while ($jobs.Count -gt 0)

    # Cleanup
    $runspacePool.Close()
    $runspacePool.Dispose()

    return $results | Where-Object Open
}




# Function to calculate the network IP
function ConvertTo-CIDR {
    param (
        [string]$IPAddress,
        [int]$PrefixLength
    )

    # Convert the prefix to a binary subnet mask
    $binaryMask = ("1" * $PrefixLength).PadRight(32, "0")
    $maskBytes = $binaryMask -split "(.{8})" | Where-Object { $_ -ne "" } | ForEach-Object { [Convert]::ToInt32($_, 2) }

    # Convert the IP into octets
    $ipBytes = $IPAddress.Split('.') | ForEach-Object { [int]$_ }

    # Apply a logical AND to get the network address
    $networkBytes = for ($i = 0; $i -lt 4; $i++) {
        $ipBytes[$i] -band $maskBytes[$i]
    }

    # Join the octets to form the network address
    $networkIP = $networkBytes -join '.'

    # Return the network in CIDR format
    return "$networkIP/$PrefixLength"
}

# Function to list the IP networks connected to the machine
function Get-PrivateNetworks {
    <#
    .SYNOPSIS
        Lists private IP networks connected to the PC with their prefixes and full networks.

    .DESCRIPTION
        This function identifies IP addresses assigned to the system's network interfaces
        and filters only those belonging to RFC 1918 private classes A, B, or C. It returns
        the calculated network in CIDR format with the prefix.

        Virtual/hypervisor adapters (Hyper-V, WSL, VMware, VirtualBox, VPN TAP adapters, etc.)
        are excluded, mirroring the same exclusion used by the mDNS responder
        (mdns_responder.ps1) - otherwise a Hyper-V "vEthernet (...)" adapter with a private IP
        but no real gateway can get picked instead of the real LAN adapter (e.g. by
        Get-ServerLanUrl / Resolve-LocalhostReplacement in kiosk_functions.ps1), sending
        kiosks and network scans to an address nothing outside this PC can reach. The
        interface currently holding the default route is always kept even if it would
        otherwise match the exclusion list, to cover legitimate Hyper-V "external
        switch"/bridge setups that do carry real LAN traffic.

        Adapters whose link is down (unplugged cable, disabled WiFi, etc.) are also
        excluded, even if Windows still shows a leftover/static IP on them - a
        disconnected adapter's configured IP is not reachable from anything else on
        the network and must not be reported as valid (e.g. by Wait-ForValidNetwork).
        Skipped only when Get-NetAdapter itself fails, to avoid losing every interface
        on systems where adapter status cannot be queried.

    .OUTPUTS
        Returns an array of PSCustomObjects: InterfaceAlias, IPAddress, PrefixLength,
        NetworkCIDR, HasDefaultGateway (true for the interface currently holding the
        0.0.0.0/0 route - the one this PC actually uses to reach the LAN/internet, and the
        strongest available signal for "this is the real adapter"), and IsWifi (best-effort,
        $false when the adapter type can't be determined).

    .EXAMPLE
        $networks = Get-PrivateNetworks
        Lists all private IP addresses with their networks.

    .NOTES
        Compatible with PowerShell 5.x.
    #>

    # Interface currently used for outbound traffic - never excluded below, and exposed to
    # callers as HasDefaultGateway so they can prefer it deterministically.
    $defaultRouteIfIndex = $null
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($route) { $defaultRouteIfIndex = $route.InterfaceIndex }
    } catch { }

    # Map InterfaceIndex -> adapter, to identify virtual/hypervisor adapters. Get-NetAdapter
    # can fail on some systems (driver quirks, permissions); on failure, skip the exclusion
    # rather than losing every interface.
    $adapterByIndex = @{}
    try {
        Get-NetAdapter -ErrorAction Stop | ForEach-Object {
            $adapterByIndex[$_.InterfaceIndex] = $_
        }
    } catch { }

    $virtualPattern = 'Hyper-V|VMware|VirtualBox|WSL|vEthernet|Pseudo|TAP|WAN Miniport'

    # Retrieve active network interfaces with their IPs
    $networkInterfaces = Get-NetIPAddress | Where-Object {
        $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -match '\d+\.\d+\.\d+\.\d+' -and
        $_.IPAddress -notlike '169.254.*' # Excludes APIPA addresses
    }

    # Filter only private IP addresses according to RFC 1918 classes
    $privateIPs = $networkInterfaces | Where-Object {
        ($_).IPAddress -match '^10\.' -or           # Classe A
        ($_).IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.' -or # Classe B
        ($_).IPAddress -match '^192\.168\.'        # Classe C
    }

    # Drop virtual/hypervisor adapters, unless this is the interface actually carrying the
    # default route (a real bridged Hyper-V setup would be wrongly excluded otherwise).
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

    # Drop adapters whose link is down (unplugged / disabled) - a static or leftover IP
    # on a disconnected adapter is not a usable network. Applied even to the default-route
    # interface: a genuinely down adapter cannot legitimately be carrying live traffic.
    # Skipped only when Get-NetAdapter itself failed above (adapterByIndex empty), to
    # avoid losing every interface on systems where adapter status can't be queried.
    if ($adapterByIndex.Count -gt 0) {
        $privateIPs = $privateIPs | Where-Object {
            $adapter = $adapterByIndex[$_.InterfaceIndex]
            -not $adapter -or $adapter.Status -eq 'Up'
        }
    }

    # Add the CIDR network (and a best-effort WiFi/wired label) to each result
    $privateIPs | ForEach-Object {
        $adapter = $adapterByIndex[$_.InterfaceIndex]
        $isWifi  = [bool](($adapter -and $adapter.PhysicalMediaType -eq 'Native 802.11') -or ($_.InterfaceAlias -match 'Wi-?Fi'))
        [PSCustomObject]@{
            InterfaceAlias    = $_.InterfaceAlias
            IPAddress         = $_.IPAddress
            PrefixLength      = $_.PrefixLength
            NetworkCIDR       = ConvertTo-CIDR -IPAddress $_.IPAddress -PrefixLength $_.PrefixLength
            HasDefaultGateway = [bool]($defaultRouteIfIndex -and $_.InterfaceIndex -eq $defaultRouteIfIndex)
            IsWifi            = $isWifi
        }
    }
}


function Test-ValidIPv4 {
    param (
        [string]$ipAddress
    )
    
    # Regex for standard IPv4 validation
    $ipv4Pattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    
    # Check 1: Basic format
    if (-not ($ipAddress -match $ipv4Pattern)) {
        return $false
    }
    
    # Check 2: Reserved ranges/localhost
    $octets = $ipAddress -split '\.'
    if ($octets[0] -eq '127') { return $false }  # Loopback
    if ($octets[0] -eq '0')   { return $false }   # Reserved network
    
    # Check 3: Multicast/link-local ranges
    if ($octets[0] -eq '224' -or $octets[0] -eq '239') { return $false }
    if ($octets[0] -eq '169' -and $octets[1] -eq '254') { return $false }
    
    return $true
}


# Pauses startup until at least one network interface has a valid (non-APIPA,
# non-virtual) IP address, re-checking every $global:Network_CheckIntervalSeconds.
# The operator can press any key to bypass the wait and continue startup anyway.
function Wait-ForValidNetwork {
    if (-not $global:Network_WaitForValidNetwork) { return }

    if (Get-PrivateNetworks) { return }

    $intervalSec = if ($global:Network_CheckIntervalSeconds -gt 0) { $global:Network_CheckIntervalSeconds } else { 5 }

    Write-Log $msg.NetworkWaitTitle -Level WARNING
    Write-Log $msg.NetworkWaitBypassHint -Level WARNING
    $Host.UI.RawUI.FlushInputBuffer()

    $elapsedSec = 0
    $bypassed = $false

    while (-not $bypassed) {
        $ticks = [int]($intervalSec * 10)
        for ($t = 0; $t -lt $ticks; $t++) {
            if ([Console]::KeyAvailable) {
                [Console]::ReadKey($true) | Out-Null
                $bypassed = $true
                break
            }
            Write-Host -NoNewline ("`r{0} ({1}s)... " -f $msg.NetworkWaitWaiting, $elapsedSec)
            Start-Sleep -Milliseconds 100
        }

        if ($bypassed) { break }

        $elapsedSec += $intervalSec
        $validNetworks = Get-PrivateNetworks
        if ($validNetworks) {
            Write-Host -NoNewline ("`r" + (' ' * 60) + "`r")
            Write-Log ($msg.NetworkWaitFound -f $validNetworks[0].IPAddress, $validNetworks[0].InterfaceAlias) -Level SUCCESS
            $Host.UI.RawUI.FlushInputBuffer()
            return
        }
    }

    Write-Host -NoNewline ("`r" + (' ' * 60) + "`r")
    Write-Log $msg.NetworkWaitBypassed -Level WARNING
    $Host.UI.RawUI.FlushInputBuffer()
}


function Invoke-CompanionDiscovery {
    <#
    .SYNOPSIS
    Broadcasts a UDP discovery probe on the LAN and collects replies from headsets
    running the VRHM Companion app. Updates known_headsets.csv when a headset IP
    has changed (matched by serial number). Returns an array of discovered companions.
    .PARAMETER TimeoutMs
    How long to wait for replies after broadcasting (default 2000 ms).
    .PARAMETER UdpPort
    UDP port used for discovery (default 5556, same as companion DiscoveryServer).
    #>
    param(
        [int]$TimeoutMs = 2000,
        [int]$UdpPort   = 5556
    )

    $discovered = [System.Collections.Generic.List[PSCustomObject]]::new()
    $udp        = $null

    try {
        # Get our local LAN IPs to populate server_ip in the probe
        $localIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' } |
            Select-Object -ExpandProperty IPAddress)
        $serverIp = if ($localIPs.Count -gt 0) { $localIPs[0] } else { "127.0.0.1" }

        $probe = [System.Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-Json -Compress @{
                type      = "VRHM_DISCOVER"
                server_ip = $serverIp
                ws_port   = $global:WebServer_port
            })
        )

        # Bind on the discovery port so replies come back to us on that same port
        $udp = [System.Net.Sockets.UdpClient]::new($UdpPort)
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = $TimeoutMs

        $bcastEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, $UdpPort)
        [void]$udp.Send($probe, $probe.Length, $bcastEp)
        Write-Log "Invoke-CompanionDiscovery: broadcast sent on port $UdpPort, waiting ${TimeoutMs}ms" -Level DEBUG

        $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([datetime]::UtcNow -lt $deadline) {
            try {
                $remoteEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $bytes    = $udp.Receive([ref]$remoteEp)
                $json     = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop

                if ($json.type -ne "VRHM_COMPANION") { continue }
                if (-not $json.serial) { continue }

                $companion = [PSCustomObject]@{
                    Serial         = $json.serial
                    Model          = $json.model
                    IP             = $json.ip
                    CompanionPort  = [int]$json.companion_port
                    AutoAdbWifi    = [bool]$json.auto_adb_wifi
                    AdbWifiEnabled = [bool]$json.adb_wifi_enabled
                    Version        = $json.version
                }
                $discovered.Add($companion)
                Write-Log "Invoke-CompanionDiscovery: found $($companion.Model) serial=$($companion.Serial) ip=$($companion.IP)" -Level DEBUG

                # Heal IP drift: if serial matches a known headset and IP has changed, update CSV
                $headsets = Get-KnownHeadsets
                $known    = $headsets | Where-Object { $_.SerialNumber -eq $companion.Serial } | Select-Object -First 1
                if ($known -and $known.IPAddress -ne $companion.IP) {
                    Write-Log ("Invoke-CompanionDiscovery: updating IP for '{0}' {1} -> {2}" -f $known.Name, $known.IPAddress, $companion.IP) -Level INFO
                    Update-HeadsetField -Id $known.Id -Field "IPAddress" -NewValue $companion.IP
                }
            } catch [System.Net.Sockets.SocketException] {
                break  # timeout
            } catch {
                Write-Log "Invoke-CompanionDiscovery: parse error: $_" -Level DEBUG
            }
        }
    } catch {
        Write-Log "Invoke-CompanionDiscovery: error: $_" -Level WARNING
    } finally {
        if ($null -ne $udp) { try { $udp.Close() } catch {} }
    }

    Write-Log "Invoke-CompanionDiscovery: $($discovered.Count) companion(s) found" -Level DEBUG
    return $discovered.ToArray()
}

