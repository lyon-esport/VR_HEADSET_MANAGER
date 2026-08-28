#Requires -Version 5.1
<#
.SYNOPSIS
    Core result model, assertions and reporting for the VR HEADSET MANAGER
    non-regression test harness.

.DESCRIPTION
    Dot-sourced by scripts\Invoke-NonRegressionTests.ps1. Provides:
      - the run state object ($global:TestRun) and its lifecycle
      - Invoke-RegressionTest: runs one test scriptblock, times it, catches
        assertion failures / skips, records the verdict and prints it
      - assertion helpers (Assert-*) that throw a plain message on failure
      - Skip-Test / Write-TestWarning / Add-TestEvidence
      - console summary plus text and HTML report writers

    Deliberately has NO dependency on the application under test: the harness
    must still work when the artifact it is testing is broken.

    ASCII only (CLAUDE.md rule 1). All file writes go through
    Write-TextFileNoBom (CLAUDE.md rule 5b).
#>

# ---------------------------------------------------------------------------
# Per-test scratch state, reset by Invoke-RegressionTest
# ---------------------------------------------------------------------------
$script:CurrentEvidence = New-Object System.Collections.Generic.List[string]
$script:CurrentWarnings = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Run lifecycle
# ---------------------------------------------------------------------------
function Initialize-TestRun {
    <#
    .SYNOPSIS
        Creates $global:TestRun, the single state object for one harness run.
    .EXAMPLE
        Initialize-TestRun -TargetRoot 'D:\rel' -Version '1.2.3' -Mode Auto -Depth Standard
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$Version = 'unknown',
        [ValidateSet('Auto', 'Manual')][string]$Mode = 'Auto',
        [ValidateSet('Light', 'Standard', 'Full')][string]$Depth = 'Standard',
        [string]$ReportFolder = (Join-Path $PSScriptRoot 'reports')
    )

    $global:TestRun = [PSCustomObject]@{
        TargetRoot       = $TargetRoot
        Version          = $Version
        Mode             = $Mode
        Depth            = $Depth
        ReportFolder     = $ReportFolder
        StartedAt        = Get-Date
        FinishedAt       = $null
        Results          = (New-Object System.Collections.Generic.List[object])
        Sections         = (New-Object System.Collections.Generic.List[object])
        CurrentSection   = $null
        AllowDestructive = $false
        HeadsetName      = ''
        # Sections 50/60 read these. Declared here because $global:TestRun is a
        # PSCustomObject - assigning an undeclared property to one throws.
        Unattended       = $false
        DevRoot          = ''
    }
    return $global:TestRun
}

function Start-TestSection {
    <#
    .SYNOPSIS
        Opens a section, prints its banner and its duration estimate.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [int]$EstimateMinutes = 0
    )

    $section = [PSCustomObject]@{
        Id              = $Id
        Title           = $Title
        EstimateMinutes = $EstimateMinutes
        StartedAt       = Get-Date
        Elapsed         = $null
    }
    $global:TestRun.CurrentSection = $section
    $global:TestRun.Sections.Add($section) | Out-Null

    Write-Host ''
    Write-Host ("=== {0} - {1} ===" -f $Id, $Title) -ForegroundColor Cyan
    if ($EstimateMinutes -gt 0) {
        Write-Host ("    estimated {0} min at depth {1}" -f $EstimateMinutes, $global:TestRun.Depth) -ForegroundColor DarkGray
    }
    return $section
}

function Complete-TestSection {
    <#
    .SYNOPSIS
        Closes the current section and prints its actual duration.
    #>
    $section = $global:TestRun.CurrentSection
    if ($null -eq $section) { return }

    $section.Elapsed = (Get-Date) - $section.StartedAt
    Write-Host ("    section done in {0}" -f (Format-TestDuration $section.Elapsed)) -ForegroundColor DarkGray
    $global:TestRun.CurrentSection = $null
}

# ---------------------------------------------------------------------------
# In-test helpers (callable from inside a test scriptblock)
# ---------------------------------------------------------------------------
function Add-TestEvidence {
    <#
    .SYNOPSIS
        Records a line of supporting detail for the test currently running.
        Shown on failure, in Manual mode, and always in the report.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    $script:CurrentEvidence.Add($Line) | Out-Null
}

