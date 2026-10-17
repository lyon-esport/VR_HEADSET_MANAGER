# VR Headset Manager - web routes: binaries (S9-3).
#
# Route handlers for ffmpeg / mediamtx / scrcpy version, update check, update and version switch.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: GET /api/ffmpeg-version - installed ffmpeg version (local, fast, no network call)
function Invoke-RouteFfmpegVersion {
    # GET /api/ffmpeg-version
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $installedVersion = Get-FfmpegVersion
        Send-JsonResponse -Response $response -Body @{ ok = $true; installedVersion = $installedVersion }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/ffmpeg-check-update - queries GitHub for the latest ffmpeg release
function Invoke-RouteFfmpegCheckUpdate {
    # POST /api/ffmpeg-check-update
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $installedVersion = Get-FfmpegVersion
        $latest = Get-LatestFfmpegVersion
        if (-not $latest) {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = "Could not reach GitHub to check the latest ffmpeg version." }
        } else {
            $updateAvailable = ($installedVersion -ne $latest.Version)
            Send-JsonResponse -Response $response -Body @{ ok = $true; installedVersion = $installedVersion; latestVersion = $latest.Version; updateAvailable = $updateAvailable }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/ffmpeg-update - downloads the latest ffmpeg build into a NEW versioned
# folder under sources\ffmpeg\ (previously installed versions are left on disk
# untouched), points config.ffmpeg.folder (+ templates\config\config.json, since this is
# a real update) at it. Does NOT restart mediamtx/scrcpy in-process - nothing running
# uses the new binary until the application is restarted. Synchronous: the download
# itself only takes a few seconds to ~1 minute, so no background job/progress-poll is
# needed.
function Invoke-RouteFfmpegUpdate {
    # POST /api/ffmpeg-update
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    $lock = $null
    try {
        $lock = Enter-VqaLock -TimeoutMs 3000
        if (-not $lock) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; pending = $true; error = "Another config change is in progress. Please retry shortly." }
            Close-HttpResponse -Response $response
            return
        }

        $result = Update-FfmpegBinary -SourcesFolder (Join-Path $ScriptPath "sources")
        if ($result.Success) {
            try {
                Set-FfmpegFolderConfig -RelativeFolder $result.Folder -UpdateTemplate:(Test-DevVersion)
            } catch {
                Write-Log ("ffmpeg-update: Set-FfmpegFolderConfig failed: " + $_.Exception.Message) -Level WARNING
                $result.Success = $false
                $result.Error = "Downloaded but failed to update config.json: " + $_.Exception.Message
            }
        }
        $devSync = $false
        if ($result.Success) { $devSync = (Sync-DevBinaryTracking -Binary ffmpeg -RelativeFolder $result.Folder).Dev }

        if ($result.Success) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; newVersion = $result.Version; folder = $result.Folder; requiresRestart = $true; devSync = $devSync }
        } else {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = $result.Error }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/ffmpeg-list-versions - lists all ffmpeg version folders present under
