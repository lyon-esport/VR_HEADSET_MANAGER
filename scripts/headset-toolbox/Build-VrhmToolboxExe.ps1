<#
    Build-VrhmToolboxExe.ps1

    One-time (re-runnable) dev tool. Compiles VrhmToolboxStub.cs into
    website\headset-toolbox\VRHM-Headset-Toolbox.exe, with the four scripts of
    website\headset-toolbox\program\ embedded as manifest resources - so the exe
    is a single, standalone download with no companion files at all. It
    self-extracts them into a VRHM-Toolbox\ subfolder next to itself on first
    run and writes vrhm_server_cache.json at its own level.

    adb.exe is deliberately NOT embedded: the toolbox downloads it from the VRHM
    server (GET /api/adb-tools) on first use, so the binary stays small and adb
    always matches the version the server runs.

    This exe replaces the four it supersedes - Start-HeadsetToolbox.exe,
    Start-Kiosk-Agent.exe, Start-Kiosk-BASIC.exe and Find-VRHM-Server.exe.

    Re-run this whenever VrhmToolboxStub.cs or anything under
    website\headset-toolbox\program\ changes, then commit the resulting .exe.
    Not dot-sourced by scripts_init.ps1 and not run automatically by the app -
    the .exe is a committed binary asset, same as adb.exe/scrcpy.exe/mediamtx.exe.

    A copy is also dropped in website\generated\headset-toolbox\ so a freshly
    built exe can be tested straight away without touching the committed one.

    The exe is version-stamped: -Version defaults to the project's version.txt, which reads
    DEVELOPPMENT-VERSION in the dev tree and carries the real release string only inside a zip
    (Create-ZipRelease.ps1 writes it synthetically). That is why Create-ZipRelease re-runs this
    script with -Version <release> -OutputPath <temp> and substitutes the result into the zip:
    a shipped exe then carries the version of the release it shipped in.

    Run manually from the project root:
        powershell -File scripts\headset-toolbox\Build-VrhmToolboxExe.ps1
        powershell -File scripts\headset-toolbox\Build-VrhmToolboxExe.ps1 -Version "26.05B"
#>

param(
    # Free-form version string ("1.2.3", "26.05B", "26.05_RC1"). Empty = read version.txt.
    [string]$Version = "",

    # Compile here instead of the committed binary. Also suppresses the test copy and the
    # "commit the exe" reminder - a build to another path is not the committed artifact.
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stubSourcePath = Join-Path $PSScriptRoot "VrhmToolboxStub.cs"
$icoPath        = Join-Path $projectRoot "sources\graph_assets\VR_HEADSET_MANAGER.ico"
$programFolder  = Join-Path $projectRoot "website\headset-toolbox\program"
$versionFilePath = Join-Path $projectRoot "version.txt"
$testCopyFolder = Join-Path $projectRoot "website\generated\headset-toolbox"

$isCustomOutput = [bool]$OutputPath
$exeOutputPath  = if ($isCustomOutput) {
    $OutputPath
} else {
    Join-Path $projectRoot "website\headset-toolbox\VRHM-Headset-Toolbox.exe"
}

if (-not (Test-Path -LiteralPath $stubSourcePath)) {
    throw "Toolbox stub source not found: $stubSourcePath"
}
if (-not (Test-Path -LiteralPath $icoPath)) {
    Write-Host "Icon not found at $icoPath - run scripts\Build-AppIcon.ps1 first. Compiling without an icon." -ForegroundColor Yellow
}

# The order matters only for readability - each file is embedded under its own
# name and the stub extracts them by that name.
$embeddedScripts = @(
    "Start-VrhmToolbox.ps1",
    "VrhmServerDiscovery.ps1",
    "VrhmHeadsetOnboard.ps1",
    "VrhmKioskAgent.ps1"
)

foreach ($name in $embeddedScripts) {
    $full = Join-Path $programFolder $name
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Toolbox program file missing: $full"
    }
}

# --- VERSION ---
# Empty -Version = read version.txt (rule 5: -LiteralPath + -Encoding UTF8). This reads
# DEVELOPPMENT-VERSION in the dev tree; a real release string is only ever passed explicitly
# by Create-ZipRelease.ps1.
if (-not $Version) {
    if (Test-Path -LiteralPath $versionFilePath) {
        $Version = (Get-Content -LiteralPath $versionFilePath -Raw -Encoding UTF8).Trim()
    }
    if (-not $Version) { $Version = "0.0.0" }
}

