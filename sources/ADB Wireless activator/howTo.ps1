<#
Manual reference notes - NOT executed by the application.
The app does all of this automatically via Install-OculusWirelessAdbApk
(modules\adb_functions.ps1). Kept here for manual recovery / debugging.

adb install app-debug.apk
adb shell pm grant tdg.oculuswirelessadb android.permission.WRITE_SECURE_SETTINGS
adb shell pm grant tdg.oculuswirelessadb android.permission.READ_LOGS
#>

#1 - Connect the headset with USB
#2 - Run these from the project root. adb.exe ships inside the active scrcpy
#    version folder (sources\scrcpy\scrcpy-win64-v<version>\), selected by
#    config.ADB.folder in config\config.json.

$adb = ".\sources\scrcpy\scrcpy-win64-v4.1\adb.exe"
$apk = ".\sources\ADB Wireless activator\tdg.oculuswirelessadb-1.3.apk"

& $adb install $apk
& $adb shell pm grant tdg.oculuswirelessadb android.permission.WRITE_SECURE_SETTINGS
& $adb shell pm grant tdg.oculuswirelessadb android.permission.READ_LOGS

& $adb tcpip 5555
& $adb shell am start -n tdg.oculuswirelessadb/.MainActivity
