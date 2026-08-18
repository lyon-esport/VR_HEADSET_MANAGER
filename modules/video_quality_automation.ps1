###############################################################
# video_quality_automation.ps1 - VQR (recommender) + VQO (auto-applier).
#
# Loaded by scripts_init.ps1 only when $global:VQA_Enabled is true.
# All functions ASCII-only (no em dashes, no curly quotes, no accents).
#
# Layered design:
#   VQR (Video Quality Recommender) - pure: reads computer_monitoring.json +
#     mediamtx client count + running scrcpy sessions + configured profile
#     max-sizes, emits a recommendation JSON. No side effects on config or
#     headsets. Runs every VRMonitor tick.
#   VQO (Video Quality Optimizer) - debounced auto-applier. Reads last N
#     VQR rows from history; if the direction (down/up/none) has been the
#     same for N consecutive cycles, calls Invoke-VqaApply.
#   Apply / Restore - snapshot baseline on first apply, track what we wrote
#     so manual operator edits between apply and restore are preserved.
###############################################################


# Round an integer down to the nearest multiple of $Step.
# 47, 5 -> 45 ; 12, 5 -> 10 ; 6, 5 -> 5 ; <= 0 returns 0.
function Get-RoundedFpsDown {
    param([int]$Value, [int]$Step = 5)
    if ($Value -le 0 -or $Step -le 0) { return 0 }
    return [int]([Math]::Floor($Value / $Step) * $Step)
}


# Clamp a value to [Min, Max]. Used to enforce min_fps / min_bitrate /
# min_max_size floors and "never above original baseline" ceilings.
# If Min > Max (caller bug, e.g. baseline lower than current floor) we treat the
# request as "pin to Min" rather than returning the unclamped Value silently.
function Get-ClampedValue {
    param([int]$Value, [int]$Min, [int]$Max)
    if ($Min -gt $Max) {
        Write-Log "Get-ClampedValue: Min ($Min) > Max ($Max); pinning to Min." -Level WARNING
        return $Min
    }
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}


###############################################################
# INPUT GATHERING
###############################################################


# Bundle every input the VQR needs into a single PSCustomObject. Returns $null
# only when the computer_monitoring.json snapshot is missing or unparseable -
# without it there is nothing for VQR to reason about.
#
# Output fields:
#   Snapshot      - parsed computer_monitoring.json (CPU, RAM, GPU, AppWorkload)
#   ClientCount   - mediamtx reader count
#   Profiles      - list of model profiles: @{Model; MaxSize}
#   Headsets      - list of running scrcpy sessions:
#                     @{Name; SerialOrIp; Model; Profile; ParsedProfile}
#   MediaMtx      - @{Framerate; BitrateMbps} (Bitrate parsed from "6M" -> 6)
function Get-VqaInputs {
    if (-not (Test-Path -LiteralPath $global:computerMonitoringFilePath)) { return $null }
    try {
        $snap = Get-Content -LiteralPath $global:computerMonitoringFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }

    # Profile max-sizes from $global:scrcpyParameters (PSCustomObject keyed by model name)
    $profiles = @()
    $sp = @($global:scrcpyParameters)
    if ($sp.Count -gt 0 -and $sp[0]) {
        foreach ($modelProp in $sp[0].PSObject.Properties) {
            $profiles += [PSCustomObject]@{
                Model   = $modelProp.Name
                MaxSize = [int]$modelProp.Value.max_size
            }
        }
    } else {
        Write-Log "VQR: scrcpyParameters global is empty or null." -Level WARNING
    }

    # Running scrcpy sessions: cross-reference known_headsets.csv with live scrcpy procs
    $headsetRows = @()
    try { $headsetRows = @(Get-KnownHeadsets) } catch { $headsetRows = @() }

    $running = @()
    foreach ($h in $headsetRows) {
        $name = $h.Name
        if (-not $name) { continue }
        $displayName = $name -replace ' ', '_'
        $proc = Get-ScrcpyProcess -displayName $displayName -headsetIP $h.IPAddress
        if ($proc) {
            $profileStr = if ($h.ScrcpyProfile) { $h.ScrcpyProfile } else { 'portrait-R-N-45-20' }
            $parsed     = ConvertFrom-ScrcpyProfile -Profile $profileStr
            $running += [PSCustomObject]@{
                Name          = $name
                IPAddress     = $h.IPAddress
                Model         = $h.Model
                Profile       = $profileStr
                ParsedProfile = $parsed
            }
        }
    }

    # MediaMTX current bitrate - "6M" / "6m" -> 6
    $mtxBitrate = 0
    if ($global:mediamtxBitrate) {
        $bw = [string]$global:mediamtxBitrate -replace '[^\d]', ''
        if ($bw) { $mtxBitrate = [int]$bw }
    }

    return [PSCustomObject]@{
        Snapshot    = $snap
        ClientCount = (Get-MediaMtxClientCount)
        Profiles    = $profiles
        Headsets    = $running
        MediaMtx    = [PSCustomObject]@{
            Framerate    = [int]$global:mediamtxFramerate
            BitrateMbps  = $mtxBitrate
        }
    }
}


###############################################################
# VQR - VIDEO QUALITY RECOMMENDER
###############################################################


# Decide whether to scale down, scale up, or do nothing based on the latest
# CPU and GPU readings vs the mitigation thresholds.
#   down : at least one of CPU/GPU is at or above its mitigation threshold.
#   up   : both CPU and GPU are at least 10 points below their mitigation
#          threshold AND a baseline snapshot exists (we previously scaled
#          down, so there is something to scale back up).
#   none : steady state.
function Get-VqaDirection {
    param([int]$Cpu, [int]$Gpu)
    if ($Cpu -ge $global:VQA_CpuMitigationThreshold -or $Gpu -ge $global:VQA_GpuMitigationThreshold) {
        return 'down'
    }
    $cpuHeadroom = ($global:VQA_CpuMitigationThreshold - 10)
    $gpuHeadroom = ($global:VQA_GpuMitigationThreshold - 10)
    if ($Cpu -lt $cpuHeadroom -and $Gpu -lt $gpuHeadroom -and (Test-Path -LiteralPath $global:VQA_OriginalsFilePath)) {
        return 'up'
    }
    return 'none'
}


