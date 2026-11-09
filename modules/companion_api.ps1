###############################################################
# companion_api.ps1
# HTTP API of the VRHM Companion app running on the headset.
# Split out of adb_functions.ps1 (S9-2). Auto-loaded by scripts_init.ps1.
# Translations are loaded centrally in scripts_init.ps1 into $global:msg.
# ASCII only (no em dashes, no curly quotes, no accents).
###############################################################


# Operator text from the nested $msg.Companion group, with a literal English fallback for runspaces
# that never loaded the translations. Example: Get-CompanionText -Key 'NoUsb' -Fallback 'No USB headset detected'
function Get-CompanionText {
    param([Parameter(Mandatory)][string]$Key, [string]$Fallback = '')
    $t = ''
    try { $t = [string](Get-MessageString -Key ("Companion.{0}" -f $Key) -Fallback '') } catch { $t = '' }
    if (-not $t -or $t -eq ("Companion.{0}" -f $Key)) { $t = $Fallback }
    return $t
}


function Get-CompanionInfo {
    <#
    .SYNOPSIS
    Calls GET http://<IP>:<CompanionPort>/info on the VRHM Companion app running on the headset.
    Returns the parsed JSON object, or $null if the companion is unreachable.
    .PARAMETER IP
    Headset IP address.
    .PARAMETER CompanionPort
    HTTP port the companion listens on (default 8765).
    .PARAMETER TimeoutSec
    Request timeout in seconds (default 2).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [int]$CompanionPort = 8765,
        [int]$TimeoutSec    = 2,
        [string]$Token      = ''
    )
    try {
        if (-not $Token) { $Token = Get-CompanionToken }
        $url  = "http://${IP}:${CompanionPort}/info"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers (Get-CompanionHttpHeaders -Token $Token) -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $resp
    } catch {
        Write-Log "Get-CompanionInfo $IP :${CompanionPort} unreachable: $_" -Level DEBUG
        return $null
    }
}


function Set-CompanionAutoAdb {
    <#
    .SYNOPSIS
    POSTs {"auto_adb_wifi": <bool>} to the companion app running on the headset.
    Returns $true on success, $false on failure (companion not installed or unreachable).
    .PARAMETER IP
    Headset IP address.
    .PARAMETER Enabled
    Whether to enable auto-ADB-WiFi on next boot.
    .PARAMETER CompanionPort
    HTTP port the companion listens on (default 8765).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [Parameter(Mandatory)]
        [bool]$Enabled,
        [int]$CompanionPort = 8765,
        [string]$Token = ''
    )
    try {
        if (-not $Token) { $Token = Get-CompanionToken }
        $body = ConvertTo-Json -Compress @{ auto_adb_wifi = $Enabled }
        $url  = "http://${IP}:${CompanionPort}/settings"
        $resp = Invoke-RestMethod -Uri $url -Method POST -Body $body -Headers (Get-CompanionHttpHeaders -Token $Token) `
                    -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
        if ($resp.ok) {
            Write-Log "Set-CompanionAutoAdb $IP -> auto_adb_wifi=$Enabled" -Level DEBUG
            return $true
        }
        Write-Log "Set-CompanionAutoAdb $IP returned ok=false" -Level WARNING
        return $false
    } catch {
        Write-Log "Set-CompanionAutoAdb $IP failed: $_" -Level WARNING
        return $false
    }
}


function Get-CompanionHttpHeaders {
    <#
    .SYNOPSIS
    Builds the HTTP headers for a companion request: the shared token (X-VRHM-Token) when one is
    given. NOTE: do NOT add a 'Connection' header here - it is a restricted header that PS 5.1's
    Invoke-RestMethod refuses in -Headers (it throws), which would make every call fail.
    #>
    param([string]$Token = '')
    $h = @{}
    if ($Token) { $h['X-VRHM-Token'] = $Token }
    return $h
}


function Get-CompanionStatus {
    <#
    .SYNOPSIS
    GET http://<IP>:<CompanionPort>/status on the VRHM Companion. Returns the parsed status object
    (bootMode, classicPort, adbWifiEnabled, keyFingerprint, autoApprove, trustedCount, autoEnabled,
    tokenSet, lastConnect, ...) or $null when the companion is unreachable or not installed.
    .EXAMPLE
    $st = Get-CompanionStatus -IP '192.168.1.243'; $st.bootMode
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [int]$CompanionPort = 8765,
        [int]$TimeoutSec    = 2,
        [string]$Token      = ''
    )
    try {
        if (-not $Token) { $Token = Get-CompanionToken }
        $url = "http://${IP}:${CompanionPort}/status"
        return Invoke-RestMethod -Uri $url -Method GET -Headers (Get-CompanionHttpHeaders -Token $Token) -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        Write-Log "Get-CompanionStatus $IP :${CompanionPort} unreachable: $_" -Level DEBUG
        return $null
    }
}


function Get-CompanionKey {
    <#
    .SYNOPSIS
    GET /key on the companion: the companion's own adb key fingerprint (informational), or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [int]$CompanionPort = 8765,
        [int]$TimeoutSec    = 2,
        [string]$Token      = ''
    )
    try {
        if (-not $Token) { $Token = Get-CompanionToken }
        $url  = "http://${IP}:${CompanionPort}/key"
        $resp = Invoke-RestMethod -Uri $url -Method GET -Headers (Get-CompanionHttpHeaders -Token $Token) -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp.ok) { return [string]$resp.fingerprint }
        return $null
    } catch {
        Write-Log "Get-CompanionKey $IP failed: $_" -Level DEBUG
        return $null
    }
}


function Invoke-CompanionPost {
    <#
    .SYNOPSIS
    POSTs a JSON body to a companion endpoint with the optional shared token. Returns the parsed
    response object on success, or $null on failure (unreachable, 401 bad token, 4xx/5xx).
    .PARAMETER Path
    The endpoint path, e.g. '/adb/mode'.
    .PARAMETER Body
    A hashtable serialised to JSON.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body = @{},
        [string]$Token = '',
        [int]$CompanionPort = 8765,
        [int]$TimeoutSec = 4
    )
    try {
        $url  = "http://${IP}:${CompanionPort}$Path"
        $json = ConvertTo-Json -Compress $Body
        $resp = Invoke-RestMethod -Uri $url -Method POST -Body $json -ContentType 'application/json' `
                    -Headers (Get-CompanionHttpHeaders -Token $Token) -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $resp
    } catch {
        Write-Log "Invoke-CompanionPost $IP $Path failed: $_" -Level WARNING
        return $null
    }
}


function Set-CompanionBootMode {
    <#
    .SYNOPSIS
    Sets the companion's boot ADB mode (POST /adb/mode): 'TLS', 'CLASSIC' or 'NONE', with an optional
    classic port. Returns $true on success.
    .EXAMPLE
    Set-CompanionBootMode -IP '192.168.1.243' -Mode CLASSIC -Port 5555 -Token $tok
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][ValidateSet('TLS','CLASSIC','NONE')][string]$Mode,
        [int]$Port = 0,
        [string]$Token = '',
        [int]$CompanionPort = 8765
    )
    $body = @{ mode = $Mode }
    if ($Port -ge 1024 -and $Port -le 65535) { $body.port = $Port }
    $r = Invoke-CompanionPost -IP $IP -Path '/adb/mode' -Body $body -Token $Token -CompanionPort $CompanionPort
    return [bool]($r -and $r.ok)
}


function Invoke-CompanionForce {
    <#
    .SYNOPSIS
    Asks the companion to enable wireless debugging and connect now (POST /adb/force), in 'CLASSIC'
    (opens tcpip on the classic port) or 'TLS' mode. Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][ValidateSet('TLS','CLASSIC')][string]$Mode,
        [string]$Token = '',
        [int]$CompanionPort = 8765
    )
    $r = Invoke-CompanionPost -IP $IP -Path '/adb/force' -Body @{ mode = $Mode } -Token $Token -CompanionPort $CompanionPort
    return [bool]($r -and $r.ok)
}


function Set-CompanionAutoEnable {
    <#
    .SYNOPSIS
    Turns the companion's "auto-enable ADB WiFi on boot" master switch on/off (POST /adb/boot).
    Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][bool]$Enabled,
        [string]$Token = '',
        [int]$CompanionPort = 8765
    )
    $r = Invoke-CompanionPost -IP $IP -Path '/adb/boot' -Body @{ enabled = $Enabled } -Token $Token -CompanionPort $CompanionPort
    return [bool]($r -and $r.ok)
}


function Set-CompanionApprove {
    <#
    .SYNOPSIS
    Turns the companion's auto-approve of the "allow debugging" popup on/off (POST /approve). Only
    approves allowlisted computers (see Set-CompanionTrustedKeys). Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][bool]$Enabled,
        [string]$Token = '',
        [int]$CompanionPort = 8765
    )
    $r = Invoke-CompanionPost -IP $IP -Path '/approve' -Body @{ enabled = $Enabled } -Token $Token -CompanionPort $CompanionPort
    return [bool]($r -and $r.ok)
}


function Set-CompanionTrustedKeys {
    <#
    .SYNOPSIS
    Manages the companion's auto-approve allowlist of RSA key fingerprints (POST /approve/trust):
    the keys of computers (the VRHM server, toolbox PCs) whose "allow debugging" popup the companion
    may approve by itself. -Set replaces the list, -Add adds one, -Clear empties it first.
    Returns the resulting list of fingerprints, or $null on failure.
    .EXAMPLE
    Set-CompanionTrustedKeys -IP '192.168.1.243' -Set @('4B:B2:...','AA:BB:...') -Token $tok
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [string[]]$Set,
        [string]$Add = '',
        [switch]$Clear,
        [string]$Token = '',
        [int]$CompanionPort = 8765
    )
    $body = @{}
    if ($Clear) { $body.clear = $true }
    if ($PSBoundParameters.ContainsKey('Set')) { $body.set = @($Set) }
    if ($Add) { $body.add = $Add }
    $r = Invoke-CompanionPost -IP $IP -Path '/approve/trust' -Body $body -Token $Token -CompanionPort $CompanionPort
    if ($r -and $r.ok) { return @($r.trusted) }
    return $null
}


function Set-HeadsetBrightnessCompanion {
    <#
    .SYNOPSIS
    Sets screen brightness (0-100%) via the companion app HTTP API.
    Faster than ADB round-trip. Falls back gracefully if companion is unreachable.
    Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$IP,
        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int]$Percent,
        [int]$CompanionPort = 8765,
        [string]$Token = ''
    )
    try {
        if (-not $Token) { $Token = Get-CompanionToken }
        $body = ConvertTo-Json -Compress @{ brightness = $Percent }
        $url  = "http://${IP}:${CompanionPort}/settings"
        $resp = Invoke-RestMethod -Uri $url -Method POST -Body $body -Headers (Get-CompanionHttpHeaders -Token $Token) `
                    -ContentType "application/json" -TimeoutSec 3 -ErrorAction Stop
        return [bool]$resp.ok
    } catch {
        Write-Log "Set-HeadsetBrightnessCompanion $IP failed: $_" -Level DEBUG
        return $false
    }
}


function Get-VrhmAdbKeyFingerprint {
    <#
    .SYNOPSIS
    The RSA key fingerprint of THIS PC's adb key, exactly as Horizon shows it in the "allow
    debugging" popup (MD5 of the DECODED adb public-key blob, upper-hex, colon-separated). This is
    what the companion's approve allowlist compares against, so the companion can auto-approve
    VRHM's own ADB connections. Reads the host adbkey.pub; returns $null when it cannot be found.
    .EXAMPLE
    $fp = Get-VrhmAdbKeyFingerprint   # e.g. 4B:B2:BB:F0:...
    #>
    param([string]$PubKeyPath = '')
    try {
        $candidates = @()
        if ($PubKeyPath) { $candidates += $PubKeyPath }
        if ($env:ANDROID_VAULT) { $candidates += (Join-Path $env:ANDROID_VAULT 'adbkey.pub') }
        if ($env:ANDROID_SDK_HOME) { $candidates += (Join-Path $env:ANDROID_SDK_HOME '.android\adbkey.pub') }
        if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE '.android\adbkey.pub') }
        if ($env:HOME) { $candidates += (Join-Path $env:HOME '.android\adbkey.pub') }
        $path = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        if (-not $path) {
            Write-Log "Get-VrhmAdbKeyFingerprint: no adbkey.pub found (start the adb server once)" -Level DEBUG
            return $null
        }
        $raw   = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
        $blob  = ($raw -split '\s+')[0]
        $bytes = [Convert]::FromBase64String($blob)
        $md5   = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
        return (($md5 | ForEach-Object { $_.ToString('X2') }) -join ':')
    } catch {
        Write-Log "Get-VrhmAdbKeyFingerprint failed: $_" -Level WARNING
        return $null
    }
}


function Invoke-CompanionCmd {
    <#
    .SYNOPSIS
    Drives the companion's headless CmdReceiver over an ADB connection (the trusted channel used at
    onboarding, before an HTTP token exists). Example cmds: status, key, setmode (--es mode),
    setport (--ei port), forceclassic, forcetls, approve_on/off, trust_add (--es fp), trust_clear,
    settoken (--es token), cleartoken, a11y_on. Returns $true when the broadcast was delivered.
    .PARAMETER Device
    A resolved ADB device object (Resolve-HeadsetAdbDevice / Get-AdbUsbDeviceDetails).
    .PARAMETER Cmd
    The command name.
    .PARAMETER Extra
    Extra adb am-broadcast args, e.g. @('--es','mode','CLASSIC').
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][string]$Cmd,
        [string[]]$Extra = @(),
        [string]$adb = $global:adbPath
    )
    $pkg = $global:CompanionPackageName
    $amArgs = "am broadcast -a $pkg.CMD -n $pkg/.CmdReceiver --es cmd $Cmd"
    if ($Extra.Count -gt 0) { $amArgs += ' ' + ($Extra -join ' ') }
    try {
        $r = Invoke-AdbCmd -Device $Device -Command $amArgs -ShellScript -adb $adb -SilentOnFail
    } catch { return $false }
    if ($r -eq $false -or $null -eq $r) { return $false }
    $text = (@($r) | ForEach-Object { [string]$_ }) -join "`n"
    if ($text -notmatch 'Broadcast completed') { return $false }
    if ($text -match 'Error|Exception|No receiver') { return $false }
    return $true
}


