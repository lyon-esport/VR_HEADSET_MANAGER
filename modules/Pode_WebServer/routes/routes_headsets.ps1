# VR Headset Manager - web routes: headsets (S9-3).
#
# Route handlers for the headset registry (add, rename, reorder, remove, address), live status and history, power, per-headset settings and the companion app.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: POST /api/renameheadset  body: {"name":"Q3_BLUE","newname":"Q3 Red"}
function Invoke-RouteRenameheadset {
    # POST /api/renameheadset
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        # name is the internal display_name (underscores), newname is raw
        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $newName = $json.newname.Trim()
        # Allow letters, digits, spaces, hyphens, underscores (1-40 chars)
        if (-not ($newName -match '^[\w\s\-]{1,40}$')) { throw "Invalid new name" }

        # Resolve old (display) name from the CSV and delegate to Rename-Headset
        $rows   = Get-KnownHeadsets
        $oldRow = $rows | Where-Object { ($_.Name -replace ' ', '_') -eq $safeName } | Select-Object -First 1
        if (-not $oldRow) { throw "Headset not found" }

        $ok = Rename-Headset -OldName $oldRow.Name -NewName $newName -headsets $rows
        if ($ok) {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes(('{"ok":true,"newname":' + ($newName | ConvertTo-Json -Compress) + '}'))
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

# API: POST /api/reorderheadsets  body: {"order":["Q3_BLUE","Q3_RED",...]}
# Delegates to Set-HeadsetsOrder (headsets_manager.ps1) which saves CSV and regenerates HTML monitors.
function Invoke-RouteReorderheadsets {
    # POST /api/reorderheadsets
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        if (-not $json.order -or $json.order.Count -eq 0) { throw "Empty order" }

        # Validate each name token
        foreach ($tok in $json.order) {
            if ($tok -notmatch '^[\w\-]+$') { throw "Invalid name token: $tok" }
        }

        Set-HeadsetsOrder -OrderedDisplayNames ([string[]]$json.order)

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

# API: POST /api/updateip  body: {"name":"Q3_BLUE","ip":"192.168.1.99"}
function Invoke-RouteUpdateip {
    # POST /api/updateip
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $parsedIp = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$json.ip, [ref]$parsedIp) -or
            $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Invalid IP address"
        }
        $safeIp = $parsedIp.ToString()

        $rows   = Get-KnownHeadsets
        $target = $rows | Where-Object { ($_.Name -replace ' ', '_') -eq $safeName } | Select-Object -First 1

        if (-not $target) {
            $respBody = [ordered]@{ ok = $false; error = 'not found' }
        }
        elseif ($target.SerialNumber) {
            # Route through the serial-keyed writer so a manual IP correction cannot
            # leave two rows on the same address - the previous holder is released.
            $r = Set-HeadsetIdentity -SerialNumber $target.SerialNumber -IPAddress $safeIp -Source 'web'
            if ($r.Ok) {
                $respBody = [ordered]@{ ok = $true }
            } else {
                $respBody = [ordered]@{ ok = $false; error = [string]$r.Error }
            }
        }
        elseif ($rows | Where-Object { $_.IPAddress -eq $safeIp -and $_.ID -ne $target.ID }) {
            # Row has no serial yet (manual IP-only entry): still refuse a duplicate.
            $respBody = [ordered]@{ ok = $false; error = 'This IP address is already registered.' }
        }
        else {
            $target.IPAddress = $safeIp
            Save-Headsets -headsets $rows
            $respBody = [ordered]@{ ok = $true }
        }
        Send-JsonResponse -Response $response -Body $respBody
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

# API: POST /api/removeheadset  body: {"name":"Q3_BLUE"}
function Invoke-RouteRemoveheadset {
    # POST /api/removeheadset
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        $safeName = [regex]::Match($json.name, '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }

        $rows  = Get-KnownHeadsets
        $match = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $match) { throw "Headset not found" }
        Remove-Headset -ID ([int]$match.ID)

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

# API: POST /api/reboot  body: {"name":"Q3_BLUE"}
function Invoke-RouteReboot {
    # POST /api/reboot
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
        if (-not $headset) { throw "Headset not found" }
        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        if (-not $device) { throw "Could not connect to headset via ADB" }
        Invoke-HeadsetReboot -Device $device -adb $adbPath | Out-Null
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

# API: POST /api/shutdown  body: {"name":"Q3_BLUE"}
function Invoke-RouteShutdown {
    # POST /api/shutdown
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
        if (-not $headset) { throw "Headset not found" }
        # Priority route: no connect / ping first, one bounded adb process (S6-1).
        $shutdownRows = @(Invoke-HeadsetShutdownBatch -Headsets @($headset) -adb $adbPath -AdbPort $adbPort -TimeoutSec 6)
        if ($shutdownRows.Count -eq 0 -or -not $shutdownRows[0].Ok) { throw "Could not shut the headset down via ADB" }
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

# API: POST /api/shutdown-all  - shuts down selected (or all) ADB-reachable headsets
function Invoke-RouteShutdownAll {
    # POST /api/shutdown-all
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $filter          = $null
        $alsoShutdownApp = $false
        if ($request.HasEntityBody) {
            $bodyStr = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
            if ($bodyStr -and $bodyStr.Trim() -ne '') {
                try {
                    $parsed = $bodyStr | ConvertFrom-Json
                    if ($parsed.headsets) { $filter = @($parsed.headsets) }
                    if ($parsed.PSObject.Properties.Name -contains 'alsoShutdownApp') {
                        $alsoShutdownApp = [bool]$parsed.alsoShutdownApp
                    }
                } catch {}
            }
        }
        $rows = Get-KnownHeadsets
        if ($filter) { $rows = $rows | Where-Object { $filter -contains ($_.Name -replace ' ', '_') } }
        # Priority route (S6-1): every headset is powered off AT THE SAME TIME (one adb
        # process each, no connect / ping first) and the whole batch is bounded, so an
        # offline fleet no longer costs ~1 minute and nothing here waits for slow work.
        $results = @()
        foreach ($r in @(Invoke-HeadsetShutdownBatch -Headsets @($rows) -adb $adbPath -AdbPort $adbPort -TimeoutSec 8)) {
            $results += @{ name = ($r.Name -replace ' ', '_'); ok = [bool]$r.Ok }
        }
        $respJson  = if ($results.Count -gt 0) { ConvertTo-Json -InputObject @($results) -Compress } else { '[]' }
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"results`":$respJson}")
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
            $alsoShutdownApp = $false
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
        # App shutdown injected AFTER response is flushed so the browser receives
        # the JSON before the web server process begins its own teardown.
        if ($alsoShutdownApp) {
            try {
                $mainProc = @(Get-MainProcessList) | Select-Object -First 1
                if ($mainProc) {
                    $mainPid = [uint32]$mainProc.ProcessId
                    [void][VrmConsoleInput]::InjectKeys($mainPid, '0', $true)
                }
            } catch {}
        }
    }
    return
}

# API: GET /api/headset-status?id=<ID>   (legacy: ?name=<Name>)
# Lightweight status endpoint: reads known_headsets_infos.csv (written by VRMonitor) and
# returns the live data for one headset as JSON. No ADB call. Used by the monitoring overlay
# JS to update the DOM every second without re-downloading the full HTML page.
# The infos file is ID-keyed (ADR-0016). ?name= is still accepted because overlay HTML
# already loaded in an operator's OBS Browser source keeps requesting it; it is resolved
# to an ID through the registry, which is the authority on names.
function Invoke-RouteHeadsetStatus {
    # GET /api/headset-status
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawId   = $request.QueryString['id']
        $rawName = $request.QueryString['name']
        if (-not $rawId -and -not $rawName) { throw "Missing id parameter" }

        $headsetRow = $null
        foreach ($h in @(Get-KnownHeadsetsCached)) {
            if ($rawId) {
                if ([string]$h.ID -eq [string]$rawId) { $headsetRow = $h; break }
            } elseif ($h.Name -eq $rawName) {
                $headsetRow = $h; break
            }
        }
        if (-not $headsetRow) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = 'Headset not found' }
            return
        }

        $infosCache = Get-HeadsetInfosCache
        if (-not $infosCache) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = 'No monitoring data yet' }
            return
        }
        $row = $infosCache[[string]$headsetRow.ID]

        if (-not $row) {
            Send-JsonResponse -Response $response -StatusCode 404 -Body @{ error = 'Headset not found' }
            return
        }

        $capSt = Get-ScrcpyCaptureState

        # Parse raw CSV strings into typed values for the JS consumer
        $battery    =if ($row.Battery -and $row.Battery -ne '-') { [int]($row.Battery -replace '\s*%','') } else { $null }
        $battLeft   = if ($row.BatteryControllerLeft  -and $row.BatteryControllerLeft  -ne '-') { [int]($row.BatteryControllerLeft  -replace '\s*%','') } else { $null }
        $battRight  = if ($row.BatteryControllerRight -and $row.BatteryControllerRight -ne '-') { [int]($row.BatteryControllerRight -replace '\s*%','') } else { $null }
        $temp       = if ($row.Temp -and $row.Temp -ne '-') { [int]($row.Temp -replace ',','.') } else { $null }
        $timeMin    = if ($row.TimeRemainingMin -and $row.TimeRemainingMin -ne '-' -and $row.TimeRemainingMin -ne '') { [int]$row.TimeRemainingMin } else { $null }

        $result = @{
            id                   = [int]$headsetRow.ID
            name                 = $headsetRow.Name
            ping                 = [bool]($row.Ping -eq 'True')
            adb_transport        = if ($row.AdbTransport -and $row.AdbTransport -ne '-') { $row.AdbTransport } else { '' }
            adb_wifi_mode        = if ($row.AdbWifiMode  -and $row.AdbWifiMode  -ne '-') { $row.AdbWifiMode }  else { '' }
            battery              = $battery
            battery_ctrl_left    = $battLeft
            battery_ctrl_right   = $battRight
            charging             = [bool]($row.Charging -eq 'True')
            temp                 = $temp
            power_state          = if ($row.PowerState -and $row.PowerState -ne '-') { $row.PowerState } else { '' }
            time_remaining_min   = $timeMin
            running_app          = if ($row.RunningApp)     { $row.RunningApp }     else { '' }
            running_app_icon     = if ($row.RunningAppIcon) { $row.RunningAppIcon } else { '' }
            # Capture state, for the video pages: running, starting right now (a mark set
            # by start-screenCopy / Request-ScrcpyCheck), and whether it will be restarted
            # by itself (auto-restart) - which tells "starting" from "stopped".
            scrcpy               = $(if ($capSt.Starting -contains [int]$headsetRow.ID) { $false } elseif ($capSt.Settling -contains [int]$headsetRow.ID) { $true } else { [bool]($row.SCRCPY -eq 'ok') })
            scrcpy_starting      = [bool](($capSt.Starting -contains [int]$headsetRow.ID) -or ($capSt.Announcing -contains [int]$headsetRow.ID))
            scrcpy_auto_restart  = [bool]($headsetRow.scrcpy_AutoRestart -eq 'True')
            # Recording flag of the registry (the record button of the [video].html page).
            record               = [bool](ConvertTo-DbBool $headsetRow.Record)
        }
        Send-JsonResponse -Response $response -Body $result
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headset-settings?name=Q3_BLUE  - reads current headset parameters via ADB
function Invoke-RouteHeadsetSettings {
    # GET /api/headset-settings
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }
        $rows    = Get-KnownHeadsetsCached
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        if (-not $device) { throw "Could not connect to headset via ADB" }

        $brand = if ($headset.PSObject.Properties['Brand'] -and $headset.Brand) { $headset.Brand } else { (Get-HeadsetBrandModel -Device $device -adb $adbPath).Brand }
        $screenTimeout    = Get-HeadsetScreenTimeout    -Device $device -adb $adbPath -Brand $brand
        $sleepTimeout     = Get-HeadsetSleepTimeout     -Device $device -adb $adbPath -Brand $brand
        $soundLevel       = Get-HeadsetSoundLevel       -Device $device -adb $adbPath
        $brightness       = Get-HeadsetBrightness       -Device $device -adb $adbPath -Brand $brand
        $blockUpdates     = Get-HeadsetUpdateBlockStatus -Device $device -adb $adbPath -Brand $brand
        $refreshRate      = if ($brand -eq 'Pico') { $null } else { Get-HeadsetRefreshRate -Device $device -adb $adbPath }
        # Session-only settings (ADR-0040): live state where the headset can tell, the remembered
        # wish otherwise (the proximity override cannot be read back).
        $sessionSaved     = Get-HeadsetSessionSettings -HeadsetId ([int]$headset.ID) -NoMemo
        $doubleTapOff     = Get-HeadsetDoubleTapDisabled -Device $device -adb $adbPath -Brand $brand
        $wideMotion       = Get-HeadsetWideMotionMode    -Device $device -adb $adbPath -Brand $brand
        $guardianPaused   = Get-HeadsetGuardianPause     -Device $device -adb $adbPath -Brand $brand
        $sharpening       = Get-HeadsetSharpening        -Device $device -adb $adbPath -Brand $brand

        Send-JsonResponse -Response $response -Body @{
            ok               = $true
            doubleTapDisabled = $doubleTapOff
            wideMotion       = $wideMotion
            guardianPaused   = $guardianPaused
            sharpening       = $sharpening
            proxKeepAwake   = [bool]$sessionSaved.desired.proxKeepAwake
            sessionReapply   = [bool]$sessionSaved.reapply
            screenTimeout    = $screenTimeout
            sleepTimeout     = $sleepTimeout
            soundLevel       = $soundLevel
            brightness       = $brightness
            blockUpdates     = $blockUpdates
            refreshRate      = $refreshRate
            refreshRates     = @(Get-HeadsetRefreshRateChoices)
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headset-firmware?name=Q3_BLUE  - returns firmware version, build, and pending OTA
function Invoke-RouteHeadsetFirmware {
    # GET /api/headset-firmware
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }
        $rows    = Get-KnownHeadsetsCached
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $device  = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        if (-not $device) { throw "Could not connect to headset via ADB" }

        $brand = if ($headset.PSObject.Properties['Brand'] -and $headset.Brand) { $headset.Brand } else { (Get-HeadsetBrandModel -Device $device -adb $adbPath).Brand }
        $fw = Get-HeadsetFirmwareInfo -Device $device -adb $adbPath -Brand $brand
        Send-JsonResponse -Response $response -Body @{
            ok            = $true
            version       = $fw.Version
            build         = $fw.Build
            updateVersion = $fw.UpdateVersion
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/companion-info?name=Q3_BLUE
# Calls GET http://<IP>:8765/info on the VRHM Companion app and returns the result.
# Returns {"ok":false,"companion":false} when the companion app is not running.
function Invoke-RouteCompanionInfo {
    # GET /api/companion-info
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }
        $rows    = Get-KnownHeadsetsCached
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $info = Get-CompanionInfo -IP $headset.IPAddress
        if ($null -ne $info) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; companion = $true; data = $info }
        } else {
            Send-JsonResponse -Response $response -Body @{ ok = $true; companion = $false }
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/companion-settings?name=Q3_BLUE  body: {"auto_adb_wifi":bool}
# Forwards settings to the Companion app running on the headset.
function Invoke-RouteCompanionSettings {
    # POST /api/companion-settings
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }
        $rows    = Get-KnownHeadsets
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }

        $bodyRaw = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json = $bodyRaw | ConvertFrom-Json

        $url  = "http://$($headset.IPAddress):8765/settings"
        $resp2 = Invoke-RestMethod -Uri $url -Method POST -Body $bodyRaw `
                     -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
        Send-JsonResponse -Response $response -Body @{ ok = [bool]$resp2.ok }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headset-storage?name=Q3_BLUE  - returns storage info via df /sdcard
function Invoke-RouteHeadsetStorage {
    # GET /api/headset-storage
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $safeName = [regex]::Match($request.QueryString['name'], '^[\w\-]+$').Value
        if (-not $safeName) { throw "Invalid headset name" }
        $rows    = Get-KnownHeadsetsCached
        $headset = $rows | Where-Object { ($_.Name -replace ' ','_') -eq $safeName } | Select-Object -First 1
        if (-not $headset) { throw "Headset not found" }
        $device  = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        if (-not $device) { throw "Could not connect to headset via ADB" }

        $s = Get-HeadsetStorageInfo -Device $device -adb $adbPath
        if (-not $s) { throw "Could not read storage info" }
        Send-JsonResponse -Response $response -Body @{
            ok          = $true
            totalGB     = $s.TotalGB
            usedGB      = $s.UsedGB
            freeGB      = $s.FreeGB
            usedPercent = $s.UsedPercent
            freePercent = $s.FreePercent
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/headset-settings/apply  body: {"name":"Q3_BLUE","settings":{...}}
function Invoke-RouteHeadsetSettingsApply {
    # POST /api/headset-settings/apply
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
        if (-not $headset) { throw "Headset not found" }
        $device = Get-BestAdbDevice -Headset $headset -AdbPort $adbPort -adb $adbPath
        if (-not $device) { throw "Could not connect to headset via ADB" }

        $s = $json.settings
        $brand = if ($headset.PSObject.Properties['Brand'] -and $headset.Brand) { $headset.Brand } else { (Get-HeadsetBrandModel -Device $device -adb $adbPath).Brand }
        if ($null -ne $s.guardianMode) {
            Set-HeadsetGuardian -Device $device -adb $adbPath -Brand $brand | Out-Null
        }

        $hid = [int]$headset.ID
        if ($null -ne $s.guardianPause) {
            $okGp = Set-HeadsetGuardianPause -Device $device -Pause ([bool]$s.guardianPause) -adb $adbPath -Brand $brand
            if ($okGp) { [void](Set-HeadsetSessionSettings -HeadsetId $hid -Desired @{ guardianPause = [bool]$s.guardianPause }) }
        }

        # Session-only settings (ADR-0040): each change is also remembered, so "re-apply after a
        # reboot" can put it back. Meta only.
        if ($null -ne $s.doubleTapDisabled) {
            if ($brand -eq 'Pico') { throw "The side double tap is only controllable on Meta Quest headsets" }
            if (-not (Set-HeadsetDoubleTapDisabled -Device $device -Disabled ([bool]$s.doubleTapDisabled) -adb $adbPath -Brand $brand)) { throw "Could not change the side double tap" }
            [void](Set-HeadsetSessionSettings -HeadsetId $hid -Desired @{ doubleTapOff = [bool]$s.doubleTapDisabled })
        }
        if ($null -ne $s.wideMotion) {
            if ($brand -eq 'Pico') { throw "Wide-motion hand tracking is only supported on Meta Quest headsets" }
            if (-not (Set-HeadsetWideMotionMode -Device $device -Enabled ([bool]$s.wideMotion) -adb $adbPath -Brand $brand)) { throw "Could not change the hand tracking mode" }
            [void](Set-HeadsetSessionSettings -HeadsetId $hid -Desired @{ wideMotion = [bool]$s.wideMotion })
        }
        if ($null -ne $s.sharpening) {
            $sharpMode = ([string]$s.sharpening).ToLowerInvariant()
            if ($sharpMode -notin @('none', 'fcas', 'mqsr')) { throw "Invalid sharpening mode" }
            if ($brand -eq 'Pico') { throw "Image sharpening is only supported on Meta Quest headsets" }
            if (-not (Set-HeadsetSharpening -Device $device -Mode $sharpMode -adb $adbPath -Brand $brand)) { throw "Could not change the image sharpening" }
            [void](Set-HeadsetSessionSettings -HeadsetId $hid -Desired @{ sharpening = $sharpMode })
        }
        if ($null -ne $s.sessionReapply) {
            if (-not (Set-HeadsetSessionSettings -HeadsetId $hid -Reapply ([bool]$s.sessionReapply))) { throw "Could not save the re-apply switch" }
        }

        if ($null -ne $s.soundLevel) {
            Set-HeadsetSoundLevel -Device $device -Percent ([int]$s.soundLevel) -adb $adbPath | Out-Null
        }

        if ($null -ne $s.brightness) {
            Set-HeadsetBrightness -Device $device -Percent ([int]$s.brightness) -adb $adbPath -Brand $brand | Out-Null
        }

        if ($null -ne $s.proxOverride) {
            # true = keep awake (prox_close, as before); false = hand the sensor back (automation_disable).
            $keep = [bool]$s.proxOverride
            if ($keep) { $okPx = Set-HeadsetProximitySensorOverride -Device $device -adb $adbPath }
            else       { $okPx = Set-HeadsetProximitySensorOverride -Device $device -adb $adbPath -Clear }
            if ($okPx) { [void](Set-HeadsetSessionSettings -HeadsetId $hid -Desired @{ proxKeepAwake = $keep }) }
        }

        if ($null -ne $s.displaySizeReset) {
            Reset-HeadsetDisplaySize -Device $device -adb $adbPath | Out-Null
        }

        if ($null -ne $s.blockUpdates) {
            Set-HeadsetUpdateBlocked -Device $device -Block ([bool]$s.blockUpdates) -adb $adbPath -Brand $brand | Out-Null
        }

        if ($null -ne $s.refreshRate) {
            $hz = 0
            if (-not [int]::TryParse([string]$s.refreshRate, [ref]$hz) -or $hz -notin @(Get-HeadsetRefreshRateChoices)) { throw "Invalid refresh rate" }
            if ($brand -eq 'Pico') { throw "Refresh rate is only supported on Meta Quest headsets" }
            if (-not (Set-HeadsetRefreshRate -Device $device -Hz $hz -adb $adbPath)) { throw "Could not set refresh rate" }
        }

        Send-JsonResponse -Response $response -Body @{ ok = $true }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headsets  - returns all known headsets as JSON (from Get-KnownHeadsets)
function Invoke-RouteHeadsets {
    # GET /api/headsets
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $rows = Get-KnownHeadsetsCached
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $items.Add([ordered]@{
                ID                 = [int]$row.ID
                Name               = $row.Name
                IPAddress          = $row.IPAddress
                Model              = $row.Model
                Brand              = $row.Brand
                SerialNumber       = $row.SerialNumber
                ScrcpyProfile      = $row.ScrcpyProfile
                scrcpy_AutoRestart = $row.scrcpy_AutoRestart
                Record             = $row.Record
            })
        }
        # ONE serialisation for the whole list. -InputObject keeps a 0 or 1 row
        # list a JSON array (the pipeline would unroll it).
        $json = if ($items.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $items.ToArray() -Compress -Depth 3 }
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
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

# API: GET /api/headsets-status  - all headsets combined status (ping/scrcpy/adb/runningApp/model/autoRestart)
# Shared by video_monitor, headsets_monitoring, headsets_settings. Uses mtime caches so at most
# one CSV read per write cycle regardless of how many pages poll simultaneously.
function Invoke-RouteHeadsetsStatus {
    # GET /api/headsets-status
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        # Live status, ID-keyed (ADR-0016). Shared mtime cache with /api/headset-status.
        $infosCache = Get-HeadsetInfosCache
        # Captures that are starting right now (scrcpy_starting kv row, see
        # Get-ScrcpyCaptureState): pages show "starting" instead of a dead stream. While a
        # capture is Starting, scrcpy is reported false whatever the monitor's SCRCPY flag
        # says - that flag lags reality by several seconds, which made a just-killed
        # capture look alive (and a started one look dead).
        $capState     = Get-ScrcpyCaptureState
        $startingSet  = @($capState.Starting)
        $settlingSet  = @($capState.Settling)
        $announceSet  = @($capState.Announcing)

        # Build response: one entry per known headset (in CSV order) joined with live infos
        $items = @(Get-KnownHeadsetsCached |
            ForEach-Object {
                $h    = $_
                $info = if ($infosCache) { $infosCache[[string]$h.ID] } else { $null }
                @{
                    display_name          = Convert-Displayname $h.Name
                    name                  = $h.Name
                    id                    = [int]$h.ID
                    ip_address            = if ($h.IPAddress) { $h.IPAddress } else { '' }
                    ping                  = [bool]($info.Ping    -eq 'True')
                    scrcpy                = $(if ($startingSet -contains [int]$h.ID) { $false } elseif ($settlingSet -contains [int]$h.ID) { $true } else { [bool]($info.SCRCPY -eq 'ok') })
                    scrcpy_starting       = [bool](($startingSet -contains [int]$h.ID) -or ($announceSet -contains [int]$h.ID))
                    adb                   = [bool]($info.ADBWifi -eq 'True')
                    charging              = [bool]($info.Charging -eq 'True')
                    charging_wattage      = if ($info.ChargingWattage -and $info.ChargingWattage -ne '-') { $info.ChargingWattage } else { '' }
                    power_state           = if ($info.PowerState -and $info.PowerState -ne '-') { $info.PowerState } else { '' }
                    time_remaining_min    = if ($info.TimeRemainingMin -and $info.TimeRemainingMin -ne '-') { $info.TimeRemainingMin } else { '' }
                    battery               = if ($info.Battery -and $info.Battery -ne '-') { $info.Battery } else { '-' }
                    battery_ctrl_left     = if ($info.BatteryControllerLeft  -and $info.BatteryControllerLeft  -ne '-') { $info.BatteryControllerLeft  } else { '-' }
                    battery_ctrl_right    = if ($info.BatteryControllerRight -and $info.BatteryControllerRight -ne '-') { $info.BatteryControllerRight } else { '-' }
                    temp                  = if ($info.Temp -and $info.Temp -ne '-') { $info.Temp } else { '-' }
                    cpu_temp              = if ($info.CpuTemp -and $info.CpuTemp -ne '-') { $info.CpuTemp } else { '-' }
                    adb_transport         = if ($info.AdbTransport -and $info.AdbTransport -ne '-') { $info.AdbTransport } else { '' }
                    # WiFi ADB mode (ADR-0034, migration 009): Classic / TLS, '' when WiFi ADB is not up.
                    adb_wifi_mode         = if ($info.AdbWifiMode -and $info.AdbWifiMode -ne '-') { $info.AdbWifiMode } else { '' }
                    # TCP port of the WiFi ADB session: classic = configured port, TLS = published
                    # mDNS endpoint of the serial (changes at every adbd restart). 0 = unknown / USB.
                    adb_port              = $(
                        $wm = if ($info.AdbWifiMode) { [string]$info.AdbWifiMode } else { '' }
                        if ($info.AdbTransport -eq 'USB') { 0 }
                        elseif ($wm -eq 'Classic') { [int](Get-ClassicAdbPort) }
                        elseif ($wm -eq 'TLS' -and $h.SerialNumber -and $h.SerialNumber -ne '-') {
                            $ep = try { Find-AdbTlsEndpointBySerial -Serial $h.SerialNumber } catch { $null }
                            if ($ep -and $ep.Port) { [int]$ep.Port } else { 0 }
                        }
                        else { 0 }
                    )
                    ipd              = (Get-HeadsetIpdValue -Headset $h)
                    running_app           = if ($info.RunningApp)     { $info.RunningApp }     else { '' }
                    running_app_icon      = if ($info.RunningAppIcon) { $info.RunningAppIcon } else { '' }
                    model                 = if ($h.Model -and $h.Model -ne '-') { $h.Model } else { '' }
                    scrcpy_auto_restart   = [bool]($h.scrcpy_AutoRestart -eq 'True')
                    record                = [bool](ConvertTo-DbBool $h.Record)
                }
            }
        )
        Send-JsonResponse -Response $response -Body $items
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/battery-history?id=3&hours=24  - battery samples for one headset
# Backs the battery graph: the hover sparkline on headsets_monitoring.html and the
# full battery_history.html page. Read-only, DB-backed, no side effects.
function Invoke-RouteBatteryHistory {
    # GET /api/battery-history
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawId = $request.QueryString['id']
        $idVal = 0
        if (-not [int]::TryParse([string]$rawId, [ref]$idVal) -or $idVal -le 0) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'Missing or invalid id parameter' }
            return
        }

        # Only the four windows the UI offers. Anything else silently falls back to
        # the widest one - this is a display window, not a command, so a stale link
        # should still draw a graph rather than an error page.
        $hoursVal = 24
        $rawHours = [string]$request.QueryString['hours']
        if ($rawHours -and @('1','3','12','24') -contains $rawHours) { $hoursVal = [int]$rawHours }

        # An empty series is a VALID answer, not a 404: samples are only written when
        # the level changes, so a headset that held steady across the whole window
        # genuinely has nothing to return. The page says so in words.
        $samples = @(Get-BatteryHistory -HeadsetId $idVal -Hours $hoursVal |
            ForEach-Object { @{ ts = [string]$_.ts; pct = [int]$_.pct } })

        Send-JsonResponse -Response $response -Body @{
            ok             = $true
            id             = $idVal
            hours          = $hoursVal
            retentionHours = [int]$global:databaseBatteryHistoryHours
            nowUtc         = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            samples        = $samples
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/metric-history?id=3&metric=temp&hours=24  - one metric's samples
# for one headset. Backs the metric graph: the hover sparkline on
# headsets_monitoring.html and the full metric_history.html page. Read-only,
# DB-backed, no side effects.
function Invoke-RouteMetricHistory {
    # GET /api/metric-history
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $rawId = $request.QueryString['id']
        $idVal = 0
        if (-not [int]::TryParse([string]$rawId, [ref]$idVal) -or $idVal -le 0) {
            Send-JsonResponse -Response $response -StatusCode 400 -Body @{ ok = $false; error = 'Missing or invalid id parameter' }
            return
        }

        # Unknown metric falls back rather than 400s, for the same reason a bad
        # window does: a stale or hand-typed link should still draw something.
        $metricDefs = Get-HeadsetMetricDefinition
        $metricVal  = [string]$request.QueryString['metric']
        if (-not $metricVal -or -not $metricDefs.Contains($metricVal)) { $metricVal = 'battery' }

        # The four windows the UI offers, plus 'all'. Anything else silently falls
        # back to 24h - this is a display window, not a command.
        #
        # 'all' resolves HERE, from the live retention period, so "all records"
        # always means "everything still kept" and the page never has to know the
        # number. The response echoes the resolved numeric hours, which is what the
        # chart pins its x scale to, so the chart needs no special case.
        $retentionHours = if ($global:databaseMetricHistoryHours) { [int]$global:databaseMetricHistoryHours } else { 24 }
        $hoursVal   = 24
        $windowName = '24'
        $rawHours   = [string]$request.QueryString['hours']
        if ($rawHours -eq 'all') {
            $hoursVal   = $retentionHours
            $windowName = 'all'
        } elseif ($rawHours -and @('1','3','12','24') -contains $rawHours) {
            $hoursVal   = [int]$rawHours
            $windowName = $rawHours
        }

        # An empty series is a VALID answer, not a 404: samples are only written when
        # the value changes, so a headset that held steady across the whole window
        # genuinely has nothing to return. The page says so in words.
        $samples = @(Get-MetricHistory -HeadsetId $idVal -Metric $metricVal -Hours $hoursVal |
            ForEach-Object { @{ ts = [string]$_.ts; value = [double]$_.value } })

        Send-JsonResponse -Response $response -Body @{
            ok             = $true
            id             = $idVal
            metric         = $metricVal
            unit           = [string]$metricDefs[$metricVal].Unit
            hours          = $hoursVal
            window         = $windowName
            retentionHours = $retentionHours
            nowUtc         = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            samples        = $samples
        }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/addheadset  body: {"name":"Q3 Blue","ip":"192.168.1.243","model":"Quest 3","serialNumber":"ABC123"}
function Invoke-RouteAddheadset {
    # POST /api/addheadset
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 65536
        $json    = $body | ConvertFrom-Json

        # Validate name: letters, numbers, spaces, hyphens, underscores (1-40 chars)
        $safeName = [regex]::Match($json.name.Trim(), '^[\w\s\-]{1,40}$').Value
        if (-not $safeName) { throw "INVALID_NAME" }

        # Validate IP format and octet range
        $parsedIp2 = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$json.ip, [ref]$parsedIp2) -or
            $parsedIp2.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "INVALID_IP"
        }
        $safeIp = $parsedIp2.ToString()

        $rows = @(Get-KnownHeadsets)

        if ($rows | Where-Object { $_.IPAddress -eq $safeIp })   { throw "IP_DUPLICATE" }
        if ($rows | Where-Object { $_.Name      -eq $safeName }) { throw "NAME_DUPLICATE" }

        $safeModel  = if ($json.model)        { ([string]$json.model).Trim().Substring(0, [Math]::Min(([string]$json.model).Trim().Length, 60)) } else { '' }
        $safeSerial = if ($json.serialNumber) { ([string]$json.serialNumber).Trim().Substring(0, [Math]::Min(([string]$json.serialNumber).Trim().Length, 40)) } else { '' }

        # A serial is a permanent identity - creating a second row for a headset we
        # already know would split its history and break identity healing. Moving a
        # known headset to a new address is register-by-serial's job, not this route's.
        if ($safeSerial -and ($rows | Where-Object { ([string]$_.SerialNumber).Trim() -eq $safeSerial })) { throw "SERIAL_DUPLICATE" }

        Add-Headset -headsets $rows -IPAddress $safeIp -Name $safeName -Model $safeModel -SerialNumber $safeSerial

        # An explicit operator add overrides an earlier "forget" from discovery.
        if ($safeSerial -and (Get-Command Remove-HeadsetDiscoveryIgnore -ErrorAction SilentlyContinue)) {
            Remove-HeadsetDiscoveryIgnore -SerialNumber $safeSerial | Out-Null
        }

        $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $response.StatusCode      = 200
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'IP_DUPLICATE'     { '{"ok":false,"error":"This IP address is already registered."}' }
            'NAME_DUPLICATE'   { '{"ok":false,"error":"A headset with this name already exists."}' }
            'SERIAL_DUPLICATE' { '{"ok":false,"error":"This headset is already registered (same serial number)."}' }
            'INVALID_NAME'     { '{"ok":false,"error":"Invalid name. Use letters, numbers, spaces or hyphens."}' }
            'INVALID_IP'       { '{"ok":false,"error":"Invalid IP address."}' }
            default            { '{"ok":false,"error":"Server error."}' }
        }
        try {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
            $response.StatusCode      = 200
            $response.ContentType     = 'application/json; charset=utf-8'
            $response.Headers.Add('Access-Control-Allow-Origin', '*')
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        } catch {}
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/headsets/register-by-serial  body: {"serialNumber":"...","ip":"...","name":"...","model":"..."}
#
# Adds a new headset, or updates an existing one's IP address, keyed by
# SerialNumber. Called by the remote Headset Toolbox (a standalone script a
# technician runs on a DIFFERENT PC than this server, website\headset-toolbox\
# Enable-HeadsetWifiAdb.ps1) after it enables WiFi ADB on a USB-connected
# headset, and by the console's equivalent "register by serial" option.
# Unlike /api/kiosks/agent-report, this DOES persist new inventory rows -
# that is the intended behavior here, matching this app's existing LAN-trust
# posture (no endpoint in this project requires authentication).
function Invoke-RouteHeadsetsRegisterBySerial {
    # POST /api/headsets/register-by-serial
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw "Request body too large" }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
        $json   = $body | ConvertFrom-Json

        $safeSerial = ([string]$json.serialNumber).Trim()
        if (-not $safeSerial -or $safeSerial.Length -gt 60) { throw "INVALID_SERIAL" }

        $parsedIp = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$json.ip, [ref]$parsedIp) -or
            $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "INVALID_IP"
        }
        $safeIp = $parsedIp.ToString()

        $safeName  = if ($json.name)  { ([string]$json.name).Trim().Substring(0, [Math]::Min(([string]$json.name).Trim().Length, 40)) } else { '' }
        $safeModel = if ($json.model) { ([string]$json.model).Trim().Substring(0, [Math]::Min(([string]$json.model).Trim().Length, 60)) } else { '' }

        $result = Set-HeadsetBySerial -SerialNumber $safeSerial -IPAddress $safeIp -Name $safeName -Model $safeModel

        if ($result.Ok) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; action = $result.Action; id = $result.ID; name = $result.Name }
        } else {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = $result.Error }
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_SERIAL' { 'Invalid or missing serial number.' }
            'INVALID_IP'     { 'Invalid IP address.' }
            default          { $_.Exception.Message }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $errMsg }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: GET /api/headsets/discovered
#
# Devices the background LAN sweep found whose serial is NOT in known_headsets.csv,
# waiting for an operator decision. Feeds the "Discovered devices" button and its
# sub-page in headsets_settings.html. Read-only - nothing here is ever auto-added.
function Invoke-RouteHeadsetsDiscovered {
    # GET /api/headsets/discovered
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $devices = @()
        if (Get-Command Get-PendingDiscoveredHeadsets -ErrorAction SilentlyContinue) {
            $devices = @(Get-PendingDiscoveredHeadsets | ForEach-Object {
                @{
                    serialNumber = [string]$_.SerialNumber
                    ip           = [string]$_.IPAddress
                    model        = [string]$_.Model
                    brand        = [string]$_.Brand
                    firstSeen    = [string]$_.FirstSeen
                    lastSeen     = [string]$_.LastSeen
                }
            })
        }
        Send-JsonResponse -Response $response -Body @{
            ok      = $true
            enabled = [bool]$global:HeadsetDiscovery_enabled
            count   = $devices.Count
            devices = $devices
        }
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'Server error.'; devices = @(); count = 0 }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}

# API: POST /api/headsets/discovered/forget  body: {"serialNumber":"..."}
#
# Permanently stops proposing a discovered device. Keyed on the SERIAL, never the
# IP, so it stays forgotten when DHCP moves it. A later manual add (USB, scan,
# /api/addheadset) still works and clears the denylist entry.
function Invoke-RouteHeadsetsDiscoveredForget {
    # POST /api/headsets/discovered/forget
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        if ($request.ContentLength64 -gt 4096) { throw "Request body too large" }
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
        $json   = $body | ConvertFrom-Json

        $safeSerial = ([string]$json.serialNumber).Trim()
        if (-not $safeSerial -or $safeSerial.Length -gt 60) { throw "INVALID_SERIAL" }

        if (Add-HeadsetDiscoveryIgnore -SerialNumber $safeSerial) {
            Send-JsonResponse -Response $response -Body @{ ok = $true; serialNumber = $safeSerial }
        } else {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'Could not update the ignore list.' }
        }
    } catch {
        $errMsg = switch -Regex ($_.Exception.Message) {
            'INVALID_SERIAL' { 'Invalid or missing serial number.' }
            default          { 'Server error.' }
        }
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $errMsg }
    } finally {
        Close-HttpResponse -Response $response
    }
    return
}
