###############################################################
# adb_transport.ps1
# ADB transport: the raw adb wrappers (Invoke-Adb, Invoke-AdbCmd), the adb
# server, device resolution (USB set, Resolve-HeadsetAdbDevice, Get-BestAdbDevice,
# Get-AdbWifiDevice) and WiFi-ADB enabling (ADR-0021, ADR-0024).
# Split out of adb_functions.ps1 (S9-2). Auto-loaded by scripts_init.ps1.
# Translations are loaded centrally in scripts_init.ps1 into $global:msg.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


# Format an ADB device id ("IP:Port") used by `adb -s <id> ...`.
# Replaces "$ip`:$port" / "$ip:$port" interpolations scattered in the codebase.
function Get-DeviceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        [int]$AdbPort = $global:adbPort_default
    )
    if (-not $AdbPort) { $AdbPort = Get-ClassicAdbPort }
    return ("{0}:{1}" -f $IPAddress, $AdbPort)
}


function Test-AdbDeviceIdIsTls {
    <#
    .SYNOPSIS
    True when an "adb devices" id is one of adb's own mDNS-named TLS transports
    ("adb-<serial>-<rand>._adb-tls-connect._tcp"), which VRHM never uses (ADR-0034 rule 4).
    .EXAMPLE
    Test-AdbDeviceIdIsTls 'adb-1WMHH8242N0366-f4JCQ1._adb-tls-connect._tcp'    # $true
    #>
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return [bool]($Id -match '\._adb-tls-connect\._tcp' -or $Id -match '^adb-')
}


function Test-AdbDeviceIdIsUsb {
    <#
    .SYNOPSIS
    True when an "adb devices" id is a USB transport: no ':' (that is ip:port, WiFi) and not an
    mDNS-named TLS id (which also has no ':' and used to be misread as USB, i.e. fired "adb tcpip"
    at a headset that is only on WiFi). The ONE classification rule (S10-3).
    .EXAMPLE
    Test-AdbDeviceIdIsUsb '2G0YC5ZG1W00ZJ'          # $true
    Test-AdbDeviceIdIsUsb '192.168.1.243:5555'      # $false
    #>
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    if ($Id -match ':') { return $false }
    return (-not (Test-AdbDeviceIdIsTls -Id $Id))
}


# Wrapper around `& $adb ...` that captures stdout, stderr, and exit code.
# Returns @{ ExitCode; StdOut; StdErr; Ok }.
# - StdOut / StdErr are arrays of lines (may be empty).
# - Ok is $true when ExitCode is 0.
# Callers should check .Ok before consuming output.
function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Adb = $global:adbPath,
        # 15s, not 0. A 0 here means WaitForExit() with no bound, so a wedged adb
        # server hangs the calling runspace forever with nothing to recover it.
        # Callers that need longer (install/push) pass their own value.
        [int]$TimeoutSeconds = 15
    )

    if (-not (Test-Path -LiteralPath $Adb)) {
        return @{ ExitCode = -1; StdOut = @(); StdErr = @("adb not found at: $Adb"); Ok = $false }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Adb
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()

        # Read streams synchronously via Task.ReadToEndAsync. Avoids:
        # - PowerShell event-pump latency (Register-ObjectEvent races, truncates large output)
        # - Deadlock when one buffer fills while waiting on the other (read one async, one sync)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdoutRaw  = $proc.StandardOutput.ReadToEnd()

        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch {}
                return @{ ExitCode = -2; StdOut = @(); StdErr = @("adb timeout after $TimeoutSeconds s"); Ok = $false }
            }
        } else {
            $proc.WaitForExit()
        }

        $stderrRaw = $stderrTask.GetAwaiter().GetResult()

        $stdout = $stdoutRaw.TrimEnd("`r","`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }
        $stderr = $stderrRaw.TrimEnd("`r","`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }
        if ($stdout.Count -eq 1 -and $stdout[0] -eq '') { $stdout = @() }
        if ($stderr.Count -eq 1 -and $stderr[0] -eq '') { $stderr = @() }

        $code = $proc.ExitCode
        return @{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr; Ok = ($code -eq 0) }
    }
    finally {
        # Release SafeProcessHandle, stdout/stderr pipe handles, wait handle
        if ($proc) { $proc.Dispose() }
    }
}


function Test-AdbTransportFailure {
    <#
    .SYNOPSIS
    True when an Invoke-Adb result failed because the TRANSPORT is gone (device not
    connected / offline / unauthorized), as opposed to the command itself failing.

    .DESCRIPTION
    Used by Invoke-AdbCmd to decide whether a failure is worth a reconnect-and-retry.
    adb.exe is not localized, so matching its English diagnostics is locale-safe.

    A timeout (ExitCode -2) is deliberately NOT a transport failure: retrying would
    cost a second full timeout, doubling the wall clock for no new information.
    #>
    param($Result)

    if (-not $Result) { return $false }
    if ($Result.ExitCode -eq -2) { return $false }   # our own timeout
    if ($Result.ExitCode -eq -1) { return $false }   # adb.exe missing

    $text = ((@($Result.StdErr) + @($Result.StdOut)) -join ' ')
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    # Match adb's ACTUAL transport diagnostics, not loose substrings.
    #
    # A bare "not found" was far too broad: plenty of perfectly normal command
    # failures say it (a missing package, a missing file, a shell builtin), and
    # treating those as a dead transport sends the caller into the reconnect
    # branch - which, for a USB device, ends in a thrown AdbCmdUsbNotDetected
    # instead of the $false the caller expected. "device 'X' not found" is the
    # transport error; "not found" on its own is usually the command's own.
    return [bool]($text -match "(?i)device\s+'[^']*'\s+not\s+found|no devices?/emulators? found|device offline|device unauthorized|device still connecting|protocol fault|error:\s*closed|transport (?:not found|is closed)")
}


