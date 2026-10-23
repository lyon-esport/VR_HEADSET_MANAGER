cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"


.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST25 -Unzip
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST25 -Depth Full -AutoApproveSetup


cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
powershell -NoProfile -ExecutionPolicy Bypass -File .\docs\improvement_plan\tasks\S3-5B_parallel_start_test.ps1 -Names 'Q2 Dragon','Q3 BLUE' -Repeat 3

powershell -NoProfile -ExecutionPolicy Bypass -File .\docs\improvement_plan\tasks\S3-5B_parallel_start_test.ps1 -Names 'Q2 Dragon','Q3 BLUE' -Repeat 3



.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST26 -Unzip
$env:VRHM_TEST_USB_HEADSET  = 'Q2 Dragon'
$env:VRHM_TEST_WIFI_HEADSET = 'Q3 BLUE'
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST26 -AutoApproveSetup -Depth Full -HeadsetName 'Q3 BLUE' -Unattended -ShutdownHeadsetsAtEnd

.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST27 -Unzip
$env:VRHM_TEST_USB_HEADSET='Q2 Dragon'; $env:VRHM_TEST_WIFI_HEADSET='Q3 BLUE'
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST27 -AutoApproveSetup -Depth Full -HeadsetName 'Q3 BLUE' -Unattended


cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
.\scripts\Test-AdbWifiModes.ps1
.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST28 -Unzip
# Elevated PowerShell (first boot of a fresh release):
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST28 -Depth Full -AutoApproveSetup


TEST USB cut from software
& C:\Users\Crazy\AppData\Local\Temp\claude\l--Drive-partag-s-04-Equipe-Technique-20-VR-VR-HEADSET-MANAGER-DEV-VERSION-VR-HEADSET-MANAGER\5c9bf98b-2afc-44af-b219-735622f67bba\scratchpad\Test-UsbSoftCut.ps1



.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST29 -Unzip
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST29 -AutoApproveSetup -Sections 50,60,85



cd 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER'
.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST30 -Unzip
# check the zip holds the APK, the icon and adb_wifi_modes.ps1
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path '..\VR_HEADSET_MANAGER.v2026-10.TEST30.zip').Path)
$z.Entries | Where-Object { $_.FullName -match 'adbautoenable|adb_wifi_modes' } | Select-Object FullName
$z.Dispose()
# optional, for the hardware test in section 86:
# $env:VRHM_TEST_TLS_HEADSET = '<name>'
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder '..\VR_HEADSET_MANAGER.v2026-10.TEST30' -Depth Full -AutoApproveSetup


.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST30 -AutoApproveSetup -Sections 86 -Unattended
