###############################################################################
# stream_benchmark.ps1 - capture benchmark of ONE headset (ADR-0026).
#
# WHAT IT DOES
# ------------
# Runs a series of short capture tests on one headset - one eye vs merged, view,
# capture FPS, bitrate, stream copy vs re-encode, GPU vs CPU encoder, h264 vs h265 -
# and measures what each one costs this PC: CPU, every GPU, memory, the scrcpy /
# ffmpeg / mediamtx processes, plus what the stream actually delivered (fps, dropped
# and duplicated frames, encode speed, read from ffmpeg's -progress file).
#
# HOW IT STAYS OUT OF THE WATCHDOG'S WAY
# --------------------------------------
# Every other stream is stopped for the run. The VRMonitor process owns the running
# pipelines (bridge jobs, $global:HeadsetPipelines), so it must stop them itself:
# the benchmark sets an EXPIRING pause flag (app_kv row benchmark_active), VRMonitor
# sees its rising edge, stops its streams, acknowledges (benchmark_ack) and keeps
# Watch-ScrcpyProcesses, Update-ComputerMonitoring and VQA quiet until it clears.
# A benchmark that dies leaves a flag that expires on its own, so the normal streams
# always come back.
#
# NOTHING IS WRITTEN TO CONFIG. The test settings (re-encode, codec, GPU on/off,
# re-encode framerate, capture mode) are $global: overrides in the benchmark's own
# process, and the scrcpy profile is a start-screenCopy parameter, never a registry
# write.
#
# The web server runs Invoke-StreamBenchmark in a background job (one at a time);
# the console runs it in the foreground (Show-SubMenu-Benchmark).
#
# ASCII only in string literals (the file is saved without a BOM).
###############################################################################

# Timings used by the run AND by the duration estimate (mirrored in
# website\headsets_monitoring.html, which gets them from the catalogue).
$script:BenchTiming = @{
    WarmupSec          = 8     # stream up, before measuring
    SettleSec          = 3     # after a stream stopped, before the next one
    StartOverheadSec   = 5     # start-screenCopy: 0.5 s bridge + 3 s before ffmpeg + scrcpy connect
    StopOverheadSec    = 2     # Stop-Scrcpy + pipeline teardown
    MergeExtraSec      = 3     # remap tables of a merged view (0 when cached)
    EncoderProbeSec    = 12    # Get-GpuEncoder probe, once per GPU codec
    StopPerStreamSec   = 5     # VRMonitor stopping one running stream
    StopMaxSec         = 30
    RestoreSec         = 10    # normal streams coming back at the end
    AckTimeoutSec      = 60    # wait for VRMonitor to acknowledge the pause
}

$script:BenchKvFlag   = 'benchmark_active'
$script:BenchKvAck    = 'benchmark_ack'
$script:BenchKvResult = 'benchmark_last'


# ---------------------------------------------------------------------------
# Pause flag (cross-process, expiring)
# ---------------------------------------------------------------------------

function Set-StreamBenchmarkActive {
    <#
    .SYNOPSIS
    Raises (or renews) the benchmark pause flag for -Seconds. VRMonitor stops every stream
    on its rising edge and keeps the scrcpy watchdog, computer monitoring and VQA quiet while
    it is set. Expires on its own if the benchmark dies.
    .EXAMPLE
    Set-StreamBenchmarkActive -RunId $runId -Seconds 90
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [int]$Seconds = 60
    )
    try {
        Set-DbKeyValue -Key $script:BenchKvFlag -Value @{
            runId = $RunId
            until = (Get-Date).AddSeconds($Seconds).ToUniversalTime().ToString('o')
        }
    } catch { }
}


function Get-StreamBenchmarkState {
    <#
    .SYNOPSIS
    The active pause flag as @{RunId;Until}, or $null when no benchmark is running (no flag,
    or an expired one). Never throws.
    #>
    param()
    try {
        if (-not (Get-Command Get-DbKeyValue -ErrorAction SilentlyContinue)) { return $null }
        $raw = Get-DbKeyValue -Key $script:BenchKvFlag
        if (-not $raw -or -not $raw.until) { return $null }
        $until = [datetime]::MinValue
        if ($raw.until -is [datetime]) {
            $until = $raw.until
        } elseif (-not [datetime]::TryParse([string]$raw.until, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$until)) {
            return $null
        }
        if ([datetime]::UtcNow -ge $until.ToUniversalTime()) { return $null }
        return @{ RunId = [string]$raw.runId; Until = $until.ToUniversalTime() }
    } catch { return $null }
}


function Test-StreamBenchmarkActive {
    <# $true while a benchmark holds the pause flag. One scalar read; never throws. #>
    param()
    return ($null -ne (Get-StreamBenchmarkState))
}


function Clear-StreamBenchmarkActive {
    param()
    try { Remove-DbKeyValue -Key $script:BenchKvFlag } catch { }
}


function Confirm-StreamBenchmarkPause {
    <#
    .SYNOPSIS
    Called by VRMonitor once it has stopped its streams for run -RunId, so the benchmark
    knows it can start its own without the watchdog killing it.
    #>
    param([Parameter(Mandatory = $true)][string]$RunId)
    try { Set-DbKeyValue -Key $script:BenchKvAck -Value @{ runId = $RunId; at = (Get-Date).ToUniversalTime().ToString('o') } } catch { }
}


# ---------------------------------------------------------------------------
# Catalogue and estimate
# ---------------------------------------------------------------------------

