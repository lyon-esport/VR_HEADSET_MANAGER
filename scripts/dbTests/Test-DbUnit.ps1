#Requires -Version 5.1
<#
.SYNOPSIS
    Layer (b) - engine unit tests. No app running, no headset, no network.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    Everything here runs against a throwaway database inside a sandbox whose
    path contains an accented character (New-TempDatabaseRoot), because that
    is the condition the real project runs under and the one that has broken
    file I/O here before (ADR-0006).

    This file covers the ENGINE only: assembly load, connection lifetime,
    schema and migration, the query/transaction/batch API, the key/value
    store, integrity and backup. Repository contract tests (headsets,
    kiosks, apps, identity healing) arrive with the sub-tasks that implement
    those repositories.

    ASCII only.
#>

# modules\database.ps1 is dot-sourced by db_test_core.ps1 at harness scope,
# so its functions are already available here.

# ---------------------------------------------------------------------------
# Assembly and connection
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'assembly loads from an accented path' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'assembly'
    try {
        Add-TestEvidence ("sandbox root: {0}" -f $sandbox.Root)
        Assert-True ($sandbox.Root -match [regex]::Escape($sandbox.Accented)) 'sandbox path carries the accented folder name'

        Import-DatabaseAssembly | Out-Null
        Add-TestEvidence ("SQLite engine: {0}" -f $global:databaseEngineVersion)
        Assert-NotNull $global:databaseEngineVersion 'engine version'

        # DELETE ... RETURNING (the kiosk command claim) needs 3.35+.
        $parts = $global:databaseEngineVersion.Split('.')
        $major = [int]$parts[0]; $minor = [int]$parts[1]
        Assert-True ($major -gt 3 -or ($major -eq 3 -and $minor -ge 35)) 'engine is 3.35 or newer'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'connection opens in WAL with foreign keys on' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'conn'
    try {
        Get-DbConnection | Out-Null
        $journal = Invoke-DbScalar -Sql 'PRAGMA journal_mode;'
        $fk      = Invoke-DbScalar -Sql 'PRAGMA foreign_keys;'
        Add-TestEvidence ("journal_mode={0} foreign_keys={1}" -f $journal, $fk)
        Assert-Equal 'wal' ([string]$journal).ToLower() 'journal mode'
        Assert-Equal 1 ([int]$fk) 'foreign_keys pragma'
        Assert-FileExists $sandbox.DatabasePath 'the database file'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a connection reached from a foreign runspace throws' -Test {
    # The failure this guards against is silent memory corruption: a native
    # SQLite handle used from two threads. Better a loud error immediately.
    $sandbox = New-TempDatabaseRoot -Name 'runspace'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null

        # [PowerShell]::Create() already hands back an opened runspace.
        $ps = [PowerShell]::Create()
        # Hand the OPEN connection to another runspace on purpose, then reach
        # it through the module's own accessor and expect a refusal.
        $null = $ps.AddScript({
            param($ModulePath, $Conn, $RsId)
            . $ModulePath
            Set-Variable -Scope Script -Name DbConn           -Value $Conn
            Set-Variable -Scope Script -Name DbConnRunspaceId -Value $RsId
            try { Get-DbConnection | Out-Null; return 'NO-THROW' }
            catch { return $_.Exception.Message }
        }).AddArgument((Join-Path -Path (Join-Path (Get-DbTestRepoRoot) 'modules') -ChildPath 'database.ps1')).
           AddArgument($script:DbConn).
           AddArgument([System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId)

        $result = [string](@($ps.Invoke()) | Select-Object -First 1)
        $ps.Dispose()

        Add-TestEvidence ("foreign runspace got: {0}" -f $result)
        Assert-True ($result -ne 'NO-THROW') 'the foreign-runspace guard must refuse the connection'
        Assert-Match $result 'runspace' 'the error names the runspace problem'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Close-DbConnection releases every file handle' -Test {
    # If this regresses, the release/test folder cannot be deleted after
    # shutdown and the non-regression harness cleanup starts failing.
    $sandbox = New-TempDatabaseRoot -Name 'handles'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO app_kv(key, value_json) VALUES ('probe','1');" | Out-Null
        Close-DbConnection -Checkpoint

        $removed = $true
        foreach ($f in @($sandbox.DatabasePath, "$($sandbox.DatabasePath)-wal", "$($sandbox.DatabasePath)-shm")) {
            if (Test-Path -LiteralPath $f) {
                try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { $removed = $false; Add-TestEvidence ("locked: {0}" -f $f) }
            }
        }
        Assert-True $removed 'database files are deletable right after Close-DbConnection'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Schema and migration
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Initialize-Database -Role Main creates the full schema' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'schema'
    try {
        $result = Initialize-Database -Role Main -SkipBackup
        Assert-True $result.Ok 'initialization succeeded'
        Add-TestEvidence ("schema version: {0}" -f $result.SchemaVersion)
        Assert-True ($result.SchemaVersion -ge 1) 'schema version is at least 1'

        $expected = @(
            'schema_version','db_versions','headsets','headset_status','metric_history',
            'kiosks','kiosk_status','kiosk_agent_reports','kiosk_commands','kiosk_autoadd_ignore',
            'discovered_headsets','headset_discovery_ignore','app_catalog','headset_installed_apps',
            'headset_favorite_apps','headset_timers','vqa_history','app_kv'
        )
        $actual = @(Invoke-DbQuery -Sql "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | ForEach-Object { $_.name })
        Add-TestEvidence ("tables: {0}" -f ($actual -join ', '))
        foreach ($t in $expected) { Assert-Contains $actual $t ("table {0}" -f $t) }

        $views = @(Invoke-DbQuery -Sql "SELECT name FROM sqlite_master WHERE type='view' ORDER BY name;" | ForEach-Object { $_.name })
        Add-TestEvidence ("views: {0}" -f ($views -join ', '))
        foreach ($v in @('v_headsets','v_headset_status','v_headset_full','v_kiosks','v_app_catalog','v_discovered_pending')) {
            Assert-Contains $views $v ("view {0}" -f $v)
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Initialize-Database is idempotent and preserves data' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'idempotent'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Set-DbKeyValue -Key 'probe' -Value @{ n = 42 }
        $v1 = Get-DbUserVersion

        Close-DbConnection
        $second = Initialize-Database -Role Main -SkipBackup
        $v2 = Get-DbUserVersion
        Add-TestEvidence ("user_version: {0} -> {1}" -f $v1, $v2)
        Assert-Equal $v1 $v2 'user_version unchanged by a second init'
        Assert-True $second.Ok 'second initialization succeeded'

        $probe = Get-DbKeyValue -Key 'probe'
        Assert-NotNull $probe 'the value written before the second init'
        Assert-Equal 42 ([int]$probe.n) 'the preserved value'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a pending migration is applied in order and bumps user_version' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'migrate'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $before = Get-DbUserVersion

        # Drop a synthetic 002 into the SANDBOX copy of modules\db\schema.
        $next = ('{0:D3}' -f ($before + 1))
        $file = Join-Path -Path (Join-Path $sandbox.DbFolder 'schema') -ChildPath ("{0}_test_migration.sql" -f $next)
        Set-Content -LiteralPath $file -Encoding Ascii -Value @'
CREATE TABLE IF NOT EXISTS migration_probe (id INTEGER PRIMARY KEY, note TEXT NOT NULL DEFAULT '');
INSERT INTO migration_probe(id, note) VALUES (1, 'applied');
'@
        $after = Update-DatabaseSchema
        Add-TestEvidence ("user_version: {0} -> {1}" -f $before, $after)
        Assert-Equal ($before + 1) $after 'user_version advanced by exactly one'

        $note = Invoke-DbScalar -Sql 'SELECT note FROM migration_probe WHERE id = 1;'
        Assert-Equal 'applied' ([string]$note) 'the migration body ran'

        # Re-running must be a no-op, not a duplicate insert.
        Update-DatabaseSchema | Out-Null
        $count = [int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM migration_probe;')
        Assert-Equal 1 $count 'the migration is not applied twice'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a worker refuses a database whose schema is behind the module set' -Test {
    # This is what stops a stale process half-migrating a live database.
    $sandbox = New-TempDatabaseRoot -Name 'worker'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $ok = Initialize-Database -Role Worker
        Assert-True $ok.Ok 'a matching worker init succeeds'

        # Pretend the file was written by an older build.
        Invoke-DbNonQuery -Sql 'PRAGMA user_version = 0;' | Out-Null
        Assert-Throws -Label 'a worker on a stale schema' -Match 'schema version mismatch' -Script {
            Initialize-Database -Role Worker
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Query API
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'named queries load, prepare and reuse' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'named'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null

        $sql = Get-DbNamedQuery -Name 'kv.get'
        Assert-Match $sql 'app_kv' 'kv.get reads app_kv'

        Set-DbKeyValue -Key 'alpha' -Value @{ v = 1 }
        Set-DbKeyValue -Key 'beta'  -Value @{ v = 2 }

        # Same prepared command, different parameter values.
        $a = Get-DbKeyValue -Key 'alpha'
        $b = Get-DbKeyValue -Key 'beta'
        Assert-Equal 1 ([int]$a.v) 'first read'
        Assert-Equal 2 ([int]$b.v) 'second read through the same prepared command'

        Assert-Throws -Label 'an unknown query name' -Match 'not found' -Script { Get-DbNamedQuery -Name 'nope.missing' }
        Assert-Throws -Label 'a malformed query name' -Match 'Invalid query name' -Script { Get-DbNamedQuery -Name 'Bad Name' }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'DBNull comes back as $null, not the DBNull singleton' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'dbnull'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO kiosk_agent_reports(ip_address, hostname, last_report_at) VALUES ('10.0.0.9', NULL, '2026-01-01');" | Out-Null
        $row = @(Invoke-DbQuery -Sql "SELECT hostname FROM kiosk_agent_reports WHERE ip_address = '10.0.0.9';")[0]
        Assert-True ($null -eq $row.hostname) 'a NULL column reads back as $null'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a failing transaction rolls back completely' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'txn'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1');" | Out-Null

        $threw = $false
        try {
            Invoke-DbTransaction -Script {
                Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (2,'B','10.0.0.2');" | Out-Null
                # Duplicate IP violates the UNIQUE index: the whole block must undo.
                Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (3,'C','10.0.0.1');" | Out-Null
            }
        } catch { $threw = $true }

        Assert-True $threw 'the transaction surfaced the constraint violation'
        $count = [int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headsets;')
        Add-TestEvidence ("headset rows after rollback: {0}" -f $count)
        Assert-Equal 1 $count 'the partial insert was rolled back'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Invoke-DbBatch commits many rows atomically' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'batch'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null

        $rows = @()
        for ($i = 1; $i -le 200; $i++) {
            $rows += @{ key = ("k{0}" -f $i); value_json = ('{"i":' + $i + '}') }
        }
        $n = Invoke-DbBatch -Name 'kv.set' -Rows $rows
        Add-TestEvidence ("rows written: {0}" -f $n)
        Assert-Equal 200 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM app_kv;')) 'all rows committed'

        # A bad row anywhere in the batch must undo the whole batch, including
        # the good rows that preceded it. The NULL key is rejected by the
        # NOT NULL on app_kv.key - SQLite would otherwise accept NULL in a
        # TEXT PRIMARY KEY, a long-standing quirk the schema guards against.
        $bad = @(@{ key = 'good'; value_json = '{}' }, @{ key = $null; value_json = '{}' })
        $threw = $false
        try { Invoke-DbBatch -Name 'kv.set' -Rows $bad | Out-Null } catch { $threw = $true }
        Assert-True $threw 'a bad row fails the batch'
        Assert-Equal 200 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM app_kv;')) 'the failed batch left nothing behind'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Key/value store
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'key/value round-trips nested objects and accented text' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'kv'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null

        # An accented value built from char codes, so this file stays ASCII.
        $accented = 'Vid' + [char]0x00E9 + 'o ' + [char]0x00E8 + 'me'
        $snapshot = @{
            Timestamp = '2026-09-08T10:00:00Z'
            CPU       = @{ Model = $accented; LoadPercent = 42 }
            GPU       = @(@{ Index = 0; Model = 'Radeon' }, @{ Index = 1; Model = 'NVIDIA' })
        }
        Set-DbKeyValue -Key 'computer_monitoring' -Value $snapshot

        $back = Get-DbKeyValue -Key 'computer_monitoring'
        Assert-NotNull $back 'the stored snapshot'
        Assert-Equal $accented ([string]$back.CPU.Model) 'accented text survives the round trip'
        Assert-Equal 42 ([int]$back.CPU.LoadPercent) 'nested scalar'
        Assert-Equal 2 (@($back.GPU).Count) 'nested array length'
        Assert-Equal 'NVIDIA' ([string]$back.GPU[1].Model) 'nested array element'

        Assert-True ($null -eq (Get-DbKeyValue -Key 'absent')) 'a missing key returns $null'
        Assert-Equal 'fallback' ([string](Get-DbKeyValue -Key 'absent' -Default 'fallback')) 'the default is honoured'

        Remove-DbKeyValue -Key 'computer_monitoring'
        Assert-True ($null -eq (Get-DbKeyValue -Key 'computer_monitoring')) 'the key was removed'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Contract helpers, counters, triggers
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'views return string IDs and True/False strings' -Test {
    # This is the compatibility contract: callers do $_.ID -eq $ID against a
    # value from a CSV era, key hashtables with [string]$h.ID, and read
    # booleans through ConvertTo-BoolField. Integers would break all three.
    $sandbox = New-TempDatabaseRoot -Name 'contract'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql @"
INSERT INTO headsets(id,name,ip_address,scrcpy_auto_restart,record,scrcpy_profile,brand,model,serial_number,sort_order)
VALUES (7,'Q3 RED','192.168.1.244',1,0,'square-R-N-20-6','Meta','Quest 3','2G0YC5ZG5400PS',0);
"@ | Out-Null

        $row = @(Invoke-DbQuery -Sql 'SELECT * FROM v_headsets;')[0]
        Add-TestEvidence ("ID type: {0}, value '{1}'" -f $row.ID.GetType().Name, $row.ID)
        Assert-True ($row.ID -is [string]) 'ID is TEXT so loose compares and hashtable keys keep working'
        Assert-True ($row.ID -eq 7) 'a string ID still compares equal to an int'
        Assert-Equal 'True'  ([string]$row.scrcpy_AutoRestart) 'boolean rendered as the string True'
        Assert-Equal 'False' ([string]$row.Record) 'boolean rendered as the string False'

        foreach ($col in @('ID','Name','IPAddress','scrcpy_AutoRestart','Record','ScrcpyProfile','Brand','Model','SerialNumber')) {
            Assert-True ($row.PSObject.Properties.Name -contains $col) ("legacy column {0} is present" -f $col)
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'ConvertTo-DbBool and ConvertFrom-DbBool agree with ConvertTo-BoolField' -Test {
    Assert-Equal 1 (ConvertTo-DbBool 'True')  'string True'
    Assert-Equal 1 (ConvertTo-DbBool 'true')  'lowercase true'
    Assert-Equal 1 (ConvertTo-DbBool $true)   'boolean true'
    Assert-Equal 1 (ConvertTo-DbBool '1')     'string 1'
    Assert-Equal 0 (ConvertTo-DbBool 'False') 'string False'
    Assert-Equal 0 (ConvertTo-DbBool '')      'empty string'
    Assert-Equal 0 (ConvertTo-DbBool $null)   'null'
    Assert-Equal 1 (ConvertTo-DbBool $null -Default $true) 'null with a true default'
    Assert-Equal 'True'  (ConvertFrom-DbBool 1) 'one renders as True'
    Assert-Equal 'False' (ConvertFrom-DbBool 0) 'zero renders as False'
}

Invoke-RegressionTest -Name 'table version counters advance on write' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'versions'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $v0 = Get-DbTableVersion -Name 'headsets'
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1');" | Out-Null
        $v1 = Get-DbTableVersion -Name 'headsets'
        Invoke-DbNonQuery -Sql "UPDATE headsets SET name='B' WHERE id=1;" | Out-Null
        $v2 = Get-DbTableVersion -Name 'headsets'
        Invoke-DbNonQuery -Sql "DELETE FROM headsets WHERE id=1;" | Out-Null
        $v3 = Get-DbTableVersion -Name 'headsets'

        Add-TestEvidence ("headsets counter: {0} -> {1} -> {2} -> {3}" -f $v0, $v1, $v2, $v3)
        Assert-True ($v1 -gt $v0) 'insert bumps the counter'
        Assert-True ($v2 -gt $v1) 'update bumps the counter'
        Assert-True ($v3 -gt $v2) 'delete bumps the counter'

        $other = Get-DbTableVersion -Name 'app_kv'
        Assert-Equal 0 ([int]$other) 'an untouched table keeps its counter at zero'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'cascade delete removes every dependent row' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'cascade'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql @"
INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1');
INSERT INTO headset_status(headset_id) VALUES (1);
INSERT INTO headset_installed_apps(headset_id,package_name,version) VALUES (1,'com.x','1.0');
INSERT INTO headset_favorite_apps(headset_id,package_name,display_name) VALUES (1,'com.x','X');
INSERT INTO headset_timers(headset_id,minutes,seconds,mode) VALUES (1,10,0,'dec');
"@ | Out-Null

        Invoke-DbNonQuery -Sql 'DELETE FROM headsets WHERE id = 1;' | Out-Null

        foreach ($t in @('headset_status','headset_installed_apps','headset_favorite_apps','headset_timers')) {
            $n = [int](Invoke-DbScalar -Sql ("SELECT COUNT(*) FROM {0};" -f $t))
            Add-TestEvidence ("{0}: {1} row(s) left" -f $t, $n)
            Assert-Equal 0 $n ("{0} cascaded" -f $t)
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the metric triggers sample only, and never prune' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'metrics'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1'); INSERT INTO headset_status(headset_id) VALUES (1);" | Out-Null

        # Migration 005 moved retention off the trigger and onto the maintenance
        # sweep. Sampling fires on every reading change, inside the monitor's
        # batched status write, so a DELETE and a correlated subquery there were
        # paid for by every sample - and anything that throws in that
        # transaction loses the whole tick, for every headset.
        for ($i = 1; $i -le 130; $i++) {
            $ts = (Get-Date).AddSeconds(-$i).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            Invoke-DbNonQuery -Sql ("INSERT OR REPLACE INTO metric_history(headset_id, metric, ts, value) VALUES (1, 'battery', '{0}', {1});" -f $ts, ($i % 100)) | Out-Null
        }
        # Count what actually landed rather than assuming 130. Timestamps are
        # whole seconds, so if the loop above straddles a second boundary two
        # iterations can produce the same ts and INSERT OR REPLACE merges them.
        $before = [int](Invoke-DbScalar -Sql "SELECT COUNT(*) FROM metric_history WHERE headset_id = 1 AND metric = 'battery';")
        Assert-True ($before -gt 100) 'well over the old 100-row cap was seeded'

        Invoke-DbNonQuery -Sql "UPDATE headset_status SET battery = '55 %' WHERE headset_id = 1;" | Out-Null

        $n = [int](Invoke-DbScalar -Sql "SELECT COUNT(*) FROM metric_history WHERE headset_id = 1 AND metric = 'battery';")
        Add-TestEvidence ("battery rows: {0} seeded -> {1} after one sample" -f $before, $n)
        Assert-Equal ($before + 1) $n 'the trigger added its sample and removed nothing'

        # "85 %" is what headset_status actually holds; CAST must stop at the space.
        $lvl = [double](Invoke-DbScalar -Sql "SELECT value FROM metric_history WHERE headset_id = 1 AND metric = 'battery' ORDER BY ts DESC LIMIT 1;")
        Assert-Equal 55 ([int]$lvl) 'a "55 %" display string is stored as 55'

        # The placeholder '-' must never be sampled.
        Invoke-DbNonQuery -Sql "UPDATE headset_status SET battery = '-' WHERE headset_id = 1;" | Out-Null
        $after = [int](Invoke-DbScalar -Sql "SELECT COUNT(*) FROM metric_history WHERE headset_id = 1 AND metric = 'battery';")
        Assert-Equal $n $after 'the dash placeholder is not recorded as a sample'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'temperature is sampled at 0.1 C, comma decimal included' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'temperature'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1'); INSERT INTO headset_status(headset_id) VALUES (1);" | Out-Null

        # The whole point of a REAL column: an INTEGER one would hand 36.4 back as
        # 36, silently, because a value is read through its column's DECLARED type.
        Invoke-DbNonQuery -Sql "UPDATE headset_status SET temp = '36.4' WHERE headset_id = 1;" | Out-Null
        $t = [double](Invoke-DbScalar -Sql "SELECT value FROM metric_history WHERE headset_id = 1 AND metric = 'temp' ORDER BY ts DESC LIMIT 1;")
        Add-TestEvidence ("stored temperature: {0}" -f $t)
        Assert-Equal 36.4 $t 'a decimal temperature keeps its tenth of a degree'

        # Get-HeadsetBatteryStatus formats with .ToString("0.0"), which yields a
        # COMMA under a FR locale. CAST('36,4' AS REAL) is 36 without the REPLACE.
        Invoke-DbNonQuery -Sql "UPDATE headset_status SET temp = '41,7' WHERE headset_id = 1;" | Out-Null
        $t2 = [double](Invoke-DbScalar -Sql "SELECT value FROM metric_history WHERE headset_id = 1 AND metric = 'temp' ORDER BY ts DESC LIMIT 1;")
        Add-TestEvidence ("stored comma-decimal temperature: {0}" -f $t2)
        Assert-Equal 41.7 $t2 'a comma decimal separator is not truncated'

        # Each column feeds its own metric, and nothing bleeds across.
        Invoke-DbNonQuery -Sql "UPDATE headset_status SET battery_controller_left = '72 %', battery_controller_right = '68 %', charging_wattage = '18' WHERE headset_id = 1;" | Out-Null
        foreach ($pair in @(@('ctrl_left',72), @('ctrl_right',68), @('wattage',18))) {
            $v = [double](Invoke-DbScalar -Sql ("SELECT value FROM metric_history WHERE headset_id = 1 AND metric = '{0}' ORDER BY ts DESC LIMIT 1;" -f $pair[0]))
            Assert-Equal ([double]$pair[1]) $v ("{0} sampled from its own column" -f $pair[0])
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'metric.prune removes only samples past the cutoff' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'prune'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address) VALUES (1,'A','10.0.0.1'); INSERT INTO headset_status(headset_id) VALUES (1);" | Out-Null

        $old   = [datetime]::UtcNow.AddHours(-48).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $fresh = [datetime]::UtcNow.AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
        foreach ($m in @('battery','temp','ctrl_left','ctrl_right','wattage')) {
            Invoke-DbNonQuery -Sql ("INSERT INTO metric_history(headset_id, metric, ts, value) VALUES (1,'{0}','{1}',10),(1,'{0}','{2}',20);" -f $m, $old, $fresh) | Out-Null
        }

        # One DELETE covers every headset and every metric - that is the point of
        # folding the per-metric tables into one.
        $cutoff  = [datetime]::UtcNow.AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $removed = Invoke-DbNonQuery -Name 'metric.prune' -Parameters @{ cutoff = $cutoff }
        Add-TestEvidence ("pruned {0} row(s) across 5 metrics" -f $removed)
        Assert-Equal 5 ([int]$removed) 'exactly the five stale rows went'

        $left = [int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM metric_history;')
        Assert-Equal 5 $left 'the five fresh rows survived'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'discovery pruning triggers fire on known and ignored serials' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'discovery'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql @"
INSERT INTO discovered_headsets(serial_number, ip_address, model, brand, first_seen, last_seen)
VALUES ('SER-A','10.0.0.5','Quest 3','Meta','2026-01-01','2026-01-01'),
       ('SER-B','10.0.0.6','Quest 3','Meta','2026-01-01','2026-01-01'),
       ('SER-C','10.0.0.7','Quest 3','Meta','2026-01-01','2026-01-01');
"@ | Out-Null
        Assert-Equal 3 (@(Invoke-DbQuery -Sql 'SELECT * FROM v_discovered_pending;').Count) 'three pending proposals'

        # Registering a headset with that serial retires its proposal.
        Invoke-DbNonQuery -Sql "INSERT INTO headsets(id,name,ip_address,serial_number) VALUES (1,'A','10.0.0.5','SER-A');" | Out-Null
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql "SELECT COUNT(*) FROM discovered_headsets WHERE serial_number='SER-A';")) 'a known serial is pruned'

        # Forgetting one retires it too, and the denylist is serial-keyed.
        Invoke-DbNonQuery -Sql "INSERT INTO headset_discovery_ignore(serial_number) VALUES ('SER-B');" | Out-Null
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql "SELECT COUNT(*) FROM discovered_headsets WHERE serial_number='SER-B';")) 'a forgotten serial is pruned'

        $pending = @(Invoke-DbQuery -Sql 'SELECT * FROM v_discovered_pending;')
        Add-TestEvidence ("still pending: {0}" -f (($pending | ForEach-Object { $_.SerialNumber }) -join ', '))
        Assert-Equal 1 $pending.Count 'exactly one proposal remains'
        Assert-Equal 'SER-C' ([string]$pending[0].SerialNumber) 'the untouched proposal remains'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the kiosk command claim delivers exactly once' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'queue'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Invoke-DbNonQuery -Sql @"
INSERT INTO kiosk_commands(ip_address, cmd, nonce, delay_sec, queued_at, queued_unix)
VALUES ('10.0.0.20','reboot',1001,5,'2026-09-08T10:00:00Z',1757325600);
"@ | Out-Null

        $claimSql = @"
DELETE FROM kiosk_commands
 WHERE id = (SELECT id FROM kiosk_commands WHERE ip_address = @ip ORDER BY id LIMIT 1)
RETURNING id, ip_address AS ip, cmd, nonce, delay_sec AS delaySec, queued_at AS queuedAt, queued_unix;
"@
        $first  = @(Invoke-DbQuery -Sql $claimSql -Parameters @{ ip = '10.0.0.20' })
        $second = @(Invoke-DbQuery -Sql $claimSql -Parameters @{ ip = '10.0.0.20' })

        Add-TestEvidence ("first claim: {0} row(s); second claim: {1} row(s)" -f $first.Count, $second.Count)
        Assert-Equal 1 $first.Count  'the first claimer gets the command'
        Assert-Equal 0 $second.Count 'the second claimer gets nothing'
        Assert-Equal 'reboot' ([string]$first[0].cmd) 'the claimed command'
        Assert-Equal 1001 ([int]$first[0].nonce) 'the claimed nonce'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Integrity and backup
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'integrity check passes on a healthy database' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'integrity'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $quick = Test-DatabaseIntegrity -Quick
        $full  = Test-DatabaseIntegrity
        Add-TestEvidence ("quick: {0}; full: {1}" -f ($quick.Messages -join ','), ($full.Messages -join ','))
        Assert-True $quick.Ok 'quick_check reports ok'
        Assert-True $full.Ok  'integrity_check reports ok'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'backup writes a usable snapshot and rotates old ones' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'backup'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Set-DbKeyValue -Key 'marker' -Value @{ n = 7 }

        $path = Backup-Database -Keep 2
        Assert-NotNull $path 'the backup path'
        Assert-FileExists $path 'the backup file'
        Add-TestEvidence ("backup: {0} ({1} bytes)" -f (Split-Path -Leaf $path), (Get-Item -LiteralPath $path).Length)

        # A VACUUM INTO snapshot must be a valid, readable database.
        $probe = New-Object System.Data.SQLite.SQLiteConnection(("Data Source={0};Version=3;Pooling=False;Read Only=True" -f $path))
        $probe.Open()
        $cmd = $probe.CreateCommand()
        $cmd.CommandText = "SELECT value_json FROM app_kv WHERE key='marker';"
        $value = [string]$cmd.ExecuteScalar()
        $cmd.Dispose(); $probe.Close(); $probe.Dispose()
        Add-TestEvidence ("value read back from the backup: {0}" -f $value)
        Assert-Match $value '7' 'the backup carries the data written before it'

        # Rotation: keep only the newest N.
        for ($i = 0; $i -lt 3; $i++) { Start-Sleep -Milliseconds 1100; Backup-Database -Keep 2 | Out-Null }
        $kept = @(Get-ChildItem -LiteralPath $sandbox.BackupFolder -Filter 'vrhm_*.db')
        Add-TestEvidence ("backups kept: {0}" -f $kept.Count)
        Assert-True ($kept.Count -le 2) 'rotation keeps at most the requested number'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a corrupt database is replaced from the newest good backup' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'corrupt'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Set-DbKeyValue -Key 'survivor' -Value @{ n = 99 }
        Backup-Database -Keep 3 | Out-Null
        Close-DbConnection -Checkpoint

        # Overwrite the header with garbage: SQLite rejects the file outright.
        $bytes = [byte[]](1..200 | ForEach-Object { 0xEE })
        [System.IO.File]::WriteAllBytes($sandbox.DatabasePath, $bytes)
        foreach ($s in @("$($sandbox.DatabasePath)-wal", "$($sandbox.DatabasePath)-shm")) {
            if (Test-Path -LiteralPath $s) { Remove-Item -LiteralPath $s -Force }
        }

        $result = Initialize-Database -Role Main -SkipBackup
        Add-TestEvidence ("restored: {0}; integrity messages: {1}" -f $result.Restored, ($result.Integrity.Messages -join ','))
        Assert-True $result.Ok 'initialization recovered'
        Assert-True $result.Restored 'a backup was restored'

        $back = Get-DbKeyValue -Key 'survivor'
        Assert-NotNull $back 'data recovered from the backup'
        Assert-Equal 99 ([int]$back.n) 'the recovered value'

        $aside = @(Get-ChildItem -LiteralPath $sandbox.DataFolder -Filter 'vrhm.db.corrupt_*')
        Add-TestEvidence ("corrupt copies kept aside: {0}" -f $aside.Count)
        Assert-True ($aside.Count -ge 1) 'the corrupt file was preserved for diagnosis, not deleted'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
