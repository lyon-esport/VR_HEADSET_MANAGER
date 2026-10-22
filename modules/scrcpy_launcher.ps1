
#################
# START SCREEN COPY
#################

<#
start-screenCopy -headsetIP 192.168.1.243 -adbPort 5555 -displayName "Quest 3 Manu"
$headsetIP = "192.168.1.243"
$displayName =  "Quest 3 Manu"
start-screenCopy -displayName $displayName -headsetIP $ip
#>

# Parse a scrcpy profile string into a typed object.
# Format: [view-]EYE-AUDIO-FPS-BW   (view defaults to 'portrait')
#   view  = portrait | square | wide | fullscreen  (fullscreen = crop 0:0:0:0, no angle)
#   EYE   = L | R | M                 (left eye, right eye, or M = both eyes merged - eye_merge.ps1)
#   AUDIO = D | N                     (audio-dup or no-audio)
#   FPS   = integer                   (max-fps)
#   BW    = integer Mbps              (bitrate)
# Returns @{ View; Eye; AudioDup; Fps; BitrateMbps; Raw } or $null on parse failure.
function ConvertFrom-ScrcpyProfile {
    param(
        [string]$Profile = 'portrait-R-N-45-20'
    )
    if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = 'portrait-R-N-45-20' }
    $parts = $Profile -split '-'

    # Backward compat: 4-part legacy format (Eye-Audio-FPS-BW) -> prepend "portrait"
    if ($parts.Count -eq 4 -and $parts[0] -in @('L','R','M')) {
        $parts = @('portrait') + $parts
    }
    if ($parts.Count -ne 5) { return $null }

    $fps = 0; $bw = 0
    if (-not [int]::TryParse([string]$parts[3], [ref]$fps)) { return $null }
    if (-not [int]::TryParse([string]$parts[4], [ref]$bw))  { return $null }

    return @{
        View        = $parts[0].ToLower()
        Eye         = $parts[1].ToUpper()
        AudioDup    = ($parts[2].ToUpper() -eq 'D')
        Fps         = $fps
        BitrateMbps = $bw
        Raw         = $Profile
    }
}


# Inverse of ConvertFrom-ScrcpyProfile. Builds the canonical "view-EYE-AUDIO-FPS-BW" string.
function ConvertTo-ScrcpyProfile {
    param(
        [string]$View = 'portrait',
        [ValidateSet('L','R','M')]
        [string]$Eye = 'R',
        [bool]$AudioDup = $false,
        [int]$Fps = 45,
        [int]$BitrateMbps = 20
    )
    $audio = if ($AudioDup) { 'D' } else { 'N' }
    return ("{0}-{1}-{2}-{3}-{4}" -f $View.ToLower(), $Eye.ToUpper(), $audio, $Fps, $BitrateMbps)
}


