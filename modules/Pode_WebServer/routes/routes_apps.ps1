# VR Headset Manager - web routes: apps (S9-3).
#
# Route handlers for headset apps: installed list, install/uninstall/update jobs, launch, favourites and the app catalogue.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: GET /api/favoriteapps?name=Q3_BLUE  - returns Meta Home + per-headset favorites as JSON
function Invoke-RouteFavoriteapps {
    # GET /api/favoriteapps
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawQuery  = $request.Url.Query.TrimStart('?')
        $nameParam = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
        $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        # favorites.list already joins the catalogue, so DisplayName and
        # LocalIconPath arrive resolved; the second pass over
        # known_apps.csv this used to do is gone.
        $favList = @()
        foreach ($r in @(Get-FavoriteApps -headsetName $safeName)) {
            if ($r.PackageName) {
                $favList += @{
                    package       = $r.PackageName
                    displayName   = $r.DisplayName
                    localIconPath = $r.LocalIconPath
                }
            }
        }
        $json = ConvertTo-Json @($favList) -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/installedapps?name=Q3_BLUE[&refresh=1][&resolveMissing=1][&includeSystem=1]
# Returns installed apps as JSON. Default: third-party only (cached). includeSystem=1: all apps (live).
function Invoke-RouteInstalledapps {
    # GET /api/installedapps
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawQuery       = $request.Url.Query.TrimStart('?')
        $nameParam      = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
        $refresh        = ($rawQuery -match '(?:^|&)refresh=1')
        $resolveMissing = ($rawQuery -match '(?:^|&)resolveMissing=1')
        $includeSystem  = ($rawQuery -match '(?:^|&)includeSystem=1')
        $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $metaHomePkg  = 'com.oculus.vrshell'

        # Load favorites
        $favPkgs = @(Get-FavoriteApps -headsetName $safeName | Select-Object -ExpandProperty PackageName)

        # Refresh cache from headset when requested (covers both includeSystem and default)
        if ($refresh) {
            $rows    = Get-KnownHeadsetsCached
            $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
            if (-not $headset) { throw "Headset not found" }
            $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
            if (-not $device) { throw "Could not connect to headset via ADB" }
            Update-InstalledAppsCache -Device $device -headsetName $headset.Name
        }

        # The cache read and the catalogue enrichment are one query now:
        # installed.list_joined does the join the two Import-Csv calls
        # here used to do by hand. "No cache yet" is an empty result
        # rather than a missing file.
        $cachedRows = @(Get-HeadsetInstalledAppsCached -headsetName $safeName)
        if ($cachedRows.Count -gt 0) {
            $appList = @($cachedRows | ForEach-Object {
                $pkg = $_.PackageName
                $dn  = if ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                $sz  = 0L
                if ($null -ne $_.SizeBytes) { [void][long]::TryParse([string]$_.SizeBytes, [ref]$sz) }
                @{ package = $pkg; displayName = $dn; localIconPath = $_.LocalIconPath; version = $_.Version; pendingVersion = $_.PendingVersion; storeVersion = $_.StoreVersion; sizeBytes = $sz; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = (ConvertTo-BoolField $_.ThirdParty) }
            } | Where-Object { $includeSystem -or $_.thirdParty } | Sort-Object { $_.displayName })
        } else {
            $appNamesLookup = Get-AppCatalogMap
            # Fallback: live ADB call (no cache yet)
            $rows    = Get-KnownHeadsetsCached
            $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
            if (-not $headset) { throw "Headset not found" }
            $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
            if (-not $device) { throw "Could not connect to headset via ADB" }
            $installedApps = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly:(-not $includeSystem) -adb $adbPath
            $appList = @($installedApps | ForEach-Object {
                $pkg   = $_.PackageName
                $entry = if ($appNamesLookup.ContainsKey($pkg)) { $appNamesLookup[$pkg] } else { $null }
                $dn    = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } elseif ($_.DisplayName -and $_.DisplayName -ne $pkg) { $_.DisplayName } else { $pkg }
                $icon  = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } elseif ($_.LocalIconPath) { $_.LocalIconPath } else { '' }
                @{ package = $pkg; displayName = $dn; localIconPath = $icon; version = $_.Version; pendingVersion = ''; storeVersion = ''; sizeBytes = 0L; favorite = ($favPkgs -contains $pkg -or $pkg -eq $metaHomePkg); thirdParty = [bool]$_.ThirdParty }
            } | Sort-Object { $_.displayName })
        }

        $json = ConvertTo-Json @($appList) -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('[]')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/uninstallapp  body: {"name":"Q3_BLUE","package":"com.beatgames.beatsaber"}
