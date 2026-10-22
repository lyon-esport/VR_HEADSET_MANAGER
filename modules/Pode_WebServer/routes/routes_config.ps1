# VR Headset Manager - web routes: config (S9-3).
#
# Route handlers for config.json read/save/reset, defaults, GPU list, and opening files and folders on this PC.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: GET /api/openconfig  - opens config.json in the default editor (Notepad)
function Invoke-RouteOpenconfig {
    # GET /api/openconfig
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $cfgFile = [System.IO.Path]::GetFullPath((Join-Path $ScriptPath "config\config.json"))
        if (Test-Path -LiteralPath $cfgFile) {
            Start-Process notepad.exe -ArgumentList "`"$cfgFile`""
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"config.json not found"}')
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
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/openfolder?target=logs|config|records  - opens folder in Explorer
function Invoke-RouteOpenfolder {
    # GET /api/openfolder
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $target = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)['target']
        $recordsFolder = try {
            $c = Get-Content -LiteralPath $global:ConfigFilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($c.scrcpy -and $c.scrcpy.recordFolder) { [string]$c.scrcpy.recordFolder } else { $null }
        } catch { $null }
        $folderMap = @{
            'logs'    = (Join-Path $global:ScriptPath "logs")
            'config'  = (Join-Path $global:ScriptPath "config")
            'records' = $recordsFolder
        }
        $folder = $folderMap[$target]
        if ($folder -and [System.IO.Directory]::Exists($folder)) {
            Start-Process explorer.exe -ArgumentList "`"$folder`""
            Send-JsonResponse -Response $response -Body @{ ok = $true } -StatusCode 200
        } else {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'folder not found' } -StatusCode 200
        }
    } catch {
        Send-JsonResponse -Response $response -Body @{ ok = $false; error = $_.Exception.Message } -StatusCode 500
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/browse-folder  - opens native Windows folder picker, returns selected path
function Invoke-RouteBrowseFolder {
    # POST /api/browse-folder
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $tmp = [System.IO.Path]::GetTempFileName()
        $ps  = "Add-Type -AssemblyName System.Windows.Forms;" +
               "`$d = New-Object System.Windows.Forms.FolderBrowserDialog;" +
               "`$d.Description = 'Select recording folder';" +
               "`$d.ShowNewFolderButton = `$true;" +
               "if (`$d.ShowDialog() -eq 'OK') { [System.IO.File]::WriteAllText('$tmp', `$d.SelectedPath, [System.Text.Encoding]::UTF8) } " +
               "else { [System.IO.File]::WriteAllText('$tmp', '', [System.Text.Encoding]::UTF8) }"
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Command', $ps) -WindowStyle Hidden -Wait
        $chosen = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8).Trim()
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($chosen) {
            $escaped = $chosen.Replace('\','\\').Replace('"','\"')
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"path`":`"$escaped`"}")
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"cancelled":true,"path":""}')
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
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/config  - returns config.json content as JSON
function Invoke-RouteConfig {
    # GET /api/config
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $cfgFile = Join-Path $ScriptPath "config\config.json"
        if (Test-Path -LiteralPath $cfgFile) {
            # Read-ConfigFileText opens with Delete sharing; retried briefly so a read that
            # lands on a Write-ConfigJson swap does not hand the page an error.
            $raw = $null
            for ($cfgTry = 1; $cfgTry -le 5; $cfgTry++) {
                try { $raw = Read-ConfigFileText -Path $cfgFile; break }
                catch { if ($cfgTry -eq 5) { throw }; Start-Sleep -Milliseconds (50 * $cfgTry) }
            }
            # Strip UTF-8 BOM if present so JSON.parse() succeeds in the browser
            if ($raw -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
            $response.StatusCode = 200
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $response.StatusCode = 404
        }
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/config/defaults  - returns templates/config/config.json content as JSON
function Invoke-RouteConfigDefaults {
    # GET /api/config/defaults
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $tplFile = Join-Path $ScriptPath "templates\config\config.json"
        if (Test-Path -LiteralPath $tplFile) {
            $raw = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8
            if ($raw -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
            $response.StatusCode = 200
        } else {
            $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $response.StatusCode = 404
        }
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.Headers.Add('Access-Control-Allow-Origin', '*')
        $response.ContentLength64 = $respBytes.Length
        $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
    } catch {
        try {
            $eb = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $response.StatusCode = 500; $response.ContentType = 'application/json; charset=utf-8'
            $response.ContentLength64 = $eb.Length; $response.OutputStream.Write($eb, 0, $eb.Length)
        } catch {}
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/server-info  - returns server local IPs so the client can detect local access
function Invoke-RouteServerInfo {
    # GET /api/server-info
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $ips = @('127.0.0.1', 'localhost') + @($lanNetworks | ForEach-Object { $_.IPAddress })
        Send-JsonResponse -Response $response -Body @{ localIPs = $ips } -StatusCode 200
    } catch {
        Send-JsonResponse -Response $response -Body @{ localIPs = @('127.0.0.1', 'localhost') } -StatusCode 200
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: GET /api/gpu-list  - returns installed GPUs (index + model) via Get-GpuInfo,
# feeds the "Graphics Card" dropdown in vrhm_config.html (Performance.GPU_Index)
function Invoke-RouteGpuList {
    # GET /api/gpu-list
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $gpus = @(Get-GpuInfo) | ForEach-Object { @{ index = $_.Index; model = $_.Model } }
        Send-JsonResponse -Response $response -Body @{ ok = $true; gpus = @($gpus) }
    } catch {
        Send-JsonResponse -Response $response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
    } finally { Close-HttpResponse -Response $response }
    return
}

# API: POST /api/config/save  - validates and writes the posted JSON as config.json
function Invoke-RouteConfigSave {
    # POST /api/config/save
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    try {
        $body = Read-RequestBody -Request $request -Response $response -MaxBytes 1048576
        # Validate JSON before touching disk
        $newCfg = $body | ConvertFrom-Json
        $cfgFile = Join-Path $ScriptPath "config\config.json"

        # Snapshot the live-applicable mediamtx streaming fields against
        # the in-memory globals BEFORE writing. If any change, VRMonitor is
        # asked to restart mediamtx and the running captures (below) so the
        # new framerate / bitrate / re-encode flag / codec take effect
        # without an app restart.
        $oldFps      = $global:mediamtxFramerate
        $oldBw       = $global:mediamtxBitrate
        $oldReencode = [bool]$global:mediamtxReencode
        $oldCodec    = if ($global:mediamtxCodec) { $global:mediamtxCodec } else { 'h264' }
        $newFps      = $null; $newBw = $null; $newReencode = $false; $newCodec = 'h264'
        if ($newCfg -and $newCfg.mediamtx) {
            $newFps      = $newCfg.mediamtx.stream_framerate
            $newBw       = $newCfg.mediamtx.stream_bitrate
            $newReencode = [bool]$newCfg.mediamtx.reencode_in_ffmpeg
            $newCodec    = if ($newCfg.mediamtx.codec) { $newCfg.mediamtx.codec } else { 'h264' }
        }
        $streamingChanged = ($newFps -ne $oldFps) -or ($newBw -ne $oldBw) -or ($newReencode -ne $oldReencode) -or ($newCodec -ne $oldCodec)

        # Snapshot Capture Mode against the in-memory global BEFORE writing.
        # Performance.Capture_Mode is not live-applied by a plain config
        # write: the running captures must be restarted in the new mode
        # (and mediamtx when the LocalWindow boundary is crossed), which
        # the restart request below asks VRMonitor to do - the same thing
        # Set-CaptureMode does for the dedicated /api/capture-mode endpoint.
        $oldCaptureMode = $global:CaptureMode
        $newCaptureMode = $null
        if ($newCfg -and $newCfg.Performance) { $newCaptureMode = $newCfg.Performance.Capture_Mode }
        $captureModeChanged = $newCaptureMode -and ($newCaptureMode -ne $oldCaptureMode) -and ($newCaptureMode -in @('StreamOnly','StreamAndLocalWindow','LocalWindow'))

        # Snapshot of the capture settings (scrcpy section: view crops/angles, codec, buffers,
        # eye merge calibration) before and after: a running capture is built from them, and
        # the monitor would only notice a change on its next slow tick.
        if ($null -eq $newCfg) { throw "The posted configuration is empty." }

        # WiFi ADB modes (ADR-0037): refuse an invalid value instead of writing it, and remember
        # the section so THIS lane reloads its globals below when it changed (the other lane does
        # through ConfigGeneration; without the reload this lane kept resolving headsets with the
        # previous mode order).
        if (Get-Command Test-AdbWifiModeConfig -ErrorAction SilentlyContinue) {
            $adbErr = Test-AdbWifiModeConfig -Adb $newCfg.ADB
            if ($adbErr) {
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = $adbErr } -StatusCode 400
                return
            }
        }
        $newAdbSig = if ($newCfg.ADB) { ($newCfg.ADB | ConvertTo-Json -Depth 6 -Compress) } else { '' }
        $oldAdbSig = ''
        $oldCaptureSig = ''
        $newCaptureSig = if ($newCfg -and $newCfg.scrcpy) { ($newCfg.scrcpy | ConvertTo-Json -Depth 20 -Compress) } else { '' }

        # Snapshot read and write under the config lock, so another writer cannot slip in
        # between; the posted text is written as-is (atomic swap, UTF-8 without BOM).
        $saveLock = Enter-VqaLock -TimeoutMs 5000
        try {
            try {
                $oldCfgObj = Read-ConfigJson -ConfigFilePath $cfgFile -NonInteractive
                if ($oldCfgObj -and $oldCfgObj.scrcpy) { $oldCaptureSig = ($oldCfgObj.scrcpy | ConvertTo-Json -Depth 20 -Compress) }
                if ($oldCfgObj -and $oldCfgObj.ADB)    { $oldAdbSig     = ($oldCfgObj.ADB | ConvertTo-Json -Depth 6 -Compress) }
            } catch {}
            Write-ConfigJson -Object $body -Path $cfgFile
        } finally {
            if ($saveLock) { Exit-VqaLock -Stream $saveLock }
        }

        if ($oldAdbSig -ne $newAdbSig) {
            # The ADB section (WiFi ADB modes, classic port) changed: this lane's resolver follows
            # at once. VRMonitor notices on its next slow tick (Update-AdbWifiModeState).
            try { $null = Get-Config -ConfigFilePath $cfgFile } catch { }
        }

        if ($oldCaptureSig -ne $newCaptureSig) {
            # -NoMark: most of these edits (another model's view, a new view) restart nothing;
            # the watchdog marks a capture "starting" itself when it really restarts one.
            [void](Request-ScrcpyCheck -All -NoMark -Reason 'capture settings changed')
        }

        # Streams and mediamtx belong to VRMonitor (ADR-0032): this request only ASKS, in
        # ONE request (a second one written before VRMonitor's next 500 ms fast tick would
        # replace the first). VRMonitor reloads config, stops the running captures, restarts
        # mediamtx when the streaming fields changed (or the LocalWindow boundary was crossed:
        # its YAML differs) and starts the captures again - the ffmpeg push re-reads the new
        # framerate / bitrate / re-encode / codec globals, and the new mode applies. The
        # response no longer waits for it: mediamtx = a mediamtx restart was requested,
        # scrcpy = the headsets whose capture runs now and will be restarted, requested =
        # a restart request was written, pending = it could not be written.
        $restarted = @{ mediamtx = $false; scrcpy = @(); pending = $false; captureMode = $false; requested = $false }
        if ($streamingChanged -or $captureModeChanged) {
            # This process's globals (capture mode, streaming fields) follow the saved file.
            try { $null = Get-Config -ConfigFilePath $cfgFile } catch { }
            $crossedBoundary = $captureModeChanged -and (($oldCaptureMode -eq 'LocalWindow') -ne ($newCaptureMode -eq 'LocalWindow'))
            $wantMtx = [bool]($streamingChanged -or $crossedBoundary)
            $reasons = @()
            if ($streamingChanged)   { $reasons += 'mediamtx streaming settings changed' }
            if ($captureModeChanged) { $reasons += ("capture mode {0} -> {1}" -f $oldCaptureMode, $newCaptureMode) }
            $reqId = Request-StreamRestart -MediaMtx:$wantMtx -Reason ('config save: ' + ($reasons -join ', '))
            if ($reqId) {
                $restarted.requested   = $true
                $restarted.mediamtx    = $wantMtx
                $restarted.captureMode = [bool]$captureModeChanged
                $runningNames = @()
                foreach ($row in (Get-KnownHeadsetsCached)) {
                    if (Get-ScrcpyProcess -displayName (Convert-Displayname $row.Name) -headsetIP $row.IPAddress -headsetSerial $row.SerialNumber) { $runningNames += $row.Name }
                }
                $restarted.scrcpy = $runningNames
            } else {
                $restarted.pending = $true
                Write-Log "config/save: the stream restart request could not be written - restart the streams or the app." -Level WARNING
            }
        }
        $respObj = @{ ok = $true; restarted = $restarted }
        $respBytes = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Compress -Depth 4))
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

# API: POST /api/config/reset  - archives config.json with timestamp, copies template
function Invoke-RouteConfigReset {
    # POST /api/config/reset
    param([Parameter(Mandatory = $true)] $Context)
    $response = $Context.Response

    try {
        $cfgFile = Join-Path $ScriptPath "config\config.json"
        $tplFile = Join-Path $ScriptPath "templates\config\config.json"
        if (-not (Test-Path -LiteralPath $tplFile)) { throw "Template file not found" }
        $tplRaw = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8
        if ($null -eq ($tplRaw | ConvertFrom-Json)) { throw "Template file is empty" }
        $resetLock = Enter-VqaLock -TimeoutMs 5000
        try {
            if (Test-Path -LiteralPath $cfgFile) {
                $stamp   = Get-Date -Format 'yyyy.MM.dd-HH.mm'
                $cfgDir  = [System.IO.Path]::GetDirectoryName($cfgFile)
                $archive = Join-Path $cfgDir "config_$stamp.json"
                Copy-Item -LiteralPath $cfgFile -Destination $archive -Force
            }
            Write-ConfigJson -Object $tplRaw -Path $cfgFile
        } finally {
            if ($resetLock) { Exit-VqaLock -Stream $resetLock }
        }
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
