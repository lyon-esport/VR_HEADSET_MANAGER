###############################################################
# adb_device_settings.ps1
# Headset device settings and power: WiFi push/connect, reboot/shutdown,
# guardian, brightness, sound, proximity, refresh rate, OTA update block.
# Split out of adb_functions.ps1 (S9-2). Auto-loaded by scripts_init.ps1.
# Translations are loaded centrally in scripts_init.ps1 into $global:msg.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


# Returns the stored password for a given SSID from the encrypted WiFi store, or $null if not found.
function Get-WifiPassword {
    param([Parameter(Mandatory)][string]$Ssid)
    $match = Get-WifiNetworks | Where-Object { $_.SSID -eq $Ssid } | Select-Object -First 1
    if ($match) { return $match.Password }
    return $null
}


# Connects a headset to a WiFi network via ADB.
# $UseRandomMac=$false (default) forces the real device MAC; $true allows Android MAC randomization.
# Password is resolved from the encrypted store when omitted.
# Returns $true on success, $false on failure.
function Connect-HeadsetToWifi {
    # Meta Quest: `cmd wifi connect-network` works for shell uid - automated push.
    # Pico (probed on Pico 4 Ultra): BOTH `cmd wifi connect-network` AND `add-network`
    # throw SecurityException for uid 2000 (shell). No public ADB path can write
    # WPA credentials. Best we can do is open the system WiFi picker on the headset
    # so the operator completes the join interactively.
    param(
        [Parameter(Mandatory)][object]$Device,
        [Parameter(Mandatory)][string]$Ssid,
        [string]$Password,
        [bool]$UseRandomMac = $false,
        [string]$Brand = ""
    )

    if (-not $Password) {
        $Password = Get-WifiPassword -Ssid $Ssid
        if (-not $Password) {
            Write-Log ($msg.Wifi.PasswordNotFound -f $Ssid) -Level ERROR
            return $false
        }
    }

    Invoke-AdbCmd -Device $Device -Command "shell svc wifi enable" -SilentOnFail | Out-Null

    if ($Brand -eq "Pico") {
        Write-Log ("Automated WiFi push not supported on Pico (uid 2000 SecurityException on cmd wifi connect-network). Opening WiFi picker on headset for SSID '{0}'." -f $Ssid) -Level WARNING
        Invoke-AdbCmd -Device $Device -Command "shell am start -a android.settings.WIFI_SETTINGS" -SilentOnFail | Out-Null
        return $false
    }

    $macFlag = if ($UseRandomMac) { 'persistent' } else { 'none' }

    # SilentOnFail: keep the password out of WARN logs (Invoke-AdbCmd would otherwise
    # log the full command string verbatim on non-zero exit).
    $out = Invoke-AdbCmd -Device $Device -Command "shell cmd -w wifi connect-network `"$Ssid`" wpa2 `"$Password`" -r $macFlag" -SilentOnFail

    if ($out -ne $false -and ($out -join '') -notmatch 'error|failed|unknown') {
        Write-Log ($msg.Wifi.ConnectSuccess -f $Ssid, $Device.DeviceId) -Level SUCCESS
        return $true
    } else {
        # Mask password before logging the response. Generic redaction in case the
        # response echoes the command line on some firmware.
        $resp = ($out -join ' ').Trim()
        $resp = $resp -replace [regex]::Escape($Password), '***'
        Write-Log ($msg.Wifi.ConnectFailed -f $Ssid, $Device.DeviceId, $resp) -Level ERROR
        return $false
    }
}


function Get-HeadsetVisibleWifiNetworks {
    <#
    .SYNOPSIS
    The WiFi networks the HEADSET's own radio can currently see.

    .DESCRIPTION
    The scan runs on the headset, never on the server: a 6 GHz-only network is
    perfectly visible to a modern PC and completely invisible to an older
    headset that has no radio for that band. Pushing such an SSID would drop the
    headset off the network with no way back, so every push is gated on this.

    Returns @(@{Ssid;Frequency;Rssi}), or $null when the firmware does not
    support the command - $null means "unknown", which is deliberately NOT the
    same as an empty array ("nothing in range").

    .EXAMPLE
    $seen = Get-HeadsetVisibleWifiNetworks -Device $device
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Device,
        [int]$SettleSeconds = 4
    )

    # start-scan only kicks a scan off; the results land a moment later.
    Invoke-AdbCmd -Device $Device -Command "shell cmd -w wifi start-scan" -SilentOnFail | Out-Null
    Start-Sleep -Seconds $SettleSeconds

    $out = Invoke-AdbCmd -Device $Device -Command "shell cmd -w wifi list-scan-results" -SilentOnFail
    if ($out -eq $false) { return $null }

    $lines = @($out)
    if ($lines.Count -eq 0) { return $null }

    $joined = ($lines -join "`n")
    if ($joined -match '(?i)unknown command|Exception|not supported') { return $null }

    $results = @()
    foreach ($line in $lines) {
        $text = [string]$line
        if (-not $text) { continue }
        # Header row of "list-scan-results" - skip it rather than parse it.
        if ($text -match '(?i)^\s*BSSID\b') { continue }
        # A row, as a Quest 3 actually prints it:
        #   b4:fb:e4:c8:6c:d6  5180  -81(0:-83/1:-85)  >1000.0  MyWifi  [WPA2-PSK-CCMP][ESS]
        # Note the RSSI column is NOT a bare number (it carries the per-chain
        # detail in parentheses) and the age column is not one either - both are
        # matched as opaque tokens and only the leading integer of the RSSI is
        # read back out.
        if ($text -match '^\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$') {
            $rest = $Matches[5]
            # Keep the capability flags ([WPA2-PSK-CCMP][ESS] ...) before they are stripped from the SSID:
            # the DIAG page needs them to pick open / wpa2 / wpa3 for "cmd wifi connect-network".
            $flags = (([regex]::Matches($rest, '\[[^\]]*\]') | ForEach-Object { $_.Value }) -join '')
            # Trailing capability flags such as [WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]
            # are not part of the SSID - and there is always more than one group,
            # so the strip has to be repeated, not anchored to a single pair.
            $ssid = ($rest -replace '(\s*\[[^\]]*\])+\s*$', '').Trim()
            $rssi = 0
            if ($Matches[3] -match '^(-?\d+)') { $rssi = [int]$Matches[1] }
            # A hidden network prints an empty SSID column; there is nothing to
            # match against, so it is dropped rather than recorded as "".
            if ($ssid) {
                $results += @{ Ssid = $ssid; Frequency = [int]$Matches[2]; Rssi = $rssi; Flags = $flags }
            }
        }
    }

    if ($results.Count -eq 0) { return @() }
    return $results
}


function Test-HeadsetWifiSsidVisible {
    <#
    .SYNOPSIS
    $true / $false when the headset's own scan settles the question, $null when
    the headset could not be scanned at all.

    .EXAMPLE
    if ((Test-HeadsetWifiSsidVisible -Device $device -Ssid 'VR-LAB') -eq $false) { ... }
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Device,
        [Parameter(Mandatory = $true)][string]$Ssid
    )

    $seen = Get-HeadsetVisibleWifiNetworks -Device $Device
    if ($null -eq $seen) { return $null }
    return [bool](@($seen | Where-Object { $_.Ssid -eq $Ssid }).Count -gt 0)
}


