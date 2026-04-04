#####################################
# CONFIGURE QUEST HEADSET USING ADB #
#####################################

# Translations are loaded centrally in scripts_init.ps1 into $global:msg

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
    


}
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
    Installs the WiFi ADB APK after verifying its presence
    
    .DESCRIPTION
    - Checks if the APK is already installed
    - Installs only if necessary
    - Maintains the same critical permissions
    #>
    param (
        [string]$adb = $global:adbPath
    )

    $apkPath = $global:ADBWirelessActivatorAPK
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

    # 2. Detect and verify headset connected via USB
    #$devices = & $adbPath devices -l | Where-Object { $_ -match '\tdevice$' -and $_ -match '\tusb$' }

    & $adb usb
    $devices = & $adb devices | Where-Object { $_ -match '\tdevice$' } 
    if (-not $devices) {
        Write-Log ($msg.NoHeadsetDetected) -Level WARNING
        return $false
    }
    
    $deviceId = ($devices -split '\t')[0]
    # Retrieve the model:
    $headsetModel = & $adb -s $deviceId shell getprop ro.product.model
    Write-Log ($msg.HeadsetDetected -f $headsetModel, $deviceId) -Level INFO

    try {

        # 3. Check for existing installation
        $packageName = $global:ADBWirelessActivatorPackageName
        $isInstalled = & $adb -s $deviceId shell pm list packages $packageName
        if ($isInstalled) {
            $version = (& $adb -s $deviceId shell dumpsys package $packageName| Select-String "versionName") -split '=' | Select-Object -Last 1
            Write-Log ($msg.ApkAlreadyInstalled -f $packageName, $version) -Level INFO 
            Write-Log ($msg.Reinstalling) -Level INFO 
        }

        else {
            # 4. Installation if missing
            Write-Log ($msg.InstallingApk) -Level INFO
            & $adb -s $deviceId install -r $apkPath
            if ($LASTEXITCODE -ne 0) {
                Write-Log ($msg.ApkInstallFailed) -Level ERROR
                Pause
            }
        }
        # Apply critical permissions
        Write-Log ($msg.ConfiguringPermissions) -Level INFO
        & $adb -s $deviceId shell pm grant $packageName android.permission.WRITE_SECURE_SETTINGS
        #& $adb -s $deviceId shell pm grant $packageName android.permission.READ_LOGS
        # Launch app on headset
        & $adb -s $deviceId shell am start -n tdg.oculuswirelessadb/.MainActivity

        # 5. Activate TCP/IP (always)
        Write-Log ($msg.ActivatingWifiAdbMode) -Level INFO
        & $adb -s $deviceId tcpip 5555
        Start-Sleep -Seconds 2

        return $true
    }
    catch {
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
        $usbDevice = Test-UsbAdbDevice -adb $adb
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

        $deviceId = ($devices -split '\t')[0]
        # Retrieve the model:
        $headsetModel = & $adb -s $deviceId shell getprop ro.product.model
        Write-Log ($msg.HeadsetDetected -f $headsetModel, $deviceId) -Level INFO

        # Step 3: Check SSID
        #$wifiInfo = & $adb -s $deviceId shell "dumpsys wifi" > ../../WifiDump.txt
        $wifiInfo = & $adb -s $deviceId shell "dumpsys wifi | grep -E 'mWifiInfo'"

        if ($wifiInfo -match 'SSID: "([^"]+)"') {
            $currentSSID = $matches[1]  # Returns the SSID without quotes
            Write-Log ($msg.CurrentlyConnectedSsid -f $currentSSID) -Level INFO
        }

        # Step 4: Verify the connected SSID
        if ($currentSSID -notmatch [regex]::Escape($wifi_ssid)) {
            Write-Log ($msg.HeadsetNotConnectedToSsid -f $wifi_ssid) -Level WARNING

            try {
                # Connect to new network using fixed MAC option

                & $adb -s $deviceId shell "svc wifi enable"
                & $adb -s $deviceId shell cmd -w wifi connect-network $wifi_ssid wpa2  $wifi_pwd -r none

                # Activate network
                Write-Log ($msg.ActivatingWifiNetwork -f $wifi_ssid, $headsetModel, $deviceId) -Level INFO
                Start-Sleep -Seconds 5
            } catch {
                Write-Log ($msg.WifiConfigFailed -f $_) -Level ERROR
                return $false
            }
        }





        # 3. Retrieve WiFi IP
        Write-Log ($msg.RetrievingIp) -Level INFO
        $ipInfo = & $adb -s $deviceId shell ip -f inet addr show wlan0 | 
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
            & $adb -s $deviceId tcpip $AdbPort
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


function Test-UsbAdbDevice {

    param(
        [int]$MaxAttempts = 5,
        [string]$adb = $global:adbPath
    )


    if (-not (Test-Path $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $false
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {

        try {
            $usbDevice = & $adb devices |
                Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ":" }

            if ($usbDevice) {
                Write-Log ($msg.UsbAdbDeviceDetected) -Level SUCCESS
                return $usbDevice
            }
        }
        catch {
                Write-Log ($msg.ADBExecutionFailed -f $_.Exception.Message) -Level ERROR

        Write-Log ($msg.NoUsbHeadsetDetectedPrompt) -Level INFO
        if ((Read-Host) -match "^[Qq]$") {
            Write-Log ($msg.UserCancelledUsbDetection) -Level INFO
            return $false
        }
    }

    Write-Log ($msg.NoUsbAdbDeviceFound -f $MaxAttempts) -Level ERROR
    return $false
    }
}


function Connect-AdbWifi {
    <#
    .SYNOPSIS
    Connects to a VR headset via ADB over WiFi and keeps the connection open.

    .DESCRIPTION
    - If the headset is already in the ADB devices list as connected, skips reconnection.
    - Tests network reachability via ping.
    - Checks if the ADB TCP port is open.
    - A closed port hints that developer mode or WiFi ADB is not enabled on the headset.
    - Attempts adb connect and verifies the result.

    .PARAMETER headsetIP
    IP address of the headset.

    .PARAMETER AdbPort
    ADB TCP port to connect to (default: 5555).

    .EXAMPLE
    Connect-AdbWifi -headsetIP "192.168.1.100" -AdbPort 5555
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,
        [int]$AdbPort = $global:adbPort_default,
        [string]$adb = $global:adbPath
    )

    $DeviceId = "${headsetIP}:${AdbPort}"

    # 1. Verify ADB executable
    if (-not (Test-Path $adb)) {
        Write-Log ($msg.ADBExecutableNotFound -f $adb) -Level ERROR
        return $false
    }

    # 2. Check if already connected (avoid redundant reconnects)
    $alreadyConnected = & $adb devices 2>&1 |
        Where-Object { $_ -match ("^" + [regex]::Escape($DeviceId) + "\s+device$") }
    if ($alreadyConnected) {
        Write-Log ($msg.AdbWifiAlreadyConnected -f $DeviceId) -Level DEBUG
        return $true
    }

    Write-Log ($msg.AdbWifiConnecting -f $DeviceId) -Level INFO

    # 3. Test network reachability (ping)
    $pingOk = Test-Connection -ComputerName $headsetIP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        Write-Log ($msg.AdbWifiPingFailed -f $headsetIP) -Level WARNING
        return $false
    }

    # 4. Test ADB TCP port is open
    $portOpen = (Test-Port -hostname $headsetIP -port $AdbPort).open
    if (-not $portOpen) {
        Write-Log ($msg.AdbWifiPortClosed -f $AdbPort, $headsetIP) -Level WARNING
        Write-Log ($msg.AdbWifiDevModeHint) -Level WARNING
        return $false
    }

    # 5. Connect via ADB WiFi
    try {
        $connectOutput = & $adb connect $DeviceId 2>&1

        # Verify the device appears as connected
        $nowConnected = & $adb devices 2>&1 |
            Where-Object { $_ -match ("^" + [regex]::Escape($DeviceId) + "\s+device$") }
        if ($nowConnected) {
            Write-Log ($msg.AdbWifiConnected -f $DeviceId) -Level SUCCESS
            return $true
        }
        else {
            Write-Log ($msg.AdbWifiConnectFailed -f $DeviceId, ($connectOutput -join " ")) -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log ($msg.AdbWifiConnectFailed -f $DeviceId, $_) -Level ERROR
        return $false
    }
}


function Get-HeadsetModel {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = $global:adbPort_default
    )
    $DeviceId = "${headsetIP}:${AdbPort}"

    if (-not (Connect-AdbWifi -headsetIP $headsetIP -AdbPort $AdbPort -adb $adb)) {
        return $false
    }

    $headsetModel = (& $adb -s $DeviceId shell getprop ro.product.model).Trim() #.trim() to remove any trailing newline characters
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
        [string]$headsetIP,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = $global:adbPort_default
    )
    $DeviceId = "${headsetIP}:${AdbPort}"

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

        if (-not (Connect-AdbWifi -headsetIP $headsetIP -AdbPort $AdbPort -adb $adb)) {
            return $result
        }

        
        $dump = & $adb -s $DeviceId shell dumpsys OVRRemoteService 2>$null
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
        [string]$headsetIP,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = $global:adbPort_default
    )
    $DeviceId = "${headsetIP}:${AdbPort}"

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

        if (-not (Connect-AdbWifi -headsetIP $headsetIP -AdbPort $AdbPort -adb $adb)) {
            return $null
        }

        $batteryInfo = & $adb -s $DeviceId shell dumpsys battery 2>$null

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
        $controllers = Get-QuestControllerBatteryStatus -headsetIP $headsetIP -adb $adb -AdbPort $AdbPort
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




