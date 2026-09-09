#################
# KIOSK SCREENS - CHROME DEVTOOLS PROTOCOL (CDP) FUNCTIONS
#################

function Write-KioskLog {
    <#
    .SYNOPSIS
    Writes one kiosk-specific server-side log line to logs\<COMPUTERNAME>\kiosk_<date>.log.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )

    try {
        $folder = $global:logFolder
        if (-not $folder) {
            $computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { 'UNKNOWN' }
            $folder = Join-Path $global:ScriptPath (Join-Path 'logs' $computer)
        }
        if (-not (Test-Path -LiteralPath $folder)) {
            [System.IO.Directory]::CreateDirectory($folder) | Out-Null
        }

        $path = Join-Path $folder ("kiosk_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        $content = $line + [Environment]::NewLine

        if (-not (Test-Path -LiteralPath $path)) {
            if (Get-Command Write-FileWithoutBom -ErrorAction SilentlyContinue) {
                Write-FileWithoutBom -Path $path -Content $content
            } else {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
            }
        } else {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::AppendAllText($path, $content, $utf8NoBom)
        }
    } catch {
        try { Write-Log "Write-KioskLog failed: $($_.Exception.Message)" -Level DEBUG } catch { }
    }
}

function Get-CdpInfo {
    <#
    .SYNOPSIS
    Calls GET http://<IP>:<Port>/json/version on a kiosk PC running Chrome with
    remote debugging enabled. Returns the parsed JSON object (Browser,
    webSocketDebuggerUrl, etc.) or $null if unreachable.
    .PARAMETER IP
    Kiosk PC IP address.
    .PARAMETER Port
    Chrome remote debugging port (default 9222).
    .PARAMETER TimeoutSec
    Request timeout in seconds (default 2).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [int]$TimeoutSec = 2
    )
    try {
        $url  = "http://${IP}:${Port}/json/version"
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $resp
    } catch {
        Write-Log "Get-CdpInfo: unreachable at ${IP}:${Port} - $($_.Exception.Message)" -Level DEBUG
        return $null
    }
}


function Get-CdpTabs {
    <#
    .SYNOPSIS
    Calls GET http://<IP>:<Port>/json/list and returns the array of open Chrome
    tabs (id, type, url, webSocketDebuggerUrl), or @() if unreachable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [int]$TimeoutSec = 2
    )
    try {
        $url  = "http://${IP}:${Port}/json/list"
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp) { return @($resp) }
        return @()
    } catch {
        Write-Log "Get-CdpTabs: unreachable at ${IP}:${Port} - $($_.Exception.Message)" -Level DEBUG
        return @()
    }
}


function Invoke-CdpNavigate {
    <#
    .SYNOPSIS
    Navigates the active page tab of a kiosk's Chrome instance to a given URL via
    the CDP WebSocket API (Page.navigate). Returns @{Success; Error}.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [Parameter(Mandatory)]
        [string]$Url,
        [int]$TimeoutSec = 5
    )

    $tabs = Get-CdpTabs -IP $IP -Port $Port -TimeoutSec $TimeoutSec
    if (-not $tabs -or $tabs.Count -eq 0) {
        # Distinguish "kiosk unreachable / not a CDP endpoint" from "reachable but no page tab",
        # since the two need very different troubleshooting (bad IP/hostname vs. Chrome state).
        $cdpInfo = Get-CdpInfo -IP $IP -Port $Port -TimeoutSec $TimeoutSec
        if (-not $cdpInfo) {
            return @{ Success = $false; Error = "Cannot reach Chrome debug endpoint at ${IP}:${Port} - check the kiosk's IP address and that Chrome remote debugging is running" }
        }
    }
    $tab = $tabs | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
    if (-not $tab) {
        return @{ Success = $false; Error = "No page tab found on kiosk" }
    }

    $ws  = $null
    $cts = $null
    try {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))

        try {
            $ws.ConnectAsync([Uri]$tab.webSocketDebuggerUrl, $cts.Token).GetAwaiter().GetResult() | Out-Null
        } catch {
            return @{ Success = $false; Error = "WebSocket connect failed: $($_.Exception.Message)" }
        }

        try {
            $payload = @{ id = 1; method = "Page.navigate"; params = @{ url = $Url } } | ConvertTo-Json -Compress
            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null

            # Read and validate the matching CDP response. Page.navigate can fail
            # while the WebSocket send still succeeds, so check the JSON error node.
            try {
                $buffer = New-Object byte[] 8192
                $cdpResponse = $null
                while (-not $cdpResponse) {
                    $builder = [System.Text.StringBuilder]::new()
                    do {
                        $segment = [System.ArraySegment[byte]]::new($buffer)
                        $receive = $ws.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
                        if ($receive.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                            return @{ Success = $false; Error = "Chrome closed the WebSocket before confirming navigation" }
                        }
                        if ($receive.Count -gt 0) {
                            [void]$builder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $receive.Count))
                        }
                    } until ($receive.EndOfMessage)

                    $responseText = $builder.ToString()
                    if (-not $responseText) {
                        continue
                    }

                    try {
                        $candidateResponse = $responseText | ConvertFrom-Json
                    } catch {
                        return @{ Success = $false; Error = "Chrome returned an invalid CDP response: $responseText" }
                    }

                    if ($candidateResponse.id -eq 1) {
                        $cdpResponse = $candidateResponse
                    }
                }
                if ($cdpResponse.error) {
                    $code = $cdpResponse.error.code
                    $message = $cdpResponse.error.message
                    return @{ Success = $false; Error = "Chrome rejected navigation ($code): $message" }
                }
            } catch {
                return @{ Success = $false; Error = "CDP response read failed: $($_.Exception.Message)" }
            }

            Write-KioskLog "navigate ip=$IP port=$Port result=success url=$Url" -Level SUCCESS
            return @{ Success = $true }
        } catch {
            Write-KioskLog "navigate ip=$IP port=$Port result=failed error=$($_.Exception.Message)" -Level ERROR
            return @{ Success = $false; Error = "Navigate send failed: $($_.Exception.Message)" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        try {
            if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
            }
        } catch { }
        if ($ws)  { try { $ws.Dispose() }  catch { } }
        if ($cts) { try { $cts.Dispose() } catch { } }
    }
}