function Invoke-RouteUninstallapp {
    # POST /api/uninstallapp
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json     = $body | ConvertFrom-Json
        $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
        $safePkg  = [regex]::Match($json.package, '^[\w\.\-]+$').Value
        if (-not $safeName -or -not $safePkg) { throw "Invalid input" }

        $rows    = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
        if (-not $device) { throw "Could not connect to headset via ADB" }
        $ok = Uninstall-HeadsetApp -Device $device -PackageName $safePkg
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($ok) { '{"ok":true}' } else { '{"ok":false,"error":"Uninstall failed or app not found"}' }))
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errJson  = '{"ok":false,"error":' + ($_.Exception.Message | ConvertTo-Json) + '}'
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/update-app  body: {"name":"Q3_RED","package":"com.beatgames.beatsaber"}
function Invoke-RouteUpdateApp {
    # POST /api/update-app
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $parsed   = $body | ConvertFrom-Json
        $safeName = [regex]::Match(($parsed.name -replace ' ','_'), '^[\w\-]+$').Value
        $safePkg  = [regex]::Match($parsed.package, '^[\w\.\-]+$').Value
        if (-not $safeName -or -not $safePkg) { throw "Invalid parameters" }

        $rows    = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort
        if (-not $device) { throw "Could not connect to headset via ADB" }
        $ok = Start-HeadsetAppUpdate -Device $device -PackageName $safePkg -headsetName $headset.Name
        Send-JsonResponse -Response $response -Body @{ ok = $ok }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/install-progress?jobId=xxx
function Invoke-RouteInstallProgress {
    # GET /api/install-progress
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $jobId = [regex]::Match($request.Url.Query, '[?&]?jobId=([a-f0-9]+)').Groups[1].Value
        if (-not $jobId) { throw "Missing jobId" }
        $pFile = Get-JobFilePath -Name "vrm_install_$jobId.json"
        if (Test-Path -LiteralPath $pFile) {
            $raw = [System.IO.File]::ReadAllText($pFile)
            Send-JsonResponse -Response $response -Raw $raw
        } else {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = "Job not found" }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/install-cancel  body: {"jobId":"xxx"}
function Invoke-RouteInstallCancel {
    # POST /api/install-cancel
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json  = $body | ConvertFrom-Json
        $jobId = [regex]::Match([string]$json.jobId, '^[a-f0-9]+$').Value
        if (-not $jobId) { throw "Invalid jobId" }

        if ($script:installJobs.ContainsKey($jobId)) {
            $j = $script:installJobs[$jobId]
            try { Stop-Job  -Job $j -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
            $script:installJobs.Remove($jobId)
        }

        $pFile = Get-JobFilePath -Name "vrm_install_$jobId.json"
        if (Test-Path -LiteralPath $pFile) {
            try {
                $prog = [System.IO.File]::ReadAllText($pFile) | ConvertFrom-Json
                if ($prog.adbPid -and $prog.adbPid -gt 0) {
                    Stop-Process -Id $prog.adbPid -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            [System.IO.File]::WriteAllText($pFile, '{"step":"cancelled","pct":0,"file":"","error":"","adbPid":0}')
        }

        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/resolve-app-names
# Starts a background job that fetches app metadata from MetaMetadata (GitHub).
# Guard: returns {status:"already_running"} if a job is active.
# Returns {status:"no_internet"} when github.com is unreachable.
function Invoke-RouteResolveAppNames {
    # POST /api/resolve-app-names
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        # Guard: one job at a time
        if ($script:resolveJob -and $script:resolveJob.State -in @('Running', 'NotStarted')) {
            Send-JsonResponse -Response $response -Body @{ status = 'already_running' }
            return
        }
        # Clean up finished job
        if ($script:resolveJob) {
            try { Remove-Job -Job $script:resolveJob -Force -ErrorAction SilentlyContinue } catch {}
            $script:resolveJob = $null
        }
        # Internet check
        if (-not (Test-InternetConnectivity)) {
            Send-JsonResponse -Response $response -Body @{ status = 'no_internet' }
            return
        }
        # Start background job
        [System.IO.File]::WriteAllText($script:resolveProgFile, '{"status":"queued"}')
        $bodyRaw    = (Read-RequestBody -Request $request -Response $response -MaxBytes 65536)
        $bodyObj    = try { $bodyRaw | ConvertFrom-Json } catch { $null }
        $forceOnline = [bool]($bodyObj.forceOnline)
        $script:resolveJob = Start-Job -ScriptBlock $resolveJobBlock -ArgumentList $ScriptPath, $script:resolveProgFile, $ConfigFilePath, $forceOnline
        Send-JsonResponse -Response $response -Body @{ status = 'started' }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error'; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/resolve-progress
# Returns the current status of the background app name resolution job.
function Invoke-RouteResolveProgress {
    # GET /api/resolve-progress
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        if (-not $script:resolveJob -and -not (Test-Path -LiteralPath $script:resolveProgFile)) {
            Send-JsonResponse -Response $response -Body @{ status = 'idle' }
        } else {
            $raw = try { [System.IO.File]::ReadAllText($script:resolveProgFile) } catch { '{"status":"idle"}' }
            # No active job - only trust terminal statuses; stale running/queued -> idle
            if (-not $script:resolveJob) {
                $parsed = try { $raw | ConvertFrom-Json } catch { $null }
                if (-not $parsed -or $parsed.status -in @('running', 'queued')) { $raw = '{"status":"idle"}' }
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
            $response.StatusCode      = 200
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error' }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/update-app-versions
# Starts a background job that fetches LatestVersion from MetaMetadata for all packages in known_apps.csv.
# Returns {status:"started"|"already_running"|"no_internet"|"error"}.
function Invoke-RouteUpdateAppVersions {
    # POST /api/update-app-versions
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($script:updateVersionsJob -and $script:updateVersionsJob.State -in @('Running', 'NotStarted')) {
            Send-JsonResponse -Response $response -Body @{ status = 'already_running' }
            return
        }
        if ($script:updateVersionsJob) {
            try { Remove-Job -Job $script:updateVersionsJob -Force -ErrorAction SilentlyContinue } catch {}
            $script:updateVersionsJob = $null
        }
        if (-not (Test-InternetConnectivity)) {
            Send-JsonResponse -Response $response -Body @{ status = 'no_internet' }
            return
        }
        $bodyJson = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        try { $bodyObj = $bodyJson | ConvertFrom-Json } catch { $bodyObj = $null }
        $script:updateVersionsHeadsetName = if ($bodyObj -and $bodyObj.headsetName) { $bodyObj.headsetName } else { $null }
        [System.IO.File]::WriteAllText($script:updateVersionsProgFile, '{"status":"queued"}')
        $script:updateVersionsJob = Start-Job -ScriptBlock $updateVersionsJobBlock -ArgumentList $ScriptPath, $script:updateVersionsProgFile, $ConfigFilePath
        Send-JsonResponse -Response $response -Body @{ status = 'started' }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error'; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/update-app-versions-progress
# Returns current status of the background update-versions job from progress file.
function Invoke-RouteUpdateAppVersionsProgress {
    # GET /api/update-app-versions-progress
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        if (-not $script:updateVersionsJob -and -not (Test-Path -LiteralPath $script:updateVersionsProgFile)) {
            Send-JsonResponse -Response $response -Body @{ status = 'idle' }
        } else {
            # Clean up finished job
            if ($script:updateVersionsJob -and $script:updateVersionsJob.State -notin @('Running', 'NotStarted')) {
                try { Remove-Job -Job $script:updateVersionsJob -Force -ErrorAction SilentlyContinue } catch {}
                $script:updateVersionsJob = $null
            }
            $raw = try { [System.IO.File]::ReadAllText($script:updateVersionsProgFile) } catch { '{"status":"idle"}' }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
            $response.StatusCode      = 200
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error' }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/refresh-headset-apps-cache
# Calls Update-InstalledAppsCache for a given headset. Used after update-app-versions completes.
function Invoke-RouteRefreshHeadsetAppsCache {
    # POST /api/refresh-headset-apps-cache
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $bodyJson = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $bodyObj  = try { $bodyJson | ConvertFrom-Json } catch { $null }
        $hn = if ($bodyObj -and $bodyObj.headsetName) { [string]$bodyObj.headsetName } else { $null }
        if (-not $hn) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'headsetName required' }
            return
        }
        $headset = Get-KnownHeadsets | Where-Object { $_.Name -eq $hn } | Select-Object -First 1
        if (-not $headset) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'headset not found' }
            return
        }
        $device = try { Get-BestAdbDevice -headset $headset } catch { $null }
        if (-not $device) {
            $device = try { Get-AdbWifiDevice -headsetIP $headset.IPAddress } catch { $null }
        }
        if (-not $device) {
            Send-JsonResponse -Response $response -StatusCode 503 -Body @{ ok = $false; error = 'device not reachable' }
            return
        }
        Update-InstalledAppsCache -Device $device -headsetName $hn
        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/installapk
# Mode A (binary upload): Content-Type: application/octet-stream, headers X-Headset-Name + X-File-Name
# Mode B (overwrite confirm): JSON body {"name","tempId","overwrite":true}
# Mode C (local folder path): JSON body {"name","path"[,"overwrite":true]}
function Invoke-RouteInstallapk {
    # POST /api/installapk
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $contentType = $request.ContentType -replace ';.*','' | ForEach-Object { $_.Trim() }
        $transport   = $request.Headers['X-Transport']  # 'usb', 'wifi', or empty (auto)

        # Helper: resolve device by transport preference.
        #
        # USB is the DEFAULT when the cabled headset is the target one - this is
        # the one place USB bandwidth genuinely pays, because an OBB push is
        # multiple GB and WiFi ADB makes that painful. It used to require the
        # client to opt in with X-Transport: usb, and re-shelled "adb devices"
        # to check; the published snapshot already knows (ADR-0021).
        # X-Transport is still honoured as an explicit override in both
        # directions.
        $resolveDevice = {
            param($headset2)
            if ($transport -eq 'wifi') {
                return Get-AdbWifiDevice -headsetIP $headset2.IPAddress -AdbPort $adbPort -adb $adbPath
            }
            if ($headset2.SerialNumber) {
                $snap = Get-PublishedUsbSnapshot
                if ($snap -and $snap.SerialNumber -eq $headset2.SerialNumber) {
                    return [PSCustomObject]@{ DeviceId = $snap.DeviceId; ConnectionType = 'USB'; IP = $null; Port = $null }
                }
            }
            if ($transport -eq 'usb') {
                # Explicitly asked for USB but it is not the cabled headset - fall
                # through rather than silently installing over WiFi on a caller
                # that chose USB on purpose.
                return $null
            }
            return Get-BestAdbDevice -Headset $headset2 -AdbPort $adbPort -adb $adbPath
        }

        # Helper: start the install background job and respond with jobId
        $startJob = {
            param($deviceId2, $installPath2, $isFolder2, $obbPath2, $pkgName2, $cleanupApk2)
            $jobId    = [guid]::NewGuid().ToString('N')
            $pFile    = Get-JobFilePath -Name "vrm_install_$jobId.json"
            [System.IO.File]::WriteAllText($pFile, '{"step":"queued","pct":0,"file":"","error":"","adbPid":0}')
            $job = Start-Job -ScriptBlock $installJobBlock -ArgumentList $adbPath, $deviceId2, $installPath2, $isFolder2, $obbPath2, $pkgName2, $pFile, $cleanupApk2
            $script:installJobs[$jobId] = $job
            Send-JsonResponse -Response $response -Body @{ ok = $true; jobId = $jobId }
        }

        if ($contentType -eq 'application/octet-stream') {
            # Mode A: binary APK upload
            $safeNameRaw  = $request.Headers['X-Headset-Name']
            $safeFileName = [regex]::Match($request.Headers['X-File-Name'], '^[\w\.\-]+\.apk$').Value
            $safeName     = [regex]::Match(($safeNameRaw -replace ' ','_'), '^[\w\-]+$').Value
            if (-not $safeName -or -not $safeFileName) { throw "Invalid upload headers" }

            $rows    = Get-KnownHeadsets
            $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
            if (-not $headset) { throw "Headset not found" }
            $device = & $resolveDevice $headset
            if (-not $device) { throw "Could not connect to headset via ADB" }

            # Stream the body straight to a temp file (S6-2): never held in memory.
            # The cap is a constant (4 GB: an APK plus OBB-sized upload), enforced up
            # front on ContentLength64 and again while copying (a chunked body has
            # length -1). An over-cap upload leaves no partial file behind.
            $maxUploadBytes = 4GB
            if ($request.ContentLength64 -gt $maxUploadBytes) {
                Send-JsonResponse -Response $response -StatusCode 413 -Body @{ ok = $false; error = 'body too large' }
                return
            }
            $tempPath = Get-JobFilePath -Name "vrmapk_${safeName}_${safeFileName}"
            $received = [int64]0
            $tooBig   = $false
            $fs = [System.IO.FileStream]::new($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576)
            try {
                $buf = [byte[]]::new(1048576)
                $in  = $request.InputStream
                while (($read = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $received += $read
                    if ($received -gt $maxUploadBytes) { $tooBig = $true; break }
                    $fs.Write($buf, 0, $read)
                }
            } catch {
                $fs.Dispose(); $fs = $null
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                throw
            } finally {
                if ($fs) { $fs.Dispose() }
            }
            if ($tooBig) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                Send-JsonResponse -Response $response -StatusCode 413 -Body @{ ok = $false; error = 'body too large' }
                return
            }

            $pkgName     = [System.IO.Path]::GetFileNameWithoutExtension($safeFileName)
            $pmOut       = Invoke-AdbCmd -Device $device -Command "shell pm list packages $pkgName"
            $isInstalled = $pmOut -ne $false -and ($pmOut -match "package:$([regex]::Escape($pkgName))")
            if ($isInstalled) {
                $verLine = (Invoke-AdbCmd -Device $device -Command "shell dumpsys package $pkgName" | Select-String 'versionName') | Select-Object -First 1
                $curVer  = if ($verLine -match 'versionName=(\S+)') { $Matches[1] } else { '' }
                $tempId  = "vrmapk_${safeName}_${safeFileName}"
                Send-JsonResponse -Response $response -Body @{ ok = $false; alreadyInstalled = $true; package = $pkgName; installedVersion = $curVer; tempId = $tempId }
            } else {
                & $startJob $device.DeviceId $tempPath $false '' $pkgName $true
            }

        } else {
            # Mode B or C: JSON body
            $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
            $json     = $body | ConvertFrom-Json
            $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
            if (-not $safeName) { throw "Invalid headset name" }

            $rows    = Get-KnownHeadsets
            $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
            if (-not $headset) { throw "Headset not found" }
            $device = & $resolveDevice $headset
            if (-not $device) { throw "Could not connect to headset via ADB" }

            if ($json.tempId) {
                # Mode B: overwrite-confirmed APK (temp file already on disk)
                $safeTempId = [regex]::Match($json.tempId, '^vrmapk_[\w\-]+_[\w\.\-]+\.apk$').Value
                if (-not $safeTempId) { throw "Invalid tempId" }
                $tempPath = Get-JobFilePath -Name $safeTempId
                if (-not (Test-Path -LiteralPath $tempPath)) { throw "Temp file not found or expired" }
                $pkgName  = [System.IO.Path]::GetFileNameWithoutExtension(([System.IO.Path]::GetFileName($safeTempId) -replace '^vrmapk_[\w\-]+_',''))
                & $startJob $device.DeviceId $tempPath $false '' $pkgName $true

            } elseif ($json.path) {
                # Mode C: local folder/file path
                $rawPath = [string]$json.path
                if ($rawPath -match "`0" -or $rawPath.Trim() -eq '') { throw "Invalid path" }
                try { $safePath = [System.IO.Path]::GetFullPath($rawPath) } catch { throw "Invalid path" }
                if (-not $safePath) { throw "Invalid path" }
                $overwrite = [bool]$json.overwrite
                $isFolder  = Test-Path -LiteralPath $safePath -PathType Container

                # Find APK to determine package name
                $pkgName = if ($isFolder) {
                    $apks = @(Get-ChildItem -LiteralPath $safePath -Filter '*.apk' -File -ErrorAction SilentlyContinue)
                    if ($apks.Count -eq 0) { throw "No APK file found in folder" }
                    [System.IO.Path]::GetFileNameWithoutExtension($apks[0].Name)
                } else {
                    [System.IO.Path]::GetFileNameWithoutExtension($safePath)
                }

                # Pre-check: already installed?
                if (-not $overwrite) {
                    $allApps     = Get-HeadsetInstalledApps -Device $device -ThirdPartyOnly:$false -adb $adbPath
                    $isInstalled = [bool]($allApps | Where-Object { $_.PackageName -eq $pkgName })
                    if ($isInstalled) {
                        $verMatch = Invoke-AdbCmd -Device $device -Command "shell dumpsys package $pkgName" -adb $adbPath | Select-String 'versionName' | Select-Object -Last 1
                        $curVer   = if ($verMatch -and "$verMatch" -match 'versionName=(\S+)') { $Matches[1] } else { '' }
                        Send-JsonResponse -Response $response -Body @{ ok = $false; alreadyInstalled = $true; package = $pkgName; installedVersion = $curVer }
                        return  # finally will close response
                    }
                }

                $obbPath = if ($isFolder) { Join-Path $safePath $pkgName } else { '' }

                & $startJob $device.DeviceId $safePath $isFolder $obbPath $pkgName $false

            } else {
                throw "Missing tempId or path"
            }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/foregroundapp?name=Q3_BLUE  - returns the package + display name + icon of the running app
function Invoke-RouteForegroundapp {
    # GET /api/foregroundapp
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawQuery  = $request.Url.Query.TrimStart('?')
        $nameParam = if ($rawQuery -match '(?:^|&)name=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
        $safeName  = [regex]::Match(($nameParam -replace ' ','_'), '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $rows    = Get-KnownHeadsetsCached
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }

        $device  = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        $pkg     = if ($device) { Get-HeadsetForegroundApp -Device $device -adb $adbPath } else { $null }

        $result  = @{ package = ''; displayName = ''; localIconPath = '' }
        if ($pkg) {
            $result.package = $pkg
            # One row by primary key instead of scanning the whole
            # catalogue: this endpoint is polled per headset.
            $entry = @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = $pkg }) | Select-Object -First 1
            if ($entry) {
                if ($entry.DisplayName)   { $result.displayName   = $entry.DisplayName }
                if ($entry.LocalIconPath) { $result.localIconPath = $entry.LocalIconPath }
            }
            if (-not $result.displayName) { $result.displayName = $pkg }
        }
        $json      = $result | ConvertTo-Json -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('{"package":"","displayName":"","localIconPath":""}')
            $response.StatusCode = 200; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/launchapp  body: {"name":"Q3_BLUE","package":"com.beatgames.beatsaber"}
function Invoke-RouteLaunchapp {
    # POST /api/launchapp
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json     = $body | ConvertFrom-Json
        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        $safePkg  = [regex]::Match($json.package, '^[\w\.\-]+$').Value
        if (-not $safeName -or -not $safePkg) { throw "Invalid input" }

        $rows    = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        if (-not $device) { throw "Could not connect to headset via ADB" }
        $ok = Invoke-HeadsetApp -Device $device -PackageName $safePkg -adb $adbPath
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($ok) { '{"ok":true}' } else { '{"ok":false}' }))
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/togglefavorite  body: {"name":"Q3_BLUE","package":"com.pkg","displayName":"App","favorite":true}
function Invoke-RouteTogglefavorite {
    # POST /api/togglefavorite
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json     = $body | ConvertFrom-Json
        $safePkg  = [regex]::Match($json.package, '^[\w\.\-]+$').Value
        $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
        if (-not $safePkg -or -not $safeName) { throw "Invalid input" }
        $favRows = @(Get-FavoriteApps -headsetName $safeName)
        $addFav  = [string]$json.favorite -eq 'True' -or [string]$json.favorite -eq 'true'
        if ($addFav) {
            if (-not ($favRows | Where-Object { $_.PackageName -eq $safePkg })) {
                $favRows += [PSCustomObject]@{ PackageName = $safePkg; DisplayName = $json.displayName }
            }
        } else {
            $favRows = @($favRows | Where-Object { $_.PackageName -ne $safePkg })
        }
        Save-FavoriteApps -favorites $favRows -headsetName $safeName
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode      = 500
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# -- Known Apps Management API ---------------------------------------------

# API: GET /api/appnames  - returns the whole app catalogue as JSON.
# Note this endpoint is PascalCase while every other app endpoint is
# camelCase; known_apps_manager.html depends on that, so it is preserved.
function Invoke-RouteAppnames {
    # GET /api/appnames
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $appObjects = @(@(Invoke-DbQuery -Name 'catalog.list') |
            ForEach-Object {
                [PSCustomObject]@{
                    PackageName   = [string]$_.PackageName
                    DisplayName   = [string]$_.DisplayName
                    IconUrl       = [string]$_.IconUrl
                    LocalIconPath = [string]$_.LocalIconPath
                    ThirdParty    = ConvertTo-BoolField $_.ThirdParty
                }
            })
        $appsJson = $appObjects | ConvertTo-Json -Compress -Depth 2
        if ($appObjects.Count -eq 0) { $appsJson = '[]' }
        elseif ($appObjects.Count -eq 1) { $appsJson = '[' + $appsJson + ']' }
        $json = '{"apps":' + $appsJson + '}'
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('{"apps":[]}')
            $response.StatusCode = 200; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/appnames/save  - upsert a row (key = PackageName)
function Invoke-RouteAppnamesSave {
    # POST /api/appnames/save
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json   = $body | ConvertFrom-Json

        $pkg = ($json.PackageName -replace '[^\w\.\-]','').Trim()
        if (-not $pkg) { throw "Invalid PackageName" }

        # One row written, not the whole catalogue rewritten. LatestVersion
        # is preserved because the editor UI does not expose it and must
        # not clear what Update-AppCacheOnline resolved.
        $existing = @(Invoke-DbQuery -Name 'catalog.get' -Parameters @{ package_name = $pkg }) | Select-Object -First 1
        $latest   = if ($existing) { [string]$existing.LatestVersion } else { '' }
        Invoke-DbNonQuery -Name 'catalog.upsert' -Parameters @{
            package_name    = $pkg
            display_name    = [string]$json.DisplayName
            icon_url        = [string]$json.IconUrl
            local_icon_path = [string]$json.LocalIconPath
            third_party     = (ConvertTo-DbBool $json.ThirdParty)
            latest_version  = $latest
        } | Out-Null

        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/appnames/delete  - remove a row by PackageName
function Invoke-RouteAppnamesDelete {
    # POST /api/appnames/delete
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json   = $body | ConvertFrom-Json

        $pkg = ($json.PackageName -replace '[^\w\.\-]','').Trim()
        if (-not $pkg) { throw "Invalid PackageName" }

        # One DELETE. The old path rewrote every surviving row, and its
        # empty-catalogue branch wrote a header naming the long-retired
        # "Type" column - a schema the readers no longer understood.
        Invoke-DbNonQuery -Name 'catalog.delete' -Parameters @{ package_name = $pkg } | Out-Null

        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"server error"}')
            $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/appnames/clear  - empty the catalogue and re-seed from template
function Invoke-RouteAppnamesClear {
    # POST /api/appnames/clear
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $ok = Clear-AppNamesCache
        $clearBody = if ($ok) { [ordered]@{ ok = $true } } else { [ordered]@{ ok = $false; error = 'Clear failed - check server logs' } }
        Send-JsonResponse -Response $response -Body $clearBody
    } catch {
        try {
            Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $false; error = [string]$_ }) -StatusCode 500
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/defaultfavorites  - returns ordered rows from the default favorites template
function Invoke-RouteDefaultfavorites {
    # GET /api/defaultfavorites
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # The template stays a FILE - it is a shipped, operator-editable
        # seed, and /api/defaultfavorites/toggle and /reorder still write
        # it in place. Only the catalogue lookup moved to the database.
        $templatePath = Join-Path $ScriptPath "templates\data\default_favorite_apps.csv"
        $appNames     = Get-AppCatalogMap
        $result = @()
        if (Test-Path -LiteralPath $templatePath) {
            Import-Csv -LiteralPath $templatePath -Encoding UTF8 -Delimiter "," | ForEach-Object {
                if ($_.PackageName) {
                    $entry  = $appNames[$_.PackageName]
                    $result += @{
                        package       = $_.PackageName
                        displayName   = if ($entry -and $entry.DisplayName) { $entry.DisplayName } else { $_.DisplayName }
                        localIconPath = if ($entry -and $entry.LocalIconPath) { $entry.LocalIconPath } else { '' }
                    }
                }
            }
        }
        $json      = ConvertTo-Json @($result) -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('[]')
            $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/defaultfavorites/toggle  - add or remove a package from the default favorites template
function Invoke-RouteDefaultfavoritesToggle {
    # POST /api/defaultfavorites/toggle
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json
        $safePkg = [regex]::Match($json.package, '^[\w\.\-]+$').Value
        if (-not $safePkg) { throw "Invalid package" }
        $templatePath = Join-Path $ScriptPath "templates\data\default_favorite_apps.csv"
        $rows = @()
        if (Test-Path -LiteralPath $templatePath) {
            $rows = @(Import-Csv -LiteralPath $templatePath -Encoding UTF8 -Delimiter ",")
        }
        $addFav = [string]$json.favorite -eq 'True' -or [string]$json.favorite -eq 'true'
        if ($addFav) {
            if (-not ($rows | Where-Object { $_.PackageName -eq $safePkg })) {
                $rows += [PSCustomObject]@{ PackageName = $safePkg; DisplayName = [string]$json.displayName }
            }
        } else {
            $rows = @($rows | Where-Object { $_.PackageName -ne $safePkg })
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine('"PackageName","DisplayName"')
        foreach ($r in $rows) { $null = $sb.AppendLine('"' + ($r.PackageName -replace '"','""') + '","' + ($r.DisplayName -replace '"','""') + '"') }
        [System.IO.File]::WriteAllText($templatePath, $sb.ToString().TrimEnd(), $utf8NoBom)
        Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true })
    } catch {
        try {
            Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $false; error = [string]$_ }) -StatusCode 500
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/defaultfavorites/reorder  - reorder rows in the default favorites template
function Invoke-RouteDefaultfavoritesReorder {
    # POST /api/defaultfavorites/reorder
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json
        $templatePath = Join-Path $ScriptPath "templates\data\default_favorite_apps.csv"
        $rowMap = @{}
        if (Test-Path -LiteralPath $templatePath) {
            Import-Csv -LiteralPath $templatePath -Encoding UTF8 -Delimiter "," | ForEach-Object { if ($_.PackageName) { $rowMap[$_.PackageName] = $_ } }
        }
        $ordered = @()
        foreach ($pkg in $json.packages) {
            $safePkg = [regex]::Match($pkg, '^[\w\.\-]+$').Value
            if ($safePkg -and $rowMap.ContainsKey($safePkg)) { $ordered += $rowMap[$safePkg] }
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine('"PackageName","DisplayName"')
        foreach ($r in $ordered) { $null = $sb.AppendLine('"' + ($r.PackageName -replace '"','""') + '","' + ($r.DisplayName -replace '"','""') + '"') }
        [System.IO.File]::WriteAllText($templatePath, $sb.ToString().TrimEnd(), $utf8NoBom)
        Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true })
    } catch {
        try {
            Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $false; error = [string]$_ }) -StatusCode 500
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/favorites/reorder  - reorder per-headset favorites
function Invoke-RouteFavoritesReorder {
    # POST /api/favorites/reorder
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json     = $body | ConvertFrom-Json
        $safeName = [regex]::Match(($json.name -replace ' ','_'), '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid name" }
        $favMap = @{}
        @(Get-FavoriteApps -headsetName $safeName) | ForEach-Object { if ($_.PackageName) { $favMap[$_.PackageName] = $_ } }
        $ordered = @()
        foreach ($pkg in $json.packages) {
            $safePkg = [regex]::Match($pkg, '^[\w\.\-]+$').Value
            if ($safePkg -and $favMap.ContainsKey($safePkg)) { $ordered += $favMap[$safePkg] }
        }
        Save-FavoriteApps -favorites $ordered -headsetName $safeName
        Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $true })
    } catch {
        try {
            Send-JsonResponse -Response $response -Body ([ordered]@{ ok = $false; error = [string]$_ }) -StatusCode 500
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}
