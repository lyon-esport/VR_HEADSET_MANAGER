###############################################################
# adb_telemetry.ps1
# ADB telemetry readers and their parsers: brand/model, battery, controllers,
# foreground app, thermal, firmware, storage.
# Split out of adb_functions.ps1 (S9-2). Auto-loaded by scripts_init.ps1.
# Translations are loaded centrally in scripts_init.ps1 into $global:msg.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


function Get-HeadsetBrandModel {
    # Returns @{Brand; Model} where Brand is "Meta", "Pico", or "" (unknown).
    # Friendly model name comes from a brand-specific getprop because no single
    # AOSP prop carries a human-readable model on both vendors:
    #   - Meta: ro.product.model = "Quest 3" / "Quest Pro" / ...
    #   - Pico: ro.product.model = "A9210" (useless code); use pxr.vendorhw.product.model
    #          (= "PICO 4 Ultra") with sys.pxr.product.name as secondary fallback.
    # -IncludeSerial adds ro.serialno to the SAME batch and returns it as .Serial, so a
    # caller that needs identity does not pay a second round-trip for it.
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [switch]$IncludeSerial,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return @{ Brand = ""; Model = $null; Serial = "" } }

    # All props in ONE adb call. Reading them one at a time cost 2 spawns on Meta and up
    # to 4 on Pico (whose model needs a fallback chain); the batch costs 1 either way.
    # Asking for the Pico props on a Meta headset is free - getprop just returns empty
    # for a property that does not exist.
    $wanted = @(
        'ro.product.manufacturer',
        'ro.product.model',
        'pxr.vendorhw.product.model',
        'sys.pxr.product.name'
    )
    if ($IncludeSerial) { $wanted += 'ro.serialno' }

    $props = Get-AdbPropBatch -Device $Device -adb $adb -Properties $wanted

    $manufacturer = $props['ro.product.manufacturer']
    $serial       = if ($IncludeSerial) { $props['ro.serialno'] } else { "" }

    if ($manufacturer -match '(?i)pico') {
        $model = $props['pxr.vendorhw.product.model']
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $props['sys.pxr.product.name'] }
        if ([string]::IsNullOrWhiteSpace($model)) { $model = $props['ro.product.model'] }
        return @{ Brand = "Pico"; Model = $model; Serial = $serial }
    }

    $model = $props['ro.product.model']
    $brand = if ($manufacturer -match '(?i)oculus|meta') { "Meta" } else { "" }
    return @{ Brand = $brand; Model = $model; Serial = $serial }
}


function Get-HeadsetModel {
    # Back-compat wrapper. Returns the friendly model string only.
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }
    return (Get-HeadsetBrandModel -Device $Device -adb $adb).Model
}


function ConvertFrom-ControllerDump {
    <#
    .SYNOPSIS
    Parses the "Paired device:" lines of "dumpsys OVRRemoteService" into
    @{ Left = @{Battery;Status;ExternalStatus;TrackingStatus}; Right = ... }.
    Unknown fields stay $null.

    .EXAMPLE
    $c = ConvertFrom-ControllerDump -Lines $dump -DeviceId '192.168.1.10:5555'
    #>
    param (
        $Lines,
        [string]$DeviceId = ''
    )

    $result = @{
        Left  = @{
            Battery        = $null
            Status         = $null
            ExternalStatus = $null
            TrackingStatus = $null
        }
        Right = @{
            Battery        = $null
            Status         = $null
            ExternalStatus = $null
            TrackingStatus = $null
        }
    }

    $paired = @($Lines | Where-Object { $_ -match "Paired device:" })

    foreach ($line in $paired) {

        if ($line -match "Type:\s+(Left|Right)") {
            $side = $Matches[1]

            if ($line -match "Battery:\s*(\d+)%") {
                $result[$side].Battery = [int]$Matches[1]
            }

            if ($line -match "Status:\s*([A-Za-z]+)") {
                $result[$side].Status = $Matches[1]
            }

            if ($line -match "ExternalStatus:\s*(\S+)") {
                $result[$side].ExternalStatus = $Matches[1].TrimEnd(',')
                # Null out battery if controller is not connected (e.g. Searching, Disconnected)
                if ($result[$side].ExternalStatus -notmatch "^CONNECTED") {
                    $result[$side].Battery = $null
                }
            }

            if ($line -match "TrackingStatus:\s*([A-Za-z]+)") {
                $result[$side].TrackingStatus = $Matches[1]
            }

            $batteryDisplay = if ($null -ne $result[$side].Battery) { $result[$side].Battery } else { "N/A" }
            Write-Log ($msg.ControllerBatteryStatus -f $DeviceId, $side, $batteryDisplay, $result[$side].ExternalStatus, $result[$side].TrackingStatus) -Level DEBUG
        }
    }
    return $result
}


