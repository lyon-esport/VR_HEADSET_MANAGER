#####################################
# CONFIGURE QUEST HEADSET USING ADB #
#####################################

# Translations are loaded centrally in scripts_init.ps1 into $global:msg


# Format an ADB device id ("IP:Port") used by `adb -s <id> ...`.
# Replaces "$ip`:$port" / "$ip:$port" interpolations scattered in the codebase.
function Get-DeviceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        [int]$AdbPort = $global:adbPort_default
    )
    if (-not $AdbPort) { $AdbPort = 5555 }
    return ("{0}:{1}" -f $IPAddress, $AdbPort)
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
        [int]$TimeoutSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $Adb)) {
        return @{ ExitCode = -1; StdOut = @(); StdErr = @("adb not found at: $Adb"); Ok = $false }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Adb
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    $stdoutSb = [System.Text.StringBuilder]::new()
    $stderrSb = [System.Text.StringBuilder]::new()
    $outHandler = {
        param($s, $e)
        if ($null -ne $e.Data) { [void]$Event.MessageData.AppendLine($e.Data) }
    }
    Register-ObjectEvent -InputObject $proc -EventName 'OutputDataReceived' -Action $outHandler -MessageData $stdoutSb | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived'  -Action $outHandler -MessageData $stderrSb | Out-Null

    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        if ($TimeoutSeconds -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch {}
                return @{ ExitCode = -2; StdOut = @(); StdErr = @("adb timeout after $TimeoutSeconds s"); Ok = $false }
            }
        } else {
            $proc.WaitForExit()
        }
    } finally {
        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $proc } | Unregister-Event
    }

    $stdout = $stdoutSb.ToString().TrimEnd("`r","`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }
    $stderr = $stderrSb.ToString().TrimEnd("`r","`n").Split("`n") | ForEach-Object { $_.TrimEnd("`r") }
    if ($stdout.Count -eq 1 -and $stdout[0] -eq '') { $stdout = @() }
    if ($stderr.Count -eq 1 -and $stderr[0] -eq '') { $stderr = @() }

    $code = $proc.ExitCode
    return @{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr; Ok = ($code -eq 0) }
}


