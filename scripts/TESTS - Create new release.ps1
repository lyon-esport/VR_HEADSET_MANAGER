# 0. Work from the project root
Set-Location -LiteralPath 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER'

# 1. Close the dev app first. The harness needs an exclusive run.

# 2. Optional: fast static checks before spending time on a release
.\scripts\Test-TranslationParity.ps1
.\scripts\dbTests\Invoke-DbTests.ps1 -Layer Static,Unit,Status,Headsets,Apps,Import,Failure,Kiosks,Perf

# 3. Build the release zip and extract it next to the project (REQUIRED before step 5)
.\scripts\Create-ZipRelease.ps1 -Version "2026.09_DEVDIAG1" -Unzip

# 4. Name the two test headsets (as they appear in data\known_headsets.csv)
$env:VRHM_TEST_USB_HEADSET  = 'Q3 BLUE'     # cabled to this PC over USB
$env:VRHM_TEST_WIFI_HEADSET = 'Q3 RED'    # reachable over WiFi ADB only

# 5. Run the harness against that release folder
$rel = Join-Path (Split-Path (Get-Location) -Parent) 'VR_HEADSET_MANAGER.2026.09_DEVDIAG1'
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder $rel -Sections 20,85 -Depth Standard


Set-Location -LiteralPath 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER'

# 1. Close the dev app. Keep Q3 BLUE plugged in over USB.

# 2. Build and extract the release
.\scripts\Create-ZipRelease.ps1 -Version "2026.10_DEVDIAG3" -Unzip

# 3. Run section 85 (plus 20 for the web pages)
$env:VRHM_TEST_USB_HEADSET = 'Q3 BLUE'
Remove-Item Env:VRHM_TEST_WIFI_HEADSET -ErrorAction SilentlyContinue
$rel = Join-Path (Split-Path (Get-Location) -Parent) 'VR_HEADSET_MANAGER.v2026.10_DEVDIAG3'
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder $rel -Sections 20,85 -Depth Standard





Set-Location -LiteralPath 'L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER'
$release = "2026.10_DEVDIAG5"

# Close the dev app first. Keep Q3 BLUE on USB and Q3 RED awake on WiFi.
.\scripts\Create-ZipRelease.ps1 -Version $release -Unzip

$env:VRHM_TEST_USB_HEADSET     = 'Q3 BLUE'
$env:VRHM_TEST_WIFI_HEADSET    = 'Q3 RED'
$env:VRHM_TEST_WIFI_HEADSET_IP = '192.168.1.244'

$rel = Join-Path (Split-Path (Get-Location) -Parent) $('VR_HEADSET_MANAGER.v'+$release)
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder $rel -Sections 20,85 -Depth Standard -AutoApproveSetup

--------

cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder "..\VR_HEADSET_MANAGER.v2026.10_DEVSSE1" -Mode Auto -Depth Full -Unattended -AutoApproveSetup

cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder "..\VR_HEADSET_MANAGER.v2026.10_DEVSSE3" -Mode Auto -Depth Full -Unattended -AutoApproveSetup

cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder "..\VR_HEADSET_MANAGER.v2026.10_DEVSSE4" -Mode Auto -Depth Full -Unattended -AutoApproveSetup


cd "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER"
.\scripts\Create-ZipRelease.ps1 -Version 2026.10_EYEMERGE1 -Unzip
# elevated PowerShell on the first boot of this new release:
.\scripts\Invoke-NonRegressionTests.ps1 -VRHMFolder "..\VR_HEADSET_MANAGER.v2026.10_EYEMERGE1" -AutoApproveSetup
