# VR Headset Manager - web routes: benchmark (S9-3).
#
# Route handlers for the stream benchmark (ADR-0026, ADR-0027, ADR-0028).
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# ---- Stream benchmark (stream_benchmark.ps1, ADR-0026) ----
# GET /api/benchmark/options?id=<n> - what can be benchmarked on that headset + timing constants.
# Config and registry only (no ADB, no GPU probe), so it is safe on this listener.
function Invoke-RouteBenchmarkOptions {
    # GET /api/benchmark/options
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $benchId = 0
        if (-not [int]::TryParse([string]$request.QueryString['id'], [ref]$benchId) -or $benchId -le 0) { throw "INVALID_ID" }
        $benchHeadset = Get-HeadsetDiagTarget -Id $benchId
        if (-not $benchHeadset) { throw "UNKNOWN_HEADSET" }
        $benchOpts = Get-StreamBenchmarkOptions -Headset $benchHeadset
        Send-JsonResponse -Response $response -Depth 10 -Body @{
            ok = $true
            headset = @{ id = $benchHeadset.ID; name = $benchHeadset.Name; model = $benchHeadset.Model }
            options = $benchOpts
            running = (Test-StreamBenchmarkActive)
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/plan {id, selection, measureSec} - the tests a selection expands to + the time estimate.
# Pure computation (config and registry), nothing is started.
function Invoke-RouteBenchmarkPlan {
    # POST /api/benchmark/plan
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 65536) { throw "BODY_TOO_LARGE" }
        $benchBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 65536) | ConvertFrom-Json } catch { $null }
        $benchId = 0
        if (-not $benchBody -or -not [int]::TryParse([string]$benchBody.id, [ref]$benchId) -or $benchId -le 0) { throw "INVALID_ID" }
        $benchHeadset = Get-HeadsetDiagTarget -Id $benchId
        if (-not $benchHeadset) { throw "UNKNOWN_HEADSET" }
        $benchMeasure = 20
        [void][int]::TryParse([string]$benchBody.measureSec, [ref]$benchMeasure)
        if (@(10, 20, 40) -notcontains $benchMeasure) { $benchMeasure = 20 }
        $benchRunning = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count
        $benchPlan = New-StreamBenchmarkPlan -Headset $benchHeadset -Selection $benchBody.selection -MeasureSec $benchMeasure -RunningStreams $benchRunning
        Send-JsonResponse -Response $response -Depth 10 -Body @{
            ok          = [bool]$benchPlan.Ok
            error       = $benchPlan.Error
            count       = $benchPlan.Count
            estimateSec = $benchPlan.EstimateSec
            fixedSec    = $benchPlan.FixedSec
            captures    = $benchPlan.Captures
            groups      = @($benchPlan.Groups)
            selection   = $benchPlan.Selection
            tests       = @($benchPlan.Tests)
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            'BODY_TOO_LARGE'  { 'Request too large.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/start {id, selection, measureSec} - one run at a time.
function Invoke-RouteBenchmarkStart {
    # POST /api/benchmark/start
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if (($script:benchmarkJob -and $script:benchmarkJob.State -in @('Running', 'NotStarted')) -or (Test-StreamBenchmarkActive)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; status = 'already_running'; error = 'A benchmark is already running.' }
            return
        }
        if ($script:benchmarkJob) {
            try { Remove-Job -Job $script:benchmarkJob -Force -ErrorAction SilentlyContinue } catch {}
            $script:benchmarkJob = $null
        }
        if ($request.ContentLength64 -gt 65536) { throw "BODY_TOO_LARGE" }
        $benchBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 65536) | ConvertFrom-Json } catch { $null }
        $benchId = 0
        if (-not $benchBody -or -not [int]::TryParse([string]$benchBody.id, [ref]$benchId) -or $benchId -le 0) { throw "INVALID_ID" }
        $benchHeadset = Get-HeadsetDiagTarget -Id $benchId
        if (-not $benchHeadset) { throw "UNKNOWN_HEADSET" }
        $benchMeasure = 20
        [void][int]::TryParse([string]$benchBody.measureSec, [ref]$benchMeasure)
        if (@(10, 20, 40) -notcontains $benchMeasure) { $benchMeasure = 20 }
        $benchRunning = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count
        $benchPlan = New-StreamBenchmarkPlan -Headset $benchHeadset -Selection $benchBody.selection -MeasureSec $benchMeasure -RunningStreams $benchRunning
        if (-not $benchPlan.Ok) { throw ("PLAN:" + $benchPlan.Error) }
        $benchTests = @($benchPlan.Tests)
        if ($benchTests.Count -eq 0) { throw "NO_TEST" }
        $benchEta = [int]$benchPlan.EstimateSec
        $cancelPath = Get-StreamBenchmarkCancelPath
        if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::WriteAllText($script:benchmarkProgFile, ('{{"status":"queued","etaSec":{0},"estimatedTotalSec":{0},"total":{1}}}' -f [int]$benchEta, $benchTests.Count))
        $benchTestsJson = ($benchTests | ConvertTo-Json -Depth 6 -Compress)
        if ($benchTests.Count -eq 1 -and $benchTestsJson -notmatch '^\[') { $benchTestsJson = '[' + $benchTestsJson + ']' }
        $script:benchmarkJob = Start-Job -ScriptBlock $benchmarkJobBlock -ArgumentList $ScriptPath, $ConfigFilePath, $benchId, $benchTestsJson, $benchMeasure
        Write-Log ("Web: stream benchmark started for {0} ({1} test(s), {2} s window)" -f $benchHeadset.Name, $benchTests.Count, $benchMeasure) -Level INFO
        Send-JsonResponse -Response $response -Body @{ ok = $true; status = 'started'; etaSec = [int]$benchEta; total = $benchTests.Count }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            '^PLAN:'          { [string]$benchPlan.Error }
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            'NO_TEST'         { 'No valid test selected.' }
            'BODY_TOO_LARGE'  { 'Request too large.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/parallel {ids:[int], settings:{...}, measureSec} - same settings on several
# headsets at once. Shares the single-flight slot with /start.
function Invoke-RouteBenchmarkParallel {
    # POST /api/benchmark/parallel
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if (($script:benchmarkJob -and $script:benchmarkJob.State -in @('Running', 'NotStarted')) -or (Test-StreamBenchmarkActive)) {
            Send-JsonResponse -Response $response -Body @{ ok = $false; status = 'already_running'; error = 'A benchmark is already running.' }
            return
        }
        if ($script:benchmarkJob) {
            try { Remove-Job -Job $script:benchmarkJob -Force -ErrorAction SilentlyContinue } catch {}
            $script:benchmarkJob = $null
        }
        if ($request.ContentLength64 -gt 8192) { throw "BODY_TOO_LARGE" }
        $parBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 8192) | ConvertFrom-Json } catch { $null }
        if (-not $parBody -or -not $parBody.settings -or $parBody.settings -isnot [System.Management.Automation.PSCustomObject]) { throw "INVALID_SETTINGS" }
        $parIds = @()
        foreach ($rawId in @($parBody.ids)) {
            $parId = 0
            if (-not [int]::TryParse([string]$rawId, [ref]$parId) -or $parId -le 0) { throw "INVALID_ID" }
            if ($parIds -notcontains $parId) { $parIds += $parId }
        }
        if ($parIds.Count -eq 0) { throw "INVALID_ID" }
        if ($parIds.Count -gt 32) { throw "TOO_MANY" }
        $parNames = @()
        foreach ($parId in $parIds) {
            $parHeadset = Get-HeadsetDiagTarget -Id $parId
            if (-not $parHeadset) { throw "UNKNOWN_HEADSET" }
            $parNames += $parHeadset.Name
        }
        $parMeasure = 20
        [void][int]::TryParse([string]$parBody.measureSec, [ref]$parMeasure)
        if (@(10, 20, 40) -notcontains $parMeasure) { $parMeasure = 20 }
        $cancelPath = Get-StreamBenchmarkCancelPath
        if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::WriteAllText($script:benchmarkProgFile, ('{{"status":"queued","kind":"parallel","total":{0}}}' -f $parIds.Count))
        $parSettingsJson = ($parBody.settings | ConvertTo-Json -Depth 5 -Compress)
        $script:benchmarkJob = Start-Job -ScriptBlock $benchmarkParallelJobBlock -ArgumentList $ScriptPath, $ConfigFilePath, ($parIds -join ','), $parSettingsJson, $parMeasure
        Write-Log ("Web: parallel stream check started on {0} headset(s) ({1}), {2} s window" -f $parIds.Count, ($parNames -join ', '), $parMeasure) -Level INFO
        Send-JsonResponse -Response $response -Body @{ ok = $true; status = 'started'; total = $parIds.Count }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'       { 'Invalid or missing headset id.' }
            'INVALID_SETTINGS' { 'Missing settings.' }
            'TOO_MANY'         { 'Too many headsets (maximum 32).' }
            'UNKNOWN_HEADSET'  { 'A headset is not registered on this server.' }
            'BODY_TOO_LARGE'   { 'Request too large.' }
            default            { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# GET /api/benchmark/parallel/result - the last stored parallel check, result=null when none.
function Invoke-RouteBenchmarkParallelResult {
    # GET /api/benchmark/parallel/result
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        Send-JsonResponse -Response $response -Depth 10 -Body @{ ok = $true; result = (Get-StreamBenchmarkParallelResult) }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# GET /api/benchmark/progress - the progress JSON as written by the run.
function Invoke-RouteBenchmarkProgress {
    # GET /api/benchmark/progress
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $raw = '{"status":"idle"}'
        $jobAlive = ($script:benchmarkJob -and $script:benchmarkJob.State -in @('Running', 'NotStarted'))
        # The run rewrites this file once a second (temp file + replace): a read can hit that moment.
        # Retry briefly, and while our job runs answer the last good reading rather than "idle" -
        # one "idle" made the page end the run, re-enable RUN and reload, then go busy again.
        $read = $null
        for ($try = 0; $try -lt 3 -and $null -eq $read; $try++) {
            if (Test-Path -LiteralPath $script:benchmarkProgFile) {
                try { $read = [System.IO.File]::ReadAllText($script:benchmarkProgFile, [System.Text.Encoding]::UTF8) } catch { $read = $null }
                if ($read -and -not $read.Trim()) { $read = $null }
            }
            if ($null -eq $read) { Start-Sleep -Milliseconds 40 }
        }
        if ($null -ne $read) { $script:benchmarkProgLast = $read }
        elseif ($jobAlive -and $script:benchmarkProgLast) { $read = $script:benchmarkProgLast }
        if ($null -ne $read) {
            $raw = $read
            if (-not $jobAlive -and -not (Test-StreamBenchmarkActive)) {
                # No run of ours and no pause flag: a running/queued file is a leftover.
                $parsed = try { $raw | ConvertFrom-Json } catch { $null }
                if (-not $parsed -or $parsed.status -in @('running', 'queued')) { $raw = '{"status":"idle"}' }
            }
        }
        # The server's clock at answer time: the file is rewritten only on phase changes and samples,
        # so the page must count "time left" from phaseEndsAt against THIS, not against the file's
        # updatedAt - that reset the countdown at every poll (10, 9, 10, 9 s left).
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $t = $raw.TrimStart()
        if ($t.StartsWith('{') -and $t.Length -gt 2) { $raw = '{"serverNow":' + $nowMs + ',' + $t.Substring(1) }
        Send-JsonResponse -Response $response -Raw $raw
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ status = 'error' }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/cancel - the run stops after its current step and restores the streams.
function Invoke-RouteBenchmarkCancel {
    # POST /api/benchmark/cancel
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        Send-JsonResponse -Response $response -Body @{ ok = [bool](Stop-StreamBenchmark) }
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500
    } finally { Close-HttpResponse -Response $response }
    return
}

# GET /api/benchmark/result[?model=<m>] - the accumulated result of that model (default: the last
# benchmarked one), result=null when none.
function Invoke-RouteBenchmarkResult {
    # GET /api/benchmark/result
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $benchModel = [string]$request.QueryString['model']
        if ($benchModel.Length -gt 100) { $benchModel = $benchModel.Substring(0, 100) }
        $benchRes = if ($benchModel) { Get-StreamBenchmarkResult -Model $benchModel } else { Get-StreamBenchmarkResult }
        Send-JsonResponse -Response $response -Depth 12 -Body @{ ok = $true; result = $benchRes }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# GET /api/benchmark/result.csv - the same run as a CSV attachment (one line per test and GPU).
function Invoke-RouteBenchmarkResultCsv {
    # GET /api/benchmark/result.csv
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $benchModel = [string]$request.QueryString['model']
        if ($benchModel.Length -gt 100) { $benchModel = $benchModel.Substring(0, 100) }
        $benchRes = if ($benchModel) { Get-StreamBenchmarkResult -Model $benchModel } else { Get-StreamBenchmarkResult }
        if (-not $benchRes) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'No benchmark result yet.' }
        } else {
            $csvBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-StreamBenchmarkCsv -Result $benchRes))
            $csvName = 'vrhm_benchmark_{0}_{1}.csv' -f ($env:COMPUTERNAME -replace '[^A-Za-z0-9_-]', ''), (Get-Date -Format 'yyyyMMdd_HHmm')
            $response.StatusCode      = 200
            $response.ContentType     = 'text/csv; charset=utf-8'
            $response.AddHeader('Content-Disposition', ('attachment; filename="{0}"' -f $csvName))
            $response.ContentLength64 = $csvBytes.Length
            $response.OutputStream.Write($csvBytes, 0, $csvBytes.Length)
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/clear {model} - forgets the accumulated result of one model.
function Invoke-RouteBenchmarkClear {
    # POST /api/benchmark/clear
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw "BODY_TOO_LARGE" }
        $benchBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 4096) | ConvertFrom-Json } catch { $null }
        $benchModel = if ($benchBody) { [string]$benchBody.model } else { '' }
        if ([string]::IsNullOrWhiteSpace($benchModel) -or $benchModel.Length -gt 100) { throw "INVALID_MODEL" }
        Send-JsonResponse -Response $response -Body @{ ok = [bool](Clear-StreamBenchmarkResult -Model $benchModel) }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_MODEL'   { 'Invalid or missing model.' }
            'BODY_TOO_LARGE'  { 'Request too large.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/recommend {model, headsets, settings, maxCpu, maxGpu} - capacity estimate and
# up to 3 proposals computed from the stored result. Pure computation, no ADB.
function Invoke-RouteBenchmarkRecommend {
    # POST /api/benchmark/recommend
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 16384) { throw "BODY_TOO_LARGE" }
        $benchBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 16384) | ConvertFrom-Json } catch { $null }
        if (-not $benchBody) { throw "INVALID_BODY" }
        $benchModel = [string]$benchBody.model
        if ($benchModel.Length -gt 100) { throw "INVALID_MODEL" }
        $benchRes = if ($benchModel) { Get-StreamBenchmarkResult -Model $benchModel } else { Get-StreamBenchmarkResult }
        $benchHeadsets = 1
        [void][int]::TryParse([string]$benchBody.headsets, [ref]$benchHeadsets)
        $benchHeadsets = [Math]::Max(1, [Math]::Min(64, $benchHeadsets))
        $benchMaxCpu = 0; [void][int]::TryParse([string]$benchBody.maxCpu, [ref]$benchMaxCpu)
        $benchMaxGpu = 0; [void][int]::TryParse([string]$benchBody.maxGpu, [ref]$benchMaxGpu)
        $benchRecArgs = @{ Result = $benchRes; Headsets = $benchHeadsets; MaxCpu = $benchMaxCpu; MaxGpu = $benchMaxGpu }
        if ($benchBody.settings) { $benchRecArgs.Settings = $benchBody.settings }
        Send-JsonResponse -Response $response -Depth 10 -Body @{ ok = $true; recommendation = (Get-StreamBenchmarkRecommendation @benchRecArgs) }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_BODY'    { 'Invalid request.' }
            'INVALID_MODEL'   { 'Invalid model.' }
            'BODY_TOO_LARGE'  { 'Request too large.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/benchmark/apply {model, settings, headsetIds:[int], preview} - writes a proposal into the
# profile of the chosen headsets (preview:true only lists what would change).
function Invoke-RouteBenchmarkApply {
    # POST /api/benchmark/apply
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw "BODY_TOO_LARGE" }
        $benchBody = try { (Read-RequestBody -Request $request -Response $response -MaxBytes 4096) | ConvertFrom-Json } catch { $null }
        if (-not $benchBody -or -not $benchBody.settings) { throw "INVALID_BODY" }
        $benchModel = [string]$benchBody.model
        if ([string]::IsNullOrWhiteSpace($benchModel) -or $benchModel.Length -gt 100) { throw "INVALID_MODEL" }
        # No headset ticked is allowed: the restream settings in config.json are still applied.
        $benchIds = [int[]]@(@($benchBody.headsetIds) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
        $benchPreview = [bool]$benchBody.preview
        $benchApply = Set-StreamBenchmarkRecommendation -Model $benchModel -Settings $benchBody.settings -HeadsetIds $benchIds -Preview:$benchPreview
        Send-JsonResponse -Response $response -Depth 6 -Body @{
            ok = [bool]$benchApply.Ok; changes = @($benchApply.Changes); error = $benchApply.Error; preview = $benchPreview
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_BODY'    { 'Invalid request.' }
            'INVALID_MODEL'   { 'Invalid or missing model.' }
            'BODY_TOO_LARGE'  { 'Request too large.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally { Close-HttpResponse -Response $response }
    return
}
