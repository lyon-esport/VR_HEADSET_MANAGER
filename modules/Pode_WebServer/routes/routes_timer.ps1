# VR Headset Manager - web routes: timer (S9-3).
#
# Route handlers for the per-headset session timer.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# -- /end Known Apps Management API ---------------------------------------

# API: GET /api/timer?id=<headsetID>&action=... OR ?name=<displayName>&action=...
# All actions use GET so Stream Deck and browser links work without POST/CORS setup.
function Invoke-RouteTimer {
    # GET /api/timer
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawQuery = $request.Url.Query.TrimStart('?')
        $qParams  = @{}
        foreach ($pair in $rawQuery -split '&') {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2) { $qParams[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1]) }
        }

        $headsetId = 0
        if ($qParams.ContainsKey('id') -and $qParams['id'] -match '^\d+$') {
            $headsetId = [int]$qParams['id']
        } elseif ($qParams.ContainsKey('name') -and $qParams['name'] -ne '') {
            $safeName = Convert-Displayname $qParams['name']
            $matched = @(Get-KnownHeadsetsCached) | Where-Object { (Convert-Displayname $_.Name) -eq $safeName } | Select-Object -First 1
            if ($matched) { $headsetId = [int]$matched.ID }
        }
        $action = if ($qParams.ContainsKey('action')) { $qParams['action'].ToLower() } else { '' }

        if ($headsetId -le 0 -or -not $action) { throw 'Missing id or action' }

        $respJson = '{"ok":false,"error":"unknown action"}'

        # Any action but status can change what status answers: drop the memo.
        if ($action -ne 'status' -and $script:timerStatusMemo) { $script:timerStatusMemo.Remove($headsetId) }

        switch ($action) {
            'start' {
                Start-HeadsetTimer -headsetId $headsetId
                $respJson = '{"ok":true}'
            }
            'stop' {
                Stop-HeadsetTimer -headsetId $headsetId
                $respJson = '{"ok":true}'
            }
            'pause' {
                $pauseOk = Suspend-HeadsetTimer -headsetId $headsetId
                $respJson = if ($pauseOk -ne $false) { '{"ok":true}' } else { '{"ok":false,"error":"timer not found"}' }
            }
            'resume' {
                $resumeOk = Resume-HeadsetTimer -headsetId $headsetId
                $respJson = if ($resumeOk -ne $false) { '{"ok":true}' } else { '{"ok":false,"error":"timer not found or not paused"}' }
            }
            'reset' {
                Stop-HeadsetTimer -headsetId $headsetId
                $respJson = '{"ok":true}'
            }
            'status' {
                # Two pollers in the same second (page + [timer] overlay) share one computation.
                if (-not $script:timerStatusMemo) { $script:timerStatusMemo = @{} }
                $memo = $script:timerStatusMemo[$headsetId]
                $nowMs = [Environment]::TickCount
                if ($memo -and [int]($nowMs - $memo.At) -ge 0 -and [int]($nowMs - $memo.At) -lt 500) {
                    $respJson = $memo.Json
                    break
                }
                $st = Get-TimerStatus -headsetId $headsetId
                $activeStr = if ($st.active)  { 'true' } else { 'false' }
                $pausedStr = if ($st.paused)  { 'true' } else { 'false' }
                $valueJson = $st.value  | ConvertTo-Json
                $modeJson  = $st.mode   | ConvertTo-Json
                $respJson  = '{"ok":true,"active":' + $activeStr +
                             ',"paused":' + $pausedStr +
                             ',"value":'   + $valueJson +
                             ',"minutes":' + $st.minutes +
                             ',"seconds":' + $st.seconds +
                             ',"mode":'    + $modeJson + '}'
                $script:timerStatusMemo[$headsetId] = @{ At = $nowMs; Json = $respJson }
            }
            'config' {
                $min  = if ($qParams.ContainsKey('minutes') -and $qParams['minutes'] -match '^\d+$') { [int]$qParams['minutes'] } else { 5 }
                $sec  = if ($qParams.ContainsKey('seconds') -and $qParams['seconds'] -match '^\d+$') { [int]$qParams['seconds'] } else { 0 }
                $mode = if ($qParams.ContainsKey('mode')    -and $qParams['mode'] -match '^(dec|inc)$') { $qParams['mode'] } else { 'dec' }
                Set-TimerConfig -headsetId $headsetId -minutes $min -seconds $sec -mode $mode
                $respJson = '{"ok":true}'
            }
        }

        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 400
    } finally { Close-HttpResponse -Response $response }
    return
}