function Get-HeadsetAppVersion {
    <#
    .SYNOPSIS
    The installed versionName of one package on a headset (via dumpsys package), or '' when the
    package is not installed. One adb shell call.
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][string]$Pkg,
        [string]$adb = $global:adbPath
    )
    try {
        $out = Invoke-AdbCmd -Device $Device -Command "dumpsys package $Pkg | grep versionName" -ShellScript -adb $adb -SilentOnFail
        if ($out -eq $false) { return '' }
        foreach ($line in @($out)) { if ($line -match 'versionName=(.+)') { return $Matches[1].Trim() } }
        return ''
    } catch { return '' }
}


function Get-HeadsetAdbToolsStatus {
    <#
    .SYNOPSIS
    Install state of the two headset ADB-enabler apps (ADR-0042): the VRHM Companion (recommended)
    and the ADB Auto Enable app (secondary). Returns one entry per app:
    @{ key; packageName; name; recommended; installed; installedVersion; availableVersion; upgrade }.
    'upgrade' is true when installed AND the installed version differs from the bundled one.
    .EXAMPLE
    Get-HeadsetAdbToolsStatus -Device (Get-AdbUsbDeviceDetails) | Format-Table name,installed,installedVersion,availableVersion
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [string]$adb = $global:adbPath,
        [string]$Brand = ''
    )
    $compPkg = $global:CompanionPackageName
    $aePkg   = $global:ADBAutoEnablePackageName
    $compAvail = [string]$global:CompanionVersion
    $aeAvail = ''
    if ($global:ADBAutoEnableAPK -match '[-_](\d+(?:\.\d+)+)\.apk$') { $aeAvail = $Matches[1] }

    $compVer = Get-HeadsetAppVersion -Device $Device -Pkg $compPkg -adb $adb
    $result = @(
        @{ key = 'companion'; packageName = $compPkg; name = 'VRHM Companion'; recommended = $true
           installed = [bool]$compVer; installedVersion = $compVer; availableVersion = $compAvail
           upgrade = ([bool]$compVer -and $compAvail -and ($compVer -ne $compAvail)) }
    )
    # ADB Auto Enable is refused on a Pico (ADR-0038): the entry is not offered for that brand.
    if (Test-HeadsetAdbTlsSupported -Brand $Brand) {
        $aeVer = Get-HeadsetAppVersion -Device $Device -Pkg $aePkg -adb $adb
        $result += @{ key = 'autoenable'; packageName = $aePkg; name = 'ADB Auto Enable'; recommended = $false
           installed = [bool]$aeVer; installedVersion = $aeVer; availableVersion = $aeAvail
           upgrade = ([bool]$aeVer -and $aeAvail -and ($aeVer -ne $aeAvail)) }
    }
    return $result
}


function Uninstall-HeadsetAdbTool {
    <#
    .SYNOPSIS
    Uninstalls one of the two known headset ADB-enabler apps (VRHM Companion or ADB Auto Enable).
    Refuses any other package. Returns @{Ok;Error}.
    #>
    param(
        [Parameter(Mandatory)]$Device,
        [Parameter(Mandatory)][string]$Pkg,
        [string]$adb = $global:adbPath
    )
    if ($Pkg -ne $global:CompanionPackageName -and $Pkg -ne $global:ADBAutoEnablePackageName) {
        return @{ Ok = $false; Error = ((Get-CompanionText -Key 'UninstallRefused' -Fallback 'Refused: {0} is not a managed headset ADB tool') -f $Pkg) }
    }
    try {
        $out = Invoke-AdbCmd -Device $Device -Command "uninstall $Pkg" -TimeoutSeconds 60 -adb $adb
        $ok  = ($out -ne $false) -and [bool](@($out) -match 'Success')
        return @{ Ok = $ok; Error = $(if ($ok) { '' } else { (@($out) -join ' ') }) }
    } catch { return @{ Ok = $false; Error = $_.Exception.Message } }
}


