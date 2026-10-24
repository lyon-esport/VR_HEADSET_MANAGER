@echo off
REM Lance PowerShell (Windows PowerShell). Extra arguments (e.g. -AutoApprove) go to main.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0main.ps1" %*
