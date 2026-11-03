<#
.SYNOPSIS
    Headset-free unit tests of the application self-update (ADR-0041).

.DESCRIPTION
    Dot-sources modules\vrhm_update.ps1 directly (no app startup). One section per task; append new
    sections before the summary. Prints PASS/FAIL per case; exit 1 when any case fails.

.EXAMPLE
    .\scripts\Test-AppUpdate.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\vrhm_update.ps1')

$script:fails = 0
$script:count = 0
function Assert-Case([string]$Name, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green }
    else { $script:fails++; Write-Host ("[FAIL] {0} {1}" -f $Name, $Detail) -ForegroundColor Red }
}

# ------------------------------------------------------------------ S1 version grammar
$cmp = @(
    @('2026-11.RC1', '2026-11.RC1.0', 0),
    @('2026-11.RC1.2', '2026-11.RC1.10', -1),
    @('2026-11.RC2', '2026-11.RC1.9', 1),
    @('2026-12.RC1', '2026-11.RC3.4', 1),
    @('2026-11.RC1.2+dev.abc1234', '2026-11.RC1.2', 1),
    @('V2026-11.RC1', '2026-11.RC1', 0),
    @('2026-11.RC1.2.1', '2026-11.RC1.2', 1),
    @('2026-11.RC1.2+dev.abc1234', '2026-11.RC1.2+dev.def5678', 0),
    @('2026-11.rc1', '2026-11.RC1', 0),
    @('2026-11.RC1', 'V26.05', 1),
    @('V26.05', '2026-11.RC1', -1),
    @('2026-10.TEST5', '2026-11.RC1', 0),
    @('DEVELOPPMENT-VERSION', '2026-11.RC1', 0)
)
foreach ($c in $cmp) {
    $r = Compare-AppVersion -A $c[0] -B $c[1]
    Assert-Case ("compare: {0} vs {1} = {2}" -f $c[0], $c[1], $c[2]) ($r -eq $c[2]) ("got $r")
}
$pa = ConvertTo-AppVersion -Text '2026-11.RC1.2'
Assert-Case 'compare: accepts parsed objects' ((Compare-AppVersion -A $pa -B '2026-11.RC1.3') -eq -1)

$t = ConvertTo-AppVersion -Text '2026-10.TEST5'
Assert-Case 'parse: TEST5 Kind Test, n=5' ($t.Kind -eq 'Test' -and $t.Ok -and $t.Rc -eq 5)
Assert-Case 'parse: TEST alone = 1' ((ConvertTo-AppVersion -Text '2026-10.TEST').Rc -eq 1)
$d = ConvertTo-AppVersion -Text 'DEVELOPPMENT-VERSION'
Assert-Case 'parse: DevTree' ($d.Kind -eq 'DevTree')
$l = ConvertTo-AppVersion -Text 'V26.05'
Assert-Case 'parse: V26.05 Legacy, Ok false' ($l.Kind -eq 'Legacy' -and -not $l.Ok)
Assert-Case 'parse: empty and null are Legacy' ((ConvertTo-AppVersion -Text '').Kind -eq 'Legacy' -and (ConvertTo-AppVersion -Text $null).Kind -eq 'Legacy')
$r1 = ConvertTo-AppVersion -Text '2026-11.RC1.2+dev.ABC1234'
Assert-Case 'parse: fields Core/Base/Dev/Minor/Patch' ($r1.Core -eq '2026-11.RC1.2' -and $r1.Base -eq '2026-11.RC1' -and $r1.Dev -eq 'abc1234' -and $r1.Minor -eq 2 -and $r1.Patch -eq 0)
Assert-Case 'parse: V prefix stripped, Core without V' ((ConvertTo-AppVersion -Text 'V2026-11.RC1').Core -eq '2026-11.RC1')

Assert-Case 'updatable: Release true' (Test-AppVersionUpdatable -Version '2026-11.RC1')
Assert-Case 'updatable: Test false' (-not (Test-AppVersionUpdatable -Version '2026-10.TEST5'))
Assert-Case 'updatable: DevTree false' (-not (Test-AppVersionUpdatable -Version 'DEVELOPPMENT-VERSION'))
Assert-Case 'updatable: Legacy false' (-not (Test-AppVersionUpdatable -Version 'V26.05'))

