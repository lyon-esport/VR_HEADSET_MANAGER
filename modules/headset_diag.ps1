###############################################################################
# headset_diag.ps1 - backend of the headset DIAG page (website\headset_diag.html).
#
# WHY THIS IS A MODULE AND NOT CODE IN THE WEB SERVER
# ---------------------------------------------------
# Every function here takes an already-resolved ADB device (Resolve-HeadsetAdbDevice,
# so USB when the headset is cabled, WiFi otherwise), runs ONE combined "adb shell"
# call per section, parses it and returns a PSCustomObject. The web server only maps
# a request onto one of these functions; the logic stays callable from anywhere.
# (ADR-0023 records that the DIAG page is web-only: no console menu counterpart.)
#
# WHY ONE SHELL CALL PER SECTION
# ------------------------------
# The web server is a single-threaded HttpListener. A section that spawned a dozen
# adb.exe processes would freeze every other page while it ran, so each section
# chains its commands inside one "adb shell" with an echoed marker between them
# (Invoke-HeadsetDiagShell) and is parsed positionally by marker, never by guessing.
# An absent command simply yields an empty segment - it cannot shift the others.
#
# Several parsers read dumps whose exact layout varies between firmware versions.
# They are deliberately tolerant: every field is optional and a missing one is $null,
# never an exception - a DIAG page that shows what it could read beats one that fails.
#
# ASCII only in string literals (the file is saved without a BOM).
###############################################################################

$script:DiagMarker = '===VRHM==='


function Invoke-HeadsetDiagShell {
    <#
    .SYNOPSIS
    Runs several shell commands in ONE "adb shell" call and returns their outputs as
    separate segments, in the order given.

    .DESCRIPTION
    The commands are joined with an echoed marker, sent as a single script argument
    (Invoke-AdbCmd -ShellScript, so pipes, semicolons and single quotes reach the device
    shell untouched) and split back on the marker. The script always ends with an echo so
    its exit status is 0 - without that, a trailing "grep" that finds nothing would make
    Invoke-AdbCmd report the whole call as failed and discard every other segment.

    Returns an array with exactly one entry per command; each entry is a string[] of that
    command's output lines (possibly empty). Returns $null when the call itself failed
    (transport gone, timeout) so the caller can tell "nothing to report" from "no answer".

    .EXAMPLE
    $seg = Invoke-HeadsetDiagShell -Device $d -Commands @('getprop ro.product.model','settings get global auto_time')
    $seg[0][0]
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string[]]$Commands,
        [int]$TimeoutSeconds = 20
    )

    $marker = $script:DiagMarker
    $shellScript = (($Commands -join ("; echo " + $marker + "; ")) + "; echo " + $marker)
    $lines  = Invoke-AdbCmd -Device $Device -Command $shellScript -ShellScript -TimeoutSeconds $TimeoutSeconds -SilentOnFail
    if ($lines -is [bool] -or $null -eq $lines) { return $null }

    $segments = @()
    $current  = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($lines)) {
        if (([string]$line).Trim() -eq $marker) {
            $segments += ,($current.ToArray())
            $current = New-Object System.Collections.Generic.List[string]
        } else {
            $current.Add([string]$line)
        }
    }
    # Pad so the caller can always index every command it asked for.
    while ($segments.Count -lt $Commands.Count) { $segments += ,@() }
    return ,$segments
}


function Get-DiagFirstLine {
    # First non-blank line of a segment, trimmed - or '' (getprop prints an empty line for
    # a property the device lacks, which is an answer, not an error).
    param($Segment)
    foreach ($l in @($Segment)) { $t = ([string]$l).Trim(); if ($t) { return $t } }
    return ''
}

