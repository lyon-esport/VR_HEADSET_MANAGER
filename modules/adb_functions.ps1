#####################################
# CONFIGURE QUEST HEADSET USING ADB #
#####################################

<#
function Install-apk-oculuswirelessadb {
    Write-Log "Cette fonctionnalite n'a pas encore ete developpee" -Level WARNING
    #Fonction a ecrire - Copie en vrac des actions a realiser en ADB USB
    # Tester la connexion concurrente en USB si d'autres casques sont deja connectes en WIFI
    # Installer l'appli et la lancer dans le casque
    # Si le casque est deja connecte, 

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
       Write-Log "Pas de casque detecte a ajouter !"  
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
}
#>

function Start-AdbServer {
    <#
    .SYNOPSIS
    Starts ADB server if not already running.
    
    .DESCRIPTION
    Checks if ADB server is running and starts it if needed using the specified adb.exe path.
    
    .EXAMPLE
    Start-AdbServer -adbPath "C:\adb\adb.exe"
    #>
    param (
        [string]$adbPath = $global:adbPath
    )

    try {
        # Check if ADB process is running
        $adbProcess = Get-Process -Name "adb" -ErrorAction SilentlyContinue
        if (-not $adbProcess) {
            $i = 0
            while ($i -lt 5){
                $adbProcess = Get-Process -Name "adb" -ErrorAction SilentlyContinue
                if (-not $adbProcess) {
                    Write-Log "ADB server not running. Starting server..." WARNING
                    $null = Start-Process -FilePath $adbPath -ArgumentList "start-server" -NoNewWindow
                    Start-Sleep -Seconds 3
                }
                else{
                    Write-Log "ADB server started successfully" SUCCESS
                    return $true
                }
                $i++
            }
        }
        else {
            Write-Log "ADB server is already running (PID: $($adbProcess.Id))" -Level INFO
            return $true
        }
    }
    catch {
        Write-Log "Failed to start ADB server: $_" -Level ERROR
        return $false
    }
}

# Example usage:
# 

function Install-Apk-OculusWirelessAdb {
    <#
    .SYNOPSIS
    Installe l'APK WiFi ADB apres verification de sa presence
    
    .DESCRIPTION
    - Verifie si l'APK est deja installe
    - Installation uniquement si necessaire
    - Maintenance des memes permissions critiques
    #>

    $adb = $global:adbPath
    $apkPath = $global:ADBWirelessActivatorAPK
    $packageName = $global:ADBWirelessActivatorPackageName
    # 1. Verification prealable
    if (-not (Test-Path $adb)) {
        Write-Log "ADB introuvable dans $global:adbFolder" -Level ERROR
        return $false
    }

    if (-not (Test-Path $apkPath)) {
        Write-Log "APK introuvable : $apkPath" -Level ERROR
        return $false
    }

    # 2. Detection et verification du casque connecte en USB
    #$devices = & $adbPath devices -l | Where-Object { $_ -match '\tdevice$' -and $_ -match '\tusb$' }

    & $adb usb
    $devices = & $adb devices | Where-Object { $_ -match '\tdevice$' } 
    if (-not $devices) {
        Write-Log "Aucun casque detecte" -Level WARNING
        return $false
    }
    
    $deviceId = ($devices -split '\t')[0]
    # Recuperation du modele :
    $headsetModel = & $adb -s $deviceId shell getprop ro.product.model
    Write-Log "Casque detecte : $headsetModel [ $deviceId ]" -Level INFO

    try {

        # 3. Verification de l'installation existante
        $packageName = $global:ADBWirelessActivatorPackageName
        $isInstalled = & $adb -s $deviceId shell pm list packages $packageName
        if ($isInstalled) {
            $version = (& $adb -s $deviceId shell dumpsys package $packageName| Select-String "versionName") -split '=' | Select-Object -Last 1
            Write-Log "L'APK $packageName est deja installe en version $version" -Level INFO 
            Write-Log "Reinstallation" -Level INFO 
        }

        else {
            # 4. Installation si absent
            Write-Log "Installation de l'APK..." -Level INFO
            & $adb -s $deviceId install -r $apkPath
            if ($LASTEXITCODE -ne 0) {
                Write-Log "echec installation APK" -Level ERROR
                Pause
            }
        }
        # Application des permissions critiques
        Write-Log "Configuration des permissions..." -Level INFO
        & $adb -s $deviceId shell pm grant $packageName android.permission.WRITE_SECURE_SETTINGS
        #& $adb -s $deviceId shell pm grant $packageName android.permission.READ_LOGS
        # Lancement de l'application dans le casque
        & $adb shell am start -n tdg.oculuswirelessadb/.MainActivity

        # 5. Activation TCP/IP (dans tous les cas)
        Write-Log "Activation du mode WiFi ADB..." -Level INFO
        & $adb -s $deviceId tcpip 5555
        Start-Sleep -Seconds 2

        return $true
    }
    catch {deviceId
        Write-Log "ERREUR : $_" -Level ERROR
        return $false
    }
}

