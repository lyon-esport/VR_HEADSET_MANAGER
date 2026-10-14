# ==================================================================
# recordings_library.ps1 - recordings catalogue, keep flag and wipe (ADR-0029)
#
# The video files under scrcpy.recordFolder stay the source of truth for the
# pictures; the `recordings` table (migration 008) is the index the Recordings
# page browses, plus the operator's keep flag and note.
#
# File layout (scrcpy_launcher.ps1):
#   <recordFolder>\<yyyy-MM-dd>\<SafeName>\<SafeName>_<yyyyMMdd_HHmmss>.mkv
#
# All persistence goes through named queries (modules\db\queries\recordings.*.sql).
# Playback lives in recordings_playback.ps1 (not here).
#
# ASCII only.
# ==================================================================

# Time of the last catalogue sync of THIS process (throttle). Guarded init only.
if (-not (Get-Variable -Name RecordingSyncLast -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RecordingSyncLast = [datetime]::MinValue
}

# Age (seconds) under which a file is still considered "being written".
$script:RecordingOpenWindowSec = 60

# Maximum ffmpeg media probes per catalogue sync pass (~0.1 s each), see Sync-RecordingCatalog.
$script:RecordingProbeBudget = 30

# Background repair of interrupted recordings (Update-RecordingRepair): the one remux running in
# THIS process, and the files that failed to repair in it (not retried until the next start).
if (-not (Get-Variable -Name RecordingRepair -Scope Script -ErrorAction SilentlyContinue)) { $script:RecordingRepair = $null }
if (-not (Get-Variable -Name RecordingRepairFailed -Scope Script -ErrorAction SilentlyContinue)) { $script:RecordingRepairFailed = @{} }
# A remux is disk-bound (a few seconds per GB); one stuck longer than this is killed.
$script:RecordingRepairTimeoutMin = 30

# --------------------------------------------------------------------
# Private helpers
# --------------------------------------------------------------------

function Format-RecordingTimestamp {
    <#
    .SYNOPSIS
        Formats a DateTime as the local 'yyyy-MM-ddTHH:mm:ss' string stored in the catalogue.
    .EXAMPLE
        Format-RecordingTimestamp -Date (Get-Date)
    #>
    param([Parameter(Mandatory = $true)][datetime]$Date)
    return $Date.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RecordingPropValue {
    <#
    .SYNOPSIS
        Strict-mode safe property read: the value, or $null when the property does not exist.
    .EXAMPLE
        Get-RecordingPropValue -Object $headset -Name 'Model'
    #>
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-RecordingRelativePath {
    <#
    .SYNOPSIS
        Path relative to the record folder (case-insensitive prefix strip), or the full path when outside it.
    .EXAMPLE
        Get-RecordingRelativePath -Path 'D:\rec\2026-10-11\Q3_RED\Q3_RED_20261011_101500.mkv'
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [string]$global:scrcpyRecordFolder
    if ([string]::IsNullOrWhiteSpace($root)) { return $Path }
    $root = $root.TrimEnd('\', '/')
    if ($Path.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($root.Length + 1)
    }
    return $Path
}

function Get-RecordingStartFromFile {
    <#
    .SYNOPSIS
        Start time of a recording: the file-name stamp when present, else LastWriteTime minus duration.
    .EXAMPLE
        Get-RecordingStartFromFile -Path $file -DurationSec 12.5
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $DurationSec = $null
    )
    $leaf = [System.IO.Path]::GetFileName($Path)
    $m = [regex]::Match($leaf, '_(\d{8})_(\d{6})\.mkv$')
    if ($m.Success) {
        $parsed = [datetime]::MinValue
        $stamp = $m.Groups[1].Value + $m.Groups[2].Value
        if ([datetime]::TryParseExact($stamp, 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    }
    $last = [System.IO.File]::GetLastWriteTime($Path)
    if ($null -ne $DurationSec -and [double]$DurationSec -gt 0) {
        return $last.AddSeconds(-[double]$DurationSec)
    }
    return $last
}

function ConvertTo-RecordingRow {
    <#
    .SYNOPSIS
        Converts a `recordings` database row into the camelCase row object shared with the web page.
    .EXAMPLE
        ConvertTo-RecordingRow -Row $dbRow
    #>
    param([Parameter(Mandatory = $true)]$Row)

    $path = [string]$Row.file_path
    $exists = $false
    try { $exists = [bool](Test-Path -LiteralPath $path -PathType Leaf) } catch { $exists = $false }
    # A live session's row holds size 0 until it is closed: show the file's current size instead.
    $size = [int64]$Row.size_bytes
    if ([string]$Row.status -eq 'recording' -and $exists) {
        try { $size = ([System.IO.FileInfo]::new($path)).Length } catch { }
    }

    return [PSCustomObject]@{
        id          = [int]$Row.id
        safeName    = [string]$Row.safe_name
        headsetId   = $(if ($null -ne $Row.headset_id) { [int]$Row.headset_id } else { $null })
        headsetName = [string]$Row.headset_name
        fileName    = [System.IO.Path]::GetFileName($path)
        start       = [string]$Row.started_at
        end         = $(if ($null -ne $Row.ended_at) { [string]$Row.ended_at } else { $null })
        durationSec = $(if ($null -ne $Row.duration_sec) { [double]$Row.duration_sec } else { $null })
        sizeBytes   = $size
        status      = [string]$Row.status
        source      = [string]$Row.source
        keep        = ((ConvertTo-DbBool $Row.keep) -eq 1)
        note        = $(if ($null -ne $Row.note) { [string]$Row.note } else { $null })
        model       = [string]$Row.model
        profile     = [string]$Row.scrcpy_profile
        view        = [string]$Row.view
        eye         = [string]$Row.eye
        fps         = $(if ($null -ne $Row.fps) { [int]$Row.fps } else { $null })
        bitrateMbps = $(if ($null -ne $Row.bitrate_mbps) { [int]$Row.bitrate_mbps } else { $null })
        maxSize     = $(if ($null -ne $Row.max_size) { [int]$Row.max_size } else { $null })
        codec       = [string]$Row.codec
        width       = $(if ($null -ne $Row.width) { [int]$Row.width } else { $null })
        height      = $(if ($null -ne $Row.height) { [int]$Row.height } else { $null })
        captureMode = [string]$Row.capture_mode
        eyeMerge    = ((ConvertTo-DbBool $Row.eye_merge) -eq 1)
        fileExists  = $exists
    }
}

function New-RecordingInsertParams {
    <#
    .SYNOPSIS
        A complete parameter hashtable for the recordings.insert named query (every column, nulls allowed).
    .EXAMPLE
        $p = New-RecordingInsertParams -FilePath $f -SafeName 'Q3_RED' -StartedAt '2026-10-11T10:15:00'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$SafeName,
        [Parameter(Mandatory = $true)][string]$StartedAt
    )
    return @{
        headset_id     = $null
        headset_name   = $SafeName
        safe_name      = $SafeName
        file_path      = $FilePath
        rel_path       = (Get-RecordingRelativePath -Path $FilePath)
        started_at     = $StartedAt
        ended_at       = $null
        duration_sec   = $null
        size_bytes     = [int64]0
        status         = 'recording'
        source         = 'live'
        model          = ''
        scrcpy_profile = ''
        view           = ''
        eye            = ''
        fps            = $null
        bitrate_mbps   = $null
        max_size       = $null
        codec          = ''
        width          = $null
        height         = $null
        capture_mode   = ''
        eye_merge      = 0
    }
}

function New-RecordingRowFromFile {
    <#
    .SYNOPSIS
        Builds the insert parameters for a recording file found on disk (rescan or late Complete).
    .DESCRIPTION
        The headset is matched by Convert-Displayname(headset name) against the registry rows in
        -Headsets; an unmatched safe name gives headset_id null. status is 'done' unless the file
        was written less than 60 s ago (then 'recording'). source is 'scan'.
    .EXAMPLE
        New-RecordingRowFromFile -Path $f -SafeName 'Q3_RED' -Headsets @(Get-KnownHeadsets)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SafeName,
        [array]$Headsets = @(),
        [string]$Source = 'scan',
        # Import without the ffmpeg probe (codec left empty, filled by a later sync pass).
        [switch]$SkipProbe
    )

    $info = if ($SkipProbe) { @{ DurationSec = $null; Codec = $null; Width = $null; Height = $null } } else { Get-RecordingMediaInfo -Path $Path }
    $last = [System.IO.File]::GetLastWriteTime($Path)
    $start = Get-RecordingStartFromFile -Path $Path -DurationSec $info.DurationSec
    $p = New-RecordingInsertParams -FilePath $Path -SafeName $SafeName -StartedAt (Format-RecordingTimestamp -Date $start)

    foreach ($h in $Headsets) {
        $n = [string](Get-RecordingPropValue -Object $h -Name 'Name')
        if ($n -and (Convert-Displayname -displayName $n) -ceq $SafeName) {
            $idRaw = Get-RecordingPropValue -Object $h -Name 'ID'
            $idVal = 0
            if ([int]::TryParse([string]$idRaw, [ref]$idVal)) { $p.headset_id = $idVal }
            $p.headset_name = $n
            $p.model = [string](Get-RecordingPropValue -Object $h -Name 'Model')
            break
        }
    }

    $isOpen = (((Get-Date) - $last).TotalSeconds -lt $script:RecordingOpenWindowSec)
    $len = [int64]0
    try { $len = ([System.IO.FileInfo]::new($Path)).Length } catch { $len = 0 }
    $p.size_bytes = $len
    $p.source = $Source
    if ($isOpen) {
        $p.status = 'recording'
    }
    else {
        $p.status = 'done'
        $p.ended_at = Format-RecordingTimestamp -Date $last
        $dur = $info.DurationSec
        if ($null -eq $dur) { $dur = [math]::Max(0, ($last - $start).TotalSeconds) }
        $p.duration_sec = [double]$dur
    }
    if ($info.Codec) { $p.codec = [string]$info.Codec }
    if ($null -ne $info.Width) { $p.width = [int]$info.Width }
    if ($null -ne $info.Height) { $p.height = [int]$info.Height }
    return $p
}

function Save-RecordingRows {
    <#
    .SYNOPSIS
        Upserts recording rows: one Invoke-DbBatch transaction above two rows, single calls otherwise.
    .EXAMPLE
        Save-RecordingRows -Rows @($p1, $p2, $p3)
    #>
    param([array]$Rows = @())
    if ($Rows.Count -eq 0) { return }
    if ($Rows.Count -gt 2) {
        Invoke-DbBatch -Name 'recordings.insert' -Rows $Rows | Out-Null
    }
    else {
        foreach ($r in $Rows) { Invoke-DbNonQuery -Name 'recordings.insert' -Parameters $r | Out-Null }
    }
}

function Remove-RecordingRowsById {
    <#
    .SYNOPSIS
        Deletes catalogue rows by id (batch above two rows).
    .EXAMPLE
        Remove-RecordingRowsById -Ids @(3, 4, 5)
    #>
    param([array]$Ids = @())
    if ($Ids.Count -eq 0) { return }
    if ($Ids.Count -gt 2) {
        $rows = @($Ids | ForEach-Object { @{ id = [int]$_ } })
        Invoke-DbBatch -Name 'recordings.delete' -Rows $rows | Out-Null
    }
    else {
        foreach ($i in $Ids) { Invoke-DbNonQuery -Name 'recordings.delete' -Parameters @{ id = [int]$i } | Out-Null }
    }
}

# --------------------------------------------------------------------
# Catalogue
# --------------------------------------------------------------------

function Register-RecordingStart {
    <#
    .SYNOPSIS
        Adds (or refreshes) the catalogue row of a recording that has just started.
    .DESCRIPTION
        Quality fields come from the headset's scrcpy profile (ConvertFrom-ScrcpyProfile), max_size and
        codec from scrcpy.parameters.<Model>. Never throws. Returns $true when the row was written.
    .EXAMPLE
        Register-RecordingStart -Headset $headsetRow -RecordFile $recordFile -CaptureMode 'StreamOnly'
    #>
    param(
        [Parameter(Mandatory = $true)]$Headset,
        [Parameter(Mandatory = $true)][string]$RecordFile,
        [string]$ScrcpyProfile,
        [string]$CaptureMode,
        [bool]$EyeMerge,
        [string]$SafeName
    )
    try {
        $name = [string](Get-RecordingPropValue -Object $Headset -Name 'Name')
        if (-not $SafeName) { $SafeName = Convert-Displayname -displayName $name }
        if (-not $ScrcpyProfile) { $ScrcpyProfile = [string](Get-RecordingPropValue -Object $Headset -Name 'ScrcpyProfile') }
        if (-not $CaptureMode) { $CaptureMode = [string]$global:CaptureMode }

        $started = Get-Date
        if ([System.IO.File]::Exists($RecordFile)) {
            $started = Get-RecordingStartFromFile -Path $RecordFile
        }
        else {
            $leaf = [System.IO.Path]::GetFileName($RecordFile)
            $m = [regex]::Match($leaf, '_(\d{8})_(\d{6})\.mkv$')
            $parsed = [datetime]::MinValue
            if ($m.Success -and [datetime]::TryParseExact(($m.Groups[1].Value + $m.Groups[2].Value), 'yyyyMMddHHmmss',
                    [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                $started = $parsed
            }
        }

        $p = New-RecordingInsertParams -FilePath $RecordFile -SafeName $SafeName -StartedAt (Format-RecordingTimestamp -Date $started)
        $p.headset_name = $name
        $idVal = 0
        if ([int]::TryParse([string](Get-RecordingPropValue -Object $Headset -Name 'ID'), [ref]$idVal)) { $p.headset_id = $idVal }
        $model = [string](Get-RecordingPropValue -Object $Headset -Name 'Model')
        $p.model = $model
        $p.scrcpy_profile = $ScrcpyProfile
        $p.capture_mode = $CaptureMode
        $p.status = 'recording'
        $p.source = 'live'

        $parsedProfile = $null
        if ($ScrcpyProfile) { $parsedProfile = ConvertFrom-ScrcpyProfile -Profile $ScrcpyProfile }
        if ($parsedProfile) {
            $p.view = [string]$parsedProfile.View
            $p.eye = [string]$parsedProfile.Eye
            $p.fps = [int]$parsedProfile.Fps
            $p.bitrate_mbps = [int]$parsedProfile.BitrateMbps
        }

        $tpl = $null
        if ($model -and $global:scrcpyParameters) {
            $tp = $global:scrcpyParameters.PSObject.Properties[$model]
            if ($tp) { $tpl = $tp.Value }
        }
        $codec = 'h264'
        if ($tpl) {
            $vc = Get-RecordingPropValue -Object $tpl -Name 'video_codec'
            if ($vc) { $codec = [string]$vc }
            $ms = Get-RecordingPropValue -Object $tpl -Name 'max_size'
            $msVal = 0
            if ($ms -and [int]::TryParse([string]$ms, [ref]$msVal)) { $p.max_size = $msVal }
        }
        $p.codec = $codec

        $merge = $false
        if ($PSBoundParameters.ContainsKey('EyeMerge')) { $merge = $EyeMerge }
        elseif ($parsedProfile -and $parsedProfile.Eye -eq 'M' -and (Get-Command -Name Resolve-EyeMergeUse -ErrorAction SilentlyContinue)) {
            try { $merge = [bool](Resolve-EyeMergeUse -Model $model -ScrcpyProfile $ScrcpyProfile).Use } catch { $merge = $false }
        }
        $p.eye_merge = $(if ($merge) { 1 } else { 0 })

        Invoke-DbNonQuery -Name 'recordings.insert' -Parameters $p | Out-Null
        Write-Log ("Recording registered: {0} ({1})" -f $p.rel_path, $ScrcpyProfile) -Level DEBUG
        return $true
    }
    catch {
        Write-Log ("Recording registration failed for '{0}': {1}" -f $RecordFile, $_.Exception.Message) -Level WARNING
        return $false
    }
}

function Get-RecordingMediaInfo {
    <#
    .SYNOPSIS
        Duration, video codec and picture size of a media file, read from ffmpeg's banner.
    .DESCRIPTION
        Runs `ffmpeg -hide_banner -i <file>` (exit code 1 "At least one output file must be specified"
        is normal) with a 15 s timeout and parses stderr. A field that cannot be read is $null.
    .EXAMPLE
        Get-RecordingMediaInfo -Path 'D:\rec\2026-10-11\Q3_RED\Q3_RED_20261011_101500.mkv'
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = @{ DurationSec = $null; Codec = $null; Width = $null; Height = $null }
    try {
        $ffmpeg = [string]$global:ffmpegFilePath
        if (-not $ffmpeg -or -not [System.IO.File]::Exists($ffmpeg) -or -not [System.IO.File]::Exists($Path)) { return $result }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ffmpeg
        $psi.Arguments = '-hide_banner -i "' + $Path + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $errTask = $proc.StandardError.ReadToEndAsync()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            if (-not $proc.WaitForExit(15000)) {
                try { $proc.Kill() } catch { }
                return $result
            }
            $text = $errTask.Result
            $null = $outTask.Result
        }
        finally { $proc.Dispose() }

        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $d = [regex]::Match($text, 'Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)')
        if ($d.Success) {
            $sec = [double]::Parse($d.Groups[3].Value, $inv)
            $result.DurationSec = ([int]$d.Groups[1].Value * 3600) + ([int]$d.Groups[2].Value * 60) + $sec
        }
        $v = [regex]::Match($text, 'Video:\s*([A-Za-z0-9_]+)[^\r\n]*')
        if ($v.Success) {
            $result.Codec = $v.Groups[1].Value
            $r = [regex]::Match($v.Value, '(\d{2,5})x(\d{2,5})')
            if ($r.Success) {
                $result.Width = [int]::Parse($r.Groups[1].Value, $inv)
                $result.Height = [int]::Parse($r.Groups[2].Value, $inv)
            }
        }
    }
    catch {
        Write-Log ("Recording media probe failed for '{0}': {1}" -f $Path, $_.Exception.Message) -Level DEBUG
    }
    return $result
}

function Complete-RecordingEntry {
    <#
    .SYNOPSIS
        Closes the catalogue row of a recording whose session ended (or deletes it when the file is empty).
    .DESCRIPTION
        Missing or 0-byte file: the row is deleted. Otherwise ended_at = file LastWriteTime, size and
        media info are stored and status becomes 'done' - or 'interrupted' with -Interrupted (the
        writer was killed, so the file has no index and a wrong duration: Update-RecordingRepair
        remuxes it later). A file with no row yet (session started before this feature) is imported
        first. Never throws; $true when the catalogue was updated.
    .EXAMPLE
        Complete-RecordingEntry -Path $recordFile -Interrupted
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Interrupted)
    try {
        $row = @(Invoke-DbQuery -Name 'recordings.get_by_path' -Parameters @{ file_path = $Path }) | Select-Object -First 1

        $len = [int64]0
        $exists = [System.IO.File]::Exists($Path)
        if ($exists) { $len = ([System.IO.FileInfo]::new($Path)).Length }
        if (-not $exists -or $len -le 0) {
            if ($row) { Remove-RecordingRowsById -Ids @([int]$row.id) }
            return $true
        }

        if (-not $row) {
            $safe = Split-Path -Leaf (Split-Path -Parent $Path)
            $import = New-RecordingRowFromFile -Path $Path -SafeName $safe -Headsets @(Get-KnownHeadsets)
            $import.status = 'recording'
            Save-RecordingRows -Rows @($import)
            $row = @(Invoke-DbQuery -Name 'recordings.get_by_path' -Parameters @{ file_path = $Path }) | Select-Object -First 1
            if (-not $row) { return $false }
        }

        $last = [System.IO.File]::GetLastWriteTime($Path)
        $info = Get-RecordingMediaInfo -Path $Path
        $duration = $info.DurationSec
        if ($null -eq $duration) {
            $start = [datetime]::MinValue
            if ([datetime]::TryParseExact([string]$row.started_at, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$start)) {
                $duration = [math]::Max(0, ($last - $start).TotalSeconds)
            }
        }
        Invoke-DbNonQuery -Name 'recordings.complete' -Parameters @{
            file_path    = $Path
            ended_at     = (Format-RecordingTimestamp -Date $last)
            duration_sec = $(if ($null -ne $duration) { [double]$duration } else { $null })
            size_bytes   = $len
            codec        = $(if ($info.Codec) { [string]$info.Codec } else { '' })
            width        = $(if ($null -ne $info.Width) { [int]$info.Width } else { $null })
            height       = $(if ($null -ne $info.Height) { [int]$info.Height } else { $null })
            status       = $(if ($Interrupted) { 'interrupted' } else { 'done' })
        } | Out-Null
        Write-Log ("Recording completed{1}: {0}" -f (Get-RecordingRelativePath -Path $Path), $(if ($Interrupted) { ' (interrupted, repair queued)' } else { '' })) -Level DEBUG
        return $true
    }
    catch {
        Write-Log ("Recording completion failed for '{0}': {1}" -f $Path, $_.Exception.Message) -Level WARNING
        return $false
    }
}

function Sync-RecordingCatalog {
    <#
    .SYNOPSIS
        Reconciles the catalogue with the record folder: imports new files, closes stale rows, drops vanished files.
    .DESCRIPTION
        Throttled to Recordings.rescan_interval_min unless -Force. When the record folder is unset or
        unreachable NOTHING is deleted (only stale rows whose file still exists are closed) and the
        result carries Skipped = 'root-unreachable'. Never throws.
        Returns @{Ok;Added;Closed;Removed;Skipped;Error}.
    .EXAMPLE
        Sync-RecordingCatalog -Force
    #>
    param([switch]$Force)

    $res = @{ Ok = $true; Added = 0; Closed = 0; Removed = 0; Skipped = $null; Error = $null }
    try {
        $interval = 10
        if ($null -ne $global:Recordings_rescan_interval_min) {
            $iv = 0
            if ([int]::TryParse([string]$global:Recordings_rescan_interval_min, [ref]$iv) -and $iv -ge 1) { $interval = $iv }
        }
        if (-not $Force -and ((Get-Date) - $script:RecordingSyncLast).TotalMinutes -lt $interval) {
            $res.Skipped = 'throttled'
            return $res
        }
        $script:RecordingSyncLast = Get-Date

        $root = [string]$global:scrcpyRecordFolder
        $rootOk = ($root -and [System.IO.Directory]::Exists($root))
        if (-not $rootOk) {
            Write-Log ("Recordings catalogue sync: record folder '{0}' is not reachable, nothing will be removed" -f $root) -Level WARNING
            $res.Skipped = 'root-unreachable'
        }

        $known = @{}
        foreach ($r in @(Invoke-DbQuery -Name 'recordings.paths')) { $known[[string]$r.file_path] = [int]$r.id }
        $knownCi = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $known.Keys) { $knownCi[$k] = $known[$k] }

        # ffmpeg probes allowed in this pass. A first start on a folder holding hundreds of
        # recordings must not spend minutes probing: beyond the budget files are imported
        # unprobed and step (d) of later passes fills them in.
        $probeBudget = $script:RecordingProbeBudget

        # (a) import files not in the catalogue
        $newRows = New-Object System.Collections.Generic.List[object]
        if ($rootOk) {
            $headsets = @(Get-KnownHeadsets)
            foreach ($dateDir in [System.IO.Directory]::EnumerateDirectories($root)) {
                if ([System.IO.Path]::GetFileName($dateDir) -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
                foreach ($nameDir in [System.IO.Directory]::EnumerateDirectories($dateDir)) {
                    $safe = [System.IO.Path]::GetFileName($nameDir)
                    if ($safe -notmatch '^[\w\-\. ]+$') { continue }
                    foreach ($file in [System.IO.Directory]::EnumerateFiles($nameDir, '*.mkv')) {
                        if ($knownCi.ContainsKey($file)) { continue }
                        try {
                            $skip = ($probeBudget -le 0)
                            if (-not $skip) { $probeBudget-- }
                            $newRows.Add((New-RecordingRowFromFile -Path $file -SafeName $safe -Headsets $headsets -SkipProbe:$skip))
                        }
                        catch {
                            Write-Log ("Recordings catalogue sync: cannot import '{0}': {1}" -f $file, $_.Exception.Message) -Level WARNING
                        }
                    }
                }
            }
            if ($newRows.Count -gt 0) {
                Save-RecordingRows -Rows $newRows.ToArray()
                $res.Added = $newRows.Count
            }
        }

        # (b) close stale 'recording' rows (only for files that exist)
        $closeRows = New-Object System.Collections.Generic.List[object]
        $deleteIds = New-Object System.Collections.Generic.List[int]
        foreach ($open in @(Invoke-DbQuery -Name 'recordings.open')) {
            $path = [string]$open.file_path
            if (-not [System.IO.File]::Exists($path)) {
                if ($rootOk) { $deleteIds.Add([int]$open.id) }
                continue
            }
            $last = [System.IO.File]::GetLastWriteTime($path)
            if (((Get-Date) - $last).TotalSeconds -lt $script:RecordingOpenWindowSec) { continue }
            $info = Get-RecordingMediaInfo -Path $path
            $len = ([System.IO.FileInfo]::new($path)).Length
            if ($len -le 0) { if ($rootOk) { $deleteIds.Add([int]$open.id) }; continue }
            $dur = $info.DurationSec
            if ($null -eq $dur) {
                $st = [datetime]::MinValue
                if ([datetime]::TryParseExact([string]$open.started_at, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$st)) {
                    $dur = [math]::Max(0, ($last - $st).TotalSeconds)
                }
            }
            $closeRows.Add(@{
                    file_path    = $path
                    ended_at     = (Format-RecordingTimestamp -Date $last)
                    duration_sec = $(if ($null -ne $dur) { [double]$dur } else { $null })
                    size_bytes   = [int64]$len
                    codec        = $(if ($info.Codec) { [string]$info.Codec } else { '' })
                    width        = $(if ($null -ne $info.Width) { [int]$info.Width } else { $null })
                    height       = $(if ($null -ne $info.Height) { [int]$info.Height } else { $null })
                    status       = 'interrupted'
                })
        }
        if ($closeRows.Count -gt 0) {
            if ($closeRows.Count -gt 2) { Invoke-DbBatch -Name 'recordings.complete' -Rows $closeRows.ToArray() | Out-Null }
            else { foreach ($c in $closeRows) { Invoke-DbNonQuery -Name 'recordings.complete' -Parameters $c | Out-Null } }
            $res.Closed = $closeRows.Count
        }

        # (c) drop rows whose file vanished (only when the root is reachable)
        if ($rootOk) {
            foreach ($k in $known.Keys) {
                if (-not [System.IO.File]::Exists($k)) { $deleteIds.Add([int]$known[$k]) }
            }
            $unique = @($deleteIds | Select-Object -Unique)
            if ($unique.Count -gt 0) {
                Remove-RecordingRowsById -Ids $unique
                $res.Removed = $unique.Count
            }
        }

        # (d) probe rows imported without media info, within what is left of the budget
        if ($probeBudget -gt 0) {
            foreach ($m in @(Invoke-DbQuery -Name 'recordings.missing_media' -Parameters @{ limit = $probeBudget })) {
                $path = [string]$m.file_path
                if (-not [System.IO.File]::Exists($path)) { continue }
                $info = Get-RecordingMediaInfo -Path $path
                if (-not $info.Codec) { continue }
                $last = [System.IO.File]::GetLastWriteTime($path)
                $dur = $info.DurationSec
                if ($null -eq $dur) {
                    $st = [datetime]::MinValue
                    if ([datetime]::TryParseExact([string]$m.started_at, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::None, [ref]$st)) {
                        $dur = [math]::Max(0, ($last - $st).TotalSeconds)
                    }
                }
                Invoke-DbNonQuery -Name 'recordings.complete' -Parameters @{
                    file_path    = $path
                    ended_at     = $(if ($m.ended_at) { [string]$m.ended_at } else { Format-RecordingTimestamp -Date $last })
                    duration_sec = $(if ($null -ne $dur) { [double]$dur } else { $null })
                    size_bytes   = [int64]([System.IO.FileInfo]::new($path)).Length
                    codec        = [string]$info.Codec
                    width        = $(if ($null -ne $info.Width) { [int]$info.Width } else { $null })
                    height       = $(if ($null -ne $info.Height) { [int]$info.Height } else { $null })
                    status       = [string]$m.status
                } | Out-Null
            }
        }

        $summary = "Recordings catalogue sync: added {0}, closed {1}, removed {2}" -f $res.Added, $res.Closed, $res.Removed
        if ($res.Added -or $res.Closed -or $res.Removed) { Write-Log $summary -Level INFO }
        else { Write-Log $summary -Level DEBUG }
    }
    catch {
        $res.Ok = $false
        $res.Error = $_.Exception.Message
        Write-Log ("Recordings catalogue sync failed: {0}" -f $_.Exception.Message) -Level WARNING
    }
    return $res
}

function Update-RecordingRepair {
    <#
    .SYNOPSIS
        One non-blocking step of the background repair of interrupted recordings.
    .DESCRIPTION
        A recording whose ffmpeg was killed (Stop-HeadsetPipeline after its 15 s grace) or left open
        by a crash has no index (cues) and a WRONG header duration: measured, a file killed after
        6 s announced 15 s. It plays in VLC but seeks badly. A stream copy (ffmpeg -i f -map 0 -c copy)
        rewrites it complete, without re-encoding.
        Each call does at most one thing, so it can run on every VRMonitor slow tick:
          - a remux is running: when it has ended, the repaired file REPLACES the original (only when
            ffmpeg exited 0 and the copy holds at least 90 % of the bytes) and the row becomes 'done'
            with its real duration; otherwise the copy is deleted, the original kept untouched, and
            the file is not retried in this process;
          - nothing running: starts ONE remux (hidden, below-normal priority) for the oldest
            'interrupted' row whose file exists, is not being written, and fits in the free space.
        The copy is written next to the original as <file>.repair.tmp (never *.mkv, so the catalogue
        sync does not import it). Never throws. Returns 'idle', 'started', 'running', 'repaired',
        'failed' or 'skipped'.
    .EXAMPLE
        Update-RecordingRepair
    #>
    try {
        $ffmpeg = [string]$global:ffmpegFilePath
        if (-not $ffmpeg -or -not [System.IO.File]::Exists($ffmpeg)) { return 'skipped' }

        $job = $script:RecordingRepair
        if ($job) {
            $proc = $job.Proc
            if (-not $proc.HasExited) {
                if (((Get-Date) - $job.Started).TotalMinutes -lt $script:RecordingRepairTimeoutMin) { return 'running' }
                try { $proc.Kill() } catch { }
                try { [void]$proc.WaitForExit(3000) } catch { }
                Write-Log ("Recording repair timed out after {0} min, original kept: {1}" -f $script:RecordingRepairTimeoutMin, (Get-RecordingRelativePath -Path $job.Path)) -Level WARNING
            }
            $script:RecordingRepair = $null
            $code = -1; try { $code = $proc.ExitCode } catch { }
            try { $proc.Dispose() } catch { }
            $ok = $false
            if ($code -eq 0 -and [System.IO.File]::Exists($job.Tmp) -and [System.IO.File]::Exists($job.Path)) {
                $origLen = ([System.IO.FileInfo]::new($job.Path)).Length
                $newLen = ([System.IO.FileInfo]::new($job.Tmp)).Length
                if ($newLen -ge [math]::Floor($origLen * 0.9)) {
                    try {
                        # [NullString]: a plain $null reaches .NET as '' here, an "illegal path".
                        [System.IO.File]::Replace($job.Tmp, $job.Path, [NullString]::Value)
                        $ok = $true
                    } catch {
                        # Original open elsewhere (being played back): try again on a later tick.
                        try { [System.IO.File]::Delete($job.Tmp) } catch { }
                        Write-Log ("Recording repair postponed, the file could not be replaced ({1}): {0}" -f (Get-RecordingRelativePath -Path $job.Path), $_.Exception.Message) -Level INFO
                        return 'skipped'
                    }
                }
            }
            if ($ok) {
                [void](Complete-RecordingEntry -Path $job.Path)
                Write-Log ("Recording repaired (index and duration rewritten, nothing re-encoded) in {0:n0} s: {1}" -f ((Get-Date) - $job.Started).TotalSeconds, (Get-RecordingRelativePath -Path $job.Path)) -Level SUCCESS
                return 'repaired'
            }
            if ([System.IO.File]::Exists($job.Tmp)) { try { [System.IO.File]::Delete($job.Tmp) } catch { } }
            $script:RecordingRepairFailed[$job.Path] = $true
            Write-Log ("Recording repair failed (ffmpeg exit {0}), original kept as it was - it still plays in VLC: {1}" -f $code, (Get-RecordingRelativePath -Path $job.Path)) -Level WARNING
            return 'failed'
        }

        foreach ($row in @(Invoke-DbQuery -Name 'recordings.interrupted' -Parameters @{ limit = 20 })) {
            $path = [string]$row.file_path
            if ($script:RecordingRepairFailed.ContainsKey($path) -or -not [System.IO.File]::Exists($path)) { continue }
            $fi = [System.IO.FileInfo]::new($path)
            if ($fi.Length -le 0) { continue }
            if (((Get-Date) - $fi.LastWriteTime).TotalSeconds -lt $script:RecordingOpenWindowSec) { continue }   # still being written
            $tmp = $path + '.repair.tmp'
            if ([System.IO.File]::Exists($tmp)) { try { [System.IO.File]::Delete($tmp) } catch { continue } }   # left by a crash
            # The copy needs as much room as the original on the same drive.
            try {
                $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($path))
                if ($drive.AvailableFreeSpace -lt ($fi.Length + 256MB)) {
                    $script:RecordingRepairFailed[$path] = $true
                    Write-Log ("Recording not repaired, not enough free space for the copy ({0:n1} GB needed): {1}" -f ($fi.Length / 1GB), (Get-RecordingRelativePath -Path $path)) -Level WARNING
                    continue
                }
            } catch { }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ffmpeg
            $psi.Arguments = '-hide_banner -nostdin -v error -y -i "' + $path + '" -map 0 -c copy -f matroska "' + $tmp + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
            $script:RecordingRepair = @{ Path = $path; Tmp = $tmp; Proc = $proc; Started = (Get-Date) }
            Write-Log ("Recording repair started ({0:n1} GB): {1}" -f ($fi.Length / 1GB), (Get-RecordingRelativePath -Path $path)) -Level INFO
            return 'started'
        }
        return 'idle'
    }
    catch {
        Write-Log ("Recording repair step failed: {0}" -f $_.Exception.Message) -Level WARNING
        return 'skipped'
    }
}

# --------------------------------------------------------------------
# Browsing
# --------------------------------------------------------------------

function Get-RecordingHeadsets {
    <#
    .SYNOPSIS
        Headsets (by safe name) that have recordings, with their count and registry status.
    .DESCRIPTION
        Returns @(@{SafeName;ID;Name;InRegistry;Count}) sorted by registry order, then name. A headset
        removed from the registry keeps appearing (InRegistry = $false) under its stored name.
    .EXAMPLE
        Get-RecordingHeadsets | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count }
    #>
    $out = New-Object System.Collections.Generic.List[object]
    try {
        $reg = @{}
        $order = @{}
        foreach ($h in @(Get-KnownHeadsets)) {
            $idVal = 0
            if ([int]::TryParse([string]$h.ID, [ref]$idVal)) {
                $reg[$idVal] = $h
                $so = 0
                if (-not [int]::TryParse([string](Get-RecordingPropValue -Object $h -Name 'SortOrder'), [ref]$so)) { $so = 0 }
                $order[$idVal] = $so
            }
        }
        foreach ($r in @(Invoke-DbQuery -Name 'recordings.headsets')) {
            $id = $null
            $inReg = $false
            $name = [string]$r.headset_name
            if ($null -ne $r.headset_id -and $reg.ContainsKey([int]$r.headset_id)) {
                $id = [int]$r.headset_id
                $inReg = $true
                $name = [string]$reg[$id].Name
            }
            elseif ($null -ne $r.headset_id) { $id = [int]$r.headset_id }
            if (-not $name) { $name = [string]$r.safe_name }
            $out.Add([PSCustomObject]@{
                    SafeName   = [string]$r.safe_name
                    ID         = $id
                    Name       = $name
                    InRegistry = $inReg
                    Count      = [int]$r.cnt
                    SortKey    = $(if ($inReg) { $order[$id] } else { [int]::MaxValue })
                })
        }
    }
    catch {
        Write-Log ("Get-RecordingHeadsets failed: {0}" -f $_.Exception.Message) -Level WARNING
    }
    return @($out | Sort-Object -Property SortKey, Name | Select-Object -Property SafeName, ID, Name, InRegistry, Count)
}

function Get-RecordingDates {
    <#
    .SYNOPSIS
        Days (yyyy-MM-dd, newest first) holding at least one recording, optionally for one headset.
    .EXAMPLE
        Get-RecordingDates -SafeName 'Q3_RED'
    #>
    param([string]$SafeName = '')
    try {
        return @(@(Invoke-DbQuery -Name 'recordings.dates' -Parameters @{ safe_name = $SafeName }) | ForEach-Object { [string]$_.day })
    }
    catch {
        Write-Log ("Get-RecordingDates failed: {0}" -f $_.Exception.Message) -Level WARNING
        return @()
    }
}

function Get-HeadsetRecordings {
    <#
    .SYNOPSIS
        Recordings overlapping an hour window of one day, for one headset or for all of them.
    .DESCRIPTION
        -FromHour/-ToHour are 0..24 (24 = next day 00:00:00). Returns row objects (see ConvertTo-RecordingRow).
    .EXAMPLE
        Get-HeadsetRecordings -SafeName 'Q3_RED' -Date '2026-10-11' -FromHour 9 -ToHour 12
    #>
    param(
        [string]$SafeName = '',
        [Parameter(Mandatory = $true)][string]$Date,
        [int]$FromHour = 0,
        [int]$ToHour = 24,
        [switch]$AllHeadsets
    )
    try {
        $day = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$day)) { return @() }
        $FromHour = [math]::Min(24, [math]::Max(0, $FromHour))
        $ToHour = [math]::Min(24, [math]::Max(0, $ToHour))
        if ($ToHour -le $FromHour) { $ToHour = [math]::Min(24, $FromHour + 1); if ($ToHour -le $FromHour) { $FromHour = 23 } }
        $from = Format-RecordingTimestamp -Date $day.AddHours($FromHour)
        $to = Format-RecordingTimestamp -Date $day.AddHours($ToHour)

        $rows = @()
        if ($AllHeadsets) {
            $rows = @(Invoke-DbQuery -Name 'recordings.list_window_all' -Parameters @{ from_ts = $from; to_ts = $to })
        }
        else {
            $rows = @(Invoke-DbQuery -Name 'recordings.list_window' -Parameters @{ safe_name = $SafeName; from_ts = $from; to_ts = $to })
        }
        return @($rows | ForEach-Object { ConvertTo-RecordingRow -Row $_ })
    }
    catch {
        Write-Log ("Get-HeadsetRecordings failed: {0}" -f $_.Exception.Message) -Level WARNING
        return @()
    }
}

