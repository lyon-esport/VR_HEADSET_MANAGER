#Requires -Version 5.1
<#
.SYNOPSIS
    Section 40 - headset registry CRUD through the web API, plus direct unit
    tests of the scrcpy profile helpers.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section
    context.

    Needs no hardware. The synthetic headsets used here live on 192.0.2.x
    (TEST-NET-1, RFC 5737 - reserved for documentation and guaranteed never to
    be routable), so nothing here can accidentally reach a real device.

    The CRUD tests assert against known_headsets.csv rather than against the
    API's own echo, because several of the underlying functions return nothing
    at all on success - Add-Headset, Update-HeadsetField, Remove-Headset and
    Save-Headsets are all void. The file is the only source of truth.

    ASCII only (CLAUDE.md rule 1).
#>

$target = $global:TestRun.TargetRoot
$paths  = Get-SandboxPaths -TargetRoot $target

$nrtName  = 'NRT_Registry'
$nrtName2 = 'NRT_Registry_Two'
$nrtIp    = '192.0.2.10'
$nrtIp2   = '192.0.2.11'

function Get-NrtHeadsetRow {
    param([Parameter(Mandatory = $true)][string]$Name)
    $rows = @(Import-Csv -LiteralPath $paths.KnownHeadsets -Encoding UTF8)
    return ($rows | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Get-NrtHeadsetRows {
    return @(Import-Csv -LiteralPath $paths.KnownHeadsets -Encoding UTF8)
}

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True (Confirm-SandboxApp -TargetRoot $target) 'the sandbox app is not running'
}

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Add a headset by IP' -Test {
    # Clean slate in case a previous run died mid-section.
    foreach ($stale in @($nrtName, $nrtName2)) {
        if (Get-NrtHeadsetRow -Name $stale) {
            Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $stale } | Out-Null
        }
    }

    $r = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body @{
        name = $nrtName; ip = $nrtIp; model = 'Quest 3'; serialNumber = 'NRTSERIAL001'
    }
    # This endpoint returns logical failures as HTTP 200 with ok:false.
    Assert-VrmOk -Result $r -Label 'add headset'

    $row = Get-NrtHeadsetRow -Name $nrtName
    Assert-NotNull $row ("row for {0} in known_headsets.csv" -f $nrtName)
    Add-TestEvidence ("row: ID={0} IP={1} Model={2} Profile={3}" -f $row.ID, $row.IPAddress, $row.Model, $row.ScrcpyProfile)
    Assert-Equal $nrtIp $row.IPAddress 'stored IP'
    Assert-Equal 'Quest 3' $row.Model 'stored model'
}

Invoke-RegressionTest -Name 'New headset gets its default side files' -Test {
    $safe = ConvertTo-VrmSafeName $nrtName

    $favorites = Join-Path $paths.DataFolder ($safe + '_favorite_apps.csv')
    Add-TestEvidence ("favorites: {0}" -f $favorites)
    Assert-FileExists $favorites 'default favorites CSV'

    foreach ($kind in @('monitoring', 'video', 'timer')) {
        $page = Join-Path $paths.GeneratedFolder ("{0}[{1}].html" -f $safe, $kind)
        Add-TestEvidence ("generated: {0}" -f (Split-Path -Leaf $page))
        Assert-FileExists $page ("generated {0} page" -f $kind)
    }
}

Invoke-RegressionTest -Name 'CSV keeps its documented column set' -Test {
    # By NAME, not index: the on-disk column order follows the first object's
    # property order and differs from the empty-file header literal in
    # headsets_manager.ps1.
    $rows = Get-NrtHeadsetRows
    Assert-True ($rows.Count -gt 0) 'no rows to inspect'
    $columns = $rows[0].PSObject.Properties.Name
    Add-TestEvidence ("columns: {0}" -f ($columns -join ', '))

    foreach ($expected in @('ID', 'Name', 'IPAddress', 'scrcpy_AutoRestart', 'Record', 'ScrcpyProfile', 'Model', 'SerialNumber')) {
        Assert-Contains $columns $expected 'known_headsets.csv columns'
    }
}

