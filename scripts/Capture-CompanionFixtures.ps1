#requires -Version 5.1
<#
.SYNOPSIS
Captures the real output of a catalogue probe from a headset (read-only adb) into
scripts\companionFixtures\<probe>\<name>.txt (UTF-8 no BOM, LF).
.EXAMPLE
.\scripts\Capture-CompanionFixtures.ps1 -DeviceId 192.168.1.243:5555 -Probe controllers -Name q3_searching
.EXAMPLE
.\scripts\Capture-CompanionFixtures.ps1 -DeviceId 192.168.1.243:5555 -Probe all -NamePrefix q3
#>
param(
    [Parameter(Mandatory = $true)][string]$DeviceId,
    [string]$Probe = 'all',
    [string]$Name = '',
    [string]$NamePrefix = 'q3',
    [string]$AdbPath = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\companion_probes.ps1')
$global:ScriptPath = $root

if (-not $AdbPath) {
    $cfg = Get-Content -LiteralPath (Join-Path $root 'config\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $AdbPath = Join-Path (Join-Path $root 'sources') (Join-Path $cfg.ADB.folder 'adb.exe')
}
if (-not (Test-Path -LiteralPath $AdbPath)) { throw "adb not found: $AdbPath" }

$catalog = Get-CompanionProbeCatalog
if (-not $catalog) { throw 'catalogue not readable' }
$ids = if ($Probe -eq 'all') { @($catalog.probes | ForEach-Object { $_.id }) } else { @($Probe) }
$suffix = @{ controllers = 'live'; thermal = 'hal'; display = 'live'; battery_power = 'live' }
$utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($id in $ids) {
    $p = Get-CompanionProbe -Id $id
    if (-not $p) { Write-Host "unknown probe $id"; continue }
    $cmd = [string]$p.command
    $ErrorActionPreference = 'Continue'   # adb stderr (e.g. dumpsys broken pipe) is harmless
    $text = & $AdbPath -s $DeviceId shell $cmd 2>$null | Out-String
    $ErrorActionPreference = 'Stop'
    $text = ($text -replace "`r", '').TrimEnd("`n")
    if ($text.Length -gt 0) { $text += "`n" }
    $fn = if ($Name) { $Name } else { "${NamePrefix}_$($suffix[$id])" }
    $dir = Join-Path $PSScriptRoot "companionFixtures\$id"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir "$fn.txt"
    [System.IO.File]::WriteAllText($file, $text, $utf8)
    Write-Host ("{0}: {1} bytes -> {2}" -f $id, $text.Length, $file)
}