# sources\ffmpeg\ (old versions are never deleted by /api/ffmpeg-update, so more than
# one can coexist)
function Invoke-RouteFfmpegListVersions {
    # GET /api/ffmpeg-list-versions
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $versions = Get-FfmpegInstalledVersions | ForEach-Object {
            @{ version = $_.Version; folder = $_.RelativeFolder; active = $_.IsActive }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $true; versions = @($versions) }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/ffmpeg-switch-version - body {"folder":"ffmpeg\\ffmpeg-8.1.2"}
# Repoints config.ffmpeg.folder at an already-installed version folder (no download -
# the folder must already exist on disk, and templates\config\config.json is left
# untouched - a version switch is a rollback/per-instance choice, not a new baseline).
# Does NOT restart mediamtx/scrcpy in-process - the operator is told the change applies
# on next application restart.
function Invoke-RouteFfmpegSwitchVersion {
    # POST /api/ffmpeg-switch-version
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    $lock = $null
    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $body = $bodyRaw | ConvertFrom-Json

        $sourcesFolder = Join-Path $ScriptPath "sources"
        $ffmpegRoot    = Join-Path $sourcesFolder "ffmpeg"
        $requestedFolder = Join-Path $sourcesFolder ([string]$body.folder)
        $resolved = Test-RequestPath -Path $requestedFolder -Root $ffmpegRoot
        if (-not $resolved -or -not (Test-Path -LiteralPath (Join-Path $resolved "ffmpeg.exe"))) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = "Invalid or missing ffmpeg version folder." }
            Close-HttpResponse -Response $response
            return
        }
        $relFolder = Join-Path "ffmpeg" (Split-Path -Path $resolved -Leaf)

        $lock = Enter-VqaLock -TimeoutMs 3000
        if (-not $lock) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; pending = $true; error = "Another config change is in progress. Please retry shortly." }
            Close-HttpResponse -Response $response
            return
        }

        $switchOk = $true
        $switchError = $null
        try {
            Set-FfmpegFolderConfig -RelativeFolder $relFolder
        } catch {
            Write-Log ("ffmpeg-switch-version: Set-FfmpegFolderConfig failed: " + $_.Exception.Message) -Level WARNING
            $switchOk = $false
            $switchError = $_.Exception.Message
        }

        if ($switchOk) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; newVersion = (Get-FfmpegVersion); folder = $relFolder; requiresRestart = $true }
        } else {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = $switchError }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/mediamtx-version - installed mediamtx version (parsed from the
# active folder name, local/fast, no network call)
function Invoke-RouteMediamtxVersion {
    # GET /api/mediamtx-version
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $installedVersion = Get-MediaMtxVersion
        Send-JsonResponse -Response $response -Body @{ ok = $true; installedVersion = $installedVersion }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/mediamtx-check-update - queries GitHub for the latest mediamtx release
function Invoke-RouteMediamtxCheckUpdate {
    # POST /api/mediamtx-check-update
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $installedVersion = Get-MediaMtxVersion
        $latest = Get-LatestMediaMtxVersion
        if (-not $latest) {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = "Could not reach GitHub to check the latest mediamtx version." }
        } else {
            $updateAvailable = ($installedVersion -ne $latest.Version)
            Send-JsonResponse -Response $response -Body @{ ok = $true; installedVersion = $installedVersion; latestVersion = $latest.Version; updateAvailable = $updateAvailable }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/mediamtx-list-versions - lists all mediamtx version folders
# present under sources\MediaMTX\ (old versions are never deleted by
# /api/mediamtx-update, so more than one can coexist)
function Invoke-RouteMediamtxListVersions {
    # GET /api/mediamtx-list-versions
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $versions = Get-MediaMtxInstalledVersions | ForEach-Object {
            @{ version = $_.Version; folder = $_.RelativeFolder; active = $_.IsActive }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $true; versions = @($versions) }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/mediamtx-switch-version - body {"folder":"MediaMTX\\mediamtx_v1.19.2_windows_amd64"}
# Repoints config.mediamtx.folder at an already-installed version folder (no download -
# the folder must already exist on disk, and templates\config\config.json is left
# untouched - a version switch is a rollback/per-instance choice, not a new baseline).
# Does NOT restart mediamtx/scrcpy in-process - the operator is told the change applies
# on next application restart.
function Invoke-RouteMediamtxSwitchVersion {
    # POST /api/mediamtx-switch-version
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    $lock = $null
    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $body = $bodyRaw | ConvertFrom-Json

        $sourcesFolder = Join-Path $ScriptPath "sources"
        $mediamtxRoot  = Join-Path $sourcesFolder "MediaMTX"
        $requestedFolder = Join-Path $sourcesFolder ([string]$body.folder)
        $resolved = Test-RequestPath -Path $requestedFolder -Root $mediamtxRoot
        if (-not $resolved -or -not (Test-Path -LiteralPath (Join-Path $resolved "mediamtx.exe"))) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = "Invalid or missing mediamtx version folder." }
            Close-HttpResponse -Response $response
            return
        }
        $relFolder = Join-Path "MediaMTX" (Split-Path -Path $resolved -Leaf)

        $lock = Enter-VqaLock -TimeoutMs 3000
        if (-not $lock) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; pending = $true; error = "Another config change is in progress. Please retry shortly." }
            Close-HttpResponse -Response $response
            return
        }

        $switchOk = $true
        $switchError = $null
        try {
            Set-MediaMtxFolderConfig -RelativeFolder $relFolder
        } catch {
            Write-Log ("mediamtx-switch-version: Set-MediaMtxFolderConfig failed: " + $_.Exception.Message) -Level WARNING
            $switchOk = $false
            $switchError = $_.Exception.Message
        }

        if ($switchOk) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; newVersion = (Get-MediaMtxVersion); folder = $relFolder; requiresRestart = $true }
        } else {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = $switchError }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/mediamtx-update - downloads the latest mediamtx build into a NEW