Invoke-RegressionTest -Name 'Duplicate IP is rejected without corrupting the CSV' -Test {
    $before = Get-NrtHeadsetRows

    $r = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body @{
        name = 'NRT_Duplicate'; ip = $nrtIp; model = 'Quest 3'; serialNumber = 'NRTSERIAL002'
    }
    Add-TestEvidence ("response: HTTP {0} {1}" -f $r.StatusCode, (Get-VrmApiExcerpt $r.Raw 120))

    $after = Get-NrtHeadsetRows
    Add-TestEvidence ("rows before={0} after={1}" -f $before.Count, $after.Count)

    # Add-Headset early-returns on a duplicate IP, so the row count must not grow.
    Assert-Equal $before.Count $after.Count 'row count after duplicate-IP add'

    # And whatever the policy, the file must remain well formed with contiguous IDs.
    $ids = @($after | ForEach-Object { [int]$_.ID } | Sort-Object)
    for ($i = 0; $i -lt $ids.Count; $i++) {
        Assert-Equal ($i + 1) $ids[$i] 'IDs must stay contiguous from 1'
    }
}

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Toggle recording flag' -Test {
    foreach ($value in @($true, $false)) {
        $r = Invoke-VrmApi -Path '/api/recording' -Method POST -Body @{ name = $nrtName; value = $value }
        Assert-True $r.Ok ('POST /api/recording returned HTTP ' + $r.StatusCode)

        if ($r.Json -and $r.Json.PSObject.Properties.Name -contains 'storageLow' -and $r.Json.storageLow) {
            Skip-Test ('recording refused - record drive low on space (free {0} GB)' -f $r.Json.freeGB)
        }

        $row = Get-NrtHeadsetRow -Name $nrtName
        $expected = 'False'
        if ($value) { $expected = 'True' }
        Add-TestEvidence ("set {0} -> CSV Record={1}" -f $value, $row.Record)
        Assert-Equal $expected $row.Record 'Record column'
    }
}

Invoke-RegressionTest -Name 'Toggle scrcpy auto-restart flag' -Test {
    foreach ($value in @($false, $true)) {
        $r = Invoke-VrmApi -Path '/api/autorestart' -Method POST -Body @{ name = $nrtName; value = $value }
        Assert-VrmOk -Result $r -Label 'set autorestart'

        $row = Get-NrtHeadsetRow -Name $nrtName
        $expected = 'False'
        if ($value) { $expected = 'True' }
        Add-TestEvidence ("set {0} -> CSV scrcpy_AutoRestart={1}" -f $value, $row.scrcpy_AutoRestart)
        Assert-Equal $expected $row.scrcpy_AutoRestart 'scrcpy_AutoRestart column'
    }
}

Invoke-RegressionTest -Name 'Update IP address, rejecting malformed input' -Test {
    foreach ($bad in @('not-an-ip', '999.1.1.1', '')) {
        $r = Invoke-VrmApi -Path '/api/updateip' -Method POST -Body @{ name = $nrtName; ip = $bad }
        $row = Get-NrtHeadsetRow -Name $nrtName
        Add-TestEvidence ("rejected '{0}' -> HTTP {1}, CSV still {2}" -f $bad, $r.StatusCode, $row.IPAddress)
        Assert-Equal $nrtIp $row.IPAddress ("IP must be unchanged after submitting '{0}'" -f $bad)
    }

    $r = Invoke-VrmApi -Path '/api/updateip' -Method POST -Body @{ name = $nrtName; ip = $nrtIp2 }
    Assert-VrmOk -Result $r -Label 'update IP to a valid address'
    Assert-Equal $nrtIp2 (Get-NrtHeadsetRow -Name $nrtName).IPAddress 'updated IP'

    # Put it back so later tests see the original address.
    Invoke-VrmApi -Path '/api/updateip' -Method POST -Body @{ name = $nrtName; ip = $nrtIp } | Out-Null
    Assert-Equal $nrtIp (Get-NrtHeadsetRow -Name $nrtName).IPAddress 'restored IP'
}