function ConvertTo-DiagNumber {
    # Culture-proof number parse: "4,880" and "4.880" and "4880" all work for the
    # integers dumpsys prints, and a failed parse is $null rather than 0.
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = ($Text -replace '[,\s]', '')
    $v = 0.0
    if ([double]::TryParse($clean, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    return $null
}

function ConvertTo-DiagVersionKey {
    # Dotted version -> comparable [int[]]; non-numeric octets become 0.
    param([string]$Version)
    if (-not $Version) { return @() }
    return @($Version.Split('.') | ForEach-Object { $n = 0; if ([int]::TryParse(($_ -replace '\D', ''), [ref]$n)) { $n } else { 0 } })
}

function Compare-DiagVersion {
    # -1 / 0 / 1, comparing dotted versions octet by octet (a shorter one is padded with 0).
    param([string]$A, [string]$B)
    $ka = ConvertTo-DiagVersionKey $A
    $kb = ConvertTo-DiagVersionKey $B
    $n  = [Math]::Max($ka.Count, $kb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $ka.Count) { $ka[$i] } else { 0 }
        $y = if ($i -lt $kb.Count) { $kb[$i] } else { 0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Format-DiagBuild {
    # The Meta incremental is 17 digits, AAAAAAA00BBBB0CCC; the readable form is
    # AAAAAAA.BBBB.CCC (same rule as Get-HeadsetFirmwareInfo). Anything else is returned as is.
    param([string]$Incremental)
    if ($Incremental -match '^(\d{7})00(\d{4})0(\d{3})$') { return ("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3]) }
    return $Incremental
}


function Get-HeadsetDiagFirmware {
    <#
    .SYNOPSIS
    Firmware section of the DIAG page for one headset: OS version, system component
    versions, a pending OTA and its progress, and whether the updater is blocked.

    .DESCRIPTION
    One combined shell call (see Invoke-HeadsetDiagShell). The firmware version is the
    first four octets of the SystemUX versionName; on the panther / xse_panther products
    (Quest 3S family) that package is com.oculus.systemutilities instead, so both are read
    and the right one chosen in PowerShell rather than branching on the device.

    The component table comes from the OculusUpdater service dump, which lists one row per
    component with the version in the tenth pipe-separated column. That layout is the least
    stable thing read here, so the parse is best-effort: a row it cannot read is simply
    omitted.

    PICO headsets reuse Get-HeadsetFirmwareInfo and return $null for the Meta-only fields.

    Returns [PSCustomObject]@{ Ok; Brand; OsDisplay; FirmwareVersion; Environment; Build;
    Components; PendingOtaUri; OtaProgressPct; UpdaterDisabled; PrivateDns;
    PrivateDnsHost; OldFirmwareWarning; Error }.

    .EXAMPLE
    $dev = Resolve-HeadsetAdbDevice -Headset $headset
    Get-HeadsetDiagFirmware -Device $dev -Brand 'Meta'
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$Brand = '',
        [string]$adb = $global:adbPath
    )

    $r = [PSCustomObject]@{
        Ok = $false; Brand = $Brand; OsDisplay = $null; FirmwareVersion = $null
        Environment = $null; Build = $null; Components = @(); PendingOtaUri = $null
        OtaProgressPct = $null; UpdaterDisabled = $null; PrivateDns = $null
        PrivateDnsHost = $null; OldFirmwareWarning = $false; Error = $null
    }

    try {
        if ($Brand -eq 'Pico') {
            $info = Get-HeadsetFirmwareInfo -Device $Device -adb $adb -Brand 'Pico'
            if ($info) {
                $r.OsDisplay       = $info.Version
                $r.FirmwareVersion = $(if ($info.UpdateVersion) { $info.UpdateVersion } else { $info.Version })
                $r.Environment     = $info.Build
                $r.Build           = $info.Build
                $r.Ok              = $true
            } else { $r.Error = 'No answer from the headset.' }
            return $r
        }

        $seg = Invoke-HeadsetDiagShell -Device $Device -TimeoutSeconds 25 -Commands @(
            'getprop ro.hzos.build.display_name',
            'getprop ro.vros.build.version',
            'getprop ro.build.version.incremental',
            'getprop ro.product.name',
            'dumpsys package com.oculus.systemux 2>/dev/null | grep versionName',
            'dumpsys package com.oculus.systemutilities 2>/dev/null | grep versionName',
            'dumpsys DumpsysProxy OculusUpdater 2>/dev/null | head -400',
            'pm list packages -d 2>/dev/null | grep -i updater',
            "logcat -d -t 3000 2>/dev/null | grep -E 'Current progress|OTA applying update|OTA progress updated'",
            'settings get global private_dns_mode',
            'settings get global private_dns_specifier'
        )
        if (-not $seg) { $r.Error = 'No answer from the headset.'; return $r }

        $display  = Get-DiagFirstLine $seg[0]
        $vros     = Get-DiagFirstLine $seg[1]
        $incr     = Get-DiagFirstLine $seg[2]
        $product  = Get-DiagFirstLine $seg[3]
        $r.OsDisplay   = $(if ($display) { $display } else { $vros })
        $r.Environment = $incr
        $r.Build       = Format-DiagBuild $incr

        $vnLines = if ($product -match '^(xse_)?panther$') { $seg[5] } else { $seg[4] }
        $vn = ($vnLines | Select-String 'versionName=(\S+)' | Select-Object -First 1)
        if ($vn) {
            $full = $vn.Matches[0].Groups[1].Value
            $r.FirmwareVersion = $(if ($full -match '^(\d+(?:\.\d+){0,3})') { $Matches[1] } else { $full })
        }
        if ($r.FirmwareVersion -match '^(\d+)\.') { $r.OldFirmwareWarning = ([int]$Matches[1] -lt 71) }

        # Pending OTA: the download URI the updater is holding.
        $uri = (@($seg[6]) | Select-String 'download_uri\W+(\S+)' | Select-Object -First 1)
        if ($uri) { $r.PendingOtaUri = $uri.Matches[0].Groups[1].Value.Trim(',;"''') }

        # Components: rows with a known component name and a tenth pipe-separated column.
        $names = 'Integrity', 'Core Mobile Services', 'Library Quest', 'Device Settings', 'Assistant', 'Quest platform apex', 'Presence Service'
        $components = @()
        foreach ($line in @($seg[6])) {
            if ($line -notmatch '\|') { continue }
            $cells = @($line.Split('|') | ForEach-Object { $_.Trim() })
            foreach ($n in $names) {
                $idx = -1
                for ($i = 0; $i -lt $cells.Count; $i++) { if ($cells[$i] -match ('^' + [regex]::Escape($n) + '$')) { $idx = $i; break } }
                if ($idx -ge 0 -and $cells.Count -gt 9 -and $cells[9]) {
                    $components += [PSCustomObject]@{ Name = $n; Version = $cells[9] }
                    break
                }
            }
        }
        $r.Components = $components

        # OTA progress: the last logcat line that carries a percentage.
        $prog = @($seg[8]) | Where-Object { $_ -match '(\d{1,3})\s*%|progress\D{0,12}(\d{1,3})' } | Select-Object -Last 1
        if ($prog -and ($prog -match '(\d{1,3})\s*%' -or $prog -match 'progress\D{0,12}(\d{1,3})')) { $r.OtaProgressPct = [int]$Matches[1] }

        $r.UpdaterDisabled = [bool](@($seg[7] | Where-Object { $_ -match 'updater' }).Count)
        $r.PrivateDns      = Get-DiagFirstLine $seg[9]
        $r.PrivateDnsHost  = Get-DiagFirstLine $seg[10]
        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}


function Get-HeadsetFirmwareQuick {
    <#
    .SYNOPSIS
    Just the firmware version and environment of one Meta headset, in one adb call.
    Used by the monitor's slow cadence; the DIAG page uses Get-HeadsetDiagFirmware.

    .DESCRIPTION
    Returns @{ Version; Environment } or $null when the version cannot be read. The
    version is the first four octets of the SystemUX versionName (SystemUtilities on the
    panther products).
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$adb = $global:adbPath
    )
    $seg = Invoke-HeadsetDiagShell -Device $Device -TimeoutSeconds 12 -Commands @(
        'getprop ro.product.name',
        'getprop ro.build.version.incremental',
        'dumpsys package com.oculus.systemux 2>/dev/null | grep versionName',
        'dumpsys package com.oculus.systemutilities 2>/dev/null | grep versionName'
    )
    if (-not $seg) { return $null }
    $product = Get-DiagFirstLine $seg[0]
    $lines   = if ($product -match '^(xse_)?panther$') { $seg[3] } else { $seg[2] }
    $vn = ($lines | Select-String 'versionName=(\d+(?:\.\d+){0,3})' | Select-Object -First 1)
    if (-not $vn) { return $null }
    return @{ Version = $vn.Matches[0].Groups[1].Value; Environment = (Get-DiagFirstLine $seg[1]) }
}


function Update-HeadsetFirmwareHistory {
    <#
    .SYNOPSIS
    Records the headset firmware version in firmware_history when it CHANGED since the
    last recorded one. Returns $true when a row was written.

    .DESCRIPTION
    Called from the monitor poll runspace on a slow cadence (every 10 minutes), so the
    table holds changes rather than samples. Meta only: the version comes from the
    SystemUX package, and PICO has no equivalent source, so it is skipped.
    Never throws.

    .EXAMPLE
    Update-HeadsetFirmwareHistory -Device $device -HeadsetId 3 -Brand 'Meta'
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][int]$HeadsetId,
        [string]$Brand = '',
        [string]$adb = $global:adbPath
    )
    try {
        if ($HeadsetId -le 0 -or $Brand -eq 'Pico') { return $false }
        $fw = Get-HeadsetFirmwareQuick -Device $Device -adb $adb
        if (-not $fw -or -not $fw.Version) { return $false }

        $last = @(Invoke-DbQuery -Name 'firmware.latest' -Parameters @{ headset_id = $HeadsetId }) | Select-Object -First 1
        if ($last -and [string]$last.firmware_version -eq [string]$fw.Version -and [string]$last.environment -eq [string]$fw.Environment) { return $false }

        Invoke-DbNonQuery -Name 'firmware.insert' -Parameters @{
            headset_id       = $HeadsetId
            firmware_version = [string]$fw.Version
            environment      = [string]$fw.Environment
        } | Out-Null
        Write-Log ("Firmware change recorded for headset {0}: {1}" -f $HeadsetId, $fw.Version) -Level INFO
        return $true
    } catch {
        Write-Log ("Update-HeadsetFirmwareHistory failed for headset {0}: {1}" -f $HeadsetId, $_.Exception.Message) -Level DEBUG
        return $false
    }
}


function Get-HeadsetFirmwareHistory {
    <#
    .SYNOPSIS
    The recorded firmware changes of one headset, newest first, as @{ts; firmware_version;
    environment}. @() when none, never throws.

    .EXAMPLE
    Get-HeadsetFirmwareHistory -HeadsetId 3 -Limit 10
    #>
    param(
        [Parameter(Mandatory=$true)][int]$HeadsetId,
        [int]$Limit = 20
    )
    try {
        if ($Limit -lt 1) { $Limit = 1 }
        if ($Limit -gt 200) { $Limit = 200 }
        return @(Invoke-DbQuery -Name 'firmware.history' -Parameters @{ headset_id = $HeadsetId; limit = $Limit })
    } catch { return @() }
}


function Get-FleetFirmwareComparison {
    <#
    .SYNOPSIS
    Compares the firmware of every known headset with the newest one seen for the SAME
    model. DB only - no internet lookup, no ADB.

    .DESCRIPTION
    Newest means the highest version among the headsets of that model that this server
    knows about, so it answers "is this headset behind the rest of my fleet", not "is it
    behind what Meta published". Returns one row per headset that ever reported a version:
    @{ ID; Name; Model; FirmwareVersion; NewestForModel; Behind; Mismatch }.
    Behind: this headset is older than the newest of its model. Mismatch: the model has
    more than one distinct version across the fleet.

    .EXAMPLE
    Get-FleetFirmwareComparison | Where-Object Behind
    #>
    try {
        $rows = @(Invoke-DbQuery -Name 'firmware.fleet')
    } catch { return @() }
    if ($rows.Count -eq 0) { return @() }

    $newest = @{}
    $distinct = @{}
    foreach ($row in $rows) {
        $model = [string]$row.Model
        if (-not $newest.ContainsKey($model) -or (Compare-DiagVersion $row.FirmwareVersion $newest[$model]) -gt 0) { $newest[$model] = [string]$row.FirmwareVersion }
        if (-not $distinct.ContainsKey($model)) { $distinct[$model] = @{} }
        $distinct[$model][[string]$row.FirmwareVersion] = $true
    }

    return @($rows | ForEach-Object {
        $model = [string]$_.Model
        [PSCustomObject]@{
            ID              = $_.ID
            Name            = $_.Name
            Model           = $model
            FirmwareVersion = $_.FirmwareVersion
            NewestForModel  = $newest[$model]
            Behind          = [bool]((Compare-DiagVersion $_.FirmwareVersion $newest[$model]) -lt 0)
            Mismatch        = [bool]($distinct[$model].Count -gt 1)
        }
    })
}


function ConvertFrom-DiagKeyValueLine {
    # "Type=Touch, Model=Rift S, isAttached: true" -> @{ type=...; model=...; isattached=... }
    # Keys are lower-cased so a firmware that changes the capitalisation does not matter.
    param([string]$Line)
    $h = @{}
    foreach ($m in [regex]::Matches($Line, '(\w+)\s*[=:]\s*([^,;\]\)\}]+)')) {
        $k = $m.Groups[1].Value.ToLowerInvariant()
        if (-not $h.ContainsKey($k)) { $h[$k] = $m.Groups[2].Value.Trim() }
    }
    return $h
}

function Get-DiagKeyValue {
    # First value in a ConvertFrom-DiagKeyValueLine table whose key matches the pattern.
    param([hashtable]$Table, [string]$KeyPattern)
    foreach ($k in $Table.Keys) { if ($k -match $KeyPattern) { return $Table[$k] } }
    return $null
}


function Get-HeadsetDiagHealth {
    <#
    .SYNOPSIS
    Health section of the DIAG page: temperatures and throttling, fan, CPU/GPU levels,
    battery health, controllers, busiest processes, memory, boot stage, clock drift,
    time zone and camera errors.

    .DESCRIPTION
    One combined shell call. Temperatures go through ConvertFrom-ThermalService, the
    same parser the monitor uses for the metric history, so the DIAG tiles and the graphs
    can never disagree.

    Battery health is the last learned capacity over the estimated (design) capacity
    from batterystats, as a percentage; $null when either is missing.

    ClockDriftSec is the headset epoch minus the middle of the PC time bracketing the call,
    so the call latency does not count as drift. A wrong clock is worth surfacing: it breaks
    TLS and makes logs unreadable.

    CameraErrors counts "Timedout waiting for frame ctx" lines in the last 5000 log lines,
    a known sign of a failing tracking camera.

    The layouts of the fan, controller and top output differ between firmware versions, so
    those parses are tolerant: unreadable fields are $null and the raw line is kept.

    .EXAMPLE
    Get-HeadsetDiagHealth -Device (Resolve-HeadsetAdbDevice -Headset $h)
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$adb = $global:adbPath
    )

    $r = [PSCustomObject]@{
        Ok = $false; Temps = $null; Fan = $null; CpuLevel = $null; GpuLevel = $null
        Battery = $null; Controllers = @(); TopProcesses = @(); Memory = $null
        BootStage = $null; ClockDriftSec = $null; TimeZone = $null; AutoTime = $null
        CameraErrors = 0; HardwareRaw = @(); Error = $null
    }

    try {
        $pcBefore = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $seg = Invoke-HeadsetDiagShell -Device $Device -TimeoutSeconds 30 -Commands @(
            'dumpsys thermalservice 2>/dev/null | head -250',
            'dumpsys hardware_properties 2>/dev/null | head -40',
            'dumpsys FanMonitorService 2>/dev/null | head -40',
            'getprop debug.oculus.cpuLevel',
            'getprop debug.oculus.gpuLevel',
            "dumpsys batterystats --charged 2>/dev/null | grep -i 'battery capacity'",
            'dumpsys battery 2>/dev/null',
            "dumpsys OVRRemoteService 2>/dev/null | grep 'Paired device'",
            'top -m 10 -n 1 -b 2>/dev/null',
            'dumpsys meminfo 2>/dev/null | head -40',
            'getprop service.bootanim.exit',
            'getprop init.svc.bootanim',
            'date +%s',
            'getprop persist.sys.timezone',
            'settings get global auto_time',
            'logcat -d -t 5000 -s CAM_ERR 2>/dev/null'
        )
        $pcAfter = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (-not $seg) { $r.Error = 'No answer from the headset.'; return $r }

        # --- temperatures ---
        $t = ConvertFrom-ThermalService -Lines $seg[0]
        $labels = @('None', 'Light', 'Moderate', 'Severe', 'Critical', 'Emergency', 'Shutdown')
        $r.Temps = [PSCustomObject]@{
            Cpu = $t.Cpu; Gpu = $t.Gpu; Battery = $t.Battery; Skin = $t.Skin; UsbPort = $t.UsbPort
            ThrottlingStatus = $t.Status
            ThrottlingLabel  = $(if ($null -ne $t.Status -and $t.Status -ge 0 -and $t.Status -lt $labels.Count) { $labels[$t.Status] } else { $null })
            Sensors          = $t.Sensors
        }
        $r.HardwareRaw = @($seg[1] | Where-Object { $_.Trim() } | Select-Object -First 25)

        # --- fan: tolerant, the dump layout is not fixed ---
        $fanText = (@($seg[2]) -join "`n")
        if ($fanText.Trim()) {
            $speed = $null; $status = $null; $pwm = $null
            if ($fanText -match '(?i)speed\D{0,12}(\d+)')  { $speed  = [int]$Matches[1] }
            if ($fanText -match '(?i)status\W{1,4}(\w+)')  { $status = $Matches[1] }
            if ($fanText -match '(?i)pwm\D{0,12}(\d+)')    { $pwm    = [int]$Matches[1] }
            $r.Fan = [PSCustomObject]@{ Speed = $speed; Status = $status; Pwm = $pwm; Raw = @($seg[2] | Where-Object { $_.Trim() } | Select-Object -First 10) }
        }

        $cpuLevel = Get-DiagFirstLine $seg[3]; if ($cpuLevel) { $r.CpuLevel = $cpuLevel }
        $gpuLevel = Get-DiagFirstLine $seg[4]; if ($gpuLevel) { $r.GpuLevel = $gpuLevel }

        # --- battery: design vs learned capacity, plus the live dumpsys battery fields ---
        $cap = @{}
        foreach ($l in @($seg[5])) {
            if ($l -match '(?i)(estimated|last learned|min learned|max learned)\s+battery capacity:\s*([\d\.,]+)') {
                $cap[$Matches[1].ToLowerInvariant()] = ConvertTo-DiagNumber $Matches[2]
            }
        }
        $health = $null
        if ($cap['last learned'] -and $cap['estimated'] -and $cap['estimated'] -gt 0) {
            $health = [Math]::Min(100, [int][Math]::Round(100.0 * $cap['last learned'] / $cap['estimated']))
        }
        $bat = @{}
        foreach ($l in @($seg[6])) {
            if ($l -match '^\s*([A-Za-z][A-Za-z ]*?):\s*(\S.*)$') { $bat[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() }
        }
        $plugged = 'None'
        if ($bat['ac powered'] -eq 'true') { $plugged = 'AC' }
        elseif ($bat['usb powered'] -eq 'true') { $plugged = 'USB' }
        elseif ($bat['wireless powered'] -eq 'true') { $plugged = 'Wireless' }
        $tempTenths = ConvertTo-DiagNumber $bat['temperature']
        $r.Battery = [PSCustomObject]@{
            Level = ConvertTo-DiagNumber $bat['level']
            Plugged = $plugged
            TempC = $(if ($null -ne $tempTenths) { $tempTenths / 10.0 } else { $null })
            VoltageMv = ConvertTo-DiagNumber $bat['voltage']
            DesignMah = $cap['estimated']
            LearnedMah = $cap['last learned']
            HealthPct = $health
        }

        # --- controllers ---
        $controllers = @()
        foreach ($l in @($seg[7])) {
            $kv = ConvertFrom-DiagKeyValueLine $l
            if ($kv.Count -eq 0) { continue }
            $controllers += [PSCustomObject]@{
                Type        = Get-DiagKeyValue $kv '^type$'
                Model       = Get-DiagKeyValue $kv '^model$'
                HardwareRev = Get-DiagKeyValue $kv '^(hardware_?rev|hw_?rev)'
                Firmware    = Get-DiagKeyValue $kv '^(fw|firmware)'
                Battery     = Get-DiagKeyValue $kv '^batt'
                IsAttached  = Get-DiagKeyValue $kv '^is_?attached$'
                Status      = Get-DiagKeyValue $kv '^status$'
                Raw         = $l.Trim()
            }
        }
        $r.Controllers = $controllers

        # --- top: process rows follow the PID header ---
        $procs = @()
        $afterHeader = $false
        foreach ($l in @($seg[8])) {
            if (-not $afterHeader) { if ($l -match '^\s*PID\s+USER') { $afterHeader = $true }; continue }
            $f = @($l.Trim() -split '\s+')
            if ($f.Count -lt 12 -or $f[0] -notmatch '^\d+$') { continue }
            $procs += [PSCustomObject]@{ Pid = [int]$f[0]; User = $f[1]; CpuPct = (ConvertTo-DiagNumber $f[8]); MemPct = (ConvertTo-DiagNumber $f[9]); Name = ($f[11..($f.Count - 1)] -join ' ') }
        }
        $r.TopProcesses = $procs

        # --- memory (dumpsys meminfo prints kilobytes) ---
        $memText = (@($seg[9]) -join "`n")
        $kb = @{}
        foreach ($k in 'Total', 'Free', 'Used') {
            if ($memText -match ('(?i)' + $k + ' RAM:\s*([\d,\.]+)K')) { $kb[$k] = ConvertTo-DiagNumber $Matches[1] }
        }
        if ($kb.ContainsKey('Total')) {
            $r.Memory = [PSCustomObject]@{
                TotalMb = [Math]::Round($kb['Total'] / 1024.0)
                FreeMb  = $(if ($kb.ContainsKey('Free')) { [Math]::Round($kb['Free'] / 1024.0) } else { $null })
                UsedMb  = $(if ($kb.ContainsKey('Used')) { [Math]::Round($kb['Used'] / 1024.0) } else { $null })
            }
        }

        # --- boot stage, clock, time zone, camera errors ---
        $bootExit = Get-DiagFirstLine $seg[10]
        $bootSvc  = Get-DiagFirstLine $seg[11]
        $r.BootStage = $(if ($bootExit -eq '1' -and ($bootSvc -eq 'stopped' -or -not $bootSvc)) { 'Booted' } elseif ($bootExit -or $bootSvc) { 'Booting' } else { $null })
        $devEpoch = ConvertTo-DiagNumber (Get-DiagFirstLine $seg[12])
        if ($null -ne $devEpoch) { $r.ClockDriftSec = [int]([Math]::Round($devEpoch - (($pcBefore + $pcAfter) / 2.0))) }
        $tz = Get-DiagFirstLine $seg[13]; if ($tz) { $r.TimeZone = $tz }
        $at = Get-DiagFirstLine $seg[14]; if ($at) { $r.AutoTime = ($at -eq '1') }
        $r.CameraErrors = @($seg[15] | Where-Object { $_ -match 'Timedout waiting for frame ctx' }).Count

        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}


function Get-HeadsetDiagWireless {
    <#
    .SYNOPSIS
    Wireless section of the DIAG page: the current WiFi link, saved networks, whether
    Meta servers are reachable from the headset, and the Bluetooth state with bonded
    devices.

    .DESCRIPTION
    One combined shell call. The WiFi link comes from the mWifiInfo line of dumpsys wifi,
    parsed field by field rather than positionally because the set of fields grows with
    every Android release. Band is derived from the frequency (2.4, 5 or 6 GHz).

    MetaReachable is a 2-packet ping of graph.oculus.com run FROM the headset, so it tells
    an operator whether the headset can reach Meta at all (store, updates, accounts), which
    is a different question from whether the PC can reach the headset.

    Bluetooth bonded devices are read from lines that START with a MAC address in
    dumpsys bluetooth_manager; the dump is large, so it is filtered on the device side.

    Returns [PSCustomObject]@{ Ok; WifiEnabled; Ssid; Bssid; RssiDbm; LinkSpeedMbps;
    TxSpeedMbps; RxSpeedMbps; FrequencyMhz; Band; Standard; Ip; SavedNetworks;
    MetaReachable; MetaLatencyMs; BluetoothEnabled; BluetoothState; BondedDevices; AdbTlsEnabled; Error }.

    .EXAMPLE
    Get-HeadsetDiagWireless -Device (Resolve-HeadsetAdbDevice -Headset $h)
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$adb = $global:adbPath
    )

    $r = [PSCustomObject]@{
        Ok = $false; WifiEnabled = $null; Ssid = $null; Bssid = $null; RssiDbm = $null
        LinkSpeedMbps = $null; TxSpeedMbps = $null; RxSpeedMbps = $null; FrequencyMhz = $null
        Band = $null; Standard = $null; Ip = $null; SavedNetworks = @()
        MetaReachable = $null; MetaLatencyMs = $null
        BluetoothEnabled = $null; BluetoothState = $null; BondedDevices = @(); AdbTlsEnabled = $null; Error = $null
    }

    try {
        $seg = Invoke-HeadsetDiagShell -Device $Device -TimeoutSeconds 25 -Commands @(
            "dumpsys wifi 2>/dev/null | grep -E 'mWifiInfo|Wifi is'",
            'cmd wifi list-networks 2>/dev/null',
            'ip -4 addr show wlan0 2>/dev/null',
            'ping -c 2 -W 2 graph.oculus.com 2>&1',
            "dumpsys bluetooth_manager 2>/dev/null | grep -i -E 'enabled:|state:|^ *[0-9A-F]{2}(:[0-9A-F]{2}){5}'",
            'settings get global adb_wifi_enabled'
        )
        if (-not $seg) { $r.Error = 'No answer from the headset.'; return $r }

        # --- WiFi link ---
        $tlsRaw = Get-DiagFirstLine $seg[5]
        if ($tlsRaw -eq '1') { $r.AdbTlsEnabled = $true } elseif ($tlsRaw -eq '0' -or $tlsRaw -eq 'null') { $r.AdbTlsEnabled = $false }
        $wifiText = (@($seg[0]) -join "`n")
        if ($wifiText -match '(?i)Wifi is (\w+)') { $r.WifiEnabled = ($Matches[1] -eq 'enabled') }
        $info = @($seg[0] | Where-Object { $_ -match 'mWifiInfo' } | Select-Object -First 1)
        if ($info.Count -gt 0) {
            $i = [string]$info[0]
            if ($i -match 'SSID:\s*"?([^",]*)"?')                  { $r.Ssid = $Matches[1].Trim() }
            if ($i -match 'BSSID:\s*([0-9a-fA-F:]{17})')           { $r.Bssid = $Matches[1] }
            if ($i -match 'RSSI:\s*(-?\d+)')                       { $r.RssiDbm = [int]$Matches[1] }
            if ($i -match '(?<![A-Za-z] )Link speed:\s*(\d+)')     { $r.LinkSpeedMbps = [int]$Matches[1] }
            if ($i -match 'Tx Link speed:\s*(\d+)')                { $r.TxSpeedMbps = [int]$Matches[1] }
            if ($i -match 'Rx Link speed:\s*(\d+)')                { $r.RxSpeedMbps = [int]$Matches[1] }
            if ($i -match 'Frequency:\s*(\d+)')                    { $r.FrequencyMhz = [int]$Matches[1] }
            if ($i -match 'Wi-Fi standard:\s*(\w+)') {
                $std = $Matches[1]
                $r.Standard = $(if ($std -match '^\d+$') { switch ([int]$std) { 1 { 'Legacy' } 4 { 'Wi-Fi 4' } 5 { 'Wi-Fi 5' } 6 { 'Wi-Fi 6' } 7 { 'Wi-Fi 7' } default { $std } } } else { $std })
            }
        }
        if ($null -ne $r.FrequencyMhz) {
            $f = $r.FrequencyMhz
            $r.Band = $(if ($f -ge 2400 -and $f -lt 2500) { '2.4 GHz' } elseif ($f -ge 4900 -and $f -lt 5900) { '5 GHz' } elseif ($f -ge 5925 -and $f -le 7125) { '6 GHz' } else { $null })
        }

        # --- saved networks: rows of "id  ssid  security" after the header ---
        $saved = @()
        foreach ($l in @($seg[1])) {
            if ($l -match '^\s*(\d+)\s+(.+?)\s{2,}(\S.*?)\s*$') { $saved += [PSCustomObject]@{ Id = [int]$Matches[1]; Ssid = $Matches[2].Trim(); Security = $Matches[3].Trim() } }
        }
        $r.SavedNetworks = @(Merge-DiagSavedWifi -Rows $saved)

        # --- IP of wlan0 ---
        $ipLine = @($seg[2] | Where-Object { $_ -match 'inet\s+(\d+\.\d+\.\d+\.\d+)' } | Select-Object -First 1)
        if ($ipLine.Count -gt 0 -and $ipLine[0] -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { $r.Ip = $Matches[1] }

        # --- Meta reachability from the headset itself ---
        $pingText = (@($seg[3]) -join "`n")
        if ($pingText -match '(\d+)\s+packets transmitted,\s*(\d+)\s+(?:packets )?received') { $r.MetaReachable = ([int]$Matches[2] -gt 0) }
        elseif ($pingText -match '(?i)unknown host|bad address|network is unreachable') { $r.MetaReachable = $false }
        if ($pingText -match 'min/avg/max[^=]*=\s*[\d\.]+/([\d\.]+)/') { $r.MetaLatencyMs = [Math]::Round((ConvertTo-DiagNumber $Matches[1]), 1) }

        # --- Bluetooth ---
        $btText = (@($seg[4]) -join "`n")
        if ($btText -match '(?i)enabled:\s*(\w+)') { $r.BluetoothEnabled = ($Matches[1] -eq 'true') }
        if ($btText -match '(?i)\bstate:\s*(\w+)') { $r.BluetoothState = $Matches[1] }
        $bonded = @{}
        foreach ($l in @($seg[4])) {
            if ($l -match '^\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\s*(?:\[[^\]]*\])?\s*(.*)$') {
                $addr = $Matches[1].ToUpperInvariant()
                if (-not $bonded.ContainsKey($addr)) { $bonded[$addr] = $Matches[2].Trim() }
            }
        }
        $r.BondedDevices = @($bonded.Keys | ForEach-Object { [PSCustomObject]@{ Address = $_; Name = $bonded[$_] } })

        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}


function Get-HeadsetUsbEvents {
    <#
    .SYNOPSIS
    Recent Windows connect/disconnect events for Meta (VID 2833) and Pico (VID 2D40) USB
    devices, newest first. @() when the logs are unavailable. Never throws.

    .DESCRIPTION
    A cable that works but flaps shows up here as a burst of disconnect/connect events long
    before an operator notices a dropped stream. Two logs are read because which one is
    populated depends on the Windows build; a log that is missing or disabled is skipped.
    Only the first 200 characters of each message are kept.

    .EXAMPLE
    Get-HeadsetUsbEvents -Max 10
    #>
    param([int]$Max = 20)

    $found = @()
    foreach ($log in @('Microsoft-Windows-Kernel-PnP/Device Configuration', 'Microsoft-Windows-DriverFrameworks-UserMode/Operational')) {
        try { $raw = @(Get-WinEvent -LogName $log -MaxEvents 400 -ErrorAction Stop) } catch { continue }
        foreach ($e in $raw) {
            if ($e.Message -match 'VID_(2833|2D40)') {
                $text = ([string]$e.Message -replace '\s+', ' ')
                if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
                $found += [PSCustomObject]@{
                    Time    = $e.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    Id      = $e.Id
                    Log     = $log
                    Message = $text
                }
            }
        }
    }
    return @($found | Sort-Object Time -Descending | Select-Object -First $Max)
}


function Get-HeadsetDiagUsb {
    <#
    .SYNOPSIS
    USB / cable section of the DIAG page, computed entirely on the PC side: it never talks
    to the headset, so it costs no ADB call.

    .DESCRIPTION
    Uses the cabled set VRMonitor published (Get-PublishedUsbDevices) to decide whether the
    headset is on USB at all, then adds the negotiated link speed (Get-UsbDeviceSpeed, which
    is memoised), recent connect/disconnect events and any Meta/Pico USB device Windows
    flags with a problem code.

    When the headset is not on USB the result is just @{ OnUsb = $false }: every other field
    would be meaningless, and the page hides the section.

    Returns [PSCustomObject]@{ OnUsb; Serial; Since; Speed; Events; ProblemDevices }.

    .EXAMPLE
    Get-HeadsetDiagUsb -Headset $headset
    #>
    param([Parameter(Mandatory=$true)] $Headset)

    $serial = if ($Headset.SerialNumber) { ([string]$Headset.SerialNumber).Trim() } else { '' }
    $cabled = @()
    if ($serial -and $serial -ne '-') { $cabled = @(Get-PublishedUsbDevices -MaxAgeSec 0 | Where-Object { $_.Serial -eq $serial }) }
    if ($cabled.Count -eq 0) { return [PSCustomObject]@{ OnUsb = $false } }

    $speed = $null
    try { $speed = Get-UsbDeviceSpeed -Serial $serial } catch { }

    $problems = @()
    try {
        $filter = "PNPDeviceID LIKE '%VID_2833%' OR PNPDeviceID LIKE '%VID_2D40%'"
        $problems = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter $filter -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
            ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DeviceId = $_.PNPDeviceID; Status = $_.Status; ErrorCode = [int]$_.ConfigManagerErrorCode } })
    } catch { }

    return [PSCustomObject]@{
        OnUsb          = $true
        Serial         = $serial
        Since          = $cabled[0].Since
        Speed          = $speed
        Events         = @(Get-HeadsetUsbEvents -Max 15)
        ProblemDevices = $problems
    }
}


function Measure-HeadsetAdbThroughput {
    <#
    .SYNOPSIS
    The measuring core shared by the USB cable test and the WiFi throughput test: pushes then
    pulls a random temporary file over the given ADB device, -Passes times, and reports MB/s per
    pass. Returns @{ Ok; Passes; AvgPushMBps; AvgPullMBps; SizeMb; Error }.

    .DESCRIPTION
    Takes an already-resolved device and does NOT decide whether the transport is the right one -
    the callers do that, because a number measured on the wrong link would be reported as if it
    described the other. The remote and both local temp files are removed whatever happens.

    .EXAMPLE
    Measure-HeadsetAdbThroughput -Device $device -Passes 3 -SizeMb 32
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][int]$Passes,
        [int]$SizeMb = 32,
        [string]$adb = $global:adbPath
    )
    $r = [PSCustomObject]@{ Ok = $false; Passes = @(); AvgPushMBps = $null; AvgPullMBps = $null; SizeMb = $SizeMb; Error = $null }
    $tmp    = Join-Path -Path $env:TEMP -ChildPath ("vrhm_speed_{0}.bin" -f [guid]::NewGuid().ToString('N'))
    $pulled = $tmp + '.pull'
    $remote = '/sdcard/vrhm_speed_test.bin'
    try {
        $bytes = New-Object byte[] ($SizeMb * 1MB)
        (New-Object System.Random).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        $bytes = $null

        $rows = @()
        for ($p = 1; $p -le $Passes; $p++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $push = Invoke-Adb -Arguments @('-s', $Device.DeviceId, 'push', $tmp, $remote) -TimeoutSeconds 90 -Adb $adb
            $sw.Stop()
            if (-not $push.Ok) { $r.Error = 'Push failed: ' + (($push.StdErr + $push.StdOut) -join ' '); break }
            $pushMbps = [Math]::Round($SizeMb / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds), 1)

            $sw.Restart()
            $pull = Invoke-Adb -Arguments @('-s', $Device.DeviceId, 'pull', $remote, $pulled) -TimeoutSeconds 90 -Adb $adb
            $sw.Stop()
            if (-not $pull.Ok) { $r.Error = 'Pull failed: ' + (($pull.StdErr + $pull.StdOut) -join ' '); break }
            $pullMbps = [Math]::Round($SizeMb / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds), 1)

            $rows += [PSCustomObject]@{ Pass = $p; PushMBps = $pushMbps; PullMBps = $pullMbps }
        }
        $r.Passes = $rows
        if ($rows.Count -gt 0) {
            $r.AvgPushMBps = [Math]::Round((($rows | Measure-Object -Property PushMBps -Average).Average), 1)
            $r.AvgPullMBps = [Math]::Round((($rows | Measure-Object -Property PullMBps -Average).Average), 1)
            $r.Ok = ($rows.Count -eq $Passes)
        }
    } catch {
        $r.Error = $_.Exception.Message
    } finally {
        try { Invoke-AdbCmd -Device $Device -Command ("shell rm -f " + $remote) -SilentOnFail -adb $adb | Out-Null } catch { }
        foreach ($f in @($tmp, $pulled)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    }
    return $r
}


