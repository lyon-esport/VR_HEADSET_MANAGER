###############################################################
# binary_updates.ps1
# Bundled binary versions: check / update / switch for ffmpeg, mediamtx
# and scrcpy, the config + template folder setters and the dev-tree
# tracking (.releaseinclude / .gitignore). Split out of utils.ps1 (S9-1).
# Auto-loaded by scripts_init.ps1.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################

# Returns the installed ffmpeg version string (e.g. "7.0.2"), or $null if the
# exe is missing or the output cannot be parsed. Runs "ffmpeg -version" and
# reads the first line ("ffmpeg version 7.0.2-full_build-www.gyan.dev ...").
function Get-FfmpegVersion {
    param([string]$FfmpegPath = $global:ffmpegFilePath)
    if (-not $FfmpegPath -or -not (Test-Path -LiteralPath $FfmpegPath)) { return $null }
    try {
        $out = & $FfmpegPath -version 2>&1
        $first = $out | Select-Object -First 1
        # Gyan builds report "ffmpeg version 9.0.1-essentials_build-www.gyan.dev ...".
        # Extract just the numeric version so it compares equal to the bare
        # X.Y.Z string Get-LatestFfmpegVersion parses from the release asset name.
        if ($first -match 'ffmpeg version\s+(\d+(?:\.\d+){1,2})') { return $Matches[1] }
        if ($first -match 'ffmpeg version\s+(\S+)') { return $Matches[1] }
        return $null
    } catch {
        return $null
    }
}

# Queries the GyanD/codexffmpeg GitHub releases API for the latest available
# build. Returns @{Version; DownloadUrl; AssetName} or $null on network/parse
# failure. Never called automatically (only on operator-triggered "check for
# update") to avoid hitting GitHub on every page load.
function Get-LatestFfmpegVersion {
    try {
        $apiUrl = "https://api.github.com/repos/GyanD/codexffmpeg/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*essentials_build-www.zip" } | Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        }
        if (-not $asset) { return $null }
        $version = $release.tag_name
        if ($asset.name -match '(\d+\.\d+(\.\d+)?)') { $version = $Matches[1] }
        return @{ Version = $version; DownloadUrl = $asset.browser_download_url; AssetName = $asset.name }
    } catch {
        return $null
    }
}

# Downloads and installs the latest ffmpeg build to a NEW versioned folder
# "<SourcesFolder>\ffmpeg\ffmpeg-<version>\ffmpeg.exe" - the previously installed version's
# folder is left untouched on disk (no in-place upgrade; config.ffmpeg.folder is what selects
# the active one), same convention as Update-MediaMtxBinary/Update-ScrcpyBinary.
# No-ops (Success=true) if that version's folder already exists.
# Shared implementation used by the first-run welcome wizard (Invoke-FfmpegDownload in
# welcome.ps1) and the web UI update endpoint - same GitHub release, same
# BITS-with-WebClient-fallback download, same zip extraction logic.
# Returns @{Success; Version; Folder (relative to SourcesFolder); Error}.
function Update-FfmpegBinary {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    try {
        $latest = Get-LatestFfmpegVersion
        if (-not $latest) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not query latest ffmpeg release from GitHub." }
        }
        $parentFolder = Join-Path $SourcesFolder "ffmpeg"
        $destFolder   = Join-Path $parentFolder ("ffmpeg-{0}" -f $latest.Version)
        $relFolder    = Join-Path "ffmpeg" (Split-Path -Path $destFolder -Leaf)
        $destExe      = Join-Path $destFolder "ffmpeg.exe"

        if (Test-Path -LiteralPath $destExe) {
            return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
        }

        $zipPath = Join-Path $env:TEMP "vrm_ffmpeg_download.zip"
        $bitsOk = $false
        try {
            $bits = Get-Service -Name BITS -ErrorAction Stop
            if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                Start-BitsTransfer -Source $latest.DownloadUrl -Destination $zipPath -Description "Downloading ffmpeg..." -ErrorAction Stop
                $bitsOk = $true
            }
        } catch { }
        if (-not $bitsOk) {
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
            $wc.DownloadFile($latest.DownloadUrl, $zipPath)
            $wc.Dispose()
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry = $zip.Entries | Where-Object { $_.FullName -like "*/bin/ffmpeg.exe" } | Select-Object -First 1
        if (-not $entry) {
            $zip.Dispose()
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not find bin\ffmpeg.exe in the downloaded archive." }
        }
        if (-not (Test-Path -LiteralPath $destFolder)) {
            New-Item -ItemType Directory -Path $destFolder | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destExe, $true)

        # Best-effort: the same gyan.dev zip normally also ships bin/ffprobe.exe.
        # Not every build variant includes it, so a miss here must not fail the
        # ffmpeg update itself - callers that need ffprobe (e.g. the non-regression
        # harness) tolerate its absence.
        try {
            $probeEntry = $zip.Entries | Where-Object { $_.FullName -like "*/bin/ffprobe.exe" } | Select-Object -First 1
            if ($probeEntry) {
                $destProbe = Join-Path $destFolder "ffprobe.exe"
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($probeEntry, $destProbe, $true)
            }
        } catch { }

        $zip.Dispose()
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath $destExe)) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Downloaded archive did not contain ffmpeg.exe." }
        }
        $newVersion = Get-FfmpegVersion -FfmpegPath $destExe
        return @{ Success = $true; Version = $newVersion; Folder = $relFolder; Error = $null }
    } catch {
        return @{ Success = $false; Version = $null; Folder = $null; Error = $_.Exception.Message }
    }
}