# Resolves the view to use for a NEW headset of the given model: the view
# flagged "default": true under scrcpy.parameters.<Model>.views (set from
# vrhm_config.html's "Manage Headset Profiles" star, or via
# Set-ScrcpyDefaultView in the console), else the first view defined for
# that model, else the literal 'square' when the model is blank/unknown or
# has no views (Model is often not known yet at headset-creation time).
function Get-ScrcpyDefaultView {
    param(
        [string]$Model
    )
    if (-not $Model -or -not $global:scrcpyParameters.$Model -or -not $global:scrcpyParameters.$Model.views) {
        return 'square'
    }
    $viewNames = @($global:scrcpyParameters.$Model.views | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
    if ($viewNames.Count -eq 0) { return 'square' }
    $starred = $viewNames | Where-Object { $global:scrcpyParameters.$Model.views.$_.default -eq $true } | Select-Object -First 1
    if ($starred) { return $starred }
    return $viewNames[0]
}


# Flags one view as the default for a model (clearing the flag on every
# other view of that model), persisted to the live config.json. Console
# counterpart of the star toggle in vrhm_config.html's "Manage Headset
# Profiles" modal, which persists the same "default": true key through the
# generic POST /api/config/save. Returns $true/$false.
function Set-ScrcpyDefaultView {
    param(
        [Parameter(Mandatory)] [string]$Model,
        [Parameter(Mandatory)] [string]$View
    )
    $cfgPath = Join-Path $global:ScriptPath 'config\config.json'
    $cfgLock = Enter-VqaLock -TimeoutMs 5000
    try {
        $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
        if (-not $cfg -or -not $cfg.scrcpy -or -not $cfg.scrcpy.parameters -or -not $cfg.scrcpy.parameters.$Model -or -not $cfg.scrcpy.parameters.$Model.views -or -not $cfg.scrcpy.parameters.$Model.views.$View) {
            Write-Log "Set-ScrcpyDefaultView: model '$Model' or view '$View' not found in config.json." -Level ERROR
            return $false
        }
        foreach ($vName in ($cfg.scrcpy.parameters.$Model.views.PSObject.Properties.Name)) {
            $isDefault = ($vName -eq $View)
            $viewObj = $cfg.scrcpy.parameters.$Model.views.$vName
            if ($viewObj.PSObject.Properties.Name -contains 'default') {
                $viewObj.default = $isDefault
            } elseif ($isDefault) {
                $viewObj | Add-Member -MemberType NoteProperty -Name 'default' -Value $true
            }
        }
        Write-ConfigJson -Object $cfg -Path $cfgPath -Depth 20
    } catch {
        Write-Log ("Set-ScrcpyDefaultView: failed to update config.json: " + $_.Exception.Message) -Level ERROR
        return $false
    } finally {
        if ($cfgLock) { Exit-VqaLock -Stream $cfgLock }
    }
    Get-Config -ConfigFilePath $cfgPath | Out-Null
    Write-Log ("Set-ScrcpyDefaultView: '{0}' is now the default view for model '{1}'." -f $View, $Model) -Level INFO
    return $true
}


# Captures ONE full, uncropped frame of a headset screen as a PNG - the reference image the
# visual view editor (vrhm_config.html, Headset Profiles) draws crop rectangles on. scrcpy has
# no screenshot option, so this records a few seconds with NO --crop / --angle / --max-size
# (native resolution = the coordinate system of the view crops) and extracts the last frame
# with ffmpeg. adb screencap is deliberately not used: on a headset it does not necessarily
# return the same image scrcpy captures, and the crop must be expressed in scrcpy's frame.
# Returns @{Ok;Path;Width;Height;Transport;Error}. Never throws.
# Example: Get-HeadsetScreenFrame -Headset (Get-HeadsetDiagTarget -Id 3)
function Get-HeadsetScreenFrame {
    param(
        [Parameter(Mandatory)] $Headset,
        [string]$OutFile,
        [ValidateRange(1, 15)] [int]$DurationSec = 3,
        [ValidateSet('Auto','USB','WiFi')] [string]$Transport = 'Auto'
    )
    $result = @{ Ok = $false; Path = $null; Width = 0; Height = 0; Transport = '-'; Error = $null }
    $tmpMkv = $null
    try {
        if (-not $OutFile) {
            $OutFile = Join-Path $global:ScriptPath ("website\generated\view_editor\headset_{0}.png" -f $Headset.ID)
        }
        $outDir = Split-Path -Path $OutFile -Parent
        # .NET call: New-Item has no -LiteralPath in PS 5.1 and the project root is accented.
        if (-not (Test-Path -LiteralPath $outDir)) { [void][System.IO.Directory]::CreateDirectory($outDir) }

        if (-not $global:scrcpyFilePath -or -not (Test-Path -LiteralPath $global:scrcpyFilePath)) {
            $result.Error = "scrcpy.exe not found at: $global:scrcpyFilePath"
            return $result
        }
        if (-not $global:ffmpegFilePath -or -not (Test-Path -LiteralPath $global:ffmpegFilePath)) {
            $result.Error = "ffmpeg.exe not found at: $global:ffmpegFilePath - install ffmpeg from the Advanced section of the configuration page."
            return $result
        }

        $device = Resolve-HeadsetAdbDevice -Headset $Headset -PreferTransport $Transport
        if (-not $device) {
            $result.Error = ("Headset '{0}' is not reachable over USB or WiFi ADB." -f $Headset.Name)
            return $result
        }
        $result.Transport = [string]$device.ConnectionType

        $tmpMkv = Join-Path ([System.IO.Path]::GetTempPath()) ("vrhm_frame_{0}_{1}.mkv" -f $Headset.ID, [guid]::NewGuid().ToString('N'))
        $scrcpyArgs = @('-s', $device.DeviceId, '--no-window', '--no-playback', '--no-audio',
                        '--video-codec=h264', "--record=`"$tmpMkv`"", '--record-format=mkv',
                        "--time-limit=$DurationSec")
        $tpl = if ($Headset.Model) { $global:scrcpyParameters.($Headset.Model) } else { $null }
        if ($tpl -and $tpl.video_encoder -and (-not $tpl.video_codec -or $tpl.video_codec -eq 'h264')) {
            $scrcpyArgs += ("--video-encoder={0}" -f $tpl.video_encoder)
        }

        Write-Log ("Get-HeadsetScreenFrame: capturing '{0}' over {1} ({2})" -f $Headset.Name, $result.Transport, $device.DeviceId) -Level INFO
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $global:scrcpyFilePath
        $psi.WorkingDirectory       = Split-Path -Path $global:scrcpyFilePath -Parent
        $psi.Arguments              = $scrcpyArgs -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $scrcpyErr = ''
        try {
            [void]$proc.Start()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(($DurationSec + 12) * 1000)) {
                try { $proc.Kill() } catch {}
                [void]$proc.WaitForExit(3000)
            }
            $scrcpyErr = ([string]$errTask.GetAwaiter().GetResult()) + ([string]$outTask.GetAwaiter().GetResult())
        } finally {
            $proc.Dispose()
        }

        if (-not (Test-Path -LiteralPath $tmpMkv) -or (Get-Item -LiteralPath $tmpMkv).Length -eq 0) {
            $tail = (@($scrcpyErr -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 4) -join ' | '
            $result.Error = "scrcpy produced no video. If a stream is already running for this headset, stop it and retry. scrcpy: $tail"
            Write-Log ("Get-HeadsetScreenFrame: {0}" -f $result.Error) -Level WARNING
            return $result
        }

        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        # Last frame first: the first one can still be a black/transition frame. -sseof needs the
        # duration scrcpy writes on a clean close, hence the first-frame fallback.
        & $global:ffmpegFilePath -hide_banner -loglevel error -y -sseof -1 -i $tmpMkv -frames:v 1 -update 1 $OutFile 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $OutFile)) {
            & $global:ffmpegFilePath -hide_banner -loglevel error -y -i $tmpMkv -frames:v 1 -update 1 $OutFile 2>$null | Out-Null
        }
        if (-not (Test-Path -LiteralPath $OutFile)) {
            $result.Error = 'ffmpeg could not extract a frame from the scrcpy recording.'
            return $result
        }

        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($OutFile)
        try { $result.Width = $img.Width; $result.Height = $img.Height } finally { $img.Dispose() }
        $result.Path = $OutFile
        $result.Ok   = $true
        Write-Log ("Get-HeadsetScreenFrame: '{0}' frame {1}x{2} saved to {3}" -f $Headset.Name, $result.Width, $result.Height, $OutFile) -Level INFO
    } catch {
        $result.Error = $_.Exception.Message
        Write-Log ("Get-HeadsetScreenFrame failed: {0}" -f $_.Exception.Message) -Level ERROR
    } finally {
        if ($tmpMkv -and (Test-Path -LiteralPath $tmpMkv)) { Remove-Item -LiteralPath $tmpMkv -Force -ErrorAction SilentlyContinue }
    }
    return $result
}


# Build the scrcpy argument string from a model template (config.json) and a per-headset profile.
# Profile format: [L/R]-[D/N]-FPS-BW  e.g. "R-N-45-20"
#   L/R = Left or Right eye  (selects crop + angle from model template)
#   D/N = audio-dup or no-audio
#   FPS = max-fps value
#   BW  = bitrate in Mbps
function ConvertTo-ScrcpyArguments {
    param(
        [string]$headsetModel,
        [string]$scrcpyProfile = "portrait-R-N-45-20",
        $modelTemplate = $null,
        # Lens position of the headset (IPD, mm) for a model with an `ipd` block; '' = the default one.
        [string]$ipd = ''
    )

    if ([string]::IsNullOrWhiteSpace($scrcpyProfile)) { $scrcpyProfile = "portrait-R-N-45-20" }
    $parts = $scrcpyProfile -split '-'

    # Backward compat: 4-part legacy format (Eye-Audio-FPS-BW) -> prepend "portrait"
    if ($parts.Count -eq 4 -and $parts[0] -in @('L','R','M')) {
        $parts = @('portrait') + $parts
    }

    if ($parts.Count -ne 5) {
        Write-Log ($msg.Scrcpy.InvalidProfile -f $scrcpyProfile) -Level WARNING
        $parts = @('portrait', 'R', 'N', '45', '20')
    }

    $viewName  = $parts[0].ToLower()  # e.g. portrait, square, wide
    $eye       = $parts[1].ToUpper()  # L, R or M (merged)

    # M = both eyes merged on the PC (eye_merge.ps1): scrcpy must send the FULL frame - no crop,
    # no angle, no max-size - and ffmpeg does the rest. When the merge cannot run (LocalWindow
    # capture mode has no ffmpeg, or the model has no enabled calibration) the profile falls back
    # to the RIGHT eye, the dominant eye of most people.
    $mergeFullFrame = $false
    if ($eye -eq 'M') {
        $mergeUse = Resolve-EyeMergeUse -Model $headsetModel -ScrcpyProfile ($parts -join '-') -Ipd $ipd
        if ($mergeUse.Use) {
            $mergeFullFrame = $true
        } else {
            $eye = 'R'
            $warnKey = "$headsetModel|$($mergeUse.Reason)"
            if (-not $script:EyeMergeFallbackWarned) { $script:EyeMergeFallbackWarned = @{} }
            if (-not $script:EyeMergeFallbackWarned.ContainsKey($warnKey)) {
                $script:EyeMergeFallbackWarned[$warnKey] = $true
                $why = if ($mergeUse.Reason -eq 'localwindow') { 'the LocalWindow capture mode has no ffmpeg stage' } else { "model '$headsetModel' has no enabled eye merge calibration" }
                Write-Log ("Merged view requested but {0} - using the right eye instead." -f $why) -Level WARNING
            }
        }
    }
    $audioPref = $parts[2].ToUpper()  # D=audio-dup, N=no-audio
    $fps       = $parts[3]            # e.g. 45
    $bw        = $parts[4]            # e.g. 20 (Mbps)

    if ($null -eq $modelTemplate) {
        $modelTemplate = Get-ModelTemplateForIpd -Model $headsetModel -Ipd $ipd
    }

    $audioArg = if ($audioPref -eq 'D') { "--audio-dup" } else { "--no-audio" }

    if ($null -eq $modelTemplate) {
        Write-Log $msg.Scrcpy.ModelUnknown -Level WARNING
        return "--max-fps=$fps -b ${bw}M $audioArg"
    }

    # Backward compat: if old flat-string format, return as-is
    if ($modelTemplate -is [string]) {
        return $modelTemplate
    }

    # New views-based format: look up named view, fall back to first available view
    $crop  = $null
    $angle = $null
    if ($modelTemplate.views) {
        $view = $modelTemplate.views.$viewName
        if (-not $view) {
            $firstKey = ($modelTemplate.views | Get-Member -MemberType NoteProperty | Select-Object -First 1).Name
            $view = $modelTemplate.views.$firstKey
            Write-Log ($msg.Scrcpy.InvalidProfile -f "view '$viewName' not found, using '$firstKey'") -Level WARNING
        }
        if ($view -and -not $mergeFullFrame) {
            $eyeObj = if ($eye -eq 'L') { $view.left_eye } else { $view.right_eye }
            if ($eyeObj) {
                $crop  = $eyeObj.crop
                $angle = $eyeObj.angle
            }
        }
    } elseif (-not $mergeFullFrame) {
        # Legacy flat template (crop_left/crop_right/angle_left/angle_right)
        $crop  = if ($eye -eq 'L') { $modelTemplate.crop_left  } else { $modelTemplate.crop_right  }
        $angle = if ($eye -eq 'L') { $modelTemplate.angle_left } else { $modelTemplate.angle_right }
    }

    $argParts = [System.Collections.Generic.List[string]]::new()
    if ($crop -and $crop -ne '0:0:0:0') { $argParts.Add("--crop $crop") }
    if ($null -ne $angle -and "$angle" -ne "" -and [int]"$angle" -ne 0) { $argParts.Add("--angle=$angle") }
    $argParts.Add("--max-fps=$fps")
    $argParts.Add("-b ${bw}M")
    # A merged view needs the native frame: the lookup tables are built for its exact size.
    if ($modelTemplate.max_size -and -not $mergeFullFrame) { $argParts.Add("--max-size=$($modelTemplate.max_size)") }
    if ($modelTemplate.video_codec)   { $argParts.Add("--video-codec=$($modelTemplate.video_codec)") }
    if ($modelTemplate.video_encoder -and $modelTemplate.video_encoder -ne "") { $argParts.Add("--video-encoder=$($modelTemplate.video_encoder)") }
    if ($modelTemplate.video_buffer)  {
        $argParts.Add("--video-buffer=$($modelTemplate.video_buffer)")
        $argParts.Add("--audio-buffer=$($modelTemplate.video_buffer)")
    }
    if ($modelTemplate.stay_awake -eq $true) { $argParts.Add("--stay-awake") }
    $argParts.Add($audioArg)

    return ($argParts -join ' ')
}

# Returns the running scrcpy process whose window title matches $displayName,
# or $null if none found. $displayName must be in window-title form (spaces -> underscores).
# Only considers processes launched from this app's scrcpy folder to avoid killing foreign scrcpy instances.
# -Census (Get-ProcessCensus): same matching, but the owned scrcpy list and the command lines come
# from that one snapshot instead of a Win32_Process query per untitled scrcpy. A census whose CIM
# query failed (Ok = $false) is ignored and the live lookup runs, as without -Census.
function Get-ScrcpyProcess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$displayName,
        [string]$headsetIP = '',
        # A USB launch carries -s <serial> instead of -s ip:port, so the serial identifies the
        # session just as well as the address does.
        [string]$headsetSerial = '',
        [hashtable]$Census = $null
    )
    $useCensus = ($null -ne $Census) -and $Census.Ok
    if ($useCensus) {
        # Skip a census entry that ended since the snapshot (HasExited reads the open handle, no query).
        $ownedProcs = @($Census.Scrcpy | Where-Object { try { -not $_.HasExited } catch { $true } })
    } else {
        $ownedProcs = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }
    }

    # Primary: match by window title (works when window is on the active virtual desktop)
    $byTitle = $ownedProcs | Where-Object { $_.MainWindowTitle -eq $displayName } | Select-Object -First 1
    if ($byTitle) { return $byTitle }

    # Fallback: match by command line - handles windows on inactive virtual desktops
    # where MainWindowTitle is empty. Requires either displayName or headsetIP in the cmdline.
    return $ownedProcs | Where-Object {
        if ($useCensus) {
            $entry   = $Census.ByPid[[int]$_.Id]
            $cmdLine = if ($entry) { $entry.CommandLine } else { $null }
        } else {
            $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue
            $cmdLine = $cimProc.CommandLine
            if ($cimProc) { $cimProc.Dispose() }
        }
        # Exact -s target / --window-title value (utils.ps1): a substring match let
        # 192.168.1.24 claim the session of 192.168.1.244, and Q3_RED the one of Q3_RED2.
        return (Test-ScrcpyCommandLineTarget -CommandLine $cmdLine -IPAddress $headsetIP `
                    -Serial $headsetSerial -DisplayName $displayName)
    } | Select-Object -First 1
}

function Get-ProcessCensus {
    <#
    .SYNOPSIS
    ONE Win32_Process query for the processes the app cares about (scrcpy, ffmpeg, mediamtx,
    powershell), taken once per VRMonitor slow tick (S3-4).

    .DESCRIPTION
    Returns @{ Ok; At; ByPid; Scrcpy }:
      ByPid  - hashtable [int]PID -> @{ Name; CommandLine; ParentProcessId; ExecutablePath }
      Scrcpy - the OWNED scrcpy processes (Get-Process objects, path under $global:scrcpyFolder,
               the same ownership rule as Get-ScrcpyProcess), so the window-title match still works.
    Ok = $false when the CIM query failed: consumers then fall back to their live lookup.
    A process started after the census is not in it; callers that start captures (start-screenCopy)
    keep their own live "already running" guard. Never throws.

    .EXAMPLE
    $census = Get-ProcessCensus
    Get-ScrcpyProcess -displayName 'Q3_RED' -headsetIP '192.168.1.244' -Census $census
    #>
    $census = @{ Ok = $false; At = (Get-Date); ByPid = @{}; Scrcpy = @() }
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop `
            -Filter "Name='scrcpy.exe' OR Name='ffmpeg.exe' OR Name='mediamtx.exe' OR Name='powershell.exe'")
        foreach ($r in $rows) {
            $census.ByPid[[int]$r.ProcessId] = @{
                Name            = [string]$r.Name
                CommandLine     = [string]$r.CommandLine
                ParentProcessId = [int]$r.ParentProcessId
                ExecutablePath  = [string]$r.ExecutablePath
            }
            $r.Dispose()
        }
        $census.Ok = $true
    } catch {
        Write-Log ("Get-ProcessCensus: Win32_Process query failed: " + $_.Exception.Message) -Level DEBUG
        return $census
    }
    $census.Scrcpy = @(Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
        Where-Object { $census.ByPid.ContainsKey([int]$_.Id) -and $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" })
    return $census
}

function Get-ScrcpyPidMap {
    <#
    .SYNOPSIS
    Headset ID -> scrcpy PID of every running capture, for the per-headset poll runspaces (S3-4).

    .DESCRIPTION
    Built from a Get-ProcessCensus snapshot with the Get-ScrcpyProcess matching rules (window
    title, -s ip:port, -s <serial>, display name in the command line), then completed with the
    pipelines THIS process started (live, no query), so a capture started after the census is
    listed too. VRMonitor publishes the result as $sharedState['_scrcpy_pids']; stage 1 of each
    poll runspace then only checks that PID with Get-Process -Id. Keys are the headset ID as a
    string, values [int] PIDs. Returns a NEW hashtable (never mutated after publishing).
    A census that failed (Ok = $false) gives $null: nothing reliable to publish.

    .EXAMPLE
    $sharedState['_scrcpy_pids'] = Get-ScrcpyPidMap -Census (Get-ProcessCensus) -KnownHeadsets @(Get-KnownHeadsets)
    #>
    param(
        [hashtable]$Census,
        [object[]]$KnownHeadsets = @()
    )
    if (-not $Census -or -not $Census.Ok) { return $null }
    $map = @{}
    foreach ($h in $KnownHeadsets) {
        if (-not $h -or -not $h.Name -or (Test-UnknownIp $h.IPAddress)) { continue }
        $safe = Convert-Displayname $h.Name
        $proc = $null
        # A pipeline this process started is authoritative and live: it also covers a capture the
        # watchdog restarted after the census was taken (the census still lists the old PID).
        if ($global:HeadsetPipelines -and $global:HeadsetPipelines.ContainsKey($safe)) {
            $sp = $global:HeadsetPipelines[$safe].ScrcpyProcess
            try { if ($sp -and -not $sp.HasExited) { $proc = $sp } } catch { }
        }
        if (-not $proc) {
            try { $proc = Get-ScrcpyProcess -displayName $safe -headsetIP $h.IPAddress -headsetSerial $h.SerialNumber -Census $Census } catch { }
        }
        if ($proc) { $map[[string]$h.ID] = [int]$proc.Id }
    }
    return $map
}

# -------------------------------------------------------------------
# Pipe-mode streaming pipeline (StreamOnly / StreamAndLocalWindow capture modes)
#
# Architecture: scrcpy records its H.264 stream to a Windows named pipe;
# ffmpeg reads from a paired pipe and pushes RTSP to mediamtx with -c copy.
# An in-process C# relay thread (VrhmPipeBridge, ADR-0035) acts as the named-pipe
# SERVER on both ends (scrcpy and ffmpeg both connect as CLIENTS), so the byte stream
# flows scrcpy -> pipeIn -> bridge -> pipeOut -> ffmpeg -> mediamtx without
# any re-encoding. CPU cost is near-zero compared to the legacy gdigrab+
# libx264 path.
#
# Per-headset state is tracked in $global:HeadsetPipelines keyed by the
# safe display name (spaces -> underscores), so Stop-Scrcpy can tear down
# the trio (scrcpy + bridge + ffmpeg) atomically.
# -------------------------------------------------------------------
if (-not (Get-Variable -Name HeadsetPipelines -Scope Global -ErrorAction SilentlyContinue)) {
    $global:HeadsetPipelines = @{}
}

# Pipeline health check (Get-HeadsetPipelineFaults, run by the slow-tick watchdog): a pipeline can
# break while its scrcpy keeps running - ffmpeg exits on a broken pipe when mediamtx restarts, the
# bridge thread ends - and the stream then answers 404 with nothing to restart it. Per safe display
# name: PathMisses = consecutive checks with the mediamtx path missing or not ready, Restarts =
# times of the automatic restarts (rate limit), GaveUpUntil = end of the current give-up period.
if (-not (Get-Variable -Name HeadsetPipelineHealth -Scope Global -ErrorAction SilentlyContinue)) {
    $global:HeadsetPipelineHealth = @{}
}
$script:PipelineHealthGraceSec    = 20   # no verdict this long after a pipeline start (publish takes a few s)
$script:PipelineHealthPathMisses  = 2    # a missing/unready path must be seen on this many checks in a row
$script:PipelineHealthMaxRestarts = 3    # automatic restarts allowed per headset...
$script:PipelineHealthWindowMin   = 5    # ...within this sliding window, then ERROR and wait

# Recording files that scrcpy (windowed LocalWindow mode) writes DIRECTLY, keyed by the safe display
# name, so they can be checked once the session is over. In the pipe modes ffmpeg writes the file and
# the path lives in $global:HeadsetPipelines[<name>].RecordFile instead.
if (-not (Get-Variable -Name DirectRecordings -Scope Global -ErrorAction SilentlyContinue)) {
    $global:DirectRecordings = @{}
}

# Machine-wide lock around the START of a scrcpy client (launch -> its server connected). On Windows
# several scrcpy clients started at the same moment can listen on the SAME local port (scrcpy's
# port range plus SO_REUSEADDR), and a headset's server then connects to another headset's client.
# Seen 2026-10-18 with two captures started in parallel by the capture workers (ADR-0036): Q2
# Dragon's server got "Connection refused" and its stream carried Q3 BLUE's picture (recording
# 1580x1580 instead of the 1408x1408 crop, 20 Mb/s twice instead of 20 + 6). Starts were safe before
# only because they were serial. A named mutex, so it also covers the benchmark job, the console and
# a second install on this PC. Returns the held mutex, or $null when it could not be taken within
# -TimeoutSec (the start then proceeds unlocked, WARNING). Pair with Exit-ScrcpyLaunchLock, on the
# SAME thread.
# Example: $lock = Enter-ScrcpyLaunchLock -Name 'Q3_RED'; try { ... } finally { Exit-ScrcpyLaunchLock -Lock $lock }
function Enter-ScrcpyLaunchLock {
    param([string]$Name = '', [int]$TimeoutSec = 30)
    $m = $null
    try {
        $m = New-Object System.Threading.Mutex($false, 'Global\VRHM_ScrcpyLaunch')
        $got = $false
        try { $got = $m.WaitOne($TimeoutSec * 1000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) { return $m }
        Write-Log ("scrcpy launch lock not obtained within {0} s for {1} - starting without it." -f $TimeoutSec, $Name) -Level WARNING
        $m.Dispose()
    } catch {
        Write-Log ("scrcpy launch lock unavailable for {0}: {1}" -f $Name, $_.Exception.Message) -Level WARNING
        if ($m) { try { $m.Dispose() } catch { } }
    }
    return $null
}

# Releases what Enter-ScrcpyLaunchLock returned ($null is fine). Never throws.
# Example: Exit-ScrcpyLaunchLock -Lock $lock
function Exit-ScrcpyLaunchLock {
    param($Lock)
    if (-not $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { }
    try { $Lock.Dispose() } catch { }
}

# Snapshot of a table's keys, safe while another runspace writes to it. In VRMonitor the capture
# tables ($global:HeadsetPipelines, DirectRecordings, ScrcpyLaunchState, EyeMergeRejected) are
# synchronized hashtables shared with the capture workers (S3-5 Step B): a single read or write
# is atomic, but ENUMERATING .Keys is not - a worker adding an entry mid-loop throws "Collection
# was modified". Copying under the table's SyncRoot (the lock its writes take) avoids that, and
# costs nothing for a plain hashtable. Returns @() for $null. Never throws.
# Example: foreach ($k in (Get-SyncTableKeys -Table $global:HeadsetPipelines)) { ... }
function Get-SyncTableKeys {
    param($Table)
    if ($null -eq $Table) { return @() }
    $keys = @()
    $locked = $false
    try {
        [System.Threading.Monitor]::Enter($Table.SyncRoot)
        $locked = $true
        $keys = @($Table.Keys)
    } catch {
    } finally {
        if ($locked) { [System.Threading.Monitor]::Exit($Table.SyncRoot) }
    }
    return $keys
}

function Complete-RecordingFile {
    <#
    .SYNOPSIS
    Checks a recording file once the session that wrote it has ended: deletes it if it is EMPTY
    (0 bytes), and warns if it is suspiciously small. Returns $true when a file was removed.

    .DESCRIPTION
    A recording file is created the moment a capture attempt starts, long before any video exists,
    and every restart attempt gets a NEW timestamped name. An attempt that fails right away - the
    cable pulled during a relaunch, a headset that has just gone to sleep - therefore leaves a
    0-byte .mkv behind. A real folder held four of them from one burst of restarts (plus a 1 KB
    one), and they look exactly like a broken recording the operator would waste time on.

    Only a 0-byte file is deleted: it provably holds nothing. A small but non-empty file is KEPT and
    flagged, because it might hold the only footage of something; the 64 KB threshold is far below
    a second of video at any bitrate this app uses, so it is a header with no usable picture.
    Never throws: this runs while sessions are being torn down.
    -Interrupted: the writer was force-killed - the catalogue row is marked 'interrupted' so the
    background repair (Update-RecordingRepair) rewrites its index and duration.

    .EXAMPLE
    Complete-RecordingFile -Path 'D:\Records\2026-10-05\Q3_BLUE\Q3_BLUE_20261005_101500.mkv' -Interrupted
    #>
    param([string]$Path, [switch]$Interrupted)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $false }
            $len = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
            if ($len -eq 0) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                Write-Log ("Removed an empty recording left by a capture attempt that never produced video: {0}" -f $Path) -Level INFO
                return $true
            }
            if ($len -lt 65536) {
                Write-Log ("Recording is very small ({0} bytes), probably without usable video: {1}" -f $len, $Path) -Level WARNING
            }
        } catch {
            Write-Log ("Complete-RecordingFile could not check '{0}': {1}" -f $Path, $_.Exception.Message) -Level DEBUG
        }
        return $false
    } finally {
        if (Get-Command Complete-RecordingEntry -ErrorAction SilentlyContinue) { try { [void](Complete-RecordingEntry -Path $Path -Interrupted:$Interrupted) } catch {} }
    }
}

function Complete-DirectRecording {
    <#
    .SYNOPSIS
    Runs Complete-RecordingFile on the file scrcpy was writing directly for one headset (windowed
    LocalWindow mode) and forgets it. Call it once that scrcpy process has exited.
    .EXAMPLE
    Complete-DirectRecording -SafeName 'Q3_BLUE'
    #>
    param([Parameter(Mandatory)][string]$SafeName)
    # The session is over: its LocalWindow launch stamp (Get-ScrcpyLaunchStamp) goes with it.
    if ($global:ScrcpyLaunchState) { $global:ScrcpyLaunchState.Remove($SafeName) }
    $path = $global:DirectRecordings[$SafeName]
    if (-not $path) { return }
    $global:DirectRecordings.Remove($SafeName)
    [void](Complete-RecordingFile -Path $path)
}

function Get-HeadsetPipeNames {
    param([Parameter(Mandatory)][string]$SafeName)
    return @{
        In  = "vrm_${SafeName}_in"
        Out = "vrm_${SafeName}_out"
    }
}

# In-process pipe bridge (ADR-0035, supersedes ADR-0003). scrcpy records into the named pipe
# vrm_<safe>_in and ffmpeg reads vrm_<safe>_out; both are pipe CLIENTS, so a server pair must sit
# between them. It used to be a Start-Job per stream (a whole powershell.exe, 60-100 MB, ~0.5-1 s
# to start, an interpreted 4 KB copy loop). It is now a C# class compiled once per process: one
# background thread per stream, in whichever process calls start-screenCopy (VRMonitor normally,
# the benchmark job or the console otherwise). Every wait of that thread also waits on a stop
# event, so Stop() works from ANY thread and returns at once; the thread is a background thread,
# so a dying process never waits for it and the OS closes both pipes (ffmpeg then sees EOF).
# Changing this C# source needs a restart of the process that compiled it (Add-Type cannot reload).
$script:PipeBridgeCsharp = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class VrhmPipeBridge
{
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenThread(uint access, bool inherit, uint threadId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetThreadTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    private const uint ThreadQueryLimitedInformation = 0x0800;

    private static readonly object RegistryLock = new object();
    private static readonly List<VrhmPipeBridge> LiveBridges = new List<VrhmPipeBridge>();
    private static double endedCpuSeconds = 0.0;

    private readonly NamedPipeServerStream srvIn;
    private readonly NamedPipeServerStream srvOut;
    private readonly ManualResetEvent stopEvent = new ManualResetEvent(false);
    private readonly int readSize;
    private readonly int inTimeoutMs;
    private readonly int outTimeoutMs;
    private readonly Thread thread;
    private IntPtr threadHandle = IntPtr.Zero;
    private long bytesCopied = 0;
    private volatile bool hasData = false;
    private volatile bool stopRequested = false;
    private volatile string state = "Running";
    private volatile string error = "";
    private int nativeThreadId = 0;

    public string Name { get; private set; }
    public string PipeIn { get; private set; }
    public string PipeOut { get; private set; }
    public DateTime StartedUtc { get; private set; }
    public DateTime EndedUtc { get; private set; }

    // Both pipe servers are created HERE, on the caller's thread: when the constructor returns
    // they exist (so scrcpy may open pipe-in), and a name still in use throws to the caller.
    public VrhmPipeBridge(string name, string pipeIn, string pipeOut, int pipeBufferBytes, int readBytes, int inTimeoutMs, int outTimeoutMs)
    {
        Name = name; PipeIn = pipeIn; PipeOut = pipeOut;
        this.readSize = Math.Max(4096, readBytes);
        this.inTimeoutMs = inTimeoutMs;
        this.outTimeoutMs = outTimeoutMs;
        srvIn = new NamedPipeServerStream(pipeIn, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, pipeBufferBytes, pipeBufferBytes);
        try
        {
            srvOut = new NamedPipeServerStream(pipeOut, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, pipeBufferBytes, pipeBufferBytes);
        }
        catch { srvIn.Dispose(); throw; }
        StartedUtc = DateTime.UtcNow;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Name = "VrmBridge_" + name;
        lock (RegistryLock) { LiveBridges.Add(this); }
        thread.Start();
    }

    public bool IsAlive { get { return thread.IsAlive; } }
    public bool Listening { get { return true; } }
    public bool HasData { get { return hasData; } }
    public string State { get { return state; } }
    public string Error { get { return error; } }
    public long BytesCopied { get { return Interlocked.Read(ref bytesCopied); } }
    public int NativeThreadId { get { return nativeThreadId; } }

    // CPU time used by this bridge's thread so far (kernel + user), in seconds.
    public double CpuSeconds { get { lock (RegistryLock) { return ReadCpuLocked(); } } }

    private double ReadCpuLocked()
    {
        if (threadHandle == IntPtr.Zero) { return 0.0; }
        long c, e, k, u;
        if (!GetThreadTimes(threadHandle, out c, out e, out k, out u)) { return 0.0; }
        return (k + u) / 1e7;
    }

    // Asks the thread to stop and waits at most joinMs for it (0 = do not wait). Never throws.
    public bool Stop(int joinMs)
    {
        stopRequested = true;
        try { stopEvent.Set(); } catch { }
        if (joinMs <= 0) { return !thread.IsAlive; }
        try { return thread.Join(joinMs); } catch { return false; }
    }

    // CPU seconds of every bridge this process ever ran (ended ones included), so a caller can
    // take deltas between two readings: the benchmark's "bridge" process entry.
    public static double TotalCpuSeconds()
    {
        lock (RegistryLock)
        {
            double sum = endedCpuSeconds;
            foreach (VrhmPipeBridge b in LiveBridges) { sum += b.ReadCpuLocked(); }
            return sum;
        }
    }

    public static int LiveCount() { lock (RegistryLock) { return LiveBridges.Count; } }

    // Stops every bridge of this process (shutdown safety net). Returns how many were asked.
    public static int StopAll(int joinMs)
    {
        VrhmPipeBridge[] all;
        lock (RegistryLock) { all = LiveBridges.ToArray(); }
        foreach (VrhmPipeBridge b in all) { b.Stop(0); }
        if (joinMs > 0)
        {
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(joinMs);
            foreach (VrhmPipeBridge b in all)
            {
                int left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                if (left <= 0) { break; }
                try { b.thread.Join(left); } catch { }
            }
        }
        return all.Length;
    }

    // Waits for h or the stop event. True only when h was signalled.
    private bool WaitOrStop(WaitHandle h, int timeoutMs)
    {
        int r = WaitHandle.WaitAny(new WaitHandle[] { h, stopEvent }, timeoutMs < 0 ? Timeout.Infinite : timeoutMs);
        return r == 0;
    }

    // One read: bytes read, 0 at end of stream, -1 when stopped.
    private int ReadOrStop(byte[] buf)
    {
        IAsyncResult ar = srvIn.BeginRead(buf, 0, buf.Length, null, null);
        if (!WaitOrStop(ar.AsyncWaitHandle, -1)) { return -1; }
        try { return srvIn.EndRead(ar); } catch (IOException) { return 0; }
    }

    // One write: false when stopped or when the reader (ffmpeg) is gone.
    private bool WriteOrStop(byte[] buf, int count)
    {
        IAsyncResult ar;
        try { ar = srvOut.BeginWrite(buf, 0, count, null, null); } catch (IOException) { return false; }
        if (!WaitOrStop(ar.AsyncWaitHandle, -1)) { return false; }
        try { srvOut.EndWrite(ar); } catch (IOException) { return false; }
        Interlocked.Add(ref bytesCopied, count);
        return true;
    }

    private void Run()
    {
        string endState = "Completed";
        try
        {
            nativeThreadId = (int)GetCurrentThreadId();
            IntPtr h = OpenThread(ThreadQueryLimitedInformation, false, (uint)nativeThreadId);
            lock (RegistryLock) { threadHandle = h; }
            // Accept both connections IN PARALLEL: waiting for pipe-in alone would let scrcpy
            // fill the pipe-in buffer and fail before ffmpeg could connect.
            IAsyncResult arIn = srvIn.BeginWaitForConnection(null, null);
            IAsyncResult arOut = srvOut.BeginWaitForConnection(null, null);
            if (!WaitOrStop(arIn.AsyncWaitHandle, inTimeoutMs))
            {
                endState = stopRequested ? "Stopped" : "Failed";
                if (!stopRequested) { error = "scrcpy did not open the input pipe in time"; }
                return;
            }
            srvIn.EndWaitForConnection(arIn);
            byte[] buf = new byte[readSize];
            // The first chunk (Matroska header + codec extradata) is read BEFORE ffmpeg connects
            // and written first once it has: nothing is lost or reordered.
            int first = ReadOrStop(buf);
            if (first < 0) { endState = "Stopped"; return; }
            // scrcpy opened the pipe and closed it without a byte: ffmpeg then reads an empty
            // input ("EBML header parsing failed"). Said here so the health fault names the cause.
            if (first == 0) { error = "scrcpy closed the input pipe before sending any data"; return; }
            hasData = true;
            if (!WaitOrStop(arOut.AsyncWaitHandle, outTimeoutMs))
            {
                endState = stopRequested ? "Stopped" : "Failed";
                if (!stopRequested) { error = "ffmpeg did not open the output pipe in time"; }
                return;
            }
            srvOut.EndWaitForConnection(arOut);
            if (!WriteOrStop(buf, first)) { endState = stopRequested ? "Stopped" : "Completed"; return; }
            while (true)
            {
                int n = ReadOrStop(buf);
                if (n < 0) { endState = "Stopped"; break; }
                if (n == 0) { break; }
                if (!WriteOrStop(buf, n)) { if (stopRequested) { endState = "Stopped"; } break; }
            }
        }
        catch (Exception ex)
        {
            endState = stopRequested ? "Stopped" : "Failed";
            if (!stopRequested) { error = ex.GetType().Name + ": " + ex.Message; }
        }
        finally
        {
            // Disposing the servers aborts any pending I/O and closes both pipes: ffmpeg sees EOF.
            try { srvIn.Dispose(); } catch { }
            try { srvOut.Dispose(); } catch { }
            lock (RegistryLock)
            {
                endedCpuSeconds += ReadCpuLocked();
                if (threadHandle != IntPtr.Zero) { CloseHandle(threadHandle); threadHandle = IntPtr.Zero; }
                LiveBridges.Remove(this);
            }
            EndedUtc = DateTime.UtcNow;
            state = endState;
        }
    }
}

// Copies a process's stderr lines to a log file from the .NET event thread (S3-5 Step B). It
// replaced Register-ObjectEvent -Action, whose action runs only in the runspace that registered
// it, and only while that runspace processes events: a capture started by a worker runspace
// that then went idle would stop draining ffmpeg's stderr, and ffmpeg blocks once that pipe is
// full. Attach right after Process.Start (it starts the async read); Dispose after CancelErrorRead.
// Same encoding as the writer it replaced (Encoding.UTF8, with a BOM).
public sealed class VrhmStderrSink : IDisposable
{
    private readonly StreamWriter writer;
    private readonly object gate = new object();
    private bool closed = false;

    private VrhmStderrSink(StreamWriter w) { writer = w; }

    public static VrhmStderrSink Attach(System.Diagnostics.Process process, string path)
    {
        StreamWriter w = new StreamWriter(path, false, new System.Text.UTF8Encoding(true));
        w.AutoFlush = true;
        VrhmStderrSink sink = new VrhmStderrSink(w);
        process.ErrorDataReceived += sink.OnData;
        process.BeginErrorReadLine();
        return sink;
    }

    private void OnData(object sender, System.Diagnostics.DataReceivedEventArgs e)
    {
        if (string.IsNullOrEmpty(e.Data)) { return; }
        lock (gate)
        {
            if (closed) { return; }
            try { writer.WriteLine(e.Data); } catch { }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (closed) { return; }
            closed = true;
            try { writer.Dispose(); } catch { }
        }
    }
}
'@

$script:PipeBridgePipeBufferBytes = 1048576   # kernel buffer of each pipe server (as the job had)
$script:PipeBridgeReadBytes       = 262144    # copy buffer (the job read 4 KB at a time)
$script:PipeBridgeInTimeoutSec    = 60        # scrcpy must open pipe-in within this
$script:PipeBridgeOutTimeoutSec   = 30        # ffmpeg must open pipe-out within this, after the first data

# Compiles VrhmPipeBridge once per process. $true when the type is available, $false (ERROR logged)
# when the compile failed. Example: if (Initialize-PipeBridgeType) { [VrhmPipeBridge]::LiveCount() }
function Initialize-PipeBridgeType {
    # Both classes come from the one source: a process that compiled an older source without
    # VrhmStderrSink keeps that type until it restarts (Add-Type cannot reload).
    if (('VrhmPipeBridge' -as [type]) -and ('VrhmStderrSink' -as [type])) { return $true }
    if ('VrhmPipeBridge' -as [type]) {
        Write-Log 'Pipe bridge: this process holds an older build of the relay helper (no VrhmStderrSink) - restart it.' -Level ERROR
        return $false
    }
    try {
        Add-Type -TypeDefinition $script:PipeBridgeCsharp -Language CSharp -ErrorAction Stop
        return $true
    } catch {
        Write-Log ("Pipe bridge: could not compile the relay helper: {0}" -f $_.Exception.Message) -Level ERROR
        return $false
    }
}

# Starts the in-process pipe bridge of one headset (ADR-0035): two named-pipe servers relaying
# bytes from In (scrcpy writes) to Out (ffmpeg reads) on a background thread. Returns the
# VrhmPipeBridge object (IsAlive, State, HasData, BytesCopied, CpuSeconds, Error). Throws when the
# helper cannot be compiled or a pipe name is still in use (start-screenCopy logs it and gives up).
# The bridge ends on its own when scrcpy disconnects, or after the 60 s / 30 s connect timeouts.
# Example: $b = Start-HeadsetPipeBridge -SafeName 'Q3_RED'
function Start-HeadsetPipeBridge {
    param(
        [Parameter(Mandatory)][string]$SafeName
    )
    if (-not (Initialize-PipeBridgeType)) { throw 'the pipe bridge helper could not be compiled' }
    $names = Get-HeadsetPipeNames -SafeName $SafeName
    return [VrhmPipeBridge]::new($SafeName, $names.In, $names.Out, $script:PipeBridgePipeBufferBytes,
        $script:PipeBridgeReadBytes, ($script:PipeBridgeInTimeoutSec * 1000), ($script:PipeBridgeOutTimeoutSec * 1000))
}

# Waits until the pipe bridge reports -Signal ('listening': both pipe servers exist, true as soon
# as Start-HeadsetPipeBridge returned; 'data': scrcpy wrote its first bytes, so ffmpeg can be
# started), polling every -PollMs for at most -TimeoutMs. Returns early (with $false) when the
# bridge ended, or when -Process (scrcpy) exited. The caller proceeds at the cap exactly as it did
# after the old fixed sleeps (S3-5). Returns $true when the signal was seen. Never throws.
# Example: Wait-HeadsetPipeBridgeSignal -Bridge $b -Signal 'data' -TimeoutMs 3000 -PollMs 100 -Process $scrcpyProc
function Wait-HeadsetPipeBridgeSignal {
    param(
        [Parameter(Mandatory)][Alias('Job')]$Bridge,
        [Parameter(Mandatory)][ValidateSet('listening','data')][string]$Signal,
        [int]$TimeoutMs = 1000,
        [int]$PollMs = 50,
        [System.Diagnostics.Process]$Process = $null
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            if ($Signal -eq 'listening' -and $Bridge.Listening) { return $true }
            if ($Signal -eq 'data' -and $Bridge.HasData) { return $true }
            if (-not $Bridge.IsAlive) { return $false }
            if ($Process) { try { if ($Process.HasExited) { return $false } } catch { } }
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
            Start-Sleep -Milliseconds $PollMs
        }
    } catch {
        Write-Log ("Wait-HeadsetPipeBridgeSignal: {0}" -f $_.Exception.Message) -Level DEBUG
        return $false
    } finally {
        $sw.Stop()
    }
}

# Stops one pipe bridge WITHOUT blocking the caller: signals its thread and waits at most -JoinMs
# (default 200) for it. The thread notices the stop at once (every wait includes the stop event),
# so the join is normally a few ms; a thread still running past it is a background thread that
# disposes both pipes as it ends. Callable from any thread. Logs the time taken. Never throws.
# Example: Stop-HeadsetPipeBridge -Bridge $entry.Bridge -SafeName 'Q3_RED'
function Stop-HeadsetPipeBridge {
    param(
        $Bridge,
        [Parameter(Mandatory)][string]$SafeName,
        [int]$JoinMs = 200
    )
    if (-not $Bridge) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ended = $false
    try { $ended = [bool]$Bridge.Stop($JoinMs) } catch { }
    $copied = 0
    try { $copied = [long]$Bridge.BytesCopied } catch { }
    Write-Log ("Stop-HeadsetPipeBridge: bridge of {0} stopped in {1} ms (ended={2}, {3} MB relayed)" -f $SafeName, $sw.ElapsedMilliseconds, $ended, [Math]::Round($copied / 1MB, 1)) -Level DEBUG
}

# Stops every pipe bridge of THIS process, tracked or not (shutdown safety net used by
# Stop-Scrcpy when it stops everything). Returns how many were stopped. Never throws.
# Example: Stop-AllHeadsetPipeBridges
function Stop-AllHeadsetPipeBridges {
    param([int]$JoinMs = 500)
    if (-not ('VrhmPipeBridge' -as [type])) { return 0 }
    try { return [int][VrhmPipeBridge]::StopAll($JoinMs) } catch { return 0 }
}

# CPU seconds used by every pipe bridge thread of THIS process since it started (ended bridges
# included), for delta measurements; 0 when no bridge was ever started. Never throws.
# Example: Get-HeadsetPipeBridgeCpuSeconds
function Get-HeadsetPipeBridgeCpuSeconds {
    if (-not ('VrhmPipeBridge' -as [type])) { return 0.0 }
    try { return [double][VrhmPipeBridge]::TotalCpuSeconds() } catch { return 0.0 }
}

# Quotes/escapes a single argument for ProcessStartInfo.Arguments (a single
# command-line string), following the same rules the Win32 CRT / CommandLineToArgvW
# parser expects: wrap in quotes if it contains whitespace or a quote, double any
# backslashes that immediately precede a quote (or the closing quote), and escape
# embedded quotes. Needed because ProcessStartInfo.ArgumentList is unavailable on
# some PowerShell 5.1 / .NET runtimes (evaluates to $null there).
function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Launches ffmpeg as a pipe-reader -> RTSP-publisher to mediamtx, and optionally
# a second output that writes the H.264 stream to a recording file. Both outputs
# use -c copy so the cost is one extra muxer (no re-encode).
function Start-FfmpegStreamPush {
    param(
        [Parameter(Mandatory)][string]$SafeName,
        [Parameter(Mandatory)][string]$RtspUrl,
        [string]$RecordFile = '',
        [string]$SourceCodec = 'h264',
        # Lookup tables from Get-EyeMergeMaps: merges both eyes of the full frame (forces the
        # re-encode path; the recording then holds the merged image too, through one tee output).
        [hashtable]$EyeMerge = $null,
        # Stream benchmark (stream_benchmark.ps1): ffmpeg writes frame/drop/dup/speed here once
        # per second (-progress). Empty for a normal stream.
        [string]$ProgressFile = ''
    )
    $names = Get-HeadsetPipeNames -SafeName $SafeName
    # One file PER SESSION (timestamped), never overwritten: a stream that keeps dying and
    # restarting used to leave only the LAST session's stderr, so the failing ones could not
    # be analysed - and a still-running previous ffmpeg held the shared file open, failing
    # the next start with "file in use". Get-LogSources' ffmpeg pattern still matches, and
    # Remove-OldLogFiles purges them on the usual retention.
    $logErr = Join-Path $global:logFolder ("{0}_{1}_ffmpegPush_stderr.txt" -f $SafeName, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $argList = [System.Collections.Generic.List[string]]::new()
    # Verbosity from config ffmpeg.log_level (default 'warning'). At 'info' and above ffmpeg
    # also logs its encoder setup and stream mapping, which is what a failing push needs.
    $ffLogLevel = if ($global:ffmpegLogLevel) { [string]$global:ffmpegLogLevel } else { 'warning' }
    $argList.AddRange([string[]]@('-hide_banner','-loglevel',$ffLogLevel))
    if ($ProgressFile) { $argList.AddRange([string[]]@('-stats_period','1','-progress',$ProgressFile)) }
    # Passthrough needs the bitstream filter matching the actual stream codec
    # (mkv/AVCC -> Annex-B for RTSP). An unrecognized codec cannot be safely
    # passed through - force re-encode for this stream so it doesn't die like
    # the h265-with-h264-filter bug this branch was fixed for.
    $forceReencode = $global:mediamtxReencode
    if ($EyeMerge) { $forceReencode = $true }   # a filtered stream cannot be passed through
    $passthroughArgs = $null
    if (-not $forceReencode) {
        $passthroughArgs = switch ($SourceCodec) {
            'h264'  { @('-bsf:v','h264_mp4toannexb') }
            'h265'  { @('-bsf:v','hevc_mp4toannexb','-tag:v','hvc1') }
            default {
                Write-Log ("Start-FfmpegStreamPush: unknown SourceCodec '{0}' for {1} - passthrough bitstream filter unknown, forcing re-encode for this stream" -f $SourceCodec, $SafeName) -Level ERROR
                $forceReencode = $true
                $null
            }
        }
    }
    # Low-latency input flags applied ONLY when we are going to re-encode. They
    # cut libavformat's default 5s analyzeduration / 5MB probesize down to the
    # minimum the matroska demuxer needs to identify the H.264 stream (without
    # this it cannot fulfil -map 0:v:0 and ffmpeg exits immediately). 100ms /
    # 32KB is enough in practice while still saving ~400-700ms vs the defaults.
    # -fflags +nobuffer + -flags low_delay disable libavformat's read-ahead and
    # frame-reorder delay. -avioflags direct is intentionally NOT used: it
    # bypasses I/O buffering for the named pipe which proved unstable.
    if ($forceReencode) {
        $argList.AddRange([string[]]@(
            '-fflags','+nobuffer','-flags','low_delay',
            '-analyzeduration','100000','-probesize','32768'))
    }
    $argList.AddRange([string[]]@('-f','matroska','-i',"\\.\pipe\$($names.Out)"))
    if ($EyeMerge) {
        $mergeArgs = Get-EyeMergeFfmpegArgs -Maps $EyeMerge
        $argList.AddRange([string[]]$mergeArgs.Inputs)
        $argList.AddRange([string[]]@('-filter_complex', $mergeArgs.Graph))
    }
    # Output 1: RTSP push into mediamtx. mediamtx remuxes this single source into
    # RTSP / HLS / WebRTC (WHEP) for downstream viewers, so re-encoding here caps
    # bandwidth on every viewer protocol (including the video_monitor web page).
    # The optional file recording output below stays -c copy regardless, so on-disk
    # captures keep source quality.
    if ($forceReencode) {
        if ($EyeMerge) {
            # A merged stream always encodes on the CPU, whatever GPU is selected. The merge (two
            # remaps + blend) runs on the CPU anyway, and benchmarks showed a hardware encoder gave
            # no gain there: handing the merged frames to the GPU kept the CPU just as busy (frame
            # upload / format conversion) while loading the GPU too. Every other stream keeps the
            # GPU encoder of Get-GpuEncoder.
            $cpuCodec = if ($global:mediamtxCodec -eq 'h265') { 'h265' } else { 'h264' }
            $enc = @{ Name = $(if ($cpuCodec -eq 'h265') { 'libx265' } else { 'libx264' }); Vendor = 'CPU'; ExtraArgs = @(); Codec = $cpuCodec }
            Write-Log ("Start-FfmpegStreamPush: merged stream of {0} encoded on the CPU ({1})" -f $SafeName, $enc.Name) -Level INFO
        } else {
            $enc = Get-GpuEncoder
        }
        $bw  = [string]$global:mediamtxBitrate
        # config.mediamtx.stream_bitrate is expected in "<n>M" form (see templates\config\config.json,
        # video_quality_automation.ps1's Set-VqaAutoApply/Restore-VqaOriginals writers). Guard against a
        # bare digit value (e.g. manually edited/saved without the unit) being passed straight to -b:v -
        # ffmpeg then interprets it as bits/sec, which is too low for the encoder to open at all.
        if ($bw -match '^\d+$') { $bw = "${bw}M" }
        $fps = $global:mediamtxFramerate
        # Short GOP (= framerate) so new WHEP subscribers receive a keyframe within
        # ~1s of joining. The per-encoder argument list itself lives in
        # Get-StreamEncoderArgs (modules\utils.ps1) so that Test-FfmpegEncoder probes
        # the exact same configuration this stream runs with - see the comments there.
        $gop = [string]$fps
        $encParams = Get-StreamEncoderArgs -EncoderName $enc.Name -Bitrate $bw -Gop $gop
        $rtspOut = [System.Collections.Generic.List[string]]::new()
        if ($EyeMerge) { $rtspOut.AddRange([string[]]@('-map','[vout]')) }
        else           { $rtspOut.AddRange([string[]]@('-map','0:v:0')) }
        # Hardware H.264 encoders (QSV, NVENC, AMF, MF) cannot open a frame wider or taller
        # than 4096 px. An uncapped capture (model max_size 0 with the 'fullscreen' view, i.e.
        # no crop) is the Quest 3's full native frame, wider than that: h264_qsv refused to
        # open ("Current resolution is unsupported"), ffmpeg exited before publishing, and
        # the watchdog restarted scrcpy in a loop with no stream ever reaching mediamtx.
        # HEVC encoders go to 8192, which is why only h264 failed. Scale down to fit, keeping
        # the aspect ratio and even dimensions; a frame already within 4096 is left as is.
        # (A merged output is always narrower than 4096 and comes from -filter_complex, where an
        # extra -vf would be rejected, so it skips this.)
        if ($enc.Name -like 'h264_*' -and -not $EyeMerge) {
            $rtspOut.AddRange([string[]]@('-vf', 'scale=w=min(iw\,4096):h=min(ih\,4096):force_original_aspect_ratio=decrease:force_divisible_by=2'))
        }
        $rtspOut.AddRange([string[]]$encParams)
        if ($enc.ExtraArgs -and $enc.ExtraArgs.Count -gt 0) { $rtspOut.AddRange([string[]]$enc.ExtraArgs) }
        # -flush_packets / -muxdelay / -muxpreload: tell the RTSP muxer to push
        # every packet immediately and not pre-buffer any startup interval.
        if ($EyeMerge -and $RecordFile) {
            # One encode, two destinations: the recording is the merged image the viewers see.
            # onfail=ignore keeps the stream alive if the disk fails. Forward slashes: the tee
            # muxer treats a backslash as an escape character. +global_header: Matroska behind a
            # tee needs the codec headers up front ("error writing header" without it).
            $teeTarget = "[f=rtsp:rtsp_transport=tcp]{0}|[f=matroska:onfail=ignore]{1}" -f $RtspUrl, ($RecordFile -replace '\\', '/')
            $rtspOut.AddRange([string[]]@('-flags','+global_header','-r',[string]$fps,'-pix_fmt','yuv420p',
                '-flush_packets','1','-muxdelay','0','-muxpreload','0','-f','tee',$teeTarget))
        } else {
            $rtspOut.AddRange([string[]]@('-r',[string]$fps,'-pix_fmt','yuv420p',
                '-pkt_size','1316','-flush_packets','1','-muxdelay','0','-muxpreload','0',
                '-f','rtsp','-rtsp_transport','tcp',$RtspUrl))
        }
        $argList.AddRange([string[]]$rtspOut.ToArray())
        Write-Log ("Start-FfmpegStreamPush: {0} re-encoding with {1} @ {2}fps / {3} (low-latency tuning on)" -f $SafeName, $enc.Name, $fps, $bw) -Level DEBUG
    } else {
        # Passthrough (Annex-B is required by mediamtx; MKV stores AVCC)
        $argList.AddRange([string[]](@('-map','0','-c','copy') + $passthroughArgs +
            @('-f','rtsp','-rtsp_transport','tcp',$RtspUrl)))
    }
    # Optional output 2: file recording (MKV/MP4 - ffmpeg picks from extension).
    # Passed unquoted - manually quoted/escaped below by ConvertTo-ProcessArgument,
    # same as every other path-bearing argument in this list (e.g. the -i pipe path).
    # Manually pre-quoting here would double-quote the value.
    if ($RecordFile -and -not $EyeMerge) {
        # -flush_packets 1: have the muxer hand data to the OS as soon as a Matroska cluster is
        # complete instead of leaving it in ffmpeg's buffer, so a kill loses the cluster in progress
        # rather than whatever was buffered. Measured at 8 Mbps: no CPU or memory difference and
        # about 15% more write calls (~4 per second, ~220 KB each) - it forces nothing to physical disk.
        $argList.AddRange([string[]]@('-map','0','-c','copy','-flush_packets','1','-y',$RecordFile))
    }
    # Started via raw Process/ProcessStartInfo (not Start-Process) so we retain a live,
    # writable StandardInput stream - needed to ask ffmpeg to quit gracefully ("q") on
    # stop, so it flushes/finalises the -c copy recording output instead of losing
    # buffered but unwritten data to a hard kill. RedirectStandardError must then be
    # drained asynchronously ourselves (Start-Process did this for us via its file
    # redirection) or ffmpeg can block once its stderr pipe buffer fills.
    # NOTE: ProcessStartInfo.ArgumentList is unusable here - on this host/PowerShell 5.1
    # runtime it evaluates to $null (pre-.NET-4.7.2 behavior of the loaded CLR), so
    # arguments are joined into a single quoted command-line string instead.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = $global:ffmpegFilePath
    $psi.Arguments = ($argList | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()

    # stderr -> log file on the .NET event thread (VrhmStderrSink), not Register-ObjectEvent: an
    # event action runs only in the runspace that registered it, so a capture started by a
    # worker runspace (S3-5 Step B) would stop draining stderr once that runspace went idle, and
    # ffmpeg blocks when the pipe is full. Start-HeadsetPipeBridge compiled the type already;
    # the check is for a caller that streams without a bridge.
    if (-not (Initialize-PipeBridgeType)) {
        try { $proc.Kill() } catch { }
        throw 'the stderr helper (VrhmStderrSink) is not available'
    }
    $errWriter = [VrhmStderrSink]::Attach($proc, $logErr)

    return @{
        Process              = $proc
        ErrorWriter          = $errWriter
        ErrorSubscriptionId  = $null
    }
}

# Sets the global capture mode, persists it to config.json, and asks VRMonitor to restart
# the running captures in the new mode (Request-StreamRestart). Used by the
# CLI Config sub-menu and the web settings page so the operator can toggle
# window visibility live without bouncing the app.
function Set-CaptureMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('StreamOnly','StreamAndLocalWindow','LocalWindow')]
        [string]$Mode
    )
    if ($global:CaptureMode -eq $Mode) {
        Write-Log ("CaptureMode unchanged ({0})" -f $Mode) -Level DEBUG
        return $true
    }
    $previous = $global:CaptureMode

    # Persist to config.json (the source of truth across restarts)
    $cfgPath = Join-Path $global:ScriptPath "config\config.json"
    $cfgLock = Enter-VqaLock -TimeoutMs 5000
    try {
        $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
        if (-not $cfg) { Write-Log "Set-CaptureMode: could not read config.json" -Level ERROR; return $false }
        if ($null -eq $cfg.Performance) {
            $cfg | Add-Member -NotePropertyName Performance -NotePropertyValue ([PSCustomObject]@{ GPU_Acceleration = $true; GPU_Index = 0; Capture_Mode = $Mode })
        } else {
            if ($cfg.Performance.PSObject.Properties.Name -contains 'Capture_Mode') {
                $cfg.Performance.Capture_Mode = $Mode
            } else {
                $cfg.Performance | Add-Member -NotePropertyName Capture_Mode -NotePropertyValue $Mode
            }
        }
        Write-ConfigJson -Object $cfg -Path $cfgPath -Depth 20
    } catch {
        Write-Log ("Set-CaptureMode: failed to update config.json: {0}" -f $_.Exception.Message) -Level ERROR
        return $false
    } finally {
        if ($cfgLock) { Exit-VqaLock -Stream $cfgLock }
    }
    $global:CaptureMode = $Mode

    # The captures belong to VRMonitor (ADR-0032), and this helper runs in the web server or the
    # console, so it only ASKS: VRMonitor reloads config (picking up the new mode), stops every
    # running capture, restarts mediamtx when the LocalWindow boundary was crossed (its YAML differs:
    # paths: {} vs all_others:), then restarts the captures in the new mode.
    $crossedBoundary = (($previous -eq 'LocalWindow') -ne ($Mode -eq 'LocalWindow'))
    [void](Request-StreamRestart -MediaMtx:$crossedBoundary -Reason ("capture mode {0} -> {1}" -f $previous, $Mode))

    Write-Log ("CaptureMode set to {0} (was {1}); VRMonitor restarts the captures now" -f $Mode, $previous) -Level SUCCESS
    return $true
}

# Tears down the bridge + ffmpeg push for one headset. Called by Stop-Scrcpy.
function Stop-HeadsetPipeline {
    param([Parameter(Mandatory)][string]$SafeName)
    $entry = $global:HeadsetPipelines[$SafeName]
    if (-not $entry) { return }
    $forcedKill = $false
    if ($entry.FfmpegProcess) {
        $ff = $entry.FfmpegProcess
        try {
            if ($ff.HasExited) {
                # ffmpeg died on its own before this stop (a broken RTSP pipe when mediamtx restarted,
                # a crash): a failed ffmpeg does not write the recording's index, so the file is
                # handled like a forced kill and repaired in the background.
                $code = 0
                try { $code = [int]$ff.ExitCode } catch { }
                if ($code -ne 0 -and $entry.RecordFile) {
                    $forcedKill = $true
                    Write-Log ("Stop-HeadsetPipeline: ffmpeg for {0} had already exited with code {1}. The recording '{2}' may lack its index; it is repaired automatically in the background (Recordings catalogue)." -f $SafeName, $code, $entry.RecordFile) -Level INFO
                }
            } else {
                # Ask ffmpeg to quit gracefully ("q" on stdin) so the -c copy recording
                # output gets flushed/finalised instead of losing buffered frames to a
                # hard kill. Only force-kill if it doesn't exit within the timeout.
                try {
                    $ff.StandardInput.WriteLine('q')
                    $ff.StandardInput.Flush()
                    $ff.StandardInput.Close()
                } catch {}
                # 15 s, not 5: finalising the recording (index, flush of a multi-GB file on a disk that
                # OBS may be writing to at the same time) can legitimately take longer than 5 s, and a
                # kill in that window is what leaves a recording without its index.
                # Without a recording there is nothing to finalise, so waiting buys nothing and only
                # delays the next start (a restart waits here before launching scrcpy again): 2 s.
                $graceMs = if ($entry.RecordFile) { 15000 } else { 2000 }
                if (-not $ff.WaitForExit($graceMs)) {
                    $forcedKill = $true
                    if ($entry.RecordFile) {
                        Write-Log ("Stop-HeadsetPipeline: ffmpeg for {0} did not exit gracefully within 15 s - forcing kill. The recording '{1}' lacks its index; it stays playable and is repaired automatically in the background (Recordings catalogue)." -f $SafeName, $entry.RecordFile) -Level WARNING
                    } else {
                        # Nothing is lost: no recording on this stream, the live stream was being stopped anyway.
                        Write-Log ("Stop-HeadsetPipeline: ffmpeg for {0} did not exit within {1} s after 'q' - forcing kill (no recording on this stream)." -f $SafeName, [int]($graceMs / 1000)) -Level INFO
                    }
                    try { Stop-Process -Id $ff.Id -Force -ErrorAction SilentlyContinue } catch {}
                    try { [void]$ff.WaitForExit(3000) } catch {}
                }
            }
        } catch {}
        try { $ff.CancelErrorRead() } catch {}
    }
    # ffmpeg is gone: check what it left behind (empty file from an attempt that never got video).
    if ($entry.RecordFile) { [void](Complete-RecordingFile -Path $entry.RecordFile -Interrupted:$forcedKill) }
    if ($entry.FfmpegErrorSubId) {
        try { Unregister-Event -SubscriptionId $entry.FfmpegErrorSubId -ErrorAction SilentlyContinue } catch {}
    }
    if ($entry.FfmpegErrorWriter) {
        try { $entry.FfmpegErrorWriter.Dispose() } catch {}
    }
    if ($entry.Bridge) {
        # Signals the in-process bridge thread and returns at once (never blocks the caller).
        Stop-HeadsetPipeBridge -Bridge $entry.Bridge -SafeName $SafeName
    }
    $global:HeadsetPipelines.Remove($SafeName)
}

function start-screenCopy {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,

        [string]$displayName = [string]$headsetIP,

        [boolean]$recording = $false,

        [int]$adbPort = $global:adbPort_default,

        [string]$scrcpyProfile = "R-N-45-20",

        # Which ADB transport to capture over. Auto follows config ADB.prefer_usb: USB (-s <serial>)
        # when the headset is cabled to this PC, WiFi (-s ip:port) otherwise. The watchdog passes
        # WiFi explicitly only when it must not interrupt a session (never today); every other
        # caller leaves it on Auto.
        [ValidateSet('Auto','USB','WiFi')]
        [string]$transport = 'Auto',

        # Stream benchmark only: passed to Start-FfmpegStreamPush -ProgressFile.
        [string]$ffmpegProgressFile = ''

    )

    $displayName =  Convert-Displayname($displayName)

    # Guard: skip if a scrcpy window for this headset is already running
    if (Get-ScrcpyProcess -displayName $displayName) {
        # No sleep here (S3-5): this used to wait 5 s, which froze the caller (the VRMonitor loop)
        # for nothing - the guard alone prevents the second instance, and every caller runs at most
        # once per tick. Say whether this process owns the session, for diagnosis.
        $owned = ($global:HeadsetPipelines -and $global:HeadsetPipelines.ContainsKey($displayName)) -or
                 ($global:ScrcpyLaunchState -and $global:ScrcpyLaunchState.ContainsKey($displayName))
        Write-Log -Message ($msg.Scrcpy.AlreadyRunning -f $displayName) -Level WARNING
        Write-Log ("start-screenCopy: {0} already running, session owned by this process: {1}" -f $displayName, [bool]$owned) -Level DEBUG
        return
    }

    $adb = $global:adbPath
    $scrcpy = $global:scrcpyFilePath

    # A previous windowed (LocalWindow) session for this headset is over: check the file it wrote.
    Complete-DirectRecording -SafeName $displayName

    # Pick the transport. The registry row supplies the serial number the USB transport is
    # keyed on; a caller that only has an address still works, it just never gets USB.
    # Resolve-HeadsetAdbDevice replaces the old port probe + "adb connect" for the WiFi case
    # (Get-AdbWifiDevice does both) and costs no adb.exe at all for the USB case.
    $knownRow = @(Get-KnownHeadsets) | Where-Object { $_.IPAddress -eq $headsetIP } | Select-Object -First 1
    if (-not $knownRow) { $knownRow = [PSCustomObject]@{ Name = $displayName; IPAddress = $headsetIP; SerialNumber = '' } }

    # Tell every page this capture is starting (app_kv, cross-process). The mark is cleared in the
    # finally below on EVERY exit - a failed start must not keep announcing one - and on success
    # it is held a few more seconds: the stream reaches mediamtx about a second after the pipeline
    # is up, and the indicator must not vanish before the picture appears.
    $startingId = 0
    if ($knownRow.PSObject.Properties['ID']) { [void][int]::TryParse([string]$knownRow.ID, [ref]$startingId) }
    if ($startingId -gt 0) { Set-ScrcpyStartingState -HeadsetId $startingId }
    $startHoldSec = 0
    try {

    $captureDevice = $null
    try {
        Write-Log -Message ($msg.Scrcpy.CheckingAdb -f "$headsetIP`:$adbPort") -Level "INFO"
        $captureDevice = Resolve-HeadsetAdbDevice -Headset $knownRow -PreferTransport $transport -AdbPort $adbPort
    } catch {
        Write-Log -Message ($msg.Scrcpy.ExecError -f $_.Exception.Message) -Level "ERROR"
		return
    }


	$options = ""
    if (-not $captureDevice) {
        # Neither USB nor WiFi answered: same outcome as the old "ADB port closed" exit.
        Write-Log -Message ($msg.AdbPortNotResponding -f $adbPort) -Level WARNING
        return
    }
    $adb_device = $captureDevice.DeviceId
    # WiFi mode of the capture (ADR-0034): 'Classic' / 'TLS', '' over USB. Stored with the launch
    # state for diagnosis; the restart decision still keys on Transport (USB/WiFi) only.
    $launchWifiMode = if ($captureDevice.ConnectionType -eq 'WiFi' -and $captureDevice.PSObject.Properties['WifiMode']) { [string]$captureDevice.WifiMode } else { '' }
    Write-Log ("scrcpy capture for {0} over {1}{2} ({3})" -f $displayName, $captureDevice.ConnectionType, $(if ($launchWifiMode) { " $launchWifiMode" } else { '' }), $adb_device) -Level INFO
    $headsetModel   = Get-HeadsetModel -Device $captureDevice
    Write-Log -Message ($msg.Scrcpy.ModelDetected -f $headsetModel) -Level "INFO"
    $modelTemplate  = $global:scrcpyParameters.$headsetModel
    $sourceCodec    = if ($modelTemplate -and $modelTemplate.video_codec) { $modelTemplate.video_codec } else { 'h264' }
	<#
    if ($adb_model -like "Quest 2") {
		#$options = "--crop=1550:1250:2000:280 --max-size=800 --video-bit-rate=10M --max-fps 60 --video-buffer=50 --video-codec=h265" #Oeil droit
        $options = "-b10m --max-fps 60 --video-buffer=50 --video-codec=h265" #Oeil droit
	} elseif ($adb_model -like "Quest 3") {
		#crop = "1700:1200:250:500"
        #$options = "--crop=1664:1304:2260:450 --angle=-21 --max-size=800 --video-bit-rate=10M --max-fps=30 --video-codec=h265" #  --video-encoder=OMX.qcom.video.encoder.avc " #Oeil droit  --video-buffer=100
        #$options = "-b10m --max-fps=60 --video-codec=h264" #Oeil droit  --video-buffer=100
        $options = " -b20m --max-fps=30 --video-codec=h264 --video-buffer=100" #  --video-encoder=OMX.qcom.video.encoder.avc " #Oeil droit  --video-buffer=100
	}
    #>



    # Lens position (IPD) of this headset: the views and the merge calibration follow it (ADR-0030).
    $lensIpd = if ($startingId -gt 0) { Get-HeadsetIpdValue -HeadsetId $startingId -Model $headsetModel } else { '' }
    $options = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $scrcpyProfile -ipd $lensIpd

    # Merged view (eye M): the lookup tables are built for one exact frame size, so check the
    # headset really sends that size, then build (or reuse) the tables. Any failure falls back to
    # the right eye for this calibration/view (Set-EyeMergeRejected) instead of streaming garbage.
    $eyeMergeMaps = $null
    $eyeMergeKey  = ''
    $mergeUse = Resolve-EyeMergeUse -Model $headsetModel -ScrcpyProfile $scrcpyProfile -Ipd $lensIpd
    if ($mergeUse.Use) {
        $mergeProfile = Get-EyeMergeProfile -Model $headsetModel -Ipd $lensIpd
        $display = Get-HeadsetDisplaySize -Device $captureDevice
        if ($display -and ($display.Width -ne [int]$mergeProfile.frame_width -or $display.Height -ne [int]$mergeProfile.frame_height)) {
            Set-EyeMergeRejected -Model $headsetModel -Key $mergeUse.Key -Reason ("display is {0}x{1}, calibration expects {2}x{3}" -f $display.Width, $display.Height, $mergeProfile.frame_width, $mergeProfile.frame_height)
        } else {
            $eyeMergeMaps = Get-EyeMergeMaps -Model $headsetModel -View $mergeUse.View -Ipd $lensIpd
            if ($eyeMergeMaps.Ok) {
                $eyeMergeKey = $mergeUse.Key
                Write-Log ("Merged view for {0}: {1}x{2} crop {3}" -f $displayName, $eyeMergeMaps.Width, $eyeMergeMaps.Height, $eyeMergeMaps.Crop) -Level INFO
            } else {
                Set-EyeMergeRejected -Model $headsetModel -Key $mergeUse.Key -Reason $eyeMergeMaps.Error
                $eyeMergeMaps = $null
            }
        }
        if (-not $eyeMergeMaps) {
            $options = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $scrcpyProfile -ipd $lensIpd
        }
    }

    # Check that scrcpy exists
    if (-not (Test-Path -LiteralPath $scrcpy)) {
        Write-Log -Message ($msg.Scrcpy.NotFound -f $scrcpyPath) -Level "ERROR"
        return
    }

    # Check if recording is enabled
    if ($recording) {
        $timestamp_Today = Get-Date -Format "yyyy-MM-dd"
        $recordFolder = Join-Path -Path $global:scrcpyRecordFolder -ChildPath ("${timestamp_Today}\${displayName}")

        if (-not (Test-Path -LiteralPath $recordFolder)) {
            New-Item -ItemType Directory -Path $recordFolder -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $recordFile = Join-Path -Path $recordFolder -ChildPath "${displayName}_$timestamp.mkv"
        $recordOption = "--record=`"$recordFile`""
        Write-Log -Message ($msg.Scrcpy.Recording -f $recordFile) -Level "INFO"
    } else {
        $recordOption = ""
        $recordFile = ''
    }
    # Dispatch on capture mode:
    #   StreamOnly          -> --no-window + record-to-pipe + ffmpeg push to RTSP
    #   StreamAndLocalWindow-> visible window + record-to-pipe + ffmpeg push to RTSP (no GDI)
    #   LocalWindow         -> visible window only, no streaming pipeline (file recording via scrcpy)
    # Re-read the device id: a USB transport failure inside Get-HeadsetModel /
    # Get-HeadsetDisplaySize makes Invoke-AdbCmd switch $captureDevice to WiFi IN PLACE
    # (ADR-0024), and launching scrcpy with the dead serial costs a failed start + restart.
    if ($captureDevice.DeviceId -and $captureDevice.DeviceId -ne $adb_device) {
        Write-Log ("scrcpy capture for {0} moved to {1} ({2}) after a transport failure" -f $displayName, $captureDevice.ConnectionType, $captureDevice.DeviceId) -Level INFO
        $adb_device = $captureDevice.DeviceId
    }
    $captureMode = if ($global:CaptureMode) { $global:CaptureMode } else { 'StreamOnly' }
    $usePipe = ($captureMode -in @('StreamOnly','StreamAndLocalWindow'))

    # Desired-state stamp of this launch (after the merge block, so a rejected merge gives the same
    # key the watchdog will compute). Stored with the session; the watchdog compares stamps instead
    # of parsing scrcpy's command line.
    $launchStamp = Get-ScrcpyLaunchStamp -Model ([string]$headsetModel) -ScrcpyProfile $scrcpyProfile -Ipd $lensIpd -Recording ([bool]$recording) -CaptureMode $captureMode
    $launchTransport = [string]$captureDevice.ConnectionType

    if ($captureMode -eq 'LocalWindow') {
        # No streaming - GPU SDL is fine here. File recording (if any)
        # uses scrcpy's native --record directly.
        $arguments = "-s $adb_device $options --window-title=$displayName $recordOption"
    } else {
        $names    = Get-HeadsetPipeNames -SafeName $displayName
        # Pipe mode forces periodic IDR frames so late RTSP subscribers can start decoding immediately.
        $pipeArgs = "--record=\\.\pipe\$($names.In) --record-format=mkv --video-codec-options=i-frame-interval=1"
        if ($captureMode -eq 'StreamOnly') { $pipeArgs += " --no-window --no-playback" }
        # In window-visible mode, prefer GPU SDL rendering when GPU is on.
        $renderArg = if ($captureMode -eq 'StreamAndLocalWindow' -and -not $global:GPU_Acceleration) { "--render-driver=software" } else { "" }
        # In pipe mode scrcpy can only have ONE --record target (the pipe), so we
        # do not pass the file-record option here. ffmpeg writes the recording
        # file as a second -c copy output below.
        $arguments = "-s $adb_device $options --window-title=$displayName $renderArg $pipeArgs"
    }
    # Verbosity from config scrcpy.log_level (default 'info' = scrcpy's own default, so no
    # flag is added). It is part of the launch stamp (Get-ScrcpyLaunchStamp), so a change restarts the session.
    if ($global:scrcpyLogLevel -and $global:scrcpyLogLevel -ne 'info') {
        $arguments += " --verbosity=$($global:scrcpyLogLevel)"
    }
    #.\scrcpy.exe --crop 1664:1304:2260:450 --angle=-21 --max-fps 45 -b 16M --no-audio --video-buffer=100 --video-codec=h264 --video-encoder=OMX.qcom.video.encoder.avc -s $adb_device
    #.\sources\scrcpy-win64-v3.3\scrcpy.exe -s 192.168.1.243:5555 -b20m --crop=1664:1304:2260:450 --angle=-21 --max-size=800 --max-fps=30 --video-codec=h265 --no-audio --window-title=Q3_BLUE

	Write-Log -Message ($msg.Scrcpy.Launching -f $arguments) -Level "SUCCESS"

    # Pipe modes: start the bridge BEFORE scrcpy so the pipe-in server is listening.
    # Defensively clear any leftover pipeline entry first - if a previous scrcpy died
    # but its bridge or ffmpeg push was still tracked, the named-pipe server names
    # would still be in use and a fresh bridge would fail to create.
    $bridge = $null
    if ($usePipe) {
        Stop-HeadsetPipeline -SafeName $displayName
        try {
            $bridge = Start-HeadsetPipeBridge -SafeName $displayName
            # The in-process bridge creates both pipe servers before Start-HeadsetPipeBridge
            # returns, so 'listening' is immediate; the wait stays as a cheap sanity check.
            $bridgeWait = [System.Diagnostics.Stopwatch]::StartNew()
            $bridgeReady = Wait-HeadsetPipeBridgeSignal -Bridge $bridge -Signal 'listening' -TimeoutMs 1000
            Write-Log ("start-screenCopy: pipe bridge for {0} listening={1} after {2} ms" -f $displayName, $bridgeReady, $bridgeWait.ElapsedMilliseconds) -Level DEBUG
        } catch {
            Write-Log -Message ("Failed to start pipe bridge for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            return
        }
    }

    # Per-session scrcpy logs (same reason as the ffmpeg one in Start-FfmpegStreamPush): a
    # restart must not overwrite the output of the session that just failed.
    $sessionStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    # Held until this scrcpy's server has connected (first data, or a window): see Enter-ScrcpyLaunchLock.
    $launchLock = Enter-ScrcpyLaunchLock -Name $displayName
    try {
        $scrcpyProc = Start-Process $scrcpy -ArgumentList $arguments -PassThru -NoNewWindow `
			-RedirectStandardOutput (Join-Path -Path $global:logFolder -ChildPath ("{0}_{1}_StandardOutput.txt" -f $displayName, $sessionStamp)) `
			-RedirectStandardError  (Join-Path -Path $global:logFolder -ChildPath ("{0}_{1}_StandardError.txt" -f $displayName, $sessionStamp))
	} catch {
        Write-Log -Message ($msg.Scrcpy.LaunchError -f $_.Exception.Message) -Level "ERROR"
        Exit-ScrcpyLaunchLock -Lock $launchLock
        if ($bridge) { Stop-HeadsetPipeBridge -Bridge $bridge -SafeName $displayName }
		return
    }

    # scrcpy is launched. LocalWindow has no pipeline to wait for: its window is the result.
    if (-not $usePipe) {
        # Window mode has no pipe to watch: the lock is held until the window exists (at most 6 s).
        $winWait = [System.Diagnostics.Stopwatch]::StartNew()
        while ($winWait.ElapsedMilliseconds -lt 6000) {
            try { $scrcpyProc.Refresh(); if ($scrcpyProc.HasExited -or $scrcpyProc.MainWindowHandle -ne [IntPtr]::Zero) { break } } catch { break }
            Start-Sleep -Milliseconds 100
        }
        Exit-ScrcpyLaunchLock -Lock $launchLock; $launchLock = $null
        $startHoldSec = 2
        $global:ScrcpyLaunchState[$displayName] = @{ LaunchStamp = $launchStamp.Stamp; StampParts = $launchStamp.Parts; Transport = $launchTransport; WifiMode = $launchWifiMode }
    }

    # Windowed LocalWindow mode: scrcpy itself writes the recording. Remember the file so it can be
    # checked once the session is over (Complete-DirectRecording).
    if (-not $usePipe -and $recordFile) { $global:DirectRecordings[$displayName] = $recordFile }
    # Recordings catalogue (ADR-0029): one row per recorded session, closed by Complete-RecordingFile.
    if ($recordFile -and (Get-Command Register-RecordingStart -ErrorAction SilentlyContinue)) {
        try {
            $catalogFile = if ($usePipe) { [System.IO.Path]::ChangeExtension($recordFile, '.mkv') } else { $recordFile }
            [void](Register-RecordingStart -Headset $knownRow -RecordFile $catalogFile -ScrcpyProfile $scrcpyProfile -CaptureMode $captureMode -EyeMerge ([bool]$eyeMergeMaps) -SafeName $displayName)
        } catch { Write-Log ("Recordings catalogue: could not register {0}: {1}" -f $recordFile, $_.Exception.Message) -Level WARNING }
    }

    if ($usePipe) {
        # Wait for scrcpy to open its record file (connect to pipe-in) and produce the first
        # video packets so the H.264 extradata is available - ffmpeg needs it for the RTSP
        # PUBLISH SDP, otherwise mediamtx rejects with 400 Bad Request.
        # The bridge emits 'data' once scrcpy's first bytes (Matroska header + extradata) are in
        # (S3-5); wait for that, 100 ms period, at most the 3 s the old fixed sleep took. A scrcpy
        # that exits, or a bridge that ends, stops the wait early (ffmpeg then fails as before).
        $dataWait = [System.Diagnostics.Stopwatch]::StartNew()
        # 6 s, not 3: the launch lock is held until scrcpy's server has connected, and ffmpeg
        # cannot open the pipe before the first bytes anyway (EBML header parsing failed).
        $dataReady = Wait-HeadsetPipeBridgeSignal -Bridge $bridge -Signal 'data' -TimeoutMs 6000 -PollMs 100 -Process $scrcpyProc
        Exit-ScrcpyLaunchLock -Lock $launchLock; $launchLock = $null
        Write-Log ("start-screenCopy: first scrcpy data for {0} seen={1} after {2} ms" -f $displayName, $dataReady, $dataWait.ElapsedMilliseconds) -Level DEBUG
        try {
            $pathName = (ConvertTo-RestreamPathName -HeadsetName $displayName)
            $rtspUrl  = "rtsp://127.0.0.1:$($global:mediamtxRtspPort)/$pathName"
            # In pipe mode, ffmpeg handles file recording instead of scrcpy
            # (scrcpy can only have one --record target, already taken by the pipe).
            # Switch the file extension to mkv to avoid moov-atom-at-end issues with
            # streaming-style writes - mkv finalises incrementally and survives kills.
            $ffmpegRecord = ''
            if ($recording -and $recordFile) {
                $ffmpegRecord = [System.IO.Path]::ChangeExtension($recordFile, '.mkv')
            }
            # The mediamtx this publisher connects to. Another PID later means mediamtx restarted
            # under the stream and the RTSP session is gone (Get-HeadsetPipelineFault).
            $mediaMtxPid = 0
            if (Get-Command Get-MediaMtxProcess -ErrorAction SilentlyContinue) {
                try { $mtxProc = Get-MediaMtxProcess; if ($mtxProc) { $mediaMtxPid = [int]$mtxProc.Id } } catch { }
            }
            $ffmpegPush = Start-FfmpegStreamPush -SafeName $displayName -RtspUrl $rtspUrl -RecordFile $ffmpegRecord -SourceCodec $sourceCodec -EyeMerge $eyeMergeMaps -ProgressFile $ffmpegProgressFile
            $global:HeadsetPipelines[$displayName] = @{
                Bridge              = $bridge
                ScrcpyProcess       = $scrcpyProc
                FfmpegProcess       = $ffmpegPush.Process
                FfmpegErrorWriter   = $ffmpegPush.ErrorWriter
                FfmpegErrorSubId    = $ffmpegPush.ErrorSubscriptionId
                PipeInName     = (Get-HeadsetPipeNames -SafeName $displayName).In
                PipeOutName    = (Get-HeadsetPipeNames -SafeName $displayName).Out
                RtspUrl        = $rtspUrl
                CaptureMode    = $captureMode
                Recording      = [bool]$recording
                RecordFile     = $ffmpegRecord
                EyeMergeKey    = $eyeMergeKey
                LaunchStamp    = $launchStamp.Stamp
                StampParts     = $launchStamp.Parts
                Transport      = $launchTransport
                WifiMode       = $launchWifiMode
                MediaMtxPid    = $mediaMtxPid
                StartedAt      = (Get-Date)
            }
            Write-Log ("Pipe pipeline up for {0}: mode={1} rtsp={2}" -f $displayName, $captureMode, $rtspUrl) -Level SUCCESS
            $startHoldSec = 4
        } catch {
            Write-Log ("Failed to start ffmpeg push for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            try { Stop-Process -Id $scrcpyProc.Id -Force -EA SilentlyContinue } catch {}
            if ($bridge) { Stop-HeadsetPipeBridge -Bridge $bridge -SafeName $displayName }
        }
    }

    } finally {
        Exit-ScrcpyLaunchLock -Lock $launchLock
        # Every exit path ends here: success holds the "starting" mark a few seconds, anything
        # else (ADB unreachable, scrcpy missing, ffmpeg failed to start) clears it at once.
        if ($startingId -gt 0) {
            if ($startHoldSec -gt 0) { Set-ScrcpyStartingState -HeadsetId $startingId -Clear -HoldSec $startHoldSec }
            else                     { Set-ScrcpyStartingState -HeadsetId $startingId -Clear }
        }
    }
}




# Per-session launch state of a LocalWindow capture (no pipeline entry exists for it), keyed by the
# safe display name: @{ LaunchStamp; StampParts; Transport }. Pipe modes keep the same fields in
# $global:HeadsetPipelines[<name>]. A global (not $script:) so the VRMonitor capture workers can
# share it (Start-ScrcpyCaptureWorkers injects the same synchronized table into each worker).
if (-not (Get-Variable -Name ScrcpyLaunchState -Scope Global -ErrorAction SilentlyContinue) -or $null -eq $global:ScrcpyLaunchState) {
    $global:ScrcpyLaunchState = @{}
}

function Get-ScrcpyLaunchStamp {
    <#
    .SYNOPSIS
    The "desired state" of one capture: everything that must restart a running session when it
    changes, as one string plus its named components.

    .DESCRIPTION
    start-screenCopy stores the stamp it launched with; Watch-ScrcpyProcesses rebuilds it and
    compares, instead of parsing scrcpy's command line. Components: args (exact
    ConvertTo-ScrcpyArguments output), merge (Resolve-EyeMergeUse key, '' when not merging),
    rec, mode (capture mode), loglevel, reencode (re-encode, codec, fps, bitrate, GPU choice).
    The transport is NOT part of it: Get-ScrcpyTransportDecision owns that decision.
    The GPU choice is the config (GPU_Acceleration/GPU_Index), never a Get-GpuEncoder probe.

    .EXAMPLE
    $s = Get-ScrcpyLaunchStamp -Model 'Quest 3' -ScrcpyProfile 'square-R-N-45-20' -Ipd '' -Recording $false -CaptureMode 'StreamOnly'
    $s.Stamp; $s.Parts.args
    #>
    param(
        [Parameter(Mandatory=$true)] [string]$Model,
        [Parameter(Mandatory=$true)] [string]$ScrcpyProfile,
        [string]$Ipd = '',
        [bool]$Recording = $false,
        [string]$CaptureMode = 'StreamOnly'
    )

    $argsText = [string](ConvertTo-ScrcpyArguments -headsetModel $Model -scrcpyProfile $ScrcpyProfile -ipd $Ipd)
    $mergeKey = ''
    $use = Resolve-EyeMergeUse -Model $Model -ScrcpyProfile $ScrcpyProfile -Ipd $Ipd
    if ($use -and $use.Use) { $mergeKey = [string]$use.Key }

    $reencode = [bool]$global:mediamtxReencode
    $encText = 'copy'
    if ($reencode) {
        $encText = 'enc:{0}:{1}:{2}:{3}:{4}' -f $global:mediamtxCodec, $global:mediamtxFramerate, $global:mediamtxBitrate, [bool]$global:GPU_Acceleration, $global:GPU_Index
    }

    $parts = [ordered]@{
        args     = ($argsText -replace '\s+', ' ').Trim()
        merge    = $mergeKey
        rec      = [bool]$Recording
        mode     = $CaptureMode
        loglevel = [string]$global:scrcpyLogLevel
        reencode = $encText
    }
    $stamp = (($parts.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '|')
    return @{ Stamp = $stamp; Parts = $parts }
}

function Get-ScrcpyTransportDecision {
    <#
    .SYNOPSIS
    Decides whether a RUNNING scrcpy session should be restarted because the best ADB
    transport for its headset changed. Returns @{ Restart; Reason; Current; Preferred }.

    .DESCRIPTION
    The session is bound to the transport it was launched with: "-s <serial>" is USB,
    "-s ip:port" is WiFi. Two situations call for a restart:

      * The session is on USB but the cable is gone. scrcpy usually exits by itself, but not
        always promptly, and a dead capture is a black tile on every wall - so restart now;
        start-screenCopy then resolves to WiFi on its own.
      * The session is on WiFi and the headset has been cabled. Whether that interrupts the
        stream is the operator choice scrcpy.usb_switch_mode:
          stable      switch once the serial has been cabled for scrcpy.usb_switch_stable_sec
                      AND the headset is not recording (the default - a flapping cable must
                      not bounce the stream, and a recording must not be cut in two)
          immediate   switch as soon as the cable is seen, even while recording
          next_start  never interrupt: USB is used the next time scrcpy starts

    Nothing is decided while an operator action holds USB (Test-UsbBusy): those actions
    re-enumerate the transport for seconds, and the published set is unreliable meanwhile.
    The cabled set is VRMonitor published snapshot, so this costs no adb.exe.

    .EXAMPLE
    $d = Get-ScrcpyTransportDecision -Headset $headset -CurrentTransport 'WiFi' -Recording $false
    if ($d.Restart) { Write-Log $d.Reason }
    #>
    param(
        [Parameter(Mandatory=$true)] $Headset,
        # Transport the session was launched with, as stored by start-screenCopy ('USB' or
        # 'WiFi'). Empty (adopted session, unknown) = no decision.
        [string]$CurrentTransport = '',
        [bool]$Recording = $false
    )

    $d = [PSCustomObject]@{ Restart = $false; Reason = ''; Current = '-'; Preferred = '-' }
    if ($CurrentTransport -notin @('USB','WiFi')) { return $d }
    $d.Current = $CurrentTransport

    $busy = $false
    if (Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) { $busy = Test-UsbBusy }
    if ($busy) { return $d }

    $serial = if ($Headset.SerialNumber) { ([string]$Headset.SerialNumber).Trim() } else { '' }
    $cabled = $null
    if ($serial -and $serial -ne '-') {
        $cabled = @(Get-PublishedUsbDevices | Where-Object { $_.Serial -eq $serial }) | Select-Object -First 1
    }
    $preferUsb = if ($null -ne $global:ADB_prefer_usb) { [bool]$global:ADB_prefer_usb } else { $true }
    $d.Preferred = $(if ($cabled -and $preferUsb) { 'USB' } else { 'WiFi' })

    if ($d.Current -eq 'USB') {
        if (-not $cabled) {
            $d.Restart = $true
            $d.Reason  = (Get-MessageString -Key 'Diag.ScrcpyCableLost' -Fallback 'USB cable removed for {0} - moving the capture to WiFi.') -f $Headset.Name
        }
        return $d
    }

    # Currently on WiFi.
    if ($d.Preferred -ne 'USB') { return $d }
    $mode = if ($global:scrcpyUsbSwitchMode) { [string]$global:scrcpyUsbSwitchMode } else { 'stable' }
    $switchMsg = (Get-MessageString -Key 'Diag.ScrcpySwitchToUsb' -Fallback 'USB cable detected for {0} - moving the capture from WiFi to USB.') -f $Headset.Name
    if ($mode -eq 'immediate') {
        $d.Restart = $true; $d.Reason = $switchMsg
    } elseif ($mode -eq 'stable' -and -not $Recording) {
        $since = [datetime]::MinValue
        $parsed = [datetime]::TryParse([string]$cabled.Since, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$since)
        $stableSec = if ($global:scrcpyUsbSwitchStableSec) { [int]$global:scrcpyUsbSwitchStableSec } else { 10 }
        if ($parsed -and (([datetime]::UtcNow - $since).TotalSeconds -ge $stableSec)) {
            $d.Restart = $true; $d.Reason = $switchMsg
        }
    }
    return $d
}


# ---------------------------------------------------------------------------------------------
# "Capture starting" state and "check now" requests (cross-process, app_kv).
#
# The web pages could only guess that a capture was starting (auto-restart ON, ADB up, no scrcpy),
# and after a kill or a settings change the restart waited for the monitor's slow tick. Two
# app_kv rows fix both, readable and writable from any process:
#   scrcpy_starting       { "<headsetId>": <+expiry = starting | -expiry = up, picture arriving> }
#       set when a start was requested (or the restart began), cleared when the stream is up, the
#       start failed or nothing needed doing. Expires by itself (TTL), so a crash cannot leave a
#       headset "starting" forever. Exposed by /api/headsets-status and /api/headset-status.
#   scrcpy_check_request  { id; at; ids; reason }
#       "look at these headsets NOW": VRMonitor's 500 ms fast path reloads config and runs
#       Watch-ScrcpyProcesses for them instead of waiting for the slow tick (same channel idea as
#       ADR-0027's stream restart request, but per headset and without stopping anything).
# ---------------------------------------------------------------------------------------------
$script:ScrcpyStartingKey    = 'scrcpy_starting'
$script:ScrcpyCheckKey       = 'scrcpy_check_request'
$script:ScrcpyStartingTtlSec = 45
$script:ScrcpyOverrideExtraSec = 11   # settling lasts HoldSec + this: see Get-ScrcpyCaptureState
$script:ScrcpyStartingMemo   = $null

function Get-ScrcpyCaptureState {
    <#
    .SYNOPSIS
    The captures that are starting, as @{ Starting; Settling; Announcing } (int[] each). Memoised
    for 0.7 s per process: the status endpoints are polled by every open page. Never throws.

    .DESCRIPTION
    The scrcpy_starting kv row holds one number per headset. A positive one is the expiry of a
    start in progress; a NEGATIVE one the expiry of a capture that is UP:
      Starting    scrcpy is not up yet. The status endpoints report scrcpy = false for it
                  whatever the monitor's SCRCPY flag says: that flag lags reality by several
                  seconds in BOTH directions (measured ~7 s), so right after a kill it still
                  reads "ok" - which made the page show a running capture and revert.
      Settling    the pipeline is up. scrcpy is reported TRUE for it, for up to 15 s: the flag
                  is still stale-false for a while after the start, and without this the page
                  saw the capture "crash" again right after its picture appeared.
      Announcing  the first seconds of Settling: the page still says "starting" (the picture is
                  arriving) although scrcpy is already true.

    .EXAMPLE
    $st = Get-ScrcpyCaptureState
    if ($st.Starting -contains [int]$headset.ID) { 'not up yet' }
    #>
    try {
        $m = $script:ScrcpyStartingMemo
        if ($m -and (([DateTime]::UtcNow - $m.At).TotalMilliseconds -lt 700)) { return $m }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $starting  = [System.Collections.Generic.List[int]]::new()
        $settling  = [System.Collections.Generic.List[int]]::new()
        $announcing = [System.Collections.Generic.List[int]]::new()
        $cur = Get-DbKeyValue -Key $script:ScrcpyStartingKey
        if ($cur) {
            foreach ($p in $cur.PSObject.Properties) {
                $v = 0L
                if (-not [int64]::TryParse([string]$p.Value, [ref]$v)) { continue }
                if ([Math]::Abs($v) -le $now) { continue }
                if ($v -gt 0) { $starting.Add([int]$p.Name); continue }
                $settling.Add([int]$p.Name)
                if (([Math]::Abs($v) - $script:ScrcpyOverrideExtraSec) -gt $now) { $announcing.Add([int]$p.Name) }
            }
        }
        $script:ScrcpyStartingMemo = @{ At = [DateTime]::UtcNow; Starting = $starting.ToArray(); Settling = $settling.ToArray(); Announcing = $announcing.ToArray() }
        return $script:ScrcpyStartingMemo
    } catch {
        return @{ At = [DateTime]::UtcNow; Starting = @(); Settling = @(); Announcing = @() }
    }
}

function Get-ScrcpyStartingIds {
    <#
    .SYNOPSIS
    Every headset id the pages announce as "starting" (Starting + Announcing, see
    Get-ScrcpyCaptureState). Never throws; wrap in @().

    .EXAMPLE
    if (@(Get-ScrcpyStartingIds) -contains [int]$headset.ID) { 'starting' }
    #>
    $s = Get-ScrcpyCaptureState
    return @($s.Starting) + @($s.Announcing)
}

function Set-ScrcpyStartingState {
    <#
    .SYNOPSIS
    Marks headsets as "capture starting" (default), or clears the mark (-Clear). -HoldSec with
    -Clear means "the pipeline is up": the capture is announced for that many more seconds (the
    stream reaches mediamtx about a second after the pipeline) and is reported as running for
    HoldSec + 11 s regardless of the monitor's lagging flag (Settling, see
    Get-ScrcpyCaptureState). Clearing a headset that is not marked costs one read and no write.
    Never throws.

    .EXAMPLE
    Set-ScrcpyStartingState -HeadsetId 3
    Set-ScrcpyStartingState -HeadsetId 3 -Clear -HoldSec 4
    #>
    param(
        [Parameter(Mandatory = $true)][int[]]$HeadsetId,
        [switch]$Clear,
        [int]$HoldSec = 0
    )
    try {
        if ($Clear -and $HoldSec -le 0) {
            $active = @(Get-ScrcpyCaptureState | ForEach-Object { @($_.Starting) + @($_.Settling) })
            if (-not @($HeadsetId | Where-Object { $active -contains $_ })) { return }
        }
        $now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # Negative = up (settling); positive = starting (not up yet).
        $value = if ($Clear) { -($now + [Math]::Max(0, $HoldSec) + $script:ScrcpyOverrideExtraSec) } else { $now + $script:ScrcpyStartingTtlSec }
        Invoke-DbTransaction -Script {
            $cur = Get-DbKeyValue -Key $script:ScrcpyStartingKey
            $map = [ordered]@{}
            if ($cur) {
                foreach ($p in $cur.PSObject.Properties) {
                    $v = 0L
                    if ([int64]::TryParse([string]$p.Value, [ref]$v) -and [Math]::Abs($v) -gt $now) { $map[[string]$p.Name] = $v }
                }
            }
            foreach ($id in $HeadsetId) {
                if ($Clear -and $HoldSec -le 0) { $map.Remove([string]$id) } else { $map[[string]$id] = $value }
            }
            Set-DbKeyValue -Key $script:ScrcpyStartingKey -Value $map
        } | Out-Null
        $script:ScrcpyStartingMemo = $null
    } catch {
        Write-Log ("Set-ScrcpyStartingState failed: {0}" -f $_.Exception.Message) -Level DEBUG
    }
}
function Request-ScrcpyCheck {
    <#
    .SYNOPSIS
    Asks VRMonitor to look at these headsets right now (-HeadsetId, or -All) and marks them
    "starting". Call it after anything that kills a capture or changes what it must be:
    the kill button, a profile / recording / capture-mode / view / calibration change.
    Only headsets with auto-restart ON and a known address are concerned - for the others
    nothing would start. VRMonitor does the real work (it owns the pipelines): reload config,
    Watch-ScrcpyProcesses for these ids (restart if the running session no longer matches,
    start if none runs). Returns the ids that were requested ($null-safe empty array). Never throws.

    -NoMark: only nudge, do not announce "starting". For a change that MAY need no restart at all
    (view definitions, calibration): the watchdog marks a headset itself when it really restarts
    one, whereas marking them all first would flash "starting" on captures that never stop.

    .EXAMPLE
    [void](Request-ScrcpyCheck -HeadsetId $headset.ID -Reason 'profile changed')
    [void](Request-ScrcpyCheck -All -NoMark -Reason 'view definitions changed')
    #>
    param([int[]]$HeadsetId = @(), [switch]$All, [switch]$NoMark, [string]$Reason = '')
    try {
        $targets = @(Get-KnownHeadsets | Where-Object {
            (ConvertTo-BoolField $_.scrcpy_AutoRestart) -and -not (Test-UnknownIp $_.IPAddress) -and
            ($All -or ($HeadsetId -contains [int]$_.ID))
        })
        $ids = @($targets | ForEach-Object { [int]$_.ID })
        if ($ids.Count -eq 0) { return @() }
        if (-not $NoMark) { Set-ScrcpyStartingState -HeadsetId $ids }
        Set-DbKeyValue -Key $script:ScrcpyCheckKey -Value @{
            id = [guid]::NewGuid().ToString('N'); at = (Get-Date).ToUniversalTime().ToString('o'); ids = $ids; reason = $Reason
        }
        return $ids
    } catch {
        Write-Log ("Request-ScrcpyCheck failed: {0}" -f $_.Exception.Message) -Level DEBUG
        return @()
    }
}

function Get-ScrcpyCheckRequest {
    <# The pending check request @{id;at;ids;reason}, or $null. Read by VRMonitor's fast path. #>
    param()
    try { return (Get-DbKeyValue -Key $script:ScrcpyCheckKey) } catch { return $null }
}


function Get-HeadsetPipelineFault {
    <#
    .SYNOPSIS
    Why one pipe pipeline is broken, or '' when it is healthy or cannot be judged yet. The
    decision behind Get-HeadsetPipelineFaults; the only state it changes is -State.PathMisses.

    .DESCRIPTION
    Broken when ANY of:
      - the ffmpeg push has exited;
      - the pipe bridge thread has ended (IsAlive false);
      - mediamtx runs under another PID than the one the pipeline published to (it restarted and
        the RTSP session went with it);
      - the mediamtx path is missing or not ready on PipelineHealthPathMisses (2) checks in a row
        (-State.PathMisses counts them).
    Nothing is judged during the first PipelineHealthGraceSec (20) s of a pipeline: ffmpeg only
    publishes a few seconds after the start. -PathStates $null (the mediamtx API did not answer)
    skips the path rule and keeps the miss count as it was, so one missed answer never counts.
    -MediaMtxPid 0 (mediamtx not found) skips the PID rule, as does a pipeline that recorded no
    PID at start. scrcpy is not looked at: the caller only asks about pipelines whose scrcpy runs.

    .EXAMPLE
    $state = @{ PathMisses = 0 }
    Get-HeadsetPipelineFault -Pipeline $global:HeadsetPipelines['Q3_RED'] -PathName 'q3_red' -PathStates (Get-MediaMtxPathStates) -MediaMtxPid 4242 -State $state
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Pipeline,
        [Parameter(Mandatory = $true)][string]$PathName,
        [hashtable]$PathStates = $null,
        [int]$MediaMtxPid = 0,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [datetime]$Now = (Get-Date)
    )
    if ($Pipeline.StartedAt -and (($Now - [datetime]$Pipeline.StartedAt).TotalSeconds -lt $script:PipelineHealthGraceSec)) {
        $State.PathMisses = 0
        return ''
    }
    $ff = $Pipeline.FfmpegProcess
    if ($ff) {
        $exited = $false
        try { $exited = $ff.HasExited } catch { }
        if ($exited) {
            $code = '?'
            try { $code = [string]$ff.ExitCode } catch { }
            return ("the ffmpeg push exited (code {0})" -f $code)
        }
    }
    if ($Pipeline.Bridge) {
        $bridgeAlive = $false
        try { $bridgeAlive = [bool]$Pipeline.Bridge.IsAlive } catch { }
        if (-not $bridgeAlive) {
            $bridgeState = '?'; $bridgeError = ''
            try { $bridgeState = [string]$Pipeline.Bridge.State; $bridgeError = [string]$Pipeline.Bridge.Error } catch { }
            if ($bridgeError) { return ("the pipe bridge is {0} ({1})" -f $bridgeState, $bridgeError) }
            return ("the pipe bridge is {0}" -f $bridgeState)
        }
    }
    $startPid = [int]$Pipeline.MediaMtxPid
    if ($MediaMtxPid -gt 0 -and $startPid -gt 0 -and $MediaMtxPid -ne $startPid) {
        return ("mediamtx restarted under the stream (pid {0} -> {1})" -f $startPid, $MediaMtxPid)
    }
    if ($null -ne $PathStates) {
        $path = $PathStates[$PathName]
        if ($path -and $path.Ready) {
            $State.PathMisses = 0
        } else {
            $State.PathMisses = [int]$State.PathMisses + 1
            if ($State.PathMisses -ge $script:PipelineHealthPathMisses) {
                $what = if ($path) { 'not ready' } else { 'missing' }
                return ("mediamtx path '{0}' {1} on {2} checks in a row" -f $PathName, $what, $State.PathMisses)
            }
        }
    }
    return ''
}

function Get-HeadsetPipelineFaults {
    <#
    .SYNOPSIS
    Pipeline health check of the VRMonitor slow tick: the pipe pipelines of THIS process whose
    scrcpy still runs but whose stream is broken, as a hashtable safe display name -> reason
    (Get-HeadsetPipelineFault). Never throws.

    .DESCRIPTION
    Called by Watch-ScrcpyProcesses -CheckPipelineHealth, which restarts the broken ones through
    its usual restart path, rate-limited by Approve-HeadsetPipelineRestart. mediamtx's path list
    is read ONCE (Get-MediaMtxPathStates), and only when a pipeline is past its start grace.
    Returns an empty table, judging nothing, while:
      - a stream benchmark runs (it owns the captures, ADR-0026);
      - the capture mode is LocalWindow (no pipeline) or mediamtx is disabled (nothing to publish to).
    Only the pipelines in $global:HeadsetPipelines are judged, i.e. those this process started.
    Every planned stream / mediamtx restart is a request VRMonitor runs itself on its fast path
    (Request-StreamRestart, ADR-0032), on the same thread as this check, so the two never race and
    no lock is needed here.
    -PathStates and -MediaMtxPid replace the live reads (tests).

    .EXAMPLE
    $faults = Get-HeadsetPipelineFaults
    foreach ($name in $faults.Keys) { '{0}: {1}' -f $name, $faults[$name] }
    #>
    param(
        [hashtable]$PathStates = $null,
        [int]$MediaMtxPid = 0,
        [datetime]$Now = (Get-Date)
    )
    $faults = @{}
    try {
        $health = $global:HeadsetPipelineHealth
        # Forget the path misses of pipelines that are gone, but keep their restart times while
        # they still count, so a restart that did not bring a pipeline back stays rate-limited.
        $cutoff = $Now.AddMinutes(-$script:PipelineHealthWindowMin)
        foreach ($key in @($health.Keys)) {
            if ($global:HeadsetPipelines.ContainsKey($key)) { continue }
            $health[$key].PathMisses = 0
            if (@($health[$key].Restarts | Where-Object { $_ -gt $cutoff }).Count -eq 0) { $health.Remove($key) }
        }
        if ($global:HeadsetPipelines.Count -eq 0) { return $faults }
        if (-not $global:mediamtxEnabled -or $global:CaptureMode -eq 'LocalWindow') { return $faults }
        if ((Get-Command Test-StreamBenchmarkActive -ErrorAction SilentlyContinue) -and (Test-StreamBenchmarkActive)) { return $faults }

        # Pipelines that can be judged: scrcpy still running (a dead scrcpy is the watchdog's
        # ordinary restart) and past the start grace.
        $candidates = @()
        foreach ($key in @(Get-SyncTableKeys -Table $global:HeadsetPipelines)) {
            $entry = $global:HeadsetPipelines[$key]
            if (-not $entry -or $entry.CaptureMode -eq 'LocalWindow') { continue }
            $scrcpyAlive = $false
            try { $scrcpyAlive = [bool]($entry.ScrcpyProcess -and -not $entry.ScrcpyProcess.HasExited) } catch { }
            if (-not $scrcpyAlive) { continue }
            if (-not $health.ContainsKey($key)) { $health[$key] = @{ PathMisses = 0; Restarts = @(); GaveUpUntil = $null } }
            if ($entry.StartedAt -and (($Now - [datetime]$entry.StartedAt).TotalSeconds -lt $script:PipelineHealthGraceSec)) {
                $health[$key].PathMisses = 0
                continue
            }
            $candidates += $key
        }
        if ($candidates.Count -eq 0) { return $faults }

        if (-not $PSBoundParameters.ContainsKey('PathStates')) {
            $PathStates = $null
            if (Get-Command Get-MediaMtxPathStates -ErrorAction SilentlyContinue) { $PathStates = Get-MediaMtxPathStates }
        }
        if (-not $PSBoundParameters.ContainsKey('MediaMtxPid')) {
            $MediaMtxPid = 0
            if (Get-Command Get-MediaMtxProcess -ErrorAction SilentlyContinue) {
                $mtx = Get-MediaMtxProcess
                if ($mtx) { $MediaMtxPid = [int]$mtx.Id }
            }
        }
        if ($null -eq $PathStates) {
            Write-Log "Pipeline health check: the mediamtx API did not answer - path check skipped this tick." -Level DEBUG
        }

        foreach ($key in $candidates) {
            # Same path name start-screenCopy publishes to.
            $pathName = ConvertTo-RestreamPathName -HeadsetName $key
            $reason = Get-HeadsetPipelineFault -Pipeline $global:HeadsetPipelines[$key] -PathName $pathName `
                -PathStates $PathStates -MediaMtxPid $MediaMtxPid -State $health[$key] -Now $Now
            if ($reason) { $faults[$key] = $reason }
        }
    } catch {
        Write-Log ("Pipeline health check failed: {0}" -f $_.Exception.Message) -Level WARNING
    }
    return $faults
}