# Core VQR. Always writes a recommendation JSON and appends one history row,
# even when the direction is 'none' - the VQO debouncer relies on a continuous
# row stream to count consecutive agreements.
#
# Mitigation logic (when direction == 'down'):
#   Step 1: reduce each profile's max_size by VQA_DownscaleStepPercent.
#           Models with max_size == 0 (uncapped) start from
#           VQA_DefaultUncappedMaxSize before being scaled.
#   Step 2: align all running scrcpy sessions on the lowest currently-applied
#           Fps and Bitrate, so further reductions affect everyone equally.
#   Step 3: apply VQA_DownscaleStepPercent to those aligned Fps/Bitrate values
#           and to the mediamtx bitrate. FPS rounded down to fps_round_step,
#           bitrate rounded to integer Mbps. Floors enforced via VQA_Min*.
#
# Upscale uses the same step but never exceeds the values stored in
# vqa_originals.json - the operator's chosen ceiling.
# Pure: compute one row for the Profiles table from a single profile input.
# Returns @{Model; Original; Current; Recommended}.
function Get-VqaProfileRecommendation {
    param(
        [Parameter(Mandatory)] $Profile,        # @{Model; MaxSize}
        [Parameter(Mandatory)] [string]$Direction,
        [Parameter(Mandatory)] [double]$Step,
        $Originals                              # parsed vqa_originals.json or $null
    )
    $current = [int]$Profile.MaxSize
    # Treat 0 (uncapped) as VQA_DefaultUncappedMaxSize for math only - the raw
    # operator value (often 0) is what we report in Original/Current so the UI
    # can render "uncapped" honestly.
    $effective = if ($current -eq 0) { [int]$global:VQA_DefaultUncappedMaxSize } else { $current }
    $original  = $current
    if ($Originals -and $Originals.Profiles) {
        $origEntry = $Originals.Profiles | Where-Object { $_.Model -eq $Profile.Model } | Select-Object -First 1
        if ($origEntry) { $original = [int]$origEntry.MaxSize }
    }

    $recommended = $current
    switch ($Direction) {
        'down' {
            $recommended = [int][Math]::Round($effective * (1 - $Step))
            $recommended = Get-ClampedValue -Value $recommended -Min $global:VQA_MinMaxSize -Max $effective
        }
        'up' {
            $recommended = [int][Math]::Round($effective * (1 + $Step))
            $ceiling = if ($original -gt 0) { $original } else { $effective }
            $recommended = Get-ClampedValue -Value $recommended -Min $effective -Max $ceiling
        }
        # 'none' -> recommended stays $current
    }
    return [PSCustomObject]@{
        Model       = $Profile.Model
        Original    = $original
        Current     = $current
        Recommended = $recommended
    }
}


# Pure: compute one row for the Headsets table from a single running session.
# Returns $null when ParsedProfile is missing. Otherwise returns the row object
# including the rebuilt RecommendedProfile string.
# LowestFps / LowestBw are the per-cycle alignment targets (step 2 of the
# 3-step mitigation pipeline).
function Get-VqaHeadsetRecommendation {
    param(
        [Parameter(Mandatory)] $Headset,        # @{Name; Model; Profile; ParsedProfile; ...}
        [Parameter(Mandatory)] [string]$Direction,
        [Parameter(Mandatory)] [double]$Step,
        [Parameter(Mandatory)] [int]$FpsStep,
        [Parameter(Mandatory)] [int]$LowestFps,
        [Parameter(Mandatory)] [int]$LowestBw,
        $Originals
    )
    if (-not $Headset.ParsedProfile) { return $null }

    $curFps = [int]$Headset.ParsedProfile.Fps
    $curBw  = [int]$Headset.ParsedProfile.BitrateMbps
    $origFps = $curFps; $origBw = $curBw
    if ($Originals -and $Originals.Headsets) {
        $origEntry = $Originals.Headsets | Where-Object { $_.Name -eq $Headset.Name } | Select-Object -First 1
        if ($origEntry) { $origFps = [int]$origEntry.Fps; $origBw = [int]$origEntry.BitrateMbps }
    }

    $newFps = $curFps; $newBw = $curBw
    switch ($Direction) {
        'down' {
            # Step 2 (align to lowest in the cohort) + Step 3 (downscale step%)
            $alignedFps = if ($LowestFps -gt 0) { $LowestFps } else { $curFps }
            $alignedBw  = if ($LowestBw  -gt 0) { $LowestBw }  else { $curBw }
            $newFps = Get-RoundedFpsDown -Value ([int][Math]::Round($alignedFps * (1 - $Step))) -Step $FpsStep
            $newBw  = [int][Math]::Round($alignedBw * (1 - $Step))
            $newFps = Get-ClampedValue -Value $newFps -Min $global:VQA_MinFps         -Max $curFps
            $newBw  = Get-ClampedValue -Value $newBw  -Min $global:VQA_MinBitrateMbps -Max $curBw
        }
        'up' {
            $newFps = Get-RoundedFpsDown -Value ([int][Math]::Round($curFps * (1 + $Step))) -Step $FpsStep
            $newBw  = [int][Math]::Round($curBw * (1 + $Step))
            $newFps = Get-ClampedValue -Value $newFps -Min $curFps -Max $origFps
            $newBw  = Get-ClampedValue -Value $newBw  -Min $curBw  -Max $origBw
        }
    }

    return [PSCustomObject]@{
        Name              = $Headset.Name
        Model             = $Headset.Model
        OriginalFps       = $origFps
        OriginalBitrate   = $origBw
        CurrentFps        = $curFps
        CurrentBitrate    = $curBw
        RecommendedFps    = $newFps
        RecommendedBitrate= $newBw
        CurrentProfile    = $Headset.Profile
        RecommendedProfile= (ConvertTo-ScrcpyProfile -View $Headset.ParsedProfile.View -Eye $Headset.ParsedProfile.Eye -AudioDup $Headset.ParsedProfile.AudioDup -Fps $newFps -BitrateMbps $newBw)
    }
}


# Pure: compute the MediaMTX row. Returns @{OriginalFramerate; OriginalBitrate;
# CurrentFramerate; CurrentBitrate; RecommendedFramerate; RecommendedBitrate}.
function Get-VqaMediaMtxRecommendation {
    param(
        [Parameter(Mandatory)] $Current,        # @{Framerate; BitrateMbps}
        [Parameter(Mandatory)] [string]$Direction,
        [Parameter(Mandatory)] [double]$Step,
        [Parameter(Mandatory)] [int]$FpsStep,
        $Originals
    )
    $mtxBw     = [int]$Current.BitrateMbps
    $mtxFps    = [int]$Current.Framerate
    $mtxOrigBw  = $mtxBw; $mtxOrigFps = $mtxFps
    if ($Originals -and $Originals.MediaMtx) {
        $mtxOrigBw  = [int]$Originals.MediaMtx.BitrateMbps
        $mtxOrigFps = [int]$Originals.MediaMtx.Framerate
    }
    $mtxNewBw  = $mtxBw; $mtxNewFps = $mtxFps
    switch ($Direction) {
        'down' {
            $mtxNewBw  = Get-ClampedValue -Value ([int][Math]::Round($mtxBw  * (1 - $Step))) -Min $global:VQA_MinBitrateMbps -Max $mtxBw
            $mtxNewFps = Get-RoundedFpsDown -Value ([int][Math]::Round($mtxFps * (1 - $Step))) -Step $FpsStep
            $mtxNewFps = Get-ClampedValue -Value $mtxNewFps -Min $global:VQA_MinFps -Max $mtxFps
        }
        'up' {
            $mtxNewBw  = Get-ClampedValue -Value ([int][Math]::Round($mtxBw  * (1 + $Step))) -Min $mtxBw -Max $mtxOrigBw
            $mtxNewFps = Get-RoundedFpsDown -Value ([int][Math]::Round($mtxFps * (1 + $Step))) -Step $FpsStep
            $mtxNewFps = Get-ClampedValue -Value $mtxNewFps -Min $mtxFps -Max $mtxOrigFps
        }
    }
    return [PSCustomObject]@{
        OriginalFramerate   = $mtxOrigFps
        OriginalBitrate     = $mtxOrigBw
        CurrentFramerate    = $mtxFps
        CurrentBitrate      = $mtxBw
        RecommendedFramerate= $mtxNewFps
        RecommendedBitrate  = $mtxNewBw
    }
}