Invoke-RegressionTest -Name 'Update scrcpy profile, rejecting malformed input' -Test {
    $valid = 'square-L-D-45-15'
    $r = Invoke-VrmApi -Path '/api/updateprofile' -Method POST -Body @{ name = $nrtName; profile = $valid }
    Assert-VrmOk -Result $r -Label 'set a valid profile'
    Assert-Equal $valid (Get-NrtHeadsetRow -Name $nrtName).ScrcpyProfile 'stored profile'

    foreach ($bad in @('nonsense', 'square-X-D-45-15', 'square-L-D-abc-15', 'square-L-D-45')) {
        $r = Invoke-VrmApi -Path '/api/updateprofile' -Method POST -Body @{ name = $nrtName; profile = $bad }
        $stored = (Get-NrtHeadsetRow -Name $nrtName).ScrcpyProfile
        Add-TestEvidence ("rejected '{0}' -> HTTP {1}, CSV still '{2}'" -f $bad, $r.StatusCode, $stored)
        Assert-Equal $valid $stored ("profile must be unchanged after submitting '{0}'" -f $bad)
    }
}

Invoke-RegressionTest -Name 'Legacy 4-part profile is normalised, not rejected' -Test {
    $r = Invoke-VrmApi -Path '/api/updateprofile' -Method POST -Body @{ name = $nrtName; profile = 'R-N-45-20' }
    Assert-VrmOk -Result $r -Label 'set a legacy 4-part profile'

    $stored = (Get-NrtHeadsetRow -Name $nrtName).ScrcpyProfile
    Add-TestEvidence ("legacy 'R-N-45-20' stored as '{0}'" -f $stored)
    Assert-Match $stored '^[\w]+-[LR]-[DN]-\d+-\d+$' 'normalised profile shape'
}

Invoke-RegressionTest -Name 'Rename moves the side files with the headset' -Test {
    $oldSafe = ConvertTo-VrmSafeName $nrtName
    $newName = 'NRT_Renamed'
    $newSafe = ConvertTo-VrmSafeName $newName

    $r = Invoke-VrmApi -Path '/api/renameheadset' -Method POST -Body @{ name = $nrtName; newname = $newName }
    Assert-VrmOk -Result $r -Label 'rename headset'

    Assert-NotNull (Get-NrtHeadsetRow -Name $newName) 'renamed row'
    Assert-True ($null -eq (Get-NrtHeadsetRow -Name $nrtName)) 'the old name must be gone from the CSV'

    foreach ($kind in @('monitoring', 'video')) {
        $oldPage = Join-Path $paths.GeneratedFolder ("{0}[{1}].html" -f $oldSafe, $kind)
        $newPage = Join-Path $paths.GeneratedFolder ("{0}[{1}].html" -f $newSafe, $kind)
        Add-TestEvidence ("{0}: old gone={1}, new present={2}" -f $kind, (-not (Test-Path -LiteralPath $oldPage)), (Test-Path -LiteralPath $newPage))
        Assert-FileMissing $oldPage ("stale {0} page for the old name" -f $kind)
        Assert-FileExists  $newPage ("{0} page for the new name" -f $kind)
    }

    $oldFav = Join-Path $paths.DataFolder ($oldSafe + '_favorite_apps.csv')
    $newFav = Join-Path $paths.DataFolder ($newSafe + '_favorite_apps.csv')
    Assert-FileMissing $oldFav 'stale favorites CSV'
    Assert-FileExists  $newFav 'renamed favorites CSV'

    # Rename back so the rest of the section uses one stable name.
    Invoke-VrmApi -Path '/api/renameheadset' -Method POST -Body @{ name = $newName; newname = $nrtName } | Out-Null
    Assert-NotNull (Get-NrtHeadsetRow -Name $nrtName) 'renamed back'
}

