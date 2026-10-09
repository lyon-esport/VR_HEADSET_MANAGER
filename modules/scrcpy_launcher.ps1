
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
#   EYE   = L | R                     (left or right eye)
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
    if ($parts.Count -eq 4 -and $parts[0] -in @('L','R')) {
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
        [ValidateSet('L','R')]
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
    Write-FileWithoutBom -Path $cfgPath -Content (($cfg | ConvertTo-Json -Depth 12))
    Get-Config
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
        $modelTemplate = $null
    )

    if ([string]::IsNullOrWhiteSpace($scrcpyProfile)) { $scrcpyProfile = "portrait-R-N-45-20" }
    $parts = $scrcpyProfile -split '-'

    # Backward compat: 4-part legacy format (Eye-Audio-FPS-BW) -> prepend "portrait"
    if ($parts.Count -eq 4 -and $parts[0] -in @('L','R')) {
        $parts = @('portrait') + $parts
    }

    if ($parts.Count -ne 5) {
        Write-Log ($msg.ScrcpyInvalidProfile -f $scrcpyProfile) -Level WARNING
        $parts = @('portrait', 'R', 'N', '45', '20')
    }

    $viewName  = $parts[0].ToLower()  # e.g. portrait, square, wide
    $eye       = $parts[1].ToUpper()  # L or R
    $audioPref = $parts[2].ToUpper()  # D=audio-dup, N=no-audio
    $fps       = $parts[3]            # e.g. 45
    $bw        = $parts[4]            # e.g. 20 (Mbps)

    if ($null -eq $modelTemplate) {
        $modelTemplate = $global:scrcpyParameters.$headsetModel
    }

    $audioArg = if ($audioPref -eq 'D') { "--audio-dup" } else { "--no-audio" }

    if ($null -eq $modelTemplate) {
        Write-Log $msg.ScrcpyModelUnknown -Level WARNING
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
            Write-Log ($msg.ScrcpyInvalidProfile -f "view '$viewName' not found, using '$firstKey'") -Level WARNING
        }
        if ($view) {
            $eyeObj = if ($eye -eq 'L') { $view.left_eye } else { $view.right_eye }
            if ($eyeObj) {
                $crop  = $eyeObj.crop
                $angle = $eyeObj.angle
            }
        }
    } else {
        # Legacy flat template (crop_left/crop_right/angle_left/angle_right)
        $crop  = if ($eye -eq 'L') { $modelTemplate.crop_left  } else { $modelTemplate.crop_right  }
        $angle = if ($eye -eq 'L') { $modelTemplate.angle_left } else { $modelTemplate.angle_right }
    }

    $argParts = [System.Collections.Generic.List[string]]::new()
    if ($crop -and $crop -ne '0:0:0:0') { $argParts.Add("--crop $crop") }
    if ($null -ne $angle -and "$angle" -ne "" -and [int]"$angle" -ne 0) { $argParts.Add("--angle=$angle") }
    $argParts.Add("--max-fps=$fps")
    $argParts.Add("-b ${bw}M")
    if ($modelTemplate.max_size)       { $argParts.Add("--max-size=$($modelTemplate.max_size)") }
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

    .EXAMPLE
    Complete-RecordingFile -Path 'D:\Records\2026-10-05\Q3_BLUE\Q3_BLUE_20261005_101500.mkv'
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
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
    $job = Start-Job -Name "VrmBridge_$SafeName" -ScriptBlock {
        param($pipeIn, $pipeOut)
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
        }
    } -ArgumentList $names.In, $names.Out
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
        [string]$SourceCodec = 'h264'
    )
    $names = Get-HeadsetPipeNames -SafeName $SafeName
    # One file PER SESSION (timestamped), never overwritten: a stream that keeps dying and
    # restarting used to leave only the LAST session's stderr, so the failing ones could not
    # be analysed - and a still-running previous ffmpeg held the shared file open, failing
    # the next start with "file in use". Get-LogSources' ffmpeg pattern still matches, and
    # Remove-OldLogFiles purges them on the usual retention.
    $logErr = Join-Path $global:logFolder ("{0}_{1}_ffmpegPush_stderr.txt" -f $SafeName, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.AddRange([string[]]@('-hide_banner','-loglevel','warning'))
    # Passthrough needs the bitstream filter matching the actual stream codec
    # (mkv/AVCC -> Annex-B for RTSP). An unrecognized codec cannot be safely
    # passed through - force re-encode for this stream so it doesn't die like
    # the h265-with-h264-filter bug this branch was fixed for.
    $forceReencode = $global:mediamtxReencode
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
    # Output 1: RTSP push into mediamtx. mediamtx remuxes this single source into
    # RTSP / HLS / WebRTC (WHEP) for downstream viewers, so re-encoding here caps
    # bandwidth on every viewer protocol (including the video_monitor web page).
    # The optional file recording output below stays -c copy regardless, so on-disk
    # captures keep source quality.
    if ($forceReencode) {
        $enc = Get-GpuEncoder
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
        $rtspOut.AddRange([string[]]@('-map','0:v:0'))
        # Hardware H.264 encoders (QSV, NVENC, AMF, MF) cannot open a frame wider or taller
        # than 4096 px. An uncapped capture (model max_size 0 with the 'fullscreen' view, i.e.
        # no crop) is the Quest 3's full native frame, wider than that: h264_qsv refused to
        # open ("Current resolution is unsupported"), ffmpeg exited before publishing, and
        # the watchdog restarted scrcpy in a loop with no stream ever reaching mediamtx.
        # HEVC encoders go to 8192, which is why only h264 failed. Scale down to fit, keeping
        # the aspect ratio and even dimensions; a frame already within 4096 is left as is.
        if ($enc.Name -like 'h264_*') {
            $rtspOut.AddRange([string[]]@('-vf', 'scale=w=min(iw\,4096):h=min(ih\,4096):force_original_aspect_ratio=decrease:force_divisible_by=2'))
        }
        $rtspOut.AddRange([string[]]$encParams)
        if ($enc.ExtraArgs -and $enc.ExtraArgs.Count -gt 0) { $rtspOut.AddRange([string[]]$enc.ExtraArgs) }
        # -flush_packets / -muxdelay / -muxpreload: tell the RTSP muxer to push
        # every packet immediately and not pre-buffer any startup interval.
        $rtspOut.AddRange([string[]]@('-r',[string]$fps,'-pix_fmt','yuv420p',
            '-pkt_size','1316','-flush_packets','1','-muxdelay','0','-muxpreload','0',
            '-f','rtsp','-rtsp_transport','tcp',$RtspUrl))
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
    if ($RecordFile) {
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

# Sets the global capture mode, persists it to config.json, and restarts any
# currently-running scrcpy session that's affected by the change. Used by the
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
        Write-FileWithoutBom -Path $cfgPath -Content ($cfg | ConvertTo-Json -Depth 20)
    } catch {
        Write-Log ("Set-CaptureMode: failed to update config.json: {0}" -f $_.Exception.Message) -Level ERROR
        return $false
    }
    $global:CaptureMode = $Mode

    # mediamtx YAML structure depends on the mode (paths: {} vs all_others:).
    # LocalWindow uses paths: {} (no publishers accepted),
    # pipe modes (StreamOnly/StreamAndLocalWindow) need all_others:. Restart mediamtx
    # only when crossing that boundary.
    $crossedBoundary = (($previous -eq 'LocalWindow') -ne ($Mode -eq 'LocalWindow'))
    if ($crossedBoundary) {
        try { Stop-MediaMtx; Start-Sleep -Milliseconds 500; Start-MediaMtx } catch {
            Write-Log ("Set-CaptureMode: mediamtx restart failed: {0}" -f $_.Exception.Message) -Level WARNING
        }
    }

    # Kill every owned scrcpy process so they get restarted in the new mode.
    # We deliberately do NOT call start-screenCopy here:
    #  - This helper is called both from the web server (separate process - it does
    #    not own the running pipelines) and from the CLI menu (main process).
    #    Restarting from the wrong process would orphan the bridge job and lose
    #    track of the pipeline.
    #  - The VRMonitor background job reloads config.json on every slow cycle
    #    (refresh_timer), then Watch-ScrcpyProcesses sees a headset with
    #    AutoRestart=True and no running scrcpy, and respawns it with the freshly
    #    loaded $global:CaptureMode. That is the single owner of restarts.
    $owned = @(Get-Process -Name scrcpy -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" })
    foreach ($p in $owned) {
        $title = if ($p.MainWindowTitle) { $p.MainWindowTitle } else { '' }
        $headset = $null
        if ($title) {
            $headset = Get-KnownHeadsets | Where-Object { (Convert-Displayname $_.Name) -eq $title } | Select-Object -First 1
        }
        if ($headset) {
            Write-Log ("Set-CaptureMode: stopping {0} so VRMonitor restarts it in {1} mode" -f $headset.Name, $Mode) -Level INFO
            Stop-Scrcpy -HeadsetName $headset.Name | Out-Null
        } else {
            # Headless scrcpy has no window title - fall back to direct PID kill.
            Write-Log ("Set-CaptureMode: stopping scrcpy pid={0} (no window title, headless) so VRMonitor restarts it" -f $p.Id) -Level INFO
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
        }
    }
    # Local registry cleanup (web/main may both hold dead entries after a kill)
    foreach ($key in @($global:HeadsetPipelines.Keys)) { Stop-HeadsetPipeline -SafeName $key }

    Write-Log ("CaptureMode set to {0} (was {1}); VRMonitor will respawn on next cycle" -f $Mode, $previous) -Level SUCCESS
    return $true
}

# Tears down the bridge job + ffmpeg push for one headset. Called by Stop-Scrcpy.
function Stop-HeadsetPipeline {
    param([Parameter(Mandatory)][string]$SafeName)
    $entry = $global:HeadsetPipelines[$SafeName]
    if (-not $entry) { return }
    if ($entry.FfmpegProcess) {
        $ff = $entry.FfmpegProcess
        try {
            if (-not $ff.HasExited) {
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
                if (-not $ff.WaitForExit(15000)) {
                    Write-Log ("Stop-HeadsetPipeline: ffmpeg for {0} did not exit gracefully within 15 s - forcing kill. The recording '{1}' may lack its index: it stays playable in VLC / ffmpeg, and can be repaired with: ffmpeg -i <file> -c copy <fixed>.mkv" -f $SafeName, $entry.RecordFile) -Level WARNING
                    try { Stop-Process -Id $ff.Id -Force -ErrorAction SilentlyContinue } catch {}
                    try { [void]$ff.WaitForExit(3000) } catch {}
                }
            }
        } catch {}
        try { $ff.CancelErrorRead() } catch {}
    }
    # ffmpeg is gone: check what it left behind (empty file from an attempt that never got video).
    if ($entry.RecordFile) { [void](Complete-RecordingFile -Path $entry.RecordFile) }
    if ($entry.FfmpegErrorSubId) {
        try { Unregister-Event -SubscriptionId $entry.FfmpegErrorSubId -ErrorAction SilentlyContinue } catch {}
    }
    if ($entry.FfmpegErrorWriter) {
        try { $entry.FfmpegErrorWriter.Dispose() } catch {}
    }
    if ($entry.Bridge) {
        try { Stop-Job   $entry.Bridge -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job $entry.Bridge -Force -ErrorAction SilentlyContinue } catch {}
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
        [string]$transport = 'Auto'

    )

    $displayName =  Convert-Displayname($displayName)

    # Guard: skip if a scrcpy window for this headset is already running
    if (Get-ScrcpyProcess -displayName $displayName) {
        Write-Log -Message ($msg.ScrcpyAlreadyRunning -f $displayName) -Level WARNING
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
    $captureDevice = $null
    try {
        Write-Log -Message ($msg.ScrcpyCheckingAdb -f "$headsetIP`:$adbPort") -Level "INFO"
        $captureDevice = Resolve-HeadsetAdbDevice -Headset $knownRow -PreferTransport $transport -AdbPort $adbPort
    } catch {
        Write-Log -Message ($msg.ScrcpyExecError -f $_.Exception.Message) -Level "ERROR"
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
    Write-Log -Message ($msg.ScrcpyModelDetected -f $headsetModel) -Level "INFO"
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



    $options = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $scrcpyProfile

    # Check that scrcpy exists
    if (-not (Test-Path $scrcpy)) {
        Write-Log -Message ($msg.ScrcpyNotFound -f $scrcpyPath) -Level "ERROR"
        return
    }

    # Check if recording is enabled
    if ($recording) {
        $timestamp_Today = Get-Date -Format "yyyy-MM-dd"
        $recordFolder = Join-Path -Path $global:scrcpyRecordFolder -ChildPath ("${timestamp_Today}\${displayName}")

        if (-not (Test-Path $recordFolder)) {
            New-Item -ItemType Directory -Path $recordFolder -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $recordFile = Join-Path -Path $recordFolder -ChildPath "${displayName}_$timestamp.mkv"
        $recordOption = "--record=`"$recordFile`""
        Write-Log -Message ($msg.ScrcpyRecording -f $recordFile) -Level "INFO"
    } else {
        $recordOption = ""
        $recordFile = ''
    }
    # Dispatch on capture mode:
    #   StreamOnly          -> --no-window + record-to-pipe + ffmpeg push to RTSP
    #   StreamAndLocalWindow-> visible window + record-to-pipe + ffmpeg push to RTSP (no GDI)
    #   LocalWindow         -> visible window only, no streaming pipeline (file recording via scrcpy)
    $captureMode = if ($global:CaptureMode) { $global:CaptureMode } else { 'StreamOnly' }
    $usePipe = ($captureMode -in @('StreamOnly','StreamAndLocalWindow'))

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
    #.\scrcpy.exe --crop 1664:1304:2260:450 --angle=-21 --max-fps 45 -b 16M --no-audio --video-buffer=100 --video-codec=h264 --video-encoder=OMX.qcom.video.encoder.avc -s $adb_device
    #.\sources\scrcpy-win64-v3.3\scrcpy.exe -s 192.168.1.243:5555 -b20m --crop=1664:1304:2260:450 --angle=-21 --max-size=800 --max-fps=30 --video-codec=h265 --no-audio --window-title=Q3_BLUE

	Write-Log -Message ($msg.ScrcpyLaunching -f $arguments) -Level "SUCCESS"

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
        Write-Log -Message ($msg.ScrcpyLaunchError -f $_.Exception.Message) -Level "ERROR"
        if ($bridgeJob) { try { Stop-Job $bridgeJob -EA SilentlyContinue; Remove-Job $bridgeJob -Force -EA SilentlyContinue } catch {} }
		return
    }

    # Windowed LocalWindow mode: scrcpy itself writes the recording. Remember the file so it can be
    # checked once the session is over (Complete-DirectRecording).
    if (-not $usePipe -and $recordFile) { $global:DirectRecordings[$displayName] = $recordFile }

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
            $ffmpegPush = Start-FfmpegStreamPush -SafeName $displayName -RtspUrl $rtspUrl -RecordFile $ffmpegRecord -SourceCodec $sourceCodec
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
                StartedAt      = (Get-Date)
            }
            Write-Log ("Pipe pipeline up for {0}: mode={1} rtsp={2}" -f $displayName, $captureMode, $rtspUrl) -Level SUCCESS
        } catch {
            Write-Log ("Failed to start ffmpeg push for {0}: {1}" -f $displayName, $_.Exception.Message) -Level "ERROR"
            try { Stop-Process -Id $scrcpyProc.Id -Force -EA SilentlyContinue } catch {}
            if ($bridgeJob) { try { Stop-Job $bridgeJob -EA SilentlyContinue; Remove-Job $bridgeJob -Force -EA SilentlyContinue } catch {} }
        }
    }
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
    $d = Get-ScrcpyTransportDecision -Headset $headset -CommandLine $cmdLine -Recording $false
    if ($d.Restart) { Write-Log $d.Reason }
    #>
    param(
        [Parameter(Mandatory=$true)] $Headset,
        [string]$CommandLine,
        [bool]$Recording = $false
    )

    $d = [PSCustomObject]@{ Restart = $false; Reason = ''; Current = '-'; Preferred = '-' }
    if (-not $CommandLine) { return $d }
    if ($CommandLine -match '-s\s+\x22?([^\s\x22]+)') {
        $d.Current = $(if ($Matches[1] -match ':') { 'WiFi' } else { 'USB' })
    } else {
        return $d
    }

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


function Watch-ScrcpyProcesses {
    param(
        # IP -> live info record, as the VRMonitor per-headset runspaces publish it in
        # $sharedState (stage 1 refreshed every second). When a headset has a record here,
        # its ADBWifi/Model are read from it instead of running a full synchronous
        # Get-KnownHeadsetInfos poll (ping + ADB + battery + thermal + app) just to learn
        # whether ADB is up - that poll, one headset after another, delayed every start.
        [hashtable]$HeadsetInfo = $null,
        # Limit the pass to these headset IDs (the VRMonitor fast-path start trigger).
        [int[]]$HeadsetId = $null
    )

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
        Write-Log ($msg.ScrcpyCheckHeadset -f $headset.Name, $headset.IPAddress) -Level DEBUG

        $headsetInfos = $null
        if ($HeadsetInfo -and $HeadsetInfo.ContainsKey([string]$headset.IPAddress)) {
            $headsetInfos = $HeadsetInfo[[string]$headset.IPAddress]
        }
        if (-not $headsetInfos) { $headsetInfos = Get-KnownHeadsetInfos $headset }
        if (ConvertTo-BoolField $headsetInfos.ADBWifi) {
            Write-Log ($msg.ScrcpyCheckProcess -f $headset.Name, $headset.IPAddress) -Level DEBUG
            $runningScrcpyProcess_forThisheadset = Get-ScrcpyProcess -displayName (Convert-Displayname $headset.Name) -headsetIP $headset.IPAddress -headsetSerial $headset.SerialNumber

            Write-Log ($msg.ScrcpyProcessFound -f $runningScrcpyProcess_forThisheadset) -Level DEBUG
            if (-not $runningScrcpyProcess_forThisheadset) {
                # Re-read capture mode from config.json to avoid a stale mode when
                # Set-CaptureMode fires between the slow-path Get-Config and this watchdog.
                # Uses -LiteralPath and -Encoding UTF8 (mandatory for the accented project root).
                try {
                    $freshJson = Get-Content -LiteralPath (Join-Path $global:ScriptPath "config\config.json") -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if ($freshJson -and $freshJson.Performance -and $freshJson.Performance.Capture_Mode) {
                        $global:CaptureMode = $freshJson.Performance.Capture_Mode
                    }
                } catch {}
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording (ConvertTo-BoolField $headset.Record) -scrcpyProfile $headsetProfile
            } else {
                # scrcpy is running - check if parameters have changed
                $shouldRestart = $false
                $headsetProfile = if ($headset.ScrcpyProfile) { $headset.ScrcpyProfile } else { "R-N-45-20" }
                $expectedRecording = ($headset.Record -eq "True")

                $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($runningScrcpyProcess_forThisheadset.Id)" -ErrorAction SilentlyContinue
                $cmdLine = $cimProc.CommandLine
                if ($cimProc) { $cimProc.Dispose() }

                # Check recording option mismatch only when we could actually read the command line.
                # If $cmdLine is null (process vanished from WMI), skip the check to avoid a
                # spurious restart caused by $false -ne $true when recording is expected.
                # In pipe mode, scrcpy's --record always points to a named pipe (streaming);
                # the recording file is written by ffmpeg as a second output. The cmdline does
                # NOT carry that file, so we compare against the pipeline registry instead.
                $inPipeMode = $cmdLine -and ($cmdLine -match '--record=\\\\\.\\pipe\\')
                if ($inPipeMode) {
                    $safeName = Convert-Displayname $headset.Name
                    $pipeline = $global:HeadsetPipelines[$safeName]
                    $currentRecording = if ($pipeline) { [bool]$pipeline.Recording } else { $false }
                    if ($currentRecording -ne $expectedRecording) {
                        Write-Log ($msg.ScrcpyRecordingChanged -f $headset.Name) -Level INFO
                        $shouldRestart = $true
                    }
                } else {
                    $hasRecord = if ($cmdLine) { [bool]($cmdLine -match '--record=(?!\\\\\.\\pipe\\)') } else { $expectedRecording }
                    if ($hasRecord -ne $expectedRecording) {
                        Write-Log ($msg.ScrcpyRecordingChanged -f $headset.Name) -Level INFO
                        $shouldRestart = $true
                    }
                }

                # Check scrcpy options and profile mismatch
                if (-not $shouldRestart) {
                    $headsetModel = $headsetInfos.Model
                    $expectedOptions = ConvertTo-ScrcpyArguments -headsetModel $headsetModel -scrcpyProfile $headsetProfile
                    if ($expectedOptions -ne "") {
                        # Strip pipe-mode args (added by start-screenCopy on top of ConvertTo-ScrcpyArguments
                        # output) from the cmdline before comparison, otherwise the watchdog will see them as
                        # "options changed" and restart-loop every cycle.
                        $cmdLineForCompare = $cmdLine
                        $cmdLineForCompare = $cmdLineForCompare -replace '--record=\\\\\.\\pipe\\\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--record-format=\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--video-codec-options=\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--no-window', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--no-playback', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--render-driver=\S+', ''
                        $cmdLineForCompare = $cmdLineForCompare -replace '--window-title=\S+', ''
                        $normalizedCmdLine = ($cmdLineForCompare -replace '\s+', ' ').Trim()
                        $normalizedOptions = ($expectedOptions -replace '\s+', ' ').Trim()
                        if ($normalizedCmdLine -notlike "*$normalizedOptions*") {
                            Write-Log ($msg.ScrcpyOptionsChanged -f $headset.Name, $headsetModel) -Level INFO
                            $shouldRestart = $true
                        }
                    }
                }

                # USB-first transport: move the session when the cable appears or disappears.
                # Skipped when a restart is already due for another reason - that restart
                # re-resolves the transport anyway. See Get-ScrcpyTransportDecision for the
                # three scrcpy.usb_switch_mode behaviours.
                if (-not $shouldRestart) {
                    $transportDecision = Get-ScrcpyTransportDecision -Headset $headset -CommandLine $cmdLine -Recording $expectedRecording
                    if ($transportDecision.Restart) {
                        Write-Log $transportDecision.Reason -Level INFO
                        $shouldRestart = $true
                    }
                }

                if ($shouldRestart) {
                    Write-Log ($msg.ScrcpyRestarting -f $headset.Name) -Level INFO
                    # Send WM_CLOSE so scrcpy can finalise any recording file before exiting
                    # Same rule as Stop-Scrcpy: only a scrcpy that HAS a window can be closed politely, and
                    # only a window that ignored the request deserves the "may be incomplete" warning.
                    $hadWindow = ($runningScrcpyProcess_forThisheadset.MainWindowHandle -ne [IntPtr]::Zero)
                    $closed = $hadWindow -and $runningScrcpyProcess_forThisheadset.CloseMainWindow()
                    if ($closed) {
                        $runningScrcpyProcess_forThisheadset.WaitForExit(10000) | Out-Null
                    }
                    if (-not $runningScrcpyProcess_forThisheadset.HasExited) {
                        if ($hadWindow) { Write-Log ($msg.ScrcpyStopTimeout -f $headset.Name) -Level WARNING }
                        Stop-Process -Id $runningScrcpyProcess_forThisheadset.Id -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 1
                    }
                    Complete-DirectRecording -SafeName (Convert-Displayname $headset.Name)
                    start-screenCopy -displayName $headset.Name -headsetIP $headset.IPAddress -recording $expectedRecording -scrcpyProfile $headsetProfile
                }
            }
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
                Write-Log ($msg.ScrcpyStopTimeout -f $proc.MainWindowTitle) -Level WARNING
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
        Write-Log ($msg.ScrcpyStopForHeadset -f (Convert-Displayname $HeadsetName)) -Level INFO
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
    if (-not (Test-Path -Path "C:\msys64\mingw64\share\scrcpy\scrcpy-server")) {
        New-Item -Path "C:/msys64/mingw64/share/scrcpy/" -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\scrcpy-server" -Destination "C:\msys64\mingw64\share\scrcpy\" -Force
        Write-Log $msg.ScrcpyServerFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy server file already exists." -Level DEBUG
    }
    # scrcpy.png
    $destinationPath = "C:/msys64/mingw64/share/icons/hicolor/256x256/apps/scrcpy.png"
    if (-not (Test-Path -Path $destinationPath)) {
        New-Item -Path ([System.IO.Path]::GetDirectoryName($destinationPath)) -ItemType Directory -Force
        Copy-Item -Path "$scrcpyFolder\icon.png" -Destination $destinationPath -Force
        Write-Log $msg.ScrcpyIconFileCopied -Level INFO
    } else {
        #Write-Log "Scrcpy icon file already exists." -Level DEBUG
    }
}
