#Requires -Version 5.1
<#
.SYNOPSIS
    Headset selection and live stream-health helpers for the VR HEADSET MANAGER
    non-regression harness. Dot-sourced by scripts\Invoke-NonRegressionTests.ps1.

.DESCRIPTION
    Sections 50 (scrcpy lifecycle) and 60 (streaming matrix) are the only ones
    that need real hardware, and they share all of the plumbing below.

    Two things are worth knowing before reading further:

      - There is NO "start scrcpy for this headset" endpoint. The app starts
        scrcpy indirectly: setting scrcpy_AutoRestart = True makes the VRMonitor
        loop's Watch-ScrcpyProcesses launch it on its next slow pass. So every
        "start streaming" here is a POST /api/autorestart followed by a poll.

      - Watch-ScrcpyProcesses refuses to launch until Get-KnownHeadsetInfos has
        reported ADBWifi = true for that headset. That is why Wait-NrtHeadsetAdb
        exists and must be awaited before expecting any scrcpy process.

    The sandbox registry starts empty, so these sections import ONE headset from
    the operator's dev registry (reachability-probed first) rather than hardcoding
    an address - no real IP ever lands in a committed test file.

    ASCII only (CLAUDE.md rule 1).
#>

# ---------------------------------------------------------------------------
# Headset discovery and selection
# ---------------------------------------------------------------------------

function Get-NrtDevHeadsets {
    <#
    .SYNOPSIS
        Reads the operator's real headset registry from the DEV folder.

    .DESCRIPTION
        The sandbox registry is deliberately empty, so the candidate list has to
        come from somewhere else. The dev folder's known_headsets.csv is the
        operator's own list and is never written to by the harness.

    .EXAMPLE
        $candidates = Get-NrtDevHeadsets -DevRoot $devRoot
    #>
    param([Parameter(Mandatory = $true)][string]$DevRoot)

    $csv = Join-Path $DevRoot 'data\known_headsets.csv'
    if (-not (Test-Path -LiteralPath $csv)) { return @() }

    try {
        return @(Import-Csv -LiteralPath $csv -Encoding UTF8 | Where-Object { $_.IPAddress })
    }
    catch {
        return @()
    }
}

function Test-NrtHeadsetReachable {
    <#
    .SYNOPSIS
        Returns $true when the headset answers ping AND has the ADB port open.

    .DESCRIPTION
        Both checks matter: ping alone passes for a headset that is awake but has
        wireless ADB switched off, and scrcpy cannot attach to that.

    .EXAMPLE
        if (Test-NrtHeadsetReachable -IPAddress '10.0.0.5' -AdbPort 5555) { ... }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [int]$AdbPort = 5555,
        [int]$TimeoutMs = 1500
    )

    $ping = $false
    try { $ping = Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue } catch { }
    if (-not $ping) { return $false }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        return $client.ConnectAsync($IPAddress, $AdbPort).Wait($TimeoutMs)
    }
    catch { return $false }
    finally { if ($client) { try { $client.Close() } catch { } } }
}

