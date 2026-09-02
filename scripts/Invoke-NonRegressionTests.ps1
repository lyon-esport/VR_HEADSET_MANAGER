#Requires -Version 5.1
<#
.SYNOPSIS
    Non-regression test harness for VR HEADSET MANAGER. Runs against an
    EXTRACTED RELEASE FOLDER, not against the dev working copy.

.DESCRIPTION
    Run this from the dev folder after building a release. It provisions a
    sandbox profile inside the extracted release (its own config\config.json
    and data\), boots the app, drives it through the web API the way an
    operator would, and reports PASS / WARN / SKIP / FAIL per test.

    The harness itself never ships: scripts\ is hard-excluded from releases by
    Create-ZipRelease.ps1, and section 10 asserts that the extracted release
    contains no scripts\ folder at all.

.PARAMETER VRHMFolder
    The VR HEADSET MANAGER folder to test (must contain main.ps1) - an
    extracted release, or this same source checkout when there is nothing else
    to test against. When omitted, the newest VR_HEADSET_MANAGER.v* sibling
    folder is auto-detected; if none exists and the run is interactive, you
    are offered a choice: test the current folder, or browse for one. The
    harness refuses to auto-detect the dev folder itself unless -Force is
    passed (this guard does not apply when you explicitly choose to test the
    current folder from that prompt - that choice is itself informed consent).

.PARAMETER Version
    Version label for the report. Read from the target's version.txt when omitted.

.PARAMETER Mode
    Auto   - prompt only when a physical action is unavoidable (default)
    Manual - confirm every step and allow overriding any verdict

.PARAMETER Depth
    Light | Standard | Full. Controls how much of the streaming / scrcpy
    matrix is exercised. Standard is the default.

.PARAMETER Sections
    Section ids to run, e.g. -Sections 10,20,50. Default is all of them.

.PARAMETER HeadsetName
    Registered headset to drive. Prompted for when several are available.

.PARAMETER AllowDestructive
    Enables the app uninstall/reinstall tests in section 80. These use the
    shipped 'ADB Wireless activator' APK as their own subject, so they repair
    what they break.

