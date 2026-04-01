<#
.SYNOPSIS
    Discovers Meta Quest headsets on the local network via mDNS.
.DESCRIPTION
    Listens for mDNS announcements on port 5353 (UDP multicast).
    Detects ADB-over-WiFi services broadcast by Meta Quest headsets,
    including random ports assigned by tools like Quest Game Optimizer.
    No external dependencies - fully standalone module.
    Requires .NET System.Net.Sockets (no external dependency).
.NOTES
    To integrate with the VR_HEADSET_MANAGER project:
    - Replace Write-MdnsLog calls with Write-Log from logging.ps1
    - Replace Register-DiscoveredHeadset with Add-Headset from headsets_infos_manager.ps1
#>

# ─── Constants ────────────────────────────────────────────────────────────────

$MDNS_MULTICAST_ADDRESS = "224.0.0.251"
$MDNS_PORT              = 5353
$MDNS_LISTEN_TIMEOUT_MS = 5000

$ADB_SERVICE_TYPES = @(
    "_adb-tls-connect._tcp",
    "_adb-tls-pairing._tcp",
    "_adb._tcp"
)

# ─── Standalone Logger ────────────────────────────────────────────────────────

<#
    Minimal logger - replace with Write-Log from logging.ps1 if integrated
    into the VR_HEADSET_MANAGER project.
#>
function Write-MdnsLog {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "$timestamp [$Level] $Message"

    $colorMap = @{
        "DEBUG"   = @{ ForegroundColor = "DarkGray" }
        "INFO"    = @{ ForegroundColor = "Cyan" }
        "SUCCESS" = @{ ForegroundColor = "White";  BackgroundColor = "DarkGreen" }
        "WARNING" = @{ ForegroundColor = "Yellow" }
        "ERROR"   = @{ ForegroundColor = "White";  BackgroundColor = "DarkRed" }
    }

    $params = $colorMap[$Level]
    Write-Host $logEntry @params

    # Append to a local log file next to this script
    $logFile = Join-Path -Path $PSScriptRoot -ChildPath "mdns_scanner.log"
    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8
}

# ─── DNS Packet Parser ────────────────────────────────────────────────────────

<#
    Parses a raw mDNS/DNS label sequence from a byte array.
    Handles standard labels and pointer compression (RFC 1035).
    Returns a hashtable: @{ Name = "..."; NextOffset = N }
#>
function Read-DnsName {
    param (
        [byte[]]$Data,
        [int]$Offset
    )

    $labels     = @()
    $visited    = @{}
    $nextOffset = -1

    while ($Offset -lt $Data.Length) {

        if ($visited.ContainsKey($Offset)) { break }
        $visited[$Offset] = $true

        $length = $Data[$Offset]

        if ($length -eq 0) {
            if ($nextOffset -eq -1) { $nextOffset = $Offset + 1 }
            break
        }

        # Pointer compression (top 2 bits = 11)
        if (($length -band 0xC0) -eq 0xC0) {
            if ($nextOffset -eq -1) { $nextOffset = $Offset + 2 }
            $Offset = (($length -band 0x3F) -shl 8) -bor $Data[$Offset + 1]
            continue
        }

        $Offset++
        $label   = [System.Text.Encoding]::UTF8.GetString($Data, $Offset, $length)
        $labels += $label
        $Offset += $length
    }

    return @{
        Name       = ($labels -join ".")
        NextOffset = $nextOffset
    }
}

<#
    Parses a minimal mDNS response packet.
    Extracts PTR, SRV, A, and TXT records relevant to ADB service discovery.
    Returns a list of parsed resource records.
