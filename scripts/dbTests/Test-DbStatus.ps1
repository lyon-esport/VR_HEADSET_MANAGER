#Requires -Version 5.1
<#
.SYNOPSIS
    Live headset status: the id-keyed contract, the startup reset, the merged
    view and the battery-history sampling trigger.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    This area is ADR-0016 made concrete. Status rows carry NO identity columns:
    a rename, a reorder or a DHCP address change must not require a single
    status write. The tests below assert exactly that, because the defect the
    ADR removes - joining live status onto a headset by NAME - is silent when it
    happens and shows one headset's battery under another headset's label.

    It is also the most frequently written table in the application: the monitor
    fast path upserts every row at up to 2 Hz behind a fingerprint gate.

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
# Only for Get-HeadsetInfosCsvColumn, the single source of truth for the status
# column set. Dot-sourcing defines functions; nothing here starts the monitor.
. (Join-Path $modulesRoot 'headsets_monitoring.ps1')

function New-StatusSandbox {
    param([string]$Name = 'status')
    $sandbox = New-TempDatabaseRoot -Name $Name
    Initialize-Database -Role Main -SkipBackup | Out-Null

    $logFolder = Join-Path $sandbox.Root 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sandbox.Root 'website\generated') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sandbox.Root 'website\timer') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sandbox.Root 'templates\data') -Force | Out-Null
    $global:logFolder             = $logFolder
    $global:logFile               = Join-Path $logFolder 'dbtest.log'
    $global:knownHeadsetsFilePath = Join-Path $sandbox.DataFolder 'known_headsets.csv'
    return $sandbox
}

function Set-TestStatus {
    <#
    .SYNOPSIS
        Write one status row the way the monitor fast path does.
    #>
    param(
        [int]$HeadsetId,
        [int]$Ping = 1,
        [int]$AdbWifi = 1,
        [string]$Battery = '80',
        [string]$Scrcpy = '-',
        [string]$RunningApp = '-'
    )
    Invoke-DbNonQuery -Name 'status.upsert' -Parameters @{
        ID                     = $HeadsetId
        Ping                   = $Ping
        ADBWifi                = $AdbWifi
        Battery                = $Battery
        Charging               = '-'
        ChargingWattage        = '-'
        Temp                   = '-'
        BatteryControllerLeft  = '-'
        BatteryControllerRight = '-'
        PowerState             = '-'
        TimeRemainingMin       = '-'
        SCRCPY                 = $Scrcpy
        RunningApp             = $RunningApp
        RunningAppIcon         = ''
    } | Out-Null
}

