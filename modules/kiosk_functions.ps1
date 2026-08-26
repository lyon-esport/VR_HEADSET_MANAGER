#################
# KIOSK SCREENS - CHROME DEVTOOLS PROTOCOL (CDP) FUNCTIONS
#################

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

            # Best-effort read of one response frame - not strictly validated
            try {
                $buffer = New-Object byte[] 8192
                $segment = [System.ArraySegment[byte]]::new($buffer)
                $ws.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult() | Out-Null
            } catch {
                Write-Log "Invoke-CdpNavigate: response read failed (non-fatal) - $($_.Exception.Message)" -Level DEBUG
            }

            return @{ Success = $true }
        } catch {
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

    $chosen = $networks | Where-Object { $_.InterfaceAlias -match '(?i)ethernet' } | Select-Object -First 1
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
    @{IPAddress; Browser; AlreadyKnown}.
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

    $knownIPs = @((Get-KnownKiosks).IPAddress)

    foreach ($device in $openPorts) {
        $ip      = $device.IPAddress
        $cdpInfo = Get-CdpInfo -IP $ip -Port $Port
        if (-not $cdpInfo) { continue }

        $results += [PSCustomObject]@{
            IPAddress    = $ip
            Browser      = $cdpInfo.Browser
            AlreadyKnown = ($knownIPs -contains $ip)
        }
    }

    return $results
}