function Get-QuestControllerBatteryStatus {
    <#
    .SYNOPSIS
    Retrieves Quest controller battery, connection status and tracking state
    using OVRRemoteService dumpsys.
    #>

    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return @{ Left = @{ Battery=$null; Status=$null; ExternalStatus=$null; TrackingStatus=$null }; Right = @{ Battery=$null; Status=$null; ExternalStatus=$null; TrackingStatus=$null } } }
    $DeviceId = $Device.DeviceId

    $result = ConvertFrom-ControllerDump -Lines @() -DeviceId $DeviceId

    try {
        Write-Log ($msg.QueryControllerStatus -f $DeviceId) -Level DEBUG

        $dump = Invoke-AdbCmd -Device $Device -Command "shell dumpsys OVRRemoteService" -adb $adb
        if (-not $dump) {
            Write-Log ($msg.ControllerStatusFailed -f "No output") -Level WARNING
            return $result
        }

        return (ConvertFrom-ControllerDump -Lines $dump -DeviceId $DeviceId)
    }
    catch {
        Write-Log ($msg.ControllerStatusFailed -f $_.Exception.Message) -Level ERROR
        return $result
    }
}


function ConvertFrom-BatteryDump {
    <#
    .SYNOPSIS
    Parses the lines of "dumpsys battery" into the battery status object
    (Level, Charging, TempC, RawStatus, MaxCharging*). The controller fields stay $null.

    .EXAMPLE
    $b = ConvertFrom-BatteryDump -Lines $batteryInfo
    #>
    param (
        [Parameter(Mandatory=$true)]
        $Lines
    )
    $batteryInfo = @($Lines)

    $result = [PSCustomObject]@{
        Level                  = $null
        Charging               = $false
        TempC                  = $null
        RawStatus              = $null
        MaxChargingCurrentA    = $null
        MaxChargingVoltageV    = $null
        MaxChargingWattageW    = $null
        BatteryControllerLeft  = $null
        BatteryControllerRight = $null
    }

    $result.RawStatus = $batteryInfo -join "`n"

    # Battery level
    $levelMatch = $batteryInfo | Select-String "level:\s+(\d+)"
    if ($levelMatch) {
        $result.Level = [int]$levelMatch.Matches[0].Groups[1].Value
    }

    # Charging state
    $chargingMatch = $batteryInfo | Select-String "AC powered:\s+(true|false)"
    if ($chargingMatch) {
        $result.Charging = $chargingMatch.Matches[0].Groups[1].Value -eq "true"
    }

    # Temperature (tenths of degree)
    $tempMatch = $batteryInfo | Select-String "temperature:\s+(\d+)"
    if ($tempMatch) {
        $result.TempC = [math]::Round(
            $tempMatch.Matches[0].Groups[1].Value / 10,
            1
        )
    }

    # Max charging current (microamps -> A) and voltage (microvolts -> V)
    $currentMatch = $batteryInfo | Select-String "Max charging current:\s+(\d+)"
    $voltageMatch = $batteryInfo | Select-String "Max charging voltage:\s+(\d+)"
    if ($currentMatch) {
        $result.MaxChargingCurrentA = [math]::Round($currentMatch.Matches[0].Groups[1].Value / 1000000, 3)
    }
    if ($voltageMatch) {
        $result.MaxChargingVoltageV = [math]::Round($voltageMatch.Matches[0].Groups[1].Value / 1000000, 3)
    }
    if ($result.MaxChargingCurrentA -and $result.MaxChargingVoltageV) {
        $result.MaxChargingWattageW = [math]::Round($result.MaxChargingCurrentA * $result.MaxChargingVoltageV, 2)
    }
    return $result
}