function Install-VrhmCompanion {
    <#
    .SYNOPSIS
    Installs and fully provisions the VRHM Companion app on a headset (ADR-0042): the recommended
    cable-free-ADB-at-boot agent (adbautoenable stays a secondary choice).

    .DESCRIPTION
    Steps, each reported in Steps (a failed one does not hide the others): install -r -d, grant
    WRITE_SECURE_SETTINGS + POST_NOTIFICATIONS, enable the ApproveService accessibility (append,
    never overwriting), provision the HTTP token (settoken), push this PC's adb key fingerprint to
    the auto-approve allowlist (trust_add), set the boot mode (setmode/setport), optionally enable
    auto-approve (approve_on), start the app, and for CLASSIC mode open tcpip now.
    The caller MUST hold Set-UsbBusy (tcpip re-enumerates the USB transport).

    .PARAMETER Device
    A resolved USB ADB device object (Get-AdbUsbDeviceDetails). Resolved if omitted.
    .PARAMETER Mode
    Boot ADB mode to set: 'TLS' or 'CLASSIC'. When omitted: the effective preferred WiFi mode
    (Get-AdbWifiPreferredMode, fallback TLS). A brand without ADB-over-TLS (Pico) is forced to CLASSIC.
    .PARAMETER ResetAllowlist
    Empty the companion's auto-approve allowlist (trust_clear) before adding keys. Without it keys are only added.
    .PARAMETER ClassicPort
    Classic port for CLASSIC mode (default from Get-ClassicAdbPort).
    .PARAMETER AutoApprove
    Enable the companion's auto-approve of the "allow debugging" popup (allowlist-gated).
    .PARAMETER Token
    The HTTP API token to provision. A random one is generated and returned when omitted.
    .PARAMETER TrustedFingerprints
    Extra RSA key fingerprints to allowlist (e.g. toolbox PC keys) besides this PC's own.

    .EXAMPLE
    $r = Install-VrhmCompanion -Device (Get-AdbUsbDeviceDetails) -Mode TLS; $r.Steps | Format-Table Name,Ok,Detail
    #>
    param(
        [PSCustomObject]$Device = $null,
        [ValidateSet('TLS','CLASSIC')][string]$Mode,
        [int]$ClassicPort = 0,
        [switch]$AutoApprove,
        [switch]$ResetAllowlist,
        [string]$Token = '',
        [string[]]$TrustedFingerprints = @(),
        [string]$adb = $global:adbPath
    )

    $apkPath = $global:CompanionAPK
    $pkg     = $global:CompanionPackageName
    $steps   = New-Object System.Collections.ArrayList
    $result  = @{ Ok = $false; Steps = @(); Reinstalled = $false; Error = ''; Token = ''; Fingerprint = '' }

    $addStep = {
        # $Ok is untyped on purpose: a step's success expression may be a bool, an Invoke-AdbCmd /
        # Invoke-CompanionCmd result (an array of output lines) or $null. Casting an array straight
        # to [bool] throws and used to abort the whole install - defeating the "a failed step does
        # not hide the others" contract. Normalise here instead: an array counts as success when it
        # has any truthy element (adb returned output), $null / $false as failure.
        param([string]$Name, $Ok, [string]$Detail)
        $okBool = if ($Ok -is [bool]) { $Ok }
                  elseif ($null -eq $Ok) { $false }
                  elseif ($Ok -is [array]) { @($Ok | Where-Object { $_ }).Count -gt 0 }
                  else { [bool]$Ok }
        [void]$steps.Add(@{ Name = $Name; Ok = $okBool; Detail = $Detail })
        Write-Log ("VRHM Companion: {0} - {1}" -f $Name, $Detail) -Level $(if ($okBool) { 'INFO' } else { 'ERROR' })
    }

    if (-not (Test-Path -LiteralPath $adb)) {
        $result.Error = ($msg.ADBNotFound -f $global:adbFolder); Write-Log $result.Error -Level ERROR; return $result
    }
    if (-not $apkPath -or -not (Test-Path -LiteralPath $apkPath)) {
        $result.Error = ((Get-CompanionText -Key 'ApkNotFound' -Fallback 'VRHM Companion APK not found at {0}') -f $apkPath); Write-Log $result.Error -Level ERROR; return $result
    }
    if ($pkg -notmatch '^[A-Za-z0-9._]+$') {
        $result.Error = ((Get-CompanionText -Key 'InvalidPackage' -Fallback 'Invalid package name: {0}') -f $pkg); Write-Log $result.Error -Level ERROR; return $result
    }
    if (-not $Device) {
        $Device = Get-AdbUsbDevice -adb $adb
        if (-not $Device) { $result.Error = (Get-CompanionText -Key 'NoUsb' -Fallback 'No USB headset detected'); Write-Log $result.Error -Level WARNING; return $result }
    }

    if (-not $ClassicPort) { $ClassicPort = Get-ClassicAdbPort }
    # Use the stable per-fleet token (ADR-0043) so VRHM can validate the companion's telemetry
    # pushes; a caller may still override it with -Token.
    if (-not $Token) { $Token = Get-CompanionToken }
    $result.Token = $Token

    # Mode: explicit, else the effective preferred WiFi mode, else TLS. No TLS on a Pico (ADR-0038).
    $modeNote = ''
    if (-not $Mode) {
        $Mode = 'TLS'
        try {
            if (Get-Command Get-AdbWifiPreferredMode -ErrorAction SilentlyContinue) {
                $pm = [string](Get-AdbWifiPreferredMode)
                if ($pm -eq 'Classic') { $Mode = 'CLASSIC' }
            }
        } catch { $Mode = 'TLS' }
    }
    $devBrand = ''
    $devSerial = ''
    try { if ($Device.PSObject.Properties['Brand']) { $devBrand = [string]$Device.Brand } } catch { $devBrand = '' }
    # The adb serial is read here (shell can read ro.serialno, the app cannot) and handed to the
    # companion so its telemetry pushes carry the serial the registry knows.
    if (Get-Command Get-HeadsetBrandModel -ErrorAction SilentlyContinue) {
        try {
            $bm = Get-HeadsetBrandModel -Device $Device -adb $adb -IncludeSerial
            if ($bm -and $bm.Brand -and -not $devBrand) { $devBrand = [string]$bm.Brand }
            if ($bm -and $bm.Serial) { $devSerial = ([string]$bm.Serial).Trim() }
        } catch { }
    }
    $tlsOk = $true
    try { if (Get-Command Test-HeadsetAdbTlsSupported -ErrorAction SilentlyContinue) { $tlsOk = [bool](Test-HeadsetAdbTlsSupported -Brand $devBrand) } } catch { $tlsOk = $true }
    if (-not $tlsOk -and $Mode -eq 'TLS') {
        $Mode = 'CLASSIC'
        $modeNote = (Get-CompanionText -Key 'ModeForcedClassic' -Fallback 'ADB over TLS is not supported on this brand: CLASSIC mode used')
    }
    $isUsbTarget = $false
    try { $isUsbTarget = [bool](Test-AdbDeviceIdIsUsb -Id ([string]$Device.DeviceId)) } catch { $isUsbTarget = $false }

    Write-Log "Installing VRHM Companion on $($Device.DeviceId)" -Level INFO
    if ($modeNote) { & $addStep 'mode forced' $true $modeNote }

    # a. install / reinstall
    try {
        $pm = Invoke-AdbCmd -Device $Device -Command "pm list packages $pkg" -ShellScript -adb $adb -SilentOnFail
        $result.Reinstalled = ($pm -ne $false) -and [bool](@($pm) | Where-Object { $_ -match "^package:$([regex]::Escape($pkg))\s*$" })
        $out = Invoke-AdbCmd -Device $Device -Command "install -r -d `"$apkPath`"" -TimeoutSeconds 180 -adb $adb
        $okInstall = ($out -ne $false) -and [bool](@($out) -match 'Success')
        & $addStep 'install' $okInstall $(if ($okInstall) { if ($result.Reinstalled) { 'reinstalled' } else { 'installed' } } else { (@($out) -join ' ') })
    } catch { & $addStep 'install' $false $_.Exception.Message }
    $installStep = @($steps | Where-Object { $_.Name -eq 'install' })[0]
    if (-not $installStep -or -not $installStep.Ok) {
        $result.Steps = @($steps)
        $result.Error = ((Get-CompanionText -Key 'InstallStepFailed' -Fallback 'install failed: {0}') -f $(if ($installStep) { $installStep.Detail } else { '?' }))
        return $result
    }

    # b. permissions
    foreach ($perm in 'WRITE_SECURE_SETTINGS', 'POST_NOTIFICATIONS') {
        try {
            $r = Invoke-AdbCmd -Device $Device -Command "pm grant $pkg android.permission.$perm" -ShellScript -adb $adb
            & $addStep "grant $perm" ($r -ne $false) $(if ($r -ne $false) { 'granted' } else { 'pm grant failed' })
        } catch { & $addStep "grant $perm" $false $_.Exception.Message }
    }

    # b2. usage-stats appop: the foreground-app fallback of telemetry v2 (UsageStatsManager) needs it,
    # and it can only be granted over adb (telemetry-v2.md section 1, decision D2)
    try {
        $r = Invoke-AdbCmd -Device $Device -Command "appops set $pkg GET_USAGE_STATS allow" -ShellScript -adb $adb
        & $addStep 'grant GET_USAGE_STATS' ($r -ne $false) $(if ($r -ne $false) { 'granted' } else { 'appops set failed' })
    } catch { & $addStep 'grant GET_USAGE_STATS' $false $_.Exception.Message }

    # b3. power-save allowlist: exempts the app from the background foreground-service start restriction
    try {
        $r = Invoke-AdbCmd -Device $Device -Command "dumpsys deviceidle whitelist +$pkg" -ShellScript -adb $adb
        & $addStep 'battery allowlist' ($r -ne $false) $(if ($r -ne $false) { 'allowlisted' } else { 'deviceidle failed' })
    } catch { & $addStep 'battery allowlist' $false $_.Exception.Message }

    # c. accessibility (ApproveService): append, never overwrite another enabled service
    try {
        $component = $global:CompanionApproveService
        $cur = ((Invoke-AdbCmd -Device $Device -Command 'settings get secure enabled_accessibility_services' -ShellScript -adb $adb) -join '').Trim()
        $list = @()
        if ($cur -and $cur -ne 'null') { $list = @($cur -split ':' | Where-Object { $_ }) }
        $did = $true; $detail = 'already enabled'
        if ($list -notcontains $component) {
            $q = ConvertTo-DiagShellQuoted -Text (($list + $component) -join ':')
            $r = Invoke-AdbCmd -Device $Device -Command "settings put secure enabled_accessibility_services $q" -ShellScript -adb $adb
            $did = ($r -ne $false); $detail = if ($did) { 'enabled' } else { 'settings put failed' }
        }
        if ($did) {
            $r = Invoke-AdbCmd -Device $Device -Command 'settings put secure accessibility_enabled 1' -ShellScript -adb $adb
            if ($r -eq $false) { $did = $false; $detail = 'accessibility_enabled failed' }
        }
        & $addStep 'accessibility' $did $detail
    } catch { & $addStep 'accessibility' $false $_.Exception.Message }

    # Runs one companion broadcast; a throw counts as failure. Returns a strict bool.
    $cmd = {
        param([string]$Cmd, [string[]]$Extra = @())
        try { return [bool](Invoke-CompanionCmd -Device $Device -Cmd $Cmd -Extra $Extra -adb $adb) } catch { return $false }
    }
    $failTxt = Get-CompanionText -Key 'StepFailed' -Fallback 'failed'

    # d. provision token (over the trusted ADB channel, never first over HTTP)
    $okTok = & $cmd 'settoken' @('--es','token',$Token)
    & $addStep 'token' $okTok $(if ($okTok) { Get-CompanionText -Key 'StepProvisioned' -Fallback 'provisioned' } else { $failTxt })

    # d2. provision the adb serial (the identity the telemetry route matches on)
    if ($devSerial -match '^[A-Za-z0-9._-]{4,64}$') {
        $okSer = & $cmd 'setserial' @('--es','serial',$devSerial)
        & $addStep 'serial' $okSer $(if ($okSer) { $devSerial } else { $failTxt })
    } else {
        & $addStep 'serial' $false (Get-CompanionText -Key 'SerialUnreadable' -Fallback 'serial not readable over adb')
    }

    # e. allowlist this PC's adb key (+ any extra keys) for auto-approve
    $fp = $null
    try { $fp = Get-VrhmAdbKeyFingerprint } catch { $fp = $null }
    $result.Fingerprint = [string]$fp
    $allKeys = @(); if ($fp) { $allKeys += $fp }; $allKeys += @($TrustedFingerprints | Where-Object { $_ })
    if ($allKeys.Count -gt 0) {
        $okTrust = $true
        if ($ResetAllowlist) { $okTrust = $okTrust -and (& $cmd 'trust_clear') }
        foreach ($k in $allKeys) { $okTrust = $okTrust -and (& $cmd 'trust_add' @('--es','fp',$k)) }
        & $addStep 'allowlist' $okTrust $(if ($okTrust) { ((Get-CompanionText -Key 'StepKeys' -Fallback '{0} key(s)') -f $allKeys.Count) } else { $failTxt })
    } else {
        & $addStep 'allowlist' $false (Get-CompanionText -Key 'NoAdbKey' -Fallback 'no adb key fingerprint (run the adb server once)')
    }

    # f. mode + optional auto-approve
    $okPort = & $cmd 'setport' @('--ei','port',"$ClassicPort")
    $okMode = & $cmd 'setmode' @('--es','mode',$Mode)
    & $addStep 'mode' ($okPort -and $okMode) $(if ($okPort -and $okMode) { "$Mode (port $ClassicPort)" } else { $failTxt })
    if ($AutoApprove) {
        $okAp = & $cmd 'approve_on'
        & $addStep 'auto-approve' $okAp $(if ($okAp) { 'on' } else { $failTxt })
    }

    # g. enable its accessibility service to actually bind, and start the app once
    $okA11y = & $cmd 'a11y_on'
    & $addStep 'a11y bind' $okA11y $(if ($okA11y) { Get-CompanionText -Key 'StepRequested' -Fallback 'requested' } else { $failTxt })
    try {
        $r = Invoke-AdbCmd -Device $Device -Command "am start -n `"$pkg/.MainActivity`"" -ShellScript -adb $adb
        & $addStep 'start' ($r -ne $false) $(if ($r -ne $false) { 'started' } else { 'am start failed' })
    } catch { & $addStep 'start' $false $_.Exception.Message }

    # h. CLASSIC: open tcpip now (usable without waiting for a reboot). tcpip drops USB for seconds,
    # so it is only fired on a USB target.
    if ($Mode -eq 'CLASSIC') {
        if ($isUsbTarget) {
            $okTcp = & $cmd 'forceclassic'
            & $addStep 'classic tcpip' $okTcp $(if ($okTcp) { "port $ClassicPort" } else { $failTxt })
        } else {
            & $addStep 'classic tcpip' $true (Get-CompanionText -Key 'SkippedWifiTarget' -Fallback 'skipped (WiFi target)')
        }
    }

    # i. verify over HTTP when the headset address is known (best effort, never fails the install)
    $verifyIp = ''
    try { if ($Device.PSObject.Properties['IP'] -and $Device.IP) { $verifyIp = [string]$Device.IP } } catch { $verifyIp = '' }
    $verified = $false
    if ($verifyIp -and -not (Test-UnknownIp -IPAddress $verifyIp)) {
        try {
            Start-Sleep -Milliseconds 1500
            $st = Get-CompanionStatus -IP $verifyIp -Token $Token
            if ($st) { $verified = $true; & $addStep 'verify' ([bool]$st.tokenSet) ("bootMode={0} tokenSet={1}" -f $st.bootMode, $st.tokenSet) }
        } catch { $verified = $false }
    }
    if (-not $verified) { & $addStep 'verify' $true (Get-CompanionText -Key 'NotVerified' -Fallback 'not verified') }

    $result.Steps = @($steps)
    $failed = @($steps | Where-Object { -not $_.Ok })
    $result.Mode = $Mode
    $result.Ok = ($failed.Count -eq 0)
    if ($result.Ok) { Write-Log 'VRHM Companion installed and provisioned' -Level SUCCESS }
    else { $result.Error = ('steps failed: ' + (($failed | ForEach-Object { $_.Name }) -join ', ')) }
    return $result
}


# ---------------------------------------------------------------------------
# Information source per headset (ADR-0043 telemetry push).
# The GLOBAL default is $global:ADB_info_source ('adb' | 'companion'); a headset
# may override it through the app_kv row headset_info_source_<id> =
# { source:'default'|'companion'|'adb'|'tls'|'classic', at }. 'default' follows the
# global (no row). 'tls'/'classic' are kept for forward-compatibility (a future
# per-headset transport preference); for TELEMETRY they mean 'adb' like today.
# These readers live here, not in headsets_manager.ps1, because the per-headset
# VRMonitor poll runspace imports companion_api.ps1 but NOT headsets_manager.ps1.
# ---------------------------------------------------------------------------

$script:HeadsetInfoSourceValues = @('default', 'companion', 'adb', 'tls', 'classic')

# The raw per-headset override ('default' when none). Memoised 2 s per process/runspace like
# Get-HeadsetSessionSettings. Never throws. Example: Get-HeadsetInfoSource -HeadsetId 3
function Get-HeadsetInfoSource {
    param([Parameter(Mandatory)][int]$HeadsetId, [switch]$NoMemo)
    if ($HeadsetId -le 0) { return 'default' }
    if (-not $script:HeadsetInfoSourceMemo) { $script:HeadsetInfoSourceMemo = @{} }
    $m = $script:HeadsetInfoSourceMemo[$HeadsetId]
    if (-not $NoMemo -and $m -and ([datetime]::UtcNow - $m.At).TotalSeconds -lt 2) { return $m.Val }
    $val = 'default'
    try {
        $raw = Get-DbKeyValue -Key ("headset_info_source_{0}" -f $HeadsetId)
        if ($raw -and $raw.source) {
            $s = ([string]$raw.source).Trim().ToLowerInvariant()
            if ($s -in $script:HeadsetInfoSourceValues) { $val = $s }
        }
    } catch { $val = 'default' }
    $script:HeadsetInfoSourceMemo[$HeadsetId] = @{ At = [datetime]::UtcNow; Val = $val }
    return $val
}

# Sets one headset's info-source override. 'default' removes the row (follow the global).
# Returns $true when the store was written (or cleared). Never throws.
# Example: Set-HeadsetInfoSource -HeadsetId 3 -Source 'companion'
function Set-HeadsetInfoSource {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [Parameter(Mandatory)][string]$Source
    )
    if ($HeadsetId -le 0) { return $false }
    $s = ([string]$Source).Trim().ToLowerInvariant()
    if ($s -notin $script:HeadsetInfoSourceValues) { return $false }
    try {
        if ($s -eq 'default') {
            Remove-DbKeyValue -Key ("headset_info_source_{0}" -f $HeadsetId)
        } else {
            $doc = [ordered]@{ source = $s; at = [datetime]::UtcNow.ToString('o') }
            Set-DbKeyValue -Key ("headset_info_source_{0}" -f $HeadsetId) -Value ([PSCustomObject]$doc)
        }
        if ($script:HeadsetInfoSourceMemo) { $script:HeadsetInfoSourceMemo.Remove($HeadsetId) }
        return $true
    } catch { return $false }
}

# Forgets a removed headset's info-source override. Called by Remove-Headset. Never throws.
# Example: Remove-HeadsetInfoSource -HeadsetId 3
function Remove-HeadsetInfoSource {
    param([Parameter(Mandatory)][int]$HeadsetId)
    try { Remove-DbKeyValue -Key ("headset_info_source_{0}" -f $HeadsetId) } catch { }
    if ($script:HeadsetInfoSourceMemo) { $script:HeadsetInfoSourceMemo.Remove($HeadsetId) }
}

# The EFFECTIVE telemetry source of one headset: 'companion' or 'adb'. 'companion' iff the
# per-headset override is 'companion', or it is 'default' and the global $global:ADB_info_source
# is 'companion'. Any override of 'adb'/'tls'/'classic' resolves to 'adb' (telemetry via ADB poll;
# the tls/classic transport is driven globally by wifi_preferred_mode). Never throws.
# Example: if ((Resolve-HeadsetInfoSource -HeadsetId 3) -eq 'companion') { ... }
function Resolve-HeadsetInfoSource {
    param([Parameter(Mandatory)][int]$HeadsetId)
    $override = Get-HeadsetInfoSource -HeadsetId $HeadsetId
    if ($override -eq 'companion') { return 'companion' }
    if ($override -eq 'default') {
        $g = if ($global:ADB_info_source) { [string]$global:ADB_info_source } else { 'adb' }
        if ($g -eq 'companion') { return 'companion' }
    }
    return 'adb'
}

# ---------------------------------------------------------------------------
# Keep headset awake (T2.1b): the headset must not go to sleep. DEFAULT ON.
# The wish lives in the app_kv row headset_keep_awake_<id> = { enabled; at }. It is applied by the
# VRHM Companion app when it answers (wake lock + proximity override through the app's own ADB),
# otherwise over PC ADB with the proximity override (Meta only), which ADR-0040 re-applies after
# every reboot (proxKeepAwake + reapply).
# ---------------------------------------------------------------------------