# Win32 file/product version fields are numeric-only (max 4 parts, each 0-65535). The project's
# version string is free-form, so only the leading numeric dotted prefix is used for that; the
# full original string is kept separately as the informational/product version.
$numericMatch = [regex]::Match($Version, '^\d+(\.\d+){0,3}')
$numericParts = if ($numericMatch.Success) { $numericMatch.Value -split '\.' } else { @('0') }
$numericParts = @($numericParts | ForEach-Object { [Math]::Min([int]$_, 65535) })
while ($numericParts.Count -lt 4) { $numericParts += '0' }
$fileVersion = ($numericParts[0..3] -join '.')

Write-Host "Version : $Version (file version $fileVersion)" -ForegroundColor White

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe (C# compiler) not found. Expected under Microsoft.NET\Framework(64)\v4.0.30319."
}

# --- GENERATED ASSEMBLY INFO ---
# website\generated\ is gitignored and release-excluded, so this leaks nowhere and stays
# inspectable after a build. This script does not dot-source utils.ps1, so Write-FileWithoutBom
# is unavailable here - WriteAllText with a no-BOM UTF8Encoding is the equivalent (rule 5b/ASCII
# rule: every value written below is ASCII-only by construction - version string is validated
# elsewhere as ^[\d][\w.\-_]*$, and the rest are literal ASCII text).
function Get-EscapedCSharpString {
    param([string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

if (-not (Test-Path -LiteralPath $testCopyFolder)) {
    New-Item -ItemType Directory -Path $testCopyFolder -Force | Out-Null
}
$assemblyInfoPath = Join-Path $testCopyFolder "AssemblyInfo.generated.cs"
$assemblyInfoLines = @(
    "using System.Reflection;",
    "",
    "[assembly: AssemblyVersion(`"$fileVersion`")]",
    "[assembly: AssemblyFileVersion(`"$fileVersion`")]",
    "[assembly: AssemblyInformationalVersion(`"$(Get-EscapedCSharpString $Version)`")]",
    "[assembly: AssemblyTitle(`"VRHM Headset Toolbox`")]",
    "[assembly: AssemblyProduct(`"VR HEADSET MANAGER`")]",
    "[assembly: AssemblyCompany(`"VR HEADSET MANAGER`")]",
    "[assembly: AssemblyDescription(`"Headset onboarding and kiosk agent toolbox`")]"
)
$assemblyInfoText = ($assemblyInfoLines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($assemblyInfoPath, $assemblyInfoText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Compiling VRHM toolbox stub with: $csc"
$cscArgs = @(
    "/nologo",
    "/target:exe"
)
if (Test-Path -LiteralPath $icoPath) {
    $cscArgs += "/win32icon:`"$icoPath`""
}
foreach ($name in $embeddedScripts) {
    $full = Join-Path $programFolder $name
    $cscArgs += "/resource:`"$full`",$name"
}
$exeOutputDir = Split-Path $exeOutputPath -Parent
if ($exeOutputDir -and -not (Test-Path -LiteralPath $exeOutputDir)) {
    New-Item -ItemType Directory -Path $exeOutputDir -Force | Out-Null
}

$cscArgs += "/out:`"$exeOutputPath`""
$cscArgs += "`"$stubSourcePath`""
$cscArgs += "`"$assemblyInfoPath`""

$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "csc.exe compilation failed with exit code $($proc.ExitCode)"
}

Write-Host "VRHM toolbox exe built: $exeOutputPath" -ForegroundColor Green

if ($isCustomOutput) {
    # Built to a caller-specified path (e.g. Create-ZipRelease's release-stamped copy) - not the
    # committed binary, so no test copy and no commit reminder.
    return
}

# Test copy. website\generated\ is excluded from git and from release zips, so
# this is a scratch copy only - the committed binary is the one above.
try {
    Copy-Item -LiteralPath $exeOutputPath -Destination (Join-Path $testCopyFolder "VRHM-Headset-Toolbox.exe") -Force
    Write-Host "Test copy: $(Join-Path $testCopyFolder 'VRHM-Headset-Toolbox.exe')" -ForegroundColor Green
} catch {
    Write-Host "Could not write the test copy: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "Remember to commit the exe in website\headset-toolbox\ to git."
