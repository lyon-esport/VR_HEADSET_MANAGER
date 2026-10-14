# Test-TranslationParity.ps1
#
# Compares the keys of every translation file under modules\translations\ against
# the canonical en-US.psd1, RECURSIVELY: nested groups (Diag, Kiosk, ...) are walked
# and differences are reported as dotted paths (Diag.CableTestRunning). A key whose
# type differs (string vs hashtable) is reported too.
#
# Also gates the Import-PowerShellDataFile limit of 500 key/value pairs per
# hashtable literal: any file whose top-level table, or any nested table, holds
# $KeyWarnThreshold keys or more is flagged. The top-level count is always printed.
#
# Exit code:
#   0 = parity OK and key counts under the threshold
#   1 = drift found and/or key-count limit reached
#       (final lines tell which: "Translation parity: DRIFT" / "Key-count limit: EXCEEDED")
#   2 = en-US.psd1 not found / unreadable
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\Test-TranslationParity.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\Test-TranslationParity.ps1 -Path <folder with *.psd1>
#
# ASCII only.

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    # Folder holding the locale files. Default: <RepoRoot>\modules\translations.
    # Lets a test point the script at a tampered COPY without touching real files.
    [string]$Path = '',
    [int]$KeyWarnThreshold = 480
)

$ErrorActionPreference = 'Stop'

$translationsDir = $Path
if ([string]::IsNullOrWhiteSpace($translationsDir)) {
    $translationsDir = Join-Path -Path $RepoRoot -ChildPath (Join-Path 'modules' 'translations')
}
if (-not (Test-Path -LiteralPath $translationsDir)) {
    Write-Host "ERROR: translations folder not found: $translationsDir" -ForegroundColor Red
    exit 2
}

$enPath = Join-Path -Path $translationsDir -ChildPath 'en-US.psd1'
if (-not (Test-Path -LiteralPath $enPath)) {
    Write-Host "ERROR: en-US.psd1 not found at $enPath" -ForegroundColor Red
    exit 2
}

# Flattens a (possibly nested) hashtable to dotted path -> 'leaf' | 'table'.
function Get-KeyPathMap {
    param($Table, [string]$Prefix, [hashtable]$Map)
    foreach ($k in $Table.Keys) {
        $p = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
        if ($Table[$k] -is [System.Collections.IDictionary]) {
            $Map[$p] = 'table'
            Get-KeyPathMap -Table $Table[$k] -Prefix $p -Map $Map
        } else {
            $Map[$p] = 'leaf'
        }
    }
}

# Key count of every hashtable literal in the tree: dotted path ('' = top level) -> count.
function Get-TableKeyCounts {
    param($Table, [string]$Prefix, [hashtable]$Counts)
    $Counts[$Prefix] = @($Table.Keys).Count
    foreach ($k in $Table.Keys) {
        if ($Table[$k] -is [System.Collections.IDictionary]) {
            $p = if ($Prefix) { "$Prefix.$k" } else { [string]$k }
            Get-TableKeyCounts -Table $Table[$k] -Prefix $p -Counts $Counts
        }
    }
}

$script:limitHit = $false

# Prints the top-level count and flags any table at or above the threshold.
function Test-KeyCountLimit {
    param($Table, [string]$Label)
    $counts = @{}
    Get-TableKeyCounts -Table $Table -Prefix '' -Counts $counts
    $top = $counts['']
    $color = if ($top -ge $KeyWarnThreshold) { 'Yellow' } else { 'Gray' }
    Write-Host ("  Top-level keys: {0} (limit 500, warn at {1})" -f $top, $KeyWarnThreshold) -ForegroundColor $color
    foreach ($p in ($counts.Keys | Sort-Object)) {
        if ($counts[$p] -ge $KeyWarnThreshold) {
            $script:limitHit = $true
            $name = if ($p) { "nested table '$p'" } else { 'top-level table' }
            Write-Host ("  KEY LIMIT: {0} in {1} has {2} keys (>= {3})" -f $name, $Label, $counts[$p], $KeyWarnThreshold) -ForegroundColor Red
        }
    }
}

try {
    $en = Import-PowerShellDataFile -LiteralPath $enPath
} catch {
    Write-Host "ERROR: failed to parse en-US.psd1: $_" -ForegroundColor Red
    exit 2
}

$enMap = @{}
Get-KeyPathMap -Table $en -Prefix '' -Map $enMap
$drift = $false

Write-Host ""
Write-Host "=== en-US.psd1 (reference) ===" -ForegroundColor Cyan
Test-KeyCountLimit -Table $en -Label 'en-US.psd1'

$locales = Get-ChildItem -LiteralPath $translationsDir -Filter '*.psd1' |
    Where-Object { $_.Name -ne 'en-US.psd1' }

if (-not $locales) {
    Write-Host "Only en-US.psd1 present - nothing to compare." -ForegroundColor Yellow
}

foreach ($file in $locales) {
    Write-Host ""
    Write-Host ("=== {0} ===" -f $file.Name) -ForegroundColor Cyan
    try {
        $loc = Import-PowerShellDataFile -LiteralPath $file.FullName
    } catch {
        Write-Host ("  ERROR: failed to parse: {0}" -f $_) -ForegroundColor Red
        $drift = $true
        continue
    }
    $locMap = @{}
    Get-KeyPathMap -Table $loc -Prefix '' -Map $locMap

    $missing = @($enMap.Keys  | Where-Object { -not $locMap.ContainsKey($_) } | Sort-Object)
    $extra   = @($locMap.Keys | Where-Object { -not $enMap.ContainsKey($_)  } | Sort-Object)
    $typeBad = @($enMap.Keys  | Where-Object { $locMap.ContainsKey($_) -and $locMap[$_] -ne $enMap[$_] } | Sort-Object)

    if ($missing.Count -gt 0) {
        $drift = $true
        Write-Host ("  Missing in {0} ({1}):" -f $file.BaseName, $missing.Count) -ForegroundColor Yellow
        foreach ($k in $missing) { Write-Host ("    - {0}" -f $k) }
    }
    if ($extra.Count -gt 0) {
        $drift = $true
        Write-Host ("  Extra in {0} ({1}):" -f $file.BaseName, $extra.Count) -ForegroundColor Yellow
        foreach ($k in $extra) { Write-Host ("    + {0}" -f $k) }
    }
    if ($typeBad.Count -gt 0) {
        $drift = $true
        Write-Host ("  Type mismatch in {0} ({1}):" -f $file.BaseName, $typeBad.Count) -ForegroundColor Yellow
        foreach ($k in $typeBad) {
            Write-Host ("    ! {0}: en-US={1}, {2}={3}" -f $k, $enMap[$k], $file.BaseName, $locMap[$k])
        }
    }
    if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $typeBad.Count -eq 0) {
        Write-Host ("  OK ({0} keys incl. nested)" -f $locMap.Count) -ForegroundColor Green
    }
    Test-KeyCountLimit -Table $loc -Label $file.Name
}

Write-Host ""
if ($drift) {
    Write-Host "Translation parity: DRIFT" -ForegroundColor Red
} else {
    Write-Host "Translation parity: OK" -ForegroundColor Green
}
if ($script:limitHit) {
    Write-Host ("Key-count limit: EXCEEDED (>= {0} keys in one hashtable; hard limit is 500)" -f $KeyWarnThreshold) -ForegroundColor Red
} else {
    Write-Host "Key-count limit: OK" -ForegroundColor Green
}

if ($drift -or $script:limitHit) { exit 1 }
exit 0