function Invoke-AdbCmd {
    <#
    .SYNOPSIS
    Executes an ADB command, returning stdout on success; reconnects and retries once
    if the transport turns out to be gone.

    .DESCRIPTION
    - $Device: PSCustomObject from Get-AdbWifiDevice/Get-AdbUsbDevice, OR a plain "IP:Port" string.
    - $Command is a string of ADB arguments after -s <DeviceId>
      e.g. "shell getprop ro.product.model"  or  "install -r `"C:\path with spaces\app.apk`""
    - Throws a descriptive exception for infrastructure failures (unreachable, unauthorized).
    - Returns $false when the command runs but exits with a non-zero exit code.
    - Returns a string array (may be empty @()) on success.

    ORDER MATTERS - do not reintroduce a pre-flight check. This function used to run
    "adb devices" BEFORE every command to validate the transport, which made every
    single call cost TWO adb.exe processes instead of one. With ~95 call sites and a
    per-headset poll loop, that was the single largest source of process churn in the
    app (~780 adb.exe/min at 5 headsets).

    The happy path now spawns exactly one process. The transport checks still exist,
    with identical semantics and identical exception messages - they just moved into
    the failure branch, where they cost nothing until something is actually wrong.
    There is no added latency for an unreachable headset: adb fails immediately with
    "device not found" because the adb server already knows the transport is gone;
    it does not go to the network to find out.
    #>
    param (
        [Parameter(Mandatory=$true)]
        $Device,
        [Parameter(Mandatory=$true)]
        [string]$Command,
        [int]$TimeoutSeconds = 7,
        [string]$adb = $global:adbPath,
        [switch]$SilentOnFail,
        # $Command is ONE shell script handed to "adb shell" as a single argument, not a list
        # of adb arguments. Needed for chained commands (";", "|", quotes): the default path
        # splits on whitespace and trims double quotes per token, which is fine for plain
        # "shell getprop x" but mangles a script. Embedded double quotes are escaped for the
        # Windows command line; the device shell sees the script verbatim.
        [switch]$ShellScript
    )

    if (-not $Device) { throw ($msg.AdbCmdDeviceNull) }

    # Accept plain "IP:Port" string - coerce to a minimal WiFi device object
    if ($Device -is [string]) {
        $parts = $Device -split ':'
        $Device = [PSCustomObject]@{
            DeviceId       = $Device
            ConnectionType = 'WiFi'
            IP             = $parts[0]
            Port           = if ($parts.Count -gt 1) { [int]$parts[1] } else { $global:adbPort_default }
        }
    }

    if (-not (Test-Path -LiteralPath $adb)) {
        throw ($msg.ADBExecutableNotFound -f $adb)
    }

    $deviceId = $Device.DeviceId

    # Split $Command preserving quoted segments (handles paths with spaces)
    if ($ShellScript) {
        $argv = @('-s', $deviceId, 'shell', ($Command -replace '"', '\"'))
    } else {
        $tokens = [regex]::Matches($Command, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }
        $argv   = @('-s', $deviceId) + $tokens
    }

    # ---- Attempt 1: just run it. One process. ----
    $result = Invoke-Adb -Arguments $argv -TimeoutSeconds $TimeoutSeconds -Adb $adb
    if ($result.Ok) { return $result.StdOut }

    # Failed. A plain command error (bad package, missing path, ...) is not our problem.
    if (-not (Test-AdbTransportFailure -Result $result)) {
        if (-not $SilentOnFail) {
            $errDetail = ($result.StdErr + $result.StdOut) -join ' '
            Write-Log ($msg.AdbCmdFailed -f $deviceId, $Command, $result.ExitCode, $errDetail) -Level WARNING
        }
        return $false
    }

    # ---- Transport is gone: recover, with the original diagnostics ----

    # USB-first: a device the resolver handed out as USB carries the headset's WiFi address
    # (HeadsetIP). When the cable drops mid-session, retry ONCE over WiFi instead of failing -
    # the headset is almost always still on the network. Never the other way round: a WiFi
    # failure is not retried over USB here, because Resolve-HeadsetAdbDevice already prefers
    # USB on the next call whenever the published snapshot says the cable is present.
    $fellBack = $false
    # Whatever happens next, this cable entry has just failed: stop every later lookup in this
    # process from choosing it until it is re-plugged (see Get-PublishedUsbDevices).
    if ($Device.ConnectionType -eq 'USB') { Register-UsbTransportFailure -Serial ([string]$Device.DeviceId) }
    $hasHeadsetIp = ($Device.PSObject.Properties['HeadsetIP'] -and $Device.HeadsetIP)
    $hasSerial    = ($Device.PSObject.Properties['SerialNumber'] -and $Device.SerialNumber)
    if ($Device.ConnectionType -eq 'USB' -and ($hasHeadsetIp -or $hasSerial)) {
        $fbPort = if ($Device.PSObject.Properties['HeadsetPort'] -and $Device.HeadsetPort) { [int]$Device.HeadsetPort } else { Get-ClassicAdbPort }
        $wifiDev = $null
        if (Get-Command Resolve-HeadsetWifiDevice -ErrorAction SilentlyContinue) {
            # Every enabled WiFi mode in preference order (ADR-0034): a TLS-only headset is
            # reachable here too. Still ONE fallback for this call.
            $fbHeadset = [PSCustomObject]@{
                Name         = $deviceId
                SerialNumber = $(if ($hasSerial) { [string]$Device.SerialNumber } else { [string]$Device.DeviceId })
                IPAddress    = $(if ($hasHeadsetIp) { [string]$Device.HeadsetIP } else { '' })
            }
            $wifiDev = Resolve-HeadsetWifiDevice -Headset $fbHeadset -ClassicPort $fbPort -adb $adb
        } elseif ($hasHeadsetIp) {
            $wifiDev = Get-AdbWifiDevice -headsetIP $Device.HeadsetIP -AdbPort $fbPort -adb $adb
        }
        if ($wifiDev) {
            Write-Log ((Get-MessageString -Key 'Diag.FallbackToWifi' -Fallback 'USB transport lost for {0} - retrying over WiFi ({1}).') -f $deviceId, $wifiDev.DeviceId) -Level WARNING
            # Tell the CALLER what really answered. The device object it passed in is shared by
            # reference, so update it in place: otherwise a caller that reports the transport
            # (the DIAG page, the status badge) keeps saying USB for a command that went over
            # WiFi, and later calls with the same object would retry the dead cable first.
            foreach ($p in 'DeviceId', 'ConnectionType', 'IP', 'Port', 'WifiMode') {
                if ($wifiDev.PSObject.Properties[$p]) { $Device | Add-Member -NotePropertyName $p -NotePropertyValue $wifiDev.$p -Force }
            }
            $Device   = $wifiDev
            $deviceId = $wifiDev.DeviceId
            $argv[1]  = $deviceId
            $fellBack = $true
        }
    }

    if ($fellBack) {
        # Transport already re-established by Get-AdbWifiDevice; go straight to attempt 2.
    } elseif ($Device.ConnectionType -eq 'WiFi') {
        $ip   = $Device.IP
        $port = if ($Device.Port) { $Device.Port } else { Get-ClassicAdbPort }

        # 1. Same endpoint: most drops are an 'offline' transport on a port that still listens,
        #    and a plain reconnect repairs them.
        $isConnected = $false
        $portOpen = (Test-Port -hostname $ip -port $port).open
        if ($portOpen) {
            # Bounded: this recovery branch runs on every failed command of a repeating poll.
            $null = Invoke-Adb -Arguments @('connect', $deviceId) -Adb $adb -TimeoutSeconds 10
            $isConnected = [bool]((Invoke-Adb -Arguments @('devices') -Adb $adb -TimeoutSeconds 5).StdOut |
                Where-Object { $_ -match ("^" + [regex]::Escape($deviceId) + "\s+device$") })
        }

        # 2. ADR-0034: retry ONCE over the other enabled WiFi mode (classic <-> TLS), and tell the
        #    caller in place, like the USB->WiFi fallback above. Never chained: a call that already
        #    fell back from USB does not reach this branch.
        if (-not $isConnected -and (Get-Command Get-AdbWifiModeFallbackDevice -ErrorAction SilentlyContinue)) {
            $altDev = Get-AdbWifiModeFallbackDevice -Device $Device -adb $adb
            if ($altDev) {
                Write-Log ("WiFi ADB {0} lost for {1} - retrying over {2} ({3})" -f (Get-AdbWifiDeviceMode -Device $Device), $deviceId, $altDev.WifiMode, $altDev.DeviceId) -Level WARNING
                foreach ($p in 'DeviceId', 'IP', 'Port', 'WifiMode') {
                    $Device | Add-Member -NotePropertyName $p -NotePropertyValue $altDev.$p -Force
                }
                $deviceId    = $altDev.DeviceId
                $argv[1]     = $deviceId
                $isConnected = $true
            }
        }

        if (-not $isConnected) {
            if (-not $portOpen) {
                $pingOk = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
                if (-not $pingOk) {
                    throw ($msg.AdbCmdPingFailed -f $ip)
                }
                throw ($msg.AdbCmdPortClosed -f $ip, $port)
            }
            throw ($msg.AdbCmdWifiNotConnected -f $deviceId)
        }

    } elseif ($Device.ConnectionType -eq 'USB') {
        $devicesOutput = @((Invoke-Adb -Arguments @('devices') -Adb $adb -TimeoutSeconds 5).StdOut | Where-Object { $_ -notmatch '^List of devices' -and $_ -ne '' })

        if ($devicesOutput | Where-Object { $_ -match 'unauthorized' }) {
            $serial = (($devicesOutput | Where-Object { $_ -match 'unauthorized' } | Select-Object -First 1) -split "`t")[0].Trim()
            throw ($msg.AdbCmdUsbUnauthorized -f $serial)
        }
        if (-not ($devicesOutput | Where-Object { $_ -match "`tdevice$" -and (Test-AdbDeviceIdIsUsb -Id (($_ -split "`t")[0].Trim())) })) {
            throw ($msg.AdbCmdUsbNotDetected)
        }

    } else {
        # Unknown connection type - nothing to reconnect, report as a plain failure.
        if (-not $SilentOnFail) {
            $errDetail = ($result.StdErr + $result.StdOut) -join ' '
            Write-Log ($msg.AdbCmdFailed -f $deviceId, $Command, $result.ExitCode, $errDetail) -Level WARNING
        }
        return $false
    }

    # ---- Attempt 2: transport restored, run it once more ----
    $result = Invoke-Adb -Arguments $argv -TimeoutSeconds $TimeoutSeconds -Adb $adb
    if ($result.Ok) { return $result.StdOut }

    if (-not $SilentOnFail) {
        $errDetail = ($result.StdErr + $result.StdOut) -join ' '
        Write-Log ($msg.AdbCmdFailed -f $deviceId, $Command, $result.ExitCode, $errDetail) -Level WARNING
    }
    return $false
}


function Get-AdbPropBatch {
    <#
    .SYNOPSIS
    Reads several getprop values (and optionally the wlan0 IP) in ONE adb call.

    .DESCRIPTION
    One "adb shell" round-trip instead of one per property. Each Invoke-AdbCmd is a
    process spawn, so reading manufacturer + model + serial separately cost three of
    them; this costs one.

    Segments are separated by an echoed marker rather than parsed positionally from a
    single blob, because getprop prints an EMPTY line for a property the device does
    not have - without the marker an absent property would silently shift every later
    value up by one. Only ";" and "echo" are used, no shell quoting or $ expansion, so
    nothing has to survive two layers of argument escaping.

    Returns a hashtable keyed by property name, plus 'WlanIp' when -IncludeWlanIp is
    set. A property the device does not have comes back as an empty string, never $null.

    .EXAMPLE
    $p = Get-AdbPropBatch -Device $usbDevice -Properties @('ro.product.manufacturer','ro.serialno') -IncludeWlanIp
    $p['ro.serialno']; $p['WlanIp']
    #>
    param (
        [Parameter(Mandatory=$true)]
        $Device,
        # Not mandatory: -IncludeWlanIp alone is a legitimate call (read just the
        # address), and a mandatory [string[]] would prompt on an empty array.
        [string[]]$Properties = @(),
        [switch]$IncludeWlanIp,
        [int]$TimeoutSeconds = 10,
        [string]$adb = $global:adbPath
    )

    if (-not $Properties) { $Properties = @() }
    if ($Properties.Count -eq 0 -and -not $IncludeWlanIp) { return @{} }

    $marker = '__VRHM__'
    $out    = @{}
    foreach ($p in $Properties) { $out[$p] = '' }
    if ($IncludeWlanIp) { $out['WlanIp'] = '' }

    $parts = @()
    foreach ($p in $Properties) {
        $parts += "getprop $p"
        $parts += "echo $marker"
    }
    if ($IncludeWlanIp) {
        $parts += "ip -f inet addr show wlan0"
        $parts += "echo $marker"
    }

    # The outer quotes make the whole script ONE token for Invoke-AdbCmd's tokenizer,
    # which Invoke-Adb then re-quotes for the command line - so adb hands the entire
    # string to the device shell, unsplit.
    $cmd = 'shell "' + ($parts -join '; ') + '"'

    $lines = Invoke-AdbCmd -Device $Device -Command $cmd -TimeoutSeconds $TimeoutSeconds -adb $adb
    if ($lines -eq $false) { return $out }

    # Split the output back into one segment per requested item, in order.
    $segments = @()
    $current  = @()
    foreach ($line in @($lines)) {
        if ($line.Trim() -eq $marker) {
            $segments += ,@($current)
            $current = @()
        } else {
            $current += $line
        }
    }

    $i = 0
    foreach ($p in $Properties) {
        if ($i -lt $segments.Count) { $out[$p] = (@($segments[$i]) -join '').Trim() }
        $i++
    }
    if ($IncludeWlanIp -and $i -lt $segments.Count) {
        foreach ($line in @($segments[$i])) {
            if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') {
                $out['WlanIp'] = $Matches[1]
                break
            }
        }
    }

    return $out
}