# Orchestrator. Reads inputs, picks direction, builds rows via the three pure
# helpers above, writes the recommendation JSON + history row. When direction
# is 'none' the helpers naturally return Recommended==Current rows (no math),
# so the UI tables stay populated with current values.
function Invoke-VideoQualityRecommendation {
    $inputs = Get-VqaInputs
    if (-not $inputs) {
        Write-Log "VQR: no computer_monitoring snapshot, skipping." -Level DEBUG
        return $null
    }

    # Decrement the post-change cooldown counter once per VQR cycle. The web UI
    # uses CooldownRemaining > 0 to suppress warnings, and VQO short-circuits
    # while the cooldown is active.
    $cooldownRemaining = Step-VqaCooldown

    # CPU = LoadPercent. GPU = max Load3DPercent across adapters (worst case).
    $cpu = if ($inputs.Snapshot.CPU -and $null -ne $inputs.Snapshot.CPU.LoadPercent) { [int]$inputs.Snapshot.CPU.LoadPercent } else { 0 }
    $gpu = 0
    if ($inputs.Snapshot.GPU) {
        foreach ($g in @($inputs.Snapshot.GPU)) {
            if ($null -ne $g.Load3DPercent -and [int]$g.Load3DPercent -gt $gpu) { $gpu = [int]$g.Load3DPercent }
        }
    }

    $direction = Get-VqaDirection -Cpu $cpu -Gpu $gpu
    $step      = [double]$global:VQA_DownscaleStepPercent / 100.0
    $fpsStep   = $global:VQA_FpsRoundStep

    # Load originals (if a previous apply has happened) for upscale ceilings.
    $originals = $null
    if (Test-Path -LiteralPath $global:VQA_OriginalsFilePath) {
        try { $originals = Get-Content -LiteralPath $global:VQA_OriginalsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $originals = $null }
    }

    # Profiles
    $profileRows = @()
    foreach ($p in $inputs.Profiles) {
        $profileRows += Get-VqaProfileRecommendation -Profile $p -Direction $direction -Step $step -Originals $originals
    }

    # Headsets - cohort alignment first (step 2 of mitigation pipeline)
    $lowestFps = 0; $lowestBw = 0
    foreach ($h in $inputs.Headsets) {
        if ($h.ParsedProfile) {
            if ($lowestFps -eq 0 -or $h.ParsedProfile.Fps         -lt $lowestFps) { $lowestFps = [int]$h.ParsedProfile.Fps }
            if ($lowestBw  -eq 0 -or $h.ParsedProfile.BitrateMbps -lt $lowestBw)  { $lowestBw  = [int]$h.ParsedProfile.BitrateMbps }
        }
    }
    $headsetRows = @()
    foreach ($h in $inputs.Headsets) {
        $row = Get-VqaHeadsetRecommendation -Headset $h -Direction $direction -Step $step `
            -FpsStep $fpsStep -LowestFps $lowestFps -LowestBw $lowestBw -Originals $originals
        if ($row) { $headsetRows += $row }
    }

    # MediaMTX
    $mtxRow = Get-VqaMediaMtxRecommendation -Current $inputs.MediaMtx -Direction $direction `
        -Step $step -FpsStep $fpsStep -Originals $originals

    $reason = "CPU=${cpu}% GPU=${gpu}% (mitigation: cpu>=$($global:VQA_CpuMitigationThreshold) or gpu>=$($global:VQA_GpuMitigationThreshold))"

    $rec = [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Direction    = $direction
        Reason       = $reason
        Cpu          = $cpu
        Gpu          = $gpu
        ScrcpyCount  = $inputs.Headsets.Count
        ClientCount  = $inputs.ClientCount
        Thresholds   = [PSCustomObject]@{
            CpuMax        = $global:VQA_CpuMaxThreshold
            GpuMax        = $global:VQA_GpuMaxThreshold
            CpuMitigation = $global:VQA_CpuMitigationThreshold
            GpuMitigation = $global:VQA_GpuMitigationThreshold
        }
        Profiles     = $profileRows
        Headsets     = $headsetRows
        MediaMtx     = $mtxRow
        # Auto-apply state + cooldown - consumed by the web UI and topbar chip.
        AutoApplyProfiles  = [bool]$global:VQA_AutoApplyProfiles
        AutoApplyHeadsets  = [bool]$global:VQA_AutoApplyHeadsets
        AutoApplyMediaMtx  = [bool]$global:VQA_AutoApplyMediaMtx
        # Derived header badge state (ON if any section is ON).
        VqoEnabled         = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
        CooldownRemaining  = [int]$cooldownRemaining
    }

    try {
        Write-FileWithoutBom -Path $global:VQA_RecommendationFilePath -Content ($rec | ConvertTo-Json -Depth 6)
        Add-VqaHistoryRow -Rec $rec
    } catch {
        Write-Log ("VQR: failed to write recommendation: " + $_.Exception.Message) -Level WARNING
    }

    Write-Log ("VQR: direction=$direction cpu=${cpu}% gpu=${gpu}% scrcpy=$($inputs.Headsets.Count) clients=$($inputs.ClientCount)") -Level DEBUG
    return $rec
}


# Append one row to vqa_history.csv. Header is created on first write; the file
# is truncated to a header-only state by Initialize-VideoQualityAutomation at
# startup, so history is per-session.
function Add-VqaHistoryRow {
    param($Rec)
    $header = "Timestamp;CpuPct;GpuPct;ScrcpyCount;ClientCount;Direction;Reason;Json"
    if (-not (Test-Path -LiteralPath $global:VQA_HistoryFilePath)) {
        Write-FileWithoutBom -Path $global:VQA_HistoryFilePath -Content ($header + "`r`n")
    }
    $json = ($Rec | ConvertTo-Json -Depth 6 -Compress) -replace '"', '""'
    $line = "{0};{1};{2};{3};{4};{5};{6};""{7}""`r`n" -f `
        $Rec.Timestamp, $Rec.Cpu, $Rec.Gpu, $Rec.ScrcpyCount, $Rec.ClientCount, $Rec.Direction, ($Rec.Reason -replace ';', ','), $json
    # PS5 Add-Content -Encoding UTF8 prepends a BOM to every appended write,
    # which would scatter BOM bytes across the CSV. Append via .NET directly
    # with explicit no-BOM encoding.
    [System.IO.File]::AppendAllText($global:VQA_HistoryFilePath, $line, [System.Text.UTF8Encoding]::new($false))
}


###############################################################
# VQO - VIDEO QUALITY OPTIMIZER (auto-applier)
###############################################################


# Read the last $count rows from vqa_history.csv. Returns @() if fewer rows
# than requested exist (so VQO waits until the buffer is full).
function Get-LastVqaHistoryRows {
    param([int]$Count)
    if (-not (Test-Path -LiteralPath $global:VQA_HistoryFilePath)) { return @() }
    $expectedHeader = "Timestamp;CpuPct;GpuPct;ScrcpyCount;ClientCount;Direction;Reason;Json"
    $all = @(Get-Content -LiteralPath $global:VQA_HistoryFilePath -Encoding UTF8)
    if ($all.Count -eq 0 -or $all[0] -ne $expectedHeader) {
        Write-Log "VQR: history file header missing or malformed, resetting." -Level WARNING
        Write-FileWithoutBom -Path $global:VQA_HistoryFilePath -Content ($expectedHeader + "`r`n")
        return @()
    }
    $rows = @($all | Select-Object -Skip 1)
    if ($rows.Count -lt $Count) { return @() }
    return @($rows | Select-Object -Last $Count)
}


###############################################################
# COOLDOWN
# After any apply (manual, VQO, restore) or any auto-apply flag toggle, the
# system must settle. Until VQA_CooldownCycles brand-new VQR cycles have run,
# warnings are suppressed in the UI and VQO does not auto-apply.
###############################################################


# Persist a fresh cooldown counter (= VQA_CooldownCycles). Called whenever the
# system mutates so VQR is "quiet" for the next N cycles.
function Start-VqaCooldown {
    $n = [int]$global:VQA_CooldownCycles
    if ($n -lt 1) {
        # Cooldown disabled by config - remove any stale file so the UI/VQO see 0.
        Remove-Item -LiteralPath $global:VQA_CooldownFilePath -Force -ErrorAction SilentlyContinue
        return
    }
    $obj = [PSCustomObject]@{ RemainingCycles = $n; StartedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss") }
    Write-FileWithoutBom -Path $global:VQA_CooldownFilePath -Content ($obj | ConvertTo-Json -Compress)
}


# Patches CooldownRemaining in the existing vqa_recommendation.json in place so
# the web UI reflects a freshly-armed cooldown on its very next poll, instead
# of waiting for the next full VQR cycle (which only runs on the VRMonitor
# slow loop and can be tens of seconds to minutes away). No-op if the
# recommendation file does not exist yet (e.g. very first apply of a session).
function Set-VqaRecommendationCooldown {
    if (-not (Test-Path -LiteralPath $global:VQA_RecommendationFilePath)) { return }
    try {
        $rec = Get-Content -LiteralPath $global:VQA_RecommendationFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $rec.CooldownRemaining = Get-VqaCooldownRemaining
        Write-FileWithoutBom -Path $global:VQA_RecommendationFilePath -Content ($rec | ConvertTo-Json -Depth 6)
    } catch {
        Write-Log ("VQA: failed to patch recommendation cooldown: " + $_.Exception.Message) -Level WARNING
    }
}


# Read the remaining cooldown counter (0 when no cooldown is active).
function Get-VqaCooldownRemaining {
    if (-not (Test-Path -LiteralPath $global:VQA_CooldownFilePath)) { return 0 }
    try { return [int](Get-Content -LiteralPath $global:VQA_CooldownFilePath -Raw -Encoding UTF8 | ConvertFrom-Json).RemainingCycles } catch { return 0 }
}


# Called once at the top of every VQR cycle. Decrements the counter, deletes
# the file when it reaches 0, returns the post-decrement value (so the
# recommendation JSON can carry it).
function Step-VqaCooldown {
    # Short timeout: if another process holds the lock, skip this decrement -
    # the next VQR cycle will catch up. Contention is non-fatal here.
    $lock = Enter-VqaLock -TimeoutMs 500
    if (-not $lock) { return (Get-VqaCooldownRemaining) }
    try {
        $remaining = Get-VqaCooldownRemaining
        if ($remaining -le 0) { return 0 }
        $remaining = $remaining - 1
        if ($remaining -le 0) {
            Remove-Item -LiteralPath $global:VQA_CooldownFilePath -Force -ErrorAction SilentlyContinue
            return 0
        }
        $obj = [PSCustomObject]@{ RemainingCycles = $remaining; StartedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss") }
        Write-FileWithoutBom -Path $global:VQA_CooldownFilePath -Content ($obj | ConvertTo-Json -Compress)
        return $remaining
    } finally {
        Exit-VqaLock -Stream $lock
    }
}


###############################################################
# PER-SECTION AUTO-APPLY TOGGLE
###############################################################


# Persist a per-section auto-apply flag to config.json, refresh the global,
# update the derived $global:VQA_EnabledVQO, and arm the cooldown.
# Used by the console sub-menu and the web API /api/vqa/toggle-auto-apply.
function Set-VqaAutoApply {
    param(
        [Parameter(Mandatory)] [ValidateSet('profiles','headsets','mediamtx')] [string]$Section,
        [Parameter(Mandatory)] [bool]$Enabled
    )
    $cfgPath = Join-Path $global:ScriptPath 'config\config.json'
    $cfg = Read-ConfigJson -ConfigFilePath $cfgPath -NonInteractive
    if (-not $cfg -or -not $cfg.VideoQualityAutomation) {
        Write-Log "VQA: cannot toggle auto-apply, config.json unreadable." -Level ERROR
        return $false
    }
    switch ($Section) {
        'profiles' {
            if ($cfg.VideoQualityAutomation.PSObject.Properties.Name -contains 'auto_apply_profiles') {
                $cfg.VideoQualityAutomation.auto_apply_profiles = $Enabled
            } else {
                $cfg.VideoQualityAutomation | Add-Member -MemberType NoteProperty -Name 'auto_apply_profiles' -Value $Enabled
            }
            $global:VQA_AutoApplyProfiles = $Enabled
        }
        'headsets' {
            if ($cfg.VideoQualityAutomation.PSObject.Properties.Name -contains 'auto_apply_headsets') {
                $cfg.VideoQualityAutomation.auto_apply_headsets = $Enabled
            } else {
                $cfg.VideoQualityAutomation | Add-Member -MemberType NoteProperty -Name 'auto_apply_headsets' -Value $Enabled
            }
            $global:VQA_AutoApplyHeadsets = $Enabled
        }
        'mediamtx' {
            if ($cfg.VideoQualityAutomation.PSObject.Properties.Name -contains 'auto_apply_mediamtx') {
                $cfg.VideoQualityAutomation.auto_apply_mediamtx = $Enabled
            } else {
                $cfg.VideoQualityAutomation | Add-Member -MemberType NoteProperty -Name 'auto_apply_mediamtx' -Value $Enabled
            }
            $global:VQA_AutoApplyMediaMtx = $Enabled
        }
    }
    Write-FileWithoutBom -Path $cfgPath -Content (($cfg | ConvertTo-Json -Depth 12))
    $global:VQA_EnabledVQO = ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)
    Write-Log ("VQA: auto_apply_$Section set to $Enabled.") -Level INFO
    return $true
}


# Auto-applier. Runs only when at least one per-section flag is true, the
# cooldown is over, AND the last N history rows all agreed on 'down'.
# Upsize ('up') and 'none' never trigger auto-apply - operators apply upsize
# manually to avoid the up/down ping-pong loop around the mitigation threshold.
function Invoke-VideoQualityOptimizer {
    if (-not ($global:VQA_AutoApplyProfiles -or $global:VQA_AutoApplyHeadsets -or $global:VQA_AutoApplyMediaMtx)) { return }
    if ((Get-VqaCooldownRemaining) -gt 0) { return }

    $n = [int]$global:VQA_VqoConsecutiveCount
    if ($n -lt 1) {
        # Misconfigured (missing or zero). Use a sane default and log ONCE per
        # session so the operator notices but the log isn't spammed each cycle.
        if (-not $script:VqaVqoCountFallbackWarned) {
            Write-Log ("VQO: VQA_VqoConsecutiveCount is $n; using fallback of 5. Set vqo_consecutive_count in config.json.") -Level WARNING
            $script:VqaVqoCountFallbackWarned = $true
        }
        $n = 5
    }
    $rows = Get-LastVqaHistoryRows -Count $n
    if ($rows.Count -lt $n) { return }

    # Column 6 (0-indexed 5) = Direction. Every row must be 'down'.
    foreach ($d in ($rows | ForEach-Object { ($_ -split ';')[5] })) {
        if ($d -ne 'down') { return }
    }

    Write-Log ("VQO: $n consecutive 'down' recommendations - auto-applying enabled sections.") -Level INFO
    try {
        # Single coalesced call so config.json is written once and mediamtx
        # restarts at most once per cycle. Invoke-VqaApply uses SectionFilter to
        # skip sections whose per-section flag is off.
        Invoke-VqaApply -Scope 'all' -SectionFilter @{
            Profiles = $global:VQA_AutoApplyProfiles
            Headsets = $global:VQA_AutoApplyHeadsets
            MediaMtx = $global:VQA_AutoApplyMediaMtx
        } | Out-Null
    } catch {
        Write-Log ("VQO: apply failed: " + $_.Exception.Message) -Level ERROR
    }
}


###############################################################
# APPLY / RESTORE
###############################################################


# Returns the latest recommendation object (parsed JSON) or $null.
function Get-LatestVqaRecommendation {
    if (-not (Test-Path -LiteralPath $global:VQA_RecommendationFilePath)) { return $null }
    try { return Get-Content -LiteralPath $global:VQA_RecommendationFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}


# Per-field baseline merge. Captures the CURRENT (pre-mutation) value of each
# field listed in $Applied that does NOT already have a baseline entry; existing
# entries are never overwritten so the snapshot always reflects the operator's
# original ceiling, even across multiple apply cycles.
#
# This is the Phase 2 fix for the "restore pushes 480 instead of 0" bug: a
# whole-config snapshot captured at first-apply was poisoned whenever config had
# already been mutated by a crashed earlier session. With per-field lazy capture
# triggered only when a field is about to change, each field's baseline equals
# its true pre-mutation value (as long as the previous session restored cleanly
# - which Phase 1's success tracking enforces).
function Save-VqaBaseline {
    param(
        # Hashtable describing the imminent mutation. Same shape as the $applied
        # hashtable built by Invoke-VqaApply.
        [Parameter(Mandatory)] $Applied
    )
    # NOTE: Caller (Invoke-VqaApply) already holds Enter-VqaLock. Do NOT acquire
    # it here - FileShare.None means re-entry would deadlock.
    $cfg = Read-ConfigJson -ConfigFilePath (Join-Path $global:ScriptPath 'config\config.json') -NonInteractive
    if (-not $cfg) {
        Write-Log "VQA: cannot read config.json for baseline snapshot." -Level ERROR
        return
    }

    # Load existing baseline (if any) so we merge instead of overwriting captured fields.
    $existing = $null
    if (Test-Path -LiteralPath $global:VQA_OriginalsFilePath) {
        try { $existing = Get-Content -LiteralPath $global:VQA_OriginalsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $existing = $null }
    }
    $mergedProfiles = @{}
    $mergedHeadsets = @{}
    $mergedMtx      = $null
    if ($existing) {
        if ($existing.Profiles) { foreach ($p in @($existing.Profiles)) { $mergedProfiles[$p.Model] = $p } }
        if ($existing.Headsets) { foreach ($h in @($existing.Headsets)) { $mergedHeadsets[$h.Name] = $h } }
        if ($existing.MediaMtx) { $mergedMtx = $existing.MediaMtx }
    }

    $captured = @()

    foreach ($p in @($Applied.Profiles)) {
        if ($mergedProfiles.ContainsKey($p.Model)) { continue }
        if ($cfg.scrcpy.parameters.PSObject.Properties.Name -notcontains $p.Model) { continue }
        $curMax = [int]$cfg.scrcpy.parameters.($p.Model).max_size
        $mergedProfiles[$p.Model] = [PSCustomObject]@{ Model = $p.Model; MaxSize = $curMax }
        $captured += "$($p.Model)=$curMax"
    }

    foreach ($h in @($Applied.Headsets)) {
        if ($mergedHeadsets.ContainsKey($h.Name)) { continue }
        $row = Get-KnownHeadsets | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
        if (-not $row) { continue }
        $parsed = ConvertFrom-ScrcpyProfile -Profile $row.ScrcpyProfile
        if (-not $parsed) { continue }
        $mergedHeadsets[$h.Name] = [PSCustomObject]@{
            Name        = $h.Name
            Profile     = $row.ScrcpyProfile
            Fps         = [int]$parsed.Fps
            BitrateMbps = [int]$parsed.BitrateMbps
        }
        $captured += "$($h.Name)=$($row.ScrcpyProfile)"
    }

    if ($Applied.MediaMtx -and -not $mergedMtx) {
        $curFps = if ($cfg.mediamtx -and $cfg.mediamtx.stream_framerate) { [int]$cfg.mediamtx.stream_framerate } else { 0 }
        $curBw  = 0
        if ($cfg.mediamtx -and $cfg.mediamtx.stream_bitrate) {
            $digits = ([string]$cfg.mediamtx.stream_bitrate) -replace '[^\d]', ''
            if ($digits) { $curBw = [int]$digits }
        }
        $mergedMtx = [PSCustomObject]@{ Framerate = $curFps; BitrateMbps = $curBw }
        $captured += "MediaMtx=${curFps}fps/${curBw}M"
    }

    if ($captured.Count -eq 0) { return }   # nothing new to capture

    $snap = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Profiles  = @($mergedProfiles.Values)
        Headsets  = @($mergedHeadsets.Values)
        MediaMtx  = $mergedMtx
    }
    Write-FileWithoutBom -Path $global:VQA_OriginalsFilePath -Content ($snap | ConvertTo-Json -Depth 5)
    Write-Log ("VQA: baseline merged. Captured: [" + ($captured -join ', ') + "].") -Level INFO
}


# Apply the latest recommendation. Scope filters which parts to push:
#   all      - profiles + all headsets + mediamtx
#   profile  - only the profile whose Model matches $Target
#   headset  - only the headset whose Name matches $Target
#   mediamtx - only mediamtx framerate / bitrate
# Writes vqa_applied.json describing exactly which fields we changed, so
# Restore-VqaOriginals can detect operator manual edits afterwards.
function Invoke-VqaApply {
    param(
        [ValidateSet('all','profile','headset','mediamtx')]
        [string]$Scope = 'all',
        [string]$Target = '',
        # When VQO runs with mixed per-section flags, it passes which sections are
        # actually enabled so we can do the work in one pass (single config write,
        # single mediamtx restart). Manual web/console callers leave this $null.
        [hashtable]$SectionFilter = $null
    )

    $lock = Enter-VqaLock
    if (-not $lock) {
        Write-Log "VQA: another apply is in progress, skipping." -Level WARNING
        return $false
    }
    try {
        $rec = Get-LatestVqaRecommendation
        if (-not $rec) { Write-Log "VQA: no recommendation to apply." -Level WARNING; return $false }
        if ($rec.Direction -eq 'none') { Write-Log "VQA: recommendation is 'none', nothing to apply." -Level INFO; return $false }

        # Resolve which section is in scope. SectionFilter (when supplied) further
        # narrows things so VQO can call once with -Scope all + filter rather than
        # 3x with one scope each.
        $doProfiles = ($Scope -eq 'all' -or $Scope -eq 'profile')  -and ($null -eq $SectionFilter -or [bool]$SectionFilter.Profiles)
        $doHeadsets = ($Scope -eq 'all' -or $Scope -eq 'headset')  -and ($null -eq $SectionFilter -or [bool]$SectionFilter.Headsets)
        $doMtx      = ($Scope -eq 'all' -or $Scope -eq 'mediamtx') -and ($null -eq $SectionFilter -or [bool]$SectionFilter.MediaMtx)

        $configPath = Join-Path $global:ScriptPath 'config\config.json'
        $cfg = Read-ConfigJson -ConfigFilePath $configPath -NonInteractive
        if (-not $cfg) { Write-Log "VQA: cannot read config.json for apply." -Level ERROR; return $false }

        # ---- PASS 1: compute what would change. Pure - no side effects. ----
        $applied = @{
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
            Profiles  = @()
            Headsets  = @()
            MediaMtx  = $null
        }
        $restartProcs = @()

        if ($doProfiles) {
            foreach ($p in $rec.Profiles) {
                if ($Scope -eq 'profile' -and $Target -and $p.Model -ne $Target) { continue }
                if ([int]$p.Recommended -eq [int]$p.Current) { continue }
                if ($cfg.scrcpy.parameters.PSObject.Properties.Name -contains $p.Model) {
                    $applied.Profiles += [PSCustomObject]@{ Model = $p.Model; MaxSize = [int]$p.Recommended }
                    foreach ($h in $rec.Headsets) {
                        if ($h.Model -eq $p.Model -and ($restartProcs -notcontains $h.Name)) { $restartProcs += $h.Name }
                    }
                }
            }
        }

        if ($doMtx) {
            $newFps = [int]$rec.MediaMtx.RecommendedFramerate
            $newBw  = [int]$rec.MediaMtx.RecommendedBitrate
            $curFps = [int]$rec.MediaMtx.CurrentFramerate
            $curBw  = [int]$rec.MediaMtx.CurrentBitrate
            if ($newFps -ne $curFps -or $newBw -ne $curBw) {
                $applied.MediaMtx = [PSCustomObject]@{ Framerate = $newFps; BitrateMbps = $newBw }
            }
        }

        if ($doHeadsets) {
            $allHeads = @(Get-KnownHeadsets)
            foreach ($h in $rec.Headsets) {
                if ($Scope -eq 'headset' -and $Target -and $h.Name -ne $Target) { continue }
                if ($h.RecommendedProfile -eq $h.CurrentProfile) { continue }
                $row = $allHeads | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
                if (-not $row) { continue }
                $applied.Headsets += [PSCustomObject]@{
                    Name    = $h.Name
                    Profile = $h.RecommendedProfile
                    _Id     = [int]$row.ID    # carry through so PASS 2 doesn't need a second lookup
                }
                if ($restartProcs -notcontains $h.Name) { $restartProcs += $h.Name }
            }
        }

        $mutated = ($applied.Profiles.Count -gt 0) -or ($applied.Headsets.Count -gt 0) -or ($null -ne $applied.MediaMtx)
        if (-not $mutated) {
            Write-Log "VQA: recommendation matches current state, nothing to apply." -Level INFO
            return $false
        }

        # ---- Snapshot baseline (per-field, lazy) before any mutation ----
        # Save-VqaBaseline captures only fields not already in baseline, using
        # their CURRENT pre-mutation value. Safe to call every apply.
        Save-VqaBaseline -Applied $applied

        # ---- PASS 2: write mutations to disk ----
        $restartMtx = $false
        foreach ($p in $applied.Profiles) {
            $cfg.scrcpy.parameters.($p.Model).max_size = [int]$p.MaxSize
        }
        if ($applied.MediaMtx) {
            $cfg.mediamtx.stream_framerate = [int]$applied.MediaMtx.Framerate
            $cfg.mediamtx.stream_bitrate   = ("{0}M" -f [int]$applied.MediaMtx.BitrateMbps)
            $restartMtx = $true
        }
        if ($applied.Profiles.Count -gt 0 -or $applied.MediaMtx) {
            Write-FileWithoutBom -Path $configPath -Content (($cfg | ConvertTo-Json -Depth 12))
            try { Get-Config -ConfigFilePath $configPath | Out-Null } catch { }
        }

        foreach ($h in $applied.Headsets) {
            try {
                Update-HeadsetField -ID ([int]$h._Id) -Field 'ScrcpyProfile' -NewValue $h.Profile | Out-Null
            } catch {
                Write-Log ("VQA: failed to update " + $h.Name + ": " + $_.Exception.Message) -Level WARNING
            }
        }

        # Strip the internal _Id field before persisting applied.json
        $appliedToWrite = @{
            Timestamp = $applied.Timestamp
            Profiles  = $applied.Profiles
            Headsets  = @($applied.Headsets | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Profile = $_.Profile } })
            MediaMtx  = $applied.MediaMtx
        }
        Write-FileWithoutBom -Path $global:VQA_AppliedFilePath -Content ($appliedToWrite | ConvertTo-Json -Depth 5)

        # mediamtx never reads stream_framerate/stream_bitrate - only
        # Start-FfmpegStreamPush does. So a mediamtx-only change does not need
        # mediamtx restarted, it needs every currently-running ffmpeg pusher
        # bounced so it re-reads the new globals. Restarting mediamtx here
        # would sever their RTSP sockets underneath them (broken pipe / HEVC
        # POC corruption) for no benefit.
        if ($restartMtx) {
            foreach ($row in (Get-KnownHeadsets)) {
                $safe = Convert-Displayname $row.Name
                if ((Get-ScrcpyProcess -displayName $safe -headsetIP $row.IPAddress) -and ($restartProcs -notcontains $row.Name)) {
                    $restartProcs += $row.Name
                }
            }
        }

        # -- Restart affected scrcpy sessions
        foreach ($name in $restartProcs) {
            try {
                $row = Get-KnownHeadsets | Where-Object { $_.Name -eq $name } | Select-Object -First 1
                if ($row) {
                    Stop-Scrcpy -HeadsetName $name -HeadsetIP $row.IPAddress | Out-Null
                    Start-Sleep -Milliseconds 500
                    start-screenCopy -headsetIP $row.IPAddress -displayName $row.Name -scrcpyProfile $row.ScrcpyProfile
                }
            } catch {
                Write-Log ("VQA: failed to restart scrcpy for $name " + $_.Exception.Message) -Level WARNING
            }
        }

        Write-Log ($msg.VqaRecommendationApplied -f $rec.Direction) -Level SUCCESS
        Start-VqaCooldown
        Set-VqaRecommendationCooldown
        # Drop the cross-process flag read by the VRMonitor loop's
        # Update-ComputerMonitoring so CPU/GPU stats refresh within seconds
        # instead of waiting for the next throttled cycle - the UI uses those
        # numbers to colour the VQA bars and headroom indicators.
        try { [System.IO.File]::WriteAllText((Join-Path $global:ScriptPath 'data\computer_monitoring_forcerefresh.flag'), '') } catch { }
        return $true
    } finally {
        Exit-VqaLock -Stream $lock
    }
}


# Restore baseline values, skipping any field the operator has manually edited
# since we wrote it. Detection: if the current value still equals what we wrote
# (recorded in vqa_applied.json), the operator did not touch it -> safe to
# revert. Otherwise leave it alone.
function Restore-VqaOriginals {
    if (-not (Test-Path -LiteralPath $global:VQA_OriginalsFilePath)) { return $false }

    $lock = Enter-VqaLock
    if (-not $lock) {
        Write-Log "VQA: restore skipped, another VQA operation is in progress." -Level WARNING
        return $false
    }
    try {

    $orig = $null; $applied = $null
    try { $orig    = Get-Content -LiteralPath $global:VQA_OriginalsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (Test-Path -LiteralPath $global:VQA_AppliedFilePath) {
        try { $applied = Get-Content -LiteralPath $global:VQA_AppliedFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (-not $orig) { return $false }

    $configPath = Join-Path $global:ScriptPath 'config\config.json'
    $cfg = Read-ConfigJson -ConfigFilePath $configPath -NonInteractive
    if (-not $cfg) { Write-Log "VQA: cannot read config.json for restore." -Level ERROR; return $false }
    $configChanged = $false
    $restartMtx    = $false
    # M8: track failures. If anything throws, keep originals/applied files so the
    # operator can diagnose and retry.
    $errCount = 0

    # -- Profiles (single int per model; full-field operator-edit check)
    if ($orig.Profiles -and $cfg.scrcpy -and $cfg.scrcpy.parameters) {
        foreach ($p in $orig.Profiles) {
            if (-not ($cfg.scrcpy.parameters.PSObject.Properties.Name -contains $p.Model)) { continue }
            $curVal = [int]$cfg.scrcpy.parameters.($p.Model).max_size
            $appliedVal = $null
            if ($applied -and $applied.Profiles) {
                $a = $applied.Profiles | Where-Object { $_.Model -eq $p.Model } | Select-Object -First 1
                if ($a) { $appliedVal = [int]$a.MaxSize }
            }
            # Restore only if the operator has not edited the field since our apply.
            if ($null -eq $appliedVal -or $curVal -eq $appliedVal) {
                if ($curVal -ne [int]$p.MaxSize) {
                    $cfg.scrcpy.parameters.($p.Model).max_size = [int]$p.MaxSize
                    $configChanged = $true
                }
            }
        }
    }

    # -- MediaMTX (already per-field)
    if ($orig.MediaMtx) {
        $curFps = [int]$cfg.mediamtx.stream_framerate
        $curBwStr = [string]$cfg.mediamtx.stream_bitrate
        $curBw = 0
        $bwDigits = $curBwStr -replace '[^\d]', ''
        if ($bwDigits) { $curBw = [int]$bwDigits }
        $appliedMtx = if ($applied) { $applied.MediaMtx } else { $null }
        $operatorEditedFps = ($appliedMtx -and [int]$appliedMtx.Framerate   -ne $curFps)
        $operatorEditedBw  = ($appliedMtx -and [int]$appliedMtx.BitrateMbps -ne $curBw)
        if (-not $appliedMtx -or -not $operatorEditedFps) {
            if ($curFps -ne [int]$orig.MediaMtx.Framerate) { $cfg.mediamtx.stream_framerate = [int]$orig.MediaMtx.Framerate; $configChanged = $true; $restartMtx = $true }
        }
        if (-not $appliedMtx -or -not $operatorEditedBw) {
            $origBw = [int]$orig.MediaMtx.BitrateMbps
            if ($curBw -ne $origBw) { $cfg.mediamtx.stream_bitrate = "${origBw}M"; $configChanged = $true; $restartMtx = $true }
        }
    }

    if ($configChanged) {
        try {
            Write-FileWithoutBom -Path $configPath -Content (($cfg | ConvertTo-Json -Depth 12))
            try { Get-Config -ConfigFilePath $configPath | Out-Null } catch { }
        } catch {
            Write-Log ("VQA restore: config.json write failed: " + $_.Exception.Message) -Level ERROR
            $errCount++
        }
    }

    # -- Headsets (per-field operator-edit detection)
    # ScrcpyProfile is "view-EYE-AUDIO-FPS-BW". A whole-string compare misses
    # partial operator edits (e.g., FPS changed while other fields match VQA's
    # last write). Parse all three (baseline / applied / current) and decide per
    # field; rebuild the profile string from the merged result.
    $restartProcs = @()
    if ($orig.Headsets) {
        foreach ($h in $orig.Headsets) {
            $row = Get-KnownHeadsets | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
            if (-not $row) { continue }

            $baseline = ConvertFrom-ScrcpyProfile -Profile $h.Profile
            $current  = ConvertFrom-ScrcpyProfile -Profile $row.ScrcpyProfile
            if (-not $baseline -or -not $current) { continue }

            $appliedParsed = $null
            if ($applied -and $applied.Headsets) {
                $a = $applied.Headsets | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
                if ($a) { $appliedParsed = ConvertFrom-ScrcpyProfile -Profile $a.Profile }
            }

            # Per-field decision: keep current value if operator edited it
            # (current differs from what VQA last wrote); otherwise restore to
            # baseline. When no applied entry exists for this headset, restore
            # everything.
            $fields = @{
                View        = $current.View
                Eye         = $current.Eye
                AudioDup    = $current.AudioDup
                Fps         = $current.Fps
                BitrateMbps = $current.BitrateMbps
            }
            foreach ($f in @('View','Eye','AudioDup','Fps','BitrateMbps')) {
                $touched = $false
                if ($appliedParsed) {
                    if ($current.$f -ne $appliedParsed.$f) { $touched = $true }
                }
                if (-not $touched) { $fields[$f] = $baseline.$f }
            }

            $newProfile = ConvertTo-ScrcpyProfile `
                -View $fields.View -Eye $fields.Eye -AudioDup $fields.AudioDup `
                -Fps $fields.Fps -BitrateMbps $fields.BitrateMbps

            if ($newProfile -ne $row.ScrcpyProfile) {
                try {
                    Update-HeadsetField -ID ([int]$row.ID) -Field 'ScrcpyProfile' -NewValue $newProfile | Out-Null
                    $restartProcs += $h.Name
                } catch {
                    Write-Log ("VQA restore: failed to update " + $h.Name + ": " + $_.Exception.Message) -Level WARNING
                    $errCount++
                }
            }
        }
    }

    foreach ($name in $restartProcs) {
        try {
            $row = Get-KnownHeadsets | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($row -and (Get-ScrcpyProcess -displayName ($row.Name -replace ' ','_') -headsetIP $row.IPAddress)) {
                Stop-Scrcpy -HeadsetName $name -HeadsetIP $row.IPAddress | Out-Null
                Start-Sleep -Milliseconds 500
                start-screenCopy -headsetIP $row.IPAddress -displayName $row.Name -scrcpyProfile $row.ScrcpyProfile
            }
        } catch {
            Write-Log ("VQA restore: scrcpy restart failed for $name`: " + $_.Exception.Message) -Level WARNING
            # scrcpy restart failure does not corrupt baseline; do not block file cleanup
        }
    }
    if ($restartMtx) {
        try { Stop-MediaMtx; Start-Sleep -Seconds 1; Start-MediaMtx } catch {
            Write-Log ("VQA restore: mediamtx restart failed: " + $_.Exception.Message) -Level WARNING
        }
    }

    if ($errCount -gt 0) {
        Write-Log ("VQA: restore PARTIAL ($errCount error(s)). Originals and applied files kept for retry.") -Level WARNING
        return $false
    }

    Remove-Item -LiteralPath $global:VQA_OriginalsFilePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $global:VQA_AppliedFilePath   -Force -ErrorAction SilentlyContinue
    Write-Log $msg.VqaRestored -Level SUCCESS
    # Restore is also a "system mutated" event - arm the cooldown so VQR/VQO
    # let the workload re-stabilise before reacting.
    Start-VqaCooldown
    Set-VqaRecommendationCooldown
    # Trigger immediate computer-monitoring refresh (cross-process flag read by
    # the VRMonitor loop). Without this the UI keeps showing stale CPU/GPU
    # numbers until the throttled cycle elapses.
    try { [System.IO.File]::WriteAllText((Join-Path $global:ScriptPath 'data\computer_monitoring_forcerefresh.flag'), '') } catch { }
    return $true

    } finally {
        Exit-VqaLock -Stream $lock
    }
}