function Test-HeadsetUsbCable {
    <#
    .SYNOPSIS
    Measures the real throughput of the USB cable: pushes then pulls a random temporary file
    over USB, -Passes times, and reports MB/s per pass.

    .DESCRIPTION
    A USB 2 cable (or a damaged USB 3 one) negotiates fine and then crawls under load; the
    link speed shown by Windows cannot tell the difference, a transfer can. USB ONLY: when
    the headset is not on a USB transport the test is refused, because a WiFi number would
    be reported as if it described the cable.

    While it runs, USB is claimed with Set-UsbBusy so the VRMonitor watcher does not fire
    "adb tcpip" into the transfer, and released in the finally block. Refused outright when
    an operator action already holds USB. The measuring itself is Measure-HeadsetAdbThroughput.

    Returns [PSCustomObject]@{ Ok; Refused; Passes; AvgPushMBps; AvgPullMBps; SizeMb; Error }.

    .EXAMPLE
    Test-HeadsetUsbCable -Headset $headset -Passes 3
    #>
    param(
        [Parameter(Mandatory=$true)] $Headset,
        [int]$Passes = 0,
        [int]$SizeMb = 32,
        [string]$adb = $global:adbPath
    )

    $r = [PSCustomObject]@{ Ok = $false; Refused = $false; Passes = @(); AvgPushMBps = $null; AvgPullMBps = $null; SizeMb = $SizeMb; Error = $null }
    if ($Passes -le 0) { $Passes = if ($global:Diag_cable_test_passes) { [int]$global:Diag_cable_test_passes } else { 3 } }
    if ($Passes -gt 10) { $Passes = 10 }

    if (Test-UsbBusy) { $r.Refused = $true; $r.Error = 'USB is busy with another operation - try again in a minute.'; return $r }
    $device = Resolve-HeadsetAdbDevice -Headset $Headset -PreferTransport USB -adb $adb
    if (-not $device -or $device.ConnectionType -ne 'USB') { $r.Refused = $true; $r.Error = 'This headset is not connected over USB.'; return $r }

    Set-UsbBusy -Seconds ($Passes * 60 + 30)
    try {
        $m = Measure-HeadsetAdbThroughput -Device $device -Passes $Passes -SizeMb $SizeMb -adb $adb
        $r.Passes = $m.Passes; $r.AvgPushMBps = $m.AvgPushMBps; $r.AvgPullMBps = $m.AvgPullMBps; $r.Ok = $m.Ok; $r.Error = $m.Error
    } finally {
        Clear-UsbBusy
    }
    return $r
}


