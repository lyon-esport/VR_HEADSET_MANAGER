# VR Headset Manager - web routes: vqa (S9-3).
#
# Route handlers for video quality automation, computer monitoring and the load tier.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: GET /api/load-tier  - returns the current adaptive-monitoring tier so the
# browser can scale its own polling intervals (status, computer-stats) up under load.
# Tier and multiplier come from Get-LoadTier / Get-LoadMultiplier in utils.ps1; base
# values come from the live config-driven globals so the operator can re-tune in one place.
function Invoke-RouteLoadTier {
    # GET /api/load-tier
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $tier = try { Get-LoadTier } catch { 'idle' }
        $mult = try { Get-LoadMultiplier -Tier $tier } catch { 1 }
        $vrm  = if ($null -ne $global:VRMonitor_refresh_timer) { [int]$global:VRMonitor_refresh_timer } else { 5 }
        $cm   = if ($null -ne $global:ComputerMonitoring_refresh_timer_sec) { [int]$global:ComputerMonitoring_refresh_timer_sec } else { 60 }
        Send-JsonResponse -Response $response -Body @{
            ok       = $true
            loadTier = @{
                tier       = "$tier"
                multiplier = [int]$mult
                base       = @{ vrmonitor = $vrm; computer_monitoring = $cm }
            }
        }
    } catch {
        try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/vqa/status - returns whether Video Quality Automation is enabled and the 3 per-section
# auto-apply flags. The legacy enabled_vqo is included as a derived OR for any consumer that still reads it.
# Always available so the web UI can decide whether to render the VQA section, even when VQA is disabled.
function Invoke-RouteVqaStatus {
    # GET /api/vqa/status
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $derivedVqo = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
        Send-JsonResponse -Response $response -Body @{
            enabled              = [bool]$global:VQA_Enabled
            auto_apply_profiles  = [bool]$global:VQA_AutoApplyProfiles
            auto_apply_headsets  = [bool]$global:VQA_AutoApplyHeadsets
            auto_apply_mediamtx  = [bool]$global:VQA_AutoApplyMediaMtx
            enabled_vqo          = [bool]$derivedVqo
            cpu_max_threshold    = if ($global:VQA_Enabled) { [int]$global:VQA_CpuMaxThreshold }        else { $null }
            gpu_max_threshold    = if ($global:VQA_Enabled) { [int]$global:VQA_GpuMaxThreshold }        else { $null }
            cpu_mitigation       = if ($global:VQA_Enabled) { [int]$global:VQA_CpuMitigationThreshold } else { $null }
            gpu_mitigation       = if ($global:VQA_Enabled) { [int]$global:VQA_GpuMitigationThreshold } else { $null }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/vqa/apply  - Applies the latest VQR recommendation. Body: { scope, target }.
function Invoke-RouteVqaApply {
    # POST /api/vqa/apply
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if (-not $global:VQA_Enabled) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'VQA disabled' }
        } else {
            $bodyText = (Read-RequestBody -Request $request -Response $response -MaxBytes 65536)
            $body  = if ($bodyText) { try { $bodyText | ConvertFrom-Json } catch { $null } } else { $null }
            $scope = if ($body -and $body.scope)  { [string]$body.scope }  else { 'all' }
            $target= if ($body -and $body.target) { [string]$body.target } else { '' }
            $ok = Invoke-VqaApply -Scope $scope -Target $target
            Send-JsonResponse -Response $response -Body @{ ok = [bool]$ok }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/vqa/restore  - Reverts to operator baseline, skipping fields edited manually since apply.
function Invoke-RouteVqaRestore {
    # POST /api/vqa/restore
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        if (-not $global:VQA_Enabled) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'VQA disabled' }
        } else {
            $ok = Reset-VqaToOriginals
            Send-JsonResponse -Response $response -Body @{ ok = [bool]$ok }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/vqa/toggle-auto-apply
# Body: { section: "profiles" | "headsets" | "mediamtx", enabled: bool }
# Persists to config.json via Set-VqaAutoApply (which also arms the cooldown).
# Returns the full 3-section state + derived_vqo so the UI can paint all buttons at once.
function Invoke-RouteVqaToggleAutoApply {
    # POST /api/vqa/toggle-auto-apply
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if (-not $global:VQA_Enabled) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'VQA disabled' }
        } else {
            $bodyText = (Read-RequestBody -Request $request -Response $response -MaxBytes 65536)
            $body = if ($bodyText) { try { $bodyText | ConvertFrom-Json } catch { $null } } else { $null }
            $section = if ($body -and $body.section) { [string]$body.section } else { '' }
            if ($section -notin @('profiles','headsets','mediamtx')) {
                Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = "section must be 'profiles', 'headsets' or 'mediamtx'" }
            } else {
                $current = switch ($section) {
                    'profiles' { $global:VQA_AutoApplyProfiles }
                    'headsets' { $global:VQA_AutoApplyHeadsets }
                    'mediamtx' { $global:VQA_AutoApplyMediaMtx }
                }
                $newVal = if ($body -and $null -ne $body.enabled) { [bool]$body.enabled } else { -not [bool]$current }
                Set-VqaAutoApply -Section $section -Enabled $newVal | Out-Null
                $derivedVqo = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
                Send-JsonResponse -Response $response -Body @{
                    ok                  = $true
                    auto_apply_profiles = [bool]$global:VQA_AutoApplyProfiles
                    auto_apply_headsets = [bool]$global:VQA_AutoApplyHeadsets
                    auto_apply_mediamtx = [bool]$global:VQA_AutoApplyMediaMtx
                    derived_vqo         = [bool]$derivedVqo
                }
            }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/vqa/toggle-vqo  - DEPRECATED. The single master VQO flag has been
# replaced by 3 per-section flags. The header badge is now derived from those.
# Returns 410 Gone with a hint so old clients fail loudly.
function Invoke-RouteVqaToggleVqo {
    # POST /api/vqa/toggle-vqo
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        Send-JsonResponse -Response $response -StatusCode 410 -Body @{
            ok    = $false
            error = 'toggle-vqo is deprecated; use POST /api/vqa/toggle-auto-apply with { section, enabled }'
        }
    } catch { } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/computer-monitoring - the latest hardware snapshot.
# Replaces the pages reading data\computer_monitoring.json directly off
# disk; the body is the same object that file used to hold.
function Invoke-RouteComputerMonitoring {
    # GET /api/computer-monitoring
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # The stored JSON text is sent as is: parsing it only to serialise it
        # again was the whole cost of this poll.
        $snapshotRaw = $null
        try { $snapshotRaw = Get-DbKeyValueRaw -Key 'computer_monitoring' } catch { }
        if ($snapshotRaw) {
            Send-JsonResponse -Response $response -Raw $snapshotRaw
        } else {
            # 404, not an empty object: the page must be able to tell
            # "no snapshot yet" from "a snapshot with no CPU in it".
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'no snapshot yet' }
        }
    } catch {
        try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
    } finally {
        try { $response.Close() } catch {}
    }
    return
}

# API: GET /api/vqa/recommendation - the latest VQR recommendation.
# Replaces the pages reading data\vqa_recommendation.json directly.
function Invoke-RouteVqaRecommendation {
    # GET /api/vqa/recommendation
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $rec = $null
        try { $rec = Get-DbKeyValue -Key 'vqa_recommendation' } catch { }
        if ($rec) {
            Send-JsonResponse -Response $response -Body $rec
        } else {
            # 404 mirrors the old behaviour of the file simply not
            # existing before the first VQR cycle of a session.
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ ok = $false; error = 'no recommendation yet' }
        }
    } catch {
        try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
    } finally {
        try { $response.Close() } catch {}
    }
    return
}

# API: POST /api/computer-monitoring/force-refresh
# Creates a flag file read by the VRMonitor loop (separate process) to trigger an immediate refresh.
function Invoke-RouteComputerMonitoringForceRefresh {
    # POST /api/computer-monitoring/force-refresh
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $flagFile = Join-Path -Path $global:ScriptPath -ChildPath "data\computer_monitoring_forcerefresh.flag"
        [System.IO.File]::WriteAllText($flagFile, '')
        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}
