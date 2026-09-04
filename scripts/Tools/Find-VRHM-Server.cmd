@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Find-VRHM-Server.ps1" %*
echo.
pause