function Wait-NrtCandidatesReachable {
    <#
    .SYNOPSIS
        Grace-window poll: re-probes -Candidates every ~2s for -TimeoutSec and
        returns whichever ones answer ping + ADB port before the window closes.

    .DESCRIPTION
        Used right after the operator confirms a physical action ("plugged it
        in"), since WiFi ADB can take a few seconds to come back after
        power-on / USB-plug - a single immediate re-probe would often still
        see the headset as down and force a needless extra prompt round-trip.

    .EXAMPLE
        $reachable = Wait-NrtCandidatesReachable -Candidates $candidates -AdbPort 5555 -TimeoutSec 20
    #>
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [int]$AdbPort = 5555,
        [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $reachable = @($Candidates | Where-Object { Test-NrtHeadsetReachable -IPAddress $_.IPAddress -AdbPort $AdbPort })
        if ($reachable.Count -gt 0) { return $reachable }
        if ((Get-Date) -ge $deadline) { return @() }
        Start-Sleep -Seconds 2
    }
}

function Invoke-NrtEnableUsbWifiAdb {
    <#
    .SYNOPSIS
        Bridges a USB-connected headset onto WiFi ADB via POST /api/enablewifiadb.
        Returns @{ Ip; Model; Port } on success, $null otherwise (including when
        nothing is on USB - this is a safe, harmless no-op in that case).

    .DESCRIPTION
        Plugging a headset into USB does NOT by itself make it answer on its
        WiFi IP:port - that only happens once wireless ADB (tcpip mode) is
        enabled, and a headset that went to sleep drops that mode. The app's
        own automatic USB onboarding (Invoke-UsbHeadsetActions, run every
        VRMonitor cycle) only re-enables it for a headset already present in
        THAT app instance's known_headsets.csv - which is empty in the sandbox
        at this point, since sections 50/60 only add the headset once one is
        resolved (the exact chicken-and-egg this helper breaks). This calls the
        same underlying action (Enable-AdbTcpIp, via the public API an operator
        would use in the web UI) directly, independent of any registry match.

    .EXAMPLE
        $bridged = Invoke-NrtEnableUsbWifiAdb
        if ($bridged) { Write-Host ("USB bridge: {0} -> {1}" -f $bridged.Model, $bridged.Ip) }
    #>
    try {
        $r = Invoke-VrmApi -Path '/api/enablewifiadb' -Method POST -TimeoutSec 20
        if ($r.Ok -and $r.Json -and $r.Json.ok -and $r.Json.ip) {
            return @{ Ip = [string]$r.Json.ip; Model = [string]$r.Json.model; Port = $r.Json.port }
        }
    }
    catch { }
    return $null
}

function Resolve-NrtTestHeadset {
    <#
    .SYNOPSIS
        Picks the headset sections 50/60 will drive, or returns $null.

    .DESCRIPTION
        Order of precedence:
          1. -HeadsetName on the command line wins outright (still probed)
          2. otherwise every dev-registry headset is probed, and:
               - exactly one reachable  -> used
               - several reachable      -> operator picks in Manual mode,
                                           first one in Auto/Unattended
               - none reachable         -> see below

        When nothing answers ping + ADB port, Invoke-NrtEnableUsbWifiAdb is
        tried first, silently: a headset can be sitting right there on USB
        with WiFi ADB simply not (yet) re-enabled since it went to sleep, and
        this resolves that without ever bothering the operator (a harmless
        no-op when nothing is on USB).

        If that does not help and the dev registry is NOT empty (this
        operator's machine legitimately has headsets configured, so this
        looks like "unplugged right now" rather than "no hardware ever"), and
        the run is not -Unattended, the operator is asked via
        Wait-OperatorAction to connect the headset (power/USB if it went to
        sleep, same WiFi network). Each confirmation re-tries the USB bridge
        and then the probe after a grace window (Wait-NrtCandidatesReachable).
        This repeats - re-asking each time - until either a headset becomes
        reachable or the operator chooses [S] to skip.

        A dev registry with zero rows, or an -Unattended run, never prompts:
        $null comes back immediately and the caller SKIPs. That is deliberate
        - a machine with no headset configured at all (CI, another dev's
        box) must stay green and silent.

    .EXAMPLE
        $headset = Resolve-NrtTestHeadset -DevRoot $devRoot -AdbPort 5555
        if (-not $headset) { Skip-Test 'no reachable headset' }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DevRoot,
        [int]$AdbPort = 5555
    )

    $candidates = @(Get-NrtDevHeadsets -DevRoot $DevRoot)
    if ($candidates.Count -eq 0) { return $null }

    $requested = ''
    if ($global:TestRun -and $global:TestRun.HeadsetName) { $requested = $global:TestRun.HeadsetName }

    if ($requested) {
        $match = $candidates | Where-Object { $_.Name -eq $requested } | Select-Object -First 1
        if (-not $match) { return $null }
        $pool = @($match)
    }
    else {
        $pool = $candidates
    }

    $reachable = @($pool | Where-Object { Test-NrtHeadsetReachable -IPAddress $_.IPAddress -AdbPort $AdbPort })

    # Silent pre-check: a headset can already be sitting on USB (or was just
    # plugged in a moment ago) with its WiFi ADB not (yet) enabled. Bridging it
    # here can resolve reachability without ever bothering the operator - the
    # call is a harmless no-op when nothing is on USB.
    if ($reachable.Count -eq 0) {
        $bridged = Invoke-NrtEnableUsbWifiAdb
        if ($bridged) {
            Write-Host ("  USB bridge: {0} is now on WiFi ADB at {1}:{2}" -f $bridged.Model, $bridged.Ip, $bridged.Port) -ForegroundColor DarkGray
            $reachable = @($pool | Where-Object { Test-NrtHeadsetReachable -IPAddress $_.IPAddress -AdbPort $AdbPort })
        }
    }

    $unattended = ($global:TestRun -and $global:TestRun.Unattended)
    $firstPrompt = $true
    while ($reachable.Count -eq 0 -and -not $unattended) {
        $names = ($pool | ForEach-Object { "$($_.Name) ($($_.IPAddress))" }) -join ', '
        if ($firstPrompt) {
            $message = "No headset answered ping + ADB port $AdbPort. Connect it - plug in USB power/cable if it went to sleep, and make sure it is on the same WiFi network - then press Enter to retry."
        } else {
            $message = "Still not reachable. Keep checking the connection (USB power, WiFi) and press Enter to retry."
        }
        $firstPrompt = $false

        $confirmed = Wait-OperatorAction -Message $message -Hint ("candidate(s): {0}" -f $names)
        if (-not $confirmed) { return $null }

        # Re-attempt the USB bridge every round: the operator may have just
        # plugged the cable in response to this very prompt.
        $bridged = Invoke-NrtEnableUsbWifiAdb
        if ($bridged) {
            Write-Host ("  USB bridge: {0} is now on WiFi ADB at {1}:{2}" -f $bridged.Model, $bridged.Ip, $bridged.Port) -ForegroundColor DarkGray
        }

        $reachable = @(Wait-NrtCandidatesReachable -Candidates $pool -AdbPort $AdbPort -TimeoutSec 20)
    }

    if ($reachable.Count -eq 0) { return $null }
    if ($reachable.Count -eq 1) { return $reachable[0] }

    $interactive = $true
    if ($global:TestRun -and $global:TestRun.Unattended) { $interactive = $false }
    if ($global:TestRun -and $global:TestRun.Mode -eq 'Auto') { $interactive = $false }

    if (-not $interactive) { return $reachable[0] }

    $picked = Select-TestHeadset -Candidates @($reachable | ForEach-Object { $_.Name })
    return ($reachable | Where-Object { $_.Name -eq $picked } | Select-Object -First 1)
}