# ------------------------------------------------------------------ installed manifest (temp folder)
$tmp = Join-Path $env:TEMP ('vrhm_upd_test_' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Assert-Case 'manifest: empty root -> $null' ($null -eq (Get-AppInstalledManifest -Root $tmp))
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $tmp 'release.json'), '{"schema":1,"version":"2026-11.RC1.2","commit":"abc"}', $enc)
    [System.IO.File]::WriteAllText((Join-Path $tmp 'version.txt'), "2026-11.RC1.2`r`n", $enc)
    $m = Get-AppInstalledManifest -Root $tmp
    Assert-Case 'manifest: release.json read' ($m -and $m.version -eq '2026-11.RC1.2')
    $vi = Get-AppVersionInfo -Root $tmp
    Assert-Case 'info: version/updatable/commit from release.json' ($vi.Version -eq '2026-11.RC1.2' -and $vi.Updatable -and -not $vi.DevTree -and $vi.Commit -eq 'abc')
    New-Item -ItemType Directory -Path (Join-Path $tmp 'data\update') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmp 'data\update\installed.json'), '{"version":"2026-11.RC1.3","commit":"def"}', $enc)
    Assert-Case 'manifest: installed.json wins' ((Get-AppInstalledManifest -Root $tmp).version -eq '2026-11.RC1.3')
    [System.IO.File]::WriteAllText((Join-Path $tmp 'data\update\installed.json'), '{ broken', $enc)
    Assert-Case 'manifest: corrupt installed.json falls back to release.json' ((Get-AppInstalledManifest -Root $tmp).version -eq '2026-11.RC1.2')
    [System.IO.File]::WriteAllText((Join-Path $tmp 'version.txt'), 'DEVELOPPMENT-VERSION', $enc)
    $vd = Get-AppVersionInfo -Root $tmp
    Assert-Case 'info: dev tree not updatable' ($vd.DevTree -and -not $vd.Updatable)
    Assert-Case 'info: missing root never throws' ($null -ne (Get-AppVersionInfo -Root (Join-Path $tmp 'nope')))
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ S5 update path (pure)
function New-TestRel([string]$V, [string]$Type, [string]$Base, [string]$Min) {
    return @{ Version = $V; Type = $Type; Base = $Base; MinUpgradeFrom = $Min; Updatable = $true; Reason = '' }
}
$A = '2026-11.RC1'
$p1 = Get-AppUpdatePath -From $A -To '2026-11.RC1.2' -Releases @((New-TestRel '2026-11.RC1.1' 'minor' $A $A), (New-TestRel '2026-11.RC1.2' 'minor' $A '2026-11.RC1.1'))
Assert-Case 'path: chain B,C' ($p1.Ok -and (@($p1.Hops) -join ',') -eq '2026-11.RC1.1,2026-11.RC1.2') ($p1.Hops -join ',')
$p2 = Get-AppUpdatePath -From $A -To '2026-11.RC1.2' -Releases @((New-TestRel '2026-11.RC1.1' 'minor' $A $A), (New-TestRel '2026-11.RC1.2' 'minor' $A $A))
Assert-Case 'path: direct C' ($p2.Ok -and (@($p2.Hops) -join ',') -eq '2026-11.RC1.2') ($p2.Hops -join ',')
$p3 = Get-AppUpdatePath -From $A -To '2026-12.RC1.1' -Releases @((New-TestRel '2026-12.RC1' 'major' '2026-12.RC1' $A), (New-TestRel '2026-12.RC1.1' 'minor' '2026-12.RC1' '2026-12.RC1'))
Assert-Case 'path: major then minor' ($p3.Ok -and (@($p3.Hops) -join ',') -eq '2026-12.RC1,2026-12.RC1.1') ($p3.Hops -join ',')
$p4 = Get-AppUpdatePath -From $A -To '2026-12.RC1' -Releases @((New-TestRel '2026-12.RC1' 'major' '2026-12.RC1' '2026-11.RC1.1'))
Assert-Case 'path: NoRoute with Needs' (-not $p4.Ok -and $p4.Reason -eq 'NoRoute' -and $p4.Needs -eq '2026-11.RC1.1') ("$($p4.Reason) $($p4.Needs)")
$p5 = Get-AppUpdatePath -From $A -To '2026-11.RC1.1' -Releases @((New-TestRel '2026-11.RC1.1' 'minor' '2026-10.RC9' $A))
Assert-Case 'path: other line NoRoute' (-not $p5.Ok -and $p5.Reason -eq 'NoRoute') $p5.Reason
Assert-Case 'path: Same' ((Get-AppUpdatePath -From $A -To $A -Releases @()).Reason -eq 'Same')
Assert-Case 'path: Older' ((Get-AppUpdatePath -From '2026-11.RC1.2' -To $A -Releases @()).Reason -eq 'Older')
Assert-Case 'path: NotUpdatable (test version)' ((Get-AppUpdatePath -From '2026-10.TEST5' -To $A -Releases @()).Reason -eq 'NotUpdatable')
$notUp = @{ Version = '2026-11.RC1.1'; Type = ''; Base = ''; MinUpgradeFrom = ''; Updatable = $false; Reason = 'NoManifest' }
Assert-Case 'path: non-updatable target NotUpdatable' ((Get-AppUpdatePath -From $A -To '2026-11.RC1.1' -Releases @($notUp)).Reason -eq 'NotUpdatable')
$p6 = Get-AppUpdatePath -From $A -To '2026-11.RC1.3' -Releases @((New-TestRel '2026-11.RC1.1' 'minor' $A $A), (New-TestRel '2026-11.RC1.2' 'minor' $A $A), (New-TestRel '2026-11.RC1.3' 'minor' $A '2026-11.RC1.1'))
Assert-Case 'path: tie-break prefers highest intermediate (.2 over .1)' ($p6.Ok -and (@($p6.Hops) -join ',') -eq '2026-11.RC1.2,2026-11.RC1.3') ($p6.Hops -join ',')

Assert-Case 'protected: config/data/logs/scripts' ((Test-AppUpdateProtectedPath 'config/config.json') -and (Test-AppUpdateProtectedPath 'data\x.db') -and (Test-AppUpdateProtectedPath 'logs/a') -and (Test-AppUpdateProtectedPath 'scripts/a.ps1'))
Assert-Case 'protected: ffmpeg, overlays, generated' ((Test-AppUpdateProtectedPath 'sources/ffmpeg/ffmpeg-8/ffmpeg.exe') -and (Test-AppUpdateProtectedPath 'website/Q3 RED[monitoring].html') -and (Test-AppUpdateProtectedPath 'website/monitor.html') -and (Test-AppUpdateProtectedPath 'website/generated/x'))
Assert-Case 'protected: code is not protected' (-not (Test-AppUpdateProtectedPath 'modules/utils.ps1') -and -not (Test-AppUpdateProtectedPath 'website/video_monitor.html') -and -not (Test-AppUpdateProtectedPath 'sources/MediaMTX/x.exe'))

