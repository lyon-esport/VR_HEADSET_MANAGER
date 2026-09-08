####################################################################
### EMBEDDED DATABASE (SQLite) - THE ONLY SQLite-AWARE MODULE     ###
####################################################################
#
# This module is the single data-access layer for the application. NO other
# module, script or web handler may reference a System.Data.SQLite type or
# pass raw -Sql: domain modules call Invoke-DbQuery / Invoke-DbNonQuery /
# Invoke-DbScalar / Invoke-DbTransaction / Invoke-DbBatch with a -Name that
# resolves to a file under modules\db\queries\.
# scripts\dbTests\Test-DbStatic.ps1 enforces that boundary.
#
# Engine: System.Data.SQLite (x64, .NET Framework build) vendored under
# sources\sqlite\<version>\ and selected by config.database.folder, following
# the one-folder-per-binary-version rule (ADR-0011).
#
# Concurrency model
# -----------------
# The app runs one connection PER PROCESS AND PER RUNSPACE - never shared.
# All state below lives in $script: scope; because every runspace dot-sources
# this file itself, $script: is naturally per-runspace. A connection carries
# the runspace InstanceId it was opened on and Get-DbConnection throws if it
# is reached from another one, so the worst silent failure mode (a native
# handle used across threads) becomes a loud, immediate error.
#
# Writers are serialised by SQLite itself: WAL journal + BusyTimeout +
# BEGIN IMMEDIATE (never a read-to-write upgrade, which yields
# SQLITE_BUSY_SNAPSHOT) + a retry wrapper around whole transactions.
#
# File I/O rules of ADR-0006 apply here as everywhere: -LiteralPath on every
# call, -Encoding UTF8 on every read, Write-FileWithoutBom on every write.
# ASCII only in string literals (ADR-0007).
####################################################################


# -------------------------------------------------------------------
# Internal state (per process AND per runspace - see header)
# -------------------------------------------------------------------
$script:DbConn            = $null   # the live SQLiteConnection
$script:DbConnRunspaceId  = $null   # runspace that opened it (foreign-use guard)
$script:DbConnPath        = $null   # database file the connection points at
$script:DbPrepared        = @{}     # query name -> prepared SQLiteCommand
$script:DbQueryText       = @{}     # query name -> SQL text (read once from disk)
$script:DbTransaction     = $null   # active SQLiteTransaction (nesting joins it)
$script:DbTransactionDepth = 0
$script:DbAssemblyLoaded  = $false
$script:DbBusyWarned      = $false  # WARNING once per contention burst


# -------------------------------------------------------------------
# Logging shim
#
# Write-Log needs $global:debugLevelToConsole / $global:logFile, which are set
# by Get-Config. This module is also exercised by scripts\dbTests\ outside a
# configured app, so route through a shim that degrades to Write-Verbose
# rather than throwing where the logging globals are absent.
# -------------------------------------------------------------------
function Write-DbLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    if ((Get-Command Write-Log -ErrorAction SilentlyContinue) -and $global:debugLevelToConsole) {
        try { Write-Log $Message -Level $Level; return } catch { }
    }
    Write-Verbose ("[{0}] {1}" -f $Level, $Message)
}


# -------------------------------------------------------------------
# Boolean conversion
#
# The CSV era stored booleans as the strings "True"/"False" and every consumer
# reads them through ConvertTo-BoolField. The database stores INTEGER 0/1, and
# the views convert back to those strings on the way out, so ConvertTo-BoolField
# and every existing comparison keep working untouched.
# -------------------------------------------------------------------

# ConvertTo-DbBool "True" -> 1 ; ConvertTo-DbBool $false -> 0
function ConvertTo-DbBool {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $(if ($Default) { 1 } else { 0 }) }
    if ($Value -is [bool]) { return $(if ($Value) { 1 } else { 0 }) }
    $s = ([string]$Value).Trim()
    if ($s.Length -eq 0) { return $(if ($Default) { 1 } else { 0 }) }
    if ($s -eq '1') { return 1 }
    if ($s -eq '0') { return 0 }
    if ([string]::Equals($s, 'True', [System.StringComparison]::OrdinalIgnoreCase)) { return 1 }
    return 0
}

# ConvertFrom-DbBool 1 -> "True". Use only where a view cannot do it.
function ConvertFrom-DbBool {
    param($Value)
    if ((ConvertTo-DbBool $Value) -eq 1) { return 'True' }
    return 'False'
}


# -------------------------------------------------------------------
# Assembly loading
# -------------------------------------------------------------------

<#
.SYNOPSIS
    Loads System.Data.SQLite into this process. Idempotent.