function Get-StreamBenchmarkTiming {
    <# The timing constants (run and estimate). Returned as a copy. #>
    param()
    return $script:BenchTiming.Clone()
}


function Get-StreamBenchmarkTestEstimate {
    <#
    .SYNOPSIS
    Estimated seconds for ONE test with a measure window of -MeasureSec (the same formula
    the web page uses on the client side).
    #>
    param(
        [Parameter(Mandatory = $true)]$Test,
        [int]$MeasureSec = 20
    )
    $t = $script:BenchTiming
    if ($Test.Encoding -eq 'none') { return [int]($t.SettleSec + $MeasureSec) }
    return [int]([int]$Test.OverheadSec + $t.WarmupSec + $MeasureSec + $t.SettleSec)
}


function Get-StreamBenchmarkFixedEstimate {
    <#
    .SYNOPSIS
    Run-level seconds outside the tests: stopping the -RunningStreams currently streaming,
    one encoder probe per GPU codec among -Tests, and the restore at the end.
    #>
    param(
        [object[]]$Tests = @(),
        [int]$RunningStreams = 0
    )
    $t = $script:BenchTiming
    $stop = [Math]::Min($t.StopMaxSec, $RunningStreams * $t.StopPerStreamSec)
    $gpuCodecs = @($Tests | Where-Object { $_.Encoding -eq 'gpu' } | ForEach-Object { $_.Codec } | Select-Object -Unique)
    return [int]($stop + $gpuCodecs.Count * $t.EncoderProbeSec + $t.RestoreSec)
}


