# recordings_playback.ps1 - browser preview of a recorded .mkv (ADR-0029).
#
# A recording is re-encoded live to a small h264 stream by ffmpeg and published to the running
# mediamtx under playback_<token>; the browser plays it over WHEP. Sessions are short lived and are
# kept alive by a heartbeat (Update-RecordingPlaybackHeartbeat); Remove-IdleRecordingPlayback reaps
# the ones that stopped pinging. Auto-loaded by scripts_init.ps1's module glob.
# Nothing here throws: every function returns Ok=$false / $false / 0 on failure.

# token -> @{Process;RecordingId;StartedAt;LastPing;LogFile}
if (-not (Get-Variable -Name RecordingPlaybackSessions -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RecordingPlaybackSessions = @{}
}

function Test-RecordingPlaybackAvailable {
    <#
    .SYNOPSIS
        Tells whether the browser preview of a recording can work right now.
    .DESCRIPTION
        Needs the bundled ffmpeg, mediamtx enabled AND running, and a capture mode that lets
        mediamtx accept a publisher (LocalWindow writes an empty path list).
    .EXAMPLE
        $a = Test-RecordingPlaybackAvailable
        if (-not $a.Ok) { Write-Log $a.Reason -Level WARNING }
    #>
    [CmdletBinding()]
    param()
    try {
        if (-not $global:ffmpegFilePath -or -not (Test-Path -LiteralPath $global:ffmpegFilePath)) {
            return @{ Ok = $false; Reason = 'ffmpeg is not installed.' }
        }
        if (-not $global:mediamtxEnabled) {
            return @{ Ok = $false; Reason = 'Streaming server (mediamtx) is disabled in the configuration.' }
        }
        if ($global:CaptureMode -eq 'LocalWindow') {
            return @{ Ok = $false; Reason = 'Capture mode is LocalWindow: the streaming server accepts no stream.' }
        }
        if (-not (Get-MediaMtxProcess)) {
            return @{ Ok = $false; Reason = 'Streaming server (mediamtx) is not running.' }
        }
        return @{ Ok = $true; Reason = '' }
    } catch {
        return @{ Ok = $false; Reason = ("Playback check failed: {0}" -f $_.Exception.Message) }
    }
}

function Set-PlaybackMediaPath {
    <#
    .SYNOPSIS
        Adds (-Add) or deletes (-Remove) the mediamtx path of one preview session via the REST API.
    .DESCRIPTION
        The preview cannot rely on the YAML catch-all path: Sync-RestreamPaths used to delete
        'all_others' and the API path list is what mediamtx actually enforces. So each session
        registers playback_<token> itself before publishing and removes it when it stops.
        Returns $true on success; an already existing path on -Add counts as success. Never throws.
    .EXAMPLE
        Set-PlaybackMediaPath -StreamPath 'playback_a1b2c3d4' -Add
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StreamPath, [switch]$Add, [switch]$Remove)
    $apiPort = if ($global:mediamtxApiPort) { $global:mediamtxApiPort } else { 9997 }
    try {
        if ($Add) {
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $null = Invoke-RestMethod -Uri ("http://localhost:{0}/v3/config/paths/add/{1}" -f $apiPort, $StreamPath) `
                -Method Post -Body $bodyBytes -ContentType 'application/json' -TimeoutSec 3 -ErrorAction Stop
        } elseif ($Remove) {
            $null = Invoke-RestMethod -Uri ("http://localhost:{0}/v3/config/paths/delete/{1}" -f $apiPort, $StreamPath) `
                -Method Delete -TimeoutSec 3 -ErrorAction Stop
        }
        return $true
    } catch {
        $m = $_.Exception.Message
        if ($Add -and $m -match 'already exists|400') {
            # The path may already be there (catch-all or a previous add): publishing will tell.
            Write-Log ("Recording playback: mediamtx path {0} not added ({1})" -f $StreamPath, $m) -Level DEBUG
            return $true
        }
        Write-Log ("Recording playback: mediamtx path {0} {1} failed: {2}" -f $StreamPath, $(if ($Add) { 'add' } else { 'delete' }), $m) -Level WARNING
        return $false
    }
}

