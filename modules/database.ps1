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

        # Reuse the parameter objects instead of Clear() + AddWithValue.
        #
        # A prepared command keeps its bindings; tearing them down and building
        # new SQLiteParameter objects on every call throws away most of what
        # Prepare() bought. Measured on a 300-row installed-apps replace, the
        # rebuild alone cost 57 ms of 70 ms. Same call, same values, setting
        # .Value on the existing parameters: 13 ms.
        #
        # The set is rebuilt only when it actually differs, which happens the
        # first time a query is used and never again for a given query.
        $reuse = $false
        if ($Parameters -and $cmd.Parameters.Count -eq $Parameters.Count) {
            $reuse = $true
            foreach ($key in $Parameters.Keys) {
                $pname = if ($key.StartsWith('@')) { $key } else { '@' + $key }
                if ($cmd.Parameters.IndexOf($pname) -lt 0) { $reuse = $false; break }
            }
        }
        if ($reuse) {
            foreach ($key in $Parameters.Keys) {
                $value = $Parameters[$key]
                if ($null -eq $value) { $value = [System.DBNull]::Value }
                $pname = if ($key.StartsWith('@')) { $key } else { '@' + $key }
                $cmd.Parameters[$pname].Value = $value
            }
            if ($script:DbTransaction) { $cmd.Transaction = $script:DbTransaction }
            return $cmd
        }
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


<#
.SYNOPSIS
    Drops one named query's cached prepared command, so the next call rebuilds it.
.DESCRIPTION
    Called whenever a statement THROWS. A prepared SQLiteCommand that failed is
    not reusable: its parameter bindings are left in an indeterminate state, and
    every later call on it returns "bad parameter or other API misuse" rather
    than the real error - or rather than succeeding once the cause has passed.

    That turned a transient, self-healing failure into a permanent one. A single
    FOREIGN KEY violation on one status write (a headset removed while the
    monitor still held the previous registry snapshot) poisoned the cached
    status.upsert command, and every subsequent tick failed for the life of the
    process. Live status stopped updating for EVERY headset until a restart.

    Evicting here is what makes Invoke-DbWithRetry able to actually recover.
.EXAMPLE
    Remove-DbPreparedCommand -Name 'status.upsert'
#>
function Remove-DbPreparedCommand {
    param([string]$Name)

    if (-not $Name) { return }
    if (-not $script:DbPrepared.ContainsKey($Name)) { return }
    try { $script:DbPrepared[$Name].Dispose() } catch { }
    $script:DbPrepared.Remove($Name) | Out-Null
}


<#
.SYNOPSIS
    Normalises a batch row (hashtable or PSCustomObject) to a parameter hashtable.
.EXAMPLE
    $params = ConvertTo-DbParameterMap -Row $row
#>
function ConvertTo-DbParameterMap {
    param([Parameter(Mandatory = $true)]$Row)
    if ($Row -is [hashtable]) { return $Row }
    $map = @{}
    foreach ($p in $Row.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
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
        $reader = $null
        try {
            $reader = $cmd.ExecuteReader()

            # Column names and count are fixed for the whole result set, so
            # resolve them ONCE. Calling GetName() per column per row meant 2700
            # interop calls to list one headset's 300 apps, which was most of
            # that query's cost.
            $fieldCount = $reader.FieldCount
            $names = New-Object 'string[]' $fieldCount
            for ($i = 0; $i -lt $fieldCount; $i++) { $names[$i] = $reader.GetName($i) }

            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $fieldCount; $i++) {
                    $value = $reader.GetValue($i)
                    if ($value -is [System.DBNull]) { $value = $null }
                    $row[$names[$i]] = $value
                }
                $rows.Add([PSCustomObject]$row) | Out-Null
            }
        }
        catch {
            # A failed statement leaves its cached prepared command unusable.
            Remove-DbPreparedCommand -Name $Name
            throw
        }
        finally {
            if ($reader) { $reader.Close(); $reader.Dispose() }
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
        }
        catch {
            # A failed statement leaves its cached prepared command unusable.
            Remove-DbPreparedCommand -Name $Name
            throw
        }
        finally {
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
        }
        catch {
            # A failed statement leaves its cached prepared command unusable.
            Remove-DbPreparedCommand -Name $Name
            throw
        }
        finally {
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
        # Resolve the command ONCE and drive it directly, instead of calling
        # Invoke-DbNonQuery per row.
        #
        # This is the bulk path - the installed-apps replace, the catalogue
        # resolve - and per-row it used to pay for three PowerShell function
        # calls and a scriptblock invocation on top of the actual statement. On
        # a 300-row replace that overhead was 92 ms of 162 ms; the whole
        # operation is ~13 ms once it is gone.
        #
        # The retry wrapper is NOT skipped: it sits outside this transaction, as
        # it must, so a SQLITE_BUSY still replays the entire batch.
        $count = 0
        $cmd   = $null
        try {
        foreach ($row in $batchRows) {
            $params = ConvertTo-DbParameterMap -Row $row
            if ($null -eq $cmd) {
                # Establishes the parameter set and attaches the transaction.
                $cmd = Get-DbCommand -Name $batchName -Parameters $params
            } else {
                foreach ($key in $params.Keys) {
                    $value = $params[$key]
                    if ($null -eq $value) { $value = [System.DBNull]::Value }
                    $pname = if ($key.StartsWith('@')) { $key } else { '@' + $key }
                    $index = $cmd.Parameters.IndexOf($pname)
                    if ($index -lt 0) {
                        # A row with a different shape: fall back to the general
                        # path for it rather than binding something wrong.
                        $cmd = Get-DbCommand -Name $batchName -Parameters $params
                        break
                    }
                    $cmd.Parameters[$index].Value = $value
                }
            }
            $count += $cmd.ExecuteNonQuery()
        }
        }
        catch {
            # A failed statement leaves its cached prepared command unusable, and
            # this path holds that command across every row of the batch. Without
            # eviction one bad row - a foreign key violation from a headset
            # removed mid-tick, say - breaks every later call on this query for
            # the life of the process.
            Remove-DbPreparedCommand -Name $batchName
            throw
        }
        return $count
    }
}


