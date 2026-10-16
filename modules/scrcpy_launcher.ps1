
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
function Get-ScrcpyProcess {
    param(
        [Parameter(Mandatory=$true)]
        [string]$displayName,
        [string]$headsetIP = '',
        # A USB launch carries -s <serial> instead of -s ip:port, so the serial identifies the
        # session just as well as the address does.
        [string]$headsetSerial = ''
    )
    $ownedProcs = Get-Process -Name "scrcpy" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }

    # Primary: match by window title (works when window is on the active virtual desktop)
    $byTitle = $ownedProcs | Where-Object { $_.MainWindowTitle -eq $displayName } | Select-Object -First 1
    if ($byTitle) { return $byTitle }

    # Fallback: match by command line - handles windows on inactive virtual desktops
    # where MainWindowTitle is empty. Requires either displayName or headsetIP in the cmdline.
    return $ownedProcs | Where-Object {
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue
        $cmdLine = $cimProc.CommandLine
        if ($cimProc) { $cimProc.Dispose() }
        if (-not $cmdLine) { return $false }
        if ($headsetIP -and $cmdLine -match [regex]::Escape($headsetIP)) { return $true }
        if ($headsetSerial -and $headsetSerial -ne '-' -and $cmdLine -match ('-s\s+\x22?' + [regex]::Escape($headsetSerial) + '(?:\x22|\s|$)')) { return $true }
        if ($cmdLine -match [regex]::Escape($displayName)) { return $true }
        return $false
    } | Select-Object -First 1
}

# -------------------------------------------------------------------
# Pipe-mode streaming pipeline (StreamOnly / StreamAndLocalWindow capture modes)
#
# Architecture: scrcpy records its H.264 stream to a Windows named pipe;
# ffmpeg reads from a paired pipe and pushes RTSP to mediamtx with -c copy.
# A tiny PowerShell background job acts as the named-pipe SERVER on both
# ends (scrcpy and ffmpeg both connect as CLIENTS), so the byte stream
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
# bridge job dies - and the stream then answers 404 with nothing to restart it. Per safe display
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
    if ($script:ScrcpyLaunchState) { $script:ScrcpyLaunchState.Remove($SafeName) }
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