function Get-StreamBenchmarkCatalog {
    <#
    .SYNOPSIS
    The tests available for one headset, in run order: a curated set (Default = $true,
    one axis varied at a time from a reference profile) and extra combinations
    (Default = $false). Each test:
    @{Id;Group;Label;Eye;View;Fps;Mbps;Encoding(none|copy|gpu|cpu);Codec;Default;Available;Reason;OverheadSec}
    .DESCRIPTION
    Reads only config, the registry row and the last computer-monitoring snapshot - no ADB,
    no GPU probe - so the web page can ask for it on the single-threaded listener.
    The reference is the headset's current view, right eye, 45 fps, 20 Mbps, stream copy.
    Re-encoding tests re-encode at the capture FPS and at the configured
    mediamtx.stream_bitrate.
    .EXAMPLE
    Get-StreamBenchmarkCatalog -Headset (Get-HeadsetDiagTarget -Id 3)
    #>
    param([Parameter(Mandatory = $true)]$Headset)

    $model = [string]$Headset.Model
    $refView = $null
    $parsed = ConvertFrom-ScrcpyProfile -Profile ([string]$Headset.ScrcpyProfile)
    if ($parsed) { $refView = $parsed.View }
    $views = @()
    if ($model -and $global:scrcpyParameters.$model -and $global:scrcpyParameters.$model.views) {
        $views = @($global:scrcpyParameters.$model.views | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
    }
    if (-not $refView -or ($views.Count -gt 0 -and $views -notcontains $refView)) { $refView = Get-ScrcpyDefaultView -Model $model }
    if ($views.Count -eq 0) { $views = @($refView) }

    $tpl = if ($model) { $global:scrcpyParameters.$model } else { $null }
    $sourceCodec = if ($tpl -and $tpl.video_codec) { [string]$tpl.video_codec } else { 'h264' }

    $mergeOk = $false
    $mergeReason = 'No eye merge calibration for this model.'
    try { $mergeOk = [bool](Test-EyeMergeSupported -Model $model) } catch { $mergeOk = $false }
    # LocalWindow capture is not a blocker: the benchmark forces StreamOnly in its own process.

    # GPU present? From the last computer-monitoring snapshot (no probe here).
    $gpuCount = -1
    try {
        $snap = Get-DbKeyValue -Key 'computer_monitoring'
        if ($snap -and $snap.GPU) { $gpuCount = @($snap.GPU).Count } elseif ($snap) { $gpuCount = 0 }
    } catch { }
    $gpuOk = ($gpuCount -ne 0)

    $t = $script:BenchTiming
    $list = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $add = {
        param([string]$Group, [string]$Eye, [string]$View, [int]$Fps, [int]$Mbps, [string]$Enc, [string]$Codec, [bool]$Default)
        $codecEff = if ($Enc -eq 'copy') { $sourceCodec } else { $Codec }
        $id = if ($Enc -eq 'none') { 'baseline' } else { ('{0}-{1}-{2}-{3}-{4}-{5}' -f $Eye, $View, $Fps, $Mbps, $Enc, $codecEff).ToLower() }
        if ($seen.ContainsKey($id)) {
            if ($Default) { $seen[$id].Default = $true }
            return
        }
        $avail = $true; $reason = ''
        if ($Eye -eq 'M' -and -not $mergeOk) { $avail = $false; $reason = $mergeReason }
        elseif ($Enc -eq 'gpu' -and -not $gpuOk) { $avail = $false; $reason = 'No GPU found on this PC.' }
        if (-not $global:mediamtxEnabled -and $Enc -ne 'none') { $avail = $false; $reason = 'mediamtx is disabled: streaming tests need it.' }

        $encLabel = switch ($Enc) {
            'none' { 'no stream' }
            'copy' { 'copy' }
            'gpu'  { 'GPU ' + $codecEff }
            'cpu'  { 'CPU ' + $codecEff }
        }
        $label = if ($Enc -eq 'none') { 'Baseline - no stream (idle PC)' } else {
            '{0} eye {1}, {2} fps, {3} Mbps, {4}' -f $Eye, $View, $Fps, $Mbps, $encLabel
        }
        $overhead = 0
        if ($Enc -ne 'none') {
            $overhead = $t.StartOverheadSec + $t.StopOverheadSec
            if ($Eye -eq 'M') { $overhead += $t.MergeExtraSec }
        }
        $test = [ordered]@{
            Id = $id; Group = $Group; Label = $label; Eye = $Eye; View = $View; Fps = $Fps; Mbps = $Mbps
            Encoding = $Enc; Codec = $codecEff; Default = $Default; Available = $avail; Reason = $reason
            OverheadSec = $overhead
        }
        $seen[$id] = $test
        $list.Add($test)
    }

    $v = $refView
    # ---- Curated (pre-ticked) ----
    & $add 'Baseline'  ''  ''  0  0  'none' ''     $true
    & $add 'Reference' 'R' $v  45 20 'copy' ''     $true
    & $add 'Eye'       'M' $v  45 20 'gpu'  'h264' $true
    & $add 'Eye'       'M' $v  45 20 'cpu'  'h264' $true
    & $add 'Eye'       'M' $v  45 20 'gpu'  'h265' $true
    foreach ($f in 30, 60, 72) { & $add 'FPS' 'R' $v $f 20 'copy' '' $true }
    foreach ($b in 10, 40)     { & $add 'Bitrate' 'R' $v 45 $b 'copy' '' $true }
    & $add 'Encoding'  'R' $v  45 20 'gpu'  'h264' $true
    & $add 'Encoding'  'R' $v  45 20 'cpu'  'h264' $true
    & $add 'Encoding'  'R' $v  45 20 'gpu'  'h265' $true
    & $add 'Encoding'  'R' $v  45 20 'cpu'  'h265' $true
    foreach ($f in 60, 72) { & $add 'FPS + GPU' 'R' $v $f 20 'gpu' 'h264' $true }
    & $add 'Bitrate + GPU' 'R' $v 45 40 'gpu' 'h264' $true

    # ---- Extras (listed, unticked) ----
    foreach ($view in $views) { if ($view -ne $v) { & $add 'View' 'R' $view 45 20 'copy' '' $false } }
    & $add 'Stress' 'M' $v 72 40 'gpu' 'h264' $false
    & $add 'Stress' 'R' $v 72 40 'cpu' 'h265' $false
    # No left-eye tests: L and R crops of a view are the same size, so they cost the same.
    foreach ($eye in 'R', 'M') {
        foreach ($f in 30, 45, 60, 72) {
            foreach ($enc in @(@('copy',''), @('gpu','h264'), @('cpu','h264'), @('gpu','h265'), @('cpu','h265'))) {
                if ($eye -eq 'M' -and $enc[0] -eq 'copy') { continue }   # a merged view is always re-encoded
                & $add 'Grid' $eye $v $f 20 $enc[0] $enc[1] $false
            }
        }
    }
    foreach ($b in 5, 10, 30, 40) {
        foreach ($enc in @(@('copy',''), @('gpu','h264'), @('cpu','h264'))) { & $add 'Grid' 'R' $v 45 $b $enc[0] $enc[1] $false }
    }

    return @{
        Model           = $model
        ReferenceView   = $v
        SourceCodec     = $sourceCodec
        ReencodeBitrate = [string]$global:mediamtxBitrate
        MediamtxEnabled = [bool]$global:mediamtxEnabled
        Timing          = (Get-StreamBenchmarkTiming)
        Tests           = $list.ToArray()
    }
}


# ---------------------------------------------------------------------------
# Measuring
# ---------------------------------------------------------------------------

function Initialize-StreamBenchmarkCpuType {
    <# Compiles the GetSystemTimes wrapper once per process. Locale-independent, unlike Get-Counter. #>
    param()
    if ('VrhmCpuTimes' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VrhmCpuTimes {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    public static long[] Read() {
        long i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) { return null; }
        return new long[] { i, k, u };
    }
}
'@ -ErrorAction Stop
        return $true
    } catch {
        Write-Log ("Benchmark: CPU time helper unavailable: " + $_.Exception.Message) -Level WARNING
        return $false
    }
}


function Get-StreamBenchmarkCpuPercent {
    <# Whole-PC CPU % between two VrhmCpuTimes snapshots (kernel time includes idle). #>
    param($From, $To)
    if (-not $From -or -not $To) { return $null }
    $idle = [double]($To[0] - $From[0])
    $total = [double](($To[1] - $From[1]) + ($To[2] - $From[2]))
    if ($total -le 0) { return $null }
    return [Math]::Round([Math]::Max(0, [Math]::Min(100, (1 - $idle / $total) * 100)), 1)
}


