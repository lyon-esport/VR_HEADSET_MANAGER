#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the database test layers against the development tree.

.DESCRIPTION
    Unlike scripts\Invoke-NonRegressionTests.ps1, which drives a full
    extracted release, this harness needs no running application and no
    hardware. It exercises modules\database.ps1 directly against throwaway
    databases created under TEMP in a folder whose name carries an accented
    character - the condition the real project runs under (ADR-0006).

    Layers:
      Static   - source-tree checks: the SQLite access boundary, named-query
                 parity, migration numbering, ASCII, release packaging.
      Unit     - engine behaviour against a temp database.
      Stress   - multi-process and multi-runspace write contention.   (T10)
      Failure  - missing DLL, corrupt file, read-only folder, upgrades. (T10)
      Perf     - latency budgets.                                      (T10)

    Reports land in scripts\dbTests\reports\<timestamp>_... exactly like the
    non-regression harness, because it reuses that harness's runner.

.PARAMETER Layer
    Which layers to run. Defaults to Static and Unit, the two that are
    complete and fast enough to run on every change.

.EXAMPLE
    .\Invoke-DbTests.ps1
.EXAMPLE
    .\Invoke-DbTests.ps1 -Layer Static
.OUTPUTS
    Exit code 0 when nothing failed, 1 on any FAIL, 2 on a prerequisite
    problem. WARN never fails the run.
#>

[CmdletBinding()]
param(
    [ValidateSet('Static', 'Unit', 'Stress', 'Failure', 'Perf', 'All')]
    [string[]]$Layer = @('Static', 'Unit'),
    [switch]$KeepSandboxes
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'db_test_core.ps1')

$repoRoot = Get-DbTestRepoRoot

# Layer registry. File names mirror the layer names; a layer whose file does
# not exist yet is reported as SKIP rather than crashing the run, so this
# harness is usable from the first sub-task onward.
$layers = @(
    [PSCustomObject]@{ Id = 'Static';  Title = 'Static source checks';        File = 'Test-DbStatic.ps1' }
    [PSCustomObject]@{ Id = 'Unit';    Title = 'Engine unit tests';           File = 'Test-DbUnit.ps1' }
    [PSCustomObject]@{ Id = 'Stress';  Title = 'Concurrency stress';          File = 'Test-DbConcurrency.ps1' }
    [PSCustomObject]@{ Id = 'Failure'; Title = 'Failure injection';           File = 'Test-DbFailures.ps1' }
    [PSCustomObject]@{ Id = 'Perf';    Title = 'Performance budgets';         File = 'Test-DbPerf.ps1' }
)

$selected = if ($Layer -contains 'All') { $layers } else { @($layers | Where-Object { $Layer -contains $_.Id }) }
if ($selected.Count -eq 0) {
    Write-Host 'No layer selected.' -ForegroundColor Red
    exit 2
}

# Version string for the report header: the app version if one is recorded,
# otherwise the short commit.
$version = 'dev'
try {
    $sha = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $sha) { $version = "dev-$sha" }
} catch { }

Write-Host ''
Write-Host '=== VR HEADSET MANAGER - database tests ===' -ForegroundColor White
Write-Host ("  Repo   : {0}" -f $repoRoot) -ForegroundColor DarkGray
Write-Host ("  Layers : {0}" -f (($selected | ForEach-Object { $_.Id }) -join ', ')) -ForegroundColor DarkGray
Write-Host ("  Scratch: {0}" -f (Get-DbTestScratchRoot)) -ForegroundColor DarkGray

Initialize-TestRun -TargetRoot $repoRoot -Version $version -Mode Auto -Depth Standard `
                   -ReportFolder (Join-Path -Path $PSScriptRoot -ChildPath 'reports') | Out-Null

try {
    foreach ($entry in $selected) {
        $path = Join-Path -Path $PSScriptRoot -ChildPath $entry.File
        Start-TestSection -Id $entry.Id -Title $entry.Title | Out-Null

        if (-not (Test-Path -LiteralPath $path)) {
            Invoke-RegressionTest -Name ("{0} layer is present" -f $entry.Id) -Test {
                Skip-Test ("{0} is not implemented yet" -f $entry.File)
            }
            Complete-TestSection
            continue
        }

        try {
            . $path
        } catch {
            # A throw escaping a layer file records one synthetic failure
            # instead of killing every remaining layer.
            $message = $_.Exception.Message
            Invoke-RegressionTest -Name ("{0} layer aborted" -f $entry.Id) -Test {
                throw $message
            }
        }
        Complete-TestSection
    }
} finally {
    Write-TestSummary
    try {
        Write-TestReportText | Out-Null
        Write-TestReportHtml | Out-Null
        Write-Host ("  Report  : {0}" -f $global:TestRun.ArtifactFolder) -ForegroundColor DarkGray
    } catch {
        Write-Host ("  Report generation failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    # Sandboxes are removed by each test, but a hard failure can leave one
    # behind and they hold an open database file.
    if (-not $KeepSandboxes) {
        $scratch = Get-DbTestScratchRoot
        if (Test-Path -LiteralPath $scratch) {
            $stale = @(Get-ChildItem -LiteralPath $scratch -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) })
            foreach ($d in $stale) {
                try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch { }
            }
        }
    }
}

exit (Get-TestExitCode)
