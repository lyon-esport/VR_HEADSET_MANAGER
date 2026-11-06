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
        [string]$adb = $global:adbPath
    )
    $compPkg = $global:CompanionPackageName
    $aePkg   = $global:ADBAutoEnablePackageName
    $compAvail = [string]$global:CompanionVersion
    $aeAvail = ''
    if ($global:ADBAutoEnableAPK -match '[-_](\d+(?:\.\d+)+)\.apk$') { $aeAvail = $Matches[1] }

    $compVer = Get-HeadsetAppVersion -Device $Device -Pkg $compPkg -adb $adb
    $aeVer   = Get-HeadsetAppVersion -Device $Device -Pkg $aePkg   -adb $adb

    return @(
        @{ key = 'companion'; packageName = $compPkg; name = 'VRHM Companion'; recommended = $true
           installed = [bool]$compVer; installedVersion = $compVer; availableVersion = $compAvail
           upgrade = ([bool]$compVer -and $compAvail -and ($compVer -ne $compAvail)) },
        @{ key = 'autoenable'; packageName = $aePkg; name = 'ADB Auto Enable'; recommended = $false
           installed = [bool]$aeVer; installedVersion = $aeVer; availableVersion = $aeAvail
           upgrade = ([bool]$aeVer -and $aeAvail -and ($aeVer -ne $aeAvail)) }
    )
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
    try { if ($Device.PSObject.Properties['Brand']) { $devBrand = [string]$Device.Brand } } catch { $devBrand = '' }
    if (-not $devBrand -and (Get-Command Get-HeadsetBrandModel -ErrorAction SilentlyContinue)) {
        try {
            $bm = Get-HeadsetBrandModel -Device $Device -adb $adb
            if ($bm -and $bm.Brand) { $devBrand = [string]$bm.Brand }
        } catch { $devBrand = '' }
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

# The telemetry value field names carried on the wire and stored in the kv row.
$script:CompanionTelemetryFields = @('battery', 'charging', 'wattage', 'temp', 'cpuTemp', 'gpuTemp', 'skinTemp', 'ctrlLeft', 'ctrlRight', 'foregroundApp')

# Writes one companion telemetry push into app_kv companion_telemetry_<id>. -Full replaces the
# stored set (first push after a connect); otherwise the named fields MERGE onto what is stored
# (delta push; absent fields keep their previous value). Stamps 'at' (UTC ISO-8601). -Fields is a
# hashtable of the wire field names present in this push. Returns $true when written. Never throws.
# Example: Set-CompanionTelemetry -HeadsetId 3 -Full -Fields @{ battery = 87; charging = $true }
function Set-CompanionTelemetry {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [hashtable]$Fields = @{},
        [switch]$Full
    )
    if ($HeadsetId -le 0) { return $false }
    try {
        $doc = [ordered]@{}
        if (-not $Full) {
            $prev = $null
            try { $prev = Get-DbKeyValue -Key ("companion_telemetry_{0}" -f $HeadsetId) } catch { $prev = $null }
            if ($prev) { foreach ($k in $script:CompanionTelemetryFields) { if ($null -ne $prev.$k) { $doc[$k] = $prev.$k } } }
        }
        foreach ($k in $script:CompanionTelemetryFields) {
            if ($Fields.ContainsKey($k)) { $doc[$k] = $Fields[$k] }
        }
        $doc['at'] = [datetime]::UtcNow.ToString('o')
        Set-DbKeyValue -Key ("companion_telemetry_{0}" -f $HeadsetId) -Value ([PSCustomObject]$doc)
        if ($script:CompanionTelemetryMemo) { $script:CompanionTelemetryMemo.Remove($HeadsetId) }
        return $true
    } catch { return $false }
}

# The last companion telemetry push for one headset, or $null when absent or older than
# -MaxAgeSec (default $global:Companion_telemetry_stale_sec, floor 2). Memoised 1 s per
# process/runspace. The returned object carries the wire fields + 'at'. Never throws.
# Example: $t = Get-CompanionTelemetry -HeadsetId 3; if ($t) { $t.battery }
function Get-CompanionTelemetry {
    param(
        [Parameter(Mandatory)][int]$HeadsetId,
        [int]$MaxAgeSec = 0
    )
    if ($HeadsetId -le 0) { return $null }
    if ($MaxAgeSec -le 0) { $MaxAgeSec = if ($global:Companion_telemetry_stale_sec) { [int]$global:Companion_telemetry_stale_sec } else { 10 } }
    if ($MaxAgeSec -lt 2) { $MaxAgeSec = 2 }
    if (-not $script:CompanionTelemetryMemo) { $script:CompanionTelemetryMemo = @{} }
    $m = $script:CompanionTelemetryMemo[$HeadsetId]
    if ($m -and ([datetime]::UtcNow - $m.At).TotalSeconds -lt 1) { $val = $m.Val }
    else {
        $val = $null
        try { $val = Get-DbKeyValue -Key ("companion_telemetry_{0}" -f $HeadsetId) } catch { $val = $null }
        $script:CompanionTelemetryMemo[$HeadsetId] = @{ At = [datetime]::UtcNow; Val = $val }
    }
    if (-not $val -or -not $val.at) { return $null }
    # A keepalive-only document (no measurement) must not count as fresh.
    $hasValue = $false
    foreach ($k in $script:CompanionTelemetryFields) { if ($null -ne $val.$k) { $hasValue = $true; break } }
    if (-not $hasValue) { return $null }
    try {
        $age = ([datetime]::UtcNow - ([datetime]::Parse($val.at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal))).TotalSeconds
        if ($age -gt $MaxAgeSec) { return $null }
    } catch { return $null }
    return $val
}


# Fills a headset info record ($Info, a New-DefaultHeadsetInfo object) IN PLACE from one companion
# telemetry object ($Telemetry from Get-CompanionTelemetry), matching the string formats the ADB
# stage 2 produces (battery "87 %", temps "36.4", controllers "90 %"). Only fields the push carried
# are overwritten. Used by the VRMonitor poll runspace when the info source is companion. Never
# throws. Example: Set-HeadsetInfoFromCompanion -Info $workingInfo -Telemetry $ct
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
            if ($chg -and $null -ne $Telemetry.wattage) { $Info.ChargingWattage = ("{0}" -f [int]$Telemetry.wattage) }
            elseif (-not $chg) { $Info.ChargingWattage = "-" }
        }
        if ($null -ne $Telemetry.temp)     { $Info.Temp     = ([double]$Telemetry.temp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.cpuTemp)  { $Info.CpuTemp  = ([double]$Telemetry.cpuTemp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.gpuTemp)  { $Info.GpuTemp  = ([double]$Telemetry.gpuTemp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.skinTemp) { $Info.SkinTemp = ([double]$Telemetry.skinTemp).ToString("0.0", $inv) }
        if ($null -ne $Telemetry.ctrlLeft)  { $Info.BatteryControllerLeft  = ("{0} %" -f [int]$Telemetry.ctrlLeft) }
        if ($null -ne $Telemetry.ctrlRight) { $Info.BatteryControllerRight = ("{0} %" -f [int]$Telemetry.ctrlRight) }
    } catch { }
}