function ConvertTo-NrtSafeName {
    <#
    .SYNOPSIS
        Mirrors the app's Convert-Displayname: spaces become underscores.
        This is the scrcpy window title and the per-headset file-name stem.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace ' ', '_')
}

function ConvertTo-NrtStreamPath {
    <#
    .SYNOPSIS
        Mirrors the app's ConvertTo-RestreamPathName: safe name, lowercased.
        This is the mediamtx path a headset publishes to.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return (ConvertTo-NrtSafeName -Name $Name).ToLower()
}

# ---------------------------------------------------------------------------
# Sandbox registry helpers
# ---------------------------------------------------------------------------

function Add-NrtSandboxHeadset {
    <#
    .SYNOPSIS
        Imports one real headset into the sandbox registry through the public API.

    .EXAMPLE
        Add-NrtSandboxHeadset -Headset $headset
    #>
    param([Parameter(Mandatory = $true)]$Headset)

    $body = @{
        name         = $Headset.Name
        ip           = $Headset.IPAddress
        model        = $Headset.Model
        serialNumber = $Headset.SerialNumber
    }
    $r = Invoke-VrmApi -Path '/api/addheadset' -Method POST -Body $body
    return $r
}

function Get-NrtSandboxHeadset {
    <#
    .SYNOPSIS
        Returns the SANDBOX's registry row for a headset (via /api/headsets), or $null.

    .DESCRIPTION
        Use this - not the dev-registry row - whenever a test asserts against
        what the app is actually configured to do. /api/addheadset assigns its
        own DEFAULT scrcpy profile and ignores any profile in the request, so the
        two registries disagree the moment a headset is imported.

    .EXAMPLE
        $row = Get-NrtSandboxHeadset -Name 'Q3 RED'
        Assert-Equal $row.ScrcpyProfile $observedProfile 'cmdline profile'
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $r = Invoke-VrmApi -Path '/api/headsets'
    if (-not $r.Ok -or -not $r.Json) { return $null }
    return (@($r.Json) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Set-NrtScrcpyProfile {
    <#
    .SYNOPSIS
        Sets a headset's scrcpy profile in the sandbox registry.

    .EXAMPLE
        Set-NrtScrcpyProfile -Name 'Q3 RED' -Profile 'max-R-N-60-5'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $safe = ConvertTo-NrtSafeName -Name $Name
    return (Invoke-VrmApi -Path '/api/updateprofile' -Method POST -Body @{ name = $safe; profile = $Profile })
}

function Set-NrtAutoRestart {
    <#
    .SYNOPSIS
        Enables or disables scrcpy auto-restart, which is how the app is told to
        start or stop streaming a headset.

    .EXAMPLE
        Set-NrtAutoRestart -Name 'Q3 RED' -Enabled $true
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $safe = ConvertTo-NrtSafeName -Name $Name
    return (Invoke-VrmApi -Path '/api/autorestart' -Method POST -Body @{ name = $safe; value = $Enabled })
}

function Wait-NrtHeadsetAdb {
    <#
    .SYNOPSIS
        Waits until VRMonitor reports ADBWifi = true for a headset.

    .DESCRIPTION
        Watch-ScrcpyProcesses will not launch scrcpy before this is true, so
        every streaming test has to await it first. Reads the app's own live
        status file (semicolon-delimited, per CLAUDE.md).

    .EXAMPLE
        Assert-True (Wait-NrtHeadsetAdb -TargetRoot $target -Name 'Q3 RED' -TimeoutSec 90) 'ADB never came up'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSec = 90
    )

    $paths    = Get-SandboxPaths -TargetRoot $TargetRoot
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $paths.HeadsetsInfos) {
            try {
                $rows = @(Import-Csv -LiteralPath $paths.HeadsetsInfos -Delimiter ';' -Encoding UTF8)
                $row  = $rows | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
                if ($row -and ("$($row.ADBWifi)" -match '^(True|true|1)$')) { return $true }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# ---------------------------------------------------------------------------
# scrcpy process helpers
# ---------------------------------------------------------------------------

function Get-NrtScrcpyProcess {
    <#
    .SYNOPSIS
        Finds the scrcpy process for one headset, restricted to binaries that
        live under the TARGET release folder.

    .DESCRIPTION
        The path restriction is the point: it proves the RELEASE's scrcpy is what
        is running, and stops a stray scrcpy launched from the dev folder (or by
        the operator's own session) from making a test pass.

        Matches the app's own Get-ScrcpyProcess strategy - window title first,
        command line as the fallback for windows on inactive virtual desktops.

    .EXAMPLE
        $p = Get-NrtScrcpyProcess -TargetRoot $target -Name 'Q3 RED' -IPAddress '10.0.0.5'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$IPAddress = ''
    )

    $safe  = ConvertTo-NrtSafeName -Name $Name
    $root  = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $procs = @(Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | Where-Object {
        $p = ''
        try { $p = $_.Path } catch { }
        $p -and $p.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($procs.Count -eq 0) { return $null }

    $byTitle = $procs | Where-Object { $_.MainWindowTitle -eq $safe } | Select-Object -First 1
    if ($byTitle) { return $byTitle }

    foreach ($proc in $procs) {
        $cmdLine = ''
        try {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $proc.Id) -ErrorAction SilentlyContinue
            if ($cim) { $cmdLine = [string]$cim.CommandLine }
        }
        catch { }
        if (-not $cmdLine) { continue }
        if ($IPAddress -and $cmdLine -match [regex]::Escape($IPAddress)) { return $proc }
        if ($cmdLine -match [regex]::Escape($safe)) { return $proc }
    }
    return $null
}

function Get-NrtProcessCommandLine {
    <#
    .SYNOPSIS
        Returns a process's full command line, or '' when it cannot be read.
    #>
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ProcessId) -ErrorAction SilentlyContinue
        if ($cim) { return [string]$cim.CommandLine }
    }
    catch { }
    return ''
}

function Wait-NrtScrcpy {
    <#
    .SYNOPSIS
        Waits for a headset's scrcpy process to appear (-Running) or disappear
        (-Running:$false). Returns the process object, or $null on timeout.

    .EXAMPLE
        $proc = Wait-NrtScrcpy -TargetRoot $target -Name 'Q3 RED' -IPAddress $ip -Running $true -TimeoutSec 90
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$IPAddress = '',
        [bool]$Running = $true,
        [int]$TimeoutSec = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-NrtScrcpyProcess -TargetRoot $TargetRoot -Name $Name -IPAddress $IPAddress
        if ($Running -and $proc) { return $proc }
        if ((-not $Running) -and (-not $proc)) { return $null }
        Start-Sleep -Milliseconds 1000
    }

    if ($Running) { return $null }
    return (Get-NrtScrcpyProcess -TargetRoot $TargetRoot -Name $Name -IPAddress $IPAddress)
}

# ---------------------------------------------------------------------------
# mediamtx stream health
# ---------------------------------------------------------------------------

function Get-NrtMediaMtxPaths {
    <#
    .SYNOPSIS
        GET /v3/paths/list against the sandbox mediamtx API. Returns the items
        array, or @() when mediamtx is unreachable.

    .EXAMPLE
        $paths = Get-NrtMediaMtxPaths -ApiPort 9997
    #>
    param(
        [int]$ApiPort = 9997,
        [int]$TimeoutSec = 5
    )

    try {
        $resp = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v3/paths/list" -f $ApiPort) `
                                  -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp -and $resp.items) { return @($resp.items) }
        return @()
    }
    catch { return @() }
}