function Test-HeadsetWifiThroughput {
    <#
    .SYNOPSIS
    Measures the real WiFi throughput between this PC and the headset: pushes then pulls a random
    temporary file over the headset's WiFi ADB connection, -Passes times, and reports MB/s per pass.

    .DESCRIPTION
    The WiFi counterpart of Test-HeadsetUsbCable. A link can show a high negotiated speed and
    still crawl under load (a busy channel, a weak signal, a congested access point); a transfer
    shows what the video stream will actually get. WIFI ONLY: refused when the headset has no live
    WiFi ADB connection, because a USB number would be reported as if it described the WiFi.
    A cabled headset can be tested too, as long as its WiFi ADB is on - the transfer goes over
    WiFi regardless of the cable. Unlike the cable test it does not claim USB, since nothing here
    re-enumerates it. This measures PC to headset only (not internet speed).

    Returns [PSCustomObject]@{ Ok; Refused; Passes; AvgPushMBps; AvgPullMBps; SizeMb; Error }.

    .EXAMPLE
    Test-HeadsetWifiThroughput -Headset $headset -Passes 3
    #>
    param(
        [Parameter(Mandatory=$true)] $Headset,
        [int]$Passes = 0,
        [int]$SizeMb = 32,
        [string]$adb = $global:adbPath
    )

    $r = [PSCustomObject]@{ Ok = $false; Refused = $false; Passes = @(); AvgPushMBps = $null; AvgPullMBps = $null; SizeMb = $SizeMb; Error = $null }
    if ($Passes -le 0) { $Passes = if ($global:Diag_cable_test_passes) { [int]$global:Diag_cable_test_passes } else { 3 } }
    if ($Passes -gt 10) { $Passes = 10 }

    $device = Resolve-HeadsetAdbDevice -Headset $Headset -PreferTransport WiFi -adb $adb
    if (-not $device -or $device.ConnectionType -ne 'WiFi') { $r.Refused = $true; $r.Error = 'This headset has no WiFi ADB connection to test (is WiFi ADB enabled and the headset on the network?).'; return $r }

    $m = Measure-HeadsetAdbThroughput -Device $device -Passes $Passes -SizeMb $SizeMb -adb $adb
    $r.Passes = $m.Passes; $r.AvgPushMBps = $m.AvgPushMBps; $r.AvgPullMBps = $m.AvgPullMBps; $r.Ok = $m.Ok; $r.Error = $m.Error
    return $r
}


function Invoke-HeadsetDiagAction {
    <#
    .SYNOPSIS
    Runs ONE shell script on the headset for an operator action and returns
    @{ Ok; Output; Error }. Never throws.

    .DESCRIPTION
    Ok means the command ran and exited 0. Invoke-AdbCmd returns $false for a non-zero exit
    and throws for an unreachable device; both are turned into Ok = $false with a readable
    Error, so the web layer always has something to show the operator.

    .EXAMPLE
    Invoke-HeadsetDiagAction -Device $d -Script 'settings put global auto_time 1'
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string]$Script,
        [int]$TimeoutSeconds = 15
    )
    try {
        $out = Invoke-AdbCmd -Device $Device -Command $Script -ShellScript -TimeoutSeconds $TimeoutSeconds -SilentOnFail
        if ($out -is [bool] -or $null -eq $out) { return [PSCustomObject]@{ Ok = $false; Output = @(); Error = 'The command failed on the headset.' } }
        return [PSCustomObject]@{ Ok = $true; Output = @($out); Error = $null }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Output = @(); Error = $_.Exception.Message }
    }
}


