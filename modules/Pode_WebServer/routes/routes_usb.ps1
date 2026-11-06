# VR Headset Manager - web routes: usb (S9-3).
#
# Route handlers for USB onboarding and the remote toolbox downloads (ADR-0021, ADR-0022).
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: POST /api/headset-connection-check  body: {"name":"Q3_Blue"}
# Returns: {"usb":bool,"wifi":bool}
function Invoke-RouteHeadsetConnectionCheck {
    # POST /api/headset-connection-check
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $body | ConvertFrom-Json
        $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $rows    = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }

        # Read the published snapshot instead of shelling out. This route is
        # polled every 5 s per open apps page, and it used to spawn an
        # "adb devices" AND run Get-UsbDeviceSpeed - which walked the whole
        # PnP tree, unfiltered and uncached - on every one of those polls.
        $usbAvailable = $false
        $usbSpeed     = $null
        if ($headset.SerialNumber) {
            $snap = Get-PublishedUsbSnapshot
            if ($snap -and $snap.SerialNumber -eq $headset.SerialNumber) {
                $usbAvailable = $true
                $usbSpeed     = $snap.UsbSpeed
            }
        }

        # Either WiFi ADB mode (ADR-0034): classic port, or the published TLS endpoint answering.
        $wifiAvailable = $false
        if (Get-Command Test-HeadsetWifiAdbUp -ErrorAction SilentlyContinue) {
            $wifiAvailable = [bool](Test-HeadsetWifiAdbUp -Headset $headset -ClassicPort $adbPort).Up
        } elseif ($headset.IPAddress) {
            $wifiAvailable = (Test-Port -hostname $headset.IPAddress -port $adbPort).open
        }

        Send-JsonResponse -Response $response -Body @{ usb = $usbAvailable; usbSpeed = $usbSpeed; wifi = $wifiAvailable }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/detectusbheadset  - detects a USB-connected ADB device and returns its WiFi IP
function Invoke-RouteDetectusbheadset {
    # GET /api/detectusbheadset
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Published snapshot, not a live probe: the full detail probe took
        # ~450 ms and this listener loop is single-threaded, so running it
        # here stalled every other request for its duration.
        $usbInfo = Get-PublishedUsbSnapshot
        $result = if ($usbInfo -and $usbInfo.IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            @{ found = $true; ip = $usbInfo.IP; model = $usbInfo.Model }
        } else {
            @{ found = $false; ip = ''; model = '' }
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
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"found":false}')
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

# API: POST /api/enablewifiadb  - runs adb tcpip <classic port> on the USB-connected headset
function Invoke-RouteEnablewifiadb {
    # POST /api/enablewifiadb
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Claim USB: this runs adb tcpip, which re-enumerates the transport.
        Set-UsbBusy -Seconds 45
        $result = Enable-AdbTcpIp -AdbPort $adbPort -adb $adbPath
        $json   = ConvertTo-Json $result -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        # Shrink the USB claim (S9 follow-up, TEST23 section 30): it was left for its full
        # 45/60/180 s after the request ended, and the VRMonitor USB watcher yields for as
        # long as it is held - no detection, no IP heal. 10 s still covers the transport
        # re-enumeration that adb tcpip / adb usb cause.
        Set-UsbBusy -Seconds 10
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/installadbwifiapk  - installs the WiFi ADB APK on the USB-connected headset
function Invoke-RouteInstalladbwifiapk {
    # POST /api/installadbwifiapk
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Claim USB: Install-OculusWirelessAdbApk runs BOTH 'adb usb' and
        # 'adb tcpip', so it bounces the transport twice.
        Set-UsbBusy -Seconds 180
        $device = Get-AdbUsbDeviceDetails -adb $adbPath
        if (-not $device) {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"No USB headset detected"}')
            $response.StatusCode = 200
            $response.ContentType = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $respBytes.Length
            $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
        } else {
            $ok = Install-OculusWirelessAdbApk -Device $device -adb $adbPath
            # Retrieve IP after install (tcpip was run inside Install-OculusWirelessAdbApk)
            $ip    = ''
            $model = ''
            $portOpen = $false
            $ipOutput = Invoke-AdbCmd -Device $device -Command "shell ip -f inet addr show wlan0" -adb $adbPath
            foreach ($line in $ipOutput) {
                if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') { $ip = $Matches[1]; break }
            }
            $model = ((Invoke-AdbCmd -Device $device -Command "shell getprop ro.product.model" -adb $adbPath) -join '').Trim()
            if ($ip) { $portOpen = (Test-Port -hostname $ip -port $adbPort).open }
            $resultObj = @{ ok = [bool]$ok; model = $model; ip = $ip; port = $adbPort; portOpen = $portOpen; reinstalled = $true }
            $json = ConvertTo-Json $resultObj -Compress
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.StatusCode      = 200
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $respBytes.Length
            $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
        }
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        # Shrink the USB claim (S9 follow-up, TEST23 section 30): it was left for its full
        # 45/60/180 s after the request ended, and the VRMonitor USB watcher yields for as
        # long as it is held - no detection, no IP heal. 10 s still covers the transport
        # re-enumeration that adb tcpip / adb usb cause.
        Set-UsbBusy -Seconds 10
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/installadbautoenable  body (optional): {"id":<headsetId>}  - installs and configures
# the ADB auto-enable app (S10-6). With an id it acts on that headset over its own ADB link; without
# one, on the USB-cabled headset. Mirrors /api/installvrhmcompanion (ADR-0043 per-headset targeting).
function Invoke-RouteInstalladbautoenable {
    # POST /api/installadbautoenable
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    $claimed  = $false
    try {
        $hsId = 0
        try {
            $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
            if ($body) { $json = $body | ConvertFrom-Json; [void][int]::TryParse([string]$json.id, [ref]$hsId) }
        } catch {}
        $r = Resolve-AdbToolsRouteDevice -Id $hsId
        if (-not $r.Ok) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = $r.Error }
        } else {
            # Claim USB only for a cabled target: the final classic step runs 'adb tcpip',
            # which re-enumerates the USB transport. A WiFi target needs no claim.
            if ($r.Usb) { Set-UsbBusy -Seconds 180; $claimed = $true }
            $res = Install-AdbAutoEnableApk -Device $r.Device -adb $adbPath
            Send-JsonResponse -Response $response -Body @{
                ok          = [bool]$res.Ok
                model       = [string]$r.Model
                reinstalled = [bool]$res.Reinstalled
                steps       = @($res.Steps)
                error       = [string]$res.Error
            }
        }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'server error' } -StatusCode 500 } catch {}
    } finally {
        # Same shrink as the other USB-mutating routes: the watcher yields while the claim is held.
        if ($claimed) { Set-UsbBusy -Seconds 10 }
        Close-HttpResponse -Response $response
    }
    return
}