function Get-NrtMediaMtxPath {
    <#
    .SYNOPSIS
        Returns the single mediamtx path entry for a headset, or $null.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [int]$ApiPort = 9997
    )
    return (Get-NrtMediaMtxPaths -ApiPort $ApiPort | Where-Object { $_.name -eq $PathName } | Select-Object -First 1)
}

function Wait-NrtStreamReady {
    <#
    .SYNOPSIS
        Waits for a mediamtx path to exist and report ready = true.

    .EXAMPLE
        Assert-True (Wait-NrtStreamReady -PathName 'q3_red' -ApiPort 9997 -TimeoutSec 60) 'stream never became ready'
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [int]$ApiPort = 9997,
        [int]$TimeoutSec = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-NrtMediaMtxPath -PathName $PathName -ApiPort $ApiPort
        if ($p -and $p.ready) { return $true }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

function Test-NrtStreamStable {
    <#
    .SYNOPSIS
        The core streaming assertion: N seconds of genuinely flowing video.

    .DESCRIPTION
        Samples /v3/paths/list once a second for -Seconds and requires all of:
          - the path exists in every sample
          - ready = true in every sample (no flap / republish mid-window)
          - bytesReceived never goes backwards
          - at most -AllowedStalls intervals show no growth (mediamtx updates its
            counters lazily, so demanding growth in every single interval is
            flaky; demanding it in nearly all of them is not)
          - average throughput >= -MinKbps, which separates a live video stream
            from a path that is merely open and dribbling keepalives

        Returns a result object rather than throwing, so the caller decides the
        verdict and can attach the numbers as evidence:
          @{ Stable; Reason; Samples; Seconds; TotalBytes; AvgKbps; Stalls;
             ReadyAlways; FirstBytes; LastBytes }

    .EXAMPLE
        $s = Test-NrtStreamStable -PathName 'q3_red' -ApiPort 9997 -Seconds 15
        Assert-True $s.Stable $s.Reason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PathName,
        [int]$ApiPort = 9997,
        [int]$Seconds = 15,
        [int]$AllowedStalls = 1,
        [int]$MinKbps = 100
    )

    $samples     = @()
    $readyAlways = $true
    $missing     = $false

    for ($i = 0; $i -lt $Seconds; $i++) {
        $p = Get-NrtMediaMtxPath -PathName $PathName -ApiPort $ApiPort
        if (-not $p) {
            $missing = $true
            $samples += [PSCustomObject]@{ At = Get-Date; Bytes = -1; Ready = $false }
        }
        else {
            if (-not $p.ready) { $readyAlways = $false }
            $bytes = 0
            if ($null -ne $p.bytesReceived) { $bytes = [int64]$p.bytesReceived }
            $samples += [PSCustomObject]@{ At = Get-Date; Bytes = $bytes; Ready = [bool]$p.ready }
        }
        if ($i -lt ($Seconds - 1)) { Start-Sleep -Milliseconds 1000 }
    }

    $result = [PSCustomObject]@{
        Stable      = $false
        Reason      = ''
        Samples     = $samples.Count
        Seconds     = $Seconds
        TotalBytes  = 0
        AvgKbps     = 0
        Stalls      = 0
        ReadyAlways = $readyAlways
        FirstBytes  = 0
        LastBytes   = 0
    }

    if ($missing) {
        $result.Reason = ("mediamtx path '{0}' disappeared during the {1}s window" -f $PathName, $Seconds)
        return $result
    }
    if (-not $readyAlways) {
        $result.Reason = ("mediamtx path '{0}' was not ready for the whole {1}s window" -f $PathName, $Seconds)
        return $result
    }

    $result.FirstBytes = $samples[0].Bytes
    $result.LastBytes  = $samples[-1].Bytes
    $result.TotalBytes = $result.LastBytes - $result.FirstBytes

    $stalls = 0
    for ($i = 1; $i -lt $samples.Count; $i++) {
        $delta = $samples[$i].Bytes - $samples[$i - 1].Bytes
        if ($delta -lt 0) {
            $result.Reason = ("bytesReceived went backwards ({0} -> {1}) - the stream was republished mid-window" -f $samples[$i - 1].Bytes, $samples[$i].Bytes)
            return $result
        }
        if ($delta -eq 0) { $stalls++ }
    }
    $result.Stalls = $stalls

    $elapsed = ($samples[-1].At - $samples[0].At).TotalSeconds
    if ($elapsed -le 0) { $elapsed = 1 }
    $result.AvgKbps = [int](($result.TotalBytes * 8) / 1000 / $elapsed)

    if ($stalls -gt $AllowedStalls) {
        $result.Reason = ("stream stalled in {0} of {1} intervals (max allowed {2})" -f $stalls, ($samples.Count - 1), $AllowedStalls)
        return $result
    }
    if ($result.AvgKbps -lt $MinKbps) {
        $result.Reason = ("throughput {0} kbps is below the {1} kbps floor - path is open but not carrying video" -f $result.AvgKbps, $MinKbps)
        return $result
    }

    $result.Stable = $true
    $result.Reason = ("{0}s stable: {1} kbps, {2} bytes, {3} stall(s)" -f $Seconds, $result.AvgKbps, $result.TotalBytes, $stalls)
    return $result
}