function Close-KioskBrowser {
    <#
    .SYNOPSIS
    Closes the whole Chrome browser process on a kiosk PC via the CDP
    WebSocket API (Browser.close), using the browser-level webSocketDebuggerUrl
    from Get-CdpInfo (not a per-tab one). Returns @{Success; Error}. The
    kiosk launcher script does not auto-restart Chrome, so the operator must
    relaunch it manually on the kiosk device afterwards.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port       = 9222,
        [int]$TimeoutSec = 5
    )

    $cdpInfo = Get-CdpInfo -IP $IP -Port $Port -TimeoutSec $TimeoutSec
    if (-not $cdpInfo -or -not $cdpInfo.webSocketDebuggerUrl) {
        return @{ Success = $false; Error = "Cannot reach Chrome debug endpoint at ${IP}:${Port} - check the kiosk's IP address and that Chrome remote debugging is running" }
    }

    $ws  = $null
    $cts = $null
    try {
        $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))

        try {
            $ws.ConnectAsync([Uri]$cdpInfo.webSocketDebuggerUrl, $cts.Token).GetAwaiter().GetResult() | Out-Null
        } catch {
            return @{ Success = $false; Error = "WebSocket connect failed: $($_.Exception.Message)" }
        }

        try {
            $payload = @{ id = 1; method = "Browser.close" } | ConvertTo-Json -Compress
            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null
            # No response read: Browser.close tears down the browser (and this socket)
            # immediately, so waiting for a reply here would just time out.
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = "Browser.close send failed: $($_.Exception.Message)" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        try {
            if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
            }
        } catch { }
        if ($ws)  { try { $ws.Dispose() }  catch { } }
        if ($cts) { try { $cts.Dispose() } catch { } }
    }
}


function Get-KioskReachability {
    <#
    .SYNOPSIS
    Cheap reachability poll for a kiosk PC: ICMP ping + CDP TCP port check, plus
    (when the debug port is open) the URL actually showing on the kiosk's tab
    right now - this is ground truth for what's on screen, independent of
    whatever VRHM last attempted to push (which goes stale the moment the
    kiosk PC or Chrome itself restarts back to a blank tab).
    Returns @{Reachable; LatencyMs; CdpOpen; CurrentUrl}. CurrentUrl is $null
    when the debug port isn't reachable (kiosk PC down, or Chrome not running
    in debug mode) - in that case the caller has no way to know what's on
    screen and should not assume anything.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$Port = 9222
    )

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply      = $ping.Send($IP, 400)
        $reachable  = $reply.Status -eq 'Success'
        $latencyMs  = if ($reachable) { $reply.RoundtripTime } else { $null }
    } catch {
        $reachable = $false
        $latencyMs = $null
    } finally {
        $ping.Dispose()
    }

    $cdpOpen    = $false
    $currentUrl = $null
    if ($reachable) {
        # A raw TCP connect is not enough here: when the kiosk needed the
        # netsh portproxy workaround (Chrome ignores --remote-debugging-address
        # and only binds loopback), the portproxy rule is a kernel-level relay
        # that keeps accepting TCP connections even after Chrome itself has
        # exited - a plain Test-Port would keep reporting CdpOpen=true against
        # a dead browser. Only a real CDP HTTP response proves the debug
        # endpoint is actually alive right now.
        $cdpOpen = $null -ne (Get-CdpInfo -IP $IP -Port $Port -TimeoutSec 2)
        if ($cdpOpen) {
            $tabs = Get-CdpTabs -IP $IP -Port $Port -TimeoutSec 2
            $tab  = $tabs | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
            if ($tab) { $currentUrl = $tab.url }
        }
    }

    return @{ Reachable = $reachable; LatencyMs = $latencyMs; CdpOpen = $cdpOpen; CurrentUrl = $currentUrl }
}


