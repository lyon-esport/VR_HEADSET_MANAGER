# VR Headset Manager - web routes: wifi (S9-3).
#
# Route handlers for the encrypted WiFi store and pushing a network to a headset.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: POST /api/connectwifi  - connects USB device to the configured WiFi network
function Invoke-RouteConnectwifi {
    # POST /api/connectwifi
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Claim USB: changing the headset's network changes its address.
        Set-UsbBusy -Seconds 60
        $result = @{ ok = $false; error = '' }
        if (-not ($adbPath -and (Test-Path -LiteralPath $adbPath))) {
            $result.error = 'ADB not found.'
        } else {
            $knownNetworks = Get-WifiNetworks
            $preferredNet  = $knownNetworks | Where-Object { $_.Preferred } | Select-Object -First 1
            if (-not $preferredNet) { $preferredNet = $knownNetworks | Select-Object -First 1 }
            if (-not $preferredNet) {
                $result.error = 'No WiFi network configured. Add one in vrhm_config.'
            } else {
            $wifiSsid = $preferredNet.SSID
            $wifiPwd  = $preferredNet.Password
            # Find USB device
            $usbDeviceId = (& $adbPath devices 2>&1 |
                Where-Object { $_ -match '^\S+\s+device$' -and $_ -notmatch '^\*' -and $_ -notmatch '^\d+\.\d+' } |
                Select-Object -First 1) -replace '\s+device$', ''
            if (-not $usbDeviceId) {
                $result.error = 'No USB device found.'
            } else {
                $usbDev    = [PSCustomObject]@{ DeviceId = $usbDeviceId; ConnectionType = 'USB'; IP = $null; Port = $null }
                $usbBrand  = (Get-HeadsetBrandModel -Device $usbDev -adb $adbPath).Brand
                $result.ok = Connect-HeadsetToWifi -Device $usbDev -Ssid $wifiSsid -Password $wifiPwd -Brand $usbBrand
                if (-not $result.ok) {
                    if ($usbBrand -eq 'Pico') {
                        $result.error = "WiFi picker opened on Pico headset - automated push is not supported (uid 2000 SecurityException). Complete the join on the headset for SSID '$wifiSsid'."
                    } else {
                        $result.error = 'WiFi connection failed.'
                    }
                }
            }
            }
        }
        $jsonOut   = ConvertTo-Json $result -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Internal error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/wifi-networks  - returns known WiFi networks (SSIDs only, passwords masked)
# API: GET /api/wifi-detect  - returns the PC's currently connected WiFi SSID and password
function Invoke-RouteWifiDetect {
    # GET /api/wifi-detect
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Single call: Get-ComputerWifiInfo resolves SSID and password in
        # one pass, instead of two independent netsh round-trips.
        $wifiInfo = Get-ComputerWifiInfo
        $payload  = @{
            ok          = $true
            ssid        = $(if ($wifiInfo) { $wifiInfo.Ssid } else { $null })
            password    = $(if ($wifiInfo) { $wifiInfo.Password } else { $null })
            profileName = $(if ($wifiInfo) { $wifiInfo.ProfileName } else { $null })
        }
        Send-JsonResponse -Response $response -Body $payload
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500
    } finally { Close-HttpResponse -Response $response }
    return
}

