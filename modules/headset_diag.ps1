###############################################################################
# headset_diag.ps1 - per-headset diagnostics behind website\headset_diag.html
#
# WHAT THIS IS
# ------------
# The backend of the DIAG page (inspired by the Quas v7.0 multitool): firmware,
# health, wireless, USB/cable and a set of operator actions, for ONE known
# headset at a time. Web-only by decision (ADR-0023, proposed): there is no
# console menu for it, but every bit of logic lives here, in module functions,
# so a console entry can be added later without touching the web server.
#
# THE RULES
# ---------
# * One section = ONE adb shell spawn. The web server is a single-threaded
#   HttpListener, so a section that ran fifteen adb.exe processes would freeze
#   every other page for its whole duration. Commands are chained inside one
#   shell and the output is split back on an echoed marker (the same technique
#   as Get-AdbPropBatch). The PC-side USB section and the cable test are the
#   documented exceptions: the first runs no adb at all, the second is an
#   explicit operator action.
# * The device is resolved USB-first (Resolve-HeadsetAdbDevice, ADR-0024
#   proposed) and every adb call goes through Invoke-HeadsetDiagRaw, which
#   retries once over WiFi when a USB transport disappears mid-command.
# * The shell script travels as ONE double-quoted argument, so it must never
#   contain a double quote or a backslash-quote. Text coming from the operator
#   is sanitised for that before it is spliced in.
# * Nothing here touches the existing WiFi ADB enabling flow. The ADB-over-TLS
#   functions at the bottom are an experiment, called only by the DIAG page.
#
# ASCII only (ADR-0007).
###############################################################################

$script:DiagMarker = '===VRHM==='

# Shell commands the free-text ADB panel refuses outright. Matched
# case-insensitively anywhere in the command.
$script:DiagBlockedPatterns = @(
    'reboot\s+bootloader',
    'reboot\s+recovery',
    'rm\s+-[a-z]*r[a-z]*f?\s+/(\s|$)',
    'rm\s+-[a-z]*f[a-z]*r\s+/(\s|$)',
    '\bwipe\b',
    '\bfastboot\b'
)


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

function Invoke-HeadsetDiagRaw {
    <#
    .SYNOPSIS
    Runs one adb command for the DIAG page and returns the full result, even when
    the command exits non-zero.

    .DESCRIPTION
    Invoke-AdbCmd returns $false on a non-zero exit, which is right for the rest of
    the app but wrong here: a diagnostic "grep" that matches nothing exits 1, and
    the operator's free-text command must show its stderr. So this calls
    Invoke-Adb directly and keeps the one thing Invoke-AdbCmd adds that matters:
    a USB device of a known headset that loses its transport is retried ONCE over
    WiFi (cable pulled while the page was open).

    Returns @{ Ok; ExitCode; StdOut; StdErr; DeviceId; Transport; FellBack }.
    .EXAMPLE
    $r = Invoke-HeadsetDiagRaw -Device $d -Arguments @('shell','getprop ro.product.model')
    #>
    param(
        [Parameter(Mandatory=$true)]$Device,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 15,
        [string]$adb = $global:adbPath
    )

    $deviceId  = [string]$Device.DeviceId
    $transport = [string]$Device.ConnectionType
    $result    = Invoke-Adb -Arguments (@('-s', $deviceId) + $Arguments) -TimeoutSeconds $TimeoutSeconds -Adb $adb
    $fellBack  = $false

    if (-not $result.Ok -and $transport -eq 'USB' -and $Device.PSObject.Properties['HeadsetIP'] -and $Device.HeadsetIP -and (Test-AdbTransportFailure -Result $result)) {
        if ($null -eq $script:UsbFailedSerials) { $script:UsbFailedSerials = @{} }
        $script:UsbFailedSerials[$deviceId] = Get-Date
        $port = if ($Device.HeadsetPort) { [int]$Device.HeadsetPort } else { $global:adbPort_default }
        $wifi = Get-AdbWifiDevice -headsetIP $Device.HeadsetIP -AdbPort $port -adb $adb
        if ($wifi) {
            Write-Log ((Get-MessageString -Key 'Diag.Transport.FallbackToWifi' -Fallback 'USB transport lost for {0}: retrying over WiFi ({1})') -f $deviceId, $wifi.DeviceId) -Level INFO
            $deviceId  = $wifi.DeviceId
            $transport = 'WiFi'
            $fellBack  = $true
            $result    = Invoke-Adb -Arguments (@('-s', $deviceId) + $Arguments) -TimeoutSeconds $TimeoutSeconds -Adb $adb
        }
    }

    return @{
        Ok        = [bool]$result.Ok
        ExitCode  = $result.ExitCode
        StdOut    = @($result.StdOut)
        StdErr    = @($result.StdErr)
        DeviceId  = $deviceId
        Transport = $transport
        FellBack  = $fellBack
    }
}


function Invoke-HeadsetDiagShell {
    <#
    .SYNOPSIS
    Runs several shell commands in ONE "adb shell" and returns one string array per
    command, in order.

    .DESCRIPTION
    Commands are joined with "; echo ===VRHM===; " so a command that prints
    nothing (an absent property, a grep with no match) still yields its own empty
    segment instead of shifting every later one. A command that fails does not
    stop the chain - ";" is not "&&".

    Returns @{ Segments = @(@(...), ...); Transport; DeviceId; Ok; Error }.
    .EXAMPLE
    $r = Invoke-HeadsetDiagShell -Device $d -Commands @('getprop ro.product.model', 'date +%s')
    $r.Segments[1]
    #>
    param(
        [Parameter(Mandatory=$true)]$Device,
        [Parameter(Mandatory=$true)][string[]]$Commands,
        [int]$TimeoutSeconds = 20,
        [string]$adb = $global:adbPath
    )

    foreach ($c in $Commands) {
        if ($c -match '"') { throw "Invoke-HeadsetDiagShell: a command must not contain a double quote: $c" }
    }
    $script = ($Commands -join ("; echo " + $script:DiagMarker + "; ")) + "; echo " + $script:DiagMarker
    $r = Invoke-HeadsetDiagRaw -Device $Device -Arguments @('shell', $script) -TimeoutSeconds $TimeoutSeconds -adb $adb

    $segments = @()
    $current  = @()
    foreach ($line in @($r.StdOut)) {
        if ($line.Trim() -eq $script:DiagMarker) {
            $segments += ,@($current)
            $current = @()
        } else {
            $current += $line
        }
    }
    while ($segments.Count -lt $Commands.Count) { $segments += ,@() }

    $err = ''
    if (-not $r.Ok -and @($r.StdOut).Count -eq 0) { $err = ((@($r.StdErr) -join ' ').Trim()) }
    return @{
        Segments  = $segments
        Transport = $r.Transport
        DeviceId  = $r.DeviceId
        FellBack  = $r.FellBack
        Ok        = ($err -eq '')
        Error     = $err
    }
}


function Get-DiagSegmentText {
    # First non-empty trimmed line of a segment, or '' - for single-value getprop/settings reads.
    param($Segment)
    foreach ($l in @($Segment)) { if ($l -and $l.Trim()) { return $l.Trim() } }
    return ''
}


function ConvertTo-DiagShellQuoted {
    <#
    .SYNOPSIS
    Makes operator text safe to splice into the DIAG shell string as one
    single-quoted device-shell word.
    .DESCRIPTION
    Printable ASCII only (anything else is dropped), double quotes and backslashes
    dropped (they would break the outer Windows argument), single quotes escaped
    the POSIX way ('\'' closes, adds a literal quote, reopens).
    .EXAMPLE
    ConvertTo-DiagShellQuoted "Time's up"   # -> 'Time'\''s up'
    #>
    param([string]$Text, [int]$MaxLength = 200)
    if ($null -eq $Text) { $Text = '' }
    $clean = -join ($Text.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -le 126 -and $_ -ne '"' -and $_ -ne '\' })
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) }
    return "'" + ($clean -replace "'", "'\''") + "'"
}