function Approve-HeadsetPipelineRestart {
    <#
    .SYNOPSIS
    Rate limit of the automatic pipeline restarts: $true (and the restart is counted) while the
    headset had fewer than PipelineHealthMaxRestarts (3) of them in the last
    PipelineHealthWindowMin (5) minutes, $false otherwise. Never throws.

    .DESCRIPTION
    Logs the WARNING of an approved restart with its reason. When the limit is reached it logs ONE
    ERROR and approves nothing more until the oldest counted restart leaves the window, so a
    mediamtx that stays down cannot cause a restart loop, and a stream still comes back on its own
    once mediamtx is fixed.

    .EXAMPLE
    if (Approve-HeadsetPipelineRestart -SafeName 'Q3_RED' -Reason 'the ffmpeg push exited (code 1)') { 'restart it' }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SafeName,
        [string]$Reason = '',
        [datetime]$Now = (Get-Date)
    )
    try {
        $health = $global:HeadsetPipelineHealth
        if (-not $health.ContainsKey($SafeName)) { $health[$SafeName] = @{ PathMisses = 0; Restarts = @(); GaveUpUntil = $null } }
        $state  = $health[$SafeName]
        $cutoff = $Now.AddMinutes(-$script:PipelineHealthWindowMin)
        $state.Restarts = @($state.Restarts | Where-Object { $_ -gt $cutoff })
        if ($state.Restarts.Count -ge $script:PipelineHealthMaxRestarts) {
            if (-not $state.GaveUpUntil -or $Now -ge $state.GaveUpUntil) {
                $state.GaveUpUntil = (@($state.Restarts | Sort-Object)[0]).AddMinutes($script:PipelineHealthWindowMin)
                Write-Log ("Stream of {0} is still broken ({1}) after {2} automatic restarts in {3} min - no more automatic restart before {4:HH:mm:ss}. Check that mediamtx runs (Services menu) and read the latest {0}_*_ffmpegPush_stderr.txt log." -f $SafeName, $Reason, $state.Restarts.Count, $script:PipelineHealthWindowMin, $state.GaveUpUntil) -Level ERROR
            }
            return $false
        }
        $state.GaveUpUntil = $null
        $state.PathMisses  = 0
        $state.Restarts    = @($state.Restarts) + @($Now)
        Write-Log ("Stream of {0} is broken while scrcpy still runs: {1} - restarting the whole pipeline (automatic restart {2}/{3} in {4} min)." -f $SafeName, $Reason, $state.Restarts.Count, $script:PipelineHealthMaxRestarts, $script:PipelineHealthWindowMin) -Level WARNING
        return $true
    } catch {
        Write-Log ("Approve-HeadsetPipelineRestart failed for {0}: {1}" -f $SafeName, $_.Exception.Message) -Level DEBUG
        return $false
    }
}