function Get-RecordingById {
    <#
    .SYNOPSIS
        One recording as a row object, or $null.
    .EXAMPLE
        Get-RecordingById -Id 12
    #>
    param([Parameter(Mandatory = $true)][int]$Id)
    try {
        $row = @(Invoke-DbQuery -Name 'recordings.get' -Parameters @{ id = $Id }) | Select-Object -First 1
        if (-not $row) { return $null }
        return (ConvertTo-RecordingRow -Row $row)
    }
    catch {
        Write-Log ("Get-RecordingById failed: {0}" -f $_.Exception.Message) -Level WARNING
        return $null
    }
}

function Set-RecordingKeep {
    <#
    .SYNOPSIS
        Protects (or unprotects) a recording from the wipe, with an optional note (200 chars max).
    .EXAMPLE
        Set-RecordingKeep -Id 12 -Keep $true -Note 'Client demo'
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][bool]$Keep,
        [string]$Note
    )
    try {
        $n = $null
        if ($Note) {
            $n = ($Note -replace '[\x00-\x1F\x7F]', ' ').Trim()
            if ($n.Length -gt 200) { $n = $n.Substring(0, 200) }
            if ($n.Length -eq 0) { $n = $null }
        }
        $cnt = Invoke-DbNonQuery -Name 'recordings.set_keep' -Parameters @{ id = $Id; keep = $(if ($Keep) { 1 } else { 0 }); note = $n }
        return ([int]$cnt -gt 0)
    }
    catch {
        Write-Log ("Set-RecordingKeep failed: {0}" -f $_.Exception.Message) -Level WARNING
        return $false
    }
}

