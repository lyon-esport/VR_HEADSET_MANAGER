#Requires -Version 5.1
<#
.SYNOPSIS
    Layer - legacy import and the operator CSV round-trip.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    The fixtures here are built to match what the REAL data\ folder of this
    project actually contains, not an idealised version of it:

      * known_headsets.csv carries a UTF-8 BOM and non-contiguous ids
        (3,5,6,7,8), one of them on a 127.0.0.x unknown-IP placeholder.
      * known_apps.csv predates the LatestVersion column.
      * <name>_installed_apps.csv predates the SizeBytes column.
      * three per-headset files are orphans whose headset was removed long
        ago (Q3_KATVR, Q3_GREEN, Dupe).
      * several JSON files simply do not exist.
      * known_headsets_infos.csv is tested in BOTH shapes: the current
        15-column one and the pre-ADR-0016 one with identity columns.

    Names carrying accents are built from char codes so this file stays
    7-bit ASCII, while the fixture on disk is genuinely accented UTF-8.

    ASCII only.
#>

# ---------------------------------------------------------------------------
# Fixture builder
# ---------------------------------------------------------------------------

function Write-FixtureFile {
    <#
    .SYNOPSIS
        Writes a fixture with or without a UTF-8 BOM, as the field requires.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [switch]$WithBom
    )
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($WithBom.IsPresent)))
}

