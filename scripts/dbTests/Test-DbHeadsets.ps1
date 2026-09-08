#Requires -Version 5.1
<#
.SYNOPSIS
    Headset registry contracts, plus timers and the discovery proposal queue.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    The registry is the parent of nearly everything else: live status, timers,
    installed apps and favourites all hang off headsets(id) with a cascade. So
    these tests care about identity above all - that an id never moves, that a
    serial is the healing key, and that a DHCP address swap converges without
    an operator touching anything.

    Set-HeadsetIdentity is the function that matters most here. It is the ONLY
    serial-keyed writer of an address, and getting it wrong made a lease swap
    permanent: headset A's row inherited headset B's serial, destroying the one
    key that could have healed it.

    ASCII only.
#>

$modulesRoot = Join-Path -Path (Get-DbTestRepoRoot) -ChildPath 'modules'
. (Join-Path $modulesRoot 'logging.ps1')
. (Join-Path $modulesRoot 'utils.ps1')
# Test-ValidIPv4, used by the discovery module to reject a malformed address.
. (Join-Path $modulesRoot 'network_scanner.ps1')

# Every message these modules log goes through $msg. Without it each lookup is
# an undefined-variable error under strict mode, and Write-Log throws on an
# empty string even without it - the same reason each poll runspace loads
# translations before calling any module function.
$global:msg = Import-PowerShellDataFile -Path (Join-Path $modulesRoot 'translations\en-US.psd1')

function New-HeadsetSandbox {
    <#
    .SYNOPSIS
        Sandbox with a schema and the globals the registry module reads.
    .DESCRIPTION
        Save-Headsets regenerates HTML overlays and timer files as a side
        effect. Those helpers live in modules this layer does not load, so they
        are stubbed to no-ops: what is under test is persistence, and the
        regeneration is asserted by the non-regression harness against a real
        app instead.
    #>
    param([string]$Name = 'headset')
    $sandbox = New-TempDatabaseRoot -Name $Name
    Initialize-Database -Role Main -SkipBackup | Out-Null

    $logFolder = Join-Path $sandbox.Root 'logs'
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sandbox.Root 'website\generated') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sandbox.Root 'website\timer') -Force | Out-Null
    $global:logFolder             = $logFolder
    $global:logFile               = Join-Path $logFolder 'dbtest.log'
    $global:knownHeadsetsFilePath = Join-Path $sandbox.DataFolder 'known_headsets.csv'
    return $sandbox
}

# Side effects of Save-Headsets that belong to other modules.
function Write-htmlMonitor            { param($h) }
function Update-HeadsetMonitoringFile { }
function Update-HeadsetVideoFile      { }
function Update-HeadsetTimerFile      { }
function Get-ScrcpyProcess            { param($displayName, $headsetIP) return $null }
function Convert-Displayname          { param($Name) return ($Name -replace ' ', '_') }
function Stop-HeadsetTimer            { param($headsetId) }
function Get-TimerFilePath            { param($headsetId) return (Join-Path $global:ScriptPath "website\timer\$headsetId.txt") }
function Get-TimerRunFilePath         { param($headsetId) return (Join-Path $global:ScriptPath "website\timer\$headsetId.run") }
function Get-HeadsetSitePath          { param($Name, $Kind) return (Join-Path $global:ScriptPath "website\generated\$Name[$Kind].html") }

# The registry itself, loaded after the stubs so its real functions win.
. (Join-Path $modulesRoot 'headsets_manager.ps1')
. (Join-Path $modulesRoot 'timer.ps1')
. (Join-Path $modulesRoot 'headsets_discovery.ps1')

function Add-TestHeadset {
    param([string]$Name, [string]$Ip, [string]$Serial = '', [string]$Model = 'Quest 3')
    Add-Headset -IPAddress $Ip -Name $Name -Model $Model -SerialNumber $Serial
}