function ConvertTo-DiagShellText {
    <#
    .SYNOPSIS
    Makes free text safe to embed inside a single-quoted shell string on the headset:
    printable ASCII only, capped in length, with every single quote closed-escaped-reopened.

    .DESCRIPTION
    Non-ASCII is dropped rather than transliterated: the headset shell and the input service
    both mangle it unpredictably, and an operator message does not need it. The result is
    meant to be wrapped in single quotes by the caller.

    .EXAMPLE
    "echo '" + (ConvertTo-DiagShellText -Text "it's ok") + "'"
    #>
    param([string]$Text, [int]$MaxLength = 300)
    if (-not $Text) { return '' }
    $ascii = (($Text.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -le 126 }) -join '')
    if ($ascii.Length -gt $MaxLength) { $ascii = $ascii.Substring(0, $MaxLength) }
    return $ascii.Replace("'", "'\''")
}


function Set-HeadsetBluetooth {
    <#
    .SYNOPSIS
    Turns the headset Bluetooth radio on or off. Returns @{ Ok; Output; Error }.
    .EXAMPLE
    Set-HeadsetBluetooth -Device $d -Enable $true
    #>
    param([Parameter(Mandatory=$true)] $Device, [Parameter(Mandatory=$true)][bool]$Enable)
    return Invoke-HeadsetDiagAction -Device $Device -Script ("cmd bluetooth_manager " + $(if ($Enable) { 'enable' } else { 'disable' }))
}

function Open-HeadsetBluetoothSettings {
    <#
    .SYNOPSIS
    Opens the Bluetooth settings screen inside the headset, so the player can pair a
    bHaptics vest or a ProTube from the headset itself. Returns @{ Ok; Output; Error }.
    .EXAMPLE
    Open-HeadsetBluetoothSettings -Device $d
    #>
    param([Parameter(Mandatory=$true)] $Device)
    return Invoke-HeadsetDiagAction -Device $Device -Script 'am start -a android.settings.BLUETOOTH_SETTINGS'
}


function ConvertTo-IanaTimeZone {
    <#
    .SYNOPSIS
    Maps a Windows time zone id (Romance Standard Time) to the IANA id Android expects
    (Europe/Paris). $null when the zone is not in the table.

    .DESCRIPTION
    .NET Framework on Windows PowerShell 5.1 has no IANA conversion, and shipping the full
    CLDR table for one optional convenience is not worth it. The table covers the zones this
    tool is realistically run in; an unmapped zone means the clock sync still happens and
    only the time zone is left alone, which the caller reports.

    .EXAMPLE
    ConvertTo-IanaTimeZone -WindowsId ([System.TimeZoneInfo]::Local.Id)
    #>
    param([string]$WindowsId)
    $map = @{
        'UTC' = 'UTC'; 'GMT Standard Time' = 'Europe/London'; 'Greenwich Standard Time' = 'Atlantic/Reykjavik'
        'W. Europe Standard Time' = 'Europe/Berlin'; 'Romance Standard Time' = 'Europe/Paris'
        'Central Europe Standard Time' = 'Europe/Budapest'; 'Central European Standard Time' = 'Europe/Warsaw'
        'E. Europe Standard Time' = 'Europe/Chisinau'; 'FLE Standard Time' = 'Europe/Kiev'
        'GTB Standard Time' = 'Europe/Bucharest'; 'Russian Standard Time' = 'Europe/Moscow'
        'Turkey Standard Time' = 'Europe/Istanbul'; 'Israel Standard Time' = 'Asia/Jerusalem'
        'Arabian Standard Time' = 'Asia/Dubai'; 'India Standard Time' = 'Asia/Kolkata'
        'China Standard Time' = 'Asia/Shanghai'; 'Tokyo Standard Time' = 'Asia/Tokyo'
        'Korea Standard Time' = 'Asia/Seoul'; 'Singapore Standard Time' = 'Asia/Singapore'
        'AUS Eastern Standard Time' = 'Australia/Sydney'; 'New Zealand Standard Time' = 'Pacific/Auckland'
        'Eastern Standard Time' = 'America/New_York'; 'Central Standard Time' = 'America/Chicago'
        'Mountain Standard Time' = 'America/Denver'; 'Pacific Standard Time' = 'America/Los_Angeles'
        'Alaskan Standard Time' = 'America/Anchorage'; 'Hawaiian Standard Time' = 'Pacific/Honolulu'
        'Atlantic Standard Time' = 'America/Halifax'; 'E. South America Standard Time' = 'America/Sao_Paulo'
        'Argentina Standard Time' = 'America/Argentina/Buenos_Aires'; 'South Africa Standard Time' = 'Africa/Johannesburg'
        'Egypt Standard Time' = 'Africa/Cairo'; 'Morocco Standard Time' = 'Africa/Casablanca'
    }
    if ($WindowsId -and $map.ContainsKey($WindowsId)) { return $map[$WindowsId] }
    return $null
}


function Sync-HeadsetClock {
    <#
    .SYNOPSIS
    Puts the headset clock right: turns automatic time on and forces a network time refresh,
    and optionally sets the time zone to this PC time zone. Returns
    @{ Ok; Output; Error; TimeZoneSet; TimeZone }.

    .DESCRIPTION
    A wrong clock breaks TLS (store, accounts, updates) and makes every log timestamp
    misleading. The headset has no way to ask the PC for the time over ADB, so the fix is to
    enable network time and trigger a refresh. TimeZoneSet is $false when the PC zone has no
    entry in ConvertTo-IanaTimeZone; the clock is still synced in that case.

    .EXAMPLE
    Sync-HeadsetClock -Device $d -SetTimeZone
    #>
    param([Parameter(Mandatory=$true)] $Device, [switch]$SetTimeZone)

    $res = Invoke-HeadsetDiagAction -Device $Device -Script 'settings put global auto_time 1; cmd network_time_update_service force_refresh; echo done'
    $out = [PSCustomObject]@{ Ok = $res.Ok; Output = $res.Output; Error = $res.Error; TimeZoneSet = $false; TimeZone = $null }
    if ($res.Ok -and $SetTimeZone) {
        $iana = ConvertTo-IanaTimeZone -WindowsId ([System.TimeZoneInfo]::Local.Id)
        if ($iana) {
            $tz = Invoke-HeadsetDiagAction -Device $Device -Script ("cmd alarm set-timezone " + $iana)
            $out.TimeZoneSet = [bool]$tz.Ok
            $out.TimeZone    = $iana
        }
    }
    return $out
}

function Reset-HeadsetPrivateDns {
    <#
    .SYNOPSIS
    Turns private DNS off on the headset. A stale private-DNS setting is a common reason a
    headset has WiFi but no internet. Returns @{ Ok; Output; Error }.
    .EXAMPLE
    Reset-HeadsetPrivateDns -Device $d
    #>
    param([Parameter(Mandatory=$true)] $Device)
    return Invoke-HeadsetDiagAction -Device $Device -Script 'settings put global private_dns_mode off'
}

function Set-HeadsetUpdaterDisabled {
    <#
    .SYNOPSIS
    Disables (or re-enables) the headset updater packages with pm disable-user, as an extra
    on top of the appops block of Set-HeadsetUpdateBlocked. Returns
    @{ Ok; Results = @(@{Package;Ok;Error}); Error }.

    .DESCRIPTION
    Some firmware refuses pm disable-user on the updater because it is a protected package,
    which is why the appops block exists. A refusal is therefore reported per package and
    does not make the whole call fail: Ok is true when at least one package changed.

    .EXAMPLE
    Set-HeadsetUpdaterDisabled -Device $d -Brand 'Meta' -Disabled $true
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$Brand = '',
        [Parameter(Mandatory=$true)][bool]$Disabled
    )
    $results = @()
    foreach ($pkg in @(Get-UpdaterPackages -Brand $Brand)) {
        $shellCmd = if ($Disabled) { "pm disable-user --user 0 " + $pkg } else { "pm enable " + $pkg }
        $a = Invoke-HeadsetDiagAction -Device $Device -Script $shellCmd
        $results += [PSCustomObject]@{ Package = $pkg; Ok = $a.Ok; Error = $a.Error }
    }
    $anyOk = [bool](@($results | Where-Object { $_.Ok }).Count)
    return [PSCustomObject]@{ Ok = $anyOk; Results = $results; Error = $(if ($anyOk) { $null } else { 'The headset refused the change for every updater package.' }) }
}

function Set-HeadsetAppEnabled {
    <#
    .SYNOPSIS
    Enables or disables one installed package for the primary user (pm enable /
    pm disable-user). Returns @{ Ok; Output; Error }.

    .DESCRIPTION
    The package name is validated against the Android package-name alphabet before it
    reaches a shell, so it cannot carry anything else. List the disabled packages with
    "pm list packages -d" (a preset on the DIAG page).

    .EXAMPLE
    Set-HeadsetAppEnabled -Device $d -Package com.example.app -Enable $false
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string]$Package,
        [Parameter(Mandatory=$true)][bool]$Enable
    )
    if ($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') {
        return [PSCustomObject]@{ Ok = $false; Output = @(); Error = 'Invalid package name.' }
    }
    $shellCmd = if ($Enable) { "pm enable " + $Package } else { "pm disable-user --user 0 " + $Package }
    return Invoke-HeadsetDiagAction -Device $Device -Script $shellCmd
}


function Send-HeadsetPlayerMessage {
    <#
    .SYNOPSIS
    Posts a notification on the headset so an operator can leave the player a message
    (cmd notification post, big-text style). Returns @{ Ok; Output; Error }.

    .DESCRIPTION
    LIMITATION, confirmed on a real headset: cmd notification post only puts the message in
    the headset notification center. It is NOT drawn over the view the player is looking
    at. Showing it on screen needs code running inside the headset (the companion app, a
    later step), so this stays a notification-center message until then.
    The text is reduced to printable ASCII, capped and quoted by ConvertTo-DiagShellText, so
    it cannot break out of the quoted argument.

    .EXAMPLE
    Send-HeadsetPlayerMessage -Device $d -Title 'Operator' -Text 'Please return to the desk'
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$Title = 'Message',
        [Parameter(Mandatory=$true)][string]$Text
    )
    $t = ConvertTo-DiagShellText -Text $Title -MaxLength 60
    $b = ConvertTo-DiagShellText -Text $Text  -MaxLength 300
    if (-not $b) { return [PSCustomObject]@{ Ok = $false; Output = @(); Error = 'The message is empty after removing unsupported characters.' } }
    if (-not $t) { $t = 'Message' }
    return Invoke-HeadsetDiagAction -Device $Device -Script ("cmd notification post -S bigtext -t '" + $t + "' vrhm_msg '" + $b + "'")
}

function Send-HeadsetText {
    <#
    .SYNOPSIS
    Types text into whatever field has focus in the headset (input text). Returns
    @{ Ok; Output; Error }.

    .DESCRIPTION
    Meant for the Wi-Fi password and search boxes, which are painful with the controllers.
    Printable ASCII only, 200 characters at most; a space is sent as the input service
    escape %s.

    .EXAMPLE
    Send-HeadsetText -Device $d -Text 'my wifi password'
    #>
    param([Parameter(Mandatory=$true)] $Device, [Parameter(Mandatory=$true)][string]$Text)
    $clean = ConvertTo-DiagShellText -Text $Text -MaxLength 200
    if (-not $clean) { return [PSCustomObject]@{ Ok = $false; Output = @(); Error = 'The text is empty after removing unsupported characters.' } }
    return Invoke-HeadsetDiagAction -Device $Device -Script ("input text '" + $clean.Replace(' ', '%s') + "'")
}

