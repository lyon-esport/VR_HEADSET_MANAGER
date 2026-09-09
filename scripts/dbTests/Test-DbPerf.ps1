#Requires -Version 5.1
<#
.SYNOPSIS
    Latency budgets for the operations on the hot paths.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    Sized like a busy install: 10 headsets, 2000 catalogue entries, 300
    installed apps per headset. Every measurement reports its p95 as evidence
    whether it passes or not, so a regression is visible as a number and not
    only as a red line.

    Budgets come from the migration plan. They are deliberately loose - the
    point is to catch an accidental O(n) read or a missing index, not to
    benchmark the machine. A budget failure on a heavily loaded laptop is worth
    re-running before believing.

    p95 rather than mean: the tail is what an operator feels when a status
    overlay stutters, and one slow outlier in a mean disappears.

    ASCII only.
#>

$modulesRoot = Join-Path -Path (Get-DbTestRepoRoot) -ChildPath 'modules'
. (Join-Path $modulesRoot 'logging.ps1')
. (Join-Path $modulesRoot 'utils.ps1')
. (Join-Path $modulesRoot 'network_scanner.ps1')
$global:msg = Import-PowerShellDataFile -Path (Join-Path $modulesRoot 'translations\en-US.psd1')

function Write-htmlMonitor            { param($h) }
function Update-HeadsetMonitoringFile { }
function Update-HeadsetVideoFile      { }
function Update-HeadsetTimerFile      { }
function Initialize-TimerFiles        { }
function Get-ScrcpyProcess            { param($displayName, $headsetIP) return $null }
function Convert-Displayname          { param($Name) return ($Name -replace ' ', '_') }
function Stop-HeadsetTimer            { param($headsetId) }
function Get-TimerFilePath            { param($headsetId) return (Join-Path $global:ScriptPath "website\timer\$headsetId.txt") }
function Get-TimerRunFilePath         { param($headsetId) return (Join-Path $global:ScriptPath "website\timer\$headsetId.run") }
function Get-HeadsetSitePath          { param($Name, $Kind) return (Join-Path $global:ScriptPath "website\generated\$Name[$Kind].html") }

. (Join-Path $modulesRoot 'headsets_manager.ps1')

$script:PerfHeadsets    = 10
$script:PerfCatalogRows = 2000
$script:PerfAppsPerHead = 300

function Measure-DbOperation {
    <#
    .SYNOPSIS
        Runs a scriptblock N times and returns @{P95; Median; Min; Max; Runs}
        in milliseconds.
    .DESCRIPTION
        A warm-up pass runs first and is discarded: the first call to a named
        query pays for reading the .sql file and preparing the statement, which
        is a one-off cost per connection and not what these budgets are about.
    #>
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [int]$Runs = 100
    )

    & $Operation | Out-Null

    $samples = New-Object System.Collections.Generic.List[double]
    $watch   = New-Object System.Diagnostics.Stopwatch
    for ($i = 0; $i -lt $Runs; $i++) {
        $watch.Restart()
        & $Operation | Out-Null
        $watch.Stop()
        $samples.Add($watch.Elapsed.TotalMilliseconds) | Out-Null
    }

    $sorted = @($samples.ToArray() | Sort-Object)
    $index  = [int][Math]::Ceiling($sorted.Count * 0.95) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }

    return @{
        P95    = [Math]::Round($sorted[$index], 2)
        Median = [Math]::Round($sorted[[int]([Math]::Floor($sorted.Count / 2))], 2)
        Min    = [Math]::Round($sorted[0], 2)
        Max    = [Math]::Round($sorted[$sorted.Count - 1], 2)
        Runs   = $sorted.Count
    }
}