function Resolve-DiagHeadset {
    <#
    .SYNOPSIS
    Registry row + resolved ADB device for a headset id. Throws a readable
    message when either is missing.
    .EXAMPLE
    $ctx = Resolve-DiagHeadset -Id 3
    #>
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [switch]$NoDevice
    )
    $headset = @(Get-KnownHeadsets) | Where-Object { [string]$_.ID -eq [string]$Id } | Select-Object -First 1
    if (-not $headset) { throw "Headset not found" }
    if ($NoDevice) { return @{ Headset = $headset; Device = $null } }
    $device = Resolve-HeadsetAdbDevice -Headset $headset
    if (-not $device) { throw "Could not connect to headset via ADB (no USB cable and WiFi ADB unreachable)" }
    return @{ Headset = $headset; Device = $device }
}


function Get-DiagBrand {
    param($Headset)
    if ($Headset.PSObject.Properties['Brand'] -and $Headset.Brand) { return [string]$Headset.Brand }
    if ([string]$Headset.Model -match '(?i)pico') { return 'Pico' }
    return 'Meta'
}


# ---------------------------------------------------------------------------
# Sections (read only)
# ---------------------------------------------------------------------------

function Get-HeadsetDiagFirmware {
    <#
    .SYNOPSIS
    Firmware, pending OTA, updater state and private DNS for one headset (one adb spawn on Meta).
    .EXAMPLE
    Get-HeadsetDiagFirmware -Headset $h -Device $d
    #>
    param(
        [Parameter(Mandatory=$true)]$Headset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath
    )

    $brand = Get-DiagBrand $Headset
    $out = [ordered]@{
        Brand              = $brand
        OsDisplay          = ''
        FirmwareVersion    = ''
        EnvironmentRaw     = ''
        Build              = ''
        ProductName        = ''
        Components         = @()
        PendingOta         = ''
        OtaProgress        = $null
        OtaLog             = @()
        UpdaterDisabled    = $null
        UpdateBlocked      = $null
        PrivateDnsMode     = ''
        PrivateDnsHost     = ''
        OldFirmwareWarning = $false
        Transport          = [string]$Device.ConnectionType
        History            = @()
    }

    if ($brand -eq 'Pico') {
        # PICO exposes none of the Meta-only fields; reuse the existing reader.
        $fw = Get-HeadsetFirmwareInfo -Device $Device -adb $adb -Brand 'Pico'
        if ($fw) {
            $out.OsDisplay       = [string]$fw.Version
            $out.FirmwareVersion = [string]$fw.UpdateVersion
            $out.EnvironmentRaw  = [string]$fw.Build
            $out.Build           = [string]$fw.Build
        }
    } else {
        $cmds = @(
            'getprop ro.hzos.build.display_name',
            'getprop ro.vros.build.version',
            'getprop ro.build.version.incremental',
            'getprop ro.product.name',
            'dumpsys package com.oculus.systemux | grep -m1 versionName',
            'dumpsys package com.oculus.systemutilities | grep -m1 versionName',
            'dumpsys DumpsysProxy OculusUpdater | head -300',
            'pm list packages -d | grep -i updater',
            "logcat -d -t 3000 | grep -E 'Current progress|OTA applying update|OTA progress updated' | tail -5",
            'settings get global private_dns_mode',
            'settings get global private_dns_specifier'
        )
        $r = Invoke-HeadsetDiagShell -Device $Device -Commands $cmds -TimeoutSeconds 25 -adb $adb
        if (-not $r.Ok) { throw $r.Error }
        $seg = $r.Segments
        $out.Transport = $r.Transport

        $out.OsDisplay   = Get-DiagSegmentText $seg[0]
        if (-not $out.OsDisplay) { $out.OsDisplay = Get-DiagSegmentText $seg[1] }
        $out.EnvironmentRaw = Get-DiagSegmentText $seg[2]
        if ($out.EnvironmentRaw -match '^(\d{7})00(\d{4})0(\d{3})$') {
            $out.Build = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        } else {
            $out.Build = $out.EnvironmentRaw
        }
        $out.ProductName = Get-DiagSegmentText $seg[3]

        # Quest Pro ships the system shell as systemutilities instead of systemux.
        $vnLine = if ($out.ProductName -match 'panther') { Get-DiagSegmentText $seg[5] } else { Get-DiagSegmentText $seg[4] }
        if (-not $vnLine) { $vnLine = (Get-DiagSegmentText $seg[4]) + (Get-DiagSegmentText $seg[5]) }
        if ($vnLine -match 'versionName=(\S+)') {
            $octets = @($Matches[1] -split '\.')
            $out.FirmwareVersion = (($octets | Select-Object -First 4) -join '.')
        }
        if ($out.FirmwareVersion -match '^(\d+)') { $out.OldFirmwareWarning = ([int]$Matches[1] -lt 71) }

        # OculusUpdater dump: component table rows are '|'-separated; the version
        # sits in column 10 on current firmware (Quas uses the same column).
        $wanted = 'Integrity|Core Mobile Services|Library|Device Settings|Assistant|Platform|Presence'
        $components = @()
        foreach ($line in @($seg[6])) {
            if ($line -match 'download_uri\s*[=:]\s*(\S+)' -and -not $out.PendingOta) { $out.PendingOta = $Matches[1].Trim(',') }
            if ($line -notmatch '\|') { continue }
            $cols = @($line -split '\|' | ForEach-Object { $_.Trim() })
            $name = $cols[0]
            if (-not $name -or $name -notmatch $wanted) { continue }
            $ver = if ($cols.Count -gt 9 -and $cols[9]) { $cols[9] } else { @($cols | Where-Object { $_ -match '^\d+(\.\d+)+' } | Select-Object -Last 1) -join '' }
            $components += [ordered]@{ Name = $name; Version = $ver }
        }
        $out.Components = $components

        $out.UpdaterDisabled = [bool](@($seg[7] | Where-Object { $_ -match 'package:' }).Count -gt 0)

        $otaLines = @($seg[8] | Where-Object { $_ })
        $out.OtaLog = @($otaLines | ForEach-Object { if ($_.Length -gt 200) { $_.Substring(0, 200) } else { $_ } })
        foreach ($l in $otaLines) {
            if ($l -match '(\d{1,3}(?:\.\d+)?)\s*%') { $out.OtaProgress = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }
            elseif ($l -match '(?i)progress[^\d]*(0?\.\d+|1\.0)\b') { $out.OtaProgress = [Math]::Round(100 * [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture), 1) }
        }

        $out.PrivateDnsMode = Get-DiagSegmentText $seg[9]
        $out.PrivateDnsHost = Get-DiagSegmentText $seg[10]
        if ($out.PrivateDnsHost -eq 'null') { $out.PrivateDnsHost = '' }
    }

    try {
        $out.History = @(Invoke-DbQuery -Name 'firmware.history' -Parameters @{ headset_id = [int]$Headset.ID } |
            ForEach-Object { [ordered]@{ ts = [string]$_.ts; version = [string]$_.firmware_version; environment = [string]$_.environment } })
    } catch { $out.History = @() }

    return [PSCustomObject]$out
}


