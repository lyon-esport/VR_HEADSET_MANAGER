# VR Headset Manager - web routes: recordings (S9-3).
#
# Route handlers for the recordings library and playback (ADR-0029), the /api/recordings/* prefix route.
# Dot-sourced by ..\web_routes.ps1 on both lanes (accept loop and slow-lane worker, ADR-0019);
# functions only. Each handler is reached through $script:RouteTable / $script:RoutePrefixes
# in web_routes.ps1, owns $response.Close() and leaves with `return`, never `continue`.
# The lane of a route is decided in web_routes.ps1 ($script:SlowRoutes / $script:PriorityRoutes),
# not here: moving a handler between files never changes its lane.

# API: /api/recordings/* (ADR-0029) - recordings library: catalogue, keep flag,
# wipe, download of the original file, and low-res WHEP playback sessions.
# Backend: recordings_library.ps1 / recordings_playback.ps1. Bodies capped at 4096.
function Invoke-RouteRecordings {
    # prefix route, see $script:RoutePrefixes
    param([Parameter(Mandatory = $true)] $Context)
    $request  = $Context.Request
    $response = $Context.Response

    $recDeferClose = $false
    try {
        $recPath = $request.Url.LocalPath
        $recGet  = ($request.HttpMethod -eq 'GET')
        $recPost = ($request.HttpMethod -eq 'POST')
        try { Remove-IdleRecordingPlayback | Out-Null } catch {}

        # JSON body reader: throws 'BODY_TOO_LARGE' / 'BAD_JSON'
        $recReadBody = {
            if ($request.ContentLength64 -gt 4096) { throw 'BODY_TOO_LARGE' }
            $txt = Read-RequestBody -Request $request -Response $response -MaxBytes 4096
            if ($txt.Length -gt 4096) { throw 'BODY_TOO_LARGE' }
            try { $o = $txt | ConvertFrom-Json } catch { throw 'BAD_JSON' }
            if ($null -eq $o) { throw 'BAD_JSON' }
            $o
        }
        $recQ = $request.QueryString

        if ($recGet -and $recPath -eq '/api/recordings/headsets') {
            $rows = @(Get-RecordingHeadsets | ForEach-Object {
                @{ safeName = $_.SafeName; id = $_.ID; name = $_.Name; inRegistry = [bool]$_.InRegistry; count = $_.Count }
            })
            Send-JsonResponse -Response $response -Body @{ ok = $true; headsets = $rows }

        } elseif ($recGet -and $recPath -eq '/api/recordings/dates') {
            $sn = [string]$recQ['safeName']
            if ($sn.Length -gt 80) { throw 'BAD_INPUT' }
            $dates = if ($sn) { @(Get-RecordingDates -SafeName $sn) } else { @(Get-RecordingDates) }
            Send-JsonResponse -Response $response -Body @{ ok = $true; dates = @($dates) }

        } elseif ($recGet -and $recPath -eq '/api/recordings/list') {
            $sn   = [string]$recQ['safeName']
            $date = [string]$recQ['date']
            if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'BAD_INPUT' }
            if ($sn.Length -gt 80) { throw 'BAD_INPUT' }
            $fromH = 0; $toH = 24
            if ($recQ['from']) { [void][int]::TryParse([string]$recQ['from'], [ref]$fromH) }
            if ($recQ['to'])   { [void][int]::TryParse([string]$recQ['to'],   [ref]$toH) }
            $fromH = [Math]::Max(0, [Math]::Min(24, $fromH))
            $toH   = [Math]::Max(0, [Math]::Min(24, $toH))
            if ($fromH -ge $toH) { $fromH = 0; $toH = 24 }
            $recs = if ($recQ['all'] -eq '1') {
                @(Get-HeadsetRecordings -Date $date -FromHour $fromH -ToHour $toH -AllHeadsets)
            } else {
                if (-not $sn) { throw 'BAD_INPUT' }
                @(Get-HeadsetRecordings -SafeName $sn -Date $date -FromHour $fromH -ToHour $toH)
            }
            $pb = Test-RecordingPlaybackAvailable
            Send-JsonResponse -Depth 8 -Response $response -Body @{
                ok         = $true
                recordings = @($recs)
                playback   = @{ ok = [bool]$pb.Ok; reason = $pb.Reason }
            }

        } elseif ($recPost -and $recPath -eq '/api/recordings/rescan') {
            $sync = Sync-RecordingCatalog -Force
            Send-JsonResponse -Response $response -Body @{
                ok = [bool]$sync.Ok; added = $sync.Added; closed = $sync.Closed; removed = $sync.Removed; error = $sync.Error
            }

        } elseif ($recGet -and $recPath -eq '/api/recordings/download') {
            $rid = 0
            if (-not [int]::TryParse([string]$recQ['id'], [ref]$rid) -or $rid -le 0) { throw 'BAD_INPUT' }
            $row = @(Invoke-DbQuery -Name 'recordings.get' -Parameters @{ id = $rid }) | Select-Object -First 1
            if (-not $row -or -not $row.file_path -or -not (Test-Path -LiteralPath ([string]$row.file_path))) {
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'Recording not found.' } -StatusCode 404
            } else {
                $recFile = [string]$row.file_path
                $leaf    = ([System.IO.Path]::GetFileName($recFile)) -replace '[^A-Za-z0-9._-]', '_'
                $recInfo = Get-Item -LiteralPath $recFile
                $response.StatusCode      = 200
                $response.ContentType     = 'video/x-matroska'
                $response.AddHeader('Content-Disposition', ('attachment; filename="{0}"' -f $leaf))
                $response.ContentLength64 = $recInfo.Length
                # A recording is often several GB. A synchronous CopyTo would hold this
                # single-threaded accept loop for the whole transfer and freeze every other
                # page (live video wall included), so the copy runs asynchronously and the
                # response is closed later by Complete-PendingRecordingDownloads.
                $fs = [System.IO.FileStream]::new($recFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 81920, $true)
                $task = $fs.CopyToAsync($response.OutputStream, 81920)
                [void]$script:RecordingDownloads.Add(@{ Task = $task; Stream = $fs; Response = $response; File = $leaf })
                $recDeferClose = $true
            }

        } elseif ($recPost -and $recPath -eq '/api/recordings/keep') {
            $j = & $recReadBody
            $rid = 0
            if (-not [int]::TryParse([string]$j.id, [ref]$rid) -or $rid -le 0) { throw 'BAD_INPUT' }
            $note = if ($null -ne $j.note) { [string]$j.note } else { '' }
            if ($note.Length -gt 500) { $note = $note.Substring(0, 500) }
            if (-not (Get-RecordingById -Id $rid)) {
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'Recording not found.' } -StatusCode 404
            } else {
                $keepVal = ($j.keep -eq $true -or [string]$j.keep -eq 'true' -or [string]$j.keep -eq '1')
                $okSet = Set-RecordingKeep -Id $rid -Keep $keepVal -Note $note
                Send-JsonResponse -Response $response -Body @{ ok = [bool]$okSet; id = $rid; keep = $keepVal }
            }

        } elseif ($recPost -and $recPath -eq '/api/recordings/delete') {
            $j = & $recReadBody
            $rid = 0
            if (-not [int]::TryParse([string]$j.id, [ref]$rid) -or $rid -le 0) { throw 'BAD_INPUT' }
            $d = Remove-Recording -Id $rid
            $code = if ($d.Ok) { 200 } elseif ($d.Error -eq 'Recording not found.') { 404 } elseif ($d.Refused) { 409 } else { 500 }
            Send-JsonResponse -Response $response -StatusCode $code -Body @{
                ok = [bool]$d.Ok; id = $rid; refused = [bool]$d.Refused; fileName = $d.FileName; error = $d.Error
            }

        } elseif ($recPost -and $recPath -eq '/api/recordings/wipe') {
            $j = & $recReadBody
            $mode = [string]$j.mode
            if ($mode -notin @('older', 'date')) { throw 'BAD_INPUT' }
            $sn = if ($j.safeName) { [string]$j.safeName } else { '' }
            if ($sn.Length -gt 80) { throw 'BAD_INPUT' }
            # Safety: anything but an explicit false is a preview.
            $preview = -not ($j.preview -eq $false -or [string]$j.preview -eq 'false')
            $wargs = @{ Preview = [switch]$preview }
            if ($sn) { $wargs.SafeName = $sn }
            if ($mode -eq 'older') {
                $days = 0
                if (-not [int]::TryParse([string]$j.days, [ref]$days) -or $days -lt 1) { throw 'BAD_INPUT' }
                $wargs.OlderThanDays = $days
            } else {
                if ([string]$j.date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'BAD_INPUT' }
                $wargs.Date = [string]$j.date
            }
            $w = Remove-OldRecordings @wargs
            Send-JsonResponse -Depth 8 -Response $response -Body @{
                ok = [bool]$w.Ok; count = $w.Count; bytes = $w.Bytes; kept = $w.Kept; deleted = $w.Deleted
                failed = @($w.Failed | ForEach-Object { @{ id = $_.Id; file = $_.File; error = $_.Error } })
                items  = @($w.Items | ForEach-Object { @{ id = $_.Id; fileName = $_.FileName; start = $_.Start; sizeBytes = $_.SizeBytes } })
                preview = $preview; error = $w.Error
            }

        } elseif ($recPost -and $recPath -eq '/api/recordings/play') {
            $j = & $recReadBody
            $rid = 0
            if (-not [int]::TryParse([string]$j.id, [ref]$rid) -or $rid -le 0) { throw 'BAD_INPUT' }
            $off = 0.0
            if ($null -ne $j.offset) { [void][double]::TryParse([string]$j.offset, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$off) }
            if ($off -lt 0) { $off = 0.0 }
            $spd = 1
            if ($null -ne $j.speed) { [void][int]::TryParse([string]$j.speed, [ref]$spd) }
            if ($spd -notin @(1, 2, 4)) { throw 'BAD_INPUT' }
            if (-not (Get-RecordingById -Id $rid)) {
                Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'Recording not found.' } -StatusCode 404
            } else {
                $p = Start-RecordingPlayback -RecordingId $rid -OffsetSec $off -Speed $spd -HostName ([string]$request.Url.Host)
                Send-JsonResponse -Response $response -Body @{
                    ok = [bool]$p.Ok; token = $p.Token; whepUrl = $p.WhepUrl; offsetSec = $p.OffsetSec; speed = $p.Speed; error = $p.Error
                }
            }

        } elseif ($recPost -and ($recPath -eq '/api/recordings/play-stop' -or $recPath -eq '/api/recordings/play-ping')) {
            $j = & $recReadBody
            $tok = [string]$j.token
            if ($tok -notmatch '^[0-9a-f]{8}$') { throw 'BAD_INPUT' }
            if ($recPath -eq '/api/recordings/play-stop') {
                $r = Stop-RecordingPlayback -Token $tok
                Send-JsonResponse -Response $response -Body @{ ok = $true; stopped = [bool]$r }
            } else {
                $alive = Update-RecordingPlaybackHeartbeat -Token $tok
                Send-JsonResponse -Response $response -Body @{ ok = $true; alive = [bool]$alive }
            }

        } else {
            Send-JsonResponse -Response $response -Body @{ ok = $false; error = 'Unknown recordings endpoint.' } -StatusCode 404
        }
    } catch {
        $m = $_.Exception.Message
        $code = if ($m -in @('BODY_TOO_LARGE', 'BAD_JSON', 'BAD_INPUT')) { 400 } else { 500 }
        $txt = switch ($m) {
            'BODY_TOO_LARGE' { 'Request body too large.' }
            'BAD_JSON'       { 'Invalid JSON body.' }
            'BAD_INPUT'      { 'Invalid or missing parameter.' }
            default          { $m }
        }
        try { Send-JsonResponse -Response $response -Body @{ ok = $false; error = $txt } -StatusCode $code } catch {}
    } finally {
        if (-not $recDeferClose) { Close-HttpResponse -Response $response }
    }
    return
}