# Resolves the ADB device the adb-tools routes act on. With a positive headset id it targets
# THAT registered headset over its own ADB link (USB when cabled, else WiFi; Resolve-HeadsetAdbDevice,
# ADR-0024); with id 0/absent it falls back to the USB-cabled device (the add-headset onboarding path).
# Returns @{Ok;Device;Model;Usb;Error}. Usb drives whether the caller must hold Set-UsbBusy
# (tcpip re-enumerates USB; a WiFi target needs no claim).
function Resolve-AdbToolsRouteDevice {
    param([int]$Id = 0)
    if ($Id -gt 0) {
        if (-not (Get-Command Get-HeadsetDiagTarget -ErrorAction SilentlyContinue)) {
            return @{ Ok = $false; Error = 'Headset lookup unavailable' }
        }
        $row = Get-HeadsetDiagTarget -Id $Id
        if (-not $row) { return @{ Ok = $false; Error = 'Unknown headset' } }
        $device = Resolve-HeadsetAdbDevice -Headset $row
        if (-not $device) { return @{ Ok = $false; Error = 'Headset not reachable over ADB' } }
        $model = if ($device.Model) { [string]$device.Model } else { [string]$row.Model }
        return @{ Ok = $true; Device = $device; Model = $model; Usb = ([string]$device.ConnectionType -eq 'USB') }
    }
    $device = Get-AdbUsbDeviceDetails -adb $adbPath
    if (-not $device) { return @{ Ok = $false; Error = 'No USB headset detected' } }
    return @{ Ok = $true; Device = $device; Model = [string]$device.Model; Usb = $true }
}