function Invoke-AdbCmd {
    <#
    .SYNOPSIS
    Validates device reachability then executes an ADB command, returning stdout on success.
    .DESCRIPTION
    - $Device: PSCustomObject from Get-AdbWifiDevice/Get-AdbUsbDevice, OR a plain "IP:Port" string.
    - $Command is a string of ADB arguments after -s <DeviceId>
      e.g. "shell getprop ro.product.model"  or  "install -r `"C:\path with spaces\app.apk`""
    - Throws a descriptive exception for infrastructure failures (unreachable, unauthorized).
    - Returns $false when the command runs but exits with a non-zero exit code.
    - Returns a string array (may be empty @()) on success.
    #>
    param (
        [Parameter(Mandatory=$true)]
        $Device,
        [Parameter(Mandatory=$true)]
        [string]$Command,
        [int]$TimeoutSeconds = 7,
        [string]$adb = $global:adbPath
    )

    if (-not $Device) { throw ($msg.AdbCmdDeviceNull) }

    # Accept plain "IP:Port" string — coerce to a minimal WiFi device object
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

    if ($Device.ConnectionType -eq 'WiFi') {
        $ip   = $Device.IP
        $port = if ($Device.Port) { $Device.Port } else { $global:adbPort_default }

        # Fast path: already connected — skip all network checks
        $isConnected = [bool](& $adb devices 2>$null |
            Where-Object { $_ -match ("^" + [regex]::Escape($deviceId) + "\s+device$") })

        if (-not $isConnected) {
            # Only run network checks when ADB is not yet connected
            $portOpen = (Test-Port -hostname $ip -port $port).open
            if (-not $portOpen) {
                $pingOk = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
                if (-not $pingOk) {
                    throw ($msg.AdbCmdPingFailed -f $ip)
                }
                throw ($msg.AdbCmdPortClosed -f $ip, $port)
            }

            & $adb connect $deviceId 2>$null | Out-Null
            $isConnected = [bool](& $adb devices 2>$null |
                Where-Object { $_ -match ("^" + [regex]::Escape($deviceId) + "\s+device$") })
            if (-not $isConnected) {
                throw ($msg.AdbCmdWifiNotConnected -f $deviceId)
            }
        }

    } elseif ($Device.ConnectionType -eq 'USB') {
        $devicesOutput = @(& $adb devices 2>$null | Where-Object { $_ -notmatch '^List of devices' -and $_ -ne '' })

        if ($devicesOutput | Where-Object { $_ -match 'unauthorized' }) {
            $serial = (($devicesOutput | Where-Object { $_ -match 'unauthorized' } | Select-Object -First 1) -split "`t")[0].Trim()
            throw ($msg.AdbCmdUsbUnauthorized -f $serial)
        }
        if (-not ($devicesOutput | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' })) {
            throw ($msg.AdbCmdUsbNotDetected)
        }
    }

    # Split $Command preserving quoted segments (handles paths with spaces)
    $tokens = [regex]::Matches($Command, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }

    $result = Invoke-Adb -Arguments (@('-s', $deviceId) + $tokens) `
                         -TimeoutSeconds $TimeoutSeconds -Adb $adb

    if (-not $result.Ok) {
        $errDetail = ($result.StdErr + $result.StdOut) -join ' '
        Write-Log ($msg.AdbCmdFailed -f $Device.DeviceId, $Command, $result.ExitCode, $errDetail) -Level WARNING
        return $false
    }
    return $result.StdOut
}


<#
function Install-OculusWirelessAdbApk {
    Write-Log ($msg.FeatureNotImplemented) -Level WARNING
    #Fonction a ecrire - Copie en vrac des actions a realiser en ADB USB
    # Test concurrent USB connection if other headsets are already connected via WiFi
    # Install the app and launch it on the headset
    # If the headset is already connected,

    # Usefull adb commands : https://gist.github.com/Pulimet/5013acf2cd5b28e55036c82c91bd56d8
    
    .\adb -d
    adb -e install path/to/app.apk
        -d                        - directs command to the only connected USB device...
        -e                        - directs command to the only running emulator...
        -s <serial number>        ...
        -p <product name or path> ...

    

    .\adb.exe devices -l
    .\adb connect 192.168.1.253:5555
    if (((.\adb.exe devices | Select-String $adb_device -AllMatches).Matches.Count) -lt 1) {
       Write-Log ($msg.NoHeadsetToAdd) -Level WARNING
    }
    elseif (((.\adb.exe devices | Select-String $adb_device -AllMatches).Matches.Count) -gt 1)

    cd "C:\Users\Crazy\Documents\Scripts\Quest screen mirroring Streaming\scrcpy-win64-v3.2"
    .\adb.exe usb
    .\adb.exe install -r "C:\Users\Crazy\Documents\Scripts\Quest screen mirroring Streaming\ADB Wireless activator\tdg.oculuswirelessadb-1.2.apk" #-r = reinstall pour re-ecraser l'application
    .\adb.exe shell pm grant tdg.oculuswirelessadb android.permission.WRITE_SECURE_SETTINGS
    .\adb.exe shell pm grant tdg.oculuswirelessadb android.permission.READ_LOGS
    .\adb.exe shell am start -n tdg.oculuswirelessadb/.MainActivity

    .\adb.exe tcpip 5555
    
    Connect using Wifi
    .\adb.exe shell ip route
    .\adb.exe  connect 192.168.1.253:5555
    .\adb.exe disconnect 192.168.1.253:5555
    .\adb.exe kill-server

    #KEY COMMANDS
     .\adb.exe shell input keyevent 3 #Simulate Home button press
     .\adb.exe shell input keyevent 4 #Simulate Back button press
     .\adb.exe shell input keyevent 26 #Simulate Power button press
     .\adb.exe shell input keyevent 82 #Simulate Menu button press
    .\adb.exe shell input keyevent 223 #Simulate Volume Up button press
    .\adb.exe shell input keyevent 224 #Simulate Volume Down button press
    

#>

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
    if (-not (Test-Path $adb)) {
        Write-Log ($msg.ADBNotFound -f $global:adbFolder) -Level ERROR
        return $false
    }
    if (-not (Test-Path $apkPath)) {
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
        Invoke-AdbCmd -Device $Device -Command "tcpip 5555" -adb $adb | Out-Null
        Start-Sleep -Seconds 2

        return $true
    } catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
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
    Port to use for ADB (default: 5555)

    .EXAMPLE
    Enable-WiFiADB -AdbPort 5555
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$wifi_ssid,
        [string]$wifi_pwd,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb = $global:adbPath
        
    )

    # 1. Initial verification
    if (-not (Test-Path $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $false
    }

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
        # Retrieve the model:
        $headsetModel = ((Invoke-AdbCmd -Device $usbDevice -Command "shell getprop ro.product.model" -adb $adb) -join '').Trim()
        Write-Log ($msg.HeadsetDetected -f $headsetModel, $deviceId) -Level INFO

        # Step 3: Check SSID (filter in PowerShell to avoid shell pipe issues on some Android builds)
        $wifiInfo = (Invoke-AdbCmd -Device $usbDevice -Command "shell dumpsys wifi" -adb $adb) | Select-String 'mWifiInfo'

        if ($wifiInfo -match 'SSID: "([^"]+)"') {
            $currentSSID = $matches[1]  # Returns the SSID without quotes
            Write-Log ($msg.CurrentlyConnectedSsid -f $currentSSID) -Level INFO
        }

        # Step 4: Verify the connected SSID
        if ($currentSSID -notmatch [regex]::Escape($wifi_ssid)) {
            Write-Log ($msg.HeadsetNotConnectedToSsid -f $wifi_ssid) -Level WARNING

            $switchChoice = (Read-Host ($msg.SwitchToSsidPrompt -f $wifi_ssid)).ToUpper()
            if ($switchChoice -eq 'Y') {
                try {
                    Invoke-AdbCmd -Device $usbDevice -Command "shell svc wifi enable" -adb $adb | Out-Null
                    Invoke-AdbCmd -Device $usbDevice -Command "shell cmd -w wifi connect-network $wifi_ssid wpa2 $wifi_pwd -r none" -adb $adb | Out-Null

                    Write-Log ($msg.ActivatingWifiNetwork -f $wifi_ssid, $headsetModel, $deviceId) -Level INFO
                    Start-Sleep -Seconds 5
                } catch {
                    Write-Log ($msg.WifiConfigFailed -f $_) -Level ERROR
                    return $false
                }
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

        Write-Log ($msg.WifiIpDetected -f $ipInfo) -Level INFO

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
            
            $knownHeadsets = Get-KnownHeadsets
            if ($knownHeadsets.IPAddress -contains $ipInfo){
                Write-Log ($msg.IpAlreadyKnown) -Level INFO
            }
            else {
                $choice = (Read-Host $msg.AddToKnownPrompt).ToUpper()

                switch ($choice) {
                    'Y' {   Write-Log ($msg.AddingHeadsetToList) -Level INFO
                            $headsetName = Read-Host ($msg.HeadsetNamePrompt)
                            Add-Headset -Name $headsetName -IPAddress $ipInfo
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

    if (-not (Test-Path $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $null
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $usbLine = & $adb devices |
                Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ":" }
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
    try {
        $device = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like "USB\*\$Serial" } |
            Select-Object -First 1
        if (-not $device) { return $null }

        $currentId = $device.InstanceId
        for ($i = 0; $i -lt 8; $i++) {
            $prop = Get-PnpDeviceProperty -InstanceId $currentId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
            if (-not $prop -or -not $prop.Data) { break }
            $parentId = $prop.Data

            # InstanceId of the controller often contains the controller type
            if ($parentId -match 'xHCI|XHCI') { return 'USB 3.0' }
            if ($parentId -match 'EHCI|ehci')  { return 'USB 2.0' }

            # Fall back to device friendly name / description
            $parentDev = Get-PnpDevice -InstanceId $parentId -ErrorAction SilentlyContinue
            if ($parentDev) {
                $name = "$($parentDev.FriendlyName) $($parentDev.Description)"
                if ($name -match 'xHCI|SuperSpeed|USB 3') { return 'USB 3.0' }
                if ($name -match 'EHCI|USB 2')             { return 'USB 2.0' }
            }
            $currentId = $parentId
        }
        return $null
    } catch {
        return $null
    }
}


function Get-BestAdbDevice {
    <#
    .SYNOPSIS
    Returns the fastest available ADB device for a known headset: USB if connected, WiFi otherwise.
    #>
    param (
        [Parameter(Mandatory=$true)] $Headset,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = 5555
    )

    if ($Headset.SerialNumber) {
        try {
            $usbLine = & $adb devices 2>$null | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' }
            if ($usbLine) {
                $serial = ($usbLine -split "`t")[0].Trim()
                if ($serial -eq $Headset.SerialNumber) {
                    Write-Log "USB connection preferred for $($Headset.Name) (serial $serial)" -Level DEBUG
                    return [PSCustomObject]@{ DeviceId = $serial; ConnectionType = 'USB'; IP = $null; Port = $null }
                }
            }
        } catch {
            Write-Log ($msg.ADBExecutionFailed -f $_.Exception.Message) -Level ERROR
        }
    }

    return Get-AdbWifiDevice -headsetIP $Headset.IPAddress -AdbPort $AdbPort -adb $adb
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

    if (-not $adb -or -not (Test-Path $adb)) {
        return [PSCustomObject]@{ ok = $false; error = "ADB not found" }
    }

    try {
        $usbLine = & $adb devices 2>$null | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' }
        if (-not $usbLine) {
            return [PSCustomObject]@{ ok = $false; error = "No USB headset detected" }
        }
        $deviceId  = ($usbLine -split "`t")[0].Trim()
        $usbDevice = [PSCustomObject]@{ DeviceId = $deviceId; ConnectionType = 'USB'; IP = $null; Port = $null }

        $model = ((Invoke-AdbCmd -Device $usbDevice -Command "shell getprop ro.product.model" -adb $adb) -join '').Trim()

        # Enable TCP/IP mode
        Invoke-AdbCmd -Device $usbDevice -Command "tcpip $AdbPort" -adb $adb | Out-Null
        Start-Sleep -Seconds 2

        # Retrieve WiFi IP
        $ip = ''
        $ipOutput = Invoke-AdbCmd -Device $usbDevice -Command "shell ip -f inet addr show wlan0" -adb $adb
        foreach ($line in $ipOutput) {
            if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') {
                $ip = $Matches[1]; break
            }
        }

        Write-Log ($msg.ActivatingWifiAdbPort -f $AdbPort) -Level INFO
        return [PSCustomObject]@{ ok = $true; model = $model; ip = $ip; port = $AdbPort }
    } catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}


function Invoke-UsbHeadsetActions {
    <#
    .SYNOPSIS
    Runs automated background actions on a USB-connected headset. No user prompts.
    Called on every VRMonitor loop iteration.

    .DESCRIPTION
    - Silently checks for a USB ADB device via Get-AdbUsbDeviceInfo (single attempt, no prompts).
    - Returns $null immediately if no USB device is present.
    - If a USB headset is found and already connected to WiFi, enables TCP/IP
      wireless ADB automatically.
    - Matches the headset in known_headsets.csv by ro.serialno and updates its IP if it changed.
    - Returns a result object for use by future actions added to this function.
    #>
    param (
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath
    )

    if (-not $adb -or -not (Test-Path $adb)) { return $null }

    try {
        $deviceInfo = Get-AdbUsbDeviceDetails -AdbPort $AdbPort -adb $adb
        if (-not $deviceInfo) { return $null }

        $deviceId = $deviceInfo.DeviceId
        $model    = $deviceInfo.Model
        $ip       = $deviceInfo.IP
        $serial   = $deviceInfo.SerialNumber

        Write-Log ($msg.UsbHeadsetConnected -f $model, $deviceId) -Level INFO

        $wifiAdbEnabled = $false

        # Resolve known headset entry first - we only enable WiFi ADB for known headsets
        # to avoid repeated USB disconnect/reconnect cycles on unregistered devices.
        $knownMatch = $null
        if ($serial) {
            $knownHeadsets = Get-KnownHeadsets
            $knownMatch = $knownHeadsets | Where-Object { $_.SerialNumber -eq $serial } | Select-Object -First 1
        }

        if ($ip) {
            if ($knownMatch) {
                if (-not $deviceInfo.WifiAdbOpen) {
                    # Enable TCP/IP mode - this disconnects USB momentarily (by design)
                    Invoke-AdbCmd -Device $deviceInfo -Command "tcpip $AdbPort" -adb $adb | Out-Null
                    Start-Sleep -Seconds 1
                    Write-Log ($msg.UsbWifiAdbEnabled -f $model, $ip, $AdbPort) -Level SUCCESS
                } else {
                    Write-Log ($msg.AdbWifiAlreadyConnected -f "${ip}:${AdbPort}") -Level DEBUG
                }
                $wifiAdbEnabled = $true

                # Update IP in CSV if it changed
                if ($knownMatch.IPAddress -ne $ip) {
                    Write-Log ($msg.UsbHeadsetIpUpdated -f $model, $knownMatch.IPAddress, $ip) -Level SUCCESS
                    Update-HeadsetField -ID ([int]$knownMatch.ID) -Field 'IPAddress' -NewValue $ip
                }
            } else {
                Write-Log ($msg.UsbHeadsetNoWifiIp -f $model) -Level DEBUG
            }
        } else {
            Write-Log ($msg.UsbHeadsetNoWifiIp -f $model) -Level DEBUG
        }

        return [PSCustomObject]@{
            deviceId       = $deviceId
            model          = $model
            ip             = $ip
            serialNumber   = $serial
            wifiAdbEnabled = $wifiAdbEnabled
        }
    } catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $null
    }
}