function Resolve-LocalhostReplacement {
    <#
    .SYNOPSIS
    Detects whether a URL points at localhost/127.0.0.1 (would resolve to the
    kiosk PC itself, not this VRHM host) and suggests a LAN IP replacement.
    Returns @{NeedsReplacement; SuggestedIP; SuggestedUrl; OriginalUrl} or
    @{NeedsReplacement=$false}.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        $uri = [Uri]$Url
    } catch {
        return @{ NeedsReplacement = $false }
    }

    if ($uri.Host -notin @('localhost', '127.0.0.1')) {
        return @{ NeedsReplacement = $false }
    }

    $networks = @(Get-PrivateNetworks)
    if (-not $networks -or $networks.Count -eq 0) {
        return @{ NeedsReplacement = $false }
    }

    $chosen = $networks | Where-Object { $_.HasDefaultGateway } | Select-Object -First 1
    if (-not $chosen) { $chosen = $networks | Where-Object { $_.InterfaceAlias -match '(?i)ethernet' } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $networks | Select-Object -First 1 }
    $chosenIP = $chosen.IPAddress

    $suggestedUri = [UriBuilder]$uri
    $suggestedUri.Host = $chosenIP

    return @{
        NeedsReplacement = $true
        SuggestedIP      = $chosenIP
        SuggestedUrl     = $suggestedUri.Uri.AbsoluteUri
        OriginalUrl      = $Url
    }
}


function Invoke-KioskScan {
    <#
    .SYNOPSIS
    Scans a CIDR range for open kiosk CDP ports and confirms each open port is
    really a Chrome DevTools endpoint. Returns an array of
    @{IPAddress; Browser; AlreadyKnown; Advanced; Hostname; OSVersion;
    InterfaceType; AgentVersion}.
    The agent fields are populated from the kiosk agent cache (data\kiosks_agent.json)
    for kiosks running the advanced launcher (Start-KioskAgent.*), which report
    themselves to this server; they stay $null for basic (v1) kiosks.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CIDR,
        [int]$Port    = 9222,
        [int]$Timeout = 300
    )

    $openPorts = Test-PortForCidr -CIDR $CIDR -Port $Port -Timeout $Timeout
    $results   = @()

    if (-not $openPorts) { return $results }

    # Project each row rather than enumerating the member off the array: with no
    # kiosks registered, `(Get-KnownKiosks).IPAddress` throws under strict mode
    # because no element carries the property.
    $knownIPs = @(Get-KnownKiosks | ForEach-Object { $_.IPAddress })

    foreach ($device in $openPorts) {
        $ip      = $device.IPAddress
        $cdpInfo = Get-CdpInfo -IP $ip -Port $Port
        if (-not $cdpInfo) { continue }

        $agent = Get-KioskAgentInfo -IPAddress $ip

        $results += [PSCustomObject]@{
            IPAddress     = $ip
            Browser       = $cdpInfo.Browser
            AlreadyKnown  = ($knownIPs -contains $ip)
            Advanced      = ($null -ne $agent)
            Hostname      = if ($agent) { $agent.Hostname }      else { $null }
            OSVersion     = if ($agent) { $agent.OS }            else { $null }
            InterfaceType = if ($agent) { $agent.InterfaceType } else { $null }
            AgentVersion  = if ($agent) { $agent.AgentVersion }  else { $null }
        }
    }

    return $results
}