# -------------------------------------------------------------------
# Capture workers (S3-5 Step B, ADR-0036). A capture start (adb probes, eye-merge tables, bridge,
# scrcpy, the wait for scrcpy's first data, the ffmpeg push) and a restart (closing the old
# session, up to 15 s of ffmpeg grace to finalise a recording, then the start) used to run on
# the VRMonitor thread, one headset after another: starting 6 headsets froze the 500 ms fast
# path for 25 s or more. VRMonitor now opens a small RunspacePool (Start-ScrcpyCaptureWorkers)
# and the watchdog SUBMITS the work (Submit-ScrcpyCaptureJob); the fast path drains finished
# jobs (Update-ScrcpyCaptureWorkers). Without a pool (console, benchmark job, web server) the
# job runs inline, exactly as before.
#
# Rules that keep it safe:
#   - The capture tables ($global:HeadsetPipelines, DirectRecordings, ScrcpyLaunchState,
#     EyeMergeRejected) are synchronized hashtables injected into every worker, so a pipeline a
#     worker starts is seen by the loop (health check, PID map, stamps, Stop-Scrcpy). Enumerate
#     them with Get-SyncTableKeys.
#   - ONE job per headset at a time; the loop never touches a busy headset (the watchdog skips
#     it; Stop-Scrcpy cancels the job instead of tearing the pipeline down under it, and the job
#     undoes its own start when it sees the cancel).
#   - Everything a pipeline holds is thread-agnostic: Process objects, the in-process bridge
#     (ADR-0035) and the stderr sink (VrhmStderrSink) - no Start-Job, no Register-ObjectEvent.
# -------------------------------------------------------------------
$script:CaptureWorkerMax     = 2     # concurrent starts (each one is mostly waiting on adb / scrcpy)
$script:CaptureJobWarnSec    = 120   # a job older than this is logged once (WARNING)
$script:CaptureJobStopSec    = 300   # ...and asked to stop (ERROR); the headset is then free again
$script:CaptureWorkerTables  = @('HeadsetPipelines', 'DirectRecordings', 'ScrcpyLaunchState', 'EyeMergeRejected')