function Compare-DiagVersion {
    # -1 / 0 / 1 on dotted numeric versions ("76.0.0.522" vs "77.1"); non-numeric parts compare as 0.
    param([string]$A, [string]$B)
    $pa = @($A -split '[^\d]+' | Where-Object { $_ -ne '' })
    $pb = @($B -split '[^\d]+' | Where-Object { $_ -ne '' })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { [int64]$pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { [int64]$pb[$i] } else { 0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}


function Get-FleetFirmwareComparison {
    <#
    .SYNOPSIS
    Newest firmware per model across known headsets, from firmware_history only
    (no internet lookup), with Behind / Mismatch flags.
    .DESCRIPTION
    Behind   = this headset runs an older version than the newest one seen on the
               same model in the fleet.
    Mismatch = the model has more than one version in the fleet.
    Headsets never sampled yet (the monitor writes the first row ~30 s after it
    reaches a headset) are listed with an empty version.
    .EXAMPLE
    Get-FleetFirmwareComparison | Format-Table
    #>
    param([int]$HighlightId = 0)

    $rows = @()
    try { $rows = @(Invoke-DbQuery -Name 'firmware.latest') } catch { $rows = @() }
    $byId = @{}
    foreach ($r in $rows) { $byId[[string]$r.ID] = $r }

    $headsets = @(Get-KnownHeadsets)
    $newest = @{}
    $versionsPerModel = @{}
    foreach ($r in $rows) {
        $model = if ($r.Model) { [string]$r.Model } else { '?' }
        $v = [string]$r.firmware_version
        if (-not $versionsPerModel.ContainsKey($model)) { $versionsPerModel[$model] = @() }
        if ($versionsPerModel[$model] -notcontains $v) { $versionsPerModel[$model] += $v }
        if (-not $newest.ContainsKey($model) -or (Compare-DiagVersion $v $newest[$model]) -gt 0) { $newest[$model] = $v }
    }

    $items = @()
    foreach ($h in $headsets) {
        $model = if ($h.Model) { [string]$h.Model } else { '?' }
        $r = $byId[[string]$h.ID]
        $v = if ($r) { [string]$r.firmware_version } else { '' }
        $items += [ordered]@{
            id          = [int]$h.ID
            name        = [string]$h.Name
            model       = $model
            version     = $v
            environment = $(if ($r) { [string]$r.environment } else { '' })
            seenAt      = $(if ($r) { [string]$r.ts } else { '' })
            newest      = $(if ($newest.ContainsKey($model)) { $newest[$model] } else { '' })
            behind      = [bool]($v -and $newest.ContainsKey($model) -and (Compare-DiagVersion $v $newest[$model]) -lt 0)
            mismatch    = [bool]($versionsPerModel.ContainsKey($model) -and @($versionsPerModel[$model]).Count -gt 1)
            current     = ([int]$h.ID -eq $HighlightId)
        }
    }
    return $items
}


function Get-HeadsetDiagHealth {
    <#
    .SYNOPSIS
    Thermals, fan, CPU/GPU level, battery health, controllers, processes, memory,
    boot stage, clock and camera errors (one adb spawn).
    .EXAMPLE
    Get-HeadsetDiagHealth -Headset $h -Device $d
    #>
    param(
        [Parameter(Mandatory=$true)]$Headset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath
    )

    $cmds = @(
        'dumpsys thermalservice',                                         # 0
        'dumpsys hardware_properties | head -30',                         # 1
        'dumpsys FanMonitorService | head -40',                           # 2
        'getprop debug.oculus.cpuLevel',                                  # 3
        'getprop debug.oculus.gpuLevel',                                  # 4
        "dumpsys batterystats --charged | grep -i -m6 'capacity'",        # 5
        'dumpsys battery',                                                # 6
        "dumpsys OVRRemoteService | grep -i -A14 'Paired device'",       # 7
        'top -m 10 -n 1 -b',                                              # 8
        'head -5 /proc/meminfo',                                          # 9
        'getprop sys.boot_completed',                                     # 10
        'getprop init.svc.bootanim',                                      # 11
        'date +%s',                                                       # 12
        'getprop persist.sys.timezone',                                   # 13
        'settings get global auto_time',                                  # 14
        "logcat -d -t 5000 -s CAM_ERR | grep -c 'Timedout waiting for frame ctx'"  # 15
    )
    $sent = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $r = Invoke-HeadsetDiagShell -Device $Device -Commands $cmds -TimeoutSeconds 30 -adb $adb
    $back = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not $r.Ok) { throw $r.Error }
    $seg = $r.Segments

    $thermal = ConvertFrom-ThermalService -Lines @($seg[0])
    $temps = [ordered]@{
        Cpu        = $thermal.Cpu
        Gpu        = $thermal.Gpu
        Battery    = $thermal.Battery
        Skin       = $thermal.Skin
        Usb        = $thermal.Usb
        Status     = $thermal.ThermalStatus
        Throttling = $thermal.Throttling
        Sensors    = @($thermal.Sensors | Select-Object -First 40 | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.Type; value = $_.Value; status = $_.Status } })
    }

    # Fan: no stable format across firmwares, so pick the obvious numbers and keep
    # a few raw lines for the operator.
    $fanLines = @($seg[2] | Where-Object { $_ -and $_.Trim() })
    $fan = [ordered]@{ Rpm = $null; Pwm = $null; Status = ''; Raw = @($fanLines | Select-Object -First 12) }
    foreach ($l in $fanLines) {
        if ($null -eq $fan.Rpm -and $l -match '(?i)(rpm|speed)\D{0,12}(\d{2,5})') { $fan.Rpm = [int]$Matches[2] }
        if ($null -eq $fan.Pwm -and $l -match '(?i)pwm\D{0,12}(\d{1,5})')         { $fan.Pwm = [int]$Matches[1] }
        if (-not $fan.Status  -and $l -match '(?i)\bstatus\s*[:=]\s*(\w+)')        { $fan.Status = $Matches[1] }
    }

    # Battery health = learned capacity / design ("Estimated") capacity.
    $design = $null; $learnedMax = $null; $learnedMin = $null
    foreach ($l in @($seg[5])) {
        if ($l -match '(?i)Estimated battery capacity:\s*([\d\.]+)')   { $design     = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($l -match '(?i)Max learned battery capacity:\s*([\d\.]+)') { $learnedMax = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($l -match '(?i)Min learned battery capacity:\s*([\d\.]+)') { $learnedMin = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    $learned = if ($null -ne $learnedMax) { $learnedMax } else { $learnedMin }
    $battery = [ordered]@{
        Level          = $null
        TempC          = $null
        VoltageMv      = $null
        Health         = ''
        Status         = ''
        DesignMah      = $design
        LearnedMah     = $learned
        HealthPercent  = $(if ($design -and $learned) { [Math]::Round(100 * $learned / $design, 1) } else { $null })
    }
    $healthNames = @{ '1' = 'unknown'; '2' = 'good'; '3' = 'overheat'; '4' = 'dead'; '5' = 'over voltage'; '6' = 'failure'; '7' = 'cold' }
    $statusNames = @{ '1' = 'unknown'; '2' = 'charging'; '3' = 'discharging'; '4' = 'not charging'; '5' = 'full' }
    foreach ($l in @($seg[6])) {
        if ($l -match '^\s*level:\s*(\d+)')       { $battery.Level = [int]$Matches[1] }
        if ($l -match '^\s*temperature:\s*(\d+)') { $battery.TempC = [Math]::Round([int]$Matches[1] / 10.0, 1) }
        if ($l -match '^\s*voltage:\s*(\d+)')     { $battery.VoltageMv = [int]$Matches[1] }
        if ($l -match '^\s*health:\s*(\d+)')      { $battery.Health = $(if ($healthNames.ContainsKey($Matches[1])) { $healthNames[$Matches[1]] } else { $Matches[1] }) }
        if ($l -match '^\s*status:\s*(\d+)')      { $battery.Status = $(if ($statusNames.ContainsKey($Matches[1])) { $statusNames[$Matches[1]] } else { $Matches[1] }) }
    }

    # Controllers: one block per "Paired device". Field names follow
    # OVRRemoteService's dump; anything absent stays empty.
    $controllers = @()
    $cur = $null
    foreach ($l in @($seg[7])) {
        if ($l -match '(?i)Paired device') {
            if ($cur) { $controllers += $cur }
            $cur = [ordered]@{ Type = ''; Model = ''; HardwareRev = ''; Firmware = ''; Battery = ''; IsAttached = ''; Status = '' }
            if ($l -match '(?i)Paired device[^:]*:\s*(.+)$') { $cur.Model = $Matches[1].Trim() }
            continue
        }
        if (-not $cur) { continue }
        foreach ($pair in @(
            @('Type', '(?i)\btype\s*[:=]\s*([^,]+)'),
            @('Model', '(?i)\bmodel\s*[:=]\s*([^,]+)'),
            @('HardwareRev', '(?i)hardware\s*rev\w*\s*[:=]\s*([^,]+)'),
            @('Firmware', '(?i)firmware\w*\s*[:=]\s*([^,]+)'),
            @('Battery', '(?i)battery\w*\s*[:=]\s*([^,]+)'),
            @('IsAttached', '(?i)isAttached\s*[:=]\s*([^,]+)'),
            @('Status', '(?i)\bstatus\s*[:=]\s*([^,]+)'))) {
            if (-not $cur[$pair[0]] -and $l -match $pair[1]) { $cur[$pair[0]] = $Matches[1].Trim() }
        }
    }
    if ($cur) { $controllers += $cur }

    # top: keep the process table rows only.
    $procs = @()
    $inTable = $false
    foreach ($l in @($seg[8])) {
        if ($l -match '^\s*PID\s+USER') { $inTable = $true; continue }
        if (-not $inTable -or -not $l.Trim()) { continue }
        $cols = @($l.Trim() -split '\s+')
        if ($cols.Count -ge 12) {
            $procs += [ordered]@{ Pid = $cols[0]; User = $cols[1]; Cpu = $cols[8]; Mem = $cols[9]; Name = ($cols[11..($cols.Count - 1)] -join ' ') }
        }
    }

    $mem = [ordered]@{ TotalMb = $null; AvailableMb = $null; FreeMb = $null }
    foreach ($l in @($seg[9])) {
        if ($l -match '^MemTotal:\s*(\d+)')     { $mem.TotalMb     = [int]([int64]$Matches[1] / 1024) }
        if ($l -match '^MemAvailable:\s*(\d+)') { $mem.AvailableMb = [int]([int64]$Matches[1] / 1024) }
        if ($l -match '^MemFree:\s*(\d+)')      { $mem.FreeMb      = [int]([int64]$Matches[1] / 1024) }
    }

    $bootCompleted = (Get-DiagSegmentText $seg[10]) -eq '1'
    $bootAnim      = Get-DiagSegmentText $seg[11]
    $bootStage = if ($bootCompleted -and $bootAnim -ne 'running') { 'ready' } elseif ($bootAnim -eq 'running') { 'boot animation' } else { 'booting' }

    # Clock drift against the PC, compensating half the round trip.
    $devEpoch = 0L
    $drift = $null
    if ([int64]::TryParse((Get-DiagSegmentText $seg[12]), [ref]$devEpoch)) {
        $pcMid = ($sent + $back) / 2.0 / 1000.0
        $drift = [Math]::Round($devEpoch - $pcMid, 1)
    }

    $camErrors = 0
    [void][int]::TryParse((Get-DiagSegmentText $seg[15]), [ref]$camErrors)

    return [PSCustomObject][ordered]@{
        Transport      = $r.Transport
        Temperatures   = $temps
        HardwareProps  = @($seg[1] | Where-Object { $_ -and $_.Trim() } | Select-Object -First 20)
        Fan            = $fan
        CpuLevel       = Get-DiagSegmentText $seg[3]
        GpuLevel       = Get-DiagSegmentText $seg[4]
        Battery        = $battery
        Controllers    = $controllers
        TopProcesses   = $procs
        Memory         = $mem
        BootStage      = $bootStage
        ClockDriftSec  = $drift
        Timezone       = Get-DiagSegmentText $seg[13]
        AutoTime       = ((Get-DiagSegmentText $seg[14]) -eq '1')
        CameraErrors   = $camErrors
    }
}


function Get-HeadsetDiagWireless {
    <#
    .SYNOPSIS
    WiFi link, saved networks, Meta reachability and Bluetooth state (one adb spawn).
    .EXAMPLE
    Get-HeadsetDiagWireless -Headset $h -Device $d
    #>
    param(
        [Parameter(Mandatory=$true)]$Headset,
        [Parameter(Mandatory=$true)]$Device,
        [string]$adb = $global:adbPath
    )

    $cmds = @(
        "dumpsys wifi | grep -E 'mWifiInfo|Wifi is' | head -4",   # 0
        'cmd wifi list-networks',                                  # 1
        'ip -4 addr show wlan0',                                   # 2
        'ping -c 2 -W 2 graph.oculus.com',                         # 3
        'dumpsys bluetooth_manager | head -150',                   # 4
        'cmd wifi status'                                          # 5
    )
    $r = Invoke-HeadsetDiagShell -Device $Device -Commands $cmds -TimeoutSeconds 25 -adb $adb
    if (-not $r.Ok) { throw $r.Error }
    $seg = $r.Segments

    $wifi = [ordered]@{
        Enabled = $null; Ssid = ''; Bssid = ''; Rssi = $null; TxMbps = $null; RxMbps = $null
        LinkMbps = $null; FrequencyMhz = $null; Band = ''; Standard = ''; Ip = ''
    }
    $info = (@($seg[0]) -join ' ')
    if ($info -match 'Wifi is (\w+)')                        { $wifi.Enabled = ($Matches[1] -eq 'enabled') }
    if ($info -match 'SSID:\s*"?([^",]+)"?,')                { $wifi.Ssid = $Matches[1].Trim() }
    if ($info -match 'BSSID:\s*([0-9a-fA-F:]{17})')          { $wifi.Bssid = $Matches[1] }
    if ($info -match 'RSSI:\s*(-?\d+)')                      { $wifi.Rssi = [int]$Matches[1] }
    if ($info -match '(?<!(?:Tx|Rx) )Link speed:\s*(?<v>\d+)') { $wifi.LinkMbps = [int]$Matches['v'] }
    if ($info -match '(?<!Max Supported )Tx Link speed:\s*(\d+)') { $wifi.TxMbps = [int]$Matches[1] }
    if ($info -match '(?<!Max Supported )Rx Link speed:\s*(\d+)') { $wifi.RxMbps = [int]$Matches[1] }
    if ($info -match 'Frequency:\s*(\d+)')                   { $wifi.FrequencyMhz = [int]$Matches[1] }
    if ($info -match 'Wi-Fi standard:\s*(\w+)') {
        $std = $Matches[1]
        $names = @{ '4' = 'Wi-Fi 4 (802.11n)'; '5' = 'Wi-Fi 5 (802.11ac)'; '6' = 'Wi-Fi 6 (802.11ax)'; '7' = 'Wi-Fi 6E'; '8' = 'Wi-Fi 7 (802.11be)' }
        $wifi.Standard = $(if ($names.ContainsKey($std)) { $names[$std] } else { $std })
    }
    if (-not $wifi.Ssid) {
        foreach ($l in @($seg[5])) { if ($l -match '\bssid="([^"]+)"' -or $l -match 'SSID:\s+"?([^",]+)') { $wifi.Ssid = $Matches[1].Trim(); break } }
    }
    if ($wifi.FrequencyMhz) {
        $wifi.Band = if ($wifi.FrequencyMhz -lt 3000) { '2.4 GHz' } elseif ($wifi.FrequencyMhz -lt 5925) { '5 GHz' } else { '6 GHz' }
    }
    foreach ($l in @($seg[2])) { if ($l -match 'inet\s+(\d{1,3}(?:\.\d{1,3}){3})/') { $wifi.Ip = $Matches[1]; break } }

    $saved = @()
    foreach ($l in @($seg[1])) {
        if ($l -match '^\s*(\d+)\s+(.+?)\s{2,}(\S+)\s*$') { $saved += [ordered]@{ Id = [int]$Matches[1]; Ssid = $Matches[2].Trim(); Security = $Matches[3] } }
    }

    $pingText = (@($seg[3]) -join ' ')
    $meta = [ordered]@{ Reachable = $false; LossPercent = $null; AvgMs = $null }
    if ($pingText -match '(\d+)% packet loss') { $meta.LossPercent = [int]$Matches[1]; $meta.Reachable = ([int]$Matches[1] -lt 100) }
    if ($pingText -match '=\s*[\d\.]+/([\d\.]+)/') { $meta.AvgMs = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }

    $bt = [ordered]@{ Enabled = $null; State = ''; Name = ''; Bonded = @() }
    $inBonded = $false
    foreach ($l in @($seg[4])) {
        if ($null -eq $bt.Enabled -and $l -match '^\s*enabled:\s*(\w+)') { $bt.Enabled = ($Matches[1] -eq 'true') }
        if (-not $bt.State -and $l -match '^\s*state:\s*(\w+)')          { $bt.State = $Matches[1] }
        if (-not $bt.Name  -and $l -match '^\s*name:\s*(.+)$')           { $bt.Name = $Matches[1].Trim() }
        if ($l -match '^\s*Bonded devices:') { $inBonded = $true; continue }
        if ($inBonded) {
            if ($l -match '^\s*([0-9A-Fa-f:]{17}|XX:XX:XX:XX:[0-9A-Fa-f:]{5})\s*(?:\[\s*\w+\s*\])?\s*(.*)$') {
                $bt.Bonded += [ordered]@{ Address = $Matches[1]; Name = $Matches[2].Trim() }
            } elseif ($l.Trim()) {
                $inBonded = $false
            }
        }
    }

    return [PSCustomObject][ordered]@{
        Transport     = $r.Transport
        Wifi          = $wifi
        SavedNetworks = $saved
        MetaServers   = $meta
        Bluetooth     = $bt
    }
}


function Get-HeadsetDiagUsb {
    <#
    .SYNOPSIS
    PC-side USB diagnostics for a cabled headset: link speed and recent Windows
    connect/disconnect events and problem devices for Meta (VID 2833) and PICO
    (VID 2D40). Runs NO adb command.
    .DESCRIPTION
    Returns @{ OnUsb = $false } when the headset is not in VRMonitor's published
    USB set - nothing on the PC side says anything about a headset on WiFi.
    .EXAMPLE
    Get-HeadsetDiagUsb -Headset $h
    #>
    param([Parameter(Mandatory=$true)]$Headset)

    $serial = ([string]$Headset.SerialNumber).Trim()
    $entry  = $null
    if ($serial) { $entry = @(Get-PublishedUsbDevices -NoCache) | Where-Object { $_.Serial -eq $serial } | Select-Object -First 1 }
    if (-not $entry) { return [PSCustomObject]@{ OnUsb = $false; Serial = $serial } }

    $speed = $null
    try { $speed = Get-UsbDeviceSpeed -Serial $serial } catch { $speed = $null }

    $events = @()
    if (Get-Command Get-WinEvent -ErrorAction SilentlyContinue) {
        $since = (Get-Date).AddHours(-24)
        foreach ($log in @('Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-DriverFrameworks-UserMode/Operational')) {
            try {
                $raw = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -MaxEvents 300 -ErrorAction Stop)
                foreach ($e in $raw) {
                    $text = [string]$e.Message
                    if ($text -notmatch '(?i)VID_(2833|2D40)') { continue }
                    $first = ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    $events += [ordered]@{
                        Time    = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                        Id      = $e.Id
                        Log     = ($log -replace '^Microsoft-Windows-', '')
                        Summary = $(if ($first.Length -gt 160) { $first.Substring(0, 160) } else { $first })
                    }
                }
            } catch { }
        }
        $events = @($events | Sort-Object { $_.Time } -Descending | Select-Object -First 25)
    }

    $problems = @()
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        foreach ($vid in @('2833', '2D40')) {
            try {
                foreach ($d in @(Get-PnpDevice -InstanceId ("USB\VID_" + $vid + "*") -ErrorAction SilentlyContinue)) {
                    if ($d.Status -and $d.Status -ne 'OK' -and $d.Status -ne 'Unknown') {
                        $problems += [ordered]@{ Name = [string]$d.FriendlyName; Status = [string]$d.Status; InstanceId = [string]$d.InstanceId }
                    }
                }
            } catch { }
        }
    }

    return [PSCustomObject][ordered]@{
        OnUsb        = $true
        Serial       = $serial
        Since        = [string]$entry.Since
        UsbSpeed     = $speed
        Events       = $events
        ProblemDevices = $problems
        UsbBusy      = $(if (Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) { [bool](Test-UsbBusy) } else { $false })
    }
}


function Test-HeadsetUsbCable {
    <#
    .SYNOPSIS
    Measures the cable: pushes and pulls a 32 MB random file N times over USB only.
    .DESCRIPTION
    Random bytes, not zeros: recent adb compresses transfers, and a compressible
    file would report a speed the cable never delivered. Refused when the headset
    is not on USB or while an operator action holds USB. The remote and local
    temp files are always removed.
    Returns @{ Ok; Passes = @(@{ Pass; PushMBps; PullMBps; Error }); AvgPushMBps; AvgPullMBps; Error }.
    .EXAMPLE
    Test-HeadsetUsbCable -Headset $h -Passes 3
    #>
    param(
        [Parameter(Mandatory=$true)]$Headset,
        [int]$Passes = 0,
        [int]$SizeMB = 32,
        [string]$adb = $global:adbPath
    )
    if ($Passes -le 0) { $Passes = $(if ($global:Diag_CableTestPasses) { [int]$global:Diag_CableTestPasses } else { 3 }) }
    $Passes = [Math]::Min(10, [Math]::Max(1, $Passes))

    $serial = ([string]$Headset.SerialNumber).Trim()
    if (Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) {
        if (Test-UsbBusy) { return [PSCustomObject]@{ Ok = $false; Error = 'USB is busy with another operator action. Try again in a minute.'; Passes = @() } }
    }
    if (-not $serial -or -not (Test-HeadsetOnUsb -SerialNumber $serial)) {
        return [PSCustomObject]@{ Ok = $false; Error = 'This headset is not connected by USB. The cable test only runs over USB.'; Passes = @() }
    }

    $tmpDir  = [System.IO.Path]::GetTempPath()
    $src     = Join-Path -Path $tmpDir -ChildPath ("vrhm_cable_" + [guid]::NewGuid().ToString('N') + ".bin")
    $dst     = $src + ".back"
    $remote  = '/data/local/tmp/vrhm_cable_test.bin'
    $bytes   = [int64]$SizeMB * 1MB
    $results = @()
    try {
        $buf = New-Object byte[] ($SizeMB * 1MB)
        (New-Object System.Random).NextBytes($buf)
        [System.IO.File]::WriteAllBytes($src, $buf)
        $buf = $null

        for ($i = 1; $i -le $Passes; $i++) {
            $res = [ordered]@{ Pass = $i; PushMBps = $null; PullMBps = $null; Error = '' }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $push = Invoke-Adb -Arguments @('-s', $serial, 'push', $src, $remote) -TimeoutSeconds 120 -Adb $adb
            $sw.Stop()
            if (-not $push.Ok) { $res.Error = ('push failed: ' + ((@($push.StdErr) + @($push.StdOut)) -join ' ')); $results += $res; continue }
            $res.PushMBps = [Math]::Round(($bytes / 1MB) / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds), 1)

            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $pull = Invoke-Adb -Arguments @('-s', $serial, 'pull', $remote, $dst) -TimeoutSeconds 120 -Adb $adb
            $sw.Stop()
            if (-not $pull.Ok) { $res.Error = ('pull failed: ' + ((@($pull.StdErr) + @($pull.StdOut)) -join ' ')); $results += $res; continue }
            $res.PullMBps = [Math]::Round(($bytes / 1MB) / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds), 1)
            $len = if (Test-Path -LiteralPath $dst) { (Get-Item -LiteralPath $dst).Length } else { 0 }
            if ($len -ne $bytes) { $res.Error = ("size mismatch after pull: {0} of {1} bytes" -f $len, $bytes) }
            $results += $res
        }
    } catch {
        $results += [ordered]@{ Pass = 0; PushMBps = $null; PullMBps = $null; Error = $_.Exception.Message }
    } finally {
        Invoke-Adb -Arguments @('-s', $serial, 'shell', ('rm -f ' + $remote)) -TimeoutSeconds 10 -Adb $adb | Out-Null
        foreach ($f in @($src, $dst)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    }

    $push = @($results | Where-Object { $null -ne $_.PushMBps } | ForEach-Object { $_.PushMBps })
    $pull = @($results | Where-Object { $null -ne $_.PullMBps } | ForEach-Object { $_.PullMBps })
    $errs = @($results | Where-Object { $_.Error })
    Write-Log ((Get-MessageString -Key 'Diag.CableTestDone' -Fallback 'USB cable test on {0}: push {1} MB/s, pull {2} MB/s, {3} error(s)') -f $Headset.Name,
        $(if ($push.Count) { [Math]::Round(($push | Measure-Object -Average).Average, 1) } else { '-' }),
        $(if ($pull.Count) { [Math]::Round(($pull | Measure-Object -Average).Average, 1) } else { '-' }),
        $errs.Count) -Level INFO

    return [PSCustomObject][ordered]@{
        Ok          = ($errs.Count -eq 0)
        SizeMB      = $SizeMB
        UsbSpeed    = $(try { Get-UsbDeviceSpeed -Serial $serial } catch { $null })
        Passes      = $results
        AvgPushMBps = $(if ($push.Count) { [Math]::Round(($push | Measure-Object -Average).Average, 1) } else { $null })
        AvgPullMBps = $(if ($pull.Count) { [Math]::Round(($pull | Measure-Object -Average).Average, 1) } else { $null })
        Error       = $(if ($errs.Count) { [string]$errs[0].Error } else { '' })
    }
}