# ------------------------------------------------------------------ manifest from zip + staging (offline, fake install root)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-FakeReleaseZip([string]$ZipPath, [string]$Top, $Manifest, [hashtable]$Files, [string]$Sep = '\') {
    $fs = [System.IO.File]::Create($ZipPath)
    $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $all = @{}
        foreach ($k in $Files.Keys) { $all[$k] = $Files[$k] }
        $all['release.json'] = ($Manifest | ConvertTo-Json -Depth 6)
        foreach ($k in $all.Keys) {
            $e = $za.CreateEntry(($Top + $Sep + $k.Replace('/', $Sep)))
            $w = New-Object System.IO.StreamWriter($e.Open(), (New-Object System.Text.UTF8Encoding($false)))
            $w.Write($all[$k]); $w.Dispose()
        }
    } finally { $za.Dispose(); $fs.Dispose() }
}
function Get-TextSha([string]$Text) {
    $b = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $s = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($s.ComputeHash($b)).Replace('-', '').ToLowerInvariant())
}
$tmp2 = Join-Path $env:TEMP ('vrhm_upd_stage_' + [guid]::NewGuid().ToString('N'))
try {
    $fake = Join-Path $tmp2 'install'
    New-Item -ItemType Directory -Path (Join-Path $fake 'modules') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fake 'data\update') -Force | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    $oldA = 'old a'; $same = 'same'; $gone = 'gone'
    [System.IO.File]::WriteAllText((Join-Path $fake 'version.txt'), '2026-11.RC1', $enc)
    [System.IO.File]::WriteAllText((Join-Path $fake 'modules\a.ps1'), $oldA, $enc)
    [System.IO.File]::WriteAllText((Join-Path $fake 'modules\same.ps1'), $same, $enc)
    [System.IO.File]::WriteAllText((Join-Path $fake 'modules\gone.ps1'), $gone, $enc)
    $inst = @{ version = '2026-11.RC1'; commit = 'c0'; base = '2026-11.RC1'; files = @{
            'modules/a.ps1' = @{ sha256 = (Get-TextSha $oldA); size = 5 }
            'modules/same.ps1' = @{ sha256 = (Get-TextSha $same); size = 4 }
            'modules/gone.ps1' = @{ sha256 = (Get-TextSha $gone); size = 4 }
            'config/old.json' = @{ sha256 = (Get-TextSha 'x'); size = 1 } } }
    [System.IO.File]::WriteAllText((Join-Path $fake 'data\update\installed.json'), ($inst | ConvertTo-Json -Depth 6), $enc)

    $newA = 'new a'; $newB = 'brand new'; $cfgNew = 'cfg new'
    $man = [ordered]@{ schema = 1; app = 'VRHM'; version = '2026-11.RC1.1'; type = 'minor'; base = '2026-11.RC1'; minUpgradeFrom = '2026-11.RC1'
        dbSchema = 9; commit = 'c1'; files = @(
            @{ path = 'modules/a.ps1'; sha256 = (Get-TextSha $newA); size = 5 },
            @{ path = 'modules/same.ps1'; sha256 = (Get-TextSha $same); size = 4 },
            @{ path = 'modules/new.ps1'; sha256 = (Get-TextSha $newB); size = 9 },
            @{ path = 'config/config.json'; sha256 = (Get-TextSha $cfgNew); size = 7 },
            @{ path = 'version.txt'; sha256 = (Get-TextSha '2026-11.RC1.1'); size = 13 }) }
    $content = @{ 'modules/a.ps1' = $newA; 'modules/same.ps1' = $same; 'modules/new.ps1' = $newB; 'config/config.json' = $cfgNew; 'version.txt' = '2026-11.RC1.1' }
    $zip = Join-Path $tmp2 'pkg.zip'
    New-FakeReleaseZip -ZipPath $zip -Top 'VR_HEADSET_MANAGER' -Manifest $man -Files $content
    $mz = Get-AppReleaseManifest -ZipPath $zip
    Assert-Case 'zip manifest: backslash entry read, Source zip' ($mz -and $mz.version -eq '2026-11.RC1.1' -and $mz.Source -eq 'zip' -and $mz.ZipPath -eq $zip)
    $zipNo = Join-Path $tmp2 'fwd.zip'
    New-FakeReleaseZip -ZipPath $zipNo -Top 'X' -Manifest @{ a = 1 } -Files @{ 'f.txt' = 'x' } -Sep '/'
    $fs = [System.IO.File]::Create((Join-Path $tmp2 'plain.zip')); $za = New-Object System.IO.Compression.ZipArchive($fs, 'Create')
    $en = $za.CreateEntry('Top\f.txt'); $w = New-Object System.IO.StreamWriter($en.Open()); $w.Write('x'); $w.Dispose(); $za.Dispose(); $fs.Dispose()
    Assert-Case 'zip manifest: absent -> $null' ($null -eq (Get-AppReleaseManifest -ZipPath (Join-Path $tmp2 'plain.zip')))
    Assert-Case 'zip manifest: forward-slash zip also read' ($null -ne (Get-AppReleaseManifest -ZipPath $zipNo))

    $rsp = Start-AppUpdate -Target '2026-11.RC1.1' -ZipPaths @($zip) -Releases @() -Root $fake -Force -ProgressFile (Join-Path $tmp2 'prog.json')
    Assert-Case 'stage: Ok inplace' ($rsp.Ok -and $rsp.Mode -eq 'inplace') ("$($rsp.Reason) $($rsp.Error)")
    $job = Get-Content -LiteralPath (Join-Path $fake 'data\update\job.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'stage: job fields' ($job.phase -eq 'staged' -and $job.fromVersion -eq '2026-11.RC1' -and $job.toVersion -eq '2026-11.RC1.1' -and $job.toCommit -eq 'c1' -and $job.mode -eq 'inplace')
    $cp = @($job.copy)
    Assert-Case 'stage: copy = changed + new + version.txt + release.json' ((($cp | Sort-Object) -join ',') -eq 'modules/a.ps1,modules/new.ps1,release.json,version.txt') ($cp -join ',')
    Assert-Case 'stage: unchanged file not copied' ($cp -notcontains 'modules/same.ps1')
    Assert-Case 'stage: protected config excluded from copy' ($cp -notcontains 'config/config.json')
    Assert-Case 'stage: delete = gone.ps1 only (config/old.json protected)' ((@($job.delete) -join ',') -eq 'modules/gone.ps1') (@($job.delete) -join ',')
    Assert-Case 'stage: top folder flattened' (Test-Path -LiteralPath (Join-Path $job.stageRoot 'modules\a.ps1'))
    $chain = Get-Content -LiteralPath (Join-Path $fake 'data\update\chain.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'stage: chain.json target, no remaining hops' ($chain.target -eq '2026-11.RC1.1' -and @($chain.hops).Count -eq 0)
    Assert-Case 'stage: manifest carries files map + version' ($job.manifest.version -eq '2026-11.RC1.1' -and $job.manifest.files.'modules/new.ps1'.sha256 -eq (Get-TextSha $newB))
    $pg = Get-Content -LiteralPath (Join-Path $tmp2 'prog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'stage: progress staged 100' ($pg.status -eq 'staged' -and $pg.percent -eq 100)
    $st = Get-AppUpdateState -Root $fake
    Assert-Case 'state: pending job read, phase staged' ($st.Pending -and $st.Phase -eq 'staged')
    $again = Start-AppUpdate -Target '2026-11.RC1.1' -ZipPaths @($zip) -Releases @() -Root $fake -Force
    Assert-Case 'stage: second job refused JobPending' (-not $again.Ok -and $again.Reason -eq 'JobPending')

    Remove-Item -LiteralPath (Join-Path $fake 'data\update\job.json') -Force
    $bad = $content.Clone(); $bad['modules/new.ps1'] = 'tampered'
    $zipBad = Join-Path $tmp2 'bad.zip'
    New-FakeReleaseZip -ZipPath $zipBad -Top 'VR_HEADSET_MANAGER' -Manifest $man -Files $bad
    $rb = Start-AppUpdate -Target '2026-11.RC1.1' -ZipPaths @($zipBad) -Releases @() -Root $fake -Force
    Assert-Case 'stage: tampered file -> FileHashMismatch' (-not $rb.Ok -and $rb.Reason -eq 'FileHashMismatch') ("$($rb.Reason)")
    Assert-Case 'stage: failed stage cleaned' (-not (Test-Path -LiteralPath (Join-Path $fake 'data\update\stage\2026-11.RC1.1')))
    $rd = Start-AppUpdate -Target 'dev' -Releases @() -Root $fake -Force
    Assert-Case 'stage: dev without installed commit refused, nothing staged' (-not $rd.Ok -and $rd.Reason -ne 'DevNotImplemented' -and -not (Test-Path -LiteralPath (Join-Path $fake 'data\update\job.json'))) ("$($rd.Reason)")
    $majMan = [ordered]@{}
    foreach ($k in $man.Keys) { $majMan[$k] = $man[$k] }
    $majMan.version = '2026-12.RC1'; $majMan.type = 'major'; $majMan.base = '2026-12.RC1'
    $zipMaj = Join-Path $tmp2 'maj.zip'
    New-FakeReleaseZip -ZipPath $zipMaj -Top 'VR_HEADSET_MANAGER' -Manifest $majMan -Files $content
    $rm = Start-AppUpdate -Target '2026-12.RC1' -ZipPaths @($zipMaj) -Releases @() -Root $fake -Force
    Assert-Case 'stage: major -> installed in a new folder, old job.json mode major' ($rm.Ok -and $rm.Mode -eq 'major' -and (Test-Path -LiteralPath (Join-Path $tmp2 'VR_HEADSET_MANAGER.v2026-12.RC1\VR_HEADSET_MANAGER\modules\a.ps1')) -and ((Read-UpdateJsonFile -Path (Join-Path $fake 'data\update\job.json')).mode -eq 'major')) ("$($rm.Reason) $($rm.Error)")
    Remove-Item -LiteralPath (Join-Path $fake 'data\update\job.json') -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText((Join-Path $fake 'version.txt'), 'DEVELOPPMENT-VERSION', $enc)
    $rt = Start-AppUpdate -Target '2026-11.RC1.1' -ZipPaths @($zip) -Releases @() -Root $fake -Force
    Assert-Case 'stage: dev tree refused' (-not $rt.Ok -and $rt.Reason -eq 'DevTree')
}
finally {
    if (Test-Path -LiteralPath $tmp2) { Remove-Item -LiteralPath $tmp2 -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ T8 Merge-ConfigTemplate / Invoke-AppUpgradeSteps
$cfgJ = '{"a":{"b":1,"arr":[1,2],"t":"x"},"keep":5,"scrcpy":{"parameters":{"Quest 3":{"max_size":0}}}}'
$tplJ = '{"a":{"b":9,"c":{"d":2},"arr":[7,8,9],"t":{"x":1}},"keep":6,"n":3,"scrcpy":{"parameters":{"Quest 3":{"max_size":1,"views":{}},"Quest 9":{"max_size":2}}}}'
$mr = Merge-ConfigTemplate -Config ($cfgJ | ConvertFrom-Json) -Template ($tplJ | ConvertFrom-Json)
Assert-Case 'merge: missing nested key added' ($mr.Config.a.c.d -eq 2 -and $mr.Added -contains 'a.c')
Assert-Case 'merge: missing top key added' ($mr.Config.n -eq 3 -and $mr.Added -contains 'n')
Assert-Case 'merge: existing values kept' ($mr.Config.a.b -eq 1 -and $mr.Config.keep -eq 5)
Assert-Case 'merge: array untouched' (@($mr.Config.a.arr).Count -eq 2)
Assert-Case 'merge: type mismatch kept as config' ($mr.Config.a.t -eq 'x' -and -not ($mr.Added -contains 'a.t'))
Assert-Case 'merge: existing model subtree not modified' ($null -eq $mr.Config.scrcpy.parameters.'Quest 3'.PSObject.Properties['views'] -and $mr.Config.scrcpy.parameters.'Quest 3'.max_size -eq 0)
Assert-Case 'merge: missing model added' ($mr.Config.scrcpy.parameters.'Quest 9'.max_size -eq 2 -and $mr.Added -contains 'scrcpy.parameters.Quest 9')

$tmp3 = Join-Path ([System.IO.Path]::GetTempPath()) ('vrhm_upg_' + [guid]::NewGuid().ToString('N'))
try {
    $enc3 = New-Object System.Text.UTF8Encoding($false)
    foreach ($d in 'config', 'templates\config', 'modules\upgrade', 'data') { New-Item -ItemType Directory -Path (Join-Path $tmp3 $d) -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $tmp3 'version.txt'), '2026-11.RC1.2', $enc3)
    [System.IO.File]::WriteAllText((Join-Path $tmp3 'config\config.json'), $cfgJ, $enc3)
    [System.IO.File]::WriteAllText((Join-Path $tmp3 'templates\config\config.json'), $tplJ, $enc3)
    $cp = Join-Path $tmp3 'config\config.json'
    $applied = Join-Path $tmp3 'data\update\applied.json'

    $u1 = Invoke-AppUpgradeSteps -Root $tmp3 -ConfigPath $cp -NoReload
    $a1 = Get-Content -LiteralPath $applied -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'upgrade: first install only records version' (-not $u1.Ran -and $a1.lastVersion -eq '2026-11.RC1.2' -and ((Get-Content -LiteralPath $cp -Raw -Encoding UTF8) -notmatch '"n"'))

    $u2 = Invoke-AppUpgradeSteps -Root $tmp3 -ConfigPath $cp -NoReload
    Assert-Case 'upgrade: same version is a no-op' (-not $u2.Ran)

    [System.IO.File]::WriteAllText($applied, '{"lastVersion":"2026-11.RC1.0","steps":[]}', $enc3)
    $stepBody = 'function Invoke-UpgradeStep { $global:T8Order += "@@V@@" }'
    foreach ($v in '2026-11.RC1.2', '2026-11.RC1.1', '2026-11.RC1.0', '2026-11.RC1.3', '2026-11.RC1.10') {
        [System.IO.File]::WriteAllText((Join-Path $tmp3 ("modules\upgrade\$v.ps1")), ($stepBody.Replace('@@V@@', $v)), $enc3)
    }
    $global:T8Order = @()
    $u3 = Invoke-AppUpgradeSteps -Root $tmp3 -ConfigPath $cp -NoReload
    $cfgAfter = Get-Content -LiteralPath $cp -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'upgrade: config merged on upgrade' ($u3.Ran -and $cfgAfter.n -eq 3 -and $cfgAfter.a.b -eq 1) ("$($u3.Error)")
    Assert-Case 'upgrade: steps in range, version order' (($global:T8Order -join ',') -eq '2026-11.RC1.1,2026-11.RC1.2') ($global:T8Order -join ',')
    $a3 = Get-Content -LiteralPath $applied -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'upgrade: applied.json advanced with steps' ($a3.lastVersion -eq '2026-11.RC1.2' -and @($a3.steps).Count -eq 2)

    [System.IO.File]::WriteAllText($applied, '{"lastVersion":"2026-11.RC1.0","steps":[]}', $enc3)
    [System.IO.File]::WriteAllText((Join-Path $tmp3 'modules\upgrade\2026-11.RC1.1.ps1'), 'function Invoke-UpgradeStep { throw "boom" }', $enc3)
    $global:T8Order = @()
    $u4 = Invoke-AppUpgradeSteps -Root $tmp3 -ConfigPath $cp -NoReload
    $a4 = Get-Content -LiteralPath $applied -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Case 'upgrade: failing step stops, lastVersion kept for retry' ($u4.Error -eq 'boom' -and $a4.lastVersion -eq '2026-11.RC1.0' -and $global:T8Order.Count -eq 0)

    [System.IO.File]::WriteAllText((Join-Path $tmp3 'version.txt'), 'DEVELOPPMENT-VERSION', $enc3)
    Remove-Item -LiteralPath $applied -Force
    $u5 = Invoke-AppUpgradeSteps -Root $tmp3 -ConfigPath $cp -NoReload
    Assert-Case 'upgrade: dev tree does nothing' (-not $u5.Ran -and -not (Test-Path -LiteralPath $applied))

    $cd = Join-Path $tmp3 'data\update'
    [System.IO.File]::WriteAllText((Join-Path $cd 'chain.json'), '{"target":"x","hops":[],"importItems":[]}', $enc3)
    Resume-AppUpdateChain -Root $tmp3 -WaitSec 1
    Assert-Case 'chain: no hops left deletes chain.json' (-not (Test-Path -LiteralPath (Join-Path $cd 'chain.json')))
}
finally {
    Remove-Variable -Name T8Order -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmp3) { Remove-Item -LiteralPath $tmp3 -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ T9 dev diff guard + live compare
function New-T9File([string]$Path, [string]$Status, [string]$Prev = '') { return @{ Path = $Path; Status = $Status; PreviousPath = $Prev } }
$tplOld = '{"a":{"b":1,"c":[1,2]},"d":"x"}'
$g1 = Test-AppDevDiffGuard -Files @(New-T9File 'modules/db/schema/003_x.sql' 'modified') -InstalledDbSchema 9
Assert-Case 'guard: old schema edited blocks' ($g1.Blocked -and $g1.BlockReasons[0] -like 'Major change on the branch*')
$g2 = Test-AppDevDiffGuard -Files @(New-T9File 'modules/db/schema/010_y.sql' 'added') -InstalledDbSchema 9
Assert-Case 'guard: new schema warns only' (-not $g2.Blocked -and $g2.Warnings.Count -eq 1)
$g2b = Test-AppDevDiffGuard -Files @(New-T9File 'modules/db/schema/010_y.sql' 'modified') -InstalledDbSchema 9
Assert-Case 'guard: schema above installed modified does not block' (-not $g2b.Blocked)
$g3 = Test-AppDevDiffGuard -Files @() -OldTemplateJson $tplOld -NewTemplateJson '{"a":{"c":[1,2]},"d":"x"}'
Assert-Case 'guard: template key removed blocks' ($g3.Blocked -and $g3.BlockReasons[0] -like '*a.b*')
$g4 = Test-AppDevDiffGuard -Files @() -OldTemplateJson $tplOld -NewTemplateJson '{"a":{"b":1,"c":[1,2,3],"e":2},"d":"x"}'
Assert-Case 'guard: template key added warns only (array content ignored)' (-not $g4.Blocked -and $g4.Warnings.Count -eq 1 -and $g4.Warnings[0] -like '*a.e*')
$g5 = Test-AppDevDiffGuard -Files @(New-T9File 'modules/updater.ps1' 'modified')
Assert-Case 'guard: updater change blocks' $g5.Blocked
$g6 = Test-AppDevDiffGuard -Files @((New-T9File 'sources/MediaMTX/x/mediamtx.exe' 'modified'), (New-T9File 'main.ps1' 'modified'))
Assert-Case 'guard: sources and main.ps1 warn' (-not $g6.Blocked -and $g6.Warnings.Count -eq 2)
$g7 = Test-AppDevDiffGuard -Files @(New-T9File 'modules/utils.ps1' 'modified') -OldTemplateJson $tplOld -NewTemplateJson $tplOld -InstalledDbSchema 9
Assert-Case 'guard: plain module edit neither' (-not $g7.Blocked -and $g7.Warnings.Count -eq 0)
$g8 = Test-AppDevDiffGuard -Files @(New-T9File 'modules/db/schema/011_z.sql' 'renamed' 'modules/db/schema/002_z.sql') -InstalledDbSchema 9
Assert-Case 'guard: rename of applied schema blocks' $g8.Blocked

# live, read-only: one compare call from HEAD~3 to the dev branch, fake installed manifest in TEMP
$t9 = Join-Path $env:TEMP ('t9_' + [guid]::NewGuid().ToString('N'))
try {
    . (Join-Path $root 'modules\release_include.ps1')
    $head = (& git -C $root rev-parse 'HEAD~3' 2>$null)
    if (-not $head) { Write-Host '[SKIP] live dev diff: no git HEAD~3' }
    else {
        New-Item -ItemType Directory -Path (Join-Path $t9 'data\update') -Force | Out-Null
        $enc9 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText((Join-Path $t9 'version.txt'), '2026-11.RC1.2', $enc9)
        [System.IO.File]::WriteAllText((Join-Path $t9 'data\update\installed.json'), ('{"version":"2026-11.RC1.2","commit":"' + $head + '","dbSchema":99,"files":{}}'), $enc9)
        $d9 = Get-AppDevDiff -Root $t9 -Releases @()
        if (-not $d9.Ok) { Write-Host ("[SKIP] live dev diff: {0} {1}" -f $d9.Reason, $d9.Error) }
        else {
            Write-Host ("LIVE reason={0} aheadBy={1} files={2} changed={3} added={4} removed={5} ignored={6} blocked={7} warnings={8}" -f $d9.Reason, $d9.AheadBy, @($d9.Files).Count, $d9.Counts.Changed, $d9.Counts.Added, $d9.Counts.Removed, $d9.Counts.Ignored, $d9.Blocked, @($d9.Warnings).Count)
            Assert-Case 'live: compare ok with branch head' ($d9.Available -and $d9.AheadBy -ge 0 -and $d9.ToCommit.Length -ge 7)
            Assert-Case 'live: counts consistent' (@($d9.Files).Count -eq ($d9.Counts.Changed + $d9.Counts.Added + $d9.Counts.Removed + $d9.Counts.Ignored))
        }
    }
} finally {
    if (Test-Path -LiteralPath $t9) { Remove-Item -LiteralPath $t9 -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ S11 major install + import (T10)
. (Join-Path $root 'modules\vrhm_import.ps1')
$enc10 = New-Object System.Text.UTF8Encoding $false
$t10 = Join-Path $env:TEMP ('t10_' + [guid]::NewGuid().ToString('N'))
try {
    # target folder rule
    $a = Get-AppMajorTargetRoot -Root (Join-Path $t10 'apps\VR_HEADSET_MANAGER.v2026-11.RC1\VR_HEADSET_MANAGER') -Version '2027-01.RC1'
    Assert-Case 'major target: parent named VR_HEADSET_MANAGER.v* -> sibling of the parent' ($a -eq (Join-Path $t10 'apps\VR_HEADSET_MANAGER.v2027-01.RC1\VR_HEADSET_MANAGER')) $a
    $b = Get-AppMajorTargetRoot -Root (Join-Path $t10 'apps\whatever\VR_HEADSET_MANAGER') -Version '2027-01.RC1'
    Assert-Case 'major target: other parent -> inside that parent' ($b -eq (Join-Path $t10 'apps\whatever\VR_HEADSET_MANAGER.v2027-01.RC1\VR_HEADSET_MANAGER')) $b

    # Install-AppMajorRelease
    $old = Join-Path $t10 'apps\VR_HEADSET_MANAGER.v2026-11.RC1\VR_HEADSET_MANAGER'
    $stage = Join-Path $t10 'stage'
    New-Item -ItemType Directory -Path (Join-Path $old 'data\update'), (Join-Path $old 'sources\ffmpeg\ffmpeg-8.1'), (Join-Path $old 'sources\scrcpy\x'), (Join-Path $stage 'modules') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $old 'sources\ffmpeg\ffmpeg-8.1\ffmpeg.exe'), 'x', $enc10)
    [System.IO.File]::WriteAllText((Join-Path $stage 'main.ps1'), '# new', $enc10)
    [System.IO.File]::WriteAllText((Join-Path $stage 'modules\a.ps1'), '# a', $enc10)
    [System.IO.File]::WriteAllText((Join-Path $stage 'release.json'), '{"version":"2027-01.RC1"}', $enc10)
    [System.IO.File]::WriteAllText((Join-Path $old 'data\update\chain.json'), '{"target":"2027-02.RC1","hops":["2027-02.RC1"],"importItems":["headsets"]}', $enc10)
    $mf = [PSCustomObject]@{ version = '2027-01.RC1' }
    $ir = Install-AppMajorRelease -StageRoot $stage -Manifest $mf -ImportItems @('headsets', 'crops') -Root $old -FromVersion '2026-11.RC1'
    Assert-Case 'major install: ok and NewRoot returned' ($ir.Ok -and $ir.Mode -eq 'major' -and $ir.NewRoot -eq $a) ($ir.Error)
    Assert-Case 'major install: staged tree copied' ((Test-Path -LiteralPath (Join-Path $ir.NewRoot 'main.ps1')) -and (Test-Path -LiteralPath (Join-Path $ir.NewRoot 'modules\a.ps1')))
    Assert-Case 'major install: ffmpeg folder copied, scrcpy not' ((Test-Path -LiteralPath (Join-Path $ir.NewRoot 'sources\ffmpeg\ffmpeg-8.1\ffmpeg.exe')) -and -not (Test-Path -LiteralPath (Join-Path $ir.NewRoot 'sources\scrcpy')))
    $impf = Read-UpdateJsonFile -Path (Join-Path $ir.NewRoot 'data\update\import_from.json')
    Assert-Case 'major install: import_from.json content' ($impf.from -eq $old -and $impf.fromVersion -eq '2026-11.RC1' -and @($impf.items).Count -eq 2 -and @($impf.chain).Count -eq 1 -and $impf.target -eq '2027-02.RC1')
    $chn = Read-UpdateJsonFile -Path (Join-Path $ir.NewRoot 'data\update\chain.json')
    $stn = Read-UpdateJsonFile -Path (Join-Path $ir.NewRoot 'data\update\state.json')
    Assert-Case 'major install: new root chain.json + healthy state.json' (@($chn.hops).Count -eq 1 -and $stn.phase -eq 'healthy' -and $stn.toVersion -eq '2027-01.RC1')
    $jb = Read-UpdateJsonFile -Path (Join-Path $old 'data\update\job.json')
    Assert-Case 'major install: old job.json mode major phase staged' ($jb.mode -eq 'major' -and $jb.phase -eq 'staged' -and $jb.newRoot -eq $ir.NewRoot -and $jb.installRoot -eq $old)
    $ir2 = Install-AppMajorRelease -StageRoot $stage -Manifest $mf -Root $old -FromVersion '2026-11.RC1'
    Assert-Case 'major install: refuses a non-empty target' (-not $ir2.Ok -and $ir2.Error -like '*not empty*')
    $ir3 = Install-AppMajorRelease -StageRoot (Join-Path $t10 'nope') -Manifest $mf -Root $old
    Assert-Case 'major install: refuses a missing stage' (-not $ir3.Ok)

    # profile view rule
    $params = ('{"Quest 3":{"views":{"square":{"default":true},"max":{}}}}' | ConvertFrom-Json)
    $pv1 = Test-ImportProfileView -Profile 'max-R-N-45-20' -Model 'Quest 3' -Parameters $params
    $pv2 = Test-ImportProfileView -Profile 'gone-L-D-30-10' -Model 'Quest 3' -Parameters $params
    $pv3 = Test-ImportProfileView -Profile 'max-R-N-45-20' -Model 'Unknown' -Parameters $params
    Assert-Case 'profile: existing view kept' ($pv1.Kept -and $pv1.Profile -eq 'max-R-N-45-20')
    Assert-Case 'profile: missing view reset to the default view, rest kept' (-not $pv2.Kept -and $pv2.Profile -eq 'square-L-D-30-10')
    Assert-Case 'profile: unknown model falls back to square' (-not $pv3.Kept -and $pv3.Profile -eq 'square-R-N-45-20')

    # Import-PreviousInstallConfig
    $from = Join-Path $t10 'oldinst'; $newr = Join-Path $t10 'newinst'
    New-Item -ItemType Directory -Path (Join-Path $from 'config'), (Join-Path $from 'data'), (Join-Path $newr 'templates\config') -Force | Out-Null
    $oldCfg = '{"language":"fr-FR","WebServer":{"port":9090},"mediamtx":{"rtsp_port":1111,"hls_port":2222},"Performance":{"GPU_Acceleration":true},"Update":{"github_repo":"a/b"},' +
        '"scrcpy":{"recordFolder":"E:\\Rec","recordMinFreeSpaceGB":9,"parameters":{"Quest 3":{"views":{"mine":{"x":1}},"eye_merge":{"enabled":true},"max_size":1},"Old Model":{"views":{"v":{}}}}},"Recordings":{"rescan_interval_min":3}}'
    $newCfg = '{"language":"en-US","WebServer":{"port":8080},"mediamtx":{"rtsp_port":8554,"hls_port":8888,"webrtc_port":8889},"Performance":{"GPU_Acceleration":false},' +
        '"scrcpy":{"recordFolder":"C:\\DATA","recordMinFreeSpaceGB":5,"parameters":{"Quest 3":{"views":{"square":{}},"max_size":0}}},"Recordings":{"rescan_interval_min":10}}'
    [System.IO.File]::WriteAllText((Join-Path $from 'config\config.json'), $oldCfg, $enc10)
    [System.IO.File]::WriteAllText((Join-Path $newr 'templates\config\config.json'), $newCfg, $enc10)
    [System.IO.File]::WriteAllText((Join-Path $from 'data\wifi_networks.dat'), 'dpapi', $enc10)
    $cr = Import-PreviousInstallConfig -From $from -Items @('recording', 'crops', 'wifi') -Root $newr
    $cfgOut = Read-UpdateJsonFile -Path (Join-Path $newr 'config\config.json')
    Assert-Case 'config import: ok, config.json created from the template' ($cr.Ok -and $cfgOut) ($cr.Error)
    Assert-Case 'config import: settings applied (language, ports, Performance, Update)' ($cfgOut.language -eq 'fr-FR' -and $cfgOut.WebServer.port -eq 9090 -and $cfgOut.mediamtx.rtsp_port -eq 1111 -and $cfgOut.mediamtx.hls_port -eq 2222 -and $cfgOut.mediamtx.webrtc_port -eq 8889 -and $cfgOut.Performance.GPU_Acceleration -eq $true -and $cfgOut.Update.github_repo -eq 'a/b')
    Assert-Case 'config import: recording copied' ($cfgOut.scrcpy.recordFolder -eq 'E:\Rec' -and $cfgOut.scrcpy.recordMinFreeSpaceGB -eq 9 -and $cfgOut.Recordings.rescan_interval_min -eq 3)
    $q3 = $cfgOut.scrcpy.parameters.'Quest 3'
    Assert-Case 'config import: crops of a model in the new template copied, rest kept' ($q3.views.mine.x -eq 1 -and $q3.eye_merge.enabled -eq $true -and $q3.max_size -eq 0)
    Assert-Case 'config import: model absent from the new template skipped and reported' ($null -eq $cfgOut.scrcpy.parameters.PSObject.Properties['Old Model'] -and $cr.Items['crops'].message -like '*Old Model*')
    Assert-Case 'config import: wifi store copied' ((Test-Path -LiteralPath (Join-Path $newr 'data\wifi_networks.dat')) -and $cr.Items['wifi'].count -eq 1)
    $cr2 = Import-PreviousInstallConfig -From $from -Items @() -Root $newr
    $cfg2 = Read-UpdateJsonFile -Path (Join-Path $newr 'config\config.json')
    Assert-Case 'config import: no item = only settings, recording not copied' ($cr2.Ok -and $cfg2.scrcpy.recordFolder -eq 'C:\DATA' -and $cfg2.language -eq 'fr-FR')
    Assert-Case 'config import: unreadable previous config is a clean failure' (-not (Import-PreviousInstallConfig -From (Join-Path $t10 'missing') -Items @() -Root $newr).Ok)
    # merge mode keeps the target's other keys
    [System.IO.File]::WriteAllText((Join-Path $newr 'config\config.json'), '{"language":"en-US","custom":{"keep":1},"scrcpy":{"recordFolder":"C:\\X","parameters":{"Quest 3":{"views":{"square":{}}}}}}', $enc10)
    $cr3 = Import-PreviousInstallConfig -From $from -Items @('recording') -Root $newr -Merge
    $cfg3 = Read-UpdateJsonFile -Path (Join-Path $newr 'config\config.json')
    Assert-Case 'config import: merge mode keeps existing keys' ($cr3.Ok -and $cfg3.custom.keep -eq 1 -and $cfg3.scrcpy.recordFolder -eq 'E:\Rec')
    # startup hook + chain
    $newr2 = Join-Path $t10 'newinst2'
    New-Item -ItemType Directory -Path (Join-Path $newr2 'templates\config'), (Join-Path $newr2 'data\update') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $newr2 'templates\config\config.json'), $newCfg, $enc10)
    $impJson = '{"from":' + ($from | ConvertTo-Json) + ',"fromVersion":"x","items":["recording"],"chain":["2027-02.RC1"],"target":"2027-02.RC1"}'
    [System.IO.File]::WriteAllText((Join-Path $newr2 'data\update\import_from.json'), $impJson, $enc10)
    $hk = Invoke-PreviousInstallConfigStartup -Root $newr2
    Assert-Case 'startup hook: config created and chain.json written' ($hk -and (Test-Path -LiteralPath (Join-Path $newr2 'config\config.json')) -and (Test-Path -LiteralPath (Join-Path $newr2 'data\update\chain.json')))
    Assert-Case 'startup hook: does nothing when config.json exists' (-not (Invoke-PreviousInstallConfigStartup -Root $newr2))

    # shortcut rewrite
    $lnkDir = Join-Path $t10 'lnk'
    New-Item -ItemType Directory -Path $lnkDir -Force | Out-Null
    try {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut((Join-Path $lnkDir 'app.lnk')); $s.TargetPath = (Join-Path $old 'START_VR_HEADSET_MANAGER.cmd'); $s.WorkingDirectory = $old; $s.Save()
        $s2 = $sh.CreateShortcut((Join-Path $lnkDir 'other.lnk')); $s2.TargetPath = (Join-Path $env:windir 'notepad.exe'); $s2.Save()
        $chg = @(Update-AppShortcuts -OldRoot $old -NewRoot $ir.NewRoot -Folders @($lnkDir))
        $chk = $sh.CreateShortcut((Join-Path $lnkDir 'app.lnk'))
        Assert-Case 'shortcuts: target under the old root moved to the new root, others untouched' ($chg.Count -eq 1 -and $chk.TargetPath -eq (Join-Path $ir.NewRoot 'START_VR_HEADSET_MANAGER.cmd') -and $chk.WorkingDirectory -eq $ir.NewRoot)
    } catch { Write-Host ("[SKIP] shortcuts: {0}" -f $_.Exception.Message) }

    # Invoke-DbExternalQuery against a temp database (needs the SQLite assembly of the dev tree)
    $dbDir = Join-Path $t10 'db'
    New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
    try {
        $global:ScriptPath = $root
        $sqliteDir = Join-Path $root 'sources\sqlite\System.Data.SQLite-1.0.119'
        $global:databaseFolder = $sqliteDir
        $global:databaseAssemblyPath = Join-Path $sqliteDir 'System.Data.SQLite.dll'
        $global:databaseInteropPath = Join-Path $sqliteDir 'x64\SQLite.Interop.dll'
        if (-not (Test-Path -LiteralPath $global:databaseAssemblyPath)) { throw 'SQLite assembly not found in the dev tree' }
        . (Join-Path $root 'modules\database.ps1')
        $dbf = Join-Path $dbDir 'vrhm.db'
        $init = Initialize-Database -Role Main -DatabasePath $dbf -SkipBackup
        if (-not $init.Ok) { throw ('Initialize-Database failed: ' + $init.Error) }
        Invoke-DbNonQuery -Name 'catalog.upsert' -Parameters @{ package_name = 'com.x'; display_name = 'X'; icon_url = ''; local_icon_path = ''; third_party = 1; latest_version = '' } | Out-Null
        Close-DbConnection -Checkpoint
        $rows = @(Invoke-DbExternalQuery -DatabasePath $dbf -Name 'import.app_catalog')
        Assert-Case 'external query: reads another database, DBNull handled' ($rows.Count -eq 1 -and $rows[0].package_name -eq 'com.x' -and $null -eq (Get-DbExternalLastError))
        $none = @(Invoke-DbExternalQuery -DatabasePath (Join-Path $dbDir 'nope.db') -Name 'import.headsets')
        Assert-Case 'external query: missing database = empty + error text' ($none.Count -eq 0 -and (Get-DbExternalLastError) -like '*not found*')
        $roFile = Get-Item -LiteralPath $dbf; $roFile.IsReadOnly = $true
        $rows2 = @(Invoke-DbExternalQuery -DatabasePath $dbf -Name 'import.app_catalog')
        $roFile.IsReadOnly = $false
        Assert-Case 'external query: works on a read-only file' ($rows2.Count -eq 1)
        Assert-Case 'external query: own connection left closed' ($null -eq $script:DbConn -or $script:DbConn.State -ne 'Open')
    } catch { Write-Host ("[SKIP] external query: {0}" -f $_.Exception.Message) }
} finally {
    if (Test-Path -LiteralPath $t10) { Remove-Item -LiteralPath $t10 -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ (later tasks append sections here)

Write-Host ("{0} case(s), {1} failure(s)" -f $script:count, $script:fails)
if ($script:fails -gt 0) { exit 1 }
exit 0