function Invoke-HeadsetRecovery {
    <#
    .SYNOPSIS
    Gentle recovery actions for a headset that looks stuck, from least to most disruptive:
    Wake, Home, RestartShell, RestartSystemUX. Returns @{ Ok; Output; Error }.

    .DESCRIPTION
    Wake presses the power key event (224); Home returns to the launcher; RestartShell and
    RestartSystemUX force-stop the shell / system UI package so the OS relaunches it. None
    of them reboots the device or touches user data. Unknown actions are refused.

    .EXAMPLE
    Invoke-HeadsetRecovery -Device $d -Action RestartShell
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string]$Action
    )
    $shellCmd = switch ($Action) {
        'Wake'            { 'input keyevent 224' }
        'Home'            { 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' }
        'RestartShell'    { 'am force-stop com.oculus.vrshell; am start -n com.oculus.vrshell/.HomeActivity' }
        'RestartSystemUX' { 'am force-stop com.oculus.systemux' }
        default           { $null }
    }
    if (-not $shellCmd) { return [PSCustomObject]@{ Ok = $false; Output = @(); Error = ('Unknown recovery action: ' + $Action) } }
    return Invoke-HeadsetDiagAction -Device $Device -Script $shellCmd
}


function Get-HeadsetDiagPresets {
    <#
    .SYNOPSIS
    The operator-editable command presets of the DIAG page (config Diag.command_presets), as
    @(@{ name; command }). @() when none are configured.
    .EXAMPLE
    Get-HeadsetDiagPresets | ForEach-Object name
    #>
    return @($global:Diag_command_presets)
}


function Test-HeadsetDiagCommandAllowed {
    <#
    .SYNOPSIS
    $true when a free-text shell command is acceptable for the DIAG command panel.

    .DESCRIPTION
    This is a guard against an expensive typo, not a security boundary: the operator already
    has full ADB access on this PC. It refuses what cannot be undone from the page - rebooting
    to the bootloader, fastboot, wiping data, and rm -rf on the root. Anything else runs.
    Commands are shell-only (they run inside adb shell), so an adb sub-command is not
    reachable from here.

    .EXAMPLE
    Test-HeadsetDiagCommandAllowed -Command 'getprop ro.product.model'
    #>
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    if ($Command.Length -gt 2000) { return $false }
    if ($Command -match "\x00") { return $false }
    $blocked = @(
        'reboot\s+bootloader',
        'fastboot',
        '(?<![a-z])wipe',
        'rm\s+(-\S+\s+)*-\S*[rR]\S*\s+(-\S+\s+)*/(\s|\*|$)'
    )
    foreach ($p in $blocked) { if ($Command -match ('(?i)' + $p)) { return $false } }
    return $true
}


function Invoke-HeadsetCustomCommand {
    <#
    .SYNOPSIS
    Runs one operator-typed (or preset) shell command on the headset and returns its output.
    Returns @{ Ok; Output; Truncated; Blocked; Error }.

    .DESCRIPTION
    Shell only, 20 second timeout, output capped at 64 KB. Refused commands (see
    Test-HeadsetDiagCommandAllowed) come back with Blocked = $true and never reach the
    headset. EVERY run is logged at INFO with the headset and the command: this panel is an
    audit-worthy capability, and when a headset misbehaves after an operator session the log
    is the only record of what was typed.

    .EXAMPLE
    Invoke-HeadsetCustomCommand -Device $d -Command 'getprop ro.product.model' -HeadsetName 'Q3 RED'
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$HeadsetName = ''
    )
    $cmd = $Command.Trim()
    if (-not (Test-HeadsetDiagCommandAllowed -Command $cmd)) {
        Write-Log ("DIAG command REFUSED for headset '{0}': {1}" -f $HeadsetName, $cmd) -Level WARNING
        return [PSCustomObject]@{ Ok = $false; Output = ''; Truncated = $false; Blocked = $true; Error = 'This command is not allowed from the DIAG page.' }
    }

    Write-Log ("DIAG command on headset '{0}': {1}" -f $HeadsetName, $cmd) -Level INFO
    $res = Invoke-HeadsetDiagAction -Device $Device -Script $cmd -TimeoutSeconds 20
    $text = (@($res.Output) -join "`n")
    $truncated = $false
    if ($text.Length -gt 65536) { $text = $text.Substring(0, 65536); $truncated = $true }
    return [PSCustomObject]@{ Ok = $res.Ok; Output = $text; Truncated = $truncated; Blocked = $false; Error = $res.Error }
}


function Get-HeadsetAdbTlsStatus {
    <#
    .SYNOPSIS
    EXPERIMENTAL probe: is Wireless debugging (ADB over TLS) enabled on the headset, and does
    it advertise a connect port over mDNS? Returns @{ Ok; Enabled; RawValue; MdnsPort; Error }.

    .DESCRIPTION
    Investigation only. The question is whether ADB over TLS could one day replace re-running
    "adb tcpip 5555" after every headset reboot, which needs a cable. NOTHING in the existing
    enable flow calls this, or Enable-HeadsetAdbTls, or Connect-HeadsetAdbTls: they exist so a
    technician can gather evidence from the DIAG page without changing how headsets are
    onboarded. MdnsPort is looked up with Find-QuestHeadsetsMdns (_adb-tls-connect._tcp) and
    matched on the headset IP; it is $null when nothing answered in time.

    .EXAMPLE
    Get-HeadsetAdbTlsStatus -Device $d -HeadsetIp '192.168.1.244'
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string]$HeadsetIp = '',
        [int]$MdnsTimeoutMs = 3000
    )
    $flag = Invoke-HeadsetDiagAction -Device $Device -Script 'settings get global adb_wifi_enabled'
    $raw  = if ($flag.Ok) { Get-DiagFirstLine $flag.Output } else { $null }
    $port = $null
    if ($HeadsetIp -and (Get-Command Find-QuestHeadsetsMdns -ErrorAction SilentlyContinue)) {
        try {
            $hit = @(Find-QuestHeadsetsMdns -TimeoutMs $MdnsTimeoutMs -ServiceTypes @('_adb-tls-connect._tcp')) |
                Where-Object { $_.IPAddress -eq $HeadsetIp } | Select-Object -First 1
            if ($hit) { $port = [int]$hit.Port }
        } catch { }
    }
    return [PSCustomObject]@{ Ok = $flag.Ok; Enabled = [bool]($raw -eq '1'); RawValue = $raw; MdnsPort = $port; Error = $flag.Error }
}

function Enable-HeadsetAdbTls {
    <#
    .SYNOPSIS
    EXPERIMENTAL: turns Wireless debugging on (settings put global adb_wifi_enabled 1).
    Evidence gathering only - see Get-HeadsetAdbTlsStatus. Returns @{ Ok; Output; Error }.
    .EXAMPLE
    Enable-HeadsetAdbTls -Device $d
    #>
    param([Parameter(Mandatory=$true)] $Device)
    return Invoke-HeadsetDiagAction -Device $Device -Script 'settings put global adb_wifi_enabled 1'
}

function Disable-HeadsetAdbTls {
    <#
    .SYNOPSIS
    Turns Wireless debugging (ADB over TLS) off: settings put global adb_wifi_enabled 0.
    The normal WiFi ADB used by this app (adb tcpip 5555) is a different feature and is not
    touched. Returns @{ Ok; Output; Error }.
    .EXAMPLE
    Disable-HeadsetAdbTls -Device $d
    #>
    param([Parameter(Mandatory=$true)] $Device)
    return Invoke-HeadsetDiagAction -Device $Device -Script 'settings put global adb_wifi_enabled 0'
}

function Connect-HeadsetAdbTls {
    <#
    .SYNOPSIS
    EXPERIMENTAL: runs "adb connect ip:port" against the mDNS-advertised TLS port and reports
    whether the transport came up. Returns @{ Ok; Output; Error }. Evidence gathering only.
    .EXAMPLE
    Connect-HeadsetAdbTls -IP '192.168.1.244' -Port 37123
    #>
    param(
        [Parameter(Mandatory=$true)][string]$IP,
        [Parameter(Mandatory=$true)][int]$Port,
        [string]$adb = $global:adbPath
    )
    if ($IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or $Port -lt 1 -or $Port -gt 65535) {
        return [PSCustomObject]@{ Ok = $false; Output = ''; Error = 'Invalid address or port.' }
    }
    $r = Invoke-Adb -Arguments @('connect', ($IP + ':' + $Port)) -TimeoutSeconds 10 -Adb $adb
    $text = ((@($r.StdOut) + @($r.StdErr)) -join ' ').Trim()
    return [PSCustomObject]@{ Ok = [bool]($r.Ok -and $text -match '(?i)connected'); Output = $text; Error = $(if ($r.Ok) { $null } else { $text }) }
}


function Get-HeadsetDiagTarget {
    <#
    .SYNOPSIS
    The registry row of one headset by its permanent numeric id (ADR-0016), or $null.
    The DIAG page addresses headsets by id, never by name or address, so a rename or a DHCP
    change cannot make a link point at another headset.
    .EXAMPLE
    Get-HeadsetDiagTarget -Id 3
    #>
    param([Parameter(Mandatory=$true)][int]$Id)
    return (@(Get-KnownHeadsets) | Where-Object { [string]$_.ID -eq [string]$Id } | Select-Object -First 1)
}


function Get-HeadsetDiagSection {
    <#
    .SYNOPSIS
    One DIAG section for one headset, as @{ ok; section; transport; error; data }.

    .DESCRIPTION
    The single entry point the web layer calls. Sections: firmware, health, wireless, tls
    (these four talk to the headset over the resolved transport), and usb, fleet, history
    (PC side and database only, so they work even when the headset is unreachable).

    The firmware section also carries the headset own row of the fleet comparison and its
    last recorded firmware changes, so the page needs one request for the whole card.
    transport is USB or WiFi - what the section was actually read over - and a dash for the
    PC-side sections.

    .EXAMPLE
    Get-HeadsetDiagSection -Headset $headset -Section health
    #>
    param(
        [Parameter(Mandatory=$true)] $Headset,
        [Parameter(Mandatory=$true)][ValidateSet('firmware','health','wireless','usb','fleet','history','tls')][string]$Section,
        # Auto follows config ADB.prefer_usb. USB / WiFi only change which transport is tried FIRST
        # (the other remains the fallback), so asking for WiFi on a cabled headset tests its WiFi
        # link without touching any setting. The response always names the transport that answered.
        [ValidateSet('Auto','USB','WiFi')][string]$Transport = 'Auto'
    )

    $res = [PSCustomObject]@{ ok = $false; section = $Section; transport = '-'; error = $null; data = $null }

    if ($Section -eq 'usb')     { $res.data = Get-HeadsetDiagUsb -Headset $Headset; $res.ok = $true; return $res }
    if ($Section -eq 'fleet')   { $res.data = @(Get-FleetFirmwareComparison); $res.ok = $true; return $res }
    if ($Section -eq 'history') { $res.data = @(Get-HeadsetFirmwareHistory -HeadsetId ([int]$Headset.ID) -Limit 20); $res.ok = $true; return $res }

    try {
        $device = Resolve-HeadsetAdbDevice -Headset $Headset -PreferTransport $Transport
    } catch {
        $res.error = $_.Exception.Message
        return $res
    }
    if (-not $device) { $res.error = 'The headset is not reachable over ADB (neither USB nor WiFi).'; return $res }
    $res.transport = $device.ConnectionType

    $brand = if ($Headset.PSObject.Properties['Brand'] -and $Headset.Brand) { [string]$Headset.Brand } else { '' }
    switch ($Section) {
        'firmware' {
            $fw = Get-HeadsetDiagFirmware -Device $device -Brand $brand
            $mine = @(Get-FleetFirmwareComparison) | Where-Object { [string]$_.ID -eq [string]$Headset.ID } | Select-Object -First 1
            $fw | Add-Member -NotePropertyName Fleet   -NotePropertyValue $mine -Force
            $fw | Add-Member -NotePropertyName History -NotePropertyValue @(Get-HeadsetFirmwareHistory -HeadsetId ([int]$Headset.ID) -Limit 10) -Force
            $res.data = $fw; $res.ok = [bool]$fw.Ok; $res.error = $fw.Error
        }
        'health'   { $d = Get-HeadsetDiagHealth   -Device $device; $res.data = $d; $res.ok = [bool]$d.Ok; $res.error = $d.Error }
        'wireless' { $d = Get-HeadsetDiagWireless -Device $device; $res.data = $d; $res.ok = [bool]$d.Ok; $res.error = $d.Error }
        'tls'      { $d = Get-HeadsetAdbTlsStatus -Device $device -HeadsetIp ([string]$Headset.IPAddress); $res.data = $d; $res.ok = [bool]$d.Ok; $res.error = $d.Error }
    }
    # Read it AGAIN: if the cable dropped mid-call, Invoke-AdbCmd retried over WiFi and updated this
    # device object, so this is the transport that really answered, not the one chosen at the start.
    $res.transport = $device.ConnectionType
    return $res
}