#>
function Read-MdnsPacket {
    param ([byte[]]$Data)

    $records = @()

    if ($Data.Length -lt 12) { return $records }

    $answerCount     = ($Data[6]  -shl 8) -bor $Data[7]
    $additionalCount = ($Data[10] -shl 8) -bor $Data[11]
    $totalRecords    = $answerCount + $additionalCount

    $offset = 12

    # Skip question section
    $questionCount = ($Data[4] -shl 8) -bor $Data[5]
    for ($q = 0; $q -lt $questionCount -and $offset -lt $Data.Length; $q++) {
        $parsed = Read-DnsName -Data $Data -Offset $offset
        $offset = $parsed.NextOffset + 4
    }

    for ($r = 0; $r -lt $totalRecords -and $offset -lt $Data.Length; $r++) {
        $nameResult = Read-DnsName -Data $Data -Offset $offset
        $offset     = $nameResult.NextOffset

        if ($offset + 10 -gt $Data.Length) { break }

        $type     = ($Data[$offset]     -shl 8) -bor $Data[$offset + 1]
        $rdLength = ($Data[$offset + 8] -shl 8) -bor $Data[$offset + 9]
        $offset  += 10

        if ($offset + $rdLength -gt $Data.Length) { break }

        $rdData = $Data[$offset..($offset + $rdLength - 1)]

        switch ($type) {
            12 {
                # PTR - service instance name
                $ptr     = Read-DnsName -Data $Data -Offset $offset
                $records += @{ Type = "PTR"; Name = $nameResult.Name; Value = $ptr.Name }
            }
            33 {
                # SRV - priority(2) + weight(2) + port(2) + target hostname
                $port    = ($rdData[4] -shl 8) -bor $rdData[5]
                $target  = Read-DnsName -Data $Data -Offset ($offset + 6)
                $records += @{ Type = "SRV"; Name = $nameResult.Name; Port = $port; Target = $target.Name }
            }
            1 {
                # A - IPv4 address
                if ($rdLength -eq 4) {
                    $ip      = "$($rdData[0]).$($rdData[1]).$($rdData[2]).$($rdData[3])"
                    $records += @{ Type = "A"; Name = $nameResult.Name; IP = $ip }
                }
            }
            16 {
                # TXT - key=value metadata pairs
                $txtEntries = @()
                $pos = 0
                while ($pos -lt $rdData.Length) {
                    $len = $rdData[$pos]; $pos++
                    if ($len -gt 0 -and ($pos + $len) -le $rdData.Length) {
                        $txtEntries += [System.Text.Encoding]::UTF8.GetString($rdData, $pos, $len)
                        $pos += $len
                    }
                }
                $records += @{ Type = "TXT"; Name = $nameResult.Name; Entries = $txtEntries }
            }
        }

        $offset += $rdLength
    }

    return $records
}

# ─── mDNS Query Builder ───────────────────────────────────────────────────────

<#
    Builds a raw mDNS PTR query packet for a given service type.
    Sends it to the multicast group to actively solicit responses (RFC 6762).
#>
function New-MdnsQuery {
    param ([string]$ServiceType)

    $header = [byte[]](0x00,0x00, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00)

    $question = [System.Collections.Generic.List[byte]]::new()
    foreach ($label in ($ServiceType + ".local") -split "\.") {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($label)
        $question.Add([byte]$bytes.Length)
        foreach ($b in $bytes) { $question.Add($b) }
    }
    $question.Add(0x00)        # End of name
    $question.Add(0x00)
    $question.Add(0x0C)        # QTYPE = PTR
    $question.Add(0x00)
    $question.Add(0x01)        # QCLASS = IN

    return $header + $question.ToArray()
}

# ─── Network Interface Helper ─────────────────────────────────────────────────

<#
    Returns all active non-loopback IPv4 network interfaces.
    Used to join the mDNS multicast group on each relevant NIC.