.DESCRIPTION
    Refuses a 32-bit host (the vendored interop is x64 only), clears the
    Mark-Of-The-Web from both DLLs (a blocked assembly fails with a
    loadFromRemoteSources error that names nothing useful), then LoadFrom the
    managed assembly. LoadFrom takes a plain string, so the accented project
    root is not a problem - it is -Path wildcard expansion that breaks on it,
    not .NET (ADR-0006).
    PreLoadSQLite_BaseDirectory tells System.Data.SQLite where to find
    x64\SQLite.Interop.dll regardless of the process working directory.
.EXAMPLE
    Import-DatabaseAssembly
#>
function Import-DatabaseAssembly {
    if ($script:DbAssemblyLoaded) { return $true }

    # Another dot-source cycle in the same process may already have loaded it.
    $already = [AppDomain]::CurrentDomain.GetAssemblies() |
               Where-Object { $_.GetName().Name -eq 'System.Data.SQLite' } |
               Select-Object -First 1
    if ($already) {
        $script:DbAssemblyLoaded = $true
        return $true
    }

    if (-not [Environment]::Is64BitProcess) {
        throw "VR HEADSET MANAGER requires 64-bit PowerShell: the bundled SQLite interop library is x64 only."
    }

    $asmPath = $global:databaseAssemblyPath
    $intPath = $global:databaseInteropPath
    if ([string]::IsNullOrWhiteSpace($asmPath)) {
        throw "Database assembly path is not set. Get-Config must run before Initialize-Database."
    }
    if (-not (Test-Path -LiteralPath $asmPath)) {
        throw ("SQLite assembly not found at '{0}'. Check config.database.folder and that the sources\sqlite folder shipped with this release." -f $asmPath)
    }
    if (-not (Test-Path -LiteralPath $intPath)) {
        throw ("SQLite interop library not found at '{0}'. The x64 subfolder must sit next to System.Data.SQLite.dll." -f $intPath)
    }

    # Strip MOTW. Harmless when absent; essential on a freshly unzipped release.
    foreach ($dll in @($asmPath, $intPath)) {
        try { Unblock-File -LiteralPath $dll -ErrorAction SilentlyContinue } catch { }
    }

    $env:PreLoadSQLite_BaseDirectory = $global:databaseFolder

    try {
        [System.Reflection.Assembly]::LoadFrom($asmPath) | Out-Null
    } catch {
        throw ("Failed to load the SQLite assembly from '{0}': {1}" -f $asmPath, $_.Exception.Message)
    }

    # DELETE ... RETURNING (the deliver-once kiosk command claim) needs 3.35+.
    $engine = [System.Data.SQLite.SQLiteConnection]::SQLiteVersion
    $global:databaseEngineVersion = $engine
    $parts = $engine.Split('.')
    $major = [int]$parts[0]
    $minor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
    if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 35)) {
        throw ("SQLite engine {0} is too old: 3.35 or newer is required (RETURNING support)." -f $engine)
    }

    $script:DbAssemblyLoaded = $true
    Write-DbLog ("SQLite engine {0} loaded from {1}" -f $engine, $global:databaseFolder) -Level DEBUG
    return $true
}


# -------------------------------------------------------------------
# Connection management
# -------------------------------------------------------------------

function Get-DbConnectionString {
    param([string]$DatabasePath = $global:databaseFilePath)
    $busy = if ($global:databaseBusyTimeoutMs) { [int]$global:databaseBusyTimeoutMs } else { 5000 }
    # Pooling=False is deliberate: pooled connections are shared by connection
    # string, which is exactly the cross-runspace sharing this module forbids.
    return ("Data Source={0};Version=3;Journal Mode=WAL;Synchronous=Normal;Foreign Keys=True;BusyTimeout={1};Pooling=False;DateTimeKind=Utc;DateTimeFormat=ISO8601" -f $DatabasePath, $busy)
}

<#
.SYNOPSIS
    Returns this runspace's SQLite connection, opening it on first use.
.DESCRIPTION
    Throws if called from a runspace other than the one that opened the
    connection - a native SQLite handle used across threads corrupts memory
    silently, so this turns it into an immediate, named error.
.EXAMPLE
    $conn = Get-DbConnection