# ---------------------------------------------------------------------------
# Operator actions (each is one adb spawn)
# ---------------------------------------------------------------------------

function Invoke-HeadsetDiagActionShell {
    # Runs one action's shell string and shapes the common result.
    param($Device, [string]$Script, [string]$Action, [int]$TimeoutSeconds = 15)
    $r = Invoke-HeadsetDiagRaw -Device $Device -Arguments @('shell', $Script) -TimeoutSeconds $TimeoutSeconds
    $text = ((@($r.StdOut) + @($r.StdErr)) | Where-Object { $_ }) -join "`n"
    return [PSCustomObject][ordered]@{
        Ok        = [bool]$r.Ok
        Action    = $Action
        Output    = $(if ($text.Length -gt 4000) { $text.Substring(0, 4000) } else { $text })
        Transport = $r.Transport
    }
}

function Set-HeadsetBluetooth {
    <# .SYNOPSIS Turns Bluetooth on or off. .EXAMPLE Set-HeadsetBluetooth -Device $d -Enable $true #>
    param([Parameter(Mandatory=$true)]$Device, [bool]$Enable = $true)
    $verb = if ($Enable) { 'enable' } else { 'disable' }
    return Invoke-HeadsetDiagActionShell -Device $Device -Action ("bluetooth_" + $verb) `
        -Script ("cmd bluetooth_manager $verb || svc bluetooth $verb")
}

function Open-HeadsetBluetoothSettings {
    <# .SYNOPSIS Opens the Bluetooth settings screen inside the headset (pair bHaptics, ProTube...). #>
    param([Parameter(Mandatory=$true)]$Device)
    return Invoke-HeadsetDiagActionShell -Device $Device -Action 'bluetooth_settings' `
        -Script 'am start -a android.settings.BLUETOOTH_SETTINGS'
}

