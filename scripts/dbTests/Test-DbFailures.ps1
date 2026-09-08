#Requires -Version 5.1
<#
.SYNOPSIS
    Layer (f) - failure injection. What happens when the engine, the file or
    the folder is not in the state the app expects.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    Each case here is a real field condition rather than a hypothetical:

      * A missing DLL is what a release zip built without the sources\sqlite
        line produces, and the operator must see WHICH file and WHERE.
      * Mark-Of-The-Web on the DLLs is the normal state of a freshly
        downloaded and extracted release. It fails with an opaque
        loadFromRemoteSources error, so the loader unblocks the files itself.
      * A read-only data folder is what running from Program Files looks like.
      * A schema newer than the module set is what a downgrade looks like.

    ASCII only.
#>

Invoke-RegressionTest -Name 'a missing engine DLL is reported with its exact path' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'nodll'
    try {
        # Point at a folder that does not hold the assembly, exactly as a
        # release built without the sources\sqlite manifest line would.
        $global:databaseAssemblyPath = Join-Path -Path $sandbox.Root -ChildPath 'missing\System.Data.SQLite.dll'

        # Test-RequiredBinaries must name it before anything tries to load it.
        # The other binary globals are normally set by Get-Config; give them
        # real values so this test fails on the database entry alone.
        $global:adbPath        = $global:databaseInteropPath
        $global:scrcpyFilePath = $global:databaseInteropPath
        $global:mediamtxEnabled = $false

        $modules = Join-Path -Path (Get-DbTestRepoRoot) -ChildPath 'modules'
        . (Join-Path -Path $modules -ChildPath 'utils.ps1')
        $check = Test-RequiredBinaries
        $missingNames = @($check.Missing | ForEach-Object { $_.ExeName })
        Add-TestEvidence ("missing binaries reported: {0}" -f ($missingNames -join ', '))
        Assert-Contains $missingNames 'System.Data.SQLite.dll' 'the missing engine assembly is reported'

        $entry = @($check.Missing | Where-Object { $_.ExeName -eq 'System.Data.SQLite.dll' })[0]
        Assert-Equal 'Database.AssemblyNotFound' ([string]$entry.MessageKey) 'the translation key for the missing assembly'

        # The loader must also fail with a message naming the path. In a FRESH
        # process: Import-DatabaseAssembly returns early once the assembly is
        # in the AppDomain, and earlier layers already loaded it here.
        $runner = Join-Path -Path $sandbox.Root -ChildPath 'nodll_load.ps1'
        $script = @'
param($Module, $Asm)
$global:ScriptPath           = Split-Path -Parent $Module
$global:databaseFolder       = Split-Path -Parent $Asm
$global:databaseAssemblyPath = $Asm
$global:databaseInteropPath  = Join-Path (Split-Path -Parent $Asm) 'x64\SQLite.Interop.dll'
$global:debugLevelToConsole  = 'NONE'
. $Module
try { Import-DatabaseAssembly | Out-Null; 'NO-THROW' } catch { 'THREW: ' + $_.Exception.Message }
'@
        Set-Content -LiteralPath $runner -Value $script -Encoding Ascii
        $modulePath = Join-Path -Path (Join-Path (Get-DbTestRepoRoot) 'modules') -ChildPath 'database.ps1'
        $loadResult = [string](& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
                                -Module $modulePath -Asm $global:databaseAssemblyPath 2>&1 | Select-Object -Last 1)
        Add-TestEvidence ("fresh process loader result: {0}" -f $loadResult)
        Assert-Match $loadResult 'THREW' 'the loader refuses to continue without the engine'
        Assert-Match $loadResult 'not found' 'the error says the assembly was not found'
        Assert-Match $loadResult 'System\.Data\.SQLite\.dll' 'the error names the expected path'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the missing-binary message resolves through the nested translation key' -Test {
    # Test-RequiredBinaries hands back a DOTTED key now, which $msg.($key)
    # cannot resolve - that is what Get-MessageString is for. If this
    # regresses, the operator sees a blank line instead of the reason the
    # application refused to start.
    $modules = Join-Path -Path (Get-DbTestRepoRoot) -ChildPath 'modules'
    . (Join-Path -Path $modules -ChildPath 'utils.ps1')

    $translations = Join-Path -Path $modules -ChildPath 'translations'
    foreach ($locale in @('en-US', 'fr-FR')) {
        $file = Join-Path -Path $translations -ChildPath ("{0}.psd1" -f $locale)
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $global:msg = Import-PowerShellDataFile -Path $file

        foreach ($key in @('Database.AssemblyNotFound', 'Database.InteropNotFound', 'Database.InitFailed', 'Database.Ready')) {
            $text = Get-MessageString -Key $key
            Assert-True ($text -ne $key) ("{0}: {1} resolves to a translated string" -f $locale, $key)
        }
        $formatted = (Get-MessageString -Key 'Database.AssemblyNotFound') -f 'C:\somewhere\System.Data.SQLite.dll'
        Add-TestEvidence ("{0}: {1}" -f $locale, $formatted)
        Assert-Match $formatted 'System\.Data\.SQLite\.dll' ("{0}: the path placeholder is filled in" -f $locale)
    }

    # An unknown key degrades to the key itself, never to an empty string:
    # Write-Log throws on an empty message.
    Assert-Equal 'Nope.Missing' (Get-MessageString -Key 'Nope.Missing') 'an unknown key falls back to the key'
}