# ---------------------------------------------------------------------------
# Registry basics
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Get-KnownHeadsets returns the legacy shape in display order' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsshape'
    try {
        Add-TestHeadset -Name 'Q2 Dragon' -Ip '10.0.0.1' -Serial 'SER-A' -Model 'Quest 2'
        Add-TestHeadset -Name 'Q3 RED'    -Ip '10.0.0.2' -Serial 'SER-B'

        $rows = @(Get-KnownHeadsets)
        Assert-Equal 2 $rows.Count 'two headsets'
        foreach ($col in @('ID','Name','IPAddress','scrcpy_AutoRestart','Record','ScrcpyProfile','Brand','Model','SerialNumber')) {
            Assert-True ($rows[0].PSObject.Properties.Name -contains $col) ("legacy column {0} present" -f $col)
        }
        Add-TestEvidence ("ID type {0}; autoRestart '{1}'; record '{2}'" -f $rows[0].ID.GetType().Name, $rows[0].scrcpy_AutoRestart, $rows[0].Record)
        Assert-True ($rows[0].ID -is [string]) 'ID is TEXT so loose compares keep working'
        Assert-True ($rows[0].ID -eq 1) 'and still equals an int'
        Assert-Equal 'True'  ([string]$rows[0].scrcpy_AutoRestart) 'the default auto-restart is the string True'
        Assert-Equal 'False' ([string]$rows[0].Record)             'the default record flag is the string False'

        # ConvertTo-BoolField is what every consumer uses on these.
        Assert-True  (ConvertTo-BoolField $rows[0].scrcpy_AutoRestart) 'ConvertTo-BoolField reads True'
        Assert-False (ConvertTo-BoolField $rows[0].Record)             'ConvertTo-BoolField reads False'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Add-Headset rejects a duplicate address and a duplicate serial' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsdup'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'

        Add-TestHeadset -Name 'Impostor' -Ip '10.0.0.1' -Serial 'SER-Z'
        Assert-Equal 1 (@(Get-KnownHeadsets)).Count 'a duplicate address was refused'

        Add-TestHeadset -Name 'Clone' -Ip '10.0.0.9' -Serial 'SER-A'
        Assert-Equal 1 (@(Get-KnownHeadsets)).Count 'a duplicate serial was refused - moving a headset is Set-HeadsetIdentity''s job'

        # An EMPTY serial is not a duplicate: it means "not learned yet".
        Add-TestHeadset -Name 'NoSerial1' -Ip '10.0.0.10'
        Add-TestHeadset -Name 'NoSerial2' -Ip '10.0.0.11'
        Add-TestEvidence ("rows: {0}" -f ((@(Get-KnownHeadsets) | ForEach-Object { $_.Name }) -join ', '))
        Assert-Equal 3 (@(Get-KnownHeadsets)).Count 'two serial-less headsets can coexist'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'headset ids are permanent and never reused' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsids'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'
        Add-TestHeadset -Name 'B' -Ip '10.0.0.2' -Serial 'SER-B'
        Add-TestHeadset -Name 'C' -Ip '10.0.0.3' -Serial 'SER-C'

        Remove-Headset -ID 2
        $rows = @(Get-KnownHeadsets)
        Add-TestEvidence ("after removing 2: {0}" -f (($rows | ForEach-Object { "$($_.ID)=$($_.Name)" }) -join ', '))
        Assert-Equal 2 $rows.Count 'two remain'
        Assert-Equal 'C' ([string](@($rows | Where-Object { $_.ID -eq '3' })).Name) 'id 3 is still C'

        Add-TestHeadset -Name 'D' -Ip '10.0.0.4' -Serial 'SER-D'
        $d = @(Get-KnownHeadsets) | Where-Object { $_.Name -eq 'D' }
        Add-TestEvidence ("new headset D got id {0}" -f $d.ID)
        Assert-Equal '4' ([string]$d.ID) 'the freed id 2 was not reused'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Set-HeadsetsOrder changes display order without touching ids' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsorder'
    try {
        Add-TestHeadset -Name 'Q2 Dragon' -Ip '10.0.0.1' -Serial 'SER-A'
        Add-TestHeadset -Name 'Q3 RED'    -Ip '10.0.0.2' -Serial 'SER-B'
        Add-TestHeadset -Name 'Q3 Blue'   -Ip '10.0.0.3' -Serial 'SER-C'

        # Display names use underscores, as the web drag-and-drop sends them.
        Set-HeadsetsOrder -OrderedDisplayNames @('Q3_Blue', 'Q2_Dragon', 'Q3_RED')

        $rows = @(Get-KnownHeadsets)
        Add-TestEvidence ("order: {0}" -f (($rows | ForEach-Object { "$($_.Name)#$($_.ID)" }) -join ' | '))
        Assert-Equal 'Q3 Blue'   ([string]$rows[0].Name) 'the reorder took effect'
        Assert-Equal 'Q2 Dragon' ([string]$rows[1].Name) 'second position'
        Assert-Equal 'Q3 RED'    ([string]$rows[2].Name) 'third position'
        Assert-Equal '3' ([string]$rows[0].ID) 'and Q3 Blue kept id 3 - order is not identity'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Update-HeadsetField writes each field a caller uses' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsupd'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'

        Update-HeadsetField -ID 1 -Field 'Name'               -NewValue 'Renamed'
        Update-HeadsetField -ID 1 -Field 'Record'             -NewValue 'True'
        Update-HeadsetField -ID 1 -Field 'scrcpy_AutoRestart' -NewValue 'False'
        Update-HeadsetField -ID 1 -Field 'ScrcpyProfile'      -NewValue 'square-R-N-20-6'
        Update-HeadsetField -ID 1 -Field 'Brand'              -NewValue 'Meta'
        Update-HeadsetField -ID 1 -Field 'Model'              -NewValue 'Quest 3'

        $h = @(Get-KnownHeadsets)[0]
        Add-TestEvidence ("{0} record={1} auto={2} profile={3} {4}/{5}" -f $h.Name, $h.Record, $h.scrcpy_AutoRestart, $h.ScrcpyProfile, $h.Brand, $h.Model)
        Assert-Equal 'Renamed'          ([string]$h.Name)               'Name'
        Assert-Equal 'True'             ([string]$h.Record)             'Record became the string True'
        Assert-Equal 'False'            ([string]$h.scrcpy_AutoRestart) 'auto-restart became the string False'
        Assert-Equal 'square-R-N-20-6'  ([string]$h.ScrcpyProfile)      'profile'
        Assert-Equal 'Meta'             ([string]$h.Brand)              'brand'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'removing a headset cascades its dependent rows' -Test {
    # The CSV era deleted each per-headset file by hand, and missed one whenever
    # a rename had moved it first.
    $sandbox = New-HeadsetSandbox -Name 'hscascade'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'
        Add-TestHeadset -Name 'B' -Ip '10.0.0.2' -Serial 'SER-B'

        Invoke-DbNonQuery -Sql "INSERT INTO headset_status(headset_id) VALUES (1);" | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headset_installed_apps(headset_id,package_name,version) VALUES (1,'com.x','1.0');" | Out-Null
        Invoke-DbNonQuery -Sql "INSERT INTO headset_favorite_apps(headset_id,package_name,display_name) VALUES (1,'com.x','X');" | Out-Null
        Set-TimerConfig -headsetId 1 -minutes 10 -seconds 0 -mode 'dec'

        Remove-Headset -ID 1

        foreach ($t in @('headset_status','headset_installed_apps','headset_favorite_apps','headset_timers')) {
            $n = [int](Invoke-DbScalar -Sql ("SELECT COUNT(*) FROM {0} WHERE headset_id = 1;" -f $t))
            Add-TestEvidence ("{0}: {1} row(s) left for the removed headset" -f $t, $n)
            Assert-Equal 0 $n ("{0} cascaded" -f $t)
        }
        Assert-Equal 1 (@(Get-KnownHeadsets)).Count 'the other headset is untouched'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Set-HeadsetIdentity - the healing path
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Set-HeadsetIdentity moves a headset by serial' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsident'
    try {
        Add-TestHeadset -Name 'Q3 RED' -Ip '10.0.0.1' -Serial 'SER-A'

        $r = Set-HeadsetIdentity -SerialNumber 'SER-A' -IPAddress '10.0.0.50' -Source 'test'
        Add-TestEvidence ("action={0} id={1}" -f $r.Action, $r.ID)
        Assert-True $r.Ok 'the move succeeded'
        Assert-Equal 'updated' ([string]$r.Action) 'reported as an update'
        Assert-Equal '10.0.0.50' ([string](@(Get-KnownHeadsets)[0].IPAddress)) 'the address moved'
        Assert-Equal '1' ([string](@(Get-KnownHeadsets)[0].ID)) 'the id did not'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'an unchanged identity writes nothing at all' -Test {
    # The monitor calls this on every poll. If it saved each time, every poll
    # would rewrite the registry and regenerate every HTML overlay.
    $sandbox = New-HeadsetSandbox -Name 'hsnoop'
    try {
        Add-TestHeadset -Name 'Q3 RED' -Ip '10.0.0.1' -Serial 'SER-A'
        $version = Get-DbTableVersion -Name 'headsets'

        $r = Set-HeadsetIdentity -SerialNumber 'SER-A' -IPAddress '10.0.0.1' -Source 'test'
        Add-TestEvidence ("action={0}; table version {1} -> {2}" -f $r.Action, $version, (Get-DbTableVersion -Name 'headsets'))
        Assert-Equal 'unchanged' ([string]$r.Action) 'reported as unchanged'
        Assert-Equal $version (Get-DbTableVersion -Name 'headsets') 'and nothing was written'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a squatted address is released to an unknown-IP placeholder' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hssquat'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'
        Add-TestHeadset -Name 'B' -Ip '10.0.0.2' -Serial 'SER-B'

        # B's serial now answers at A's address: DHCP handed it over.
        $r = Set-HeadsetIdentity -SerialNumber 'SER-B' -IPAddress '10.0.0.1' -Source 'test'
        Add-TestEvidence ("action={0}; released {1}" -f $r.Action, (@($r.Released | ForEach-Object { "$($_.Name):$($_.OldIP)->$($_.NewIP)" }) -join ', '))
        Assert-True $r.Ok 'the move succeeded'
        Assert-Equal 1 (@($r.Released)).Count 'the squatting row was released'

        $rows = @(Get-KnownHeadsets)
        $a = @($rows | Where-Object { $_.SerialNumber -eq 'SER-A' })[0]
        $b = @($rows | Where-Object { $_.SerialNumber -eq 'SER-B' })[0]
        Assert-Equal '10.0.0.1' ([string]$b.IPAddress) 'B took the address'
        Assert-True (Test-UnknownIp $a.IPAddress) ("A was released to an unknown address ({0})" -f $a.IPAddress)
        Assert-Equal 2 $rows.Count 'no duplicate row was created'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a crossed DHCP pair converges in two calls with no operator action' -Test {
    # The failure this prevents: the registry used to overwrite a row's serial
    # with whatever answered at its address, which made the swap permanent and
    # destroyed the only key that could heal it.
    $sandbox = New-HeadsetSandbox -Name 'hsswap'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.10' -Serial 'SER-A'
        Add-TestHeadset -Name 'B' -Ip '10.0.0.11' -Serial 'SER-B'

        # The leases crossed: A is now at .11 and B at .10.
        Set-HeadsetIdentity -SerialNumber 'SER-B' -IPAddress '10.0.0.10' -Source 'test' | Out-Null
        Set-HeadsetIdentity -SerialNumber 'SER-A' -IPAddress '10.0.0.11' -Source 'test' | Out-Null

        $rows = @(Get-KnownHeadsets)
        $a = @($rows | Where-Object { $_.SerialNumber -eq 'SER-A' })[0]
        $b = @($rows | Where-Object { $_.SerialNumber -eq 'SER-B' })[0]
        Add-TestEvidence ("A={0} B={1}" -f $a.IPAddress, $b.IPAddress)
        Assert-Equal '10.0.0.11' ([string]$a.IPAddress) 'A ended up at the other address'
        Assert-Equal '10.0.0.10' ([string]$b.IPAddress) 'and B at As old one'
        Assert-Equal 2 $rows.Count 'still exactly two rows'
        Assert-Equal 'A' ([string]$a.Name) 'A kept its name'
        Assert-Equal '1' ([string]$a.ID)   'and its id'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'two headsets can swap addresses in a single save' -Test {
    # The regression this pins down: Save-Headsets writes rows one at a time, so
    # writing the row that is taking an address while the other still holds it
    # trips the UNIQUE index on ip_address. That is precisely a DHCP lease swap,
    # the case Set-HeadsetIdentity exists to heal - and it failed silently,
    # leaving the registry unchanged and healing permanently broken.
    $sandbox = New-HeadsetSandbox -Name 'hsswapsave'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'
        Add-TestHeadset -Name 'B' -Ip '10.0.0.2' -Serial 'SER-B'

        # Hand Save-Headsets both rows with their addresses exchanged, in the
        # order that used to break: the taker first.
        $rows = @(Get-KnownHeadsets)
        $a = @($rows | Where-Object { $_.SerialNumber -eq 'SER-A' })[0]
        $b = @($rows | Where-Object { $_.SerialNumber -eq 'SER-B' })[0]
        $a.IPAddress = '10.0.0.2'
        $b.IPAddress = '10.0.0.1'
        Save-Headsets -headsets @($a, $b)

        $after = @(Get-KnownHeadsets)
        $aAfter = @($after | Where-Object { $_.SerialNumber -eq 'SER-A' })[0]
        $bAfter = @($after | Where-Object { $_.SerialNumber -eq 'SER-B' })[0]
        Add-TestEvidence ("A={0} B={1}" -f $aAfter.IPAddress, $bAfter.IPAddress)
        Assert-Equal '10.0.0.2' ([string]$aAfter.IPAddress) 'A took Bs address'
        Assert-Equal '10.0.0.1' ([string]$bAfter.IPAddress) 'and B took As'
        Assert-Equal 2 $after.Count 'both rows survived'

        # No parked placeholder may be left behind.
        $parked = @($after | Where-Object { ([string]$_.IPAddress).StartsWith('park:') })
        Assert-Equal 0 $parked.Count 'no parked address leaked out of the transaction'

        # A three-way rotation exercises the same guard.
        Add-TestHeadset -Name 'C' -Ip '10.0.0.3' -Serial 'SER-C'
        $rows = @(Get-KnownHeadsets)
        $x = @($rows | Where-Object { $_.SerialNumber -eq 'SER-A' })[0]
        $y = @($rows | Where-Object { $_.SerialNumber -eq 'SER-B' })[0]
        $z = @($rows | Where-Object { $_.SerialNumber -eq 'SER-C' })[0]
        $x.IPAddress = '10.0.0.3'
        $y.IPAddress = '10.0.0.2'
        $z.IPAddress = '10.0.0.1'
        Save-Headsets -headsets @($x, $y, $z)

        $final = @(Get-KnownHeadsets)
        Add-TestEvidence ("rotation: {0}" -f (($final | ForEach-Object { "$($_.SerialNumber)=$($_.IPAddress)" }) -join ', '))
        Assert-Equal '10.0.0.3' ([string](@($final | Where-Object { $_.SerialNumber -eq 'SER-A' })[0].IPAddress)) 'A rotated'
        Assert-Equal '10.0.0.1' ([string](@($final | Where-Object { $_.SerialNumber -eq 'SER-C' })[0].IPAddress)) 'C rotated'
        Assert-Equal 3 $final.Count 'all three survived'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'an unknown serial is skipped unless adding is allowed' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsallowadd'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'

        $skipped = Set-HeadsetIdentity -SerialNumber 'SER-NEW' -IPAddress '10.0.0.5' -Source 'test'
        Add-TestEvidence ("without -AllowAdd: action={0}" -f $skipped.Action)
        Assert-Equal 'skipped' ([string]$skipped.Action) 'discovery reports it back rather than adding'
        Assert-Equal 1 (@(Get-KnownHeadsets)).Count 'nothing was added'

        $added = Set-HeadsetBySerial -SerialNumber 'SER-NEW' -IPAddress '10.0.0.5' -Name 'New one' -Model 'Quest 3'
        Add-TestEvidence ("via Set-HeadsetBySerial: action={0} id={1}" -f $added.Action, $added.ID)
        Assert-True $added.Ok 'the explicit add succeeded'
        Assert-Equal 'added' ([string]$added.Action) 'reported as added'
        Assert-Equal 2 (@(Get-KnownHeadsets)).Count 'and the row exists'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'timer configuration round-trips and defaults sensibly' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hstimer'
    try {
        Add-TestHeadset -Name 'A' -Ip '10.0.0.1' -Serial 'SER-A'

        $default = Get-TimerConfig -headsetId 1
        Add-TestEvidence ("default: {0}m{1}s {2}" -f $default.minutes, $default.seconds, $default.mode)
        Assert-Equal 5 ([int]$default.minutes) 'a headset gets a default timer'
        Assert-Equal 'dec' ([string]$default.mode) 'counting down by default'

        Set-TimerConfig -headsetId 1 -minutes 12 -seconds 30 -mode 'inc'
        $set = Get-TimerConfig -headsetId 1
        Assert-Equal 12 ([int]$set.minutes) 'minutes stored'
        Assert-Equal 30 ([int]$set.seconds) 'seconds stored'
        Assert-Equal 'inc' ([string]$set.mode) 'mode stored'

        # An unknown mode is coerced rather than rejected: the column has a CHECK
        # constraint, and a bad value would otherwise fail the whole write.
        Set-TimerConfig -headsetId 1 -minutes 1 -seconds 0 -mode 'sideways'
        Assert-Equal 'dec' ([string](Get-TimerConfig -headsetId 1).mode) 'an invalid mode falls back to dec'

        # A headset with no row at all still answers.
        $missing = Get-TimerConfig -headsetId 999
        Assert-Equal 5 ([int]$missing.minutes) 'an unknown headset gets the default'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'a pending proposal is recorded once and refreshed after' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsdisc'
    try {
        Assert-True (Add-PendingDiscoveredHeadset -SerialNumber 'SER-NEW' -IPAddress '10.0.0.7' -Model 'Quest 3' -Brand 'Meta') 'the proposal was recorded'
        $first = @(Get-PendingDiscoveredHeadsets)
        Assert-Equal 1 $first.Count 'one proposal pending'
        $firstSeen = [string]$first[0].FirstSeen

        Start-Sleep -Milliseconds 1100
        Add-PendingDiscoveredHeadset -SerialNumber 'SER-NEW' -IPAddress '10.0.0.8' -Model 'Quest 3' -Brand 'Meta' | Out-Null
        $second = @(Get-PendingDiscoveredHeadsets)
        Add-TestEvidence ("firstSeen {0} -> {1}; ip {2}" -f $firstSeen, $second[0].FirstSeen, $second[0].IPAddress)
        Assert-Equal 1 $second.Count 'still one proposal - deduped by serial'
        Assert-Equal '10.0.0.8' ([string]$second[0].IPAddress) 'the address was refreshed'
        Assert-Equal $firstSeen ([string]$second[0].FirstSeen) 'but first-seen was preserved'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a proposal disappears once its serial is known or forgotten' -Test {
    $sandbox = New-HeadsetSandbox -Name 'hsdiscprune'
    try {
        Add-PendingDiscoveredHeadset -SerialNumber 'SER-KNOWN'  -IPAddress '10.0.0.7' -Model 'Quest 3' -Brand 'Meta' | Out-Null
        Add-PendingDiscoveredHeadset -SerialNumber 'SER-FORGET' -IPAddress '10.0.0.8' -Model 'Quest 3' -Brand 'Meta' | Out-Null
        Add-PendingDiscoveredHeadset -SerialNumber 'SER-KEEP'   -IPAddress '10.0.0.9' -Model 'Quest 3' -Brand 'Meta' | Out-Null
        Assert-Equal 3 (@(Get-PendingDiscoveredHeadsets)).Count 'three proposals'

        # Registering one retires its proposal.
        Set-HeadsetBySerial -SerialNumber 'SER-KNOWN' -IPAddress '10.0.0.7' -Name 'Adopted' -Model 'Quest 3' | Out-Null
        # Forgetting one retires it too, permanently.
        Assert-True (Add-HeadsetDiscoveryIgnore -SerialNumber 'SER-FORGET') 'the device was forgotten'

        $pending = @(Get-PendingDiscoveredHeadsets)
        Add-TestEvidence ("still pending: {0}" -f (($pending | ForEach-Object { $_.SerialNumber }) -join ', '))
        Assert-Equal 1 $pending.Count 'only the untouched proposal remains'
        Assert-Equal 'SER-KEEP' ([string]$pending[0].SerialNumber) 'and it is the right one'

        # A forgotten device must not come back on the next sweep.
        Assert-False (Add-PendingDiscoveredHeadset -SerialNumber 'SER-FORGET' -IPAddress '10.0.0.8') 'a forgotten serial is refused'
        Assert-Equal 1 (@(Get-PendingDiscoveredHeadsets)).Count 'and stays gone'

        # But an explicit manual add still works, and clears the denylist.
        Assert-True (Test-HeadsetDiscoveryIgnored -SerialNumber 'SER-FORGET') 'still on the denylist'
        Assert-True (Remove-HeadsetDiscoveryIgnore -SerialNumber 'SER-FORGET') 'un-forgetting works'
        Assert-False (Test-HeadsetDiscoveryIgnored -SerialNumber 'SER-FORGET') 'and clears the entry'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the forget list is keyed on serial, never on address' -Test {
    # A device that moves must stay forgotten. Keying on the address would let
    # a DHCP change resurrect it.
    $sandbox = New-HeadsetSandbox -Name 'hsdiscserial'
    try {
        Add-HeadsetDiscoveryIgnore -SerialNumber 'SER-GONE' | Out-Null
        Assert-False (Add-PendingDiscoveredHeadset -SerialNumber 'SER-GONE' -IPAddress '10.0.0.7') 'refused at its old address'
        Assert-False (Add-PendingDiscoveredHeadset -SerialNumber 'SER-GONE' -IPAddress '10.0.0.99') 'and still refused at a new one'
        Assert-Equal 0 (@(Get-PendingDiscoveredHeadsets)).Count 'nothing pending'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