# Returns the installed mediamtx version string (e.g. "1.17.1"), or $null if
# unparsable. mediamtx binaries are shipped one-per-version-folder (no shared
# in-place upgrade), so the version is read from the folder name itself
# (e.g. "mediamtx_v1.17.1_windows_amd64") rather than by invoking the exe.
function Get-MediaMtxVersion {
    param([string]$MediaMtxFolder = $global:mediamtxFolder)
    if (-not $MediaMtxFolder) { return $null }
    $leaf = Split-Path -Path $MediaMtxFolder -Leaf
    if ($leaf -match 'v(\d+(?:\.\d+){1,2})') { return $Matches[1] }
    return $null
}

# Queries the bluenviron/mediamtx GitHub releases API for the latest available
# Windows amd64 build. Returns @{Version; DownloadUrl; AssetName} or $null on
# network/parse failure. Only called on operator-triggered "check for update".
function Get-LatestMediaMtxVersion {
    try {
        $apiUrl = "https://api.github.com/repos/bluenviron/mediamtx/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*windows_amd64.zip" } | Select-Object -First 1
        if (-not $asset) { return $null }
        $version = $release.tag_name -replace '^v', ''
        if ($asset.name -match 'v?(\d+(?:\.\d+){1,2})') { $version = $Matches[1] }
        return @{ Version = $version; DownloadUrl = $asset.browser_download_url; AssetName = $asset.name }
    } catch {
        return $null
    }
}