.PARAMETER Unattended
    Suppresses operator prompts for physical actions (e.g. "connect the
    headset") - those SKIP immediately instead of asking and waiting. Use
    this for CI / walk-away runs with no one at the keyboard.

    The interactive launch menu is a separate concern: it is skipped
    automatically whenever -Mode, -Depth, or -Sections is passed explicitly,
    since there is nothing left to ask. -Unattended also skips the menu (it
    implies "no prompts at all"), but you do not need it just to bypass the
    menu - passing the run parameters is enough.

.PARAMETER RestoreOnly
    Do not run any test. Just tear down a sandbox left behind by a crashed run.

.PARAMETER KeepSandbox
    Skip the end-of-run sandbox reset, leaving config\config.json, data\ and
    logs\ in place for post-mortem inspection. Note that the NEXT run against
    that same folder will then fail section 10's packaging assertions, which are
    only meaningful on a pristine extraction.

.PARAMETER Force
    Allow -TargetRoot to point at the dev folder. Dangerous: the run will
    overwrite the live config.json and data\*.csv.

.OUTPUTS
    Console output plus a .txt and .html report under
    scripts\nonRegressionTests\reports\.
    Exit code 0 = all passed, 1 = at least one FAIL, 2 = prerequisite failure.

.EXAMPLE
    .\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder "..\VR_HEADSET_MANAGER.v1.2.3"

.EXAMPLE
    .\scripts\Invoke-NonRegressionTests.ps1 -Depth Light -Sections 10,20 -Mode Auto -Unattended
#>
param(
    [string]$VRHMFolder = '',
    [string]$Version = '',
    [ValidateSet('Auto', 'Manual')][string]$Mode = 'Auto',
    [ValidateSet('Light', 'Standard', 'Full')][string]$Depth = 'Standard',
    # Deliberately [string[]] and not [int[]]: when this script is launched with
    # -File, "-Sections 10,20,40" arrives as the single string "10,20,40", and
    # [int[]] would silently coerce that to the one value 102040. Normalised by
    # ConvertTo-SectionIdList below.
    [string[]]$Sections = @(),
    [string]$HeadsetName = '',
    [switch]$AllowDestructive,
    [switch]$Unattended,
    [switch]$RestoreOnly,
    [switch]$KeepSandbox,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$harnessRoot = Join-Path $PSScriptRoot 'nonRegressionTests'
$devRoot     = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Bootstrap the harness modules
# ---------------------------------------------------------------------------
foreach ($piece in @('test_core.ps1', 'test_prompt.ps1', 'test_api.ps1', 'test_sandbox.ps1', 'test_stream.ps1')) {
    $piecePath = Join-Path $harnessRoot $piece
    if (Test-Path -LiteralPath $piecePath) {
        . $piecePath
    }
    elseif ($piece -in @('test_core.ps1', 'test_prompt.ps1')) {
        Write-Host "ERROR: required harness file not found: $piecePath" -ForegroundColor Red
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Section registry - the single source of truth for what exists and how long
# it takes. Estimates are minutes; 0 means the section is skipped at that depth.
# ---------------------------------------------------------------------------
$sectionRegistry = @(
    [PSCustomObject]@{ Id = 10; Title = 'Startup and packaging'; File = '10_startup.ps1';          Light = 2; Standard = 2;  Full = 2;  Operator = $false }
    [PSCustomObject]@{ Id = 20; Title = 'Web pages and API';     File = '20_webpages.ps1';         Light = 2; Standard = 3;  Full = 3;  Operator = $false }
    [PSCustomObject]@{ Id = 30; Title = 'USB onboarding';        File = '30_headset_usb.ps1';      Light = 0; Standard = 5;  Full = 5;  Operator = $true  }
    [PSCustomObject]@{ Id = 40; Title = 'Registry CRUD';         File = '40_headset_registry.ps1'; Light = 1; Standard = 3;  Full = 4;  Operator = $false }
    [PSCustomObject]@{ Id = 50; Title = 'scrcpy lifecycle';      File = '50_scrcpy.ps1';           Light = 2; Standard = 8;  Full = 20; Operator = $true  }
    [PSCustomObject]@{ Id = 60; Title = 'Streaming matrix';      File = '60_streaming.ps1';        Light = 1; Standard = 10; Full = 35; Operator = $true  }
    [PSCustomObject]@{ Id = 70; Title = 'Monitoring';            File = '70_monitoring.ps1';       Light = 1; Standard = 3;  Full = 5;  Operator = $false }
    [PSCustomObject]@{ Id = 80; Title = 'Apps manager';          File = '80_apps.ps1';             Light = 0; Standard = 4;  Full = 8;  Operator = $true  }
    [PSCustomObject]@{ Id = 90; Title = 'Shutdown and reaper';   File = '90_shutdown.ps1';         Light = 1; Standard = 2;  Full = 3;  Operator = $false }
)

function ConvertTo-SectionIdList {
    <#
    .SYNOPSIS
        Flattens whatever -Sections was given into an int[] of section ids.

    .DESCRIPTION
        Accepts every shape the caller might produce: an array of ints, an
        array of strings, or a single comma-separated string (which is what
        "-File script.ps1 -Sections 10,20,40" actually delivers).

    .EXAMPLE
        ConvertTo-SectionIdList @('10,20,40')   # -> 10, 20, 40
    #>
    param([AllowNull()][string[]]$Raw)

    if ($null -eq $Raw -or $Raw.Count -eq 0) { return @() }

    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($item in $Raw) {
        if ($null -eq $item) { continue }
        foreach ($token in ($item -split '[,;\s]+')) {
            $trimmed = $token.Trim()
            if ($trimmed -match '^\d+$') { $ids.Add([int]$trimmed) | Out-Null }
        }
    }
    return @($ids)
}

function Get-SectionEstimate {
    param([Parameter(Mandatory = $true)]$Section, [Parameter(Mandatory = $true)][string]$AtDepth)
    return [int]$Section.$AtDepth
}

function Get-DepthTotalMinutes {
    param([Parameter(Mandatory = $true)][string]$AtDepth, $Registry = $sectionRegistry)
    $total = 0
    foreach ($s in $Registry) { $total += (Get-SectionEstimate -Section $s -AtDepth $AtDepth) }
    return $total
}

# ---------------------------------------------------------------------------
# Target resolution
# ---------------------------------------------------------------------------
function Resolve-TargetRoot {
    <#
    .SYNOPSIS
        Resolves and validates the folder under test. Exits 2 rather than
        guessing when nothing suitable is found and nothing can be asked.
    #>
    param([string]$Requested, [string]$DevRoot, [bool]$AllowDevRoot, [bool]$Unattended)

    $resolved = ''
    $selfTestChosen = $false

    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested)) {
            Write-Host "ERROR: -VRHMFolder does not exist: $Requested" -ForegroundColor Red
            exit 2
        }
        $resolved = (Resolve-Path -LiteralPath $Requested).Path
    }
    else {
        $parent = Split-Path -Parent $DevRoot
        $leaf   = Split-Path -Leaf $DevRoot
        $candidates = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$leaf.v*" } |
            Sort-Object LastWriteTime -Descending)

        if ($candidates.Count -gt 0) {
            $resolved = $candidates[0].FullName
            Write-Host ("  Auto-detected target: {0}" -f $resolved) -ForegroundColor DarkGray
        }
        elseif ($Unattended) {
            Write-Host "ERROR: no extracted release folder found next to this folder." -ForegroundColor Red
            Write-Host "       Expected something like: $parent\$leaf.v<version>" -ForegroundColor DarkGray
            Write-Host "       Build one with: .\scripts\Create-ZipRelease.ps1 -Version <v> -Unzip" -ForegroundColor DarkGray
            Write-Host "       Or pass -VRHMFolder explicitly." -ForegroundColor DarkGray
            exit 2
        }
        else {
            # Nothing to auto-detect: this copy of the harness may be sitting
            # somewhere with no separate release to test (a plain clone, or
            # this same folder deployed on another machine). Ask rather than
            # fail outright - this is how the harness tests itself.
            Write-Host ''
            Write-Host '  No extracted release folder was found next to this folder, and no' -ForegroundColor Yellow
            Write-Host '  -VRHMFolder was given.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host ("    [1] Test the current folder ({0})" -f $DevRoot)
            Write-Host '    [2] Browse for a folder...'
            Write-Host ''
            $choice = Read-TestMenuChoice -Prompt '  Select' -Accept @('1', '2') -Default '1'

            if ($choice -eq '2') {
                Add-Type -AssemblyName System.Windows.Forms
                $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                $dialog.Description = 'Select the VR HEADSET MANAGER folder to test (must contain main.ps1)'
                if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or -not $dialog.SelectedPath) {
                    Write-Host "ERROR: no folder selected." -ForegroundColor Red
                    exit 2
                }
                $resolved = $dialog.SelectedPath
            }
            else {
                $resolved = $DevRoot
                $selfTestChosen = $true
            }
        }
    }

    # The release zip nests everything under a <folderName>\ entry, so an
    # extracted release is <extractDir>\VR_HEADSET_MANAGER\main.ps1 rather than
    # <extractDir>\main.ps1. Accept either shape by descending one level when
    # the folder we were handed is just a wrapper.
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'main.ps1'))) {
        $nested = @(Get-ChildItem -LiteralPath $resolved -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'main.ps1') })
        if ($nested.Count -eq 1) {
            $resolved = $nested[0].FullName
            Write-Host ("  Descended into the extracted app folder: {0}" -f (Split-Path -Leaf $resolved)) -ForegroundColor DarkGray
        }
    }

    # Picking "[1] Test the current folder" from the prompt above IS informed
    # consent - it does not need -Force on top of itself. This guard only
    # protects against -VRHMFolder / auto-detection accidentally landing on
    # the dev folder by coincidence.
    $devResolved = (Resolve-Path -LiteralPath $DevRoot).Path
    if ($resolved -eq $devResolved -and -not $AllowDevRoot -and -not $selfTestChosen) {
        Write-Host "ERROR: refusing to run against the dev folder." -ForegroundColor Red
        Write-Host "       This would overwrite your live config\config.json and data\*.csv." -ForegroundColor DarkGray
        Write-Host "       Point -VRHMFolder at an extracted release, or pass -Force to override." -ForegroundColor DarkGray
        exit 2
    }

    $mainPs1 = Join-Path $resolved 'main.ps1'
    if (-not (Test-Path -LiteralPath $mainPs1)) {
        Write-Host "ERROR: target does not look like a VR HEADSET MANAGER install (no main.ps1):" -ForegroundColor Red
        Write-Host "       $resolved" -ForegroundColor DarkGray
        exit 2
    }

    return $resolved
}

