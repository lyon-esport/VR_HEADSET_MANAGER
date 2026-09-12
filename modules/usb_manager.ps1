###############################################################################
# usb_manager.ps1 - the single owner of USB headset detection and onboarding.
#
# WHY THIS MODULE EXISTS
# ----------------------
# USB used to be probed by TWO independent pollers: the VRMonitor slow path
# (Invoke-UsbHeadsetActions, every refresh_timer) and a dedicated Start-Job
# inside the web server (every 3 s). Each ran the full ~17-spawn detail probe,
# forever, whether or not anything had changed - roughly 500 adb.exe launches
# per minute with a headset cabled, from two processes, against one adb server.
#
# Worse, the "already enabled, do not re-fire tcpip" short-circuit keyed on a
# WifiAdbOpen flag that could never become true, because Enable-AdbTcpIp ran
# "adb tcpip" and never "adb connect". A transient 'offline' on the WiFi
# transport was enough to re-fire tcpip, and tcpip re-enumerates the USB
# transport - a measured 10-second USB outage, which could itself provoke the
# next re-fire. That is the loop this module removes.
#
# THE RULE
# --------
# Steady state costs exactly ONE "adb devices" call, because that single call
# answers both questions at once: is a headset cabled, and is its WiFi ADB
# transport live. Anything more only happens when one of those answers changes.
#
# Escalation is strictly ordered, cheapest first:
#   1. presence unchanged + WiFi transport live  -> do nothing            (0 extra)
#   2. WiFi transport missing                    -> "adb connect"         (1 extra)
#   3. connect failed AND backoff elapsed        -> full onboarding       (~4 extra)
# Step 2 is what makes an 'offline' blip cheap: it costs one connect instead of
# a tcpip that would drop USB for ten seconds.
#
# Registry WRITES are never done here. Update-UsbWatchState only PUBLISHES an
# onboarding request into the state bag it is handed; the caller - which runs on
# the VRMonitor main thread - is what performs Set-HeadsetIdentity. That keeps
# every registry write in one thread, as ADR-0002 requires.
#
# This deliberately does NOT get its own runspace. Once the steady-state tick is
# a single "adb devices" call there is nothing to move off the slow path, and a
# second runspace would just recreate the two-independent-pollers problem this
# module exists to remove. The only slow part left is onboarding itself (a few
# seconds), which happens once per plug event.
###############################################################################


# ---------------------------------------------------------------------------
# Module-scope state. These live for the lifetime of the process that loaded the
# module - that persistence IS the memo, and it is what stops the tcpip loop.
# ---------------------------------------------------------------------------
$script:UsbMemo            = @{}     # serial -> @{ Ip; TcpipAt; Failures; Brand; Model }
$script:UsbLastSerial      = $null
$script:UsbTcpipBackoffSec = 30      # never re-fire tcpip for the same serial faster than this
$script:UsbTcpipBackoffMax = 300


function Get-AdbUsbPresence {
    <#
    .SYNOPSIS
    ONE "adb devices" call, parsed into both the cabled device and the live WiFi
    transports.

    .DESCRIPTION
    This is the cheap tick. The old code asked adb the same question twice per
    probe - once to find the USB serial, once to test whether "ip:port" was
    connected - when a single listing already contains both.

    Only a transport in state 'device' counts as live: 'offline' and
    'unauthorized' are explicitly not live, and are reported so the caller can
    react differently to each.

    .EXAMPLE
    $p = Get-AdbUsbPresence
    if ($p.Serial -and ($p.WifiTransports -contains '192.168.1.243:5555')) { ... }
    #>
    param([string]$adb = $global:adbPath)

    $out = [PSCustomObject]@{
        Serial         = $null
        State          = $null
        Unauthorized   = $false
        WifiTransports = @()
        OfflineWifi    = @()
    }
    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) { return $out }

    $lines = @(& $adb devices 2>$null | Where-Object { $_ -and $_ -notmatch '^List of devices' })

    $live    = @()
    $offline = @()
    foreach ($line in $lines) {
        if ($line -notmatch "`t") { continue }
        $parts = $line -split "`t"
        $id    = $parts[0].Trim()
        $state = $parts[1].Trim()

        if ($id -match ':') {
            if ($state -eq 'device') { $live += $id } else { $offline += $id }
            continue
        }

        # First USB entry wins. A single cabled headset is the supported shape.
        if (-not $out.Serial) {
            $out.Serial = $id
            $out.State  = $state
            if ($state -eq 'unauthorized') { $out.Unauthorized = $true }
        }
    }

    $out.WifiTransports = $live
    $out.OfflineWifi    = $offline
    return $out
}


