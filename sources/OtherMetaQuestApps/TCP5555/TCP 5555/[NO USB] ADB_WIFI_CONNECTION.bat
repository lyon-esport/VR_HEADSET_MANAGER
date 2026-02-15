@echo off
:: /////////////////////////////////////////////
set IP=192.168.1.16
:: /////////////////////////////////////////////

echo [Retrieving IP and PORT...]
bin\nmap.exe %IP% -p 30000-49999 --defeat-rst-ratelimit | bin\awk.exe "/tcp open/{print $1}" | bin\awk.exe "{split($0,a, \"/\"); print a[1]}" > temp.txt
set /p PORT=<temp.txt
del temp.txt

echo --
echo [Disconnecting old connections...]
bin\adb.exe disconnect
timeout 1

echo --
echo [Establishing wireless connection...]
bin\adb.exe connect %IP%:%PORT%
timeout 2

bin\adb.exe tcpip 5555
timeout 3