@echo off
echo [Disconnecting old connections...]
bin\adb.exe disconnect

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