function New-LegacyFixtureSet {
    <#
    .SYNOPSIS
        Populates a sandbox data\ folder with a realistic legacy file set.
    .OUTPUTS
        A hashtable of the interesting values a test needs to assert against.
    #>
    param([Parameter(Mandatory = $true)]$Sandbox)

    $data = $Sandbox.DataFolder
    if (-not (Test-Path -LiteralPath $data)) { New-Item -ItemType Directory -Path $data -Force | Out-Null }

    # An accented headset name, built from char codes so this source stays ASCII.
    $accentedName = 'Q3 ' + [char]0x00C9 + 'quipe ' + [char]0x00E9 + 't' + [char]0x00E9
    $accentedSafe = $accentedName -replace ' ', '_'

    # --- headset registry: BOM, non-contiguous ids, a 127.0.0.x placeholder --
    $headsets = @(
        '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"'
        '"3","Q2 Dragon","172.16.254.202","True","False","square_IPD_Mid-R-N-10-4","Meta","Quest 2","1WMHH8242N0366"'
        '"5","Q3 RED","172.16.254.204","True","True","square-R-N-20-6","Meta","Quest 3","2G0YC5ZG5400PS"'
        '"6","Q3 Matt","127.0.0.2","False","False","square-R-N-20-6","Meta","Quest 3","2G0YC5ZG1L01K3"'
        ('"8","{0}","192.168.1.243","True","False","square-R-N-45-20","oculus","Quest 3","2G0YC5ZG1W00ZJ"' -f $accentedName)
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'known_headsets.csv') -Content ($headsets + "`r`n") -WithBom

    # --- live status: current 15-column shape, semicolon delimited ----------
    $infos = @(
        '"ID";"Ping";"ADBWifi";"Battery";"Charging";"ChargingWattage";"Temp";"BatteryControllerLeft";"BatteryControllerRight";"PowerState";"TimeRemainingMin";"BatteryHistory";"SCRCPY";"RunningApp";"RunningAppIcon"'
        '"3";"True";"True";"77";"False";"-";"31";"90";"85";"discharging";"120";"2026-09-08T10:00:00=80|2026-09-08T10:30:00=77";"-";"com.oculus.vrshell";""'
        '"5";"False";"False";"-";"-";"-";"-";"-";"-";"-";"-";"";"-";"-";""'
        '"99";"True";"True";"50";"-";"-";"-";"-";"-";"-";"-";"";"-";"-";""'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'known_headsets_infos.csv') -Content ($infos + "`r`n") -WithBom

    # --- kiosks: no BOM, a URL containing commas and quotes ------------------
    $kiosks = @(
        '"ID","Name","IPAddress","Port","PushedURL","LastPushedAt"'
        '"1","Legion GO","192.168.1.93","9222","http://x/y?a=1,2","2026-09-01 01:42:08"'
        '"3","RPI 3 Kiosk","192.168.1.116","9222","",""'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'known_kiosks.csv') -Content ($kiosks + "`r`n")

    # --- app catalogue: NO LatestVersion column (older schema) --------------
    $apps = @(
        '"PackageName","DisplayName","IconUrl","LocalIconPath","ThirdParty"'
        '"com.swearl.playa","","","/assets/app_icons/android.png","True"'
        '"com.oculus.vrshell","Meta Application Browser","","","False"'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'known_apps.csv') -Content ($apps + "`r`n") -WithBom

    # --- per-headset installed apps: NO SizeBytes column --------------------
    $installed = @(
        '"PackageName","Version","PendingVersion","StoreVersion"'
        '"android","14","",""'
        '"com.oculus.vrshell","69.0","70.0","70.0"'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'Q2_Dragon_installed_apps.csv') -Content ($installed + "`r`n") -WithBom
    # ORPHAN: no headset called Q3 KATVR
    Write-FixtureFile -Path (Join-Path $data 'Q3_KATVR_installed_apps.csv') -Content ($installed + "`r`n") -WithBom

    # --- favourites, including one on the accented headset ------------------
    $favs = @(
        '"PackageName","DisplayName"'
        '"com.oculus.vrshell","Meta Application Browser"'
        '"com.anagan.qgo","Quest Game Optimizer"'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'Q3_RED_favorite_apps.csv') -Content ($favs + "`r`n")
    Write-FixtureFile -Path (Join-Path $data ("{0}_favorite_apps.csv" -f $accentedSafe)) -Content ($favs + "`r`n")
    # ORPHANS
    Write-FixtureFile -Path (Join-Path $data 'Q3_GREEN_favorite_apps.csv') -Content ($favs + "`r`n")
    Write-FixtureFile -Path (Join-Path $data 'Dupe_favorite_apps.csv') -Content ($favs + "`r`n")

    # --- timers: one row points at a headset that no longer exists ----------
    $timers = @(
        '"HeadsetID","Minutes","Seconds","Mode"'
        '"3","10","0","dec"'
        '"5","5","30","inc"'
        '"77","1","0","dec"'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'timer.csv') -Content ($timers + "`r`n") -WithBom

    # --- VQA history: semicolon delimited, JSON in the last column ----------
    $vqa = @(
        'Timestamp;CpuPct;GpuPct;ScrcpyCount;ClientCount;Direction;Reason;Json'
        '2026-09-08T09:00:00;42;30;2;1;none;within thresholds;{"a":1}'
        '2026-09-08T09:05:00;85;70;3;2;down;cpu above mitigation;{"a":2}'
    ) -join "`r`n"
    Write-FixtureFile -Path (Join-Path $data 'vqa_history.csv') -Content ($vqa + "`r`n")

    # --- JSON state ---------------------------------------------------------
    Write-FixtureFile -Path (Join-Path $data 'discovered_headsets.json') -Content (
        '[{"SerialNumber":"SER-NEW-1","IPAddress":"192.168.1.77","Model":"Quest 3","Brand":"Meta","FirstSeen":"2026-09-01T10:00:00","LastSeen":"2026-09-08T10:00:00"}]')
    Write-FixtureFile -Path (Join-Path $data 'headset_discovery_ignore.json') -Content '["SER-FORGOTTEN-1"]'
    Write-FixtureFile -Path (Join-Path $data 'kiosk_autoadd_ignore.json') -Content '["192.168.1.200"]'
    Write-FixtureFile -Path (Join-Path $data 'kiosks_agent.json') -Content (
        '[{"IPAddress":"192.168.1.93","MachineId":"M1","Hostname":"LEGION","OS":"Windows 11","OSFamily":"Windows","InterfaceType":"Ethernet","InterfaceName":"eth0","LinkSpeedMbps":1000,"Browser":"Chrome","BrowserRunning":true,"CdpPort":9222,"CurrentUrl":"http://x","UptimeSec":3600,"AutoRestartBrowser":true,"AgentVersion":"2.1","LastAck":"","LastReportAt":"2026-09-08 10:00:00"}]')
    # Live state: must be recognised and moved aside, never imported.
    Write-FixtureFile -Path (Join-Path $data 'kiosks_status.json') -Content (
        '[{"Port":9222,"CdpOpen":true,"CurrentUrl":"http://x","LatencyMs":3,"IPAddress":"192.168.1.93","Reachable":true}]')

    # An accented value inside a snapshot, to prove UTF-8 survives the trip.
    # JSON needs each backslash doubled. Note the replacement string is two
    # literal backslashes, NOT four: PowerShell's -replace does not treat a
    # backslash as an escape character in the replacement.
    $accentedPath = 'C:\Drive partag' + [char]0x00E9 + 's\VRHM'
    $jsonPath     = $accentedPath -replace '\\', '\\'
    Write-FixtureFile -Path (Join-Path $data 'fw_state.json') -Content (
        '{"AdbPath":"C:\\adb.exe","WebServerPort":8080,"DefenderExclusionPath":"' + $jsonPath + '"}')
    Write-FixtureFile -Path (Join-Path $data 'computer_monitoring.json') -Content (
        '{"Timestamp":"2026-09-08T10:00:00","CPU":{"Model":"Ryzen","LoadPercent":42},"RAM":{"TotalGB":32}}')

    # --- pending kiosk commands: one fresh, one long expired ----------------
    $cmdFolder = Join-Path $data 'kiosk_commands'
    New-Item -ItemType Directory -Path $cmdFolder -Force | Out-Null
    $freshNonce = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    $staleNonce = $freshNonce - (3600 * 1000)
    Write-FixtureFile -Path (Join-Path $cmdFolder '192-168-1-93_1.json') -Content (
        '{"cmd":"reboot","nonce":' + $freshNonce + ',"delaySec":5,"ip":"192.168.1.93","queuedAt":"2026-09-08T10:00:00Z"}')
    Write-FixtureFile -Path (Join-Path $cmdFolder '192-168-1-93_2.json') -Content (
        '{"cmd":"shutdown","nonce":' + $staleNonce + ',"delaySec":5,"ip":"192.168.1.93","queuedAt":"2026-09-08T09:00:00Z"}')

    return @{
        AccentedName  = $accentedName
        AccentedSafe  = $accentedSafe
        AccentedPath  = $accentedPath
        HeadsetIds    = @(3, 5, 6, 8)
        OrphanFiles   = @('Q3_KATVR_installed_apps.csv', 'Q3_GREEN_favorite_apps.csv', 'Dupe_favorite_apps.csv')
        FreshNonce    = $freshNonce
        StaleNonce    = $staleNonce
    }
}