# Runs in a worker runspace (as script text, so scripts_init.ps1 dot-sources into the runspace's
# GLOBAL scope and stays loaded for the next job of that runspace). The first job of a runspace
# loads the modules (~5-7 s), which is why Start-ScrcpyCaptureWorkers sends warm-up jobs at once.
$script:CaptureWorkerScript = @'
param($Job)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not (Get-Command Invoke-ScrcpyCaptureJob -ErrorAction SilentlyContinue)) {
    # Nobody reads this runspace's streams: keep Write-Host records out of memory (as VRMonitor does).
    $global:PSDefaultParameterValues['Write-Host:InformationAction'] = 'Ignore'
    # Same role as the VRMonitor job: Worker database connection, no web server / setup / VQA init.
    $global:IsVRMonitorJob        = $true
    $global:IsScrcpyCaptureWorker = $true
    . (Join-Path $global:ScriptPath 'modules\scripts_init.ps1')
}
if ($Job.Mode -eq 'Warm') {
    $ok = [bool](Get-Command Invoke-ScrcpyCaptureJob -ErrorAction SilentlyContinue)
    if ($ok) { $ok = [bool](Initialize-PipeBridgeType) }
    # The first re-encoding start of this runspace would pay the encoder probe (Get-GpuEncoder
    # caches per runspace); pay it here, off every start.
    if ($ok -and $global:mediamtxReencode -and $global:CaptureMode -ne 'LocalWindow' -and (Get-Command Get-GpuEncoder -ErrorAction SilentlyContinue)) {
        try { [void](Get-GpuEncoder) } catch { }
    }
    return @{ Ok = $ok; Warm = $true; Cancelled = $false; Error = $(if ($ok) { '' } else { 'modules did not load' }); DurationMs = $sw.ElapsedMilliseconds }
}
$Job.InWorker = $true
Invoke-ScrcpyCaptureJob -Job $Job
'@