function Get-TargetVersion {
    param([Parameter(Mandatory = $true)][string]$Root)
    $versionFile = Join-Path $Root 'version.txt'
    if (Test-Path -LiteralPath $versionFile) {
        $raw = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
        if ($raw) { return $raw }
    }
    $leaf = Split-Path -Leaf $Root
    if ($leaf -match '\.v(.+)$') { return $Matches[1] }
    return 'unknown'
}

# ---------------------------------------------------------------------------
# Launch menu
# ---------------------------------------------------------------------------
function Show-LaunchMenu {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$DefaultMode,
        [Parameter(Mandatory = $true)][string]$DefaultDepth
    )

    Write-Host ''
    Write-Host '=== VR HEADSET MANAGER - Non-Regression Tests ===' -ForegroundColor White
    Write-Host ("  Target  : {0}" -f $TargetRoot) -ForegroundColor DarkGray
    Write-Host ("  Version : {0}" -f $Version) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Mode' -ForegroundColor Gray
    Write-Host '    [1] Automatic - prompt only when a physical action is unavoidable'
    Write-Host '    [2] Manual    - confirm every step, override any verdict'
    Write-Host '    [3] Sections  - pick which sections to run'
    Write-Host ''

    $modeChoice = Read-TestMenuChoice -Prompt '  Select mode' -Accept @('1', '2', '3') -Default '1'

    $chosenMode = $DefaultMode
    $chosenSections = @()

    if ($modeChoice -eq '1') { $chosenMode = 'Auto' }
    if ($modeChoice -eq '2') { $chosenMode = 'Manual' }
    if ($modeChoice -eq '3') {
        Write-Host ''
        Write-Host '  Available sections:' -ForegroundColor Gray
        foreach ($s in $sectionRegistry) {
            $flag = ''
            if ($s.Operator) { $flag = '  (needs operator)' }
            Write-Host ("    {0}  {1}{2}" -f $s.Id, $s.Title, $flag)
        }
        Write-Host ''
        $raw = Read-Host '  Sections to run (comma separated, empty = all)'
        if ($raw -and $raw.Trim()) {
            $chosenSections = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        }
        $subMode = Read-TestMenuChoice -Prompt '  Run those sections [1] Automatic or [2] Manual' -Accept @('1', '2') -Default '1'
        if ($subMode -eq '1') { $chosenMode = 'Auto' } else { $chosenMode = 'Manual' }
    }

    Write-Host ''
    Write-Host '  Depth' -ForegroundColor Gray
    Write-Host ("    [1] Light     ~{0,2} min  - one representative combo per axis" -f (Get-DepthTotalMinutes 'Light'))
    Write-Host ("    [2] Standard  ~{0,2} min  - one axis varied at a time (default)" -f (Get-DepthTotalMinutes 'Standard'))
    Write-Host ("    [3] Full      ~{0,2} min  - exhaustive cross-product" -f (Get-DepthTotalMinutes 'Full'))
    Write-Host ''

    $depthChoice = Read-TestMenuChoice -Prompt '  Select depth' -Accept @('1', '2', '3') -Default '2'
    $chosenDepth = $DefaultDepth
    switch ($depthChoice) {
        '1' { $chosenDepth = 'Light' }
        '2' { $chosenDepth = 'Standard' }
        '3' { $chosenDepth = 'Full' }
    }

    return @{ Mode = $chosenMode; Depth = $chosenDepth; Sections = $chosenSections }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$sectionIds = ConvertTo-SectionIdList -Raw $Sections

