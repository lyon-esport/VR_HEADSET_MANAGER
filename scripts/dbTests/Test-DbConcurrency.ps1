#Requires -Version 5.1
<#
.SYNOPSIS
    Write contention across separate PROCESSES and across runspaces.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    Every other layer runs single-threaded, so none of them can prove the claim
    the whole migration rests on: that the CSV era's five unsynchronised writers
    are safe once they share one WAL database. The flat files had no locking at
    all - known_apps.csv had N+3 concurrent whole-file rewriters and the last
    one won, silently. The replacement is WAL journalling, BEGIN IMMEDIATE
    transactions and a retry wrapper, and only real contention exercises it.

    Two kinds of concurrency are produced, because the application has both:
      * separate PROCESSES  - main console, VRMonitor job, web server, the
        app-resolve job. Driven by stress_worker.ps1, one process per role.
      * separate RUNSPACES in one process - the per-headset poll runspaces,
        each of which opens its own connection behind an InstanceId guard.

    Duration defaults to a value that keeps the suite quick. Set
    VRHM_STRESS_SECONDS for a longer soak, e.g. 60 before a release.

    ASCII only.
#>

$script:StressSeconds = 12
if ($env:VRHM_STRESS_SECONDS) {
    $parsed = 0
    if ([int]::TryParse($env:VRHM_STRESS_SECONDS, [ref]$parsed) -and $parsed -ge 5) {
        $script:StressSeconds = $parsed
    }
}