# Public alias used by the web UI / console "Restore originals" button.
function Reset-VqaToOriginals { return Restore-VqaOriginals }


###############################################################
# STARTUP / SHUTDOWN HOOKS
###############################################################


# Called once at startup by scripts_init.ps1. Two responsibilities:
#   1. Crash-recovery: if vqa_originals.json exists from a previous run, the
#      app exited without going through Restore-VqaOriginals - revert now.
#   2. Reset per-session history (vqa_history.csv).
function Initialize-VideoQualityAutomation {
    if (Test-Path -LiteralPath $global:VQA_OriginalsFilePath) {
        Write-Log "VQA: orphan baseline detected from previous run, restoring." -Level WARNING
        $restoreOk = $false
        try { $restoreOk = [bool](Restore-VqaOriginals) } catch {
            Write-Log ("VQA: orphan restore threw: " + $_.Exception.Message) -Level ERROR
        }
        if (-not $restoreOk) {
            Write-Log "VQA: orphan restore FAILED. Leaving originals/applied/history in place for diagnosis. Manual fix required." -Level ERROR
            return
        }
    }
    # Per-session history: header only - only when restore succeeded (or was unnecessary).
    $header = "Timestamp;CpuPct;GpuPct;ScrcpyCount;ClientCount;Direction;Reason;Json"
    Write-FileWithoutBom -Path $global:VQA_HistoryFilePath -Content ($header + "`r`n")
    Write-Log $msg.VqaHistoryReset -Level DEBUG
}