# --------------------------------------------------------------------
# Wipe
# --------------------------------------------------------------------

function Remove-EmptyRecordingFolders {
    <#
    .SYNOPSIS
        Removes the now-empty <SafeName> and <date> folders of deleted recordings, strictly below the
        record folder (never the record folder itself). Never throws.
    .EXAMPLE
        Remove-EmptyRecordingFolders -Directories @('D:\rec\2026-10-11\Q3_RED')
    #>
    param([string[]]$Directories = @())
    try {
        $root = [string]$global:scrcpyRecordFolder
        if (-not $root -or -not [System.IO.Directory]::Exists($root)) { return }
        $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        foreach ($dir in @($Directories | Where-Object { $_ } | Select-Object -Unique)) {
            $cur = $dir
            for ($level = 0; $level -lt 2 -and $cur; $level++) {
                $full = [System.IO.Path]::GetFullPath($cur).TrimEnd('\', '/')
                if (-not $full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { break }
                if (-not [System.IO.Directory]::Exists($full)) { $cur = [System.IO.Path]::GetDirectoryName($full); continue }
                $any = $false
                foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($full)) { $any = $true; break }
                if ($any) { break }
                try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop } catch { break }
                $cur = [System.IO.Path]::GetDirectoryName($full)
            }
        }
    }
    catch { }
}