function Start-AdbServer {
    <#
    .SYNOPSIS
    Starts ADB server if not already running.
    
    .DESCRIPTION
    Checks if ADB server is running and starts it if needed using the specified adb.exe path.
    
    .EXAMPLE
    Start-AdbServer -adb "C:\adb\adb.exe"
    #>
    param (
        [string]$adb = $global:adbPath
    )

    try {
        # Check if ADB process is running
        $adbProcess = Get-Process -Name "adb" -ErrorAction SilentlyContinue
        if (-not $adbProcess) {
            $i = 0
            while ($i -lt 5){
                $adbProcess = Get-Process -Name "adb" -ErrorAction SilentlyContinue
                if (-not $adbProcess) {
                    Write-Log ($msg.ADBServerNotRunning) -Level WARNING
                    $null = Start-Process -FilePath $adb -ArgumentList "start-server" -NoNewWindow
                    Start-Sleep -Seconds 3
                }
                else{
                    Write-Log ($msg.ADBServerStarted) -Level SUCCESS
                    return $true
                }
                $i++
            }
        }
        else {
            Write-Log ($msg.ADBServerAlreadyRunning -f $($adbProcess.Id)) -Level INFO
            return $true
        }
    }
    catch {
        Write-Log ($msg.FailedStartADBServer -f $_) -Level ERROR
        return $false
    }
}


function Stop-AdbServer {
    <#
    .SYNOPSIS
    Stops this install's own local ADB server process, if one is running.

    .DESCRIPTION
    "adb start-server" forks a background server process that outlives the app by
    design - Start-AdbServer / Confirm-AppPortsAvailable deliberately reuse it
    across restarts to skip re-authorizing headsets. That also means it outlives
    the app when the goal is to delete the whole install folder (e.g. a release
    candidate extracted for testing): the running adb.exe keeps a file lock on
    itself under sources\, and nothing else in this app ever stops it.

    Only kills adb.exe processes whose path is under THIS install's sources\
    folder, so an unrelated adb server (Android Studio, a different VRHM install)
    is never touched. Called from Invoke-AppShutdown on every shutdown/restart.
    reaper.ps1 carries its own copy of this same path-matching logic for the
    crash path, since it intentionally does not dot-source modules.

    .EXAMPLE
    Stop-AdbServer
    #>
    param (
        [string]$SourcesFolder = (Join-Path $global:ScriptPath "sources")
    )

    try {
        $prefix = $SourcesFolder.TrimEnd('\') + '\'
        $killed = $false
        Get-Process -Name "adb" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.Path -and $_.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                    $killed = $true
                }
            } catch { }
        }
        if ($killed) { Write-Log $msg.ADBServerStopped -Level DEBUG }
    } catch {
        Write-Log ($msg.ADBServerStopFailed -f $_) -Level WARNING
    }
}


# Example usage:
#

