@echo off
echo [Disconnecting old connections...]
bin\adb.exe disconnect

echo.
echo [Get attached devices...]
bin\adb.exe devices
for %%a in (*.apk) do (
	echo [Installing application %%a]
	bin\adb.exe install -r %%a
)

bin\adb.exe shell "settings put secure accessibility_enabled 1 && settings put secure enabled_accessibility_services com.anagan79.tcp5555/com.anagan79.tcp5555.services.AppChangeDetectionService && pm grant com.anagan79.tcp5555 android.permission.WRITE_SECURE_SETTINGS"

echo.
echo [Waiting for device to initialize...]
bin\adb.exe tcpip 5555
timeout 3

echo.
echo [Connecting to device with IP %ip%...]
FOR /F "tokens=2" %%G IN ('bin\adb.exe shell ip addr show wlan0 ^|find "inet "') DO set ipfull=%%G
FOR /F "tokens=1 delims=/" %%G in ("%ipfull%") DO set ip=%%G
bin\adb.exe connect %ip%
timeout 3