#################
# KIOSK AGENT - REPORT CACHE AND COMMAND QUEUE
#
# The advanced kiosk launcher (website\kiosk-launcher\Start-KioskAgent.ps1 /
# Start-KioskAgent-Linux.sh) never listens on a port. It only makes outbound
# calls: to its own loopback CDP port, and to this server's
# POST /api/kiosks/agent-report endpoint every few seconds. That request
# carries the kiosk's hardware/OS/link info (cached here by Save-KioskAgentReport)
# and its response carries any pending operator command (queued here by
# Add-KioskCommand, drained by Get-PendingKioskCommand).
#
# Commands are stored one-file-per-command rather than in a shared JSON list:
# both the console (main.ps1 process) and the web server (separate process)
# queue commands, and an atomic file create needs no cross-process lock.
#################

function Get-ServerLanUrl {
    <#
    .SYNOPSIS
    Returns this server's LAN base URL ("http://192.168.1.37:8080") - the address a
    kiosk on the same network must use to reach us. Prefers the interface holding the
    default route, then an Ethernet-named interface, mirroring Resolve-LocalhostReplacement.
    Get-PrivateNetworks already excludes virtual/hypervisor adapters (Hyper-V, WSL, VMware,
    VPN), so a private-range IP on one of those (e.g. a Hyper-V "vEthernet (...)" switch)
    is never picked in place of the real LAN adapter. Returns $null when no private network
    is available.
    .EXAMPLE
    $url = Get-ServerLanUrl        # -> http://192.168.1.37:8080
    #>
    param(
        [int]$Port = $global:WebServer_port
    )

    $networks = @(Get-PrivateNetworks)
    if (-not $networks -or $networks.Count -eq 0) { return $null }

    $chosen = $networks | Where-Object { $_.HasDefaultGateway } | Select-Object -First 1
    if (-not $chosen) { $chosen = $networks | Where-Object { $_.InterfaceAlias -match '(?i)ethernet' } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $networks | Select-Object -First 1 }
    if (-not $chosen -or -not $chosen.IPAddress) { return $null }

    return ("http://{0}:{1}" -f $chosen.IPAddress, $Port)
}


# ---------------------------------------------------------------------------
# RETIRED PATH HELPERS
#
# The three helpers below name files the application no longer reads or writes:
# agent reports, the command queue and the auto-add denylist are tables now.
# They are kept because the legacy importer still has to find those files once,
# on the first startup after the migration, and because a support request may
# ask where the pre-migration data went. Do not use them in new code.
# ---------------------------------------------------------------------------

function Get-KioskAgentReportPath {
    <#
    .SYNOPSIS
    RETIRED - path of the pre-migration data\kiosks_agent.json. The agent cache
    is the kiosk_agent_reports table now; this is only for the legacy importer.
    #>
    return (Join-Path $global:ScriptPath "data\kiosks_agent.json")
}


# Get-KioskCommandFolder and ConvertTo-KioskIpToken were removed here.
#
# They served the pre-migration queue, which was one JSON file per command under
# data\kiosk_commands\. That shape existed ONLY because there was no
# cross-process lock: both the console and the web server queue commands, and an
# atomic file create was the only way two writers could share a queue safely
# (ADR-0013). ConvertTo-KioskIpToken existed for the same reason - the address
# became part of a filename, so a malformed one was a path-traversal risk.
#
# The queue is the kiosk_commands table now (ADR-0017). Delivery is one
# statement, kiosk_commands.claim, a DELETE ... RETURNING that reads and removes
# the oldest row atomically - so deliver-once is enforced by the database rather
# than by the filesystem, and an address is a column value that needs no
# sanitising. Neither helper had a caller: the legacy importer builds the folder
# path itself, because it must read the old layout regardless of what the app
# now uses.


function Get-TruncatedText {
    <#
    .SYNOPSIS
    Returns a string capped at -Max characters ($null passes through). Used to
    bound every string field of an agent report before it is persisted - that
    payload arrives over the network from an unauthenticated LAN device.
    #>
    param(
        $Value,
        [int]$Max = 200
    )
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s.Length -gt $Max) { return $s.Substring(0, $Max) }
    return $s
}


