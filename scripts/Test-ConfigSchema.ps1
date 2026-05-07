# Test-ConfigSchema.ps1
#
# Compares the runtime config (config\config.json) to the template (templates\config\config.json).
# Reports keys present in one but not the other, and structural differences (object vs array vs scalar).
# Value differences (e.g. user-customised paths) are reported as INFO and do NOT fail the check.
#
# Exit code:
#   0 = schemas match
#   1 = drift found (missing or extra keys, or type mismatch)
#   2 = either file missing or unreadable
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\Test-ConfigSchema.ps1
#
# ASCII only.

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$runtimePath  = Join-Path -Path $RepoRoot -ChildPath (Join-Path 'config'    'config.json')
$templatePath = Join-Path -Path $RepoRoot -ChildPath (Join-Path 'templates' (Join-Path 'config' 'config.json'))

foreach ($p in @($runtimePath, $templatePath)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("ERROR: not found: {0}" -f $p) -ForegroundColor Red
        exit 2
    }
}

function Read-JsonObject {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Host ("ERROR: failed to parse JSON: {0}: {1}" -f $Path, $_) -ForegroundColor Red
        exit 2
    }
}

function Get-NodeKind {
    param($Node)
    if ($null -eq $Node)             { return 'null' }
    if ($Node -is [array])           { return 'array' }
    if ($Node -is [pscustomobject])  { return 'object' }
    return 'scalar'
}

$runtime  = Read-JsonObject -Path $runtimePath
$template = Read-JsonObject -Path $templatePath

$drift  = $false
$valueDiffs = New-Object System.Collections.Generic.List[string]

function Compare-ConfigNode {
    param(
        $Runtime,
        $Template,
        [string]$Path
    )
    $rKind = Get-NodeKind $Runtime
    $tKind = Get-NodeKind $Template

    if ($rKind -ne $tKind) {
        $script:drift = $true
        Write-Host ("  TYPE MISMATCH at '{0}': runtime={1}, template={2}" -f $Path, $rKind, $tKind) -ForegroundColor Yellow
        return
    }

    if ($tKind -eq 'object') {
        $rKeys = if ($Runtime)  { $Runtime.PSObject.Properties.Name }  else { @() }
        $tKeys = if ($Template) { $Template.PSObject.Properties.Name } else { @() }

        foreach ($k in $tKeys) {
            $sub = if ($Path) { "$Path.$k" } else { $k }
            if ($rKeys -notcontains $k) {
                $script:drift = $true
                Write-Host ("  MISSING in runtime: {0}" -f $sub) -ForegroundColor Yellow
            } else {
                Compare-ConfigNode -Runtime $Runtime.$k -Template $Template.$k -Path $sub
            }
        }
        foreach ($k in $rKeys) {
            $sub = if ($Path) { "$Path.$k" } else { $k }
            if ($tKeys -notcontains $k) {
                $script:drift = $true
                Write-Host ("  EXTRA in runtime  : {0}" -f $sub) -ForegroundColor Yellow
            }
        }
        return
    }

    if ($tKind -eq 'array') {
        if ($Runtime.Count -ne $Template.Count) {
            $script:valueDiffs.Add(("  array length differs at '{0}': runtime={1}, template={2}" -f $Path, $Runtime.Count, $Template.Count))
        }
        for ($i = 0; $i -lt [Math]::Min($Runtime.Count, $Template.Count); $i++) {
            Compare-ConfigNode -Runtime $Runtime[$i] -Template $Template[$i] -Path ("{0}[{1}]" -f $Path, $i)
        }
        return
    }

    if ("$Runtime" -ne "$Template") {
        $script:valueDiffs.Add(("  value differs at '{0}': runtime='{1}', template='{2}'" -f $Path, $Runtime, $Template))
    }
}

Write-Host ("Comparing:")
Write-Host ("  runtime : {0}" -f $runtimePath)
Write-Host ("  template: {0}" -f $templatePath)
Write-Host ""

Compare-ConfigNode -Runtime $runtime -Template $template -Path ''

if ($valueDiffs.Count -gt 0) {
    Write-Host ""
    Write-Host ("Value differences (INFO, not failing - {0} entries):" -f $valueDiffs.Count) -ForegroundColor DarkGray
    foreach ($d in $valueDiffs) { Write-Host $d -ForegroundColor DarkGray }
}

Write-Host ""
if ($drift) {
    Write-Host "Config schema: DRIFT (structural)" -ForegroundColor Red
    exit 1
} else {
    Write-Host "Config schema: OK (structures match)" -ForegroundColor Green
    exit 0
}