# ---------------------------------------------------------------------------
# Shape and contract
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'status rows keep the legacy CSV shape and carry no identity' -Test {
    $sandbox = New-StatusSandbox -Name 'stshape'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'Q3 RED'
        Set-TestStatus -HeadsetId $id

        $rows = @(Invoke-DbQuery -Name 'status.list')
        Assert-Equal 1 $rows.Count 'one status row'

        foreach ($col in (Get-HeadsetInfosCsvColumn)) {
            Assert-True ($rows[0].PSObject.Properties.Name -contains $col) ("legacy column {0} present" -f $col)
        }

        # ADR-0016: identity must NOT be here. If these ever appear, a consumer
        # will start joining on them again and a rename will corrupt the display.
        foreach ($forbidden in @('Name', 'IPAddress', 'Brand', 'Model', 'SerialNumber')) {
            Assert-False ($rows[0].PSObject.Properties.Name -contains $forbidden) ("identity column {0} must NOT be in a status row" -f $forbidden)
        }

        Add-TestEvidence ("ID '{0}' ({1}); Ping '{2}'" -f $rows[0].ID, $rows[0].ID.GetType().Name, $rows[0].Ping)
        Assert-True ($rows[0].ID -is [string]) 'ID is TEXT so loose compares keep working'
        Assert-Equal 'True' ([string]$rows[0].Ping) 'booleans are the strings the CSV carried'
        Assert-True (ConvertTo-BoolField $rows[0].Ping) 'and ConvertTo-BoolField reads them'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a rename or an address change writes nothing to status (ADR-0016)' -Test {
    $sandbox = New-StatusSandbox -Name 'stadr16'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'Q3 RED'
        Set-TestStatus -HeadsetId $id -Battery '73'

        $before = Get-DbTableVersion -Name 'headset_status'

        Rename-Headset -OldName 'Q3 RED' -NewName 'Q3 BLUE' | Out-Null
        Set-HeadsetIdentity -SerialNumber 'SER-A' -IPAddress '10.0.0.99' | Out-Null

        $after = Get-DbTableVersion -Name 'headset_status'
        Add-TestEvidence ("headset_status counter {0} -> {1}" -f $before, $after)
        Assert-Equal $before $after 'neither a rename nor an address change touched the status table'

        # And the status is still attached to the same headset, now under its new
        # name and address.
        $merged = @(Get-HeadsetInfosMerged)
        Assert-Equal 1 $merged.Count 'one merged row'
        Assert-Equal 'Q3 BLUE'    ([string]$merged[0].Name)      'identity comes from the registry'
        Assert-Equal '10.0.0.99'  ([string]$merged[0].IPAddress) 'and so does the address'
        Assert-Equal '73'         ([string]$merged[0].Battery)   'while the live battery survived untouched'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the merged view joins identity on ID and drops orphans' -Test {
    $sandbox = New-StatusSandbox -Name 'stmerge'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        $idA = Resolve-HeadsetIdByName -Name 'A'
        $idB = Resolve-HeadsetIdByName -Name 'B'
        Set-TestStatus -HeadsetId $idA -Battery '10'
        Set-TestStatus -HeadsetId $idB -Battery '90'

        $merged = @(Get-HeadsetInfosMerged)
        Assert-Equal 2 $merged.Count 'both headsets merged'
        foreach ($col in @('ID','Name','IPAddress','Brand','Model','SerialNumber','Battery','Ping','SCRCPY')) {
            Assert-True ($merged[0].PSObject.Properties.Name -contains $col) ("merged column {0} present" -f $col)
        }
        $rowA = $merged | Where-Object { $_.Name -eq 'A' }
        Assert-Equal '10' ([string]$rowA.Battery) 'each headset kept its own live values'

        # Removing a headset must take its status with it, and the merged view
        # must not surface a row with no owner.
        Remove-Headset -ID $idA
        $merged = @(Get-HeadsetInfosMerged)
        Add-TestEvidence ("after removal: {0}" -f (($merged | ForEach-Object { $_.Name }) -join ', '))
        Assert-Equal 1 $merged.Count 'the removed headset is gone from the merged view'
        Assert-Equal 'B' ([string]$merged[0].Name) 'and the survivor is the right one'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'status.list')).Count 'its status row cascaded away too'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'merged rows come back in display order, not id order' -Test {
    $sandbox = New-StatusSandbox -Name 'storder'
    try {
        foreach ($n in @('A', 'B', 'C')) {
            Add-Headset -IPAddress ("10.0.0." + ([array]::IndexOf(@('A','B','C'), $n) + 1)) -Name $n -Model 'Quest 3' -SerialNumber ("SER-" + $n)
            Set-TestStatus -HeadsetId (Resolve-HeadsetIdByName -Name $n)
        }

        # Reorder the registry the way a drag-and-drop does: array order IS
        # display order. Status must follow it, not the id sequence.
        $rows = @(Get-KnownHeadsets)
        $reordered = @($rows | Where-Object { $_.Name -eq 'C' }) + @($rows | Where-Object { $_.Name -eq 'A' }) + @($rows | Where-Object { $_.Name -eq 'B' })
        Save-Headsets -headsets $reordered

        $merged = @(Get-HeadsetInfosMerged)
        Add-TestEvidence ("order: {0}" -f (($merged | ForEach-Object { $_.Name }) -join ' > '))
        Assert-Equal 'C' ([string]$merged[0].Name) 'display order is honoured'
        Assert-Equal 'A' ([string]$merged[1].Name) 'second in display order'
        Assert-Equal 'B' ([string]$merged[2].Name) 'third in display order'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Startup reset and seed
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'startup truncates stale status and seeds a default row per headset' -Test {
    $sandbox = New-StatusSandbox -Name 'stseed'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        Set-TestStatus -HeadsetId (Resolve-HeadsetIdByName -Name 'A') -Battery '42' -Scrcpy 'Running'

        # What scripts_init.ps1 does at startup.
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Name 'status.truncate'     | Out-Null
            Invoke-DbNonQuery -Name 'status.seed_missing' | Out-Null
        } | Out-Null

        $rows = @(Invoke-DbQuery -Name 'status.list')
        Assert-Equal 2 $rows.Count 'every headset has a row, including the one that never reported'

        $a = $rows | Where-Object { $_.ID -eq (Resolve-HeadsetIdByName -Name 'A') }
        Add-TestEvidence ("seeded A: battery '{0}' scrcpy '{1}' ping '{2}'" -f $a.Battery, $a.SCRCPY, $a.Ping)
        Assert-Equal '-'     ([string]$a.Battery) 'stale battery from the previous run is gone'
        Assert-Equal '-'     ([string]$a.SCRCPY)  'and so is the stale scrcpy state'
        Assert-Equal 'False' ([string]$a.Ping)    'a seeded row is not reachable until something polls it'

        # The seed is idempotent: running it twice must not duplicate or reset.
        Set-TestStatus -HeadsetId (Resolve-HeadsetIdByName -Name 'A') -Battery '55'
        Invoke-DbNonQuery -Name 'status.seed_missing' | Out-Null
        $a = @(Invoke-DbQuery -Name 'status.list') | Where-Object { $_.ID -eq (Resolve-HeadsetIdByName -Name 'A') }
        Assert-Equal '55' ([string]$a.Battery) 'seed_missing leaves an existing row alone'
        Assert-Equal 2 (@(Invoke-DbQuery -Name 'status.list')).Count 'and does not duplicate rows'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a newly added headset gets a status row without a poll' -Test {
    $sandbox = New-StatusSandbox -Name 'stnew'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Invoke-DbNonQuery -Name 'status.seed_missing' | Out-Null
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'status.list')).Count 'first headset seeded'

        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        Invoke-DbNonQuery -Name 'status.seed_missing' | Out-Null
        Assert-Equal 2 (@(Invoke-DbQuery -Name 'status.list')).Count 'the new headset got a row too'
        Assert-Equal 2 (@(Get-HeadsetInfosMerged)).Count 'and shows up in the merged view immediately'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Battery history
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'battery history samples on change, one row per second, latest wins' -Test {
    $sandbox = New-StatusSandbox -Name 'stbatt'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'A'
        Set-TestStatus -HeadsetId $id -Battery '-'

        # Several changes inside one second. Before migration 003 this raised
        # "UNIQUE constraint failed" and aborted the entire status batch, because
        # SQLite ignores OR REPLACE inside a trigger body. Now the last value for
        # a given second wins and nothing throws.
        foreach ($pct in @('80', '79', '79', '78')) { Set-TestStatus -HeadsetId $id -Battery $pct }

        $hist   = @(Invoke-DbQuery -Sql "SELECT ts, pct FROM battery_history WHERE headset_id = $id ORDER BY ts;")
        $levels = @($hist | ForEach-Object { [int]$_.pct })
        Add-TestEvidence ("after burst: {0} row(s), values {1}" -f $hist.Count, ($levels -join ', '))
        Assert-Equal 1 $hist.Count 'a burst inside one second collapses to a single sample'
        Assert-Equal 78 $levels[0] 'and that sample carries the newest reading'
        Assert-False ($levels -contains 0) 'the - placeholder was never sampled as a number'

        # A change in a later second is a new sample, not an overwrite.
        Start-Sleep -Seconds 2
        Set-TestStatus -HeadsetId $id -Battery '77'
        $hist   = @(Invoke-DbQuery -Sql "SELECT ts, pct FROM battery_history WHERE headset_id = $id ORDER BY ts;")
        $levels = @($hist | ForEach-Object { [int]$_.pct })
        Add-TestEvidence ("after the next second: {0} row(s), values {1}" -f $hist.Count, ($levels -join ', '))
        Assert-Equal 2 $hist.Count 'a change in a later second is a new sample'
        Assert-Equal 77 $levels[1] 'and it holds the new reading'

        # A repeated value never fires the trigger at all.
        $before = @(Invoke-DbQuery -Sql "SELECT ts FROM battery_history WHERE headset_id = $id;").Count
        Set-TestStatus -HeadsetId $id -Battery '77'
        $after = @(Invoke-DbQuery -Sql "SELECT ts FROM battery_history WHERE headset_id = $id;").Count
        Assert-Equal $before $after 'an unchanged battery value adds no history row'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a battery burst does not abort the whole status batch (migration 003)' -Test {
    $sandbox = New-StatusSandbox -Name 'stbatch'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        $idA = Resolve-HeadsetIdByName -Name 'A'
        $idB = Resolve-HeadsetIdByName -Name 'B'
        Set-TestStatus -HeadsetId $idA -Battery '90'
        Set-TestStatus -HeadsetId $idB -Battery '50'

        # This is the shape of the real failure: the monitor writes EVERY
        # headset in one batch, so a collision on one headset's battery history
        # used to roll back every other headset's live status for that tick.
        $rows = @()
        foreach ($pair in @(@{ Id = $idA; Pct = '89' }, @{ Id = $idB; Pct = '49' })) {
            $rows += @{
                ID = $pair.Id; Ping = 1; ADBWifi = 1; Battery = $pair.Pct
                Charging = '-'; ChargingWattage = '-'; Temp = '-'
                BatteryControllerLeft = '-'; BatteryControllerRight = '-'
                PowerState = '-'; TimeRemainingMin = '-'
                SCRCPY = '-'; RunningApp = '-'; RunningAppIcon = ''
            }
        }
        Invoke-DbBatch -Name 'status.upsert' -Rows $rows | Out-Null
        Invoke-DbBatch -Name 'status.upsert' -Rows $rows | Out-Null

        $stored = @(Invoke-DbQuery -Name 'status.list')
        $a = $stored | Where-Object { $_.ID -eq $idA }
        $b = $stored | Where-Object { $_.ID -eq $idB }
        Add-TestEvidence ("A battery '{0}', B battery '{1}'" -f $a.Battery, $b.Battery)
        Assert-Equal '89' ([string]$a.Battery) 'headset A committed'
        Assert-Equal '49' ([string]$b.Battery) 'headset B committed in the same batch'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'battery history is stored ONLY in its own table (migration 005)' -Test {
    $sandbox = New-StatusSandbox -Name 'stpack'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'A'

        # The packed cell on headset_status is gone. Keeping the same data in two
        # shapes with two retention policies, only one of which anything read, is
        # what 005 removed - so assert the column really is absent rather than
        # trusting the migration ran.
        $cols = @(Invoke-DbQuery -Sql "PRAGMA table_info(headset_status);" | ForEach-Object { [string]$_.name })
        Add-TestEvidence ("headset_status columns: {0}" -f ($cols -join ', '))
        Assert-False ($cols -contains 'battery_history') 'the packed battery_history column is gone from headset_status'

        # A row has to exist before the view can be inspected for its shape.
        Set-TestStatus -HeadsetId $id
        $viewCols = @(Invoke-DbQuery -Name 'status.list')[0].PSObject.Properties.Name
        Assert-False ($viewCols -contains 'BatteryHistory') 'and it is gone from the status view'
        Assert-False ((Get-HeadsetInfosCsvColumn) -contains 'BatteryHistory') 'and from the canonical column list'

        # The table is still fed, by the trigger on the Battery column.
        Set-TestStatus -HeadsetId $id -Battery '80'
        Set-TestStatus -HeadsetId $id -Battery '79'
        $rows = @(Invoke-DbQuery -Sql "SELECT pct FROM battery_history WHERE headset_id = $id;")
        Assert-True ($rows.Count -gt 0) 'samples still land in the battery_history table'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the poll runspace preloads its history from the table, per headset' -Test {
    $sandbox = New-StatusSandbox -Name 'stpreload'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        $idA = Resolve-HeadsetIdByName -Name 'A'
        $idB = Resolve-HeadsetIdByName -Name 'B'

        foreach ($s in @(@{h=$idA;t='2026-01-01T10:00:00Z';p=80}, @{h=$idA;t='2026-01-01T10:05:00Z';p=79},
                         @{h=$idA;t='2026-01-01T10:10:00Z';p=78}, @{h=$idA;t='2026-01-01T10:15:00Z';p=77},
                         @{h=$idB;t='2026-01-01T10:00:00Z';p=50})) {
            Invoke-DbNonQuery -Sql ("INSERT INTO battery_history(headset_id, ts, pct) VALUES ({0}, '{1}', {2});" -f $s.h, $s.t, $s.p) | Out-Null
        }

        # battery.recent is what the runspace calls. Newest N, returned OLDEST
        # first, because Get-BatteryTimeEstimate reads the series as a slope and
        # treats the final entry as the current level.
        $recent = @(Invoke-DbQuery -Name 'battery.recent' -Parameters @{ headset_id = $idA; limit = 3 })
        $levels = @($recent | ForEach-Object { [int]$_.pct })
        Add-TestEvidence ("A preload: {0}" -f ($levels -join ' > '))
        Assert-Equal 3 $recent.Count 'the limit is honoured'
        Assert-Equal 79 $levels[0] 'oldest of the newest three comes first'
        Assert-Equal 77 $levels[2] 'and the current level comes last'

        # Per headset, never the previous occupant of an address.
        $bRecent = @(Invoke-DbQuery -Name 'battery.recent' -Parameters @{ headset_id = $idB; limit = 3 })
        Assert-Equal 1 $bRecent.Count 'B sees only its own sample'
        Assert-Equal 50 ([int]$bRecent[0].pct) 'and it is B''s value'

        # Unlike the packed cell, these rows survive the startup status reset -
        # which is what makes the estimate genuinely restart-proof for the first
        # time.
        Invoke-DbNonQuery -Name 'status.truncate' | Out-Null
        Assert-Equal 3 (@(Invoke-DbQuery -Name 'battery.recent' -Parameters @{ headset_id = $idA; limit = 3 })).Count 'history survives a status truncate'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'maintenance prunes battery history to the retention window' -Test {
    $sandbox = New-StatusSandbox -Name 'stretain'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'A'

        $now = [datetime]::UtcNow
        $fresh = @(1, 5, 23)   # hours old - inside a 24h window
        $stale = @(25, 48, 200)
        foreach ($h in ($fresh + $stale)) {
            $ts = $now.AddHours(-$h).ToString('yyyy-MM-ddTHH:mm:ssZ')
            Invoke-DbNonQuery -Sql ("INSERT INTO battery_history(headset_id, ts, pct) VALUES ({0}, '{1}', 50);" -f $id, $ts) | Out-Null
        }
        Assert-Equal 6 (@(Invoke-DbQuery -Sql "SELECT ts FROM battery_history WHERE headset_id = $id;")).Count 'six samples seeded'

        # Retention is enforced by the maintenance sweep, NOT by the sampling
        # trigger: sampling fires on every battery change and sits inside the
        # monitor's batched status write, where a DELETE has no business.
        $global:databaseBatteryHistoryHours = 24
        Invoke-DbMaintenance -Force | Out-Null

        $left = @(Invoke-DbQuery -Sql "SELECT ts FROM battery_history WHERE headset_id = $id;")
        Add-TestEvidence ("{0} of 6 samples left after a 24h prune" -f $left.Count)
        Assert-Equal 3 $left.Count 'only the samples inside the window survived'

        # And it self-throttles, so the slow loop can call it every tick.
        Invoke-DbNonQuery -Sql ("INSERT INTO battery_history(headset_id, ts, pct) VALUES ({0}, '{1}', 50);" -f $id, $now.AddHours(-99).ToString('yyyy-MM-ddTHH:mm:ssZ')) | Out-Null
        $global:databaseMaintenanceIntervalMin = 60
        Assert-False ([bool](Invoke-DbMaintenance)) 'a second call inside the interval is skipped'
        Assert-Equal 4 (@(Invoke-DbQuery -Sql "SELECT ts FROM battery_history WHERE headset_id = $id;")).Count 'so the stale sample is still there'
        Assert-True ([bool](Invoke-DbMaintenance -Force)) '-Force overrides the throttle'
        Assert-Equal 3 (@(Invoke-DbQuery -Sql "SELECT ts FROM battery_history WHERE headset_id = $id;")).Count 'and prunes it'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Write path used by the monitor
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'an offline headset writes a valid row through the batch path' -Test {
    $sandbox = New-StatusSandbox -Name 'stoffline'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'A'

        # Every text column is NOT NULL and the two flags are CHECK (x IN (0,1)),
        # so a record from a headset that never answered - nulls and .NET bools -
        # is exactly the case that would fail if the write path bound it raw.
        $row = @{
            ID = $id; Ping = (ConvertTo-DbBool $false); ADBWifi = (ConvertTo-DbBool $false)
            Battery = '-'; Charging = '-'; ChargingWattage = '-'; Temp = '-'
            BatteryControllerLeft = '-'; BatteryControllerRight = '-'
            PowerState = '-'; TimeRemainingMin = '-'
            SCRCPY = '-'; RunningApp = '-'; RunningAppIcon = ''
        }
        Invoke-DbBatch -Name 'status.upsert' -Rows @($row) | Out-Null

        $stored = @(Invoke-DbQuery -Name 'status.list')
        Assert-Equal 1 $stored.Count 'the offline headset produced a row'
        Assert-Equal 'False' ([string]$stored[0].Ping) 'a .NET false became the string False through the view'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the status change counter moves on every write, so caches invalidate' -Test {
    $sandbox = New-StatusSandbox -Name 'stver'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'A'

        Set-TestStatus -HeadsetId $id -Battery '80'
        $v1 = Get-DbTableVersion -Name 'headset_status'
        Set-TestStatus -HeadsetId $id -Battery '79'
        $v2 = Get-DbTableVersion -Name 'headset_status'
        Add-TestEvidence ("counter {0} -> {1}" -f $v1, $v2)

        # The web server keys its live-status cache on this counter instead of a
        # file mtime. If an in-place update did not bump it, every poller would
        # serve the first reading forever.
        Assert-True ($v2 -gt $v1) 'an in-place status update bumps the counter'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