function Measure-StreamBenchmarkSample {
    <#
    .SYNOPSIS
    One load sample (~2-3 s): every GPU (Get-GpuInfo), memory (Get-RamInfo) and the
    scrcpy / ffmpeg / mediamtx processes (Get-AppWorkload). The CPU % of the sample is
    measured over the same interval with GetSystemTimes.
    #>
    param()
    $c0 = $null; if ('VrhmCpuTimes' -as [type]) { $c0 = [VrhmCpuTimes]::Read() }
    $gpus = @(); try { $gpus = @(Get-GpuInfo) } catch { }
    $ram  = $null; try { $ram = Get-RamInfo } catch { }
    $work = @(); try { $work = @(Get-AppWorkload -ProcessNames @('scrcpy', 'ffmpeg', 'mediamtx') -SampleMs 500) } catch { }
    $c1 = $null; if ('VrhmCpuTimes' -as [type]) { $c1 = [VrhmCpuTimes]::Read() }
    return @{
        Cpu  = (Get-StreamBenchmarkCpuPercent -From $c0 -To $c1)
        Gpus = $gpus
        Ram  = $ram
        Work = $work
    }
}


function Read-FfmpegProgressFile {
    <#
    .SYNOPSIS
    Last values of an ffmpeg -progress file: @{Frame;Drop;Dup;Speed} (any of them $null when
    absent). The file is still being written by ffmpeg, so it is opened with shared access.
    #>
    param([string]$Path)
    $res = @{ Frame = $null; Drop = $null; Dup = $null; Speed = $null }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $res }
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
        $last = { param($key) $m = [regex]::Matches($text, "(?m)^$key=\s*([0-9.]+)"); if ($m.Count -gt 0) { $m[$m.Count - 1].Groups[1].Value } else { $null } }
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $v = & $last 'frame';       if ($v) { $res.Frame = [double]::Parse($v, $inv) }
        $v = & $last 'drop_frames'; if ($v) { $res.Drop  = [double]::Parse($v, $inv) }
        $v = & $last 'dup_frames';  if ($v) { $res.Dup   = [double]::Parse($v, $inv) }
        $v = & $last 'speed';       if ($v) { $res.Speed = [double]::Parse($v, $inv) }
    } catch { }
    return $res
}


function Get-StreamBenchmarkAggregate {
    <# Folds the samples of one test into averages and peaks. #>
    param([object[]]$Samples = @(), [Nullable[double]]$CpuWindowAvg = $null)
    $avg  = { param($vals) $v = @($vals | Where-Object { $null -ne $_ }); if ($v.Count -eq 0) { $null } else { [Math]::Round(($v | Measure-Object -Average).Average, 1) } }
    $peak = { param($vals) $v = @($vals | Where-Object { $null -ne $_ }); if ($v.Count -eq 0) { $null } else { [Math]::Round(($v | Measure-Object -Maximum).Maximum, 1) } }

    $cpuVals = @($Samples | ForEach-Object { $_.Cpu })
    $cpuAvg = if ($null -ne $CpuWindowAvg) { $CpuWindowAvg } else { & $avg $cpuVals }

    $gpuIdx = @($Samples | ForEach-Object { $_.Gpus } | ForEach-Object { $_.Index } | Select-Object -Unique | Sort-Object)
    $gpus = foreach ($i in $gpuIdx) {
        $rows = @($Samples | ForEach-Object { $_.Gpus } | Where-Object { $_.Index -eq $i })
        [ordered]@{
            Index     = $i
            Model     = [string]($rows | Select-Object -First 1).Model
            UtilAvg   = & $avg  ($rows | ForEach-Object { $_.UtilizationPercent })
            UtilPeak  = & $peak ($rows | ForEach-Object { $_.UtilizationPercent })
            D3Avg     = & $avg  ($rows | ForEach-Object { $_.Load3DPercent })
            VideoAvg  = & $avg  ($rows | ForEach-Object { $_.VideoPercent })
            EncodeAvg = & $avg  ($rows | ForEach-Object { $_.EncodePercent })
            VramGB    = & $avg  ($rows | ForEach-Object { $_.VramUsedGB })
        }
    }

    $proc = [ordered]@{}
    foreach ($n in 'scrcpy', 'ffmpeg', 'mediamtx') {
        $rows = @($Samples | ForEach-Object { $_.Work } | Where-Object { $_.ProcessName -eq $n })
        $proc[$n] = [ordered]@{
            CpuAvg = & $avg  ($rows | ForEach-Object { $_.TotalCpuPct })
            MemMB  = & $peak ($rows | ForEach-Object { $_.TotalMemoryMB })
        }
    }

    return [ordered]@{
        Samples    = @($Samples).Count
        CpuAvg     = $cpuAvg
        CpuPeak    = & $peak $cpuVals
        RamUsedGB  = & $avg  ($Samples | ForEach-Object { if ($_.Ram) { $_.Ram.UsedGB } })
        RamPeakGB  = & $peak ($Samples | ForEach-Object { if ($_.Ram) { $_.Ram.UsedGB } })
        RamUsedPct = & $avg  ($Samples | ForEach-Object { if ($_.Ram) { $_.Ram.UsedPercent } })
        Gpus       = @($gpus)
        Procs      = $proc
    }
}


# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

function Get-StreamBenchmarkProgressPath {
    <# Progress JSON of the running/last benchmark (TEMP, like the other web jobs). #>
    param()
    return [System.IO.Path]::Combine($env:TEMP, 'vrm_benchmark.json')
}


function Get-StreamBenchmarkCancelPath {
    param()
    return [System.IO.Path]::Combine($env:TEMP, 'vrm_benchmark.cancel')
}


function Stop-StreamBenchmark {
    <# Asks the running benchmark to stop after the current step (cancel file). #>
    param()
    try { [System.IO.File]::WriteAllText((Get-StreamBenchmarkCancelPath), 'cancel') ; return $true } catch { return $false }
}