function Get-AdbUsbDeviceDetails {
    <#
    .SYNOPSIS
    Returns full details about a USB-connected ADB device for the web UI.

    .DESCRIPTION
    Single-attempt, no interactive prompts. Returns DeviceId, IP, Model,
    SerialNumber, WiFiSSID, WifiAdbOpen (bool), ApkInstalled (bool), or $null.
    Designed for the /api/usbdeviceinfo web server route.
    #>
    param (
        [string]$PackageName = $global:ADBWirelessActivatorPackageName,
        [int]$AdbPort        = $global:adbPort_default,
        [string]$adb         = $global:adbPath
    )

    if (-not $adb -or -not (Test-Path $adb)) { return $null }

    try {
        $usbLine = & $adb devices 2>$null | Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ':' }
        if (-not $usbLine) { return $null }

        $deviceId  = ($usbLine -split "`t")[0].Trim()
        $usbDevice = [PSCustomObject]@{ DeviceId = $deviceId; ConnectionType = 'USB'; IP = $null; Port = $null }

        # WiFi IP from wlan0
        $ip = ''
        $ipOutput = Invoke-AdbCmd -Device $usbDevice -Command "shell ip -f inet addr show wlan0" -adb $adb
        foreach ($line in $ipOutput) {
            if ($line -match 'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/') {
                $ip = $Matches[1]; break
            }
        }

        $model        = ((Invoke-AdbCmd -Device $usbDevice -Command "shell getprop ro.product.model" -adb $adb) -join '').Trim()
        $serialNumber = ((Invoke-AdbCmd -Device $usbDevice -Command "shell getprop ro.serialno" -adb $adb) -join '').Trim()

        # Current WiFi SSID
        $ssid = ''
        $wifiInfo = (Invoke-AdbCmd -Device $usbDevice -Command "shell dumpsys wifi" -adb $adb) | Select-String 'mWifiInfo'
        if ($wifiInfo -match 'SSID: "([^"]+)"') { $ssid = $Matches[1] }

        # WiFi ADB already open on IP:Port?
        $wifiAdbOpen = $false
        if ($ip) {
            $wifiDeviceId = "${ip}:${AdbPort}"
            $adbDevices   = & $adb devices 2>$null
            $wifiAdbOpen  = [bool]($adbDevices | Where-Object { $_ -match ("^" + [regex]::Escape($wifiDeviceId) + "\s+device$") })
        }

        # APK installed?
        $apkInstalled = $false
        if ($PackageName) {
            $pmResult     = Invoke-AdbCmd -Device $usbDevice -Command "shell pm list packages $PackageName" -adb $adb
            $apkInstalled = $pmResult -ne $false -and [bool]($pmResult | Where-Object { $_ -match "package:$([regex]::Escape($PackageName))" })
        }

        return [PSCustomObject]@{
            DeviceId       = $deviceId
            ConnectionType = 'USB'
            IP             = $ip
            Model          = $model
            SerialNumber   = $serialNumber
            WiFiSSID       = $ssid
            WifiAdbOpen    = $wifiAdbOpen
            ApkInstalled   = $apkInstalled
            Port           = $null
        }
    } catch {
        Write-Log ($msg.ADBExecutionFailed -f $_.Exception.Message) -Level ERROR
        return $null
    }
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
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb  = $global:adbPath
    )

    $DeviceId = "${headsetIP}:${AdbPort}"

    if (-not (Test-Path $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $null
    }

    # Already connected? Return immediately without re-connecting.
    $alreadyConnected = & $adb devices 2>&1 |
        Where-Object { $_ -match ("^" + [regex]::Escape($DeviceId) + "\s+device$") }
    if ($alreadyConnected) {
        Write-Log ($msg.AdbWifiAlreadyConnected -f $DeviceId) -Level DEBUG
        return [PSCustomObject]@{ DeviceId = $DeviceId; ConnectionType = 'WiFi'; IP = $headsetIP; Port = $AdbPort }
    }

    Write-Log ($msg.AdbWifiConnecting -f $DeviceId) -Level INFO

    $pingOk = Test-Connection -ComputerName $headsetIP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        Write-Log ($msg.AdbWifiPingFailed -f $headsetIP) -Level WARNING
        return $null
    }

    $portOpen = (Test-Port -hostname $headsetIP -port $AdbPort).open
    if (-not $portOpen) {
        Write-Log ($msg.AdbWifiPortClosed -f $AdbPort, $headsetIP) -Level WARNING
        Write-Log ($msg.AdbWifiDevModeHint) -Level WARNING
        return $null
    }

    try {
        $connectOutput = & $adb connect $DeviceId 2>&1
        $nowConnected = & $adb devices 2>&1 |
            Where-Object { $_ -match ("^" + [regex]::Escape($DeviceId) + "\s+device$") }
        if ($nowConnected) {
            Write-Log ($msg.AdbWifiConnected -f $DeviceId) -Level SUCCESS
            return [PSCustomObject]@{ DeviceId = $DeviceId; ConnectionType = 'WiFi'; IP = $headsetIP; Port = $AdbPort }
        } else {
            Write-Log ($msg.AdbWifiConnectFailed -f $DeviceId, ($connectOutput -join " ")) -Level ERROR
            return $null
        }
    } catch {
        Write-Log ($msg.AdbWifiConnectFailed -f $DeviceId, $_) -Level ERROR
        return $null
    }
}


function Get-HeadsetModel {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }
    $headsetModel = ((Invoke-AdbCmd -Device $Device -Command "shell getprop ro.product.model" -adb $adb) -join '').Trim()
    return $headsetModel
}