function Save-KioskAgentReport {
    <#
    .SYNOPSIS
    Merges one agent report into data\kiosks_agent.json, keyed by IP address.
    The caller (the web server endpoint) MUST pass the IP taken from the request's
    remote endpoint, never one taken from the request body.
    .EXAMPLE
    Save-KioskAgentReport -IPAddress "192.168.1.93" -Report $parsedBody
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [Parameter(Mandatory)]
        $Report
    )

    $entry = [PSCustomObject]@{
        IPAddress          = $IPAddress
        MachineId          = Get-TruncatedText $Report.machineId 100
        Hostname           = Get-TruncatedText $Report.hostname 100
        OS                 = Get-TruncatedText $Report.os 150
        OSFamily           = Get-TruncatedText $Report.osFamily 30
        InterfaceType      = Get-TruncatedText $Report.interfaceType 30
        InterfaceName      = Get-TruncatedText $Report.interfaceName 100
        LinkSpeedMbps      = if ($null -ne $Report.linkSpeedMbps) { [int]$Report.linkSpeedMbps } else { $null }
        Browser            = Get-TruncatedText $Report.browser 100
        BrowserRunning     = [bool]$Report.browserRunning
        CdpPort            = if ($null -ne $Report.cdpPort) { [int]$Report.cdpPort } else { $null }
        CurrentUrl         = Get-TruncatedText $Report.currentUrl 500
        UptimeSec          = if ($null -ne $Report.uptimeSec) { [int64]$Report.uptimeSec } else { $null }
        AutoRestartBrowser = [bool]$Report.autoRestartBrowser
        AgentVersion       = Get-TruncatedText $Report.version 20
        LastAck            = if ($Report.ack) { Get-TruncatedText ("{0}/{1}/{2}" -f $Report.ack.cmd, $Report.ack.nonce, $Report.ack.result) 100 } else { $null }
        LastReportAt       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    # Read the previous row BEFORE the upsert overwrites it: the change-detection
    # log below is the only reason it is needed.
    $previous = $null
    try {
        $previous = @(Invoke-DbQuery -Name 'agent.get' -Parameters @{ ip_address = $IPAddress }) | Select-Object -First 1
    } catch { }

    try {
        Invoke-DbNonQuery -Name 'agent.upsert' -Parameters @{
            ip_address           = $entry.IPAddress
            machine_id           = $entry.MachineId
            hostname             = $entry.Hostname
            os                   = $entry.OS
            os_family            = $entry.OSFamily
            interface_type       = $entry.InterfaceType
            interface_name       = $entry.InterfaceName
            link_speed_mbps      = $entry.LinkSpeedMbps
            browser              = $entry.Browser
            browser_running      = (ConvertTo-DbBool $entry.BrowserRunning)
            cdp_port             = $entry.CdpPort
            current_url          = $entry.CurrentUrl
            uptime_sec           = $entry.UptimeSec
            auto_restart_browser = (ConvertTo-DbBool $entry.AutoRestartBrowser)
            agent_version        = $entry.AgentVersion
            last_ack             = $entry.LastAck
            last_report_at       = $entry.LastReportAt
        } | Out-Null

        if (-not $previous) {
            Write-KioskLog "agent report new ip=$IPAddress host=$($entry.Hostname) browserRunning=$($entry.BrowserRunning) url=$($entry.CurrentUrl)" -Level INFO
        } elseif ($previous.CurrentUrl -ne $entry.CurrentUrl -or ((ConvertTo-DbBool $previous.BrowserRunning) -ne (ConvertTo-DbBool $entry.BrowserRunning)) -or $previous.AgentVersion -ne $entry.AgentVersion) {
            Write-KioskLog "agent report changed ip=$IPAddress host=$($entry.Hostname) browserRunning=$($entry.BrowserRunning) url=$($entry.CurrentUrl)" -Level INFO
        }
    } catch {
        Write-Log "Save-KioskAgentReport: failed to store the report for $IPAddress - $($_.Exception.Message)" -Level WARNING
        Write-KioskLog "agent report write failed ip=$IPAddress error=$($_.Exception.Message)" -Level WARNING
        return $false
    }
    return $true
}


function Get-KioskAgentReports {
    <#
    .SYNOPSIS
    Returns EVERY cached agent report, each with an added IsStale flag, or @() when
    no kiosk has ever reported.
    Use this instead of calling Get-KioskAgentInfo in a loop: /api/kiosks is polled
    every 4s by the browser, and a per-kiosk call would re-read and re-parse the
    whole cache file once per kiosk on every poll.
    .PARAMETER StaleAfterSec
    A report older than this is flagged IsStale (default 30 - about 6 missed reports
    at the default 5s interval).
    #>
    param(
        [int]$StaleAfterSec = 30
    )

    try {
        $all = @(Invoke-DbQuery -Name 'agent.list')
    } catch {
        Write-Log "Get-KioskAgentReports: could not read the agent cache - $($_.Exception.Message)" -Level DEBUG
        return @()
    }

    # IsStale is computed here, not in SQL: the threshold is a parameter of the
    # question being asked, not a property of the stored row.
    $now = Get-Date
    foreach ($entry in $all) {
        if (-not $entry) { continue }
        $isStale = $true
        if ($entry.LastReportAt) {
            try {
                $last    = [datetime]::ParseExact([string]$entry.LastReportAt, 'yyyy-MM-dd HH:mm:ss', $null)
                $isStale = ($now - $last).TotalSeconds -gt $StaleAfterSec
            } catch {
                $isStale = $true
            }
        }
        Add-Member -InputObject $entry -NotePropertyName 'IsStale' -NotePropertyValue $isStale -Force
        # These two come back as INTEGER 0/1, but callers and the JSON the web
        # UI receives expect real booleans. Note ConvertTo-BoolField is the
        # WRONG tool here: it string-compares against "True", so an integer 1
        # would read as false. ConvertTo-DbBool accepts every representation.
        Add-Member -InputObject $entry -NotePropertyName 'BrowserRunning'     -NotePropertyValue ((ConvertTo-DbBool $entry.BrowserRunning) -eq 1)     -Force
        Add-Member -InputObject $entry -NotePropertyName 'AutoRestartBrowser' -NotePropertyValue ((ConvertTo-DbBool $entry.AutoRestartBrowser) -eq 1) -Force
    }

    return $all
}