function Invoke-HeadsetWifiPush {
    <#
    .SYNOPSIS
    Moves one known headset onto one of the WiFi networks this server holds the
    password for - over the server's own ADB connection, so the password never
    leaves the server.

    .DESCRIPTION
    The headset is scanned FIRST (Get-HeadsetVisibleWifiNetworks). When it
    cannot see the requested SSID, nothing is pushed and the headset is left on
    its current network; the reachable known networks are returned instead so
    the caller can offer an alternative. A headset that cannot be scanned at all
    is treated as "unknown" and only pushed when -Force is passed.

    Works for a headset reached over WiFi ADB and for one cabled to this server:
    Get-BestAdbDevice prefers USB when it is there.

    Returns @{Ok; Visible; Pushed; VisibleKnown; Error}.

    .EXAMPLE
    $r = Invoke-HeadsetWifiPush -Headset $headset -Ssid 'VR-LAB'
    if (-not $r.Pushed) { $r.VisibleKnown }
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Headset,
        [Parameter(Mandatory = $true)][string]$Ssid,
        [switch]$Force,
        # Classic WiFi ADB port; 0 = config (Get-ClassicAdbPort, via the resolver).
        [int]$AdbPort = 0,
        [string]$adb = $global:adbPath
    )

    $result = @{ Ok = $false; Visible = $null; Pushed = $false; VisibleKnown = @(); Error = $null }

    $known = @(Get-WifiNetworks)
    if (-not ($known | Where-Object { $_.SSID -eq $Ssid })) {
        $result.Error = "This server does not know the password for '$Ssid'."
        return $result
    }

    $device = $null
    try {
        $device = Get-BestAdbDevice -Headset $Headset -AdbPort $AdbPort -adb $adb
    } catch {
        $device = $null
    }
    if (-not $device) {
        $result.Error = "The headset could not be reached over ADB."
        return $result
    }

    $seen = Get-HeadsetVisibleWifiNetworks -Device $device
    if ($null -ne $seen) {
        $visibleSsids = @($seen | ForEach-Object { $_.Ssid } | Select-Object -Unique)
        $result.Visible = [bool]($visibleSsids -contains $Ssid)
        $result.VisibleKnown = @($known | Where-Object { $visibleSsids -contains $_.SSID } | ForEach-Object { $_.SSID })

        if (-not $result.Visible -and -not $Force) {
            $result.Ok = $true
            $result.Error = "The headset cannot see '$Ssid' - nothing was pushed, it stays on its current network."
            Write-Log ("WiFi push refused for '{0}': headset {1} cannot see that SSID." -f $Ssid, $Headset.Name) -Level WARNING
            return $result
        }
    } else {
        Write-Log ("Could not scan WiFi networks from headset {0} - pushing '{1}' without the visibility check." -f $Headset.Name, $Ssid) -Level WARNING
    }

    $brand = if ($Headset.Brand) { [string]$Headset.Brand } else { "" }
    $pushed = Connect-HeadsetToWifi -Device $device -Ssid $Ssid -Brand $brand

    $result.Ok     = $true
    $result.Pushed = [bool]$pushed
    if (-not $pushed) {
        $result.Error = "The headset refused the WiFi change (see the server log for details)."
    }
    return $result
}