#>
function Get-DbConnection {
    param([string]$DatabasePath = $global:databaseFilePath)

    if ($script:DbConn -and $script:DbConn.State -eq 'Open') {
        $currentRs = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId
        if ($script:DbConnRunspaceId -ne $currentRs) {
            throw ("Database connection opened on runspace {0} was reached from runspace {1}. Every runspace must open its own connection." -f $script:DbConnRunspaceId, $currentRs)
        }
        return $script:DbConn
    }

    Import-DatabaseAssembly | Out-Null

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        throw "Database file path is not set. Get-Config must run before any database call."
    }
    $dbFolder = Split-Path -Parent $DatabasePath
    if ($dbFolder -and -not (Test-Path -LiteralPath $dbFolder)) {
        New-Item -ItemType Directory -Path $dbFolder -Force | Out-Null
    }

    $conn = New-Object System.Data.SQLite.SQLiteConnection((Get-DbConnectionString -DatabasePath $DatabasePath))
    $conn.Open()

    # WAL is a persistent property of the file, the rest are per-connection.
    $pragma = $conn.CreateCommand()
    $pragma.CommandText = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;"
    $pragma.ExecuteNonQuery() | Out-Null
    $pragma.Dispose()

    $script:DbConn           = $conn
    $script:DbConnPath       = $DatabasePath
    $script:DbConnRunspaceId = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId
    $script:DbPrepared       = @{}   # prepared commands are bound to a connection
    return $script:DbConn
}

<#
.SYNOPSIS
    Closes this runspace's connection and disposes every prepared command.
.DESCRIPTION
    -Checkpoint additionally folds the WAL back into the main database file
    (TRUNCATE), which the main process does on shutdown so the release folder
    is left with a single clean .db and no -wal/-shm sidecars.
.EXAMPLE
    Close-DbConnection -Checkpoint
#>
function Close-DbConnection {
    param([switch]$Checkpoint)

    if ($script:DbTransaction) {
        try { $script:DbTransaction.Rollback() } catch { }
        $script:DbTransaction = $null
        $script:DbTransactionDepth = 0
    }

    foreach ($cmd in $script:DbPrepared.Values) {
        try { $cmd.Dispose() } catch { }
    }
    $script:DbPrepared = @{}

    if ($script:DbConn) {
        if ($Checkpoint -and $script:DbConn.State -eq 'Open') {
            try {
                $c = $script:DbConn.CreateCommand()
                $c.CommandText = "PRAGMA wal_checkpoint(TRUNCATE);"
                $c.ExecuteNonQuery() | Out-Null
                $c.Dispose()
            } catch {
                Write-DbLog ("WAL checkpoint failed on close: {0}" -f $_.Exception.Message) -Level DEBUG
            }
        }
        try { $script:DbConn.Close() } catch { }
        try { $script:DbConn.Dispose() } catch { }
    }

    $script:DbConn           = $null
    $script:DbConnRunspaceId = $null
    $script:DbConnPath       = $null
}


# -------------------------------------------------------------------
# Named queries (the "stored procedure" substitute)
#
# SQLite has no stored procedures. The equivalent here is one .sql file per
# operation under modules\db\queries\, loaded once and kept as a PREPARED
# SQLiteCommand for the life of the connection: subsequent calls only rebind
# parameter values, so the parse/plan cost is paid once per runspace.
# -------------------------------------------------------------------

function Get-DbQueryFolder {
    return (Join-Path -Path (Join-Path -Path $global:ScriptPath -ChildPath "modules") -ChildPath (Join-Path "db" "queries"))
}

function Get-DbSchemaFolder {
    return (Join-Path -Path (Join-Path -Path $global:ScriptPath -ChildPath "modules") -ChildPath (Join-Path "db" "schema"))
}

<#
.SYNOPSIS
    Returns the SQL text of a named query, caching it after the first read.
.EXAMPLE
    Get-DbNamedQuery -Name 'headsets.list'
#>
function Get-DbNamedQuery {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($script:DbQueryText.ContainsKey($Name)) { return $script:DbQueryText[$Name] }

    if ($Name -notmatch '^[a-z0-9_]+\.[a-z0-9_]+$') {
        throw ("Invalid query name '{0}'. Expected <area>.<name>, lowercase letters, digits and underscores." -f $Name)
    }
    $path = Join-Path -Path (Get-DbQueryFolder) -ChildPath ("{0}.sql" -f $Name)
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("Named query '{0}' not found at '{1}'." -f $Name, $path)
    }
    $sql = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $script:DbQueryText[$Name] = $sql
    return $sql
}

# Returns a prepared, parameter-bound SQLiteCommand for a named query, or a
# throwaway command when raw -Sql was supplied (importer / migrations only).
function Get-DbCommand {
    param(
        [string]$Name,
        [string]$Sql,
        [hashtable]$Parameters
    )
    $conn = Get-DbConnection

    if ($Name) {
        if (-not $script:DbPrepared.ContainsKey($Name)) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = Get-DbNamedQuery -Name $Name
            $cmd.Prepare()
            $script:DbPrepared[$Name] = $cmd
        }
        $cmd = $script:DbPrepared[$Name]
        $cmd.Parameters.Clear()
    } else {
        if ([string]::IsNullOrWhiteSpace($Sql)) {
            throw "Either -Name or -Sql must be supplied."
        }
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
    }

    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($null -eq $value) { $value = [System.DBNull]::Value }
            $pname = if ($key.StartsWith('@')) { $key } else { '@' + $key }
            $cmd.Parameters.AddWithValue($pname, $value) | Out-Null
        }
    }

    # The active transaction must be attached or the statement runs outside it.
    if ($script:DbTransaction) { $cmd.Transaction = $script:DbTransaction }
    return $cmd
}