# API: POST /api/installvrhmcompanion  body (optional): {"id":<headsetId>}  - installs and provisions
# the VRHM Companion app (ADR-0042), the recommended cable-free-ADB-at-boot agent. With an id it acts on
# that headset over its own ADB link; without one, on the USB-cabled headset. Mirrors /api/installadbautoenable.
function Invoke-RouteInstallvrhmcompanion {
    # POST /api/installvrhmcompanion
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    $claimed  = $false
    try {
        $hsId = 0
        try {
            $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
            if ($body) { $json = $body | ConvertFrom-Json; [void][int]::TryParse([string]$json.id, [ref]$hsId) }
        } catch {}
        $r = Resolve-AdbToolsRouteDevice -Id $hsId
        if (-not $r.Ok) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = $r.Error }
        } else {
            # Claim USB only for a cabled target: provisioning ends with 'adb tcpip' (classic),
            # which re-enumerates the USB transport. A WiFi target needs no claim.
            if ($r.Usb) { Set-UsbBusy -Seconds 180; $claimed = $true }
            $res = Install-VrhmCompanion -Device $r.Device -adb $adbPath
            Send-JsonResponse -Response $response -Body @{
                ok          = [bool]$res.Ok
                model       = [string]$r.Model
                reinstalled = [bool]$res.Reinstalled
                mode        = $(if ($res.ContainsKey('Mode')) { [string]$res.Mode } else { '' })
                steps       = @($res.Steps)
                error       = [string]$res.Error
            }
        }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'server error' } -StatusCode 500 } catch {}
    } finally {
        if ($claimed) { Set-UsbBusy -Seconds 10 }
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headset-adb-tools-status  [?id=<headsetId>]  - install state + versions of the two
# headset ADB-enabler apps (VRHM Companion, ADB Auto Enable). With an id, reads THAT headset over its
# ADB link; without one, the USB-cabled headset (ADR-0042).
function Invoke-RouteHeadsetadbtoolsstatus {
    # GET /api/headset-adb-tools-status
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    try {
        $hsId = 0
        [void][int]::TryParse([string]$request.QueryString['id'], [ref]$hsId)
        $r = Resolve-AdbToolsRouteDevice -Id $hsId
        if (-not $r.Ok) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = $r.Error }
        } else {
            $apps = @(Get-HeadsetAdbToolsStatus -Device $r.Device -adb $adbPath)
            Send-JsonResponse -Response $response -Body @{ ok = $true; model = [string]$r.Model; apps = $apps }
        }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'server error' } -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/uninstall-headset-app  body: {"pkg":"com.vrheadsetmanager.companion"[,"id":<headsetId>]}
# Uninstalls one of the two managed ADB-enabler apps. With an id, from THAT headset over its ADB link;
# without one, from the USB-cabled headset (ADR-0042).
function Invoke-RouteUninstallheadsetapp {
    # POST /api/uninstall-headset-app
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    $claimed  = $false
    try {
        $json = (Read-RequestBody -Request $request -Response $response -MaxBytes 4096) | ConvertFrom-Json
        $pkg  = [string]$json.pkg
        $hsId = 0
        [void][int]::TryParse([string]$json.id, [ref]$hsId)
        $r = Resolve-AdbToolsRouteDevice -Id $hsId
        if (-not $r.Ok) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = $r.Error }
        } else {
            if ($r.Usb) { Set-UsbBusy -Seconds 60; $claimed = $true }
            $res = Uninstall-HeadsetAdbTool -Device $r.Device -Pkg $pkg -adb $adbPath
            Send-JsonResponse -Response $response -Body @{ ok = [bool]$res.Ok; pkg = $pkg; error = [string]$res.Error }
        }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'server error' } -StatusCode 500 } catch {}
    } finally {
        if ($claimed) { Set-UsbBusy -Seconds 10 }
        Close-HttpResponse -Response $response
    }
    return
}

# Constant-time, case-sensitive ordinal token compare. An empty expected token never matches.
function Test-CompanionTokenMatch {
    param([string]$Expected, [string]$Sent)
    if ([string]::IsNullOrEmpty($Expected) -or $null -eq $Sent) { return $false }
    if ($Expected.Length -ne $Sent.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $Expected.Length; $i++) { $diff = $diff -bor ([int][char]$Expected[$i] -bxor [int][char]$Sent[$i]) }
    return ($diff -eq 0)
}

