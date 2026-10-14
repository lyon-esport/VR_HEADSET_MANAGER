cd 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER'

$NewVersion = "2026-10.RC1"


.\scripts\Create-ZipRelease.ps1 -Version $NewVersion -Unzip

.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder $("..\VR_HEADSET_MANAGER.v"+$NewVersion) -AutoApproveSetup -Mode Auto -Unattended