# -------------------------------------------------------------------
# Retry wrapper
#
# SQLITE_BUSY / SQLITE_LOCKED survive the connection BusyTimeout in two cases
# this app really hits: a writer waiting behind another writer's transaction,
# and a snapshot conflict from a read-then-write upgrade. Retrying the WHOLE
# unit of work (never a statement inside an open transaction) is the only
# correct response.
# -------------------------------------------------------------------
function Invoke-DbWithRetry {
    # NOTE the parameter name. PowerShell looks variables up dynamically at
    # scriptblock INVOCATION time, so if this parameter were called $Script,
    # a caller whose own block also references $Script would resolve it to
    # THIS function's parameter - which is that same block - and re-enter
    # itself. That produced "cannot start a transaction within a transaction"
    # from Invoke-DbTransaction. Keep these names distinct.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Operation = 'database operation'
    )

    # Inside an open transaction the retry unit is the whole transaction, not
    # one statement: replaying a single statement would corrupt the batch.
    if ($script:DbTransaction) { return & $Action }

    $max = if ($global:databaseRetryMax) { [int]$global:databaseRetryMax } else { 6 }
    $attempt = 0
    while ($true) {
        try {
            $result = & $Action
            if ($attempt -gt 0) { $script:DbBusyWarned = $false }
            return $result
        } catch {
            $ex = $_.Exception
            $isBusy = $false
            if ($ex -is [System.Data.SQLite.SQLiteException]) {
                $rc = [string]$ex.ResultCode
                if ($rc -eq 'Busy' -or $rc -eq 'Locked' -or $rc -eq 'Busy_Snapshot') { $isBusy = $true }
            }
            if (-not $isBusy -or $attempt -ge $max) { throw }

            $attempt++
            if (-not $script:DbBusyWarned) {
                Write-DbLog ("Database is busy during {0}; retrying (attempt {1}/{2})." -f $Operation, $attempt, $max) -Level WARNING
                $script:DbBusyWarned = $true
            }
            $delay = [Math]::Min(500, 20 * [Math]::Pow(2, $attempt - 1))
            Start-Sleep -Milliseconds $delay
        }
    }
}


# -------------------------------------------------------------------
# Query execution
# -------------------------------------------------------------------

<#
.SYNOPSIS
    Runs a SELECT and returns its rows as PSCustomObject[].
.DESCRIPTION
    Column names come straight from the statement's aliases. Every named query
    aliases to the legacy CSV header names (ID, Name, IPAddress, ...) so callers
    keep the property names they already use. DBNull becomes $null.
    Always wrap the result in @() at the call site: a single row is not an array.
.EXAMPLE
    $rows = @(Invoke-DbQuery -Name 'headsets.list')
    $one  = @(Invoke-DbQuery -Name 'headsets.get_by_id' -Parameters @{ id = 3 })
#>
function Invoke-DbQuery {
    param(
        [string]$Name,
        [string]$Sql,
        [hashtable]$Parameters
    )
    return Invoke-DbWithRetry -Operation ("query {0}" -f $(if ($Name) { $Name } else { 'inline' })) -Action {
        $cmd = Get-DbCommand -Name $Name -Sql $Sql -Parameters $Parameters
        $rows = New-Object System.Collections.Generic.List[object]
        $reader = $cmd.ExecuteReader()
        try {
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $value = $reader.GetValue($i)
                    if ($value -is [System.DBNull]) { $value = $null }
                    $row[$reader.GetName($i)] = $value
                }
                $rows.Add([PSCustomObject]$row) | Out-Null
            }
        } finally {
            $reader.Close()
            $reader.Dispose()
            if (-not $Name) { $cmd.Dispose() }
        }
        return $rows.ToArray()
    }
}

<#
.SYNOPSIS
    Runs a statement that returns no rows; returns the affected row count.
.EXAMPLE
    Invoke-DbNonQuery -Name 'headsets.delete' -Parameters @{ id = 3 }
#>
function Invoke-DbNonQuery {
    param(
        [string]$Name,
        [string]$Sql,
        [hashtable]$Parameters
    )
    return Invoke-DbWithRetry -Operation ("nonquery {0}" -f $(if ($Name) { $Name } else { 'inline' })) -Action {
        $cmd = Get-DbCommand -Name $Name -Sql $Sql -Parameters $Parameters
        try {
            return $cmd.ExecuteNonQuery()
        } finally {
            if (-not $Name) { $cmd.Dispose() }
        }
    }
}

