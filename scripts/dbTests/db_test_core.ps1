#Requires -Version 5.1
<#
.SYNOPSIS
    Shared scaffolding for the database test layers.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 before any layer script. Reuses the
    non-regression harness runner (Invoke-RegressionTest, the Assert-*
    family, Add-TestEvidence, the report writers) so database tests report
    exactly like every other test in this project.

    The important piece here is New-TempDatabaseRoot: it builds a sandbox
    whose folder name contains an accented character, because the real
    project lives under "Drive partages" with an accented e and that single
    byte has broken file I/O in this codebase repeatedly (ADR-0006). Testing
    the database engine from an ASCII-only temp path would not exercise the
    case that actually matters. The accent is built from a char code so this
    file itself stays 7-bit ASCII (ADR-0007).

    ASCII only.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Locate the project and reuse the NRT harness runner -------------------
$script:DbTestScriptRoot = $PSScriptRoot
$script:DbTestRepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$nrtCore = Join-Path -Path (Join-Path -Path $script:DbTestRepoRoot -ChildPath 'scripts') `
                     -ChildPath (Join-Path 'nonRegressionTests' 'test_core.ps1')
if (-not (Test-Path -LiteralPath $nrtCore)) {
    throw ("Non-regression harness core not found at '{0}'." -f $nrtCore)
}
. $nrtCore

function Get-DbTestRepoRoot { return $script:DbTestRepoRoot }

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

function Get-DbTestScratchRoot {
    <#
    .SYNOPSIS
        Parent folder for all database test sandboxes.
    .DESCRIPTION
        Uses the session scratch area under TEMP. Never the project folder:
        these tests create, corrupt and delete database files.
    #>
    return (Join-Path -Path $env:TEMP -ChildPath 'vrhm_dbtests')
}

function New-TempDatabaseRoot {
    <#
    .SYNOPSIS
        Creates an isolated sandbox rooted at an ACCENTED folder name and
        points the database globals at it.

    .DESCRIPTION
        Returns a hashtable describing the sandbox. The caller gets a fully
        configured environment: $global:ScriptPath, the modules\db tree
        (schema + queries, copied so a test can add a fake migration without
        touching the repo), and every $global:database* variable Get-Config
        would normally set.

        The assembly itself is NOT copied - it is loaded from the repo's
        sources\sqlite folder, which is the path the app really uses.

    .EXAMPLE
        $sandbox = New-TempDatabaseRoot -Name 'engine'
        Initialize-Database -Role Main | Out-Null
        Remove-TempDatabaseRoot -Sandbox $sandbox
    #>
    param(
        [string]$Name = 'db',
        [switch]$SkipDbFolderCopy
    )

    # "donnees" with an accented first e, built from a char code so this
    # source file stays ASCII.
    $accented = 'donn' + [char]0x00E9 + 'es'
    $stamp    = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $root     = Join-Path -Path (Get-DbTestScratchRoot) -ChildPath (("{0}_{1}_{2}" -f $Name, $stamp, $accented))

    foreach ($sub in @('', 'data', 'modules', 'logs')) {
        $folder = if ($sub) { Join-Path -Path $root -ChildPath $sub } else { $root }
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }

    # Copy the SQL tree so a test may add or corrupt a migration in isolation.
    if (-not $SkipDbFolderCopy) {
        $srcDb = Join-Path -Path (Join-Path -Path $script:DbTestRepoRoot -ChildPath 'modules') -ChildPath 'db'
        $dstDb = Join-Path -Path (Join-Path -Path $root -ChildPath 'modules') -ChildPath 'db'
        Copy-Item -LiteralPath $srcDb -Destination $dstDb -Recurse -Force
    }

    # Minimal global state: what Get-Config would have set, plus the logging
    # globals Write-Log needs so the module's log shim stays quiet.
    $global:ScriptPath              = $root
    $global:databaseFolder          = Join-Path -Path (Join-Path -Path $script:DbTestRepoRoot -ChildPath 'sources') -ChildPath (Join-Path 'sqlite' 'System.Data.SQLite-1.0.119')
    $global:databaseAssemblyPath    = Join-Path -Path $global:databaseFolder -ChildPath 'System.Data.SQLite.dll'
    $global:databaseInteropPath     = Join-Path -Path (Join-Path -Path $global:databaseFolder -ChildPath 'x64') -ChildPath 'SQLite.Interop.dll'
    $global:databaseFilePath        = Join-Path -Path (Join-Path -Path $root -ChildPath 'data') -ChildPath 'vrhm.db'
    $global:databaseBusyTimeoutMs   = 5000
    $global:databaseRetryMax        = 6
    $global:databaseIntegrityCheck  = 'quick'
    $global:databaseBackupKeep      = 3
    $global:databaseBackupOnStartup = $false
    $global:databaseMetricHistoryHours     = 24
    $global:databaseMaintenanceIntervalMin = 60
    $global:debugLevelToConsole     = 'NONE'
    $global:debugLevelToFile        = 'NONE'
    $global:logFile                 = Join-Path -Path (Join-Path -Path $root -ChildPath 'logs') -ChildPath 'dbtest.log'

    return @{
        Root         = $root
        DataFolder   = Join-Path -Path $root -ChildPath 'data'
        DbFolder     = Join-Path -Path (Join-Path -Path $root -ChildPath 'modules') -ChildPath 'db'
        DatabasePath = $global:databaseFilePath
        BackupFolder = Join-Path -Path (Join-Path -Path $root -ChildPath 'data') -ChildPath 'backup'
        Accented     = $accented
    }
}

function Remove-TempDatabaseRoot {
    <#
    .SYNOPSIS
        Closes the connection and deletes a sandbox. Never throws.
    .DESCRIPTION
        The connection must go first: SQLite keeps the .db, -wal and -shm
        files open, and on Windows an open handle makes the folder
        undeletable. That is the same failure the release-folder cleanup hits
        if a shutdown path forgets Close-DbConnection, so exercising it here
        is deliberate.
    #>
    param([Parameter(Mandatory = $true)]$Sandbox)

    try { Close-DbConnection } catch { }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    for ($i = 0; $i -lt 5; $i++) {
        try {
            if (Test-Path -LiteralPath $Sandbox.Root) {
                Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction Stop
            }
            return $true
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}

function Get-DbModuleUnderTestPath {
    <#
    .SYNOPSIS
        Path of the modules\database.ps1 the tests exercise.
    .DESCRIPTION
        Deliberately the REPO copy, not a sandbox copy: the tests must
        exercise the module that actually ships. Only the SQL tree and the
        data folder are sandboxed.

        Callers dot-source this path AT FILE SCOPE - never from inside a
        helper function, which would define the module's functions in that
        function's scope and lose them on return.
    #>
    $modulePath = Join-Path -Path (Join-Path -Path $script:DbTestRepoRoot -ChildPath 'modules') -ChildPath 'database.ps1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("modules\database.ps1 not found at '{0}'." -f $modulePath)
    }
    return $modulePath
}

# Load the module under test into this (the harness) scope, so every layer
# file dot-sourced later sees its functions.
. (Get-DbModuleUnderTestPath)

# ---------------------------------------------------------------------------
# Extra assertions
# ---------------------------------------------------------------------------

function Assert-Throws {
    <#
    .SYNOPSIS
        Fails unless the scriptblock throws, optionally matching a pattern.
    .EXAMPLE
        Assert-Throws { Get-DbNamedQuery -Name 'nope' } -Match 'not found'
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [string]$Match = '',
        [string]$Label = 'the operation'
    )
    $threw   = $false
    $message = ''
    try { & $Script | Out-Null } catch { $threw = $true; $message = $_.Exception.Message }

    if (-not $threw) { throw ("{0} was expected to throw but did not" -f $Label) }
    if ($Match -and $message -notmatch $Match) {
        throw ("{0} threw '{1}', which does not match '{2}'" -f $Label, $message, $Match)
    }
}