# Downloads and installs the latest mediamtx build to a NEW versioned folder
# "<SourcesFolder>\MediaMTX\mediamtx_v<version>_windows_amd64\" - the existing
# installed version's folder is left untouched on disk (mediamtx has no
# in-place upgrade; config.mediamtx.folder is what selects the active one).
# No-ops (returns Success=true) if that version's folder already exists.
# Returns @{Success; Version; Folder (relative to SourcesFolder); Error}.
function Update-MediaMtxBinary {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    try {
        $latest = Get-LatestMediaMtxVersion
        if (-not $latest) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not query latest mediamtx release from GitHub." }
        }
        $parentFolder = Join-Path $SourcesFolder "MediaMTX"
        $destFolder   = Join-Path $parentFolder ("mediamtx_v{0}_windows_amd64" -f $latest.Version)
        $relFolder    = Join-Path "MediaMTX" (Split-Path -Path $destFolder -Leaf)

        if (Test-Path -LiteralPath (Join-Path $destFolder "mediamtx.exe")) {
            return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
        }

        $zipPath = Join-Path $env:TEMP "vrm_mediamtx_download.zip"
        $bitsOk = $false
        try {
            $bits = Get-Service -Name BITS -ErrorAction Stop
            if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                Start-BitsTransfer -Source $latest.DownloadUrl -Destination $zipPath -Description "Downloading mediamtx..." -ErrorAction Stop
                $bitsOk = $true
            }
        } catch { }
        if (-not $bitsOk) {
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
            $wc.DownloadFile($latest.DownloadUrl, $zipPath)
            $wc.Dispose()
        }

        if (-not (Test-Path -LiteralPath $parentFolder)) {
            New-Item -ItemType Directory -Path $parentFolder | Out-Null
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # destFolder must not exist yet for ExtractToDirectory - guaranteed by the
        # early-return check above.
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destFolder)
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath (Join-Path $destFolder "mediamtx.exe"))) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Downloaded archive did not contain mediamtx.exe." }
        }
        return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
    } catch {
        return @{ Success = $false; Version = $null; Folder = $null; Error = $_.Exception.Message }
    }
}

# Enumerates all installed version folders of a bundled binary under
# "<SourcesFolder>\<ParentFolder>\" (Update-*Binary never deletes an old version folder on
# update, so multiple can coexist). Shared body for Get-MediaMtxInstalledVersions,
# Get-ScrcpyInstalledVersions and Get-FfmpegInstalledVersions - only the parent folder name,
# exe file name, and version regex differ between binaries.
# -VersionPattern must contain exactly one capture group for the version string (matched
# against the folder name). Returns [PSCustomObject[]] of @{Version; RelativeFolder; IsActive},
# sorted by version descending. Folders without a parsable version or without the expected exe
# are skipped.
function Get-InstalledBinaryVersions {
    param(
        [Parameter(Mandatory = $true)][string]$ParentFolder,
        [Parameter(Mandatory = $true)][string]$ExeName,
        [Parameter(Mandatory = $true)][string]$VersionPattern,
        [string]$ActiveFolder,
        [string]$SourcesFolder = (Join-Path $global:ScriptPath "sources")
    )
    $parentPath = Join-Path $SourcesFolder $ParentFolder
    if (-not (Test-Path -LiteralPath $parentPath)) { return @() }
    $results = @()
    Get-ChildItem -LiteralPath $parentPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Path -LiteralPath (Join-Path $_.FullName $ExeName))) { return }
        if ($_.Name -notmatch $VersionPattern) { return }
        $relFolder = Join-Path $ParentFolder $_.Name
        $isActive = $ActiveFolder -and ((Split-Path -Path $ActiveFolder -Leaf) -eq $_.Name)
        $results += [PSCustomObject]@{ Version = $Matches[1]; RelativeFolder = $relFolder; IsActive = [bool]$isActive }
    }
    return @($results | Sort-Object -Property { [version]$_.Version } -Descending)
}

