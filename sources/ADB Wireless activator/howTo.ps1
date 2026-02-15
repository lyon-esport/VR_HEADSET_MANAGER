<#
adb install app-debug.apk
adb shell pm grant tdg.oculuswirelessadb android.permission.WRITE_SECURE_SETTINGS
adb shell pm grant tdg.oculuswirelessadb android.permission.READ_LOGS
#>

#1 - Connect the headset with USB
cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\sources\scrcpy-win64-v3.3.3"

.\adb.exe install "C:\Users\Crazy\Documents\Scripts\Quest screen miroring Streaming\ADB Wireless activator\tdg.oculuswirelessadb-1.2.apk"
.\adb.exe shell pm grant tdg.oculuswirelessadb android.permission.WRITE_SECURE_SETTINGS
.\adb.exe shell pm grant tdg.oculuswirelessadb android.permission.READ_LOGS

.\adb.exe tcpip 5555
.\adb.exe shell am start -n tdg.oculuswirelessadb/.MainActivity