function Invoke-HeadsetDiagActionByName {
    <#
    .SYNOPSIS
    Runs one allow-listed DIAG action for one headset by NAME and returns
    @{ ok; action; transport; message; result }.

    .DESCRIPTION
    The single entry point behind POST /api/headset-diag/action and /command. The set of
    actions is closed: an unknown name is refused, so the web layer cannot be talked into
    reaching an arbitrary function. Every call is logged at INFO with the headset and the
    action, because these change the state of a live headset.

    Actions: bluetooth_on, bluetooth_off, bluetooth_settings, sync_clock (arg setTimeZone),
    reset_dns, updater_disable, updater_enable, app_enable / app_disable (arg package),
    player_message (args title, text), send_text (arg text), recover_wake, recover_home,
    recover_restart_shell, recover_restart_systemux, cable_test (arg passes), tls_enable,
    tls_connect (arg port), command (arg command - the custom shell command panel).

    cable_test is the one action that resolves its own transport: it must be USB, and says so
    when it is not.

    .EXAMPLE
    Invoke-HeadsetDiagActionByName -Headset $h -Action sync_clock -Arguments @{ setTimeZone = $true }
    #>
    param(
        [Parameter(Mandatory=$true)] $Headset,
        [Parameter(Mandatory=$true)][string]$Action,
        $Arguments = $null,
        [ValidateSet('Auto','USB','WiFi')][string]$Transport = 'Auto'
    )

    $res = [PSCustomObject]@{ ok = $false; action = $Action; transport = '-'; message = $null; result = $null }
    $arg = { param($n) if ($null -eq $Arguments) { return $null }; if ($Arguments -is [System.Collections.IDictionary]) { return $Arguments[$n] }; $p = $Arguments.PSObject.Properties[$n]; if ($p) { return $p.Value } else { return $null } }
    $known = @('bluetooth_on','bluetooth_off','bluetooth_settings','sync_clock','reset_dns','updater_disable','updater_enable',
               'app_enable','app_disable','player_message','send_text','recover_wake','recover_home','recover_restart_shell',
               'recover_restart_systemux','cable_test','wifi_speed_test','tls_enable','tls_disable','tls_connect','command','wifi_scan','wifi_switch')
    if ($known -notcontains $Action) { $res.message = ('Unknown action: ' + $Action); return $res }

    Write-Log ("DIAG action '{0}' on headset '{1}'" -f $Action, $Headset.Name) -Level INFO
    $brand = if ($Headset.PSObject.Properties['Brand'] -and $Headset.Brand) { [string]$Headset.Brand } else { '' }

    try {
        if ($Action -eq 'cable_test') {
            $passes = 0; [void][int]::TryParse([string](& $arg 'passes'), [ref]$passes)
            $r = Test-HeadsetUsbCable -Headset $Headset -Passes $passes
            $res.transport = 'USB'; $res.result = $r; $res.ok = [bool]$r.Ok; $res.message = $r.Error
            return $res
        }

        if ($Action -eq 'wifi_speed_test') {
            $passes = 0; [void][int]::TryParse([string](& $arg 'passes'), [ref]$passes)
            $r = Test-HeadsetWifiThroughput -Headset $Headset -Passes $passes
            $res.transport = 'WiFi'; $res.result = $r; $res.ok = [bool]$r.Ok; $res.message = $r.Error
            return $res
        }

        $device = Resolve-HeadsetAdbDevice -Headset $Headset -PreferTransport $Transport
        if (-not $device) { $res.message = 'The headset is not reachable over ADB (neither USB nor WiFi).'; return $res }
        $res.transport = $device.ConnectionType

        $r = switch ($Action) {
            'bluetooth_on'             { Set-HeadsetBluetooth -Device $device -Enable $true }
            'bluetooth_off'            { Set-HeadsetBluetooth -Device $device -Enable $false }
            'bluetooth_settings'       { Open-HeadsetBluetoothSettings -Device $device }
            'sync_clock'               { Sync-HeadsetClock -Device $device -SetTimeZone:([bool](& $arg 'setTimeZone')) }
            'reset_dns'                { Reset-HeadsetPrivateDns -Device $device }
            'updater_disable'          { Set-HeadsetUpdaterDisabled -Device $device -Brand $brand -Disabled $true }
            'updater_enable'           { Set-HeadsetUpdaterDisabled -Device $device -Brand $brand -Disabled $false }
            'app_enable'               { Set-HeadsetAppEnabled -Device $device -Package ([string](& $arg 'package')) -Enable $true }
            'app_disable'              { Set-HeadsetAppEnabled -Device $device -Package ([string](& $arg 'package')) -Enable $false }
            'player_message'           { Send-HeadsetPlayerMessage -Device $device -Title ([string](& $arg 'title')) -Text ([string](& $arg 'text')) }
            'send_text'                { Send-HeadsetText -Device $device -Text ([string](& $arg 'text')) }
            'recover_wake'             { Invoke-HeadsetRecovery -Device $device -Action 'Wake' }
            'recover_home'             { Invoke-HeadsetRecovery -Device $device -Action 'Home' }
            'recover_restart_shell'    { Invoke-HeadsetRecovery -Device $device -Action 'RestartShell' }
            'recover_restart_systemux' { Invoke-HeadsetRecovery -Device $device -Action 'RestartSystemUX' }
            'tls_enable'               { Enable-HeadsetAdbTls -Device $device }
            'tls_disable'              { Disable-HeadsetAdbTls -Device $device }
            'tls_connect'              { $p = 0; [void][int]::TryParse([string](& $arg 'port'), [ref]$p); Connect-HeadsetAdbTls -IP ([string]$Headset.IPAddress) -Port $p }
            'command'                  { Invoke-HeadsetCustomCommand -Device $device -Command ([string](& $arg 'command')) -HeadsetName ([string]$Headset.Name) }
            'wifi_scan'                { Get-HeadsetWifiOverview -Device $device }
            'wifi_switch'              { Switch-HeadsetWifi -Device $device -Ssid ([string](& $arg 'ssid')) -Password ([string](& $arg 'password')) -Security ([string](& $arg 'security')) -Brand $brand -SaveToStore:([bool](& $arg 'save')) -Force:([bool](& $arg 'force')) }
        }
        $res.result  = $r
        $res.ok      = [bool]$r.Ok
        $res.message = $(if ($r -and $r.PSObject.Properties['Message'] -and $r.Message) { $r.Message } else { $r.Error })
        # The transport that really answered (see Get-HeadsetDiagSection).
        $res.transport = $device.ConnectionType
    } catch {
        $res.message = $_.Exception.Message
    }
    return $res
}


function ConvertTo-DiagShellQuoted {
    <#
    .SYNOPSIS
    Quotes arbitrary text (an SSID, a WiFi password) as ONE single-quoted argument for the headset
    shell. Unlike ConvertTo-DiagShellText it KEEPS non-ASCII characters, because real SSIDs and
    passwords contain accents and symbols. Throws on control characters.

    .DESCRIPTION
    A single quote inside the text is closed, escaped and reopened. Control characters (newline,
    NUL, ...) are refused rather than stripped: silently altering a password would make a
    connection fail for a reason nobody could see. The result is meant to be embedded in a script
    sent with Invoke-AdbCmd -ShellScript, which passes it as ONE argument, so spaces and shell
    metacharacters in the SSID or password cannot split or be interpreted.

    .EXAMPLE
    "cmd wifi connect-network " + (ConvertTo-DiagShellQuoted -Text "Lab Wi-Fi 5G") + " wpa2 ..."
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    if ($Text -match '[\x00-\x1F\x7F]') { throw 'Control characters are not allowed in an SSID or a password.' }
    return ("'" + $Text.Replace("'", "'\''") + "'")
}


function Get-WifiBand {
    # 2.4 / 5 / 6 GHz from a frequency in MHz, $null when it is none of them.
    param([int]$FrequencyMhz)
    if ($FrequencyMhz -ge 2400 -and $FrequencyMhz -lt 2500) { return '2.4 GHz' }
    if ($FrequencyMhz -ge 4900 -and $FrequencyMhz -lt 5900) { return '5 GHz' }
    if ($FrequencyMhz -ge 5925 -and $FrequencyMhz -le 7125) { return '6 GHz' }
    return $null
}


function Get-WifiSecurityFromFlags {
    <#
    .SYNOPSIS
    The "cmd wifi connect-network" security keyword (open, owe, wpa2, wpa3) for a scan result,
    or enterprise / unsupported when no password-only join is possible.

    .DESCRIPTION
    Read from the capability flags of a scan row. A network that advertises BOTH a PSK and SAE
    (WPA2/WPA3 transition mode) is joined as wpa2, which every such access point accepts, while a
    SAE-only network needs wpa3. Enterprise (EAP) networks need a certificate or an identity that
    a shell command cannot supply, so they are reported as such instead of failing obscurely.

    .EXAMPLE
    Get-WifiSecurityFromFlags -Flags '[WPA2-PSK-CCMP][ESS]'    # wpa2
    #>
    param([string]$Flags)
    if (-not $Flags)                    { return 'open' }
    if ($Flags -match 'EAP')            { return 'enterprise' }
    if ($Flags -match 'PSK')            { return 'wpa2' }
    if ($Flags -match 'SAE')            { return 'wpa3' }
    if ($Flags -match 'OWE')            { return 'owe' }
    if ($Flags -match 'WEP|WPA|RSN')    { return 'unsupported' }
    return 'open'
}


function Merge-DiagSavedWifi {
    <#
    .SYNOPSIS
    One row per SSID from the rows of "cmd wifi list-networks". The headset keeps one entry PER
    security type (wpa2-psk and wpa3-sae for the same name), so the raw list shows each network twice.
    Returns @(@{Id;Ssid;Security}) with the security types joined by " / ".
    .EXAMPLE
    Merge-DiagSavedWifi -Rows $saved
    #>
    param([AllowEmptyCollection()][array]$Rows = @())
    $merged = @()
    foreach ($g in ($Rows | Group-Object -Property Ssid)) {
        $first = $g.Group | Select-Object -First 1
        $secs = @($g.Group | ForEach-Object { $_.Security } | Select-Object -Unique)
        $merged += [PSCustomObject]@{ Id = $first.Id; Ssid = $first.Ssid; Security = ($secs -join ' / ') }
    }
    return $merged
}


