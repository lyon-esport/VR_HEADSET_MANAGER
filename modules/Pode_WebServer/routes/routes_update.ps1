# VR Headset Manager - web routes: application self-update (spec S6).
#
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable in web_routes.ps1, owns
# $response.Close() and leaves with `return`, never `continue`. Lanes are decided in web_routes.ps1:
# check and dev-diff are slow; status, upload, apply, progress and cancel are FAST because the
# Start-Job handle ($script:appUpdateJob) is loop-bound. Backend: modules\vrhm_update.ps1.

# GET /api/app-update/status
function Invoke-RouteAppUpdateStatus {
    # GET /api/app-update/status
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $updInfo = Get-AppVersionInfo
        $updState = Get-AppUpdateState
        $updReport = $null
        try { $updReport = Get-DbKeyValue -Key 'update_import_report' } catch { $updReport = $null }
        $updKind = ''
        if ($updInfo.Parsed) { $updKind = [string]$updInfo.Parsed.Kind }
        Send-JsonResponse -Response $response -Depth 8 -Body @{
            ok           = $true
            version      = [string]$updInfo.Version
            kind         = $updKind
            devTree      = [bool]$updInfo.DevTree
            updatable    = [bool]$updInfo.Updatable
            commit       = [string]$updInfo.Commit
            state        = $updState
            importReport = $updReport
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/app-update/check {force}
function Invoke-RouteAppUpdateCheck {
    # POST /api/app-update/check
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $updBody = $null
        if ($request.ContentLength64 -ne 0) {
            $updBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 4096) | ConvertFrom-Json } catch { $null }
        }
        $updForce = ($updBody -and ([string]$updBody.force -in @('True', 'true', '1')))
        # Uploaded zips (tempIds from /api/app-update/upload) join the release list.
        $updZips = New-Object System.Collections.ArrayList
        if ($updBody -and $updBody.PSObject.Properties['tempIds']) {
            $updDir = Get-AppUpdateDataPath
            foreach ($tid in @($updBody.tempIds | ForEach-Object { $_ })) {
                if ([string]$tid -match '^[\w-]{1,64}$') {
                    $zp = Join-Path $updDir ('upload_{0}.zip' -f $tid)
                    if (Test-Path -LiteralPath $zp -PathType Leaf) { [void]$updZips.Add($zp) }
                }
            }
        }
        $updOpts = Get-AppUpdateOptions -Force:$updForce -ZipPaths @($updZips.ToArray())
        Send-JsonResponse -Response $response -Depth 10 -Body @{ ok = [bool]$updOpts.Ok; error = $updOpts.Error; options = $updOpts }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/app-update/import  body {path, items:[ids], check}
# Imports items from a previous installation folder into THIS install (same backend as console
# Config > Update > I: Import-PreviousInstall). check:true only validates the folder and returns its
# version. Slow lane: it reads another database and copies icons. Answers
# {ok, valid, version, error, report:{<item>:{ok,count,message}}}.
function Invoke-RouteAppUpdateImport {
    # POST /api/app-update/import
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $impBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 8192) | ConvertFrom-Json } catch { $null }
        $impPath = ''
        if ($impBody -and $impBody.path) { $impPath = ([string]$impBody.path).Trim().Trim('"').TrimEnd('\') }
        if (-not $impPath -or $impPath.Length -gt 400 -or -not [System.IO.Path]::IsPathRooted($impPath)) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; valid = $false; error = 'A full folder path is required.' }
            return
        }
        $isInstall = (Test-Path -LiteralPath (Join-Path $impPath 'config\config.json')) -or (Test-Path -LiteralPath (Join-Path $impPath 'data\vrhm.db'))
        if (-not $isInstall) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; valid = $false; error = ('Not a VR HEADSET MANAGER installation (no config\config.json and no data\vrhm.db): ' + $impPath) }
            return
        }
        if ([string]::Equals($impPath, ([string]$global:ScriptPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; valid = $false; error = 'This is the running installation itself.' }
            return
        }
        $impVer = ''
        try { $impVer = (Get-Content -LiteralPath (Join-Path $impPath 'version.txt') -Raw -Encoding UTF8 -ErrorAction Stop).Trim() } catch { }
        if ($impBody.PSObject.Properties['check'] -and [string]$impBody.check -in @('True', 'true', '1')) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; valid = $true; version = $impVer }
            return
        }
        $known = @('headsets', 'profiles', 'crops', 'recording', 'kiosks', 'apps', 'wifi')
        $impItems = @(@($impBody.items | ForEach-Object { [string]$_ }) | Where-Object { $known -contains $_ } | Select-Object -Unique)
        if ($impItems.Count -eq 0) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; valid = $true; error = 'Select at least one item to import.' }
            return
        }
        Write-Log ("Web: import from previous installation {0} ({1}), items: {2}" -f $impPath, $impVer, ($impItems -join ',')) -Level INFO
        $impRes = Import-PreviousInstall -Path $impPath -Items $impItems
        $impReport = $null
        if ($impRes -and $impRes.Report) { try { $impReport = ([string]$impRes.Report | ConvertFrom-Json).items } catch { } }
        Send-JsonResponse -Response $response -Depth 8 -Body @{ ok = [bool]($impRes -and $impRes.Ok); valid = $true; version = $impVer; error = $(if ($impRes) { $impRes.Error } else { 'no result' }); report = $impReport }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/app-update/dev-diff