function Measure-RawSql {
    <#
    .SYNOPSIS
        Times a statement's EXECUTION only, draining the reader without building
        a single PowerShell object.
    .DESCRIPTION
        Separates the two costs that a plain Invoke-DbQuery measurement adds
        together: how long SQLite takes, and how long PowerShell takes to turn
        the result into objects and pass them up through the call chain. Only
        the first is something a schema or an index can fix, so only the first
        deserves a tight budget.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [int]$Runs = 20
    )
    $conn = Get-DbConnection
    $cmd  = $conn.CreateCommand()
    $cmd.CommandText = $Sql
    try {
        $samples = New-Object System.Collections.Generic.List[double]
        $watch   = New-Object System.Diagnostics.Stopwatch
        for ($n = 0; $n -lt ($Runs + 1); $n++) {
            $watch.Restart()
            $reader = $cmd.ExecuteReader()
            while ($reader.Read()) { }
            $reader.Close(); $reader.Dispose()
            $watch.Stop()
            if ($n -gt 0) { $samples.Add($watch.Elapsed.TotalMilliseconds) | Out-Null }
        }
        $sorted = @($samples.ToArray() | Sort-Object)
        $index  = [int][Math]::Ceiling($sorted.Count * 0.95) - 1
        if ($index -lt 0) { $index = 0 }
        return @{
            P95 = [Math]::Round($sorted[$index], 2)
            Median = [Math]::Round($sorted[[int]([Math]::Floor($sorted.Count / 2))], 2)
            Min = [Math]::Round($sorted[0], 2)
            Max = [Math]::Round($sorted[$sorted.Count - 1], 2)
            Runs = $sorted.Count
        }
    } finally { $cmd.Dispose() }
}

function Assert-Budget {
    <#
    .SYNOPSIS
        Records the measurement as evidence, then asserts it against a budget.
    .DESCRIPTION
        -MedianBudgetMs asserts the median as well, and is what the sub-5 ms
        operations use.

        Those are fast enough that a p95 budget tight enough to be meaningful is
        also tight enough to catch a garbage collection and fail at random. A
        flaky budget is worse than a loose one: it teaches everyone to ignore a
        red line. So the median carries the real assertion - it is stable across
        runs and moves immediately if a query regresses - while the p95 gets
        enough headroom to absorb a GC pause and only catches something
        pathological.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][hashtable]$Measurement,
        [Parameter(Mandatory = $true)][double]$BudgetMs,
        [double]$MedianBudgetMs = 0
    )
    Add-TestEvidence ("{0}: median {1} ms, p95 {2} ms (min {3}, max {4}, n={5}) - budget {6} ms{7}" -f `
        $Label, $Measurement.Median, $Measurement.P95, $Measurement.Min, $Measurement.Max, $Measurement.Runs, $BudgetMs, `
        $(if ($MedianBudgetMs -gt 0) { " p95 / {0} ms median" -f $MedianBudgetMs } else { '' }))

    if ($MedianBudgetMs -gt 0) {
        Assert-True ($Measurement.Median -lt $MedianBudgetMs) ("{0} median {1} ms is within its {2} ms budget" -f $Label, $Measurement.Median, $MedianBudgetMs)
    }
    Assert-True ($Measurement.P95 -lt $BudgetMs) ("{0} p95 {1} ms is within its {2} ms budget" -f $Label, $Measurement.P95, $BudgetMs)
}