# Desired keep-awake state of one headset: $true unless the operator switched it off. Memo 2 s.
# -Stored returns instead whether an operator wish exists (ADB-only headsets are only managed
# over ADB once it does). Never throws. Example: Get-HeadsetKeepAwake -HeadsetId 3
function Get-HeadsetKeepAwake {
    param([Parameter(Mandatory)][int]$HeadsetId, [switch]$Stored, [switch]$NoMemo)
    if ($HeadsetId -le 0) { if ($Stored) { return $false } else { return $true } }
    if (-not $script:HeadsetKeepAwakeMemo) { $script:HeadsetKeepAwakeMemo = @{} }
    $m = $script:HeadsetKeepAwakeMemo[$HeadsetId]
    if (-not $NoMemo -and $m -and ([datetime]::UtcNow - $m.At).TotalSeconds -lt 2) {
        if ($Stored) { return $m.Stored } else { return $m.Val }
    }
    $val = $true; $has = $false
    try {
        $raw = Get-DbKeyValue -Key ("headset_keep_awake_{0}" -f $HeadsetId)
        if ($raw -and $null -ne $raw.enabled) { $val = [bool]$raw.enabled; $has = $true }
    } catch { $val = $true; $has = $false }
    $script:HeadsetKeepAwakeMemo[$HeadsetId] = @{ At = [datetime]::UtcNow; Val = $val; Stored = $has }
    if ($Stored) { return $has } else { return $val }
}

# Forgets a removed headset's keep-awake wish. Called by Remove-Headset. Never throws.
# Example: Remove-HeadsetKeepAwake -HeadsetId 3
function Remove-HeadsetKeepAwake {
    param([Parameter(Mandatory)][int]$HeadsetId)
    try { Remove-DbKeyValue -Key ("headset_keep_awake_{0}" -f $HeadsetId) } catch { }
    if ($script:HeadsetKeepAwakeMemo) { $script:HeadsetKeepAwakeMemo.Remove($HeadsetId) }
}