function Invoke-RouteAppUpdateDevDiff {
    # POST /api/app-update/dev-diff
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        if (-not (Get-Command -Name Get-AppDevDiff -ErrorAction SilentlyContinue)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'not implemented' }
            return
        }
        $updDiff = Get-AppDevDiff
        Send-JsonResponse -Response $response -Depth 8 -Body @{ ok = [bool]$updDiff.Ok; diff = $updDiff }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/app-update/upload - raw zip body streamed to data\update\upload_<id>.zip (cap 2 GB).
function Invoke-RouteAppUpdateUpload {
    # POST /api/app-update/upload
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    $updPath = $null
    try {
        $updMax = 2GB
        if ($request.ContentLength64 -gt $updMax) {
            Send-JsonResponse -Response $response -StatusCode 413 -Body @{ ok = $false; error = 'body too large' }
            return
        }
        $updDir = Get-AppUpdateDataPath -Create
        $updId = [guid]::NewGuid().ToString('N')
        $updPath = Join-Path $updDir ("upload_{0}.zip" -f $updId)
        $updReceived = [int64]0
        $updTooBig = $false
        $updFs = [System.IO.FileStream]::new($updPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576)
        try {
            $updBuf = [byte[]]::new(1048576)
            $updIn = $request.InputStream
            while (($updRead = $updIn.Read($updBuf, 0, $updBuf.Length)) -gt 0) {
                $updReceived += $updRead
                if ($updReceived -gt $updMax) { $updTooBig = $true; break }
                $updFs.Write($updBuf, 0, $updRead)
            }
        } finally { $updFs.Dispose() }
        if ($updTooBig) {
            Remove-Item -LiteralPath $updPath -Force -ErrorAction SilentlyContinue
            Send-JsonResponse -Response $response -StatusCode 413 -Body @{ ok = $false; error = 'body too large' }
            return
        }
        $updManifest = Get-AppReleaseManifest -ZipPath $updPath
        if ($null -eq $updManifest) {
            Remove-Item -LiteralPath $updPath -Force -ErrorAction SilentlyContinue
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'This zip file has no release.json: it is not an update package.' }
            return
        }
        Write-Log ("Web: update package uploaded ({0} bytes), version {1}" -f $updReceived, $updManifest.version) -Level INFO
        Send-JsonResponse -Response $response -Depth 6 -Body @{ ok = $true; tempId = $updId; manifest = $updManifest }
    } catch {
        if ($updPath) { Remove-Item -LiteralPath $updPath -Force -ErrorAction SilentlyContinue }
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/app-update/apply {target, tempIds, importItems, confirm, force} - single-flight job.
function Invoke-RouteAppUpdateApply {
    # POST /api/app-update/apply
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($script:appUpdateJob -and $script:appUpdateJob.State -in @('Running', 'NotStarted')) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; status = 'already_running'; error = 'An update is already running.' }
            return
        }
        if ($request.ContentLength64 -gt 65536) { throw 'BODY_TOO_LARGE' }
        $updBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 65536) | ConvertFrom-Json } catch { $null }
        if (-not $updBody) { throw 'BAD_BODY' }
        if ([string]$updBody.confirm -notin @('True', 'true')) { throw 'NO_CONFIRM' }
        $updTarget = [string]$updBody.target
        if ($updTarget -ne 'dev' -and $updTarget -notmatch '^[\w.+-]{3,60}$') { throw 'BAD_TARGET' }
        $updTemp = New-Object System.Collections.ArrayList
        foreach ($t in @($updBody.tempIds)) { if ([string]$t -match '^[\w-]{1,64}$') { [void]$updTemp.Add([string]$t) } }
        $updItems = New-Object System.Collections.ArrayList
        foreach ($t in @($updBody.importItems)) { if ([string]$t -match '^\w{1,32}$') { [void]$updItems.Add([string]$t) } }
        $updForce = ([string]$updBody.force -in @('True', 'true'))
        if ($script:appUpdateJob) {
            try { Remove-Job -Job $script:appUpdateJob -Force -ErrorAction SilentlyContinue } catch {}
            $script:appUpdateJob = $null
        }
        $script:appUpdateRestarting = $false
        [System.IO.File]::WriteAllText($script:appUpdateProgFile, '{"status":"running","step":"resolve","percent":1,"message":"Starting","hops":[],"current":""}')
        $script:appUpdateJob = Start-Job -ScriptBlock $appUpdateJobBlock -ArgumentList $ScriptPath, $ConfigFilePath, $updTarget, ($updTemp.ToArray() -join ','), ($updItems.ToArray() -join ','), $updForce, $script:appUpdateProgFile
        Write-Log ("Web: application update started (target {0})" -f $updTarget) -Level INFO
        Send-JsonResponse -Response $response -Body @{ ok = $true; status = 'started' }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'BODY_TOO_LARGE' { 'Request body too large.' }
            'BAD_BODY'       { 'Invalid request body.' }
            'NO_CONFIRM'     { 'Confirmation required.' }
            'BAD_TARGET'     { 'Invalid target version.' }
            default          { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# GET /api/app-update/progress - the job's progress file; triggers the restart once when 'staged'.
function Invoke-RouteAppUpdateProgress {
    # GET /api/app-update/progress
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $raw = '{"status":"idle"}'
        $jobAlive = ($script:appUpdateJob -and $script:appUpdateJob.State -in @('Running', 'NotStarted'))
        $read = $null
        for ($try = 0; $try -lt 3 -and $null -eq $read; $try++) {
            if (Test-Path -LiteralPath $script:appUpdateProgFile) {
                try { $read = [System.IO.File]::ReadAllText($script:appUpdateProgFile, [System.Text.Encoding]::UTF8) } catch { $read = $null }
                if ($read -and -not $read.Trim()) { $read = $null }
            }
            if ($null -eq $read) { Start-Sleep -Milliseconds 40 }
        }
        if ($null -ne $read) {
            $raw = $read
            $parsed = try { $raw | ConvertFrom-Json } catch { $null }
            if (-not $parsed) { $raw = '{"status":"idle"}' }
            elseif ($parsed.status -eq 'running' -and -not $jobAlive) { $raw = '{"status":"idle"}' }
            elseif ($parsed.status -eq 'staged' -and -not $jobAlive -and -not $script:appUpdateRestarting) {
                # Staging finished: restart through the updater when the backend has it, else stay 'staged'.
                if (Get-Command -Name Invoke-AppUpdateRestart -ErrorAction SilentlyContinue) {
                    $script:appUpdateRestarting = $true
                    try {
                        $o = [ordered]@{ status = 'restarting'; step = 'restarting'; percent = 100; message = 'The application is restarting'; hops = @($parsed.hops); current = [string]$parsed.current }
                        $raw = ($o | ConvertTo-Json -Compress)
                        [System.IO.File]::WriteAllText($script:appUpdateProgFile, $raw)
                    } catch { }
                    Write-Log 'Web: application update staged, restarting' -Level INFO
                    try { Invoke-AppUpdateRestart | Out-Null } catch { Write-Log ("Web: update restart failed: " + $_.Exception.Message) -Level ERROR }
                }
            }
        }
        Send-JsonResponse -Response $response -Raw $raw
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error' }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/app-update/cancel - stops the staging job; refused once the restart started.
function Invoke-RouteAppUpdateCancel {
    # POST /api/app-update/cancel
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        if ($script:appUpdateRestarting) {
            Send-JsonResponse -Response $response -StatusCode 409 -Body @{ ok = $false; error = 'The restart has started: it cannot be cancelled.' }
            return
        }
        if ($script:appUpdateJob) {
            try { Stop-Job -Job $script:appUpdateJob -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job -Job $script:appUpdateJob -Force -ErrorAction SilentlyContinue } catch {}
            $script:appUpdateJob = $null
        }
        # A staged job that was never picked up by the updater is dropped with the cancel.
        $updJobFile = Join-Path (Get-AppUpdateDataPath) 'job.json'
        $updPending = Read-UpdateJsonFile -Path $updJobFile
        if ($updPending -and [string]$updPending.phase -eq 'staged') {
            Remove-Item -LiteralPath $updJobFile -Force -ErrorAction SilentlyContinue
        }
        [System.IO.File]::WriteAllText($script:appUpdateProgFile, '{"status":"idle"}')
        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}
