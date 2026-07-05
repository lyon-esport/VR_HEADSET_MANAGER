# VR Headsets Manager - mdns_responder.ps1
# Multicast DNS (mDNS) responder: answers A-record queries for <hostname>.local
# so browsers on the same LAN can reach the web server by name (e.g. http://vrhm.local).
# RFC 6762 compliant. Runs as a Start-Job background job alongside the web server.
# Enabled/disabled via config.json MdnsResponder.enabled.

function Start-MdnsResponder {
    if (-not $global:MdnsResponder_enabled) { return }

    $existing = Get-Job -Name "MdnsResponder" -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -eq 'Running') {
        Write-Log "mDNS responder already running" -Level DEBUG
        return
    }

    $hostname   = if ($global:MdnsResponder_hostname) { $global:MdnsResponder_hostname } else { "vrhm" }
    $scriptPath = $global:ScriptPath

    $responderBlock = {
        param($ScriptPath, $Hostname)

        # Write PID so the reaper can kill this process if main dies ungracefully
        $pidFilePath = Join-Path $ScriptPath "data\mdns_responder.pid"
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($pidFilePath, "$PID", $utf8NoBom)
        } catch { }

        # Inline helpers (avoids dot-sourcing mdns_scanner.ps1 which has $PSScriptRoot side-effects in job context)
        function Read-DnsName {
            param([byte[]]$Data, [int]$Offset)
            $labels = @(); $visited = @{}; $nextOffset = -1
            while ($Offset -lt $Data.Length) {
                if ($visited.ContainsKey($Offset)) { break }
                $visited[$Offset] = $true
                $length = $Data[$Offset]
                if ($length -eq 0) {
                    if ($nextOffset -eq -1) { $nextOffset = $Offset + 1 }
                    break
                }
                if (($length -band 0xC0) -eq 0xC0) {
                    if ($nextOffset -eq -1) { $nextOffset = $Offset + 2 }
                    $Offset = (($length -band 0x3F) -shl 8) -bor $Data[$Offset + 1]
                    continue
                }
                $Offset++
                $labels += [System.Text.Encoding]::UTF8.GetString($Data, $Offset, $length)
                $Offset += $length
            }
            return @{ Name = ($labels -join "."); NextOffset = $nextOffset }
        }

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

        # Collect ALL usable LAN IPs so multi-homed machines (Wi-Fi + Ethernet,
        # two different subnets) advertise every reachable address.
        # Clients pick whichever IP they can route to (standard Avahi/Bonjour behaviour).
        $respondIPs = [System.Collections.Generic.List[string]]::new()

        # Step 1: non-virtual physical/bridge NICs (excludes Hyper-V, VMware, WSL, TAP...)
        [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object {
                $_.OperationalStatus -eq 'Up' -and
                $_.NetworkInterfaceType -notin @('Loopback', 'Tunnel') -and
                $_.Description -notmatch 'Hyper-V|VMware|VirtualBox|WSL|vEthernet|Pseudo|TAP|WAN Miniport'
            } | ForEach-Object {
                $_.GetIPProperties().UnicastAddresses |
                    Where-Object {
                        $_.Address.AddressFamily -eq 'InterNetwork' -and
                        $_.Address.ToString() -notmatch '^(127\.|169\.254\.)'
                    } | ForEach-Object {
                        $a = $_.Address.ToString()
                        if (-not $respondIPs.Contains($a)) { $respondIPs.Add($a) }
                    }
            }

        # Step 2: always include the default-route interface IP first.
        # Covers Hyper-V bridge adapters (e.g. "vEthernet (Bridge_LAN)") that are
        # filtered above by description but carry real LAN traffic.
        try {
            $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                Where-Object { $_.NextHop -ne '0.0.0.0' } |
                Sort-Object RouteMetric | Select-Object -First 1
            if ($route) {
                $routeIP = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex `
                    -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress
                if ($routeIP -and -not $respondIPs.Contains($routeIP)) {
                    $respondIPs.Insert(0, $routeIP)
                }
            }
        } catch { }

        if ($respondIPs.Count -eq 0) { Write-RLog "No suitable LAN IPs found - exiting"; return }

        $targetFqdn = "$Hostname.local"

        # Build label-encoded name bytes for "hostname.local" once (reused in every response)
        $nameBytes = [System.Collections.Generic.List[byte]]::new()
        foreach ($label in ($targetFqdn -split '\.')) {
            $lb = [System.Text.Encoding]::UTF8.GetBytes($label)
            $nameBytes.Add([byte]$lb.Length)
            foreach ($b in $lb) { $nameBytes.Add($b) }
        }
        $nameBytes.Add(0x00)
        $nameArr = $nameBytes.ToArray()

        $logPath = Join-Path $ScriptPath "data\mdns_responder.log"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false

        function Write-RLog { param($msg)
            try { [System.IO.File]::AppendAllText($logPath, "$(Get-Date -Format 'HH:mm:ss') $msg`n", $utf8NoBom) } catch { }
        }

        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            # ReuseAddress must be set before Bind so Windows DNS Client and our socket
            # can both hold port 5353 simultaneously (same pattern as mdns_scanner.ps1)
            $udp.Client.SetSocketOption(
                [System.Net.Sockets.SocketOptionLevel]::Socket,
                [System.Net.Sockets.SocketOptionName]::ReuseAddress,
                $true
            )
            $udp.Client.Bind(
                [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 5353)
            )

            foreach ($localIp in (Get-ActiveIPv4Interfaces)) {
                try {
                    $udp.JoinMulticastGroup(
                        [System.Net.IPAddress]::Parse("224.0.0.251"),
                        $localIp
                    )
                } catch { Write-RLog "JoinMulticast failed on ${localIp}: $_" }
            }

            $udp.Client.ReceiveTimeout = 500
            $multicastEP = New-Object System.Net.IPEndPoint(
                [System.Net.IPAddress]::Parse("224.0.0.251"), 5353
            )

            Write-RLog "mDNS responder listening for $targetFqdn -> $($respondIPs -join ', ')"

            while ($true) {
                try {
                    $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $data     = $udp.Receive([ref]$remoteEP)

                    if ($data.Length -lt 12) { continue }
                    # Ignore mDNS responses (QR bit = 1 in flags byte)
                    if (($data[2] -band 0x80) -ne 0) { continue }

                    $qdCount       = ($data[4] -shl 8) -bor $data[5]
                    $offset        = 12
                    $shouldRespond = $false
                    $quBitSet      = $false   # unicast-response requested by querier

                    for ($q = 0; $q -lt $qdCount; $q++) {
                        if ($offset -ge $data.Length) { break }
                        $parsed = Read-DnsName -Data $data -Offset $offset
                        $offset = $parsed.NextOffset
                        if ($offset -lt 0 -or ($offset + 4) -gt $data.Length) { break }
                        $qtype    =  ($data[$offset]     -shl 8) -bor $data[$offset + 1]
                        $rawClass = ($data[$offset + 2] -shl 8) -bor $data[$offset + 3]
                        $qclass   = $rawClass -band 0x7FFF
                        if ($rawClass -band 0x8000) { $quBitSet = $true }
                        $offset += 4
                        # TYPE=1 (A) or TYPE=255 (ANY), CLASS=1 (IN)
                        if (($qtype -eq 1 -or $qtype -eq 255) -and $qclass -eq 1 `
                            -and $parsed.Name -ieq $targetFqdn) {
                            $shouldRespond = $true
                        }
                    }

                    if (-not $shouldRespond) { continue }

                    # RFC 6762 response: one A record per usable LAN IP.
                    # Multi-homed machines advertise all IPs; clients pick whichever is reachable.
                    $anCount = [byte]([Math]::Min($respondIPs.Count, 255))

                    $response = [System.Collections.Generic.List[byte]]::new()
                    $response.AddRange([byte[]]@($data[0], $data[1]))       # Transaction ID (echo)
                    $response.AddRange([byte[]](0x84, 0x00))                # Flags: QR=1 AA=1
                    $response.AddRange([byte[]](0x00, 0x00))                # QDCOUNT = 0
                    $response.AddRange([byte[]](0x00, $anCount))            # ANCOUNT = N
                    $response.AddRange([byte[]](0x00, 0x00))                # NSCOUNT = 0
                    $response.AddRange([byte[]](0x00, 0x00))                # ARCOUNT = 0

                    foreach ($ip in $respondIPs) {
                        $ipb = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
                        $response.AddRange($nameArr)                            # Answer name
                        $response.AddRange([byte[]](0x00, 0x01))               # TYPE = A
                        $response.AddRange([byte[]](0x80, 0x01))               # CLASS = IN + cache-flush
                        $response.AddRange([byte[]](0x00, 0x00, 0x00, 0x78))  # TTL = 120 s
                        $response.AddRange([byte[]](0x00, 0x04))               # RDLENGTH = 4
                        $response.AddRange([byte[]]$ipb)                       # RDATA = IPv4
                    }
                    $pkt = $response.ToArray()

                    # When QU bit is set (Windows DNS Client always sets it), respond
                    # unicast directly to the querier so same-machine resolution works.
                    # Also send multicast so other devices on the LAN receive the response.
                    if ($quBitSet) {
                        $udp.Send($pkt, $pkt.Length, $remoteEP) | Out-Null
                    }
                    $udp.Send($pkt, $pkt.Length, $multicastEP) | Out-Null

                } catch [System.Net.Sockets.SocketException] {
                    continue  # Receive timeout (500 ms) - expected, keep looping
                } catch {
                    Write-RLog "Loop error: $_"
                    continue
                }
            }
        } catch {
            Write-RLog "Fatal: $_"
        } finally {
            if ($udp) { try { $udp.Close() } catch { } }
        }
    }

    $global:MdnsResponderJob = Start-Job -Name "MdnsResponder" `
        -ScriptBlock $responderBlock `
        -ArgumentList $scriptPath, $hostname

    Write-Log ($msg.MdnsResponderStarted -f $hostname) -Level INFO
}

function Stop-MdnsResponder {
    $job = Get-Job -Name "MdnsResponder" -ErrorAction SilentlyContinue
    if ($job) {
        Stop-Job   -Name "MdnsResponder" -ErrorAction SilentlyContinue
        Remove-Job -Name "MdnsResponder" -Force -ErrorAction SilentlyContinue
    }
    $global:MdnsResponderJob = $null

    # Stop-Job terminates the child process without running finally blocks,
    # so the PID file must be cleaned up here rather than inside the job.
    $pidFilePath = Join-Path $global:ScriptPath "data\mdns_responder.pid"
    if (Test-Path -LiteralPath $pidFilePath) {
        Remove-Item -LiteralPath $pidFilePath -Force -ErrorAction SilentlyContinue
    }

    Write-Log $msg.MdnsResponderStopped -Level INFO
}