function New-PerfSandbox {
    <#
    .SYNOPSIS
        A sandbox loaded to production scale, in as few transactions as possible.
    #>
    param([string]$Name = 'perf')

    $sandbox = New-TempDatabaseRoot -Name $Name
    Initialize-Database -Role Main -SkipBackup | Out-Null

    $logFolder = Join-Path $sandbox.Root 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    $global:logFolder = $logFolder

    Invoke-DbTransaction -Script {
        for ($i = 1; $i -le $script:PerfHeadsets; $i++) {
            Invoke-DbNonQuery -Name 'headsets.upsert' -Parameters @{
                id = $i; name = ("PERF{0}" -f $i); ip_address = ("10.7.0.{0}" -f $i)
                scrcpy_auto_restart = 1; record = 0; scrcpy_profile = 'square-R-N-45-20'
                brand = 'Meta'; model = 'Quest 3'; serial_number = ("SER-PERF-{0}" -f $i)
                sort_order = $i
            } | Out-Null
        }
    } | Out-Null
    Invoke-DbNonQuery -Name 'status.seed_missing' | Out-Null

    $catalog = @()
    for ($i = 0; $i -lt $script:PerfCatalogRows; $i++) {
        $catalog += @{
            package_name = ("com.perf.pkg{0}" -f $i); display_name = ("Perf App {0}" -f $i)
            icon_url = ''; local_icon_path = ("/assets/app_icons/com.perf.pkg{0}.png" -f $i)
            third_party = 1; latest_version = '1.0'
        }
    }
    Invoke-DbBatch -Name 'catalog.upsert' -Rows $catalog | Out-Null

    for ($h = 1; $h -le $script:PerfHeadsets; $h++) {
        $apps = @()
        for ($i = 0; $i -lt $script:PerfAppsPerHead; $i++) {
            $apps += @{
                headset_id = $h; package_name = ("com.perf.pkg{0}" -f $i)
                version = '1.0'; pending_version = ''; store_version = ''
                size_bytes = [int64]($i * 2048)
            }
        }
        Invoke-DbBatch -Name 'installed.insert' -Rows $apps | Out-Null
    }

    return $sandbox
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'opening an existing database stays well under a second' -Test {
    $sandbox = New-PerfSandbox -Name 'perfopen'
    try {
        Close-DbConnection

        # Measured with the assembly already loaded, which is the honest figure
        # for every process after the first: the .NET assembly is loaded once per
        # process and the interop DLL is resolved from the same folder.
        $m = Measure-DbOperation -Runs 20 -Operation {
            Initialize-Database -Role Worker | Out-Null
            Close-DbConnection
        }
        Assert-Budget -Label 'Initialize-Database (existing db, no import)' -Measurement $m -BudgetMs 800

        Initialize-Database -Role Worker | Out-Null
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Reads on the hot paths
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'registry and merged-status reads are cheap enough to poll' -Test {
    $sandbox = New-PerfSandbox -Name 'perfread'
    try {
        # Get-KnownHeadsets runs on nearly every console redraw and every web
        # request that resolves identity.
        $m = Measure-DbOperation -Runs 200 -Operation { @(Get-KnownHeadsets) }
        Assert-Budget -Label 'Get-KnownHeadsets' -Measurement $m -BudgetMs 10 -MedianBudgetMs 4

        # Get-HeadsetInfosMerged is the join that replaced a file read plus a
        # hand-built hashtable. It backs the console table and the dashboard.
        $m = Measure-DbOperation -Runs 200 -Operation { @(Get-HeadsetInfosMerged) }
        Assert-Budget -Label 'Get-HeadsetInfosMerged' -Measurement $m -BudgetMs 12 -MedianBudgetMs 5

        # What the web server calls once per cache miss.
        $m = Measure-DbOperation -Runs 200 -Operation { @(Invoke-DbQuery -Name 'status.list') }
        Assert-Budget -Label 'status.list' -Measurement $m -BudgetMs 12 -MedianBudgetMs 5

        # And the counter it checks on EVERY request to decide whether to bother.
        # This one has to be nearly free or the cache is pointless.
        $m = Measure-DbOperation -Runs 200 -Operation { Get-DbTableVersion -Name 'headset_status' }
        Assert-Budget -Label 'Get-DbTableVersion (cache check)' -Measurement $m -BudgetMs 4 -MedianBudgetMs 1
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'per-headset app reads scale to 300 apps and a 2000-row catalogue' -Test {
    $sandbox = New-PerfSandbox -Name 'perfapps'
    try {
        # installed.list_joined is a LEFT JOIN of 300 rows against 2000.
        #
        # The QUERY PLAN is the real assertion here, not the clock. Measured
        # directly, the statement takes 0.4 ms and the plan uses an index at both
        # ends; the ~50 ms this test sees is PowerShell marshalling 300 objects
        # up through Invoke-DbQuery and its retry wrapper, which no index can
        # help. A timing budget alone would therefore be mostly measuring
        # PowerShell, and would not fail if someone dropped an index.
        #
        # So: assert the plan explicitly, and keep a loose clock budget only to
        # catch something pathological.
        $plan = @(Invoke-DbQuery -Sql ("EXPLAIN QUERY PLAN " + ((Get-DbNamedQuery -Name 'installed.list_joined') -replace '@headset_id', '1')))
        $planText = ($plan | ForEach-Object { [string]$_.detail }) -join ' | '
        Add-TestEvidence ("plan: {0}" -f $planText)
        Assert-False ($planText -match 'SCAN (?!.*USING)') 'neither table is fully scanned'
        Assert-True  ($planText -match 'SEARCH i USING PRIMARY KEY') 'installed apps are found by the composite primary key'
        Assert-True  ($planText -match 'SEARCH c USING INDEX')       'the catalogue is joined through its unique index'

        $m = Measure-DbOperation -Runs 100 -Operation { @(Invoke-DbQuery -Name 'installed.list_joined' -Parameters @{ headset_id = 1 }) }
        Assert-Budget -Label 'installed.list_joined (300 apps x 2000 catalogue)' -Measurement $m -BudgetMs 120

        # catalog.list is the one query that returns thousands of rows, and it
        # shows the split clearly: the statement itself is a couple of
        # milliseconds, while turning 2000 rows into PSCustomObjects and passing
        # them up through Invoke-DbQuery costs roughly 0.17 ms per row.
        #
        # That per-row cost is inherent to PowerShell, not to the schema, so the
        # tight budget goes on the SQL and the end-to-end figure gets a loose one
        # that only catches something pathological.
        #
        # The consequence is a rule, not a number: whole-catalogue reads belong
        # on operator-initiated paths, never on a poll loop. Get-AppInfo reads a
        # SINGLE row through catalog.get for exactly this reason.
        $raw = Measure-RawSql -Runs 20 -Sql 'SELECT PackageName, DisplayName, IconUrl, LocalIconPath, ThirdParty, LatestVersion FROM v_app_catalog ORDER BY DisplayName COLLATE NOCASE, PackageName COLLATE NOCASE;'
        Assert-Budget -Label 'catalog.list SQL only (2000 rows)' -Measurement $raw -BudgetMs 15

        $m = Measure-DbOperation -Runs 20 -Operation { @(Invoke-DbQuery -Name 'catalog.list') }
        Assert-Budget -Label 'catalog.list end-to-end (2000 rows, PowerShell objects)' -Measurement $m -BudgetMs 600

        # One row by primary key, called per headset per poll by Get-AppInfo.
        $m = Measure-DbOperation -Runs 200 -Operation { @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = 'com.perf.pkg1500' }) }
        Assert-Budget -Label 'catalog.get (single row by key)' -Measurement $m -BudgetMs 2
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Writes on the hot paths
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'the monitor fast-path write fits inside its tick' -Test {
    $sandbox = New-PerfSandbox -Name 'perfstatus'
    try {
        # The fingerprint gate lets this run at up to 2 Hz, so a 10-headset
        # batch has 500 ms of headroom. The budget is 12 ms because anything
        # near the tick length means the monitor is spending its life writing.
        $rows = @()
        for ($i = 1; $i -le $script:PerfHeadsets; $i++) {
            $rows += @{
                ID = $i; Ping = 1; ADBWifi = 1; Battery = '77'
                Charging = '-'; ChargingWattage = '-'; Temp = '-'
                BatteryControllerLeft = '-'; BatteryControllerRight = '-'
                PowerState = '-'; TimeRemainingMin = '-'; BatteryHistory = ''
                SCRCPY = '-'; RunningApp = '-'; RunningAppIcon = ''
            }
        }
        $batch = $rows
        $m = Measure-DbOperation -Runs 100 -Operation { Invoke-DbBatch -Name 'status.upsert' -Rows $batch }
        Assert-Budget -Label ("status.upsert batch ({0} headsets)" -f $script:PerfHeadsets) -Measurement $m -BudgetMs 12
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a full installed-apps replace stays inside its budget' -Test {
    $sandbox = New-PerfSandbox -Name 'perfreplace'
    try {
        $apps = @()
        for ($i = 0; $i -lt $script:PerfAppsPerHead; $i++) {
            $apps += @{
                headset_id = 1; package_name = ("com.perf.pkg{0}" -f $i)
                version = '2.0'; pending_version = ''; store_version = ''
                size_bytes = [int64]($i * 2048)
            }
        }
        $toWrite = $apps

        # Clear-then-batch-insert in one transaction, exactly what
        # Update-InstalledAppsCache does after every app-cache refresh.
        #
        # A per-row loop of Invoke-DbNonQuery measured 162 ms here against 13 ms
        # for the batch, which is why the caller uses Invoke-DbBatch and why
        # Get-DbCommand reuses its parameter objects.
        $m = Measure-DbOperation -Runs 30 -Operation {
            Invoke-DbTransaction -Script {
                Invoke-DbNonQuery -Name 'installed.delete_for_headset' -Parameters @{ headset_id = 1 } | Out-Null
                Invoke-DbBatch -Name 'installed.insert' -Rows $toWrite | Out-Null
            }
        }
        # Median carries the assertion, p95 absorbs a GC pause - same reasoning as
        # the fast reads above. The plan's figure was 40 ms; the operation
        # measures ~17 ms and its tail wanders to about twice that on a busy
        # machine, so a bare 40 ms p95 red-lined at random.
        Assert-Budget -Label ("installed apps replace ({0} rows)" -f $script:PerfAppsPerHead) -Measurement $m -BudgetMs 60 -MedianBudgetMs 25
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