# versioned folder under sources\MediaMTX\ (the previously installed version's folder +
# files are left on disk untouched), points config.json's mediamtx.folder (+
# templates\config\config.json, since this is a real update) at the new folder. Does NOT
# restart mediamtx/scrcpy in-process - nothing running uses the new binary until the
# application is restarted. Synchronous, same shape as /api/ffmpeg-update.
function Invoke-RouteMediamtxUpdate {
    # POST /api/mediamtx-update
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    $lock = $null
    try {
        $lock = Enter-VqaLock -TimeoutMs 3000
        if (-not $lock) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; pending = $true; error = "Another config change is in progress. Please retry shortly." }
            Close-HttpResponse -Response $response
            return
        }

        $result = Update-MediaMtxBinary -SourcesFolder (Join-Path $ScriptPath "sources")
        if ($result.Success) {
            try {
                Set-MediaMtxFolderConfig -RelativeFolder $result.Folder -UpdateTemplate:(Test-DevVersion)
            } catch {
                Write-Log ("mediamtx-update: Set-MediaMtxFolderConfig failed: " + $_.Exception.Message) -Level WARNING
                $result.Success = $false
                $result.Error = "Downloaded but failed to update config.json: " + $_.Exception.Message
            }
        }
        $devSync = $false
        if ($result.Success) { $devSync = (Sync-DevBinaryTracking -Binary mediamtx -RelativeFolder $result.Folder).Dev }

        if ($result.Success) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; newVersion = $result.Version; folder = $result.Folder; requiresRestart = $true; devSync = $devSync }
        } else {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = $result.Error }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/scrcpy-version - installed scrcpy version (parsed from the
# active folder name, local/fast, no network call)
function Invoke-RouteScrcpyVersion {
    # GET /api/scrcpy-version
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $installedVersion = Get-ScrcpyVersion
        Send-JsonResponse -Response $response -Body @{ ok = $true; installedVersion = $installedVersion }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/scrcpy-check-update - queries GitHub for the latest official
# scrcpy release (NOTE: this project ships a patched "no flickering" build -
# the official release is the only public source, so an update replaces it)
function Invoke-RouteScrcpyCheckUpdate {
    # POST /api/scrcpy-check-update
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $installedVersion = Get-ScrcpyVersion
        $latest = Get-LatestScrcpyVersion
        if (-not $latest) {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = "Could not reach GitHub to check the latest scrcpy version." }
        } else {
            $updateAvailable = ($installedVersion -ne $latest.Version)
            Send-JsonResponse -Response $response -Body @{ ok = $true; installedVersion = $installedVersion; latestVersion = $latest.Version; updateAvailable = $updateAvailable }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/scrcpy-list-versions - lists all scrcpy version folders
# present under sources\scrcpy\ (old versions are never deleted by
# /api/scrcpy-update, so more than one can coexist)
function Invoke-RouteScrcpyListVersions {
    # GET /api/scrcpy-list-versions
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $versions = Get-ScrcpyInstalledVersions | ForEach-Object {
            @{ version = $_.Version; folder = $_.RelativeFolder; active = $_.IsActive }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $true; versions = @($versions) }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/scrcpy-switch-version - body {"folder":"scrcpy\\scrcpy-win64-v4.1"}
# Repoints config.scrcpy.folder AND config.ADB.folder at an already-installed version
# folder (no download - the folder must already exist on disk, and
# templates\config\config.json is left untouched - a version switch is a
# rollback/per-instance choice, not a new baseline). Does NOT restart
# scrcpy/adb-server in-process - the operator is told the change applies on next
# application restart. mediamtx is untouched.
function Invoke-RouteScrcpySwitchVersion {
    # POST /api/scrcpy-switch-version
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    $lock = $null
    try {
        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $body = $bodyRaw | ConvertFrom-Json

        $sourcesFolder = Join-Path $ScriptPath "sources"
        $scrcpyRoot    = Join-Path $sourcesFolder "scrcpy"
        $requestedFolder = Join-Path $sourcesFolder ([string]$body.folder)
        $resolved = Test-RequestPath -Path $requestedFolder -Root $scrcpyRoot
        if (-not $resolved -or -not (Test-Path -LiteralPath (Join-Path $resolved "scrcpy.exe"))) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = "Invalid or missing scrcpy version folder." }
            Close-HttpResponse -Response $response
            return
        }
        $relFolder = Join-Path "scrcpy" (Split-Path -Path $resolved -Leaf)

        $lock = Enter-VqaLock -TimeoutMs 3000
        if (-not $lock) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; pending = $true; error = "Another config change is in progress. Please retry shortly." }
            Close-HttpResponse -Response $response
            return
        }

        $switchOk = $true
        $switchError = $null
        try {
            Set-ScrcpyAdbFolderConfig -RelativeFolder $relFolder
        } catch {
            Write-Log ("scrcpy-switch-version: Set-ScrcpyAdbFolderConfig failed: " + $_.Exception.Message) -Level WARNING
            $switchOk = $false
            $switchError = $_.Exception.Message
        }

        if ($switchOk) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; newVersion = (Get-ScrcpyVersion); folder = $relFolder; requiresRestart = $true }
        } else {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = $switchError }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/scrcpy-update - downloads the latest official scrcpy build (bundles
# adb.exe) into a NEW folder under sources\scrcpy\ (consolidating any legacy top-level
# scrcpy folder into sources\scrcpy\ too - moved, not deleted), points config.json's
# scrcpy.folder AND ADB.folder (+ templates\config\config.json, since this is a real
# update) at the new folder. Does NOT restart scrcpy/adb-server in-process - nothing
# running uses the new binaries until the application is restarted. mediamtx is
# untouched (scrcpy/adb are independent of it). Synchronous, same shape as
# /api/ffmpeg-update and /api/mediamtx-update.
function Invoke-RouteScrcpyUpdate {
    # POST /api/scrcpy-update
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    $lock = $null
    try {
        $lock = Enter-VqaLock -TimeoutMs 3000
        if (-not $lock) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; pending = $true; error = "Another config change is in progress. Please retry shortly." }
            Close-HttpResponse -Response $response
            return
        }

        $result = Update-ScrcpyBinary -SourcesFolder (Join-Path $ScriptPath "sources")
        if ($result.Success) {
            try {
                Set-ScrcpyAdbFolderConfig -RelativeFolder $result.Folder -UpdateTemplate:(Test-DevVersion)
            } catch {
                Write-Log ("scrcpy-update: Set-ScrcpyAdbFolderConfig failed: " + $_.Exception.Message) -Level WARNING
                $result.Success = $false
                $result.Error = "Downloaded but failed to update config.json: " + $_.Exception.Message
            }
        }
        $devSync = $false
        if ($result.Success) { $devSync = (Sync-DevBinaryTracking -Binary scrcpy -RelativeFolder $result.Folder).Dev }

        if ($result.Success) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; newVersion = $result.Version; folder = $result.Folder; requiresRestart = $true; devSync = $devSync }
        } else {
            Send-JsonResponse -Response $response -StatusCode 502 -Body @{ ok = $false; error = $result.Error }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
        Close-HttpResponse -Response $response
    }
    return
}