function Sync-HeadsetClock {
    <#
    .SYNOPSIS
    Turns network time on and forces a refresh; optionally sets the time zone.
    .DESCRIPTION
    -TimeZone is an IANA name (the DIAG page sends the browser's own). Windows
    PowerShell 5.1 cannot convert a Windows zone id to IANA, which is why the
    page supplies it. Setting the zone is best effort: "service call alarm 3"
    is the shell-level setter and some firmwares refuse it.
    .EXAMPLE
    Sync-HeadsetClock -Device $d -TimeZone 'Europe/Paris'
    #>
    param([Parameter(Mandatory=$true)]$Device, [string]$TimeZone = '')
    $parts = @('settings put global auto_time 1', 'cmd network_time_update_service force_refresh')
    if ($TimeZone) {
        if ($TimeZone -notmatch '^[A-Za-z]+(/[A-Za-z0-9_+\-]+){0,2}$') { throw "Invalid time zone name" }
        $parts += ('service call alarm 3 s16 ' + $TimeZone)
    }
    return Invoke-HeadsetDiagActionShell -Device $Device -Action 'clock_sync' -Script ($parts -join '; ')
}

function Reset-HeadsetPrivateDns {
    <# .SYNOPSIS Turns Private DNS off (a wrong DNS-over-TLS host blocks Meta servers silently). #>
    param([Parameter(Mandatory=$true)]$Device)
    return Invoke-HeadsetDiagActionShell -Device $Device -Action 'private_dns_reset' `
        -Script 'settings put global private_dns_mode off; settings get global private_dns_mode'
}

function Set-HeadsetUpdaterDisabled {
    <#
    .SYNOPSIS
    Disables (pm disable-user) or re-enables the system updater packages.
    .DESCRIPTION
    An extra layer on top of the existing appops block (Set-HeadsetUpdateBlocked),
    which it does not replace. Re-enabling is always possible over ADB.
    #>
    param([Parameter(Mandatory=$true)]$Device, [bool]$Disable = $true, [string]$Brand = '')
    $pkgs  = Get-UpdaterPackages -Brand $Brand
    $parts = foreach ($p in $pkgs) { if ($Disable) { "pm disable-user --user 0 $p" } else { "pm enable $p" } }
    return Invoke-HeadsetDiagActionShell -Device $Device -Action $(if ($Disable) { 'updater_disable' } else { 'updater_enable' }) -Script ($parts -join '; ')
}

function Get-HeadsetDisabledPackages {
    <# .SYNOPSIS Packages currently disabled on the headset. #>
    param([Parameter(Mandatory=$true)]$Device)
    $r = Invoke-HeadsetDiagRaw -Device $Device -Arguments @('shell', 'pm list packages -d')
    return @($r.StdOut | Where-Object { $_ -match '^package:(.+)$' } | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Sort-Object)
}

function Set-HeadsetAppEnabled {
    <# .SYNOPSIS Disables (pm disable-user) or enables one package. .EXAMPLE Set-HeadsetAppEnabled -Device $d -Package com.oculus.explore -Enable $false #>
    param([Parameter(Mandatory=$true)]$Device, [Parameter(Mandatory=$true)][string]$Package, [bool]$Enable = $true)
    if ($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') { throw "Invalid package name" }
    $script = if ($Enable) { "pm enable $Package" } else { "pm disable-user --user 0 $Package" }
    return Invoke-HeadsetDiagActionShell -Device $Device -Action $(if ($Enable) { 'app_enable' } else { 'app_disable' }) -Script $script
}

function Send-HeadsetPlayerMessage {
    <#
    .SYNOPSIS
    Posts a notification to the player (EXPERIMENTAL).
    .DESCRIPTION
    "cmd notification post" over ADB, no companion APK. Whether it is visible
    while an immersive app runs depends on the firmware: the non-regression test
    asks the operator to confirm. Printable ASCII only.
    .EXAMPLE
    Send-HeadsetPlayerMessage -Device $d -Title 'VRHM' -Text 'Session ends in 5 minutes'
    #>
    param([Parameter(Mandatory=$true)]$Device, [string]$Title = 'VRHM', [Parameter(Mandatory=$true)][string]$Text)
    $t = ConvertTo-DiagShellQuoted -Text $Title -MaxLength 60
    $b = ConvertTo-DiagShellQuoted -Text $Text  -MaxLength 300
    if ($b -eq "''") { throw "Message text is empty" }
    $r = Invoke-HeadsetDiagActionShell -Device $Device -Action 'player_message' -Script ("cmd notification post -S bigtext -t $t vrhm_msg $b")
    $r | Add-Member -NotePropertyName Experimental -NotePropertyValue $true -Force
    return $r
}

function Send-HeadsetText {
    <#
    .SYNOPSIS
    Types text into the focused field on the headset (input text).
    .DESCRIPTION
    Spaces become %s (what "input text" expects), the rest is single-quoted.
    Printable ASCII only; double quotes and backslashes are dropped.
    #>
    param([Parameter(Mandatory=$true)]$Device, [Parameter(Mandatory=$true)][string]$Text)
    $q = ConvertTo-DiagShellQuoted -Text ($Text -replace ' ', '%s') -MaxLength 500
    if ($q -eq "''") { throw "Text is empty" }
    return Invoke-HeadsetDiagActionShell -Device $Device -Action 'input_text' -Script ("input text $q")
}

function Invoke-HeadsetRecovery {
    <#
    .SYNOPSIS
    Soft recovery: wake the display, go Home, restart the VR shell or SystemUX.
    .EXAMPLE
    Invoke-HeadsetRecovery -Device $d -Action RestartShell
    #>
    param(
        [Parameter(Mandatory=$true)]$Device,
        [ValidateSet('Wake','Home','RestartShell','RestartSystemUX')][string]$Action
    )
    $script = switch ($Action) {
        'Wake'            { 'input keyevent 224' }
        'Home'            { 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' }
        'RestartShell'    { 'am force-stop com.oculus.vrshell; am start -n com.oculus.vrshell/.HomeActivity' }
        'RestartSystemUX' { 'am force-stop com.oculus.systemux' }
    }
    return Invoke-HeadsetDiagActionShell -Device $Device -Action ('recovery_' + $Action) -Script $script
}

function Test-HeadsetCustomCommandAllowed {
    <# .SYNOPSIS Returns '' when the command may run, else the reason it is refused. #>
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return 'The command is empty.' }
    if ($Command.Length -gt 1000) { return 'The command is too long (1000 characters max).' }
    if ($Command -match '"') { return 'Double quotes are not supported: use single quotes.' }
    if ($Command -match '[\x00-\x08\x0A-\x1F\x7F]') { return 'Control characters are not allowed.' }
    foreach ($p in $script:DiagBlockedPatterns) {
        if ($Command -match ('(?i)' + $p)) { return 'This command is blocked on the DIAG page (bootloader, recovery, wipe, fastboot and rm -rf / are never run from here).' }
    }
    return ''
}

function Invoke-HeadsetCustomCommand {
    <#
    .SYNOPSIS
    Runs one operator-supplied SHELL command (never a host-side adb verb).
    .DESCRIPTION
    20 s timeout, output truncated to 64 KB, every run logged at INFO with the
    headset and the command, refused patterns logged at WARNING.
    .EXAMPLE
    Invoke-HeadsetCustomCommand -Headset $h -Device $d -Command 'getprop ro.product.model'
    #>
    param(
        [Parameter(Mandatory=$true)]$Headset,
        [Parameter(Mandatory=$true)]$Device,
        [Parameter(Mandatory=$true)][string]$Command
    )
    $Command = $Command.Trim()
    if ($Command -match '^adb\s+shell\s+') { $Command = $Command -replace '^adb\s+shell\s+', '' }
    elseif ($Command -match '^shell\s+')   { $Command = $Command -replace '^shell\s+', '' }

    $why = Test-HeadsetCustomCommandAllowed -Command $Command
    if ($why) {
        Write-Log ((Get-MessageString -Key 'Diag.CommandBlocked' -Fallback 'DIAG: command refused on {0}: {1}') -f $Headset.Name, $Command) -Level WARNING
        return [PSCustomObject][ordered]@{ Ok = $false; Blocked = $true; Error = $why; Output = ''; ExitCode = $null; Truncated = $false; Transport = [string]$Device.ConnectionType }
    }

    Write-Log ((Get-MessageString -Key 'Diag.CommandRun' -Fallback 'DIAG: shell command on {0} ({1}): {2}') -f $Headset.Name, $Device.DeviceId, $Command) -Level INFO
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-HeadsetDiagRaw -Device $Device -Arguments @('shell', $Command) -TimeoutSeconds 20
    $sw.Stop()
    $text = ((@($r.StdOut) + @($r.StdErr)) -join "`n")
    $max = 65536
    $truncated = $text.Length -gt $max
    if ($truncated) { $text = $text.Substring(0, $max) }
    return [PSCustomObject][ordered]@{
        Ok         = [bool]$r.Ok
        Blocked    = $false
        ExitCode   = $r.ExitCode
        Output     = $text
        Truncated  = $truncated
        DurationMs = [int]$sw.Elapsed.TotalMilliseconds
        Transport  = $r.Transport
        Error      = $(if ($r.ExitCode -eq -2) { 'Timed out after 20 s' } else { '' })
    }
}

function Get-HeadsetDiagPresets {
    <# .SYNOPSIS The ADB panel presets from config (Diag.command_presets), sanitised. #>
    $list = @()
    foreach ($p in @($global:Diag_CommandPresets)) {
        if (-not $p -or -not $p.command) { continue }
        $cmd = [string]$p.command
        if (Test-HeadsetCustomCommandAllowed -Command $cmd) { continue }
        $list += [ordered]@{ name = $(if ($p.name) { [string]$p.name } else { $cmd }); command = $cmd }
    }
    return $list
}


# ---------------------------------------------------------------------------
# EXPERIMENTAL - ADB over TLS (Android 11+ wireless debugging)
#
# Investigation only: can the mDNS-advertised TLS transport replace re-running
# "adb tcpip 5555" after every reboot? NOTHING in the existing WiFi ADB enabling
# flow calls these; only the DIAG page does, on an explicit click.
# ---------------------------------------------------------------------------

function Get-HeadsetAdbTlsStatus {
    <#
    .SYNOPSIS
    adb_wifi_enabled on the headset plus the _adb-tls-connect._tcp port seen over mDNS.
    #>
    param([Parameter(Mandatory=$true)]$Headset, [Parameter(Mandatory=$true)]$Device, [int]$MdnsTimeoutMs = 2500)
    $r = Invoke-HeadsetDiagShell -Device $Device -Commands @('settings get global adb_wifi_enabled', 'getprop service.adb.tls.port') -TimeoutSeconds 10
    $enabled = (Get-DiagSegmentText $r.Segments[0]) -eq '1'
    $propPort = Get-DiagSegmentText $r.Segments[1]

    $mdnsPort = $null
    if (Get-Command Find-QuestHeadsetsMdns -ErrorAction SilentlyContinue) {
        try {
            $hits = @(Find-QuestHeadsetsMdns -TimeoutMs $MdnsTimeoutMs -ServiceTypes @('_adb-tls-connect._tcp'))
            $hit  = $hits | Where-Object { $_.IPAddress -eq $Headset.IPAddress } | Select-Object -First 1
            if ($hit) { $mdnsPort = [int]$hit.Port }
        } catch { }
    }
    return [PSCustomObject][ordered]@{
        Experimental   = $true
        AdbWifiEnabled = $enabled
        TlsPortProp    = $propPort
        MdnsPort       = $mdnsPort
        HeadsetIP      = [string]$Headset.IPAddress
    }
}

function Enable-HeadsetAdbTls {
    <# .SYNOPSIS Turns on Android wireless debugging (adb_wifi_enabled = 1). EXPERIMENTAL. #>
    param([Parameter(Mandatory=$true)]$Device)
    $r = Invoke-HeadsetDiagActionShell -Device $Device -Action 'tls_enable' -Script 'settings put global adb_wifi_enabled 1; settings get global adb_wifi_enabled'
    $r | Add-Member -NotePropertyName Experimental -NotePropertyValue $true -Force
    return $r
}

function Connect-HeadsetAdbTls {
    <#
    .SYNOPSIS
    "adb connect ip:<mdns port>" against the TLS transport. EXPERIMENTAL.
    .DESCRIPTION
    Succeeds only on a PC the headset already paired with (Android pairing code);
    the result is reported as evidence, never acted on.
    #>
    param([Parameter(Mandatory=$true)]$Headset, [int]$Port, [string]$adb = $global:adbPath)
    if ($Port -le 0 -or $Port -gt 65535) { throw "Invalid TLS port" }
    $target = ("{0}:{1}" -f $Headset.IPAddress, $Port)
    $r = Invoke-Adb -Arguments @('connect', $target) -TimeoutSeconds 10 -Adb $adb
    $text = ((@($r.StdOut) + @($r.StdErr)) -join ' ').Trim()
    Write-Log ((Get-MessageString -Key 'Diag.TlsConnect' -Fallback 'DIAG (experimental): adb connect {0} -> {1}') -f $target, $text) -Level INFO
    return [PSCustomObject][ordered]@{
        Experimental = $true
        Target       = $target
        Connected    = [bool]($text -match 'connected to')
        Output       = $text
    }
}


# ---------------------------------------------------------------------------
# Dispatchers used by the web server
# ---------------------------------------------------------------------------

function Get-HeadsetDiagSection {
    <#
    .SYNOPSIS
    One DIAG section for one headset id: firmware | health | wireless | usb | fleet | tls.
    .EXAMPLE
    Get-HeadsetDiagSection -Id 3 -Section health
    #>
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][ValidateSet('firmware','health','wireless','usb','fleet','tls','summary')][string]$Section
    )
    switch ($Section) {
        'fleet' { return @{ items = @(Get-FleetFirmwareComparison -HighlightId $Id) } }
        'usb'   {
            $ctx = Resolve-DiagHeadset -Id $Id -NoDevice
            return (Get-HeadsetDiagUsb -Headset $ctx.Headset)
        }
        'summary' {
            # No adb at all: what the page header needs (name, model, transport badge).
            $ctx = Resolve-DiagHeadset -Id $Id -NoDevice
            $h = $ctx.Headset
            $onUsb = [bool]((Get-AdbPreferUsb) -and (Test-HeadsetOnUsb -SerialNumber ([string]$h.SerialNumber)))
            return [ordered]@{
                id = [int]$h.ID; name = [string]$h.Name; ip = [string]$h.IPAddress; model = [string]$h.Model
                brand = (Get-DiagBrand $h); serial = [string]$h.SerialNumber
                transport = $(if ($onUsb) { 'USB' } else { 'WiFi' })
                autoRefreshSec = $(if ($global:Diag_AutoRefreshSec) { [int]$global:Diag_AutoRefreshSec } else { 30 })
                cableTestPasses = $(if ($global:Diag_CableTestPasses) { [int]$global:Diag_CableTestPasses } else { 3 })
            }
        }
    }
    $ctx = Resolve-DiagHeadset -Id $Id
    switch ($Section) {
        'firmware' { return (Get-HeadsetDiagFirmware -Headset $ctx.Headset -Device $ctx.Device) }
        'health'   { return (Get-HeadsetDiagHealth   -Headset $ctx.Headset -Device $ctx.Device) }
        'wireless' { return (Get-HeadsetDiagWireless -Headset $ctx.Headset -Device $ctx.Device) }
        'tls'      { return (Get-HeadsetAdbTlsStatus -Headset $ctx.Headset -Device $ctx.Device) }
    }
}