function Invoke-HeadsetReboot {
    <#
    .SYNOPSIS
    Reboots a VR headset via ADB.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.HeadsetRebooting -f $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "reboot" -adb $adb | Out-Null
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Invoke-HeadsetShutdown {
    <#
    .SYNOPSIS
    Powers off a VR headset via ADB.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.HeadsetShuttingDown -f $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "reboot -p" -adb $adb | Out-Null
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-HeadsetShutdownTarget {
    <#
    .SYNOPSIS
    The adb -s target of a known headset for a power-off, WITHOUT any network I/O.

    .DESCRIPTION
    Same order as Resolve-HeadsetAdbDevice (USB serial when the headset is in the published
    cabled set and USB is not held by an operator action, else IP:port, honouring
    ADB.prefer_usb), but it never runs "adb connect" or a ping: a power-off must start at
    once, and an address the adb server does not know simply makes adb fail fast with
    "device not found". Returns $null when the row has neither a serial nor a usable address.

    .EXAMPLE
    Get-HeadsetShutdownTarget -Headset $row    # @{ DeviceId = '1WMHH...'; ConnectionType = 'USB' }
    #>
    param (
        [Parameter(Mandatory=$true)] $Headset,
        [int]$AdbPort = 0
    )
    if ($AdbPort -le 0) { $AdbPort = Get-ClassicAdbPort }

    $serial = if ($Headset.SerialNumber) { ([string]$Headset.SerialNumber).Trim() } else { '' }
    if ($serial -eq '-') { $serial = '' }
    $ip = if ($Headset.IPAddress -and -not (Test-UnknownIp $Headset.IPAddress)) { [string]$Headset.IPAddress } else { '' }

    $usbFirst = if ($null -ne $global:ADB_prefer_usb) { [bool]$global:ADB_prefer_usb } else { $true }
    $usb = $null
    if ($serial) {
        $busy = $false
        if (Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) { $busy = Test-UsbBusy }
        if (-not $busy -and @(Get-PublishedUsbDevices | Where-Object { $_.Serial -eq $serial }).Count -gt 0) {
            $usb = [PSCustomObject]@{ DeviceId = $serial; ConnectionType = 'USB' }
        }
    }
    $wifi = $null
    if (Get-Command Resolve-HeadsetWifiEndpoint -ErrorAction SilentlyContinue) {
        # WiFi mode (ADR-0034), still without network I/O: the mode the monitor last saw answer
        # (live status, one row read) first, then the configured order. Each endpoint is a
        # lookup only (registry address, or the published TLS endpoint of the serial).
        $order = @(Get-AdbWifiModeOrder)
        try {
            $live = @(Invoke-DbQuery -Name 'status.get' -Parameters @{ headset_id = [int]$Headset.ID }) | Select-Object -First 1
            if ($live -and $order -contains [string]$live.AdbWifiMode) {
                $order = @([string]$live.AdbWifiMode) + @($order | Where-Object { $_ -ne [string]$live.AdbWifiMode })
            }
        } catch { }
        foreach ($m in $order) {
            $ep = Resolve-HeadsetWifiEndpoint -Headset $Headset -Mode $m -ClassicPort $AdbPort
            if ($ep) { $wifi = [PSCustomObject]@{ DeviceId = ('{0}:{1}' -f $ep.Ip, $ep.Port); ConnectionType = 'WiFi'; WifiMode = $ep.Mode }; break }
        }
    } elseif ($ip) {
        $wifi = [PSCustomObject]@{ DeviceId = (Get-DeviceId -IPAddress $ip -AdbPort $AdbPort); ConnectionType = 'WiFi' }
    }

    if ($usbFirst) { if ($usb) { return $usb }; return $wifi }
    if ($wifi) { return $wifi }
    return $usb
}


function Invoke-HeadsetShutdownBatch {
    <#
    .SYNOPSIS
    Powers off several headsets AT THE SAME TIME, with a hard overall deadline.

    .DESCRIPTION
    One "adb -s <target> shell reboot -p" process per headset, all started before any is
    awaited, so the cost is the slowest headset and not the sum - an offline fleet used to
    take ~1 minute because each one waited out its own connect timeout in turn. Targets come
    from Get-HeadsetShutdownTarget (no network I/O). Anything still running at -TimeoutSec
    is killed and reported as failed. Returns one row per headset, in input order:
    @{ID; Name; Ok; Transport; Error}.

    Invoke-AppShutdown ends with Stop-AdbServer, which would cut a power-off still in flight:
    a caller that shuts the app down afterwards must use the returned rows (this function
    only returns once every process has exited or was killed).

    .EXAMPLE
    $r = Invoke-HeadsetShutdownBatch -Headsets @(Get-KnownHeadsets) -TimeoutSec 6
    #>
    param (
        [Parameter(Mandatory=$true)] [AllowEmptyCollection()] [object[]]$Headsets,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = 0,
        [ValidateRange(1, 60)] [int]$TimeoutSec = 8
    )

    $items = New-Object System.Collections.ArrayList
    foreach ($h in @($Headsets)) {
        $row = [ordered]@{ ID = $h.ID; Name = [string]$h.Name; Ok = $false; Transport = ''; Error = ''; Process = $null }
        try {
            if (-not $adb -or -not (Test-Path -LiteralPath $adb)) { throw 'adb not found' }
            $target = Get-HeadsetShutdownTarget -Headset $h -AdbPort $AdbPort
            if (-not $target) { throw 'no usable address' }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $adb
            $psi.Arguments              = '-s "{0}" shell reboot -p' -f $target.DeviceId
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $row.Process   = [System.Diagnostics.Process]::Start($psi)
            $row.Transport = $target.ConnectionType
            Write-Log ($msg.HeadsetShuttingDown -f $target.DeviceId) -Level INFO
        } catch {
            $row.Error = $_.Exception.Message
        }
        [void]$items.Add($row)
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $running = @($items | Where-Object { $_.Process -and -not $_.Process.HasExited })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 50
    }

    $results = foreach ($row in $items) {
        $p = $row.Process
        if ($p) {
            try {
                if (-not $p.HasExited) {
                    try { $p.Kill() } catch { }
                    $row.Error = 'timeout'
                } else {
                    $stderr = ''
                    try { $stderr = $p.StandardError.ReadToEnd() } catch { }
                    # A device that powers off mid-command can make adb exit non-zero with
                    # "closed"; that is a success. A missing / unauthorized / offline device
                    # is the failure worth reporting.
                    if ($p.ExitCode -eq 0 -or $stderr -match 'closed') {
                        $row.Ok = $true
                    } else {
                        $row.Error = if ($stderr) { $stderr.Trim() } else { "adb exit code $($p.ExitCode)" }
                    }
                }
            } catch { $row.Error = $_.Exception.Message }
            try { $p.Dispose() } catch { }
        }
        Write-Log ("Shutdown: {0} => ok={1}{2}" -f $row.Name, $row.Ok, $(if ($row.Error) { " ($($row.Error))" } else { '' })) -Level INFO
        [PSCustomObject]@{ ID = $row.ID; Name = $row.Name; Ok = $row.Ok; Transport = $row.Transport; Error = $row.Error }
    }
    return @($results)
}


function Set-HeadsetGuardianPause {
    # Pauses (disables) or resumes the Guardian boundary display via debug.oculus.guardian_pause.
    # Session-only - resets on reboot. Pico exposes no equivalent debug prop, so the
    # call is a no-op + WARNING for Brand=Pico (operator must use the headset UI).
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [bool]$Pause = $true,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId
    if ($Brand -eq "Pico") {
        Write-Log "Guardian pause toggle not supported on Pico ($DeviceId) - no equivalent debug prop. Use the headset UI." -Level WARNING
        return $false
    }
    $val = if ($Pause) { '1' } else { '0' }
    try {
        Write-Log ($msg.SettingGuardianMode -f "pause=$val", $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell setprop debug.oculus.guardian_pause $val" -adb $adb | Out-Null
        Write-Log ($msg.HeadsetSettingApplied -f $DeviceId) -Level SUCCESS
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Set-HeadsetGuardian {
    # Opens the guardian/boundary setup UI on the headset so the user can
    # run the initialization. Meta: com.oculus.guardiansetup/.MainActivity.
    # Pico: tries candidate activities in order until one succeeds (exit code 0).
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId
    Write-Log ($msg.SettingGuardianMode -f 'init', $DeviceId) -Level INFO
    try {
        if ($Brand -eq "Pico") {
            $candidates = @(
                "com.pico.guardian/.GuardianActivity",
                "com.pico.guardian/.GuardianSetupActivity",
                "com.pico.guardian/.MainActivity",
                "com.pvr.guardian/.MainActivity"
            )
            foreach ($component in $candidates) {
                $result = Invoke-Adb -adb $adb -Arguments @("-s", $DeviceId, "shell", "am", "start", "-n", $component)
                if ($result.Ok -and $result.StdOut -notmatch 'Error|does not exist|No activities found') {
                    Write-Log ($msg.HeadsetSettingApplied -f $DeviceId) -Level SUCCESS
                    return $true
                }
                Write-Log "Pico guardian candidate failed: $component" -Level DEBUG
            }
            Write-Log "No Pico guardian activity responded. Guardian init may not be supported via ADB on this firmware." -Level WARNING
            return $false
        } else {
            Invoke-AdbCmd -Device $Device -Command "shell am start -n com.oculus.guardiansetup/.MainActivity" -adb $adb | Out-Null
            Write-Log ($msg.HeadsetSettingApplied -f $DeviceId) -Level SUCCESS
            return $true
        }
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-HeadsetScreenTimeout {
    # Meta: persist.ovr.prefs_overrides.idle_time_threshold (seconds, *1000 -> ms)
    # Pico: those props don't exist; fall back to the universal AOSP setting
    #       screen_off_timeout (already ms). When $Brand is empty the Meta path
    #       is tried first, then the AOSP fallback - covers older registry rows.
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { return '-1' }
    try {
        if ($Brand -ne "Pico") {
            $raw = ((Invoke-AdbCmd -Device $Device -Command "shell getprop persist.ovr.prefs_overrides.idle_time_threshold" -adb $adb) -join '').Trim()
            if ($raw -and $raw -match '^\d+$') {
                $ms = [int]$raw * 1000
                if ($ms -eq 0) { return '-1' }
                return [string]$ms
            }
            if ($Brand -eq "Meta") { return '-1' }
        }
        $raw = ((Invoke-AdbCmd -Device $Device -Command "shell settings get system screen_off_timeout" -adb $adb) -join '').Trim()
        if ($raw -and $raw -ne 'null' -and $raw -match '^\d+$') {
            $ms = [int]$raw
            if ($ms -eq 0) { return '-1' }
            return [string]$ms
        }
        # Pico-specific fallback: persist.pxr.idle_time_threshold (in seconds)
        if ($Brand -eq "Pico") {
            $raw = ((Invoke-AdbCmd -Device $Device -Command "shell getprop persist.pxr.idle_time_threshold" -adb $adb) -join '').Trim()
            if ($raw -and $raw -match '^\d+$') {
                $ms = [int]$raw * 1000
                if ($ms -eq 0) { return '-1' }
                return [string]$ms
            }
        }
        return '-1'
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return '-1' }
}


function Get-HeadsetSleepTimeout {
    # Meta: persist.ovr.prefs_overrides.autosleep_time
    # Pico: no separate sleep prop. Reuse screen_off_timeout (same value as
    #       Get-HeadsetScreenTimeout on Pico - the UI can show identical values).
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { return '-1' }
    try {
        if ($Brand -ne "Pico") {
            $raw = ((Invoke-AdbCmd -Device $Device -Command "shell getprop persist.ovr.prefs_overrides.autosleep_time" -adb $adb) -join '').Trim()
            if ($raw -and $raw -match '^\d+$') {
                $ms = [int]$raw * 1000
                if ($ms -eq 0) { return '-1' }
                return [string]$ms
            }
            if ($Brand -eq "Meta") { return '-1' }
        }
        $raw = ((Invoke-AdbCmd -Device $Device -Command "shell settings get system screen_off_timeout" -adb $adb) -join '').Trim()
        if ($raw -and $raw -ne 'null' -and $raw -match '^\d+$') {
            $ms = [int]$raw
            if ($ms -eq 0) { return '-1' }
            return [string]$ms
        }
        return '-1'
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return '-1' }
}

# Quest hardware uses 0-255 with a ~38 minimum (~15% useful range).
# Pico uses 0-100 directly (no scale factor; screen_brightness_max returns null).
$script:BrightnessMinRaw = 38

$script:BrightnessMaxRaw = 255


function Get-HeadsetBrightness {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { return '50' }
    try {
        $raw = ((Invoke-AdbCmd -Device $Device -Command "shell settings get system screen_brightness" -adb $adb) -join '').Trim()
        if (-not ($raw -and $raw -ne 'null' -and $raw -match '^\d+$')) { return '50' }
        $rawInt = [int]$raw
        if ($Brand -eq "Pico") {
            return [string][Math]::Max(0, [Math]::Min(100, $rawInt))
        }
        $pct = [int]([Math]::Round(($rawInt - $script:BrightnessMinRaw) / ($script:BrightnessMaxRaw - $script:BrightnessMinRaw) * 100))
        return [string][Math]::Max(0, [Math]::Min(100, $pct))
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return '50' }
}


function Set-HeadsetBrightness {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [ValidateRange(0,100)]
        [int]$Percent = 50,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId
    $raw = if ($Brand -eq "Pico") {
        [int]([Math]::Max(0, [Math]::Min(100, $Percent)))
    } else {
        [int]([Math]::Round($Percent / 100.0 * ($script:BrightnessMaxRaw - $script:BrightnessMinRaw) + $script:BrightnessMinRaw))
    }
    try {
        Write-Log ($msg.SettingBrightness -f $Percent, $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell settings put system screen_brightness $raw" -adb $adb | Out-Null
        Write-Log ($msg.HeadsetSettingApplied -f $DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function Get-HeadsetSoundLevel {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return '50' }
    try {
        $raw = (Invoke-AdbCmd -Device $Device -Command "shell cmd media_session volume --stream 3 --get" -adb $adb) -join ' '
        if ($raw -match 'volume is (\d+) in range \[0\.\.(\d+)\]') {
            $current = [int]$Matches[1]
            $max     = [int]$Matches[2]
            if ($max -gt 0) {
                return [string][int]([Math]::Round($current / $max * 100))
            }
        }
        return '50'
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return '50' }
}


function Set-HeadsetSoundLevel {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [ValidateRange(0,100)]
        [int]$Percent = 50,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId
    try {
        # Read current range to compute the raw target value
        $getOut = (Invoke-AdbCmd -Device $Device -Command "shell cmd media_session volume --stream 3 --get" -adb $adb) -join ' '
        $max = 15
        if ($getOut -match 'in range \[0\.\.(\d+)\]') { $max = [int]$Matches[1] }
        $value = [int]([Math]::Round($Percent / 100.0 * $max))
        Write-Log ($msg.SettingSoundLevel -f $Percent, $DeviceId) -Level INFO
        # Use AudioService binder directly - method 12 = setStreamVolume(streamType, index, flags)
        # on Meta Quest (Android 14 / SDK 34). stream=3 (MUSIC), flags=0.
        Invoke-AdbCmd -Device $Device -Command "shell service call audio 12 i32 3 i32 $value i32 0" -adb $adb | Out-Null
        Write-Log ($msg.HeadsetSettingApplied -f $DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function Set-HeadsetProximitySensorOverride {
    # Keeps the headset awake as if worn (prox_close). -Clear sends automation_disable, the
    # broadcast the QGO app uses to hand the proximity sensor back (to be confirmed on a
    # headset). Session only. The state is not readable.
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [switch]$Clear
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    $action = if ($Clear) { 'automation_disable' } else { 'prox_close' }
    try {
        Write-Log "Proximity sensor override ($action) on $($Device.DeviceId)" -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell am broadcast -a com.oculus.vrpowermanager.$action" -adb $adb | Out-Null
        Write-Log ($msg.HeadsetSettingApplied -f $Device.DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function Get-HeadsetRefreshRateChoices {
    <#
    .SYNOPSIS
    Refresh rates (Hz) offered for a forced Meta Quest display rate. Shared by the web
    Configure modal and the console menu. From Meta's display-frequency documentation:
    72/80/90/96/100/120 Hz on Quest 2 / 3 / 3S (Quest Pro: up to 90), and 144/180/200 Hz
    on Quest 3 only. Capped at 200 Hz on purpose: 240 Hz does not work well in practice.
    .EXAMPLE
    Get-HeadsetRefreshRateChoices
    #>
    return @(72, 80, 90, 96, 100, 120, 144, 180, 200)
}


function Get-HeadsetRefreshRate {
    <#
    .SYNOPSIS
    Forced display refresh rate of a Meta Quest (debug.oculus.refreshRate), as [int] Hz,
    or $null when not forced / unreadable.
    .EXAMPLE
    Get-HeadsetRefreshRate -Device $device
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }
    try {
        $out = Invoke-AdbCmd -Device $Device -Command "shell getprop debug.oculus.refreshRate" -adb $adb
        if (-not $out) { return $null }
        $hz = 0
        if ([int]::TryParse((@($out) -join '').Trim(), [ref]$hz) -and $hz -gt 0) { return $hz }
        return $null
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level WARNING; return $null }
}


function Set-HeadsetRefreshRate {
    <#
    .SYNOPSIS
    Forces the display refresh rate of a Meta Quest (setprop debug.oculus.refreshRate).
    Session only - a reboot clears it. Returns $true/$false.
    .EXAMPLE
    Set-HeadsetRefreshRate -Device $device -Hz 90
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [Parameter(Mandatory=$true)][ValidateRange(72, 200)][int]$Hz,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    try {
        Write-Log "Forcing display refresh rate to $Hz Hz on $($Device.DeviceId)" -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell setprop debug.oculus.refreshRate $Hz" -adb $adb | Out-Null
        Write-Log ($msg.HeadsetSettingApplied -f $Device.DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function ConvertFrom-SensorUidState {
    <#
    .SYNOPSIS
    Parses the output of `cmd sensorservice get-uid-state <package>`: 'idle' -> $true (the
    package's sensors are switched off), 'active' -> $false, anything else -> $null.
    Pure, no adb. Used by Get-HeadsetDoubleTapDisabled.
    .EXAMPLE
    ConvertFrom-SensorUidState -Text 'idle'
    #>
    param ([string]$Text)
    $t = ([string]$Text).Trim().ToLowerInvariant()
    if ($t -eq 'idle') { return $true }
    if ($t -eq 'active') { return $false }
    return $null
}


function Get-HeadsetDoubleTapDisabled {
    <#
    .SYNOPSIS
    Is the headset-side double tap (the tap on the side of the headset that toggles
    passthrough) switched off? $true = disabled, $false = working, $null = unreadable.
    Reads the sensor state override of the Horizon shell (cmd sensorservice get-uid-state).
    Meta only; a Pico has no such sensor and returns $null.
    .EXAMPLE
    Get-HeadsetDoubleTapDisabled -Device $device
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device -or $Brand -eq 'Pico') { return $null }
    try {
        # get-uid-state answers through its exit code too (idle = 5), which Invoke-AdbCmd would
        # take for a failure and return nothing: end the script with `true` so only the text counts.
        $out = Invoke-AdbCmd -Device $Device -Command "cmd sensorservice get-uid-state com.oculus.vrshell; true" -ShellScript -adb $adb -SilentOnFail
        if ($out -is [bool]) { return $null }
        return (ConvertFrom-SensorUidState -Text (@($out) -join ''))
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level WARNING; return $null }
}


function Set-HeadsetDoubleTapDisabled {
    <#
    .SYNOPSIS
    Disables (or re-enables) the headset-side double tap that toggles passthrough, by putting
    the Horizon shell's sensor access to idle (cmd sensorservice set-uid-state ... idle) or
    clearing that override (reset-uid-state). Meta v81 removed the Settings option; this is
    the same mechanism the QGO app uses. Session only: the override is lost when the headset
    restarts. Verified by reading the state back. Returns $true/$false.
    .EXAMPLE
    Set-HeadsetDoubleTapDisabled -Device $device -Disabled $true
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [bool]$Disabled = $true,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    if ($Brand -eq 'Pico') {
        Write-Log "Double tap control not supported on Pico ($($Device.DeviceId)) - no such sensor." -Level WARNING
        return $false
    }
    # `; true`: the result is verified by the read-back below, not by the exit code.
    $cmd = if ($Disabled) { 'cmd sensorservice set-uid-state com.oculus.vrshell idle; true' } else { 'cmd sensorservice reset-uid-state com.oculus.vrshell; true' }
    try {
        Write-Log "Side double tap $(if ($Disabled) { 'disabled' } else { 'enabled' }) on $($Device.DeviceId)" -Level INFO
        Invoke-AdbCmd -Device $Device -Command $cmd -ShellScript -adb $adb | Out-Null
        $now = Get-HeadsetDoubleTapDisabled -Device $Device -adb $adb -Brand $Brand
        if ($now -ne $Disabled) {
            Write-Log "Side double tap read-back differs on $($Device.DeviceId) (wanted disabled=$Disabled, read '$now')." -Level WARNING
            return $false
        }
        Write-Log ($msg.HeadsetSettingApplied -f $Device.DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function ConvertFrom-WideMotionProps {
    <#
    .SYNOPSIS
    Parses the line `F=<forceEnablePerformanceFeatures> A=<allowhandoverride> T=<handoverridetype>`
    printed by Get-HeadsetWideMotionMode into $true when the hand tracking wide-motion mode
    (body tracking assisted hand tracking, as set by QGO) is on, $false when off, $null when the
    line is not understood. Pure, no adb.
    .EXAMPLE
    ConvertFrom-WideMotionProps -Text 'F=BODY_TRACKING A=1 T=3'
    #>
    param ([string]$Text)
    if (-not ([string]$Text -match 'F=(\S*)\s+A=(\S*)\s+T=(\S*)')) { return $null }
    $force = $Matches[1]; $allow = $Matches[2]; $type = $Matches[3]
    return [bool]($force -match 'BODY_TRACKING' -and $allow -eq '1' -and $type -eq '3')
}


function Get-HeadsetWideMotionMode {
    <#
    .SYNOPSIS
    Is the hand tracking wide-motion mode on ($true), off ($false) or unreadable ($null)?
    Reads the three debug props QGO sets. Meta only.
    .EXAMPLE
    Get-HeadsetWideMotionMode -Device $device
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device -or $Brand -eq 'Pico') { return $null }
    try {
        $script = 'echo "F=$(getprop debug.oculus.forceEnablePerformanceFeatures) A=$(getprop debug.bodyapi.allowhandoverride) T=$(getprop debug.bodyapi.handoverridetype)"'
        $out = Invoke-AdbCmd -Device $Device -Command $script -ShellScript -adb $adb -SilentOnFail
        if ($out -is [bool]) { return $null }
        return (ConvertFrom-WideMotionProps -Text (@($out) -join ' '))
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level WARNING; return $null }
}


function Set-HeadsetWideMotionMode {
    <#
    .SYNOPSIS
    Turns the hand tracking wide-motion mode on or off (the QGO option). On sets
    debug.oculus.forceEnablePerformanceFeatures=BODY_TRACKING, debug.bodyapi.allowhandoverride=1
    and debug.bodyapi.handoverridetype=3; off clears the three props. Session only: a restart
    clears them. Verified by reading back. Meta only. Returns $true/$false.
    .EXAMPLE
    Set-HeadsetWideMotionMode -Device $device -Enabled $true
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [bool]$Enabled = $true,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    if ($Brand -eq 'Pico') {
        Write-Log "Wide-motion hand tracking not supported on Pico ($($Device.DeviceId))." -Level WARNING
        return $false
    }
    $script = if ($Enabled) {
        "setprop debug.oculus.forceEnablePerformanceFeatures BODY_TRACKING && setprop debug.bodyapi.allowhandoverride 1 && setprop debug.bodyapi.handoverridetype 3"
    } else {
        "setprop debug.oculus.forceEnablePerformanceFeatures '' && setprop debug.bodyapi.allowhandoverride '' && setprop debug.bodyapi.handoverridetype ''"
    }
    try {
        Write-Log "Hand tracking wide-motion mode $(if ($Enabled) { 'on' } else { 'off' }) on $($Device.DeviceId)" -Level INFO
        Invoke-AdbCmd -Device $Device -Command $script -ShellScript -adb $adb | Out-Null
        $now = Get-HeadsetWideMotionMode -Device $Device -adb $adb -Brand $Brand
        if ($now -ne $Enabled) {
            Write-Log "Wide-motion mode read-back differs on $($Device.DeviceId) (wanted $Enabled, read '$now')." -Level WARNING
            return $false
        }
        Write-Log ($msg.HeadsetSettingApplied -f $Device.DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function Get-HeadsetGuardianPause {
    <#
    .SYNOPSIS
    Is the Guardian boundary paused (debug.oculus.guardian_pause = 1)? $true / $false, or $null
    when unreadable or on a Pico. Counterpart of Set-HeadsetGuardianPause.
    .EXAMPLE
    Get-HeadsetGuardianPause -Device $device
    #>
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device -or $Brand -eq 'Pico') { return $null }
    try {
        $out = Invoke-AdbCmd -Device $Device -Command 'echo "G=$(getprop debug.oculus.guardian_pause)"' -ShellScript -adb $adb -SilentOnFail
        if ($out -is [bool]) { return $null }
        if ((@($out) -join ' ') -notmatch 'G=(\S*)') { return $null }
        return ($Matches[1] -eq '1')
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level WARNING; return $null }
}


function Reset-HeadsetDisplaySize {
    param (
        [Parameter(Mandatory=$true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.ErrorOccurred -f 'No device') -Level ERROR; return $false }
    try {
        Write-Log "Resetting display size on $($Device.DeviceId)" -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell wm size reset" -adb $adb | Out-Null
        Write-Log ($msg.HeadsetSettingApplied -f $Device.DeviceId) -Level SUCCESS
        return $true
    }
    catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}


function Get-UpdaterPackages {
    # Brand -> updater package names. Pico ships two updater apps that both run
    # OTA background work, so both must be denied/allowed for the block to stick.
    param([string]$Brand)
    if ($Brand -eq "Pico") {
        return @('com.picovr.updatesystem', 'com.picovr.firmwareupdate')
    }
    return @('com.oculus.updater')
}


function Get-HeadsetUpdateBlockStatus {
    param (
        $Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not (Test-Path -LiteralPath $adb)) { return $null }
    try {
        # Blocked iff EVERY updater package has RUN_IN_BACKGROUND: deny.
        # Any package with allow flips the result to false (the block is partial).
        $packages = Get-UpdaterPackages -Brand $Brand
        $sawAny   = $false
        foreach ($pkg in $packages) {
            $output = Invoke-AdbCmd -Device $Device -Command "shell appops get $pkg" -adb $adb
            if ($null -eq $output) { continue }
            $sawAny = $true
            if (-not (($output -join "`n") -match 'RUN_IN_BACKGROUND:\s*deny')) {
                return $false
            }
        }
        if (-not $sawAny) { return $null }
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $null
    }
}


function Set-HeadsetUpdateBlocked {
    param (
        $Device,
        [bool]$Block,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not (Test-Path -LiteralPath $adb)) { return $false }
    try {
        $displayName = if ($Device -is [string]) { $Device } else { $Device.DisplayName }
        $packages = Get-UpdaterPackages -Brand $Brand
        $action   = if ($Block) { 'deny' } else { 'allow' }
        if ($Block) {
            Write-Log ($msg.BlockingUpdates -f $displayName) -Level INFO
        } else {
            Write-Log ($msg.UnblockingUpdates -f $displayName) -Level INFO
        }
        $result = $null
        foreach ($pkg in $packages) {
            Invoke-AdbCmd -Device $Device -Command "shell appops set $pkg RUN_IN_BACKGROUND $action" -adb $adb | Out-Null
            $result = Invoke-AdbCmd -Device $Device -Command "shell appops set $pkg RUN_ANY_IN_BACKGROUND $action" -adb $adb
        }
        if ($result -ne $false) {
            Write-Log ($msg.UpdateBlockApplied -f $displayName) -Level SUCCESS
            return $true
        }
        Write-Log ($msg.UpdateBlockFailed -f $displayName) -Level WARNING
        return $false
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


# ---------------------------------------------------------------------------------------------
# Session-only headset settings and their re-apply after a reboot (ADR-0040).
# A few headset settings are overrides that live in the running system and are lost when the
# headset restarts: the side double tap (sensor override), the hand tracking wide-motion mode,
# the Guardian pause and the proximity sensor override. The operator's wish is kept per headset
# in the app_kv row headset_session_settings_<id> (one row per headset, so poll runspaces never
# race on a shared document, same precedent as headset_ipd_<id>):
#   { reapply: bool, desired: { doubleTapOff, wideMotion, guardianPause, proxKeepAwake },
#     bootId: "<kernel boot id the settings were last applied on>", appliedAt: "<iso utc>" }
# With reapply on, the headset's poll runspace applies the desired settings once per boot.
# ---------------------------------------------------------------------------------------------

# The four remembered on/off settings, in the order they are applied. The image sharpening mode
# is remembered too, as a string (none | fcas | mqsr), see ConvertTo-SharpeningMode.
function Get-SessionSettingKeys { return @('doubleTapOff', 'wideMotion', 'guardianPause', 'proxKeepAwake') }

# Normalises an image sharpening mode: 'fcas' (AMD FidelityFX CAS), 'mqsr' (Meta Quest Super
# Resolution) or 'none' for anything else. Pure.
# Example: ConvertTo-SharpeningMode 'FCAS'
function ConvertTo-SharpeningMode {
    param($Value)
    $v = ([string]$Value).Trim().ToLowerInvariant()
    if ($v -eq 'fcas' -or $v -eq 'mqsr') { return $v }
    return 'none'
}

# The image sharpening mode shown by the headset's debug props (QGO's "Image Sharpening
# Algorithm"): layerFilter 4 = FidelityFX CAS, 3 = Meta Quest Super Resolution, empty = off;
# any other value reads 'custom'. Pure, no adb.
# Example: ConvertFrom-SharpeningProps -LayerFilter '4'
function ConvertFrom-SharpeningProps {
    param([string]$LayerFilter = '')
    $v = $LayerFilter.Trim()
    if ($v -eq '') { return 'none' }
    if ($v -eq '4') { return 'fcas' }
    if ($v -eq '3') { return 'mqsr' }
    return 'custom'
}

# The headset's current image sharpening mode ('none', 'fcas', 'mqsr', 'custom'), or $null when
# unreadable or on a Pico. A global setting: QGO also offers it per app, VRHM only the global one.
# Example: Get-HeadsetSharpening -Device $device -Brand 'Meta'
function Get-HeadsetSharpening {
    param([Parameter(Mandatory)][PSCustomObject]$Device, [string]$adb = $global:adbPath, [string]$Brand = '')
    if (-not $Device -or $Brand -eq 'Pico') { return $null }
    try {
        $out = Invoke-AdbCmd -Device $Device -Command 'echo "L=$(getprop debug.oculus.layerFilter)"' -ShellScript -adb $adb -SilentOnFail
        if ($out -is [bool]) { return $null }
        if (-not ((@($out) -join ' ') -match 'L=(\S*)')) { return $null }
        $lf = $Matches[1]
        return (ConvertFrom-SharpeningProps -LayerFilter $lf)
    } catch { return $null }
}

# Sets the image sharpening mode with the two debug props QGO uses (decoded from QGO 14.5.0):
#   none -> layerFilter '' and pfr.autofilter ''
#   fcas -> layerFilter 4,  pfr.autofilter 4 on Horizon OS 207 or newer, 1 on older firmware
#   mqsr -> layerFilter 3,  pfr.autofilter 4
# Session only (debug props are lost at reboot). Verified by reading back. Meta only.
# Returns $true/$false. Example: Set-HeadsetSharpening -Device $device -Mode 'mqsr' -Brand 'Meta'
function Set-HeadsetSharpening {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Device,
        [Parameter(Mandatory)][string]$Mode,
        [string]$adb = $global:adbPath,
        [string]$Brand = ''
    )
    if (-not $Device) { return $false }
    if ($Brand -eq 'Pico') { Write-Log "Image sharpening not supported on Pico ($($Device.DeviceId))." -Level WARNING; return $false }
    $m = ConvertTo-SharpeningMode $Mode
    $layer = ''; $auto = ''
    if ($m -ne 'none') {
        $vros = 0
        try {
            $vv = Invoke-AdbCmd -Device $Device -Command 'getprop ro.vros.build.version' -ShellScript -adb $adb -SilentOnFail
            if ($vv -isnot [bool]) { [void][int]::TryParse(((@($vv) -join '').Trim()), [ref]$vros) }
        } catch { }
        if ($m -eq 'mqsr') { $layer = '3'; $auto = '4' }
        else               { $layer = '4'; $auto = $(if ($vros -ge 207 -or $vros -eq 0) { '4' } else { '1' }) }
    }
    $q = { param($v) if ($v -eq '') { "''" } else { $v } }
    $script = 'setprop debug.oculus.layerFilter {0} && setprop debug.oculus.pfr.autofilter {1}' -f (& $q $layer), (& $q $auto)
    try {
        Write-Log "Image sharpening $m on $($Device.DeviceId)" -Level INFO
        Invoke-AdbCmd -Device $Device -Command $script -ShellScript -adb $adb | Out-Null
        $now = Get-HeadsetSharpening -Device $Device -adb $adb -Brand $Brand
        if ($now -ne $m) {
            Write-Log "Image sharpening read-back differs on $($Device.DeviceId) (wanted $m, read '$now')." -Level WARNING
            return $false
        }
        Write-Log ($msg.HeadsetSettingApplied -f $Device.DeviceId) -Level SUCCESS
        return $true
    } catch { Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR; return $false }
}

# The stored session settings of one headset, always a full object (every flag false when nothing
# is stored). Memoised 2 s per process so a burst of calls costs one database read. Never throws.
# Example: (Get-HeadsetSessionSettings -HeadsetId 3).desired.doubleTapOff
function Get-HeadsetSessionSettings {
    param([Parameter(Mandatory)][int]$HeadsetId, [switch]$NoMemo)
    $blank = [PSCustomObject]@{
        reapply   = $false
        desired   = [PSCustomObject]@{ doubleTapOff = $false; wideMotion = $false; guardianPause = $false; proxKeepAwake = $false; sharpening = 'none' }
        bootId    = ''
        appliedAt = ''
    }
    if ($HeadsetId -le 0) { return $blank }
    if (-not $script:HeadsetSessionMemo) { $script:HeadsetSessionMemo = @{} }
    $m = $script:HeadsetSessionMemo[$HeadsetId]
    if (-not $NoMemo -and $m -and ([datetime]::UtcNow - $m.At).TotalSeconds -lt 2) { return $m.Val }
    $val = $blank
    try {
        $raw = Get-DbKeyValue -Key ("headset_session_settings_{0}" -f $HeadsetId)
        if ($raw) {
            $val = [PSCustomObject]@{
                reapply   = [bool]$raw.reapply
                desired   = [PSCustomObject]@{
                    doubleTapOff  = [bool]$raw.desired.doubleTapOff
                    wideMotion    = [bool]$raw.desired.wideMotion
                    guardianPause = [bool]$raw.desired.guardianPause
                    proxKeepAwake = [bool]$raw.desired.proxKeepAwake
                    sharpening    = (ConvertTo-SharpeningMode $raw.desired.sharpening)
                }
                bootId    = [string]$raw.bootId
                appliedAt = [string]$raw.appliedAt
            }
        }
    } catch { $val = $blank }
    $script:HeadsetSessionMemo[$HeadsetId] = @{ At = [datetime]::UtcNow; Val = $val }
    return $val
}

# Stores a change in the session settings of one headset, keeping what is not named.
# -Reapply sets the "re-apply after reboot" switch; -Desired is a hashtable of the four flags
# (only the keys given are changed); -BootId stamps the boot the settings were applied on.
# Returns $true when written. Never throws.
# Example: Set-HeadsetSessionSettings -HeadsetId 3 -Desired @{ doubleTapOff = $true }
function Set-HeadsetSessionSettings {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [object]$Reapply = $null,
        [hashtable]$Desired = $null,
        [string]$BootId = $null
    )
    if ($HeadsetId -le 0) { return $false }
    try {
        $cur = Get-HeadsetSessionSettings -HeadsetId $HeadsetId -NoMemo
        $d = [ordered]@{
            doubleTapOff  = [bool]$cur.desired.doubleTapOff
            wideMotion    = [bool]$cur.desired.wideMotion
            guardianPause = [bool]$cur.desired.guardianPause
            proxKeepAwake = [bool]$cur.desired.proxKeepAwake
            sharpening    = (ConvertTo-SharpeningMode $cur.desired.sharpening)
        }
        if ($Desired) {
            foreach ($k in (Get-SessionSettingKeys)) { if ($Desired.ContainsKey($k)) { $d[$k] = [bool]$Desired[$k] } }
            if ($Desired.ContainsKey('sharpening')) { $d['sharpening'] = ConvertTo-SharpeningMode $Desired['sharpening'] }
        }
        $doc = [ordered]@{
            reapply   = $(if ($null -ne $Reapply) { [bool]$Reapply } else { [bool]$cur.reapply })
            desired   = $d
            bootId    = $(if ($PSBoundParameters.ContainsKey('BootId')) { $BootId } else { [string]$cur.bootId })
            appliedAt = $(if ($PSBoundParameters.ContainsKey('BootId')) { [datetime]::UtcNow.ToString('o') } else { [string]$cur.appliedAt })
        }
        Set-DbKeyValue -Key ("headset_session_settings_{0}" -f $HeadsetId) -Value ([PSCustomObject]$doc)
        if ($script:HeadsetSessionMemo) { $script:HeadsetSessionMemo.Remove($HeadsetId) }
        return $true
    } catch { return $false }
}

# Forgets the stored session settings of a removed headset. Never throws.
# Example: Remove-HeadsetSessionSettings -HeadsetId 3
function Remove-HeadsetSessionSettings {
    param([Parameter(Mandatory)][int]$HeadsetId)
    try { Remove-DbKeyValue -Key ("headset_session_settings_{0}" -f $HeadsetId) } catch { }
    if ($script:HeadsetSessionMemo) { $script:HeadsetSessionMemo.Remove($HeadsetId) }
}

# The kernel boot id of the headset (changes at every boot) and whether the system finished booting,
# in ONE adb call. Returns @{BootId;Completed} or $null when unreadable. A headset that has just
# rebooted answers adb before sys.boot_completed is 1, so callers wait for Completed.
# Example: $b = Get-HeadsetBootState -Device $device
function Get-HeadsetBootState {
    param([Parameter(Mandatory)][PSCustomObject]$Device, [string]$adb = $global:adbPath)
    try {
        $out = Invoke-AdbCmd -Device $Device -Command 'echo "B=$(cat /proc/sys/kernel/random/boot_id) C=$(getprop sys.boot_completed)"' -ShellScript -adb $adb -SilentOnFail
        if ($out -is [bool]) { return $null }
        $text = (@($out) -join ' ')
        if (-not ($text -match 'B=(\S+)\s+C=(\S*)')) { return $null }
        $bootId = $Matches[1]; $completed = ($Matches[2] -eq '1')
        return @{ BootId = $bootId; Completed = $completed }
    } catch { return $null }
}

# Pure decision: should the stored session settings be applied now? Returns @{Apply;Reason}.
#   -Settings  Get-HeadsetSessionSettings result
#   -BootId / -Completed   the headset's current boot (Get-HeadsetBootState)
#   -AppliedBootId  the boot the settings were last applied on (stored, or this runspace's memo)
#   -Blocked   a benchmark runs or USB is busy        -NextTry  earliest time to retry a failed apply
# Example: Get-SessionSettingsApplyDecision -Settings $s -BootId 'abc' -Completed $true -AppliedBootId ''
function Get-SessionSettingsApplyDecision {
    param(
        [Parameter(Mandatory)]$Settings,
        [string]$BootId = '',
        [bool]$Completed = $false,
        [string]$AppliedBootId = '',
        [bool]$Blocked = $false,
        [datetime]$NextTry = [datetime]::MinValue,
        [datetime]$Now = [datetime]::Now
    )
    if (-not $Settings.reapply)                       { return @{ Apply = $false; Reason = 'switch off' } }
    $any = $false
    foreach ($k in (Get-SessionSettingKeys)) { if ($Settings.desired.$k) { $any = $true } }
    if ((ConvertTo-SharpeningMode $Settings.desired.sharpening) -ne 'none') { $any = $true }
    if (-not $any)                                    { return @{ Apply = $false; Reason = 'nothing to apply' } }
    if (-not $BootId)                                 { return @{ Apply = $false; Reason = 'boot id unknown' } }
    if (-not $Completed)                              { return @{ Apply = $false; Reason = 'still booting' } }
    if ($BootId -eq $AppliedBootId)                   { return @{ Apply = $false; Reason = 'already applied on this boot' } }
    if ($Blocked)                                     { return @{ Apply = $false; Reason = 'blocked (benchmark or USB busy)' } }
    if ($Now -lt $NextTry)                            { return @{ Apply = $false; Reason = 'backoff' } }
    return @{ Apply = $true; Reason = 'new boot' }
}

# Applies the desired session settings to a headset now. Only the settings wanted ON are applied,
# and the readable ones only when they are not already in that state. Meta only (a Pico returns an
# empty result). Returns a hashtable key -> $true/$false for each setting it tried.
# Example: Invoke-HeadsetSessionSettingsApply -Device $device -Brand 'Meta' -Settings $s
function Invoke-HeadsetSessionSettingsApply {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Device,
        [Parameter(Mandatory)]$Settings,
        [string]$Brand = '',
        [string]$adb = $global:adbPath,
        [switch]$DriftOnly
    )
    # -DriftOnly: the drift check. Only the settings that no longer match are set again (and
    # reported); a setting already in the wanted state is left alone and not listed, and the
    # proximity override, which cannot be read back, is not re-sent.
    $res = @{}
    if ($Brand -eq 'Pico') { return $res }
    if ($Settings.desired.doubleTapOff) {
        $ok = ((Get-HeadsetDoubleTapDisabled -Device $Device -adb $adb -Brand $Brand) -eq $true)
        if (-not $ok) { $res['doubleTapOff'] = [bool](Set-HeadsetDoubleTapDisabled -Device $Device -Disabled $true -adb $adb -Brand $Brand) }
        elseif (-not $DriftOnly) { $res['doubleTapOff'] = $true }
    }
    if ($Settings.desired.wideMotion) {
        $ok = ((Get-HeadsetWideMotionMode -Device $Device -adb $adb -Brand $Brand) -eq $true)
        if (-not $ok) { $res['wideMotion'] = [bool](Set-HeadsetWideMotionMode -Device $Device -Enabled $true -adb $adb -Brand $Brand) }
        elseif (-not $DriftOnly) { $res['wideMotion'] = $true }
    }
    if ($Settings.desired.guardianPause) {
        $ok = ((Get-HeadsetGuardianPause -Device $Device -adb $adb -Brand $Brand) -eq $true)
        if (-not $ok) { $res['guardianPause'] = [bool](Set-HeadsetGuardianPause -Device $Device -Pause $true -adb $adb -Brand $Brand) }
        elseif (-not $DriftOnly) { $res['guardianPause'] = $true }
    }
    $sharp = ConvertTo-SharpeningMode $Settings.desired.sharpening
    if ($sharp -ne 'none') {
        $ok = ((Get-HeadsetSharpening -Device $Device -adb $adb -Brand $Brand) -eq $sharp)
        if (-not $ok) { $res['sharpening'] = [bool](Set-HeadsetSharpening -Device $Device -Mode $sharp -adb $adb -Brand $Brand) }
        elseif (-not $DriftOnly) { $res['sharpening'] = $true }
    }
    if ($Settings.desired.proxKeepAwake -and -not $DriftOnly) {
        # Not readable, so it is always sent (and never in the drift check).
        $res['proxKeepAwake'] = [bool](Set-HeadsetProximitySensorOverride -Device $Device -adb $adb)
    }
    return $res
}

# One step of the poll runspace: when the re-apply switch is on and the headset booted since the
# settings were last applied, apply them. Cheap when the switch is off (one memoised database read,
# no adb call). -State is a hashtable the runspace keeps between calls (AppliedBootId, NextTry,
# Failures). Never throws. Returns $true when settings were applied.
# Example: Update-HeadsetSessionSettings -Headset $row -Device $device -Brand 'Meta' -Blocked $false -State $st
function Update-HeadsetSessionSettings {
    param(
        [Parameter(Mandatory)]$Headset,
        [Parameter(Mandatory)][PSCustomObject]$Device,
        [string]$Brand = '',
        [bool]$Blocked = $false,
        [Parameter(Mandatory)][hashtable]$State
    )
    try {
        $id = 0
        if (-not [int]::TryParse([string]$Headset.ID, [ref]$id) -or $id -le 0) { return $false }
        if ($Brand -eq 'Pico') { return $false }
        $settings = Get-HeadsetSessionSettings -HeadsetId $id
        if (-not $settings.reapply) { return $false }
        if (-not $State.ContainsKey('NextTry')) { $State['NextTry'] = [datetime]::MinValue }
        $boot = Get-HeadsetBootState -Device $Device
        if (-not $boot) {
            if ($State['LastReason'] -ne 'boot state unreadable') { $State['LastReason'] = 'boot state unreadable'; Write-Log ("Session settings on {0}: not applied (boot state unreadable)." -f $Headset.Name) -Level DEBUG }
            return $false
        }
        $applied = $(if ($State['AppliedBootId']) { [string]$State['AppliedBootId'] } else { [string]$settings.bootId })
        $dec = Get-SessionSettingsApplyDecision -Settings $settings -BootId $boot.BootId -Completed $boot.Completed -AppliedBootId $applied -Blocked $Blocked -NextTry $State['NextTry']
        if (-not $dec.Apply) {
            # One DEBUG line per change of reason, so a skipped re-apply is explained in the log.
            $why = '{0} (boot {1})' -f $dec.Reason, $boot.BootId
            if ($State['LastReason'] -ne $why) { $State['LastReason'] = $why; Write-Log ("Session settings on {0}: not applied ({1})." -f $Headset.Name, $why) -Level DEBUG }
            # Drift check, once a minute, on a boot that was already handled: another tool can
            # overwrite a setting after VRHM applied it (QGO writes its own stored values a
            # little after a restart). The settings that no longer match are set again.
            if ($dec.Reason -like 'already applied*' -and -not $Blocked) {
                if (-not $State.ContainsKey('NextDrift')) { $State['NextDrift'] = [datetime]::Now.AddSeconds(60) }
                if ([datetime]::Now -ge $State['NextDrift']) {
                    $State['NextDrift'] = [datetime]::Now.AddSeconds(60)
                    $fix = Invoke-HeadsetSessionSettingsApply -Device $Device -Settings $settings -Brand $Brand -DriftOnly
                    if ($fix.Count -gt 0) {
                        Write-Log ("Session settings on {0} had changed since the restart, set again: {1}." -f $Headset.Name, (@($fix.Keys) -join ', ')) -Level INFO
                        return $true
                    }
                }
            }
            return $false
        }
        $r = Invoke-HeadsetSessionSettingsApply -Device $Device -Settings $settings -Brand $Brand
        $failed = @($r.Keys | Where-Object { -not $r[$_] })
        if ($failed.Count -eq 0) {
            $State['AppliedBootId'] = $boot.BootId
            $State['Failures'] = 0
            [void](Set-HeadsetSessionSettings -HeadsetId $id -BootId $boot.BootId)
            Write-Log ("Session settings re-applied on {0} after a restart ({1})." -f $Headset.Name, (@($r.Keys) -join ', ')) -Level INFO
            return $true
        }
        $State['Failures'] = 1 + [int]$State['Failures']
        $State['NextTry'] = [datetime]::Now.AddSeconds([Math]::Min(300, 30 * [int]$State['Failures']))
        Write-Log ("Session settings re-apply incomplete on {0}: failed {1}. Retrying later." -f $Headset.Name, ($failed -join ', ')) -Level WARNING
        return $false
    } catch {
        if ($State['LastReason'] -ne ('error ' + $_.Exception.Message)) { $State['LastReason'] = 'error ' + $_.Exception.Message; Write-Log ("Session settings on {0}: step error: {1}" -f $Headset.Name, $_.Exception.Message) -Level DEBUG }
        return $false
    }
}
