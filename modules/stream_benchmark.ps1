###############################################################################
# stream_benchmark.ps1 - capture benchmark of ONE headset (ADR-0026).
#
# WHAT IT DOES
# ------------
# Runs a grid of short capture tests on one headset - single eye vs merged, view,
# capture FPS and bitrate, GPU (each one) vs CPU encoder, h264 vs h265, re-encode
# bitrate and max capture size -
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
# THE RUN WRITES NOTHING TO CONFIG. The test settings (re-encode, codec, GPU on/off and
# index, re-encode framerate and bitrate, max capture size, capture mode) are $global:
# overrides in the benchmark's own process, and the scrcpy profile is a start-screenCopy
# parameter, never a registry write. Only an operator "Apply" of a recommendation
# (Set-StreamBenchmarkRecommendation) writes config, and VRMonitor then restarts the
# streams it owns (Request-StreamRestart, ADR-0027).
#
# The web server runs Invoke-StreamBenchmark in a background job (one at a time);
# the console runs it in the foreground (Show-SubMenu-Benchmark).
#
# ASCII only in string literals (the file is saved without a BOM).
###############################################################################

# Timings used by the run AND by the duration estimate (website\benchmark.html gets them
# from Get-StreamBenchmarkOptions / New-StreamBenchmarkPlan).
$script:BenchTiming = @{
    WarmupSec          = 8     # stream up, before measuring
    SettleSec          = 3     # after a stream stopped, before the next one
    StartOverheadSec   = 5     # start-screenCopy: 0.5 s bridge + 3 s before ffmpeg + scrcpy connect
    StopOverheadSec    = 2     # Stop-Scrcpy + pipeline teardown
    MergeExtraSec      = 3     # remap tables of a merged view (0 when cached)
    EncoderProbeSec    = 25    # Get-GpuEncoder probe, once per GPU codec (NVENC measured ~30 s)
    SamplerWarmSec     = 6     # New-StreamBenchmarkSampler: first GPU counter read, once per run
    StopPerStreamSec   = 5     # VRMonitor stopping one running stream
    StopMaxSec         = 30
    RestoreSec         = 10    # normal streams coming back at the end
    AckTimeoutSec      = 60    # wait for VRMonitor to acknowledge the pause
}

$script:BenchKvFlag   = 'benchmark_active'
$script:BenchKvAck    = 'benchmark_ack'
# Results accumulate per headset model (ADR-0027): benchmark_result_<model>, plus the
# model benchmarked last so a caller without a model still finds something to show.
$script:BenchKvResultPrefix = 'benchmark_result_'
$script:BenchKvLastModel    = 'benchmark_last_model'
# Stream restart requests executed by VRMonitor (Request-StreamRestart, ADR-0027).
$script:BenchKvRestart      = 'streams_restart_request'
# Hard cap on one run (a full grid grows fast: 2 x 2 x 4 x 4 x 2 = 128).
$script:BenchMaxTests       = 200
# PS 5.1 TRAP, fixed everywhere in this file: [Math]::Max(0, 3.4) returns 3 - PowerShell picks
# the INT overload when the first argument is an int literal and truncates the double. It turned
# every sub-second process CPU delta into 0 (adb / bridge / NVENC ffmpeg always read 0 %) and
# rounded GPU percentages and load deltas. Always write 0.0 / 100.0 when the value is a double.
# Processes of the capture chain, by name (the pipe bridge job is tracked by PID).
$script:BenchProcNames      = @('adb', 'scrcpy', 'ffmpeg', 'mediamtx')
# Concurrent NVENC sessions a GeForce driver allows (8 on current drivers; professional cards
# are not limited). Caps the headset count of an NVIDIA-encoded recommendation.
$script:BenchNvencSessionCap = 8
# Last parallel check (Invoke-StreamBenchmarkParallel).
$script:BenchKvParallel     = 'benchmark_parallel_last'


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
# Options, plan (test grid) and estimate
# ---------------------------------------------------------------------------

function Get-StreamBenchmarkTiming {
    <# The timing constants (run and estimate). Returned as a copy. #>
    param()
    return $script:BenchTiming.Clone()
}


function Get-StreamBenchmarkTestEstimate {
    <#
    .SYNOPSIS
    Estimated seconds for ONE test with a measure window of -MeasureSec.
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
    one encoder probe per GPU + codec pair among -Tests, and the restore at the end.
    #>
    param(
        [object[]]$Tests = @(),
        [int]$RunningStreams = 0
    )
    $t = $script:BenchTiming
    $stop = [Math]::Min($t.StopMaxSec, $RunningStreams * $t.StopPerStreamSec)
    $gpuKeys = @($Tests | Where-Object { $_.Encoding -eq 'gpu' } | ForEach-Object { '{0}|{1}' -f $_.GpuIndex, $_.Codec } | Select-Object -Unique)
    return [int]($stop + $gpuKeys.Count * $t.EncoderProbeSec + $t.SamplerWarmSec + $t.RestoreSec)
}


function ConvertTo-StreamBenchmarkMbps {
    <# "4M" / "4000k" / "4" -> 4 (Mb/s, int). $null when unparsable. #>
    param($Value)
    $s = ([string]$Value).Trim().ToUpper()
    if ($s -match '^(\d+(?:\.\d+)?)\s*M?$') { return [int][Math]::Round([double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)) }
    if ($s -match '^(\d+(?:\.\d+)?)\s*K$')  { return [int][Math]::Max(1, [Math]::Round([double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) / 1000)) }
    return $null
}


function Get-StreamBenchmarkModelTemplate {
    <#
    .SYNOPSIS
    The scrcpy.parameters entry of one model, or $null. $global:scrcpyParameters is a
    PSCustomObject, or a one-element array of it after Update-EyeMergeParameters reloaded
    it, so both shapes are handled here.
    #>
    param([string]$Model)
    if (-not $Model -or -not $global:scrcpyParameters) { return $null }
    $root = @($global:scrcpyParameters)[0]
    if (-not $root) { return $null }
    $p = $root.PSObject.Properties[$Model]
    if ($p) { return $p.Value }
    return $null
}


function Set-StreamBenchmarkModelTemplate {
    <# Replaces the scrcpy.parameters entry of one model IN MEMORY (benchmark process only). #>
    param([string]$Model, $Template)
    $root = @($global:scrcpyParameters)[0]
    if (-not $root -or -not $Model) { return }
    if ($root.PSObject.Properties[$Model]) { $root.$Model = $Template }
    else { $root | Add-Member -NotePropertyName $Model -NotePropertyValue $Template }
}


function Get-StreamBenchmarkGpuList {
    <#
    .SYNOPSIS
    The GPUs of this PC as @(@{Index;Model;Best}). Read from the last computer-monitoring
    snapshot (no counter read on the web listener); Get-GpuInfo only when there is none.
    Best = config Performance.GPU_Index (first GPU when that index does not exist).
    #>
    param()
    $gpus = @()
    try {
        $snap = Get-DbKeyValue -Key 'computer_monitoring'
        if ($snap -and $snap.GPU) { $gpus = @($snap.GPU) }
    } catch { }
    if ($gpus.Count -eq 0) { try { $gpus = @(Get-GpuInfo) } catch { $gpus = @() } }
    $best = [int]$global:GPU_Index
    if (-not ($gpus | Where-Object { [int]$_.Index -eq $best })) { $best = if ($gpus.Count -gt 0) { [int]$gpus[0].Index } else { -1 } }
    return @($gpus | ForEach-Object { @{ Index = [int]$_.Index; Model = [string]$_.Model; Best = ([int]$_.Index -eq $best) } })
}


function Get-StreamBenchmarkOptions {
    <#
    .SYNOPSIS
    Everything the benchmark page (and the console) needs to draw the test selection for one
    headset: views, merge support, GPUs, configured re-encode bitrate / max capture size,
    the default selection (= the reference test), the offered choices and the timing.
    Config, registry and database only - no ADB, no GPU probe.
    .EXAMPLE
    Get-StreamBenchmarkOptions -Headset (Get-HeadsetDiagTarget -Id 3)
    #>
    param([Parameter(Mandatory = $true)]$Headset)

    $model = [string]$Headset.Model
    $tpl = Get-StreamBenchmarkModelTemplate -Model $model
    $views = @()
    if ($tpl -and $tpl.views) { $views = @($tpl.views.PSObject.Properties | ForEach-Object { $_.Name }) }
    $current = $null
    $parsed = ConvertFrom-ScrcpyProfile -Profile ([string]$Headset.ScrcpyProfile)
    if ($parsed) { $current = $parsed.View }
    if (-not $current -or ($views.Count -gt 0 -and $views -notcontains $current)) { $current = Get-ScrcpyDefaultView -Model $model }
    if ($views.Count -eq 0) { $views = @($current) }

    $mergeOk = $false
    try { $mergeOk = [bool](Test-EyeMergeSupported -Model $model) } catch { $mergeOk = $false }

    $gpus = @(Get-StreamBenchmarkGpuList)
    $bestGpu = $gpus | Where-Object { $_.Best } | Select-Object -First 1
    $reenc = ConvertTo-StreamBenchmarkMbps $global:mediamtxBitrate
    if (-not $reenc) { $reenc = 4 }
    $maxSize = if ($tpl -and $null -ne $tpl.max_size) { [int]$tpl.max_size } else { 0 }

    $defaultEnc = if ($bestGpu) { 'gpu:' + $bestGpu.Index } else { 'cpu' }
    return @{
        Model           = $model
        Views           = @($views | ForEach-Object { @{ Name = $_; Current = ($_ -eq $current) } })
        CurrentView     = $current
        MergeSupported  = $mergeOk
        MergeReason     = if ($mergeOk) { '' } else { 'No eye merge calibration for this model.' }
        Gpus            = $gpus
        SourceCodec     = if ($tpl -and $tpl.video_codec) { [string]$tpl.video_codec } else { 'h264' }
        ReencodeMbps    = $reenc
        MaxSize         = $maxSize
        MediamtxEnabled = [bool]$global:mediamtxEnabled
        Timing          = (Get-StreamBenchmarkTiming)
        Thresholds      = @{
            CpuMax = if ($null -ne $global:VQA_CpuMaxThreshold) { [int]$global:VQA_CpuMaxThreshold } else { 80 }
            GpuMax = if ($null -ne $global:VQA_GpuMaxThreshold) { [int]$global:VQA_GpuMaxThreshold } else { 80 }
            CpuMitigation = if ($null -ne $global:VQA_CpuMitigationThreshold) { [int]$global:VQA_CpuMitigationThreshold } else { 60 }
            GpuMitigation = if ($null -ne $global:VQA_GpuMitigationThreshold) { [int]$global:VQA_GpuMitigationThreshold } else { 60 }
        }
        Choices         = @{
            Bitrates     = @(5, 10, 20, 40)
            Fps          = @(15, 30, 45, 60)
            ReencodeMbps = @(2, 4, 6, 8, 12)
            MaxSizes     = @(0, 2560, 1920, 1440, 1080, 720)
        }
        Defaults        = @{
            Encodings = @($defaultEnc); Codecs = @('h264'); Bitrates = @(10); Fps = @(45)
            Eyes = @('R'); View = $current; ReencodeMbps = $reenc; MaxSize = $maxSize
        }
    }
}


function Get-StreamBenchmarkSelectionValue {
    <# Reads one field of a selection given as a hashtable OR a PSCustomObject (parsed JSON). #>
    param($Selection, [string]$Name)
    if ($null -eq $Selection) { return $null }
    if ($Selection -is [System.Collections.IDictionary]) {
        foreach ($k in $Selection.Keys) { if ([string]$k -ieq $Name) { return $Selection[$k] } }
        return $null
    }
    $p = $Selection.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($p) { return $p.Value }
    return $null
}


function New-StreamBenchmarkTest {
    <# Builds one test object (internal). Encoding: none | cpu | gpu. #>
    param(
        [string]$Encoding, [int]$GpuIndex = -1, [string]$GpuName = '', [string]$Codec = '',
        [string]$Eye = '', [string]$View = '', [int]$Fps = 0, [int]$Mbps = 0,
        [int]$ReencodeMbps = 0, [int]$MaxSize = 0,
        # Typical presets: what this test varies (ref / size / fps / mbps / reenc / merged / baseline).
        [string]$Role = '',
        # Baselines only: -End gives the closing baseline 'baseline_end' (drift correction).
        [switch]$End
    )
    $t = $script:BenchTiming
    if ($Encoding -eq 'none') {
        return [ordered]@{
            Id = $(if ($End) { 'baseline_end' } else { 'baseline' })
            Label = $(if ($End) { 'Baseline at the end - no stream (idle PC)' } else { 'Baseline - no stream (idle PC)' })
            Eye = ''; View = ''; Fps = 0; Mbps = 0
            Encoding = 'none'; GpuIndex = -1; GpuName = ''; Codec = ''; ReencodeMbps = 0; MaxSize = 0
            Available = $true; Reason = ''; OverheadSec = 0; Role = 'baseline'
        }
    }
    # A merged view always sends the full frame: max capture size does not apply to it.
    if ($Eye -eq 'M') { $MaxSize = -1 }
    $encTag = if ($Encoding -eq 'gpu') { 'gpu' + $GpuIndex } else { 'cpu' }
    $id = ('{0}-{1}-{2}-{3}-{4}-{5}-r{6}-s{7}' -f $Eye, $View, $Fps, $Mbps, $encTag, $Codec, $ReencodeMbps, $MaxSize).ToLower()
    $encLabel = if ($Encoding -eq 'gpu') { 'GPU {0} {1}' -f $GpuIndex, $Codec } else { 'CPU ' + $Codec }
    $eyeLabel = if ($Eye -eq 'M') { 'merged' } else { 'single eye' }
    $sizeLabel = if ($MaxSize -lt 0) { 'full frame' } elseif ($MaxSize -eq 0) { 'native size' } else { 'max {0} px' -f $MaxSize }
    $overhead = $t.StartOverheadSec + $t.StopOverheadSec
    if ($Eye -eq 'M') { $overhead += $t.MergeExtraSec }
    return [ordered]@{
        Id = $id
        Label = ('{0} {1}, {2} fps, {3} Mb/s, {4}, re-encode {5} Mb/s, {6}' -f $eyeLabel, $View, $Fps, $Mbps, $encLabel, $ReencodeMbps, $sizeLabel)
        Eye = $Eye; View = $View; Fps = $Fps; Mbps = $Mbps
        Encoding = $Encoding; GpuIndex = $GpuIndex; GpuName = $GpuName; Codec = $Codec
        ReencodeMbps = $ReencodeMbps; MaxSize = $MaxSize
        Available = $true; Reason = ''; OverheadSec = $overhead; Role = $Role
    }
}


function Get-StreamBenchmarkFramePixels {
    <#
    .SYNOPSIS
    Size of the picture a stream carries: @{W;H;Pixels;NativeW;NativeH;Approx}. Single eye: the
    view's eye crop (scrcpy --crop, kept by --angle), scaled down to -MaxSize like scrcpy
    --max-size (longest side, multiple of 8). Merged (-Eye M): the merged canvas crop of that
    view (max size does not apply). The base of the model's pixel-rate axis.
    .EXAMPLE
    Get-StreamBenchmarkFramePixels -Model 'Quest 3' -View 'square' -MaxSize 1080
    #>
    param([Parameter(Mandatory = $true)][string]$Model, [string]$View, [string]$Eye = 'R', [int]$MaxSize = 0)
    $res = @{ W = 0; H = 0; Pixels = 0; NativeW = 0; NativeH = 0; Approx = $false }
    $mp = $null
    try { $mp = Get-EyeMergeProfile -Model $Model -IncludeDisabled } catch { }
    if ($Eye -eq 'M' -and $mp) {
        $crop = $null; try { $crop = Get-EyeMergeViewCrop -Model $Model -View $View -MergeProfile $mp } catch { }
        if ($crop) { $res.W = [int]$crop.W; $res.H = [int]$crop.H; $res.NativeW = $res.W; $res.NativeH = $res.H; $res.Pixels = $res.W * $res.H; return $res }
    }
    $w = 0; $h = 0
    $tpl = Get-StreamBenchmarkModelTemplate -Model $Model
    $vd = if ($tpl -and $tpl.views -and $View) { $tpl.views.$View } else { $null }
    $eyeDef = if ($vd) { if ($Eye -eq 'L') { $vd.left_eye } else { $vd.right_eye } } else { $null }
    if ($eyeDef -and $eyeDef.crop -and ([string]$eyeDef.crop) -match '^(\d+):(\d+):') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
    if ($w -le 0 -or $h -le 0) {
        # No crop ('fullscreen'): the whole frame - known from the eye merge calibration, else a guess.
        if ($mp -and $mp.frame_width) { $w = [int]$mp.frame_width; $h = [int]$mp.frame_height } else { $w = 3840; $h = 2160; $res.Approx = $true }
    }
    $res.NativeW = $w; $res.NativeH = $h
    $long = [Math]::Max($w, $h)
    if ($MaxSize -gt 0 -and $long -gt $MaxSize) {
        $k = $MaxSize / $long
        $w = [int]([Math]::Floor($w * $k / 8) * 8); $h = [int]([Math]::Floor($h * $k / 8) * 8)
    }
    $res.W = $w; $res.H = $h; $res.Pixels = $w * $h
    return $res
}


