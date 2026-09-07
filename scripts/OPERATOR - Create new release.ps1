cd 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER\scripts'


.\Create-ZipRelease.ps1 -Version "2026-09.RC1" -Unzip

.\Invoke-NonRegressionTests.ps1 -Version "2026-09.RC1"