function Get-KioskAgentInfo {
    <#
    .SYNOPSIS
    Returns the cached agent report for one kiosk IP, with an added IsStale flag,
    or $null when that kiosk has never reported (i.e. it runs the basic v1 launcher,
    or was started without -ServerUrl).
    For more than one kiosk at a time, call Get-KioskAgentReports once instead.
    .EXAMPLE
    $agent = Get-KioskAgentInfo -IPAddress "192.168.1.93"
    if ($agent -and -not $agent.IsStale) { "Advanced kiosk: $($agent.Hostname)" }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [int]$StaleAfterSec = 30
    )

    # Queries one row rather than reading everything and filtering. As a file
    # this had to parse the whole cache per call, which is why the console
    # redraw cost one full parse per kiosk (Show-SubMenu-KioskScreens) and why
    # /api/kiosks had to use the plural form. Both are now cheap either way.
    $entry = $null
    try {
        $entry = @(Invoke-DbQuery -Name 'agent.get' -Parameters @{ ip_address = $IPAddress }) | Select-Object -First 1
    } catch {
        Write-Log "Get-KioskAgentInfo: could not read the agent cache - $($_.Exception.Message)" -Level DEBUG
        return $null
    }
    if (-not $entry) { return $null }

    $isStale = $true
    if ($entry.LastReportAt) {
        try {
            $last    = [datetime]::ParseExact([string]$entry.LastReportAt, 'yyyy-MM-dd HH:mm:ss', $null)
            $isStale = ((Get-Date) - $last).TotalSeconds -gt $StaleAfterSec
        } catch {
            $isStale = $true
        }
    }
    Add-Member -InputObject $entry -NotePropertyName 'IsStale' -NotePropertyValue $isStale -Force
    Add-Member -InputObject $entry -NotePropertyName 'BrowserRunning'     -NotePropertyValue ((ConvertTo-DbBool $entry.BrowserRunning) -eq 1)     -Force
    Add-Member -InputObject $entry -NotePropertyName 'AutoRestartBrowser' -NotePropertyValue ((ConvertTo-DbBool $entry.AutoRestartBrowser) -eq 1) -Force
    return $entry
}


function Get-KioskAutoAddIgnorePath {
    <#
    .SYNOPSIS
    Returns the path of data\kiosk_autoadd_ignore.json - a flat JSON array of IP
    addresses that must NOT be auto-registered from an agent report, because the
    operator explicitly removed that kiosk (see Remove-Kiosk / Add-KioskAutoAddIgnore).
    Manual re-add (console/web "Add kiosk", or scan) is unaffected - this only gates
    the automatic agent-report path.
    #>
    return (Join-Path $global:ScriptPath "data\kiosk_autoadd_ignore.json")
}


function Test-KioskAutoAddIgnored {
    <#
    .SYNOPSIS
    Returns $true if -IPAddress is on the auto-add denylist. A missing/unreadable
    file means nothing is ignored.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress
    )

    try {
        return ([int](Invoke-DbScalar -Name 'kiosk_ignore.exists' -Parameters @{ ip_address = $IPAddress }) -gt 0)
    } catch {
        # An unreadable denylist means nothing is ignored, same as a missing
        # file did: failing open here only risks re-adding a kiosk, while
        # failing closed would silently drop every auto-registration.
        Write-Log "Test-KioskAutoAddIgnored: could not read the denylist - $($_.Exception.Message)" -Level DEBUG
        return $false
    }
}