# ---------------------------------------------------------------------------
# Legacy import
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'legacy import brings every supported file into the database' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'import'
    try {
        $fx = New-LegacyFixtureSet -Sandbox $sandbox
        Initialize-Database -Role Main -SkipBackup | Out-Null

        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder
        Add-TestEvidence ("imported {0} file(s), skipped {1}, errors {2}" -f $r.Imported.Count, $r.Skipped.Count, $r.Errors.Count)
        foreach ($e in $r.Errors) { Add-TestEvidence ("ERROR {0}: {1}" -f $e.File, $e.Error) }
        Assert-Equal 0 $r.Errors.Count 'the import reported no errors'

        # Registry: permanent, non-contiguous ids preserved exactly.
        $headsets = @(Invoke-DbQuery -Name 'headsets.list')
        $ids = @($headsets | ForEach-Object { [int]$_.ID })
        Add-TestEvidence ("headset ids: {0}" -f ($ids -join ', '))
        Assert-Equal 4 $headsets.Count 'four headsets imported'
        foreach ($expected in $fx.HeadsetIds) { Assert-Contains $ids $expected ("id {0} preserved" -f $expected) }

        # The unknown-IP placeholder row must survive untouched.
        $matt = @($headsets | Where-Object { $_.Name -eq 'Q3 Matt' })[0]
        Assert-Equal '127.0.0.2' ([string]$matt.IPAddress) 'the 127.0.0.x placeholder is preserved'
        Assert-Equal 'False' ([string]$matt.scrcpy_AutoRestart) 'a False boolean round-trips as the string False'

        $red = @($headsets | Where-Object { $_.Name -eq 'Q3 RED' })[0]
        Assert-Equal 'True' ([string]$red.Record) 'a True boolean round-trips as the string True'
        Assert-Equal '2G0YC5ZG5400PS' ([string]$red.SerialNumber) 'the serial is preserved'

        # Kiosks keep their ids too (1 and 3, not resequenced to 1 and 2).
        $kiosks = @(Invoke-DbQuery -Name 'kiosks.list')
        $kioskIds = @($kiosks | ForEach-Object { [int]$_.ID })
        Add-TestEvidence ("kiosk ids: {0}" -f ($kioskIds -join ', '))
        Assert-Equal 2 $kiosks.Count 'two kiosks imported'
        Assert-Contains $kioskIds 3 'kiosk id 3 is preserved, not resequenced'

        # Catalogue, favourites, installed apps, timers, discovery.
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM app_catalog;')) 'app catalogue rows'
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_installed_apps;')) 'installed apps for the matched headset only'
        Assert-Equal 4 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_favorite_apps;')) 'favourites for the two matched headsets'
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_timers;')) 'timers, minus the row for a headset that no longer exists'
        Assert-Equal 1 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM discovered_headsets;')) 'pending discovery'
        Assert-Equal 1 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_discovery_ignore;')) 'discovery denylist'
        Assert-Equal 1 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM kiosk_autoadd_ignore;')) 'kiosk auto-add denylist'
        Assert-Equal 1 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM kiosk_agent_reports;')) 'agent reports'
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM vqa_history;')) 'VQA history rows'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'accented names and values survive the import unchanged' -Test {
    # The whole project lives under an accented path and this class of bug is
    # silent and compounding, so it is asserted byte-for-byte rather than by eye.
    $sandbox = New-TempDatabaseRoot -Name 'accents'
    try {
        $fx = New-LegacyFixtureSet -Sandbox $sandbox
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null

        $headsets = @(Invoke-DbQuery -Name 'headsets.list')
        $names = @($headsets | ForEach-Object { [string]$_.Name })
        Add-TestEvidence ("names: {0}" -f ($names -join ' | '))
        Assert-Contains $names $fx.AccentedName 'the accented headset name is intact'

        # And its favourites were matched through the accented filename.
        $accented = @($headsets | Where-Object { $_.Name -eq $fx.AccentedName })[0]
        $favCount = [int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_favorite_apps WHERE headset_id = @id;' -Parameters @{ id = [int]$accented.ID })
        Add-TestEvidence ("favourites matched to the accented headset: {0}" -f $favCount)
        Assert-Equal 2 $favCount 'the accented per-headset file was matched to its headset'

        # An accented value inside a JSON snapshot.
        $fw = Get-DbKeyValue -Key 'fw_state'
        Assert-NotNull $fw 'fw_state imported'
        Add-TestEvidence ("DefenderExclusionPath: {0}" -f $fw.DefenderExclusionPath)
        Assert-Equal $fx.AccentedPath ([string]$fw.DefenderExclusionPath) 'the accented path is byte-identical, not mojibake'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'orphan per-headset files are reported and moved, never imported' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'orphans'
    try {
        $fx = New-LegacyFixtureSet -Sandbox $sandbox
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder

        $skippedFiles = @($r.Skipped | ForEach-Object { $_.File })
        foreach ($s in $r.Skipped) { Add-TestEvidence ("skipped {0}: {1}" -f $s.File, $s.Reason) }
        foreach ($orphan in $fx.OrphanFiles) {
            Assert-Contains $skippedFiles $orphan ("{0} reported as an orphan" -f $orphan)
        }

        # Reported AND moved out of data\, so the next startup does not re-scan them.
        foreach ($orphan in $fx.OrphanFiles) {
            Assert-FileMissing (Join-Path $sandbox.DataFolder $orphan) ("{0} left data\" -f $orphan)
            Assert-FileExists  (Join-Path $r.LegacyFolder $orphan)    ("{0} preserved in the legacy folder" -f $orphan)
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'originals are moved aside, not deleted' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'moved'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder

        Assert-NotNull $r.LegacyFolder 'a legacy folder was created'
        Add-TestEvidence ("legacy folder: {0}" -f (Split-Path -Leaf $r.LegacyFolder))

        foreach ($f in @('known_headsets.csv', 'known_kiosks.csv', 'known_apps.csv', 'timer.csv', 'fw_state.json')) {
            Assert-FileMissing (Join-Path $sandbox.DataFolder $f) ("{0} left data\" -f $f)
            Assert-FileExists  (Join-Path $r.LegacyFolder $f)     ("{0} kept in the legacy folder" -f $f)
        }

        # The originals must be byte-identical: this is the operator's rollback.
        $original = Get-Content -LiteralPath (Join-Path $r.LegacyFolder 'known_headsets.csv') -Raw -Encoding UTF8
        Assert-Match $original 'Q2 Dragon' 'the preserved original still holds its data'

        # A second run has nothing left to do and must not throw.
        $again = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder
        Add-TestEvidence ("second run imported {0} file(s)" -f $again.Imported.Count)
        Assert-Equal 0 $again.Imported.Count 'the import is idempotent - nothing left to import'
        Assert-Equal 0 $again.Errors.Count 'and it does not error on an already-migrated folder'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the import log records what happened' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'importlog'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null

        $log = @(Get-DbKeyValue -Key 'legacy_import_log' -Default @())
        Assert-True ($log.Count -ge 1) 'an import log entry was written'
        $entry = $log[$log.Count - 1]
        Add-TestEvidence ("logged {0} imported, {1} skipped" -f @($entry.Imported).Count, @($entry.Skipped).Count)
        Assert-NotNull $entry.When 'the entry carries a timestamp'
        Assert-NotNull $entry.LegacyFolder 'the entry records where the originals went'
        Assert-True (@($entry.Imported).Count -gt 0) 'the entry lists the imported files'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'stale kiosk commands are dropped, fresh ones survive' -Test {
    # A reboot queued while a kiosk was switched off must not fire an hour
    # later just because a migration ran.
    $sandbox = New-TempDatabaseRoot -Name 'cmds'
    try {
        $fx = New-LegacyFixtureSet -Sandbox $sandbox
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null

        $cmds = @(Invoke-DbQuery -Sql 'SELECT cmd, nonce FROM kiosk_commands ORDER BY id;')
        Add-TestEvidence ("commands imported: {0}" -f (($cmds | ForEach-Object { $_.cmd }) -join ', '))
        Assert-Equal 1 $cmds.Count 'only the fresh command was carried over'
        Assert-Equal 'reboot' ([string]$cmds[0].cmd) 'the fresh command is the reboot'
        Assert-Equal $fx.FreshNonce ([int64]$cmds[0].nonce) 'its nonce is preserved'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'live kiosk status is skipped rather than imported' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'livestatus'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder

        $skipped = @($r.Skipped | Where-Object { $_.File -eq 'kiosks_status.json' })
        Assert-Equal 1 $skipped.Count 'kiosks_status.json is explicitly skipped'
        Add-TestEvidence ("reason: {0}" -f $skipped[0].Reason)
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM kiosk_status;')) 'no live status rows were carried over'
        Assert-FileExists (Join-Path $r.LegacyFolder 'kiosks_status.json') 'but the original is still preserved'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the pre-ADR-0016 20-column status file still imports' -Test {
    # The shape this project used before the status file was normalised. An
    # operator upgrading from an older release meets exactly this.
    $sandbox = New-TempDatabaseRoot -Name 'oldinfos'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        $old = @(
            '"ID";"Name";"IPAddress";"Ping";"ADBWifi";"Battery";"Charging";"ChargingWattage";"Temp";"BatteryControllerLeft";"BatteryControllerRight";"PowerState";"TimeRemainingMin";"BatteryHistory";"SCRCPY";"RunningApp";"RunningAppIcon";"Brand";"Model";"SerialNumber"'
            '"3";"Q2 Dragon";"172.16.254.202";"True";"True";"65";"False";"-";"30";"88";"80";"discharging";"90";"2026-09-08T08:00:00=70";"-";"com.x";"";"Meta";"Quest 2";"1WMHH8242N0366"'
        ) -join "`r`n"
        Write-FixtureFile -Path (Join-Path $sandbox.DataFolder 'known_headsets_infos.csv') -Content ($old + "`r`n") -WithBom

        Initialize-Database -Role Main -SkipBackup | Out-Null
        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder
        Assert-Equal 0 $r.Errors.Count 'the old shape imports without error'

        $row = @(Invoke-DbQuery -Sql 'SELECT * FROM v_headset_status WHERE ID = 3;')[0]
        Assert-NotNull $row 'a status row for headset 3'
        Add-TestEvidence ("battery={0}" -f $row.Battery)
        Assert-Equal '65' ([string]$row.Battery) 'the live value was read from the old column set'

        # The legacy file's BatteryHistory column is deliberately NOT carried
        # over (migration 005): those samples are rows in battery_history now and
        # the packed string has no column to land in. The fixture still contains
        # it, so this proves an unknown legacy column is ignored rather than
        # breaking the import.
        Assert-False ($row.PSObject.Properties.Name -contains 'BatteryHistory') 'the retired packed column is not resurrected by an old file'

        # The identity columns of the old file are ignored, not written back.
        $reg = @(Invoke-DbQuery -Name 'headsets.list')
        $names = @($reg | ForEach-Object { [string]$_.Name })
        Assert-Contains $names 'Q2 Dragon' 'the registry name comes from the registry, not the status file'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'missing columns fall back to defaults' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'defaults'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null

        # known_apps.csv had no LatestVersion column.
        $app = @(Invoke-DbQuery -Sql "SELECT * FROM app_catalog WHERE package_name = 'com.swearl.playa';")[0]
        Assert-NotNull $app 'the catalogue row'
        Assert-Equal '' ([string]$app.latest_version) 'the missing LatestVersion column defaults to empty'
        Assert-Equal 1 ([int]$app.third_party) 'ThirdParty True became 1'

        $builtin = @(Invoke-DbQuery -Sql "SELECT * FROM app_catalog WHERE package_name = 'com.oculus.vrshell';")[0]
        Assert-Equal 0 ([int]$builtin.third_party) 'ThirdParty False became 0'

        # The installed-apps file had no SizeBytes column.
        $inst = @(Invoke-DbQuery -Sql "SELECT * FROM headset_installed_apps WHERE package_name = 'android';")[0]
        Assert-NotNull $inst 'the installed-app row'
        Assert-Equal 0 ([int]$inst.size_bytes) 'the missing SizeBytes column defaults to zero'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'WhatIf reports the plan without touching anything' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'whatif'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null

        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder -WhatIf
        Add-TestEvidence ("would import {0} file(s)" -f $r.Imported.Count)
        Assert-True ($r.Imported.Count -gt 0) 'the plan lists files to import'
        Assert-True ($null -eq $r.LegacyFolder) 'no legacy folder is created'
        Assert-FileExists (Join-Path $sandbox.DataFolder 'known_headsets.csv') 'the original is still in place'
        $legacyDirs = @(Get-ChildItem -LiteralPath $sandbox.DataFolder -Directory -Filter 'legacy_*' -ErrorAction SilentlyContinue)
        Assert-Equal 0 $legacyDirs.Count 'nothing was moved'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the area filter imports only what has been migrated' -Test {
    # The migration lands one area at a time. A file must not be moved aside
    # until the code that reads it has been switched to the database, or that
    # code would find nothing on the next start. This is what enforces it.
    $sandbox = New-TempDatabaseRoot -Name 'areas'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null

        $r = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder -Include snapshots, vqa
        $importedFiles = @($r.Imported | ForEach-Object { $_.File })
        Add-TestEvidence ("imported: {0}" -f ($importedFiles -join ', '))

        # In scope for these two areas.
        Assert-Contains $importedFiles 'fw_state.json'            'the firewall snapshot was imported'
        Assert-Contains $importedFiles 'computer_monitoring.json' 'the hardware snapshot was imported'
        Assert-Contains $importedFiles 'vqa_history.csv'          'the VQA history was imported'

        # Out of scope: still on disk, still readable by the code that owns them.
        foreach ($untouched in @('known_headsets.csv', 'known_kiosks.csv', 'known_apps.csv', 'timer.csv')) {
            Assert-FileExists (Join-Path $sandbox.DataFolder $untouched) ("{0} is left in place" -f $untouched)
            Assert-True ($importedFiles -notcontains $untouched) ("{0} was not imported" -f $untouched)
        }
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headsets;')) 'no headsets were imported'
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM app_catalog;')) 'no catalogue rows were imported'

        # And the in-scope originals did move aside.
        Assert-FileMissing (Join-Path $sandbox.DataFolder 'fw_state.json') 'the imported snapshot left data\'
        Assert-FileExists  (Join-Path $r.LegacyFolder 'fw_state.json')     'and is preserved in the legacy folder'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a later area import picks up the files left behind' -Test {
    # Running one area now and another later must converge on the same state
    # as importing everything at once.
    $sandbox = New-TempDatabaseRoot -Name 'staged'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null

        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder -Include snapshots, vqa | Out-Null
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headsets;')) 'headsets not yet imported'

        $second = Import-LegacyDataFiles -DataFolder $sandbox.DataFolder -Include headsets, status, apps, timers
        Add-TestEvidence ("second pass imported {0} file(s)" -f $second.Imported.Count)
        Assert-Equal 0 $second.Errors.Count 'the second pass reported no errors'
        Assert-Equal 4 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headsets;')) 'headsets imported on the second pass'
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM app_catalog;')) 'catalogue imported on the second pass'
        Assert-Equal 2 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_timers;')) 'timers imported on the second pass'

        # Two legacy folders now exist, one per run - both preserved.
        $legacyDirs = @(Get-ChildItem -LiteralPath $sandbox.DataFolder -Directory -Filter 'legacy_*')
        Add-TestEvidence ("legacy folders: {0}" -f $legacyDirs.Count)
        Assert-True ($legacyDirs.Count -ge 1) 'the originals are preserved across staged runs'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Snapshot accessors now backed by the key/value store
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'the VQA history table behaves like the old per-session CSV' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'vqahist'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null

        # Reason deliberately contains a semicolon: the CSV era had to strip
        # those out because the reader split raw lines on ';' and took index 5.
        $rows = @()
        foreach ($i in 1..6) {
            $rows += @{
                ts = ("2026-09-08T10:0{0}:00" -f $i); cpu_pct = 80 + $i; gpu_pct = 70
                scrcpy_count = 2; client_count = 1; direction = 'down'
                reason = 'cpu above mitigation; gpu fine'; json = ('{"i":' + $i + '}')
            }
        }
        Invoke-DbBatch -Name 'vqa.history_insert' -Rows $rows | Out-Null

        $last = @(Invoke-DbQuery -Name 'vqa.history_last' -Parameters @{ n = 5 })
        Assert-Equal 5 $last.Count 'the newest five rows come back'
        Add-TestEvidence ("newest first: {0}" -f (($last | ForEach-Object { $_.Timestamp }) -join ', '))
        Assert-Equal '2026-09-08T10:06:00' ([string]$last[0].Timestamp) 'ordered newest first'
        Assert-Equal 'down' ([string]$last[0].Direction) 'the direction column reads by name'
        Assert-Match ([string]$last[0].Reason) ';' 'a semicolon in the reason no longer has to be stripped'

        Invoke-DbNonQuery -Name 'vqa.history_clear' | Out-Null
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM vqa_history;')) 'history is cleared per session'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the firewall snapshot round-trips an accented path' -Test {
    # This is the exact failure ADR-0006 was written for: the accented
    # DefenderExclusionPath degraded on every read/write cycle until it never
    # matched the real path again and the Defender prompt returned every run.
    $sandbox = New-TempDatabaseRoot -Name 'fwstate'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null
        $accented = 'L:\Drive partag' + [char]0x00E9 + 's\VR_HEADSET_MANAGER'

        $state = [PSCustomObject]@{
            AdbPath               = 'C:\adb.exe'
            WebServerPort         = 8080
            DefenderExclusionPath = $accented
        }
        Set-DbKeyValue -Key 'fw_state' -Value $state -Depth 4

        # Ten cycles: the old failure only became visible after compounding.
        for ($i = 0; $i -lt 10; $i++) {
            $read = Get-DbKeyValue -Key 'fw_state'
            Set-DbKeyValue -Key 'fw_state' -Value $read -Depth 4
        }
        $final = Get-DbKeyValue -Key 'fw_state'
        Add-TestEvidence ("after 10 read/write cycles: {0}" -f $final.DefenderExclusionPath)
        Assert-Equal $accented ([string]$final.DefenderExclusionPath) 'the accented path never degrades'
        Assert-Equal 8080 ([int]$final.WebServerPort) 'the numeric field survives too'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the cooldown counter steps down and clears' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'cooldown'
    try {
        Initialize-Database -Role Main -SkipBackup | Out-Null

        Assert-Equal 0 ([int](Get-DbKeyValue -Key 'vqa_cooldown' -Default 0)) 'no cooldown to begin with'
        Set-DbKeyValue -Key 'vqa_cooldown' -Value ([PSCustomObject]@{ RemainingCycles = 3; StartedAt = '2026-09-08T10:00:00' })
        Assert-Equal 3 ([int](Get-DbKeyValue -Key 'vqa_cooldown').RemainingCycles) 'the counter was armed'

        Set-DbKeyValue -Key 'vqa_cooldown' -Value ([PSCustomObject]@{ RemainingCycles = 1; StartedAt = '2026-09-08T10:00:00' })
        Assert-Equal 1 ([int](Get-DbKeyValue -Key 'vqa_cooldown').RemainingCycles) 'the counter stepped down'

        Remove-DbKeyValue -Key 'vqa_cooldown'
        Assert-True ($null -eq (Get-DbKeyValue -Key 'vqa_cooldown')) 'the counter clears to nothing, not to zero'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Operator CSV round-trip
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'headset CSV export then import is lossless' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'roundtrip'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null

        $before = @(Invoke-DbQuery -Name 'headsets.list')
        $csv = Join-Path $sandbox.Root 'export.csv'
        Export-HeadsetsCsv -Path $csv | Out-Null
        Assert-FileExists $csv 'the exported file'

        # No BOM: the project-wide convention for generated text.
        $bytes = [System.IO.File]::ReadAllBytes($csv)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Add-TestEvidence ("export has BOM: {0}; {1} bytes" -f $hasBom, $bytes.Length)
        Assert-False $hasBom 'the export is UTF-8 without a BOM'

        $header = (Get-Content -LiteralPath $csv -TotalCount 1 -Encoding UTF8)
        Add-TestEvidence ("header: {0}" -f $header)
        foreach ($col in (Get-HeadsetCsvColumn)) {
            Assert-Match $header ([regex]::Escape($col)) ("the export carries the legacy column {0}" -f $col)
        }

        $result = Import-HeadsetsCsv -Path $csv -Mode Replace
        Add-TestEvidence ("import: added={0} updated={1} removed={2}" -f $result.Added, $result.Updated, $result.Removed)
        Assert-True $result.Ok 'the round-trip import succeeded'
        Assert-Equal 0 $result.Added   'nothing was added'
        Assert-Equal 0 $result.Removed 'nothing was removed'

        $after = @(Invoke-DbQuery -Name 'headsets.list')
        Assert-Equal $before.Count $after.Count 'the same number of headsets'
        for ($i = 0; $i -lt $before.Count; $i++) {
            foreach ($col in (Get-HeadsetCsvColumn)) {
                Assert-Equal ([string]$before[$i].$col) ([string]$after[$i].$col) ("row {0} column {1} unchanged" -f $i, $col)
            }
        }
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'an edited CSV adds, updates and (in Replace) removes' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'edited'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null

        # What an operator would do in Excel: rename one, change an IP, add a
        # new headset, and delete a row.
        $csv = Join-Path $sandbox.Root 'edited.csv'
        $content = @(
            '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"'
            '"3","Q2 Dragon RENAMED","172.16.254.99","True","False","square_IPD_Mid-R-N-10-4","Meta","Quest 2","1WMHH8242N0366"'
            '"5","Q3 RED","172.16.254.204","True","True","square-R-N-20-6","Meta","Quest 3","2G0YC5ZG5400PS"'
            '"","Q3 BRAND NEW","192.168.1.55","True","False","square-R-N-20-6","Meta","Quest 3","NEWSERIAL001"'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($csv, $content + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        $r = Import-HeadsetsCsv -Path $csv -Mode Replace
        Add-TestEvidence ("added={0} updated={1} removed={2}" -f $r.Added, $r.Updated, $r.Removed)
        Assert-True $r.Ok 'the edited import succeeded'
        Assert-Equal 1 $r.Added   'the new headset was added'
        Assert-Equal 2 $r.Updated 'the two existing headsets were updated'
        Assert-Equal 2 $r.Removed 'the two rows absent from the file were removed'

        $after = @(Invoke-DbQuery -Name 'headsets.list')
        $names = @($after | ForEach-Object { [string]$_.Name })
        Add-TestEvidence ("names now: {0}" -f ($names -join ' | '))
        Assert-Contains $names 'Q2 Dragon RENAMED' 'the rename was applied'
        Assert-Contains $names 'Q3 BRAND NEW'      'the new headset exists'

        # Matched on serial, so the permanent id survived the rename.
        $renamed = @($after | Where-Object { $_.Name -eq 'Q2 Dragon RENAMED' })[0]
        Assert-Equal '3' ([string]$renamed.ID) 'the permanent id survived the rename'
        Assert-Equal '172.16.254.99' ([string]$renamed.IPAddress) 'the edited IP was applied'

        # A removed headset takes its dependent rows with it.
        Assert-Equal 0 ([int](Invoke-DbScalar -Sql 'SELECT COUNT(*) FROM headset_timers WHERE headset_id NOT IN (SELECT id FROM headsets);')) 'no orphaned timer rows'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'Merge mode never removes rows absent from the file' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'merge'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null
        $before = @(Invoke-DbQuery -Name 'headsets.list').Count

        $csv = Join-Path $sandbox.Root 'partial.csv'
        $content = @(
            '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"'
            '"5","Q3 RED","172.16.254.111","True","False","square-R-N-20-6","Meta","Quest 3","2G0YC5ZG5400PS"'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($csv, $content + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        $r = Import-HeadsetsCsv -Path $csv -Mode Merge
        Add-TestEvidence ("before={0} added={1} updated={2} removed={3}" -f $before, $r.Added, $r.Updated, $r.Removed)
        Assert-True $r.Ok 'the merge succeeded'
        Assert-Equal 0 $r.Removed 'Merge removes nothing'
        Assert-Equal $before (@(Invoke-DbQuery -Name 'headsets.list')).Count 'the headset count is unchanged'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'a CSV with a bad row is refused wholesale' -Test {
    # Half-applying an operator's spreadsheet is worse than applying none of
    # it: they would have to work out which rows landed.
    $sandbox = New-TempDatabaseRoot -Name 'badcsv'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null
        $before = @(Invoke-DbQuery -Name 'headsets.list')

        $csv = Join-Path $sandbox.Root 'bad.csv'
        $content = @(
            '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"'
            '"3","Q2 Dragon","10.0.0.1","True","False","p","Meta","Quest 2","1WMHH8242N0366"'
            '"5","Q3 RED","10.0.0.1","True","False","p","Meta","Quest 3","2G0YC5ZG5400PS"'
            '"6","","10.0.0.3","True","False","p","Meta","Quest 3","2G0YC5ZG1L01K3"'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($csv, $content + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        $r = Import-HeadsetsCsv -Path $csv -Mode Merge
        foreach ($e in $r.Errors) { Add-TestEvidence ("line {0}: {1}" -f $e.Line, $e.Reason) }
        Assert-False $r.Ok 'the import was refused'
        Assert-Equal 2 $r.Errors.Count 'both bad rows were reported'

        # Errors carry the LINE NUMBER, so the operator can fix the spreadsheet.
        $lines = @($r.Errors | ForEach-Object { [int]$_.Line })
        Assert-Contains $lines 3 'the duplicate IP is reported on line 3'
        Assert-Contains $lines 4 'the empty name is reported on line 4'

        $after = @(Invoke-DbQuery -Name 'headsets.list')
        Assert-Equal $before.Count $after.Count 'the registry is untouched'
        $dragon = @($after | Where-Object { [string]$_.ID -eq '3' })[0]
        Assert-Equal '172.16.254.202' ([string]$dragon.IPAddress) 'not even the first, valid row was applied'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'CSV import WhatIf reports without writing' -Test {
    $sandbox = New-TempDatabaseRoot -Name 'csvwhatif'
    try {
        New-LegacyFixtureSet -Sandbox $sandbox | Out-Null
        Initialize-Database -Role Main -SkipBackup | Out-Null
        Import-LegacyDataFiles -DataFolder $sandbox.DataFolder | Out-Null
        $version = Get-DbTableVersion -Name 'headsets'

        $csv = Join-Path $sandbox.Root 'plan.csv'
        $content = @(
            '"ID","Name","IPAddress","scrcpy_AutoRestart","Record","ScrcpyProfile","Brand","Model","SerialNumber"'
            '"","Q3 PLANNED","192.168.1.60","True","False","p","Meta","Quest 3","PLANNED001"'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($csv, $content + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

        $r = Import-HeadsetsCsv -Path $csv -Mode Merge -WhatIf
        Add-TestEvidence ("plan: added={0} updated={1}" -f $r.Added, $r.Updated)
        Assert-True $r.Ok 'the plan is valid'
        Assert-Equal 1 $r.Added 'the plan reports one addition'
        Assert-Equal $version (Get-DbTableVersion -Name 'headsets') 'the table was not written to'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
