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
function _RoundFpsDown {
    param([int]$Value, [int]$Step = 5)
    if ($Value -le 0 -or $Step -le 0) { return 0 }
    return [int]([Math]::Floor($Value / $Step) * $Step)
}


# Clamp a value to [Min, Max]. Used to enforce min_fps / min_bitrate /
# min_max_size floors and "never above original baseline" ceilings.
function _Clamp {
    param([int]$Value, [int]$Min, [int]$Max)
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}


###############################################################
# INPUT GATHERING
###############################################################


# GET /v3/paths/list against the mediamtx HTTP API and sum readers across paths.
# Returns the total active reader count, or 0 if mediamtx is disabled, the API
# is unreachable, or the response cannot be parsed.
function Get-MediaMtxClientCount {
    if (-not $global:mediamtxEnabled) { return 0 }
    $port = $global:mediamtxApiPort
    if (-not $port) { return 0 }
    $url = "http://localhost:$port/v3/paths/list"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 2 -ErrorAction Stop
    } catch {
        return 0
    }
    $count = 0
    if ($resp -and $resp.items) {
        foreach ($p in $resp.items) {
            if ($p.readers) { $count += @($p.readers).Count }
        }
    }
    return [int]$count
}


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
    if ($global:scrcpyParameters) {
        foreach ($modelProp in $global:scrcpyParameters[0].PSObject.Properties) {
            $profiles += [PSCustomObject]@{
                Model   = $modelProp.Name
                MaxSize = [int]$modelProp.Value.max_size
            }
        }
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
function _GetVqaDirection {
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
function Invoke-VideoQualityRecommendation {
    $inputs = Get-VqaInputs
    if (-not $inputs) {
        Write-Log "VQR: no computer_monitoring snapshot, skipping." -Level DEBUG
        return $null
    }

    # Decrement the post-change cooldown counter once per VQR cycle. The web UI
    # uses CooldownRemaining > 0 to suppress warnings, and VQO short-circuits
    # while the cooldown is active.
    $cooldownRemaining = _DecrementVqaCooldown

    # CPU = LoadPercent. GPU = max Load3DPercent across adapters (worst case).
    $cpu = if ($inputs.Snapshot.CPU -and $null -ne $inputs.Snapshot.CPU.LoadPercent) { [int]$inputs.Snapshot.CPU.LoadPercent } else { 0 }
    $gpu = 0
    if ($inputs.Snapshot.GPU) {
        foreach ($g in @($inputs.Snapshot.GPU)) {
            if ($null -ne $g.Load3DPercent -and [int]$g.Load3DPercent -gt $gpu) { $gpu = [int]$g.Load3DPercent }
        }
    }

    $direction = _GetVqaDirection -Cpu $cpu -Gpu $gpu
    $step      = [double]$global:VQA_DownscaleStepPercent / 100.0
    $fpsStep   = $global:VQA_FpsRoundStep

    # Load originals (if a previous apply has happened) for upscale ceilings.
    $originals = $null
    if (Test-Path -LiteralPath $global:VQA_OriginalsFilePath) {
        try { $originals = Get-Content -LiteralPath $global:VQA_OriginalsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $originals = $null }
    }

    # ------- Profiles table (per scrcpy model) -------
    $profileRows = @()
    foreach ($p in $inputs.Profiles) {
        $current = [int]$p.MaxSize
        # Treat 0 (uncapped) as VQA_DefaultUncappedMaxSize for math only - the raw
        # operator value (often 0) is what we report in Original / Current so the
        # UI can render "uncapped" honestly.
        $effective = if ($current -eq 0) { [int]$global:VQA_DefaultUncappedMaxSize } else { $current }
        $original  = $current
        if ($originals -and $originals.Profiles) {
            $origEntry = $originals.Profiles | Where-Object { $_.Model -eq $p.Model } | Select-Object -First 1
            if ($origEntry) { $original = [int]$origEntry.MaxSize }
        }

        $recommended = $current
        switch ($direction) {
            'down' {
                $recommended = [int][Math]::Round($effective * (1 - $step))
                $recommended = _Clamp -Value $recommended -Min $global:VQA_MinMaxSize -Max $effective
            }
            'up' {
                $recommended = [int][Math]::Round($effective * (1 + $step))
                $ceiling = if ($original -gt 0) { $original } else { $effective }
                $recommended = _Clamp -Value $recommended -Min $effective -Max $ceiling
            }
        }
        $profileRows += [PSCustomObject]@{
            Model       = $p.Model
            Original    = $original
            Current     = $current
            Recommended = $recommended
        }
    }

    # ------- Headsets table (per running scrcpy session) -------
    # Step 2: find lowest currently-applied Fps and Bitrate across running headsets.
    $lowestFps = 0; $lowestBw = 0
    foreach ($h in $inputs.Headsets) {
        if ($h.ParsedProfile) {
            if ($lowestFps -eq 0 -or $h.ParsedProfile.Fps -lt $lowestFps)         { $lowestFps = [int]$h.ParsedProfile.Fps }
            if ($lowestBw  -eq 0 -or $h.ParsedProfile.BitrateMbps -lt $lowestBw)  { $lowestBw  = [int]$h.ParsedProfile.BitrateMbps }
        }
    }

    $headsetRows = @()
    foreach ($h in $inputs.Headsets) {
        if (-not $h.ParsedProfile) { continue }
        $curFps = [int]$h.ParsedProfile.Fps
        $curBw  = [int]$h.ParsedProfile.BitrateMbps
        $origFps = $curFps; $origBw = $curBw
        if ($originals -and $originals.Headsets) {
            $origEntry = $originals.Headsets | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
            if ($origEntry) { $origFps = [int]$origEntry.Fps; $origBw = [int]$origEntry.BitrateMbps }
        }

        $newFps = $curFps; $newBw = $curBw
        switch ($direction) {
            'down' {
                # Step 2 (align) + Step 3 (downscale step%)
                $alignedFps = if ($lowestFps -gt 0) { $lowestFps } else { $curFps }
                $alignedBw  = if ($lowestBw  -gt 0) { $lowestBw }  else { $curBw }
                $newFps = _RoundFpsDown -Value ([int][Math]::Round($alignedFps * (1 - $step))) -Step $fpsStep
                $newBw  = [int][Math]::Round($alignedBw * (1 - $step))
                $newFps = _Clamp -Value $newFps -Min $global:VQA_MinFps         -Max $curFps
                $newBw  = _Clamp -Value $newBw  -Min $global:VQA_MinBitrateMbps -Max $curBw
            }
            'up' {
                $newFps = _RoundFpsDown -Value ([int][Math]::Round($curFps * (1 + $step))) -Step $fpsStep
                $newBw  = [int][Math]::Round($curBw * (1 + $step))
                $newFps = _Clamp -Value $newFps -Min $curFps -Max $origFps
                $newBw  = _Clamp -Value $newBw  -Min $curBw  -Max $origBw
            }
        }

        $headsetRows += [PSCustomObject]@{
            Name              = $h.Name
            Model             = $h.Model
            OriginalFps       = $origFps
            OriginalBitrate   = $origBw
            CurrentFps        = $curFps
            CurrentBitrate    = $curBw
            RecommendedFps    = $newFps
            RecommendedBitrate= $newBw
            CurrentProfile    = $h.Profile
            RecommendedProfile= (ConvertTo-ScrcpyProfile -View $h.ParsedProfile.View -Eye $h.ParsedProfile.Eye -AudioDup $h.ParsedProfile.AudioDup -Fps $newFps -BitrateMbps $newBw)
        }
    }

    # ------- MediaMTX row -------
    $mtxBw       = [int]$inputs.MediaMtx.BitrateMbps
    $mtxFps      = [int]$inputs.MediaMtx.Framerate
    $mtxOrigBw   = $mtxBw; $mtxOrigFps = $mtxFps
    if ($originals -and $originals.MediaMtx) {
        $mtxOrigBw  = [int]$originals.MediaMtx.BitrateMbps
        $mtxOrigFps = [int]$originals.MediaMtx.Framerate
    }
    $mtxNewBw  = $mtxBw; $mtxNewFps = $mtxFps
    switch ($direction) {
        'down' {
            $mtxNewBw  = _Clamp -Value ([int][Math]::Round($mtxBw  * (1 - $step))) -Min $global:VQA_MinBitrateMbps -Max $mtxBw
            $mtxNewFps = _RoundFpsDown -Value ([int][Math]::Round($mtxFps * (1 - $step))) -Step $fpsStep
            $mtxNewFps = _Clamp -Value $mtxNewFps -Min $global:VQA_MinFps -Max $mtxFps
        }
        'up' {
            $mtxNewBw  = _Clamp -Value ([int][Math]::Round($mtxBw  * (1 + $step))) -Min $mtxBw -Max $mtxOrigBw
            $mtxNewFps = _RoundFpsDown -Value ([int][Math]::Round($mtxFps * (1 + $step))) -Step $fpsStep
            $mtxNewFps = _Clamp -Value $mtxNewFps -Min $mtxFps -Max $mtxOrigFps
        }
    }

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
        MediaMtx     = [PSCustomObject]@{
            OriginalFramerate  = $mtxOrigFps
            OriginalBitrate    = $mtxOrigBw
            CurrentFramerate   = $mtxFps
            CurrentBitrate     = $mtxBw
            RecommendedFramerate= $mtxNewFps
            RecommendedBitrate  = $mtxNewBw
        }
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
        _AppendVqaHistory -Rec $rec
    } catch {
        Write-Log ("VQR: failed to write recommendation: " + $_.Exception.Message) -Level WARNING
    }

    Write-Log ("VQR: direction=$direction cpu=${cpu}% gpu=${gpu}% scrcpy=$($inputs.Headsets.Count) clients=$($inputs.ClientCount)") -Level DEBUG
    return $rec
}


# Append one row to vqa_history.csv. Header is created on first write; the file
# is truncated to a header-only state by Initialize-VideoQualityAutomation at
# startup, so history is per-session.
function _AppendVqaHistory {
    param($Rec)
    $header = "Timestamp;CpuPct;GpuPct;ScrcpyCount;ClientCount;Direction;Reason;Json"
    if (-not (Test-Path -LiteralPath $global:VQA_HistoryFilePath)) {
        Write-FileWithoutBom -Path $global:VQA_HistoryFilePath -Content ($header + "`r`n")
    }
    $json = ($Rec | ConvertTo-Json -Depth 6 -Compress) -replace '"', '""'
    $line = "{0};{1};{2};{3};{4};{5};{6};""{7}""" -f `
        $Rec.Timestamp, $Rec.Cpu, $Rec.Gpu, $Rec.ScrcpyCount, $Rec.ClientCount, $Rec.Direction, ($Rec.Reason -replace ';', ','), $json
    Add-Content -LiteralPath $global:VQA_HistoryFilePath -Value $line -Encoding UTF8
}


###############################################################
# VQO - VIDEO QUALITY OPTIMIZER (auto-applier)
###############################################################


# Read the last $count rows from vqa_history.csv. Returns @() if fewer rows
# than requested exist (so VQO waits until the buffer is full).
function _GetLastVqaHistoryRows {
    param([int]$Count)
    if (-not (Test-Path -LiteralPath $global:VQA_HistoryFilePath)) { return @() }
    $all = @(Get-Content -LiteralPath $global:VQA_HistoryFilePath -Encoding UTF8 | Select-Object -Skip 1)
    if ($all.Count -lt $Count) { return @() }
    return @($all | Select-Object -Last $Count)
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


# Read the remaining cooldown counter (0 when no cooldown is active).
function Get-VqaCooldownRemaining {
    if (-not (Test-Path -LiteralPath $global:VQA_CooldownFilePath)) { return 0 }
    try { return [int](Get-Content -LiteralPath $global:VQA_CooldownFilePath -Raw -Encoding UTF8 | ConvertFrom-Json).RemainingCycles } catch { return 0 }
}


# Called once at the top of every VQR cycle. Decrements the counter, deletes
# the file when it reaches 0, returns the post-decrement value (so the
# recommendation JSON can carry it).
function _DecrementVqaCooldown {
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
    $cfg = Read-ConfigJson -ConfigFilePath $cfgPath
    if (-not $cfg -or -not $cfg.VideoQualityAutomation) { return $false }
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
    if ($n -lt 1) { $n = 5 }
    $rows = _GetLastVqaHistoryRows -Count $n
    if ($rows.Count -lt $n) { return }

    # Column 6 (0-indexed 5) = Direction. Every row must be 'down'.
    foreach ($d in ($rows | ForEach-Object { ($_ -split ';')[5] })) {
        if ($d -ne 'down') { return }
    }

    Write-Log ("VQO: $n consecutive 'down' recommendations - auto-applying enabled sections.") -Level INFO
    $applied = $false
    try {
        if ($global:VQA_AutoApplyProfiles) { Invoke-VqaApply -Scope 'profile'  | Out-Null; $applied = $true }
        if ($global:VQA_AutoApplyHeadsets) { Invoke-VqaApply -Scope 'headset'  | Out-Null; $applied = $true }
        if ($global:VQA_AutoApplyMediaMtx) { Invoke-VqaApply -Scope 'mediamtx' | Out-Null; $applied = $true }
    } catch {
        Write-Log ("VQO: apply failed: " + $_.Exception.Message) -Level ERROR
    }
    # Invoke-VqaApply already arms the cooldown at the end of each successful
    # apply, so the file already exists by here; this call is a no-op redundancy
    # only when every section flag was off (in which case $applied stays false).
    if (-not $applied) { Write-Log "VQO: all per-section flags off after pre-check - nothing applied." -Level DEBUG }
}


###############################################################
# APPLY / RESTORE
###############################################################


# Returns the latest recommendation object (parsed JSON) or $null.
function _GetLatestVqaRecommendation {
    if (-not (Test-Path -LiteralPath $global:VQA_RecommendationFilePath)) { return $null }
    try { return Get-Content -LiteralPath $global:VQA_RecommendationFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}


# Build the baseline snapshot from the CURRENT (pre-apply) state. Stored on
# first apply only - never overwritten so subsequent applies still know the
# operator's original ceilings for upscaling.
function _SnapshotVqaOriginals {
    $cfg = Read-ConfigJson -ConfigFilePath (Join-Path $global:ScriptPath 'config\config.json')
    $profiles = @()
    if ($cfg -and $cfg.scrcpy -and $cfg.scrcpy.parameters) {
        foreach ($prop in $cfg.scrcpy.parameters.PSObject.Properties) {
            $profiles += [PSCustomObject]@{ Model = $prop.Name; MaxSize = [int]$prop.Value.max_size }
        }
    }

    $heads = @()
    foreach ($h in @(Get-KnownHeadsets)) {
        $parsed = ConvertFrom-ScrcpyProfile -Profile $h.ScrcpyProfile
        if ($parsed) {
            $heads += [PSCustomObject]@{
                Name        = $h.Name
                Profile     = $h.ScrcpyProfile
                Fps         = [int]$parsed.Fps
                BitrateMbps = [int]$parsed.BitrateMbps
            }
        }
    }

    $mtxBw = 0
    if ($global:mediamtxBitrate) {
        $bw = [string]$global:mediamtxBitrate -replace '[^\d]', ''
        if ($bw) { $mtxBw = [int]$bw }
    }

    $snap = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Profiles  = $profiles
        Headsets  = $heads
        MediaMtx  = [PSCustomObject]@{
            Framerate    = [int]$global:mediamtxFramerate
            BitrateMbps  = $mtxBw
        }
    }
    Write-FileWithoutBom -Path $global:VQA_OriginalsFilePath -Content ($snap | ConvertTo-Json -Depth 5)
    Write-Log "VQA: baseline snapshot written." -Level INFO
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
        [string]$Target = ''
    )

    $rec = _GetLatestVqaRecommendation
    if (-not $rec) { Write-Log "VQA: no recommendation to apply." -Level WARNING; return $false }
    if ($rec.Direction -eq 'none') { Write-Log "VQA: recommendation is 'none', nothing to apply." -Level INFO; return $false }

    if (-not (Test-Path -LiteralPath $global:VQA_OriginalsFilePath)) { _SnapshotVqaOriginals }

    $applied = @{
        Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Profiles  = @()
        Headsets  = @()
        MediaMtx  = $null
    }

    $configPath = Join-Path $global:ScriptPath 'config\config.json'
    $cfg = Read-ConfigJson -ConfigFilePath $configPath
    if (-not $cfg) { Write-Log "VQA: cannot read config.json for apply." -Level ERROR; return $false }

    $configChanged = $false
    $restartMtx    = $false
    $restartProcs  = @()

    # -- Profiles (config.json scrcpy.parameters.<Model>.max_size)
    if ($Scope -eq 'all' -or $Scope -eq 'profile') {
        foreach ($p in $rec.Profiles) {
            if ($Scope -eq 'profile' -and $Target -and $p.Model -ne $Target) { continue }
            if ([int]$p.Recommended -eq [int]$p.Current) { continue }
            if ($cfg.scrcpy.parameters.PSObject.Properties.Name -contains $p.Model) {
                $cfg.scrcpy.parameters.($p.Model).max_size = [int]$p.Recommended
                $configChanged = $true
                $applied.Profiles += [PSCustomObject]@{ Model = $p.Model; MaxSize = [int]$p.Recommended }
                # All running sessions of this model need a scrcpy restart for new max_size to take effect.
                foreach ($h in $rec.Headsets) {
                    if ($h.Model -eq $p.Model -and ($restartProcs -notcontains $h.Name)) { $restartProcs += $h.Name }
                }
            }
        }
    }

    # -- MediaMTX (config.json mediamtx.stream_framerate / stream_bitrate)
    if ($Scope -eq 'all' -or $Scope -eq 'mediamtx') {
        $newFps = [int]$rec.MediaMtx.RecommendedFramerate
        $newBw  = [int]$rec.MediaMtx.RecommendedBitrate
        $curFps = [int]$rec.MediaMtx.CurrentFramerate
        $curBw  = [int]$rec.MediaMtx.CurrentBitrate
        if ($newFps -ne $curFps -or $newBw -ne $curBw) {
            $cfg.mediamtx.stream_framerate = $newFps
            $cfg.mediamtx.stream_bitrate   = "${newBw}M"
            $configChanged = $true
            $restartMtx    = $true
            $applied.MediaMtx = [PSCustomObject]@{ Framerate = $newFps; BitrateMbps = $newBw }
        }
    }

    if ($configChanged) {
        Write-FileWithoutBom -Path $configPath -Content (($cfg | ConvertTo-Json -Depth 12))
        # Reload globals so subsequent reads see the new values immediately.
        try { Get-Config -ConfigFilePath $configPath } catch { }
    }

    # -- Per-headset (known_headsets.csv ScrcpyProfile column)
    # Update-HeadsetField looks up by ID, so map Name -> ID via Get-KnownHeadsets once.
    if ($Scope -eq 'all' -or $Scope -eq 'headset') {
        $allHeads = @(Get-KnownHeadsets)
        foreach ($h in $rec.Headsets) {
            if ($Scope -eq 'headset' -and $Target -and $h.Name -ne $Target) { continue }
            if ($h.RecommendedProfile -eq $h.CurrentProfile) { continue }
            $row = $allHeads | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
            if (-not $row) { continue }
            try {
                Update-HeadsetField -ID ([int]$row.ID) -Field 'ScrcpyProfile' -NewValue $h.RecommendedProfile | Out-Null
                $applied.Headsets += [PSCustomObject]@{ Name = $h.Name; Profile = $h.RecommendedProfile }
                if ($restartProcs -notcontains $h.Name) { $restartProcs += $h.Name }
            } catch {
                Write-Log ("VQA: failed to update " + $h.Name + ": " + $_.Exception.Message) -Level WARNING
            }
        }
    }

    # Persist what we wrote (used by restore to detect operator manual edits)
    Write-FileWithoutBom -Path $global:VQA_AppliedFilePath -Content ($applied | ConvertTo-Json -Depth 5)

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

    # -- Restart mediamtx if its config changed
    if ($restartMtx) {
        try { Stop-MediaMtx; Start-Sleep -Seconds 1; Start-MediaMtx } catch { Write-Log "VQA: mediamtx restart failed." -Level WARNING }
    }

    Write-Log ($msg.VqaRecommendationApplied -f $rec.Direction) -Level SUCCESS
    # Arm the post-change cooldown so the workload can settle before VQR resumes
    # warning the operator or VQO triggers another apply.
    Start-VqaCooldown
    return $true
}


# Restore baseline values, skipping any field the operator has manually edited
# since we wrote it. Detection: if the current value still equals what we wrote
# (recorded in vqa_applied.json), the operator did not touch it -> safe to
# revert. Otherwise leave it alone.
function Restore-VqaOriginals {
    if (-not (Test-Path -LiteralPath $global:VQA_OriginalsFilePath)) { return $false }

    $orig = $null; $applied = $null
    try { $orig    = Get-Content -LiteralPath $global:VQA_OriginalsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (Test-Path -LiteralPath $global:VQA_AppliedFilePath) {
        try { $applied = Get-Content -LiteralPath $global:VQA_AppliedFilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (-not $orig) { return $false }

    $configPath = Join-Path $global:ScriptPath 'config\config.json'
    $cfg = Read-ConfigJson -ConfigFilePath $configPath
    $configChanged = $false
    $restartMtx    = $false

    # -- Profiles
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

    # -- MediaMTX
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
        Write-FileWithoutBom -Path $configPath -Content (($cfg | ConvertTo-Json -Depth 12))
        try { Get-Config -ConfigFilePath $configPath } catch { }
    }

    # -- Headsets
    $restartProcs = @()
    if ($orig.Headsets) {
        foreach ($h in $orig.Headsets) {
            $row = Get-KnownHeadsets | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
            if (-not $row) { continue }
            $appliedProfile = $null
            if ($applied -and $applied.Headsets) {
                $a = $applied.Headsets | Where-Object { $_.Name -eq $h.Name } | Select-Object -First 1
                if ($a) { $appliedProfile = [string]$a.Profile }
            }
            if ($null -ne $appliedProfile -and $row.ScrcpyProfile -ne $appliedProfile) { continue }
            if ($row.ScrcpyProfile -ne $h.Profile) {
                try {
                    Update-HeadsetField -ID ([int]$row.ID) -Field 'ScrcpyProfile' -NewValue $h.Profile | Out-Null
                    $restartProcs += $h.Name
                } catch { }
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
        } catch { }
    }
    if ($restartMtx) {
        try { Stop-MediaMtx; Start-Sleep -Seconds 1; Start-MediaMtx } catch { }
    }

    Remove-Item -LiteralPath $global:VQA_OriginalsFilePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $global:VQA_AppliedFilePath   -Force -ErrorAction SilentlyContinue
    Write-Log $msg.VqaRestored -Level SUCCESS
    # Restore is also a "system mutated" event - arm the cooldown so VQR/VQO
    # let the workload re-stabilise before reacting.
    Start-VqaCooldown
    return $true
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
        try { Restore-VqaOriginals | Out-Null } catch { }
    }
    # Per-session history: header only.
    $header = "Timestamp;CpuPct;GpuPct;ScrcpyCount;ClientCount;Direction;Reason;Json"
    Write-FileWithoutBom -Path $global:VQA_HistoryFilePath -Content ($header + "`r`n")
    Write-Log $msg.VqaHistoryReset -Level DEBUG
}


###############################################################
# CONSOLE SUB-MENU
###############################################################


# [M] Monitoring sub-menu. Modelled on Show-SubMenu-Services. Lives in this
# module so the whole menu disappears when VQA is disabled (the module is
# not dot-sourced in that case).
function Show-SubMenu-Monitoring {
    do {
        Clear-Host
        Write-Host ""
        Write-Host " ==========================================================" -ForegroundColor Cyan
        Write-Host "   $($msg.MonitoringMenuTitle)" -ForegroundColor Cyan
        Write-Host " ==========================================================" -ForegroundColor Cyan
        Write-Host ""

        $rec = _GetLatestVqaRecommendation
        if ($rec) {
            $color = if ($rec.Direction -eq 'down') { 'Yellow' } elseif ($rec.Direction -eq 'up') { 'Green' } else { 'Gray' }
            Write-Host ("   CPU: {0}%   GPU: {1}%   scrcpy: {2}   clients: {3}" -f $rec.Cpu, $rec.Gpu, $rec.ScrcpyCount, $rec.ClientCount) -ForegroundColor White
            Write-Host ("   Direction: {0}   Reason: {1}" -f $rec.Direction, $rec.Reason) -ForegroundColor $color
        } else {
            Write-Host "   No recommendation yet." -ForegroundColor DarkGray
        }
        $p = if ($global:VQA_AutoApplyProfiles) { 'ON' } else { 'OFF' }
        $h = if ($global:VQA_AutoApplyHeadsets) { 'ON' } else { 'OFF' }
        $m = if ($global:VQA_AutoApplyMediaMtx) { 'ON' } else { 'OFF' }
        $cd = Get-VqaCooldownRemaining
        Write-Host ("   Auto-apply:  Profiles [{0}]   Headsets [{1}]   MediaMTX [{2}]" -f $p, $h, $m) -ForegroundColor White
        Write-Host ("   Cooldown:    {0} cycles remaining" -f $cd) -ForegroundColor White
        Write-Host ""
        Write-Host "   [1] Toggle Profiles auto-apply"
        Write-Host "   [2] Toggle Headsets auto-apply"
        Write-Host "   [3] Toggle MediaMTX auto-apply"
        Write-Host "   [4] Apply current recommendation now"
        Write-Host "   [5] Restore originals"
        Write-Host "   [6] Show full recommendation JSON"
        Write-Host "   [0] Back"
        Write-Host ""
        $choice = Read-Host "   Choice"

        switch ($choice) {
            '1' { Set-VqaAutoApply -Section 'profiles' -Enabled (-not $global:VQA_AutoApplyProfiles) | Out-Null; Start-Sleep -Milliseconds 500 }
            '2' { Set-VqaAutoApply -Section 'headsets' -Enabled (-not $global:VQA_AutoApplyHeadsets) | Out-Null; Start-Sleep -Milliseconds 500 }
            '3' { Set-VqaAutoApply -Section 'mediamtx' -Enabled (-not $global:VQA_AutoApplyMediaMtx) | Out-Null; Start-Sleep -Milliseconds 500 }
            '4' { Invoke-VqaApply -Scope 'all' | Out-Null; Read-Host "Press Enter" }
            '5' { Restore-VqaOriginals | Out-Null; Read-Host "Press Enter" }
            '6' {
                if (Test-Path -LiteralPath $global:VQA_RecommendationFilePath) {
                    Get-Content -LiteralPath $global:VQA_RecommendationFilePath -Raw | Write-Host
                } else {
                    Write-Host "No recommendation file yet."
                }
                Read-Host "Press Enter"
            }
        }
    } while ($choice -ne '0')
}
