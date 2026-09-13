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

    Run manually from the project root:
        powershell -File scripts\headset-toolbox\Build-VrhmToolboxExe.ps1
#>

$ErrorActionPreference = "Stop"

$projectRoot    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stubSourcePath = Join-Path $PSScriptRoot "VrhmToolboxStub.cs"
$icoPath        = Join-Path $projectRoot "sources\graph_assets\VR_HEADSET_MANAGER.ico"
$programFolder  = Join-Path $projectRoot "website\headset-toolbox\program"
$exeOutputPath  = Join-Path $projectRoot "website\headset-toolbox\VRHM-Headset-Toolbox.exe"
$testCopyFolder = Join-Path $projectRoot "website\generated\headset-toolbox"

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

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe (C# compiler) not found. Expected under Microsoft.NET\Framework(64)\v4.0.30319."
}

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
$cscArgs += "/out:`"$exeOutputPath`""
$cscArgs += "`"$stubSourcePath`""

$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "csc.exe compilation failed with exit code $($proc.ExitCode)"
}

Write-Host "VRHM toolbox exe built: $exeOutputPath" -ForegroundColor Green

# Test copy. website\generated\ is excluded from git and from release zips, so
# this is a scratch copy only - the committed binary is the one above.
try {
    if (-not (Test-Path -LiteralPath $testCopyFolder)) {
        New-Item -ItemType Directory -Path $testCopyFolder -Force | Out-Null
    }
    Copy-Item -LiteralPath $exeOutputPath -Destination (Join-Path $testCopyFolder "VRHM-Headset-Toolbox.exe") -Force
    Write-Host "Test copy: $(Join-Path $testCopyFolder 'VRHM-Headset-Toolbox.exe')" -ForegroundColor Green
} catch {
    Write-Host "Could not write the test copy: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "Remember to commit the exe in website\headset-toolbox\ to git."