<#
.SYNOPSIS
    Returns the first column of the first row, or $null.
.EXAMPLE
    $n = Invoke-DbScalar -Name 'headsets.next_id'
#>
function Invoke-DbScalar {
    param(
        [string]$Name,
        [string]$Sql,
        [hashtable]$Parameters
    )
    return Invoke-DbWithRetry -Operation ("scalar {0}" -f $(if ($Name) { $Name } else { 'inline' })) -Action {
        $cmd = Get-DbCommand -Name $Name -Sql $Sql -Parameters $Parameters
        try {
            $value = $cmd.ExecuteScalar()
            if ($value -is [System.DBNull]) { return $null }
            return $value
        } finally {
            if (-not $Name) { $cmd.Dispose() }
        }
    }
}

<#
.SYNOPSIS
    Runs a scriptblock inside one BEGIN IMMEDIATE transaction.
.DESCRIPTION
    IMMEDIATE takes the writer lock up front instead of upgrading a read
    later, which is what produces SQLITE_BUSY_SNAPSHOT under concurrency.
    A nested call joins the outer transaction rather than starting a second
    one. The retry wrapper sits OUTSIDE the transaction, so a busy database
    replays the whole block, never half of it.
.EXAMPLE
    Invoke-DbTransaction -Script {
        Invoke-DbNonQuery -Name 'headsets.release_ip' -Parameters @{ id = 2 }
        Invoke-DbNonQuery -Name 'headsets.set_ip'     -Parameters @{ id = 5; ip = '192.168.1.44' }
    }
#>
function Invoke-DbTransaction {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)

    if ($script:DbTransaction) {
        # Nested: join the outer transaction. The outermost call commits.
        $script:DbTransactionDepth++
        try {
            return & $Script
        } finally {
            $script:DbTransactionDepth--
        }
    }

    # Bind the caller's block to a distinctly named local. The wrapper below
    # is invoked from inside Invoke-DbWithRetry, and a variable named $Script
    # would resolve to that function's own parameter (see the note there).
    $userScript = $Script

    return Invoke-DbWithRetry -Operation 'transaction' -Action {
        $conn = Get-DbConnection
        # Serializable maps to BEGIN IMMEDIATE in System.Data.SQLite: take the
        # write lock now instead of upgrading a read later, which is what
        # yields SQLITE_BUSY_SNAPSHOT under concurrency. Using the ADO.NET
        # object (rather than raw BEGIN text) also gives us a handle to store,
        # so nested calls are detected and commands can be attached to it.
        $txn = $conn.BeginTransaction([System.Data.IsolationLevel]::Serializable)
        $script:DbTransaction      = $txn
        $script:DbTransactionDepth = 1
        try {
            $result = & $userScript
            $txn.Commit()
            return $result
        } catch {
            try { $txn.Rollback() } catch { }
            throw
        } finally {
            try { $txn.Dispose() } catch { }
            $script:DbTransaction      = $null
            $script:DbTransactionDepth = 0
        }
    }
}

<#
.SYNOPSIS
    Executes one named statement once per row, all inside a single transaction.
.DESCRIPTION
    The bulk path for the hot writers: the 500 ms status export, the installed
    apps replace, the app catalogue resolve. One prepared statement, one
    transaction, one fsync - instead of N of each.
.EXAMPLE
    Invoke-DbBatch -Name 'status.upsert' -Rows $infoRows
#>
function Invoke-DbBatch {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Rows
    )
    if ($Rows.Count -eq 0) { return 0 }

    # Bind to distinctly named locals: scriptblocks resolve variables against
    # the runtime scope chain, so a name shared with a function further down
    # the chain would shadow ours (see the note in Invoke-DbWithRetry).
    $batchName = $Name
    $batchRows = $Rows

    return Invoke-DbTransaction -Script {
        $count = 0
        foreach ($row in $batchRows) {
            $params = $row
            if ($row -isnot [hashtable]) {
                # Accept PSCustomObject rows too, so callers can pass records straight through.
                $params = @{}
                foreach ($p in $row.PSObject.Properties) { $params[$p.Name] = $p.Value }
            }
            $count += Invoke-DbNonQuery -Name $batchName -Parameters $params
        }
        return $count
    }
}


# -------------------------------------------------------------------
# Change counters
#
# db_versions holds one counter per table, bumped by triggers on every
# insert/update/delete. It replaces the file-mtime caches the web server used
# to keep: one cheap scalar read tells a caller whether its cached copy is
# still current.
# -------------------------------------------------------------------

<#
.SYNOPSIS
    Returns the change counter of one table. Use it to invalidate caches.