function Get-HeadsetBatteryStatus {
    <#
    .SYNOPSIS
    Retrieves battery level, charging state and temperature from a VR headset via ADB.
    Controller battery: Meta uses dumpsys OVRRemoteService (works). Pico controller
    battery is not reachable from public ADB (the level lives behind the
    PXR.IPxrControllerService binder, only callable from a signed system-priv APK)
    so we return $null for Brand=Pico. TODO: ship a companion APK if needed.
    The poll runspace does not call this: it reads battery, controllers and the
    foreground app in one adb call (Get-HeadsetPollSnapshot) and feeds the same parsers.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { return $null }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.BatteryStatusQuery -f $DeviceId) -Level DEBUG

        $batteryInfo = Invoke-AdbCmd -Device $Device -Command "shell dumpsys battery" -adb $adb

        if (-not $batteryInfo) {
            Write-Log ($msg.NoBatteryData -f $DeviceId) -Level WARNING
            return $null
        }

        $result = ConvertFrom-BatteryDump -Lines $batteryInfo

        # Controller battery levels (left & right) - Meta only.
        if ($Brand -ne "Pico") {
            $controllers = Get-QuestControllerBatteryStatus -Device $Device -adb $adb
            if ($controllers) {
                $result.BatteryControllerLeft  = $controllers.Left.Battery
                $result.BatteryControllerRight = $controllers.Right.Battery
            }
        }

        Write-Log ($msg.BatteryStatus -f $DeviceId, $result.Level, $result.Charging, $result.TempC, $result.MaxChargingWattageW) -Level DEBUG
        return $result
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $null
    }
}