Invoke-RegressionTest -Name 'Reordering rewrites the IDs' -Test {
    $r = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body @{
        name = $nrtName2; ip = $nrtIp2; model = 'Quest 2'; serialNumber = 'NRTSERIAL003'
    }
    Assert-VrmOk -Result $r -Label 'add the second headset'

    $r = Invoke-VrmApi -Path '/api/reorderheadsets' -Method POST -Body @{ order = @($nrtName2, $nrtName) }
    Assert-VrmOk -Result $r -Label 'reorder headsets'

    $rows = Get-NrtHeadsetRows | Sort-Object { [int]$_.ID }
    Add-TestEvidence ("order now: {0}" -f (($rows | ForEach-Object { "{0}={1}" -f $_.ID, $_.Name }) -join ', '))
    Assert-Equal $nrtName2 $rows[0].Name 'first headset after reorder'
    Assert-Equal $nrtName  $rows[1].Name 'second headset after reorder'
}

# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Remove cleans up every side file' -Test {
    $safe = ConvertTo-VrmSafeName $nrtName2

    $r = Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName2 }
    Assert-VrmOk -Result $r -Label 'remove headset'

    Assert-True ($null -eq (Get-NrtHeadsetRow -Name $nrtName2)) 'row must be gone from the CSV'

    # Remove-Headset promises six separate deletions; check the ones that exist.
    foreach ($kind in @('monitoring', 'video', 'timer')) {
        Assert-FileMissing (Join-Path $paths.GeneratedFolder ("{0}[{1}].html" -f $safe, $kind)) ("generated {0} page" -f $kind)
    }
    Assert-FileMissing (Join-Path $paths.DataFolder ($safe + '_favorite_apps.csv'))  'favorites CSV'
    Assert-FileMissing (Join-Path $paths.DataFolder ($safe + '_installed_apps.csv')) 'installed apps CSV'

    $ids = @(Get-NrtHeadsetRows | ForEach-Object { [int]$_.ID } | Sort-Object)
    Add-TestEvidence ("IDs after removal: {0}" -f ($ids -join ', '))
    for ($i = 0; $i -lt $ids.Count; $i++) {
        Assert-Equal ($i + 1) $ids[$i] 'IDs must be renumbered contiguously after a removal'
    }
}

Invoke-RegressionTest -Name 'Tear down the section test headset' -Test {
    Invoke-VrmApi -Path '/api/removeheadset' -Method POST -Body @{ name = $nrtName } | Out-Null
    Assert-True ($null -eq (Get-NrtHeadsetRow -Name $nrtName)) 'test headset removed'
}

# ---------------------------------------------------------------------------
# Profile helpers - direct module calls, no endpoint exists for these
# ---------------------------------------------------------------------------

Invoke-RegressionTest -Name 'Profile strings round-trip through parse and rebuild' -Test {
    $cases = @('max-R-N-60-10', 'max-R-D-60-10', 'square_IPD_Mid-L-N-45-15', 'portrait-R-N-45-20', 'fullscreen-L-D-30-8')

    $results = Invoke-InTargetModules -TargetRoot $target -Body {
        $out = @()
        foreach ($case in @('max-R-N-60-10', 'max-R-D-60-10', 'square_IPD_Mid-L-N-45-15', 'portrait-R-N-45-20', 'fullscreen-L-D-30-8')) {
            $p = ConvertFrom-ScrcpyProfile -Profile $case
            $rebuilt = $null
            if ($null -ne $p) {
                $rebuilt = ConvertTo-ScrcpyProfile -View $p.View -Eye $p.Eye -AudioDup $p.AudioDup -Fps $p.Fps -BitrateMbps $p.BitrateMbps
            }
            $out += [PSCustomObject]@{ Input = $case; Parsed = ($null -ne $p); Rebuilt = $rebuilt }
        }
        $out
    }

    foreach ($r in @($results)) {
        Add-TestEvidence ("{0} -> {1}" -f $r.Input, $r.Rebuilt)
        Assert-True $r.Parsed ("failed to parse profile '{0}'" -f $r.Input)
        Assert-Equal $r.Input $r.Rebuilt ("round-trip for '{0}'" -f $r.Input)
    }
    Assert-Equal $cases.Count @($results).Count 'every case was evaluated'
}