.EXAMPLE
    $v = Get-DbTableVersion -Name 'headsets'
#>
function Get-DbTableVersion {
    param([Parameter(Mandatory = $true)][string]$Name)
    $value = Invoke-DbScalar -Name 'meta.table_version' -Parameters @{ name = $Name }
    if ($null -eq $value) { return 0 }
    return [int64]$value
}


# -------------------------------------------------------------------
# Key/value store (app_kv)
#
# Snapshot-shaped state that was previously one JSON file each: fw_state,
# computer_monitoring, vqa_recommendation / originals / applied / cooldown,
# legacy_import_log. Stored as JSON text so the shapes stay exactly what the
# existing readers expect.
# -------------------------------------------------------------------

<#
.SYNOPSIS
    Reads one app_kv entry and returns the parsed object.
.EXAMPLE
    $fw = Get-DbKeyValue -Key 'fw_state'
#>
function Get-DbKeyValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        $Default = $null
    )
    $json = Invoke-DbScalar -Name 'kv.get' -Parameters @{ key = $Key }
    if ($null -eq $json -or [string]::IsNullOrWhiteSpace([string]$json)) { return $Default }
    try {
        return ([string]$json | ConvertFrom-Json)
    } catch {
        Write-DbLog ("app_kv entry '{0}' is not valid JSON: {1}" -f $Key, $_.Exception.Message) -Level WARNING
        return $Default
    }
}

<#
.SYNOPSIS
    Writes one app_kv entry (insert or replace).
.EXAMPLE
    Set-DbKeyValue -Key 'computer_monitoring' -Value $snapshot
#>
function Set-DbKeyValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 20
    )
    $json = if ($Value -is [string]) { $Value } else { ($Value | ConvertTo-Json -Depth $Depth -Compress) }
    Invoke-DbNonQuery -Name 'kv.set' -Parameters @{ key = $Key; value_json = $json } | Out-Null
}

<#
.SYNOPSIS
    Deletes one app_kv entry.
.EXAMPLE
    Remove-DbKeyValue -Key 'vqa_cooldown'
#>
function Remove-DbKeyValue {
    param([Parameter(Mandatory = $true)][string]$Key)
    Invoke-DbNonQuery -Name 'kv.delete' -Parameters @{ key = $Key } | Out-Null
}


# -------------------------------------------------------------------
# Integrity and backup
# -------------------------------------------------------------------

<#
.SYNOPSIS
    Runs PRAGMA quick_check (default) or integrity_check.
.OUTPUTS
    @{ Ok = [bool]; Messages = @() }
.EXAMPLE
    $r = Test-DatabaseIntegrity -Quick
#>
function Test-DatabaseIntegrity {
    param([switch]$Quick)
    $pragma = if ($Quick) { "PRAGMA quick_check;" } else { "PRAGMA integrity_check;" }
    try {
        $rows = @(Invoke-DbQuery -Sql $pragma)
        # The single result column is named quick_check or integrity_check
        # depending on the pragma, so read the first property by position
        # rather than by name.
        $messages = @($rows | ForEach-Object {
            $props = @($_.PSObject.Properties)
            if ($props.Count -gt 0) { [string]$props[0].Value } else { '' }
        })
        $ok = ($messages.Count -eq 1 -and $messages[0] -eq 'ok')
        return @{ Ok = $ok; Messages = $messages }
    } catch {
        return @{ Ok = $false; Messages = @($_.Exception.Message) }
    }
}

function Get-DbBackupFolder {
    return (Join-Path -Path (Join-Path -Path $global:ScriptPath -ChildPath "data") -ChildPath "backup")
}

<#
.SYNOPSIS
    Writes a consistent single-file snapshot to data\backup\ and rotates old ones.
.DESCRIPTION
    VACUUM INTO produces one clean file with no -wal sidecar, safe to copy while
    the app runs. Returns the backup path, or $null on failure (never throws:
    a failed backup must not stop the application from starting).
.EXAMPLE
    Backup-Database -Keep 5
#>
function Backup-Database {
    param([int]$Keep = 0)
    if ($Keep -le 0) {
        $Keep = if ($global:databaseBackupKeep) { [int]$global:databaseBackupKeep } else { 5 }
    }
    try {
        $folder = Get-DbBackupFolder
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        $stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
        $target = Join-Path -Path $folder -ChildPath ("vrhm_{0}.db" -f $stamp)
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }

        # VACUUM INTO cannot run inside a transaction and takes no parameters.
        Invoke-DbNonQuery -Sql ("VACUUM INTO '{0}';" -f $target.Replace("'", "''")) | Out-Null

        $old = @(Get-ChildItem -LiteralPath $folder -Filter "vrhm_*.db" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
        foreach ($f in $old) {
            try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
        }
        Write-DbLog ("Database backup written to {0}" -f $target) -Level DEBUG
        return $target
    } catch {
        Write-DbLog ("Database backup failed: {0}" -f $_.Exception.Message) -Level WARNING
        return $null
    }
}


