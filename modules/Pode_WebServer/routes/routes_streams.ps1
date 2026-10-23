# VR Headset Manager - web routes: streams (S9-3).
#
# Route handlers for captures and restreaming: recording toggle, capture mode, scrcpy profile/views, auto-restart, start/stop, mediamtx restart and proxy.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: POST /api/recording  body: {"name":"Q3_BLUE","value":true}
function Invoke-RouteRecording {
    # POST /api/recording
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $rows = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if ($headset) {
            $enable = ([string]$json.value -eq 'True' -or [string]$json.value -eq 'true')
            # Low-disk guard, registry write and capture restart: shared with the console.
            $rec = Set-HeadsetRecording -Headset $headset -Enabled $enable -Headsets $rows
            if ($rec.StorageLow) {
                $lowBody = ('{"ok":false,"storageLow":true,"freeGB":' + $rec.FreeGB + ',"minFreeGB":' + $rec.MinFreeGB + ',"driveLetter":"' + $rec.DriveLetter + '"}')
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($lowBody)
                $response.StatusCode      = 200
                $response.ContentType     = 'application/json; charset=utf-8'
                $response.Headers.Add('Access-Control-Allow-Origin', '*')
                $response.ContentLength64 = $respBytes.Length
                $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                Close-HttpResponse -Response $response
                return
            }
            if (-not $rec.Ok) { throw "Set-HeadsetRecording failed" }
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
        }
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

# API: GET /api/recording-drive  - returns RecordingDrive node from computer_monitoring.json
function Invoke-RouteRecordingDrive {
    # GET /api/recording-drive
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $rdInfo = $null
        try {
            $monJson = Get-DbKeyValue -Key 'computer_monitoring'
            if ($monJson) { $rdInfo = $monJson.RecordingDrive }
        } catch {}
        if (-not $rdInfo) {
            try { $rdInfo = Get-RecordingDriveInfo } catch {}
        }
        if ($rdInfo) {
            Send-JsonResponse -Response $response -Body $rdInfo
        } else {
            Send-JsonResponse -Response $response -Body @{ error = 'unavailable' }
        }
    } catch {
        try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/capture-mode  - returns the current global capture mode
function Invoke-RouteCaptureModeGet {
    # GET /api/capture-mode
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        Send-JsonResponse -Response $response -Body @{ ok = $true; mode = "$global:CaptureMode" }
    } catch {
        try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = 'server error' } } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/capture-mode  body: {"mode":"StreamOnly|StreamAndLocalWindow|LocalWindow"}
# Switches global capture mode, persists to config.json, restarts any running
# scrcpy session in the new mode. Mirrors the CLI Config -> V sub-menu.
function Invoke-RouteCaptureModePost {
    # POST /api/capture-mode
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = (Read-RequestBody -Request $request -Response $response -MaxBytes 65536)
        $j = $body | ConvertFrom-Json -ErrorAction Stop
        $mode = "$($j.mode)"
        if ($mode -notin @('StreamOnly','StreamAndLocalWindow','LocalWindow')) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'invalid mode' }
        } else {
            $ok = [bool](Set-CaptureMode -Mode $mode)
            Send-JsonResponse -Response $response -Body @{ ok = $ok; mode = "$global:CaptureMode" }
        }
    } catch {
        try { Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = "$($_.Exception.Message)" } } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/updateprofile  body: {"name":"Q3_BLUE","profile":"portrait-R-N-45-20"}
function Invoke-RouteUpdateprofile {
    # POST /api/updateprofile
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        # Validate headset name
        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        # Validate profile format: <viewname>-[L/R/M]-[D/N]-<posint>-<posint> (M = merged eyes)
        # Also accept legacy 4-part format [L/R/M]-[D/N]-<posint>-<posint>
        $safeProfile = [regex]::Match($json.profile, '^[\w]+-[LRM]-[DN]-\d+-\d+$').Value
        if (-not $safeProfile) {
            # Try legacy format and auto-upgrade
            $legacy = [regex]::Match($json.profile, '^[LRM]-[DN]-\d+-\d+$').Value
            if ($legacy) { $safeProfile = "portrait-$legacy" } else { throw "Invalid profile format" }
        }
        $parts = $safeProfile -split '-'
        if ([int]$parts[3] -lt 1 -or [int]$parts[4] -lt 1) { throw "FPS and bitrate must be positive" }

        $rows = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if ($headset) {
            $profileChanged = ([string]$headset.ScrcpyProfile -ne $safeProfile)
            Update-HeadsetField -headsets $rows -ID ([int]$headset.ID) -Field "ScrcpyProfile" -NewValue $safeProfile
            # A new profile restarts the running capture: mark it "starting" now and have the
            # monitor apply it at once (registry edge + this request), not on the slow tick.
            if ($profileChanged) { [void](Request-ScrcpyCheck -HeadsetId ([int]$headset.ID) -Reason 'profile changed') }
            # A merged view above 30 fps is saved, but the answer carries the CPU warning.
            $fpsAdvice = Get-EyeMergeFpsAdvice -ScrcpyProfile $safeProfile
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ ok = $true; warning = $(if ($fpsAdvice.Warn) { $fpsAdvice.Message } else { $null }) } | ConvertTo-Json -Compress))
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
        }
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