function Get-QuestControllerBatteryStatus {
    <#
    .SYNOPSIS
    Retrieves Quest controller battery, connection status and tracking state
    using OVRRemoteService dumpsys.
    #>

    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return @{ Left = @{ Battery=$null; Status=$null; ExternalStatus=$null; TrackingStatus=$null }; Right = @{ Battery=$null; Status=$null; ExternalStatus=$null; TrackingStatus=$null } } }
    $DeviceId = $Device.DeviceId

    $result = @{
        Left  = @{
            Battery        = $null
            Status         = $null
            ExternalStatus = $null
            TrackingStatus = $null
        }
        Right = @{
            Battery        = $null
            Status         = $null
            ExternalStatus = $null
            TrackingStatus = $null
        }
    }

    try {
        Write-Log ($msg.QueryControllerStatus -f $DeviceId) -Level DEBUG

        $dump = Invoke-AdbCmd -Device $Device -Command "shell dumpsys OVRRemoteService" -adb $adb
        if (-not $dump) {
            Write-Log ($msg.ControllerStatusFailed -f "No output") -Level WARNING
            return $result
        }

        $lines = $dump | Where-Object { $_ -match "Paired device:" }

        foreach ($line in $lines) {

            if ($line -match "Type:\s+(Left|Right)") {
                $side = $Matches[1]

                if ($line -match "Battery:\s*(\d+)%") {
                    $result[$side].Battery = [int]$Matches[1]
                }

                if ($line -match "Status:\s*([A-Za-z]+)") {
                    $result[$side].Status = $Matches[1]
                }

                if ($line -match "ExternalStatus:\s*(\S+)") {
                    $result[$side].ExternalStatus = $Matches[1].TrimEnd(',')
                    # Null out battery if controller is not connected (e.g. Searching, Disconnected)
                    if ($result[$side].ExternalStatus -notmatch "^CONNECTED") {
                        $result[$side].Battery = $null
                    }
                }

                if ($line -match "TrackingStatus:\s*([A-Za-z]+)") {
                    $result[$side].TrackingStatus = $Matches[1]
                }

                $batteryDisplay = if ($null -ne $result[$side].Battery) { $result[$side].Battery } else { "N/A" }
                Write-Log ($msg.ControllerBatteryStatus -f $DeviceId, $side, $batteryDisplay, $result[$side].ExternalStatus, $result[$side].TrackingStatus) -Level DEBUG
            }
        }

        return $result
    }
    catch {
        Write-Log ($msg.ControllerStatusFailed -f $_.Exception.Message) -Level ERROR
        return $result
    }
}


function Get-HeadsetBatteryStatus {
    <#
    .SYNOPSIS
    Retrieves battery level, charging state and temperature from a VR headset via ADB.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }
    $DeviceId = $Device.DeviceId

    $result = [PSCustomObject]@{
        Level                  = $null
        Charging               = $false
        TempC                  = $null
        RawStatus              = $null
        MaxChargingCurrentA    = $null
        MaxChargingVoltageV    = $null
        MaxChargingWattageW    = $null
        BatteryControllerLeft  = $null
        BatteryControllerRight = $null
    }

    try {
        Write-Log ($msg.BatteryStatusQuery -f $DeviceId) -Level DEBUG

        $batteryInfo = Invoke-AdbCmd -Device $Device -Command "shell dumpsys battery" -adb $adb

        if (-not $batteryInfo) {
            Write-Log ($msg.NoBatteryData -f $DeviceId) -Level WARNING
            return $null
        }

        $result.RawStatus = $batteryInfo -join "`n"

        # Battery level
        $levelMatch = $batteryInfo | Select-String "level:\s+(\d+)"
        if ($levelMatch) {
            $result.Level = [int]$levelMatch.Matches[0].Groups[1].Value
        }

        # Charging state
        $chargingMatch = $batteryInfo | Select-String "AC powered:\s+(true|false)"
        if ($chargingMatch) {
            $result.Charging = $chargingMatch.Matches[0].Groups[1].Value -eq "true"
        }

        # Temperature (tenths of degree)
        $tempMatch = $batteryInfo | Select-String "temperature:\s+(\d+)"
        if ($tempMatch) {
            $result.TempC = [math]::Round(
                $tempMatch.Matches[0].Groups[1].Value / 10,
                1
            )
        }

        # Max charging current (microamps -> A) and voltage (microvolts -> V)
        $currentMatch = $batteryInfo | Select-String "Max charging current:\s+(\d+)"
        $voltageMatch = $batteryInfo | Select-String "Max charging voltage:\s+(\d+)"
        if ($currentMatch) {
            $result.MaxChargingCurrentA = [math]::Round($currentMatch.Matches[0].Groups[1].Value / 1000000, 3)
        }
        if ($voltageMatch) {
            $result.MaxChargingVoltageV = [math]::Round($voltageMatch.Matches[0].Groups[1].Value / 1000000, 3)
        }
        if ($result.MaxChargingCurrentA -and $result.MaxChargingVoltageV) {
            $result.MaxChargingWattageW = [math]::Round($result.MaxChargingCurrentA * $result.MaxChargingVoltageV, 2)
        }

        # Controller battery levels (left & right)
        $controllers = Get-QuestControllerBatteryStatus -Device $Device -adb $adb
        if ($controllers) {
            $result.BatteryControllerLeft  = $controllers.Left.Battery
            $result.BatteryControllerRight = $controllers.Right.Battery
        }

        Write-Log ($msg.BatteryStatus -f $DeviceId, $result.Level, $result.Charging, $result.TempC, $result.MaxChargingWattageW) -Level DEBUG
        return $result
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $null
    }
}




function Get-BatteryTimeEstimate {
    <#
    .SYNOPSIS
    Estimates battery power state and remaining time from a serialized history string.

    .DESCRIPTION
    Requires exactly 3 entries with 3 distinct battery % levels within a 10% spread.
    Power state is derived from the sign of % change across both intervals.
    If the direction changes between intervals (non-linear), PowerState reflects the
    last observed interval and MinutesRemaining is $null.
    When monotonic, MinutesRemaining is the average of two interval-based projections.

    .PARAMETER HistoryString
    Pipe-separated entries, each "ISO8601timestamp=level".
    Example: "2026-04-23T10:00:00=60|2026-04-23T10:15:00=61|2026-04-23T10:30:00=63"
    #>
    param (
        [string]$HistoryString
    )

    $result = [PSCustomObject]@{
        PowerState       = $null
        MinutesRemaining = $null
    }

    if ([string]::IsNullOrWhiteSpace($HistoryString)) { return $result }

    # Parse entries
    $entries = @()
    foreach ($part in ($HistoryString -split '\|')) {
        $part = $part.Trim()
        if ($part -notmatch '^(.+)=(\d+)$') { continue }
        try {
            $entries += [PSCustomObject]@{
                Time  = [datetime]$Matches[1]
                Level = [int]$Matches[2]
            }
        } catch { continue }
    }

    # Sort by time and keep last 3
    $entries = @($entries | Sort-Object Time | Select-Object -Last 3)

    # Need exactly 3 entries
    if ($entries.Count -lt 3) { return $result }

    $T0 = $entries[0]; $T1 = $entries[1]; $T2 = $entries[2]

    # All three levels must be distinct
    if ($T0.Level -eq $T1.Level -or $T1.Level -eq $T2.Level -or $T0.Level -eq $T2.Level) {
        return $result
    }

    # Max spread must be <= 10%
    $levels = @($T0.Level, $T1.Level, $T2.Level)
    if (($levels | Measure-Object -Maximum).Maximum - ($levels | Measure-Object -Minimum).Minimum -gt 10) {
        return $result
    }

    $d1 = $T1.Level - $T0.Level
    $d2 = $T2.Level - $T1.Level

    # Determine direction from last interval (used in all cases)
    $result.PowerState = if ($d2 -gt 0) { 'charging' } else { 'discharging' }

    # Non-linear: direction changed - cannot estimate time
    if (($d1 -gt 0 -and $d2 -lt 0) -or ($d1 -lt 0 -and $d2 -gt 0)) {
        return $result
    }

    # Monotonic - compute rates and average projected time
    $targetLevel = if ($result.PowerState -eq 'charging') { 100 } else { 5 }

    try {
        $min01 = ([datetime]$T1.Time - [datetime]$T0.Time).TotalMinutes
        $min12 = ([datetime]$T2.Time - [datetime]$T1.Time).TotalMinutes
    } catch { return $result }

    if ($min01 -le 0 -or $min12 -le 0) { return $result }

    $rate01 = $d1 / $min01   # %/min
    $rate12 = $d2 / $min12   # %/min

    if ($rate01 -eq 0 -or $rate12 -eq 0) { return $result }

    $remaining = $targetLevel - $T2.Level
    $time01 = $remaining / $rate01
    $time12 = $remaining / $rate12

    if ($time01 -le 0 -or $time12 -le 0) { return $result }

    $avg = ($time01 + $time12) / 2
    $result.MinutesRemaining = [math]::Min([int][math]::Round($avg), 600)

    Write-Log ($msg.BatteryTimeEstimate -f $T2.Level, $result.MinutesRemaining, $result.PowerState) -Level DEBUG
    return $result
}


