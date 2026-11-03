#Requires -Version 5.1
<#
.SYNOPSIS
    Section 89 - App self-update (ADR-0041).

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1 inside a section context.

    Tests, in order:
      1. The headset-free unit suite scripts\Test-AppUpdate.ps1 (run from the DEV tree: scripts\
         is not shipped in a release). PASS when its exit code is 0; the case count is reported.
      2. GET /api/app-update/status: ok, version equal to the target's version.txt, kind Release or
         Test. A TEST build must report updatable false.
      3. (Standard+) POST /api/app-update/check {force:true}: ok true with options.Releases as an
         array, or SKIP when the check cannot reach GitHub (offline).
      4. (Standard+) POST /api/app-update/import {path:'C:\nope\x', check:true}: answers ok false and
         valid false, and never a 500.
      5. (Full) POST /api/app-update/apply WITHOUT confirm answers 400, and GET
         /api/app-update/progress carries a status. Apply is never called with confirm and nothing
         is uploaded.

    Light depth runs 1 and 2. No operator is needed.

    ASCII only (CLAUDE.md rule 1).
#>

$target  = $global:TestRun.TargetRoot
$devRoot = $global:TestRun.DevRoot
$depth   = $global:TestRun.Depth
$appUp   = Confirm-SandboxApp -TargetRoot $target -DevRoot $devRoot

Invoke-RegressionTest -Name 'App is running' -Test {
    Assert-True $appUp 'the sandbox app is not running'
}

Invoke-RegressionTest -Name 'The headset-free unit suite (Test-AppUpdate.ps1) passes' -Test {
    $script = Join-Path $devRoot 'scripts\Test-AppUpdate.ps1'
    if (-not (Test-Path -LiteralPath $script)) { Skip-Test 'scripts\Test-AppUpdate.ps1 not found in the dev tree' }
    # The console host from $PSHOME, never the current process (see section 86: an ISE host
    # rejects -ExecutionPolicy). Output and errors go to files, with a timeout.
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = Join-Path $PSHOME 'pwsh.exe' }
    $code = $null; $out = @(); $err = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $outFile = Join-Path $env:TEMP ('vrhm_nrt89_{0}_out.txt' -f [guid]::NewGuid().ToString('N'))
        $errFile = [IO.Path]::ChangeExtension($outFile, '.err.txt')
        try {
            $p = Start-Process -FilePath $psExe -PassThru -NoNewWindow `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script)) `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $null = $p.Handle   # PS 5.1: cache the handle, or ExitCode reads back empty
            if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; $code = 'timeout' }
            else { $code = $p.ExitCode }
            if (Test-Path -LiteralPath $outFile) { $out = @(Get-Content -LiteralPath $outFile -Encoding UTF8) }
            if (Test-Path -LiteralPath $errFile) { $err = [string](Get-Content -LiteralPath $errFile -Raw -Encoding UTF8) }
        } finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
        if ($code -eq 0 -or $code -eq 1) { break }
        Add-TestEvidence ("attempt {0}: exit {1}, {2} output line(s), stderr: {3}" -f $attempt, $code, $out.Count, ($err -replace '\s+', ' ').Trim())
    }
    $summary = @($out | Where-Object { $_ -match 'case\(s\)' }) | Select-Object -Last 1
    Add-TestEvidence ("summary: {0}" -f $summary)
    $failed = @($out | Where-Object { $_ -match '^\[FAIL\]' })
    foreach ($f in ($failed | Select-Object -First 10)) { Add-TestEvidence $f }
    Assert-True ($code -eq 0) ("unit suite exit code {0}, {1} failed case(s)" -f $code, $failed.Count)
}

Invoke-RegressionTest -Name 'GET /api/app-update/status: version matches the target, kind Release or Test' -Test {
    $r = Invoke-VrmApi -Path '/api/app-update/status'
    Assert-True ($r.Ok) ('/api/app-update/status answers (HTTP {0} {1})' -f $r.StatusCode, $r.Error)
    Assert-True ([bool]$r.Json.ok) 'ok is true'
    $versionFile = Join-Path $target 'version.txt'
    Assert-FileExists $versionFile 'version.txt'
    $shipped = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
    Add-TestEvidence ("status version='{0}', kind='{1}', updatable={2}; version.txt='{3}'" -f $r.Json.version, $r.Json.kind, $r.Json.updatable, $shipped)
    Assert-Equal $shipped ([string]$r.Json.version) 'reported version equals the target version.txt'
    $kind = [string]$r.Json.kind
    Assert-True (@('Release', 'Test') -contains $kind) ("kind '{0}' is Release or Test" -f $kind)
    if ($kind -eq 'Test') {
        Assert-False ([bool]$r.Json.updatable) 'a TEST build reports updatable false'
    }
}

if ($depth -ne 'Light') {
    Invoke-RegressionTest -Name 'POST /api/app-update/check {force:true} lists releases (SKIP when offline)' -Test {
        $r = Invoke-VrmApi -Path '/api/app-update/check' -Method POST -Body @{ force = $true } -TimeoutSec 90
        Add-TestEvidence ("HTTP {0} ok={1} error='{2}'" -f $r.StatusCode, $r.Json.ok, $r.Json.error)
        if ($r.Json -and [bool]$r.Json.ok) {
            $opts = $r.Json.options
            Assert-NotNull $opts 'the check answer carries options'
            Assert-True ($opts.PSObject.Properties.Name -contains 'Releases') 'options.Releases is present (an array, possibly empty)'
            return
        }
        $errText = if ($r.Json) { [string]$r.Json.error } else { [string]$r.Error }
        $hasOptions = [bool]($r.Json -and $r.Json.PSObject.Properties['options'] -and $r.Json.options)
        if ($errText -and -not $hasOptions) { Skip-Test ('no network for the release check: ' + $errText) }
        Assert-True $false ('check failed without a usable error: ' + $errText)
    }

    Invoke-RegressionTest -Name 'POST /api/app-update/import {check:true} on a missing folder answers ok:false, valid:false' -Test {
        $r = Invoke-VrmApi -Path '/api/app-update/import' -Method POST -Body @{ path = 'C:\nope\x'; check = $true } -TimeoutSec 60
        Add-TestEvidence ("HTTP {0} ok={1} valid={2} error='{3}'" -f $r.StatusCode, $r.Json.ok, $r.Json.valid, $r.Json.error)
        Assert-True ($r.StatusCode -gt 0 -and $r.StatusCode -ne 500) ('the route answers without crashing (HTTP {0})' -f $r.StatusCode)
        Assert-NotNull $r.Json 'the answer is JSON'
        Assert-False ([bool]$r.Json.ok) 'ok is false'
        Assert-False ([bool]$r.Json.valid) 'valid is false'
    }
}

if ($depth -eq 'Full') {
    Invoke-RegressionTest -Name 'POST /api/app-update/apply without confirm answers 400, progress carries a status' -Test {
        $r = Invoke-VrmApi -Path '/api/app-update/apply' -Method POST -Body @{ target = 'dev' } -TimeoutSec 60
        Add-TestEvidence ("apply without confirm: HTTP {0}" -f $r.StatusCode)
        Assert-Equal 400 $r.StatusCode 'apply without confirm is refused with HTTP 400'
        $p = Invoke-VrmApi -Path '/api/app-update/progress'
        Add-TestEvidence ("progress: HTTP {0} status='{1}'" -f $p.StatusCode, $p.Json.status)
        Assert-True ($p.Ok) '/api/app-update/progress answers'
        Assert-True ([bool][string]$p.Json.status) 'a status field is present'
    }
}