# Stores the keep-awake wish of a headset, then applies it: companion POST /settings keep_awake when
# the companion answers, else the PC ADB proximity override (Meta only). The ADB path also records
# proxKeepAwake + re-apply (ADR-0040) so the override comes back after a reboot; the companion path
# does not need that (the app re-applies it itself at each boot).
# Returns @{Ok;Via='companion'|'adb'|'none';Applied;Error}. Ok = the wish is stored (Applied says
# whether the headset took it now). Never throws.
# Example: $r = Set-HeadsetKeepAwake -Headset $row -Enabled $true
function Set-HeadsetKeepAwake {
    param(
        [Parameter(Mandatory)]$Headset,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $res = @{ Ok = $false; Via = 'none'; Applied = $false; Error = '' }
    try {
        $id = [int]$Headset.ID
        if ($id -le 0) { $res.Error = 'invalid headset'; return $res }
        Set-DbKeyValue -Key ("headset_keep_awake_{0}" -f $id) -Value ([PSCustomObject]@{ enabled = $Enabled; at = [datetime]::UtcNow.ToString('o') })
        if ($script:HeadsetKeepAwakeMemo) { $script:HeadsetKeepAwakeMemo.Remove($id) }
        $res.Ok = $true

        $ip = [string]$Headset.IPAddress
        # 1. Companion app.
        if ($ip -and -not (Test-UnknownIp $ip)) {
            $st = Get-CompanionStatus -IP $ip
            if ($st) {
                $p = Invoke-CompanionPost -IP $ip -Path '/settings' -Body @{ keep_awake = $Enabled } -Token (Get-CompanionToken)
                if ($p -and $p.ok) { $res.Via = 'companion'; $res.Applied = $true; return $res }
                $res.Error = 'companion refused the setting'
            }
        }
        # 2. PC ADB proximity override (Meta only).
        if ([string]$Headset.Brand -eq 'Pico') {
            if (-not $res.Error) { $res.Error = 'not supported on Pico without the companion app' }
            return $res
        }
        $dev = $null
        try { $dev = Resolve-HeadsetAdbDevice -Headset $Headset } catch { $dev = $null }
        if ($dev) {
            $okPx = if ($Enabled) { Set-HeadsetProximitySensorOverride -Device $dev } else { Set-HeadsetProximitySensorOverride -Device $dev -Clear }
            if ($okPx) { $res.Via = 'adb'; $res.Applied = $true; $res.Error = '' }
            else { $res.Error = 'the proximity override failed' }
        } elseif (-not $res.Error) { $res.Error = 'headset not reachable (companion or ADB)' }
        # Remember it for the post-reboot re-apply (ADR-0040), also when the headset is unreachable now.
        if (Get-Command Set-HeadsetSessionSettings -ErrorAction SilentlyContinue) {
            if ($Enabled) { [void](Set-HeadsetSessionSettings -HeadsetId $id -Reapply $true -Desired @{ proxKeepAwake = $true }) }
            else          { [void](Set-HeadsetSessionSettings -HeadsetId $id -Desired @{ proxKeepAwake = $false }) }
        }
        return $res
    } catch {
        $res.Error = $_.Exception.Message
        return $res
    }
}


# ---------------------------------------------------------------------------
# Companion telemetry push (ADR-0043): the per-fleet HTTP token, the report-target
# provisioning, and the ingest/read of the pushed values.
# ---------------------------------------------------------------------------

# The stable per-fleet companion HTTP token (app_kv row companion_token). Created once (random,
# 32 hex) and reused for every install and for validating POST /api/companion/telemetry. Cached
# per process. Never throws (falls back to a volatile token only if the store is unavailable).
# Example: $tok = Get-CompanionToken
function Get-CompanionToken {
    if ($script:CompanionTokenCache) { return $script:CompanionTokenCache }
    $tok = ''
    try {
        $raw = Get-DbKeyValue -Key 'companion_token'
        if ($raw -and $raw.token) { $tok = [string]$raw.token }
        if (-not $tok) {
            # Race-safe: insert only when absent (kv.insert_if_absent), then ALWAYS re-read the stored
            # value so two runspaces creating at once end up with the same token.
            $cand = [Guid]::NewGuid().ToString('N')
            $json = ([PSCustomObject]@{ token = $cand; at = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress)
            Invoke-DbNonQuery -Name 'kv.insert_if_absent' -Parameters @{ key = 'companion_token'; value_json = $json } | Out-Null
            $raw = Get-DbKeyValue -Key 'companion_token'
            if ($raw -and $raw.token) { $tok = [string]$raw.token } else { $tok = $cand }
        }
    } catch {
        if (-not $tok) { $tok = [Guid]::NewGuid().ToString('N') }
    }
    $script:CompanionTokenCache = $tok
    return $tok
}

# Tells the companion where to POST its telemetry: POSTs /settings with report_url +
# report_interval_sec (and the token in the header). Idempotent - only re-pushes when the target
# or interval changed for this IP within this process. Returns $true on success. Never throws.
# Example: Set-CompanionReportTarget -IP '192.168.1.243' -ReportUrl 'http://192.168.1.37:8080/api/companion/telemetry'
function Set-CompanionReportTarget {
    param(
        [Parameter(Mandatory)][string]$IP,
        [string]$ReportUrl = '',
        [int]$IntervalSec = 0,
        [int]$CompanionPort = 8765,
        [switch]$Force
    )
    if (-not $ReportUrl) { $ReportUrl = Get-CompanionReportUrl }
    if (-not $ReportUrl) { return $false }
    if ($IntervalSec -le 0) { $IntervalSec = if ($global:Companion_report_interval_sec) { [int]$global:Companion_report_interval_sec } else { 1 } }
    if (-not $script:CompanionReportMemo) { $script:CompanionReportMemo = @{} }
    $sig = "$ReportUrl|$IntervalSec"
    $now = [datetime]::UtcNow
    # Memo per IP: Sig (last signature pushed OK), CheckAt (last /status check), FailAt / FailSec (back-off).
    $m = $script:CompanionReportMemo[$IP]
    if (-not $m) { $m = @{ Sig = ''; CheckAt = [datetime]::MinValue; FailAt = [datetime]::MinValue; FailSec = 0 }; $script:CompanionReportMemo[$IP] = $m }
    if (-not $Force -and $m.FailSec -gt 0 -and ($now - $m.FailAt).TotalSeconds -lt $m.FailSec) { return $false }
    if (-not $Force -and $m.Sig -eq $sig) {
        # Same target as last push: trust it, but at most every 5 min confirm with GET /status.
        if (($now - $m.CheckAt).TotalSeconds -lt 300) { return $true }
        $m.CheckAt = $now
        $st = $null
        try { $st = Get-CompanionStatus -IP $IP -CompanionPort $CompanionPort } catch { $st = $null }
        if (-not $st) { return $true }                      # unreachable: nothing to repair now
        if ($st.PSObject.Properties['reportUrl'] -and ([string]$st.reportUrl -eq $ReportUrl)) { return $true }
        if (-not $st.PSObject.Properties['reportUrl']) { return $true }   # older app: cannot tell
        Write-Log "Set-CompanionReportTarget ${IP}: stored report url differs, re-pushing" -Level DEBUG
    }
    try {
        $body = @{ report_url = $ReportUrl; report_interval_sec = $IntervalSec }
        $r = Invoke-CompanionPost -IP $IP -Path '/settings' -Body $body -Token (Get-CompanionToken) -CompanionPort $CompanionPort
        if ($r -and $r.ok) {
            $m.Sig = $sig; $m.CheckAt = $now; $m.FailSec = 0
            Write-Log "Set-CompanionReportTarget $IP -> $ReportUrl (every ${IntervalSec}s)" -Level DEBUG
            return $true
        }
        $m.FailAt = $now
        $m.FailSec = if ($m.FailSec -le 0) { 60 } else { [Math]::Min(600, $m.FailSec * 2) }
        return $false
    } catch {
        Write-Log "Set-CompanionReportTarget $IP failed: $_" -Level DEBUG
        return $false
    }
}

# This server's telemetry report URL ( http://<lan host>:<web port>/api/companion/telemetry ),
# or '' when no LAN address or no web server. Reuses Get-ServerLanUrl (kiosk_functions.ps1).
# Example: Get-CompanionReportUrl
function Get-CompanionReportUrl {
    try {
        if (-not (Get-Command Get-ServerLanUrl -ErrorAction SilentlyContinue)) { return '' }
        $base = Get-ServerLanUrl
        if (-not $base) { return '' }
        return ($base.TrimEnd('/') + '/api/companion/telemetry')
    } catch { return '' }
}

# The telemetry value field names carried on the wire and stored in the kv row. thermalStatus and
# rssi (telemetry v2, D4) are stored in the row only; no database column and no info-record field.
$script:CompanionTelemetryFields = @('battery', 'charging', 'sourceW', 'battW', 'wattage', 'temp', 'cpuTemp', 'gpuTemp', 'skinTemp', 'ctrlLeft', 'ctrlRight', 'foregroundApp', 'thermalStatus', 'rssi', 'ctrlLeftState', 'ctrlRightState', 'plugged', 'battStatus', 'chargeCounterMah', 'refreshHz', 'refreshForcedHz')

# Telemetry v2 server-side constants (telemetry-v2.md section 3 and 6).
$script:CompanionKeepaliveSec = 5
$script:CompanionRateGuardMs  = 200

# The wire/stored field names (route and tests read them through this, not the script variable).
# Example: Get-CompanionTelemetryFieldNames
function Get-CompanionTelemetryFieldNames { return @($script:CompanionTelemetryFields) }

# Culture-proof ISO-8601 (or any date text) to a UTC DateTime, $null when unreadable.
# Example: ConvertTo-CompanionUtc -Text '2026-11-06T10:00:00.0000000Z'
function ConvertTo-CompanionUtc {
    param($Text)
    if ($null -eq $Text -or "$Text" -eq '') { return $null }
    try {
        if ($Text -is [datetime]) { return $Text.ToUniversalTime() }
        return [datetime]::Parse([string]$Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $null }
}

# The raw stored telemetry document of one headset (app_kv companion_telemetry_<id>), memoised 1 s
# per process/runspace. $null when none. Never throws. Example: $doc = Get-CompanionTelemetryDoc -HeadsetId 3
function Get-CompanionTelemetryDoc {
    param([Parameter(Mandatory)][int]$HeadsetId)
    if ($HeadsetId -le 0) { return $null }
    if (-not $script:CompanionTelemetryMemo) { $script:CompanionTelemetryMemo = @{} }
    $m = $script:CompanionTelemetryMemo[$HeadsetId]
    if ($m -and ([datetime]::UtcNow - $m.At).TotalSeconds -lt 1) { return $m.Val }
    $val = $null
    try { $val = Get-DbKeyValue -Key ("companion_telemetry_{0}" -f $HeadsetId) } catch { $val = $null }
    $script:CompanionTelemetryMemo[$HeadsetId] = @{ At = [datetime]::UtcNow; Val = $val }
    return $val
}

# T3.1 brand capability table. The normalised capability block the companion last reported
# (`cap` of its full pushes): @{Known;Brand;Family;HasTls;CanSelfAdb;CanReadControllers;CanForeground;
# CanThermal;CanSourceW;CanBattW;CanWattage (= either);SerialSource;AppVersion;VersionCode}. Known = $false (all other values $null)
# when no cap was ever stored. Never throws. Example: (Get-CompanionCapability -HeadsetId 3).Family
function Get-CompanionCapability {
    param([Parameter(Mandatory)][int]$HeadsetId)
    $r = [ordered]@{ Known = $false; Brand = $null; Family = $null; HasTls = $null; CanSelfAdb = $null
        CanReadControllers = $null; CanForeground = $null; CanThermal = $null; CanSourceW = $null; CanBattW = $null; CanWattage = $null
        SerialSource = $null; AppVersion = $null; VersionCode = $null; ProbeCatalog = $null; Probes = $null; Shell = $null }
    try {
        $doc = Get-CompanionTelemetryDoc -HeadsetId $HeadsetId
        $cap = if ($doc -and $doc.PSObject.Properties['cap']) { $doc.cap } else { $null }
        if ($cap) {
            $get = { param($n) if ($cap.PSObject.Properties[$n]) { $cap.$n } else { $null } }
            $r.Known = $true
            $r.Brand = & $get 'brand'; $r.Family = & $get 'family'
            $r.HasTls = & $get 'hasTls'; $r.CanSelfAdb = & $get 'canSelfAdb'
            $r.CanReadControllers = & $get 'canReadControllers'; $r.CanForeground = & $get 'canForeground'
            $r.CanThermal = & $get 'canThermal'
            $legacyW = & $get 'canWattage'
            $r.CanSourceW = & $get 'canSourceW'; if ($null -eq $r.CanSourceW) { $r.CanSourceW = $legacyW }
            $r.CanBattW = & $get 'canBattW'; if ($null -eq $r.CanBattW) { $r.CanBattW = $legacyW }
            $r.CanWattage = if ($null -eq $r.CanSourceW -and $null -eq $r.CanBattW) { $null } else { [bool]($r.CanSourceW -or $r.CanBattW) }
            $r.SerialSource = & $get 'serialSource'; $r.AppVersion = & $get 'appVersion'
            $r.VersionCode = & $get 'versionCode'
            $r.ProbeCatalog = & $get 'probeCatalog'; $r.Probes = & $get 'probes'; $r.Shell = & $get 'shell'
        }
    } catch { }
    return $r
}

# T3.1. Can this headset (registry row) do ADB over TLS? $false when its brand cannot
# (Test-HeadsetAdbTlsSupported, ADR-0038) or the companion reported hasTls = false; else $true.
# Never throws. Example: Test-HeadsetTlsCapable -Headset $row
function Test-HeadsetTlsCapable {
    param([Parameter(Mandatory)]$Headset)
    try {
        if (Get-Command Test-HeadsetAdbTlsSupported -ErrorAction SilentlyContinue) {
            if (-not (Test-HeadsetAdbTlsSupported -Brand ([string]$Headset.Brand))) { return $false }
        }
        $id = 0
        if ($Headset.PSObject.Properties['ID']) { [void][int]::TryParse([string]$Headset.ID, [ref]$id) }
        if ($id -gt 0) {
            $cap = Get-CompanionCapability -HeadsetId $id
            if ($cap.Known -and $null -ne $cap.HasTls -and -not [bool]$cap.HasTls) { return $false }
        }
        return $true
    } catch { return $true }
}

# T3.1. Pure. What ADB can fill per telemetry field for a brand: @{battery;thermal;wattage;foreground;
# apps;controllers}. Controllers are not readable on a Pico (Get-HeadsetPollSnapshot skips
# OVRRemoteService there). Example: (Get-HeadsetAdbFieldSupport -Brand 'Pico').controllers -> $false
function Get-HeadsetAdbFieldSupport {
    param([string]$Brand)
    return @{
        battery = $true; thermal = $true; wattage = $true; sourceW = $true; battW = $true; foreground = $true; apps = $true
        controllers = -not ($Brand -match 'pico')
    }
}

# Merges ONE push into app_kv companion_telemetry_<id> (telemetry v2, section 6). Call it inside the
# caller's transaction (the route does) so the row and the apps ingest commit together. -Push keys:
# Proto (1|2), Run, Seq, Full, Fields (hashtable wire name -> value; a $null value = explicit "known
# absent", proto 2 only), AgeMs (hashtable name -> ms between observation and send), Cap (object or
# $null: kept from the previous row when absent), StoreAppsSig (string; '' keeps the previous one),
# IdMatch ('serial'|'address'), Rtt (ms), Unknown (string[] of field names the app withdrew).
# Semantics: Full (or a new run) replaces the field set, otherwise the named fields MERGE. A proto 2
# non-full push with no state for this run, or after a seq gap, sets RequestFull. Returns
# @{Ok;RequestFull;Gap;PrevAppsSig;AppsSig}. Never throws.
# Example: Update-CompanionTelemetryRow -HeadsetId 3 -Push @{ Proto = 2; Run = 'a1'; Seq = 5; Full = $false; Fields = @{ battery = 80 } }
function Update-CompanionTelemetryRow {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [Parameter(Mandatory)][hashtable]$Push
    )
    $res = @{ Ok = $false; RequestFull = $false; Gap = $false; PrevAppsSig = ''; AppsSig = '' }
    if ($HeadsetId -le 0) { return $res }
    try {
        $key  = "companion_telemetry_{0}" -f $HeadsetId
        $prev = $null
        try { $prev = Get-DbKeyValue -Key $key } catch { $prev = $null }
        $proto = if ($Push.ContainsKey('Proto') -and $null -ne $Push.Proto) { [int]$Push.Proto } else { 1 }
        $run   = if ($Push.ContainsKey('Run')) { [string]$Push.Run } else { '' }
        $seq   = if ($Push.ContainsKey('Seq') -and $null -ne $Push.Seq) { [int64]$Push.Seq } else { -1 }
        $full  = [bool]$Push.Full
        $now   = [datetime]::UtcNow
        $fields = if ($Push.ContainsKey('Fields') -and $Push.Fields) { $Push.Fields } else { @{} }
        $ageMs  = if ($Push.ContainsKey('AgeMs') -and $Push.AgeMs) { $Push.AgeMs } else { @{} }

        $runChanged = ($proto -ge 2 -and $prev -and ([string]$prev.run) -ne $run)
        $gap = $false
        if ($proto -ge 2 -and $prev -and -not $runChanged -and $null -ne $prev.seq -and $seq -gt ([int64]$prev.seq + 1)) { $gap = $true }
        $res.Gap = $gap
        $res.RequestFull = ($proto -ge 2 -and -not $full -and ((-not $prev) -or $runChanged -or $gap))
        if ($prev -and $prev.appsSig) { $res.PrevAppsSig = [string]$prev.appsSig }

        $doc    = [ordered]@{}
        $absent = New-Object System.Collections.ArrayList
        $obs    = [ordered]@{}
        $names  = Get-CompanionTelemetryFieldNames
        $carry  = ($prev -and -not $full -and -not $runChanged)
        if ($carry) {
            foreach ($k in $names) { if ($null -ne $prev.$k) { $doc[$k] = $prev.$k } }
            foreach ($a in @($prev.absent)) { if ($a) { [void]$absent.Add([string]$a) } }
            if ($prev.obs) { foreach ($p in $prev.obs.PSObject.Properties) { $obs[$p.Name] = $p.Value } }
        }
        # Withdrawn fields (push key 'unknown'): no longer known by the app, so no longer fresh (local-probes 6.2).
        if ($Push.ContainsKey('Unknown') -and $Push.Unknown) {
            foreach ($u in @($Push.Unknown)) {
                $un = [string]$u
                if ($doc.Contains($un)) { $doc.Remove($un) }
                while ($absent.Contains($un)) { $absent.Remove($un) }
                if ($obs.Contains($un)) { $obs.Remove($un) }
            }
        }
        foreach ($k in $names) {
            if (-not $fields.ContainsKey($k)) { continue }
            $v = $fields[$k]
            $obsAt = $now
            if ($ageMs.ContainsKey($k) -and $null -ne $ageMs[$k]) { try { $obsAt = $now.AddMilliseconds(-1.0 * [double]$ageMs[$k]) } catch { $obsAt = $now } }
            if ($null -eq $v) {
                if ($doc.Contains($k)) { $doc.Remove($k) }
                if (-not $absent.Contains($k)) { [void]$absent.Add($k) }
            } else {
                $doc[$k] = $v
                while ($absent.Contains($k)) { $absent.Remove($k) }
            }
            $obs[$k] = $obsAt.ToString('o')
        }

        $doc['proto'] = $proto
        $doc['run']   = $run
        $doc['seq']   = $seq
        $cap = $null
        if ($Push.ContainsKey('Cap') -and $Push.Cap) { $cap = $Push.Cap } elseif ($prev -and $prev.cap) { $cap = $prev.cap }
        if ($cap) { $doc['cap'] = $cap }
        $sig = ''
        if ($Push.ContainsKey('StoreAppsSig') -and $Push.StoreAppsSig) { $sig = [string]$Push.StoreAppsSig }
        elseif ($prev -and $prev.appsSig) { $sig = [string]$prev.appsSig }
        if ($sig) { $doc['appsSig'] = $sig }
        $res.AppsSig = $sig
        $idm = ''
        if ($Push.ContainsKey('IdMatch') -and $Push.IdMatch) { $idm = [string]$Push.IdMatch }
        if ($idm) { $doc['idMatch'] = $idm }
        if ($Push.ContainsKey('Rtt') -and $null -ne $Push.Rtt) { $doc['rtt'] = $Push.Rtt }
        elseif ($prev -and $null -ne $prev.rtt) { $doc['rtt'] = $prev.rtt }
        $doc['absent'] = @($absent)
        $doc['obs']    = [PSCustomObject]$obs
        $doc['at']     = $now.ToString('o')
        Set-DbKeyValue -Key $key -Value ([PSCustomObject]$doc)
        if ($script:CompanionTelemetryMemo) { $script:CompanionTelemetryMemo.Remove($HeadsetId) }
        $res.Ok = $true
        return $res
    } catch {
        Write-Log ("Update-CompanionTelemetryRow failed for headset {0}: {1}" -f $HeadsetId, $_.Exception.Message) -Level DEBUG
        return $res
    }
}

# Writes one companion telemetry push (proto 1 semantics: flat fields, -Full replaces, otherwise the
# named fields MERGE onto what is stored). Kept for v1 callers; a thin wrapper over
# Update-CompanionTelemetryRow. Returns $true when written. Never throws.
# Example: Set-CompanionTelemetry -HeadsetId 3 -Full -Fields @{ battery = 87; charging = $true }
function Set-CompanionTelemetry {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [hashtable]$Fields = @{},
        [switch]$Full
    )
    $r = Update-CompanionTelemetryRow -HeadsetId $HeadsetId -Push @{ Proto = 1; Full = [bool]$Full; Fields = $Fields }
    return [bool]$r.Ok
}

# The last companion telemetry for one headset, or $null when the last push (of any kind, a keepalive
# included) is older than the window: -MaxAgeSec when given, else max(Companion_telemetry_stale_sec,
# 2.5 x cap.keepaliveSec), floor 2 s. The returned object carries the flat field values the current run
# reported (non-null only) plus: 'at'; '_absent' (fields explicitly reported as known-absent: fresh,
# shown as '-', no ADB fallback); '_fresh' (every field name that is fresh, present or absent); '_age'
# (name -> seconds since the device observed it); '_proto'; '_cap'; '_idMatch'; 'appsSig'; '_pushAgeSec'.
# A field missing from '_fresh' is read over ADB by the poll runspace. Never throws.
# Example: $t = Get-CompanionTelemetry -HeadsetId 3; if ($t -and $t._fresh -contains 'battery') { $t.battery }
function Get-CompanionTelemetry {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [int]$MaxAgeSec = 0
    )
    if ($HeadsetId -le 0) { return $null }
    $val = Get-CompanionTelemetryDoc -HeadsetId $HeadsetId
    if (-not $val -or -not $val.at) { return $null }
    $stale = if ($global:Companion_telemetry_stale_sec) { [int]$global:Companion_telemetry_stale_sec } else { 10 }
    $keep = 0.0
    try { if ($val.cap -and $val.cap.keepaliveSec) { $keep = [double]$val.cap.keepaliveSec } } catch { $keep = 0.0 }
    $win = if ($MaxAgeSec -gt 0) { [double]$MaxAgeSec } else { [Math]::Max([double]$stale, 2.5 * $keep) }
    if ($win -lt 2) { $win = 2 }
    $at = ConvertTo-CompanionUtc -Text $val.at
    if (-not $at) { return $null }
    $now = [datetime]::UtcNow
    $pushAge = ($now - $at).TotalSeconds
    if ($pushAge -gt $win) { return $null }

    $out   = [ordered]@{}
    $fresh = New-Object System.Collections.ArrayList
    foreach ($k in (Get-CompanionTelemetryFieldNames)) {
        if ($null -ne $val.$k) { $out[$k] = $val.$k; [void]$fresh.Add($k) }
    }
    $absent = @(@($val.absent) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($a in $absent) { if (-not $fresh.Contains($a)) { [void]$fresh.Add($a) } }
    # A keepalive-only document (no measurement at all) must not count as fresh.
    if ($fresh.Count -eq 0) { return $null }
    $age = @{}
    if ($val.obs) {
        foreach ($f in $fresh) {
            $o = ConvertTo-CompanionUtc -Text $val.obs.$f
            if ($o) { $age[$f] = [Math]::Max(0, [int][Math]::Round(($now - $o).TotalSeconds)) }
        }
    }
    $out['at']          = $val.at
    $out['appsSig']     = if ($val.appsSig) { [string]$val.appsSig } else { '' }
    $out['_absent']     = $absent
    $out['_fresh']      = @($fresh)
    $out['_age']        = $age
    $out['_proto']      = if ($val.proto) { [int]$val.proto } else { 1 }
    $out['_cap']        = $val.cap
    $out['_idMatch']    = if ($val.idMatch) { [string]$val.idMatch } else { '' }
    $out['_pushAgeSec'] = [Math]::Round($pushAge, 1)
    return [PSCustomObject]$out
}


# Fills a headset info record ($Info, a New-DefaultHeadsetInfo object) IN PLACE from one companion
# telemetry object ($Telemetry from Get-CompanionTelemetry), matching the string formats the ADB
# stage 2 produces (battery "87 %", temps "36.4", controllers "90 %"). Only fields the push carried
# are overwritten; a field the push reported as known-absent ('_absent') becomes '-'. Used by the
# VRMonitor poll runspace when the info source is companion. Never throws.
# Example: Set-HeadsetInfoFromCompanion -Info $workingInfo -Telemetry $ct
function Set-HeadsetInfoFromCompanion {
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)]$Telemetry
    )
    if (-not $Info -or -not $Telemetry) { return }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        if ($null -ne $Telemetry.battery)  { $Info.Battery = ("{0} %" -f [int]$Telemetry.battery) }
        if ($null -ne $Telemetry.charging) {
            $chg = [bool]$Telemetry.charging
            $Info.Charging = $chg
            # Power source = charger rating (sourceW). Unplugged = 0 W, not '-': metric_history only
            # samples numeric values, so '-' left the last value on the graph until the next charge.
            if (-not $chg) { $Info.ChargingWattage = "0" }
            elseif ($null -ne $Telemetry.sourceW) { $Info.ChargingWattage = ([double]$Telemetry.sourceW).ToString("0.#", $inv) }
        }
        # Battery charge power: signed, + = into the battery, sent plugged or not. An app <= 1.4.2
        # sends the magnitude as 'wattage': positive while charging, negative otherwise.
        $bw = $null
        if ($null -ne $Telemetry.battW) { $bw = [double]$Telemetry.battW }
        elseif ($null -ne $Telemetry.wattage) {
            $bw = [Math]::Abs([double]$Telemetry.wattage)
            if ($null -ne $Telemetry.charging -and -not [bool]$Telemetry.charging) { $bw = -$bw }
        }
        if ($null -ne $bw) {
            if ($bw -gt 100.0) { $bw = 100.0 } elseif ($bw -lt -100.0) { $bw = -100.0 }
            $Info.BatteryPower = $bw.ToString("0.0", $inv)
        }
        if ($null -ne $Telemetry.temp)     { $Info.Temp     = ([double]$Telemetry.temp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.cpuTemp)  { $Info.CpuTemp  = ([double]$Telemetry.cpuTemp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.gpuTemp)  { $Info.GpuTemp  = ([double]$Telemetry.gpuTemp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.skinTemp) { $Info.SkinTemp = ([double]$Telemetry.skinTemp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.ctrlLeft)  { $Info.BatteryControllerLeft  = ("{0} %" -f [int]$Telemetry.ctrlLeft) }
        if ($null -ne $Telemetry.ctrlRight) { $Info.BatteryControllerRight = ("{0} %" -f [int]$Telemetry.ctrlRight) }
        $ab = @()
        if ($Telemetry.PSObject.Properties['_absent']) { $ab = @($Telemetry._absent) }
        foreach ($a in $ab) {
            switch ([string]$a) {
                'battery'   { $Info.Battery = '-' }
                'sourceW'   { $Info.ChargingWattage = '-' }
                'battW'     { $Info.BatteryPower = '-' }
                'wattage'   { $Info.BatteryPower = '-' }
                'temp'      { $Info.Temp = '-' }
                'cpuTemp'   { $Info.CpuTemp = '-' }
                'gpuTemp'   { $Info.GpuTemp = '-' }
                'skinTemp'  { $Info.SkinTemp = '-' }
                'ctrlLeft'  { $Info.BatteryControllerLeft = '-' }
                'ctrlRight' { $Info.BatteryControllerRight = '-' }
            }
        }
    } catch { }
}


# ---------------------------------------------------------------------------
# Telemetry v2 (telemetry-v2.md): token epoch, 401 drift records, server config
# sent in every 2xx, per-headset push counters, bootstrap and self-heal.
# ---------------------------------------------------------------------------

# The token epoch (app_kv companion_token_epoch, int >= 1): bumped on any token rotation, returned in
# every 2xx/401 of the telemetry route and echoed by the app in X-VRHM-Token-Epoch. Created at 1 on
# first read (insert_if_absent). Memoised 5 s. Never throws (1 on failure).
# Example: $e = Get-CompanionTokenEpoch
function Get-CompanionTokenEpoch {
    if ($script:CompanionEpochMemo -and ([datetime]::UtcNow - $script:CompanionEpochMemo.At).TotalSeconds -lt 5) { return [int]$script:CompanionEpochMemo.Val }
    $v = 1
    try {
        $raw = Get-DbKeyValue -Key 'companion_token_epoch'
        if ($null -eq $raw) {
            Invoke-DbNonQuery -Name 'kv.insert_if_absent' -Parameters @{ key = 'companion_token_epoch'; value_json = '1' } | Out-Null
            $raw = Get-DbKeyValue -Key 'companion_token_epoch'
        }
        $n = 0
        if ([int]::TryParse([string]$raw, [ref]$n) -and $n -ge 1) { $v = $n }
    } catch { $v = 1 }
    $script:CompanionEpochMemo = @{ At = [datetime]::UtcNow; Val = $v }
    return $v
}

# Bumps the token epoch by one (call after ANY rotation of the fleet token). Returns the new epoch.
# Never throws. Example: Update-CompanionTokenEpoch
function Update-CompanionTokenEpoch {
    $n = (Get-CompanionTokenEpoch) + 1
    try { Set-DbKeyValue -Key 'companion_token_epoch' -Value $n } catch { }
    $script:CompanionEpochMemo = $null
    return $n
}

# Records one rejected (401) push in app_kv companion_auth_fail_<id> = {count, firstAt, lastAt,
# sentEpoch, foreign, healedAt}: count restarts when the first failure is older than 2 min. A sent
# epoch higher than ours means the app belongs to another server database (foreign: never healed
# automatically). Returns @{Count;Foreign;Sent;Ours}. Never throws.
# Example: Register-CompanionAuthFailure -HeadsetId 3 -SentEpoch '4'
function Register-CompanionAuthFailure {
    param([Parameter(Mandatory)][int]$HeadsetId, [string]$SentEpoch = '')
    $r = @{ Count = 0; Foreign = $false; Sent = 0; Ours = 1 }
    if ($HeadsetId -le 0) { return $r }
    try {
        $key = "companion_auth_fail_{0}" -f $HeadsetId
        $now = [datetime]::UtcNow
        $row = Get-DbKeyValue -Key $key
        $count = 1; $first = $now
        if ($row -and $row.firstAt) {
            $f = ConvertTo-CompanionUtc -Text $row.firstAt
            if ($f -and ($now - $f).TotalSeconds -le 120) { $count = [int]$row.count + 1; $first = $f }
        }
        $sent = 0
        [void][int]::TryParse($SentEpoch, [ref]$sent)
        $ours = Get-CompanionTokenEpoch
        $healed = if ($row -and $row.healedAt) { [string]$row.healedAt } else { '' }
        $doc = [PSCustomObject]@{ count = $count; firstAt = $first.ToString('o'); lastAt = $now.ToString('o'); sentEpoch = $sent; foreign = ($sent -gt $ours); healedAt = $healed }
        Set-DbKeyValue -Key $key -Value $doc
        $r = @{ Count = $count; Foreign = ($sent -gt $ours); Sent = $sent; Ours = $ours }
    } catch { }
    return $r
}

# Per-headset push counters of the telemetry route (in memory, web server process): count (stored +
# rate-guarded), bytes, last handler ms, dropped, 401/404 counts, 401 window for "token drift". One
# plain hashtable: the route and /api/headsets-status both run on the accept loop. Never throws.
# Kind: ok | dropped | 401 | 404 | error. Example: Add-CompanionPushStat -HeadsetId 3 -Kind ok -Bytes 220 -HandlerMs 4.2
function Add-CompanionPushStat {
    param([int]$HeadsetId, [string]$Kind = 'ok', [int64]$Bytes = 0, [double]$HandlerMs = 0)
    if ($HeadsetId -le 0) { return }
    try {
        if (-not $script:CompanionPushStats) { $script:CompanionPushStats = @{} }
        $s = $script:CompanionPushStats[$HeadsetId]
        if (-not $s) {
            $s = @{ Count = [int64]0; Bytes = [int64]0; Dropped = [int64]0; N401 = [int64]0; N404 = [int64]0; Errors = [int64]0
                    LastHandlerMs = 0.0; LastPushUtc = [datetime]::MinValue; LastProcessedUtc = [datetime]::MinValue
                    AuthWindowStart = [datetime]::MinValue; AuthWindowCount = 0; Ring = New-Object System.Collections.ArrayList }
            $script:CompanionPushStats[$HeadsetId] = $s
        }
        $now = [datetime]::UtcNow
        switch ($Kind) {
            'ok'      { $s.Count++; $s.Bytes += $Bytes; $s.LastPushUtc = $now; $s.LastProcessedUtc = $now; $s.LastHandlerMs = $HandlerMs
                        [void]$s.Ring.Add($HandlerMs); if ($s.Ring.Count -gt 60) { $s.Ring.RemoveAt(0) }
                        $s.AuthWindowCount = 0 }
            'dropped' { $s.Count++; $s.Dropped++; $s.Bytes += $Bytes; $s.LastPushUtc = $now; $s.LastHandlerMs = $HandlerMs }
            '401'     { $s.N401++
                        if (($now - $s.AuthWindowStart).TotalSeconds -gt 120) { $s.AuthWindowStart = $now; $s.AuthWindowCount = 1 } else { $s.AuthWindowCount++ } }
            '404'     { $s.N404++ }
            default   { $s.Errors++ }
        }
    } catch { }
}

# True when the previous PROCESSED push of this headset is younger than -Ms (default 200): the route
# then answers 200 with a raised interval and does not store (rate guard). Never throws.
# Example: if (Test-CompanionPushTooSoon -HeadsetId 3) { ... }
function Test-CompanionPushTooSoon {
    param([int]$HeadsetId, [int]$Ms = 0)
    if ($Ms -le 0) { $Ms = $script:CompanionRateGuardMs }
    try {
        $s = if ($script:CompanionPushStats) { $script:CompanionPushStats[$HeadsetId] } else { $null }
        if (-not $s) { return $false }
        return (([datetime]::UtcNow - $s.LastProcessedUtc).TotalMilliseconds -lt $Ms)
    } catch { return $false }
}

# Counters of one headset for /api/headsets-status and Measure-CompanionLoad.ps1, or $null.
# Example: (Get-CompanionPushStats -HeadsetId 3).Count
function Get-CompanionPushStats {
    param([Parameter(Mandatory)][int]$HeadsetId)
    try {
        $s = if ($script:CompanionPushStats) { $script:CompanionPushStats[$HeadsetId] } else { $null }
        if (-not $s) { return $null }
        $p95 = 0.0
        if ($s.Ring.Count -gt 0) {
            $sorted = @($s.Ring | Sort-Object)
            $p95 = [double]$sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Floor(0.95 * $sorted.Count))]
        }
        $ageMs = -1
        if ($s.LastPushUtc -gt [datetime]::MinValue) { $ageMs = [int64]([datetime]::UtcNow - $s.LastPushUtc).TotalMilliseconds }
        $drift = (($s.AuthWindowCount -ge 3) -and (([datetime]::UtcNow - $s.AuthWindowStart).TotalSeconds -le 120))
        return @{ Count = $s.Count; Bytes = $s.Bytes; Dropped = $s.Dropped; N401 = $s.N401; N404 = $s.N404
                  LastHandlerMs = $s.LastHandlerMs; HandlerMsP95 = $p95; LastPushAgeMs = $ageMs; TokenDrift = $drift }
    } catch { return $null }
}

