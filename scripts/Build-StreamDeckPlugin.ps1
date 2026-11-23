<#
.SYNOPSIS
    Builds the VRHM Stream Deck plugin and packs it as a .streamDeckPlugin.
.DESCRIPTION
    Sources: StreamDeck\vrhm-plugin\ (TypeScript, manifest, property inspectors, template
    profiles). The build runs in a LOCAL work folder (default %LOCALAPPDATA%\VRHM\streamdeck-build)
    because the project lives on a Google Drive volume: node_modules (thousands of files) must
    not be synced. Needs Node.js + npm on the PATH and internet access for the first npm install.

    Steps: copy sources -> npm install (only when package.json changed) -> rollup build ->
    streamdeck validate + pack -> copy the package to
    website\headset-toolbox\VRHM-StreamDeck.streamDeckPlugin (committed, downloaded from the web UI,
    shipped in releases). package-lock.json is copied back next to the sources.

    -Link links the built plugin folder into Stream Deck (developer loop) and restarts it.
    -Deploy copies the built plugin over the INSTALLED copy and restarts it (no dialog, keys kept).
    -SkipPack builds only.
.EXAMPLE
    .\scripts\Build-StreamDeckPlugin.ps1
.EXAMPLE
    .\scripts\Build-StreamDeckPlugin.ps1 -Version 1.0.1.0 -Link
#>
param(
    [string]$Version = '',
    [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'VRHM\streamdeck-build'),
    [switch]$Link,
    [switch]$Deploy,
    [switch]$SkipPack
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$src     = Join-Path $root 'StreamDeck\vrhm-plugin'
$sdName  = 'com.lyonesport.vrhm.sdPlugin'
$outFile = Join-Path $root 'website\headset-toolbox\VRHM-StreamDeck.streamDeckPlugin'

# Call the .cmd shims, not npm.ps1 / npx.ps1: under ErrorActionPreference Stop the .ps1 shims turn
# the progress rollup and the Elgato CLI print on stderr into a terminating NativeCommandError.
$npm = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$npx = Get-Command npx.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $npm -or -not $npx) { throw 'npm.cmd / npx.cmd not found on the PATH (install Node.js).' }
$npm = $npm.Source
$npx = $npx.Source
if (-not [System.IO.Directory]::Exists($WorkDir)) { [void][System.IO.Directory]::CreateDirectory($WorkDir) }

# 1. sources -> work folder (node_modules kept)
foreach ($d in @('src', $sdName)) {
    $t = Join-Path $WorkDir $d
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
}
Copy-Item -LiteralPath (Join-Path $src 'src') -Destination (Join-Path $WorkDir 'src') -Recurse
Copy-Item -LiteralPath (Join-Path $src $sdName) -Destination (Join-Path $WorkDir $sdName) -Recurse
$binDir = Join-Path (Join-Path $WorkDir $sdName) 'bin'
if (Test-Path -LiteralPath $binDir) { Remove-Item -LiteralPath $binDir -Recurse -Force }
foreach ($f in @('rollup.config.mjs', 'tsconfig.json')) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $WorkDir $f) -Force
}
$pkgSrc  = Join-Path $src 'package.json'
$pkgWork = Join-Path $WorkDir 'package.json'
$lockSrc = Join-Path $src 'package-lock.json'
# Stamp written only after a successful install, so a failed install is retried next run.
$stamp = Join-Path $WorkDir '.vrhm-install.hash'
$pkgHash = (Get-FileHash -LiteralPath $pkgSrc).Hash
$needInstall = -not (Test-Path -LiteralPath (Join-Path $WorkDir 'node_modules')) -or
    -not (Test-Path -LiteralPath $stamp) -or
    ((Get-Content -LiteralPath $stamp -Raw -Encoding UTF8).Trim() -ne $pkgHash)