function Add-KioskAutoAddIgnore {
    <#
    .SYNOPSIS
    Adds -IPAddress to the auto-add denylist (dedup), so a still-running kiosk
    agent cannot silently re-add itself after the operator removes it. Called by
    Remove-Kiosk when the removed kiosk has agent-report history.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress
    )

    try {
        # INSERT OR IGNORE: the primary key does the dedup, so no read-then-write.
        $added = [int](Invoke-DbNonQuery -Name 'kiosk_ignore.insert' -Parameters @{ ip_address = $IPAddress })
        if ($added -gt 0) {
            Write-Log "Add-KioskAutoAddIgnore: $IPAddress will no longer be auto-registered from agent reports." -Level INFO
        }
    } catch {
        Write-Log "Add-KioskAutoAddIgnore: failed to denylist $IPAddress - $($_.Exception.Message)" -Level WARNING
    }
}


function Register-KioskFromAgentReport {
    <#
    .SYNOPSIS
    Auto-adds a kiosk to known_kiosks.csv from its first agent heartbeat. No-op if
    the IP is already known, or was denylisted by Remove-Kiosk (Add-KioskAutoAddIgnore).
    Never throws - a registration failure must not break the agent's heartbeat/
    command-delivery response.
    .EXAMPLE
    Register-KioskFromAgentReport -IPAddress "192.168.1.93" -Hostname "LOBBY-PC" -Port 9222
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [string]$Hostname,
        [int]$Port = 9222
    )

    try {
        # Ask the table, not a snapshot. Besides being current - the console and
        # another agent's heartbeat can both add kiosks at any moment - this
        # avoids `$known.IPAddress` on a possibly-empty array, which throws
        # under Set-StrictMode because the property exists on no element.
        if ([int](Invoke-DbScalar -Name 'kiosks.exists_ip' -Parameters @{ ip_address = $IPAddress }) -gt 0) { return $false }
        if (Test-KioskAutoAddIgnored -IPAddress $IPAddress) { return $false }

        $name = if ($Hostname) { $Hostname } else { $IPAddress }
        Add-Kiosk -IPAddress $IPAddress -Name $name -Port $Port

        Write-Log "Register-KioskFromAgentReport: auto-added kiosk '$name' ($IPAddress) from its first agent report." -Level SUCCESS
        Write-KioskLog "auto-register ip=$IPAddress host=$name port=$Port" -Level SUCCESS
        return $true
    } catch {
        Write-Log "Register-KioskFromAgentReport: failed for $IPAddress - $($_.Exception.Message)" -Level WARNING
        return $false
    }
}


function Add-KioskCommand {
    <#
    .SYNOPSIS
    Queues one command for an advanced kiosk. The kiosk picks it up on its next
    report. Returns the nonce, or $null on failure.
    .PARAMETER Cmd
    reboot | shutdown | browser-restart | agent-stop
    .EXAMPLE
    Add-KioskCommand -IPAddress "192.168.1.93" -Cmd "reboot"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [Parameter(Mandatory)]
        [ValidateSet('reboot', 'shutdown', 'browser-restart', 'agent-stop')]
        [string]$Cmd,
        [int]$DelaySec = 5
    )

    $now      = [datetimeoffset]::UtcNow
    $nonce    = [int64]$now.ToUnixTimeMilliseconds()
    $queuedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

    try {
        Invoke-DbNonQuery -Name 'kiosk_commands.insert' -Parameters @{
            ip_address  = $IPAddress
            cmd         = $Cmd
            nonce       = $nonce
            delay_sec   = $DelaySec
            queued_at   = $queuedAt
            # Seconds, not milliseconds: the claim compares this against a
            # wall-clock age in seconds.
            queued_unix = [int64]$now.ToUnixTimeSeconds()
        } | Out-Null
        Write-Log "Add-KioskCommand: queued '$Cmd' for kiosk $IPAddress (nonce $nonce)." -Level INFO
        Write-KioskLog "command queued ip=$IPAddress cmd=$Cmd nonce=$nonce delaySec=$DelaySec" -Level INFO
        return $nonce
    } catch {
        Write-Log "Add-KioskCommand: failed to queue '$Cmd' for $IPAddress - $($_.Exception.Message)" -Level ERROR
        Write-KioskLog "command queue failed ip=$IPAddress cmd=$Cmd error=$($_.Exception.Message)" -Level ERROR
        return $null
    }
}