$target = Resolve-TargetRoot -Requested $VRHMFolder -DevRoot $devRoot -AllowDevRoot ([bool]$Force) -Unattended ([bool]$Unattended)
if (-not $Version) { $Version = Get-TargetVersion -Root $target }

# -RestoreOnly: clean up a crashed run and stop.
if ($RestoreOnly) {
    Write-Host ''
    Write-Host '=== Restore only - tearing down any leftover sandbox ===' -ForegroundColor Cyan
    if (Get-Command Remove-SandboxArtifacts -ErrorAction SilentlyContinue) {
        Remove-SandboxArtifacts -TargetRoot $target
        if (-not $KeepSandbox) {
            Reset-SandboxTarget -TargetRoot $target -DevRoot $devRoot | Out-Null
        }
        Write-Host '  Done.' -ForegroundColor Green
        exit 0
    }
    Write-Host '  ERROR: test_sandbox.ps1 not available.' -ForegroundColor Red
    exit 2
}

# The menu exists to ASK for what wasn't given on the command line. Once the
# operator has already specified Mode, Depth, or Sections explicitly, asking
# again is just re-prompting for an answer already provided. -Unattended
# still skips it too (it means "no prompts at all"), but is not required
# just to bypass the menu.
$runParamsGiven = $PSBoundParameters.ContainsKey('Mode') -or $PSBoundParameters.ContainsKey('Depth') -or $PSBoundParameters.ContainsKey('Sections')
if (-not $Unattended -and -not $runParamsGiven) {
    $menu = Show-LaunchMenu -TargetRoot $target -Version $Version -DefaultMode $Mode -DefaultDepth $Depth
    $Mode  = $menu.Mode
    $Depth = $menu.Depth
    if ($menu.Sections.Count -gt 0) { $sectionIds = @($menu.Sections) }
}

