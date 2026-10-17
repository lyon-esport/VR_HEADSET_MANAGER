# VR Headset Manager - web routes: eye_merge (S9-3).
#
# Route handlers for frame capture, eye merge (ADR-0025), stream mask and lens positions (ADR-0030).
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: POST /api/headset-screen-frame  body {"id":3,"transport":"Auto|USB|WiFi"}
# One full, uncropped scrcpy frame of a headset for the visual view editor
# (vrhm_config.html, Headset Profiles). Logic in Get-HeadsetScreenFrame (scrcpy_launcher.ps1).
# The PNG lands in website\generated\view_editor\, served at /view_editor/<file> by the
# generated\ fallback. Blocks this listener for a few seconds (scrcpy records ~3 s).
function Invoke-RouteHeadsetScreenFrame {
    # POST /api/headset-screen-frame
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw "Request body too large" }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
        $json   = $body | ConvertFrom-Json
        $frameId = 0
        if (-not [int]::TryParse([string]$json.id, [ref]$frameId) -or $frameId -le 0) { throw "INVALID_ID" }
        $frameHeadset = Get-HeadsetDiagTarget -Id $frameId
        if (-not $frameHeadset) { throw "UNKNOWN_HEADSET" }
        $frameTransport = if ($json.transport) { [string]$json.transport } else { 'Auto' }
        if (@('Auto','USB','WiFi') -notcontains $frameTransport) { $frameTransport = 'Auto' }
        $frame = Get-HeadsetScreenFrame -Headset $frameHeadset -Transport $frameTransport
        $frameUrl = if ($frame.Ok) { "/view_editor/{0}?t={1}" -f (Split-Path -Path $frame.Path -Leaf), [DateTime]::UtcNow.Ticks } else { $null }
        Send-JsonResponse -Response $response -Body @{
            ok = [bool]$frame.Ok; url = $frameUrl; width = $frame.Width; height = $frame.Height
            transport = $frame.Transport; model = [string]$frameHeadset.Model; name = [string]$frameHeadset.Name
            error = $frame.Error
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# ---- Eye merge (both lenses stitched into one view, ADR-0025). Logic in modules\eye_merge.ps1.
# GET /api/eye-merge?model=Quest%203 -> calibration status, merged crop of every view, export snippet.
function Invoke-RouteEyeMerge {
    # GET /api/eye-merge
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $emModel = [string]$request.QueryString['model']
        if (-not $emModel -or $emModel.Length -gt 100) { throw 'Missing or invalid model.' }
        # ?ipd=58 : the lens position the calibration / views are read at (models with an `ipd` block).
        $emIpd = [string]$request.QueryString['ipd']
        if ($emIpd -notmatch '^\d{1,3}$') { $emIpd = '' }
        $emProfile = Get-EyeMergeProfile -Model $emModel -IncludeDisabled -Ipd $emIpd
        # light=1: status only (headsets_settings.html). The per-view automatic framing costs
        # ~200 ms per view and the snippet is only needed by the Headset Profiles card.
        $emLight = ([string]$request.QueryString['light'] -eq '1')
        if ($emLight) {
            Send-JsonResponse -Response $response -Body @{
                ok = $true; model = $emModel
                calibrated = [bool]$emProfile
                enabled = [bool]($emProfile -and $emProfile.enabled -ne $false)
            }
            return
        }
        $emViews = @{}
        if ($emProfile -and $emProfile.enabled -ne $false -and $global:scrcpyParameters.$emModel.views) {
            foreach ($v in $global:scrcpyParameters.$emModel.views.PSObject.Properties) {
                $c = Get-EyeMergeViewCrop -Model $emModel -View $v.Name -MergeProfile $emProfile -Ipd $emIpd
                if ($c) { $emViews[$v.Name] = @{ crop = ("{0}:{1}:{2}:{3}" -f $c.W, $c.H, $c.X, $c.Y); auto = [bool]$c.Auto; depth = (Get-EyeMergeViewDepth -Model $emModel -View $v.Name -MergeProfile $emProfile -Ipd $emIpd); baseEye = (Get-EyeMergeViewBaseEye -Model $emModel -View $v.Name -MergeProfile $emProfile -Ipd $emIpd) } }
            }
        }
        $emIpdCfg = Get-ModelIpdConfig -Model $emModel
        $emIpdInfo = $null
        if ($emIpdCfg) {
            $emCalibrated = @{}
            foreach ($pos in @($emIpdCfg.positions | ForEach-Object { [string]$_ })) {
                $emCalibrated[$pos] = [bool]($pos -eq [string]$emIpdCfg.default -and $global:scrcpyParameters.$emModel.eye_merge) -or [bool]($global:scrcpyParameters.$emModel.eye_merge_ipd -and $global:scrcpyParameters.$emModel.eye_merge_ipd.$pos)
            }
            $emIpdInfo = @{ positions = @($emIpdCfg.positions | ForEach-Object { [string]$_ }); default = [string]$emIpdCfg.default; autoDetect = ($emIpdCfg.auto_detect -ne $false); selected = $(if ($emIpd) { $emIpd } else { [string]$emIpdCfg.default }); calibrated = $emCalibrated }
        }
        Send-JsonResponse -Response $response -Body @{
            ok = $true; model = $emModel
            ipd = $emIpdInfo
            calibrated = [bool]$emProfile
            enabled = [bool]($emProfile -and $emProfile.enabled -ne $false)
            depthSupported = [bool]($emProfile -and $null -ne $emProfile.lens_focal_px)
            profile = $emProfile
            views = $emViews
            snippet = $(if ($emProfile) { Export-EyeMergeProfile -Model $emModel } else { $null })
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# GET /api/stream-mask?id=3 -> {ok,mask,url,width,height,reason}. Transparency mask of the
# headset's current stream when its view has "transparent_corners" (any eye, Get-StreamMask).
# The [video].html pages apply url with CSS mask-image; mask=false means "show the video as is".
function Invoke-RouteStreamMask {
    # GET /api/stream-mask
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $smId = 0
        if (-not [int]::TryParse([string]$request.QueryString['id'], [ref]$smId) -or $smId -le 0) { throw 'Invalid or missing headset id.' }
        $smHeadset = @(Get-KnownHeadsetsCached) | Where-Object { [string]$_.ID -eq [string]$smId } | Select-Object -First 1
        if (-not $smHeadset) { throw 'This headset is not registered on this server.' }
        $sm = Get-StreamMask -Headset $smHeadset
        Send-JsonResponse -Response $response -Body @{
            ok = [bool]$sm.Ok; mask = [bool]$sm.Mask; url = $sm.Url; width = $sm.Width; height = $sm.Height
            reason = $sm.Reason; error = $sm.Error
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; mask = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/eye-merge/frame  body {"id":3,"transport":"Auto|USB|WiFi","depth":0.75,"baseEye":"R","reuse":false}
# Same as /api/headset-screen-frame but returns the flat MERGED canvas the view editor's
# Merged tab draws on, at merge depth "depth" (metres, 0/absent = far) with main eye
# "baseEye" (L/R, absent = the calibration's). Blocks this listener
# for a few seconds (scrcpy records ~3 s); "reuse":true re-renders the last frame (~1 s).
# POST /api/eye-merge/calibrate  body {"id":3,"transport":"Auto","save":true}
# Measures the calibration of the headset's model (~3 s capture + ~2 s compute).
function Invoke-RouteEyeMergeFrameOrCalibrate {
    # POST /api/eye-merge/frame, POST /api/eye-merge/calibrate
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw 'Request body too large' }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
        $json   = $body | ConvertFrom-Json
        $emId = 0
        if (-not [int]::TryParse([string]$json.id, [ref]$emId) -or $emId -le 0) { throw 'Invalid or missing headset id.' }
        $emHeadset = Get-HeadsetDiagTarget -Id $emId
        if (-not $emHeadset) { throw 'This headset is not registered on this server.' }
        $emTransport = if ($json.transport) { [string]$json.transport } else { 'Auto' }
        if (@('Auto','USB','WiFi') -notcontains $emTransport) { $emTransport = 'Auto' }
        if ($request.Url.LocalPath -eq '/api/eye-merge/frame') {
            $emDepth = 0.0
            if ($null -ne $json.depth) { [void][double]::TryParse([string]$json.depth, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$emDepth) }
            $emBase = ([string]$json.baseEye).ToUpperInvariant()
            if ($emBase -notin @('L','R')) { $emBase = '' }
            $emIpd = [string]$json.ipd
            if ($emIpd -notmatch '^\d{1,3}$') { $emIpd = '' }
            $frame = Get-HeadsetMergedFrame -Headset $emHeadset -Transport $emTransport -DepthM $emDepth -BaseEye $emBase -ReuseFrame:([bool]$json.reuse) -Ipd $emIpd
            $frameUrl = if ($frame.Ok) { "/view_editor/{0}?t={1}" -f (Split-Path -Path $frame.Path -Leaf), [DateTime]::UtcNow.Ticks } else { $null }
            Send-JsonResponse -Response $response -Body @{
                ok = [bool]$frame.Ok; url = $frameUrl; width = $frame.Width; height = $frame.Height
                transport = $frame.Transport; model = [string]$emHeadset.Model; name = [string]$emHeadset.Name
                error = $frame.Error
            }
        } else {
            $emIpd = [string]$json.ipd
            if ($emIpd -notmatch '^\d{1,3}$') { $emIpd = '' }
            $emThr = 0
            if ($null -ne $json.lensThreshold) { [void][int]::TryParse([string]$json.lensThreshold, [ref]$emThr); if ($emThr -lt 1 -or $emThr -gt 60) { $emThr = 0 } }
            $emFrames = 1
            if ($null -ne $json.frames) { [void][int]::TryParse([string]$json.frames, [ref]$emFrames); if ($emFrames -lt 1 -or $emFrames -gt 5) { $emFrames = 1 } }
            $cal = Invoke-EyeMergeCalibration -Headset $emHeadset -Transport $emTransport -Save:([bool]$json.save) -Ipd $emIpd -LensThreshold $emThr -Frames $emFrames
            $calUrl = if ($cal.PreviewPath) { "/eye_merge/{0}?t={1}" -f (Split-Path -Path $cal.PreviewPath -Leaf), [DateTime]::UtcNow.Ticks } else { $null }
            Send-JsonResponse -Response $response -Body @{
                ok = [bool]$cal.Ok; model = $cal.Model; score = $cal.Score; profile = $cal.Profile
                previewUrl = $calUrl; width = $cal.PreviewWidth; height = $cal.PreviewHeight
                saved = [bool]$cal.Saved; ipd = $cal.Ipd; error = $cal.Error
            }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# POST /api/eye-merge/import  body {"json":"<snippet>","model":"optional","includeCrops":true}
# POST /api/eye-merge/enable  body {"model":"Quest 3","enabled":false}
function Invoke-RouteEyeMergeImportOrEnable {
    # POST /api/eye-merge/import, POST /api/eye-merge/enable
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 262144) { throw 'Request body too large' }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 262144
        $json   = $body | ConvertFrom-Json
        if ($request.Url.LocalPath -eq '/api/eye-merge/import') {
            $emTarget = if ($json.model) { [string]$json.model } else { '' }
            $imp = Import-EyeMergeProfile -Json ([string]$json.json) -Model $emTarget -IncludeViewCrops:([bool]$json.includeCrops)
            Send-JsonResponse -Response $response -Body @{ ok = [bool]$imp.Ok; model = $imp.Model; cropsApplied = $imp.CropsApplied; error = $imp.Error }
        } else {
            $emModel = [string]$json.model
            if (-not $emModel) { throw 'Missing model.' }
            $done = Set-EyeMergeEnabled -Model $emModel -Enabled ([bool]$json.enabled)
            Send-JsonResponse -Response $response -Body @{ ok = [bool]$done; model = $emModel; enabled = [bool]$json.enabled; error = $(if ($done) { $null } else { 'No calibration for this model.' }) }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# ---- Lens position (IPD) of a headset, ADR-0030. Logic in headset_diag.ps1 (Get-HeadsetIpdInfo,
# Set-HeadsetIpd, Update-HeadsetIpd); the console counterpart is Show-SubMenu-HeadsetIpd.
# GET  /api/headset-ipd?id=3 -> {ok,supported,ipd,source,iadM,at,positions,default,autoDetect}
# POST /api/headset-ipd body {"id":3,"ipd":"58"|"auto","detect":false}
#   ipd = a configured position sets a MANUAL override (held until the lens is moved again);
#   ipd = "auto" (or detect:true) reads the headset's own lens log now and follows it.
function Invoke-RouteHeadsetIpd {
    # GET /api/headset-ipd, POST /api/headset-ipd
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $ipdId = 0; $ipdWant = ''; $ipdDetect = $false
        if ($request.HttpMethod -eq 'GET') {
            [void][int]::TryParse([string]$request.QueryString['id'], [ref]$ipdId)
        } else {
            if ($request.ContentLength64 -gt 4096) { throw 'Request body too large' }
            $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
            $json   = $body | ConvertFrom-Json
            [void][int]::TryParse([string]$json.id, [ref]$ipdId)
            $ipdWant = [string]$json.ipd
            $ipdDetect = ([bool]$json.detect) -or ($ipdWant -eq 'auto')
        }
        if ($ipdId -le 0) { throw 'Invalid or missing headset id.' }
        $ipdHeadset = Get-HeadsetDiagTarget -Id $ipdId
        if (-not $ipdHeadset) { throw 'This headset is not registered on this server.' }
        $ipdCfg = Get-ModelIpdConfig -Model ([string]$ipdHeadset.Model)
        if ($request.HttpMethod -eq 'POST' -and $ipdCfg) {
            $ipdDev = Resolve-HeadsetAdbDevice -Headset $ipdHeadset
            if ($ipdDetect) {
                if (-not $ipdDev) { throw 'The headset is not reachable over ADB.' }
                # "auto": drop a manual hold first so the log value is applied now.
                try { Remove-DbKeyValue -Key ("headset_ipd_{0}" -f $ipdId) } catch { }
                if ($script:HeadsetIpdMemo) { $script:HeadsetIpdMemo.Remove($ipdId) }
                $upd = Update-HeadsetIpd -Headset $ipdHeadset -Device $ipdDev
                if (-not $upd.Ipd) {
                    # The headset log no longer holds the lens event: measure the lens pictures instead.
                    $fromFrame = Find-HeadsetIpdFromFrame -Headset $ipdHeadset
                    if (-not $fromFrame.Ok) { throw ("No lens position in the headset log ({0}) and the frame check failed: {1}" -f $upd.Reason, $fromFrame.Error) }
                    [void](Set-HeadsetIpd -HeadsetId $ipdId -Ipd $fromFrame.Ipd -Source auto)
                }
            } else {
                if (@($ipdCfg.positions | ForEach-Object { [string]$_ }) -notcontains $ipdWant) { throw 'Unknown lens position.' }
                [void](Set-HeadsetIpd -HeadsetId $ipdId -Ipd $ipdWant -Source manual -Device $ipdDev)
            }
        }
        $info = Get-HeadsetIpdInfo -Headset $ipdHeadset
        Send-JsonResponse -Response $response -Body @{
            ok = $true; supported = [bool]$info.Supported; ipd = $info.Ipd; source = $info.Source; iadM = $info.IadM
            at = $info.At; positions = @($info.Positions); default = $info.Default; autoDetect = [bool]$info.AutoDetect
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}