function New-StreamBenchmarkPlan {
    <#
    .SYNOPSIS
    Expands a test selection into the run list: the baseline, then EVERY combination of
    the selected values (full grid). Returns @{Ok;Error;Tests;Count;EstimateSec;FixedSec}.
    .DESCRIPTION
    -Selection (hashtable or parsed JSON), every list optional - an empty or invalid list
    falls back to the default (the reference test):
      Encodings    'cpu' and/or 'gpu:<index>' (unknown GPU indexes are dropped)
      Codecs       'h264' / 'h265'
      Bitrates     capture Mb/s, 1..100        Fps  5..120
      Eyes         'R' (single eye) / 'M' (merged; dropped when the model has no calibration)
      View         one view of the model (else the headset's current one)
      ReencodeMbps one value 1..100 (else config)   MaxSize  one value 0..8192 (0 = native; else config)
    Pure computation (no ADB) so the page can call it on every click. Refuses more than
    $script:BenchMaxTests tests.
    .EXAMPLE
    New-StreamBenchmarkPlan -Headset $h -Selection @{ Encodings = 'gpu:0','cpu'; Fps = 30,60 }
    #>
    param(
        [Parameter(Mandatory = $true)]$Headset,
        $Selection = $null,
        [int]$MeasureSec = 20,
        [int]$RunningStreams = -1
    )
    $opt = Get-StreamBenchmarkOptions -Headset $Headset
    $def = $opt.Defaults
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $intList = {
        param($raw, [int]$min, [int]$max, $fallback)
        $vals = @(@($raw) | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object {
            $n = 0.0
            if ([double]::TryParse([string]$_, [System.Globalization.NumberStyles]::Float, $inv, [ref]$n)) { [int][Math]::Round($n) }
        } | Where-Object { $_ -ge $min -and $_ -le $max } | Select-Object -Unique | Sort-Object)
        if ($vals.Count -eq 0) { return @($fallback) }
        return @($vals | Select-Object -First 8)
    }

    $gpuByIdx = @{}; foreach ($g in $opt.Gpus) { $gpuByIdx[[int]$g.Index] = $g }
    $encs = @(@(Get-StreamBenchmarkSelectionValue $Selection 'Encodings') | ForEach-Object { ([string]$_).Trim().ToLower() } | Where-Object {
        $_ -eq 'cpu' -or ($_ -match '^gpu:(\d+)$' -and $gpuByIdx.ContainsKey([int]$Matches[1]))
    } | Select-Object -Unique)
    if ($encs.Count -eq 0) { $encs = @($def.Encodings) }
    $codecs = @(@(Get-StreamBenchmarkSelectionValue $Selection 'Codecs') | ForEach-Object { ([string]$_).Trim().ToLower() } | Where-Object { $_ -in @('h264', 'h265') } | Select-Object -Unique)
    if ($codecs.Count -eq 0) { $codecs = @($def.Codecs) }
    $bitrates = @(& $intList (Get-StreamBenchmarkSelectionValue $Selection 'Bitrates') 1 100 $def.Bitrates)
    $fpsList  = @(& $intList (Get-StreamBenchmarkSelectionValue $Selection 'Fps') 5 120 $def.Fps)
    $eyes = @(@(Get-StreamBenchmarkSelectionValue $Selection 'Eyes') | ForEach-Object { ([string]$_).Trim().ToUpper() } | Where-Object { $_ -in @('R', 'M') } | Select-Object -Unique)
    if (-not $opt.MergeSupported) { $eyes = @($eyes | Where-Object { $_ -ne 'M' }) }
    if ($eyes.Count -eq 0) { $eyes = @($def.Eyes) }
    $view = [string](Get-StreamBenchmarkSelectionValue $Selection 'View')
    if (-not $view -or -not ($opt.Views | Where-Object { $_.Name -eq $view })) { $view = $opt.CurrentView }
    $reenc = @(& $intList (Get-StreamBenchmarkSelectionValue $Selection 'ReencodeMbps') 1 100 $def.ReencodeMbps)[0]
    $size  = @(& $intList (Get-StreamBenchmarkSelectionValue $Selection 'MaxSize') 0 8192 $def.MaxSize)[0]

    $tests = [System.Collections.Generic.List[object]]::new()
    $tests.Add((New-StreamBenchmarkTest -Encoding 'none'))
    $seen = @{}
    $preset = ([string](Get-StreamBenchmarkSelectionValue $Selection 'Preset')).Trim().ToLower()
    if ($preset -in @('typical', 'typical-quick')) {
        # ---- Typical tests: ONE change at a time from a reference, for every encoder x codec, so
        # Get-StreamBenchmarkModel can fit cost = a + b x (pixels x fps) per family and predict
        # every combination. Reference: single eye, 45 fps, 10 Mb/s, native size.
        $addT = {
            param($enc, $codec, $eye, $f, $b, $re, $sz, $role)
            $isGpu = $enc -like 'gpu:*'
            $gIdx = if ($isGpu) { [int]($enc.Split(':')[1]) } else { -1 }
            $test = New-StreamBenchmarkTest -Encoding $(if ($isGpu) { 'gpu' } else { 'cpu' }) -GpuIndex $gIdx `
                -GpuName $(if ($isGpu) { [string]$gpuByIdx[$gIdx].Model } else { '' }) -Codec $codec -Eye $eye -View $view `
                -Fps $f -Mbps $b -ReencodeMbps $re -MaxSize $sz -Role $role
            if ($seen.ContainsKey($test.Id)) { return }
            $seen[$test.Id] = $true
            if (-not $opt.MediamtxEnabled) { $test.Available = $false; $test.Reason = 'mediamtx is disabled: streaming tests need it.' }
            $tests.Add($test)
        }
        $bestEnc = @($def.Encodings)[0]
        $famEncs = if ($preset -eq 'typical') { @('cpu') + @($opt.Gpus | ForEach-Object { 'gpu:' + $_.Index }) } else { @('cpu', $bestEnc) | Select-Object -Unique }
        $px = Get-StreamBenchmarkFramePixels -Model $opt.Model -View $view -Eye 'R'
        $native = [Math]::Max($px.NativeW, $px.NativeH)
        # Mid size: geometric middle of 720 and native, on scrcpy's multiple of 8.
        $mid = [int]([Math]::Round([Math]::Sqrt(720 * $native) / 8) * 8)
        foreach ($enc in $famEncs) {
            foreach ($codec in 'h264', 'h265') {
                & $addT $enc $codec 'R' 45 10 $reenc 0 'ref'
                if ($mid -lt $native - 64) { & $addT $enc $codec 'R' 45 10 $reenc $mid 'size' }
                if (720 -lt $native - 64)  { & $addT $enc $codec 'R' 45 10 $reenc 720 'size' }
                & $addT $enc $codec 'R' 30 10 $reenc 0 'fps'
                & $addT $enc $codec 'R' 60 10 $reenc 0 'fps'
            }
        }
        # Shared effects, measured once on the reference family (best encoder, H264).
        & $addT $bestEnc 'h264' 'R' 45 5 $reenc 0 'mbps'
        & $addT $bestEnc 'h264' 'R' 45 20 $reenc 0 'mbps'
        $reLo = [Math]::Max(1, [int][Math]::Round($reenc / 2)); $reHi = [Math]::Min(100.0, $reenc * 2)
        if ($reLo -ne $reenc) { & $addT $bestEnc 'h264' 'R' 45 10 $reLo 0 'reenc' }
        if ($reHi -ne $reenc) { & $addT $bestEnc 'h264' 'R' 45 10 $reHi 0 'reenc' }
        # Merged view measured at its default frame rate (Get-EyeMergeFpsAdvice: 30 fps).
        if ($opt.MergeSupported) { foreach ($enc in $famEncs) { & $addT $enc 'h264' 'M' 30 10 $reenc 0 'merged' } }
        $tests.Add((New-StreamBenchmarkTest -Encoding 'none' -End))
        $eyes = @()   # the grid below is skipped
    }
    foreach ($eye in $eyes) {
        foreach ($enc in $encs) {
            $isGpu = $enc -like 'gpu:*'
            $gIdx = if ($isGpu) { [int]($enc.Split(':')[1]) } else { -1 }
            $gName = if ($isGpu) { [string]$gpuByIdx[$gIdx].Model } else { '' }
            foreach ($codec in $codecs) {
                foreach ($f in $fpsList) {
                    foreach ($b in $bitrates) {
                        $test = New-StreamBenchmarkTest -Encoding $(if ($isGpu) { 'gpu' } else { 'cpu' }) -GpuIndex $gIdx -GpuName $gName `
                            -Codec $codec -Eye $eye -View $view -Fps $f -Mbps $b -ReencodeMbps $reenc -MaxSize $size
                        if ($seen.ContainsKey($test.Id)) { continue }
                        $seen[$test.Id] = $true
                        if (-not $opt.MediamtxEnabled) { $test.Available = $false; $test.Reason = 'mediamtx is disabled: streaming tests need it.' }
                        $tests.Add($test)
                    }
                }
            }
        }
    }

    # A longer grid also gets a closing baseline, so a drift of the idle load during the run can
    # be corrected (Get-StreamBenchmarkBaseline averages both).
    if (-not $seen.ContainsKey('baseline_end') -and $tests.Count -ge 6 -and -not ($tests | Where-Object { $_.Id -eq 'baseline_end' })) {
        $tests.Add((New-StreamBenchmarkTest -Encoding 'none' -End))
    }
    $arr = $tests.ToArray()
    if ($RunningStreams -lt 0) { $RunningStreams = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count }
    $fixed = Get-StreamBenchmarkFixedEstimate -Tests $arr -RunningStreams $RunningStreams
    $sum = 0; foreach ($x in $arr) { $sum += (Get-StreamBenchmarkTestEstimate -Test $x -MeasureSec $MeasureSec) }
    $err = ''
    if ($arr.Count -gt $script:BenchMaxTests) { $err = ('{0} tests selected - the limit is {1}. Untick some options.' -f $arr.Count, $script:BenchMaxTests) }
    return @{
        Ok          = ($err -eq '')
        Error       = $err
        Tests       = $arr
        Count       = $arr.Count
        FixedSec    = $fixed
        EstimateSec = [int]($sum + $fixed)
        Selection   = @{ Encodings = $encs; Codecs = $codecs; Bitrates = $bitrates; Fps = $fpsList; Eyes = $eyes; View = $view; ReencodeMbps = $reenc; MaxSize = $size }
    }
}


# ---------------------------------------------------------------------------
# Measuring
# ---------------------------------------------------------------------------

function Initialize-StreamBenchmarkCpuType {
    <# Compiles the GetSystemTimes wrapper once per process. The type lives in utils.ps1 (Initialize-CpuTimesType), shared with the computer monitor. #>
    param()
    return (Initialize-CpuTimesType)
}


function Get-StreamBenchmarkCpuPercent {
    <# Whole-PC CPU % between two VrhmCpuTimes snapshots (kernel time includes idle). See Get-CpuTimesPercent (utils.ps1). #>
    param($From, $To)
    return (Get-CpuTimesPercent -From $From -To $To)
}


function New-StreamBenchmarkSampler {
    <#
    .SYNOPSIS
    Builds the fast, stateful load sampler of a benchmark run (once per run, ~5 s, during the
    pre-warm phase): the GPU layout (same adapter / LUID rules as Get-GpuInfo) and persistent
    readers of the "GPU Engine" and "GPU Adapter Memory" counter categories.
    .DESCRIPTION
    Get-GpuInfo calls Get-Counter, which re-resolves every GPU Engine instance (616 on a
    two-GPU laptop) on each call: 6-12 s per sample, so a 10 s measure got ONE sample and
    overran by ~30 s. A kept PerformanceCounterCategory pays that once (~5 s on the first
    ReadCategory) and then reads every instance in ~10 ms; utilization is computed from two
    raw snapshots (CounterSample.Calculate), i.e. exactly over the interval between them.
    #>
    param()
    $s = @{ Gpus = @(); Single = $false; ExcludeLuid = $null; Engine = $null; Memory = $null
            Cores = [Math]::Max(1, [Environment]::ProcessorCount); Prev = $null; BridgePids = @() }
    # Same adapter / PCI filter / LUID rules as Get-GpuInfo: one implementation (utils.ps1).
    try {
        $layout = Get-GpuLayout
        if ($layout) {
            $s.Gpus        = @($layout.Gpus)
            $s.Single      = [bool]$layout.Single
            $s.ExcludeLuid = $layout.ExcludeLuid
        }
    } catch { }
    try {
        $s.Engine = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
        [void]$s.Engine.ReadCategory()   # the slow first read, here rather than in a measure
    } catch { $s.Engine = $null }
    try { $s.Memory = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Adapter Memory') } catch { $s.Memory = $null }
    $s.Prev = Read-StreamBenchmarkSnapshot -Sampler $s
    return $s
}


function Read-StreamBenchmarkSnapshot {
    <# Raw state for one sampler tick (internal): CPU times, GPU engine + memory counters, process CPU. #>
    param([Parameter(Mandatory = $true)]$Sampler)
    $snap = @{ Time = [DateTime]::UtcNow; Cpu = $null; Util = $null; Mem = @{}; Proc = @{} }
    if ('VrhmCpuTimes' -as [type]) { $snap.Cpu = [VrhmCpuTimes]::Read() }
    if ($Sampler.Engine) { try { $snap.Util = $Sampler.Engine.ReadCategory()['Utilization Percentage'] } catch { } }
    if ($Sampler.Memory) {
        try {
            $md = $Sampler.Memory.ReadCategory()['Dedicated Usage']
            foreach ($k in @($md.Keys)) { if ($k -match 'luid_(0x[0-9a-f]+_0x[0-9a-f]+)') { $snap.Mem[$Matches[1]] = [double]$md[$k].RawValue } }
        } catch { }
    }
    foreach ($n in $script:BenchProcNames) {
        $cpu = 0.0; $mem = 0.0
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try { $cpu += $p.TotalProcessorTime.TotalSeconds; $mem += $p.WorkingSet64 } catch { }
        }
        $snap.Proc[$n] = @{ Cpu = $cpu; MemMB = [Math]::Round($mem / 1MB, 1) }
    }
    # The pipe bridge is a PowerShell job: no name of its own, tracked by PID
    # (Set-StreamBenchmarkBridgePids after each stream start).
    $cpu = 0.0; $mem = 0.0
    foreach ($bp in @($Sampler.BridgePids)) {
        $p = Get-Process -Id $bp -ErrorAction SilentlyContinue
        if ($p) { try { $cpu += $p.TotalProcessorTime.TotalSeconds; $mem += $p.WorkingSet64 } catch { } }
    }
    $snap.Proc['bridge'] = @{ Cpu = $cpu; MemMB = [Math]::Round($mem / 1MB, 1) }
    return $snap
}


function Set-StreamBenchmarkBridgePids {
    <#
    .SYNOPSIS
    Points the sampler at the pipe bridge job(s) of the stream(s) just started: the
    powershell.exe children of THIS process (Start-HeadsetPipeBridge uses Start-Job). Resets
    the sampler interval so a process appearing mid-interval is not counted from zero.
    #>
    param([Parameter(Mandatory = $true)]$Sampler)
    $pids = @()
    try {
        $pids = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId={0}" -f $PID) -ErrorAction Stop |
            Where-Object { $_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe' } | ForEach-Object { [int]$_.ProcessId })
    } catch { }
    $Sampler.BridgePids = $pids
    $Sampler.Prev = Read-StreamBenchmarkSnapshot -Sampler $Sampler
}


function Get-StreamBenchmarkRate {
    <#
    .SYNOPSIS
    Least-squares slope (units per second) of @(@{T;V}) points (T in seconds), $null with fewer
    than 3 distinct T. Used for the delivered FPS: ffmpeg rewrites its -progress file only once
    a second, so frame delta / wall time over a 10 s window was off by up to 10% (49/45 fps).
    A slope over every reading of the window averages that staleness out.
    #>
    param([object[]]$Points)
    $pts = @($Points | Where-Object { $null -ne $_.V })
    if (@($pts | ForEach-Object { $_.T } | Select-Object -Unique).Count -lt 3) { return $null }
    $n = $pts.Count; $mt = 0.0; $mv = 0.0
    foreach ($p in $pts) { $mt += $p.T; $mv += $p.V }
    $mt /= $n; $mv /= $n
    $num = 0.0; $den = 0.0
    foreach ($p in $pts) { $num += ($p.T - $mt) * ($p.V - $mv); $den += ($p.T - $mt) * ($p.T - $mt) }
    if ($den -le 0) { return $null }
    return ($num / $den)
}


function Measure-StreamBenchmarkSample {
    <#
    .SYNOPSIS
    One load sample over the interval since the previous one (~10-300 ms of work): whole-PC
    CPU, every GPU (busiest engine = utilization, 3D, video, encode, VRAM - the same engine
    rules as Get-GpuInfo), memory and the scrcpy / ffmpeg / mediamtx processes. Returns the
    shape Get-StreamBenchmarkAggregate expects. -Sampler comes from New-StreamBenchmarkSampler.
    #>
    param([Parameter(Mandatory = $true)]$Sampler)
    $prev = $Sampler.Prev
    $now = Read-StreamBenchmarkSnapshot -Sampler $Sampler
    $Sampler.Prev = $now
    $span = ($now.Time - $prev.Time).TotalSeconds
    if ($span -le 0) { $span = 0.001 }

    # GPU engines, bucketed [luid][engine type] = summed % over the interval (same helpers
    # and vendor rules as Get-GpuInfo, utils.ps1).
    $map = Get-GpuEngineDeltaMap -Previous $prev.Util -Current $now.Util
    $clip = { param($x) [Math]::Round([Math]::Min(100.0, [Math]::Max(0.0, $x)), 1) }
    $gpus = foreach ($g in $Sampler.Gpus) {
        $eng = $null; $memB = $null
        if ($Sampler.Single) {
            # One physical GPU: sum every LUID except the software renderer (RDP LUID mismatch, see Merge-GpuEngineMap).
            $eng = Merge-GpuEngineMap -EngineMap $map -ExcludeLuid $Sampler.ExcludeLuid
            $memB = 0.0; foreach ($k in $now.Mem.Keys) { if ($k -ne $Sampler.ExcludeLuid) { $memB += $now.Mem[$k] } }
        } elseif ($g.Luid) {
            $eng = $map[$g.Luid]
            if ($now.Mem.ContainsKey($g.Luid)) { $memB = $now.Mem[$g.Luid] }
        }
        $st = Get-GpuEngineStats $eng
        [PSCustomObject]@{
            Index = $g.Index; Model = $g.Model
            UtilizationPercent = & $clip $st.Utilization; Load3DPercent = & $clip $st.Load3D
            VideoPercent = & $clip $st.Video; EncodePercent = & $clip $st.Encode
            VramUsedGB = if ($null -ne $memB) { [Math]::Round($memB / 1GB, 2) } else { $null }
        }
    }

    $work = foreach ($n in $script:BenchProcNames + @('bridge')) {
        $d = [Math]::Max(0.0, $now.Proc[$n].Cpu - $prev.Proc[$n].Cpu)
        [PSCustomObject]@{ ProcessName = $n; TotalCpuPct = [Math]::Round($d / $span / $Sampler.Cores * 100, 1); TotalMemoryMB = $now.Proc[$n].MemMB }
    }
    $ram = $null; try { $ram = Get-RamInfo } catch { }
    return @{
        Cpu  = (Get-StreamBenchmarkCpuPercent -From $prev.Cpu -To $now.Cpu)
        Gpus = @($gpus)
        Ram  = $ram
        Work = @($work)
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
    foreach ($n in $script:BenchProcNames + @('bridge')) {
        $rows = @($Samples | ForEach-Object { $_.Work } | Where-Object { $_.ProcessName -eq $n })
        $proc[$n] = [ordered]@{
            CpuAvg = & $avg  ($rows | ForEach-Object { $_.TotalCpuPct })
            MemMB  = & $peak ($rows | ForEach-Object { $_.TotalMemoryMB })
        }
    }
    # Stream CPU = every process of the capture chain (adb transfer, scrcpy, pipe bridge,
    # ffmpeg, mediamtx). A far cleaner per-stream signal than whole-PC CPU minus baseline, whose
    # +/-3 point background noise drowned a GPU-encoded stream's 2-6 points.
    $streamVals = @($Samples | ForEach-Object { $s = 0.0; foreach ($w in @($_.Work)) { if ($null -ne $w.TotalCpuPct) { $s += [double]$w.TotalCpuPct } }; $s })

    return [ordered]@{
        Samples    = @($Samples).Count
        CpuAvg     = $cpuAvg
        CpuPeak    = & $peak $cpuVals
        StreamCpuAvg  = & $avg $streamVals
        StreamCpuPeak = & $peak $streamVals
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
        # NullString, not $null: PowerShell passes $null to a [string] parameter as '', which
        # File.Replace rejects as an invalid path - every progress write after the first failed.
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [System.IO.File]::Move($tmp, $Path) }
    } catch { }
}


function Invoke-StreamBenchmark {
    <#
    .SYNOPSIS
    Runs a benchmark plan (New-StreamBenchmarkPlan(...).Tests) on one headset, merges the
    results into the stored results of that headset model (Save-StreamBenchmarkResult) and
    returns this run: @{Ok;Status;Error;RunId;Timestamp;Host;Headset;MeasureSec;Gpus;Results}.
    .DESCRIPTION
    Raises the pause flag, waits for VRMonitor to stop every stream, pre-warms one encoder per
    GPU/CPU + codec pair, then for each test: applies the in-memory overrides (re-encode,
    codec, GPU on/off + index, re-encode framerate = capture FPS, re-encode bitrate, max
    capture size), starts the stream (recording off), warms up, samples for -MeasureSec, reads
    the ffmpeg -progress file and stops the stream. Every global is restored in finally and
    the flag is cleared, after which the watchdog restarts the normal streams.
    -Tests may be hashtables or PSCustomObjects (the web job passes them as JSON).
    -OnProgress (scriptblock, gets the state) is for the console.
    .EXAMPLE
    $plan = New-StreamBenchmarkPlan -Headset $h -Selection @{ Fps = 30, 60 }
    Invoke-StreamBenchmark -Headset $h -Tests $plan.Tests -MeasureSec 10
    #>
    param(
        [Parameter(Mandatory = $true)]$Headset,
        [Parameter(Mandatory = $true)][object[]]$Tests,
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
    $model = [string]$Headset.Model

    # Unroll one level: a caller that wrapped a parsed JSON array passes ONE element holding the
    # whole list (PS 5.1 ConvertFrom-Json trap).
    $Tests = @($Tests | ForEach-Object { $_ })
    # The start baseline first, then the plan order (a closing 'baseline_end' stays last);
    # never more than the limit.
    $tests = @(@($Tests | Where-Object { $_.Id -eq 'baseline' } | Select-Object -First 1) + @($Tests | Where-Object { $_.Id -ne 'baseline' }))
    $tests = @($tests | Where-Object { $null -ne $_ } | Select-Object -First $script:BenchMaxTests)

    $startedAt = Get-Date
    $runningStreams = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue).Count
    $estTests = @($tests | ForEach-Object { Get-StreamBenchmarkTestEstimate -Test $_ -MeasureSec $MeasureSec })
    $estFixed = Get-StreamBenchmarkFixedEstimate -Tests $tests -RunningStreams $runningStreams
    $estTotal = [int](($estTests | Measure-Object -Sum).Sum + $estFixed)

    $state = [ordered]@{
        status = 'running'; runId = $runId; phase = 'starting'
        headset = @{ id = $Headset.ID; name = $Headset.Name; model = $model }
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
            if ($k -eq $state.index - 1) { $e = [Math]::Max(0.0, $e - $SpentInTest) }
            $rem += $e
        }
        if ($state.index -eq 0) { $rem += [Math]::Max(0.0, $estFixed - $t.RestoreSec) }
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
        mediamtxBitrate   = $global:mediamtxBitrate
        mediamtxFramerate = $global:mediamtxFramerate
        GPU_Acceleration  = $global:GPU_Acceleration
        GPU_Index         = $global:GPU_Index
        GpuEncoder        = $global:GpuEncoder
    }
    $status = 'done'; $err = ''
    Write-Log ("Benchmark {0}: {1} test(s) on {2}, measure {3} s, estimated {4} s" -f $runId, $tests.Count, $Headset.Name, $MeasureSec, $estTotal) -Level INFO

    try {
        if ($tests.Count -eq 0) { throw 'No test selected.' }
        if (-not $global:mediamtxEnabled -and @($tests | Where-Object { $_.Encoding -ne 'none' }).Count -gt 0) { throw 'mediamtx is disabled: streaming tests need it.' }
        [void](Initialize-StreamBenchmarkCpuType)

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
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }).Count -gt 0) {
            Start-Sleep -Milliseconds 500
        }

        $global:CaptureMode = 'StreamOnly'
        if (@($tests | Where-Object { $_.Encoding -ne 'none' }).Count -gt 0) { try { Start-MediaMtx } catch { } }

        # Pre-warm one encoder per GPU/CPU + codec pair: the probe takes seconds and must not be
        # measured, and Get-GpuEncoder caches only ONE result.
        $encKeyOf = { param($x) if ($x.Encoding -eq 'gpu') { 'gpu|{0}|{1}' -f $x.GpuIndex, $x.Codec } else { 'cpu||{0}' -f $x.Codec } }
        $encCache = @{}
        $encKeys = @($tests | Where-Object { $_.Encoding -in @('gpu', 'cpu') } | ForEach-Object { & $encKeyOf $_ } | Select-Object -Unique)
        if ($encKeys.Count -gt 0) {
            & $publish 'checking which hardware encoders work (not measured)' (@($encKeys | Where-Object { $_ -like 'gpu|*' }).Count * $t.EncoderProbeSec)
            foreach ($k in $encKeys) {
                $parts = $k -split '\|'
                $global:mediamtxCodec = $parts[2]
                $global:GPU_Acceleration = ($parts[0] -eq 'gpu')
                if ($parts[0] -eq 'gpu') { $global:GPU_Index = [int]$parts[1] }
                $global:GpuEncoder = $null
                $encCache[$k] = Get-GpuEncoder
                Write-Log ("Benchmark: encoder for {0} is {1}" -f $k, $encCache[$k].Name) -Level INFO
            }
        }
        # The load sampler pays its slow first counter read here, not inside a measure.
        & $publish 'preparing the load sampler' $t.SamplerWarmSec
        $sampler = New-StreamBenchmarkSampler

        for ($i = 0; $i -lt $tests.Count; $i++) {
            if (& $cancelled) { $status = 'cancelled'; break }
            $test = $tests[$i]
            $state.index = $i + 1
            $state.current = [string]$test.Label
            $testStart = Get-Date
            Set-StreamBenchmarkActive -RunId $runId -Seconds ($estTests[$i] * 3 + 60)

            $res = [ordered]@{
                Id = [string]$test.Id; Label = [string]$test.Label; Eye = [string]$test.Eye; View = [string]$test.View
                Fps = [int]$test.Fps; Mbps = [int]$test.Mbps; Encoding = [string]$test.Encoding
                GpuIndex = [int]$test.GpuIndex; GpuName = [string]$test.GpuName; Codec = [string]$test.Codec
                ReencodeMbps = [int]$test.ReencodeMbps; MaxSize = [int]$test.MaxSize; Role = [string]$test.Role
                Encoder = ''; Status = 'ok'; Message = ''; ElapsedSec = 0; Load = $null
                Timestamp = (Get-Date).ToString('s'); MeasureSec = $MeasureSec
                Stream = [ordered]@{ TargetFps = [int]$test.Fps; Fps = $null; Frames = $null; Drop = $null; Dup = $null; Speed = $null }
            }
            $pipe = $null

            if (-not $test.Available) {
                $res.Status = 'skipped'; $res.Message = [string]$test.Reason
                $results.Add($res); continue
            }

            if ($test.Encoding -eq 'none') {
                & $publish 'settling' $t.SettleSec
                Start-Sleep -Seconds $t.SettleSec
            } else {
                # ---- In-memory overrides of this test ----
                $encKey = & $encKeyOf $test
                $isGpu = ($test.Encoding -eq 'gpu')
                $global:mediamtxReencode  = $true
                $global:mediamtxCodec     = [string]$test.Codec
                $global:GPU_Acceleration  = $isGpu
                if ($isGpu) { $global:GPU_Index = [int]$test.GpuIndex }
                $global:mediamtxFramerate = [int]$test.Fps
                $global:mediamtxBitrate   = ('{0}M' -f [int]$test.ReencodeMbps)
                $global:GpuEncoder        = $encCache[$encKey]
                if ($isGpu -and $encCache[$encKey] -and $encCache[$encKey].Vendor -eq 'CPU') {
                    $res.Status = 'skipped'; $res.Message = ('No working {0} encoder on GPU {1}.' -f $test.Codec, $test.GpuIndex)
                    $results.Add($res); continue
                }
                $res.Encoder = [string]$encCache[$encKey].Name
                $scrcpyProfile = ConvertTo-ScrcpyProfile -View ([string]$test.View) -Eye ([string]$test.Eye) -AudioDup $false -Fps ([int]$test.Fps) -BitrateMbps ([int]$test.Mbps)

                # Start + warm-up, retried ONCE: back-to-back restarts sometimes hand ffmpeg a pipe
                # whose first bytes are not a Matroska header ("EBML header parsing failed") and it
                # exits at once - a pipeline start race, not a load limit of the tested settings.
                $attempt = 0; $up = $false; $stopRun = $false
                while ($true) {
                    $attempt++
                    & $publish 'starting stream' ([int]$test.OverheadSec) ((Get-Date) - $testStart).TotalSeconds
                    if (Test-Path -LiteralPath $ffProgress) { Remove-Item -LiteralPath $ffProgress -Force -ErrorAction SilentlyContinue }

                    # Max capture size: a clone of the model template with max_size replaced, in place
                    # only while start-screenCopy builds the arguments. The eye merge refresh runs first
                    # so it cannot reload the parameters from config.json in the middle of the launch.
                    $origTpl = $null
                    if ([int]$test.MaxSize -ge 0) {
                        if (Get-Command Update-EyeMergeParameters -ErrorAction SilentlyContinue) { try { Update-EyeMergeParameters } catch { } }
                        $origTpl = Get-StreamBenchmarkModelTemplate -Model $model
                        if ($origTpl) {
                            $clone = $origTpl | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                            if ($clone.PSObject.Properties['max_size']) { $clone.max_size = [int]$test.MaxSize }
                            else { $clone | Add-Member -NotePropertyName 'max_size' -NotePropertyValue ([int]$test.MaxSize) }
                            Set-StreamBenchmarkModelTemplate -Model $model -Template $clone
                        }
                    }
                    try {
                        start-screenCopy -headsetIP ([string]$Headset.IPAddress) -displayName ([string]$Headset.Name) -recording $false `
                            -scrcpyProfile $scrcpyProfile -ffmpegProgressFile $ffProgress
                    } finally {
                        if ($origTpl) { Set-StreamBenchmarkModelTemplate -Model $model -Template $origTpl }
                    }

                    $pipe = $global:HeadsetPipelines[$safeName]
                    $up = [bool]($pipe -and $pipe.FfmpegProcess -and -not $pipe.FfmpegProcess.HasExited)
                    if ($up) {
                        Set-StreamBenchmarkBridgePids -Sampler $sampler
                        & $publish 'warm-up' $t.WarmupSec ((Get-Date) - $testStart).TotalSeconds
                        $warmEnd = (Get-Date).AddSeconds($t.WarmupSec)
                        while ((Get-Date) -lt $warmEnd -and -not (& $cancelled) -and -not $pipe.FfmpegProcess.HasExited) { Start-Sleep -Milliseconds 500 }
                        if (& $cancelled) { $stopRun = $true; break }
                        $up = -not $pipe.FfmpegProcess.HasExited
                    }
                    if ($up) { break }
                    try { Stop-Scrcpy -HeadsetName ([string]$Headset.Name) | Out-Null } catch { }
                    if ($attempt -ge 2) { break }
                    Write-Log ("Benchmark: {0} - the stream did not come up, retrying once." -f $test.Label) -Level WARNING
                    Start-Sleep -Seconds $t.SettleSec
                }
                if ($stopRun) {
                    try { Stop-Scrcpy -HeadsetName ([string]$Headset.Name) | Out-Null } catch { }
                    $status = 'cancelled'; break
                }
                if (-not $up) {
                    $res.Status = 'failed'; $res.Message = 'The stream did not start, twice (see the scrcpy / ffmpeg logs).'
                    $res.ElapsedSec = [int]((Get-Date) - $testStart).TotalSeconds
                    $doneEst += $estTests[$i]; $doneActual += $res.ElapsedSec
                    $results.Add($res); continue
                }
                if ($attempt -gt 1) { $res.Message = 'Started on the second attempt.' }
                if ($test.Eye -eq 'M' -and -not $pipe.EyeMergeKey) {
                    $res.Status = 'fallback'; $res.Message = 'Merged view not used - a single eye was streamed (see the eye merge warning in the log).'
                }
                # The size override is keyed on the registry model; check scrcpy really got it.
                if ([int]$test.MaxSize -ge 0 -and $pipe.ScrcpyProcess) {
                    $cl = ''
                    try { $cl = [string](Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pipe.ScrcpyProcess.Id) -ErrorAction Stop).CommandLine } catch { }
                    if ($cl) {
                        $hasSize = $cl -match '--max-size=(\d+)'
                        $got = if ($hasSize) { [int]$Matches[1] } else { 0 }
                        if ($got -ne [int]$test.MaxSize) { $res.Message = ('Max capture size {0} not applied (scrcpy got {1}).' -f $test.MaxSize, $got) }
                    }
                }
            }

            # ---- Measure ----
            & $publish 'measuring' $MeasureSec ((Get-Date) - $testStart).TotalSeconds
            $p0 = Read-FfmpegProgressFile -Path $ffProgress
            $c0 = $null; if ('VrhmCpuTimes' -as [type]) { $c0 = [VrhmCpuTimes]::Read() }
            $m0 = Get-Date
            $samples = [System.Collections.Generic.List[object]]::new()
            $measureEnd = $m0.AddSeconds($MeasureSec)
            [void](Measure-StreamBenchmarkSample -Sampler $sampler)   # resets the interval to the measure start
            # Delivered frames per reading: output frames minus duplicated plus dropped ones = what
            # actually arrived from the headset. Fitted as a slope over the whole window.
            $fpsPts = [System.Collections.Generic.List[object]]::new()
            $outPts = [System.Collections.Generic.List[object]]::new()
            $readProg = {
                $pp = Read-FfmpegProgressFile -Path $ffProgress
                if ($null -ne $pp.Frame) {
                    $tt = ((Get-Date) - $m0).TotalSeconds
                    $dd = if ($null -ne $pp.Dup) { $pp.Dup } else { 0 }; $dr = if ($null -ne $pp.Drop) { $pp.Drop } else { 0 }
                    $fpsPts.Add(@{ T = $tt; V = $pp.Frame - $dd + $dr }); $outPts.Add(@{ T = $tt; V = $pp.Frame })
                }
            }
            if ($test.Encoding -ne 'none') { & $readProg }
            while ((Get-Date) -lt $measureEnd) {
                # About one sample per second; a sample costs ~0.3 s, so the window is respected.
                $next = (Get-Date).AddSeconds(1)
                while ((Get-Date) -lt $next -and (Get-Date) -lt $measureEnd) { Start-Sleep -Milliseconds 100 }
                $samples.Add((Measure-StreamBenchmarkSample -Sampler $sampler))
                if ($test.Encoding -ne 'none') { & $readProg }
                if (& $cancelled) { break }
                if ($pipe -and $pipe.FfmpegProcess.HasExited) {
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
                    # Slope over every reading; the plain delta / wall time only as a fallback.
                    $slope = Get-StreamBenchmarkRate -Points $fpsPts.ToArray()
                    $res.Stream.Fps = if ($null -ne $slope) { [Math]::Round($slope, 1) } else { [Math]::Round(($p1.Frame - $p0.Frame) / $span, 1) }
                    $oslope = Get-StreamBenchmarkRate -Points $outPts.ToArray()
                    if ($null -ne $oslope) { $res.Stream.OutFps = [Math]::Round($oslope, 1) }
                }
                if ($null -ne $p1.Drop) { $res.Stream.Drop = [int]($p1.Drop - [double]$(if ($null -ne $p0.Drop) { $p0.Drop } else { 0 })) }
                if ($null -ne $p1.Dup)  { $res.Stream.Dup  = [int]($p1.Dup  - [double]$(if ($null -ne $p0.Dup)  { $p0.Dup }  else { 0 })) }
                $res.Stream.Speed = $p1.Speed
                if ($res.Status -eq 'ok' -and $null -eq $res.Stream.Fps -and -not $res.Message) { $res.Message = 'No ffmpeg progress data - stream figures unavailable.' }

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
    $run = [ordered]@{
        Ok         = ($status -eq 'done')
        Status     = $status
        Error      = $err
        RunId      = $runId
        Timestamp  = (Get-Date).ToString('s')
        Host       = $env:COMPUTERNAME
        Headset    = [ordered]@{ ID = $Headset.ID; Name = $Headset.Name; Model = $model }
        MeasureSec = $MeasureSec
        Gpus       = $gpuList
        Results    = $results.ToArray()
    }
    if ($results.Count -gt 0) {
        try { [void](Save-StreamBenchmarkResult -Run $run) } catch { Write-Log ("Benchmark: result not saved: " + $_.Exception.Message) -Level WARNING }
    }

    $state.status = $status; $state.error = $err; $state.index = $results.Count
    & $publish 'done'
    Write-Log ("Benchmark {0} finished: {1}, {2} result(s), {3} s" -f $runId, $status, $results.Count, [int]((Get-Date) - $startedAt).TotalSeconds) -Level $(if ($status -eq 'error') { 'ERROR' } else { 'SUCCESS' })
    return $run
}


function Invoke-StreamBenchmarkParallel {
    <#
    .SYNOPSIS
    Parallel check of the "N headsets cost N x one stream" assumption: streams the SAME settings
    on every given headset at once, measures the PC, and compares with the sum of the model's
    single-stream predictions. Stores @{Ok;Status;Error;Timestamp;Host;MeasureSec;Settings;
    Headsets;Measured;Predicted;Ratio} in app_kv benchmark_parallel_last and returns it.
    .DESCRIPTION
    Same pause / acknowledge / restore protocol and in-memory overrides as Invoke-StreamBenchmark.
    Each headset streams its own view at -Settings' eye, FPS, bitrates, encoder and codec (max size
    applied per model). Ratio = measured cost above the idle PC / predicted cost, per resource:
    1.0 means the linear model holds, above 1 means parallel streams cost more than predicted.
    .EXAMPLE
    Invoke-StreamBenchmarkParallel -Headsets @(Get-HeadsetDiagTarget -Id 3; Get-HeadsetDiagTarget -Id 5) -Settings @{ Encoding='gpu:1'; Codec='h264'; Fps=45; Mbps=10 }
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Headsets,
        $Settings = $null,
        [ValidateSet(10, 20, 40)][int]$MeasureSec = 20,
        [string]$ProgressFile = '',
        [scriptblock]$OnProgress = $null
    )
    $t = $script:BenchTiming
    $runId = [guid]::NewGuid().ToString('N')
    $cancelPath = Get-StreamBenchmarkCancelPath
    if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
    $cancelled = { Test-Path -LiteralPath $cancelPath }
    $get = { param($n) Get-StreamBenchmarkSelectionValue $Settings $n }
    $opt0 = Get-StreamBenchmarkOptions -Headset $Headsets[0]
    $enc = [string](& $get 'Encoding'); if ($enc -notmatch '^(cpu|gpu:\d+)$') { $enc = @($opt0.Defaults.Encodings)[0] }
    $codec = [string](& $get 'Codec'); if ($codec -notin @('h264', 'h265')) { $codec = 'h264' }
    $eye = if ([string](& $get 'Eye') -eq 'M') { 'M' } else { 'R' }
    $fps = if ((& $get 'Fps') -as [int]) { [int](& $get 'Fps') } else { 45 }
    $mb = if ((& $get 'Mbps') -as [int]) { [int](& $get 'Mbps') } else { 10 }
    $re = if ((& $get 'ReencodeMbps') -as [int]) { [int](& $get 'ReencodeMbps') } else { [int]$opt0.ReencodeMbps }
    $size = if ($null -ne (& $get 'MaxSize') -and "$(& $get 'MaxSize')" -ne '') { [int](& $get 'MaxSize') } else { 0 }
    $isGpu = $enc -like 'gpu:*'; $gIdx = if ($isGpu) { [int]$enc.Split(':')[1] } else { -1 }
    $set = @{ Eye = $eye; Encoding = $enc; Codec = $codec; Fps = $fps; Mbps = $mb; ReencodeMbps = $re; MaxSize = $size }

    $startedAt = Get-Date
    $total = $Headsets.Count
    $est = [int]($t.AckTimeoutSec / 4 + $t.EncoderProbeSec + $t.SamplerWarmSec + 2 * $MeasureSec + $total * $t.StartOverheadSec + $t.WarmupSec + $t.StopOverheadSec + $t.RestoreSec)
    $state = [ordered]@{ status = 'running'; runId = $runId; kind = 'parallel'; phase = 'starting'
        headset = @{ id = $Headsets[0].ID; name = ('{0} headset(s)' -f $total); model = $Headsets[0].Model }
        measureSec = $MeasureSec; index = 0; total = $total; current = 'Parallel check'
        startedAt = $startedAt.ToUniversalTime().ToString('o'); elapsedSec = 0; etaSec = $est; estimatedTotalSec = $est
        phaseEndsAt = $null; results = @(); error = ''; updatedAt = 0 }
    $publish = {
        param([string]$Phase, [int]$PhaseSec = 0)
        $state.phase = $Phase
        $state.elapsedSec = [int]((Get-Date) - $startedAt).TotalSeconds
        $state.etaSec = if ($Phase -eq 'done') { 0 } else { [Math]::Max(0.0, $est - $state.elapsedSec) }
        $state.phaseEndsAt = if ($PhaseSec -gt 0) { [long]([DateTimeOffset]::UtcNow.AddSeconds($PhaseSec).ToUnixTimeMilliseconds()) } else { $null }
        Write-StreamBenchmarkProgress -State $state -Path $ProgressFile
        if ($OnProgress) { try { & $OnProgress $state } catch { } }
    }
    $saved = @{ CaptureMode = $global:CaptureMode; mediamtxReencode = $global:mediamtxReencode; mediamtxCodec = $global:mediamtxCodec
                mediamtxBitrate = $global:mediamtxBitrate; mediamtxFramerate = $global:mediamtxFramerate
                GPU_Acceleration = $global:GPU_Acceleration; GPU_Index = $global:GPU_Index; GpuEncoder = $global:GpuEncoder }
    $origTpls = @{}
    $status = 'done'; $err = ''
    $out = [ordered]@{ Ok = $false; Status = ''; Error = ''; RunId = $runId; Timestamp = ''; Host = $env:COMPUTERNAME; MeasureSec = $MeasureSec
                       Settings = $set; Headsets = @(); Measured = $null; Predicted = $null; Ratio = $null; Baseline = $null }
    $live = [System.Collections.Generic.List[object]]::new()
    Write-Log ("Benchmark parallel check {0}: {1} headset(s), {2}" -f $runId, $total, ($set | ConvertTo-Json -Compress)) -Level INFO
    try {
        if ($total -lt 1) { throw 'No headset selected.' }
        if (-not $global:mediamtxEnabled) { throw 'mediamtx is disabled: streaming tests need it.' }
        [void](Initialize-StreamBenchmarkCpuType)
        & $publish 'checking headsets'
        foreach ($h in $Headsets) {
            $dev = $null; try { $dev = Resolve-HeadsetAdbDevice -Headset $h } catch { }
            if (-not $dev) { throw ("Headset {0} does not answer over ADB (USB or WiFi)." -f $h.Name) }
        }
        Set-StreamBenchmarkActive -RunId $runId -Seconds ($est * 2 + 120)
        & $publish 'stopping streams'
        $deadline = (Get-Date).AddSeconds($t.AckTimeoutSec)
        $acked = $false
        while ((Get-Date) -lt $deadline) {
            $ack = $null; try { $ack = Get-DbKeyValue -Key $script:BenchKvAck } catch { }
            if ($ack -and [string]$ack.runId -eq $runId) { $acked = $true; break }
            if (& $cancelled) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $acked -and -not (& $cancelled)) { try { Stop-Scrcpy | Out-Null } catch { } }
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($global:scrcpyFolder)\scrcpy.exe" }).Count -gt 0) { Start-Sleep -Milliseconds 500 }
        if (& $cancelled) { throw 'cancelled' }

        $global:CaptureMode = 'StreamOnly'
        try { Start-MediaMtx } catch { }
        & $publish 'pre-warming encoder' $t.EncoderProbeSec
        $global:mediamtxReencode = $true; $global:mediamtxCodec = $codec; $global:GPU_Acceleration = $isGpu
        if ($isGpu) { $global:GPU_Index = $gIdx }
        $global:mediamtxFramerate = $fps; $global:mediamtxBitrate = ('{0}M' -f $re)
        $global:GpuEncoder = $null
        $encoder = Get-GpuEncoder
        if ($isGpu -and $encoder.Vendor -eq 'CPU') { throw ('No working {0} encoder on GPU {1}.' -f $codec, $gIdx) }
        & $publish 'preparing the load sampler' $t.SamplerWarmSec
        $sampler = New-StreamBenchmarkSampler

        # ---- Baseline (idle, same moment) ----
        & $publish 'measuring the idle PC' $MeasureSec
        $measure = {
            param([int]$sec)
            $c0 = $null; if ('VrhmCpuTimes' -as [type]) { $c0 = [VrhmCpuTimes]::Read() }
            [void](Measure-StreamBenchmarkSample -Sampler $sampler)
            $smp = [System.Collections.Generic.List[object]]::new()
            $end = (Get-Date).AddSeconds($sec)
            while ((Get-Date) -lt $end) {
                $next = (Get-Date).AddSeconds(1)
                while ((Get-Date) -lt $next -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
                $smp.Add((Measure-StreamBenchmarkSample -Sampler $sampler))
                if (& $cancelled) { break }
            }
            $c1 = $null; if ('VrhmCpuTimes' -as [type]) { $c1 = [VrhmCpuTimes]::Read() }
            return (Get-StreamBenchmarkAggregate -Samples $smp.ToArray() -CpuWindowAvg (Get-StreamBenchmarkCpuPercent -From $c0 -To $c1))
        }
        $baseLoad = & $measure $MeasureSec
        if (& $cancelled) { throw 'cancelled' }

        # ---- Start every stream ----
        $i = 0
        foreach ($h in $Headsets) {
            $i++; $state.index = $i; $state.current = ('Starting {0}' -f $h.Name)
            & $publish 'starting streams' $t.StartOverheadSec
            $model = [string]$h.Model
            $parsed = ConvertFrom-ScrcpyProfile -Profile ([string]$h.ScrcpyProfile)
            $view = if ($parsed) { $parsed.View } else { Get-ScrcpyDefaultView -Model $model }
            $prog = [System.IO.Path]::Combine($env:TEMP, ('vrm_benchmark_par_{0}.txt' -f $h.ID))
            if (Test-Path -LiteralPath $prog) { Remove-Item -LiteralPath $prog -Force -ErrorAction SilentlyContinue }
            if ($eye -ne 'M') {
                if (Get-Command Update-EyeMergeParameters -ErrorAction SilentlyContinue) { try { Update-EyeMergeParameters } catch { } }
                $tpl = Get-StreamBenchmarkModelTemplate -Model $model
                if ($tpl) {
                    if (-not $origTpls.ContainsKey($model)) { $origTpls[$model] = $tpl }
                    $clone = $origTpls[$model] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                    if ($clone.PSObject.Properties['max_size']) { $clone.max_size = $size } else { $clone | Add-Member -NotePropertyName 'max_size' -NotePropertyValue $size }
                    Set-StreamBenchmarkModelTemplate -Model $model -Template $clone
                }
            }
            try {
                start-screenCopy -headsetIP ([string]$h.IPAddress) -displayName ([string]$h.Name) -recording $false `
                    -scrcpyProfile (ConvertTo-ScrcpyProfile -View $view -Eye $eye -AudioDup $false -Fps $fps -BitrateMbps $mb) -ffmpegProgressFile $prog
            } finally {
                if ($origTpls.ContainsKey($model)) { Set-StreamBenchmarkModelTemplate -Model $model -Template $origTpls[$model] }
            }
            $pipe = $global:HeadsetPipelines[(Convert-Displayname ([string]$h.Name))]
            $live.Add(@{ Headset = $h; View = $view; Model = $model; Progress = $prog; Pipe = $pipe
                         Started = [bool]($pipe -and $pipe.FfmpegProcess -and -not $pipe.FfmpegProcess.HasExited) })
            if (& $cancelled) { throw 'cancelled' }
        }
        if (-not ($live | Where-Object { $_.Started })) { throw 'No stream started (see the scrcpy / ffmpeg logs).' }
        Set-StreamBenchmarkBridgePids -Sampler $sampler
        $state.current = ('{0} streams' -f @($live | Where-Object { $_.Started }).Count)
        & $publish 'warm-up' $t.WarmupSec
        Start-Sleep -Seconds $t.WarmupSec

        # ---- Measure all streams together ----
        & $publish 'measuring' $MeasureSec
        $p0 = @{}; foreach ($l in $live) { $p0[$l.Headset.ID] = Read-FfmpegProgressFile -Path $l.Progress }
        $m0 = Get-Date
        $load = & $measure $MeasureSec
        $span = ((Get-Date) - $m0).TotalSeconds
        foreach ($l in $live) {
            $p1 = Read-FfmpegProgressFile -Path $l.Progress; $a = $p0[$l.Headset.ID]
            $f = $null
            if ($null -ne $p1.Frame -and $null -ne $a.Frame -and $span -gt 0) { $f = [Math]::Round(($p1.Frame - $a.Frame) / $span, 1) }
            $out.Headsets += @{ ID = $l.Headset.ID; Name = [string]$l.Headset.Name; Model = $l.Model; View = $l.View; Started = $l.Started; Fps = $f; TargetFps = $fps }
        }
        & $publish 'stopping streams' ($t.StopOverheadSec * $total)
        foreach ($l in $live) { try { Stop-Scrcpy -HeadsetName ([string]$l.Headset.Name) | Out-Null } catch { } }

        # ---- Measured vs predicted (sum of single-stream model predictions) ----
        $baseRow = @{ Id = 'baseline'; Load = $baseLoad }
        $mRow = @{ Load = $load; Stream = @{ Fps = $null; TargetFps = 0 } }
        $meas = Get-StreamBenchmarkLoadVector -Row $mRow -Base $baseRow
        $pred = @{ Cpu = 0.0; Gpu = @{}; Ram = 0.0 }; $predOk = $true; $predNote = @()
        $fits = @{}
        foreach ($l in @($live | Where-Object { $_.Started })) {
            if (-not $fits.ContainsKey($l.Model)) { $fits[$l.Model] = Get-StreamBenchmarkModel -Result (Get-StreamBenchmarkResult -Model $l.Model) }
            $fm = $fits[$l.Model]
            if (-not $fm -or -not $fm.Ok) { $predOk = $false; $predNote += ('{0}: no benchmark model' -f $l.Model); continue }
            $sv = $set.Clone(); $sv.View = $l.View
            $p = Get-StreamBenchmarkModelPrediction -ModelFit $fm -Settings $sv
            if (-not $p.Ok) { $predOk = $false; $predNote += ('{0}: {1}' -f $l.Headset.Name, $p.Error); continue }
            $pred.Cpu += $p.Vec.Cpu; $pred.Ram += $p.Vec.Ram
            foreach ($k in $p.Vec.Gpu.Keys) { if (-not $pred.Gpu.ContainsKey($k)) { $pred.Gpu[$k] = 0.0 }; $pred.Gpu[$k] += $p.Vec.Gpu[$k] }
        }
        $ratio = @{ Cpu = $null; Gpu = @{} }
        if ($pred.Cpu -ge 2) { $ratio.Cpu = [Math]::Round($meas.Cpu / $pred.Cpu, 2) }
        foreach ($k in $pred.Gpu.Keys) { if ($pred.Gpu[$k] -ge 2 -and $meas.Gpu.ContainsKey($k)) { $ratio.Gpu[[string]$k] = [Math]::Round($meas.Gpu[$k] / $pred.Gpu[$k], 2) } }
        $gpuOut = { param($v) @($v.Keys | Sort-Object | ForEach-Object { @{ Index = [int]$_; Pct = [Math]::Round([double]$v[$_], 1) } }) }
        $out.Baseline = @{ Cpu = $baseLoad.CpuAvg; StreamCpu = $baseLoad.StreamCpuAvg; RamGB = $baseLoad.RamUsedGB; Gpus = @($baseLoad.Gpus | ForEach-Object { @{ Index = $_.Index; Pct = $_.UtilAvg } }) }
        $out.Measured = @{ Cpu = [Math]::Round($meas.Cpu, 1); Gpus = (& $gpuOut $meas.Gpu); RamGB = [Math]::Round($meas.Ram, 2); WholeCpu = $load.CpuAvg; Load = $load }
        $out.Predicted = @{ Ok = $predOk; Note = ($predNote -join '; '); Cpu = [Math]::Round($pred.Cpu, 1); Gpus = (& $gpuOut $pred.Gpu); RamGB = [Math]::Round($pred.Ram, 2) }
        $out.Ratio = $ratio
    } catch {
        if ($_.Exception.Message -eq 'cancelled') { $status = 'cancelled' } else { $status = 'error'; $err = $_.Exception.Message }
        Write-Log ("Benchmark parallel check {0}: {1} {2}" -f $runId, $status, $err) -Level $(if ($status -eq 'error') { 'ERROR' } else { 'INFO' })
    } finally {
        foreach ($l in $live) { try { Stop-Scrcpy -HeadsetName ([string]$l.Headset.Name) | Out-Null } catch { } ; if (Test-Path -LiteralPath $l.Progress) { Remove-Item -LiteralPath $l.Progress -Force -ErrorAction SilentlyContinue } }
        foreach ($k in $saved.Keys) { Set-Variable -Name $k -Scope Global -Value $saved[$k] }
        foreach ($m in $origTpls.Keys) { Set-StreamBenchmarkModelTemplate -Model $m -Template $origTpls[$m] }
        Clear-StreamBenchmarkActive
        if (Test-Path -LiteralPath $cancelPath) { Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue }
    }
    $out.Ok = ($status -eq 'done'); $out.Status = $status; $out.Error = $err; $out.Timestamp = (Get-Date).ToString('s')
    if ($status -eq 'done') { try { Set-DbKeyValue -Key $script:BenchKvParallel -Value $out } catch { } }
    $state.status = $status; $state.error = $err; $state.index = $total
    & $publish 'done'
    Write-Log ("Benchmark parallel check {0} finished: {1}" -f $runId, $status) -Level $(if ($status -eq 'error') { 'ERROR' } else { 'SUCCESS' })
    return $out
}


function Get-StreamBenchmarkParallelResult {
    <# The last parallel check (Invoke-StreamBenchmarkParallel), or $null. #>
    param()
    try { return (Get-DbKeyValue -Key $script:BenchKvParallel) } catch { return $null }
}


# ---------------------------------------------------------------------------
# Stored results (accumulated per headset model, ADR-0027)
# ---------------------------------------------------------------------------

function Get-StreamBenchmarkResultKey {
    <# app_kv key of the stored results of one headset model. #>
    param([Parameter(Mandatory = $true)][string]$Model)
    $safe = ($Model.ToLower() -replace '[^a-z0-9]+', '_').Trim('_')
    if (-not $safe) { $safe = 'unknown' }
    return ($script:BenchKvResultPrefix + $safe)
}


function Save-StreamBenchmarkResult {
    <#
    .SYNOPSIS
    Merges one run into the stored results of its headset model: a test with the same id is
    replaced, a new one is added, the baseline is refreshed. A run from another PC (Host)
    replaces everything, since loads from two PCs cannot be compared. Returns the merged result.
    #>
    param([Parameter(Mandatory = $true)]$Run)
    $model = [string]$Run.Headset.Model
    $key = Get-StreamBenchmarkResultKey -Model $model
    $old = $null
    try { $old = Get-DbKeyValue -Key $key } catch { }
    $byId = [ordered]@{}
    if ($old -and [string]$old.Host -eq [string]$Run.Host) {
        foreach ($r in @($old.Results)) { if ($r -and $r.Id) { $byId[[string]$r.Id] = $r } }
    }
    foreach ($r in @($Run.Results)) {
        # A cancelled or failed re-run must not erase a good earlier measure of the same test.
        if ($r.Status -in @('ok', 'fallback') -or -not $byId.Contains([string]$r.Id)) { $byId[[string]$r.Id] = $r }
    }
    $gpus = @($Run.Gpus)
    if ($gpus.Count -eq 0 -and $old) { $gpus = @($old.Gpus) }
    $merged = [ordered]@{
        Model      = $model
        Host       = $Run.Host
        Headset    = $Run.Headset
        Timestamp  = $Run.Timestamp
        MeasureSec = $Run.MeasureSec
        LastRunId  = $Run.RunId
        LastStatus = $Run.Status
        Gpus       = $gpus
        Results    = @($byId.Values)
    }
    Set-DbKeyValue -Key $key -Value $merged
    Set-DbKeyValue -Key $script:BenchKvLastModel -Value ('"' + ($model -replace '"', '') + '"')
    return $merged
}


function Get-StreamBenchmarkResult {
    <#
    .SYNOPSIS
    The stored (accumulated) results of one headset model, or of the model benchmarked last
    when -Model is omitted. $null when none.
    .EXAMPLE
    Get-StreamBenchmarkResult -Model 'Quest 3'
    #>
    param([string]$Model = '')
    try {
        if (-not $Model) { $Model = [string](Get-DbKeyValue -Key $script:BenchKvLastModel) }
        if (-not $Model) { return $null }
        return (Get-DbKeyValue -Key (Get-StreamBenchmarkResultKey -Model $Model))
    } catch { return $null }
}


function Clear-StreamBenchmarkResult {
    <# Forgets the stored results of one headset model. #>
    param([Parameter(Mandatory = $true)][string]$Model)
    try { Remove-DbKeyValue -Key (Get-StreamBenchmarkResultKey -Model $Model); return $true } catch { return $false }
}


function ConvertTo-StreamBenchmarkCsv {
    <#
    .SYNOPSIS
    CSV text of a benchmark result: one line per test and per GPU (the test columns repeat).
    .EXAMPLE
    ConvertTo-StreamBenchmarkCsv -Result (Get-StreamBenchmarkResult -Model 'Quest 3')
    #>
    param([Parameter(Mandatory = $true)]$Result)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fmt = { param($v) if ($null -eq $v) { '' } else { [string]::Format($inv, '{0}', $v) } }
    $q = { param($s) '"' + ([string]$s -replace '"', '""') + '"' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Host,Model,Headset,Timestamp,MeasureSec,Test,Eye,View,Fps,CaptureMbps,Encoding,EncGpuIndex,Codec,ReencodeMbps,MaxSize,Encoder,Status,Message,CpuAvg,CpuPeak,RamUsedGB,RamPeakGB,GpuIndex,GpuModel,GpuUtilAvg,GpuUtilPeak,Gpu3DAvg,GpuVideoAvg,GpuEncodeAvg,GpuVramGB,ScrcpyCpu,ScrcpyMB,FfmpegCpu,FfmpegMB,MediamtxCpu,MediamtxMB,StreamFps,TargetFps,Frames,Drop,Dup,Speed,ElapsedSec,Role,StreamCpuAvg,StreamCpuPeak,AdbCpu,BridgeCpu,OutFps')
    foreach ($r in @($Result.Results)) {
        $l = $r.Load
        $gpus = if ($l -and $l.Gpus -and @($l.Gpus).Count -gt 0) { @($l.Gpus) } else { @($null) }
        $ts = if ($r.Timestamp) { $r.Timestamp } else { $Result.Timestamp }
        $ms = if ($r.MeasureSec) { $r.MeasureSec } else { $Result.MeasureSec }
        foreach ($g in $gpus) {
            $cells = @(
                (& $q $Result.Host), (& $q $Result.Model), (& $q $Result.Headset.Name), (& $q $ts), (& $fmt $ms),
                (& $q $r.Label), (& $q $r.Eye), (& $q $r.View), (& $fmt $r.Fps), (& $fmt $r.Mbps), (& $q $r.Encoding), (& $fmt $r.GpuIndex),
                (& $q $r.Codec), (& $fmt $r.ReencodeMbps), (& $fmt $r.MaxSize), (& $q $r.Encoder), (& $q $r.Status), (& $q $r.Message),
                (& $fmt $l.CpuAvg), (& $fmt $l.CpuPeak), (& $fmt $l.RamUsedGB), (& $fmt $l.RamPeakGB),
                (& $fmt $g.Index), (& $q $g.Model), (& $fmt $g.UtilAvg), (& $fmt $g.UtilPeak), (& $fmt $g.D3Avg), (& $fmt $g.VideoAvg), (& $fmt $g.EncodeAvg), (& $fmt $g.VramGB),
                (& $fmt $l.Procs.scrcpy.CpuAvg), (& $fmt $l.Procs.scrcpy.MemMB), (& $fmt $l.Procs.ffmpeg.CpuAvg), (& $fmt $l.Procs.ffmpeg.MemMB), (& $fmt $l.Procs.mediamtx.CpuAvg), (& $fmt $l.Procs.mediamtx.MemMB),
                (& $fmt $r.Stream.Fps), (& $fmt $r.Stream.TargetFps), (& $fmt $r.Stream.Frames), (& $fmt $r.Stream.Drop), (& $fmt $r.Stream.Dup), (& $fmt $r.Stream.Speed), (& $fmt $r.ElapsedSec),
                (& $q $r.Role), (& $fmt $l.StreamCpuAvg), (& $fmt $l.StreamCpuPeak), (& $fmt $l.Procs.adb.CpuAvg), (& $fmt $l.Procs.bridge.CpuAvg), (& $fmt $r.Stream.OutFps)
            )
            $lines.Add(($cells -join ','))
        }
    }
    return ($lines -join "`r`n")
}


# ---------------------------------------------------------------------------
# Recommendations: load for N headsets, proposals, apply
# ---------------------------------------------------------------------------

function Get-StreamBenchmarkBaseline {
    <#
    .SYNOPSIS
    The idle reference of a result (internal): the 'baseline' row, averaged with 'baseline_end'
    when the run measured one too, so a drift of the idle load during a long run is split
    evenly instead of being charged to the last tests. Returns a row-shaped @{Id;Load} or $null.
    #>
    param([object[]]$Rows)
    $b0 = @($Rows) | Where-Object { $_.Id -eq 'baseline' -and $_.Load } | Select-Object -First 1
    $b1 = @($Rows) | Where-Object { $_.Id -eq 'baseline_end' -and $_.Load } | Select-Object -First 1
    if (-not $b0) { return $b1 }
    if (-not $b1) { return $b0 }
    $mean = { param($x, $y) if ($null -eq $x) { $y } elseif ($null -eq $y) { $x } else { ([double]$x + [double]$y) / 2 } }
    $gpus = foreach ($g in @($b0.Load.Gpus)) {
        if (-not $g) { continue }
        $o = @($b1.Load.Gpus) | Where-Object { $_ -and [int]$_.Index -eq [int]$g.Index } | Select-Object -First 1
        @{ Index = [int]$g.Index; Model = $g.Model; UtilAvg = (& $mean $g.UtilAvg $(if ($o) { $o.UtilAvg })) }
    }
    return @{ Id = 'baseline'; Load = @{
        CpuAvg = (& $mean $b0.Load.CpuAvg $b1.Load.CpuAvg)
        StreamCpuAvg = (& $mean $b0.Load.StreamCpuAvg $b1.Load.StreamCpuAvg)
        RamUsedGB = (& $mean $b0.Load.RamUsedGB $b1.Load.RamUsedGB)
        Gpus = @($gpus)
    } }
}


function Get-StreamBenchmarkLoadVector {
    <#
    .SYNOPSIS
    What ONE stream of a measured test costs above the baseline (internal):
    @{Cpu;Gpu=@{index=pct};Ram;FpsRatio}. Negative deltas (noise) are clamped to 0.
    #>
    param($Row, $Base)
    $l = $Row.Load
    if (-not $l) { return $null }
    $bCpu = if ($Base -and $Base.Load) { [double]$Base.Load.CpuAvg } else { 0 }
    $bRam = if ($Base -and $Base.Load -and $null -ne $Base.Load.RamUsedGB) { [double]$Base.Load.RamUsedGB } else { 0 }
    $gpu = @{}
    foreach ($g in @($l.Gpus)) {
        if ($null -eq $g) { continue }
        $b = 0.0
        if ($Base -and $Base.Load) { $bg = @($Base.Load.Gpus) | Where-Object { $_ -and [int]$_.Index -eq [int]$g.Index } | Select-Object -First 1; if ($bg) { $b = [double]$bg.UtilAvg } }
        $gpu[[int]$g.Index] = [Math]::Max(0.0, [double]$g.UtilAvg - $b)
    }
    $ratio = $null
    if ($Row.Stream -and $null -ne $Row.Stream.Fps -and [double]$Row.Stream.TargetFps -gt 0) { $ratio = [double]$Row.Stream.Fps / [double]$Row.Stream.TargetFps }
    # CPU cost of the stream: from the capture-chain processes when both sides measured them
    # (whole-PC CPU carries +/-3 points of background noise); whole-PC delta otherwise (older results).
    $cpu = [Math]::Max(0.0, [double]$l.CpuAvg - $bCpu)
    if ($null -ne $l.StreamCpuAvg -and $Base -and $Base.Load -and $null -ne $Base.Load.StreamCpuAvg) {
        $cpu = [Math]::Max(0.0, [double]$l.StreamCpuAvg - [double]$Base.Load.StreamCpuAvg)
    }
    return @{
        Cpu = $cpu
        Gpu = $gpu
        Ram = if ($null -ne $l.RamUsedGB) { [Math]::Max(0.0, [double]$l.RamUsedGB - $bRam) } else { 0 }
        FpsRatio = $ratio
    }
}


function Merge-StreamBenchmarkLoadVector {
    <# Linear blend of two load vectors: A + (B - A) * W (internal). #>
    param($A, $B, [double]$W)
    # Locals must not be named $a / $b: PowerShell variables are case-insensitive, so they
    # would overwrite the -A / -B parameters.
    $gpu = @{}
    foreach ($k in @($A.Gpu.Keys) + @($B.Gpu.Keys) | Select-Object -Unique) {
        $va = if ($A.Gpu.ContainsKey($k)) { $A.Gpu[$k] } else { 0 }
        $vb = if ($B.Gpu.ContainsKey($k)) { $B.Gpu[$k] } else { 0 }
        $gpu[$k] = $va + ($vb - $va) * $W
    }
    $ratio = if ($null -ne $A.FpsRatio -and $null -ne $B.FpsRatio) { $A.FpsRatio + ($B.FpsRatio - $A.FpsRatio) * $W } elseif ($null -ne $A.FpsRatio) { $A.FpsRatio } else { $B.FpsRatio }
    return @{ Cpu = $A.Cpu + ($B.Cpu - $A.Cpu) * $W; Gpu = $gpu; Ram = $A.Ram + ($B.Ram - $A.Ram) * $W; FpsRatio = $ratio }
}


function Get-StreamBenchmarkInterpolated {
    <#
    .SYNOPSIS
    Load vector at (-Fps, -Mbps) from measured -Points @(@{Fps;Mbps;Vec}) of ONE configuration
    family (internal). Exact point when measured; else linear in FPS within a bitrate, then
    linear in bitrate. Never extrapolates: $null outside the measured range.
    #>
    param([object[]]$Points, [int]$Fps, [int]$Mbps)
    $interp1 = {
        param($pts, [double]$x)   # pts: @(@{X;Vec})
        $exact = $pts | Where-Object { $_.X -eq $x } | Select-Object -First 1
        if ($exact) { return $exact.Vec }
        # Scriptblock sort keys: Sort-Object by NAME does not see hashtable keys in PS 5.1.
        $lo = $pts | Where-Object { $_.X -lt $x } | Sort-Object { $_.X } -Descending | Select-Object -First 1
        $hi = $pts | Where-Object { $_.X -gt $x } | Sort-Object { $_.X } | Select-Object -First 1
        if (-not $lo -or -not $hi) { return $null }
        return (Merge-StreamBenchmarkLoadVector -A $lo.Vec -B $hi.Vec -W (($x - $lo.X) / ($hi.X - $lo.X)))
    }
    $byMbps = @($Points | Group-Object { $_.Mbps })
    $atFps = foreach ($grp in $byMbps) {
        $v = & $interp1 @($grp.Group | ForEach-Object { @{ X = [double]$_.Fps; Vec = $_.Vec } }) $Fps
        if ($v) { @{ X = [double]$grp.Name; Vec = $v } }
    }
    if (-not $atFps) { return $null }
    return (& $interp1 @($atFps) $Mbps)
}


function Get-StreamBenchmarkLoadEstimate {
    <#
    .SYNOPSIS
    Predicted PC load for -Headsets parallel streams of one load vector (internal):
    baseline + N x delta x (1 + margin), per resource, plus the largest N that stays under
    -MaxCpu / -MaxGpu on every resource.
    #>
    param($Vec, $Base, [object[]]$Gpus, [int]$Headsets, [double]$MaxCpu, [double]$MaxGpu, [double]$Margin)
    $k = 1.0 + $Margin
    $bCpu = if ($Base -and $Base.Load) { [double]$Base.Load.CpuAvg } else { 0 }
    $bRam = if ($Base -and $Base.Load -and $null -ne $Base.Load.RamUsedGB) { [double]$Base.Load.RamUsedGB } else { 0 }
    $maxN = 99
    $limitN = {
        param([double]$b, [double]$d, [double]$lim)
        if ($b -ge $lim) { return 0 }
        if ($d -le 0) { return 99 }
        return [int][Math]::Floor(($lim - $b) / ($d * $k))
    }
    $maxN = [Math]::Min($maxN, (& $limitN $bCpu $Vec.Cpu $MaxCpu))
    $gpuOut = foreach ($g in @($Gpus)) {
        $idx = [int]$g.Index
        $b = 0.0
        if ($Base -and $Base.Load) { $bg = @($Base.Load.Gpus) | Where-Object { $_ -and [int]$_.Index -eq $idx } | Select-Object -First 1; if ($bg) { $b = [double]$bg.UtilAvg } }
        $d = if ($Vec.Gpu.ContainsKey($idx)) { [double]$Vec.Gpu[$idx] } else { 0 }
        $maxN = [Math]::Min($maxN, (& $limitN $b $d $MaxGpu))
        $pct = [Math]::Round($b + $Headsets * $d * $k, 1)
        @{ Index = $idx; Model = [string]$g.Model; Pct = $pct; PerStream = [Math]::Round($d, 1); Fits = ($pct -le $MaxGpu) }
    }
    $cpu = [Math]::Round($bCpu + $Headsets * $Vec.Cpu * $k, 1)
    $fpsOk = ($null -eq $Vec.FpsRatio -or $Vec.FpsRatio -ge 0.9)
    return @{
        Cpu = $cpu; CpuPerStream = [Math]::Round($Vec.Cpu, 1); CpuFits = ($cpu -le $MaxCpu)
        Gpus = @($gpuOut)
        RamGB = [Math]::Round($bRam + $Headsets * $Vec.Ram * $k, 2)
        FpsRatio = if ($null -ne $Vec.FpsRatio) { [Math]::Round($Vec.FpsRatio, 2) } else { $null }
        FpsOk = $fpsOk
        MaxHeadsets = $maxN
        Fits = ($cpu -le $MaxCpu) -and -not (@($gpuOut) | Where-Object { -not $_.Fits }) -and $fpsOk
    }
}


function Get-StreamBenchmarkLinearFit {
    <#
    .SYNOPSIS
    Least squares y = A + B x over paired -X / -Y (internal): @{A;B;Rmse;N}. With fewer than two
    distinct x the line goes through the origin (B = mean y / mean x), which is what a single
    measured point can honestly say about a cost that is zero at zero pixels per second.
    #>
    param([double[]]$X, [double[]]$Y)
    $n = [Math]::Min($X.Count, $Y.Count)
    if ($n -eq 0) { return @{ A = 0.0; B = 0.0; Rmse = 0.0; N = 0 } }
    $mx = ($X | Measure-Object -Average).Average; $my = ($Y | Measure-Object -Average).Average
    $sxx = 0.0; $sxy = 0.0
    for ($i = 0; $i -lt $n; $i++) { $sxx += ($X[$i] - $mx) * ($X[$i] - $mx); $sxy += ($X[$i] - $mx) * ($Y[$i] - $my) }
    if (@($X | Select-Object -Unique).Count -lt 2 -or $sxx -le 0) {
        $a = 0.0; $b = if ($mx -gt 0) { $my / $mx } else { 0.0 }
    } else {
        $b = $sxy / $sxx; $a = $my - $b * $mx
    }
    $se = 0.0
    for ($i = 0; $i -lt $n; $i++) { $r = $Y[$i] - ($a + $b * $X[$i]); $se += $r * $r }
    return @{ A = $a; B = $b; Rmse = [Math]::Sqrt($se / $n); N = $n }
}


function Get-StreamBenchmarkModel {
    <#
    .SYNOPSIS
    Fits the load model of a stored result, so every parameter combination can be predicted
    (Get-StreamBenchmarkModelPrediction). Returns @{Ok;Error;Model;Families;RefMbps;RefReencode;
    MbpsSlope;ReencodeSlope;Base;Gpus}.
    .DESCRIPTION
    Per encoder x codec family and per resource (stream CPU, every GPU, RAM):
        cost = A + B x (pixels per frame x fps, in Mpx/s)
               + MbpsSlope x (capture Mb/s - ref) + ReencodeSlope x (re-encode Mb/s - ref)
               [+ MergedExtra for a merged view]
    Pixels come from Get-StreamBenchmarkFramePixels, so a view or max size that was never run is
    still predictable. The capture and re-encode bitrate slopes are shared by every family (the
    typical preset measures them once). Each fit keeps its RMSE, which the recommendation shows
    as a +/- band, and its measured pixel-rate range, outside which a prediction is flagged.
    Validated on a Quest 3 + RTX 5070: one change at a time predicted combined points within
    about 1 GPU point.
    .EXAMPLE
    $m = Get-StreamBenchmarkModel -Result (Get-StreamBenchmarkResult -Model 'Quest 3')
    #>
    param($Result)
    $out = @{ Ok = $false; Error = ''; Model = ''; Families = @(); RefMbps = 10; RefReencode = 4
              MbpsSlope = $null; ReencodeSlope = $null; Base = $null; Gpus = @() }
    if (-not $Result -or -not $Result.Results) { $out.Error = 'Please run first a benchmark.'; return $out }
    $model = [string]$Result.Model; $out.Model = $model
    $rows = @($Result.Results)
    $base = Get-StreamBenchmarkBaseline -Rows $rows
    $meas = @($rows | Where-Object { $_.Encoding -in @('cpu', 'gpu') -and $_.Status -in @('ok', 'fallback') -and $_.Load })
    if (-not $base -or $meas.Count -eq 0) { $out.Error = 'The stored benchmark has no baseline or no successful test.'; return $out }
    $out.Base = $base
    $gpus = @($Result.Gpus); if ($gpus.Count -eq 0) { $gpus = @($base.Load.Gpus | ForEach-Object { @{ Index = $_.Index; Model = $_.Model } }) }
    $out.Gpus = $gpus
    $gIdx = @($gpus | ForEach-Object { [int]$_.Index })

    $mode = { param($vals) @($vals | Group-Object | Sort-Object Count -Descending | Select-Object -First 1)[0].Name }
    $refMb = [int](& $mode ($meas | ForEach-Object { [int]$_.Mbps }))
    $refRe = [int](& $mode ($meas | ForEach-Object { [int]$_.ReencodeMbps }))
    $out.RefMbps = $refMb; $out.RefReencode = $refRe

    # One point per measured row: pixel rate + cost vector.
    $pts = foreach ($r in $meas) {
        $px = Get-StreamBenchmarkFramePixels -Model $model -View ([string]$r.View) -Eye ([string]$r.Eye) -MaxSize ([int]$r.MaxSize)
        $vec = Get-StreamBenchmarkLoadVector -Row $r -Base $base
        if (-not $vec -or $px.Pixels -le 0) { continue }
        # Fit on the frames actually DELIVERED: a headset that sent 35 of 45 fps made the encoder do
        # 35 fps of work, and fitting that cost against 45 biased the whole family low. Predictions
        # then use the requested fps (a headset that keeps up).
        $fpsEff = [double]$r.Fps
        if ($r.Stream -and $null -ne $r.Stream.Fps -and [double]$r.Stream.Fps -gt 0) { $fpsEff = [Math]::Min([double]$r.Stream.Fps, [double]$r.Fps * 1.1) }
        @{ Row = $r; X = $px.Pixels * $fpsEff / 1e6; Vec = $vec
           Fam = ('{0}|{1}' -f $(if ($r.Encoding -eq 'gpu') { 'gpu:' + [int]$r.GpuIndex } else { 'cpu' }), [string]$r.Codec) }
    }
    $pts = @($pts)
    $val = { param($v, $res) if ($res -eq 'cpu') { $v.Cpu } elseif ($res -eq 'ram') { $v.Ram } else { $gi = [int]$res.Substring(3); if ($v.Gpu.ContainsKey($gi)) { $v.Gpu[$gi] } else { 0.0 } } }
    $resList = @('cpu', 'ram') + @($gIdx | ForEach-Object { 'gpu' + $_ })

    # Shared slopes for capture / re-encode bitrate: from the family holding the most variation,
    # comparing points that differ ONLY in that bitrate.
    $slopeOf = {
        param([string]$field, [int]$refVal)
        $best = $null; $bestN = 1
        foreach ($g in @($pts | Group-Object { '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.Fam, $_.Row.Eye, $_.Row.View, $_.Row.Fps, $_.Row.MaxSize, $(if ($field -eq 'Mbps') { $_.Row.ReencodeMbps } else { $_.Row.Mbps }) })) {
            $n = @($g.Group | ForEach-Object { [int]$_.Row.$field } | Select-Object -Unique).Count
            if ($n -gt $bestN) { $bestN = $n; $best = @($g.Group) }
        }
        $s = @{}
        foreach ($res in $resList) {
            if ($best) { $f = Get-StreamBenchmarkLinearFit -X @($best | ForEach-Object { [double]$_.Row.$field }) -Y @($best | ForEach-Object { [double](& $val $_.Vec $res) }); $s[$res] = $f.B }
            else { $s[$res] = 0.0 }
        }
        return $s
    }
    $mbS = & $slopeOf 'Mbps' $refMb
    $reS = & $slopeOf 'ReencodeMbps' $refRe
    $out.MbpsSlope = $mbS; $out.ReencodeSlope = $reS

    # Per family: fit single-eye points (bitrate effects removed), then the merged residual.
    $fams = foreach ($g in @($pts | Group-Object { $_.Fam })) {
        $single = @($g.Group | Where-Object { $_.Row.Eye -ne 'M' })
        $merged = @($g.Group | Where-Object { $_.Row.Eye -eq 'M' })
        $adj = { param($p, $res) (& $val $p.Vec $res) - $mbS[$res] * ([double]$p.Row.Mbps - $refMb) - $reS[$res] * ([double]$p.Row.ReencodeMbps - $refRe) }
        $fit = @{}
        foreach ($res in $resList) {
            if ($single.Count -gt 0) { $fit[$res] = Get-StreamBenchmarkLinearFit -X @($single | ForEach-Object { $_.X }) -Y @($single | ForEach-Object { & $adj $_ $res }) }
        }
        $mx = $null
        if ($merged.Count -gt 0 -and $single.Count -gt 0) {
            $mx = @{}
            foreach ($res in $resList) {
                $resid = @($merged | ForEach-Object { (& $adj $_ $res) - ($fit[$res].A + $fit[$res].B * $_.X) })
                $mx[$res] = ($resid | Measure-Object -Average).Average
            }
        }
        # FPS risk: the smallest pixel rate where the PC could not keep up. A shortfall counts only
        # when the PC was the limit - the encoder fell behind real time (ffmpeg speed < 0.95) or a
        # CPU / GPU was at 85% or more. A headset that delivers fewer frames on its own (not worn,
        # proximity sensor, static scene) dropped every NVENC h264 point to 35/45 fps at 5% GPU in
        # a real run - counting that would have flagged every NVENC setting as a risk.
        $pcBound = {
            param($p)
            $l = $p.Row.Load; $sp = if ($p.Row.Stream) { $p.Row.Stream.Speed } else { $null }
            ($null -ne $sp -and [double]$sp -lt 0.95) -or ($l -and [double]$l.CpuAvg -ge 85) -or
                ($l -and @($l.Gpus | Where-Object { $_ -and [double]$_.UtilAvg -ge 85 }).Count -gt 0)
        }
        $short = @($g.Group | Where-Object { $null -ne $_.Vec.FpsRatio -and $_.Vec.FpsRatio -lt 0.9 })
        $bad = @($short | Where-Object { & $pcBound $_ } | ForEach-Object { $_.X })
        $headsetShort = @($short | Where-Object { -not (& $pcBound $_) }).Count
        $first = $g.Group[0].Row
        @{
            Key = $g.Name; Encoding = [string]$first.Encoding; GpuIndex = [int]$first.GpuIndex; Codec = [string]$first.Codec
            Encoder = [string](@($g.Group | ForEach-Object { $_.Row.Encoder } | Where-Object { $_ }) | Select-Object -First 1)
            Points = $g.Count; SinglePoints = $single.Count; MergedPoints = $merged.Count
            XMin = if ($single.Count) { ($single | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum } else { $null }
            XMax = if ($single.Count) { ($single | ForEach-Object { $_.X } | Measure-Object -Maximum).Maximum } else { $null }
            DistinctX = @($single | ForEach-Object { [Math]::Round($_.X, 2) } | Select-Object -Unique).Count
            Fit = $fit; MergedExtra = $mx
            FpsLimitX = if ($bad.Count) { ($bad | Measure-Object -Minimum).Minimum } else { $null }
            # Tests short of frames while the PC was NOT the limit: a headset-side shortfall.
            HeadsetFpsShortfalls = $headsetShort
        }
    }
    $out.Families = @($fams | Where-Object { $_.SinglePoints -gt 0 })
    if ($out.Families.Count -eq 0) { $out.Error = 'No single-eye test to build the model from.'; return $out }
    $out.Ok = $true
    return $out
}


function Get-StreamBenchmarkModelPrediction {
    <#
    .SYNOPSIS
    Predicted cost of ONE stream for any settings, from Get-StreamBenchmarkModel:
    @{Ok;Error;Vec;Err;X;Pixels;W;H;InRange;FpsRisk;Family}. Vec / Err have the LoadVector shape
    (Cpu, Gpu = @{index}, Ram) - Err holds each fit's RMSE. -Settings keys: Eye, View, Encoding
    ('cpu' | 'gpu:<i>'), Codec, Fps, Mbps, ReencodeMbps, MaxSize.
    .EXAMPLE
    Get-StreamBenchmarkModelPrediction -ModelFit $m -Settings @{ Eye='R'; View='square'; Encoding='gpu:1'; Codec='h264'; Fps=60; Mbps=10; ReencodeMbps=4; MaxSize=1080 }
    #>
    param([Parameter(Mandatory = $true)]$ModelFit, [Parameter(Mandatory = $true)]$Settings)
    $get = { param($n) Get-StreamBenchmarkSelectionValue $Settings $n }
    $eye = ([string](& $get 'Eye')).ToUpper(); if ($eye -ne 'M') { $eye = 'R' }
    $enc = ([string](& $get 'Encoding')).ToLower(); $codec = ([string](& $get 'Codec')).ToLower()
    $fps = [double](& $get 'Fps'); $mb = [double](& $get 'Mbps'); $re = [double](& $get 'ReencodeMbps')
    $size = [int](& $get 'MaxSize'); $view = [string](& $get 'View')
    $res = @{ Ok = $false; Error = ''; Vec = $null; Err = $null; X = 0; Pixels = 0; W = 0; H = 0; InRange = $true; FpsRisk = $false; Family = $null }
    $fam = $ModelFit.Families | Where-Object { $_.Key -eq ('{0}|{1}' -f $enc, $codec) } | Select-Object -First 1
    if (-not $fam) { $res.Error = ('{0} {1} was not measured.' -f $enc, $codec); return $res }
    if ($eye -eq 'M' -and -not $fam.MergedExtra) {
        # A merged view on this encoder family was not measured; another codec of the same encoder will do.
        $alt = $ModelFit.Families | Where-Object { $_.Key -like ($enc + '|*') -and $_.MergedExtra } | Select-Object -First 1
        if (-not $alt) { $res.Error = ('Merged view with {0} was not measured.' -f $enc); return $res }
        $mExtra = $alt.MergedExtra
    } else { $mExtra = $fam.MergedExtra }
    $px = Get-StreamBenchmarkFramePixels -Model $ModelFit.Model -View $view -Eye $eye -MaxSize $(if ($eye -eq 'M') { 0 } else { $size })
    if ($px.Pixels -le 0) { $res.Error = 'Unknown frame size for this view.'; return $res }
    $x = $px.Pixels * $fps / 1e6
    $one = {
        param($r)
        $f = $fam.Fit[$r]; if (-not $f) { return 0.0 }
        $v = $f.A + $f.B * $x + $ModelFit.MbpsSlope[$r] * ($mb - $ModelFit.RefMbps) + $ModelFit.ReencodeSlope[$r] * ($re - $ModelFit.RefReencode)
        if ($eye -eq 'M' -and $mExtra) { $v += $mExtra[$r] }
        return [Math]::Max(0.0, $v)
    }
    $gpu = @{}; $gerr = @{}
    foreach ($g in $ModelFit.Gpus) { $k = 'gpu' + [int]$g.Index; $gpu[[int]$g.Index] = & $one $k; $gerr[[int]$g.Index] = if ($fam.Fit[$k]) { $fam.Fit[$k].Rmse } else { 0.0 } }
    $res.Vec = @{ Cpu = (& $one 'cpu'); Gpu = $gpu; Ram = (& $one 'ram'); FpsRatio = $null }
    $res.Err = @{ Cpu = $fam.Fit['cpu'].Rmse; Gpu = $gerr; Ram = $fam.Fit['ram'].Rmse }
    $res.X = [Math]::Round($x, 2); $res.Pixels = $px.Pixels; $res.W = $px.W; $res.H = $px.H
    # Outside the measured pixel-rate range by more than 25%: flagged, still computed.
    if ($null -ne $fam.XMax -and ($x -gt $fam.XMax * 1.25 -or $x -lt $fam.XMin * 0.75)) { $res.InRange = $false }
    if ($null -ne $fam.FpsLimitX -and $x -ge $fam.FpsLimitX * 0.95) { $res.FpsRisk = $true }
    $res.Family = $fam.Key
    $res.Ok = $true
    return $res
}


function Get-StreamBenchmarkSessionCap {
    <#
    .SYNOPSIS
    Hardware cap on parallel encode sessions for an encoding ('cpu' | 'gpu:<i>'), or 0 for none:
    GeForce NVENC is limited by the driver ($script:BenchNvencSessionCap); professional NVIDIA
    cards, Intel and AMD are not.
    #>
    param([string]$Encoding, [object[]]$Gpus)
    if ($Encoding -notmatch '^gpu:(\d+)$') { return 0 }
    $g = @($Gpus) | Where-Object { [int]$_.Index -eq [int]$Matches[1] } | Select-Object -First 1
    if ($g -and [string]$g.Model -match 'NVIDIA' -and [string]$g.Model -notmatch 'Quadro|RTX A\d|RTX \d000 Ada|Tesla|Data Center') { return $script:BenchNvencSessionCap }
    return 0
}


function Get-StreamBenchmarkRecommendation {
    <#
    .SYNOPSIS
    Load estimate for -Headsets parallel streams and up to three proposals. Uses the fitted model
    (Get-StreamBenchmarkModel) when the result supports it - any parameter combination, with a
    +/- band - and falls back to Get-StreamBenchmarkRecommendationMeasured (measured tests and
    interpolation only) otherwise. Same parameters and return shape as the measured mode, plus
    Mode ('model' | 'measured'), Model (fit summary) and, in Estimate / Proposals, CpuBand,
    Gpus[].Band, InRange, FpsRisk, SessionCap, W, H.
    .EXAMPLE
    Get-StreamBenchmarkRecommendation -Result (Get-StreamBenchmarkResult -Model 'Quest 3') -Headsets 6 -Settings @{ Fps = 60; MaxSize = 1080 }
    #>
    param(
        $Result,
        [ValidateRange(1, 64)][int]$Headsets = 1,
        $Settings = $null,
        [double]$MaxCpu = -1,
        [double]$MaxGpu = -1,
        [double]$Margin = 0.10
    )
    $fit = $null
    try { $fit = Get-StreamBenchmarkModel -Result $Result } catch { $fit = $null }
    $usable = $fit -and $fit.Ok -and @($fit.Families | Where-Object { $_.DistinctX -ge 2 }).Count -gt 0
    if (-not $usable) {
        $r = Get-StreamBenchmarkRecommendationMeasured -Result $Result -Headsets $Headsets -Settings $Settings -MaxCpu $MaxCpu -MaxGpu $MaxGpu -Margin $Margin
        $r.Mode = 'measured'
        return $r
    }
    if ($MaxCpu -le 0) { $MaxCpu = if ($null -ne $global:VQA_CpuMaxThreshold) { [double]$global:VQA_CpuMaxThreshold } else { 80 } }
    if ($MaxGpu -le 0) { $MaxGpu = if ($null -ne $global:VQA_GpuMaxThreshold) { [double]$global:VQA_GpuMaxThreshold } else { 80 } }
    $out = @{ Ok = $true; Error = ''; Mode = 'model'; Headsets = $Headsets; Margin = $Margin; Limits = @{ Cpu = $MaxCpu; Gpu = $MaxGpu }
              Choices = $null; Settings = $null; Estimate = $null; Proposals = @()
              Note = 'Model fitted on the measured tests (one change at a time), linear in pixels x fps, scaled to N headsets with a safety margin. The +/- band is the fit error.'
              Model = $null }
    $base = $fit.Base; $gpus = $fit.Gpus; $modelName = $fit.Model
    $k = 1.0 + $Margin
    $hsShort = 0; foreach ($fm in $fit.Families) { $hsShort += [int]$fm.HeadsetFpsShortfalls }
    if ($hsShort -gt 0) {
        $out.Note += (' {0} test(s) received fewer frames than requested while the PC was not loaded: the headset itself limited the frame rate (not worn, proximity sensor, static scene). Wear the headset or keep it active and run those tests again for reliable frame-rate figures.' -f $hsShort)
    }

    # ---- Choices: anything the model can predict ----
    $tpl = Get-StreamBenchmarkModelTemplate -Model $modelName
    $views = @(); if ($tpl -and $tpl.views) { $views = @($tpl.views.PSObject.Properties | ForEach-Object { $_.Name }) }
    $encs = @($fit.Families | ForEach-Object { if ($_.Encoding -eq 'gpu') { 'gpu:' + $_.GpuIndex } else { 'cpu' } } | Select-Object -Unique)
    $hasMerged = [bool]($fit.Families | Where-Object { $_.MergedExtra })
    $out.Choices = @{
        Eyes = @(@('R') + $(if ($hasMerged) { @('M') } else { @() }))
        Views = $views; Encodings = $encs
        Codecs = @($fit.Families | ForEach-Object { $_.Codec } | Select-Object -Unique)
        Fps = @(15, 30, 45, 60, 72); Mbps = @(5, 10, 20, 40)
        ReencodeMbps = @(@(2, 4, 6, 8, 12) + @($fit.RefReencode) | Select-Object -Unique | Sort-Object)
        MaxSizes = @(0, 2560, 1920, 1440, 1080, 720)
    }
    $out.Model = @{
        RefMbps = $fit.RefMbps; RefReencode = $fit.RefReencode
        Families = @($fit.Families | ForEach-Object {
            $fm = $_
            @{ Key = $fm.Key; Encoder = $fm.Encoder; Points = $fm.SinglePoints; Merged = [bool]$fm.MergedExtra
               XMin = $fm.XMin; XMax = $fm.XMax; CpuRmse = [Math]::Round($fm.Fit['cpu'].Rmse, 2)
               GpuRmse = @($gpus | ForEach-Object { @{ Index = [int]$_.Index; Rmse = [Math]::Round($fm.Fit[('gpu' + [int]$_.Index)].Rmse, 2) } }) } })
    }

    # ---- Settings (defaults: single eye, current view, 45 fps, 10 Mb/s, best GPU, h264) ----
    $get = { param($n) Get-StreamBenchmarkSelectionValue $Settings $n }
    $bestGpu = $gpus | Where-Object { [int]$_.Index -eq [int]$global:GPU_Index } | Select-Object -First 1
    $defEnc = if ($bestGpu -and $encs -contains ('gpu:' + [int]$bestGpu.Index)) { 'gpu:' + [int]$bestGpu.Index } else { $encs[0] }
    $lastView = @($Result.Results | Where-Object { $_.View } | ForEach-Object { [string]$_.View } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1)[0].Name
    $s = @{
        Eye = $(if ([string](& $get 'Eye') -eq 'M' -and $hasMerged) { 'M' } else { 'R' })
        View = $(if ($views -contains [string](& $get 'View')) { [string](& $get 'View') } elseif ($lastView) { $lastView } else { $views[0] })
        Encoding = $(if ($encs -contains [string](& $get 'Encoding')) { [string](& $get 'Encoding') } else { $defEnc })
        Codec = $(if ((& $get 'Codec') -in @('h264', 'h265')) { [string](& $get 'Codec') } else { 'h264' })
        Fps = $(if ((& $get 'Fps') -as [int]) { [int](& $get 'Fps') } else { 45 })
        Mbps = $(if ((& $get 'Mbps') -as [int]) { [int](& $get 'Mbps') } else { 10 })
        ReencodeMbps = $(if ((& $get 'ReencodeMbps') -as [int]) { [int](& $get 'ReencodeMbps') } else { [int]$fit.RefReencode })
        MaxSize = $(if ($null -ne (& $get 'MaxSize') -and "$(& $get 'MaxSize')" -ne '') { [int](& $get 'MaxSize') } else { 0 })
    }
    if (-not ($fit.Families | Where-Object { $_.Key -eq ('{0}|{1}' -f $s.Encoding, $s.Codec) })) {
        $s.Codec = [string](@($fit.Families | Where-Object { $_.Key -like ($s.Encoding + '|*') })[0].Codec)
    }
    if ($s.Eye -eq 'M') { $s.MaxSize = -1 } elseif ($s.MaxSize -lt 0) { $s.MaxSize = 0 }
    $out.Settings = $s

    # ---- One settings set -> estimate for N headsets ----
    $estimate = {
        param($set, [int]$n)
        $p = Get-StreamBenchmarkModelPrediction -ModelFit $fit -Settings $set
        if (-not $p.Ok) { return @{ NotMeasured = $true; Message = $p.Error } }
        $e = Get-StreamBenchmarkLoadEstimate -Vec $p.Vec -Base $base -Gpus $gpus -Headsets $n -MaxCpu $MaxCpu -MaxGpu $MaxGpu -Margin $Margin
        $e.CpuBand = [Math]::Round($n * $p.Err.Cpu * $k, 1)
        foreach ($g in $e.Gpus) { $g.Band = [Math]::Round($n * $p.Err.Gpu[[int]$g.Index] * $k, 1) }
        $cap = Get-StreamBenchmarkSessionCap -Encoding $set.Encoding -Gpus $gpus
        $e.SessionCap = $cap
        if ($cap -gt 0) {
            $e.MaxHeadsets = [Math]::Min($e.MaxHeadsets, $cap)
            if ($n -gt $cap) { $e.Fits = $false }
        }
        $e.FpsRisk = $p.FpsRisk; $e.InRange = $p.InRange
        if ($p.FpsRisk) { $e.FpsOk = $false; $e.Fits = $false }
        $e.Measured = $false; $e.Interpolated = $true
        $e.W = $p.W; $e.H = $p.H; $e.PixelRate = $p.X
        $e.CaptureMbpsTotal = $n * [int]$set.Mbps
        $e.ReencodeMbpsPerViewer = $n * [int]$set.ReencodeMbps
        return $e
    }
    $out.Estimate = & $estimate $s $Headsets

    # ---- Proposals: search the space, best quality that fits ----
    $cands = [System.Collections.Generic.List[object]]::new()
    $candSeen = @{}
    $eyesC = @('R') + $(if ($hasMerged) { @('M') } else { @() })
    foreach ($fam in $fit.Families) {
        $enc = if ($fam.Encoding -eq 'gpu') { 'gpu:' + $fam.GpuIndex } else { 'cpu' }
        foreach ($eye in $eyesC) {
            $sizes = if ($eye -eq 'M') { @(-1) } else { @(0, 1920, 1440, 1080, 720) }
            foreach ($sz in $sizes) {
                # A merged view is only proposed at its default 30 fps (higher costs CPU per frame).
                foreach ($f in $(if ($eye -eq 'M') { @(30) } else { @(30, 45, 60, 72) })) {
                    foreach ($b in 10, 20) {
                        $set = @{ Eye = $eye; View = $s.View; Encoding = $enc; Codec = $fam.Codec; Fps = $f; Mbps = $b; ReencodeMbps = $s.ReencodeMbps; MaxSize = $sz }
                        $e = & $estimate $set $Headsets
                        if ($e.NotMeasured) { continue }
                        # A max size above the native frame gives the native frame: one candidate only.
                        $ck = '{0}|{1}|{2}|{3}x{4}|{5}|{6}' -f $enc, $fam.Codec, $eye, $e.W, $e.H, $f, $b
                        if ($candSeen.ContainsKey($ck)) { continue }
                        $candSeen[$ck] = $true
                        $cands.Add([PSCustomObject]@{
                            Settings = $set; Estimate = $e; Fits = [bool]$e.Fits
                            RankEye = [int]($eye -eq 'M'); RankFps = $f; RankPx = [int]$e.W * [int]$e.H; RankMbps = $b
                            RankGpu = [int]($enc -like 'gpu:*'); Cpu = [double]$e.Cpu; MaxN = [int]$e.MaxHeadsets
                            InRange = [bool]$e.InRange; Encoder = $fam.Encoder
                        })
                    }
                }
            }
        }
    }
    $all = @($cands)
    # Prefer predictions inside the measured range; fall back to all when none fits there.
    $fitting = @($all | Where-Object { $_.Fits -and $_.InRange })
    if ($fitting.Count -eq 0) { $fitting = @($all | Where-Object { $_.Fits }) }
    $order = @(
        @{ Expression = 'RankEye'; Descending = $true }, @{ Expression = 'RankFps'; Descending = $true },
        @{ Expression = 'RankPx'; Descending = $true }, @{ Expression = 'RankMbps'; Descending = $true },
        @{ Expression = 'RankGpu'; Descending = $true }, @{ Expression = 'Cpu'; Descending = $false })
    if ($fitting.Count -gt 0) {
        $top = @($fitting | Sort-Object -Property $order | Select-Object -First 3)
    } else {
        $top = @($all | Sort-Object -Property @{ Expression = 'MaxN'; Descending = $true }, @{ Expression = 'Cpu'; Descending = $false } | Select-Object -First 3)
        $out.Note += (' No configuration fits {0} headset(s) under these limits - the closest ones are shown.' -f $Headsets)
    }
    $out.Proposals = @($top | ForEach-Object {
        $st = $_.Settings
        $encLbl = if ($st.Encoding -eq 'cpu') { 'CPU' } else { 'GPU ' + $st.Encoding.Split(':')[1] }
        $sizeLbl = if ($st.Eye -eq 'M') { 'merged' } else { '{0}x{1}' -f $_.Estimate.W, $_.Estimate.H }
        @{ Settings = $st; Encoder = $_.Encoder; Estimate = $_.Estimate; Fits = $_.Fits
           Label = ('{0}, {1} fps, {2} Mb/s, {3} {4}, re-encode {5} Mb/s' -f $sizeLbl, $st.Fps, $st.Mbps, $encLbl, $st.Codec, $st.ReencodeMbps) }
    })
    return $out
}


function Get-StreamBenchmarkRecommendationMeasured {
    <#
    .SYNOPSIS
    Estimates the PC load of -Headsets parallel streams with -Settings, from a stored benchmark
    result, and proposes up to three measured configurations that fit under the limits.
    .DESCRIPTION
    Linear model: baseline + N x (one stream's cost above baseline) x (1 + -Margin). Settings
    not measured exactly are interpolated in FPS and capture bitrate inside one configuration
    family (eye, view, encoder, codec, re-encode bitrate, max size), never extrapolated.
    -MaxCpu / -MaxGpu default to the VQA max thresholds. A proposal must fit N headsets and
    have delivered at least 90% of its target FPS; ranked merged > single eye, then FPS,
    capture bitrate, max size, GPU before CPU, lowest CPU.
    -Settings keys (all optional, defaults = single eye, 45 fps, 10 Mb/s, best GPU, h264):
    Eye, View, Encoding ('cpu' | 'gpu:<index>'), Codec, Fps, Mbps, ReencodeMbps, MaxSize.
    Returns @{Ok;Error;Headsets;Margin;Limits;Choices;Settings;Estimate;Proposals;Note}.
    .EXAMPLE
    Get-StreamBenchmarkRecommendation -Result (Get-StreamBenchmarkResult -Model 'Quest 3') -Headsets 6
    #>
    param(
        $Result,
        [ValidateRange(1, 64)][int]$Headsets = 1,
        $Settings = $null,
        [double]$MaxCpu = -1,
        [double]$MaxGpu = -1,
        [double]$Margin = 0.10
    )
    if ($MaxCpu -le 0) { $MaxCpu = if ($null -ne $global:VQA_CpuMaxThreshold) { [double]$global:VQA_CpuMaxThreshold } else { 80 } }
    if ($MaxGpu -le 0) { $MaxGpu = if ($null -ne $global:VQA_GpuMaxThreshold) { [double]$global:VQA_GpuMaxThreshold } else { 80 } }
    $out = @{ Ok = $false; Error = ''; Headsets = $Headsets; Margin = $Margin; Limits = @{ Cpu = $MaxCpu; Gpu = $MaxGpu }
              Choices = $null; Settings = $null; Estimate = $null; Proposals = @()
              Note = 'Linear extrapolation from a single-headset measure, with a safety margin.' }
    if (-not $Result -or -not $Result.Results) { $out.Error = 'Please run first a benchmark.'; return $out }

    $rows = @($Result.Results)
    $base = $rows | Where-Object { $_.Id -eq 'baseline' -and $_.Load } | Select-Object -First 1
    $measured = @($rows | Where-Object { $_.Encoding -in @('cpu', 'gpu') -and $_.Status -in @('ok', 'fallback') -and $_.Load })
    if (-not $base -or $measured.Count -eq 0) { $out.Error = 'The stored benchmark has no baseline or no successful test - run a benchmark again.'; return $out }
    $gpus = @($Result.Gpus)
    if ($gpus.Count -eq 0 -and $base.Load.Gpus) { $gpus = @($base.Load.Gpus | ForEach-Object { @{ Index = $_.Index; Model = $_.Model } }) }

    $encOf = { param($r) if ($r.Encoding -eq 'gpu') { 'gpu:' + [int]$r.GpuIndex } else { 'cpu' } }
    $famOf = { param($eye, $view, $enc, $codec, $reenc, $size) ('{0}|{1}|{2}|{3}|{4}|{5}' -f $eye, $view, $enc, $codec, $reenc, $size) }

    # Choices = what was measured.
    $choices = @{
        Eyes         = @($measured | ForEach-Object { [string]$_.Eye } | Select-Object -Unique)
        Views        = @($measured | ForEach-Object { [string]$_.View } | Select-Object -Unique)
        Encodings    = @($measured | ForEach-Object { & $encOf $_ } | Select-Object -Unique)
        Codecs       = @($measured | ForEach-Object { [string]$_.Codec } | Select-Object -Unique)
        Fps          = @($measured | ForEach-Object { [int]$_.Fps } | Select-Object -Unique | Sort-Object)
        Mbps         = @($measured | ForEach-Object { [int]$_.Mbps } | Select-Object -Unique | Sort-Object)
        ReencodeMbps = @($measured | ForEach-Object { [int]$_.ReencodeMbps } | Select-Object -Unique | Sort-Object)
        MaxSizes     = @($measured | ForEach-Object { [int]$_.MaxSize } | Select-Object -Unique | Sort-Object)
    }
    $out.Choices = $choices

    # Settings: given value when it was measured (FPS / bitrate may be anything - interpolated),
    # else the default, else the first measured value.
    $pick = {
        param($name, $list, $default)
        $v = Get-StreamBenchmarkSelectionValue $Settings $name
        if ($null -ne $v -and "$v" -ne '' -and (@($list) -contains $v -or @($list | ForEach-Object { "$_" }) -contains "$v")) { return $v }
        if (@($list | ForEach-Object { "$_" }) -contains "$default") { return $default }
        return @($list)[0]
    }
    $bestGpu = $gpus | Where-Object { [int]$_.Index -eq [int]$global:GPU_Index } | Select-Object -First 1
    $defEnc = if ($bestGpu) { 'gpu:' + [int]$bestGpu.Index } else { 'cpu' }
    $cfgReenc = ConvertTo-StreamBenchmarkMbps $global:mediamtxBitrate
    $s = @{
        Eye  = [string](& $pick 'Eye' $choices.Eyes 'R')
        View = [string](& $pick 'View' $choices.Views ($choices.Views | Select-Object -First 1))
        Encoding = [string](& $pick 'Encoding' $choices.Encodings $defEnc)
        Codec = [string](& $pick 'Codec' $choices.Codecs 'h264')
        ReencodeMbps = [int](& $pick 'ReencodeMbps' $choices.ReencodeMbps $cfgReenc)
        MaxSize = [int](& $pick 'MaxSize' $choices.MaxSizes ($choices.MaxSizes | Select-Object -Last 1))
    }
    $fpsIn = Get-StreamBenchmarkSelectionValue $Settings 'Fps';  $s.Fps  = if ($fpsIn -as [int])  { [int]$fpsIn }  else { 45 }
    $mbIn  = Get-StreamBenchmarkSelectionValue $Settings 'Mbps'; $s.Mbps = if ($mbIn -as [int])   { [int]$mbIn }   else { 10 }
    # A merged view has no max capture size (stored as -1).
    if ($s.Eye -eq 'M') { $s.MaxSize = -1 } elseif ($s.MaxSize -lt 0) { $s.MaxSize = [int]($choices.MaxSizes | Where-Object { $_ -ge 0 } | Select-Object -Last 1) }
    $out.Settings = $s

    # Families of measured points.
    $families = @{}
    foreach ($r in $measured) {
        $fam = & $famOf $r.Eye $r.View (& $encOf $r) $r.Codec ([int]$r.ReencodeMbps) ([int]$r.MaxSize)
        if (-not $families.ContainsKey($fam)) { $families[$fam] = [System.Collections.Generic.List[object]]::new() }
        $vec = Get-StreamBenchmarkLoadVector -Row $r -Base $base
        if ($vec) { $families[$fam].Add(@{ Fps = [int]$r.Fps; Mbps = [int]$r.Mbps; Vec = $vec; Row = $r }) }
    }

    # ---- Estimate for the chosen settings ----
    $fam = & $famOf $s.Eye $s.View $s.Encoding $s.Codec $s.ReencodeMbps $s.MaxSize
    $vec = $null; $exact = $false
    if ($families.ContainsKey($fam)) {
        $pts = $families[$fam].ToArray()
        $exact = [bool]($pts | Where-Object { $_.Fps -eq $s.Fps -and $_.Mbps -eq $s.Mbps })
        $vec = Get-StreamBenchmarkInterpolated -Points $pts -Fps $s.Fps -Mbps $s.Mbps
    }
    if ($vec) {
        $est = Get-StreamBenchmarkLoadEstimate -Vec $vec -Base $base -Gpus $gpus -Headsets $Headsets -MaxCpu $MaxCpu -MaxGpu $MaxGpu -Margin $Margin
        $est.Measured = $exact
        $est.Interpolated = -not $exact
        $est.CaptureMbpsTotal = $Headsets * $s.Mbps
        $est.ReencodeMbpsPerViewer = $Headsets * $s.ReencodeMbps
        $out.Estimate = $est
    } else {
        $out.Estimate = @{ NotMeasured = $true; Message = 'These settings were not measured and are outside the measured FPS / bitrate range - run a benchmark that covers them.' }
    }

    # ---- Proposals: measured configurations that fit N headsets ----
    $cands = foreach ($f in $families.Keys) {
        foreach ($p in $families[$f]) {
            $e = Get-StreamBenchmarkLoadEstimate -Vec $p.Vec -Base $base -Gpus $gpus -Headsets $Headsets -MaxCpu $MaxCpu -MaxGpu $MaxGpu -Margin $Margin
            $r = $p.Row
            $sizeRank = if ([int]$r.MaxSize -le 0) { 100000 } else { [int]$r.MaxSize }
            [PSCustomObject]@{
                Settings = @{ Eye = [string]$r.Eye; View = [string]$r.View; Encoding = (& $encOf $r); Codec = [string]$r.Codec
                              Fps = [int]$r.Fps; Mbps = [int]$r.Mbps; ReencodeMbps = [int]$r.ReencodeMbps; MaxSize = [int]$r.MaxSize }
                Label = [string]$r.Label; Encoder = [string]$r.Encoder; Estimate = $e; Fits = [bool]$e.Fits
                RankEye = [int]($r.Eye -eq 'M'); RankFps = [int]$r.Fps; RankMbps = [int]$r.Mbps; RankSize = $sizeRank
                RankGpu = [int]($r.Encoding -eq 'gpu'); Cpu = [double]$e.Cpu; MaxN = [int]$e.MaxHeadsets
            }
        }
    }
    $cands = @($cands)
    $fitting = @($cands | Where-Object { $_.Fits })
    $order = @(
        @{ Expression = 'RankEye'; Descending = $true }, @{ Expression = 'RankFps'; Descending = $true },
        @{ Expression = 'RankMbps'; Descending = $true }, @{ Expression = 'RankSize'; Descending = $true },
        @{ Expression = 'RankGpu'; Descending = $true }, @{ Expression = 'Cpu'; Descending = $false })
    if ($fitting.Count -gt 0) {
        $top = @($fitting | Sort-Object -Property $order | Select-Object -First 3)
    } else {
        # Nothing fits: show the configurations that go furthest, so the operator sees how close it is.
        $top = @($cands | Sort-Object -Property @{ Expression = 'MaxN'; Descending = $true }, @{ Expression = 'Cpu'; Descending = $false } | Select-Object -First 3)
        $out.Note += (' No measured configuration fits {0} headset(s) under these limits - the closest ones are shown.' -f $Headsets)
    }
    $out.Proposals = @($top | ForEach-Object { @{ Settings = $_.Settings; Label = $_.Label; Encoder = $_.Encoder; Estimate = $_.Estimate; Fits = $_.Fits } })
    $out.Ok = $true
    return $out
}


function Set-StreamBenchmarkConfigValue {
    <# Sets $Object.$Name, adding the property when missing (internal). Returns $true on a change. #>
    param($Object, [string]$Name, $Value)
    $p = $Object.PSObject.Properties[$Name]
    if ($p) {
        if ("$($p.Value)" -ceq "$Value") { return $false }
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    return $true
}


function Set-StreamBenchmarkRecommendation {
    <#
    .SYNOPSIS
    Applies one recommended configuration: restream settings in config.json (re-encode on,
    framerate, bitrate, codec, GPU acceleration + index), the model's max capture size, and
    the scrcpy profile of each -HeadsetIds. -Preview lists the changes without writing.
    Returns @{Ok;Changes;Error;Preview}.
    .DESCRIPTION
    Config is written under the VQA lock like /api/config/save. Running streams are restarted
    by VRMonitor itself (Request-StreamRestart), because it owns them (ADR-0026 / ADR-0027).
    .EXAMPLE
    Set-StreamBenchmarkRecommendation -Model 'Quest 3' -Settings $rec.Proposals[0].Settings -HeadsetIds 1,3 -Preview
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)]$Settings,
        [int[]]$HeadsetIds = @(),
        [switch]$Preview
    )
    $res = @{ Ok = $false; Changes = @(); Error = ''; Preview = [bool]$Preview }
    $changes = [System.Collections.Generic.List[string]]::new()
    $get = { param($n) Get-StreamBenchmarkSelectionValue $Settings $n }
    $eye = ([string](& $get 'Eye')).ToUpper(); if ($eye -notin @('R', 'M')) { $eye = 'R' }
    $view = [string](& $get 'View')
    $enc = ([string](& $get 'Encoding')).ToLower()
    $codec = ([string](& $get 'Codec')).ToLower(); if ($codec -notin @('h264', 'h265')) { $codec = 'h264' }
    $fps = [int](& $get 'Fps'); $mbps = [int](& $get 'Mbps'); $reenc = [int](& $get 'ReencodeMbps'); $size = [int](& $get 'MaxSize')
    if ($fps -lt 5 -or $fps -gt 120 -or $mbps -lt 1 -or $mbps -gt 100 -or $reenc -lt 1 -or $reenc -gt 100) { $res.Error = 'Invalid settings.'; return $res }
    $isGpu = $enc -match '^gpu:(\d+)$'
    $gpuIdx = if ($isGpu) { [int]$Matches[1] } else { -1 }

    $cfgPath = Join-Path $global:ScriptPath 'config\config.json'
    $lock = $null
    try {
        if (-not $Preview) {
            $lock = Enter-VqaLock -TimeoutMs 5000
            if (-not $lock) { $res.Error = 'Configuration is busy (VQA lock) - try again.'; return $res }
        }
        $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
        if (-not $cfg) { $res.Error = 'config.json could not be read.'; return $res }
        if (-not $cfg.mediamtx)    { $cfg | Add-Member -NotePropertyName mediamtx -NotePropertyValue ([PSCustomObject]@{}) }
        if (-not $cfg.Performance) { $cfg | Add-Member -NotePropertyName Performance -NotePropertyValue ([PSCustomObject]@{}) }
        $track = {
            param($obj, $name, $value, $label)
            $old = if ($obj.PSObject.Properties[$name]) { "$($obj.$name)" } else { '(none)' }
            if (Set-StreamBenchmarkConfigValue -Object $obj -Name $name -Value $value) { $changes.Add(('{0}: {1} -> {2}' -f $label, $old, $value)) }
        }
        & $track $cfg.mediamtx 'reencode_in_ffmpeg' $true 'mediamtx.reencode_in_ffmpeg'
        & $track $cfg.mediamtx 'stream_framerate' $fps 'mediamtx.stream_framerate'
        & $track $cfg.mediamtx 'stream_bitrate' ('{0}M' -f $reenc) 'mediamtx.stream_bitrate'
        & $track $cfg.mediamtx 'codec' $codec 'mediamtx.codec'
        & $track $cfg.Performance 'GPU_Acceleration' ([bool]$isGpu) 'Performance.GPU_Acceleration'
        if ($isGpu) { & $track $cfg.Performance 'GPU_Index' $gpuIdx 'Performance.GPU_Index' }
        if ($eye -eq 'R' -and $size -ge 0 -and $cfg.scrcpy -and $cfg.scrcpy.parameters -and $cfg.scrcpy.parameters.PSObject.Properties[$Model]) {
            & $track $cfg.scrcpy.parameters.$Model 'max_size' $size ("scrcpy.parameters.{0}.max_size" -f $Model)
        }
        $cfgChanged = $changes.Count -gt 0
        if ($cfgChanged -and -not $Preview) {
            Write-ConfigJson -Object $cfg -Path $cfgPath -Depth 20
        }
    } finally {
        if ($lock) { Exit-VqaLock -Stream $lock }
    }

    # Per-headset profiles.
    $rows = @(Get-KnownHeadsets)
    foreach ($id in $HeadsetIds) {
        $row = $rows | Where-Object { [int]$_.ID -eq [int]$id } | Select-Object -First 1
        if (-not $row) { continue }
        $old = ConvertFrom-ScrcpyProfile -Profile ([string]$row.ScrcpyProfile)
        $v = if ($view) { $view } elseif ($old) { $old.View } else { Get-ScrcpyDefaultView -Model $row.Model }
        $audio = if ($old) { [bool]$old.AudioDup } else { $false }
        $new = ConvertTo-ScrcpyProfile -View $v -Eye $eye -AudioDup $audio -Fps $fps -BitrateMbps $mbps
        if ([string]$row.ScrcpyProfile -ne $new) {
            $changes.Add(('{0} profile: {1} -> {2}' -f $row.Name, $row.ScrcpyProfile, $new))
            if (-not $Preview) { Update-HeadsetField -ID ([int]$row.ID) -Field 'ScrcpyProfile' -NewValue $new }
        }
    }

    if (-not $Preview -and $changes.Count -gt 0) {
        if ($cfgChanged) {
            try { Get-Config -ConfigFilePath $cfgPath | Out-Null } catch { }
            Request-StreamRestart -Reason 'benchmark recommendation applied'
        }
        Write-Log ("Benchmark recommendation applied ({0} change(s)): {1}" -f $changes.Count, ($changes -join '; ')) -Level INFO
    }
    $res.Ok = $true
    $res.Changes = $changes.ToArray()
    return $res
}


function Request-StreamRestart {
    <#
    .SYNOPSIS
    Asks VRMonitor to restart every running stream (after a config change that a running
    stream would not pick up, e.g. the re-encode settings). VRMonitor owns the pipelines, so
    it does the restart itself: reload config, Stop-Scrcpy, then the watchdog restarts them
    on the same tick (ADR-0027). Any process may call this.
    #>
    param([string]$Reason = '')
    try {
        Set-DbKeyValue -Key $script:BenchKvRestart -Value @{
            id = [guid]::NewGuid().ToString('N'); at = (Get-Date).ToUniversalTime().ToString('o'); reason = $Reason
        }
    } catch { }
}


function Get-StreamRestartRequest {
    <# The pending stream restart request @{id;at;reason}, or $null. Read by VRMonitor. #>
    param()
    try { return (Get-DbKeyValue -Key $script:BenchKvRestart) } catch { return $null }
}