<#
.SYNOPSIS
    Runs ONE capture job: a start, or a restart (close the running session -ScrcpyPid, tear its
    pipeline down, then start). Called by a capture worker, or inline by Submit-ScrcpyCaptureJob
    when the process has no worker pool. A job whose Cancel flag is set before the start does
    nothing; one cancelled while it started stops what it started (Stop-Scrcpy for that headset).
    Returns @{Ok;Warm;Cancelled;Error;DurationMs}. Never throws.
.EXAMPLE
    Invoke-ScrcpyCaptureJob -Job @{ HeadsetId = 3; Name = 'Q3 BLUE'; IPAddress = '192.168.1.243'; Mode = 'Start'; Recording = $false; Profile = 'square-R-N-45-20'; ScrcpyPid = 0; Cancel = $false }
#>
function Invoke-ScrcpyCaptureJob {
    param([Parameter(Mandatory)]$Job)
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $res = @{ Ok = $false; Warm = $false; Cancelled = $false; Error = ''; DurationMs = 0 }
    $hid = [int]$Job.HeadsetId
    try {
        $safe = Convert-Displayname ([string]$Job.Name)
        if ($Job.Cancel) {
            $res.Cancelled = $true
            if ($hid -gt 0) { Set-ScrcpyStartingState -HeadsetId $hid -Clear }
            return $res
        }
        if ($Job.InWorker) {
            # A worker keeps its own globals: follow a config change the loop already reloaded.
            if ((Get-Command Test-ConfigChanged -ErrorAction SilentlyContinue) -and (Test-ConfigChanged)) {
                try { Get-Config -ConfigFilePath $global:ConfigFilePath | Out-Null } catch { }
            }
        }
        # Capture mode straight from config.json, in case Set-CaptureMode wrote it after the last
        # Get-Config (this used to be done by the watchdog right before start-screenCopy).
        # Read-ConfigJson: literal path, UTF-8, and retried across a Write-ConfigJson swap.
        try {
            $freshJson = Read-ConfigJson -ConfigFilePath (Join-Path $global:ScriptPath 'config\config.json') -NonInteractive
            if ($freshJson -and $freshJson.Performance -and $freshJson.Performance.Capture_Mode) {
                $global:CaptureMode = $freshJson.Performance.Capture_Mode
            }
        } catch { }

        if ($Job.Mode -eq 'Restart') {
            $old = $null
            if ([int]$Job.ScrcpyPid -gt 0) {
                $old = Get-Process -Id ([int]$Job.ScrcpyPid) -ErrorAction SilentlyContinue
                if ($old -and $old.ProcessName -ne 'scrcpy') { $old = $null }
            }
            if ($old) {
                # Same rule as Stop-Scrcpy: only a scrcpy that HAS a window can be closed politely,
                # and only a window that ignored the request deserves the "may be incomplete" warning.
                $hadWindow = ($old.MainWindowHandle -ne [IntPtr]::Zero)
                $closed = $hadWindow -and $old.CloseMainWindow()
                if ($closed) { [void]$old.WaitForExit(10000) }
                if (-not $old.HasExited) {
                    if ($hadWindow) { Write-Log ($msg.Scrcpy.StopTimeout -f $Job.Name) -Level WARNING }
                    Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue
                    try { [void]$old.WaitForExit(1000) } catch { }
                }
            }
            Complete-DirectRecording -SafeName $safe
            # Tear the old pipeline down HERE (ffmpeg, bridge, and the old recording file is
            # finalised) rather than only inside start-screenCopy, which skips it when the headset
            # no longer answers ADB. No-op when no pipeline is held for it.
            Stop-HeadsetPipeline -SafeName $safe
            if ($Job.Cancel) {
                $res.Cancelled = $true
                if ($hid -gt 0) { Set-ScrcpyStartingState -HeadsetId $hid -Clear }
                $res.Ok = $true
                return $res
            }
        }

        start-screenCopy -displayName ([string]$Job.Name) -headsetIP ([string]$Job.IPAddress) -recording ([bool]$Job.Recording) -scrcpyProfile ([string]$Job.Profile)

        # Read Cancel and mark the job Done in ONE step, under the job's lock: a stop that comes
        # after this point is not handed to the job any more (Request-ScrcpyCaptureCancel checks
        # Done under the same lock) and tears the capture down itself. Without it a stop landing
        # between the check and the end of the job was lost and the stream kept running.
        $undo = $false
        [System.Threading.Monitor]::Enter($Job.SyncRoot)
        try { $undo = [bool]$Job.Cancel; $Job.Done = $true } finally { [System.Threading.Monitor]::Exit($Job.SyncRoot) }
        if ($undo) {
            # A stop (benchmark, restart request, shutdown) arrived while this was starting: the
            # loop left this headset to us, so undo the start here.
            Write-Log ("Capture job for {0}: stop requested during the start - stopping it again." -f $Job.Name) -Level INFO
            try { [void](Stop-Scrcpy -HeadsetName ([string]$Job.Name) -HeadsetIP ([string]$Job.IPAddress)) } catch { }
            $res.Cancelled = $true
        }
        $res.Ok = $true
    } catch {
        $res.Error = $_.Exception.Message
        Write-Log ("Capture job ({0}) for {1} failed: {2}" -f $Job.Mode, $Job.Name, $_.Exception.Message) -Level WARNING
        if ($hid -gt 0) { try { Set-ScrcpyStartingState -HeadsetId $hid -Clear } catch { } }
    } finally {
        try { $Job.Done = $true } catch { }
        $res.DurationMs = $sw.ElapsedMilliseconds
    }
    return $res
}