# API: GET /api/scrcpyviews?model=Quest+3  - returns view names for a headset model
function Invoke-RouteScrcpyviews {
    # GET /api/scrcpyviews
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $modelParam = $request.QueryString['model']
        $views = @('portrait','square','wide')
        try {
            $liveConfig = Get-Content -LiteralPath $global:configFilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($modelParam -and $liveConfig.scrcpy.parameters.$modelParam -and $liveConfig.scrcpy.parameters.$modelParam.views) {
                $views = @($liveConfig.scrcpy.parameters.$modelParam.views.PSObject.Properties | Select-Object -ExpandProperty Name)
            }
        } catch {}
        # Built-in non-removable view available on every model.
        if ('fullscreen' -notin $views) { $views += 'fullscreen' }
        $json = $views | ConvertTo-Json -Compress
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('["portrait","square","wide"]')
            $response.StatusCode      = 200
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/autorestart  body: {"name":"Q3_BLUE","value":true}
function Invoke-RouteAutorestart {
    # POST /api/autorestart
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        # Validate input - name must be a simple identifier (no path chars)
        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $rows = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if ($headset) {
            $enable = ([string]$json.value -eq 'True' -or [string]$json.value -eq 'true')
            # Registry write + immediate start request when ON: shared with the console.
            if (-not (Set-HeadsetAutoCast -Headset $headset -Enabled $enable -Headsets $rows)) { throw "Set-HeadsetAutoCast failed" }
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"not found"}')
        }
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

# API: POST /api/stop-scrcpy  body: {"name":"Q3_BLUE"}
function Invoke-RouteStopScrcpy {
    # POST /api/stop-scrcpy
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json     = $body | ConvertFrom-Json
        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }
        $rows    = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        # NOTE: Send-JsonResponse takes an OBJECT (or -Raw text). Handing it a byte[] made it
        # JSON-encode the bytes, so the page received [123,34,...] instead of {"ok":true},
        # saw no "ok", and reverted its state as if the stop had failed (the "Starting"
        # indicator vanishing after ~1 s and the stop button coming back).
        if ($headset) {
            # Who asked: a stop always restarts a capture that has auto-restart ON, so an
            # unexpected restart must be attributable (client address + the page it came from).
            $stopFrom = try { [string]$request.RemoteEndPoint.Address } catch { '?' }
            $stopPage = try { if ($request.UrlReferrer) { [string]$request.UrlReferrer.AbsolutePath } else { '-' } } catch { '-' }
            Write-Log ("Stop scrcpy requested for {0} by {1} (page {2})" -f $headset.Name, $stopFrom, $stopPage) -Level INFO
            # Waits for a start in flight, then asks VRMonitor to restart it when auto-restart
            # is ON: shared with the console (Stop-HeadsetCapture).
            $stop = Stop-HeadsetCapture -Headset $headset
            Send-JsonResponse -Response $response -Body @{ ok = [bool]$stop.Ok; stopped = [bool]$stop.Stopped; restarting = [bool]$stop.Restarting } -StatusCode 200
        } else {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'not found' } -StatusCode 200
        }
    } catch {
        try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/start-scrcpy-all - enables autorestart for all headsets (VRMonitor starts scrcpy)
function Invoke-RouteStartScrcpyAll {
    # POST /api/start-scrcpy-all
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $rows = Get-KnownHeadsets
        foreach ($row in $rows) {
            Update-HeadsetField -Id $row.ID -Field 'scrcpy_AutoRestart' -NewValue 'True'
        }
        [void](Request-ScrcpyCheck -All -Reason 'start all captures')
        Send-JsonResponse -Response $response -Raw '{"ok":true}'
    } catch {
        try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/stop-scrcpy-all - disables autorestart for all headsets then kills all scrcpy
function Invoke-RouteStopScrcpyAll {
    # POST /api/stop-scrcpy-all
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $rows = Get-KnownHeadsets
        foreach ($row in $rows) {
            Update-HeadsetField -Id $row.ID -Field 'scrcpy_AutoRestart' -NewValue 'False'
        }
        Stop-Scrcpy
        Send-JsonResponse -Response $response -Raw '{"ok":true}'
    } catch {
        try { Send-JsonResponse -Response $response -Raw '{"ok":false,"error":"server error"}' -StatusCode 500 } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/restartmediamtx
# mediamtx and the captures publishing to it belong to VRMonitor (ADR-0032): ask it to
# restart mediamtx together with every running capture (a mediamtx restart breaks every
# publisher anyway). Answers at once; the restart runs on VRMonitor's next fast tick.
function Invoke-RouteRestartmediamtx {
    # POST /api/restartmediamtx
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $reqId = Request-StreamRestart -MediaMtx -Reason 'mediamtx restart (web)'
        if (-not $reqId) { throw 'restart request not written' }
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"requested":true}')
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
    } finally { Close-HttpResponse -Response $response }
    return
}

# Proxy: GET /proxy/mediamtx/* -> forwards to localhost MediaMTX API (avoids CORS/auth)
function Invoke-RouteMediaMtxProxy {
    # prefix route, see $script:RoutePrefixes
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response
    # The dispatcher matched the path; re-run the match here so $Matches[1] is this request's.
    $null = $request.Url.LocalPath -match '^/proxy/mediamtx(/.*)$'

    try {
        $mtxPath  = $Matches[1]
        $mtxQuery = $request.Url.Query
        $mtxPort  = if ($global:mediamtxApiPort) { $global:mediamtxApiPort } else { 9997 }
        $mtxUrl   = "http://127.0.0.1:$mtxPort$mtxPath$mtxQuery"
        # HttpWebRequest with hard timeouts so a stalled mediamtx cannot
        # freeze the single-threaded request loop for the OS default ~100s.
        $req = [System.Net.HttpWebRequest]::Create($mtxUrl)
        $req.Method            = 'GET'
        $req.Accept            = 'application/json'
        $req.Timeout           = 1500
        $req.ReadWriteTimeout  = 1500
        $resp   = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $body   = $reader.ReadToEnd()
        $reader.Close(); $stream.Close(); $resp.Close()
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $errMsg = '{"error":"mediamtx unreachable or returned an error"}'
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
            $response.StatusCode      = 502
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}