# -------------------------------------------------------------------
# Schema creation and migration
#
# modules\db\schema\NNN_*.sql, applied in numeric order inside one transaction
# each, recorded in schema_version, with PRAGMA user_version tracking the
# highest applied number. Worker processes assert user_version instead of
# migrating, so a stale module set cannot half-migrate a live database.
# -------------------------------------------------------------------

function Get-DbSchemaFile {
    $folder = Get-DbSchemaFolder
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $folder -Filter "*.sql" |
             Where-Object { $_.Name -match '^(\d{3})_[a-z0-9_]+\.sql$' } |
             Sort-Object Name)
}

function Get-DbSchemaVersionOnDisk {
    # @() at the CALL site: PowerShell unrolls a single-element array on
    # return, so a lone migration file would arrive here as a scalar with no
    # .Count - which throws under Set-StrictMode.
    $files = @(Get-DbSchemaFile)
    if ($files.Count -eq 0) { return 0 }
    $last = $files[$files.Count - 1].Name
    if ($last -match '^(\d{3})_') { return [int]$Matches[1] }
    return 0
}

function Get-DbUserVersion {
    $v = Invoke-DbScalar -Sql "PRAGMA user_version;"
    if ($null -eq $v) { return 0 }
    return [int]$v
}

<#
.SYNOPSIS
    Applies every pending schema migration, in order. Idempotent.
.OUTPUTS
    The schema version after migrating.
.EXAMPLE
    Update-DatabaseSchema
#>
function Update-DatabaseSchema {
    $current = Get-DbUserVersion
    $files   = @(Get-DbSchemaFile)   # see the note in Get-DbSchemaVersionOnDisk
    if ($files.Count -eq 0) {
        throw ("No schema files found under '{0}'." -f (Get-DbSchemaFolder))
    }

    foreach ($file in $files) {
        if ($file.Name -notmatch '^(\d{3})_') { continue }
        $version = [int]$Matches[1]
        if ($version -le $current) { continue }

        $sql = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        Write-DbLog ("Applying database schema migration {0}" -f $file.Name) -Level INFO
        # Each migration is one transaction: a failure leaves the previous
        # version intact rather than a half-built schema.
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Sql $sql | Out-Null
            Invoke-DbNonQuery -Sql ("INSERT OR REPLACE INTO schema_version(version) VALUES ({0});" -f $version) | Out-Null
        } | Out-Null
        # PRAGMA user_version cannot be parameterised and must sit outside the
        # transaction body above for SQLite to persist it reliably.
        Invoke-DbNonQuery -Sql ("PRAGMA user_version = {0};" -f $version) | Out-Null
        $current = $version
    }
    return $current
}


# -------------------------------------------------------------------
# Initialization
# -------------------------------------------------------------------

<#
.SYNOPSIS
    Opens (and for -Role Main, creates/migrates/verifies) the application database.
.DESCRIPTION
    Role Main  - the console process. Creates or migrates the schema, verifies
                 integrity (restoring the newest good backup if the file is
                 corrupt), and takes a startup backup.
    Role Worker- every other context: the VRMonitor job, the web server, the
                 dashboard, each poll runspace, each child job. Opens the
                 connection and asserts the schema version matches this module
                 set. Never migrates, never truncates.
.OUTPUTS
    @{ Ok; Role; SchemaVersion; Integrity; Backup; Restored; Error }
.EXAMPLE
    Initialize-Database -Role Main
    Initialize-Database -Role Worker