function Write-TestWarning {
    <#
    .SYNOPSIS
        Records a non-fatal concern. The test verdict becomes WARN if no
        assertion failed.
    #>
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:CurrentWarnings.Add($Message) | Out-Null
}

function Skip-Test {
    <#
    .SYNOPSIS
        Aborts the current test with a SKIP verdict (unmet precondition:
        no hardware, no internet, operator declined).
    #>
    param([Parameter(Mandatory = $true)][string]$Reason)
    throw ("SKIP::" + $Reason)
}

# ---------------------------------------------------------------------------
# Assertions - all throw a plain message string on failure
# ---------------------------------------------------------------------------
function Assert-True {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()]$Expected,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Expected -ne $Actual) {
        throw ("{0}: expected '{1}', got '{2}'" -f $Label, $Expected, $Actual)
    }
}

function Assert-NotNull {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($null -eq $Value) { throw ("{0}: value is null" -f $Label) }
    if ($Value -is [string] -and $Value -eq '') { throw ("{0}: value is an empty string" -f $Label) }
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -notmatch $Pattern) {
        throw ("{0}: '{1}' does not match the expected pattern {2}" -f $Label, $Value, $Pattern)
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Collection,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()]$Item,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($null -eq $Collection -or @($Collection) -notcontains $Item) {
        throw ("{0}: collection does not contain '{1}'" -f $Label, $Item)
    }
}

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = ''
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        $what = 'file'
        if ($Label) { $what = $Label }
        throw ("{0} not found: {1}" -f $what, $Path)
    }
}

function Assert-FileMissing {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = ''
    )
    if (Test-Path -LiteralPath $Path) {
        $what = 'file'
        if ($Label) { $what = $Label }
        throw ("{0} should not exist but does: {1}" -f $what, $Path)
    }
}

