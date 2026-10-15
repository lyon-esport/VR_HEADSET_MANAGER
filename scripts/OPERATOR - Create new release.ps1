cd 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER'

$NewVersion = "2026-10.RC1"


.\scripts\Create-ZipRelease.ps1 -Version $NewVersion -Unzip

.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder $("..\VR_HEADSET_MANAGER.v"+$NewVersion) -AutoApproveSetup -Mode Auto -Unattended


.\scripts\Measure-AppPerf.ps1 -DurationSec 30 -Label a
.\scripts\Measure-AppPerf.ps1 -DurationSec 30 -Label b -Compare ".\scripts\perf_reports\perf_20261013_232821.json"
.\scripts\Measure-AppPerf.ps1 -DurationSec 60 -Label loaded-4hs
.\scripts\Measure-AppPerf.ps1 -DurationSec 60 -Label loaded


.\scripts\Create-ZipRelease.ps1 -Version 2026-10.TEST8 -Unzip
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder ..\VR_HEADSET_MANAGER.v2026-10.TEST8 -AutoApproveSetup -Depth Standard -NoHeadset