# Resolve which sections actually run
$selected = @($sectionRegistry | Where-Object {
    ($sectionIds.Count -eq 0 -or $sectionIds -contains $_.Id) -and
    ((Get-SectionEstimate -Section $_ -AtDepth $Depth) -gt 0)
})

if ($selected.Count -eq 0) {
    Write-Host ''
    Write-Host 'ERROR: no sections selected to run at this depth.' -ForegroundColor Red
    if ($sectionIds.Count -gt 0) {
        Write-Host ("       Requested: {0}" -f ($sectionIds -join ', ')) -ForegroundColor DarkGray
        Write-Host ("       Known ids: {0}" -f (($sectionRegistry | ForEach-Object { $_.Id }) -join ', ')) -ForegroundColor DarkGray
        Write-Host ("       Note: some sections are skipped at depth {0}." -f $Depth) -ForegroundColor DarkGray
    }
    exit 2
}

$plannedMinutes = 0
foreach ($s in $selected) { $plannedMinutes += (Get-SectionEstimate -Section $s -AtDepth $Depth) }

Initialize-TestRun -TargetRoot $target -Version $Version -Mode $Mode -Depth $Depth -ReportFolder (Join-Path $harnessRoot 'reports') | Out-Null
$global:TestRun.AllowDestructive = [bool]$AllowDestructive
$global:TestRun.HeadsetName = $HeadsetName
# Sections 50/60 use this to decide whether prompting for a headset is allowed.
$global:TestRun.Unattended = [bool]$Unattended
$global:TestRun.DevRoot = $devRoot

Write-Host ''
Write-Host '=== Run plan ===' -ForegroundColor White
Write-Host ("  Mode {0}   Depth {1}   Sections {2}   Estimated {3} min" -f $Mode, $Depth, $selected.Count, $plannedMinutes) -ForegroundColor DarkGray
foreach ($s in $selected) {
    $flag = ''
    if ($s.Operator) { $flag = '  (needs operator)' }
    Write-Host ("    {0}  {1,-24} ~{2} min{3}" -f $s.Id, $s.Title, (Get-SectionEstimate -Section $s -AtDepth $Depth), $flag) -ForegroundColor DarkGray
}