# Starts a PowerShell job hosting two named-pipe servers and relaying bytes
# from In (scrcpy writes) to Out (ffmpeg reads). Returns the job object.
# The job blocks on WaitForConnection until both clients are attached, then
# loops on Read/Write. It exits cleanly when the writer (scrcpy) disconnects.
function Start-HeadsetPipeBridge {
    param(
        [Parameter(Mandatory)][string]$SafeName
    )
    $names = Get-HeadsetPipeNames -SafeName $SafeName
    # The job host is its own powershell.exe with no name of its own. It writes its PID to
    # data\bridge_<safe>.pid so the standalone reaper can kill it when main dies (S4-5);
    # removed again when the bridge ends normally.
    $bridgePidFile = Join-Path (Join-Path $global:ScriptPath 'data') ("bridge_{0}.pid" -f $SafeName)
    $job = Start-Job -Name "VrmBridge_$SafeName" -ScriptBlock {
        param($pipeIn, $pipeOut, $pidFile)
        try { [System.IO.File]::WriteAllText($pidFile, [string]$PID, (New-Object System.Text.UTF8Encoding($false))) } catch {}
        try {
            $srvIn  = New-Object System.IO.Pipes.NamedPipeServerStream(
                $pipeIn,  [System.IO.Pipes.PipeDirection]::In,  1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous, 1048576, 1048576)
            $srvOut = New-Object System.IO.Pipes.NamedPipeServerStream(
                $pipeOut, [System.IO.Pipes.PipeDirection]::Out, 1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte,
                [System.IO.Pipes.PipeOptions]::Asynchronous, 1048576, 1048576)
            # Accept both connections IN PARALLEL via async begin/end. If we wait
            # sequentially (In first, then Out), scrcpy fills the pipe-in kernel
            # buffer and errors out long before ffmpeg gets a chance to connect.
            $arIn  = $srvIn.BeginWaitForConnection($null, $null)
            $arOut = $srvOut.BeginWaitForConnection($null, $null)
            $srvIn.EndWaitForConnection($arIn)
            $srvOut.EndWaitForConnection($arOut)
            $buf = New-Object byte[] 4096
            while ($true) {
                $n = $srvIn.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                try { $srvOut.Write($buf, 0, $n); $srvOut.Flush() } catch { break }
            }
        } finally {
            try { $srvIn.Dispose()  } catch {}
            try { $srvOut.Dispose() } catch {}
            try { [System.IO.File]::Delete($pidFile) } catch {}
        }
    } -ArgumentList $names.In, $names.Out, $bridgePidFile
    return $job
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

    $errWriter = [System.IO.StreamWriter]::new($logErr, $false, [System.Text.Encoding]::UTF8)
    $errWriter.AutoFlush = $true
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $errWriter -Action {
        if ($EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) }
    }
    $proc.BeginErrorReadLine()

    return @{
        Process              = $proc
        ErrorWriter          = $errWriter
        ErrorSubscriptionId  = $errSub.Id
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

# Tears down the bridge job + ffmpeg push for one headset. Called by Stop-Scrcpy.
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
        try { Stop-Job   $entry.Bridge -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $entry.Bridge -Force -ErrorAction SilentlyContinue } catch {}
        # A stopped job's finally may not have run: drop the reaper's pid file too.
        try { [System.IO.File]::Delete((Join-Path (Join-Path $global:ScriptPath 'data') ("bridge_{0}.pid" -f $SafeName))) } catch {}
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
        Write-Log -Message ($msg.Scrcpy.AlreadyRunning -f $displayName) -Level WARNING
        Start-Sleep -Seconds 5
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
    Write-Log ("scrcpy capture for {0} over {1} ({2})" -f $displayName, $captureDevice.ConnectionType, $adb_device) -Level INFO
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
    # but its bridge job or ffmpeg push was still tracked, the named-pipe server names
    # would still be in use and a fresh bridge would fail to create.
    $bridgeJob = $null
    if ($usePipe) {
        Stop-HeadsetPipeline -SafeName $displayName
        try {
            $bridgeJob = Start-HeadsetPipeBridge -SafeName $displayName
            Start-Sleep -Milliseconds 500   # let the job create both pipe-server objects
        } catch {
            Write-Log -Message ("Failed to start pipe bridge for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            return
        }
    }

    # Per-session scrcpy logs (same reason as the ffmpeg one in Start-FfmpegStreamPush): a
    # restart must not overwrite the output of the session that just failed.
    $sessionStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    try {
        $scrcpyProc = Start-Process $scrcpy -ArgumentList $arguments -PassThru -NoNewWindow `
			-RedirectStandardOutput (Join-Path -Path $global:logFolder -ChildPath ("{0}_{1}_StandardOutput.txt" -f $displayName, $sessionStamp)) `
			-RedirectStandardError  (Join-Path -Path $global:logFolder -ChildPath ("{0}_{1}_StandardError.txt" -f $displayName, $sessionStamp))
	} catch {
        Write-Log -Message ($msg.Scrcpy.LaunchError -f $_.Exception.Message) -Level "ERROR"
        if ($bridgeJob) { try { Stop-Job $bridgeJob -EA SilentlyContinue; Remove-Job $bridgeJob -Force -EA SilentlyContinue } catch {} }
		return
    }

    # scrcpy is launched. LocalWindow has no pipeline to wait for: its window is the result.
    if (-not $usePipe) {
        $startHoldSec = 2
        $script:ScrcpyLaunchState[$displayName] = @{ LaunchStamp = $launchStamp.Stamp; StampParts = $launchStamp.Parts; Transport = $launchTransport }
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
        Start-Sleep -Milliseconds 3000
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
                Bridge              = $bridgeJob
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
                MediaMtxPid    = $mediaMtxPid
                StartedAt      = (Get-Date)
            }
            Write-Log ("Pipe pipeline up for {0}: mode={1} rtsp={2}" -f $displayName, $captureMode, $rtspUrl) -Level SUCCESS
            $startHoldSec = 4
        } catch {
            Write-Log ("Failed to start ffmpeg push for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            try { Stop-Process -Id $scrcpyProc.Id -Force -EA SilentlyContinue } catch {}
            if ($bridgeJob) { try { Stop-Job $bridgeJob -EA SilentlyContinue; Remove-Job $bridgeJob -Force -EA SilentlyContinue } catch {} }
        }
    }

    } finally {
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
# $global:HeadsetPipelines[<name>].
if (-not $script:ScrcpyLaunchState) { $script:ScrcpyLaunchState = @{} }

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
      - the pipe bridge job is no longer Running;
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
        $bridgeState = [string]$Pipeline.Bridge.State
        if ($bridgeState -ne 'Running') { return ("the pipe bridge job is {0}" -f $bridgeState) }
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
        foreach ($key in @($global:HeadsetPipelines.Keys)) {
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
        [switch]$CheckPipelineHealth
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

        $headsetInfos = $null
        if ($HeadsetInfo -and $HeadsetInfo.ContainsKey([string]$headset.IPAddress)) {
            $headsetInfos = $HeadsetInfo[[string]$headset.IPAddress]
        }
        if (-not $headsetInfos) { $headsetInfos = Get-KnownHeadsetInfos $headset }
        if (ConvertTo-BoolField $headsetInfos.ADBWifi) {
            Write-Log ($msg.Scrcpy.CheckProcess -f $headset.Name, $headset.IPAddress) -Level DEBUG
            $runningScrcpyProcess_forThisheadset = Get-ScrcpyProcess -displayName (Convert-Displayname $headset.Name) -headsetIP $headset.IPAddress -headsetSerial $headset.SerialNumber

            Write-Log ($msg.Scrcpy.ProcessFound -f $runningScrcpyProcess_forThisheadset) -Level DEBUG
            if (-not $runningScrcpyProcess_forThisheadset) {
                # Re-read capture mode from config.json to avoid a stale mode when
                # Set-CaptureMode fires between the slow-path Get-Config and this watchdog.
                # Read-ConfigJson: literal path, UTF-8, and retried across a Write-ConfigJson swap.
                try {
                    $freshJson = Read-ConfigJson -ConfigFilePath (Join-Path $global:ScriptPath "config\config.json") -NonInteractive
                    if ($freshJson -and $freshJson.Performance -and $freshJson.Performance.Capture_Mode) {
                        $global:CaptureMode = $freshJson.Performance.Capture_Mode
                    }
                } catch {}
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording (ConvertTo-BoolField $headset.Record) -scrcpyProfile $headsetProfile
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
                $launchState = if ($pipeline) { $pipeline } else { $script:ScrcpyLaunchState[$safeName] }
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
                            $script:ScrcpyLaunchState[$safeName] = $adopted
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
                    # Send WM_CLOSE so scrcpy can finalise any recording file before exiting
                    # Same rule as Stop-Scrcpy: only a scrcpy that HAS a window can be closed politely, and
                    # only a window that ignored the request deserves the "may be incomplete" warning.
                    $hadWindow = ($runningScrcpyProcess_forThisheadset.MainWindowHandle -ne [IntPtr]::Zero)
                    $closed = $hadWindow -and $runningScrcpyProcess_forThisheadset.CloseMainWindow()
                    if ($closed) {
                        $runningScrcpyProcess_forThisheadset.WaitForExit(10000) | Out-Null
                    }
                    if (-not $runningScrcpyProcess_forThisheadset.HasExited) {
                        if ($hadWindow) { Write-Log ($msg.Scrcpy.StopTimeout -f $headset.Name) -Level WARNING }
                        Stop-Process -Id $runningScrcpyProcess_forThisheadset.Id -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 1
                    }
                    Complete-DirectRecording -SafeName (Convert-Displayname $headset.Name)
                    # Tear the old pipeline down HERE (ffmpeg, bridge, and the old recording file is
                    # finalised) rather than only inside start-screenCopy, which skips it when the
                    # headset no longer answers ADB. No-op when this process holds no pipeline for it.
                    Stop-HeadsetPipeline -SafeName (Convert-Displayname $headset.Name)
                    start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording $expectedRecording -scrcpyProfile $headsetProfile
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

    if ($HeadsetName) {
        $displayName = Convert-Displayname $HeadsetName
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
        if (-not $procs) { return $true }
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
            Start-Sleep -Seconds 1
        }
    }

    # Tear down pipe-mode bridge + ffmpeg push for the targeted scope.
    if ($HeadsetName) {
        $safe = Convert-Displayname $HeadsetName
        Stop-HeadsetPipeline -SafeName $safe
    } else {
        foreach ($key in @($global:HeadsetPipelines.Keys)) { Stop-HeadsetPipeline -SafeName $key }
    }
    if ($HeadsetName) { Complete-DirectRecording -SafeName (Convert-Displayname $HeadsetName) }
    else { foreach ($key in @($global:DirectRecordings.Keys)) { Complete-DirectRecording -SafeName $key } }

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


function Install-ScrcpyDependencies {
    param (
        [string]$scrcpyFolder
    )
    # Create the scrcpy folder if it doesn't exist
    # scrcpy-server
    if (-not (Test-Path -LiteralPath "C:\msys64\mingw64\share\scrcpy\scrcpy-server")) {
        New-Item -Path "C:/msys64/mingw64/share/scrcpy/" -ItemType Directory -Force
        Copy-Item -LiteralPath "$scrcpyFolder\scrcpy-server" -Destination "C:\msys64\mingw64\share\scrcpy\" -Force
        Write-Log $msg.Scrcpy.ServerFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy server file already exists." -Level DEBUG
    }
    # scrcpy.png
    $destinationPath = "C:/msys64/mingw64/share/icons/hicolor/256x256/apps/scrcpy.png"
    if (-not (Test-Path -LiteralPath $destinationPath)) {
        New-Item -Path ([System.IO.Path]::GetDirectoryName($destinationPath)) -ItemType Directory -Force
        Copy-Item -LiteralPath "$scrcpyFolder\icon.png" -Destination $destinationPath -Force
        Write-Log $msg.Scrcpy.IconFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy icon file already exists." -Level DEBUG
    }
}