function Get-HeadsetSavedWifi {
    <#
    .SYNOPSIS
    The networks SAVED on the headset (cmd wifi list-networks) as @(@{Id;Ssid;Security}).
    @() when the command is unavailable. Never throws.
    .EXAMPLE
    Get-HeadsetSavedWifi -Device $device | ForEach-Object Ssid
    #>
    param([Parameter(Mandatory=$true)] $Device)
    $a = Invoke-HeadsetDiagAction -Device $Device -Script 'cmd wifi list-networks 2>/dev/null' -TimeoutSeconds 15
    if (-not $a.Ok) { return @() }
    $saved = @()
    foreach ($l in @($a.Output)) {
        if ($l -match '^\s*(\d+)\s+(.+?)\s{2,}(\S.*?)\s*$') { $saved += [PSCustomObject]@{ Id = [int]$Matches[1]; Ssid = $Matches[2].Trim(); Security = $Matches[3].Trim() } }
    }
    return (Merge-DiagSavedWifi -Rows $saved)
}


function Get-HeadsetWifiScan {
    <#
    .SYNOPSIS
    The WiFi networks the HEADSET radio can see right now, strongest first, one row per SSID:
    @{ Ssid; RssiDbm; FrequencyMhz; Band; Security; SavedOnHeadset; InServerStore }.

    .DESCRIPTION
    The scan runs on the headset, never on the server: a 6 GHz network is visible to a modern PC and
    invisible to an older headset, and the headset is the one that has to join. Security comes from
    the scan flags (Get-WifiSecurityFromFlags). InServerStore says whether this server already
    holds a password for the SSID in its encrypted WiFi store - the passwords themselves are never
    returned. SavedOnHeadset marks networks the headset already knows.

    Returns @{ Ok; Supported; Networks; Error }. Supported is $false when the firmware cannot list
    scan results over ADB, which is not the same as "nothing in range" (an empty Networks).

    .EXAMPLE
    (Get-HeadsetWifiScan -Device $device).Networks | Where-Object InServerStore
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [string[]]$SavedSsids = @(),
        [int]$SettleSeconds = 4
    )

    $r = [PSCustomObject]@{ Ok = $false; Supported = $true; Networks = @(); Error = $null }
    try {
        $seen = Get-HeadsetVisibleWifiNetworks -Device $Device -SettleSeconds $SettleSeconds
        if ($null -eq $seen) {
            $r.Supported = $false
            $r.Error = 'This headset firmware cannot list WiFi scan results over ADB.'
            return $r
        }
        $store = @(Get-WifiNetworks | ForEach-Object { [string]$_.SSID })
        $best = @{}
        foreach ($n in @($seen)) {
            if (-not $best.ContainsKey($n.Ssid) -or $n.Rssi -gt $best[$n.Ssid].Rssi) { $best[$n.Ssid] = $n }
        }
        $r.Networks = @($best.Values | Sort-Object { $_.Rssi } -Descending | ForEach-Object {
            [PSCustomObject]@{
                Ssid           = [string]$_.Ssid
                RssiDbm        = [int]$_.Rssi
                FrequencyMhz   = [int]$_.Frequency
                Band           = Get-WifiBand -FrequencyMhz ([int]$_.Frequency)
                Security       = Get-WifiSecurityFromFlags -Flags ([string]$_.Flags)
                SavedOnHeadset = [bool]($SavedSsids -contains [string]$_.Ssid)
                InServerStore  = [bool]($store -contains [string]$_.Ssid)
            }
        })
        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}


function Switch-HeadsetWifi {
    <#
    .SYNOPSIS
    Moves a headset onto another WiFi network over ADB (cmd wifi connect-network), after checking
    that the headset can actually SEE that network. Returns @{ Ok; Switched; Uncertain;
    NotVisible; PasswordRequired; Security; Saved; OnWifiTransport; Message; Error }.

    .DESCRIPTION
    Differences from Connect-HeadsetToWifi, which this does not replace:
      * the SSID and password are quoted as single shell arguments (ConvertTo-DiagShellQuoted), so
        a name or password containing spaces or quotes works - the old call split them;
      * the security type (open / owe / wpa2 / wpa3) comes from the headset scan, not a fixed wpa2;
      * the password may be typed (-Password), or left empty to use the one in the server's
        encrypted WiFi store; with -SaveToStore a typed password that WORKED is saved there.

    Safety. Joining a network the headset cannot see strands it off the network with no way back,
    so unless -Force is given the SSID must appear in the headset own scan (NotVisible otherwise,
    nothing is changed). When the headset is reached over WiFi the connection drops as soon as it
    leaves the network: the command then gets no answer, which is reported as Uncertain (not as a
    failure) with OnWifiTransport = $true, and a password is only saved on a confirmed success.
    PICO headsets cannot be joined this way (the shell is refused); the system WiFi picker is
    opened on the headset instead.

    The password never appears in a log line, in the returned object, or in any message: output
    from the device is redacted before it is returned.

    .EXAMPLE
    Switch-HeadsetWifi -Device $dev -Ssid 'Lab WiFi' -Password 'secret pass' -SaveToStore
    #>
    param(
        [Parameter(Mandatory=$true)] $Device,
        [Parameter(Mandatory=$true)][string]$Ssid,
        [string]$Password = '',
        [ValidateSet('', 'open', 'owe', 'wpa2', 'wpa3')][string]$Security = '',
        [string]$Brand = '',
        [switch]$SaveToStore,
        [switch]$Force
    )

    $res = [PSCustomObject]@{
        Ok = $false; Switched = $false; Uncertain = $false; NotVisible = $false; PasswordRequired = $false
        Security = $null; Saved = $false; OnWifiTransport = [bool]($Device.ConnectionType -eq 'WiFi')
        Message = $null; Error = $null
    }
    $fail = { param($text) $res.Message = $text; $res.Error = $text; return $res }

    # --- validate what the operator typed
    $Ssid = $Ssid.Trim()
    if (-not $Ssid -or [System.Text.Encoding]::UTF8.GetByteCount($Ssid) -gt 32) { return (& $fail 'The network name must be 1 to 32 bytes.') }
    if ($Ssid -match '[\x00-\x1F\x7F]' -or $Password -match '[\x00-\x1F\x7F]') { return (& $fail 'Control characters are not allowed in a network name or a password.') }

    if ($Brand -eq 'Pico') {
        Invoke-HeadsetDiagAction -Device $Device -Script 'am start -a android.settings.WIFI_SETTINGS' | Out-Null
        return (& $fail ('PICO headsets cannot be moved to another network over ADB. The WiFi settings screen was opened on the headset: choose ' + $Ssid + ' there.'))
    }

    # --- can the headset see it, and what security does it use?
    $sec = $Security
    $seen = $null
    if (-not $Force -or -not $sec) {
        $seen = Get-HeadsetVisibleWifiNetworks -Device $Device
    }
    if ($null -ne $seen) {
        $match = @($seen | Where-Object { $_.Ssid -eq $Ssid } | Sort-Object { $_.Rssi } -Descending | Select-Object -First 1)
        if ($match.Count -eq 0) {
            if (-not $Force) {
                $res.NotVisible = $true
                return (& $fail ("The headset cannot see '" + $Ssid + "', so it was NOT moved: it stays on its current network. Scan again, or move it closer to the access point."))
            }
        } elseif (-not $sec) {
            $sec = Get-WifiSecurityFromFlags -Flags ([string]$match[0].Flags)
        }
    } elseif (-not $Force) {
        return (& $fail 'The headset could not be scanned, so it cannot be checked that it sees this network. Nothing was changed.')
    }
    if (-not $sec) { $sec = $(if ($Password) { 'wpa2' } else { 'open' }) }
    if ($sec -eq 'enterprise' -or $sec -eq 'unsupported') {
        return (& $fail ("'" + $Ssid + "' uses a security type (enterprise / WEP) that cannot be set over ADB. Join it from the headset itself."))
    }
    $res.Security = $sec

    # --- password: typed, else the server's encrypted store
    $pw = $Password
    $fromStore = $false
    if ($sec -ne 'open' -and $sec -ne 'owe' -and -not $pw) {
        $stored = Get-WifiPassword -Ssid $Ssid
        if ($stored) { $pw = [string]$stored; $fromStore = $true }
    }
    if ($sec -in @('wpa2', 'wpa3') -and -not $pw) {
        $res.PasswordRequired = $true
        return (& $fail ("'" + $Ssid + "' needs a password and none is stored on the server. Enter it and try again."))
    }

    # --- build and send the command (one shell argument, quoted)
    $cmd = 'cmd -w wifi connect-network ' + (ConvertTo-DiagShellQuoted -Text $Ssid) + ' ' + $sec
    if ($sec -in @('wpa2', 'wpa3')) { $cmd += ' ' + (ConvertTo-DiagShellQuoted -Text $pw) }
    $cmd += ' -r none'

    $run = $null
    try {
        $run = Invoke-HeadsetDiagAction -Device $Device -Script $cmd -TimeoutSeconds 25
    } catch {
        $run = [PSCustomObject]@{ Ok = $false; Output = @(); Error = $_.Exception.Message }
    }

    # never let the password out, whatever the device printed
    $redact = { param($t) $s = [string]$t; if ($pw) { $s = $s.Replace($pw, '********') }; return $s }
    $outText = (& $redact (@($run.Output) -join ' ')).Trim()
    $errText = (& $redact $run.Error).Trim()

    if ($run.Ok -and $outText -notmatch '(?i)fail|error|unknown|invalid|not (supported|found)') {
        $res.Ok = $true
        $res.Switched = $true
        $res.Message = "The headset was told to join '" + $Ssid + "'. It reconnects within a few seconds."
        if ($SaveToStore -and $Password -and -not $fromStore) {
            try {
                $list = @(Get-WifiNetworks)
                $other = @($list | Where-Object { $_.SSID -ne $Ssid })
                $was = @($list | Where-Object { $_.SSID -eq $Ssid } | Select-Object -First 1)
                $pref = [bool]($was.Count -gt 0 -and $was[0].Preferred)
                Save-WifiNetworks -Networks (@($other) + [PSCustomObject]@{ SSID = $Ssid; Password = $Password; Preferred = $pref })
                $res.Saved = $true
            } catch {
                Write-Log ('Switch-HeadsetWifi: could not save the network to the server store: ' + $_.Exception.Message) -Level WARNING
            }
        }
        return $res
    }

    # Over WiFi the link dies the moment the headset leaves the network: no answer is expected.
    if ($res.OnWifiTransport -and -not $outText) {
        $res.Ok = $true
        $res.Uncertain = $true
        $res.Message = "The command was sent over WiFi, so the connection dropped as expected. Check that the headset comes back on '" + $Ssid + "' (it can take up to a minute); the password was not saved."
        return $res
    }

    $detail = $(if ($outText) { $outText } elseif ($errText) { $errText } else { 'no details' })
    return (& $fail ("The headset refused the connection to '" + $Ssid + "': " + $detail))
}


function Get-HeadsetWifiOverview {
    <#
    .SYNOPSIS
    One call for the DIAG "WiFi networks" card: a fresh scan from the headset radio plus the
    networks saved on the headset. Returns @{ Ok; Supported; Networks; Saved; Error }.
    .EXAMPLE
    (Get-HeadsetWifiOverview -Device $device).Networks | Select-Object Ssid, Band, Security
    #>
    param([Parameter(Mandatory=$true)] $Device)
    $saved = @(Get-HeadsetSavedWifi -Device $Device)
    $scan  = Get-HeadsetWifiScan -Device $Device -SavedSsids @($saved | ForEach-Object { $_.Ssid })
    return [PSCustomObject]@{ Ok = $scan.Ok; Supported = $scan.Supported; Networks = @($scan.Networks); Saved = $saved; Error = $scan.Error }
}