function Get-UsbDeviceSnapshot {
    <#
    .SYNOPSIS
    Full details of the cabled headset - the operator-facing record behind
    /api/usbdeviceinfo and the "new device" modal.

    .DESCRIPTION
    Rebuilt on Get-AdbPropBatch, so brand, model, serial and the wlan0 address
    come back in ONE adb round-trip instead of one per value. Pass -Presence to
    reuse a listing you already have rather than making adb list devices again.

    Returns $null when nothing is cabled. Shape is deliberately identical to the
    old Get-AdbUsbDeviceDetails so existing callers and the web UI need no edit.
    #>
    param(
        [string]$PackageName = $global:ADBWirelessActivatorPackageName,
        [int]$AdbPort        = $global:adbPort_default,
        [string]$adb         = $global:adbPath,
        $Presence            = $null
    )

    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) { return $null }
    if (-not $Presence) { $Presence = Get-AdbUsbPresence -adb $adb }
    if (-not $Presence.Serial -or $Presence.State -ne 'device') { return $null }

    $deviceId  = $Presence.Serial
    $usbDevice = [PSCustomObject]@{ DeviceId = $deviceId; ConnectionType = 'USB'; IP = $null; Port = $null }

    try {
        # Brand, model and serial in one call (Get-HeadsetBrandModel batches them),
        # then the wlan0 address and the SSID in a second. Two round-trips total.
        $bm = Get-HeadsetBrandModel -Device $usbDevice -IncludeSerial -adb $adb
        $brand  = if ($bm) { $bm.Brand } else { "" }
        $model  = if ($bm) { $bm.Model } else { "" }
        $serial = if ($bm -and $bm.Serial) { $bm.Serial } else { $deviceId }

        $net = Get-AdbPropBatch -Device $usbDevice -adb $adb -Properties @() -IncludeWlanIp
        $ip  = $net['WlanIp']

        # SSID: "cmd wifi status" first (Android 11+, clean output). The old code
        # fell back to "dumpsys wifi", which returns hundreds of KB that then get
        # parsed into a PowerShell string array - far too expensive to sit on a
        # repeating path. It stays as a fallback, but it is only ever reached when
        # the cheap call returned nothing.
        $ssid = ''
        $cmdStatus = Invoke-AdbCmd -Device $usbDevice -Command "shell cmd wifi status" -adb $adb -SilentOnFail
        if ($cmdStatus -ne $false) {
            foreach ($line in @($cmdStatus)) {
                if ($line -match '\bssid="([^"]+)"') { $ssid = $Matches[1]; break }
                if ($line -match '\bSSID:\s+([^,\s]+)') {
                    $candidate = $Matches[1].Trim().Trim('"')
                    if ($candidate -and $candidate -ne '<unknssid>') { $ssid = $candidate; break }
                }
            }
        }
        if (-not $ssid) {
            $wifiLines = @(Invoke-AdbCmd -Device $usbDevice -Command "shell dumpsys wifi" -adb $adb -SilentOnFail)
            foreach ($line in $wifiLines) {
                if ($line -match '\bSSID:\s+"([^"]+)"') {
                    $candidate = $Matches[1]
                    # Guard against a stale $Matches leaking the IP captured above.
                    if ($candidate -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $ssid = $candidate; break }
                }
                if ($line -match '\bssid="([^"]+)"') { $ssid = $Matches[1]; break }
            }
        }

        # No second "adb devices" here - the listing we were handed already knows.
        $wifiAdbOpen = $false
        if ($ip) { $wifiAdbOpen = ($Presence.WifiTransports -contains "${ip}:${AdbPort}") }

        $apkInstalled = $false
        if ($PackageName) {
            $pmResult = Invoke-AdbCmd -Device $usbDevice -Command "shell pm list packages $PackageName" -adb $adb -SilentOnFail
            $apkInstalled = $pmResult -ne $false -and [bool]($pmResult | Where-Object { $_ -match "package:$([regex]::Escape($PackageName))" })
        }

        return [PSCustomObject]@{
            DeviceId       = $deviceId
            ConnectionType = 'USB'
            IP             = $ip
            Brand          = $brand
            Model          = $model
            SerialNumber   = $serial
            WiFiSSID       = $ssid
            WifiAdbOpen    = $wifiAdbOpen
            ApkInstalled   = $apkInstalled
            UsbSpeed       = (Get-UsbDeviceSpeed -Serial $deviceId)
            Port           = $null
        }
    } catch {
        Write-Log ($msg.ADBExecutionFailed -f $_.Exception.Message) -Level ERROR
        return $null
    }
}


