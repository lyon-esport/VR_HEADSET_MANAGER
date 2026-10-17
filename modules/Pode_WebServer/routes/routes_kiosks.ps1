# VR Headset Manager - web routes: kiosks (S9-3).
#
# Route handlers for kiosk screens and the advanced kiosk agent (ADR-0013).
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: GET /api/kiosks  - returns known kiosks merged with live status from data\kiosks_status.json
function Invoke-RouteKiosks {
    # GET /api/kiosks
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $kiosks = @(Get-KnownKiosks)
        $statusList = @()
        try {
            $statusList = @(Invoke-DbQuery -Name 'kiosk_status.list')
        } catch {
            $statusList = @()
        }
        # Read the agent cache ONCE, not once per kiosk: this endpoint is
        # polled every 4s by the browser.
        $agentList = @(Get-KioskAgentReports)

        # Index both lists by IP once (first row wins, as Select-Object -First 1 did).
        $statusByIp = @{}
        foreach ($s in $statusList) { $key = [string]$s.IPAddress; if (-not $statusByIp.ContainsKey($key)) { $statusByIp[$key] = $s } }
        $agentByIp = @{}
        foreach ($a in $agentList) { $key = [string]$a.IPAddress; if (-not $agentByIp.ContainsKey($key)) { $agentByIp[$key] = $a } }

        $merged = $kiosks | ForEach-Object {
            $k = $_
            $st = $statusByIp[[string]$k.IPAddress]
            # Agent fields stay $null for basic (v1) kiosks, which never report.
            $ag = $agentByIp[[string]$k.IPAddress]
            [PSCustomObject]@{
                ID            = $k.ID
                Name          = $k.Name
                IPAddress     = $k.IPAddress
                Port          = $k.Port
                PushedURL     = $k.PushedURL
                LastPushedAt  = $k.LastPushedAt
                # Reachable/CdpOpen are INTEGER 0/1 in the table but were
                # real booleans in the JSON this replaced, and this is a
                # public API shape - convert rather than let 1/0 leak out.
                Reachable     = if ($st) { (ConvertTo-DbBool $st.Reachable) -eq 1 } else { $null }
                LatencyMs     = if ($st) { $st.LatencyMs } else { $null }
                CdpOpen       = if ($st) { (ConvertTo-DbBool $st.CdpOpen) -eq 1 }   else { $null }
                CurrentUrl    = if ($st) { $st.CurrentUrl } else { $null }
                Advanced      = ($null -ne $ag)
                AgentStale    = if ($ag) { [bool]$ag.IsStale }        else { $null }
                Hostname      = if ($ag) { $ag.Hostname }             else { $null }
                OSVersion     = if ($ag) { $ag.OS }                   else { $null }
                InterfaceType = if ($ag) { $ag.InterfaceType }        else { $null }
                InterfaceName = if ($ag) { $ag.InterfaceName }        else { $null }
                LinkSpeedMbps = if ($ag) { $ag.LinkSpeedMbps }        else { $null }
                BrowserInfo   = if ($ag) { $ag.Browser }              else { $null }
                UptimeSec     = if ($ag) { $ag.UptimeSec }            else { $null }
                AgentVersion  = if ($ag) { $ag.AgentVersion }         else { $null }
                LastReportAt  = if ($ag) { $ag.LastReportAt }         else { $null }
            }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $true; kiosks = @($merged) }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/add-manual  body: {ip, name, port}
function Invoke-RouteKiosksAddManual {
    # POST /api/kiosks/add-manual
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        $ip = ([string]$json.ip).Trim()
        if (-not $ip) { throw "IP address is required" }
        $name = ([string]$json.name).Trim()
        $port = if ($json.port) { [int]$json.port } else { 9222 }
        Add-Kiosk -IPAddress $ip -Name $name -Port $port
        Write-KioskLog "api add-manual ip=$ip name=$name port=$port result=success" -Level SUCCESS
        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Write-KioskLog "api add-manual result=failed error=$($_.Exception.Message)" -Level ERROR
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/scan  body: {cidr, port}
function Invoke-RouteKiosksScan {
    # POST /api/kiosks/scan
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        $cidr = ([string]$json.cidr).Trim()
        if (-not $cidr) { throw "CIDR is required" }
        $port = if ($json.port) { [int]$json.port } else { 9222 }
        $result = @(Invoke-KioskScan -CIDR $cidr -Port $port)
        Write-KioskLog "api scan cidr=$cidr port=$port discovered=$($result.Count) result=success" -Level SUCCESS
        Send-JsonResponse -Response $response -Body @{ ok = $true; discovered = $result }
    } catch {
        Write-KioskLog "api scan result=failed error=$($_.Exception.Message)" -Level ERROR
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/kiosks/networks  - list local private network interfaces for the scan interface-picker
function Invoke-RouteKiosksNetworks {
    # GET /api/kiosks/networks
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $networks = @(Get-PrivateNetworks)
        Send-JsonResponse -Response $response -Body @{ ok = $true; networks = $networks }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/update  body: {id, field, value}
function Invoke-RouteKiosksUpdate {
    # POST /api/kiosks/update
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        if ($null -eq $json.id) { throw "id is required" }
        if (-not $json.field) { throw "field is required" }
        Update-KioskField -ID ([int]$json.id) -Field ([string]$json.field) -NewValue ([string]$json.value)
        Write-KioskLog "api update id=$($json.id) field=$($json.field) result=success" -Level SUCCESS
        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Write-KioskLog "api update result=failed error=$($_.Exception.Message)" -Level ERROR
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/remove  body: {id}
function Invoke-RouteKiosksRemove {
    # POST /api/kiosks/remove
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        if ($null -eq $json.id) { throw "id is required" }
        Remove-Kiosk -ID ([int]$json.id)
        Write-KioskLog "api remove id=$($json.id) result=success" -Level SUCCESS
        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Write-KioskLog "api remove result=failed error=$($_.Exception.Message)" -Level ERROR
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/push  body: {id, url, confirmLocalhostReplacement}
function Invoke-RouteKiosksPush {
    # POST /api/kiosks/push
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        if ($null -eq $json.id) { throw "id is required" }
        $url = [string]$json.url
        if (-not $url) { throw "url is required" }
        $confirmReplace = [bool]$json.confirmLocalhostReplacement

        $kiosk = Get-KnownKiosks | Where-Object { $_.ID -eq [int]$json.id } | Select-Object -First 1
        if (-not $kiosk) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = "Kiosk not found" }
        } else {
            $replacement = Resolve-LocalhostReplacement -Url $url

            if ($replacement.NeedsReplacement -and -not $confirmReplace) {
                Write-KioskLog "api push id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) needsLocalhostReplacement suggested=$($replacement.SuggestedUrl)" -Level WARNING
                Send-JsonResponse -Response $response -Body @{
                    ok                = $false
                    needsConfirmation = $true
                    suggestedUrl      = $replacement.SuggestedUrl
                    suggestedIP       = $replacement.SuggestedIP
                }
            } else {
                $finalUrl = if ($replacement.NeedsReplacement -and $confirmReplace) { $replacement.SuggestedUrl } else { $url }

                $navResult = Invoke-CdpNavigate -IP $kiosk.IPAddress -Port ([int]$kiosk.Port) -Url $finalUrl

                if ($navResult.Success) {
                    Update-KioskField -ID $kiosk.ID -Field 'PushedURL' -NewValue $finalUrl
                    Update-KioskField -ID $kiosk.ID -Field 'LastPushedAt' -NewValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    Write-KioskLog "api push id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) result=success url=$finalUrl" -Level SUCCESS
                    Send-JsonResponse -Response $response -Body @{ ok = $true }
                } else {
                    Write-KioskLog "api push id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) result=failed error=$($navResult.Error)" -Level ERROR
                    Send-JsonResponse -Response $response -Body @{ ok = $false; error = $navResult.Error }
                }
            }
        }
    } catch {
        Write-KioskLog "api push result=failed error=$($_.Exception.Message)" -Level ERROR
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/kill-browser  body: {id}  - stops the kiosk browser/session
function Invoke-RouteKiosksKillBrowser {
    # POST /api/kiosks/kill-browser
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        if ($null -eq $json.id) { throw "id is required" }

        $kiosk = Get-KnownKiosks | Where-Object { $_.ID -eq [int]$json.id } | Select-Object -First 1
        if (-not $kiosk) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = "Kiosk not found" }
        } else {
            # An advanced kiosk auto-restarts its browser, so a raw CDP Browser.close
            # would just be undone by its watchdog. Stop the advanced session through
            # the agent; basic (v1) kiosks keep the original kill-only behaviour.
            $agent = Get-KioskAgentInfo -IPAddress $kiosk.IPAddress
            if ($agent -and -not $agent.IsStale) {
                $result = Invoke-KioskPowerAction -IPAddress $kiosk.IPAddress -Port ([int]$kiosk.Port) -Action 'agent-stop'
                if ($result.Success) {
                    Write-KioskLog "kill-browser advanced id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) result=queued method=$($result.Method) nonce=$($result.Nonce)" -Level SUCCESS
                    Send-JsonResponse -Response $response -Body @{ ok = $true; restarted = $false; stopped = $true; method = $result.Method }
                } else {
                    Write-KioskLog "kill-browser advanced id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) result=failed method=$($result.Method) error=$($result.Error)" -Level ERROR
                    Send-JsonResponse -Response $response -Body @{ ok = $false; error = $result.Error }
                }
            } else {
                $result = Close-KioskBrowser -IP $kiosk.IPAddress -Port ([int]$kiosk.Port)
                if ($result.Success) {
                    Write-KioskLog "kill-browser basic id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) result=success method=cdp" -Level SUCCESS
                    Send-JsonResponse -Response $response -Body @{ ok = $true; restarted = $false }
                } else {
                    Write-KioskLog "kill-browser basic id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) result=failed method=cdp error=$($result.Error)" -Level ERROR
                    Send-JsonResponse -Response $response -Body @{ ok = $false; error = $result.Error }
                }
            }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/kiosks/cdp-info?id=  - returns live CDP info (Browser, webSocketDebuggerUrl) for one kiosk
function Invoke-RouteKiosksCdpInfo {
    # GET /api/kiosks/cdp-info
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $idRaw = $request.QueryString['id']
        $safeId = [regex]::Match($idRaw, '^\d+$').Value
        if (-not $safeId) { throw "Invalid kiosk id" }
        $kiosk = Get-KnownKiosks | Where-Object { $_.ID -eq [int]$safeId } | Select-Object -First 1
        if (-not $kiosk) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = "Kiosk not found" }
        } else {
            $info = Get-CdpInfo -IP $kiosk.IPAddress -Port ([int]$kiosk.Port)
            if ($null -ne $info) {
                Send-JsonResponse -Response $response -Body @{ ok = $true; cdp = $info }
            } else {
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = "Unreachable or CDP not open" }
            }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/agent-report  - heartbeat from an advanced kiosk (Start-KioskAgent.*)
#
# This is the only endpoint in the project that accepts a POST from a remote
# device rather than from the operator's browser. Security boundary:
#   - the record is keyed on the request's REMOTE ENDPOINT address; any "ip"
#     in the body is ignored, so a kiosk cannot impersonate another one or
#     collect another kiosk's queued command
#   - the body is size-capped here and every string field is length-capped in
#     Save-KioskAgentReport
#   - a first-time report from an unknown IP DOES auto-add a known_kiosks.csv
#     row (Register-KioskFromAgentReport), matching the same LAN-trust posture
#     already applied to headsets via /api/headsets/register-by-serial. A kiosk
#     the operator explicitly removed stays removed (Add-KioskAutoAddIgnore
#     denylist written by Remove-Kiosk) unless manually re-added.
# The response carries any pending operator command (deliver-once).
function Invoke-RouteKiosksAgentReport {
    # POST /api/kiosks/agent-report
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 8192) { throw "Report body too large" }
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 8192
        $json = $bodyRaw | ConvertFrom-Json

        $remoteIp = $request.RemoteEndPoint.Address.ToString()
        # An IPv4 client reaching an IPv6-capable listener shows up as ::ffff:a.b.c.d
        if ($remoteIp -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { $remoteIp = $Matches[1] }

        Save-KioskAgentReport -IPAddress $remoteIp -Report $json | Out-Null

        $reportedPort = if ($json.cdpPort) { [int]$json.cdpPort } else { 9222 }
        Register-KioskFromAgentReport -IPAddress $remoteIp -Hostname (Get-TruncatedText $json.hostname 100) -Port $reportedPort | Out-Null

        $pending = Get-PendingKioskCommand -IPAddress $remoteIp
        Send-JsonResponse -Response $response -Body @{ ok = $true; command = $pending }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/kiosks/power  body: {id, action}  action = reboot|shutdown|browser-restart
function Invoke-RouteKiosksPower {
    # POST /api/kiosks/power
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json
        if ($null -eq $json.id) { throw "id is required" }
        $action = ([string]$json.action).Trim().ToLower()
        if ($action -notin @('reboot', 'shutdown', 'browser-restart')) {
            throw "action must be one of: reboot, shutdown, browser-restart"
        }

        $kiosk = Get-KnownKiosks | Where-Object { $_.ID -eq [int]$json.id } | Select-Object -First 1
        if (-not $kiosk) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = "Kiosk not found" }
        } else {
            $result = Invoke-KioskPowerAction -IPAddress $kiosk.IPAddress -Port ([int]$kiosk.Port) -Action $action
            if ($result.Success) {
                Write-Log "Kiosk power action '$action' sent to $($kiosk.Name) ($($kiosk.IPAddress)) via $($result.Method)." -Level SUCCESS
                Write-KioskLog "api power id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) action=$action result=success method=$($result.Method) nonce=$($result.Nonce)" -Level SUCCESS
                Send-JsonResponse -Response $response -Body @{ ok = $true; method = $result.Method; nonce = $result.Nonce }
            } else {
                Write-KioskLog "api power id=$($kiosk.ID) name=$($kiosk.Name) ip=$($kiosk.IPAddress) action=$action result=failed method=$($result.Method) error=$($result.Error)" -Level ERROR
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = $result.Error; method = $result.Method }
            }
        }
    } catch {
        Write-KioskLog "api power result=failed error=$($_.Exception.Message)" -Level ERROR
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}