function Start-RecordingPlayback {
    <#
    .SYNOPSIS
        Starts a live h264 re-encode of a recording into mediamtx and returns its WHEP URL.
    .DESCRIPTION
        -Speed is limited to 1, 2 or 4. -OffsetSec is clamped to [0, duration-1] when the duration
        is known. -FilePath bypasses the catalogue (testing). Caps concurrent sessions at
        $global:Recordings_playback_max_sessions after reaping idle ones: at the cap the least
        recently pinged session is evicted so the new request succeeds.
    .EXAMPLE
        $p = Start-RecordingPlayback -RecordingId 12 -OffsetSec 30 -Speed 2 -HostName '192.168.1.10'
        if ($p.Ok) { $p.WhepUrl }
    #>
    [CmdletBinding(DefaultParameterSetName = 'Id')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Id')][int]$RecordingId,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$FilePath,
        [double]$OffsetSec = 0,
        [int]$Speed = 1,
        [string]$HostName = ''
    )
    $fail = { param($t) @{ Ok = $false; Token = $null; WhepUrl = $null; StreamPath = $null; OffsetSec = 0; Speed = 1; Error = $t } }
    try {
        $avail = Test-RecordingPlaybackAvailable
        if (-not $avail.Ok) { return (& $fail $avail.Reason) }

        $file = $FilePath
        $duration = $null
        $recId = 0
        if ($PSCmdlet.ParameterSetName -eq 'Id') {
            $recId = $RecordingId
            $row = @(Invoke-DbQuery -Name 'recordings.get' -Parameters @{ id = $RecordingId }) | Select-Object -First 1
            if (-not $row) { return (& $fail 'Recording not found.') }
            $file = [string]$row.file_path
            if ($null -ne $row.duration_sec -and $row.duration_sec -isnot [System.DBNull]) { $duration = [double]$row.duration_sec }
        }
        if (-not $file -or -not (Test-Path -LiteralPath $file)) { return (& $fail 'Recording file is missing on disk.') }

        if ($Speed -notin 1, 2, 4) { $Speed = 1 }
        $off = [Math]::Max(0.0, $OffsetSec)
        if ($null -ne $duration -and $duration -gt 0) { $off = [Math]::Min($off, [Math]::Max(0.0, $duration - 1)) }

        # -readrate needs ffmpeg 5 or newer; older builds fall back to -re at normal speed.
        $useReadrate = $true
        $ver = Get-FfmpegVersion
        if ($ver -match '^(\d+)\.' -and [int]$Matches[1] -lt 5) { $useReadrate = $false; $Speed = 1 }

        $null = Remove-IdleRecordingPlayback
        $max = if ($global:Recordings_playback_max_sessions) { [int]$global:Recordings_playback_max_sessions } else { 2 }
        # At the cap, the newest request wins: evict the least recently pinged session(s).
        while ($script:RecordingPlaybackSessions.Count -ge $max) {
            $oldest = @($script:RecordingPlaybackSessions.GetEnumerator() |
                Sort-Object { $_.Value.LastPing }, { $_.Value.StartedAt } | Select-Object -First 1)
            if (-not $oldest -or -not (Stop-RecordingPlayback -Token $oldest[0].Key)) {
                return (& $fail ("Too many previews running ({0}). Close one first." -f $max))
            }
            Write-Log ("Recording playback: evicted {0} to make room" -f $oldest[0].Key) -Level INFO
        }

        $maxH = if ($global:Recordings_playback_max_height)  { [int]$global:Recordings_playback_max_height }  else { 720 }
        $fps  = if ($global:Recordings_playback_fps)         { [int]$global:Recordings_playback_fps }         else { 30 }
        $kbps = if ($global:Recordings_playback_bitrate_kbps){ [int]$global:Recordings_playback_bitrate_kbps }else { 2000 }

        # The preview is always h264 (browser WHEP). Get-GpuEncoder follows mediamtx.codec, so when
        # that is h265 the software h264 encoder is used instead.
        $enc = $null
        try { $enc = Get-GpuEncoder } catch { $enc = $null }
        if (-not $enc -or ([string]$enc.Name -notmatch '264')) {
            $enc = @{ Name = 'libx264'; ExtraArgs = @() }
        }
        $encParams = @(Get-StreamEncoderArgs -EncoderName $enc.Name -Bitrate ("{0}k" -f $kbps) -Gop ([string]$fps))
        $encExtra = @(); if ($enc.ExtraArgs) { $encExtra = @($enc.ExtraArgs) }

        $token = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Minimum 0 -Maximum 16) })
        $streamPath = "playback_$token"
        $rtspPort = if ($global:mediamtxRtspPort) { $global:mediamtxRtspPort } else { 8554 }
        $rtspUrl = "rtsp://127.0.0.1:$rtspPort/$streamPath"

        $vf = "scale=-2:'min($maxH,ih)'"
        if ($Speed -gt 1) { $vf = "setpts=PTS/$Speed," + $vf }
        $vf += ",fps=$fps"

        $argList = New-Object System.Collections.Generic.List[string]
        $argList.AddRange([string[]]@('-hide_banner', '-loglevel', 'warning'))
        if ($useReadrate) { $argList.AddRange([string[]]@('-readrate', [string]$Speed)) } else { $argList.Add('-re') }
        $argList.AddRange([string[]]@('-ss', ($off.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)), '-i', ('"{0}"' -f $file), '-an', '-vf', ('"{0}"' -f $vf)))
        $argList.AddRange([string[]]$encParams)
        $argList.AddRange([string[]]$encExtra)
        $argList.AddRange([string[]]@('-pix_fmt', 'yuv420p', '-f', 'rtsp', '-rtsp_transport', 'tcp', $rtspUrl))

        $logDir = if ($global:logFolder) { $global:logFolder } else { [System.IO.Path]::GetTempPath() }
        $logFile = Join-Path $logDir ("playback_{0}_{1}_ffmpeg_stderr.txt" -f $token, (Get-Date -Format 'yyyyMMdd_HHmmss'))

        if (-not (Set-PlaybackMediaPath -StreamPath $streamPath -Add)) {
            return (& $fail 'The streaming server refused the preview path (mediamtx API unreachable?).')
        }

        $proc = Start-Process -FilePath $global:ffmpegFilePath -ArgumentList ($argList -join ' ') `
            -PassThru -WindowStyle Hidden -RedirectStandardError $logFile
        if (-not $proc) {
            $null = Set-PlaybackMediaPath -StreamPath $streamPath -Remove
            return (& $fail 'Could not start ffmpeg.')
        }

        $now = Get-Date
        $script:RecordingPlaybackSessions[$token] = @{
            Process = $proc; RecordingId = $recId; StartedAt = $now; LastPing = $now; LogFile = $logFile; StreamPath = $streamPath
        }
        Write-Log ("Recording playback started: recording={0} token={1} offset={2}s speed={3}x encoder={4}" -f $recId, $token, $off, $Speed, $enc.Name) -Level INFO

        $hostPart = if ($HostName) { $HostName } else { '127.0.0.1' }
        $webrtcPort = if ($global:mediamtxWebrtcPort) { $global:mediamtxWebrtcPort } else { 8889 }
        return @{
            Ok = $true; Token = $token
            WhepUrl = ("http://{0}:{1}/{2}/whep" -f $hostPart, $webrtcPort, $streamPath)
            StreamPath = $streamPath; OffsetSec = $off; Speed = $Speed; Error = $null
        }
    } catch {
        return (& $fail $_.Exception.Message)
    }
}

function Stop-RecordingPlayback {
    <#
    .SYNOPSIS
        Stops one preview session (-Token) or all of them (-All) and forgets them.
    .EXAMPLE
        Stop-RecordingPlayback -Token 'a1b2c3d4'
    .EXAMPLE
        Stop-RecordingPlayback -All
    #>
    [CmdletBinding()]
    param([string]$Token, [switch]$All)
    try {
        $tokens = @()
        if ($All) { $tokens = @($script:RecordingPlaybackSessions.Keys) }
        elseif ($Token -and $script:RecordingPlaybackSessions.ContainsKey($Token)) { $tokens = @($Token) }
        else { return $false }
        foreach ($t in $tokens) {
            $s = $script:RecordingPlaybackSessions[$t]
            try { if ($s.Process -and -not $s.Process.HasExited) { Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue } } catch { }
            $sp = if ($s.StreamPath) { $s.StreamPath } else { "playback_$t" }
            $null = Set-PlaybackMediaPath -StreamPath $sp -Remove
            $script:RecordingPlaybackSessions.Remove($t)
            Write-Log ("Recording playback stopped: token={0}" -f $t) -Level INFO
        }
        return $true
    } catch {
        return $false
    }
}

function Update-RecordingPlaybackHeartbeat {
    <#
    .SYNOPSIS
        Marks a preview session as still watched. $true when the session is alive.
    .EXAMPLE
        if (-not (Update-RecordingPlaybackHeartbeat -Token $t)) { 'session ended' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)
    try {
        if (-not $script:RecordingPlaybackSessions.ContainsKey($Token)) { return $false }
        $s = $script:RecordingPlaybackSessions[$Token]
        if (-not $s.Process -or $s.Process.HasExited) { return $false }
        $s.LastPing = Get-Date
        return $true
    } catch {
        return $false
    }
}

function Remove-IdleRecordingPlayback {
    <#
    .SYNOPSIS
        Stops sessions whose ffmpeg exited or that missed their heartbeat. Returns how many were removed.
    .EXAMPLE
        $n = Remove-IdleRecordingPlayback
    #>
    [CmdletBinding()]
    param()
    try {
        $idle = if ($global:Recordings_playback_idle_timeout_sec) { [int]$global:Recordings_playback_idle_timeout_sec } else { 30 }
        $removed = 0
        foreach ($t in @($script:RecordingPlaybackSessions.Keys)) {
            $s = $script:RecordingPlaybackSessions[$t]
            $dead = (-not $s.Process) -or $s.Process.HasExited -or (((Get-Date) - $s.LastPing).TotalSeconds -gt $idle)
            if ($dead) {
                if (Stop-RecordingPlayback -Token $t) { $removed++ }
            }
        }
        return $removed
    } catch {
        return 0
    }
}