# The status fields added to each /api/headsets-status record: companion_age_ms (since the last push,
# from the stored row, -1 none), companion_proto, companion_cap, companion_rtt_ms and the route
# counters. Always returns a hashtable. Never throws. Example: $c = Get-CompanionPushSummary -HeadsetId 3
function Get-CompanionPushSummary {
    param([Parameter(Mandatory)][int]$HeadsetId)
    $o = @{ companion_age_ms = -1; companion_proto = 0; companion_cap = $null; companion_rtt_ms = $null
            push_count = 0; push_bytes = 0; last_push_handler_ms = 0; last_push_age_ms = -1; push_dropped = 0; push_handler_ms_p95 = 0; token_drift = $false }
    try {
        $doc = Get-CompanionTelemetryDoc -HeadsetId $HeadsetId
        if ($doc -and $doc.at) {
            $at = ConvertTo-CompanionUtc -Text $doc.at
            if ($at) { $o.companion_age_ms = [int64]([datetime]::UtcNow - $at).TotalMilliseconds }
            $o.companion_proto = if ($doc.proto) { [int]$doc.proto } else { 1 }
            $o.companion_cap   = $doc.cap
            if ($null -ne $doc.rtt) { $o.companion_rtt_ms = $doc.rtt }
        }
        $s = Get-CompanionPushStats -HeadsetId $HeadsetId
        if ($s) {
            $o.push_count = $s.Count; $o.push_bytes = $s.Bytes; $o.last_push_handler_ms = [Math]::Round($s.LastHandlerMs, 1)
            $o.last_push_age_ms = $s.LastPushAgeMs; $o.push_dropped = $s.Dropped; $o.push_handler_ms_p95 = [Math]::Round($s.HandlerMsP95, 1)
            $o.token_drift = [bool]$s.TokenDrift
        }
    } catch { }
    return $o
}

