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

        $wifiAvailable = $false
        if ($headset.IPAddress) {
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

# API: POST /api/enablewifiadb  - runs adb tcpip 5555 on the USB-connected headset
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

# API: GET /api/usbdeviceinfo  - returns full details of USB-connected ADB device
function Invoke-RouteUsbdeviceinfo {
    # GET /api/usbdeviceinfo
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Last snapshot published by VRMonitor, the single USB owner.
        $details = Get-PublishedUsbSnapshot
        $result  = @{ found = $false; ip = ''; brand = ''; model = ''; serialNumber = ''; ssid = ''; expectedSsid = ''; ssidMatch = $false; wifiAdbOpen = $false; apkInstalled = $false; alreadyRegistered = $false }
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
                apkInstalled = $details.ApkInstalled; alreadyRegistered = $alreadyReg
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