function Install-OculusWirelessAdbApk {
    <#
    .SYNOPSIS
    Installs the WiFi ADB APK on a connected headset.

    .DESCRIPTION
    - Accepts an optional $Device object (from Get-AdbUsbDevice or Get-AdbWifiDevice).
    - If no $Device is supplied, auto-detects a USB-connected device.
    - Checks if the APK is already installed, installs/reinstalls, grants permissions,
      launches the app, and enables TCP/IP mode.
    #>
    param (
        [PSCustomObject]$Device = $null,
        [string]$adb = $global:adbPath
    )

    $apkPath     = $global:ADBWirelessActivatorAPK
    $packageName = $global:ADBWirelessActivatorPackageName

    # 1. Pre-flight verification
    if (-not (Test-Path -LiteralPath $adb)) {
        Write-Log ($msg.ADBNotFound -f $global:adbFolder) -Level ERROR
        return $false
    }
    if (-not (Test-Path -LiteralPath $apkPath)) {
        Write-Log ($msg.ApkNotFound -f $apkPath) -Level ERROR
        return $false
    }

    # 2. Resolve device - auto-detect USB if not provided
    if (-not $Device) {
        & $adb usb 2>$null
        $Device = Get-AdbUsbDevice -adb $adb
        if (-not $Device) {
            Write-Log ($msg.NoHeadsetDetected) -Level WARNING
            return $false
        }
    }
    $deviceId = $Device.DeviceId

    # Retrieve the model
    $headsetModel = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.product.model" -adb $adb) -join '').Trim()
    Write-Log ($msg.HeadsetDetected -f $headsetModel, $deviceId) -Level INFO

    try {
        # 3. Check for existing installation
        $pmOut = Invoke-AdbCmd -Device $Device -Command "shell pm list packages $packageName" -adb $adb
        $isInstalled = $pmOut -ne $false -and ($pmOut -match "^package:$([regex]::Escape($packageName))$")
        if ($isInstalled) {
            $version = ((Invoke-AdbCmd -Device $Device -Command "shell dumpsys package $packageName" -adb $adb | Select-String "versionName") -split '=' | Select-Object -Last 1)
            Write-Log ($msg.ApkAlreadyInstalled -f $packageName, $version) -Level INFO
            Write-Log ($msg.Reinstalling) -Level INFO
        } else {
            # 4. Installation if missing
            Write-Log ($msg.InstallingApk) -Level INFO
            $installResult = Invoke-AdbCmd -Device $Device -Command "install -r `"$apkPath`"" -TimeoutSeconds 120 -adb $adb
            if ($installResult -eq $false) {
                Write-Log ($msg.ApkInstallFailed) -Level ERROR
                return $false
            }
        }

        # 5. Apply critical permissions
        Write-Log ($msg.ConfiguringPermissions) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell pm grant $packageName android.permission.WRITE_SECURE_SETTINGS" -adb $adb | Out-Null
        Invoke-AdbCmd -Device $Device -Command "shell pm grant $packageName android.permission.READ_LOGS" -adb $adb | Out-Null

        # 6. Launch app on headset
        Invoke-AdbCmd -Device $Device -Command "shell am start -n `"$packageName/.MainActivity`"" -adb $adb | Out-Null

        # 7. Activate TCP/IP
        Write-Log ($msg.ActivatingWifiAdbMode) -Level INFO
        Invoke-AdbCmd -Device $Device -Command ("tcpip {0}" -f (Get-ClassicAdbPort)) -adb $adb | Out-Null
        Start-Sleep -Seconds 2

        return $true
    } catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Test-HeadsetAdbTlsSupported {
    <#
    .SYNOPSIS
    $false for a brand whose firmware cannot run Wireless debugging (ADB over TLS), else $true.

    .DESCRIPTION
    PICO (measured on a PICO 4 Ultra, Android 14, 2026-10-23): adbd has the pairing libraries, but
    AdbDebuggingManager cannot start com.android.systemui/.wifi.WifiDebuggingActivity (the "allow
    wireless debugging on this network" dialog, absent from Pico's SystemUI), so
    `settings put global adb_wifi_enabled 1` is reset to 0 within a second. See ADR-0038.
    A blank or unknown brand counts as supported (nothing is known against it). Pure, no I/O.

    .EXAMPLE
    Test-HeadsetAdbTlsSupported -Brand 'Pico'   # False
    #>
    param([string]$Brand = '')
    return ($Brand -notmatch '(?i)pico')
}

function Install-AdbAutoEnableApk {
    <#
    .SYNOPSIS
    Installs and fully configures the ADB auto-enable app (eu.project_simple.adbautoenable) on a headset (S10-6).

    .DESCRIPTION
    The app re-enables Wireless debugging at every boot, so it only helps once it holds
    WRITE_SECURE_SETTINGS and POST_NOTIFICATIONS, its accessibility service is enabled and it was
    started once. Steps (each reported in Steps, a failed one does not hide the others):
    install -r -d, grants, accessibility service APPENDED to the enabled list (never overwritten),
    adb_wifi_enabled, app start and, when classic WiFi ADB is enabled, adb tcpip + adb connect.
    The caller must hold Set-UsbBusy: tcpip re-enumerates the USB transport.

    .EXAMPLE
    $r = Install-AdbAutoEnableApk -Device (Get-AdbUsbDeviceDetails); $r.Steps | Format-Table Name, Ok, Detail
    #>
    param (
        [PSCustomObject]$Device = $null,
        [string]$adb = $global:adbPath
    )

    $apkPath = $global:ADBAutoEnableAPK
    $pkg     = $global:ADBAutoEnablePackageName
    $steps   = New-Object System.Collections.ArrayList
    $result  = @{ Ok = $false; Steps = @(); Reinstalled = $false; Error = '' }

    $addStep = {
        param([string]$Name, [bool]$Ok, [string]$Detail)
        [void]$steps.Add(@{ Name = $Name; Ok = $Ok; Detail = $Detail })
        $lvl = if ($Ok) { 'INFO' } else { 'ERROR' }
        Write-Log ($msg.AdbWifi.AutoEnableStep -f $Name, $Detail) -Level $lvl
    }

    if (-not (Test-Path -LiteralPath $adb)) {
        $result.Error = ($msg.ADBNotFound -f $global:adbFolder)
        Write-Log $result.Error -Level ERROR
        return $result
    }
    if (-not $apkPath -or -not (Test-Path -LiteralPath $apkPath)) {
        $result.Error = ($msg.AdbWifi.AutoEnableApkMissing -f $apkPath)
        Write-Log $result.Error -Level ERROR
        return $result
    }
    if ($pkg -notmatch '^[A-Za-z0-9._]+$') {
        $result.Error = "Invalid package name: $pkg"
        Write-Log $result.Error -Level ERROR
        return $result
    }
    if (-not $Device) {
        $Device = Get-AdbUsbDevice -adb $adb
        if (-not $Device) {
            $result.Error = $msg.AdbWifi.AutoEnableNoUsb
            Write-Log $result.Error -Level WARNING
            return $result
        }
    }
    # The app only re-enables Wireless debugging, which a Pico cannot run (ADR-0038): refuse
    # before installing anything.
    if (Get-Command Get-HeadsetBrandModel -ErrorAction SilentlyContinue) {
        $bm = $null
        try { $bm = Get-HeadsetBrandModel -Device $Device -adb $adb } catch { }
        if ($bm -and -not (Test-HeadsetAdbTlsSupported -Brand ([string]$bm.Brand))) {
            $result.Error = ($msg.AdbWifi.TlsUnsupportedBrand -f $bm.Brand)
            Write-Log $result.Error -Level WARNING
            return $result
        }
    }
    Write-Log ($msg.AdbWifi.AutoEnableInstalling -f $Device.DeviceId) -Level INFO

    # a. install / reinstall
    try {
        $pm = Invoke-AdbCmd -Device $Device -Command "pm list packages $pkg" -ShellScript -adb $adb -SilentOnFail
        $result.Reinstalled = ($pm -ne $false) -and [bool](@($pm) | Where-Object { $_ -match "^package:$([regex]::Escape($pkg))\s*$" })
        $out = Invoke-AdbCmd -Device $Device -Command "install -r -d `"$apkPath`"" -TimeoutSeconds 120 -adb $adb
        $okInstall = ($out -ne $false) -and [bool](@($out) -match 'Success')
        & $addStep 'install' $okInstall $(if ($okInstall) { $(if ($result.Reinstalled) { 'reinstalled' } else { 'installed' }) } else { (@($out) -join ' ') })
    } catch {
        & $addStep 'install' $false $_.Exception.Message
    }
    if (-not $steps[0].Ok) {
        $result.Steps = @($steps)
        $result.Error = ($msg.AdbWifi.AutoEnableFailed -f $steps[0].Detail)
        return $result
    }

    # b. permissions
    foreach ($perm in 'WRITE_SECURE_SETTINGS', 'POST_NOTIFICATIONS') {
        try {
            $r = Invoke-AdbCmd -Device $Device -Command "pm grant $pkg android.permission.$perm" -ShellScript -adb $adb
            & $addStep "grant $perm" ($r -ne $false) $(if ($r -ne $false) { 'granted' } else { 'pm grant failed' })
        } catch { & $addStep "grant $perm" $false $_.Exception.Message }
    }

    # c. accessibility service: append, never overwrite another enabled service
    try {
        $component = "$pkg/$pkg.AdbPopupAccessibilityService"
        $cur = ((Invoke-AdbCmd -Device $Device -Command 'settings get secure enabled_accessibility_services' -ShellScript -adb $adb) -join '').Trim()
        $list = @()
        if ($cur -and $cur -ne 'null') { $list = @($cur -split ':' | Where-Object { $_ }) }
        $did = $true
        $detail = 'already enabled'
        if ($list -notcontains $component) {
            $newValue = (($list + $component) -join ':')
            $q = ConvertTo-DiagShellQuoted -Text $newValue
            $r = Invoke-AdbCmd -Device $Device -Command "settings put secure enabled_accessibility_services $q" -ShellScript -adb $adb
            $did = ($r -ne $false)
            $detail = if ($did) { 'enabled' } else { 'settings put failed' }
        }
        if ($did) {
            $r = Invoke-AdbCmd -Device $Device -Command 'settings put secure accessibility_enabled 1' -ShellScript -adb $adb
            if ($r -eq $false) { $did = $false; $detail = 'accessibility_enabled failed' }
        }
        & $addStep 'accessibility' $did $detail
    } catch { & $addStep 'accessibility' $false $_.Exception.Message }

    # d. Wireless debugging on now
    try {
        $r = Invoke-AdbCmd -Device $Device -Command 'settings put global adb_wifi_enabled 1' -ShellScript -adb $adb
        & $addStep 'wireless debugging' ($r -ne $false) $(if ($r -ne $false) { 'on' } else { 'settings put failed' })
    } catch { & $addStep 'wireless debugging' $false $_.Exception.Message }

    # e. start the app once (it closes itself and starts its watchdog service)
    try {
        $r = Invoke-AdbCmd -Device $Device -Command "am start -n `"$pkg/.MainActivity`"" -ShellScript -adb $adb
        & $addStep 'start' ($r -ne $false) $(if ($r -ne $false) { 'started' } else { 'am start failed' })
    } catch { & $addStep 'start' $false $_.Exception.Message }

    # f. classic mode: usable at once, no waiting for a reboot. tcpip drops USB for a few seconds.
    if ($global:ADB_wifi_classic_enabled) {
        try {
            $ip = ''
            foreach ($line in @(Invoke-AdbCmd -Device $Device -Command 'ip -f inet addr show wlan0' -ShellScript -adb $adb)) {
                if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') { $ip = $Matches[1]; break }
            }
            $port = Get-ClassicAdbPort
            Invoke-AdbCmd -Device $Device -Command "tcpip $port" -adb $adb | Out-Null
            Start-Sleep -Seconds 2
            $up = $false
            if ($ip) { $up = Connect-HeadsetWifiAdb -IPAddress $ip -AdbPort $port -adb $adb }
            & $addStep 'classic tcpip' ($up -or -not $ip) $(if ($up) { "${ip}:${port}" } elseif ($ip) { "${ip}:${port} (connect pending)" } else { 'no WiFi address read' })
        } catch { & $addStep 'classic tcpip' $false $_.Exception.Message }
    }

    $result.Steps = @($steps)
    $failed = @($steps | Where-Object { -not $_.Ok })
    $result.Ok = ($failed.Count -eq 0)
    if ($result.Ok) {
        Write-Log $msg.AdbWifi.AutoEnableDone -Level SUCCESS
        # A proper name in the apps list even offline; the icon is matched by file name (app_icons).
        try {
            Save-AppCatalogEntry -Entry ([PSCustomObject]@{ PackageName = $pkg; DisplayName = "ADB Auto Enable"; ThirdParty = $true }) | Out-Null
        } catch { Write-Log "Catalogue entry for $pkg not saved: $($_.Exception.Message)" -Level DEBUG }
    } else {
        $result.Error = ($msg.AdbWifi.AutoEnableFailed -f (($failed | ForEach-Object { $_.Name }) -join ', '))
        Write-Log $result.Error -Level ERROR
    }
    return $result
}


function Uninstall-AdbAutoEnableApk {
    <#
    .SYNOPSIS
    Removes the ADB auto-enable app (eu.project_simple.adbautoenable) from a headset (S10-6).
    Its accessibility entry goes with the package. Returns @{Ok;Error}. Never throws.

    .EXAMPLE
    Uninstall-AdbAutoEnableApk -Device $device
    #>
    param (
        [Parameter(Mandatory = $true)][PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    $pkg = $global:ADBAutoEnablePackageName
    if ($pkg -notmatch '^[A-Za-z0-9._]+$') { return @{ Ok = $false; Error = "Invalid package name: $pkg" } }
    try {
        $out = Invoke-AdbCmd -Device $Device -Command "uninstall $pkg" -TimeoutSeconds 60 -adb $adb
        $ok = ($out -ne $false) -and [bool](@($out) -match 'Success')
        if ($ok) {
            Write-Log ($msg.AdbWifi.AutoEnableUninstalled -f $Device.DeviceId) -Level INFO
            return @{ Ok = $true; Error = '' }
        }
        return @{ Ok = $false; Error = (@($out) -join ' ') }
    } catch {
        Write-Log ("Uninstall-AdbAutoEnableApk failed: {0}" -f $_.Exception.Message) -Level ERROR
        return @{ Ok = $false; Error = $_.Exception.Message }
    }
}


function Test-AdbDevicesAuthorization {
    # Checks if a headset is connected and authorized for USB debugging
    param (
        [string]$adb = $global:adbPath
    )

    $maxAttempts = 3
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $devices = & $adb devices 2>&1 | Where-Object { $_ -notmatch '^List of devices attached' }
        $unauthorizedFound = $false

        # Parse ADB output
        foreach ($line in $devices) {
            if ($line -like "*unauthorized*") {
                Write-Log ($msg.UsbDebugNotAuthorized) -Level WARNING
                $unauthorizedFound = $true
            }
        }

        if ($unauthorizedFound) {
            $attempt++
            $response = Read-Host ($msg.RetryPrompt -f $attempt, $maxAttempts)
            if ($response -eq '0') {
                Write-Log ($msg.UserCancelled) -Level INFO
                return $false
            }
            continue
        }

        if (-not $devices -or $devices -like "*daemon*") {
            Write-Log ($msg.NoUsbHeadsetOrDaemonIssue) -Level WARNING
            Write-Log ($msg.DeveloperModeHint) -Level WARNING
            return $false
        }

        # If we reach this point, everything is OK
        return $true
    }

    Write-Log ($msg.MaxAttemptsReached -f $maxAttempts) -Level ERROR
    return $false
}


function Enable-WiFiADB {
    <#
    .SYNOPSIS
    Enables WiFi ADB mode on a Meta Quest headset connected via USB

    .DESCRIPTION
    - Detects a headset connected via USB
    - Retrieves its WiFi IP address
    - Enables TCP/IP mode
    - Verifies the port is open

    .PARAMETER AdbPort
    Port to use for ADB (default: config ADB.adbPort_default)

    .EXAMPLE
    Enable-WiFiADB -AdbPort 5555
    #>

    param(
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb = $global:adbPath
    )

    # 1. Initial verification
    if (-not (Test-Path -LiteralPath $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $false
    }

    # Resolve WiFi credentials from secure store
    $knownNetworks = Get-WifiNetworks
    $preferredNet  = $knownNetworks | Where-Object { $_.Preferred } | Select-Object -First 1
    if (-not $preferredNet) { $preferredNet = $knownNetworks | Select-Object -First 1 }
    if (-not $preferredNet) {
        Write-Log $msg.Wifi.NoNetworkConfigured -Level ERROR
        return $false
    }
    $wifi_ssid = $preferredNet.SSID
    $wifi_pwd  = $preferredNet.Password

    Write-Log ($msg.SearchingUsbHeadset) -Level INFO
    try {

        # 2. USB Device Detection
        $usbDevice = Get-AdbUsbDevice -adb $adb
        if (-not $usbDevice) {
            Write-Log ($msg.NoUsbAdbDevice) -Level ERROR
            Write-Log ($msg.BackToMainMenu) -Level INFO
            Start-Sleep -Seconds 3
            return $false
        }

        # 3. Check if the device is authorized for USB debugging
        if (-not (Test-AdbDevicesAuthorization)) { # Ensure this works only via USB when other headsets are connected via ADB WiFi
            return $false
        }

        $deviceId = $usbDevice.DeviceId
        # Retrieve brand + friendly model name (brand-aware: Quest uses ro.product.model,
        # Pico uses pxr.vendorhw.product.model).
        $bm = Get-HeadsetBrandModel -Device $usbDevice -adb $adb
        $headsetBrand = $bm.Brand
        $headsetModel = $bm.Model
        Write-Log ($msg.HeadsetDetected -f $headsetModel, $deviceId) -Level INFO

        # Step 3: Check SSID (filter in PowerShell to avoid shell pipe issues on some Android builds)
        $wifiInfo = (Invoke-AdbCmd -Device $usbDevice -Command "shell dumpsys wifi" -adb $adb) | Select-String 'mWifiInfo'

        if ($wifiInfo -match 'SSID: "([^"]+)"') {
            $currentSSID = $matches[1]  # Returns the SSID without quotes
            Write-Log ($msg.CurrentlyConnectedSsid -f $currentSSID) -Level INFO
        }

        # Step 4: Verify the connected SSID
        $onKnownNetwork = $knownNetworks | Where-Object { $currentSSID -match [regex]::Escape($_.SSID) }
        if ($onKnownNetwork) {
            Write-Log ($msg.Wifi.HeadsetOnKnownNetwork -f $currentSSID) -Level INFO
        } elseif ($currentSSID -notmatch [regex]::Escape($wifi_ssid)) {
            Write-Log ($msg.HeadsetNotConnectedToSsid -f $wifi_ssid) -Level WARNING

            $switchChoice = (Read-Host ($msg.SwitchToSsidPrompt -f $wifi_ssid)).ToUpper()
            if ($switchChoice -eq 'Y') {
                if (-not (Connect-HeadsetToWifi -Device $usbDevice -Ssid $wifi_ssid -Password $wifi_pwd -Brand $headsetBrand)) {
                    return $false
                }
                Start-Sleep -Seconds 5
            } else {
                Write-Log ($msg.KeepingCurrentWifi) -Level INFO
            }
        }





        # 3. Retrieve WiFi IP
        Write-Log ($msg.RetrievingIp) -Level INFO
        $ipInfo = (Invoke-AdbCmd -Device $usbDevice -Command "shell ip -f inet addr show wlan0" -adb $adb) |
                  Select-String 'inet' |
                  ForEach-Object { ($_ -split '\s+')[2] -split '/' | Select-Object -First 1 }

        if (-not $ipInfo) {
            Write-Log ($msg.UnableRetrieveIp) -Level ERROR
            return $false
        }

        Write-Log ($msg.Wifi.IpDetected -f $ipInfo) -Level INFO

        # 4. Install OculusWirelessAdb APK
        $answer = Read-Host $msg.UsbInstallPrompt
        if ($answer.ToUpper() -eq "Y")
            {Install-OculusWirelessAdbApk}
        else {
        # 5. Enable TCP/IP mode

            Write-Log ($msg.ActivatingWifiAdbPort -f $AdbPort) -Level INFO
            Invoke-AdbCmd -Device $usbDevice -Command "tcpip $AdbPort" -adb $adb | Out-Null
        }
        Start-Sleep -Seconds 5  # Wait for initialization
        # 6. Port verification
        Write-Log ($msg.CheckingPortOpen -f $AdbPort) -Level INFO
        $portTest = $(Test-Port -hostname $ipInfo -port $AdbPort).open
        
        if ($portTest) {
            Write-Log ($msg.PortOpened -f $AdbPort, $ipInfo) -Level SUCCESS
            
            # Identify the headset by serial so it is registered (or healed) under its
            # permanent identity. This path used to create rows with an empty serial and
            # model, which left them unable to participate in identity healing at all.
            $usbSerial = ((Invoke-AdbCmd -Device $usbDevice -Command "shell getprop ro.serialno" -adb $adb) -join '').Trim()

            $knownHeadsets = Get-KnownHeadsets
            $alreadyKnown  = $knownHeadsets | Where-Object {
                ($usbSerial -and ([string]$_.SerialNumber).Trim() -eq $usbSerial) -or $_.IPAddress -eq $ipInfo
            } | Select-Object -First 1

            if ($alreadyKnown) {
                Write-Log ($msg.IpAlreadyKnown) -Level INFO
                if ($usbSerial) {
                    # Known headset seen over USB: authoritative, so refresh its address.
                    Set-HeadsetIdentity -SerialNumber $usbSerial -IPAddress $ipInfo -Model $headsetModel `
                                        -Brand $headsetBrand -Source 'usb-local' | Out-Null
                }
            }
            else {
                $choice = (Read-Host $msg.AddToKnownPrompt).ToUpper()

                switch ($choice) {
                    'Y' {   Write-Log ($msg.AddingHeadsetToList) -Level INFO
                            $headsetName = Read-Host ($msg.HeadsetNamePrompt)
                            if ($usbSerial) {
                                Set-HeadsetIdentity -SerialNumber $usbSerial -IPAddress $ipInfo -Name $headsetName `
                                                    -Model $headsetModel -Brand $headsetBrand -AllowAdd -Source 'usb-local' | Out-Null
                                # An explicit operator add overrides an earlier "forget".
                                if (Get-Command Remove-HeadsetDiscoveryIgnore -ErrorAction SilentlyContinue) {
                                    Remove-HeadsetDiscoveryIgnore -SerialNumber $usbSerial | Out-Null
                                }
                            } else {
                                # No serial readable - fall back to an IP-only row, which the
                                # monitor will key on first successful contact.
                                Add-Headset -Name $headsetName -IPAddress $ipInfo -Model $headsetModel
                            }
                        }
                    default {
                        Write-Log ($msg.ReturnToMainMenu) -Level INFO
                    }
                }
            }
        }
        else {
            Write-Log ($msg.PortOpenFailed -f $AdbPort) -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-AdbUsbDevice {
    <#
    .SYNOPSIS
    Detects a USB-connected ADB device and returns a device object, or $null if none found.

    .DESCRIPTION
    Returns a PSCustomObject: DeviceId (USB serial), ConnectionType='USB', IP=$null, Port=$null.
    Prompts the user to retry (or press Q to cancel) on each failed attempt.
    #>
    param (
        [int]$MaxAttempts = 5,
        [string]$adb = $global:adbPath
    )

    if (-not (Test-Path -LiteralPath $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $null
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $usbLine = & $adb devices |
                Where-Object { $_ -match "`tdevice$" -and (Test-AdbDeviceIdIsUsb -Id (($_ -split "`t")[0].Trim())) } |
                Select-Object -First 1
            if ($usbLine) {
                $serial = ($usbLine -split "`t")[0].Trim()
                Write-Log ($msg.UsbAdbDeviceDetected) -Level SUCCESS
                return [PSCustomObject]@{ DeviceId = $serial; ConnectionType = 'USB'; IP = $null; Port = $null }
            }
        } catch {
            Write-Log ($msg.ADBExecutionFailed -f $_.Exception.Message) -Level ERROR
        }
        Write-Log ($msg.NoUsbHeadsetDetectedPrompt) -Level INFO
        if ((Read-Host) -match "^[Qq]$") {
            Write-Log ($msg.UserCancelledUsbDetection) -Level INFO
            return $null
        }
    }

    Write-Log ($msg.NoUsbAdbDeviceFound -f $MaxAttempts) -Level ERROR
    return $null
}


function Get-UsbDeviceSpeed {
    <#
    .SYNOPSIS
    Returns "USB 3" or "USB 2.0" for a connected USB device identified by ADB serial number,
    by walking the PnP parent chain to find whether the host controller is xHCI (USB 3) or EHCI (USB 2).
    Returns $null if the device is not found or the controller type cannot be determined.
    #>
    param([string]$Serial)
    if (-not $Serial) { return $null }

    # Memoized per serial. A device's negotiated USB link speed cannot change
    # while it stays plugged into the same port, so this is a constant for the
    # lifetime of the connection - yet /api/headset-connection-check is polled
    # every 5 s by the apps page, and this used to redo the whole tree walk each
    # time.
    if (-not $script:UsbSpeedCache) { $script:UsbSpeedCache = @{} }
    if ($script:UsbSpeedCache.ContainsKey($Serial)) { return $script:UsbSpeedCache[$Serial] }

    try {
        # Filter in the provider, not in PowerShell. The old form was
        # "Get-PnpDevice -PresentOnly | Where-Object InstanceId -like ...", which
        # enumerates EVERY present device on the machine and discards almost all
        # of them client-side.
        $device = Get-PnpDevice -PresentOnly -InstanceId "USB\*\$Serial" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $device) {
            # Wildcard -InstanceId is not honoured on every Windows build; fall
            # back to a server-side CIM filter rather than to a full enumeration.
            $esc = $Serial -replace "'", "''"
            $device = Get-CimInstance -ClassName Win32_PnPEntity `
                        -Filter "DeviceID LIKE 'USB%\\$esc'" -ErrorAction SilentlyContinue |
                      Select-Object -First 1
            if ($device -and -not $device.InstanceId) {
                $device = [PSCustomObject]@{ InstanceId = $device.DeviceID }
            }
        }
        if (-not $device) { return $null }

        # Every exit below assigns $speed and falls through to the single cache
        # write at the end - an early "return" here would skip the memo and make
        # the cache never fill for the fast (most common) paths.
        $speed     = $null
        $currentId = $device.InstanceId
        for ($i = 0; $i -lt 8; $i++) {
            $prop = Get-PnpDeviceProperty -InstanceId $currentId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
            if (-not $prop -or -not $prop.Data) { break }
            $parentId = $prop.Data

            # InstanceId of the controller often contains the controller type
            if ($parentId -match 'xHCI|XHCI') { $speed = 'USB 3.0'; break }
            if ($parentId -match 'EHCI|ehci') { $speed = 'USB 2.0'; break }

            # Fall back to device friendly name / description
            $parentDev = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue
            if ($parentDev) {
                $name = "$($parentDev.FriendlyName) $($parentDev.Description)"
                if ($name -match 'xHCI|SuperSpeed|USB 3') { $speed = 'USB 3.0'; break }
                if ($name -match 'EHCI|USB 2')            { $speed = 'USB 2.0'; break }
            }
            $currentId = $parentId
        }

        # Cache negatives too: a device whose controller type cannot be determined
        # will not become determinable on the next poll, and re-walking eight
        # parent hops to rediscover that is the worst case, not the cheap one.
        $script:UsbSpeedCache[$Serial] = $speed
        return $speed
    } catch {
        return $null
    }
}


function Get-PublishedUsbDevices {
    <#
    .SYNOPSIS
    The cabled USB transports VRMonitor last published (app_kv row 'usb_devices'), as
    @(@{Serial;State;Since}). @() when nothing is cabled or nothing was published yet.

    .DESCRIPTION
    Reads what usb_manager.ps1 already saw instead of spawning "adb devices" - one cheap
    scalar read, memoised for -MaxAgeSec so a burst of ADB calls (a poll cycle runs several)
    costs one read. The memo is per process/runspace, like the database connection itself.
    Never throws: a transport lookup must not be able to take down a poll or a request.

    .EXAMPLE
    (Get-PublishedUsbDevices | Where-Object Serial -eq '1WMHH123').Since
    #>
    param([int]$MaxAgeSec = 2, [switch]$IncludeDead)

    try {
        $now = [datetime]::UtcNow
        if (-not $IncludeDead -and $null -ne $script:UsbDevicesCache -and $script:UsbDevicesCacheAt -and
            (($now - $script:UsbDevicesCacheAt).TotalSeconds -lt $MaxAgeSec)) {
            return @($script:UsbDevicesCache)
        }

        $list = @()
        if (Get-Command Get-DbKeyValue -ErrorAction SilentlyContinue) {
            $raw = Get-DbKeyValue -Key 'usb_devices'
            if ($raw) {
                $parsed = $null
                if ($raw -is [string]) {
                    if ($raw -ne 'null' -and -not [string]::IsNullOrWhiteSpace($raw)) { $parsed = $raw | ConvertFrom-Json }
                } else {
                    $parsed = $raw
                }
                $list = @($parsed | Where-Object { $_ -and $_.Serial })
            }
        }
        if ($IncludeDead) { return @($list) }

        # Drop the entries THIS process has just watched fail. The published set is one slow tick
        # old at best, and after an unplug it can say "cabled" for as long as the monitor takes to
        # tick again (it did not, for over a minute, in a real run) - during which every call tried
        # the dead cable first. Register-UsbTransportFailure remembers the exact plug instance
        # (its Since stamp) that failed; the entry is ignored while it is still that same instance
        # and for a bounded time. A real re-plug gets a new Since from the monitor and is trusted
        # at once, and the time bound lets a transient failure on a cable that is really there heal.
        if ($script:UsbDeadMemo -and $script:UsbDeadMemo.Count -gt 0) {
            $keep = @()
            foreach ($e in $list) {
                $m = $script:UsbDeadMemo[[string]$e.Serial]
                if ($m) {
                    $age = ($now - $m.At).TotalSeconds
                    $deadSec = if ($script:UsbDeadMemoSec) { [int]$script:UsbDeadMemoSec } else { 60 }
                    if ($m.Since -eq [string]$e.Since -and $age -lt $deadSec) { continue }
                    $script:UsbDeadMemo.Remove([string]$e.Serial)
                }
                $keep += $e
            }
            $list = $keep
        }

        $script:UsbDevicesCache   = $list
        $script:UsbDevicesCacheAt = $now
        return @($list)
    } catch {
        return @()
    }
}

# How long a cable entry that has just failed is ignored (see Get-PublishedUsbDevices).
$script:UsbDeadMemoSec = 60


function Register-UsbTransportFailure {
    <#
    .SYNOPSIS
    Records that the USB transport of one headset just failed, so every later lookup in this
    process stops choosing it until the cable is really re-plugged (or 60 s pass).

    .DESCRIPTION
    Called by Invoke-AdbCmd the moment a USB device hits a transport failure. It marks the
    CURRENT published entry for that serial (matched on its Since stamp) as unusable for this
    process. The memo is per process and per runspace on purpose: each learns from its own first
    failed call, with no shared state to keep consistent. Does nothing when the serial is not in
    the published set.

    .EXAMPLE
    Register-UsbTransportFailure -Serial '2G0YC5ZG1W00ZJ'
    #>
    param([Parameter(Mandatory=$true)][string]$Serial)

    # This runs inside the failure path of every ADB call, so it must never be the thing that
    # throws: a bookkeeping error here would turn a recoverable cable drop into a failed command.
    try {
        if (-not $script:UsbDeadMemo) { $script:UsbDeadMemo = @{} }
        $entry = @(Get-PublishedUsbDevices -IncludeDead | Where-Object { $_.Serial -eq $Serial }) | Select-Object -First 1
        if (-not $entry) { return }
        $already = $script:UsbDeadMemo[$Serial]
        $script:UsbDeadMemo[$Serial] = @{ Since = [string]$entry.Since; At = [datetime]::UtcNow }
        $script:UsbDevicesCache = $null
        if (-not $already -or $already.Since -ne [string]$entry.Since) {
            Write-Log ("USB transport of {0} failed - ignoring the published cable entry (since {1}) until it is re-plugged." -f $Serial, $entry.Since) -Level INFO
        }
    } catch { }
}


function Resolve-HeadsetAdbDevice {
    <#
    .SYNOPSIS
    The ADB device object for a KNOWN headset: USB when it is cabled to this PC, WiFi
    otherwise, with the other transport as the fallback.

    .DESCRIPTION
    USB is faster, steadier and does not depend on the headset's WiFi. The cabled set comes
    from the snapshot VRMonitor publishes (Get-PublishedUsbDevices) - no "adb devices" per
    call. USB is skipped while an operator action holds it (Test-UsbBusy: those run
    "adb usb"/"adb tcpip", which re-enumerate the transport for seconds).

    -PreferTransport only changes the ORDER, never whether a headset is reachable:
      Auto  follow config ADB.prefer_usb (USB first when true, WiFi first when false)
      USB   USB first, WiFi if the headset is not cabled
      WiFi  WiFi first, USB if the WiFi transport cannot be established

    WiFi has two modes (ADR-0034): classic (registry address + ADB.adbPort_default) and ADB over
    TLS (the published endpoint of the serial). They are tried in the order of
    ADB.wifi_preferred_mode, the second being the fallback (Resolve-HeadsetWifiDevice in
    adb_wifi_modes.ps1). -AdbPort is the CLASSIC port (0 = config).

    The returned object carries SerialNumber, HeadsetIP and HeadsetPort next to the usual
    DeviceId / ConnectionType / IP / Port, plus WifiMode ('Classic' or 'TLS') for a WiFi device.
    Invoke-AdbCmd uses them to retry once over WiFi if a USB device's cable drops mid-command,
    and once over the other WiFi mode when a WiFi transport fails. $null when nothing works.

    LAN discovery, the network scanner and USB onboarding deliberately do NOT use this:
    they act on a device that is not (yet) a known headset.

    .EXAMPLE
    $dev = Resolve-HeadsetAdbDevice -Headset $headset
    Invoke-AdbCmd -Device $dev -Command "shell getprop ro.product.model"
    #>
    param (
        [Parameter(Mandatory=$true)] $Headset,
        [ValidateSet('Auto','USB','WiFi')][string]$PreferTransport = 'Auto',
        [string]$adb = $global:adbPath,
        [int]$AdbPort = 0
    )

    if ($AdbPort -le 0) { $AdbPort = Get-ClassicAdbPort }

    $serial = if ($Headset.SerialNumber) { ([string]$Headset.SerialNumber).Trim() } else { '' }
    if ($serial -eq '-') { $serial = '' }
    $ip = if ($Headset.IPAddress -and -not (Test-UnknownIp $Headset.IPAddress)) { [string]$Headset.IPAddress } else { $null }

    $usbFirst = switch ($PreferTransport) {
        'USB'   { $true }
        'WiFi'  { $false }
        default { if ($null -ne $global:ADB_prefer_usb) { [bool]$global:ADB_prefer_usb } else { $true } }
    }

    $newUsb = {
        param($s)
        $busy = $false
        if (Get-Command Test-UsbBusy -ErrorAction SilentlyContinue) { $busy = Test-UsbBusy }
        if ($busy -or -not $s) { return $null }
        $cabled = @(Get-PublishedUsbDevices | Where-Object { $_.Serial -eq $s })
        if ($cabled.Count -eq 0) { return $null }
        return [PSCustomObject]@{
            DeviceId = $s; ConnectionType = 'USB'; IP = $null; Port = $null
            SerialNumber = $s; HeadsetIP = $ip; HeadsetPort = $AdbPort
        }
    }
    $newWifi = {
        # Mode-aware (ADR-0034): every enabled WiFi mode, preferred first.
        if (Get-Command Resolve-HeadsetWifiDevice -ErrorAction SilentlyContinue) {
            return (Resolve-HeadsetWifiDevice -Headset $Headset -ClassicPort $AdbPort -adb $adb)
        }
        # adb_wifi_modes.ps1 not loaded in this runspace: classic only, the pre-S10-3 behaviour.
        if (-not $ip) { return $null }
        $d = Get-AdbWifiDevice -headsetIP $ip -AdbPort $AdbPort -adb $adb
        if (-not $d) { return $null }
        $d | Add-Member -NotePropertyName SerialNumber -NotePropertyValue $serial -Force
        $d | Add-Member -NotePropertyName HeadsetIP    -NotePropertyValue $ip     -Force
        $d | Add-Member -NotePropertyName HeadsetPort  -NotePropertyValue $AdbPort -Force
        $d | Add-Member -NotePropertyName WifiMode     -NotePropertyValue 'Classic' -Force
        return $d
    }

    if ($usbFirst) {
        $dev = & $newUsb $serial
        if ($dev) { Write-Log ("USB transport selected for {0} (serial {1})" -f $Headset.Name, $serial) -Level DEBUG; return $dev }
        return (& $newWifi)
    }

    $dev = & $newWifi
    if ($dev) { return $dev }
    return (& $newUsb $serial)
}


function Get-BestAdbDevice {
    <#
    .SYNOPSIS
    Returns the ADB device for a known headset: USB if cabled, WiFi otherwise.
    Kept under its historical name for its existing callers; the logic is now
    Resolve-HeadsetAdbDevice, which reads the USB set VRMonitor publishes instead of
    running "adb devices" on every call.
    #>
    param (
        [Parameter(Mandatory=$true)] $Headset,
        [string]$adb = $global:adbPath,
        # 0 = the classic port from config (Get-ClassicAdbPort). It used to default to a literal
        # 5555, which silently ignored ADB.adbPort_default for every caller that passed nothing.
        [int]$AdbPort = 0
    )

    return Resolve-HeadsetAdbDevice -Headset $Headset -adb $adb -AdbPort $AdbPort
}


function Enable-AdbTcpIp {
    <#
    .SYNOPSIS
    Enables WiFi ADB (tcpip mode) on a USB-connected device. No interactive prompts.
    Designed for web server API use. Returns a result object.
    #>
    param (
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath
    )

    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) {
        return [PSCustomObject]@{ ok = $false; error = "ADB not found" }
    }

    try {
        # Wait briefly for the USB transport rather than giving up on the first look.
        #
        # The transport genuinely blips: measured on a Quest 3, it disappears from
        # "adb devices" for about a second while the app starts (the adb server is
        # restarted during startup), with NO Windows PnP event - the device stays
        # enumerated, only the ADB transport goes. An operator pressing the button
        # during that window used to get a flat "No USB headset detected", and the
        # non-regression suite failed intermittently for the same reason.
        # 15s, not 5s: tcpip re-enumeration takes about ten seconds, and the most
        # likely reason USB is briefly absent is that something just ran tcpip -
        # including the VRMonitor USB watcher onboarding this very headset.
        $usbLine  = $null
        $deadline = (Get-Date).AddSeconds(15)
        while ($true) {
            $usbLine = & $adb devices 2>$null | Where-Object { $_ -match "`tdevice$" -and (Test-AdbDeviceIdIsUsb -Id (($_ -split "`t")[0].Trim())) } | Select-Object -First 1
            if ($usbLine -or (Get-Date) -ge $deadline) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $usbLine) {
            return [PSCustomObject]@{ ok = $false; error = "No USB headset detected" }
        }
        $deviceId  = ($usbLine -split "`t")[0].Trim()
        $usbDevice = [PSCustomObject]@{ DeviceId = $deviceId; ConnectionType = 'USB'; IP = $null; Port = $null }

        # Model and the wlan0 address in one batched call instead of two round-trips.
        $bm    = Get-HeadsetBrandModel -Device $usbDevice -adb $adb
        $model = if ($bm) { $bm.Model } else { '' }
        $net   = Get-AdbPropBatch -Device $usbDevice -adb $adb -IncludeWlanIp
        $ip    = $net['WlanIp']

        # Short-circuit when WiFi ADB is ALREADY live for this headset.
        #
        # The IP is read BEFORE tcpip precisely so this check can exist. Firing
        # tcpip unconditionally re-enumerates the USB transport - a measured ~10s
        # outage - so doing it when the transport is already up is pure harm: it
        # breaks USB for ten seconds to reach a state we were already in. The
        # VRMonitor watcher may well have onboarded this headset seconds ago.
        if ($ip) {
            $alreadyUp = [bool](& $adb devices 2>$null |
                Where-Object { $_ -match ("^" + [regex]::Escape("${ip}:${AdbPort}") + "\s+device$") })
            if ($alreadyUp) {
                Write-Log ($msg.AdbWifiAlreadyConnected -f "${ip}:${AdbPort}") -Level DEBUG
                return [PSCustomObject]@{ ok = $true; model = $model; ip = $ip; port = $AdbPort; connected = $true }
            }
        }

        # Enable TCP/IP mode
        Invoke-AdbCmd -Device $usbDevice -Command "tcpip $AdbPort" -adb $adb | Out-Null
        Start-Sleep -Seconds 2

        # Re-read the address after tcpip: on a headset that had no wlan0 address
        # a moment ago, this is the read that finds it.
        if (-not $ip) {
            $net = Get-AdbPropBatch -Device $usbDevice -adb $adb -IncludeWlanIp
            $ip  = $net['WlanIp']
        }

        # Connect, then report whether the transport actually came up.
        #
        # This tail used to be missing, and its absence was not cosmetic: "adb
        # tcpip" only puts the DEVICE into tcpip mode, it does not create the
        # host-side transport. So "adb devices" never listed ip:port, WifiAdbOpen
        # stayed false forever, the UI showed WiFi ADB as closed right after
        # reporting success - and Invoke-UsbHeadsetActions, which gates on that
        # same flag, re-fired tcpip on every tick. Each re-fire re-enumerates the
        # USB transport (measured ~10 s outage on a Quest 3). Verified on a real
        # Quest 3: after tcpip the device IS listening and a plain connect works.
        $connected = $false
        if ($ip) {
            $connected = Connect-HeadsetWifiAdb -IPAddress $ip -AdbPort $AdbPort -adb $adb
        }

        Write-Log ($msg.ActivatingWifiAdbPort -f $AdbPort) -Level INFO
        return [PSCustomObject]@{ ok = $true; model = $model; ip = $ip; port = $AdbPort; connected = $connected }
    } catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}


function Invoke-UsbHeadsetActions {
    <#
    .SYNOPSIS
    Compatibility entry point for the USB onboarding tick. The logic now lives in
    modules\usb_manager.ps1 (Update-UsbWatchState); this wrapper remains because
    the console menu and the non-regression harness refer to it by name.

    .DESCRIPTION
    The old implementation ran the FULL ~17-spawn detail probe on every VRMonitor
    slow tick, re-read the whole headset registry, and called Set-HeadsetIdentity
    unconditionally - whether or not anything had changed. It also gated its
    "already enabled" check on a WifiAdbOpen flag that could never become true
    (nothing ever ran "adb connect"), so it re-fired "adb tcpip" forever, each
    time knocking the USB transport out for about ten seconds.

    Steady state is now ONE "adb devices" call. See usb_manager.ps1's header for
    the escalation ladder.

    Returns the same shape as before, or $null when nothing is cabled.
    #>
    param (
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath
    )

    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) { return $null }
    if (-not (Get-Command Update-UsbWatchState -ErrorAction SilentlyContinue)) { return $null }

    # A private state bag: this wrapper is called on the main thread, so it applies
    # the identity write itself instead of handing it to someone else.
    if (-not $script:UsbInlineState) { $script:UsbInlineState = @{} }

    # This runs on the VRMonitor SLOW TICK, and that caller does not guard it.
    # Anything escaping here aborts the rest of the tick - service watchdogs,
    # the computer monitoring respawn, VQA - for every headset, not just this one. The
    # original implementation wrapped its whole body for exactly this reason.
    $action = 'error'
    try {
        $action = Update-UsbWatchState -SharedState $script:UsbInlineState -AdbPort $AdbPort -adb $adb
    } catch {
        Write-Log ("Invoke-UsbHeadsetActions: USB tick failed: " + $_.Exception.Message) -Level WARNING
        return $null
    }

    $req = $script:UsbInlineState['_usb_onboard_request']
    if ($req) {
        $script:UsbInlineState['_usb_onboard_request'] = $null
        try {
            # The watcher now publishes this on EVERY tick, because the registry can
            # change while USB sits still - a headset registered with a stale address
            # after the memo was seeded must still heal. So the throttle lives here,
            # and it is the headsets CHANGE COUNTER, not a timer:
            #
            #   - (serial, ip) differs from what we last applied  -> the device moved
            #   - the headsets counter moved                      -> the registry
            #                                                        changed under us
            #
            # Either way we re-check; otherwise we skip. That keeps Get-KnownHeadsets
            # (a whole-table read) off the steady-state poll path, which CLAUDE.md
            # calls out explicitly, while still healing within one tick of a change.
            $version = -1
            try { $version = [int64](Get-DbTableVersion -Name 'headsets') } catch { $version = -1 }

            $last    = $script:UsbLastApplied
            $changed = (-not $last) -or
                       ($last.Serial  -ne $req.SerialNumber) -or
                       ($last.Ip      -ne $req.IPAddress)    -or
                       ($last.Version -ne $version)          -or
                       ($version -lt 0)

            if ($changed) {
                # Only for a serial we already know: enabling WiFi ADB on an
                # unregistered device would disconnect/reconnect it repeatedly, and an
                # unknown device is the "new device" modal's business, not ours.
                $known = @(Get-KnownHeadsets) | Where-Object { $_.SerialNumber -eq $req.SerialNumber } | Select-Object -First 1
                if ($known) {
                    $res = Set-HeadsetIdentity -SerialNumber $req.SerialNumber -IPAddress $req.IPAddress `
                                               -Model $req.Model -Brand $req.Brand -Source 'usb-local'
                    if ($res -and $res.Action -and $res.Action -ne 'unchanged') {
                        Write-Log ("USB: healed '{0}' to {1} ({2})" -f $res.Name, $req.IPAddress, $res.Action) -Level INFO
                        # Our own write bumps the counter; re-read so the next tick
                        # does not see a phantom change and redo the work.
                        try { $version = [int64](Get-DbTableVersion -Name 'headsets') } catch { }
                    }
                }
                $script:UsbLastApplied = @{ Serial = $req.SerialNumber; Ip = $req.IPAddress; Version = $version }
            }
        } catch {
            Write-Log ("Invoke-UsbHeadsetActions: identity update failed: " + $_.Exception.Message) -Level WARNING
        }
    }

    $snap = $script:UsbInlineState['_usb_device']

    # Publish for the web server, on change only.
    #
    # This is what lets /api/usbdeviceinfo stop running its own probe. It used to
    # be fed by a dedicated Start-Job inside the web server - a whole extra
    # powershell.exe (measured 137 MB) holding a fourth copy of the module set,
    # re-running the full detail probe every 3 seconds forever just to answer
    # "is a new headset plugged in?" for one blinking button. There is now one
    # prober, and its result travels through app_kv (ADR-0017).
    try {
        $json = if ($snap) { $snap | ConvertTo-Json -Compress -Depth 5 } else { 'null' }
        if ($json -ne $script:UsbLastPublished) {
            $script:UsbLastPublished = $json
            if (Get-Command Set-DbKeyValue -ErrorAction SilentlyContinue) {
                Set-DbKeyValue -Key 'usb_device' -Value $json
            }
        }
    } catch {
        Write-Log ("Invoke-UsbHeadsetActions: could not publish USB snapshot: " + $_.Exception.Message) -Level DEBUG
    }

    # The cabled-device set (app_kv 'usb_devices') is published by Update-UsbWatchState itself,
    # at the top of the tick - see Publish-UsbDeviceSet.

    if (-not $snap) { return $null }

    return [PSCustomObject]@{
        deviceId       = $snap.DeviceId
        model          = $snap.Model
        ip             = $snap.IP
        serialNumber   = $snap.SerialNumber
        wifiAdbEnabled = [bool]$snap.WifiAdbOpen
        action         = $action
    }
}


function Get-AdbUsbDeviceDetails {
    <#
    .SYNOPSIS
    Full details of a USB-connected ADB device. Thin wrapper over
    Get-UsbDeviceSnapshot in modules\usb_manager.ps1, kept for its existing
    callers (console menu, web endpoints, non-regression tests).

    .DESCRIPTION
    Same return shape as before. The implementation moved so that the cheap
    presence check and the expensive detail probe could finally be separated -
    this function is the expensive one, and it is now only called when something
    actually changed or an operator asked.
    #>
    param (
        [string]$PackageName = $global:ADBWirelessActivatorPackageName,
        [int]$AdbPort        = $global:adbPort_default,
        [string]$adb         = $global:adbPath
    )
    return Get-UsbDeviceSnapshot -PackageName $PackageName -AdbPort $AdbPort -adb $adb
}


function Get-AdbWifiDevice {
    <#
    .SYNOPSIS
    Verifies WiFi ADB connectivity and returns a device object, or $null on failure.

    .DESCRIPTION
    Replaces the pattern: $DeviceId = "IP:Port" + Connect-AdbWifi call inside every function.
    Returns a PSCustomObject with DeviceId, ConnectionType='WiFi', IP, Port - ready to pass
    to any device function (Get-HeadsetBatteryStatus, Invoke-HeadsetReboot, etc.).
    .EXAMPLE
    Get-AdbWifiDevice -headsetIP "192.168.1.243" -AdbPort 5555

    -Quiet logs the failure lines at DEBUG instead of WARNING/ERROR: Resolve-HeadsetWifiDevice
    passes it for every WiFi mode but the last one it tries (ADR-0034), so a headset reachable
    only in its second mode does not log a failure on every resolution.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath,
        [switch]$Quiet
    )

    if (-not $AdbPort) { $AdbPort = Get-ClassicAdbPort }
    $DeviceId = "${headsetIP}:${AdbPort}"
    $failLevel = if ($Quiet) { 'DEBUG' } else { 'WARNING' }

    if (-not (Test-Path -LiteralPath $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $null
    }

    # Already connected? Return immediately without re-connecting.
    # Bounded (5 s): this runs in every poll runspace, a wedged adb server must not hang it.
    $devicesResult = Invoke-Adb -Arguments @('devices') -Adb $adb -TimeoutSeconds 5
    $alreadyConnected = $devicesResult.StdOut |
        Where-Object { $_ -match ("^" + [regex]::Escape($DeviceId) + "\s+device$") }
    if ($alreadyConnected) {
        Write-Log ($msg.AdbWifiAlreadyConnected -f $DeviceId) -Level DEBUG
        return [PSCustomObject]@{ DeviceId = $DeviceId; ConnectionType = 'WiFi'; IP = $headsetIP; Port = $AdbPort }
    }

    Write-Log ($msg.AdbWifiConnecting -f $DeviceId) -Level INFO

    $pingOk = Test-Connection -ComputerName $headsetIP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        Write-Log ($msg.AdbWifiPingFailed -f $headsetIP) -Level $failLevel
        return $null
    }

    $portOpen = (Test-Port -hostname $headsetIP -port $AdbPort).open
    if (-not $portOpen) {
        Write-Log ($msg.AdbWifiPortClosed -f $AdbPort, $headsetIP) -Level $failLevel
        if (-not $Quiet) { Write-Log ($msg.AdbWifiDevModeHint) -Level WARNING }
        return $null
    }

    try {
        $connectResult = Invoke-Adb -Arguments @('connect', $DeviceId) -Adb $adb -TimeoutSeconds 10
        $connectOutput = @($connectResult.StdOut) + @($connectResult.StdErr)
        $nowConnected = (Invoke-Adb -Arguments @('devices') -Adb $adb -TimeoutSeconds 5).StdOut |
            Where-Object { $_ -match ("^" + [regex]::Escape($DeviceId) + "\s+device$") }
        if ($nowConnected) {
            Write-Log ($msg.AdbWifiConnected -f $DeviceId) -Level SUCCESS
            return [PSCustomObject]@{ DeviceId = $DeviceId; ConnectionType = 'WiFi'; IP = $headsetIP; Port = $AdbPort }
        } else {
            Write-Log ($msg.AdbWifiConnectFailed -f $DeviceId, ($connectOutput -join " ")) -Level $(if ($Quiet) { 'DEBUG' } else { 'ERROR' })
            return $null
        }
    } catch {
        Write-Log ($msg.AdbWifiConnectFailed -f $DeviceId, $_) -Level $(if ($Quiet) { 'DEBUG' } else { 'ERROR' })
        return $null
    }
}


function Disconnect-ADBConnections {
    param (
        [Parameter()]
        [string]$adb = $global:adbPath
    )
    try {
        if (-not (Test-Path -LiteralPath $adb)) {
            throw "ADB executable not found at $adb"
        }
        
        & $adb disconnect
        Write-Log ($msg.DisconnectingAll) -Level INFO
    }
    catch {
        Write-Log ($msg.DisconnectFailed -f $_) -Level ERROR
        throw
    }
}