function Get-BatteryTimeEstimate {
    <#
    .SYNOPSIS
    Estimates battery power state and remaining time from a serialized history string.

    .DESCRIPTION
    Requires exactly 3 entries with 3 distinct battery % levels within a 10% spread.
    Power state is derived from the sign of % change across both intervals.
    If the direction changes between intervals (non-linear), PowerState reflects the
    last observed interval and MinutesRemaining is $null.
    When monotonic, MinutesRemaining is the average of two interval-based projections.

    .PARAMETER HistoryString
    Pipe-separated entries, each "ISO8601timestamp=level".
    Example: "2026-04-23T10:00:00=60|2026-04-23T10:15:00=61|2026-04-23T10:30:00=63"
    #>
    param (
        [string]$HistoryString
    )

    $result = [PSCustomObject]@{
        PowerState       = $null
        MinutesRemaining = $null
    }

    if ([string]::IsNullOrWhiteSpace($HistoryString)) { return $result }

    # Parse entries
    $entries = @()
    foreach ($part in ($HistoryString -split '\|')) {
        $part = $part.Trim()
        if ($part -notmatch '^(.+)=(\d+)$') { continue }
        try {
            $entries += [PSCustomObject]@{
                Time  = [datetime]$Matches[1]
                Level = [int]$Matches[2]
            }
        } catch { continue }
    }

    # Sort by time and keep last 3
    $entries = @($entries | Sort-Object Time | Select-Object -Last 3)

    # Need exactly 3 entries
    if ($entries.Count -lt 3) { return $result }

    $T0 = $entries[0]; $T1 = $entries[1]; $T2 = $entries[2]

    # All three levels must be distinct
    if ($T0.Level -eq $T1.Level -or $T1.Level -eq $T2.Level -or $T0.Level -eq $T2.Level) {
        return $result
    }

    # Max spread must be <= 10%
    $levels = @($T0.Level, $T1.Level, $T2.Level)
    if (($levels | Measure-Object -Maximum).Maximum - ($levels | Measure-Object -Minimum).Minimum -gt 10) {
        return $result
    }

    $d1 = $T1.Level - $T0.Level
    $d2 = $T2.Level - $T1.Level

    # Determine direction from last interval (used in all cases)
    $result.PowerState = if ($d2 -gt 0) { 'charging' } else { 'discharging' }

    # Non-linear: direction changed - cannot estimate time
    if (($d1 -gt 0 -and $d2 -lt 0) -or ($d1 -lt 0 -and $d2 -gt 0)) {
        return $result
    }

    # Monotonic - compute rates and average projected time
    $targetLevel = if ($result.PowerState -eq 'charging') { 100 } else { 5 }

    try {
        $min01 = ([datetime]$T1.Time - [datetime]$T0.Time).TotalMinutes
        $min12 = ([datetime]$T2.Time - [datetime]$T1.Time).TotalMinutes
    } catch { return $result }

    if ($min01 -le 0 -or $min12 -le 0) { return $result }

    $rate01 = $d1 / $min01   # %/min
    $rate12 = $d2 / $min12   # %/min

    if ($rate01 -eq 0 -or $rate12 -eq 0) { return $result }

    $remaining = $targetLevel - $T2.Level
    $time01 = $remaining / $rate01
    $time12 = $remaining / $rate12

    if ($time01 -le 0 -or $time12 -le 0) { return $result }

    $avg = ($time01 + $time12) / 2
    $result.MinutesRemaining = [math]::Min([int][math]::Round($avg), 600)

    Write-Log ($msg.BatteryTimeEstimate -f $T2.Level, $result.MinutesRemaining, $result.PowerState) -Level DEBUG
    return $result
}


function ConvertFrom-ForegroundActivityLines {
    <#
    .SYNOPSIS
    Package name of the foreground app from the lines of "dumpsys activity activities"
    (full dump, or filtered with grep -A1 on topResumedActivity=/mResumedActivity), or $null.

    .EXAMPLE
    ConvertFrom-ForegroundActivityLines -Lines $dumpLines
    #>
    param (
        $Lines
    )
    $dumpLines = @($Lines | ForEach-Object { [string]$_ })

    # Quest 3 / Android 12+: the ActivityRecord wraps across two lines:
    #   line N  : "  topResumedActivity=ActivityRecord{hash u0 "
    #   line N+1: "com.package.name/com.ClassName tXXXX}"
    # We want the FIRST match (= the user app, not system overlays).
    for ($i = 0; $i -lt $dumpLines.Count - 1; $i++) {
        if ($dumpLines[$i] -match 'topResumedActivity=ActivityRecord\{') {
            # Most common: package on next line
            $nextLine = $dumpLines[$i + 1].Trim()
            if ($nextLine -match '^([\w\.]+)/') {
                return $Matches[1]
            }
            # Same-line format (some Android 10/11 builds)
            if ($dumpLines[$i] -match 'topResumedActivity.*?\s+([\w\.]+)/') {
                return $Matches[1]
            }
        }
    }

    # Fallback: mResumedActivity (Quest 2 / older firmware)
    $line = $dumpLines | Select-String "mResumedActivity" | Select-Object -First 1
    if ($line -match 'mResumedActivity.*?\s+([\w\.]+)/') {
        return $Matches[1]
    }
    return $null
}


function Get-HeadsetForegroundApp {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }

    try {
        $dumpLines = @(Invoke-AdbCmd -Device $Device -Command "shell dumpsys activity activities" -adb $adb)
        return (ConvertFrom-ForegroundActivityLines -Lines $dumpLines)
    } catch {
        Write-Log ($msg.AdbInfoFailed -f $headsetIP, $_) -Level ERROR
    }
    return $null
}


