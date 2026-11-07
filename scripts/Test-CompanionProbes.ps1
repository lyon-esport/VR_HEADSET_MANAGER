#requires -Version 5.1
<#
.SYNOPSIS
Headset-free tests of the companion probe catalogue and the PowerShell parsers (T6.1, ADR-0046).
Catalogue checks, then every fixture of scripts\companionFixtures against expected.json.
Exit 0 = all passed, 1 = a FAIL.
.EXAMPLE
.\scripts\Test-CompanionProbes.ps1
#>
param([string]$CatalogPath = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$global:ScriptPath = $root

# Minimal stand-ins so the shared parsers run without the full app.
function Write-Log { param([string]$Message, [string]$Level) }
$global:msg = @{ ControllerBatteryStatus = '{0} {1} {2} {3} {4}' }
. (Join-Path $root 'modules\adb_telemetry.ps1')
. (Join-Path $root 'modules\companion_probes.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host "PASS  $Name" }
    else { $script:fail++; Write-Host "FAIL  $Name  $Detail" }
}

if (-not $CatalogPath) { $CatalogPath = Join-Path $root 'templates\companion\probes.json' }

# ---- charging = connected to any power source (operator decision 2026-11-07) ----
foreach ($c in @(@('AC',1), @('USB',1), @('Wireless',1), @('none',0))) {
    $ln = @('  AC powered: false', '  USB powered: false', '  Wireless powered: false', '  level: 50')
    foreach ($i in 0..2) { if ($ln[$i] -like ('*' + $c[0] + ' powered*')) { $ln[$i] = $ln[$i] -replace 'false', 'true' } }
    $r = ConvertFrom-BatteryDump -Lines $ln
    Check ('ConvertFrom-BatteryDump charging with ' + $c[0]) ([bool]$r.Charging -eq [bool]$c[1])
}
# ---- catalogue ----
Check 'catalogue file exists' (Test-Path -LiteralPath $CatalogPath)
$bytes = [System.IO.File]::ReadAllBytes($CatalogPath)
Check 'catalogue ASCII only' (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0)
Check 'catalogue no BOM' (-not ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF))
Check 'catalogue LF endings' (-not ($bytes -contains 13))
$cat = Get-CompanionProbeCatalog -Path $CatalogPath
Check 'catalogue parses, schema 1' ($null -ne $cat -and [int]$cat.schema -eq 1)
Check 'catalogue version format' ($cat.version -match '^\d{4}-\d{2}-\d{2}\.\d+$') $cat.version

$wire = @('battery','charging','temp','wattage','sourceW','battW','foregroundApp','thermalStatus','rssi','cpuTemp','gpuTemp','skinTemp',
    'ctrlLeft','ctrlRight','ctrlLeftState','ctrlRightState','plugged','battStatus','chargeCounterMah','refreshHz','refreshForcedHz')
$ids = @{}
foreach ($p in @($cat.probes)) {
    $n = "probe $($p.id)"
    Check "$n id format/unique" ($p.id -match '^[a-z][a-z0-9_]{1,31}$' -and -not $ids.ContainsKey($p.id))
    $ids[$p.id] = $true
    foreach ($k in 'description','command','parser','everySec','minEverySec','maxEverySec','screenOffFactor','timeoutMs','maxOutputBytes','brands','runOn','enabled','fields') {
        Check "$n has $k" ($null -ne $p.PSObject.Properties[$k])
    }
    Check "$n cadence range" ([int]$p.minEverySec -le [int]$p.everySec -and [int]$p.everySec -le [int]$p.maxEverySec)
    Check "$n command rules" (([string]$p.command) -match '^[\x20-\x7E]+$' -and ([string]$p.command) -notmatch '__VRHM_|\bexit\b|<<|;\s*$')
    Check "$n runOn/brands values" ((@($p.runOn) | Where-Object { $_ -notin 'companion','pc' }).Count -eq 0 -and (@($p.brands) | Where-Object { $_ -notin 'meta','pico','other' }).Count -eq 0)
    foreach ($f in @($p.fields)) {
        Check "$n field $($f.name) wire name" ($f.name -in $wire)
        Check "$n field $($f.name) type" ($f.type -in 'int','number','string','bool')
    }
}
Check 'Get-CompanionProbeCommand controllers' ((Get-CompanionProbeCommand -Id 'controllers') -like "*Paired device:*")
Check 'Get-CompanionProbeCommand companion-only side filter' ($null -eq (Get-CompanionProbeCommand -Id 'battery_power' -RunOn 'companion'))
Check 'Get-CompanionProbeCommand unknown id' ($null -eq (Get-CompanionProbeCommand -Id 'nope'))
Check 'Get-HeadsetBrandFamily' ((Get-HeadsetBrandFamily -Brand 'Oculus') -eq 'meta' -and (Get-HeadsetBrandFamily -Brand 'Pico') -eq 'pico' -and (Get-HeadsetBrandFamily -Brand 'foo') -eq 'other')

# Wire names not yet in the app list are INFO only (T6.3 adds them).
if (Get-Command Get-CompanionTelemetryFieldNames -ErrorAction SilentlyContinue) {
    $known = @(Get-CompanionTelemetryFieldNames)
    foreach ($p in @($cat.probes)) { foreach ($f in @($p.fields)) { if ($f.name -notin $known) { Write-Host "INFO  field $($f.name) not yet in Get-CompanionTelemetryFieldNames (T6.3)" } } }
} else {
    Write-Host 'INFO  Get-CompanionTelemetryFieldNames not loaded (companion_api.ps1 not sourced): wire-field coverage skipped'
}

# ---- fixtures ----
$fixRoot = Join-Path $PSScriptRoot 'companionFixtures'
foreach ($p in @($cat.probes)) {
    $dir = Join-Path $fixRoot $p.id
    $expPath = Join-Path $dir 'expected.json'
    if (-not (Test-Path -LiteralPath $expPath)) { Check "fixtures $($p.id) expected.json" $false 'missing'; continue }
    $exp = Get-Content -LiteralPath $expPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File)
    Check "fixtures $($p.id) present" ($files.Count -gt 0)
    foreach ($f in $files) {
        $n = "$($p.id)/$($f.Name)"
        $e = $exp.PSObject.Properties[$f.Name]
        if (-not $e) { Check "$n has expected entry" $false; continue }
        $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        $lines = if ($raw) { @(($raw -replace "`r", '') -split "`n") } else { @() }
        $got = ConvertTo-CompanionProbeFields -Id $p.id -Lines $lines
        $want = $e.Value
        $okAll = $true; $detail = ''
        $declared = @($p.fields | ForEach-Object { $_.name })
        foreach ($name in $declared) {
            if ($null -eq $want.PSObject.Properties[$name]) { $okAll = $false; $detail += " [$name not in expected]"; continue }
            $w = $want.$name; $g = $got[$name]
            $same = $false
            if ($null -eq $w -or $null -eq $g) { $same = ($null -eq $w -and $null -eq $g) }
            elseif ($w -is [string] -or $g -is [string]) { $same = ([string]$w -ceq [string]$g) }
            else { $same = ([Math]::Abs([double]$w - [double]$g) -le 0.051) }
            if (-not $same) { $okAll = $false; $detail += " [$name want=$w got=$g]" }
        }
        Check $n $okAll $detail
    }
}

Write-Host ''
Write-Host ("RESULT  PASS={0}  FAIL={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