Copy-Item -LiteralPath $pkgSrc -Destination $pkgWork -Force
if (Test-Path -LiteralPath $lockSrc) { Copy-Item -LiteralPath $lockSrc -Destination (Join-Path $WorkDir 'package-lock.json') -Force }

Push-Location -LiteralPath $WorkDir
# Native tools write progress on stderr; failures are detected through $LASTEXITCODE below.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # 2. dependencies
    if ($needInstall) {
        Write-Host 'npm install...' -ForegroundColor Cyan
        & $npm install --no-audit --no-fund 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { throw "npm install failed ($LASTEXITCODE)" }
        Copy-Item -LiteralPath (Join-Path $WorkDir 'package-lock.json') -Destination $lockSrc -Force
        [System.IO.File]::WriteAllText($stamp, $pkgHash, (New-Object System.Text.UTF8Encoding($false)))
    }

    # 3. build
    Write-Host 'rollup build...' -ForegroundColor Cyan
    & $npm run build 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

    # 4. validate + pack
    if (-not $SkipPack) {
        $packArgs = @('streamdeck', 'pack', $sdName, '--force', '--output', $WorkDir, '--no-update-check')
        if ($Version) { $packArgs += @('--version', $Version) }
        Write-Host 'streamdeck pack...' -ForegroundColor Cyan
        & $npx @packArgs 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { throw "streamdeck pack failed ($LASTEXITCODE)" }
        $pkg = Join-Path $WorkDir 'com.lyonesport.vrhm.streamDeckPlugin'
        if (-not (Test-Path -LiteralPath $pkg)) { throw "package not found: $pkg" }
        $outDir = Split-Path -Parent $outFile
        if (-not [System.IO.Directory]::Exists($outDir)) { [void][System.IO.Directory]::CreateDirectory($outDir) }
        Copy-Item -LiteralPath $pkg -Destination $outFile -Force
        Write-Host "Package: $outFile" -ForegroundColor Green
    }

    # 5. developer loop
    if ($Link) {
        & $npx streamdeck link $sdName 2>&1 | ForEach-Object { "$_" }
        & $npx streamdeck restart com.lyonesport.vrhm 2>&1 | ForEach-Object { "$_" }
    }

    # 6. deploy over the installed copy (no Stream Deck dialog): copy the built folder into
    # %APPDATA%\Elgato\StreamDeck\Plugins\<uuid>.sdPlugin (its logs\ kept), then restart the plugin.
    if ($Deploy) {
        $installed = Join-Path $env:APPDATA ('Elgato\StreamDeck\Plugins\' + $sdName)
        if (-not (Test-Path -LiteralPath $installed)) {
            Write-Host "Not installed yet: open $outFile once, then use -Deploy." -ForegroundColor Yellow
        } else {
            $built = Join-Path $WorkDir $sdName
            foreach ($item in @(Get-ChildItem -LiteralPath $built)) {
                if ($item.Name -eq 'logs') { continue }
                $dest = Join-Path $installed $item.Name
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
            }
            Write-Host "Deployed to $installed" -ForegroundColor Green
            # `streamdeck restart` only restarts a LINKED (developer mode) plugin: for an installed one
            # it is accepted and ignored, and the old code keeps running. Stop the plugin process
            # instead; Stream Deck relaunches it from the folder just updated.
            $pattern = [regex]::Escape($installed)
            $old = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object { $_.CommandLine -match $pattern })
            foreach ($p in $old) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            $oldIds = @($old | ForEach-Object { $_.ProcessId })
            $new = $null
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $new -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
                $new = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" | Where-Object { $_.CommandLine -match $pattern -and $oldIds -notcontains $_.ProcessId } | Select-Object -First 1
            }
            if ($new) { Write-Host "Plugin relaunched (pid $($new.ProcessId))" -ForegroundColor Green }
            else { Write-Host 'Plugin did not relaunch within 30 s: quit and reopen the Stream Deck app.' -ForegroundColor Yellow }
        }
    }
} finally {
    Pop-Location
    $ErrorActionPreference = $prevEap
}