Invoke-RegressionTest -Name 'Malformed profiles parse to null, blank falls back' -Test {
    $results = Invoke-InTargetModules -TargetRoot $target -Body {
        $out = @()
        foreach ($case in @('nonsense', 'a-b-c-d-e-f', 'max-R-D-xx-10', 'max-R-D-60')) {
            $out += [PSCustomObject]@{ Input = $case; IsNull = ($null -eq (ConvertFrom-ScrcpyProfile -Profile $case)) }
        }
        $blank = ConvertFrom-ScrcpyProfile -Profile ''
        $legacy = ConvertFrom-ScrcpyProfile -Profile 'R-N-45-20'
        [PSCustomObject]@{
            Cases      = $out
            BlankView  = $(if ($null -ne $blank) { $blank.View } else { $null })
            LegacyView = $(if ($null -ne $legacy) { $legacy.View } else { $null })
        }
    }

    foreach ($c in @($results.Cases)) {
        Add-TestEvidence ("'{0}' -> null={1}" -f $c.Input, $c.IsNull)
        Assert-True $c.IsNull ("malformed profile '{0}' should parse to null" -f $c.Input)
    }
    Add-TestEvidence ("blank  -> view '{0}'" -f $results.BlankView)
    Add-TestEvidence ("legacy -> view '{0}'" -f $results.LegacyView)
    Assert-Equal 'portrait' $results.BlankView  'blank profile default view'
    Assert-Equal 'portrait' $results.LegacyView 'legacy 4-part profile default view'
}

Invoke-RegressionTest -Name 'scrcpy arguments honour view, eye and audio' -Test {
    $built = Invoke-InTargetModules -TargetRoot $target -Body {
        [PSCustomObject]@{
            RightNoAudio  = ConvertTo-ScrcpyArguments -headsetModel 'Quest 3' -scrcpyProfile 'max-R-N-60-10'
            LeftAudioDup  = ConvertTo-ScrcpyArguments -headsetModel 'Quest 3' -scrcpyProfile 'max-L-D-60-10'
            Fullscreen    = ConvertTo-ScrcpyArguments -headsetModel 'Quest 3' -scrcpyProfile 'fullscreen-R-N-45-20'
        }
    }

    Add-TestEvidence ("R/N : {0}" -f $built.RightNoAudio)
    Add-TestEvidence ("L/D : {0}" -f $built.LeftAudioDup)
    Add-TestEvidence ("full: {0}" -f $built.Fullscreen)

    Assert-True ($built.RightNoAudio -like '*--max-fps=60*') 'fps must reach the command line'
    Assert-True ($built.RightNoAudio -like '*-b 10M*')       'bitrate must reach the command line'
    Assert-True ($built.RightNoAudio -like '*--no-audio*')   'N must produce --no-audio'
    Assert-True ($built.RightNoAudio -notlike '*--audio-dup*') 'N must not produce --audio-dup'

    Assert-True ($built.LeftAudioDup -like '*--audio-dup*')  'D must produce --audio-dup'
    Assert-True ($built.LeftAudioDup -notlike '*--no-audio*') 'D must not produce --no-audio'

    # Left and right eye must select different crops from the model template.
    Assert-True ($built.RightNoAudio -ne $built.LeftAudioDup) 'L and R must not build identical arguments'

    # fullscreen is defined as crop 0:0:0:0 / angle 0, both of which are skipped.
    Assert-True ($built.Fullscreen -notlike '*--crop*')  'fullscreen must not emit --crop'
    Assert-True ($built.Fullscreen -notlike '*--angle*') 'fullscreen must not emit --angle'
}

Invoke-RegressionTest -Name 'Restream path names are filesystem and URL safe' -Test {
    $result = Invoke-InTargetModules -TargetRoot $target -Body {
        [PSCustomObject]@{
            Spaced = ConvertTo-RestreamPathName -HeadsetName 'Q3 RED'
            Mixed  = ConvertTo-RestreamPathName -HeadsetName 'NRT Test Headset'
        }
    }
    Add-TestEvidence ("'Q3 RED' -> '{0}'" -f $result.Spaced)
    Assert-Equal 'q3_red' $result.Spaced 'restream path for a spaced name'
    Assert-Match $result.Mixed '^[a-z0-9_]+$' 'restream path character set'
}