function Connect-HeadsetWifiAdb {
    <#
    .SYNOPSIS
    "adb connect <ip>:<port>" plus a verify. Returns $true when the transport is
    live afterwards.

    .DESCRIPTION
    Split out because it is step 2 of the escalation - the cheap repair for a
    transport that went 'offline' without the device having stopped listening.
    Most WiFi ADB drops are exactly that, and they do NOT need tcpip.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath
    )
    if (-not $IPAddress) { return $false }
    $target = "${IPAddress}:${AdbPort}"
    try {
        $out = & $adb connect $target 2>$null
        return [bool](@($out) -match 'connected to')
    } catch {
        return $false
    }
}


function Invoke-UsbOnboarding {
    <#
    .SYNOPSIS
    Brings a cabled headset all the way to a live WiFi ADB transport:
    read identity -> adb tcpip -> adb connect -> verify.

    .DESCRIPTION
    The "-> adb connect -> verify" tail is the part the old code was missing.
    Enable-AdbTcpIp put the device into tcpip mode and stopped there, so nothing
    ever created the host-side transport; WifiAdbOpen therefore stayed false and
    the caller re-fired tcpip on every single tick. Verified on a Quest 3: after
    "adb tcpip 5555" the device IS listening, and a plain "adb connect" brings it
    straight up.

    Returns @{ Ok; Serial; Ip; Brand; Model; WifiAdbUp; TcpipFired; Error }.
    Never throws.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Serial,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath,
        [switch]$SkipTcpip
    )

    $res = @{ Ok = $false; Serial = $Serial; Ip = ''; Brand = ''; Model = ''
              WifiAdbUp = $false; TcpipFired = $false; Error = '' }

    $usbDevice = [PSCustomObject]@{ DeviceId = $Serial; ConnectionType = 'USB'; IP = $null; Port = $null }

    try {
        $bm = Get-HeadsetBrandModel -Device $usbDevice -IncludeSerial -adb $adb
        if ($bm) {
            $res.Brand = $bm.Brand
            $res.Model = $bm.Model
            if ($bm.Serial) { $res.Serial = $bm.Serial }
        }

        $net    = Get-AdbPropBatch -Device $usbDevice -adb $adb -Properties @() -IncludeWlanIp
        $res.Ip = $net['WlanIp']

        if (-not $res.Ip) {
            $res.Error = 'no wlan0 address'
            return $res
        }

        if (-not $SkipTcpip) {
            Invoke-AdbCmd -Device $usbDevice -Command "tcpip $AdbPort" -adb $adb -SilentOnFail | Out-Null
            $res.TcpipFired = $true
            # tcpip restarts the device's adbd; it needs a moment before it accepts
            # a connection on the new port.
            Start-Sleep -Milliseconds 1200
        }

        $res.WifiAdbUp = Connect-HeadsetWifiAdb -IPAddress $res.Ip -AdbPort $AdbPort -adb $adb
        $res.Ok        = $true
        return $res
    } catch {
        $res.Error = $_.Exception.Message
        return $res
    }
}