<#
.SYNOPSIS
    Opens the capture worker pool of THIS process (VRMonitor only): converts the capture tables
    to synchronized hashtables, injects them into a RunspacePool of -MaxWorkers runspaces and
    sends one warm-up job per runspace (module load + encoder probe, off the loop). Idempotent.
    Returns $true when the pool is up; on $false every job runs inline (the old behaviour).
.EXAMPLE
    Start-ScrcpyCaptureWorkers -MaxWorkers 2
#>
function Start-ScrcpyCaptureWorkers {
    param([int]$MaxWorkers = $script:CaptureWorkerMax)
    if ($global:ScrcpyCaptureWorkers) { return $true }
    $MaxWorkers = [Math]::Max(1, [Math]::Min(8, $MaxWorkers))
    try {
        foreach ($n in $script:CaptureWorkerTables) {
            $cur = $null
            $v = Get-Variable -Name $n -Scope Global -ErrorAction SilentlyContinue
            if ($v) { $cur = $v.Value }
            if ($null -eq $cur) { $cur = @{} }
            if (-not $cur.IsSynchronized) { $cur = [hashtable]::Synchronized($cur) }
            Set-Variable -Name $n -Scope Global -Value $cur
        }
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($n in @($script:CaptureWorkerTables + @('ScriptPath', 'ConfigFilePath', 'logFolder', 'logFile'))) {
            $val = (Get-Variable -Name $n -Scope Global -ErrorAction SilentlyContinue).Value
            $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new($n, $val, ''))
        }
        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxWorkers, $iss, $Host)
        $pool.Open()
        $global:ScrcpyCaptureWorkers = @{ Pool = $pool; Max = $MaxWorkers; Jobs = @{}; Seq = 0; OpenedAt = (Get-Date) }
        for ($i = 1; $i -le $MaxWorkers; $i++) {
            $job = [hashtable]::Synchronized(@{ HeadsetId = 0; Name = "warm$i"; Mode = 'Warm'; Cancel = $false })
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:CaptureWorkerScript).AddArgument($job)
            $global:ScrcpyCaptureWorkers.Jobs["warm$i"] = @{ PS = $ps; Handle = $ps.BeginInvoke(); Job = $job; SubmittedAt = (Get-Date); Warned = $false; Stopping = $false }
        }
        Write-Log ("Capture workers: pool of {0} opened (warming up)." -f $MaxWorkers) -Level INFO
        return $true
    } catch {
        Write-Log ("Capture workers: could not open the pool, captures start on the loop thread: {0}" -f $_.Exception.Message) -Level WARNING
        $global:ScrcpyCaptureWorkers = $null
        return $false
    }
}

<#
.SYNOPSIS
    Starts or restarts the capture of one headset. With a worker pool (VRMonitor) the job is
    queued and this returns at once: 'queued', or 'busy' when a job for that headset is already
    in flight (nothing is queued). Without a pool it runs inline and returns 'inline'.
    -Mode Restart closes the running session -ScrcpyPid first.
.EXAMPLE
    Submit-ScrcpyCaptureJob -Headset $row -Mode Restart -Recording $true -ScrcpyProfile 'square-R-N-45-20' -ScrcpyPid 4242 -Reason 'profile changed'
#>
function Submit-ScrcpyCaptureJob {
    param(
        [Parameter(Mandatory)]$Headset,
        [ValidateSet('Start', 'Restart')][string]$Mode = 'Start',
        [bool]$Recording = $false,
        [string]$ScrcpyProfile = 'R-N-45-20',
        [int]$ScrcpyPid = 0,
        [string]$Reason = ''
    )
    $hid = 0
    [void][int]::TryParse([string]$Headset.ID, [ref]$hid)
    $job = [hashtable]::Synchronized(@{
        HeadsetId = $hid; Name = [string]$Headset.Name; IPAddress = [string]$Headset.IPAddress
        Mode = $Mode; Recording = $Recording; Profile = $ScrcpyProfile; ScrcpyPid = $ScrcpyPid
        Reason = $Reason; Cancel = $false; InWorker = $false
    })
    $w = $global:ScrcpyCaptureWorkers
    if (-not $w -or $hid -le 0) {
        [void](Invoke-ScrcpyCaptureJob -Job $job)
        return 'inline'
    }
    $key = [string]$hid
    if ($w.Jobs.ContainsKey($key)) {
        Write-Log ("Capture job for {0} not queued: one is already in flight." -f $Headset.Name) -Level DEBUG
        return 'busy'
    }
    # Announce it now: the job may wait for a free worker, and the pages must show "starting".
    Set-ScrcpyStartingState -HeadsetId $hid
    try {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $w.Pool
        [void]$ps.AddScript($script:CaptureWorkerScript).AddArgument($job)
        $handle = $ps.BeginInvoke()
    } catch {
        Write-Log ("Capture workers: queueing {0} failed ({1}) - running it on the loop thread." -f $Headset.Name, $_.Exception.Message) -Level WARNING
        try { $ps.Dispose() } catch { }
        [void](Invoke-ScrcpyCaptureJob -Job $job)
        return 'inline'
    }
    $w.Seq++
    $w.Jobs[$key] = @{ PS = $ps; Handle = $handle; Job = $job; SubmittedAt = (Get-Date); Warned = $false; Stopping = $false }
    Write-Log ("Capture job #{0} queued: {1} {2}{3}" -f $w.Seq, $Mode, $Headset.Name, $(if ($Reason) { " ($Reason)" } else { '' })) -Level DEBUG
    return 'queued'
}

<#
.SYNOPSIS
    Drains the capture worker pool: collects every finished job (logs its outcome and errors,
    frees the headset) and flags jobs that run too long (WARNING after 120 s, stop asked after
    300 s). Called by the VRMonitor fast path every tick; costs nothing when no job is in flight.
    Returns one @{HeadsetId;Name;Mode;Ok;Cancelled;Error;DurationMs} per finished capture job
    (warm-ups excluded). A warm-up that failed closes the pool: captures then start inline.
.EXAMPLE
    $done = @(Update-ScrcpyCaptureWorkers)
#>
function Update-ScrcpyCaptureWorkers {
    $w = $global:ScrcpyCaptureWorkers
    if (-not $w -or $w.Jobs.Count -eq 0) { return @() }
    $done = @()
    $warmFailed = $false
    foreach ($key in @($w.Jobs.Keys)) {
        $e = $w.Jobs[$key]
        $job = $e.Job
        if ($e.Handle.IsCompleted) {
            $r = $null
            try { $r = @($e.PS.EndInvoke($e.Handle)) | Select-Object -Last 1 } catch { $r = @{ Ok = $false; Error = $_.Exception.Message } }
            foreach ($er in @($e.PS.Streams.Error | Select-Object -First 3)) {
                Write-Log ("Capture job ({0}) for {1}: {2}" -f $job.Mode, $job.Name, $er.ToString()) -Level WARNING
            }
            try { $e.PS.Dispose() } catch { }
            $w.Jobs.Remove($key)
            $ok = $false; $cancelled = $false; $err = ''; $ms = [int]((Get-Date) - $e.SubmittedAt).TotalMilliseconds
            if ($r) {
                try { $ok = [bool]$r.Ok; $cancelled = [bool]$r.Cancelled; $err = [string]$r.Error; if ($null -ne $r.DurationMs) { $ms = [int]$r.DurationMs } } catch { }
            }
            if ($job.Mode -eq 'Warm') {
                if ($ok) { Write-Log ("Capture workers: {0} ready after {1} ms." -f $job.Name, $ms) -Level DEBUG }
                else { $warmFailed = $true; Write-Log ("Capture workers: warm-up {0} failed: {1}" -f $job.Name, $err) -Level ERROR }
                continue
            }
            Write-Log ("Capture job {0} for {1} done in {2} ms (ok={3}{4}{5})" -f $job.Mode, $job.Name, $ms, $ok, $(if ($cancelled) { ', cancelled' } else { '' }), $(if ($err) { ", $err" } else { '' })) -Level DEBUG
            $done += [PSCustomObject]@{ HeadsetId = [int]$job.HeadsetId; Name = [string]$job.Name; Mode = [string]$job.Mode; Ok = $ok; Cancelled = $cancelled; Error = $err; DurationMs = $ms }
        } else {
            $age = ((Get-Date) - $e.SubmittedAt).TotalSeconds
            if ($age -gt $script:CaptureJobWarnSec -and -not $e.Warned) {
                $e.Warned = $true
                Write-Log ("Capture job {0} for {1} still running after {2} s." -f $job.Mode, $job.Name, [int]$age) -Level WARNING
            }
            if ($age -gt $script:CaptureJobStopSec -and -not $e.Stopping) {
                $e.Stopping = $true
                $job.Cancel = $true
                Write-Log ("Capture job {0} for {1} stuck for {2} s - asking it to stop." -f $job.Mode, $job.Name, [int]$age) -Level ERROR
                try { [void]$e.PS.BeginStop($null, $null) } catch { }
            }
        }
    }
    if ($warmFailed) {
        Write-Log 'Capture workers: closing the pool - captures start on the loop thread from now on.' -Level ERROR
        Stop-ScrcpyCaptureWorkers -TimeoutSec 0
    }
    return $done
}