function Invoke-RouteWifiNetworks {
    # GET /api/wifi-networks
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Skip any entry without an SSID: a nameless row is not selectable
        # by anything downstream, and it renders as a blank, pushable choice
        # in the remote toolbox's network list.
        $networks  = @(Get-WifiNetworks) | Where-Object { $_ -and $_.SSID }
        $result    = @($networks | ForEach-Object { @{ ssid = $_.SSID; passwordHint = '****'; preferred = $_.Preferred } })
        $jsonOut   = ConvertTo-Json $result -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"Internal error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/wifi-networks/upsert  - add or update a WiFi network {ssid, password}
function Invoke-RouteWifiNetworksUpsert {
    # POST /api/wifi-networks/upsert
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json   = $body | ConvertFrom-Json
        $ssid        = ([string]$json.ssid).Trim()
        $wifiPassword = ([string]$json.password).Trim()
        if (-not $ssid) { throw "SSID is required" }
        $allowOverwrite = [bool]$json.allowOverwrite
        $networks  = @(Get-WifiNetworks)
        # -eq is case-insensitive in PowerShell: SSIDs are matched
        # case-insensitively, the password comparison below is not.
        $existing  = $networks | Where-Object { $_.SSID -eq $ssid }
        $result    = $null
        if ($existing) {
            if ($existing.Password -ceq $wifiPassword) {
                # Nothing would change - do not touch the encrypted store.
                $result = @{ ok = $true; message = 'unchanged'; duplicate = $true; ssid = $ssid }
            } elseif (-not $allowOverwrite) {
                # Known SSID with a different password: refuse silently
                # overwriting it. HTTP 200 - this is a confirmable
                # condition the caller must acknowledge, not an error.
                $result = @{ ok = $false; message = 'duplicate'; duplicate = $true; ssid = $ssid }
            }
        }
        if (-not $result) {
            if ($existing) {
                $existing.Password = $wifiPassword
                $message = "updated"
            } else {
                $isFirst = ($networks.Count -eq 0)
                $networks += [PSCustomObject]@{ SSID = $ssid; Password = $wifiPassword; Preferred = $isFirst }
                $message = "added"
            }
            Save-WifiNetworks -Networks $networks
            $result = @{ ok = $true; message = $message }
        }
        $jsonOut   = ConvertTo-Json $result -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errMsg    = $_.Exception.Message
            $errBytes  = [System.Text.Encoding]::UTF8.GetBytes(("{`"ok`":false,`"error`":`"$errMsg`"}"))
            $response.StatusCode      = 400
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/wifi-networks/delete  - remove a WiFi network {ssid}
function Invoke-RouteWifiNetworksDelete {
    # POST /api/wifi-networks/delete
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json   = $body | ConvertFrom-Json
        $ssid   = ([string]$json.ssid).Trim()
        if (-not $ssid) { throw "SSID is required" }
        $all      = @(Get-WifiNetworks)
        $wasPreferred = [bool]($all | Where-Object { $_.SSID -eq $ssid -and $_.Preferred })
        $networks = @($all | Where-Object { $_.SSID -ne $ssid })
        if ($wasPreferred -and $networks.Count -gt 0) { $networks[0].Preferred = $true }
        Save-WifiNetworks -Networks $networks
        $jsonOut   = ConvertTo-Json @{ ok = $true } -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errMsg    = $_.Exception.Message
            $errBytes  = [System.Text.Encoding]::UTF8.GetBytes(("{`"ok`":false,`"error`":`"$errMsg`"}"))
            $response.StatusCode      = 400
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/wifi-networks/set-preferred  - marks one SSID as preferred {ssid}
function Invoke-RouteWifiNetworksSetPreferred {
    # POST /api/wifi-networks/set-preferred
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json   = $body | ConvertFrom-Json
        $ssid   = ([string]$json.ssid).Trim()
        if (-not $ssid) { throw "SSID is required" }
        $networks = @(Get-WifiNetworks)
        $found = $false
        foreach ($n in $networks) { $n.Preferred = ($n.SSID -eq $ssid); if ($n.SSID -eq $ssid) { $found = $true } }
        if (-not $found) { throw "SSID not found" }
        Save-WifiNetworks -Networks $networks
        $jsonOut   = ConvertTo-Json @{ ok = $true } -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errMsg    = $_.Exception.Message
            $errBytes  = [System.Text.Encoding]::UTF8.GetBytes(("{`"ok`":false,`"error`":`"$errMsg`"}"))
            $response.StatusCode      = 400
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/headsets/push-wifi  body: {"serialNumber":"...","ssid":"..."}
#
# Moves one known headset onto one of the WiFi networks THIS server holds
# the password for. The password never leaves the server: the push runs
# over the server's own ADB connection to the headset (USB when it is
# cabled here, WiFi ADB otherwise).
#
# The headset is scanned first, from its OWN radio - an SSID it cannot see
# (a 6 GHz-only network on an older headset, typically) is refused rather
# than pushed, because pushing it would drop the headset off the network
# with no way back. The reachable known networks come back in
# visibleKnown so the caller can offer an alternative.
#
# Called by the remote VRHM Headset Toolbox and by the console's
# per-headset WiFi action - same function behind both (ADR-0012).
function Invoke-RouteHeadsetsPushWifi {
    # POST /api/headsets/push-wifi
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw "Request body too large" }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
        $json   = $body | ConvertFrom-Json

        $safeSsid = ([string]$json.ssid).Trim()
        if (-not $safeSsid -or $safeSsid.Length -gt 64) { throw "INVALID_SSID" }

        $safeSerial = if ($json.serialNumber) { ([string]$json.serialNumber).Trim() } else { '' }
        $safeName   = if ($json.name)         { ([string]$json.name).Trim() }         else { '' }
        if ($safeSerial.Length -gt 60 -or $safeName.Length -gt 40) { throw "INVALID_HEADSET" }

        $headsets = @(Get-KnownHeadsets)
        $headset  = $null
        if ($safeSerial) {
            $headset = $headsets | Where-Object { $_.SerialNumber -eq $safeSerial } | Select-Object -First 1
        }
        if (-not $headset -and $safeName) {
            $headset = $headsets | Where-Object { $_.Name -eq $safeName } | Select-Object -First 1
        }
        if (-not $headset) { throw "UNKNOWN_HEADSET" }

        $push = Invoke-HeadsetWifiPush -Headset $headset -Ssid $safeSsid -AdbPort $adbPort -adb $adbPath

        Send-JsonResponse -Response $response -Body @{
            ok           = [bool]$push.Ok
            visible      = $push.Visible
            pushed       = [bool]$push.Pushed
            visibleKnown = @($push.VisibleKnown)
            error        = $push.Error
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_SSID'    { 'Invalid or missing WiFi network name.' }
            'INVALID_HEADSET' { 'Invalid headset identifier.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $false; pushed = $false; visibleKnown = @(); error = $errMsg }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}