function Test-AdbDevicesAuthorization {
    # Verifie si un casque est connecte et qu'il est bien autorise
    param (
        [string]$adb = $global:adbPath
    )

    $maxAttempts = 3
    $attempt = 0

    while ($attempt -lt $maxAttempts) {
        $devices = & $adb devices 2>&1 | Where-Object { $_ -notmatch '^List of devices attached' }
        $unauthorizedFound = $false

        # Analyse de la sortie ADB
        foreach ($line in $devices) {
            if ($line -like "*unauthorized*") {
                Write-Log "ADB Debug USB non autorisé : Acceptez le debug USB dans le casque" -Level WARNING
                $unauthorizedFound = $true
            }
        }

        if ($unauthorizedFound) {
            $attempt++
            $response = Read-Host "`nRecommencer ? [Entree pour reessayer ($attempt/$maxAttempts) ; 0 pour quitter]"
            if ($response -eq '0') {
                Write-Log "Annulation demandee par l'utilisateur" -Level INFO
                return $false
            }
            continue
        }

        if (-not $devices -or $devices -like "*daemon*") {
            Write-Log "Aucun casque detecte en USB ou probleme de demon ADB" -Level WARNING
            Write-Log "--> Le casque est-il en mode développeur ?" -Level WARNING
            return $false
        }

        # Si on arrive ici, tout est OK
        return $true
    }

    Write-Log "Nombre maximum de tentatives atteint ($maxAttempts)" -Level ERROR
    return $false
}

