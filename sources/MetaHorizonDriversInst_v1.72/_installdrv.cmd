@echo off
@chcp 65001 >nul
@echo.
@echo.
@echo      Установка драйверов
@echo     ---------------------
@echo.
%windir%\System32\pnputil.exe /add-driver android_winusb.inf /subdirs /install
@echo.
@echo     ----------------------------------------------------
@echo     +++ Нажмите любую кнопку для закрытия этого окна +++
pause >nul
set "SELF_DIR=%~dp0"
start /min "" cmd /c "timeout /t 1 >nul & rd /s /q "%SELF_DIR%\""
exit
