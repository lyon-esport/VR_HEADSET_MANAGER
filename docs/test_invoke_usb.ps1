$adb = "L:\Drive partages\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER\sources\scrcpy-win64-v3.3.4_patchedNoFlickering\adb.exe"
$global:adbPath         = $adb
$global:adbPort_default = 5555
$global:msg = @{
    UsbHeadsetConnected = "USB headset connected: '{0}' ({1})"
    UsbWifiAdbEnabled   = "WiFi ADB enabled for '{0}' at {1}:{2}"
    UsbHeadsetNoWifiIp  = "USB headset '{0}' has no WiFi IP - skipping wireless ADB."
    ErrorOccurred       = "Error: {0}"
}
function Write-Log { param([string]$Message,[string]$Level="INFO") Write-Host "[$Level] $Message" }

. "L:\Drive partages\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\DEV_VERSION\VR_HEADSET_MANAGER\modules\adb_functions.ps1"

Write-Host "`n=== adb devices output ===" -ForegroundColor Cyan
& $adb devices

Write-Host "`n=== Calling Invoke-UsbHeadsetActions ===" -ForegroundColor Cyan
$result = Invoke-UsbHeadsetActions

Write-Host "`n=== Result ===" -ForegroundColor Cyan
if ($null -eq $result) {
    Write-Host "null (no USB device detected)" -ForegroundColor Yellow
} else {
    $result | Format-List
}