function Get-HeadsetForegroundApp {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = $global:adbPort_default
    )
    $DeviceId = "${headsetIP}:${AdbPort}"

    if (-not (Connect-AdbWifi -headsetIP $headsetIP -AdbPort $AdbPort -adb $adb)) {
        return $null
    }

    try {
        $dumpLines = @(& $adb -s $DeviceId shell dumpsys activity activities 2>$null)

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


# Resolves a Quest package name to its display name and icon URL.
# Checks data/app_names.csv first; on cache miss fetches from:
#   https://github.com/threethan/MetaMetadata (updates daily, covers all Meta Store + SideQuest apps)
# Unknown packages are cached with DisplayName = PackageName and empty IconUrl so the
# network is never hit more than once per package.
function Get-AppDisplayName {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackageName
    )

    $cacheFile = Join-Path $global:ScriptPath "data\app_names.csv"

    # Load cache into a hashtable keyed by PackageName
    $cache = @{}
    if (Test-Path $cacheFile) {
        foreach ($row in @(Import-Csv -Path $cacheFile -Delimiter ",")) {
            $cache[$row.PackageName] = $row
        }
    }

    # Return cached entry if present
    if ($cache.ContainsKey($PackageName)) {
        return $cache[$PackageName]
    }

    # Cache miss - fetch from MetaMetadata
    $url = "https://raw.githubusercontent.com/threethan/MetaMetadata/main/data/common/$PackageName.json"
    try {
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 8 -ErrorAction Stop
        $newEntry = [PSCustomObject]@{
            PackageName = $PackageName
            DisplayName = $response.name
            IconUrl     = if ($response.square) { $response.square } elseif ($response.icon) { $response.icon } else { "" }
        }
        Write-Log ($msg.AppDisplayNameResolved -f $PackageName, $response.name) -Level DEBUG
    } catch {
        # Not found in repo (system app, sideloaded app, etc.) - store placeholder
        $newEntry = [PSCustomObject]@{
            PackageName = $PackageName
            DisplayName = $PackageName
            IconUrl     = ""
        }
        Write-Log ($msg.AppDisplayNameNotFound -f $PackageName) -Level DEBUG
    }

    # Persist to cache
    $cache[$PackageName] = $newEntry
    $cache.Values | Export-Csv -Path $cacheFile -NoTypeInformation -Encoding UTF8

    return $newEntry
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