# -------------------------------------------------------------------
# Periodic maintenance
#
# Housekeeping that must happen regularly but must NOT sit on a write path.
# Called from the monitor's slow loop, which is the project's existing "long,
# low-priority loop"; it self-throttles so the caller can invoke it freely.
# -------------------------------------------------------------------

# Last run, per process. A worker and the main process each keep their own,
# which is harmless: the work is idempotent and the throttle only exists to
# stop it running every tick.
$script:DbLastMaintenance = $null

<#
.SYNOPSIS
    Runs periodic database housekeeping. Self-throttling and never throws.
.DESCRIPTION
    Currently one job: enforce the metric-history retention window
    (database.metric_history_hours, default 24), across every headset and every
    metric in one DELETE.

    Retention is deliberately NOT enforced by the sampling triggers. A sample is
    taken on every reading change for every headset, so pruning there would put
    a DELETE and a correlated subquery on the monitor's hot write path - and
    that path is one batched transaction covering every headset, so anything
    that throws in it loses the whole tick's status.

    -Force ignores the throttle. Failure is logged and swallowed: housekeeping
    must never take the caller down.
.EXAMPLE
    Invoke-DbMaintenance
.EXAMPLE
    Invoke-DbMaintenance -Force
#>
function Invoke-DbMaintenance {
    param(
        [switch]$Force
    )

    $intervalMin = if ($global:databaseMaintenanceIntervalMin) { [int]$global:databaseMaintenanceIntervalMin } else { 60 }
    if (-not $Force -and $null -ne $script:DbLastMaintenance) {
        if (((Get-Date) - $script:DbLastMaintenance).TotalMinutes -lt $intervalMin) { return $false }
    }
    $script:DbLastMaintenance = Get-Date

    $hours = if ($global:databaseMetricHistoryHours) { [int]$global:databaseMetricHistoryHours } else { 24 }
    if ($hours -le 0) { return $false }

    try {
        # Same ISO-8601 UTC shape the sampling triggers write, so the comparison
        # is a plain string compare against an indexed column.
        $cutoff  = [datetime]::UtcNow.AddHours(-$hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $removed = Invoke-DbNonQuery -Name 'metric.prune' -Parameters @{ cutoff = $cutoff }
        if ($removed -gt 0) {
            Write-Log ("Database maintenance: removed {0} metric sample(s) older than {1}h." -f $removed, $hours) -Level DEBUG
        }
        return $true
    }
    catch {
        Write-Log ("Database maintenance failed: " + $_.Exception.Message) -Level WARNING
        return $false
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


# ===================================================================
# LEGACY IMPORT (one-way cut-over)
#
# The application used to persist ~20 CSV/JSON files under data\. On the
# first startup after the migration these are read into the database and the
# originals are MOVED to data\legacy_<timestamp>\ - never deleted, so an
# operator can always go back and look.
#
# The importer is deliberately tolerant, because the files it meets in the
# field are not the files the current code writes:
#   * some carry a UTF-8 BOM, some do not
#   * known_apps.csv predates the LatestVersion column
#   * <name>_installed_apps.csv predates the SizeBytes column
#   * known_headsets_infos.csv may still be the pre-ADR-0016 20-column shape
#   * per-headset files exist whose headset was removed years ago (orphans)
#   * several of the JSON files may simply not exist yet
# A file it cannot map is left alone and reported, never silently dropped.
#
# It is also idempotent per file: a file that appears later (an operator
# restoring one from a backup) is picked up on the next startup.
# ===================================================================

# Reads a UTF-8 (BOM or not) text file and strips a leading BOM character,
# which Import-Csv would otherwise fold into the first column name.
function Read-LegacyText {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { return '' }
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text
}

# Import-Csv over a legacy file, honouring the delimiter and tolerating a BOM.
# Returns @() for a missing or empty file rather than throwing.
function Import-LegacyCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Delimiter = ','
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $text = Read-LegacyText -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Csv -Delimiter $Delimiter)
}

# Reads a legacy JSON file. Returns $null on missing/empty/unparsable.
function Import-LegacyJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = Read-LegacyText -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

# Reads a property from a legacy row that may not have the column at all
# (older schema), returning $Default in that case.
function Get-LegacyField {
    param($Row, [string]$Name, $Default = '')
    if ($null -eq $Row) { return $Default }
    $prop = $Row.PSObject.Properties[$Name]
    if (-not $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

# Leaf name of a configured legacy path, falling back to the shipped default
# when the path global is not set - which happens whenever VQA is disabled (its
# paths never run through Get-Config) and in the test harness.
#
# Takes the VARIABLE NAME rather than the value: under Set-StrictMode, simply
# mentioning an undefined global throws before the call is even made, so the
# lookup has to go through Get-Variable.
function Get-LegacyFileName {
    param(
        [Parameter(Mandatory = $true)][string]$GlobalName,
        [Parameter(Mandatory = $true)][string]$Default
    )
    $configured = $null
    try { $configured = Get-Variable -Name $GlobalName -Scope Global -ValueOnly -ErrorAction SilentlyContinue } catch { }
    if ([string]::IsNullOrWhiteSpace([string]$configured)) { return $Default }
    try {
        $leaf = Split-Path -Leaf ([string]$configured)
        if ([string]::IsNullOrWhiteSpace($leaf)) { return $Default }
        return $leaf
    } catch { return $Default }
}

# Display name -> the filename stem the CSV era used for per-headset files.
# Mirrors Convert-Displayname in scrcpy_launcher.ps1, reimplemented here so
# the importer does not depend on a module the runspaces may not have loaded.
function ConvertTo-LegacySafeName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace ' ', '_')
}

<#
.SYNOPSIS
    Imports the legacy data\ files into the database, then moves them aside.
.DESCRIPTION
    Each file is imported in its own transaction, so one malformed file cannot
    take the others down with it. Successfully imported originals are moved to
    data\legacy_<timestamp>\ (one folder per run that imported anything).
    An outcome record is written to the app_kv key 'legacy_import_log'.

    Order matters: headsets first, because the per-headset app, favourite and
    timer files are matched to a headset id, and the id is what the new tables
    are keyed on.
.PARAMETER Include
    Restricts the run to named areas. The migration lands one area at a time,
    and a file must NOT be moved aside until the code that reads it has been
    switched to the database - otherwise that code would find nothing.
    Areas: snapshots, vqa, headsets, status, kiosks, discovery, apps, timers.
    Omit to process everything.
.OUTPUTS
    @{ Imported = @(@{File;Rows;Note}); Skipped = @(); Errors = @(); LegacyFolder }
.EXAMPLE
    Import-LegacyDataFiles -WhatIf
    Import-LegacyDataFiles -Include snapshots,vqa
    Import-LegacyDataFiles
#>
function Import-LegacyDataFiles {
    param(
        [string]$DataFolder = (Join-Path -Path $global:ScriptPath -ChildPath 'data'),
        [ValidateSet('snapshots', 'vqa', 'headsets', 'status', 'kiosks', 'discovery', 'apps', 'timers')]
        [string[]]$Include,
        [switch]$WhatIf
    )

    # No filter means every area.
    $wantAll = ($null -eq $Include -or @($Include).Count -eq 0)
    $areas   = @{}
    foreach ($a in @('snapshots', 'vqa', 'headsets', 'status', 'kiosks', 'discovery', 'apps', 'timers')) {
        $areas[$a] = ($wantAll -or ($Include -contains $a))
    }

    $result = @{
        Imported     = New-Object System.Collections.Generic.List[object]
        Skipped      = New-Object System.Collections.Generic.List[object]
        Errors       = New-Object System.Collections.Generic.List[object]
        LegacyFolder = $null
    }
    if (-not (Test-Path -LiteralPath $DataFolder)) { return $result }

    $moved      = New-Object System.Collections.Generic.List[string]
    $stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $legacyRoot = Join-Path -Path $DataFolder -ChildPath ("legacy_{0}" -f $stamp)

    # --- helper: run one file's import, record the outcome ----------------
    function Invoke-LegacyFile {
        param(
            [string]$RelativePath,
            [scriptblock]$Import,
            [switch]$KeepOriginal
        )
        $full = Join-Path -Path $DataFolder -ChildPath $RelativePath
        if (-not (Test-Path -LiteralPath $full)) {
            $result.Skipped.Add(@{ File = $RelativePath; Reason = 'not present' }) | Out-Null
            return
        }
        try {
            $rows = & $Import $full
            if ($null -eq $rows) { $rows = 0 }
            $result.Imported.Add(@{ File = $RelativePath; Rows = [int]$rows }) | Out-Null
            if (-not $KeepOriginal) { $moved.Add($RelativePath) | Out-Null }
        } catch {
            $result.Errors.Add(@{ File = $RelativePath; Error = $_.Exception.Message }) | Out-Null
            Write-DbLog ("Legacy import of '{0}' failed: {1}" -f $RelativePath, $_.Exception.Message) -Level WARNING
        }
    }

    # --- 1. headset registry ---------------------------------------------
    if ($areas['headsets']) {
    Invoke-LegacyFile -RelativePath 'known_headsets.csv' -Import {
        param($path)
        $rows = @(Import-LegacyCsv -Path $path)
        if ($rows.Count -eq 0) { return 0 }
        $batch = @()
        $order = 0
        foreach ($r in $rows) {
            $id = 0
            if (-not [int]::TryParse([string](Get-LegacyField $r 'ID' ''), [ref]$id) -or $id -le 0) { continue }
            $batch += @{
                id                  = $id
                name                = [string](Get-LegacyField $r 'Name' ("Headset {0}" -f $id))
                ip_address          = [string](Get-LegacyField $r 'IPAddress' '')
                scrcpy_auto_restart = (ConvertTo-DbBool (Get-LegacyField $r 'scrcpy_AutoRestart' 'True') -Default $true)
                record              = (ConvertTo-DbBool (Get-LegacyField $r 'Record' 'False'))
                scrcpy_profile      = [string](Get-LegacyField $r 'ScrcpyProfile' '')
                brand               = [string](Get-LegacyField $r 'Brand' '')
                model               = [string](Get-LegacyField $r 'Model' '')
                serial_number       = [string](Get-LegacyField $r 'SerialNumber' '')
                sort_order          = $order
            }
            $order++
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'headsets.upsert' -Rows $batch)
    }
    }

    # Registry now in place: build the name -> id map the per-headset files need.
    $headsetIdByName = @{}
    try {
        foreach ($h in @(Invoke-DbQuery -Name 'headsets.list')) {
            $headsetIdByName[(ConvertTo-LegacySafeName -Name ([string]$h.Name))] = [int]$h.ID
        }
    } catch { }

    # --- 2. live status ----------------------------------------------------
    # Everything here is live and is refreshed within a second of the monitor
    # starting, so this import exists only so a migrating install does not show
    # an empty table for that second. The legacy BatteryHistory column is NOT
    # carried over: those samples are rows in battery_history now (migration
    # 005) and the packed string has no column to land in. Tolerates both the
    # old 15-column shape and the pre-ADR-0016 one with identity columns.
    if ($areas['status']) {
    Invoke-LegacyFile -RelativePath 'known_headsets_infos.csv' -Import {
        param($path)
        $rows = @(Import-LegacyCsv -Path $path -Delimiter ';')
        if ($rows.Count -eq 0) { return 0 }
        $known = @{}
        foreach ($h in @(Invoke-DbQuery -Name 'headsets.list')) { $known[[string]$h.ID] = $true }
        $batch = @()
        foreach ($r in $rows) {
            $id = [string](Get-LegacyField $r 'ID' '')
            if (-not $id -or -not $known.ContainsKey($id)) { continue }
            $batch += @{
                ID                     = $id
                Ping                   = (ConvertTo-DbBool (Get-LegacyField $r 'Ping' 'False'))
                ADBWifi                = (ConvertTo-DbBool (Get-LegacyField $r 'ADBWifi' 'False'))
                Battery                = [string](Get-LegacyField $r 'Battery' '-')
                Charging               = [string](Get-LegacyField $r 'Charging' '-')
                ChargingWattage        = [string](Get-LegacyField $r 'ChargingWattage' '-')
                Temp                   = [string](Get-LegacyField $r 'Temp' '-')
                BatteryControllerLeft  = [string](Get-LegacyField $r 'BatteryControllerLeft' '-')
                BatteryControllerRight = [string](Get-LegacyField $r 'BatteryControllerRight' '-')
                PowerState             = [string](Get-LegacyField $r 'PowerState' '-')
                TimeRemainingMin       = [string](Get-LegacyField $r 'TimeRemainingMin' '-')
                SCRCPY                 = [string](Get-LegacyField $r 'SCRCPY' '-')
                RunningApp             = [string](Get-LegacyField $r 'RunningApp' '-')
                RunningAppIcon         = [string](Get-LegacyField $r 'RunningAppIcon' '')
            }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'status.upsert' -Rows $batch)
    }
    }

    # --- 3. kiosk registry --------------------------------------------------
    if ($areas['kiosks']) {
    Invoke-LegacyFile -RelativePath 'known_kiosks.csv' -Import {
        param($path)
        $rows = @(Import-LegacyCsv -Path $path)
        if ($rows.Count -eq 0) { return 0 }
        $batch = @()
        $order = 0
        foreach ($r in $rows) {
            $id = 0
            if (-not [int]::TryParse([string](Get-LegacyField $r 'ID' ''), [ref]$id) -or $id -le 0) { continue }
            $port = 9222
            [void][int]::TryParse([string](Get-LegacyField $r 'Port' '9222'), [ref]$port)
            $batch += @{
                id             = $id
                name           = [string](Get-LegacyField $r 'Name' ("Kiosk {0}" -f $id))
                ip_address     = [string](Get-LegacyField $r 'IPAddress' '')
                port           = $port
                pushed_url     = [string](Get-LegacyField $r 'PushedURL' '')
                last_pushed_at = [string](Get-LegacyField $r 'LastPushedAt' '')
                sort_order     = $order
            }
            $order++
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'kiosks.upsert' -Rows $batch)
    }

    # --- 4. kiosk agent reports --------------------------------------------
    Invoke-LegacyFile -RelativePath 'kiosks_agent.json' -Import {
        param($path)
        $data = Import-LegacyJson -Path $path
        if ($null -eq $data) { return 0 }
        $batch = @()
        foreach ($r in @($data)) {
            $ip = [string](Get-LegacyField $r 'IPAddress' '')
            if (-not $ip) { continue }
            $batch += @{
                ip_address           = $ip
                machine_id           = [string](Get-LegacyField $r 'MachineId' '')
                hostname             = [string](Get-LegacyField $r 'Hostname' '')
                os                   = [string](Get-LegacyField $r 'OS' '')
                os_family            = [string](Get-LegacyField $r 'OSFamily' '')
                interface_type       = [string](Get-LegacyField $r 'InterfaceType' '')
                interface_name       = [string](Get-LegacyField $r 'InterfaceName' '')
                link_speed_mbps      = [int](Get-LegacyField $r 'LinkSpeedMbps' 0)
                browser              = [string](Get-LegacyField $r 'Browser' '')
                browser_running      = (ConvertTo-DbBool (Get-LegacyField $r 'BrowserRunning' 'False'))
                cdp_port             = [int](Get-LegacyField $r 'CdpPort' 9222)
                current_url          = [string](Get-LegacyField $r 'CurrentUrl' '')
                uptime_sec           = [int](Get-LegacyField $r 'UptimeSec' 0)
                auto_restart_browser = (ConvertTo-DbBool (Get-LegacyField $r 'AutoRestartBrowser' 'False'))
                agent_version        = [string](Get-LegacyField $r 'AgentVersion' '')
                last_ack             = [string](Get-LegacyField $r 'LastAck' '')
                last_report_at       = [string](Get-LegacyField $r 'LastReportAt' '')
            }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'agent.upsert' -Rows $batch)
    }

    # --- 5. kiosk auto-add denylist ----------------------------------------
    Invoke-LegacyFile -RelativePath 'kiosk_autoadd_ignore.json' -Import {
        param($path)
        $data = Import-LegacyJson -Path $path
        if ($null -eq $data) { return 0 }
        $batch = @()
        foreach ($ip in @($data)) {
            if ([string]::IsNullOrWhiteSpace([string]$ip)) { continue }
            $batch += @{ ip_address = [string]$ip }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'kiosk_ignore.insert' -Rows $batch)
    }

    # --- 6. pending kiosk commands -----------------------------------------
    # One file per command. Anything past its time-to-live is dropped rather
    # than carried over: a reboot queued while a kiosk was off must not fire
    # after a migration.
    $cmdFolder = Join-Path -Path $DataFolder -ChildPath 'kiosk_commands'
    if ($areas['kiosks'] -and (Test-Path -LiteralPath $cmdFolder)) {
        $cmdFiles = @(Get-ChildItem -LiteralPath $cmdFolder -Filter '*.json' -ErrorAction SilentlyContinue)
        if ($cmdFiles.Count -gt 0) {
            $nowUnix = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            $batch = @()
            $stale = 0
            foreach ($cf in $cmdFiles) {
                $c = Import-LegacyJson -Path $cf.FullName
                if ($null -eq $c) { continue }
                $queuedUnix = [int64](Get-LegacyField $c 'nonce' 0)
                if ($queuedUnix -gt 0 -and (($nowUnix - $queuedUnix) / 1000) -gt 300) { $stale++; continue }
                $batch += @{
                    ip_address  = [string](Get-LegacyField $c 'ip' '')
                    cmd         = [string](Get-LegacyField $c 'cmd' 'reboot')
                    nonce       = $queuedUnix
                    delay_sec   = [int](Get-LegacyField $c 'delaySec' 5)
                    queued_at   = [string](Get-LegacyField $c 'queuedAt' '')
                    queued_unix = [int64][Math]::Floor($queuedUnix / 1000)
                }
            }
            try {
                $n = 0
                if ($batch.Count -gt 0) { $n = Invoke-DbBatch -Name 'kiosk_commands.insert' -Rows $batch }
                $result.Imported.Add(@{ File = 'kiosk_commands\*.json'; Rows = [int]$n; Note = ("{0} stale command(s) dropped" -f $stale) }) | Out-Null
                foreach ($cf in $cmdFiles) { $moved.Add((Join-Path 'kiosk_commands' $cf.Name)) | Out-Null }
            } catch {
                $result.Errors.Add(@{ File = 'kiosk_commands\*.json'; Error = $_.Exception.Message }) | Out-Null
            }
        }
    }

    }

    # --- 7. discovery ------------------------------------------------------
    if ($areas['discovery']) {
    Invoke-LegacyFile -RelativePath 'discovered_headsets.json' -Import {
        param($path)
        $data = Import-LegacyJson -Path $path
        if ($null -eq $data) { return 0 }
        $batch = @()
        foreach ($r in @($data)) {
            $serial = [string](Get-LegacyField $r 'SerialNumber' '')
            if (-not $serial) { continue }
            $batch += @{
                serial_number = $serial
                ip_address    = [string](Get-LegacyField $r 'IPAddress' '')
                model         = [string](Get-LegacyField $r 'Model' '')
                brand         = [string](Get-LegacyField $r 'Brand' '')
                first_seen    = [string](Get-LegacyField $r 'FirstSeen' '')
                last_seen     = [string](Get-LegacyField $r 'LastSeen' '')
            }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'discovery.upsert' -Rows $batch)
    }

    Invoke-LegacyFile -RelativePath 'headset_discovery_ignore.json' -Import {
        param($path)
        $data = Import-LegacyJson -Path $path
        if ($null -eq $data) { return 0 }
        $batch = @()
        foreach ($s in @($data)) {
            if ([string]::IsNullOrWhiteSpace([string]$s)) { continue }
            $batch += @{ serial_number = [string]$s }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'discovery_ignore.insert' -Rows $batch)
    }
    }

    # --- 8. app catalogue ---------------------------------------------------
    # Pre-dates both the LatestVersion column and the ThirdParty column (the
    # oldest files carry Type = third-party/built-in instead).
    if ($areas['apps']) {
    Invoke-LegacyFile -RelativePath 'known_apps.csv' -Import {
        param($path)
        $rows = @(Import-LegacyCsv -Path $path)
        if ($rows.Count -eq 0) { return 0 }
        $batch = @()
        foreach ($r in $rows) {
            $pkg = [string](Get-LegacyField $r 'PackageName' '')
            if (-not $pkg) { continue }
            $thirdParty = 1
            $tpField = Get-LegacyField $r 'ThirdParty' ''
            $typeField = Get-LegacyField $r 'Type' ''
            if ("$tpField" -ne '')        { $thirdParty = ConvertTo-DbBool $tpField }
            elseif ("$typeField" -ne '')  { $thirdParty = if ("$typeField" -eq 'third-party') { 1 } else { 0 } }
            $batch += @{
                package_name    = $pkg
                display_name    = [string](Get-LegacyField $r 'DisplayName' '')
                icon_url        = [string](Get-LegacyField $r 'IconUrl' '')
                local_icon_path = [string](Get-LegacyField $r 'LocalIconPath' '')
                third_party     = $thirdParty
                latest_version  = [string](Get-LegacyField $r 'LatestVersion' '')
            }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'catalog.upsert' -Rows $batch)
    }

    # --- 9. per-headset installed apps and favourites -----------------------
    # Matched to a headset by the filename stem the CSV era used. A file whose
    # headset no longer exists is an ORPHAN: it is reported and moved aside
    # with the rest, but not imported - there is no row to attach it to.
    foreach ($suffix in @($(if ($areas['apps']) { 'installed_apps'; 'favorite_apps' }))) {
        $pattern = "*_{0}.csv" -f $suffix
        foreach ($file in @(Get-ChildItem -LiteralPath $DataFolder -Filter $pattern -ErrorAction SilentlyContinue)) {
            $stem = $file.BaseName -replace ("_{0}$" -f $suffix), ''
            $relative = $file.Name
            if (-not $headsetIdByName.ContainsKey($stem)) {
                $result.Skipped.Add(@{ File = $relative; Reason = ("orphan: no headset named '{0}'" -f ($stem -replace '_', ' ')) }) | Out-Null
                $moved.Add($relative) | Out-Null
                continue
            }
            $headsetId = $headsetIdByName[$stem]
            $localSuffix = $suffix
            Invoke-LegacyFile -RelativePath $relative -Import {
                param($path)
                $rows = @(Import-LegacyCsv -Path $path)
                if ($rows.Count -eq 0) { return 0 }
                $batch = @()
                $order = 0
                foreach ($r in $rows) {
                    $pkg = [string](Get-LegacyField $r 'PackageName' '')
                    if (-not $pkg) { continue }
                    if ($localSuffix -eq 'installed_apps') {
                        # [int64]0, not 0: a bare 0 is an Int32 and TryParse
                        # binds its [ref] by exact type, failing otherwise.
                        $size = [int64]0
                        [void][int64]::TryParse([string](Get-LegacyField $r 'SizeBytes' '0'), [ref]$size)
                        $batch += @{
                            headset_id      = $headsetId
                            package_name    = $pkg
                            version         = [string](Get-LegacyField $r 'Version' '')
                            pending_version = [string](Get-LegacyField $r 'PendingVersion' '')
                            store_version   = [string](Get-LegacyField $r 'StoreVersion' '')
                            size_bytes      = $size
                        }
                    } else {
                        $batch += @{
                            headset_id   = $headsetId
                            package_name = $pkg
                            display_name = [string](Get-LegacyField $r 'DisplayName' '')
                            sort_order   = $order
                        }
                        $order++
                    }
                }
                if ($batch.Count -eq 0) { return 0 }
                $queryName = if ($localSuffix -eq 'installed_apps') { 'installed.insert' } else { 'favorites.insert' }
                return (Invoke-DbBatch -Name $queryName -Rows $batch)
            }
        }
    }

    }

    # --- 10. timers ---------------------------------------------------------
    if ($areas['timers']) {
    Invoke-LegacyFile -RelativePath 'timer.csv' -Import {
        param($path)
        $rows = @(Import-LegacyCsv -Path $path)
        if ($rows.Count -eq 0) { return 0 }
        $known = @{}
        foreach ($h in @(Invoke-DbQuery -Name 'headsets.list')) { $known[[string]$h.ID] = $true }
        $batch = @()
        foreach ($r in $rows) {
            $id = [string](Get-LegacyField $r 'HeadsetID' '')
            if (-not $id -or -not $known.ContainsKey($id)) { continue }
            $mode = [string](Get-LegacyField $r 'Mode' 'dec')
            if ($mode -ne 'inc') { $mode = 'dec' }
            $batch += @{
                headset_id = [int]$id
                minutes    = [int](Get-LegacyField $r 'Minutes' 0)
                seconds    = [int](Get-LegacyField $r 'Seconds' 0)
                mode       = $mode
            }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'timers.upsert' -Rows $batch)
    }
    }

    # --- 11. VQA history ----------------------------------------------------
    if ($areas['vqa']) {
    Invoke-LegacyFile -RelativePath 'vqa_history.csv' -Import {
        param($path)
        $rows = @(Import-LegacyCsv -Path $path -Delimiter ';')
        if ($rows.Count -eq 0) { return 0 }
        $batch = @()
        foreach ($r in $rows) {
            $ts = [string](Get-LegacyField $r 'Timestamp' '')
            if (-not $ts) { continue }
            $batch += @{
                ts           = $ts
                cpu_pct      = [int](Get-LegacyField $r 'CpuPct' 0)
                gpu_pct      = [int](Get-LegacyField $r 'GpuPct' 0)
                scrcpy_count = [int](Get-LegacyField $r 'ScrcpyCount' 0)
                client_count = [int](Get-LegacyField $r 'ClientCount' 0)
                direction    = [string](Get-LegacyField $r 'Direction' '')
                reason       = [string](Get-LegacyField $r 'Reason' '')
                json         = [string](Get-LegacyField $r 'Json' '')
            }
        }
        if ($batch.Count -eq 0) { return 0 }
        return (Invoke-DbBatch -Name 'vqa.history_insert' -Rows $batch)
    }
    }

    # --- 12. snapshot-shaped state -> app_kv --------------------------------
    # kiosks_status.json is deliberately NOT imported: it is live state that the
    # monitor rewrites within a second, and it is truncated at every startup.
    # File names come from the configured paths where there are any: config.json
    # lets an operator rename the monitoring and VQA files, and a renamed file
    # would otherwise be reported as "not present" and silently left behind.
    # The literal names are the shipped defaults, used as a fallback.
    $kvFiles = @{}
    if ($areas['snapshots']) {
        $kvFiles['fw_state.json'] = 'fw_state'
        $kvFiles[(Get-LegacyFileName -GlobalName 'computerMonitoringFilePath' -Default 'computer_monitoring.json')] = 'computer_monitoring'
    }
    if ($areas['vqa']) {
        $kvFiles[(Get-LegacyFileName -GlobalName 'VQA_RecommendationFilePath' -Default 'vqa_recommendation.json')] = 'vqa_recommendation'
        $kvFiles[(Get-LegacyFileName -GlobalName 'VQA_OriginalsFilePath'      -Default 'vqa_originals.json')]      = 'vqa_originals'
        $kvFiles[(Get-LegacyFileName -GlobalName 'VQA_AppliedFilePath'        -Default 'vqa_applied.json')]        = 'vqa_applied'
        $kvFiles[(Get-LegacyFileName -GlobalName 'VQA_CooldownFilePath'       -Default 'vqa_cooldown.json')]       = 'vqa_cooldown'
    }
    foreach ($fileName in $kvFiles.Keys) {
        $key = $kvFiles[$fileName]
        Invoke-LegacyFile -RelativePath $fileName -Import {
            param($path)
            $text = Read-LegacyText -Path $path
            if ([string]::IsNullOrWhiteSpace($text)) { return 0 }
            # Validate before storing: an unparsable blob would poison every
            # later Get-DbKeyValue for that key.
            try { $text | ConvertFrom-Json | Out-Null } catch { throw ("not valid JSON: {0}" -f $_.Exception.Message) }
            Set-DbKeyValue -Key $key -Value $text
            return 1
        }
    }
    if ($areas['kiosks'] -and (Test-Path -LiteralPath (Join-Path -Path $DataFolder -ChildPath 'kiosks_status.json'))) {
        $result.Skipped.Add(@{ File = 'kiosks_status.json'; Reason = 'live state, rebuilt by the monitor' }) | Out-Null
        $moved.Add('kiosks_status.json') | Out-Null
    }

    # --- move the originals aside ------------------------------------------
    # NOTE: the outcome is returned as a NEW hashtable rather than by
    # converting the List values in place. Assigning an array over a hashtable
    # value that currently holds a typed List throws "argument types do not
    # match" - PowerShell binds the assignment against the existing value's
    # type instead of simply replacing the key.
    if ($WhatIf) {
        Write-DbLog ("Legacy import (WhatIf): {0} file(s) would be imported, {1} skipped, {2} error(s)." -f `
                     $result.Imported.Count, $result.Skipped.Count, $result.Errors.Count) -Level INFO
        return @{
            Imported     = $result.Imported.ToArray()
            Skipped      = $result.Skipped.ToArray()
            Errors       = $result.Errors.ToArray()
            LegacyFolder = $null
        }
    }

    if ($moved.Count -gt 0) {
        $result.LegacyFolder = $legacyRoot
        foreach ($relative in $moved) {
            $src = Join-Path -Path $DataFolder -ChildPath $relative
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $dst = Join-Path -Path $legacyRoot -ChildPath $relative
            $dstFolder = Split-Path -Parent $dst
            try {
                if (-not (Test-Path -LiteralPath $dstFolder)) { New-Item -ItemType Directory -Path $dstFolder -Force | Out-Null }
                Move-Item -LiteralPath $src -Destination $dst -Force
            } catch {
                $result.Errors.Add(@{ File = $relative; Error = ("could not move aside: {0}" -f $_.Exception.Message) }) | Out-Null
            }
        }
        Write-DbLog ("Legacy data imported: {0} file(s); originals moved to {1}" -f $moved.Count, $legacyRoot) -Level SUCCESS
    }

    # .ToArray(), not @(): under Set-StrictMode the array subexpression
    # operator throws "argument types do not match" on a generic List whose
    # elements are hashtables. ToArray is exact and cheaper anyway.
    $final = @{
        Imported     = $result.Imported.ToArray()
        Skipped      = $result.Skipped.ToArray()
        Errors       = $result.Errors.ToArray()
        LegacyFolder = $result.LegacyFolder
    }

    # Record the outcome so an operator can see later what happened and when.
    if ($final.Imported.Count -gt 0 -or $final.Errors.Count -gt 0) {
        try {
            $log = @(Get-DbKeyValue -Key 'legacy_import_log' -Default @())
            $log += [PSCustomObject]@{
                When         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
                LegacyFolder = $final.LegacyFolder
                Imported     = @($final.Imported | ForEach-Object { "{0}={1}" -f $_.File, $_.Rows })
                Skipped      = @($final.Skipped  | ForEach-Object { "{0}: {1}" -f $_.File, $_.Reason })
                Errors       = @($final.Errors   | ForEach-Object { "{0}: {1}" -f $_.File, $_.Error })
            }
            Set-DbKeyValue -Key 'legacy_import_log' -Value $log
        } catch { }
    }

    return $final
}


# ===================================================================
# OPERATOR CSV ROUND-TRIP
#
# ADR-0010 chose CSV partly so a technician could fix a row in Excel before a
# demo. Moving to a database gives that up for live editing, so the capability
# comes back as an explicit export/import of the headset registry - the one
# table an operator actually hand-edits. It is a deliberate round-trip rather
# than a live file, so the database stays the single source of truth.
# ===================================================================

# Converts the working outcome into the hashtable callers get back.
# A NEW hashtable, not a converted one: assigning an array over a hashtable
# value that currently holds a typed List throws "argument types do not
# match", because PowerShell binds the assignment against the existing
# value's type instead of simply replacing the key.
function ConvertTo-HeadsetImportResult {
    param([Parameter(Mandatory = $true)][hashtable]$Outcome)
    return @{
        Ok      = [bool]$Outcome.Ok
        Added   = [int]$Outcome.Added
        Updated = [int]$Outcome.Updated
        Removed = [int]$Outcome.Removed
        Skipped = [int]$Outcome.Skipped
        Errors  = $Outcome.Errors.ToArray()
    }
}

# The 9 legacy columns, in their original order. This IS the operator-facing
# contract: a file exported by an older build must still import here.
function Get-HeadsetCsvColumn {
    return @('ID', 'Name', 'IPAddress', 'scrcpy_AutoRestart', 'Record',
             'ScrcpyProfile', 'Brand', 'Model', 'SerialNumber')
}

<#
.SYNOPSIS
    Writes the headset registry to a CSV an operator can edit in Excel.
.DESCRIPTION
    Same 9 columns and the same display order as the CSV era, UTF-8 without a
    BOM. Booleans are written as the strings True/False, as before.
.EXAMPLE
    Export-HeadsetsCsv -Path 'C:\temp\headsets.csv'
#>
function Export-HeadsetsCsv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rows = @(Invoke-DbQuery -Name 'headsets.list')
    $columns = Get-HeadsetCsvColumn

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(($columns | ForEach-Object { '"' + $_ + '"' }) -join ',')
    foreach ($r in $rows) {
        $cells = foreach ($c in $columns) {
            $v = [string]$r.$c
            '"' + ($v -replace '"', '""') + '"'
        }
        [void]$sb.AppendLine($cells -join ',')
    }

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    # UTF-8 without BOM, the project-wide convention for generated text.
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-DbLog ("Exported {0} headset(s) to {1}" -f $rows.Count, $Path) -Level INFO
    return $Path
}

<#
.SYNOPSIS
    Imports an edited headset CSV back into the registry.
.DESCRIPTION
    Merge  (default) - rows are matched on SerialNumber first, then on ID, then
                       on Name. Unmatched rows are added. Nothing is deleted.
    Replace          - the file becomes the registry: rows not present in it
                       are removed, and their status, apps and timers cascade.

    A row is rejected rather than applied when it would break an invariant:
    a duplicate IP address, a duplicate serial, or a missing name. Every
    rejection is reported with its line number, so the operator can fix the
    spreadsheet instead of guessing.

    The whole import is ONE transaction: a file with a bad row leaves the
    registry exactly as it was.
.OUTPUTS
    @{ Ok; Added; Updated; Removed; Skipped; Errors = @(@{Line;Reason}) }
.EXAMPLE
    Import-HeadsetsCsv -Path 'C:\temp\headsets.csv' -WhatIf
    Import-HeadsetsCsv -Path 'C:\temp\headsets.csv' -Mode Merge
#>
function Import-HeadsetsCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Merge', 'Replace')][string]$Mode = 'Merge',
        [switch]$WhatIf
    )

    $outcome = @{ Ok = $false; Added = 0; Updated = 0; Removed = 0; Skipped = 0
                  Errors = (New-Object System.Collections.Generic.List[object]) }

    if (-not (Test-Path -LiteralPath $Path)) {
        $outcome.Errors.Add(@{ Line = 0; Reason = ("file not found: {0}" -f $Path) }) | Out-Null
        return (ConvertTo-HeadsetImportResult -Outcome $outcome)
    }

    $rows = @(Import-LegacyCsv -Path $Path)
    if ($rows.Count -eq 0) {
        $outcome.Errors.Add(@{ Line = 0; Reason = 'the file has no data rows' }) | Out-Null
        return (ConvertTo-HeadsetImportResult -Outcome $outcome)
    }

    $existing   = @(Invoke-DbQuery -Name 'headsets.list')
    $bySerial   = @{}; $byId = @{}; $byName = @{}
    foreach ($h in $existing) {
        if ([string]$h.SerialNumber -ne '') { $bySerial[[string]$h.SerialNumber] = $h }
        $byId[[string]$h.ID]     = $h
        $byName[[string]$h.Name] = $h
    }
    $maxId = 0
    foreach ($h in $existing) { if ([int]$h.ID -gt $maxId) { $maxId = [int]$h.ID } }

    # --- validate every row first, so nothing is applied from a bad file ----
    $planned  = New-Object System.Collections.Generic.List[object]
    $seenIp   = @{}
    $seenSer  = @{}
    $line     = 1   # header is line 1; first data row is line 2

    foreach ($r in $rows) {
        $line++
        $name   = ([string](Get-LegacyField $r 'Name' '')).Trim()
        $ip     = ([string](Get-LegacyField $r 'IPAddress' '')).Trim()
        $serial = ([string](Get-LegacyField $r 'SerialNumber' '')).Trim()

        if (-not $name) {
            $outcome.Errors.Add(@{ Line = $line; Reason = 'Name is empty' }) | Out-Null
            continue
        }
        if (-not $ip) {
            $outcome.Errors.Add(@{ Line = $line; Reason = ("IPAddress is empty for '{0}'" -f $name) }) | Out-Null
            continue
        }
        if ($seenIp.ContainsKey($ip)) {
            $outcome.Errors.Add(@{ Line = $line; Reason = ("duplicate IPAddress '{0}' (also on line {1})" -f $ip, $seenIp[$ip]) }) | Out-Null
            continue
        }
        if ($serial -and $seenSer.ContainsKey($serial)) {
            $outcome.Errors.Add(@{ Line = $line; Reason = ("duplicate SerialNumber '{0}' (also on line {1})" -f $serial, $seenSer[$serial]) }) | Out-Null
            continue
        }
        $seenIp[$ip] = $line
        if ($serial) { $seenSer[$serial] = $line }

        # Match an existing row: serial is the durable identity, then the id,
        # then the display name.
        $match = $null
        if ($serial -and $bySerial.ContainsKey($serial)) { $match = $bySerial[$serial] }
        if (-not $match) {
            $idText = ([string](Get-LegacyField $r 'ID' '')).Trim()
            if ($idText -and $byId.ContainsKey($idText)) { $match = $byId[$idText] }
        }
        if (-not $match -and $byName.ContainsKey($name)) { $match = $byName[$name] }

        $planned.Add([PSCustomObject]@{
            Line     = $line
            IsNew    = ($null -eq $match)
            Id       = if ($match) { [int]$match.ID } else { 0 }
            Name     = $name
            Ip       = $ip
            Serial   = $serial
            Auto     = (ConvertTo-DbBool (Get-LegacyField $r 'scrcpy_AutoRestart' 'True') -Default $true)
            Record   = (ConvertTo-DbBool (Get-LegacyField $r 'Record' 'False'))
            Profile  = [string](Get-LegacyField $r 'ScrcpyProfile' '')
            Brand    = [string](Get-LegacyField $r 'Brand' '')
            Model    = [string](Get-LegacyField $r 'Model' '')
        }) | Out-Null
    }

    if ($outcome.Errors.Count -gt 0) {
        # A file with any bad row is refused wholesale: half-applying an
        # operator's spreadsheet is worse than applying none of it.
        Write-DbLog ("Headset CSV import refused: {0} invalid row(s) in {1}" -f $outcome.Errors.Count, $Path) -Level WARNING
        return (ConvertTo-HeadsetImportResult -Outcome $outcome)
    }

    $keptIds = @{}
    foreach ($p in $planned) { if (-not $p.IsNew) { $keptIds[[string]$p.Id] = $true } }
    $toRemove = @()
    if ($Mode -eq 'Replace') {
        $toRemove = @($existing | Where-Object { -not $keptIds.ContainsKey([string]$_.ID) })
    }

    $outcome.Added   = @($planned | Where-Object { $_.IsNew }).Count
    $outcome.Updated = @($planned | Where-Object { -not $_.IsNew }).Count
    $outcome.Removed = $toRemove.Count

    if ($WhatIf) {
        $outcome.Ok = $true
        return (ConvertTo-HeadsetImportResult -Outcome $outcome)
    }

    # One transaction for the whole file.
    try {
        $plannedRows = $planned
        $removeRows  = $toRemove
        $nextId      = $maxId
        Invoke-DbTransaction -Script {
            foreach ($p in $plannedRows) {
                $id = $p.Id
                if ($p.IsNew) { $nextId++; $id = $nextId }
                Invoke-DbNonQuery -Name 'headsets.upsert' -Parameters @{
                    id                  = $id
                    name                = $p.Name
                    ip_address          = $p.Ip
                    scrcpy_auto_restart = $p.Auto
                    record              = $p.Record
                    scrcpy_profile      = $p.Profile
                    brand               = $p.Brand
                    model               = $p.Model
                    serial_number       = $p.Serial
                    sort_order          = $p.Line
                } | Out-Null
            }
            foreach ($rm in $removeRows) {
                Invoke-DbNonQuery -Sql 'DELETE FROM headsets WHERE id = @id;' -Parameters @{ id = [int]$rm.ID } | Out-Null
            }
        } | Out-Null
        $outcome.Ok = $true
        Write-DbLog ("Headset CSV import ({0}): {1} added, {2} updated, {3} removed" -f `
                     $Mode, $outcome.Added, $outcome.Updated, $outcome.Removed) -Level SUCCESS
    } catch {
        $outcome.Errors.Add(@{ Line = 0; Reason = $_.Exception.Message }) | Out-Null
        Write-DbLog ("Headset CSV import failed: {0}" -f $_.Exception.Message) -Level ERROR
    }

    return (ConvertTo-HeadsetImportResult -Outcome $outcome)
}