function Get-HeadsetForegroundApp {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { return $null }

    try {
        $dumpLines = @(Invoke-AdbCmd -Device $Device -Command "shell dumpsys activity activities" -adb $adb)

        # Quest 3 / Android 12+: the ActivityRecord wraps across two lines:
        #   line N  : "  topResumedActivity=ActivityRecord{hash u0 "
        #   line N+1: "com.package.name/com.ClassName tXXXX}"
        # We want the FIRST match (= the user app, not system overlays).
        for ($i = 0; $i -lt $dumpLines.Count - 1; $i++) {
            if ($dumpLines[$i] -match 'topResumedActivity=ActivityRecord\{') {
                # Most common: package on next line
                $nextLine = $dumpLines[$i + 1].Trim()
                if ($nextLine -match '^([\w\.]+)/') {
                    return $Matches[1]
                }
                # Same-line format (some Android 10/11 builds)
                if ($dumpLines[$i] -match 'topResumedActivity.*?\s+([\w\.]+)/') {
                    return $Matches[1]
                }
            }
        }

        # Fallback: mResumedActivity (Quest 2 / older firmware)
        $line = $dumpLines | Select-String "mResumedActivity" | Select-Object -First 1
        if ($line -match 'mResumedActivity.*?\s+([\w\.]+)/') {
            return $Matches[1]
        }

    } catch {
        Write-Log ($msg.AdbInfoFailed -f $headsetIP, $_) -Level ERROR
    }
    return $null
}


# Resolves a Quest package name to its display name, icon URL, and local icon path.
# Checks data/app_names.csv first; on cache miss fetches from:
#   https://github.com/threethan/MetaMetadata (updates daily, covers all Meta Store + SideQuest apps)
# Icons are downloaded to website/assets/app_icons/ and served directly by the web server.
# Unknown packages are cached with DisplayName = PackageName and empty IconUrl so the
# network is never hit more than once per package.
function Get-AppDisplayName {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackageName
    )

    $appInfo = Get-AppInfo -PackageName $PackageName -searchOnline $true

    return $appInfo
}