# API: POST /api/companion/telemetry - inbound telemetry push from the VRHM Companion app (ADR-0043)
function Invoke-RouteCompaniontelemetry {
    # POST /api/companion/telemetry
    # Serial-keyed from the body (serial is the permanent identity, ADR-0016), token-gated with
    # X-VRHM-Token (the per-fleet companion token, Get-CompanionToken). Writes the pushed values to
    # app_kv companion_telemetry_<id> (full = replace, otherwise merge) and ingests any apps list.
    # Same LAN-trust posture as /api/kiosks/agent-report. Fast lane - must never queue.
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    try {
        # Token gate (the companion was provisioned with this token at install).
        $expected = Get-CompanionToken
        $sent     = [string]$request.Headers['X-VRHM-Token']
        if (-not (Test-CompanionTokenMatch -Expected $expected -Sent $sent)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'unauthorized' } -StatusCode 401
            return
        }
        # 256 KB, not 8 KB: a full push carries the installed-apps list, which on a headset with a
        # few hundred third-party packages is ~20-30 KB (measured 223 pkgs). An 8 KB cap 413'd every
        # push, so nothing was ever stored and the reporter never advanced past its full+apps resend.
        $json = (Read-RequestBody -Request $request -Response $response -MaxBytes 262144) | ConvertFrom-Json
        $serial = ([string]$json.serial).Trim()
        if (-not $serial) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'serial required' } -StatusCode 400
            return
        }
        # Resolve serial -> permanent id (registry).
        $known = @(Get-KnownHeadsetsCached)
        $row = $known | Where-Object { [string]$_.SerialNumber -eq $serial } | Select-Object -First 1
        if (-not $row) {
            # An app that was never given its adb serial (installed before setserial existed) sends
            # its ANDROID_ID ("aid-..."), which the registry does not know. The token is already
            # checked, so accept the push when exactly ONE registry row holds the sender's address.
            $sender = ''
            try {
                $addr = $request.RemoteEndPoint.Address
                if ($addr.IsIPv4MappedToIPv6) { $addr = $addr.MapToIPv4() }
                $sender = $addr.ToString()
            } catch { $sender = '' }
            if ($sender) {
                $byIp = @($known | Where-Object { [string]$_.IPAddress -eq $sender })
                if ($byIp.Count -eq 1) {
                    $row = $byIp[0]
                    if (-not $script:CompanionSerialFallbackLogged) { $script:CompanionSerialFallbackLogged = @{} }
                    if (-not $script:CompanionSerialFallbackLogged.ContainsKey($serial)) {
                        $script:CompanionSerialFallbackLogged[$serial] = $true
                        Write-Log ("Companion telemetry: serial '{0}' unknown, matched {1} by its address {2} (reinstall the companion to give it its adb serial)" -f $serial, $row.Name, $sender) -Level INFO
                    }
                }
            }
        }
        if (-not $row) {
            # 404 so the companion keeps retrying a FULL push until the headset is registered.
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'unknown serial' } -StatusCode 404
            return
        }
        $hid = [int]$row.ID
        $full = [bool]$json.full

        $wireFields = @('battery', 'charging', 'wattage', 'temp', 'cpuTemp', 'gpuTemp', 'skinTemp', 'ctrlLeft', 'ctrlRight', 'foregroundApp')
        $fields = @{}
        foreach ($f in $wireFields) {
            $p = $json.PSObject.Properties[$f]
            if ($p -and $null -ne $p.Value) { $fields[$f] = $p.Value }
        }
        $stored = Set-CompanionTelemetry -HeadsetId $hid -Fields $fields -Full:$full
        if ($stored -eq $false) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'store failed' } -StatusCode 500
            return
        }

        $appsProp = $json.PSObject.Properties['apps']
        $appCount = 0
        if ($appsProp -and $appsProp.Value) {
            $appCount = Update-InstalledAppsCacheFromList -HeadsetId $hid -Apps @($appsProp.Value)
        }
        Send-JsonResponse -Response $response -Body @{ ok = $true; id = $hid; apps = $appCount }
    } catch [System.IO.InvalidDataException] {
        # Read-RequestBody already answered (413 body too large); nothing to send.
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'server error' } -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/usbdeviceinfo  - returns full details of USB-connected ADB device
function Invoke-RouteUsbdeviceinfo {
    # GET /api/usbdeviceinfo
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Last snapshot published by VRMonitor, the single USB owner.
        $details = Get-PublishedUsbSnapshot
        $result  = @{ found = $false; ip = ''; brand = ''; model = ''; serialNumber = ''; ssid = ''; expectedSsid = ''; ssidMatch = $false; wifiAdbOpen = $false; apkInstalled = $false; autoEnableInstalled = $false; alreadyRegistered = $false }
        if ($details) {
            $knownNetworks   = Get-WifiNetworks
            $preferredWifi   = $knownNetworks | Where-Object { $_.Preferred } | Select-Object -First 1
            if (-not $preferredWifi) { $preferredWifi = $knownNetworks | Select-Object -First 1 }
            $expectedSsidVal = if ($preferredWifi) { $preferredWifi.SSID } else { '' }
            $rows       = Get-KnownHeadsetsCached
            $alreadyReg = $false
            if ($details.SerialNumber) { $alreadyReg = [bool]($rows | Where-Object { $_.SerialNumber -eq $details.SerialNumber }) }
            if (-not $alreadyReg -and $details.IP) { $alreadyReg = [bool]($rows | Where-Object { $_.IPAddress -eq $details.IP }) }
            $result = @{
                found = $true; ip = $details.IP
                brand = if ($details.PSObject.Properties['Brand']) { $details.Brand } else { '' }
                model = $details.Model
                serialNumber = $details.SerialNumber; ssid = $details.WiFiSSID
                expectedSsid = $expectedSsidVal
                ssidMatch = (Test-SsidMatch -Reported $details.WiFiSSID -Expected $expectedSsidVal)
                wifiAdbOpen = $details.WifiAdbOpen
                apkInstalled = $details.ApkInstalled
                autoEnableInstalled = [bool]($details.PSObject.Properties['AutoEnableInstalled'] -and $details.AutoEnableInstalled)
                alreadyRegistered = $alreadyReg
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
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"found":false}')
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

# API: GET /api/adb-tools
#
# adb.exe plus its two Windows USB DLLs, zipped, taken from the ADB folder
# THIS server runs. The remote toolbox (VRHM-Headset-Toolbox.exe) does not
# embed adb: it downloads it here on first use, so it can never drift from
# the build this server manages headsets with, and the binary stays small.
function Invoke-RouteAdbTools {
    # GET /api/adb-tools
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $zipPath = New-AdbToolsPackage
        if (-not $zipPath -or -not (Test-Path -LiteralPath $zipPath)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'adb tools are not available on this server.' } -StatusCode 404
        } else {
            $zipInfo = Get-Item -LiteralPath $zipPath
            $response.StatusCode      = 200
            $response.ContentType     = 'application/zip'
            $response.AddHeader('Content-Disposition', 'attachment; filename="adb-tools.zip"')
            $response.ContentLength64 = $zipInfo.Length
            $stream = [System.IO.File]::OpenRead($zipPath)
            try { $stream.CopyTo($response.OutputStream) } finally { $stream.Dispose() }
        }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/adb-wifi-apk/info
#
# What the APK download IS, without downloading it: the package name the
# remote toolbox needs to ask a headset "do you already have this?", plus
# the file name and size. Without it the toolbox would have to download
# ~14 MB just to find out the app is already installed, or hardcode a
# package name that config.apk.adbWirelessActivatorPackageName is free to
# change.
function Invoke-RouteAdbWifiApkInfo {
    # GET /api/adb-wifi-apk/info
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $apkPresent = [bool]($apkPath -and (Test-Path -LiteralPath $apkPath))
        $payload = @{
            ok          = $true
            available   = $apkPresent
            packageName = $apkPackage
            fileName    = $(if ($apkPresent) { (Get-Item -LiteralPath $apkPath).Name } else { $null })
            sizeBytes   = $(if ($apkPresent) { (Get-Item -LiteralPath $apkPath).Length } else { 0 })
        }
        Send-JsonResponse -Response $response -Body $payload
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/adb-wifi-apk
#
# The WiFi ADB helper APK, streamed from sources\ (the folder and file
# name both come from config.apk.*). The remote toolbox downloads it and
# runs "adb install" itself, so the APK is never embedded in the toolbox
# binary and always matches what this server ships.
function Invoke-RouteAdbWifiApk {
    # GET /api/adb-wifi-apk
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        if (-not $apkPath -or -not (Test-Path -LiteralPath $apkPath)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'The WiFi ADB APK is not present on this server.' } -StatusCode 404
        } else {
            $apkInfo = Get-Item -LiteralPath $apkPath
            $response.StatusCode      = 200
            $response.ContentType     = 'application/vnd.android.package-archive'
            $response.AddHeader('Content-Disposition', ('attachment; filename="{0}"' -f $apkInfo.Name))
            $response.ContentLength64 = $apkInfo.Length
            $stream = [System.IO.File]::OpenRead($apkPath)
            try { $stream.CopyTo($response.OutputStream) } finally { $stream.Dispose() }
        }
    } catch {
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}