$exitCode = 2
try {
    # --- Preconditions and sandbox provisioning -----------------------------
    if (Get-Command Test-SandboxPreconditions -ErrorAction SilentlyContinue) {
        if (-not (Test-SandboxPreconditions -TargetRoot $target)) {
            Write-Host ''
            Write-Host 'Preconditions failed. Nothing was started or modified.' -ForegroundColor Red
            exit 2
        }
    }
    else {
        Write-Host ''
        Write-Host '  NOTE: test_sandbox.ps1 not present - running harness-only sections.' -ForegroundColor Yellow
    }

    # --- Run sections -------------------------------------------------------
    $runIndex = 0
    foreach ($section in $selected) {
        $runIndex++
        $remaining = 0
        foreach ($s in ($selected | Select-Object -Skip $runIndex)) {
            $remaining += (Get-SectionEstimate -Section $s -AtDepth $Depth)
        }

        Start-TestSection -Id ([string]$section.Id) -Title $section.Title -EstimateMinutes (Get-SectionEstimate -Section $section -AtDepth $Depth) | Out-Null

        $sectionFile = Join-Path (Join-Path $harnessRoot 'tests') $section.File
        if (-not (Test-Path -LiteralPath $sectionFile)) {
            Write-TestResult -Status 'SKIP' -Name $section.Title -Detail 'section not implemented yet'
            $global:TestRun.Results.Add([PSCustomObject]@{
                Section = [string]$section.Id; Name = $section.Title; Status = 'SKIP'
                Detail = 'section not implemented yet'; Evidence = @(); Warnings = @()
                Duration = [TimeSpan]::Zero; Override = $false; At = Get-Date
            }) | Out-Null
        }
        else {
            try {
                . $sectionFile
            }
            catch {
                Write-TestResult -Status 'FAIL' -Name ("{0} (section aborted)" -f $section.Title) -Detail $_.Exception.Message
                $global:TestRun.Results.Add([PSCustomObject]@{
                    Section = [string]$section.Id; Name = ("{0} (section aborted)" -f $section.Title); Status = 'FAIL'
                    Detail = $_.Exception.Message; Evidence = @(); Warnings = @()
                    Duration = [TimeSpan]::Zero; Override = $false; At = Get-Date
                }) | Out-Null
            }
        }

        Complete-TestSection
        if ($remaining -gt 0) {
            Write-Host ("    ~{0} min of tests remaining" -f $remaining) -ForegroundColor DarkGray
        }
    }

    $global:TestRun.FinishedAt = Get-Date
    $exitCode = Get-TestExitCode
}
finally {
    # Teardown always runs, including on Ctrl+C.
    if (Get-Command Stop-SandboxApp -ErrorAction SilentlyContinue) {
        try { Stop-SandboxApp -TargetRoot $target | Out-Null } catch { }
    }

    # Preserve the app's log file as run evidence before Reset-SandboxTarget
    # deletes logs\ entirely below.
    if (Get-Command Save-SandboxLogs -ErrorAction SilentlyContinue) {
        try { Save-SandboxLogs -TargetRoot $target } catch { }
    }

    # Restore the target to its just-extracted state so it can be tested again.
    # Section 10's packaging assertions only hold on a pristine extraction, and
    # the sandbox seed (config\config.json, data\) is what breaks them.
    if ((-not $KeepSandbox) -and (Get-Command Reset-SandboxTarget -ErrorAction SilentlyContinue)) {
        try { Reset-SandboxTarget -TargetRoot $target -DevRoot $devRoot | Out-Null } catch { }
    }

    if ($null -ne $global:TestRun) {
        if (-not $global:TestRun.FinishedAt) { $global:TestRun.FinishedAt = Get-Date }
        Write-TestSummary

        try {
            $txt  = Write-TestReportText
            $html = Write-TestReportHtml
            Write-Host ''
            Write-Host ("  Report: {0}" -f $txt) -ForegroundColor DarkGray
            Write-Host ("  Report: {0}" -f $html) -ForegroundColor DarkGray
        }
        catch {
            Write-Host ("  WARNING: could not write report - {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

exit $exitCode
