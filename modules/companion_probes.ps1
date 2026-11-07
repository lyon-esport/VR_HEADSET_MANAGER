# companion_probes.ps1 - catalogue of the companion local shell probes (T6.1, ADR-0046).
# Functions only. The catalogue file templates\companion\probes.json is the single source of the
# command texts; the parsers here must give the same wire fields as the Kotlin ones (fixtures in
# scripts\companionFixtures). Works when dot-sourced alone: no dependency except, for the
# controllers / thermal parsers, ConvertFrom-ControllerDump and ConvertFrom-ThermalService
# (adb_telemetry.ps1) which ConvertTo-CompanionProbeFields uses when present.

$script:CompanionProbeCatalogMemo = $null
$script:CompanionProbeCatalogWarned = $false

function Get-CompanionProbeCatalog {
    <#
    .SYNOPSIS
    Parsed probe catalogue, or $null when missing, unparsable or schema != 1. Never throws.
    .EXAMPLE
    (Get-CompanionProbeCatalog).version
    #>
    param([string]$Path = '')
    try {
        if (-not $Path) {
            if (-not $global:ScriptPath) { return $null }
            $Path = Join-Path $global:ScriptPath 'templates\companion\probes.json'
        }
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $fi = Get-Item -LiteralPath $Path
        $key = '{0}|{1}|{2}' -f $Path, $fi.LastWriteTimeUtc.Ticks, $fi.Length
        $memo = $script:CompanionProbeCatalogMemo
        if ($memo -and $memo.Key -eq $key) { return $memo.Catalog }
        $catalog = $null
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $catalog = $raw | ConvertFrom-Json
            if (-not $catalog -or [int]$catalog.schema -ne 1 -or -not $catalog.probes) { $catalog = $null }
        } catch { $catalog = $null }
        if (-not $catalog -and -not $script:CompanionProbeCatalogWarned) {
            $script:CompanionProbeCatalogWarned = $true
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "Companion probe catalogue unreadable or schema is not 1: $Path" -Level WARNING
            }
        }
        $script:CompanionProbeCatalogMemo = @{ Key = $key; Catalog = $catalog }
        return $catalog
    } catch { return $null }
}

function Get-CompanionProbe {
    <#
    .SYNOPSIS
    One probe object of the catalogue by id, or $null.
    .EXAMPLE
    Get-CompanionProbe -Id 'thermal'
    #>
    param([Parameter(Mandatory = $true)][string]$Id)
    try {
        $c = Get-CompanionProbeCatalog
        if (-not $c) { return $null }
        foreach ($p in @($c.probes)) { if ($p.id -eq $Id) { return $p } }
        return $null
    } catch { return $null }
}

function Get-CompanionProbeCommand {
    <#
    .SYNOPSIS
    Command text of a probe when it exists, is enabled and runs on the given side; else $null
    (the caller then uses its own literal).
    .EXAMPLE
    Get-CompanionProbeCommand -Id 'controllers'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$RunOn = 'pc'
    )
    try {
        $p = Get-CompanionProbe -Id $Id
        if (-not $p) { return $null }
        if ($p.enabled -ne $true) { return $null }
        if (@($p.runOn) -notcontains $RunOn) { return $null }
        $cmd = [string]$p.command
        if (-not $cmd) { return $null }
        return $cmd
    } catch { return $null }
}

function Get-HeadsetBrandFamily {
    <#
    .SYNOPSIS
    'pico', 'meta' or 'other' from a brand string (same rule as the companion app).
    .EXAMPLE
    Get-HeadsetBrandFamily -Brand 'oculus'
    #>
    param([string]$Brand = '')
    $b = ([string]$Brand).ToLowerInvariant()
    if ($b -match 'pico|pvr') { return 'pico' }
    if ($b -match 'oculus|meta|quest') { return 'meta' }
    return 'other'
}