# Enumerates all installed mediamtx version folders under "<SourcesFolder>\MediaMTX\".
# Thin wrapper over Get-InstalledBinaryVersions - see that function for details.
function Get-MediaMtxInstalledVersions {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    return Get-InstalledBinaryVersions -ParentFolder "MediaMTX" -ExeName "mediamtx.exe" `
        -VersionPattern 'v(\d+(?:\.\d+){1,2})' -ActiveFolder $global:mediamtxFolder -SourcesFolder $SourcesFolder
}

# Reads templates\config\config.json and sets one or more dotted-path values (e.g.
# @{ 'mediamtx.folder' = 'MediaMTX\mediamtx_v1.21.0_windows_amd64' }), writing back via
# Write-FileWithoutBom. Used to keep the fresh-install template pointed at the latest bundled
# binary version whenever a real update (not a rollback) is applied - see Set-BinaryFolderConfig.
# Missing intermediate objects along a dotted path are created. Throws on read/parse/write
# failure - callers should catch and log, since template sync is a nice-to-have and should never
# fail the underlying config.json write it accompanies.
function Set-ConfigTemplateFields {
    param([Parameter(Mandatory = $true)][hashtable]$Fields)
    $tplFile = Join-Path $global:ScriptPath "templates\config\config.json"
    $lock = Enter-VqaLock -TimeoutMs 5000
    try {
        $raw = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8
        $tpl = $raw | ConvertFrom-Json
        if ($null -eq $tpl) { throw "templates\config\config.json is empty or invalid" }
        foreach ($path in $Fields.Keys) {
            $parts = $path -split '\.'
            $node = $tpl
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if (-not $node.($parts[$i])) {
                    $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                $node = $node.($parts[$i])
            }
            $leaf = $parts[-1]
            if ($node.PSObject.Properties.Name -contains $leaf) {
                $node.$leaf = $Fields[$path]
            } else {
                $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $Fields[$path] -Force
            }
        }
        Write-ConfigJson -Object $tpl -Path $tplFile -Depth 20
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
    }
}

# Persists $RelativeFolder to every dotted config path in -ConfigPaths (e.g.
# @('mediamtx.folder'), or @('scrcpy.folder','ADB.folder') for scrcpy's bundled adb.exe) inside
# config.json, and re-runs Get-Config so the corresponding $global: binary path variables pick
# up the new binary immediately - same refresh pattern used by /api/config/save. Shared body for
# Set-MediaMtxFolderConfig, Set-ScrcpyAdbFolderConfig and Set-FfmpegFolderConfig.
# When -UpdateTemplate is passed, also mirrors the same paths into
# templates\config\config.json via Set-ConfigTemplateFields (used for real GitHub updates, so
# fresh installs default to the latest known-good version) - failures there are logged as
# WARNING and do not fail the call, since the live config.json write already succeeded.
# -UpdateTemplate is intentionally omitted for version-switch/rollback callers: rolling back to
# an older already-installed version is a per-instance choice, not a new baseline.
function Set-BinaryFolderConfig {
    param(
        [Parameter(Mandatory = $true)][string[]]$ConfigPaths,
        [Parameter(Mandatory = $true)][string]$RelativeFolder,
        [switch]$UpdateTemplate
    )
    $cfgFile = Join-Path $global:ScriptPath "config\config.json"
    # Read-modify-write under the config lock (re-entrant: the update endpoints already hold it).
    $lock = Enter-VqaLock -TimeoutMs 5000
    try {
        $cfg = Read-ConfigJson -ConfigFilePath $cfgFile -NonInteractive
        if ($null -eq $cfg) { throw "config\config.json could not be read" }
        foreach ($path in $ConfigPaths) {
            $parts = $path -split '\.'
            $node = $cfg
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if (-not $node.($parts[$i])) {
                    $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                $node = $node.($parts[$i])
            }
            $leaf = $parts[-1]
            if ($node.PSObject.Properties.Name -contains $leaf) {
                $node.$leaf = $RelativeFolder
            } else {
                $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $RelativeFolder -Force
            }
        }
        Write-ConfigJson -Object $cfg -Path $cfgFile -Depth 20
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
    }
    $null = Get-Config -ConfigFilePath $cfgFile

    # The active binary folder changed: drop the startup unblock marker (main.ps1) so the
    # next start runs Unblock-File over the new folder too.
    Remove-Item -LiteralPath (Join-Path $global:ScriptPath 'data\unblock.marker') -Force -ErrorAction SilentlyContinue

    if ($UpdateTemplate) {
        try {
            $fields = @{}
            foreach ($path in $ConfigPaths) { $fields[$path] = $RelativeFolder }
            Set-ConfigTemplateFields -Fields $fields
        } catch {
            Write-Log ("Set-BinaryFolderConfig: failed to sync templates\config\config.json: " + $_.Exception.Message) -Level WARNING
        }
    }
}

# Persists a new mediamtx.folder value to config.json (path relative to
# sources\, e.g. "MediaMTX\mediamtx_v1.18.0_windows_amd64") and re-runs
# Get-Config so $global:mediamtxFolder / $global:mediamtxFilePath pick up the
# new binary immediately - same refresh pattern used by /api/config/save.
# Thin wrapper over Set-BinaryFolderConfig - see that function for -UpdateTemplate details.
function Set-MediaMtxFolderConfig {
    param([Parameter(Mandatory = $true)][string]$RelativeFolder, [switch]$UpdateTemplate)
    Set-BinaryFolderConfig -ConfigPaths @('mediamtx.folder') -RelativeFolder $RelativeFolder -UpdateTemplate:$UpdateTemplate
}

# Returns the installed scrcpy version string (e.g. "3.3.4"), or $null if
# unparsable. Like mediamtx, scrcpy is shipped one folder per version, so the
# version is read from the folder name (e.g. "scrcpy-win64-v3.3.4_patchedNoFlickering")
# rather than by invoking the exe.
function Get-ScrcpyVersion {
    param([string]$ScrcpyFolder = $global:scrcpyFolder)
    if (-not $ScrcpyFolder) { return $null }
    $leaf = Split-Path -Path $ScrcpyFolder -Leaf
    if ($leaf -match 'v(\d+(?:\.\d+){1,2})') { return $Matches[1] }
    return $null
}

# Queries the official Genymobile/scrcpy GitHub releases API for the latest
# available Windows 64-bit build. Returns @{Version; DownloadUrl; AssetName}
# or $null on network/parse failure. Only called on operator-triggered
# "check for update". NOTE: this is the STOCK scrcpy build, not the
# "patchedNoFlickering" variant this project currently ships - there is no
# public source for that patch, so updating replaces it with the official build.
function Get-LatestScrcpyVersion {
    try {
        $apiUrl = "https://api.github.com/repos/Genymobile/scrcpy/releases/latest"
        $headers = @{ 'User-Agent' = 'VR-Headset-Manager' }
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        $asset = $release.assets | Where-Object { $_.name -like "*win64*.zip" } | Select-Object -First 1
        if (-not $asset) { return $null }
        $version = $release.tag_name -replace '^v', ''
        if ($asset.name -match 'v?(\d+(?:\.\d+){1,2})') { $version = $Matches[1] }
        return @{ Version = $version; DownloadUrl = $asset.browser_download_url; AssetName = $asset.name }
    } catch {
        return $null
    }
}

# Downloads and installs the latest scrcpy build (which also bundles adb.exe)
# to a NEW folder "<SourcesFolder>\scrcpy\scrcpy-win64-v<version>\". As part of
# consolidating all scrcpy installs under one root, the CURRENTLY active
# folder (config.scrcpy.folder, wherever it currently lives - e.g. a legacy
# top-level "sources\scrcpy-win64-v3.3.4_patchedNoFlickering\") is moved
# (not copied - content preserved, nothing deleted) into "<SourcesFolder>\scrcpy\"
# too, if it is not already there. Migration is best-effort and does not fail
# the update if it errors, since the newly downloaded version is already usable.
# Returns @{Success; Version; Folder (relative to SourcesFolder); Error}.
function Update-ScrcpyBinary {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    try {
        $latest = Get-LatestScrcpyVersion
        if (-not $latest) {
            return @{ Success = $false; Version = $null; Folder = $null; Error = "Could not query latest scrcpy release from GitHub." }
        }
        $parentFolder = Join-Path $SourcesFolder "scrcpy"
        $destFolder   = Join-Path $parentFolder ("scrcpy-win64-v{0}" -f $latest.Version)
        $relFolder    = Join-Path "scrcpy" (Split-Path -Path $destFolder -Leaf)

        if (-not (Test-Path -LiteralPath (Join-Path $destFolder "scrcpy.exe"))) {
            $zipPath = Join-Path $env:TEMP "vrm_scrcpy_download.zip"
            $bitsOk = $false
            try {
                $bits = Get-Service -Name BITS -ErrorAction Stop
                if ($bits.Status -eq 'Running' -or $bits.StartType -ne 'Disabled') {
                    Start-BitsTransfer -Source $latest.DownloadUrl -Destination $zipPath -Description "Downloading scrcpy..." -ErrorAction Stop
                    $bitsOk = $true
                }
            } catch { }
            if (-not $bitsOk) {
                $wc = [System.Net.WebClient]::new()
                $wc.Headers.Add('User-Agent', 'VR-Headset-Manager')
                $wc.DownloadFile($latest.DownloadUrl, $zipPath)
                $wc.Dispose()
            }

            if (-not (Test-Path -LiteralPath $parentFolder)) {
                New-Item -ItemType Directory -Path $parentFolder | Out-Null
            }
            if (Test-Path -LiteralPath $destFolder) {
                Remove-Item -LiteralPath $destFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destFolder)
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

            # Some releases (seen with v5.0.1) wrap everything in one top-level folder inside the
            # zip; flatten it so scrcpy.exe sits directly in $destFolder like every other version.
            if (-not (Test-Path -LiteralPath (Join-Path $destFolder "scrcpy.exe"))) {
                $inner = @(Get-ChildItem -LiteralPath $destFolder -Directory)
                if ($inner.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $inner[0].FullName "scrcpy.exe"))) {
                    foreach ($item in @(Get-ChildItem -LiteralPath $inner[0].FullName -Force)) {
                        Move-Item -LiteralPath $item.FullName -Destination $destFolder -Force
                    }
                    Remove-Item -LiteralPath $inner[0].FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not (Test-Path -LiteralPath (Join-Path $destFolder "scrcpy.exe"))) {
                return @{ Success = $false; Version = $null; Folder = $null; Error = "Downloaded archive did not contain scrcpy.exe." }
            }
        }

        # Consolidate: move the currently-active scrcpy folder into sources\scrcpy\
        # if it lives elsewhere (e.g. a legacy top-level install). Best-effort.
        try {
            $currentFolder = $global:scrcpyFolder
            if ($currentFolder -and (Test-Path -LiteralPath $currentFolder -PathType Container)) {
                $currentParent = Split-Path -Path $currentFolder -Parent
                if ($currentParent -ne $parentFolder) {
                    $leaf = Split-Path -Path $currentFolder -Leaf
                    $migratedPath = Join-Path $parentFolder $leaf
                    if (-not (Test-Path -LiteralPath $migratedPath)) {
                        if (-not (Test-Path -LiteralPath $parentFolder)) {
                            New-Item -ItemType Directory -Path $parentFolder | Out-Null
                        }
                        Move-Item -LiteralPath $currentFolder -Destination $migratedPath -Force
                    }
                }
            }
        } catch { }

        return @{ Success = $true; Version = $latest.Version; Folder = $relFolder; Error = $null }
    } catch {
        return @{ Success = $false; Version = $null; Folder = $null; Error = $_.Exception.Message }
    }
}

# Enumerates all installed scrcpy version folders under "<SourcesFolder>\scrcpy\".
# Thin wrapper over Get-InstalledBinaryVersions - see that function for details.
function Get-ScrcpyInstalledVersions {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    return Get-InstalledBinaryVersions -ParentFolder "scrcpy" -ExeName "scrcpy.exe" `
        -VersionPattern 'v(\d+(?:\.\d+){1,2})' -ActiveFolder $global:scrcpyFolder -SourcesFolder $SourcesFolder
}