#>
function Get-ActiveIPv4Interfaces {
    return [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object {
            $_.OperationalStatus -eq 'Up' -and
            $_.NetworkInterfaceType -notin @('Loopback', 'Tunnel')
        } |
        ForEach-Object {
            $_.GetIPProperties().UnicastAddresses |
                Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
                Select-Object -ExpandProperty Address
        } |
        Where-Object { $_ -ne $null }
}

# ─── Core Discovery Function ──────────────────────────────────────────────────

<#
.SYNOPSIS
    Sends mDNS queries and listens for ADB service announcements from Meta Quest headsets.
.PARAMETER TimeoutMs
    Total listening duration in milliseconds. Default: 5000.
.PARAMETER ServiceTypes
    Array of mDNS service types to query. Defaults to standard ADB service types.
.OUTPUTS
    Array of PSCustomObject: IPAddress, Port, DeviceName, ServiceType, RawSrvName
#>
function Find-QuestHeadsetsMdns {
    param (
        [int]$TimeoutMs    = $MDNS_LISTEN_TIMEOUT_MS,
        [string[]]$ServiceTypes = $ADB_SERVICE_TYPES
    )

    $discovered = @{}
    $udpClient  = $null

    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Client.SetSocketOption(
            [System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress,
            $true
        )
        $udpClient.Client.Bind(
            [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $MDNS_PORT)
        )

        # Join mDNS multicast group on every active IPv4 interface
        foreach ($localIp in (Get-ActiveIPv4Interfaces)) {
            try {
                $udpClient.JoinMulticastGroup(
                    [System.Net.IPAddress]::Parse($MDNS_MULTICAST_ADDRESS),
                    $localIp
                )
                Write-MdnsLog "mDNS: Joined multicast group on interface $localIp" -Level DEBUG
            } catch {
                Write-MdnsLog "mDNS: Could not join multicast on ${localIp}: $($_.Exception.Message)" -Level DEBUG
            }
        }

        # Actively query for each ADB service type
        $multicastEndpoint = [System.Net.IPEndPoint]::new(
            [System.Net.IPAddress]::Parse($MDNS_MULTICAST_ADDRESS),
            $MDNS_PORT
        )
        foreach ($serviceType in $ServiceTypes) {
            $queryPacket = New-MdnsQuery -ServiceType $serviceType
            $udpClient.Send($queryPacket, $queryPacket.Length, $multicastEndpoint) | Out-Null
            Write-MdnsLog "mDNS: Query sent for service type [$serviceType]" -Level DEBUG
        }

        # Intermediate storage for cross-referencing SRV and A records
        $pendingSrv = @{}   # ServiceInstanceName -> @{ Port; Target; SenderIP }
        $pendingA   = @{}   # HostName            -> IP

        $udpClient.Client.ReceiveTimeout = 500
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

        Write-MdnsLog "mDNS: Listening for responses (${TimeoutMs}ms)..." -Level INFO

        while ((Get-Date) -lt $deadline) {
            try {
                $remoteEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $rawBytes = $udpClient.Receive([ref]$remoteEP)
                $senderIP = $remoteEP.Address.ToString()
                $records  = Read-MdnsPacket -Data $rawBytes

                foreach ($rec in $records) {
                    switch ($rec.Type) {
                        "SRV" {
                            $pendingSrv[$rec.Name] = @{
                                Port     = $rec.Port
                                Target   = $rec.Target
                                SenderIP = $senderIP
                            }
                        }
                        "A" {
                            $pendingA[$rec.Name] = $rec.IP
                        }
                    }
                }

                # Attempt to resolve complete entries whenever new records arrive
                foreach ($srvKey in $pendingSrv.Keys) {
                    $srv        = $pendingSrv[$srvKey]
                    $resolvedIP = if ($pendingA.ContainsKey($srv.Target)) {
                        $pendingA[$srv.Target]
                    } else {
                        $srv.SenderIP
                    }

                    $entryKey = "${resolvedIP}:$($srv.Port)"
                    if (-not $discovered.ContainsKey($entryKey)) {
                        $deviceName = ($srvKey -replace "\._adb[^.]*\._tcp.*", "").Trim()

                        $discovered[$entryKey] = [PSCustomObject]@{
                            IPAddress   = $resolvedIP
                            Port        = $srv.Port
                            DeviceName  = $deviceName
                            ServiceType = ($srvKey -replace "^[^.]+\.", "")
                            RawSrvName  = $srvKey
                        }
                        Write-MdnsLog "mDNS: Device found -> [$deviceName] at ${resolvedIP}:$($srv.Port)" -Level SUCCESS
                    }
                }

            } catch [System.Net.Sockets.SocketException] {
                # Receive timeout - expected, continue polling until deadline
            }
        }

    } catch {
        Write-MdnsLog "mDNS: Fatal socket error: $($_.Exception.Message)" -Level ERROR
    } finally {
        if ($udpClient) { $udpClient.Close() }
    }

    return @($discovered.Values)
}

# ─── Result Display Helper ────────────────────────────────────────────────────

<#
    Formats and displays discovered headsets in a readable table.
    Standalone replacement for pipeline output formatting.
#>
function Show-DiscoveredHeadsets {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Devices
    )

    if (-not $Devices -or $Devices.Count -eq 0) {
        Write-Host "`n  No headsets found." -ForegroundColor Yellow
        return
    }

    $separator = "-" * 70
    Write-Host "`n$separator" -ForegroundColor DarkGray
    Write-Host ("  {0,-24} {1,-18} {2,-8} {3}" -f "Device Name", "IP Address", "Port", "Service") -ForegroundColor White
    Write-Host $separator -ForegroundColor DarkGray

    foreach ($device in $Devices) {
        Write-Host ("  {0,-24} {1,-18} {2,-8} {3}" -f
            $device.DeviceName,
            $device.IPAddress,
            $device.Port,
            $device.ServiceType
        ) -ForegroundColor Cyan
    }
    Write-Host "$separator`n" -ForegroundColor DarkGray
}

