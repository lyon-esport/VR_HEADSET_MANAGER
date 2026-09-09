#Requires -Version 5.1
<#
.SYNOPSIS
    App catalogue, per-headset installed apps and per-headset favourites.

.DESCRIPTION
    Dot-sourced by Invoke-DbTests.ps1 inside a section context.

    This is the area with the most concurrent writers in the whole application.
    Before the migration, Get-AppInfo and Update-InstalledAppsCache both did a
    read-modify-write of the ENTIRE known_apps.csv, and Get-AppInfo runs in every
    per-headset monitoring runspace on every poll - so N headsets meant N
    processes rewriting one unlocked file, last writer wins. These tests pin the
    replacement: single-row upserts, clear-then-insert inside one transaction,
    and rows that hang off headsets(id) rather than off a filename.

    Two things here are regression tests for defects found while migrating:
      * the change counters, which migration 002 fixes for the upsert path
      * name resolution, which has to accept both spellings of a headset name

    ASCII only.
#>

$modulesRoot = Join-Path -Path (Get-DbTestRepoRoot) -ChildPath 'modules'
. (Join-Path $modulesRoot 'logging.ps1')
. (Join-Path $modulesRoot 'utils.ps1')
. (Join-Path $modulesRoot 'network_scanner.ps1')

$global:msg = Import-PowerShellDataFile -Path (Join-Path $modulesRoot 'translations\en-US.psd1')

# Side effects that belong to modules this layer does not load.
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

