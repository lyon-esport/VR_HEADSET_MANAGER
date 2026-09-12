<#
    Build-FindServerExe.ps1

    One-time (re-runnable) dev tool. Compiles FindServerStub.cs into
    website\find-server\Find-VRHM-Server.exe, with the current
    scripts\Tools\Find-VRHM-Server.ps1 embedded as a manifest resource (so
    the exe is a single, standalone download - it self-extracts that script
    into a find-server\ subfolder next to itself on first run, and writes its
    result to a vrhm_server_cache.json shared with the other toolbox tools
    when run from inside VRHM-Headset-Toolbox.zip) and the existing
    sources\graph_assets\VR_HEADSET_MANAGER.ico embedded as its icon.

    Re-run this whenever FindServerStub.cs or scripts\Tools\Find-VRHM-Server.ps1
    changes, then commit the resulting .exe. Not dot-sourced by
    scripts_init.ps1 and not run automatically by the app - the .exe is a
    committed binary asset, same as adb.exe/scrcpy.exe/mediamtx.exe.

    Run manually from the project root:
        powershell -File scripts\find-server\Build-FindServerExe.ps1
#>

$ErrorActionPreference = "Stop"

$projectRoot     = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$stubSourcePath  = Join-Path $PSScriptRoot "FindServerStub.cs"
$icoPath         = Join-Path $projectRoot "sources\graph_assets\VR_HEADSET_MANAGER.ico"
$scriptPath      = Join-Path $projectRoot "scripts\Tools\Find-VRHM-Server.ps1"
$exeOutputFolder = Join-Path $projectRoot "website\find-server"
$exeOutputPath   = Join-Path $exeOutputFolder "Find-VRHM-Server.exe"

if (-not (Test-Path -LiteralPath $stubSourcePath)) {
    throw "Find-server stub source not found: $stubSourcePath"
}
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Find-VRHM-Server.ps1 not found to embed: $scriptPath"
}
if (-not (Test-Path -LiteralPath $icoPath)) {
    Write-Host "Icon not found at $icoPath - run scripts\Build-AppIcon.ps1 first. Compiling without an icon." -ForegroundColor Yellow
}
if (-not (Test-Path -LiteralPath $exeOutputFolder)) {
    New-Item -ItemType Directory -Path $exeOutputFolder -Force | Out-Null
}

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe (C# compiler) not found. Expected under Microsoft.NET\Framework(64)\v4.0.30319."
}

Write-Host "Compiling find-server stub with: $csc"
$cscArgs = @(
    "/nologo",
    "/target:exe"
)
if (Test-Path -LiteralPath $icoPath) {
    $cscArgs += "/win32icon:`"$icoPath`""
}
$cscArgs += "/resource:`"$scriptPath`",FindServerScript"
$cscArgs += "/out:`"$exeOutputPath`""
$cscArgs += "`"$stubSourcePath`""

$proc = Start-Process -FilePath $csc -ArgumentList $cscArgs -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "csc.exe compilation failed with exit code $($proc.ExitCode)"
}

Write-Host "Find-server exe built: $exeOutputPath"
Write-Host "Remember to commit it to git."