function Write-StreamBenchmarkProgress {
    <# Writes the progress JSON atomically (temp file + replace), so a reader never sees half a file. #>
    param([Parameter(Mandatory = $true)]$State, [string]$Path)
    if (-not $Path) { return }
    try {
        $State.updatedAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $json = $State | ConvertTo-Json -Depth 12 -Compress
        $tmp = $Path + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, $null) }
        else { [System.IO.File]::Move($tmp, $Path) }
    } catch { }
}


function Invoke-StreamBenchmark {
    <#
    .SYNOPSIS
    Runs the selected benchmark tests on one headset and returns (and stores in app_kv
    benchmark_last) the result: @{Ok;Status;Error;Timestamp;Host;Headset;Model;MeasureSec;Gpus;Results}.
    .DESCRIPTION
    Raises the pause flag, waits for VRMonitor to stop every stream, then for each test:
    applies the in-memory overrides, starts the stream (start-screenCopy, recording off),
    warms up, samples for -MeasureSec, reads the ffmpeg -progress file, stops the stream.
    The flag is cleared in a finally block, after which the watchdog restarts the normal
    streams from the registry. -OnProgress (scriptblock, gets the state) is for the console.
    .EXAMPLE
    Invoke-StreamBenchmark -Headset (Get-HeadsetDiagTarget -Id 3) -TestIds 'baseline','r-square-45-20-copy-h264' -MeasureSec 10
    #>
    param(
        [Parameter(Mandatory = $true)]$Headset,
        [Parameter(Mandatory = $true)][string[]]$TestIds,
        [ValidateSet(10, 20, 40)][int]$MeasureSec = 20,
        [string]$ProgressFile = '',
        [scriptblock]$OnProgress = $null
    )

    $t = $script:BenchTiming
    $runId = [guid]::NewGuid().ToString('N')
    $cancelPath = Get-StreamBenchmarkCancelPath
    if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
    $ffProgress = [System.IO.Path]::Combine($env:TEMP, 'vrm_benchmark_ffprogress.txt')
    $safeName = Convert-Displayname ([string]$Headset.Name)

    $catalog = Get-StreamBenchmarkCatalog -Headset $Headset
    $byId = @{}; foreach ($c in $catalog.Tests) { $byId[$c.Id] = $c }
    # Run order = catalogue order (baseline first), whatever order the caller sent.
    $tests = @($catalog.Tests | Where-Object { $TestIds -contains $_.Id })

    $startedAt = Get-Date
    $runningStreams = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count
    $estTests = @($tests | ForEach-Object { Get-StreamBenchmarkTestEstimate -Test $_ -MeasureSec $MeasureSec })
    $estFixed = Get-StreamBenchmarkFixedEstimate -Tests $tests -RunningStreams $runningStreams
    $estTotal = [int](($estTests | Measure-Object -Sum).Sum + $estFixed)

    $state = [ordered]@{
        status = 'running'; runId = $runId; phase = 'starting'
        headset = @{ id = $Headset.ID; name = $Headset.Name; model = $Headset.Model }
        measureSec = $MeasureSec; index = 0; total = $tests.Count; current = ''
        startedAt = $startedAt.ToUniversalTime().ToString('o')
        elapsedSec = 0; etaSec = $estTotal; estimatedTotalSec = $estTotal
        phaseEndsAt = $null; results = @(); error = ''; updatedAt = 0
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $doneEst = 0.0; $doneActual = 0.0

    $publish = {
        param([string]$Phase, [int]$PhaseSec = 0, [double]$SpentInTest = 0)
        $state.phase = $Phase
        $state.elapsedSec = [int]((Get-Date) - $startedAt).TotalSeconds
        $state.phaseEndsAt = if ($PhaseSec -gt 0) { [long]([DateTimeOffset]::UtcNow.AddSeconds($PhaseSec).ToUnixTimeMilliseconds()) } else { $null }
        # Remaining = remaining tests' estimates, corrected by how far off the estimate the
        # finished tests were (a slow PC converges after one or two tests), plus the restore.
        $ratio = if ($doneEst -gt 0) { [Math]::Max(0.5, [Math]::Min(3.0, $doneActual / $doneEst)) } else { 1.0 }
        $rem = 0.0
        for ($k = [Math]::Max(0, $state.index - 1); $k -lt $tests.Count; $k++) {
            $e = $estTests[$k] * $ratio
            if ($k -eq $state.index - 1) { $e = [Math]::Max(0, $e - $SpentInTest) }
            $rem += $e
        }
        if ($state.index -eq 0) { $rem += [Math]::Max(0, $estFixed - $t.RestoreSec) }
        if ($Phase -ne 'done') { $rem += $t.RestoreSec } else { $rem = 0 }
        $state.etaSec = [int]$rem
        $state.estimatedTotalSec = [int]($state.elapsedSec + $rem)
        $state.results = $results.ToArray()
        Write-StreamBenchmarkProgress -State $state -Path $ProgressFile
        if ($OnProgress) { try { & $OnProgress $state } catch { } }
    }
    $cancelled = { Test-Path -LiteralPath $cancelPath }

    # Globals overridden for the run, restored in finally.
    $saved = @{
        CaptureMode       = $global:CaptureMode
        mediamtxReencode  = $global:mediamtxReencode
        mediamtxCodec     = $global:mediamtxCodec
        GPU_Acceleration  = $global:GPU_Acceleration
        mediamtxFramerate = $global:mediamtxFramerate
        GpuEncoder        = $global:GpuEncoder
    }
    $status = 'done'; $err = ''
    Write-Log ("Benchmark {0}: {1} test(s) on {2}, measure {3} s, estimated {4} s" -f $runId, $tests.Count, $Headset.Name, $MeasureSec, $estTotal) -Level INFO

    try {
        if ($tests.Count -eq 0) { throw 'No test selected.' }
        if (-not $global:mediamtxEnabled -and @($tests | Where-Object { $_.Encoding -ne 'none' }).Count -gt 0) { throw 'mediamtx is disabled: streaming tests need it.' }
        [void](Initialize-StreamBenchmarkCpuType)

        # Headset reachable?
        & $publish 'checking headset'
        $dev = $null
        try { $dev = Resolve-HeadsetAdbDevice -Headset $Headset } catch { $dev = $null }
        if (-not $dev) { throw ("Headset {0} does not answer over ADB (USB or WiFi)." -f $Headset.Name) }

        # Pause flag: VRMonitor stops every stream and acknowledges.
        Set-StreamBenchmarkActive -RunId $runId -Seconds ($t.AckTimeoutSec + 60)
        & $publish 'stopping streams' ([Math]::Min($t.StopMaxSec, $runningStreams * $t.StopPerStreamSec))
        $deadline = (Get-Date).AddSeconds($t.AckTimeoutSec)
        $acked = $false
        while ((Get-Date) -lt $deadline) {
            $ack = $null; try { $ack = Get-DbKeyValue -Key $script:BenchKvAck } catch { }
            if ($ack -and [string]$ack.runId -eq $runId) { $acked = $true; break }
            if (& $cancelled) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $acked -and -not (& $cancelled)) {
            Write-Log "Benchmark: VRMonitor did not acknowledge the pause - stopping the remaining scrcpy sessions directly." -Level WARNING
            try { Stop-Scrcpy | Out-Null } catch { }
        }
        # Whatever VRMonitor did, no scrcpy may be left before measuring.
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }).Count -gt 0) {
            Start-Sleep -Milliseconds 500
        }

        $global:CaptureMode = 'StreamOnly'
        if (@($tests | Where-Object { $_.Encoding -ne 'none' }).Count -gt 0) { try { Start-MediaMtx } catch { } }

        # Pre-warm the encoders: the probe takes seconds and must not be measured. Cached per
        # codec+acceleration, since Get-GpuEncoder keeps only ONE result.
        $encCache = @{}
        $encKeys = @($tests | Where-Object { $_.Encoding -in @('gpu', 'cpu') } | ForEach-Object { '{0}|{1}' -f $_.Encoding, $_.Codec } | Select-Object -Unique)
        if ($encKeys.Count -gt 0) {
            & $publish 'pre-warming encoders' ($encKeys.Count * $t.EncoderProbeSec)
            foreach ($k in $encKeys) {
                $parts = $k -split '\|'
                $global:mediamtxCodec = $parts[1]
                $global:GPU_Acceleration = ($parts[0] -eq 'gpu')
                $global:GpuEncoder = $null
                $encCache[$k] = Get-GpuEncoder
                Write-Log ("Benchmark: encoder for {0} is {1}" -f $k, $encCache[$k].Name) -Level INFO
            }
        }

        for ($i = 0; $i -lt $tests.Count; $i++) {
            if (& $cancelled) { $status = 'cancelled'; break }
            $test = $tests[$i]
            $state.index = $i + 1
            $state.current = $test.Label
            $testStart = Get-Date
            Set-StreamBenchmarkActive -RunId $runId -Seconds ($estTests[$i] * 3 + 60)

            $res = [ordered]@{
                Id = $test.Id; Group = $test.Group; Label = $test.Label; Eye = $test.Eye; View = $test.View
                Fps = $test.Fps; Mbps = $test.Mbps; Encoding = $test.Encoding; Codec = $test.Codec
                Encoder = ''; Status = 'ok'; Message = ''; ElapsedSec = 0; Load = $null
                Stream = [ordered]@{ TargetFps = $test.Fps; Fps = $null; Frames = $null; Drop = $null; Dup = $null; Speed = $null }
            }

            if (-not $test.Available) {
                $res.Status = 'skipped'; $res.Message = $test.Reason
                $results.Add($res); continue
            }

            if ($test.Encoding -eq 'none') {
                & $publish 'settling' $t.SettleSec
                Start-Sleep -Seconds $t.SettleSec
            } else {
                # Apply the overrides of this test.
                $encKey = '{0}|{1}' -f $test.Encoding, $test.Codec
                $global:mediamtxReencode = ($test.Encoding -ne 'copy')
                if ($test.Encoding -ne 'copy') {
                    $global:mediamtxCodec     = $test.Codec
                    $global:GPU_Acceleration  = ($test.Encoding -eq 'gpu')
                    $global:mediamtxFramerate = $test.Fps
                    $global:GpuEncoder        = $encCache[$encKey]
                    if ($test.Encoding -eq 'gpu' -and $encCache[$encKey] -and $encCache[$encKey].Vendor -eq 'CPU') {
                        $res.Status = 'skipped'; $res.Message = ('No working GPU encoder for {0} on this PC.' -f $test.Codec)
                        $results.Add($res); continue
                    }
                    $res.Encoder = [string]$encCache[$encKey].Name
                } else {
                    $res.Encoder = 'copy'
                }
                $scrcpyProfile = ConvertTo-ScrcpyProfile -View $test.View -Eye $test.Eye -AudioDup $false -Fps $test.Fps -BitrateMbps $test.Mbps

                & $publish 'starting stream' $test.OverheadSec ((Get-Date) - $testStart).TotalSeconds
                if (Test-Path -LiteralPath $ffProgress) { Remove-Item -LiteralPath $ffProgress -Force -ErrorAction SilentlyContinue }
                start-screenCopy -headsetIP ([string]$Headset.IPAddress) -displayName ([string]$Headset.Name) -recording $false `
                    -scrcpyProfile $scrcpyProfile -ffmpegProgressFile $ffProgress
                $pipe = $global:HeadsetPipelines[$safeName]
                if (-not $pipe -or -not $pipe.FfmpegProcess -or $pipe.FfmpegProcess.HasExited) {
                    $res.Status = 'failed'; $res.Message = 'The stream did not start (see the scrcpy / ffmpeg logs).'
                    try { Stop-Scrcpy -HeadsetName ([string]$Headset.Name) | Out-Null } catch { }
                    $res.ElapsedSec = [int]((Get-Date) - $testStart).TotalSeconds
                    $results.Add($res); continue
                }
                if ($test.Eye -eq 'M' -and -not $pipe.EyeMergeKey) {
                    $res.Status = 'fallback'; $res.Message = 'Merged view not used - the right eye was streamed (see the eye merge warning in the log).'
                }

                & $publish 'warm-up' $t.WarmupSec ((Get-Date) - $testStart).TotalSeconds
                $warmEnd = (Get-Date).AddSeconds($t.WarmupSec)
                while ((Get-Date) -lt $warmEnd -and -not (& $cancelled)) { Start-Sleep -Milliseconds 500 }
                if (& $cancelled) {
                    try { Stop-Scrcpy -HeadsetName ([string]$Headset.Name) | Out-Null } catch { }
                    $status = 'cancelled'; break
                }
            }

            # ---- Measure ----
            & $publish 'measuring' $MeasureSec ((Get-Date) - $testStart).TotalSeconds
            $p0 = Read-FfmpegProgressFile -Path $ffProgress
            $c0 = $null; if ('VrhmCpuTimes' -as [type]) { $c0 = [VrhmCpuTimes]::Read() }
            $m0 = Get-Date
            $samples = [System.Collections.Generic.List[object]]::new()
            $measureEnd = $m0.AddSeconds($MeasureSec)
            while ((Get-Date) -lt $measureEnd) {
                $samples.Add((Measure-StreamBenchmarkSample))
                if (& $cancelled) { break }
                if ($test.Encoding -ne 'none' -and $pipe -and $pipe.FfmpegProcess.HasExited) {
                    $res.Status = 'failed'; $res.Message = 'ffmpeg exited during the measure (see its log).'
                    break
                }
                & $publish 'measuring' ([int]($measureEnd - (Get-Date)).TotalSeconds) ((Get-Date) - $testStart).TotalSeconds
            }
            $c1 = $null; if ('VrhmCpuTimes' -as [type]) { $c1 = [VrhmCpuTimes]::Read() }
            $span = ((Get-Date) - $m0).TotalSeconds
            $p1 = Read-FfmpegProgressFile -Path $ffProgress
            $res.Load = Get-StreamBenchmarkAggregate -Samples $samples.ToArray() -CpuWindowAvg (Get-StreamBenchmarkCpuPercent -From $c0 -To $c1)

            if ($test.Encoding -ne 'none') {
                if ($null -ne $p1.Frame -and $null -ne $p0.Frame -and $span -gt 0) {
                    $res.Stream.Frames = [int]($p1.Frame - $p0.Frame)
                    $res.Stream.Fps    = [Math]::Round(($p1.Frame - $p0.Frame) / $span, 1)
                }
                if ($null -ne $p1.Drop) { $res.Stream.Drop = [int]($p1.Drop - [double]$(if ($null -ne $p0.Drop) { $p0.Drop } else { 0 })) }
                if ($null -ne $p1.Dup)  { $res.Stream.Dup  = [int]($p1.Dup  - [double]$(if ($null -ne $p0.Dup)  { $p0.Dup }  else { 0 })) }
                $res.Stream.Speed = $p1.Speed
                if ($res.Status -eq 'ok' -and $null -eq $res.Stream.Fps) { $res.Message = 'No ffmpeg progress data - stream figures unavailable.' }

                & $publish 'settling' ($t.StopOverheadSec + $t.SettleSec) ((Get-Date) - $testStart).TotalSeconds
                try { Stop-Scrcpy -HeadsetName ([string]$Headset.Name) | Out-Null } catch { }
                Start-Sleep -Seconds $t.SettleSec
            }

            $res.ElapsedSec = [int]((Get-Date) - $testStart).TotalSeconds
            $doneEst += $estTests[$i]; $doneActual += $res.ElapsedSec
            $results.Add($res)
            Write-Log ("Benchmark: {0} -> {1}, CPU {2}%, fps {3}" -f $test.Label, $res.Status, $res.Load.CpuAvg, $res.Stream.Fps) -Level INFO
            if (& $cancelled) { $status = 'cancelled'; break }
        }
    } catch {
        $status = 'error'; $err = $_.Exception.Message
        Write-Log ("Benchmark {0} failed: {1}" -f $runId, $err) -Level ERROR
    } finally {
        try { Stop-Scrcpy -HeadsetName ([string]$Headset.Name) | Out-Null } catch { }
        foreach ($k in $saved.Keys) { Set-Variable -Name $k -Scope Global -Value $saved[$k] }
        Clear-StreamBenchmarkActive
        if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $ffProgress) { Remove-Item -LiteralPath $ffProgress -Force -ErrorAction SilentlyContinue }
    }

    $gpuList = @()
    $first = $results | Where-Object { $_.Load -and $_.Load.Gpus } | Select-Object -First 1
    if ($first) { $gpuList = @($first.Load.Gpus | ForEach-Object { @{ Index = $_.Index; Model = $_.Model } }) }
    $result = [ordered]@{
        Ok         = ($status -eq 'done')
        Status     = $status
        Error      = $err
        RunId      = $runId
        Timestamp  = (Get-Date).ToString('s')
        Host       = $env:COMPUTERNAME
        Headset    = [ordered]@{ ID = $Headset.ID; Name = $Headset.Name; Model = $Headset.Model }
        MeasureSec = $MeasureSec
        ReencodeBitrate = [string]$global:mediamtxBitrate
        Gpus       = $gpuList
        Results    = $results.ToArray()
    }
    if ($results.Count -gt 0) { try { Set-DbKeyValue -Key $script:BenchKvResult -Value $result } catch { Write-Log ("Benchmark: result not saved: " + $_.Exception.Message) -Level WARNING } }

    $state.status = $status; $state.error = $err; $state.index = $results.Count
    & $publish 'done'
    Write-Log ("Benchmark {0} finished: {1}, {2} result(s), {3} s" -f $runId, $status, $results.Count, [int]((Get-Date) - $startedAt).TotalSeconds) -Level $(if ($status -eq 'error') { 'ERROR' } else { 'SUCCESS' })
    return $result
}


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

function Get-StreamBenchmarkResult {
    <# The last stored benchmark result (app_kv benchmark_last), or $null. #>
    param()
    try { return (Get-DbKeyValue -Key $script:BenchKvResult) } catch { return $null }
}


function ConvertTo-StreamBenchmarkCsv {
    <#
    .SYNOPSIS
    CSV text of a benchmark result: one line per test and per GPU (the test columns repeat).
    .EXAMPLE
    ConvertTo-StreamBenchmarkCsv -Result (Get-StreamBenchmarkResult) | Set-Content ...
    #>
    param([Parameter(Mandatory = $true)]$Result)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fmt = { param($v) if ($null -eq $v) { '' } else { [string]::Format($inv, '{0}', $v) } }
    $q = { param($s) '"' + ([string]$s -replace '"', '""') + '"' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Host,Headset,Model,Timestamp,MeasureSec,Test,Group,Eye,View,Fps,Mbps,Encoding,Codec,Encoder,Status,Message,CpuAvg,CpuPeak,RamUsedGB,RamPeakGB,GpuIndex,GpuModel,GpuUtilAvg,GpuUtilPeak,Gpu3DAvg,GpuVideoAvg,GpuEncodeAvg,GpuVramGB,ScrcpyCpu,ScrcpyMB,FfmpegCpu,FfmpegMB,MediamtxCpu,MediamtxMB,StreamFps,TargetFps,Frames,Drop,Dup,Speed,ElapsedSec')
    foreach ($r in @($Result.Results)) {
        $l = $r.Load
        $gpus = if ($l -and $l.Gpus -and @($l.Gpus).Count -gt 0) { @($l.Gpus) } else { @($null) }
        foreach ($g in $gpus) {
            $cells = @(
                (& $q $Result.Host), (& $q $Result.Headset.Name), (& $q $Result.Headset.Model), (& $q $Result.Timestamp), (& $fmt $Result.MeasureSec),
                (& $q $r.Label), (& $q $r.Group), (& $q $r.Eye), (& $q $r.View), (& $fmt $r.Fps), (& $fmt $r.Mbps), (& $q $r.Encoding), (& $q $r.Codec), (& $q $r.Encoder),
                (& $q $r.Status), (& $q $r.Message),
                (& $fmt $l.CpuAvg), (& $fmt $l.CpuPeak), (& $fmt $l.RamUsedGB), (& $fmt $l.RamPeakGB),
                (& $fmt $g.Index), (& $q $g.Model), (& $fmt $g.UtilAvg), (& $fmt $g.UtilPeak), (& $fmt $g.D3Avg), (& $fmt $g.VideoAvg), (& $fmt $g.EncodeAvg), (& $fmt $g.VramGB),
                (& $fmt $l.Procs.scrcpy.CpuAvg), (& $fmt $l.Procs.scrcpy.MemMB), (& $fmt $l.Procs.ffmpeg.CpuAvg), (& $fmt $l.Procs.ffmpeg.MemMB), (& $fmt $l.Procs.mediamtx.CpuAvg), (& $fmt $l.Procs.mediamtx.MemMB),
                (& $fmt $r.Stream.Fps), (& $fmt $r.Stream.TargetFps), (& $fmt $r.Stream.Frames), (& $fmt $r.Stream.Drop), (& $fmt $r.Stream.Dup), (& $fmt $r.Stream.Speed), (& $fmt $r.ElapsedSec)
            )
            $lines.Add(($cells -join ','))
        }
    }
    return ($lines -join "`r`n")
}