# Persists a new folder value to BOTH config.scrcpy.folder and config.ADB.folder
# (the scrcpy release bundles adb.exe, so they always point at the same folder -
# see templates\config\config.json where both keys already share one value) and
# re-runs Get-Config so $global:scrcpyFolder/$global:scrcpyFilePath and
# $global:adbFolder/$global:adbPath all pick up the new binaries immediately.
# Thin wrapper over Set-BinaryFolderConfig - see that function for -UpdateTemplate details.
function Set-ScrcpyAdbFolderConfig {
    param([Parameter(Mandatory = $true)][string]$RelativeFolder, [switch]$UpdateTemplate)
    Set-BinaryFolderConfig -ConfigPaths @('scrcpy.folder', 'ADB.folder') -RelativeFolder $RelativeFolder -UpdateTemplate:$UpdateTemplate
}

# Enumerates all installed ffmpeg version folders under "<SourcesFolder>\ffmpeg\".
# Thin wrapper over Get-InstalledBinaryVersions - see that function for details.
function Get-FfmpegInstalledVersions {
    param([string]$SourcesFolder = (Join-Path $global:ScriptPath "sources"))
    return Get-InstalledBinaryVersions -ParentFolder "ffmpeg" -ExeName "ffmpeg.exe" `
        -VersionPattern 'ffmpeg-(\d+(?:\.\d+){1,2})' -ActiveFolder $global:ffmpegFolder -SourcesFolder $SourcesFolder
}

# Persists a new ffmpeg.folder value to config.json (path relative to sources\, e.g.
# "ffmpeg\ffmpeg-9.0.1") and re-runs Get-Config so $global:ffmpegFilePath picks up the new
# binary immediately. Thin wrapper over Set-BinaryFolderConfig - see that function for
# -UpdateTemplate details.
function Set-FfmpegFolderConfig {
    param([Parameter(Mandatory = $true)][string]$RelativeFolder, [switch]$UpdateTemplate)
    Set-BinaryFolderConfig -ConfigPaths @('ffmpeg.folder') -RelativeFolder $RelativeFolder -UpdateTemplate:$UpdateTemplate
}

# Returns $true when running from the development tree. version.txt holds the literal
# "DEVELOPPMENT-VERSION" there; a released build carries its real version number (the release
# zip substitutes a synthetic version.txt), and a missing file counts as "not dev".
# Used to gate dev-only housekeeping (template / .releaseinclude / .gitignore sync after a
# binary update) that must never run on a production install.
# Example: if (Test-DevVersion) { ... }
function Test-DevVersion {
    try {
        $versionFile = Join-Path $global:ScriptPath 'version.txt'
        if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { return $false }
        $raw = Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8
        return ($null -ne $raw -and $raw.Trim() -eq 'DEVELOPPMENT-VERSION')
    } catch {
        return $false
    }
}

# After a REAL binary update (not a rollback), keeps the dev tree's packaging files in step with
# the newly installed version. Dev version only - returns $false and touches nothing otherwise.
#   scripts\.releaseinclude : scrcpy / mediamtx -> the /sources/<parent>/<old>/ line is replaced by
#                             the new folder; ffmpeg is NOT shipped, so its line (and the comment
#                             block directly above it) is removed.
#   .gitignore              : scrcpy / mediamtx -> a managed block ignoring every version under
#                             sources\<parent>\ except the new one; ffmpeg -> nothing to do, the
#                             existing "/sources/ffmpeg*" rule already ignores any version.
# templates\config\config.json is handled by Set-BinaryFolderConfig -UpdateTemplate.
# Each file is handled independently; a failure is logged as WARNING and never throws, because
# the download and config.json write it follows already succeeded.
# Returns @{ Dev; ReleaseInclude; GitIgnore } (booleans: file was changed).
# Example: Sync-DevBinaryTracking -Binary scrcpy -RelativeFolder 'scrcpy\scrcpy-win64-v4.2'
function Sync-DevBinaryTracking {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('scrcpy', 'mediamtx', 'ffmpeg')][string]$Binary,
        [Parameter(Mandatory = $true)][string]$RelativeFolder
    )
    $out = @{ Dev = $false; ReleaseInclude = $false; GitIgnore = $false }
    if (-not (Test-DevVersion)) { return $out }
    $out.Dev = $true

    $spec = @{
        scrcpy   = @{ Parent = 'scrcpy';   InRelease = $true }
        mediamtx = @{ Parent = 'MediaMTX'; InRelease = $true }
        ffmpeg   = @{ Parent = 'ffmpeg';   InRelease = $false }
    }[$Binary]
    $leaf = Split-Path -Path $RelativeFolder -Leaf
    $parentEsc = [regex]::Escape($spec.Parent)

    # Splits text into lines (remembering the line ending and the trailing newline) so a file is
    # rewritten the way it was found.
    $readLines = {
        param($file)
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        $eol = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
        $hadTrailing = $raw.EndsWith("`n")
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($l in ($raw -split "\r?\n")) { $lines.Add($l) }
        if ($hadTrailing -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        return @{ Lines = $lines; Eol = $eol; Trailing = $hadTrailing }
    }
    $writeLines = {
        param($file, $doc)
        $text = ($doc.Lines -join $doc.Eol)
        if ($doc.Trailing) { $text += $doc.Eol }
        $text | Write-FileWithoutBom -Path $file
    }

    # --- scripts\.releaseinclude ---
    try {
        $file = Join-Path $global:ScriptPath 'scripts\.releaseinclude'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $doc = & $readLines $file
            $lines = $doc.Lines
            $before = $lines -join "`n"
            $pattern = '^\s*/sources/' + $parentEsc + '/'

            if ($spec.InRelease) {
                $newLine = "/sources/{0}/{1}/" -f $spec.Parent, $leaf
                $first = -1
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    if ($lines[$i] -imatch $pattern) {
                        if ($first -ge 0) { $lines.RemoveAt($first) }
                        $first = $i
                    }
                }
                if ($first -ge 0) {
                    $lines[$first] = $newLine
                } else {
                    $last = -1
                    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -imatch '^\s*/sources/') { $last = $i } }
                    if ($last -ge 0) { $lines.Insert($last + 1, $newLine) } else { $lines.Add($newLine) }
                }
            } else {
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    if ($lines[$i] -imatch $pattern) {
                        $lines.RemoveAt($i)
                        # drop the comment lines that sat directly above it
                        while ($i -gt 0 -and $lines[$i - 1] -match '^\s*#') { $lines.RemoveAt($i - 1); $i-- }
                    }
                }
            }
            if (($lines -join "`n") -ne $before) {
                & $writeLines $file $doc
                $out.ReleaseInclude = $true
                Write-Log ("Sync-DevBinaryTracking: updated scripts\.releaseinclude for {0} ({1})" -f $Binary, $leaf) -Level INFO
            }
        }
    } catch {
        Write-Log ("Sync-DevBinaryTracking: .releaseinclude not updated: " + $_.Exception.Message) -Level WARNING
    }

    # --- .gitignore (ffmpeg is already covered by "/sources/ffmpeg*") ---
    if ($spec.InRelease) {
        try {
            $file = Join-Path $global:ScriptPath '.gitignore'
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $doc = & $readLines $file
                $lines = $doc.Lines
                $before = $lines -join "`n"
                $begin = "# BEGIN vrhm-managed $Binary (Sync-DevBinaryTracking)"
                $end   = "# END vrhm-managed $Binary"
                $block = @(
                    $begin,
                    "# only the active version is tracked; older folders under sources are ignored",
                    ("/sources/{0}/*" -f $spec.Parent),
                    ("!/sources/{0}/{1}/" -f $spec.Parent, $leaf),
                    $end
                )
                $s = $lines.IndexOf($begin)
                $e = if ($s -ge 0) { $lines.IndexOf($end) } else { -1 }
                if ($s -ge 0 -and $e -gt $s) {
                    $lines.RemoveRange($s, $e - $s + 1)
                    $lines.InsertRange($s, [string[]]$block)
                } else {
                    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
                    $lines.AddRange([string[]]$block)
                    $doc.Trailing = $true
                }
                if (($lines -join "`n") -ne $before) {
                    & $writeLines $file $doc
                    $out.GitIgnore = $true
                    Write-Log ("Sync-DevBinaryTracking: updated .gitignore for {0} ({1})" -f $Binary, $leaf) -Level INFO
                }
            }
        } catch {
            Write-Log ("Sync-DevBinaryTracking: .gitignore not updated: " + $_.Exception.Message) -Level WARNING
        }
    }
    return $out
}