function Get-HeadsetFirmwareInfo {
    <#
    .SYNOPSIS
    Returns firmware version and build number for a headset via ADB.
    UpdateVersion is a best-effort field (always null on current Meta Quest firmware - see comment in body).
    .EXAMPLE
    $d = Get-AdbWifiDevice -headsetIP "192.168.1.244"
    Get-HeadsetFirmwareInfo -Device $d
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ""
    )
    if (-not $Device) { return $null }
    try {
        if ($Brand -eq "Pico") {
            # Pico: ro.build.version.release = Android version (e.g. 14)
            # ro.build.version.incremental = numeric build (e.g. 1769174699)
            # com.picovr.updatesystem dump has versionName (operator-friendly: "3.0.0")
            $version = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.build.version.release" -adb $adb) -join '').Trim()
            $build   = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.build.version.incremental" -adb $adb) -join '').Trim()
            $updateVersion = $null
            $dump = Invoke-AdbCmd -Device $Device -Command "shell dumpsys package com.picovr.updatesystem" -adb $adb
            if ($dump) {
                $vn = ($dump | Select-String 'versionName=([\S]+)' | Select-Object -First 1)
                if ($vn) { $updateVersion = $vn.Matches[0].Groups[1].Value }
            }
            return [PSCustomObject]@{
                Version       = $version
                Build         = $build
                UpdateVersion = $updateVersion
            }
        }

        # ro.hzos.build.display_name gives the Meta Quest OS version (e.g. "2.3")
        # ro.vros.build.version gives the numeric release (e.g. "203") used as fallback
        # All ro.*version.release props return Android version "14", not the Meta OS version
        $version = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.hzos.build.display_name" -adb $adb) -join '').Trim()
        if (-not $version) {
            $version = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.vros.build.version" -adb $adb) -join '').Trim()
        }

        # Build number: ro.build.version.incremental encodes Meta build as
        # "AAAAAAA00BBBB0CCC" (7+2+4+1+3 digits) -> "AAAAAAA.BBBB.CCC"
        # e.g. "52083180032000520" -> "5208318.3200.520"
        $rawBuild = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.build.version.incremental" -adb $adb) -join '').Trim()
        if ($rawBuild -match '^(\d{7})00(\d{4})0(\d{3})$') {
            $build = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        } else {
            $build = $rawBuild
        }

        # Pending OTA version - NOTE: on Meta Quest the update version is stored in
        # com.oculus.updater's private data (/metadata/ota/prefs/, /data/misc/update_engine/)
        # which is SELinux-protected and inaccessible to ADB without root.
        # ro.update.version is kept as a best-effort fallback for firmware variants that
        # may expose it, but returns empty on current Quest firmware.
        $updateVersion = $null
        $otaVer = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.update.version" -adb $adb) -join '').Trim()
        if ($otaVer -and $otaVer -ne $version -and $otaVer -notmatch '^\s*$') {
            $updateVersion = $otaVer
        }

        return [PSCustomObject]@{
            Version       = $version
            Build         = $build
            UpdateVersion = $updateVersion
        }
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $null
    }
}