# The per-probe overrides sent to the companion (local-probes section 7): $global:Companion_probe_overrides
# (id -> @{enabled;everySec}), only ids present in the PC catalogue, everySec clamped to its min/max.
# Returns an empty hashtable when none. Never throws. Example: Get-CompanionProbeOverrides
function Get-CompanionProbeOverrides {
    $out = @{}
    try {
        $ov = $global:Companion_probe_overrides
        if (-not $ov) { return $out }
        $props = if ($ov -is [hashtable]) { $ov.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = $_.Key; Value = $_.Value } } } else { $ov.PSObject.Properties }
        foreach ($pr in $props) {
            $id = [string]$pr.Name; $v = $pr.Value
            if (-not $v) { continue }
            $cat = $null
            if (Get-Command Get-CompanionProbe -ErrorAction SilentlyContinue) { $cat = Get-CompanionProbe -Id $id }
            if (-not $cat) { continue }
            $e = @{}
            $en = if ($v -is [hashtable]) { $v['enabled'] } else { $v.enabled }
            $ev = if ($v -is [hashtable]) { $v['everySec'] } else { $v.everySec }
            if ($null -ne $en) { $e.enabled = [bool]$en }
            if ($null -ne $ev) {
                $s = [int]$ev
                if ($cat.PSObject.Properties['minEverySec'] -and $s -lt [int]$cat.minEverySec) { $s = [int]$cat.minEverySec }
                if ($cat.PSObject.Properties['maxEverySec'] -and $s -gt [int]$cat.maxEverySec) { $s = [int]$cat.maxEverySec }
                $e.everySec = $s
            }
            if ($e.Count -gt 0) { $out[$id] = $e }
        }
    } catch { }
    return $out
}

# Display fields of the local probes for one headset (local-probes section 8.5), from the FRESH companion
# telemetry only: @{plugged;batt_status;charge_counter_mah;refresh_hz;refresh_forced_hz;
# ctrl_left_state;ctrl_right_state}; every value is $null when not fresh. Never throws.
# Example: (Get-CompanionPowerDisplay -HeadsetId 3).refresh_hz
function Get-CompanionPowerDisplay {
    param([Parameter(Mandatory)][int]$HeadsetId)
    $o = [ordered]@{ plugged = $null; batt_status = $null; charge_counter_mah = $null
        refresh_hz = $null; refresh_forced_hz = $null; ctrl_left_state = $null; ctrl_right_state = $null }
    try {
        $t = Get-CompanionTelemetry -HeadsetId $HeadsetId
        if ($t) {
            $fr = @($t._fresh)
            $g = { param($n) if ($fr -contains $n -and $null -ne $t.$n) { $t.$n } else { $null } }
            $o.plugged = & $g 'plugged'; $o.batt_status = & $g 'battStatus'; $o.charge_counter_mah = & $g 'chargeCounterMah'
            $o.refresh_hz = & $g 'refreshHz'; $o.refresh_forced_hz = & $g 'refreshForcedHz'
            $o.ctrl_left_state = & $g 'ctrlLeftState'; $o.ctrl_right_state = & $g 'ctrlRightState'
        }
    } catch { }
    return $o
}

# The server config returned in every 2xx of the telemetry route (spec section 3). -Hot = a capture or
# recording runs for the headset, -RequestFull = ask for a full push, -AppsSig = signature the PC
# holds, -Slow = rate guard hit (interval doubled). Never throws.
# Example: Get-CompanionServerConfig -HeadsetId 3 -Hot $true -AppsSig 'abc'
function Get-CompanionServerConfig {
    param([int]$HeadsetId, [bool]$Hot = $false, [bool]$RequestFull = $false, [string]$AppsSig = '', [switch]$Slow, [switch]$ProbesEnabled)
    $interval = if ($global:Companion_report_interval_sec) { [int]$global:Companion_report_interval_sec } else { 1 }
    if ($interval -lt 1) { $interval = 1 }
    if ($Slow) { $interval = [Math]::Max(2, $interval * 2) }
    $stale = if ($global:Companion_telemetry_stale_sec) { [int]$global:Companion_telemetry_stale_sec } else { 10 }
    $fullMin = 5
    try { if ($null -ne $global:Companion_full_resend_min) { $fullMin = [int]$global:Companion_full_resend_min } } catch { $fullMin = 5 }
    if ($fullMin -lt 1) { $fullMin = 1 }
    if ($fullMin -gt 60) { $fullMin = 60 }
    $probeCfg = Get-CompanionProbeOverrides
    return @{
        fullResendMin = $fullMin; probesEnabled = [bool]$ProbesEnabled; probes = $probeCfg
        ok = $true; proto = 2; id = $HeadsetId
        serverTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        intervalSec = $interval; keepaliveSec = [int]$script:CompanionKeepaliveSec; staleSec = $stale
        hot = $Hot; requestFull = $RequestFull; appsSig = $AppsSig; tokenEpoch = (Get-CompanionTokenEpoch)
    }
}

# Whether the legacy /settings bootstrap push (Set-CompanionReportTarget) is still needed for one
# headset. A proto-2 app gets its config from every push response, so it is bootstrap only: needed when
# the app is proto 1 or never pushed, when nothing was pushed for 5 min, or when the server LAN URL
# changed since this process last saw it. Never throws.
# Example: if (Test-CompanionBootstrapNeeded -HeadsetId 3 -IP $ip -ReportUrl $url) { Set-CompanionReportTarget ... }
function Test-CompanionBootstrapNeeded {
    param([Parameter(Mandatory)][int]$HeadsetId, [string]$IP = '', [string]$ReportUrl = '')
    try {
        if (-not $script:CompanionBootUrl) { $script:CompanionBootUrl = @{} }
        $changed = $false
        if ($IP) {
            $seen = $script:CompanionBootUrl[$IP]
            if ($seen -and $seen -ne $ReportUrl) { $changed = $true }
            $script:CompanionBootUrl[$IP] = $ReportUrl
        }
        if ($changed) { return $true }
        $doc = Get-CompanionTelemetryDoc -HeadsetId $HeadsetId
        if (-not $doc -or [int]$doc.proto -lt 2 -or -not $doc.at) { return $true }
        $at = ConvertTo-CompanionUtc -Text $doc.at
        if (-not $at) { return $true }
        return (([datetime]::UtcNow - $at).TotalSeconds -gt 300)
    } catch { return $true }
}

# Revives a force-stopped companion over ADB (something on the headset ran a bulk am force-stop; a
# stopped app never restarts alone). Runs only when the last telemetry push (doc.at) is older than 60 s
# and at most once per 3 min per headset. ONE adb shell script: when the service is not running it
# allowlists the app against power saving and sends the cmd 'start' broadcast with -f 0x20 (includes
# stopped packages; the receiver then calls startForegroundService); it also re-appends the
# ApproveService to enabled_accessibility_services when missing (append, never overwrite). Never
# brings an activity to the foreground. ONE WARNING (Companion.Revived) when it did something.
# Returns @{Attempted;Started;A11y}. Never throws. The caller guarantees the info source is companion.
# Example: Invoke-CompanionRevive -Headset $row -Device $device -Doc (Get-CompanionTelemetryDoc -HeadsetId 3)
function Invoke-CompanionRevive {
    param(
        [Parameter(Mandatory)]$Headset,
        [Parameter(Mandatory)]$Device,
        $Doc = $null,
        [switch]$Force,
        [string]$adb = $global:adbPath
    )
    $res = @{ Attempted = $false; Started = $false; A11y = $false }
    try {
        $id = [int]$Headset.ID
        if ($id -le 0 -or -not $Device) { return $res }
        $pkg = [string]$global:CompanionPackageName
        if (-not $pkg) { $pkg = 'com.vrheadsetmanager.companion' }
        if ($pkg -notmatch '^[A-Za-z0-9._]+$') { return $res }
        if (-not $Force) {
            if (-not $Doc) { return $res }
            $at = ConvertTo-CompanionUtc -Text $Doc.at
            if (-not $at -or ([datetime]::UtcNow - $at).TotalSeconds -le 60) { return $res }
        }
        if (-not $script:CompanionReviveState) { $script:CompanionReviveState = @{} }
        $last = $script:CompanionReviveState[$id]
        if (-not $Force -and $last -and ([datetime]::UtcNow - $last).TotalMinutes -lt 3) { return $res }
        $script:CompanionReviveState[$id] = [datetime]::UtcNow
        $res.Attempted = $true

        $script = @(
            "pkg=$pkg",
            'svc=$pkg/$pkg.ApproveService',
            'n=$(dumpsys activity services $pkg | grep -c ServiceRecord)',
            'if [ "$n" = 0 ]; then dumpsys deviceidle whitelist +$pkg >/dev/null 2>&1; am broadcast -f 0x20 -n $pkg/.CmdReceiver -a $pkg.CMD --es cmd start >/dev/null 2>&1; echo REVIVE_START; fi',
            'cur=$(settings get secure enabled_accessibility_services)',
            'case ":$cur:" in *":$svc:"*) ;; *) if [ -z "$cur" ] || [ "$cur" = null ]; then new=$svc; else new="$cur:$svc"; fi; settings put secure enabled_accessibility_services "$new"; settings put secure accessibility_enabled 1; echo REVIVE_A11Y;; esac',
            'echo REVIVE_DONE'
        ) -join "`n"
        $out = Invoke-AdbCmd -Device $Device -Command $script -ShellScript -adb $adb -SilentOnFail
        if ($out -eq $false) { return $res }
        $txt = (@($out) -join ' ')
        $res.Started = ($txt -match 'REVIVE_START')
        $res.A11y = ($txt -match 'REVIVE_A11Y')
        if ($res.Started -or $res.A11y) {
            Write-Log ((Get-CompanionText -Key 'Revived' -Fallback 'Companion on {0}: app was stopped, revived over ADB') -f [string]$Headset.Name) -Level WARNING
        }
    } catch { }
    return $res
}