# ---------------------------------------------------------------------------
# Formatting / rendering
# ---------------------------------------------------------------------------
function Format-TestDuration {
    param([Parameter(Mandatory = $true)][TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 60) { return ("{0:N1}s" -f $Span.TotalSeconds) }
    return ("{0:N0}m{1:00}s" -f [math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Get-TestStatusColor {
    param([Parameter(Mandatory = $true)][string]$Status)
    switch ($Status) {
        'PASS'  { return 'Green' }
        'WARN'  { return 'Yellow' }
        'SKIP'  { return 'DarkGray' }
        'INFO'  { return 'Cyan' }
        default { return 'Red' }
    }
}

function Write-TestResult {
    <#
    .SYNOPSIS
        Renders one result line. Mirrors the Write-Result helper style already
        used by scripts\Test-ComputerHardwareInfo.ps1.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Detail = '',
        [string]$Duration = ''
    )
    $line = "  [{0}] {1}" -f $Status.PadRight(4), $Name
    if ($Detail)   { $line += " - $Detail" }
    if ($Duration) { $line += "  ($Duration)" }
    Write-Host $line -ForegroundColor (Get-TestStatusColor $Status)
}

function Show-TestEvidence {
    param([string[]]$Evidence, [string]$Indent = '        ')
    foreach ($line in $Evidence) {
        Write-Host ($Indent + $line) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# The test runner
# ---------------------------------------------------------------------------
function Invoke-RegressionTest {
    <#
    .SYNOPSIS
        Runs one test scriptblock, times it, converts exceptions into verdicts,
        records the result and prints it.

    .DESCRIPTION
        Verdict rules:
          - scriptblock completes    -> PASS, or WARN if it called Write-TestWarning
          - throws "SKIP::<reason>"  -> SKIP
          - throws anything else     -> FAIL, or WARN when -KnownDefect is set
                                        (a documented open bug we do not want
                                        failing the whole release run)
        In Manual mode the operator is offered a verdict override afterwards.

    .EXAMPLE
        Invoke-RegressionTest -Name 'adb.exe is present' -Test {
            Assert-FileExists $adbPath 'adb.exe'
        }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Test,
        [string]$KnownDefect = ''
    )

    $script:CurrentEvidence = New-Object System.Collections.Generic.List[string]
    $script:CurrentWarnings = New-Object System.Collections.Generic.List[string]

    $sectionId = '--'
    if ($global:TestRun.CurrentSection) { $sectionId = $global:TestRun.CurrentSection.Id }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'PASS'
    $detail = ''

    try {
        $ErrorActionPreference = 'Stop'
        & $Test | Out-Null
        if ($script:CurrentWarnings.Count -gt 0) {
            $status = 'WARN'
            $detail = $script:CurrentWarnings[0]
        }
    }
    catch {
        $message = $_.Exception.Message
        if ($message -like 'SKIP::*') {
            $status = 'SKIP'
            $detail = $message.Substring(6)
        }
        elseif ($KnownDefect) {
            $status = 'WARN'
            $detail = "known defect ({0}): {1}" -f $KnownDefect, $message
        }
        else {
            $status = 'FAIL'
            $detail = $message
        }
    }
    finally {
        $sw.Stop()
    }

    $result = [PSCustomObject]@{
        Section  = $sectionId
        Name     = $Name
        Status   = $status
        Detail   = $detail
        Evidence = @($script:CurrentEvidence)
        Warnings = @($script:CurrentWarnings)
        Duration = $sw.Elapsed
        Override = $false
        At       = Get-Date
    }

    Write-TestResult -Status $status -Name $Name -Detail $detail -Duration (Format-TestDuration $sw.Elapsed)

    $showEvidence = ($status -eq 'FAIL') -or ($global:TestRun.Mode -eq 'Manual')
    if ($showEvidence -and $result.Evidence.Count -gt 0) {
        Show-TestEvidence -Evidence $result.Evidence
    }
    if ($status -ne 'WARN' -and $result.Warnings.Count -gt 0) {
        foreach ($w in $result.Warnings) {
            Write-Host ("        warn: " + $w) -ForegroundColor Yellow
        }
    }

    if ($global:TestRun.Mode -eq 'Manual' -and (Get-Command Get-OperatorVerdict -ErrorAction SilentlyContinue)) {
        $verdict = Get-OperatorVerdict -Result $result
        if ($verdict -eq 'RETRY') {
            return (Invoke-RegressionTest -Name $Name -Test $Test -KnownDefect $KnownDefect)
        }
        if ($verdict -ne $result.Status) {
            $result.Status   = $verdict
            $result.Override = $true
            Write-Host ("        operator override -> {0}" -f $verdict) -ForegroundColor Magenta
        }
    }

    $global:TestRun.Results.Add($result) | Out-Null
    return $result
}

# ---------------------------------------------------------------------------
# Summary and reports
# ---------------------------------------------------------------------------
function Get-TestRunSummary {
    <#
    .SYNOPSIS
        Returns @{Pass;Fail;Warn;Skip;Total;Elapsed} for the current run.
    #>
    $r = $global:TestRun.Results
    $finished = Get-Date
    if ($global:TestRun.FinishedAt) { $finished = $global:TestRun.FinishedAt }

    return @{
        Pass    = @($r | Where-Object { $_.Status -eq 'PASS' }).Count
        Fail    = @($r | Where-Object { $_.Status -eq 'FAIL' }).Count
        Warn    = @($r | Where-Object { $_.Status -eq 'WARN' }).Count
        Skip    = @($r | Where-Object { $_.Status -eq 'SKIP' }).Count
        Total   = $r.Count
        Elapsed = ($finished - $global:TestRun.StartedAt)
    }
}

function Write-TestSummary {
    <#
    .SYNOPSIS
        Prints the end-of-run console summary, listing every failure.
    #>
    $s = Get-TestRunSummary

    Write-Host ''
    Write-Host '=== SUMMARY ===' -ForegroundColor White
    Write-Host ("  Target  : {0}" -f $global:TestRun.TargetRoot) -ForegroundColor DarkGray
    Write-Host ("  Version : {0}   Mode: {1}   Depth: {2}" -f $global:TestRun.Version, $global:TestRun.Mode, $global:TestRun.Depth) -ForegroundColor DarkGray
    Write-Host ("  Duration: {0}" -f (Format-TestDuration $s.Elapsed)) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("  PASS {0}" -f $s.Pass) -ForegroundColor Green
    Write-Host ("  WARN {0}" -f $s.Warn) -ForegroundColor Yellow
    Write-Host ("  SKIP {0}" -f $s.Skip) -ForegroundColor DarkGray
    Write-Host ("  FAIL {0}" -f $s.Fail) -ForegroundColor Red

    if ($s.Fail -gt 0) {
        Write-Host ''
        Write-Host '  Failures:' -ForegroundColor Red
        foreach ($f in ($global:TestRun.Results | Where-Object { $_.Status -eq 'FAIL' })) {
            Write-Host ("    [{0}] {1}" -f $f.Section, $f.Name) -ForegroundColor Red
            Write-Host ("           {0}" -f $f.Detail) -ForegroundColor DarkGray
        }
    }
}

function Write-TextFileNoBom {
    <#
    .SYNOPSIS
        Writes UTF-8 text without a BOM. Local copy of the app's
        Write-FileWithoutBom so the harness stays self-contained
        (CLAUDE.md rule 5b).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-HtmlText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

function Get-TestReportBaseName {
    $stamp = $global:TestRun.StartedAt.ToString('yyyy-MM-dd_HHmmss')
    $safeVersion = ($global:TestRun.Version -replace '[^\w\.\-]', '_')
    return ("NonRegressionTests_v{0}_{1}" -f $safeVersion, $stamp)
}

function Write-TestReportText {
    <#
    .SYNOPSIS
        Writes the full plain-text transcript report. Returns its path.
    #>
    param([string]$ReportFolder = $global:TestRun.ReportFolder)

    if (-not (Test-Path -LiteralPath $ReportFolder)) {
        New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
    }
    $path = Join-Path $ReportFolder ((Get-TestReportBaseName) + '.txt')
    $s = Get-TestRunSummary

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('VR HEADSET MANAGER - Non-Regression Test Report')
    [void]$sb.AppendLine('==============================================')
    [void]$sb.AppendLine(("Target   : {0}" -f $global:TestRun.TargetRoot))
    [void]$sb.AppendLine(("Version  : {0}" -f $global:TestRun.Version))
    [void]$sb.AppendLine(("Mode     : {0}" -f $global:TestRun.Mode))
    [void]$sb.AppendLine(("Depth    : {0}" -f $global:TestRun.Depth))
    [void]$sb.AppendLine(("Started  : {0}" -f $global:TestRun.StartedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$sb.AppendLine(("Duration : {0}" -f (Format-TestDuration $s.Elapsed)))
    [void]$sb.AppendLine(("Result   : PASS {0} / WARN {1} / SKIP {2} / FAIL {3}" -f $s.Pass, $s.Warn, $s.Skip, $s.Fail))
    [void]$sb.AppendLine('')

    $lastSection = ''
    foreach ($r in $global:TestRun.Results) {
        if ($r.Section -ne $lastSection) {
            $title = ''
            $sec = $global:TestRun.Sections | Where-Object { $_.Id -eq $r.Section } | Select-Object -First 1
            if ($sec) { $title = $sec.Title }
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine(("--- {0} {1} ---" -f $r.Section, $title))
            $lastSection = $r.Section
        }
        $line = "[{0}] {1}" -f $r.Status.PadRight(4), $r.Name
        if ($r.Detail)   { $line += " - " + $r.Detail }
        if ($r.Override) { $line += "  (operator override)" }
        $line += "  (" + (Format-TestDuration $r.Duration) + ")"
        [void]$sb.AppendLine($line)
        foreach ($e in $r.Evidence) { [void]$sb.AppendLine('        ' + $e) }
    }

    Write-TextFileNoBom -Path $path -Content $sb.ToString()
    return $path
}

function Write-TestReportHtml {
    <#
    .SYNOPSIS
        Writes a compact self-contained HTML summary. Returns its path.
    #>
    param([string]$ReportFolder = $global:TestRun.ReportFolder)

    if (-not (Test-Path -LiteralPath $ReportFolder)) {
        New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
    }
    $path = Join-Path $ReportFolder ((Get-TestReportBaseName) + '.html')
    $s = Get-TestRunSummary

    $rows = New-Object System.Text.StringBuilder
    $lastSection = ''
    foreach ($r in $global:TestRun.Results) {
        if ($r.Section -ne $lastSection) {
            $title = ''
            $sec = $global:TestRun.Sections | Where-Object { $_.Id -eq $r.Section } | Select-Object -First 1
            if ($sec) { $title = $sec.Title }
            [void]$rows.AppendLine(("<tr class='sec'><td colspan='4'>{0} {1}</td></tr>" -f $r.Section, (ConvertTo-HtmlText $title)))
            $lastSection = $r.Section
        }
        $detail = ConvertTo-HtmlText $r.Detail
        if ($r.Override) { $detail += " <em>(operator override)</em>" }
        $evidence = ''
        if ($r.Evidence.Count -gt 0) {
            $evidence = "<div class='ev'>" + (($r.Evidence | ForEach-Object { ConvertTo-HtmlText $_ }) -join '<br>') + "</div>"
        }
        $rowHtml = "<tr><td class='st {0}'>{0}</td><td>{1}</td><td>{2}{3}</td><td class='dur'>{4}</td></tr>" -f $r.Status, (ConvertTo-HtmlText $r.Name), $detail, $evidence, (Format-TestDuration $r.Duration)
        [void]$rows.AppendLine($rowHtml)
    }

    $head = @'
<!doctype html>
<html><head><meta charset="utf-8"><title>VRHM Non-Regression Tests</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#1e1e1e;color:#ddd}
h1{font-size:20px;margin:0 0 4px}
.meta{color:#888;font-size:13px;margin-bottom:16px}
.tot span{display:inline-block;margin-right:16px;font-weight:600}
.PASSv{color:#4ec94e}.WARNv{color:#e0c040}.SKIPv{color:#888}.FAILv{color:#e05555}
table{border-collapse:collapse;width:100%;font-size:13px;margin-top:16px}
td{border-bottom:1px solid #333;padding:6px 8px;vertical-align:top}
tr.sec td{background:#2a2a2a;color:#6cf;font-weight:600;padding-top:10px}
td.st{width:56px;font-weight:700}
td.st.PASS{color:#4ec94e}td.st.WARN{color:#e0c040}td.st.SKIP{color:#888}td.st.FAIL{color:#e05555}
td.dur{width:70px;color:#777;text-align:right}
.ev{color:#888;font-family:Consolas,monospace;font-size:12px;margin-top:4px}
</style></head><body>
<h1>VR HEADSET MANAGER - Non-Regression Tests</h1>
'@

    $meta = "<div class=""meta"">Target: {0}<br>Version: {1} &nbsp; Mode: {2} &nbsp; Depth: {3}<br>Started: {4} &nbsp; Duration: {5}</div>" -f `
        (ConvertTo-HtmlText $global:TestRun.TargetRoot), (ConvertTo-HtmlText $global:TestRun.Version), `
        $global:TestRun.Mode, $global:TestRun.Depth, `
        $global:TestRun.StartedAt.ToString('yyyy-MM-dd HH:mm:ss'), (Format-TestDuration $s.Elapsed)

    $totals = "<div class=""tot""><span class=""PASSv"">PASS {0}</span><span class=""WARNv"">WARN {1}</span><span class=""SKIPv"">SKIP {2}</span><span class=""FAILv"">FAIL {3}</span></div>" -f `
        $s.Pass, $s.Warn, $s.Skip, $s.Fail

    $html = $head + $meta + $totals + "<table>" + $rows.ToString() + "</table></body></html>"

    Write-TextFileNoBom -Path $path -Content $html
    return $path
}

function Get-TestExitCode {
    <#
    .SYNOPSIS
        0 = all good, 1 = at least one FAIL. Prerequisite failures exit 2 from
        the entry script before any test runs. WARN never fails the run.
    #>
    $s = Get-TestRunSummary
    if ($s.Fail -gt 0) { return 1 }
    return 0
}
