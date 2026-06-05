#Requires -Version 5.1
<#
.SYNOPSIS
    Tests Get-CpuInfo, Get-RamInfo and Get-GpuInfo from modules/utils.ps1.

.DESCRIPTION
    Dot-sources utils.ps1 (no full app init required), calls each hardware
    function, pretty-prints the returned objects, and reports PASS/WARN/FAIL.

.PARAMETER ModulesRoot
    Path to the modules/ directory. Defaults to the sibling 'modules' folder
    relative to this script.

.OUTPUTS
    Console output. Exit code 0 = all OK, 1 = one or more functions failed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Test-ComputerHardwareInfo.ps1
#>
param(
    [string]$ModulesRoot = (Join-Path $PSScriptRoot '..\modules')
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$utilsPath = Join-Path $ModulesRoot 'utils.ps1'
if (-not (Test-Path -LiteralPath $utilsPath)) {
    Write-Host "ERROR: utils.ps1 not found at: $utilsPath" -ForegroundColor Red
    exit 2
}
. $utilsPath

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Result {
    param([string]$Label, [string]$Status, [string]$Detail = '')
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    $line  = "  [$Status] $Label"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Show-Object {
    param($Obj, [string]$Indent = '    ')
    if ($null -eq $Obj) { Write-Host "${Indent}(null)" -ForegroundColor DarkGray; return }
    $Obj.PSObject.Properties | ForEach-Object {
        $val = if ($null -eq $_.Value) { '(null)' } else { $_.Value }
        Write-Host ("{0}{1,-20} = {2}" -f $Indent, $_.Name, $val)
    }
}

$failed = 0

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== CPU ===' -ForegroundColor Cyan
$cpu = Get-CpuInfo
if ($null -eq $cpu) {
    Write-Result 'Get-CpuInfo' 'FAIL' 'returned $null'
    $failed++
} else {
    Show-Object $cpu
    $ok = ($cpu.Model -and $cpu.PhysicalCores -gt 0 -and $cpu.LogicalCores -gt 0)
    if ($ok) {
        Write-Result 'Get-CpuInfo' 'PASS'
    } else {
        Write-Result 'Get-CpuInfo' 'WARN' 'some expected fields missing'
    }
}

# ---------------------------------------------------------------------------
# RAM
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== RAM ===' -ForegroundColor Cyan
$ram = Get-RamInfo
if ($null -eq $ram) {
    Write-Result 'Get-RamInfo' 'FAIL' 'returned $null'
    $failed++
} else {
    Show-Object $ram
    $ok = ($ram.TotalGB -gt 0)
    if ($ok) {
        Write-Result 'Get-RamInfo' 'PASS'
    } else {
        Write-Result 'Get-RamInfo' 'WARN' 'TotalGB is 0 - check Win32_OperatingSystem'
    }
}

# ---------------------------------------------------------------------------
# GPU
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== GPU ===' -ForegroundColor Cyan
$gpus = Get-GpuInfo
if ($null -eq $gpus) {
    Write-Result 'Get-GpuInfo' 'FAIL' 'returned $null (expected array)'
    $failed++
} elseif ($gpus.Count -eq 0) {
    Write-Result 'Get-GpuInfo' 'WARN' 'no GPU adapters found (virtual machine?)'
} else {
    foreach ($gpu in $gpus) {
        Write-Host "  -- GPU $($gpu.Index): $($gpu.Model)" -ForegroundColor DarkCyan
        Show-Object $gpu '      '
        if ($null -eq $gpu.Load3DPercent) {
            Write-Result "GPU[$($gpu.Index)] perf counters" 'WARN' 'utilization unavailable (Win10 1903+ required)'
        }
    }
    Write-Result 'Get-GpuInfo' 'PASS' "$($gpus.Count) GPU(s) detected"
}

# ---------------------------------------------------------------------------
# App workload
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== APP WORKLOAD (500 ms sample) ===' -ForegroundColor Cyan
$workload = Get-AppWorkload
if ($null -eq $workload) {
    Write-Result 'Get-AppWorkload' 'FAIL' 'returned $null'
    $failed++
} else {
    foreach ($w in $workload) {
        Write-Host ("  {0,-14} count={1}  cpu={2,6:N1}%  mem={3,8:N1} MB" -f $w.ProcessName, $w.Count, $w.TotalCpuPct, $w.TotalMemoryMB)
    }
    $psFound = ($workload | Where-Object { $_.ProcessName -in @('powershell','pwsh') -and $_.Count -gt 0 })
    if ($psFound) {
        Write-Result 'Get-AppWorkload' 'PASS' 'powershell/pwsh instance(s) detected as expected'
    } else {
        Write-Result 'Get-AppWorkload' 'WARN' 'no powershell/pwsh found - unexpected in a PS session'
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($failed -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed check(s) failed." -ForegroundColor Red
    exit 1
}
