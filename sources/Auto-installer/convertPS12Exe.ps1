Install-Module -Name ps2exe -Scope CurrentUser

Import-Module ps2exe
set-location "L:\Drive partagés\04 Equipe Technique\20 VR\VR_HEADSET_MANAGER\"

Invoke-PS2EXE .\mon_script.ps1 .\mon_programme.exe