# Self-heal of the companion identity over ANY ADB transport (spec section 6, operator decision D1):
# (a) token drift: 3 rejected pushes in 2 min (companion_auth_fail_<id>) -> settoken with the current
# token (plus setserial when the serial is not provisioned); (b) serial: the route matched the push by
# address, or cap.serialSource is not 'provisioned' -> setserial. At most once per 10 min per headset
# and kind, ONE WARNING each; a foreign token epoch (app of another server database) is never healed.
# Runs in the poll runspace after the ADB device is resolved, never on the web request path. Returns
# @{Token;Serial} booleans (attempted). Never throws.
# Example: Invoke-CompanionIdentityHeal -Headset $liveHeadset -Device $device
function Invoke-CompanionIdentityHeal {
    param(
        [Parameter(Mandatory)]$Headset,
        [Parameter(Mandatory)]$Device,
        [string]$adb = $global:adbPath
    )
    $did = @{ Token = $false; Serial = $false }
    try {
        $id = [int]$Headset.ID
        if ($id -le 0 -or -not $Device) { return $did }
        if (-not $script:CompanionHealState) { $script:CompanionHealState = @{} }
        $st = $script:CompanionHealState[$id]
        if (-not $st) { $st = @{ TokenAt = [datetime]::MinValue; SerialAt = [datetime]::MinValue }; $script:CompanionHealState[$id] = $st }
        $now = [datetime]::UtcNow
        $name = [string]$Headset.Name
        $serial = ([string]$Headset.SerialNumber).Trim()
        $serialOk = ($serial -match '^[A-Za-z0-9._-]{4,64}$')

        $needSerial = $false
        $doc = Get-CompanionTelemetryDoc -HeadsetId $id
        if ($doc) {
            try { [void](Invoke-CompanionRevive -Headset $Headset -Device $Device -Doc $doc -adb $adb) } catch { }
            $src = ''
            try { if ($doc.cap -and $doc.cap.serialSource) { $src = [string]$doc.cap.serialSource } } catch { $src = '' }
            if (([string]$doc.idMatch) -eq 'address') { $needSerial = $true }
            elseif ($src -and $src -ne 'provisioned') { $needSerial = $true }
        }

        $needToken = $false
        $row = $null
        try { $row = Get-DbKeyValue -Key ("companion_auth_fail_{0}" -f $id) } catch { $row = $null }
        if ($row -and [int]$row.count -ge 3 -and -not [bool]$row.foreign) {
            $last = ConvertTo-CompanionUtc -Text $row.lastAt
            $healed = ConvertTo-CompanionUtc -Text $row.healedAt
            if ($last -and ($now - $last).TotalSeconds -le 300 -and (-not $healed -or $healed -lt $last)) { $needToken = $true }
        }

        if ($needToken -and ($now - $st.TokenAt).TotalMinutes -ge 10) {
            $st.TokenAt = $now
            $did.Token = $true
            $okTok = [bool](Invoke-CompanionCmd -Device $Device -Cmd 'settoken' -Extra @('--es', 'token', (Get-CompanionToken)) -adb $adb)
            $okSer = $true
            if ($serialOk) { $okSer = [bool](Invoke-CompanionCmd -Device $Device -Cmd 'setserial' -Extra @('--es', 'serial', $serial) -adb $adb) }
            $st.SerialAt = $now
            try {
                $upd = [PSCustomObject]@{ count = 0; firstAt = [string]$row.firstAt; lastAt = [string]$row.lastAt; sentEpoch = $row.sentEpoch; foreign = $false; healedAt = $now.ToString('o') }
                Set-DbKeyValue -Key ("companion_auth_fail_{0}" -f $id) -Value $upd
            } catch { }
            Write-Log ((Get-CompanionText -Key 'TokenHealed' -Fallback 'Companion on {0}: token re-sent over ADB after repeated rejected pushes (token {1}, serial {2})') -f $name, $(if ($okTok) { 'ok' } else { 'failed' }), $(if ($okSer) { 'ok' } else { 'failed' })) -Level WARNING
        }
        elseif ($needSerial -and $serialOk -and ($now - $st.SerialAt).TotalMinutes -ge 10) {
            $st.SerialAt = $now
            $did.Serial = $true
            $okSer = [bool](Invoke-CompanionCmd -Device $Device -Cmd 'setserial' -Extra @('--es', 'serial', $serial) -adb $adb)
            Write-Log ((Get-CompanionText -Key 'SerialHealed' -Fallback 'Companion on {0}: adb serial re-sent over ADB (it was matched by address) - {1}') -f $name, $(if ($okSer) { 'ok' } else { 'failed' })) -Level WARNING
        }
    } catch { }
    return $did
}


# ---------------------------------------------------------------------------------------------
# Companion ownership (which VRHM server the companion reports to) and version state.
# Each server has its OWN companion token, so a companion provisioned by another server answers
# 401 to this one. /health is the only open endpoint (alive + version).
# ---------------------------------------------------------------------------------------------

# One GET returning the HTTP status code (0 = no answer) and the parsed JSON body ($null when none).
# Unlike Invoke-RestMethod it tells a 401 from a timeout. Never throws.
# Example: $r = Invoke-CompanionHttpGet -Url 'http://192.168.1.243:8765/health'; $r.Code
function Invoke-CompanionHttpGet {
    param([Parameter(Mandatory)][string]$Url, [string]$Token = '', [int]$TimeoutSec = 2)
    $res = @{ Code = 0; Body = $null }
    try {
        $r = Invoke-WebRequest -Uri $Url -Method GET -Headers (Get-CompanionHttpHeaders -Token $Token) -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $res.Code = [int]$r.StatusCode
        try { $res.Body = ($r.Content | ConvertFrom-Json) } catch { $res.Body = $null }
    } catch {
        try {
            $resp = $_.Exception.Response
            if ($resp) { $res.Code = [int]$resp.StatusCode }
        } catch { }
    }
    return $res
}

# Pure. Compares two dotted companion versions (1.4.3): returns 'ok' (equal or one unknown),
# 'older' (installed < available) or 'newer' (installed > available). Never throws.
# Example: Get-CompanionVersionState -Installed '1.4.2' -Available '1.4.3'   # older
function Get-CompanionVersionState {
    param([string]$Installed = '', [string]$Available = '')
    try {
        $i = ([string]$Installed).Trim().TrimStart('vV'); $a = ([string]$Available).Trim().TrimStart('vV')
        if (-not $i -or -not $a) { return 'ok' }
        $pi = @($i -split '[.\-]' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
        $pa = @($a -split '[.\-]' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } })
        $len = [Math]::Max($pi.Count, $pa.Count)
        for ($k = 0; $k -lt $len; $k++) {
            $x = if ($k -lt $pi.Count) { $pi[$k] } else { 0 }
            $y = if ($k -lt $pa.Count) { $pa[$k] } else { 0 }
            if ($x -lt $y) { return 'older' }
            if ($x -gt $y) { return 'newer' }
        }
        return 'ok'
    } catch { return 'ok' }
}

# Pure mapping of the two HTTP answers to an ownership record. -HealthCode/-StatusCode are HTTP codes
# (0 = no answer); -Health/-Status the parsed bodies; -OurUrl this server's report URL.
# State: unreachable (no /health answer), ours, foreign (401 on /status with our token, or a different
# reportUrl), unknown (answered, but neither). ReportUrl is what the companion reports to when known
# ('' otherwise; a 1.4.4+ app also gives the host in /health.reportHost).
# Example: ConvertTo-CompanionOwnership -HealthCode 200 -StatusCode 401 -Health $h -OurUrl $url
function ConvertTo-CompanionOwnership {
    param([int]$HealthCode = 0, [int]$StatusCode = 0, $Health = $null, $Status = $null, [string]$OurUrl = '')
    $o = @{ State = 'unreachable'; Version = ''; VersionCode = 0; ReportUrl = ''; Reason = '' }
    if ($HealthCode -ne 200) { $o.Reason = 'no /health answer'; return $o }
    try {
        if ($Health -and $Health.PSObject.Properties['version']) { $o.Version = [string]$Health.version }
        if ($Health -and $Health.PSObject.Properties['versionCode']) { $o.VersionCode = [int]$Health.versionCode }
        if ($Health -and $Health.PSObject.Properties['reportHost']) { $o.ReportUrl = [string]$Health.reportHost }
    } catch { }
    if ($StatusCode -eq 401) { $o.State = 'foreign'; $o.Reason = 'token not ours'; return $o }
    if ($StatusCode -eq 200 -and $Status) {
        $rep = ''
        try { if ($Status.PSObject.Properties['reportUrl']) { $rep = [string]$Status.reportUrl } } catch { $rep = '' }
        if ($rep) { $o.ReportUrl = $rep }
        if (-not $rep -or -not $OurUrl -or $rep.TrimEnd('/') -eq $OurUrl.TrimEnd('/')) { $o.State = 'ours' }
        else { $o.State = 'foreign'; $o.Reason = 'reports to another URL' }
        return $o
    }
    $o.State = 'unknown'; $o.Reason = "status HTTP $StatusCode"
    return $o
}

# Who does the companion on this headset belong to? ONE /health (open) + ONE /status with OUR token,
# over HTTP only (no ADB). Returns @{State;Version;VersionCode;ReportUrl;Reason} (see
# ConvertTo-CompanionOwnership). Never throws.
# Example: (Get-CompanionOwnership -IP '192.168.1.243').State
function Get-CompanionOwnership {
    param([Parameter(Mandatory)][string]$IP, [int]$CompanionPort = 8765, [int]$TimeoutSec = 2)
    try {
        $h = Invoke-CompanionHttpGet -Url "http://${IP}:${CompanionPort}/health" -TimeoutSec $TimeoutSec
        if ($h.Code -ne 200) { return (ConvertTo-CompanionOwnership -HealthCode $h.Code) }
        $s = Invoke-CompanionHttpGet -Url "http://${IP}:${CompanionPort}/status" -Token (Get-CompanionToken) -TimeoutSec $TimeoutSec
        $ours = ''
        try { $ours = Get-CompanionReportUrl } catch { $ours = '' }
        return (ConvertTo-CompanionOwnership -HealthCode $h.Code -StatusCode $s.Code -Health $h.Body -Status $s.Body -OurUrl $ours)
    } catch { return @{ State = 'unreachable'; Version = ''; VersionCode = 0; ReportUrl = ''; Reason = [string]$_ } }
}

# The stored ownership of one headset (app_kv companion_owner_<id> = {state,version,reportUrl,at}), or $null.
# Example: (Get-CompanionOwnerState -HeadsetId 3).state
function Get-CompanionOwnerState {
    param([Parameter(Mandatory)][int]$HeadsetId)
    try { return (Get-DbKeyValue -Key ("companion_owner_{0}" -f $HeadsetId)) } catch { return $null }
}

# Writes companion_owner_<id> only when state / version / reportUrl changed (or older than 5 min).
# Example: Set-CompanionOwnerState -HeadsetId 3 -Ownership $o
function Set-CompanionOwnerState {
    param([Parameter(Mandatory)][int]$HeadsetId, [Parameter(Mandatory)]$Ownership)
    try {
        $key = "companion_owner_{0}" -f $HeadsetId
        $cur = $null
        try { $cur = Get-DbKeyValue -Key $key } catch { $cur = $null }
        $same = $cur -and ([string]$cur.state -eq [string]$Ownership.State) -and ([string]$cur.version -eq [string]$Ownership.Version) -and ([string]$cur.reportUrl -eq [string]$Ownership.ReportUrl)
        if ($same) {
            $at = ConvertTo-CompanionUtc -Text $cur.at
            if ($at -and ([datetime]::UtcNow - $at).TotalMinutes -lt 5) { return $false }
        }
        Set-DbKeyValue -Key $key -Value ([PSCustomObject]@{ state = [string]$Ownership.State; version = [string]$Ownership.Version; reportUrl = [string]$Ownership.ReportUrl; at = [datetime]::UtcNow.ToString('o') })
        return $true
    } catch { return $false }
}

# Removes the stored ownership (Remove-Headset). Example: Remove-CompanionOwnerState -HeadsetId 3
function Remove-CompanionOwnerState {
    param([Parameter(Mandatory)][int]$HeadsetId)
    try { Remove-DbKeyValue -Key ("companion_owner_{0}" -f $HeadsetId) } catch { }
}

# Re-attaches the companion of a headset to THIS server (operator action, never automatic): over ADB
# sends this server's token (settoken), then points the report URL here (/settings, forced) and
# re-reads the ownership. Returns @{Ok;State;Error}. Never throws. The other server loses the headset.
# Example: $r = Invoke-CompanionReattach -Headset $row -Device $device
function Invoke-CompanionReattach {
    param([Parameter(Mandatory)]$Headset, [Parameter(Mandatory)]$Device, [string]$adb = $global:adbPath)
    $res = @{ Ok = $false; State = ''; Error = '' }
    try {
        $id = [int]$Headset.ID
        $ip = [string]$Headset.IPAddress
        if ($id -le 0 -or -not $Device) { $res.Error = 'no device'; return $res }
        $okTok = [bool](Invoke-CompanionCmd -Device $Device -Cmd 'settoken' -Extra @('--es', 'token', (Get-CompanionToken)) -adb $adb)
        if (-not $okTok) { $res.Error = (Get-CompanionText -Key 'ReattachTokenFailed' -Fallback 'Could not send the token over ADB'); return $res }
        $serial = ([string]$Headset.SerialNumber).Trim()
        if ($serial -match '^[A-Za-z0-9._-]{4,64}$') {
            [void](Invoke-CompanionCmd -Device $Device -Cmd 'setserial' -Extra @('--es', 'serial', $serial) -adb $adb)
        }
        $pushed = $false
        if ($ip -and -not (Test-UnknownIp $ip)) {
            for ($k = 0; $k -lt 3 -and -not $pushed; $k++) {
                if ($k -gt 0) { Start-Sleep -Milliseconds 800 }
                $pushed = [bool](Set-CompanionReportTarget -IP $ip -Force)
            }
        }
        $o = if ($ip) { Get-CompanionOwnership -IP $ip } else { @{ State = 'unknown'; Version = ''; ReportUrl = '' } }
        try { [void](Set-CompanionOwnerState -HeadsetId $id -Ownership $o) } catch { }
        $res.State = [string]$o.State
        $res.Ok = ($pushed -and $o.State -eq 'ours')
        if (-not $res.Ok) { $res.Error = (Get-CompanionText -Key 'ReattachIncomplete' -Fallback 'Token sent, but the companion did not accept the new report address yet') }
        Write-Log ((Get-CompanionText -Key 'Reattached' -Fallback 'Companion on {0}: re-attached to this server ({1})') -f [string]$Headset.Name, $res.State) -Level WARNING
    } catch { $res.Error = $_.Exception.Message }
    return $res
}