function Get-NrtSandboxPorts {
    <#
    .SYNOPSIS
        Reads the sandbox config and returns the ports the tests need.

    .EXAMPLE
        $ports = Get-NrtSandboxPorts -TargetRoot $target
        Get-NrtMediaMtxPaths -ApiPort $ports.MediaMtxApi
    #>
    param([Parameter(Mandatory = $true)][string]$TargetRoot)

    $paths  = Get-SandboxPaths -TargetRoot $TargetRoot
    $config = $null
    try { $config = Read-JsonFileUtf8 -Path $paths.ConfigFile } catch { }

    $out = @{ MediaMtxApi = 9997; Rtsp = 8554; Hls = 8888; WebRtc = 8889; Adb = 5555; ReEncode = $true; Codec = 'h264' }
    if ($config -and $config.mediamtx) {
        if ($config.mediamtx.api_port)    { $out.MediaMtxApi = [int]$config.mediamtx.api_port }
        if ($config.mediamtx.rtsp_port)   { $out.Rtsp        = [int]$config.mediamtx.rtsp_port }
        if ($config.mediamtx.hls_port)    { $out.Hls         = [int]$config.mediamtx.hls_port }
        if ($config.mediamtx.webrtc_port) { $out.WebRtc      = [int]$config.mediamtx.webrtc_port }
        if ($null -ne $config.mediamtx.reencode_in_ffmpeg) { $out.ReEncode = [bool]$config.mediamtx.reencode_in_ffmpeg }
        if ($config.mediamtx.codec)       { $out.Codec       = [string]$config.mediamtx.codec }
    }
    if ($config -and $config.ADB -and $config.ADB.port) { $out.Adb = [int]$config.ADB.port }
    return $out
}

