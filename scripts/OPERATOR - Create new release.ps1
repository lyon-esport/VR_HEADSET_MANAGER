cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"


.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST25 -Unzip
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST25 -Depth Full -AutoApproveSetup


cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
powershell -NoProfile -ExecutionPolicy Bypass -File .\docs\improvement_plan\tasks\S3-5B_parallel_start_test.ps1 -Names 'Q2 Dragon','Q3 BLUE' -Repeat 3

powershell -NoProfile -ExecutionPolicy Bypass -File .\docs\improvement_plan\tasks\S3-5B_parallel_start_test.ps1 -Names 'Q2 Dragon','Q3 BLUE' -Repeat 3