function Get-HeadsetStorageInfo {
    <#
    .SYNOPSIS
    Returns storage capacity, usage and free space for a headset via ADB (df /sdcard).
    .EXAMPLE
    $d = Get-AdbWifiDevice -headsetIP "192.168.1.244"
    Get-HeadsetStorageInfo -Device $d
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.StorageInfoQuery -f $DeviceId) -Level DEBUG

        $dfOutput = Invoke-AdbCmd -Device $Device -Command "shell df /sdcard" -adb $adb

        if (-not $dfOutput) {
            Write-Log ($msg.StorageInfoError -f $DeviceId) -Level WARNING
            return $null
        }

        # df output: header line + data line(s). Find the line with /sdcard or /dev/fuse
        $dataLine = $dfOutput | Where-Object { $_ -match '/sdcard|/dev/fuse' } | Select-Object -First 1
        if (-not $dataLine) {
            # fallback: second non-empty line if no match by mount point
            $dataLine = ($dfOutput | Where-Object { $_.Trim() -ne '' })[1]
        }
        if (-not $dataLine) {
            Write-Log ($msg.StorageInfoError -f $DeviceId) -Level WARNING
            return $null
        }

        # Columns: Filesystem  1K-blocks  Used  Available  Use%  Mounted
        $cols = $dataLine -split '\s+' | Where-Object { $_ -ne '' }
        if ($cols.Count -lt 5) {
            Write-Log ($msg.StorageInfoError -f $DeviceId) -Level WARNING
            return $null
        }

        $totalKB = [long]$cols[1]
        $usedKB  = [long]$cols[2]
        $freeKB  = [long]$cols[3]

        $toGB = { param($kb) [math]::Round($kb / 1048576.0, 2) }

        $totalGB = & $toGB $totalKB
        $usedGB  = & $toGB $usedKB
        $freeGB  = & $toGB $freeKB

        $usedPct = if ($totalKB -gt 0) { [int][math]::Round($usedKB / $totalKB * 100) } else { 0 }
        $freePct = 100 - $usedPct

        $result = [PSCustomObject]@{
            TotalGB     = $totalGB
            UsedGB      = $usedGB
            FreeGB      = $freeGB
            UsedPercent = $usedPct
            FreePercent = $freePct
            TotalKB     = $totalKB
            UsedKB      = $usedKB
            FreeKB      = $freeKB
        }

        Write-Log ($msg.StorageInfoResult -f $DeviceId, $totalGB, $usedGB, $freeGB, $usedPct) -Level DEBUG
        return $result
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $null
    }
}