function Set-UsbBusy {
    <#
    .SYNOPSIS
    Claims USB for an operator action for the next -Seconds, so the VRMonitor
    watcher keeps its hands off.

    .DESCRIPTION
    The watcher and the web server are DIFFERENT PROCESSES sharing one adb
    server, so this is a kv flag rather than a lock - non-blocking, and it
    expires on its own if the holder dies.

    It exists because the collision is real and was observed twice: an operator
    action (enable WiFi ADB, install the activator APK) runs "adb usb" and/or
    "adb tcpip", each of which re-enumerates the USB transport for several
    seconds. If the watcher fires its own tcpip in that window, one of the two
    loses its transport mid-command and the request fails with a 500.

    .EXAMPLE
    Set-UsbBusy -Seconds 60
    #>
    param([int]$Seconds = 60)
    try {
        if (Get-Command Set-DbKeyValue -ErrorAction SilentlyContinue) {
            Set-DbKeyValue -Key 'usb_busy_until' -Value ((Get-Date).AddSeconds($Seconds).ToUniversalTime().ToString('o'))
        }
    } catch { }
}


function Clear-UsbBusy {
    param()
    try {
        if (Get-Command Set-DbKeyValue -ErrorAction SilentlyContinue) {
            Set-DbKeyValue -Key 'usb_busy_until' -Value ([datetime]::MinValue.ToUniversalTime().ToString('o'))
        }
    } catch { }
}


function Test-UsbBusy {
    <# Returns $true while an operator action holds USB. Never throws. #>
    param()
    try {
        if (-not (Get-Command Get-DbKeyValue -ErrorAction SilentlyContinue)) { return $false }
        $raw = Get-DbKeyValue -Key 'usb_busy_until'
        if (-not $raw) { return $false }
        $until = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$raw, [ref]$until)) { return $false }
        return ((Get-Date).ToUniversalTime() -lt $until.ToUniversalTime())
    } catch { return $false }
}


function Publish-UsbIdentity {
    <#
    .SYNOPSIS
    Queues "serial S is at address X" for the main thread to apply.

    .DESCRIPTION
    Must be called from EVERY path that establishes or changes the known address -
    `adopted` and `reconnected`, not just `onboarded`. Missing that was a real
    regression: those two are the common paths, so a headset whose registry row
    held a stale IP never healed. A USB-connected headset is the most
    authoritative source of its own address there is, and the whole point of the
    serial-keyed writer is to use it.

    Queuing on a state change only (never on a `noop` tick) is what keeps this
    cheap - the old code called Set-HeadsetIdentity on every single probe.
    `Set-HeadsetIdentity` is still the dedupe point: it returns 'unchanged'
    without saving when nothing differs.
    #>
    param(
        [hashtable]$SharedState,
        [string]$Serial,
        [string]$Ip,
        $Snapshot
    )
    if (-not $SharedState -or -not $Serial -or -not $Ip) { return }
    $SharedState['_usb_onboard_request'] = @{
        SerialNumber = $(if ($Snapshot -and $Snapshot.SerialNumber) { $Snapshot.SerialNumber } else { $Serial })
        IPAddress    = $Ip
        Model        = $(if ($Snapshot) { $Snapshot.Model } else { '' })
        Brand        = $(if ($Snapshot) { $Snapshot.Brand } else { '' })
        At           = (Get-Date)
    }
}


