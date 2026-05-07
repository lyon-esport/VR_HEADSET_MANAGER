# Test-TranslationParity.ps1
#
# Compares the keys of every translation file under modules\translations\ against
# the canonical en-US.psd1. Reports keys missing from each non-English locale and
# extra keys defined only in a non-English locale.
#
# Exit code:
#   0 = parity OK
#   1 = drift found
#   2 = en-US.psd1 not found / unreadable
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\Test-TranslationParity.ps1
#
# ASCII only.

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$translationsDir = Join-Path -Path $RepoRoot -ChildPath (Join-Path 'modules' 'translations')
if (-not (Test-Path -LiteralPath $translationsDir)) {
    Write-Host "ERROR: translations folder not found: $translationsDir" -ForegroundColor Red
    exit 2
}

$enPath = Join-Path -Path $translationsDir -ChildPath 'en-US.psd1'
if (-not (Test-Path -LiteralPath $enPath)) {
    Write-Host "ERROR: en-US.psd1 not found at $enPath" -ForegroundColor Red
    exit 2
}

try {
    $en = Import-PowerShellDataFile -LiteralPath $enPath
} catch {
    Write-Host "ERROR: failed to parse en-US.psd1: $_" -ForegroundColor Red
    exit 2
}

$enKeys = @{}
foreach ($k in $en.Keys) { $enKeys[[string]$k] = $true }
$drift  = $false

$locales = Get-ChildItem -LiteralPath $translationsDir -Filter '*.psd1' |
    Where-Object { $_.Name -ne 'en-US.psd1' }

if (-not $locales) {
    Write-Host "Only en-US.psd1 present - nothing to compare." -ForegroundColor Yellow
    exit 0
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
    $locKeys = @{}
    foreach ($k in $loc.Keys) { $locKeys[[string]$k] = $true }

    $missing = $enKeys.Keys  | Where-Object { -not $locKeys.ContainsKey($_) } | Sort-Object
    $extra   = $locKeys.Keys | Where-Object { -not $enKeys.ContainsKey($_)  } | Sort-Object

    if ($missing) {
        $drift = $true
        Write-Host ("  Missing in {0} ({1}):" -f $file.BaseName, $missing.Count) -ForegroundColor Yellow
        foreach ($k in $missing) { Write-Host ("    - {0}" -f $k) }
    }
    if ($extra) {
        $drift = $true
        Write-Host ("  Extra in {0} ({1}):" -f $file.BaseName, $extra.Count) -ForegroundColor Yellow
        foreach ($k in $extra) { Write-Host ("    + {0}" -f $k) }
    }
    if (-not $missing -and -not $extra) {
        Write-Host ("  OK ({0} keys)" -f $locKeys.Keys.Count) -ForegroundColor Green
    }
}

Write-Host ""
if ($drift) {
    Write-Host "Translation parity: DRIFT" -ForegroundColor Red
    exit 1
} else {
    Write-Host "Translation parity: OK" -ForegroundColor Green
    exit 0
}