Invoke-RegressionTest -Name 'a Mark-Of-The-Web blocked DLL is unblocked and loads' -Test {
    # Must run in a FRESH process: Import-DatabaseAssembly returns early once
    # the assembly is in the AppDomain (correctly - there is nothing to unblock
    # if nothing is being loaded), and earlier layers already loaded it here.
    # A first load of a freshly unzipped release is exactly this case.
    $sandbox = New-TempDatabaseRoot -Name 'motw'
    try {
        $srcFolder = $global:databaseFolder
        $dstFolder = Join-Path -Path $sandbox.Root -ChildPath 'engine'
        New-Item -ItemType Directory -Path (Join-Path $dstFolder 'x64') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $srcFolder 'System.Data.SQLite.dll') -Destination $dstFolder -Force
        Copy-Item -LiteralPath (Join-Path $srcFolder 'x64\SQLite.Interop.dll') -Destination (Join-Path $dstFolder 'x64') -Force

        $asm = Join-Path -Path $dstFolder -ChildPath 'System.Data.SQLite.dll'
        $int = Join-Path -Path $dstFolder -ChildPath 'x64\SQLite.Interop.dll'
        foreach ($dll in @($asm, $int)) {
            Set-Content -LiteralPath $dll -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -ErrorAction SilentlyContinue
        }
        $blockedBefore = $false
        try { Get-Content -LiteralPath $asm -Stream 'Zone.Identifier' -ErrorAction Stop | Out-Null; $blockedBefore = $true } catch { }
        Add-TestEvidence ("Zone.Identifier present before load: {0}" -f $blockedBefore)
        Assert-True $blockedBefore 'the test managed to mark the DLL as downloaded'

        $runner = Join-Path -Path $sandbox.Root -ChildPath 'motw_load.ps1'
        $script = @'
param($Module, $Folder, $Asm, $Int, $Db)
$global:ScriptPath             = Split-Path -Parent $Db
$global:databaseFolder         = $Folder
$global:databaseAssemblyPath   = $Asm
$global:databaseInteropPath    = $Int
$global:databaseFilePath       = $Db
$global:databaseBusyTimeoutMs  = 5000
$global:databaseRetryMax       = 2
$global:debugLevelToConsole    = 'NONE'
. $Module
try {
    Import-DatabaseAssembly | Out-Null
    $blocked = $false
    try { Get-Content -LiteralPath $Asm -Stream 'Zone.Identifier' -ErrorAction Stop | Out-Null; $blocked = $true } catch { }
    if ($blocked) { 'STILL-BLOCKED' } else { 'UNBLOCKED-AND-LOADED' }
} catch {
    'LOAD-FAILED: ' + $_.Exception.Message
}
'@
        Set-Content -LiteralPath $runner -Value $script -Encoding Ascii

        $modulePath = Join-Path -Path (Join-Path (Get-DbTestRepoRoot) 'modules') -ChildPath 'database.ps1'
        $result = [string](& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
                            -Module $modulePath -Folder $dstFolder -Asm $asm -Int $int `
                            -Db (Join-Path $sandbox.Root 'data\motw.db') 2>&1 | Select-Object -Last 1)

        Add-TestEvidence ("fresh process reported: {0}" -f $result)
        Assert-Equal 'UNBLOCKED-AND-LOADED' $result 'the loader clears the Mark-Of-The-Web and loads the engine'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a worker refuses a schema NEWER than its module set' -Test {
    # The downgrade direction: an operator rolls the app back but the database
    # file was already migrated by the newer build.
    $sandbox = New-TempDatabaseRoot -Name 'downgrade'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $current = Get-DbUserVersion
        Invoke-DbNonQuery -Sql ("PRAGMA user_version = {0};" -f ($current + 5)) | Out-Null

        Assert-Throws -Label 'a worker on a newer schema' -Match 'schema version mismatch' -Script {
            Initialize-Database -Role Worker
        }
        Add-TestEvidence ("file at {0}, module set expects {1}" -f ($current + 5), $current)
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a database in a non-existent folder is created, not fatal' -Test {
    # First run on a fresh install: data\ exists but the database does not.
    $sandbox = New-TempDatabaseRoot -Name 'freshfolder'
    try {
        $nested = Join-Path -Path $sandbox.Root -ChildPath 'data\nested\deeper'
        $global:databaseFilePath = Join-Path -Path $nested -ChildPath 'vrhm.db'
        Assert-True (-not (Test-Path -LiteralPath $nested)) 'the target folder does not exist yet'

        $result = Initialize-Database -Role Main -SkipBackup
        Assert-True $result.Ok 'initialization created the folder and the database'
        Assert-FileExists $global:databaseFilePath 'the database file'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a second process can read while the first holds a write transaction' -Test {
    # WAL exists precisely so the 2 Hz status writer never blocks the web
    # server's readers. If this regresses, the UI stalls whenever the monitor
    # writes.
    $sandbox = New-TempDatabaseRoot -Name 'walread'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1');" | Out-Null
        Close-DbConnection -Checkpoint

        Get-DbConnection | Out-Null
        $conn = $script:DbConn
        $txn  = $conn.BeginTransaction([System.Data.IsolationLevel]::Serializable)
        $w = $conn.CreateCommand()
        $w.Transaction = $txn
        $w.CommandText = "INSERT INTO headsets(id,name,ip_address) VALUES (2,'B','10.0.0.2');"
        $w.ExecuteNonQuery() | Out-Null

        # A separate connection, standing in for another process.
        $reader = New-Object System.Data.SQLite.SQLiteConnection((Get-DbConnectionString -DatabasePath $sandbox.DatabasePath))
        $reader.Open()
        $r = $reader.CreateCommand()
        $r.CommandText = 'SELECT COUNT(*) FROM headsets;'
        $seen = [int]$r.ExecuteScalar()
        $r.Dispose(); $reader.Close(); $reader.Dispose()

        $txn.Commit(); $txn.Dispose(); $w.Dispose()

        Add-TestEvidence ("reader saw {0} row(s) while an uncommitted insert was open" -f $seen)
        Assert-Equal 1 $seen 'the reader sees the committed snapshot and is not blocked'
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headsets;')) 'both rows are visible after commit'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