# ─── Optional: Register Discovered Headsets ───────────────────────────────────

<#
    Minimal standalone headset registration into a CSV file.
    Replace with Add-Headset from headsets_infos_manager.ps1 when integrated
    into the VR_HEADSET_MANAGER project.
#>
function Register-DiscoveredHeadset {
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Device,
        [string]$CsvPath = (Join-Path -Path $PSScriptRoot -ChildPath "discovered_headsets.csv")
    )

    # Load existing entries to avoid duplicates
    $existing = @()
    if (Test-Path $CsvPath) {
        $existing = Import-Csv -Path $CsvPath -Delimiter ";"
    }

    $alreadyKnown = $existing | Where-Object { $_.IPAddress -eq $Device.IPAddress -and $_.Port -eq $Device.Port }
    if ($alreadyKnown) {
        Write-MdnsLog "Register: $($Device.IPAddress):$($Device.Port) already in CSV, skipping." -Level DEBUG
        return
    }

    $newEntry = [PSCustomObject]@{
        Name        = $Device.DeviceName
        IPAddress   = $Device.IPAddress
        Port        = $Device.Port
        ServiceType = $Device.ServiceType
        DiscoveredAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    $existing += $newEntry
    $existing | Export-Csv -Path $CsvPath -Delimiter ";" -NoTypeInformation -Encoding UTF8

    Write-MdnsLog "Register: [$($Device.DeviceName)] saved to $CsvPath" -Level SUCCESS
}

# ─── Main Entry Point ─────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Discovers Quest headsets via mDNS and optionally registers them.
.PARAMETER TimeoutMs
    Listening duration in milliseconds. Default: 5000.
.PARAMETER AutoRegister
    If set, saves discovered headsets to discovered_headsets.csv.
.PARAMETER CsvPath
    Path for the output CSV. Defaults to .\discovered_headsets.csv.
.EXAMPLE
    Invoke-MdnsHeadsetScan
    Invoke-MdnsHeadsetScan -TimeoutMs 10000 -AutoRegister
    Invoke-MdnsHeadsetScan -AutoRegister -CsvPath "C:\VR\headsets.csv"
#>
function Invoke-MdnsHeadsetScan {
    param (
        [int]$TimeoutMs    = $MDNS_LISTEN_TIMEOUT_MS,
        [switch]$AutoRegister,
        [string]$CsvPath   = (Join-Path -Path $PSScriptRoot -ChildPath "discovered_headsets.csv")
    )

    Write-MdnsLog "=== mDNS Headset Discovery Started ===" -Level INFO
    $devices = Find-QuestHeadsetsMdns -TimeoutMs $TimeoutMs

    if (-not $devices -or $devices.Count -eq 0) {
        Write-MdnsLog "No ADB-enabled headsets found on the network." -Level WARNING
        return $null
    }

    Write-MdnsLog "$($devices.Count) headset(s) discovered." -Level SUCCESS
    Show-DiscoveredHeadsets -Devices $devices

    if ($AutoRegister) {
        foreach ($device in $devices) {
            Register-DiscoveredHeadset -Device $device -CsvPath $CsvPath
        }
    }

    return $devices
}

# ─── Direct Execution Guard ───────────────────────────────────────────────────
# Run automatically only when the script is executed directly, not dot-sourced.

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "`nmdns_scanner.ps1 - Standalone Mode" -ForegroundColor White
    Write-Host "Usage: Invoke-MdnsHeadsetScan [-TimeoutMs <ms>] [-AutoRegister] [-CsvPath <path>]`n" -ForegroundColor DarkGray

    # Default behavior when run directly: scan with 8 second timeout
    Invoke-MdnsHeadsetScan -TimeoutMs 8000
}