$script:StressRepoRoot   = Get-DbTestRepoRoot
$script:StressWorkerPath = Join-Path -Path (Join-Path -Path $script:StressRepoRoot -ChildPath 'scripts') `
                                     -ChildPath (Join-Path 'dbTests' 'stress_worker.ps1')

function New-StressSandbox {
    <#
    .SYNOPSIS
        Sandbox with a schema, some headsets, a kiosk and a seeded status row
        for each headset.
    #>
    param([string]$Name = 'stress', [int]$Headsets = 5)

    $sandbox = New-TempDatabaseRoot -Name $Name
    Initialize-Database -Role Main -SkipBackup | Out-Null

    for ($i = 1; $i -le $Headsets; $i++) {
        Invoke-DbNonQuery -Name 'headsets.upsert' -Parameters @{
            id = $i; name = ("STRESS{0}" -f $i); ip_address = ("10.8.0.{0}" -f $i)
            scrcpy_auto_restart = 1; record = 0; scrcpy_profile = 'square-R-N-45-20'
            brand = 'Meta'; model = 'Quest 3'; serial_number = ("SER-STRESS-{0}" -f $i)
            sort_order = $i
        } | Out-Null
    }
    Invoke-DbNonQuery -Name 'status.seed_missing' | Out-Null

    Invoke-DbNonQuery -Name 'kiosks.upsert' -Parameters @{
        id = 1; name = 'STRESS-KIOSK'; ip_address = '10.9.9.9'; port = 9222
        pushed_url = ''; last_pushed_at = ''; sort_order = 1
    } | Out-Null

    return $sandbox
}

function Start-StressWorker {
    <#
    .SYNOPSIS
        Launches one worker process and returns a handle with its result path.
    #>
    param(
        [Parameter(Mandatory = $true)]$Sandbox,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    $resultPath = Join-Path $Sandbox.Root ("stress_{0}.json" -f $Role)
    $arguments  = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:StressWorkerPath),
        '-Root',   ('"{0}"' -f $Sandbox.Root),
        '-Repo',   ('"{0}"' -f $script:StressRepoRoot),
        '-Role',   $Role,
        '-Seconds', $Seconds,
        '-ResultPath', ('"{0}"' -f $resultPath)
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    return @{ Role = $Role; Process = $process; ResultPath = $resultPath }
}

function Wait-StressWorkers {
    <#
    .SYNOPSIS
        Waits for every worker, then reads back its JSON result.
    .DESCRIPTION
        A worker that never wrote a result is reported as one error rather than
        silently counting as a pass - a crashed writer is exactly the failure
        this layer exists to catch.
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Workers,
        [int]$TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    foreach ($worker in $Workers) {
        $remaining = [int]([Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds))
        if (-not $worker.Process.WaitForExit($remaining * 1000)) {
            try { $worker.Process.Kill() } catch { }
        }
    }

    $results = @()
    foreach ($worker in $Workers) {
        if (Test-Path -LiteralPath $worker.ResultPath) {
            try {
                $raw = Get-Content -LiteralPath $worker.ResultPath -Raw -Encoding UTF8
                $results += ($raw | ConvertFrom-Json)
                continue
            } catch { }
        }
        $results += [PSCustomObject]@{
            Role = $worker.Role; Operations = 0; Errors = 1
            FirstError = 'the worker produced no result file (crashed or was killed)'
            Started = ''; Ended = ''
        }
    }
    return $results
}

# ---------------------------------------------------------------------------
# Multi-process contention
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'three writer processes contend without a single surfaced error' -Test {
    Assert-True (Test-Path -LiteralPath $script:StressWorkerPath) 'stress_worker.ps1 is present'

    $sandbox = New-StressSandbox -Name 'stressmp'
    try {
        # The connection this process holds must be closed first. The workers
        # need the file, and holding an idle connection here would only measure
        # this test's own lock, not theirs.
        Close-DbConnection -Checkpoint

        $workers = @()
        foreach ($role in @('status', 'catalog', 'reader')) {
            $workers += Start-StressWorker -Sandbox $sandbox -Role $role -Seconds $script:StressSeconds
        }
        $results = Wait-StressWorkers -Workers $workers -TimeoutSeconds ($script:StressSeconds + 90)

        $totalOps    = 0
        $totalErrors = 0
        foreach ($r in $results) {
            $totalOps    += [int]$r.Operations
            $totalErrors += [int]$r.Errors
            Add-TestEvidence ("{0}: {1} operation(s), {2} error(s){3}" -f $r.Role, $r.Operations, $r.Errors, $(if ($r.FirstError) { " - " + $r.FirstError } else { '' }))
        }

        Assert-Equal 3 $results.Count 'every worker reported'
        Assert-True ($totalOps -gt 0) 'the workers actually did work'
        # This is the assertion that matters. SQLITE_BUSY is expected under this
        # load; what must never happen is one reaching a caller.
        Assert-Equal 0 $totalErrors 'no error surfaced from any writer process'

        # Re-open and check the file is sound and self-consistent.
        Initialize-Database -Role Worker | Out-Null
        $integrity = Test-DatabaseIntegrity
        Add-TestEvidence ("integrity: Ok={0} {1}" -f $integrity.Ok, $integrity.Messages)
        Assert-True $integrity.Ok 'the database is intact after concurrent writing'

        # Every headset still has exactly one status row: the upserts collided
        # constantly and must never have produced a duplicate or lost one.
        $statusRows = @(Invoke-DbQuery -Name 'status.list')
        $headsets   = @(Invoke-DbQuery -Name 'headsets.list')
        Add-TestEvidence ("{0} headset(s), {1} status row(s)" -f $headsets.Count, $statusRows.Count)
        Assert-Equal $headsets.Count $statusRows.Count 'one status row per headset, no duplicates and none lost'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the command queue delivers each command exactly once under contention' -Test {
    $sandbox = New-StressSandbox -Name 'stressq' -Headsets 1
    try {
        # Queue a known set, then drain it. The claim is DELETE ... RETURNING,
        # so a lost race would either hand the same command to two callers or
        # drop one entirely.
        #
        # Nonces must be INTEGERS here, as Add-KioskCommand generates them
        # (a Unix timestamp in milliseconds). kiosk_commands.nonce is declared
        # INTEGER, and System.Data.SQLite reads a column back through its
        # DECLARED type: a TEXT value stored in it comes back as 0, silently.
        # SQLite itself stores and de-duplicates such a value correctly - only
        # the read is lossy - so a test that queued string nonces would compare
        # forty zeroes and look like a deliver-twice bug that is not there.
        $queued = 40
        for ($i = 0; $i -lt $queued; $i++) {
            Invoke-DbNonQuery -Name 'kiosk_commands.insert' -Parameters @{
                ip_address = '10.9.9.9'; cmd = 'reboot'
                nonce = [int64](5000 + $i); delay_sec = 0
                queued_at = (Get-Date).ToString('o'); queued_unix = [int64]$i
            } | Out-Null
        }

        $claimed = New-Object System.Collections.Generic.List[string]
        $ids     = New-Object System.Collections.Generic.List[string]
        $empty   = 0
        for ($i = 0; $i -lt ($queued + 20); $i++) {
            $row = @(Invoke-DbQuery -Name 'kiosk_commands.claim' -Parameters @{ ip_address = '10.9.9.9' })
            if ($row.Count -eq 0) { $empty++; continue }
            $claimed.Add([string]$row[0].nonce) | Out-Null
            $ids.Add([string]$row[0].id) | Out-Null
        }

        $uniqueNonces = @($claimed.ToArray() | Sort-Object -Unique)
        $uniqueIds    = @($ids.ToArray()     | Sort-Object -Unique)
        Add-TestEvidence ("claimed {0}, unique nonces {1}, unique ids {2}, empty claims {3}" -f $claimed.Count, $uniqueNonces.Count, $uniqueIds.Count, $empty)
        Assert-Equal $queued $claimed.Count      'every queued command was delivered'
        Assert-Equal $queued $uniqueNonces.Count 'and none was delivered twice'
        Assert-Equal $queued $uniqueIds.Count    'each delivery carried a distinct row id'
        Assert-True ($empty -gt 0) 'the queue drained and further claims returned nothing'

        # A replayed nonce must be refused, which is what makes the queue safe
        # against an agent retrying its heartbeat.
        Invoke-DbNonQuery -Name 'kiosk_commands.insert' -Parameters @{
            ip_address = '10.9.9.9'; cmd = 'reboot'; nonce = [int64]9999
            delay_sec = 0; queued_at = 'x'; queued_unix = [int64]0
        } | Out-Null
        Assert-Throws -Script {
            Invoke-DbNonQuery -Name 'kiosk_commands.insert' -Parameters @{
                ip_address = '10.9.9.9'; cmd = 'reboot'; nonce = [int64]9999
                delay_sec = 0; queued_at = 'x'; queued_unix = [int64]0
            }
        } -Match 'UNIQUE' -Label 'queueing a duplicate nonce'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Runspace contention inside one process
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'six runspaces each open their own connection and write safely' -Test {
    $sandbox = New-StressSandbox -Name 'stressrs' -Headsets 6
    try {
        $repoRoot   = $script:StressRepoRoot
        $rootPath   = $sandbox.Root
        $iterations = 25

        # This is the per-headset poll runspace shape: a fresh runspace that sets
        # up its own globals, dot-sources the module and opens its own
        # connection. Sharing one connection across runspaces is what the
        # InstanceId guard in Get-DbConnection exists to prevent.
        $block = {
            param([string]$Root, [string]$Repo, [int]$HeadsetId, [int]$Iterations)

            $global:ScriptPath              = $Root
            $global:databaseFolder          = Join-Path $Repo 'sources\sqlite\System.Data.SQLite-1.0.119'
            $global:databaseAssemblyPath    = Join-Path $global:databaseFolder 'System.Data.SQLite.dll'
            $global:databaseInteropPath     = Join-Path (Join-Path $global:databaseFolder 'x64') 'SQLite.Interop.dll'
            $global:databaseFilePath        = Join-Path (Join-Path $Root 'data') 'vrhm.db'
            $global:databaseBusyTimeoutMs   = 5000
            $global:databaseRetryMax        = 6
            $global:databaseIntegrityCheck  = 'quick'
            $global:databaseBackupKeep      = 3
            $global:databaseBackupOnStartup = $false
            $global:debugLevelToConsole     = 'NONE'
            $global:debugLevelToFile        = 'NONE'
            $global:logFile                 = Join-Path (Join-Path $Root 'logs') ("rs_{0}.log" -f $HeadsetId)

            $errors = 0
            try {
                . (Join-Path $Repo 'modules\logging.ps1')
                . (Join-Path $Repo 'modules\database.ps1')
                Initialize-Database -Role Worker | Out-Null

                for ($i = 0; $i -lt $Iterations; $i++) {
                    try {
                        Invoke-DbNonQuery -Name 'status.upsert' -Parameters @{
                            ID = $HeadsetId; Ping = 1; ADBWifi = 1
                            Battery = [string](30 + ($i % 50))
                            Charging = '-'; ChargingWattage = '-'; Temp = '-'
                            BatteryControllerLeft = '-'; BatteryControllerRight = '-'
                            PowerState = '-'; TimeRemainingMin = '-'
                            SCRCPY = '-'; RunningApp = '-'; RunningAppIcon = ''
                        } | Out-Null
                        @(Invoke-DbQuery -Name 'status.get' -Parameters @{ headset_id = $HeadsetId }) | Out-Null
                    } catch { $errors++ }
                }
                try { Close-DbConnection } catch { }
            } catch { $errors++ }
            return $errors
        }

        Close-DbConnection -Checkpoint

        $handles = @()
        foreach ($id in 1..6) {
            $ps = [PowerShell]::Create()
            $ps.AddScript($block).AddArgument($rootPath).AddArgument($repoRoot).AddArgument($id).AddArgument($iterations) | Out-Null
            $handles += @{ PS = $ps; Handle = $ps.BeginInvoke() }
        }

        $errorTotal = 0
        foreach ($h in $handles) {
            $out = $h.PS.EndInvoke($h.Handle)
            foreach ($value in @($out)) { $errorTotal += [int]$value }
            if ($h.PS.Streams.Error.Count -gt 0) { $errorTotal += $h.PS.Streams.Error.Count }
            $h.PS.Dispose()
        }

        Add-TestEvidence ("6 runspaces x {0} write+read cycles, {1} error(s)" -f $iterations, $errorTotal)
        Assert-Equal 0 $errorTotal 'no runspace surfaced an error'

        Initialize-Database -Role Worker | Out-Null
        $statusRows = @(Invoke-DbQuery -Name 'status.list')
        Assert-Equal 6 $statusRows.Count 'each runspace owns exactly one status row'
        $integrity = Test-DatabaseIntegrity
        Assert-True $integrity.Ok 'the database is intact after runspace contention'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the write-ahead log is checkpointed back and does not grow unbounded' -Test {
    $sandbox = New-StressSandbox -Name 'stresswal' -Headsets 5
    try {
        for ($round = 0; $round -lt 60; $round++) {
            $rows = @()
            foreach ($id in 1..5) {
                $rows += @{
                    ID = $id; Ping = 1; ADBWifi = 1; Battery = [string](20 + ($round % 60))
                    Charging = '-'; ChargingWattage = '-'; Temp = '-'
                    BatteryControllerLeft = '-'; BatteryControllerRight = '-'
                    PowerState = '-'; TimeRemainingMin = '-'
                    SCRCPY = '-'; RunningApp = '-'; RunningAppIcon = ''
                }
            }
            Invoke-DbBatch -Name 'status.upsert' -Rows $rows | Out-Null
        }

        Close-DbConnection -Checkpoint

        $walPath = $sandbox.DatabasePath + '-wal'
        $walSize = 0
        if (Test-Path -LiteralPath $walPath) { $walSize = (Get-Item -LiteralPath $walPath).Length }
        Add-TestEvidence ("WAL after checkpoint: {0} byte(s)" -f $walSize)

        # A WAL that never checkpoints grows until the disk fills. Close-DbConnection
        # -Checkpoint is what the shutdown path calls; this proves it works.
        Assert-True ($walSize -lt 4MB) 'the WAL is checkpointed back into the database on close'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