function New-AppsSandbox {
    <#
    .SYNOPSIS
        Sandbox with a schema, the registry globals, and two headsets.
    #>
    param([string]$Name = 'apps')
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

function Add-CatalogEntry {
    param(
        [string]$Package,
        [string]$Display = '',
        [string]$Icon = '',
        [string]$LocalIcon = '',
        [int]$ThirdParty = 1,
        [string]$Latest = ''
    )
    Invoke-DbNonQuery -Name 'catalog.upsert' -Parameters @{
        package_name    = $Package
        display_name    = $Display
        icon_url        = $Icon
        local_icon_path = $LocalIcon
        third_party     = $ThirdParty
        latest_version  = $Latest
    } | Out-Null
}

function Add-InstalledRow {
    param([int]$HeadsetId, [string]$Package, [string]$Version = '1.0', [int64]$Size = 0)
    Invoke-DbNonQuery -Name 'installed.insert' -Parameters @{
        headset_id      = $HeadsetId
        package_name    = $Package
        version         = $Version
        pending_version = ''
        store_version   = ''
        size_bytes      = $Size
    } | Out-Null
}

# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'catalogue round-trip keeps the legacy CSV shape' -Test {
    $sandbox = New-AppsSandbox -Name 'appcat'
    try {
        Add-CatalogEntry -Package 'com.example.game' -Display 'Example Game' -Icon 'http://x/i.png' -LocalIcon '/assets/app_icons/com.example.game.png' -ThirdParty 1 -Latest '2.5'
        Add-CatalogEntry -Package 'com.oculus.shell' -Display 'Shell' -ThirdParty 0

        $rows = @(Invoke-DbQuery -Name 'catalog.list')
        Assert-Equal 2 $rows.Count 'two catalogue entries'
        foreach ($col in @('PackageName','DisplayName','IconUrl','LocalIconPath','ThirdParty','LatestVersion')) {
            Assert-True ($rows[0].PSObject.Properties.Name -contains $col) ("legacy column {0} present" -f $col)
        }

        $game = @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = 'com.example.game' })
        Assert-Equal 1 $game.Count 'catalog.get returns exactly one row'
        Assert-Equal 'Example Game' ([string]$game[0].DisplayName) 'display name survives'
        Assert-Equal '2.5' ([string]$game[0].LatestVersion) 'latest version survives'

        # The booleans come back as the strings every consumer already parses.
        Add-TestEvidence ("thirdParty values: '{0}' / '{1}'" -f $rows[0].ThirdParty, $rows[1].ThirdParty)
        Assert-True  (ConvertTo-BoolField $game[0].ThirdParty) 'a third-party app reads as true'
        $shell = @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = 'com.oculus.shell' })
        Assert-False (ConvertTo-BoolField $shell[0].ThirdParty) 'a system app reads as false'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'catalogue upsert replaces in place and delete removes one row' -Test {
    $sandbox = New-AppsSandbox -Name 'appcatupd'
    try {
        Add-CatalogEntry -Package 'com.example.game' -Display 'Old Name'
        Add-CatalogEntry -Package 'com.example.game' -Display 'New Name'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'catalog.list')).Count 'upsert did not duplicate the row'
        $row = @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = 'com.example.game' })
        Assert-Equal 'New Name' ([string]$row[0].DisplayName) 'the second write won'

        Add-CatalogEntry -Package 'com.example.other' -Display 'Other'
        Invoke-DbNonQuery -Name 'catalog.delete' -Parameters @{ package_name = 'com.example.game' } | Out-Null
        $left = @(Invoke-DbQuery -Name 'catalog.list')
        Assert-Equal 1 $left.Count 'delete removed exactly one row'
        Assert-Equal 'com.example.other' ([string]$left[0].PackageName) 'and removed the right one'

        Invoke-DbNonQuery -Name 'catalog.clear' | Out-Null
        Assert-Equal 0 (@(Invoke-DbQuery -Name 'catalog.list')).Count 'clear empties the catalogue'
        Assert-Equal 0 ([int](Invoke-DbScalar -Name 'catalog.count')) 'and catalog.count agrees'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Name resolution
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Resolve-HeadsetIdByName accepts both spellings of a name' -Test {
    $sandbox = New-AppsSandbox -Name 'appresolve'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $expected = [int](@(Get-KnownHeadsets) | Where-Object { $_.Name -eq 'Q3 RED' }).ID

        # The console passes the real name; the web server passes the
        # underscore-converted form it used to build a filename from. Both have
        # to land on the same headset or the web UI silently shows no apps.
        Assert-Equal $expected (Resolve-HeadsetIdByName -Name 'Q3 RED') 'the name with a space resolves'
        Assert-Equal $expected (Resolve-HeadsetIdByName -Name 'Q3_RED') 'the underscore form resolves to the same id'
        Assert-Equal 0 (Resolve-HeadsetIdByName -Name 'Nope')  'an unknown name is 0, not an error'
        Assert-Equal 0 (Resolve-HeadsetIdByName -Name '')      'an empty name is 0'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Installed apps
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'installed apps replace wholesale, so an uninstall disappears' -Test {
    $sandbox = New-AppsSandbox -Name 'appinst'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'Q3 RED'

        Add-InstalledRow -HeadsetId $id -Package 'com.a' -Version '1.0'
        Add-InstalledRow -HeadsetId $id -Package 'com.b' -Version '1.0'
        Assert-Equal 2 (@(Invoke-DbQuery -Name 'installed.list' -Parameters @{ headset_id = $id })).Count 'two apps cached'

        # What Update-InstalledAppsCache does: clear, then insert the live set.
        Invoke-DbTransaction -Script {
            Invoke-DbNonQuery -Name 'installed.delete_for_headset' -Parameters @{ headset_id = $id } | Out-Null
            Invoke-DbNonQuery -Name 'installed.insert' -Parameters @{
                headset_id = $id; package_name = 'com.b'; version = '2.0'
                pending_version = ''; store_version = ''; size_bytes = [int64]500
            } | Out-Null
        } | Out-Null

        $rows = @(Invoke-DbQuery -Name 'installed.list' -Parameters @{ headset_id = $id })
        Add-TestEvidence ("remaining: {0}" -f (($rows | ForEach-Object { $_.PackageName }) -join ', '))
        Assert-Equal 1 $rows.Count 'the uninstalled app is gone'
        Assert-Equal 'com.b' ([string]$rows[0].PackageName) 'the surviving app is the right one'
        Assert-Equal '2.0'   ([string]$rows[0].Version)     'and carries its new version'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'installed.list_joined grafts catalogue metadata back on' -Test {
    $sandbox = New-AppsSandbox -Name 'appjoin'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'Q3 RED'

        Add-CatalogEntry -Package 'com.known' -Display 'Known Game' -LocalIcon '/assets/app_icons/com.known.png' -ThirdParty 1
        Add-InstalledRow -HeadsetId $id -Package 'com.known'
        # Installed but absent from the catalogue: the LEFT JOIN must still list
        # it, which is why the console menu showed blanks before this existed.
        Add-InstalledRow -HeadsetId $id -Package 'com.unknown'

        $rows = @(Invoke-DbQuery -Name 'installed.list_joined' -Parameters @{ headset_id = $id })
        Assert-Equal 2 $rows.Count 'both apps listed'

        $known = $rows | Where-Object { $_.PackageName -eq 'com.known' }
        Assert-Equal 'Known Game' ([string]$known.DisplayName) 'display name comes from the catalogue'
        Assert-Equal '/assets/app_icons/com.known.png' ([string]$known.LocalIconPath) 'icon path comes from the catalogue'

        $unknown = $rows | Where-Object { $_.PackageName -eq 'com.unknown' }
        Assert-Equal 'com.unknown' ([string]$unknown.DisplayName) 'an uncatalogued app falls back to its package name'
        Assert-True (ConvertTo-BoolField $unknown.ThirdParty) 'and defaults to third-party, never to system'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Favourites
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'favourites keep their order across a save and a reorder' -Test {
    $sandbox = New-AppsSandbox -Name 'appfav'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'Q3 RED'

        $order = 0
        foreach ($p in @('com.c', 'com.a', 'com.b')) {
            Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{
                headset_id = $id; package_name = $p; display_name = $p.ToUpper(); sort_order = $order
            } | Out-Null
            $order++
        }

        $rows = @(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $id })
        Add-TestEvidence ("order: {0}" -f (($rows | ForEach-Object { $_.PackageName }) -join ' > '))
        Assert-Equal 'com.c' ([string]$rows[0].PackageName) 'insertion order is preserved, not alphabetical order'
        Assert-Equal 'com.a' ([string]$rows[1].PackageName) 'second in insertion order'
        Assert-Equal 'com.b' ([string]$rows[2].PackageName) 'third in insertion order'

        # A reorder is an upsert of the same rows with new sort_order values.
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{
            headset_id = $id; package_name = 'com.b'; display_name = 'COM.B'; sort_order = 0
        } | Out-Null
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{
            headset_id = $id; package_name = 'com.c'; display_name = 'COM.C'; sort_order = 2
        } | Out-Null
        $rows = @(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $id })
        Assert-Equal 3 $rows.Count 'a reorder does not duplicate rows'
        Assert-Equal 'com.b' ([string]$rows[0].PackageName) 'the reorder took effect'

        Invoke-DbNonQuery -Name 'favorites.delete' -Parameters @{ headset_id = $id; package_name = 'com.a' } | Out-Null
        Assert-Equal 2 (@(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $id })).Count 'one favourite removed'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'favourites are scoped to one headset' -Test {
    $sandbox = New-AppsSandbox -Name 'appfavscope'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        $idA = Resolve-HeadsetIdByName -Name 'A'
        $idB = Resolve-HeadsetIdByName -Name 'B'

        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $idA; package_name = 'com.a'; display_name = ''; sort_order = 0 } | Out-Null
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $idB; package_name = 'com.b'; display_name = ''; sort_order = 0 } | Out-Null

        Invoke-DbNonQuery -Name 'favorites.delete_for_headset' -Parameters @{ headset_id = $idA } | Out-Null
        Assert-Equal 0 (@(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $idA })).Count 'A was cleared'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $idB })).Count 'B was untouched'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Lifecycle: cascade and rename
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'removing a headset cascades to its apps and favourites' -Test {
    $sandbox = New-AppsSandbox -Name 'appcascade'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        Add-Headset -IPAddress '10.0.0.2' -Name 'B' -Model 'Quest 3' -SerialNumber 'SER-B'
        $idA = Resolve-HeadsetIdByName -Name 'A'
        $idB = Resolve-HeadsetIdByName -Name 'B'

        Add-InstalledRow -HeadsetId $idA -Package 'com.a'
        Add-InstalledRow -HeadsetId $idB -Package 'com.b'
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $idA; package_name = 'com.a'; display_name = ''; sort_order = 0 } | Out-Null
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $idB; package_name = 'com.b'; display_name = ''; sort_order = 0 } | Out-Null

        # Remove-Headset no longer deletes any file; the cascade is the whole
        # mechanism, so if the foreign key is not enforced this test fails.
        Remove-Headset -ID $idA

        Assert-Equal 0 (@(Invoke-DbQuery -Name 'installed.list'  -Parameters @{ headset_id = $idA })).Count 'A installed apps cascaded away'
        Assert-Equal 0 (@(Invoke-DbQuery -Name 'favorites.list'  -Parameters @{ headset_id = $idA })).Count 'A favourites cascaded away'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'installed.list'  -Parameters @{ headset_id = $idB })).Count 'B installed apps survived'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'favorites.list'  -Parameters @{ headset_id = $idB })).Count 'B favourites survived'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'renaming a headset keeps its apps, with no file work at all' -Test {
    $sandbox = New-AppsSandbox -Name 'apprename'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'Q3 RED' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'Q3 RED'
        Add-InstalledRow -HeadsetId $id -Package 'com.a'
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $id; package_name = 'com.a'; display_name = ''; sort_order = 0 } | Out-Null

        Rename-Headset -OldName 'Q3 RED' -NewName 'Q3 BLUE' | Out-Null

        Assert-Equal $id (Resolve-HeadsetIdByName -Name 'Q3 BLUE') 'the id did not move'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'installed.list' -Parameters @{ headset_id = $id })).Count 'installed apps followed the rename'
        Assert-Equal 1 (@(Invoke-DbQuery -Name 'favorites.list' -Parameters @{ headset_id = $id })).Count 'favourites followed the rename'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Change counters - regression test for migration 002
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'an in-place upsert bumps the change counter (migration 002)' -Test {
    $sandbox = New-AppsSandbox -Name 'appver'
    try {
        Add-Headset -IPAddress '10.0.0.1' -Name 'A' -Model 'Quest 3' -SerialNumber 'SER-A'
        $id = Resolve-HeadsetIdByName -Name 'A'

        # 001 gave these two tables an INSERT and a DELETE trigger but no UPDATE
        # trigger, so a row changing IN PLACE left the counter alone and any
        # cache keyed on it would have served stale data forever.
        Add-InstalledRow -HeadsetId $id -Package 'com.a' -Version '1.0'
        $before = Get-DbTableVersion -Name 'installed_apps'
        Add-InstalledRow -HeadsetId $id -Package 'com.a' -Version '2.0'
        $after = Get-DbTableVersion -Name 'installed_apps'
        Add-TestEvidence ("installed_apps counter {0} -> {1}" -f $before, $after)
        Assert-True ($after -gt $before) 'updating an installed app in place bumps installed_apps'

        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $id; package_name = 'com.a'; display_name = 'A'; sort_order = 0 } | Out-Null
        $before = Get-DbTableVersion -Name 'favorite_apps'
        Invoke-DbNonQuery -Name 'favorites.insert' -Parameters @{ headset_id = $id; package_name = 'com.a'; display_name = 'A'; sort_order = 5 } | Out-Null
        $after = Get-DbTableVersion -Name 'favorite_apps'
        Add-TestEvidence ("favorite_apps counter {0} -> {1}" -f $before, $after)
        Assert-True ($after -gt $before) 'reordering a favourite in place bumps favorite_apps'

        $before = Get-DbTableVersion -Name 'app_catalog'
        Add-CatalogEntry -Package 'com.a' -Display 'A'
        Add-CatalogEntry -Package 'com.a' -Display 'A renamed'
        Assert-True ((Get-DbTableVersion -Name 'app_catalog') -gt $before) 'the catalogue counter moves too'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}

Invoke-RegressionTest -Name 'the schema migrated to user_version 2' -Test {
    $sandbox = New-AppsSandbox -Name 'appschema'
    try {
        $version = Get-DbUserVersion
        Add-TestEvidence ("user_version = {0}" -f $version)
        Assert-True ($version -ge 2) 'migration 002 was applied'

        # The two triggers 002 adds must exist by name, so a future edit that
        # drops them fails here rather than silently in a stale cache.
        $names = @(Invoke-DbQuery -Sql "SELECT name FROM sqlite_master WHERE type = 'trigger';" | ForEach-Object { [string]$_.name })
        Assert-True ($names -contains 'trg_installed_upd') 'trg_installed_upd exists'
        Assert-True ($names -contains 'trg_favorites_upd') 'trg_favorites_upd exists'
    } finally {
        Remove-TempDatabaseRoot -Sandbox $sandbox | Out-Null
    }
}