function Remove-Recording {
    <#
    .SYNOPSIS
        Deletes ONE recording (file + catalogue row) by id, refusing a protected or live one.
    .DESCRIPTION
        Refused (Ok = $false, Refused = $true) when the row has the "do not delete" flag, is still
        'recording', or its file was written less than 60 s ago. A row whose file is already gone
        is simply removed. Empty <date>\<SafeName> folders are cleaned up afterwards.
        Returns @{Ok;Refused;Id;FileName;Error}. Never throws.
    .EXAMPLE
        Remove-Recording -Id 42
    #>
    param([Parameter(Mandatory = $true)][int]$Id)
    $res = @{ Ok = $false; Refused = $false; Id = $Id; FileName = $null; Error = $null }
    try {
        $row = @(Invoke-DbQuery -Name 'recordings.get' -Parameters @{ id = $Id }) | Select-Object -First 1
        if (-not $row) { $res.Error = 'Recording not found.'; return $res }
        $path = [string]$row.file_path
        $res.FileName = [System.IO.Path]::GetFileName($path)
        if ((ConvertTo-DbBool $row.keep) -eq 1) {
            $res.Refused = $true; $res.Error = 'This recording is locked (do not delete). Unlock it first.'; return $res
        }
        if ([string]$row.status -eq 'recording') {
            $res.Refused = $true; $res.Error = 'This recording is still in progress.'; return $res
        }
        $exists = [System.IO.File]::Exists($path)
        if ($exists -and ((Get-Date) - [System.IO.File]::GetLastWriteTime($path)).TotalSeconds -lt $script:RecordingOpenWindowSec) {
            $res.Refused = $true; $res.Error = 'The file is still being written.'; return $res
        }
        if ($exists) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        Invoke-DbNonQuery -Name 'recordings.delete' -Parameters @{ id = $Id } | Out-Null
        if ($exists) { Remove-EmptyRecordingFolders -Directories @([System.IO.Path]::GetDirectoryName($path)) }
        Write-Log ("Recording deleted: {0}" -f (Get-RecordingRelativePath -Path $path)) -Level INFO
        $res.Ok = $true
    }
    catch {
        $res.Error = $_.Exception.Message
        Write-Log ("Remove-Recording failed for id {0}: {1}" -f $Id, $_.Exception.Message) -Level WARNING
    }
    return $res
}