function Enable-WiFiADB {
    <#
    .SYNOPSIS
    Active le mode WiFi ADB sur un casque Meta Quest connecte en USB

    .DESCRIPTION
    - Detecte un casque connecte en USB
    - Recupere son adresse IP WiFi
    - Active le mode TCP/IP
    - Verifie l'ouverture du port

    .PARAMETER AdbPort
    Port a utiliser pour ADB (defaut: 5555)

    .EXAMPLE
    Enable-WiFiADB -AdbPort 5555
    #>

    param(
        [Parameter(Mandatory=$true)]
        [string]$wifi_ssid,
        [string]$wifi_pwd,
        [int]$AdbPort = 5555,
        [string]$adb = $global:adbPath
        
    )

    # 1. Verification initiale
    if (-not (Test-Path $adbPath)) {
        Write-Log "ADB executable not found at $adb" -Level ERROR
        return $false
    }

    Write-Log "Searching for USB-connected headset..." -Level INFO
    try {
        
        # 2. USB Device Detection
        $usbDevice = Test-UsbAdbDevice -adb $adb
        if (-not $usbDevice) {
            Write-Log "No USB ADB device detected" -Level ERROR
            Write-Log ">> Back to main menu..." -Level INFO
            Start-Sleep -Seconds 3
            return $false
        }

        # 3. Check if the device is authorized for USB debugging
        if (-not (Test-AdbDevicesAuthorization)) { # Vérifier si ça marche bien uniquement en USB si d'autres casques sont déjà connectés en ADB Wifi
            return $false
        }

        $deviceId = ($devices -split '\t')[0]
        # Recuperation du modele :
        $headsetModel = & $adb -s $deviceId shell getprop ro.product.model
        Write-Log "Casque detecte : $headsetModel [ $deviceId ]" -Level INFO

        # Étape 3: Vérification du SSID 
        #$wifiInfo = & $adb -s $deviceId shell "dumpsys wifi" > ../../WifiDump.txt
        $wifiInfo = & $adb -s $deviceId shell "dumpsys wifi | grep -E 'mWifiInfo'"

        if ($wifiInfo -match 'SSID: "([^"]+)"') {
            $currentSSID = $matches[1]  # Retourne LES-VR-6G sans les guillemets
            Write-Log "Currently connected to SSID : $ssid" -Level INFO
        }

        # Étape 4: Vérification du SSID connecté
        if ($currentSSID -notmatch [regex]::Escape($wifi_ssid)) {
        Write-Warning "Le casque n'est pas connecte au SSID $wifi_ssid. Forcage de la connexion..." 

            try {
                # Connexion au nouveau réseau avec option MAC fixe

                & $adb -s $deviceId shell "svc wifi enable"
                & $adb -s $deviceId shell cmd -w wifi connect-network $wifi_ssid wpa2  $wifi_pwd -r none

                # Activation du réseau
                Write-Log "Activation du réseau WIFI $wifi_ssid sur le casque $headsetModel [$deviceId]"
                Start-Sleep -Seconds 5
            } catch {
                Write-Log "Echec de la configuration WiFi: $_" ERROR
                return $false
            }
        }





        # 3. Recuperation de l'IP WiFi
        Write-Log "Recuperation de l'adresse IP..." -Level INFO
        $ipInfo = & $adb -s $deviceId shell ip -f inet addr show wlan0 | 
                  Select-String 'inet' | 
                  ForEach-Object { ($_ -split '\s+')[2] -split '/' | Select-Object -First 1 }

        if (-not $ipInfo) {
            Write-Log "Impossible de recuperer l'IP. Verifiez la connexion WiFi du casque." -Level ERROR
            return $false
        }

        Write-Log "IP WiFi detectee: $ipInfo" -Level INFO

        # 4. Installation de Install-Apk-OculusWirelessAdb
        $answer = Read-Host "OPTIONNEL : Voulez-vous installer OculusWirelessAdb ?(Y/n)"
        if ($answer.ToUpper() -eq "Y")
            {Install-Apk-OculusWirelessAdb}
        else {
        # 5. Activation du mode TCP/IP

            Write-Log "Activation du mode WiFi ADB sur le port $AdbPort..." -Level INFO
            & $adb -s $deviceId tcpip $AdbPort
        }
        Start-Sleep -Seconds 5  # Attente de l'initialisation
        # 6. Verification du port
        Write-Log "Verification de l'ouverture du port $AdbPort..." -Level INFO
        $portTest = $(Test-Port -hostname $ipInfo -port $AdbPort).open
        
        if ($portTest) {
            Write-Log "Port $AdbPort ouvert avec succes sur $ipInfo" -Level SUCCESS
            
            $knownHeadsets = Get-KnownHeadsets
            if ($knownHeadsets.IPAddress -contains $ipInfo){
                Write-Log "IP du casque déjà présente dans la liste des casques connus"
            }
            else {
                $choice = (Read-Host "Voulez-vous l'ajouter aux casques connus ? (Y/N)").ToUpper()

                switch ($choice) {
                    'Y' {   Write-Host "Ajout du casque a la liste" -BackgroundColor green
                            $headsetName = Read-Host "Quel nom voulez-vous lui donner ?"
                            Add-Headset -Name $headsetName -IPAddress $ipInfo
                        }
                    default {
                        Write-Host ">> Retour au menu principal" -ForegroundColor green
                    }
                }
            }
        }
        else {
            Write-Log "echec d'ouverture du port $AdbPort" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "ERREUR: $_" -Level ERROR
        return $false
    }
}


function Test-UsbAdbDevice {

    param(
        [int]$MaxAttempts = 5,
        [string]$adb = $global:adbPath
    )


    if (-not (Test-Path $adb)) {
        Write-Log -Message "ADB executable not found at $adbPath" -Level "ERROR"
        return $false
    }

    for ($i = 1; $i -le $MaxAttempts; $i++) {

        try {
            $usbDevice = & $adbPath devices |
                Where-Object { $_ -match "`tdevice$" -and $_ -notmatch ":" }

            if ($usbDevice) {
                Write-Log -Message "USB ADB device detected." -Level "SUCCESS"
                return $usbDevice
            }
        }
        catch {
            Write-Log -Message "ADB execution failed: $($_.Exception.Message)" -Level "ERROR"
        }

        Write-Host "No USB headset detected. Connect it via USB and press ENTER (Q to quit)."
        if ((Read-Host) -match "^[Qq]$") {
            Write-Log -Message "User cancelled USB detection." -Level "INFO"
            return $false
        }
    }

    Write-Log -Message "No USB ADB device found after $MaxAttempts attempts." -Level "ERROR"
    return $false
}


function Get-HeadsetModel {
    param (
        [Parameter(Mandatory=$true)]
        [string]$headsetIP,
        [string]$adb = $global:adbPath,
        [int]$AdbPort = 5555 
    )
    $DeviceId = $headsetIP+":"+$AdbPort

    # 1. Verification initiale
    if (-not (Test-Path $adbPath)) {
        Write-Log "ADB executable not found at $adb" -Level ERROR
        return $false
    }

    $connectedDevice = & $adb devices | Select-String $headsetIP -AllMatches
        if ($connectedDevice.Matches.Count -lt 1) {
            Write-Log -Message "Aucune connexion ADB active pour $headsetIP, tentative de connexion..." -Level "INFO"
            & $adb connect $DeviceId | Out-Null
        }
        $headsetModel = (& $adb -s $DeviceId shell getprop ro.product.model).Trim() #.Trim() pour nettoyer la chaine et enlever les retours a la ligne s'il y en a
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
        [int]$AdbPort = 5555 
    )
    $DeviceId = $headsetIP+":"+$AdbPort

    $result = @{
        Left  = @{
            Battery        = $null
            Status         = $null
            TrackingStatus = $null
        }
        Right = @{
            Battery        = $null
            Status         = $null
            TrackingStatus = $null
        }
    }

    try {
        Write-Log -Message "Querying controller status via OVRRemoteService for $DeviceId" -Level DEBUG

        # 1. init verification 
        if (-not (Test-Path $adbPath)) {
            Write-Log "ADB executable not found at $adb" -Level ERROR
            return $false
        }

        $connectedDevice = & $adb devices | Select-String $headsetIP -AllMatches
        if ($connectedDevice.Matches.Count -lt 1) {
            Write-Log -Message "Aucune connexion ADB active pour $headsetIP, tentative de connexion..." -Level "INFO"
            & $adb connect $headsetIP | Out-Null
        }

        
        $dump = & $adb -s $DeviceId shell dumpsys OVRRemoteService 2>$null
        if (-not $dump) {
            Write-Log -Message "No OVRRemoteService output for $DeviceId" -Level WARNING
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

                if ($line -match "TrackingStatus:\s*([A-Za-z]+)") {
                    $result[$side].TrackingStatus = $Matches[1]
                }

                Write-Log -Message "Controller $side -> Battery=$($result[$side].Battery) Status=$($result[$side].Status) Tracking=$($result[$side].TrackingStatus)" -Level DEBUG
            }
        }

        return $result
    }
    catch {
        Write-Log -Message "Failed to retrieve controller status via OVRRemoteService: $($_.Exception.Message)" -Level ERROR
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
        [int]$AdbPort = 5555 
    )
    $DeviceId = $headsetIP+":"+$AdbPort

    $result = [PSCustomObject]@{
        Level     = $null
        Charging  = $false
        TempC     = $null
        RawStatus = $null
    }

    try {
        Write-Log -Message "Querying battery status for device $DeviceId" -Level DEBUG

        $batteryInfo = & $adb -s $DeviceId shell dumpsys battery 2>$null

        if (-not $batteryInfo) {
            Write-Log -Message "No battery data returned by adb for $DeviceId" -Level WARNING
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

        Write-Log -Message "Battery status for $DeviceId : Level=$($result.Level)% Charging=$($result.Charging) Temp=$($result.TempC)C" -Level INFO
        return $result
    }
    catch {
        Write-Log -Message "Failed to retrieve battery status for $DeviceId : $($_.Exception.Message)" -Level ERROR
        return $null
    }
}




function Disconnect-ADBConnections {
    param (
        [Parameter()]
        [string]$adb = $Global:adbPath
    )
    try {
        if (-not (Test-Path $adb)) {
            throw "ADB executable not found at $adb"
        }
        
        & $adb disconnect
        Write-Log -Message "All ADB devices are now disconnected" -Level "INFO"
    }
    catch {
        Write-Log -Message "Failed to disconnect ADB devices: $_" -Level "ERROR"
        throw
    }
}

