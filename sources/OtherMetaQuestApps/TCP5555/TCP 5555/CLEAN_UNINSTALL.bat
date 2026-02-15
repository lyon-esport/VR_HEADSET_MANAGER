@echo off
echo [Disconnecting old connections...]
bin\adb.exe disconnect

echo.
echo [Get attached devices...]
bin\adb.exe devices
bin\adb.exe uninstall com.anagan79.tcp5555