function Invoke-HeadsetDiagAction {
    <#
    .SYNOPSIS
    Allow-listed DIAG action dispatcher. Anything not listed here is refused.
    .EXAMPLE
    Invoke-HeadsetDiagAction -Id 3 -Action bluetooth -Arguments @{ enable = $false }
    #>
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][string]$Action,
        $Arguments = $null
    )
    $a = $Arguments
    function Get-Arg([string]$Name, $Default = $null) {
        if ($null -eq $a) { return $Default }
        if ($a -is [hashtable]) { if ($a.ContainsKey($Name)) { return $a[$Name] } else { return $Default } }
        $p = $a.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $Default
    }

    if ($Action -eq 'cable_test') {
        $ctx = Resolve-DiagHeadset -Id $Id -NoDevice
        return (Test-HeadsetUsbCable -Headset $ctx.Headset -Passes ([int](Get-Arg 'passes' 0)))
    }
    if ($Action -eq 'tls_connect') {
        $ctx = Resolve-DiagHeadset -Id $Id -NoDevice
        return (Connect-HeadsetAdbTls -Headset $ctx.Headset -Port ([int](Get-Arg 'port' 0)))
    }

    $ctx = Resolve-DiagHeadset -Id $Id
    $d   = $ctx.Device
    $toBool = { param($v) if ($v -is [bool]) { $v } else { [string]$v -match '^(?i)(1|true|yes|on)$' } }
    Write-Log ((Get-MessageString -Key 'Diag.ActionRun' -Fallback 'DIAG: action {0} on {1}') -f $Action, $ctx.Headset.Name) -Level INFO
    switch ($Action) {
        'bluetooth'          { return (Set-HeadsetBluetooth -Device $d -Enable (& $toBool (Get-Arg 'enable' $true))) }
        'bluetooth_settings' { return (Open-HeadsetBluetoothSettings -Device $d) }
        'clock_sync'         { return (Sync-HeadsetClock -Device $d -TimeZone ([string](Get-Arg 'timezone' ''))) }
        'private_dns_reset'  { return (Reset-HeadsetPrivateDns -Device $d) }
        'updater_disabled'   { return (Set-HeadsetUpdaterDisabled -Device $d -Disable (& $toBool (Get-Arg 'disable' $true)) -Brand (Get-DiagBrand $ctx.Headset)) }
        'list_disabled'      { return [PSCustomObject]@{ Ok = $true; Action = $Action; Packages = @(Get-HeadsetDisabledPackages -Device $d) } }
        'app_enabled'        { return (Set-HeadsetAppEnabled -Device $d -Package ([string](Get-Arg 'package' '')) -Enable (& $toBool (Get-Arg 'enable' $true))) }
        'player_message'     { return (Send-HeadsetPlayerMessage -Device $d -Title ([string](Get-Arg 'title' 'VRHM')) -Text ([string](Get-Arg 'text' ''))) }
        'input_text'         { return (Send-HeadsetText -Device $d -Text ([string](Get-Arg 'text' ''))) }
        'recovery'           {
            $what = [string](Get-Arg 'what' '')
            if (@('Wake','Home','RestartShell','RestartSystemUX') -notcontains $what) { throw "Unknown recovery action" }
            return (Invoke-HeadsetRecovery -Device $d -Action $what)
        }
        'tls_enable'         { return (Enable-HeadsetAdbTls -Device $d) }
        default              { throw ("Unknown DIAG action: " + $Action) }
    }
}