function Remove-OldRecordings {
    <#
    .SYNOPSIS
        Deletes recordings older than N days, or all recordings of one day (kept ones are never deleted).
    .DESCRIPTION
        -OlderThanDays N: started_at earlier than now - N days. -Date yyyy-MM-dd: that day. Rows with
        keep = 1 and live recordings are never touched. -Preview only counts. Afterwards the empty
        <date>\<SafeName> and <date> folders are removed (never the record folder itself).
        Returns @{Ok;Count;Bytes;Kept;Deleted;Failed;Items;Error}; Count/Bytes describe the deletable rows.
    .EXAMPLE
        Remove-OldRecordings -OlderThanDays 30 -Preview
    .EXAMPLE
        Remove-OldRecordings -Date '2026-10-01' -SafeName 'Q3_RED'
    #>
    param(
        [int]$OlderThanDays = 1,
        [string]$Date,
        [string]$SafeName = '',
        [switch]$Preview
    )
    $res = @{ Ok = $true; Count = 0; Bytes = [int64]0; Kept = 0; Deleted = 0; Failed = @(); Items = @(); Error = $null }
    try {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $mode = 'older'
        $before = ''
        $dateStr = ''
        if ($Date) {
            $d = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
                $res.Ok = $false
                $res.Error = 'Invalid date (expected yyyy-MM-dd).'
                return $res
            }
            $mode = 'date'
            $dateStr = $d.ToString('yyyy-MM-dd', $inv)
        }
        else {
            if ($OlderThanDays -lt 1) { $OlderThanDays = 1 }
            $before = Format-RecordingTimestamp -Date ((Get-Date).AddDays(-$OlderThanDays))
        }

        $cands = @(Invoke-DbQuery -Name 'recordings.wipe_candidates' -Parameters @{ safe_name = $SafeName; mode = $mode; before = $before; date = $dateStr })
        $deletable = New-Object System.Collections.Generic.List[object]
        foreach ($c in $cands) {
            if ((ConvertTo-DbBool $c.keep) -eq 1) { $res.Kept++ } else { $deletable.Add($c) }
        }
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($c in $deletable) {
            $res.Bytes += [int64]$c.size_bytes
            $items.Add(@{ Id = [int]$c.id; FileName = [System.IO.Path]::GetFileName([string]$c.file_path); Start = [string]$c.started_at; SizeBytes = [int64]$c.size_bytes })
        }
        $res.Count = $deletable.Count
        $res.Items = $items.ToArray()
        if ($Preview) { return $res }

        $failed = New-Object System.Collections.Generic.List[object]
        $dirs = New-Object System.Collections.Generic.List[string]
        foreach ($c in $deletable) {
            $path = [string]$c.file_path
            try {
                # Last safety net: a file still being written is never deleted, whatever its row says.
                if ([System.IO.File]::Exists($path) -and
                    ((Get-Date) - [System.IO.File]::GetLastWriteTime($path)).TotalSeconds -lt $script:RecordingOpenWindowSec) {
                    throw 'File is still being written.'
                }
                if ([System.IO.File]::Exists($path)) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                    $dirs.Add([System.IO.Path]::GetDirectoryName($path))
                }
                Invoke-DbNonQuery -Name 'recordings.delete' -Parameters @{ id = [int]$c.id } | Out-Null
                $res.Deleted++
            }
            catch {
                $failed.Add(@{ Id = [int]$c.id; File = [System.IO.Path]::GetFileName($path); Error = $_.Exception.Message })
            }
        }
        $res.Failed = $failed.ToArray()

        Remove-EmptyRecordingFolders -Directories $dirs.ToArray()

        Write-Log ("Recordings wipe ({0}): deleted {1}, kept {2}, failed {3}, {4:N1} MB" -f $mode, $res.Deleted, $res.Kept, $res.Failed.Count, ($res.Bytes / 1MB)) -Level INFO
    }
    catch {
        $res.Ok = $false
        $res.Error = $_.Exception.Message
        Write-Log ("Remove-OldRecordings failed: {0}" -f $_.Exception.Message) -Level WARNING
    }
    return $res
}