function Update-UsbWatchState {
    <#
    .SYNOPSIS
    One watcher tick. THE hot path - see the escalation ladder in the file header.

    .DESCRIPTION
    Publishes into $SharedState:
      _usb_device          the snapshot for the web server / UI ($null when nothing cabled)
      _usb_onboard_request an identity write for the MAIN thread to apply

    Returns a short string naming what it did, for logging: 'idle', 'noop',
    'reconnected', 'onboarded', 'backoff', 'unauthorized'.
    #>
    param(
        [hashtable]$SharedState,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath
    )

    # An operator action owns USB right now (enable WiFi ADB, install the APK).
    # Those run "adb usb"/"adb tcpip", which re-enumerate the transport for
    # several seconds; firing our own tcpip into that window makes one of the two
    # fail mid-command. Yield - the state we would have read is about to change
    # anyway, and the next tick picks it up.
    if (Test-UsbBusy) { return 'busy' }

    $presence = Get-AdbUsbPresence -adb $adb

    # ---- Nothing cabled ----
    if (-not $presence.Serial) {
        if ($null -ne $script:UsbLastSerial) {
            $script:UsbLastSerial = $null
            if ($SharedState) { $SharedState['_usb_device'] = $null }
            Write-Log "USB watcher: no device cabled" -Level DEBUG
        }
        return 'idle'
    }

    if ($presence.Unauthorized) {
        if ($script:UsbLastSerial -ne $presence.Serial) {
            $script:UsbLastSerial = $presence.Serial
            Write-Log ($msg.AdbCmdUsbUnauthorized -f $presence.Serial) -Level WARNING
        }
        return 'unauthorized'
    }
    if ($presence.State -ne 'device') { return 'idle' }

    $serial = $presence.Serial
    $memo   = $script:UsbMemo[$serial]

    # ---- 1. Known, and its transport is live: the whole tick costs one listing ----
    if ($memo -and $memo.Ip -and ($presence.WifiTransports -contains ("{0}:{1}" -f $memo.Ip, $AdbPort))) {
        # Re-read only when there is a reason to: a different headset, nothing
        # published yet, or a Partial record left behind by an onboarding that
        # could not read over USB because tcpip had just dropped the transport.
        $pub = $SharedState['_usb_device']
        if ($script:UsbLastSerial -ne $serial -or -not $pub -or $pub.Partial) {
            $script:UsbLastSerial = $serial
            $pub = Get-UsbDeviceSnapshot -AdbPort $AdbPort -adb $adb -Presence $presence
            $SharedState['_usb_device'] = $pub
        }

        # Publish the identity on EVERY tick, not just when the USB state changed.
        #
        # Publishing only on change was wrong: the REGISTRY can change while USB
        # sits perfectly still. A headset registered (or edited to a wrong address)
        # after the memo was already seeded would never heal, because every
        # subsequent tick returned here without saying anything. Writing to the
        # state bag is free - the caller is what decides whether the write is worth
        # doing, and it gates that on the headsets change counter.
        Publish-UsbIdentity -SharedState $SharedState -Serial $serial -Ip $memo.Ip -Snapshot $pub
        return 'noop'
    }

    # ---- 1b. Cold start: find out where this headset is BEFORE assuming it needs
    # anything doing. One batched read of wlan0.
    #
    # Skipping this was a real bug: with an empty memo (fresh process, or the app
    # restarting against a headset that is already fully set up) the code fell
    # straight through to tcpip - and tcpip drops the USB transport for about ten
    # seconds. Restarting the app must not knock USB out for a headset that was
    # already working.
    $ip = if ($memo) { $memo.Ip } else { $null }
    if (-not $ip) {
        $usbDevice = [PSCustomObject]@{ DeviceId = $serial; ConnectionType = 'USB'; IP = $null; Port = $null }
        try {
            $net = Get-AdbPropBatch -Device $usbDevice -adb $adb -IncludeWlanIp
            $ip  = $net['WlanIp']
        } catch { $ip = $null }
    }

    if ($ip -and ($presence.WifiTransports -contains ("{0}:{1}" -f $ip, $AdbPort))) {
        # Already up. Adopt it into the memo; do NOT fire tcpip.
        $script:UsbMemo[$serial] = @{
            Ip = $ip; TcpipAt = [DateTime]::MinValue; Failures = 0
            Brand = $(if ($memo) { $memo.Brand } else { '' })
            Model = $(if ($memo) { $memo.Model } else { '' })
        }
        $script:UsbLastSerial = $serial
        $snapshot = Get-UsbDeviceSnapshot -AdbPort $AdbPort -adb $adb -Presence $presence
        $SharedState['_usb_device'] = $snapshot
        Publish-UsbIdentity -SharedState $SharedState -Serial $serial -Ip $ip -Snapshot $snapshot
        Write-Log ("USB watcher: adopted live WiFi ADB for " + $serial + " at " + $ip) -Level DEBUG
        return 'adopted'
    }

    # ---- 2. Transport missing: try the cheap repair before anything drastic ----
    if ($ip) {
        if (Connect-HeadsetWifiAdb -IPAddress $ip -AdbPort $AdbPort -adb $adb) {
            $script:UsbMemo[$serial] = @{
                Ip = $ip; TcpipAt = [DateTime]::MinValue; Failures = 0
                Brand = $(if ($memo) { $memo.Brand } else { '' })
                Model = $(if ($memo) { $memo.Model } else { '' })
            }
            $script:UsbLastSerial = $serial
            $snapshot = Get-UsbDeviceSnapshot -AdbPort $AdbPort -adb $adb
            $SharedState['_usb_device'] = $snapshot
            Publish-UsbIdentity -SharedState $SharedState -Serial $serial -Ip $ip -Snapshot $snapshot
            Write-Log ("USB watcher: reconnected WiFi ADB for " + $serial + " at " + $ip) -Level DEBUG
            return 'reconnected'
        }
    }

    # Backoff guard. tcpip re-enumerates the USB transport (measured: a ~10 s
    # outage on a Quest 3), so firing it on every tick is actively harmful.
    if ($memo) {
        $since = ((Get-Date) - $memo.TcpipAt).TotalSeconds
        $wait  = [Math]::Min($script:UsbTcpipBackoffMax, $script:UsbTcpipBackoffSec * [Math]::Max(1, $memo.Failures))
        if ($since -lt $wait) { return 'backoff' }
    }

    # ---- 3. Full onboarding (this is the only path that fires tcpip) ----
    $result = Invoke-UsbOnboarding -Serial $serial -AdbPort $AdbPort -adb $adb
    if (-not $result.Ok) {
        $script:UsbMemo[$serial] = @{
            Ip = ''; TcpipAt = (Get-Date)
            Failures = (1 + $(if ($memo) { $memo.Failures } else { 0 }))
            Brand = $result.Brand; Model = $result.Model
        }
        Write-Log ("USB watcher: onboarding failed for " + $serial + ": " + $result.Error) -Level DEBUG
        return 'backoff'
    }

    $script:UsbMemo[$serial] = @{
        Ip       = $result.Ip
        TcpipAt  = (Get-Date)
        Failures = $(if ($result.WifiAdbUp) { 0 } else { 1 + $(if ($memo) { $memo.Failures } else { 0 }) })
        Brand    = $result.Brand
        Model    = $result.Model
    }
    $script:UsbLastSerial = $serial

    # Hand the identity write to the main thread - never write the registry here.
    if ($SharedState -and $result.Serial -and $result.Ip) {
        $SharedState['_usb_onboard_request'] = @{
            SerialNumber = $result.Serial
            IPAddress    = $result.Ip
            Model        = $result.Model
            Brand        = $result.Brand
            At           = (Get-Date)
        }
    }

    # Build the published record from what onboarding already learned rather than
    # re-probing: tcpip has just dropped the USB transport, so a snapshot taken
    # right now would come back $null and the UI would blink "no device".
    if ($SharedState) {
        $SharedState['_usb_device'] = [PSCustomObject]@{
            DeviceId       = $serial
            ConnectionType = 'USB'
            IP             = $result.Ip
            Brand          = $result.Brand
            Model          = $result.Model
            SerialNumber   = $result.Serial
            WiFiSSID       = ''
            WifiAdbOpen    = $result.WifiAdbUp
            ApkInstalled   = $false
            UsbSpeed       = $null
            Port           = $null
            Partial        = $true      # a later tick replaces this with a full read
        }
    }

    Write-Log ($msg.UsbWifiAdbEnabled -f $result.Model, $result.Ip, $AdbPort) -Level SUCCESS
    return 'onboarded'
}


function Clear-UsbMemo {
    <#
    .SYNOPSIS
    Forgets the onboarding memo, so the next tick re-onboards from scratch.
    Used by operator actions that deliberately change the device's WiFi state.
    #>
    param([string]$Serial)
    if ($Serial) { $script:UsbMemo.Remove($Serial) | Out-Null }
    else         { $script:UsbMemo = @{} }
    $script:UsbLastSerial = $null
}