<#
.SYNOPSIS
    $true while a capture job for the headset (-HeadsetId) is in flight in this process.
.EXAMPLE
    if (Test-ScrcpyCaptureBusy -HeadsetId 3) { 'busy' }
#>
function Test-ScrcpyCaptureBusy {
    param([int]$HeadsetId)
    $w = $global:ScrcpyCaptureWorkers
    return [bool]($w -and $HeadsetId -gt 0 -and $w.Jobs.ContainsKey([string]$HeadsetId))
}

<#
.SYNOPSIS
    Number of capture jobs in flight in this process (warm-ups excluded). 0 without a pool.
.EXAMPLE
    if ((Get-ScrcpyCaptureBusyCount) -eq 0) { Confirm-StreamBenchmarkPause -RunId $id }
#>
function Get-ScrcpyCaptureBusyCount {
    $w = $global:ScrcpyCaptureWorkers
    if (-not $w) { return 0 }
    return @($w.Jobs.Values | Where-Object { $_.Job.Mode -ne 'Warm' }).Count
}

<#
.SYNOPSIS
    Sets the Cancel flag of the in-flight capture jobs of -SafeName (or of all of them) and
    returns the safe names concerned. The job undoes its own start when it sees the flag, so the
    caller must leave those headsets alone (Stop-Scrcpy skips their teardown). @() without a pool.
.EXAMPLE
    Request-ScrcpyCaptureCancel -SafeName 'Q3_RED'
#>
function Request-ScrcpyCaptureCancel {
    param([string]$SafeName = '')
    $w = $global:ScrcpyCaptureWorkers
    if (-not $w) { return @() }
    $names = @()
    foreach ($e in @($w.Jobs.Values)) {
        if ($e.Job.Mode -eq 'Warm') { continue }
        $n = Convert-Displayname ([string]$e.Job.Name)
        if ($SafeName -and $n -ne $SafeName) { continue }
        # Only a job that has not passed its last cancel check takes the stop over (same lock
        # as the check in Invoke-ScrcpyCaptureJob). A finished job not drained yet is left out:
        # the caller tears that headset down itself.
        $claimed = $false
        [System.Threading.Monitor]::Enter($e.Job.SyncRoot)
        try { if (-not $e.Job.Done) { $e.Job.Cancel = $true; $claimed = $true } } finally { [System.Threading.Monitor]::Exit($e.Job.SyncRoot) }
        if ($claimed) { $names += $n }
    }
    if ($names.Count -gt 0) { Write-Log ("Capture workers: cancel requested for {0}" -f ($names -join ', ')) -Level DEBUG }
    return $names
}

<#
.SYNOPSIS
    Closes the capture worker pool (VRMonitor shutdown): cancels every job, waits at most
    -TimeoutSec for them (a cancelled job undoes its own start), then disposes the pool. Jobs
    still running are asked to stop. Never throws.
.EXAMPLE
    Stop-ScrcpyCaptureWorkers -TimeoutSec 8
#>
function Stop-ScrcpyCaptureWorkers {
    param([int]$TimeoutSec = 8)
    $w = $global:ScrcpyCaptureWorkers
    if (-not $w) { return }
    try {
        foreach ($e in @($w.Jobs.Values)) { $e.Job.Cancel = $true }
        $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSec))
        while ((Get-Date) -lt $deadline -and @($w.Jobs.Values | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
            Start-Sleep -Milliseconds 100
        }
        foreach ($key in @($w.Jobs.Keys)) {
            $e = $w.Jobs[$key]
            if (-not $e.Handle.IsCompleted) {
                Write-Log ("Capture workers: job {0} for {1} still running at close - stopping it." -f $e.Job.Mode, $e.Job.Name) -Level WARNING
                try { [void]$e.PS.BeginStop($null, $null) } catch { }
            } else {
                try { [void]$e.PS.EndInvoke($e.Handle) } catch { }
                try { $e.PS.Dispose() } catch { }
            }
        }
        $w.Jobs.Clear()
        try { [void]$w.Pool.BeginClose($null, $null) } catch { }
    } catch {
    } finally {
        $global:ScrcpyCaptureWorkers = $null
    }
}


function Watch-ScrcpyProcesses {
    param(
        # IP -> live info record, as the VRMonitor per-headset runspaces publish it in
        # $sharedState (stage 1 refreshed every second). When a headset has a record here,
        # its ADBWifi/Model are read from it instead of running a full synchronous
        # Get-KnownHeadsetInfos poll (ping + ADB + battery + thermal + app) just to learn
        # whether ADB is up - that poll, one headset after another, delayed every start.
        [hashtable]$HeadsetInfo = $null,
        # Limit the pass to these headset IDs (the VRMonitor fast-path start trigger).
        [int[]]$HeadsetId = $null,
        # Also restart a running capture whose pipeline broke under it (dead ffmpeg push or bridge,
        # mediamtx restarted, path not published): Get-HeadsetPipelineFaults. Passed by the
        # VRMonitor slow tick only, so mediamtx's path list is read once per slow tick.
        [switch]$CheckPipelineHealth,
        # Get-ProcessCensus snapshot (VRMonitor, S3-4): the running-capture check reads it instead of
        # a Win32_Process query per untitled scrcpy. Omitted = live lookup, as before.
        [hashtable]$Census = $null
    )

    # A stream benchmark is running (stream_benchmark.ps1, ADR-0026): it owns the capture of
    # its headset and every other stream is stopped on purpose. Starting or "correcting" any
    # scrcpy now would kill its test stream or skew its measurements.
    if ((Get-Command Test-StreamBenchmarkActive -ErrorAction SilentlyContinue) -and (Test-StreamBenchmarkActive)) {
        Write-Log "Watch-ScrcpyProcesses: stream benchmark running - watchdog paused." -Level DEBUG
        return
    }

    $pipelineFaults = @{}
    if ($CheckPipelineHealth) { $pipelineFaults = Get-HeadsetPipelineFaults }

    # Step 1: Retrieve scrcpy processes running on the machine

    # Rows whose address is unknown (released by Set-HeadsetIdentity, or never filled in)
    # are excluded: there is nothing to connect to, and probing them would only burn a
    # Get-KnownHeadsetInfos round trip per watchdog pass.
    $knownHeadsets_with_autorestart = Get-KnownHeadsets |
        Where-Object { (ConvertTo-BoolField $_.scrcpy_AutoRestart) -and -not (Test-UnknownIp $_.IPAddress) }
    if ($HeadsetId) {
        $knownHeadsets_with_autorestart = $knownHeadsets_with_autorestart | Where-Object { $HeadsetId -contains [int]$_.ID }
    }

    # For each headset with autorestart, ensure there's a scrcpy process started

    foreach ($headset in $knownHeadsets_with_autorestart) {
        Write-Log ($msg.Scrcpy.CheckHeadset -f $headset.Name, $headset.IPAddress) -Level DEBUG

        # A capture worker is starting or restarting this headset (S3-5 Step B): its scrcpy,
        # pipeline and stamp are in motion, so judging it now would only queue a second job.
        # The next pass after the job ends sees the result.
        if (Test-ScrcpyCaptureBusy -HeadsetId ([int]$headset.ID)) {
            Write-Log ("Watchdog: {0} skipped, a capture job is in flight." -f $headset.Name) -Level DEBUG
            continue
        }

        $headsetInfos = $null
        if ($HeadsetInfo -and $HeadsetInfo.ContainsKey([string]$headset.IPAddress)) {
            $headsetInfos = $HeadsetInfo[[string]$headset.IPAddress]
        }
        if (-not $headsetInfos) { $headsetInfos = Get-KnownHeadsetInfos $headset }
        if (ConvertTo-BoolField $headsetInfos.ADBWifi) {
            Write-Log ($msg.Scrcpy.CheckProcess -f $headset.Name, $headset.IPAddress) -Level DEBUG
            $runningScrcpyProcess_forThisheadset = Get-ScrcpyProcess -displayName (Convert-Displayname $headset.Name) -headsetIP $headset.IPAddress -headsetSerial $headset.SerialNumber -Census $Census

            Write-Log ($msg.Scrcpy.ProcessFound -f $runningScrcpyProcess_forThisheadset) -Level DEBUG
            if (-not $runningScrcpyProcess_forThisheadset) {
                # Queued to a capture worker in VRMonitor, inline elsewhere (Submit-ScrcpyCaptureJob).
                # The job re-reads the capture mode from config.json right before the start.
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                [void](Submit-ScrcpyCaptureJob -Headset $headset -Mode Start -Recording (ConvertTo-BoolField $headset.Record) -ScrcpyProfile $headsetProfile -Reason 'not running')
            } else {
                # scrcpy is running - has the desired state changed since it was launched?
                # Compared as one stamp (Get-ScrcpyLaunchStamp) stored by start-screenCopy, never by
                # parsing scrcpy's command line.
                $shouldRestart = $false
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                $expectedRecording = ($headset.Record -eq "True")
                $headsetModel = $headsetInfos.Model
                $safeName = Convert-Displayname $headset.Name

                $pipeline = $global:HeadsetPipelines[$safeName]
                $launchState = if ($pipeline) { $pipeline } else { $global:ScrcpyLaunchState[$safeName] }
                $storedStamp = if ($launchState) { [string]$launchState.LaunchStamp } else { '' }
                $storedTransport = ''

                if ($headsetModel -and "$headsetModel" -ne '-') {
                    $lensIpd = Get-HeadsetIpdValue -HeadsetId ([int]$headset.ID) -Model ([string]$headsetModel)
                    $captureModeNow = if ($global:CaptureMode) { $global:CaptureMode } else { 'StreamOnly' }
                    $expected = Get-ScrcpyLaunchStamp -Model ([string]$headsetModel) -ScrcpyProfile $headsetProfile -Ipd $lensIpd -Recording $expectedRecording -CaptureMode $captureModeNow
                    if (-not $storedStamp) {
                        # Started before this build, or by another process: adopt the current
                        # expectation instead of restarting a stream that may be fine.
                        $adopted = @{ LaunchStamp = $expected.Stamp; StampParts = $expected.Parts; Transport = '' }
                        if ($pipeline) {
                            $pipeline.LaunchStamp = $expected.Stamp
                            $pipeline.StampParts  = $expected.Parts
                            if (-not $pipeline.ContainsKey('Transport')) { $pipeline.Transport = '' }
                        } else {
                            $global:ScrcpyLaunchState[$safeName] = $adopted
                        }
                        Write-Log ("Watchdog: adopted the running capture of {0} (no launch stamp)." -f $headset.Name) -Level DEBUG
                    } else {
                        $storedTransport = if ($launchState.Transport) { [string]$launchState.Transport } else { '' }
                        if ($storedStamp -ne $expected.Stamp) {
                            $oldParts = $launchState.StampParts
                            $changed = @($expected.Parts.Keys | Where-Object { -not $oldParts -or ([string]$oldParts[$_] -ne [string]$expected.Parts[$_]) })
                            if ($changed.Count -eq 1 -and $changed[0] -eq 'rec') {
                                Write-Log ($msg.Scrcpy.RecordingChanged -f $headset.Name) -Level INFO
                            } elseif ($changed -contains 'merge') {
                                Write-Log ("Merged view settings changed for {0} - restarting the stream." -f $headset.Name) -Level INFO
                            } else {
                                Write-Log (($msg.Scrcpy.OptionsChanged -f $headset.Name, $headsetModel) + " (" + ($changed -join ',') + ")") -Level INFO
                            }
                            $shouldRestart = $true
                        }
                    }
                }

                # USB-first transport: move the session when the cable appears or disappears.
                # Skipped when a restart is already due for another reason - that restart
                # re-resolves the transport anyway. See Get-ScrcpyTransportDecision for the
                # three scrcpy.usb_switch_mode behaviours.
                if (-not $shouldRestart) {
                    $transportDecision = Get-ScrcpyTransportDecision -Headset $headset -CurrentTransport $storedTransport -Recording $expectedRecording
                    if ($transportDecision.Restart) {
                        Write-Log $transportDecision.Reason -Level INFO
                        $shouldRestart = $true
                    }
                }

                # Pipeline health: scrcpy runs but the stream behind it is broken (nothing would
                # ever restart it). Checked last, so a restart already due for another reason does
                # not use up the rate limit. The restart below finalises the old recording
                # (Stop-HeadsetPipeline, from start-screenCopy) and keeps recording on.
                if (-not $shouldRestart) {
                    $faultKey = Convert-Displayname $headset.Name
                    if ($pipelineFaults.ContainsKey($faultKey) -and
                        (Approve-HeadsetPipelineRestart -SafeName $faultKey -Reason $pipelineFaults[$faultKey])) {
                        $shouldRestart = $true
                    }
                }

                if ($shouldRestart) {
                    # Announce the restart now: closing the old session can take seconds and the
                    # operator must see "starting", not a dead stream.
                    Set-ScrcpyStartingState -HeadsetId ([int]$headset.ID)
                    Write-Log ($msg.Scrcpy.Restarting -f $headset.Name) -Level INFO
                    # Closing the old session (WM_CLOSE / kill), tearing its pipeline down (up to 15 s
                    # of ffmpeg grace to finalise a recording) and the new start all run in the job
                    # (Invoke-ScrcpyCaptureJob), on a capture worker in VRMonitor.
                    [void](Submit-ScrcpyCaptureJob -Headset $headset -Mode Restart -Recording $expectedRecording -ScrcpyProfile $headsetProfile `
                        -ScrcpyPid ([int](@($runningScrcpyProcess_forThisheadset)[0].Id)) -Reason 'restart')
                } else {
                    # The running session already matches: a "starting" mark set by
                    # Request-ScrcpyCheck for this headset would otherwise linger until it expires.
                    Set-ScrcpyStartingState -HeadsetId ([int]$headset.ID) -Clear
                }
            }
        } else {
            # ADB is down: nothing can start, so stop announcing a capture that cannot.
            Set-ScrcpyStartingState -HeadsetId ([int]$headset.ID) -Clear
        }
    }
}


# Gracefully stops scrcpy processes launched from this app's scrcpy folder.
# No argument: stops all owned scrcpy processes (shutdown path).
# -HeadsetName: stops only the process for that specific headset.
function Stop-Scrcpy {
    param(
        [string]$HeadsetName = '',
        [string]$HeadsetIP   = ''
    )

    # A capture job in flight (VRMonitor capture workers, S3-5 Step B) owns its headset until it
    # ends: cancel it and leave that headset's teardown to the job, which stops what it started.
    # Tearing the pipeline down here at the same time would finalise the recording twice.
    $busyNames = @(Request-ScrcpyCaptureCancel -SafeName $(if ($HeadsetName) { Convert-Displayname $HeadsetName } else { '' }))

    if ($HeadsetName) {
        $displayName = Convert-Displayname $HeadsetName
        if ($busyNames -contains $displayName) {
            Write-Log ("Stop-Scrcpy: {0} is being started by a capture job - the job will stop it." -f $displayName) -Level INFO
            return $true
        }
        $procs = @(Get-ScrcpyProcess -displayName $displayName -headsetIP $HeadsetIP)
        if (-not $procs) {
            # scrcpy already gone (crashed or exited on its own) - still tear
            # down any leftover pipe-bridge/ffmpeg-push trio for this headset
            # before returning, so the registry doesn't leak.
            Stop-HeadsetPipeline -SafeName $displayName
            Complete-DirectRecording -SafeName $displayName
            if ($msg.ScrcpyNotRunning) { Write-Log ($msg.ScrcpyNotRunning -f $displayName) -Level WARNING }
            return $false
        }
    } else {
        $procs = @(Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
                   Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" })
        if (-not $procs) {
            # No scrcpy left, but a pipeline whose scrcpy died may still hold its ffmpeg and its
            # in-process bridge: stopping "everything" must leave none of them (ADR-0035).
            foreach ($key in @(Get-SyncTableKeys -Table $global:HeadsetPipelines)) { if ($busyNames -notcontains $key) { Stop-HeadsetPipeline -SafeName $key } }
            if ($busyNames.Count -eq 0) { [void](Stop-AllHeadsetPipeBridges) }
            return $true
        }
    }

    foreach ($proc in $procs) {
        # Only a scrcpy WITH a window can be asked politely (WM_CLOSE lets it finalise a recording it
        # writes itself). StreamOnly runs with --no-window: there is nothing to close, ending it is
        # the normal stop, and its recording is written by ffmpeg, which finalises on end-of-input.
        # Warning "recording may be incomplete" for that case was noise that hid real problems.
        $hadWindow = ($proc.MainWindowHandle -ne [IntPtr]::Zero)
        $closed = $hadWindow -and $proc.CloseMainWindow()
        if ($closed) { $proc.WaitForExit(10000) | Out-Null }
        if (-not $proc.HasExited) {
            if ($hadWindow) {
                Write-Log ($msg.Scrcpy.StopTimeout -f $proc.MainWindowTitle) -Level WARNING
            } else {
                Write-Log "Stopping a windowless scrcpy (its recording, if any, is finalised by ffmpeg)." -Level DEBUG
            }
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            try { [void]$proc.WaitForExit(1000) } catch { }
        }
    }

    # Tear down pipe-mode bridge + ffmpeg push for the targeted scope.
    if ($HeadsetName) {
        $safe = Convert-Displayname $HeadsetName
        Stop-HeadsetPipeline -SafeName $safe
    } else {
        foreach ($key in @(Get-SyncTableKeys -Table $global:HeadsetPipelines)) { if ($busyNames -notcontains $key) { Stop-HeadsetPipeline -SafeName $key } }
        # Safety net: a bridge no pipeline entry tracks any more (a start that failed half-way).
        if ($busyNames.Count -eq 0) { [void](Stop-AllHeadsetPipeBridges) }
    }
    if ($HeadsetName) { Complete-DirectRecording -SafeName (Convert-Displayname $HeadsetName) }
    else { foreach ($key in @(Get-SyncTableKeys -Table $global:DirectRecordings)) { if ($busyNames -notcontains $key) { Complete-DirectRecording -SafeName $key } } }

    if ($HeadsetName) {
        Write-Log ($msg.Scrcpy.StopForHeadset -f (Convert-Displayname $HeadsetName)) -Level INFO
    } else {
        Write-Log "All scrcpy processes stopped." -Level INFO
    }
    return $true
}


function Convert-Displayname {
    param(
             [Parameter(Mandatory=$true)]
             [string]$displayName
        )
    $displayName =  $displayName.replace(" ","_") # convert displayname
    return $displayName
}