function Get-PendingKioskCommand {
    <#
    .SYNOPSIS
    Returns the oldest pending command for a kiosk and DELETES it (deliver-once),
    or $null when the queue is empty. Commands older than -MaxAgeSec are discarded
    without being delivered: a reboot queued while a kiosk was powered off must not
    fire the moment it comes back an hour later.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [int]$MaxAgeSec = 300
    )

    # Each iteration claims the oldest queued command with a single
    # DELETE ... RETURNING, so read-and-remove is one atomic step. Two agents
    # reporting at the same instant can never both receive the same command,
    # which is what the old one-file-per-command layout bought with an atomic
    # file create; the database gives it directly.
    $nowUnix = [int64]([datetimeoffset]::UtcNow.ToUnixTimeSeconds())

    while ($true) {
        $cmdObj = $null
        try {
            $cmdObj = @(Invoke-DbQuery -Name 'kiosk_commands.claim' -Parameters @{ ip_address = $IPAddress }) | Select-Object -First 1
        } catch {
            Write-Log "Get-PendingKioskCommand: could not claim a command for $IPAddress - $($_.Exception.Message)" -Level WARNING
            return $null
        }
        if (-not $cmdObj) { return $null }

        $ageSec = $nowUnix - [int64]$cmdObj.queued_unix
        if ($ageSec -gt $MaxAgeSec) {
            # Already deleted by the claim, so it is gone for good - which is
            # the point: a reboot queued while a kiosk was powered off must not
            # fire the moment it comes back an hour later.
            Write-Log "Get-PendingKioskCommand: discarded stale '$($cmdObj.cmd)' for $IPAddress (queued $([int]$ageSec)s ago)." -Level WARNING
            continue
        }

        Write-Log "Get-PendingKioskCommand: delivering '$($cmdObj.cmd)' to kiosk $IPAddress (nonce $($cmdObj.nonce))." -Level INFO
        Write-KioskLog "command delivered ip=$IPAddress cmd=$($cmdObj.cmd) nonce=$($cmdObj.nonce)" -Level INFO

        # queued_unix is an internal ordering/TTL column. The rest of the object
        # is serialised straight into the agent-report reply, and the kiosk
        # agents parse exactly cmd/nonce/delaySec/ip/queuedAt.
        return ($cmdObj | Select-Object -Property cmd, nonce, delaySec, ip, queuedAt)
    }
}


function Invoke-KioskPowerAction {
    <#
    .SYNOPSIS
    Orders a power action on a kiosk screen. Preferred path: queue the command for
    the kiosk's agent to collect on its next report (works even when Chrome is
    closed). Fallback for a kiosk with no live agent: push the kiosk_command.html
    sentinel page over CDP - the advanced launcher watches its own loopback CDP for
    that URL, and picking it up also teaches it this server's address.
    Returns @{Success; Method; Error; Nonce}.
    .PARAMETER Action
    reboot | shutdown | browser-restart | agent-stop
    .EXAMPLE
    Invoke-KioskPowerAction -IPAddress "192.168.1.93" -Port 9222 -Action reboot
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IPAddress,
        [int]$Port = 9222,
        [Parameter(Mandatory)]
        [ValidateSet('reboot', 'shutdown', 'browser-restart', 'agent-stop')]
        [string]$Action,
        [int]$DelaySec = 5
    )

    $agent = Get-KioskAgentInfo -IPAddress $IPAddress

    if ($agent -and -not $agent.IsStale) {
        $nonce = Add-KioskCommand -IPAddress $IPAddress -Cmd $Action -DelaySec $DelaySec
        if ($null -eq $nonce) {
            return @{ Success = $false; Method = 'agent'; Error = "Could not queue the command"; Nonce = $null }
        }
        return @{ Success = $true; Method = 'agent'; Error = $null; Nonce = $nonce }
    }

    # ---- Fallback: CDP sentinel page ----
    $serverUrl = Get-ServerLanUrl
    if (-not $serverUrl) {
        return @{ Success = $false; Method = 'sentinel'; Error = "No agent report from this kiosk, and no local LAN address to build the fallback command URL"; Nonce = $null }
    }

    $nonce = [int64]([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds())
    $url   = "{0}/kiosk_command.html?cmd={1}&nonce={2}&delay={3}" -f $serverUrl, $Action, $nonce, $DelaySec

    $navResult = Invoke-CdpNavigate -IP $IPAddress -Port $Port -Url $url
    if ($navResult.Success) {
        Write-Log "Invoke-KioskPowerAction: pushed '$Action' sentinel to kiosk $IPAddress (nonce $nonce)." -Level INFO
        return @{ Success = $true; Method = 'sentinel'; Error = $null; Nonce = $nonce }
    }

    return @{ Success = $false; Method = 'sentinel'; Error = $navResult.Error; Nonce = $null }
}
