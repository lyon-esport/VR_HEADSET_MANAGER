#Requires -Version 5.1
<#
.SYNOPSIS
    Kiosk repository contracts: registry, agent cache, denylist, command queue.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    Kiosks are the first migrated area with two genuinely concurrent writers -
    the monitor job writes kiosk_status while the web server writes agent
    reports and can add kiosks - so the tests here care as much about what a
    write does NOT touch as about what it does.

    The registry module is loaded on top of the engine, because these are
    repository tests rather than engine tests.

    ASCII only.
#>

# The kiosk repositories, plus what they call: Write-Log from logging.ps1 and
# ConvertTo-BoolField from utils.ps1.
$modulesRoot = Join-Path -Path (Get-DbTestRepoRoot) -ChildPath 'modules'
. (Join-Path $modulesRoot 'logging.ps1')
. (Join-Path $modulesRoot 'utils.ps1')
. (Join-Path $modulesRoot 'kiosks_manager.ps1')
. (Join-Path $modulesRoot 'kiosk_functions.ps1')

function New-KioskSandbox {
    <#
    .SYNOPSIS
        Sandbox with a schema, plus the globals the kiosk modules read.
    .DESCRIPTION
        knownKiosksFilePath is a default parameter value on Get-KnownKiosks and
        is no longer used for anything, but under Set-StrictMode merely naming
        an undefined global throws - so it has to exist. Same reasoning for the
        log globals: Write-KioskLog falls back to $global:ScriptPath\logs when
        logFolder is unset, and that fallback must land inside the sandbox.
    #>
    param([string]$Name = 'kiosk')
    $sandbox = New-TempDatabaseRoot -Name $Name
    Initialize-Database -Role Main -SkipBackup | Out-Null

    $logFolder = Join-Path $sandbox.Root 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    $global:logFolder           = $logFolder
    $global:logFile             = Join-Path $logFolder 'dbtest.log'
    $global:knownKiosksFilePath = Join-Path $sandbox.DataFolder 'known_kiosks.csv'
    return $sandbox
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Add-Kiosk assigns ids and refuses a duplicate address' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskadd'
    try {
        Add-Kiosk -IPAddress '192.168.1.93'  -Name 'Legion GO'   -Port 9222
        Add-Kiosk -IPAddress '192.168.1.116' -Name 'RPI 3 Kiosk' -Port 9222

        $rows = @(Get-KnownKiosks)
        Add-TestEvidence ("ids: {0}" -f (($rows | ForEach-Object { $_.ID }) -join ', '))
        Assert-Equal 2 $rows.Count 'two kiosks were added'
        Assert-Equal '1' ([string]$rows[0].ID) 'first kiosk got id 1'
        Assert-Equal '2' ([string]$rows[1].ID) 'second kiosk got id 2'

        # The legacy column names and string types the console and web read.
        foreach ($col in @('ID', 'Name', 'IPAddress', 'Port', 'PushedURL', 'LastPushedAt')) {
            Assert-True ($rows[0].PSObject.Properties.Name -contains $col) ("legacy column {0} present" -f $col)
        }
        Assert-True ($rows[0].ID -is [string]) 'ID is TEXT, so loose compares still work'
        Assert-True ($rows[0].ID -eq 1) 'and a string id still equals an int'

        # Duplicate address is refused without adding anything.
        Add-Kiosk -IPAddress '192.168.1.93' -Name 'Impostor'
        Assert-Equal 2 (@(Get-KnownKiosks)).Count 'the duplicate address was refused'

        # An empty name defaults to the address (a deliberate product decision).
        Add-Kiosk -IPAddress '192.168.1.200'
        $added = @(Get-KnownKiosks) | Where-Object { $_.IPAddress -eq '192.168.1.200' }
        Assert-Equal '192.168.1.200' ([string]$added.Name) 'an empty name defaults to the address'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'kiosk ids are permanent across delete and re-add' -Test {
    # The CSV version resequenced 1..N on every save, so deleting the middle
    # kiosk silently renumbered the one after it - and the id is the handle the
    # web UI uses for push, edit, reboot and delete.
    $sandbox = New-KioskSandbox -Name 'kioskids'
    try {
        Add-Kiosk -IPAddress '10.0.0.1' -Name 'A'
        Add-Kiosk -IPAddress '10.0.0.2' -Name 'B'
        Add-Kiosk -IPAddress '10.0.0.3' -Name 'C'

        Remove-Kiosk -ID 2
        $rows = @(Get-KnownKiosks)
        Add-TestEvidence ("after removing id 2: {0}" -f (($rows | ForEach-Object { "$($_.ID)=$($_.Name)" }) -join ', '))
        Assert-Equal 2 $rows.Count 'two kiosks remain'
        Assert-Equal 'A' ([string](@($rows | Where-Object { $_.ID -eq '1' })).Name) 'id 1 is still A'
        Assert-Equal 'C' ([string](@($rows | Where-Object { $_.ID -eq '3' })).Name) 'id 3 is STILL C, not renumbered to 2'

        # A new kiosk takes max+1, never the freed id and never a row count.
        Add-Kiosk -IPAddress '10.0.0.4' -Name 'D'
        $d = @(Get-KnownKiosks) | Where-Object { $_.Name -eq 'D' }
        Add-TestEvidence ("new kiosk D got id {0}" -f $d.ID)
        Assert-Equal '4' ([string]$d.ID) 'the new kiosk got max+1, not the freed id 2'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'twelve kiosks keep their ids through a save' -Test {
    # The specific case the CSV code got wrong: Sort-Object ID on Import-Csv
    # strings orders 1, 10, 11, 12, 2, ... so the resequence reassigned nearly
    # every id. Nothing may move here.
    $sandbox = New-KioskSandbox -Name 'kiosk12'
    try {
        foreach ($i in 1..12) { Add-Kiosk -IPAddress ("10.1.0.{0}" -f $i) -Name ("Kiosk {0}" -f $i) }

        $before = @{}
        foreach ($k in @(Get-KnownKiosks)) { $before[[string]$k.IPAddress] = [string]$k.ID }
        Add-TestEvidence ("ids before: {0}" -f ((@(Get-KnownKiosks) | ForEach-Object { $_.ID }) -join ','))

        Save-Kiosks -kiosks @(Get-KnownKiosks)

        $moved = @()
        foreach ($k in @(Get-KnownKiosks)) {
            if ($before[[string]$k.IPAddress] -ne [string]$k.ID) {
                $moved += ("{0}: {1} -> {2}" -f $k.IPAddress, $before[[string]$k.IPAddress], $k.ID)
            }
        }
        foreach ($m in $moved) { Add-TestEvidence $m }
        Add-TestEvidence ("ids after : {0}" -f ((@(Get-KnownKiosks) | ForEach-Object { $_.ID }) -join ','))
        Assert-Equal 0 $moved.Count 'no kiosk changed id across a save'
        Assert-Equal 12 (@(Get-KnownKiosks)).Count 'all twelve survived'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Update-KioskField writes each allowed field and nothing else' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskupd'
    try {
        Add-Kiosk -IPAddress '10.0.0.1' -Name 'Before'

        Update-KioskField -ID 1 -Field 'Name'         -NewValue 'After'
        Update-KioskField -ID 1 -Field 'Port'         -NewValue '9333'
        Update-KioskField -ID 1 -Field 'PushedURL'    -NewValue 'http://x/y?a=1,2'
        Update-KioskField -ID 1 -Field 'LastPushedAt' -NewValue '2026-09-08 10:00:00'
        Update-KioskField -ID 1 -Field 'IPAddress'    -NewValue '10.0.0.9'

        $k = @(Get-KnownKiosks)[0]
        Add-TestEvidence ("{0} {1}:{2} url={3}" -f $k.Name, $k.IPAddress, $k.Port, $k.PushedURL)
        Assert-Equal 'After'               ([string]$k.Name)         'Name updated'
        Assert-Equal '9333'                ([string]$k.Port)         'Port updated'
        Assert-Equal 'http://x/y?a=1,2'    ([string]$k.PushedURL)    'a URL containing a comma survives'
        Assert-Equal '2026-09-08 10:00:00' ([string]$k.LastPushedAt) 'LastPushedAt updated'
        Assert-Equal '10.0.0.9'            ([string]$k.IPAddress)    'IPAddress updated'

        # An unknown field, or an unknown id, must write NOTHING. The CSV code
        # called Save-Kiosks unconditionally, so either case rewrote the whole
        # file and resequenced every id.
        $version = Get-DbTableVersion -Name 'kiosks'
        Update-KioskField -ID 1  -Field 'Nonsense' -NewValue 'x'
        Update-KioskField -ID 99 -Field 'Name'     -NewValue 'ghost'
        Add-TestEvidence ("table version {0} -> {1}" -f $version, (Get-DbTableVersion -Name 'kiosks'))
        Assert-Equal $version (Get-DbTableVersion -Name 'kiosks') 'a rejected update writes nothing at all'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Save-Kiosks stores display order and drops omitted rows' -Test {
    $sandbox = New-KioskSandbox -Name 'kiosksave'
    try {
        Add-Kiosk -IPAddress '10.0.0.1' -Name 'A'
        Add-Kiosk -IPAddress '10.0.0.2' -Name 'B'
        Add-Kiosk -IPAddress '10.0.0.3' -Name 'C'

        # Reverse the order; the array order is the display order.
        $reversed = @(@(Get-KnownKiosks) | Sort-Object { [int]$_.ID } -Descending)
        Save-Kiosks -kiosks $reversed
        $names = @(Get-KnownKiosks) | ForEach-Object { $_.Name }
        Add-TestEvidence ("order now: {0}" -f ($names -join ', '))
        Assert-Equal 'C' ([string]$names[0]) 'the reordered array set the display order'
        Assert-Equal 'A' ([string]$names[2]) 'and the last row is the old first one'

        # Omitting a row deletes it, as rewriting the whole CSV used to.
        Save-Kiosks -kiosks @(@(Get-KnownKiosks) | Where-Object { $_.Name -ne 'B' })
        $after = @(Get-KnownKiosks)
        Add-TestEvidence ("after omitting B: {0}" -f (($after | ForEach-Object { $_.Name }) -join ', '))
        Assert-Equal 2 $after.Count 'the omitted kiosk was removed'
        Assert-True (@($after | Where-Object { $_.Name -eq 'B' }).Count -eq 0) 'B is gone'

        # An empty array clears the table.
        Save-Kiosks -kiosks @()
        Assert-Equal 0 (@(Get-KnownKiosks)).Count 'an empty array clears the registry'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Agent reports
# ---------------------------------------------------------------------------

function New-TestAgentReport {
    param([string]$Hostname = 'LEGION', [bool]$BrowserRunning = $true, [string]$Url = 'http://x')
    # 'ack' is present but null, which is what a real agent sends when it has
    # no command result to report. Save-KioskAgentReport reads $Report.ack, and
    # under Set-StrictMode an absent property throws where a null one does not.
    return [PSCustomObject]@{
        machineId = 'M1'; hostname = $Hostname; os = 'Windows 11'; osFamily = 'Windows'
        interfaceType = 'Ethernet'; interfaceName = 'eth0'; linkSpeedMbps = 1000
        browser = 'Chrome/152.0'; browserRunning = $BrowserRunning; cdpPort = 9222
        currentUrl = $Url; uptimeSec = 3600; autoRestartBrowser = $true; version = '2.1'
        ack = $null
    }
}

Invoke-RegressionTest -Name 'agent reports upsert by address and keep real booleans' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskagent'
    try {
        Assert-True (Save-KioskAgentReport -IPAddress '10.0.0.5' -Report (New-TestAgentReport)) 'the first report was stored'
        Assert-True (Save-KioskAgentReport -IPAddress '10.0.0.6' -Report (New-TestAgentReport -Hostname 'RPI')) 'a second kiosk was stored'

        $all = @(Get-KioskAgentReports)
        Add-TestEvidence ("reports: {0}" -f (($all | ForEach-Object { "$($_.IPAddress)=$($_.Hostname)" }) -join ', '))
        Assert-Equal 2 $all.Count 'both reports are cached'

        $one = Get-KioskAgentInfo -IPAddress '10.0.0.5'
        Assert-NotNull $one 'the single-kiosk lookup found it'
        Assert-Equal 'LEGION' ([string]$one.Hostname) 'hostname round-trips'
        Assert-Equal 1000 ([int]$one.LinkSpeedMbps) 'the numeric field round-trips'

        # These are INTEGER 0/1 in the table but must reach the web UI as real
        # booleans. Note ConvertTo-BoolField would answer false for an integer
        # 1, which is exactly the trap this asserts against.
        Assert-True ($one.BrowserRunning -is [bool]) 'BrowserRunning is a real boolean'
        Assert-True $one.BrowserRunning 'and it is true'
        Assert-True ($one.AutoRestartBrowser -is [bool]) 'AutoRestartBrowser is a real boolean'

        # A second report from the same address REPLACES, never appends.
        Save-KioskAgentReport -IPAddress '10.0.0.5' -Report (New-TestAgentReport -Hostname 'RENAMED' -BrowserRunning $false) | Out-Null
        Assert-Equal 2 (@(Get-KioskAgentReports)).Count 'still two rows, not three'
        $updated = Get-KioskAgentInfo -IPAddress '10.0.0.5'
        Assert-Equal 'RENAMED' ([string]$updated.Hostname) 'the row was replaced'
        Assert-False $updated.BrowserRunning 'a false boolean round-trips as false'

        Assert-True ($null -eq (Get-KioskAgentInfo -IPAddress '10.0.0.99')) 'a kiosk that never reported returns null'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'IsStale is computed against the threshold, not stored' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskstale'
    try {
        Save-KioskAgentReport -IPAddress '10.0.0.5' -Report (New-TestAgentReport) | Out-Null

        $fresh = Get-KioskAgentInfo -IPAddress '10.0.0.5' -StaleAfterSec 30
        Assert-False $fresh.IsStale 'a report from just now is not stale'

        # Backdate the stored timestamp rather than waiting.
        $old = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-dd HH:mm:ss')
        Invoke-DbNonQuery -Sql 'UPDATE kiosk_agent_reports SET last_report_at = @t WHERE ip_address = @ip;' `
                          -Parameters @{ t = $old; ip = '10.0.0.5' } | Out-Null

        $stale = Get-KioskAgentInfo -IPAddress '10.0.0.5' -StaleAfterSec 30
        Add-TestEvidence ("last report {0}; IsStale at 30s = {1}" -f $old, $stale.IsStale)
        Assert-True $stale.IsStale 'a ten-minute-old report is stale at a 30s threshold'

        # The same row answers differently for a different question, which is
        # why staleness is computed rather than stored.
        $tolerant = Get-KioskAgentInfo -IPAddress '10.0.0.5' -StaleAfterSec 3600
        Assert-False $tolerant.IsStale 'and is not stale at a one-hour threshold'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Auto-add denylist and registration
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'a removed kiosk with agent history is denylisted' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskdeny'
    try {
        Add-Kiosk -IPAddress '10.0.0.5' -Name 'Reporting'
        Add-Kiosk -IPAddress '10.0.0.6' -Name 'Manual only'
        Save-KioskAgentReport -IPAddress '10.0.0.5' -Report (New-TestAgentReport) | Out-Null

        Remove-Kiosk -ID 1
        Assert-True  (Test-KioskAutoAddIgnored -IPAddress '10.0.0.5') 'the kiosk with agent history was denylisted'
        Remove-Kiosk -ID 2
        Assert-False (Test-KioskAutoAddIgnored -IPAddress '10.0.0.6') 'a manually-added kiosk needs no denylist entry'

        # Denylisting twice is a no-op, not a duplicate row.
        Add-KioskAutoAddIgnore -IPAddress '10.0.0.5'
        Assert-Equal 1 ([int](Invoke-DbScalar -Sql "SELECT COUNT(*) FROM kiosk_autoadd_ignore WHERE ip_address = '10.0.0.5';")) 'the denylist deduplicates'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'agent registration adds once and respects the denylist' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskreg'
    try {
        Assert-True  (Register-KioskFromAgentReport -IPAddress '10.0.0.7' -Hostname 'NEW') 'a first heartbeat auto-adds the kiosk'
        Assert-False (Register-KioskFromAgentReport -IPAddress '10.0.0.7' -Hostname 'NEW') 'a second heartbeat does not add it again'
        Assert-Equal 1 (@(Get-KnownKiosks)).Count 'exactly one row'
        Assert-Equal 'NEW' ([string](@(Get-KnownKiosks)[0].Name)) 'the hostname became the name'

        # The whole point of the denylist: an agent still running after the
        # operator removed its kiosk must not re-add itself.
        Remove-Kiosk -ID 1
        Add-KioskAutoAddIgnore -IPAddress '10.0.0.7'
        Assert-False (Register-KioskFromAgentReport -IPAddress '10.0.0.7' -Hostname 'NEW') 'a denylisted address is not re-added'
        Assert-Equal 0 (@(Get-KnownKiosks)).Count 'the registry stayed empty'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Command queue
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'a queued command is delivered exactly once' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskcmd'
    try {
        $nonce = Add-KioskCommand -IPAddress '10.0.0.5' -Cmd 'reboot' -DelaySec 5
        Assert-NotNull $nonce 'the command was queued'

        $first = Get-PendingKioskCommand -IPAddress '10.0.0.5'
        Assert-NotNull $first 'the first claim got the command'
        Add-TestEvidence ("claimed cmd={0} nonce={1} delaySec={2} ip={3}" -f $first.cmd, $first.nonce, $first.delaySec, $first.ip)

        # These exact lowercase names go on the wire to the kiosk agents.
        foreach ($k in @('cmd', 'nonce', 'delaySec', 'ip', 'queuedAt')) {
            Assert-True ($first.PSObject.Properties.Name -contains $k) ("the delivered object carries {0}" -f $k)
        }
        Assert-True ($first.PSObject.Properties.Name -notcontains 'queued_unix') 'the internal TTL column is not exposed'
        Assert-Equal 'reboot' ([string]$first.cmd) 'the command survived'
        Assert-Equal ([int64]$nonce) ([int64]$first.nonce) 'the nonce survived'

        Assert-True ($null -eq (Get-PendingKioskCommand -IPAddress '10.0.0.5')) 'a second claim gets nothing'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'commands are claimed oldest first and per kiosk' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskcmdorder'
    try {
        Add-KioskCommand -IPAddress '10.0.0.5' -Cmd 'reboot'          | Out-Null
        Start-Sleep -Milliseconds 5
        Add-KioskCommand -IPAddress '10.0.0.5' -Cmd 'browser-restart' | Out-Null
        Add-KioskCommand -IPAddress '10.0.0.6' -Cmd 'shutdown'        | Out-Null

        $a = Get-PendingKioskCommand -IPAddress '10.0.0.5'
        $b = Get-PendingKioskCommand -IPAddress '10.0.0.5'
        Add-TestEvidence ("order: {0} then {1}" -f $a.cmd, $b.cmd)
        Assert-Equal 'reboot'          ([string]$a.cmd) 'the oldest command comes first'
        Assert-Equal 'browser-restart' ([string]$b.cmd) 'then the next one'
        Assert-True ($null -eq (Get-PendingKioskCommand -IPAddress '10.0.0.5')) 'then the queue is empty'

        # The other kiosk's command was never touched.
        $c = Get-PendingKioskCommand -IPAddress '10.0.0.6'
        Assert-NotNull $c 'the other kiosk still has its command'
        Assert-Equal 'shutdown' ([string]$c.cmd) 'and it is the right one'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a stale command is discarded, never delivered' -Test {
    # A reboot queued while a kiosk was powered off must not fire the moment it
    # comes back an hour later.
    $sandbox = New-KioskSandbox -Name 'kioskttl'
    try {
        Add-KioskCommand -IPAddress '10.0.0.5' -Cmd 'reboot' | Out-Null
        Invoke-DbNonQuery -Sql 'UPDATE kiosk_commands SET queued_unix = queued_unix - 3600 WHERE ip_address = @ip;' `
                          -Parameters @{ ip = '10.0.0.5' } | Out-Null

        Assert-True ($null -eq (Get-PendingKioskCommand -IPAddress '10.0.0.5' -MaxAgeSec 300)) 'the hour-old command was not delivered'
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM kiosk_commands;')) 'and it was removed, not left to fire later'

        # A stale command must not hide a fresh one queued behind it.
        Add-KioskCommand -IPAddress '10.0.0.6' -Cmd 'shutdown' | Out-Null
        Invoke-DbNonQuery -Sql 'UPDATE kiosk_commands SET queued_unix = queued_unix - 3600 WHERE ip_address = @ip;' `
                          -Parameters @{ ip = '10.0.0.6' } | Out-Null
        Start-Sleep -Milliseconds 5
        Add-KioskCommand -IPAddress '10.0.0.6' -Cmd 'reboot' | Out-Null

        $delivered = Get-PendingKioskCommand -IPAddress '10.0.0.6' -MaxAgeSec 300
        Assert-NotNull $delivered 'the fresh command behind the stale one was delivered'
        Assert-Equal 'reboot' ([string]$delivered.cmd) 'and it is the fresh one'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'two concurrent claimers share one command between them' -Test {
    # This is what the one-file-per-command queue was protecting: two agents
    # reporting at the same instant must not both act on the same reboot.
    $sandbox = New-KioskSandbox -Name 'kioskrace'
    try {
        Add-KioskCommand -IPAddress '10.0.0.5' -Cmd 'reboot' | Out-Null

        $claimSql = Get-DbNamedQuery -Name 'kiosk_commands.claim'
        $dbPath   = $sandbox.DatabasePath
        $connStr  = Get-DbConnectionString -DatabasePath $dbPath
        Close-DbConnection -Checkpoint

        # Two separate connections, standing in for two request handlers.
        $claimBlock = {
            param($ConnStr, $Sql)
            $c = New-Object System.Data.SQLite.SQLiteConnection($ConnStr)
            $c.Open()
            $cmd = $c.CreateCommand()
            $cmd.CommandText = $Sql
            $cmd.Parameters.AddWithValue('@ip_address', '10.0.0.5') | Out-Null
            $got = 0
            $r = $cmd.ExecuteReader()
            while ($r.Read()) { $got++ }
            $r.Close(); $cmd.Dispose(); $c.Close(); $c.Dispose()
            return $got
        }
        $one = & $claimBlock $connStr $claimSql
        $two = & $claimBlock $connStr $claimSql

        Add-TestEvidence ("claimer A got {0} row(s); claimer B got {1}" -f $one, $two)
        Assert-Equal 1 ($one + $two) 'exactly one of the two claimers received the command'

        Get-DbConnection | Out-Null
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM kiosk_commands;')) 'the queue is empty afterwards'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Live status
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'kiosk status upserts by address and truncates at startup' -Test {
    $sandbox = New-KioskSandbox -Name 'kioskstatus'
    try {
        $rows = @(
            @{ ip_address = '10.0.0.5'; port = 9222; reachable = 1; latency_ms = 3;    cdp_open = 1; current_url = 'http://x'; extra_json = '{}' }
            @{ ip_address = '10.0.0.6'; port = 9222; reachable = 0; latency_ms = $null; cdp_open = 0; current_url = '';         extra_json = '{}' }
        )
        Invoke-DbBatch -Name 'kiosk_status.upsert' -Rows $rows | Out-Null

        $list = @(Invoke-DbQuery -Name 'kiosk_status.list')
        Assert-Equal 2 $list.Count 'both status rows are stored'
        $up = @($list | Where-Object { $_.IPAddress -eq '10.0.0.5' })[0]
        Add-TestEvidence ("10.0.0.5 reachable={0} latency={1} url={2}" -f $up.Reachable, $up.LatencyMs, $up.CurrentUrl)
        Assert-Equal 1 ([int]$up.Reachable) 'reachable stored'
        Assert-Equal 3 ([int]$up.LatencyMs) 'latency stored'
        Assert-NotNull $up.LastChecked 'updated_at replaces the old LastChecked blob'

        $down = @($list | Where-Object { $_.IPAddress -eq '10.0.0.6' })[0]
        Assert-True ($null -eq $down.LatencyMs) 'an unreachable kiosk has a null latency'

        # Re-polling the same kiosk updates rather than duplicating.
        Invoke-DbBatch -Name 'kiosk_status.upsert' -Rows @(
            @{ ip_address = '10.0.0.5'; port = 9222; reachable = 0; latency_ms = $null; cdp_open = 0; current_url = ''; extra_json = '{}' }
        ) | Out-Null
        Assert-Equal 2 (@(Invoke-DbQuery -Name 'kiosk_status.list')).Count 'still two rows'
        Assert-Equal 0 ([int](@(Invoke-DbQuery -Name 'kiosk_status.list') | Where-Object { $_.IPAddress -eq '10.0.0.5' })[0].Reachable) 'the row was updated'

        # Startup clears it: live state must not survive a restart.
        Invoke-DbNonQuery -Name 'kiosk_status.truncate' | Out-Null
        Assert-Equal 0 (@(Invoke-DbQuery -Name 'kiosk_status.list')).Count 'the truncate clears live status'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the monitor and the web server write different tables' -Test {
    # The two writers used to be kept apart by living in separate FILES. They
    # are separate tables now, so neither can clobber the other - and the
    # registry is a third thing again.
    $sandbox = New-KioskSandbox -Name 'kioskwriters'
    try {
        Add-Kiosk -IPAddress '10.0.0.5' -Name 'Shared'
        $registryVersion = Get-DbTableVersion -Name 'kiosks'

        # Monitor-side write.
        Invoke-DbBatch -Name 'kiosk_status.upsert' -Rows @(
            @{ ip_address = '10.0.0.5'; port = 9222; reachable = 1; latency_ms = 4; cdp_open = 1; current_url = 'http://x'; extra_json = '{}' }
        ) | Out-Null
        # Web-side write.
        Save-KioskAgentReport -IPAddress '10.0.0.5' -Report (New-TestAgentReport) | Out-Null

        Assert-Equal $registryVersion (Get-DbTableVersion -Name 'kiosks') 'neither writer touched the registry'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'kiosk_status.list')).Count 'the status row is there'
        Assert-Equal 1 (@(Get-KioskAgentReports)).Count 'and so is the agent report'

        # And the registry row still reads correctly with both present.
        $k = @(Get-KnownKiosks)[0]
        Assert-Equal 'Shared' ([string]$k.Name) 'the registry row is intact'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