function ConvertFrom-DisplayRefreshProbe {
    <#
    .SYNOPSIS
    Parses the output of the 'display' probe into @{RefreshHz;RefreshForcedHz} (ints or $null).
    .EXAMPLE
    ConvertFrom-DisplayRefreshProbe -Lines $lines
    #>
    param($Lines)
    $r = @{ RefreshHz = $null; RefreshForcedHz = $null }
    try {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $all = @($Lines | ForEach-Object { ([string]$_).TrimEnd("`r") })
        $hz = $null
        foreach ($l in $all) {
            if ($l -like '*mActiveSfDisplayMode=*') {
                $m = [regex]::Match($l, 'refreshRate=([0-9.]+)')
                if ($m.Success) { $hz = $m.Groups[1].Value }
                break
            }
        }
        if ($null -eq $hz) {
            foreach ($l in $all) {
                $m = [regex]::Match($l, 'renderFrameRate ([0-9.]+)')
                if ($m.Success) { $hz = $m.Groups[1].Value; break }
            }
        }
        if ($null -ne $hz) {
            $d = 0.0
            if ([double]::TryParse($hz, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) {
                $r.RefreshHz = [int][Math]::Round($d, 0, [MidpointRounding]::AwayFromZero)
            }
        }
        foreach ($l in $all) {
            $m = [regex]::Match($l.Trim(), '^forced=(\d+)$')
            if ($m.Success) {
                $f = [int]$m.Groups[1].Value
                if ($f -gt 0) { $r.RefreshForcedHz = $f }
                break
            }
        }
    } catch { }
    return $r
}

function ConvertFrom-BatteryPowerDump {
    <#
    .SYNOPSIS
    Parses 'dumpsys battery' into @{Plugged;BattStatus;ChargeCounterMah}.
    .EXAMPLE
    ConvertFrom-BatteryPowerDump -Lines (Get-Content -LiteralPath $f -Encoding UTF8)
    #>
    param($Lines)
    $r = @{ Plugged = 'none'; BattStatus = 'unknown'; ChargeCounterMah = $null }
    try {
        $all = @($Lines | ForEach-Object { ([string]$_).TrimEnd("`r") })
        $found = $false
        foreach ($pair in @(@('AC', 'ac'), @('USB', 'usb'), @('Wireless', 'wireless'), @('Dock', 'dock'))) {
            foreach ($l in $all) {
                if ($l -match ('^\s*' + $pair[0] + ' powered:\s*true\s*$')) { $r.Plugged = $pair[1]; $found = $true; break }
            }
            if ($found) { break }
        }
        $map = @{ 2 = 'charging'; 3 = 'discharging'; 4 = 'not_charging'; 5 = 'full' }
        foreach ($l in $all) {
            $m = [regex]::Match($l, '^\s*status:\s*(\d+)\s*$')
            if ($m.Success) {
                $n = [int]$m.Groups[1].Value
                if ($map.ContainsKey($n)) { $r.BattStatus = $map[$n] }
                break
            }
        }
        foreach ($l in $all) {
            $m = [regex]::Match($l, '^\s*Charge counter:\s*(\d+)\s*$')
            if ($m.Success) {
                $mah = [int][Math]::Floor([double]$m.Groups[1].Value / 1000.0)
                if ($mah -gt 0) { $r.ChargeCounterMah = $mah }
                break
            }
        }
    } catch { }
    return $r
}

function ConvertTo-CompanionProbeFields {
    <#
    .SYNOPSIS
    Wire fields (ordered hashtable, $null = known absent) for one probe from its output lines.
    The PowerShell side of the parity test against the Kotlin parsers.
    .EXAMPLE
    ConvertTo-CompanionProbeFields -Id 'thermal' -Lines $lines
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        $Lines
    )
    $out = [ordered]@{}
    $all = @($Lines | ForEach-Object { ([string]$_).TrimEnd("`r") })
    switch ($Id) {
        'controllers' {
            $dump = $null
            if (Get-Command ConvertFrom-ControllerDump -ErrorAction SilentlyContinue) {
                $dump = ConvertFrom-ControllerDump -Lines $all
            }
            foreach ($side in @('Left', 'Right')) {
                $has = $false
                foreach ($l in $all) {
                    if ($l -match 'Paired device:' -and $l -match ('Type:\s+' + $side)) { $has = $true }
                }
                $bat = $null; $st = $null
                if ($dump) { $bat = $dump[$side].Battery; $st = $dump[$side].ExternalStatus }
                if (-not $has) { $state = 'none'; $bat = $null }
                elseif ([string]::IsNullOrEmpty($st)) { $state = 'unknown' }
                else {
                    $state = ([string]$st).ToLowerInvariant()
                    if ($state -notmatch '^connected') { $bat = $null }
                }
                $out["ctrl$side"] = $bat
                $out["ctrl${side}State"] = $state
            }
            # wire order: ctrlLeft, ctrlRight, ctrlLeftState, ctrlRightState
            $ordered = [ordered]@{}
            $ordered['ctrlLeft'] = $out['ctrlLeft']
            $ordered['ctrlRight'] = $out['ctrlRight']
            $ordered['ctrlLeftState'] = $out['ctrlLeftState']
            $ordered['ctrlRightState'] = $out['ctrlRightState']
            return $ordered
        }
        'thermal' {
            $out['cpuTemp'] = $null; $out['gpuTemp'] = $null; $out['skinTemp'] = $null
            if (Get-Command ConvertFrom-ThermalService -ErrorAction SilentlyContinue) {
                $t = ConvertFrom-ThermalService -Lines $all
                $round = { param($v) if ($null -eq $v) { $null } else { [Math]::Round([double]$v, 1, [MidpointRounding]::AwayFromZero) } }
                $out['cpuTemp'] = & $round $t.Cpu
                $out['gpuTemp'] = & $round $t.Gpu
                $out['skinTemp'] = & $round $t.Skin
            }
            return $out
        }
        'display' {
            $d = ConvertFrom-DisplayRefreshProbe -Lines $all
            $out['refreshHz'] = $d.RefreshHz
            $out['refreshForcedHz'] = $d.RefreshForcedHz
            return $out
        }
        'battery_power' {
            $b = ConvertFrom-BatteryPowerDump -Lines $all
            $out['plugged'] = $b.Plugged
            $out['battStatus'] = $b.BattStatus
            $out['chargeCounterMah'] = $b.ChargeCounterMah
            return $out
        }
        default { return $null }
    }
}
