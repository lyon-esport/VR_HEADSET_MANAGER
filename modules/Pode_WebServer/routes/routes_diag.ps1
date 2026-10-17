# VR Headset Manager - web routes: diag (S9-3).
#
# Route handlers for the headset DIAG page (ADR-0023).
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: GET /api/headset-diag?id=3&section=firmware|health|wireless|usb|fleet|history|tls
# One DIAG page section for one headset (headset_diag.html). The page loads the sections
# SEQUENTIALLY: each ADB section is one combined adb shell call, and this listener is
# single-threaded, so a burst of parallel section requests would freeze every other page.
# All the logic is in modules\headset_diag.ps1 (Get-HeadsetDiagSection) - ADR-0023.
function Invoke-RouteHeadsetDiag {
    # GET /api/headset-diag
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $diagId = 0
        if (-not [int]::TryParse([string]$request.QueryString['id'], [ref]$diagId) -or $diagId -le 0) { throw "INVALID_ID" }
        $diagSection = [string]$request.QueryString['section']
        if (@('firmware','health','wireless','usb','fleet','history','tls') -notcontains $diagSection) { throw "INVALID_SECTION" }
        $diagHeadset = Get-HeadsetDiagTarget -Id $diagId
        if (-not $diagHeadset) { throw "UNKNOWN_HEADSET" }
        $diagTransport = [string]$request.QueryString['transport']
        if (@('Auto','USB','WiFi') -notcontains $diagTransport) { $diagTransport = 'Auto' }
        $diagResult = Get-HeadsetDiagSection -Headset $diagHeadset -Section $diagSection -Transport $diagTransport
        Send-JsonResponse -Response $response -Depth 8 -Body @{
            ok = [bool]$diagResult.ok; section = $diagResult.section; transport = $diagResult.transport
            error = $diagResult.error; data = $diagResult.data
            headset = @{ id = $diagHeadset.ID; name = $diagHeadset.Name; model = $diagHeadset.Model; brand = $diagHeadset.Brand; ip = $diagHeadset.IPAddress; serial = $diagHeadset.SerialNumber }
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'INVALID_SECTION' { 'Unknown DIAG section.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = $errMsg }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/headset-diag/action  body {"id":3,"action":"sync_clock","args":{...}}
# One dispatcher over a CLOSED list of actions (Invoke-HeadsetDiagActionByName refuses
# any other name). Same LAN-trust posture as the rest of the app (ADR-0014).
function Invoke-RouteHeadsetDiagAction {
    # POST /api/headset-diag/action
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 8192) { throw "Request body too large" }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 8192
        $json   = $body | ConvertFrom-Json
        $diagId = 0
        if (-not [int]::TryParse([string]$json.id, [ref]$diagId) -or $diagId -le 0) { throw "INVALID_ID" }
        $diagAction = ([string]$json.action).Trim()
        if (-not $diagAction -or $diagAction.Length -gt 40) { throw "INVALID_ACTION" }
        $diagHeadset = Get-HeadsetDiagTarget -Id $diagId
        if (-not $diagHeadset) { throw "UNKNOWN_HEADSET" }
        $diagTransport = if ($json.transport) { [string]$json.transport } else { 'Auto' }
        if (@('Auto','USB','WiFi') -notcontains $diagTransport) { $diagTransport = 'Auto' }
        $diagResult = Invoke-HeadsetDiagActionByName -Headset $diagHeadset -Action $diagAction -Arguments $json.args -Transport $diagTransport
        Send-JsonResponse -Response $response -Depth 8 -Body @{
            ok = [bool]$diagResult.ok; action = $diagResult.action; transport = $diagResult.transport
            message = $diagResult.message; result = $diagResult.result
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'INVALID_ACTION'  { 'Invalid or missing action.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; message = $errMsg }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/headset-diag/command  body {"id":3,"command":"getprop ro.product.model"}
# The custom ADB shell panel: free text or a preset, shell only, refused when it matches
# the deny list, 20 s timeout, 64 KB output cap, every run logged. Goes through the same
# dispatcher as the other actions (action 'command').
function Invoke-RouteHeadsetDiagCommand {
    # POST /api/headset-diag/command
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 8192) { throw "Request body too large" }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 8192
        $json   = $body | ConvertFrom-Json
        $diagId = 0
        if (-not [int]::TryParse([string]$json.id, [ref]$diagId) -or $diagId -le 0) { throw "INVALID_ID" }
        $diagCommand = ([string]$json.command).Trim()
        if (-not $diagCommand) { throw "INVALID_COMMAND" }
        $diagHeadset = Get-HeadsetDiagTarget -Id $diagId
        if (-not $diagHeadset) { throw "UNKNOWN_HEADSET" }
        $diagTransport = if ($json.transport) { [string]$json.transport } else { 'Auto' }
        if (@('Auto','USB','WiFi') -notcontains $diagTransport) { $diagTransport = 'Auto' }
        $diagResult = Invoke-HeadsetDiagActionByName -Headset $diagHeadset -Action 'command' -Arguments @{ command = $diagCommand } -Transport $diagTransport
        $cmdOut = if ($diagResult.result) { $diagResult.result } else { $null }
        Send-JsonResponse -Response $response -Depth 8 -Body @{
            ok = [bool]$diagResult.ok; transport = $diagResult.transport; message = $diagResult.message
            output    = $(if ($cmdOut) { $cmdOut.Output } else { '' })
            truncated = $(if ($cmdOut) { [bool]$cmdOut.Truncated } else { $false })
            blocked   = $(if ($cmdOut) { [bool]$cmdOut.Blocked } else { $false })
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_ID'      { 'Invalid or missing headset id.' }
            'INVALID_COMMAND' { 'Type a command first.' }
            'UNKNOWN_HEADSET' { 'This headset is not registered on this server.' }
            default           { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; message = $errMsg; output = ''; truncated = $false; blocked = $false }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headset-diag/presets  - the operator-editable command presets plus the
# page timings, all from config (Diag.*). No headset involved, so it never touches ADB.
function Invoke-RouteHeadsetDiagPresets {
    # GET /api/headset-diag/presets
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        Send-JsonResponse -Response $response -Body @{
            ok             = $true
            presets        = @(Get-HeadsetDiagPresets)
            autoRefreshSec = [int]$global:Diag_auto_refresh_sec
            cablePasses    = [int]$global:Diag_cable_test_passes
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}