#>
function Initialize-Database {
    param(
        [ValidateSet('Main', 'Worker')][string]$Role = 'Worker',
        [string]$DatabasePath = $global:databaseFilePath,
        [switch]$SkipBackup
    )

    $result = @{
        Ok = $false; Role = $Role; SchemaVersion = 0
        Integrity = $null; Backup = $null; Restored = $false; Error = $null
    }

    try {
        Import-DatabaseAssembly | Out-Null

        if ($Role -eq 'Main') {
            $existed = Test-Path -LiteralPath $DatabasePath

            # Opening is itself a corruption test: SQLite validates the file
            # header on Open and throws "file is not a database" for a
            # truncated or overwritten file, before any pragma can run. So
            # the open must be inside the recovery path, not before it.
            $openFailed = $false
            try {
                Get-DbConnection -DatabasePath $DatabasePath | Out-Null
            } catch {
                if (-not $existed) { throw }
                $openFailed = $true
                $result.Integrity = @{ Ok = $false; Messages = @($_.Exception.Message) }
                Write-DbLog ("Database could not be opened: {0}" -f $_.Exception.Message) -Level ERROR
            }

            # A file that opens can still be internally damaged.
            if ($existed -and -not $openFailed) {
                $quick = ($global:databaseIntegrityCheck -ne 'full')
                $check = Test-DatabaseIntegrity -Quick:$quick
                $result.Integrity = $check
                if (-not $check.Ok) {
                    Write-DbLog ("Database integrity check FAILED: {0}" -f ($check.Messages -join '; ')) -Level ERROR
                }
            }

            if ($existed -and $result.Integrity -and -not $result.Integrity.Ok) {
                $restored = Restore-DatabaseFromBackup -DatabasePath $DatabasePath
                $result.Restored = $restored
                if (-not $restored) {
                    Write-DbLog "No usable backup found; starting from an empty database. Re-import headsets from a CSV export if needed." -Level ERROR
                    # Move the unusable file aside so a fresh one can be built.
                    Close-DbConnection
                    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    if (Test-Path -LiteralPath $DatabasePath) {
                        try { Move-Item -LiteralPath $DatabasePath -Destination ("{0}.corrupt_{1}" -f $DatabasePath, $stamp) -Force } catch { }
                    }
                    Get-DbConnection -DatabasePath $DatabasePath | Out-Null
                }
            }

            $result.SchemaVersion = Update-DatabaseSchema

            if (-not $SkipBackup -and $global:databaseBackupOnStartup) {
                $result.Backup = Backup-Database
            }
        } else {
            # A worker must never CREATE the database: only the main process
            # builds and migrates it. Opening a missing path would silently
            # leave an empty, schema-less file behind that the next main start
            # then has to migrate - and worse, hide the real problem (a worker
            # launched without its parent).
            if (-not (Test-Path -LiteralPath $DatabasePath)) {
                throw ("Database file '{0}' does not exist. A worker process never creates it - start the application through main.ps1." -f $DatabasePath)
            }
            Get-DbConnection -DatabasePath $DatabasePath | Out-Null
            $onDisk  = Get-DbSchemaVersionOnDisk
            $current = Get-DbUserVersion
            if ($current -ne $onDisk) {
                throw ("Database schema version mismatch: file is at {0}, this module set expects {1}. Restart the application so the main process can migrate." -f $current, $onDisk)
            }
            $result.SchemaVersion = $current
        }

        $global:DatabaseReady = $true
        $result.Ok = $true
        Write-DbLog ("Database ready (role {0}, schema {1})" -f $Role, $result.SchemaVersion) -Level DEBUG
    } catch {
        $result.Error = $_.Exception.Message
        $global:DatabaseReady = $false
        Write-DbLog ("Database initialization failed: {0}" -f $result.Error) -Level ERROR
        throw
    }

    return $result
}

# Renames a corrupt database aside and copies the newest backup that passes a
# quick_check into its place. Returns $true when a backup was restored.
function Restore-DatabaseFromBackup {
    param([string]$DatabasePath = $global:databaseFilePath)

    $folder = Get-DbBackupFolder
    if (-not (Test-Path -LiteralPath $folder)) { return $false }
    $backups = @(Get-ChildItem -LiteralPath $folder -Filter "vrhm_*.db" -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) { return $false }

    Close-DbConnection

    $stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
    $corrupt = "{0}.corrupt_{1}" -f $DatabasePath, $stamp
    try {
        if (Test-Path -LiteralPath $DatabasePath) {
            Move-Item -LiteralPath $DatabasePath -Destination $corrupt -Force
            Write-DbLog ("Corrupt database moved aside to {0}" -f $corrupt) -Level WARNING
        }
        foreach ($sidecar in @("$DatabasePath-wal", "$DatabasePath-shm")) {
            if (Test-Path -LiteralPath $sidecar) { Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-DbLog ("Could not move the corrupt database aside: {0}" -f $_.Exception.Message) -Level ERROR
        return $false
    }

    foreach ($backup in $backups) {
        try {
            Copy-Item -LiteralPath $backup.FullName -Destination $DatabasePath -Force
            Get-DbConnection -DatabasePath $DatabasePath | Out-Null
            $check = Test-DatabaseIntegrity -Quick
            if ($check.Ok) {
                Write-DbLog ("Database restored from backup {0}" -f $backup.Name) -Level SUCCESS
                return $true
            }
            Write-DbLog ("Backup {0} is also corrupt; trying an older one." -f $backup.Name) -Level WARNING
            Close-DbConnection
            Remove-Item -LiteralPath $DatabasePath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-DbLog ("Restore from {0} failed: {1}" -f $backup.Name, $_.Exception.Message) -Level WARNING
            Close-DbConnection
        }
    }
    return $false
}