function Disconnect-ADBConnections {
    param (
        [Parameter()]
        [string]$adb = $global:adbPath
    )
    try {
        if (-not (Test-Path $adb)) {
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


function Invoke-HeadsetReboot {
    <#
    .SYNOPSIS
    Reboots a VR headset via ADB.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.HeadsetRebooting -f $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "reboot" -adb $adb | Out-Null
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Invoke-HeadsetRecenter {
    <#
    .SYNOPSIS
    Triggers a view recenter on a Meta Quest headset via ADB over WiFi.

    .DESCRIPTION
    *** NOT WORKING - UNDER INVESTIGATION ***

    Attempted approach: send a proximity-close broadcast (com.oculus.vrpowermanager.prox_close)
    to simulate putting the headset on, which should trigger RecenterLocalSpace_Internal
    in com.oculus.vrruntimeservice.

    Logcat confirms RecenterLocalSpace_Internal is called when the user manually recenters
    via the controller long-press or the hand tracking UI, but the broadcast alone does
    not reliably trigger it remotely via ADB.

    Other approaches tested with no success:
      - am broadcast -a com.oculus.vrpowermanager.RECENTER
      - am broadcast -a com.oculus.vrshell.RECENTER
      - am broadcast -a com.oculus.guardian.RESET_ORIENTATION
      - input keyevent --longpress 312 (KEYCODE_STEM_PRIMARY)
      - input keyevent --longpress 3 (HOME)
      - service call space 1/2/3
      - service call runtimeipchelper 1..10
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.HeadsetRecentering -f $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "shell am broadcast -a com.oculus.vrpowermanager.prox_close" -adb $adb | Out-Null
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Invoke-HeadsetShutdown {
    <#
    .SYNOPSIS
    Powers off a VR headset via ADB.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        Write-Log ($msg.HeadsetShuttingDown -f $DeviceId) -Level INFO
        Invoke-AdbCmd -Device $Device -Command "reboot -p" -adb $adb | Out-Null
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Invoke-HeadsetApp {
    <#
    .SYNOPSIS
    Launches an application on a VR headset via ADB over WiFi.

    .DESCRIPTION
    Accepts either a PackageName or a DisplayName.
    - If a DisplayName is supplied, it is resolved to a PackageName via the
      app_names.csv cache (and updated if the app is not yet listed).
    - Verifies the app is installed on the headset before launching.
    - Returns $true on success, $false on any failure.

    .PARAMETER headsetIP
    IP address of the headset.

    .PARAMETER PackageName
    Android package name (e.g. "com.myapp.vr"). Takes priority over DisplayName.

    .PARAMETER DisplayName
    Human-readable app name as listed in app_names.csv (e.g. "SKYBOX VR Video Player").

    .PARAMETER AdbPort
    ADB TCP port (default: global adbPort_default).

    .EXAMPLE
    Invoke-HeadsetApp -headsetIP "192.168.1.100" -PackageName "com.myapp.vr"
    Invoke-HeadsetApp -headsetIP "192.168.1.100" -DisplayName "SKYBOX VR Video Player"
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$PackageName  = '',
        [string]$DisplayName  = '',
        [string]$adb          = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    # 1. Resolve PackageName from DisplayName if not provided directly
    if (-not $PackageName) {
        if (-not $DisplayName) {
            Write-Log ($msg.ErrorOccurred -f "Either PackageName or DisplayName must be provided.") -Level ERROR
            return $false
        }

        # Search cache
        $cacheFile = Join-Path $global:ScriptPath "data\app_names.csv"
        $match = $null
        if (Test-Path $cacheFile) {
            $match = @(Import-Csv -Path $cacheFile -Delimiter ",") |
                     Where-Object { $_.DisplayName -eq $DisplayName } |
                     Select-Object -First 1
        }

        if ($match) {
            $PackageName = $match.PackageName
            Write-Log ($msg.AppDisplayNameResolved -f $PackageName, $DisplayName) -Level DEBUG
        } else {
            Write-Log ($msg.AppDisplayNameNotFound -f $DisplayName) -Level ERROR
            return $false
        }
    } else {
        # Ensure the package is listed in app_names.csv (triggers cache update if needed)
        Get-AppDisplayName -PackageName $PackageName | Out-Null
    }

    # 2. Device already connected - no Connect-AdbWifi needed

    # 3. Verify the app is installed on the headset
    $installed = Invoke-AdbCmd -Device $Device -Command "shell pm list packages $PackageName" -adb $adb
    if ($installed -eq $false -or -not ($installed -match [regex]::Escape("package:$PackageName"))) {
        Write-Log ($msg.ErrorOccurred -f "App '$PackageName' is not installed on $DeviceId.") -Level ERROR
        return $false
    }

    # 4. Launch the app
    try {
        Write-Log ($msg.HeadsetDetected -f $PackageName, $DeviceId) -Level INFO
        # Meta Home (vrshell) is a system launcher - monkey cannot inject into it; use HOME intent
        if ($PackageName -eq 'com.oculus.vrshell') {
            $launchOutput = Invoke-AdbCmd -Device $Device -Command "shell am start -a android.intent.action.MAIN -c android.intent.category.HOME" -adb $adb
            if ($launchOutput -eq $false -or ($launchOutput -match "error|Error|Exception")) {
                Write-Log ($msg.ErrorOccurred -f "Failed to launch Meta Home: $launchOutput") -Level ERROR
                return $false
            }
            return $true
        }
        $launchOutput = Invoke-AdbCmd -Device $Device -Command "shell monkey -p $PackageName -c android.intent.category.LAUNCHER 1" -adb $adb
        if ($launchOutput -eq $false -or ($launchOutput -match "error|Error|Exception")) {
            Write-Log ($msg.ErrorOccurred -f "Failed to launch '$PackageName': $launchOutput") -Level ERROR
            return $false
        }
        return $true
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Get-HeadsetInstalledApps {
    <#
    .SYNOPSIS
    Returns an array of all installed applications on a VR headset via ADB over WiFi.

    .DESCRIPTION
    Queries the headset with "pm list packages" and returns an array of PSCustomObjects
    with PackageName, DisplayName and IconUrl.
    - Known packages are resolved instantly from the local app_names.csv cache.
    - When -ResolveMissing is specified, packages absent from the cache are looked up
      online via the MetaMetadata repository and app_names.csv is updated accordingly.
      Requires an active internet connection; unknown apps that are not found online
      are stored with DisplayName = PackageName and IconUrl = "" so the network is
      never hit more than once per package.

    .PARAMETER headsetIP
    IP address of the headset.

    .PARAMETER ThirdPartyOnly
    When specified, only returns user-installed (non-system) packages (-3 flag).

    .PARAMETER ResolveMissing
    When specified, fetches metadata for packages not yet in app_names.csv and
    updates the cache file. Requires internet access.

    .PARAMETER AdbPort
    ADB TCP port (default: global adbPort_default).

    .EXAMPLE

    Get-HeadsetInstalledApps -device $Device -ThirdPartyOnly
    Get-HeadsetInstalledApps -device $Device -ThirdPartyOnly -ResolveMissing
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$AppCacheFilePath = $global:AppCacheFilePath,
        [switch]$ThirdPartyOnly = $true,
        [switch]$ResolveMissing = $false,
        [string]$adb    = $global:adbPath
    )
    if (-not $Device) { return @() }
    $DeviceId = $Device.DeviceId

    try {
        $pmArgs = if ($ThirdPartyOnly) { 'list packages -3' } else { 'list packages' }
        $rawLines = Invoke-AdbCmd -Device $Device -Command "shell pm $pmArgs" -adb $adb

        if (-not $rawLines) {
            Write-Log ($msg.ErrorOccurred -f "No packages returned from $DeviceId") -Level WARNING
            return @()
        }
        # Collect all package names first
        $packages = foreach ($line in $rawLines) {
            if ($line -match '^package:(.+)$') { $Matches[1].Trim() }
        }

        # Load app_names.csv cache into a hashtable for fast lookup
        $cache = @{}
        if (Test-Path $AppCacheFilePath) {
            foreach ($row in @(Import-Csv -Path $AppCacheFilePath -Delimiter ",")) {
                $cache[$row.PackageName] = $row
            }
        }

        # Resolve missing packages online if requested
        
        if ($ResolveMissing) {
            $missing = @($packages | Where-Object { -not $cache.ContainsKey($_) })
            if ($missing.Count -gt 0) {
                Write-Log ($msg.AppDisplayNameNotFound -f "$($missing.Count) unknown packages - fetching online...") -Level INFO
                foreach ($pkg in $missing) {
                    # Get-AppDisplayName fetches metadata and updates app_names.csv automatically
                    $entry = Get-AppInfo -PackageName $pkg -searchOnline $true
                    $cache[$pkg] = $entry
                }
            }
            Update-AppCacheFromMetaMetadata -CacheFilePath $AppCacheFilePath
        }
        
        # When returning all packages, determine which are third-party with a second ADB call
        $thirdPartySet = @{}
        if (-not $ThirdPartyOnly) {
            $tp = Invoke-AdbCmd -Device $Device -Command "shell pm list packages -3" -adb $adb
            foreach ($line in $tp) {
                if ($line -match '^package:(.+)$') { $thirdPartySet[$Matches[1].Trim()] = $true }
            }
        }

        $apps = foreach ($pkg in $packages) {
            $entry = if ($cache.ContainsKey($pkg)) { $cache[$pkg] } else { $null }
            [PSCustomObject]@{
                PackageName   = $pkg
                DisplayName   = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } else { $pkg }
                IconUrl       = if ($entry) { $entry.IconUrl }       else { '' }
                LocalIconPath = if ($entry) { $entry.LocalIconPath } else { '' }
                Version       = if ($entry) { $entry.Version }       else { '' }
                ThirdParty    = if ($ThirdPartyOnly) { $true } else { $thirdPartySet.ContainsKey($pkg) }
            }
        }

        # reorder apps alphabetically by DisplayName for better UX
        $apps = $apps | Sort-Object DisplayName

        
        Write-Log ($msg.HeadsetDetected -f "$($apps.Count) apps", $DeviceId) -Level INFO
        return $apps

    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return @()
    }
}


function Get-AppInfo {
    <#
    .SYNOPSIS
    Retrieves display name and icon URL for a given Android package name, using a local cache and online lookup.
    .DESCRIPTION
    Checks a local CSV cache file for the package information first. If not found or incomplete,
    optionally searches online via the MetaMetadata GitHub repository and updates the cache.
    Returns a PSCustomObject with PackageName, DisplayName, IconUrl, and LocalIconPath (if icon downloaded).
    Update the cache file with any new information found online to minimize future lookups.
    .PARAMETER PackageName
    The Android package name to look up (e.g. "com.myapp.vr").
    .PARAMETER AppCacheFilePath
    Path to the local CSV cache file (default: global AppCacheFilePath).
    .PARAMETER IconCacheDir
    Directory to store downloaded icons (default: "website\assets\app_icons" under the script path).
    .PARAMETER searchOnline
    If set, performs an online search for missing packages and updates the cache (default: $true).
    .EXAMPLE
    Get-AppInfo -PackageName "com.myapp.vr"
    Get-AppInfo -PackageName "com.cosmorama.tabletroopers"
    Get-AppInfo -PackageName "com.mrf.pixeltoys.cabin" -searchOnline $true
       #>

    param (
        [Parameter(Mandatory=$true)]
        [string]$PackageName,
        [string]$AppCacheFilePath = $global:AppCacheFilePath,
        [string]$IconCacheDir = $(Join-Path $global:ScriptPath "website\assets\app_icons"),
        [bool]$searchOnline = $false
    )

    # genreate package name without com. on the beginning without using match
    if ($PackageName.StartsWith("com.")) {
        $PackageName_short = $PackageName.Substring(4)
    } else {
        $PackageName_short = $PackageName
    }
    
    $appInfos = [PSCustomObject]@{
                PackageName = $PackageName
                DisplayName = $PackageName_short
                IconUrl     = ""
                LocalIconPath = ""
                }
                

    # 1. Check local cache first
    $cache = @{}
    if (Test-Path $AppCacheFilePath) {
        foreach ($row in @(Import-Csv -Path $AppCacheFilePath -Delimiter ",")) {
            $cache[$row.PackageName] = $row
        }
    }
    # If the cache contains the package with all info let's return it !
    if ($cache.ContainsKey($PackageName) -and $PackageName_short -notin $cache[$PackageName].DisplayName -and $cache[$PackageName].IconUrl) {
        return $cache[$PackageName]
    }
    # fill the display name with cached value if already known, it may be added before of set manually by the user.
    if ($cache[$PackageName].DisplayName -and $PackageName_short -in $cache[$PackageName].DisplayName) {
        $appInfos.DisplayName = $cache[$PackageName].DisplayName
    }

    # Let's search online !
    if ($searchOnline) {
        $baseUrl = "https://raw.githubusercontent.com/threethan/MetaMetadata/main/data"
        $folders = @('common', 'oculus', 'oculus_public', 'oculusdb', 'sidequest')
    
        
        foreach ($folder in $folders) {
            $url = "$baseUrl/$folder/$PackageName.json"
            write-log ($msg.AppDisplayNameResolved -f $appInfos.DisplayName, "Online lookup on $url") -Level DEBUG
            $response = $null
            $icon = ""
            try {
                $response = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
                $icon = ""
                if ($response.square) { $icon = $response.square }
                elseif ($response.icon) { $icon = $response.icon }
                elseif ($response.landscape) { $icon = $response.landscape }
                elseif ($response.portrait) { $icon = $response.portrait }
                elseif ($response.hero) { $icon = $response.hero }
                elseif ($response.logo) { $icon = $response.logo }
            } catch {
                # Not found in this folder, try next
            }
            if ($response.name) {$appInfos.DisplayName = $response.name}
            if ($icon) {
                $appInfos.IconUrl = $icon
                break
            }
        }
    
        # Download icon locally so the web UI can display it without hitting remote URLs
        if ($appInfos.IconUrl) {
            if (-not (Test-Path $IconCacheDir)) {
                New-Item -ItemType Directory -Path $IconCacheDir -Force | Out-Null
            }

            # Derive extension from the remote URL; default to .png
            $ext = '.png'
            if ($appInfos.IconUrl -match '\.([a-zA-Z]{2,4})(?:[?#]|$)') {
                $ext = '.' + $Matches[1].ToLower()
            }
            $iconFileName = "$PackageName$ext"
            $iconFile     = Join-Path $IconCacheDir $iconFileName

            if (-not (Test-Path $iconFile)) {
                try {
                    Invoke-WebRequest -Uri $appInfos.IconUrl -OutFile $iconFile -TimeoutSec 10 -ErrorAction Stop
                    Write-Log ($msg.AppDisplayNameResolved -f "Icon saved", $iconFileName) -Level DEBUG
                } catch {
                    Write-Log ($msg.AppDisplayNameNotFound -f "Icon download failed: $PackageName") -Level DEBUG
                    $iconFileName = ""
                }
            }

            if ($iconFileName -ne "") {
                $appInfos.LocalIconPath = "/assets/app_icons/$iconFileName"
            }
        }
    }


    if (($appInfos.DisplayName -ne $cache[$PackageName].DisplayName) -and ($PackageName_short -eq $appInfos.DisplayName)){
        $appInfos.DisplayName = $cache[$PackageName].DisplayName
    }

      # Update cache file if we got new info
    if ($appInfos -notlike $cache[$PackageName]) {
        $cache[$PackageName] = $appInfos
        $cache.Values | Sort-Object DisplayName | Export-Csv -Path $AppCacheFilePath -NoTypeInformation -Encoding UTF8
    }
    return $appInfos
}

# Generate a function that will rebuild in background the app_names.csv cache file from the online MetaMetadata repository, iterating through all packages and fetching their metadata. This can be used to pre-populate the cache with known apps without needing to trigger lookups one by one.
function Update-AppCacheFromMetaMetadata { #DOES NOT WORKS, UNDER INVESTIGATION
    <#
    .SYNOPSIS
    Rebuilds the local app_names.csv cache file by fetching metadata for all packages listed in the MetaMetadata GitHub repository.
    .DESCRIPTION
    Iterates through all JSON files in the MetaMetadata data folders (common, oculus, oculus_public, oculusdb, sidequest) and extracts package names, display names and icon URLs. Updates the local app_names.csv cache file with this information, which can then be used for instant resolution of app display names and icons without needing to hit the network for each lookup.
    .EXAMPLE
    Update-AppCacheFromMetaMetadata
       #>
    param (
        [string]$AppCacheFilePath = $global:AppCacheFilePath,
        [string]$IconCacheDir = $(Join-Path $global:ScriptPath "website\assets\app_icons")
    )

    $baseUrl = "https://raw.githubusercontent.com/threethan/MetaMetadata/main/data"
    $folders = @('common', 'oculus', 'oculus_public', 'oculusdb', 'sidequest')
    $cache = @{}

    foreach ($folder in $folders) {
        $indexUrl = "$baseUrl/$folder/index.json"
        try {
            $index = Invoke-RestMethod -Uri $indexUrl -TimeoutSec 10 -ErrorAction Stop
            foreach ($entry in $index) {
                if ($entry.package) {
                    $packageName = $entry.package
                    if (-not $cache.ContainsKey($packageName)) {
                        $displayName = if ($entry.name) { $entry.name } else { $packageName }
                        $iconUrl = ""
                        if ($entry.square) { $iconUrl = $entry.square }
                        elseif ($entry.icon) { $iconUrl = $entry.icon }
                        elseif ($entry.landscape) { $iconUrl = $entry.landscape }
                        elseif ($entry.portrait) { $iconUrl = $entry.portrait }
                        elseif ($entry.hero) { $iconUrl = $entry.hero }
                        elseif ($entry.logo) { $iconUrl = $entry.logo }

                        # Download icon locally
                        $localIconPath = ""
                        if ($iconUrl) {
                            if (-not (Test-Path $IconCacheDir)) {
                                New-Item -ItemType Directory -Path $IconCacheDir -Force | Out-Null
                            }
                            $ext = '.png'
                            if ($iconUrl -match '\.([a-zA-Z]{2,4})(?:[?#]|$)') {
                                $ext = '.' + $Matches[1].ToLower()
                            }
                            $iconFileName = "$packageName$ext"
                            $iconFile = Join-Path $IconCacheDir $iconFileName
                            if (-not (Test-Path $iconFile)) {
                                try {
                                    Invoke-WebRequest -Uri $iconUrl -OutFile $iconFile -TimeoutSec 10 -ErrorAction Stop
                                    Write-Log ($msg.AppDisplayNameResolved -f "Icon saved", $iconFileName) -Level DEBUG
                                } catch {
                                    Write-Log ($msg.AppDisplayNameNotFound -f "Icon download failed: $packageName") -Level DEBUG
                                    $iconFileName = ""
                                }
                            }
                            if ($iconFileName -ne "") {
                                $localIconPath = "/assets/app_icons/$iconFileName"
                            }
                        }
                        $cache[$packageName] = [PSCustomObject]@{
                            PackageName = $packageName
                            DisplayName = $displayName
                            IconUrl     = $iconUrl
                            LocalIconPath = $localIconPath
                        }
                    }
                }
            }
        } catch {
            Write-Log ($msg.ErrorOccurred -f "Failed to fetch index from $indexUrl : $_") -Level ERROR
        }
    }
    # Save cache to CSV
    $cache.Values | Sort-Object DisplayName | Export-Csv -Path $AppCacheFilePath -NoTypeInformation -Encoding UTF8
    Write-Log ($msg.AppDisplayNameResolved -f "Cache update complete", $cache.Count) -Level INFO
}


function Get-InstalledAppsCachePath {
    param ([string]$headsetName)
    return Join-Path $global:ScriptPath "data\$(Convert-Displayname $headsetName)_installed_apps.csv"
}

function Update-InstalledAppsCache {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [string]$headsetName,
        [switch]$ResolveMissing,
        [string]$adb = $global:adbPath
    )

    try {
        $cachePath    = Get-InstalledAppsCachePath -headsetName $headsetName
        $appNamesPath = Join-Path $global:ScriptPath "data\app_names.csv"

        # Fetch third-party packages from headset
        $rawOutput = Invoke-AdbCmd -Device $Device -Command "shell pm list packages -3" -adb $adb
        $packages  = @($rawOutput | ForEach-Object { ($_ -replace '^package:', '').Trim() } | Where-Object { $_ -ne '' } | Sort-Object)

        if ($packages.Count -eq 0) { return }

        # When -ResolveMissing: fetch online metadata for packages not yet fully resolved
        if ($ResolveMissing) {
            $appNames = @{}
            if (Test-Path $appNamesPath) {
                Import-Csv -Path $appNamesPath -Delimiter "," | ForEach-Object {
                    if ($_.PackageName) { $appNames[$_.PackageName] = $_ }
                }
            }
            foreach ($pkg in $packages) {
                $cached = $appNames[$pkg]
                $needsResolve = (-not $cached) -or (-not $cached.DisplayName) -or ($cached.DisplayName -eq $pkg) -or (-not $cached.IconUrl)
                if ($needsResolve) {
                    Get-AppInfo -PackageName $pkg -searchOnline $true | Out-Null
                }
            }
        }

        # Load app_names lookup (possibly updated above)
        $appNames = @{}
        if (Test-Path $appNamesPath) {
            Import-Csv -Path $appNamesPath -Delimiter "," | ForEach-Object {
                if ($_.PackageName) { $appNames[$_.PackageName] = $_ }
            }
        }

        # Fetch version names for all installed packages in a single ADB call
        # Format: "Package [com.pkg] (hash):" then "    versionName=x.y.z"
        $versions   = @{}
        $currentPkg = $null
        foreach ($line in (Invoke-AdbCmd -Device $Device -Command "shell dumpsys package packages" -TimeoutSeconds 60 -adb $adb)) {
            if ($line -match '^\s{2}Package \[([^\]]+)\]') {
                $currentPkg = $Matches[1]
            } elseif ($currentPkg -and $line -match '^\s+versionName=(\S+)') {
                $versions[$currentPkg] = $Matches[1]
                $currentPkg = $null
            }
        }

        # Build new rows
        $newRows = $packages | ForEach-Object {
            $pkg     = $_
            $entry   = $appNames[$pkg]
            $dn      = if ($entry -and $entry.DisplayName -and $entry.DisplayName -ne $pkg) { $entry.DisplayName } else { $pkg }
            $ico     = if ($entry) { $entry.IconUrl }     else { '' }
            $icoPath = if ($entry) { $entry.LocalIconPath } else { '' }
            $ver     = if ($versions.ContainsKey($pkg)) { $versions[$pkg] } else { '' }
            [PSCustomObject]@{ PackageName = $pkg; DisplayName = $dn; IconUrl = $ico; LocalIconPath = $icoPath; Version = $ver }
        }

        # Compare with existing cache (by sorted package list only); always write when -ResolveMissing
        $changed = $ResolveMissing.IsPresent
        if (-not $changed -and (Test-Path $cachePath)) {
            $existing = @(Import-Csv -Path $cachePath -Delimiter "," | Select-Object -ExpandProperty PackageName | Sort-Object)
            $changed  = ($existing -join ',') -ne ($packages -join ',')
        } elseif (-not (Test-Path $cachePath)) {
            $changed = $true
        }

        if ($changed) {
            $newRows | Export-Csv -Path $cachePath -NoTypeInformation -Delimiter "," -Encoding UTF8 -Force
            Write-Log ($msg.InstalledAppsCacheUpdated -f $headsetName, $packages.Count) -Level DEBUG
        }
    }
    catch {
        Write-Log ($msg.InstalledAppsCacheFailed -f $headsetName, $_) -Level DEBUG
    }
}

function Uninstall-HeadsetApp {
    <#
    .SYNOPSIS
    Uninstalls a third-party application from a VR headset via ADB.
    .DESCRIPTION
    Uses Get-HeadsetInstalledApps to verify the package is a third-party app before uninstalling.
    Returns $false with a warning if the app is not found or is a system package.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [Parameter(Mandatory=$true)]
        [string]$PackageName,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return $false }
    $DeviceId = $Device.DeviceId

    try {
        # Check third-party apps only
        $thirdPartyApps = Get-HeadsetInstalledApps -Device $Device -ThirdPartyOnly -adb $adb
        $isThirdParty   = [bool]($thirdPartyApps.PackageName | Where-Object { $_ -eq $PackageName })

        if (-not $isThirdParty) {
            # Distinguish: system app vs not installed at all
            $allApps  = Get-HeadsetInstalledApps -Device $Device -ThirdPartyOnly:$false -adb $adb
            $isSystem = [bool]($allApps.PackageName | Where-Object { $_ -eq $PackageName })

            if ($isSystem) {
                Write-Log ($msg.AppNotThirdParty -f $PackageName, $DeviceId) -Level WARNING
            } else {
                Write-Log ($msg.AppNotFound -f $PackageName, $DeviceId) -Level WARNING
            }
            return $false
        }

        Write-Log ($msg.AppUninstalling -f $PackageName, $DeviceId) -Level INFO
        $output = Invoke-AdbCmd -Device $Device -Command "shell pm uninstall $PackageName" -adb $adb
        if ($output -isnot [bool] -and ($output -match "^Success")) {
            Write-Log ($msg.AppUninstallSuccess -f $PackageName, $DeviceId) -Level SUCCESS
            return $true
        } else {
            Write-Log ($msg.AppUninstallFailed -f $PackageName, $DeviceId, ($output -join ' ')) -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return $false
    }
}


function Install-HeadsetApp {
    <#
    .SYNOPSIS
    Installs an APK (and optional OBB data folder) onto a VR headset via ADB.
    .DESCRIPTION
    $path can be a direct .apk file path, or a folder whose root contains:
      - <packagename>.apk  (installed via adb install -r)
      - <packagename>/     (optional OBB data, pushed to /sdcard/Android/obb/<packagename>/)
    Returns [PSCustomObject]@{PackageName; Version} on success, $false on error or skipped install.
    If the app is already installed and -Overwrite is not set, returns $false.
    #>
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Device,
        [Parameter(Mandatory=$true)]
        [string]$path,
        [switch]$Overwrite,
        [string]$adb = $global:adbPath
    )
    if (-not $Device) { Write-Log ($msg.AdbWifiConnectFailed -f 'unknown', 'no device') -Level ERROR; return [PSCustomObject]@{ Ok = $false; Error = 'No device' } }
    $DeviceId = $Device.DeviceId

    try {
        # --- Resolve APK file ---
        $isFolder = Test-Path -LiteralPath $path -PathType Container
        $apkPath  = $null

        if (-not $isFolder) {
            if (-not ($path -match '\.apk$') -or -not (Test-Path -LiteralPath $path)) {
                Write-Log ($msg.ApkNotFound -f $path) -Level ERROR
                return [PSCustomObject]@{ Ok = $false; Error = "APK not found: $path" }
            }
            $apkPath = $path
        } else {
            $apkFiles = @(Get-ChildItem -LiteralPath $path -Filter '*.apk' -File)
            if ($apkFiles.Count -eq 0) {
                Write-Log ($msg.ApkFileNotFound -f $path) -Level ERROR
                return [PSCustomObject]@{ Ok = $false; Error = "No .apk file found in folder: $path" }
            }
            $apkPath = $apkFiles[0].FullName
        }

        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($apkPath)

        # --- Pre-check: already installed? ---
        $allApps     = Get-HeadsetInstalledApps -Device $Device -ThirdPartyOnly:$false -adb $adb
        $isInstalled = [bool]($allApps | Where-Object { $_.PackageName -eq $packageName })
        if ($isInstalled) {
            $verMatch         = Invoke-AdbCmd -Device $Device -Command "shell dumpsys package $packageName" -adb $adb | Select-String 'versionName' | Select-Object -Last 1
            $installedVersion = if ($verMatch -and "$verMatch" -match 'versionName=(\S+)') { $Matches[1] } else { '' }
            Write-Log ($msg.ApkAlreadyInstalled -f $packageName, $installedVersion) -Level INFO
            if (-not $Overwrite) {
                Write-Log ($msg.UserCancelled) -Level INFO
                return [PSCustomObject]@{ Ok = $false; Error = 'Already installed'; PackageName = $packageName; InstalledVersion = $installedVersion }
            }
        }

        # --- Step 1: Install APK ---
        Write-Log ($msg.InstallingApk) -Level INFO
        $installOutput = Invoke-AdbCmd -Device $Device -Command "install -r `"$apkPath`"" -TimeoutSeconds 120 -adb $adb
        $outputText    = if ($installOutput -ne $false) { ($installOutput -join ' ').Trim() } else { '' }
        if ($installOutput -eq $false -or $outputText -match 'Failure|INSTALL_FAILED') {
            $errDetail = if ($outputText -match '(INSTALL_FAILED_\S+|\[.+\])') { $Matches[1] } elseif ($outputText) { $outputText } else { 'ADB install command failed' }
            Write-Log ($msg.ApkInstallFailed) -Level ERROR
            return [PSCustomObject]@{ Ok = $false; Error = $errDetail }
        }

        $verMatchPost     = Invoke-AdbCmd -Device $Device -Command "shell dumpsys package $packageName" -adb $adb | Select-String 'versionName' | Select-Object -Last 1
        $installedVersion = if ($verMatchPost -and "$verMatchPost" -match 'versionName=(\S+)') { $Matches[1] } else { '' }
        Write-Log ($msg.ApkInstallSuccess -f $packageName, $DeviceId) -Level SUCCESS

        # --- Step 2: Push OBB folder (folder input only) ---
        if ($isFolder) {
            $obbFolder = Join-Path $path $packageName
            if (Test-Path -LiteralPath $obbFolder -PathType Container) {
                Write-Log ($msg.ObbFolderFound -f $packageName) -Level INFO
                Invoke-AdbCmd -Device $Device -Command "shell mkdir -p /sdcard/Android/obb/$packageName" -adb $adb | Out-Null
                $pushResult = Invoke-AdbCmd -Device $Device -Command "push `"$obbFolder`" /sdcard/Android/obb/$packageName" -TimeoutSeconds 300 -adb $adb
                if ($pushResult -eq $false) {
                    Write-Log ($msg.ObbPushFailed -f $packageName, $DeviceId, 'ADB push failed') -Level ERROR
                    return [PSCustomObject]@{ Ok = $false; Error = 'OBB data push failed' }
                }
                Write-Log ($msg.ObbPushSuccess -f $packageName, $DeviceId) -Level SUCCESS
            }
        }

        return [PSCustomObject]@{ Ok = $true; PackageName = $packageName; Version = $installedVersion }
    }
    catch {
        Write-Log ($msg.ErrorOccurred -f $_) -Level ERROR
        return [PSCustomObject]@{ Ok = $false; Error = $_.ToString() }
    }
}