function ConvertFrom-ThermalService {
    <#
    .SYNOPSIS
    Parses the output of "dumpsys thermalservice" into per-sensor-type temperatures.

    .DESCRIPTION
    Shared by the VRMonitor stage-2 read (CPU/GPU/skin into the metric history) and the
    DIAG page health section, so the parsing lives in exactly one place.

    thermalservice lists each sensor as
        Temperature{mValue=36.4, mType=3, mName=VIRTUAL-SKIN, mStatus=0}
    mType is the Android HardwareProperties type: 0 CPU, 1 GPU, 2 BATTERY, 3 SKIN,
    4 USB_PORT. There are usually several sensors per type (cpu0..cpuN), so the value kept
    per type is the MAXIMUM - the hottest core is what throttles the device.

    The dump holds the same sensors twice, as "Cached temperatures" and as "Current
    temperatures from HAL". The HAL section is preferred when present, because the cache
    can be stale; the whole dump is used when the section is missing (older firmware).

    NaN and absurd readings (<= 0 or > 150) are ignored: an unplugged or uncalibrated
    sensor reports them and they would wreck the graph scale.

    "Thermal Status: N" is the overall throttling level (0 none, 1 light, 2 moderate,
    3 severe, 4 critical, 5 emergency, 6 shutdown), returned as Status.

    Returns [PSCustomObject]@{ Cpu; Gpu; Battery; Skin; UsbPort; Status; Sensors } - each
    temperature a [double] or $null when no sensor of that type reported; Sensors is the
    flat list @{Type;Name;Value;Status} for the DIAG page.

    .EXAMPLE
    $t = ConvertFrom-ThermalService -Lines (Invoke-AdbCmd -Device $d -Command "shell dumpsys thermalservice")
    $t.Cpu
    #>
    param([string[]]$Lines)

    $result = [PSCustomObject]@{
        Cpu = $null; Gpu = $null; Battery = $null; Skin = $null; UsbPort = $null
        BatterySensor = $null; SkinSensor = $null
        Status = $null; Sensors = @()
    }
    if (-not $Lines) { return $result }

    $all = @($Lines)

    # Prefer the live HAL section; fall back to the whole dump.
    $start = -1
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -match 'Current temperatures from HAL') { $start = $i + 1; break }
    }
    $scan = @()
    if ($start -ge 0) {
        for ($i = $start; $i -lt $all.Count; $i++) {
            # The section ends at the next non-indented heading (cooling devices, etc.).
            if ($all[$i] -match '^\S' -and $all[$i] -notmatch 'Temperature\{') { break }
            $scan += $all[$i]
        }
    }
    if ($scan.Count -eq 0) { $scan = $all }

    $inv     = [System.Globalization.CultureInfo]::InvariantCulture
    $pattern = 'Temperature\{mValue=(?<v>[^,]+),\s*mType=(?<t>\d+),\s*mName=(?<n>[^,]*),\s*mStatus=(?<s>\d+)\}'
    $best    = @{}
    $sensors = @()
    foreach ($line in $scan) {
        $m = [regex]::Match($line, $pattern)
        if (-not $m.Success) { continue }
        $value = 0.0
        if (-not [double]::TryParse($m.Groups['v'].Value.Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$value)) { continue }
        if ([double]::IsNaN($value) -or $value -le 0 -or $value -gt 150) { continue }
        $type = [int]$m.Groups['t'].Value
        $sensors += [PSCustomObject]@{ Type = $type; Name = $m.Groups['n'].Value.Trim(); Value = $value; Status = [int]$m.Groups['s'].Value }
        if (-not $best.ContainsKey($type) -or $value -gt $best[$type]) { $best[$type] = $value }
    }

    if ($best.ContainsKey(0)) { $result.Cpu     = $best[0] }
    if ($best.ContainsKey(1)) { $result.Gpu     = $best[1] }
    # Battery and skin are NOT the hottest sensor of their type. A Quest 3 reports a power-chip
    # die (pm8550b_tz, ~58 C) and a fuel gauge next to the real battery sensor, and a dozen
    # internal board sensors (soc-usr, rf-usr, pcb*-usr) next to the surface ones - taking the
    # maximum put a chip temperature on the "battery" and "skin" tiles, 15-20 C above what the
    # battery and the casing actually are. So prefer the sensor that carries the meaning:
    #   battery  the one named "battery" (it equals dumpsys battery), then batt-virt-usr
    #   skin     the virtual surface sensor (virtual-skin / skin / surf-virt-usr)
    # and only fall back to the maximum when a firmware has none of them. CPU and GPU stay at
    # the maximum on purpose: the hottest core is the one that throttles.
    $preferred = {
        param([int]$Type, [string[]]$NamePatterns)
        $of = @($sensors | Where-Object { $_.Type -eq $Type })
        if ($of.Count -eq 0) { return $null }
        foreach ($rx in $NamePatterns) {
            $hit = $of | Where-Object { $_.Name -match $rx } | Select-Object -First 1
            if ($hit) { return $hit }
        }
        return ($of | Sort-Object Value -Descending | Select-Object -First 1)
    }
    $batterySensor = & $preferred 2 @('(?i)^battery$', '(?i)^batt-virt')
    if ($batterySensor) { $result.Battery = $batterySensor.Value; $result.BatterySensor = $batterySensor.Name }
    $skinSensor = & $preferred 3 @('(?i)^virtual-skin$', '(?i)^skin', '(?i)^surf-virt')
    if ($skinSensor) { $result.Skin = $skinSensor.Value; $result.SkinSensor = $skinSensor.Name }
    if ($best.ContainsKey(4)) { $result.UsbPort = $best[4] }
    $result.Sensors = $sensors

    foreach ($line in $all) {
        $sm = [regex]::Match($line, 'Thermal Status:\s*(\d+)')
        if ($sm.Success) { $result.Status = [int]$sm.Groups[1].Value; break }
    }
    return $result
}