function Start-NrtHeadsetStream {
    <#
    .SYNOPSIS
        Brings one headset all the way up: registered, ADB seen, scrcpy running.
        Returns @{ Ok; Reason; Process }.

    .DESCRIPTION
        Shared by sections 50 and 60 so the multi-step bring-up sequence -
        add, wait for ADB, enable autorestart, wait for the process - is written
        once. Does not assert; the caller turns Ok/Reason into a verdict.

    .EXAMPLE
        $up = Start-NrtHeadsetStream -TargetRoot $target -Headset $headset
        Assert-True $up.Ok $up.Reason
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)]$Headset,
        [int]$AdbTimeoutSec = 90,
        [int]$ScrcpyTimeoutSec = 90
    )

    $out = @{ Ok = $false; Reason = ''; Process = $null }

    $existing = Invoke-VrmApi -Path '/api/headsets'
    $already  = $false
    if ($existing.Json) {
        $already = @($existing.Json | Where-Object { $_.Name -eq $Headset.Name }).Count -gt 0
    }
    if (-not $already) {
        $add = Add-NrtSandboxHeadset -Headset $Headset
        if (-not $add.Ok) {
            $out.Reason = ("could not register the headset: HTTP {0}" -f $add.StatusCode)
            return $out
        }

        # /api/addheadset ignores any profile in the request and assigns its own
        # default, so carry the operator's real profile across explicitly. Without
        # this the tests would exercise a profile nobody actually uses.
        if ($Headset.ScrcpyProfile) {
            Set-NrtScrcpyProfile -Name $Headset.Name -Profile $Headset.ScrcpyProfile | Out-Null
        }
    }

    if (-not (Wait-NrtHeadsetAdb -TargetRoot $TargetRoot -Name $Headset.Name -TimeoutSec $AdbTimeoutSec)) {
        $out.Reason = ("VRMonitor never reported ADBWifi for '{0}' within {1}s" -f $Headset.Name, $AdbTimeoutSec)
        return $out
    }

    $r = Set-NrtAutoRestart -Name $Headset.Name -Enabled $true
    if (-not $r.Ok) {
        $out.Reason = ("POST /api/autorestart returned HTTP {0}" -f $r.StatusCode)
        return $out
    }

    $proc = Wait-NrtScrcpy -TargetRoot $TargetRoot -Name $Headset.Name -IPAddress $Headset.IPAddress `
                           -Running $true -TimeoutSec $ScrcpyTimeoutSec
    if (-not $proc) {
        $out.Reason = ("scrcpy did not start for '{0}' within {1}s of enabling auto-restart" -f $Headset.Name, $ScrcpyTimeoutSec)
        return $out
    }

    $out.Ok      = $true
    $out.Process = $proc
    $out.Reason  = ("scrcpy PID {0}" -f $proc.Id)
    return $out
}

function Stop-NrtHeadsetStream {
    <#
    .SYNOPSIS
        Tears one headset back down: auto-restart off, scrcpy stopped.
        Best-effort - never throws, so it is safe in a teardown test.

    .EXAMPLE
        Stop-NrtHeadsetStream -TargetRoot $target -Headset $headset
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)]$Headset,
        [int]$TimeoutSec = 45,
        [int]$Attempts = 3
    )

    $safe = ConvertTo-NrtSafeName -Name $Headset.Name

    # Retried on purpose. A watchdog relaunch already in flight when the stop
    # lands will finish AFTER it, bringing the pipeline straight back up - the
    # app logs "Pipe pipeline up" seconds after "Scrcpy stopped". One stop is
    # therefore not reliably a stop; keep going until it stays down.
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { Set-NrtAutoRestart -Name $Headset.Name -Enabled $false | Out-Null } catch { }
        try { Invoke-VrmApi -Path '/api/stop-scrcpy' -Method POST -Body @{ name = $safe } | Out-Null } catch { }

        $still = Wait-NrtScrcpy -TargetRoot $TargetRoot -Name $Headset.Name -IPAddress $Headset.IPAddress `
                                -Running $false -TimeoutSec $TimeoutSec
        if ($null -ne $still) { continue }

        # Settle window: catch a relaunch that was mid-flight when we stopped.
        Start-Sleep -Seconds 8
        $late = Get-NrtScrcpyProcess -TargetRoot $TargetRoot -Name $Headset.Name -IPAddress $Headset.IPAddress
        if (-not $late) { return $true }
    }
    return $false
}
