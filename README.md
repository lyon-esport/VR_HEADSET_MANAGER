# VR HEADSET MANAGER

## Overview

**VR HEADSET MANAGER** is a PowerShell-based automation tool designed to manage, monitor, and capture screens of **Meta Quest VR headsets** on flat screen using **ADB** and **scrcpy**.

It provides:
- 
- Automated wireless ADB activation
- Headset detection over local network (with developper mode and ADB Wifi already enabled)
- Scrcpy streaming with auto-restart
- Optional session recording
- Log management
- Graphic reporting of each headset with HTML generation for OBS integration
- CSV-based headset configuration management

The tool is intended for **VR labs, demo environments, training centers, and multi-headset deployments**.

I personally use it during showrooms and gaming exhibitions to capture the live video feeds from multiple headsets simultaneously. These video streams are then managed inside OBS to present visitors with a global, real-time view of all active VR experiences.

## Installation

1. **Place the project folder on your machine**  
   > Copy or clone the `VR_HEADSET_MANAGER` folder to your local computer.

2. **Run the launcher**  
   - :warning: Run as admin :warning: **START_VR_HEADSET_MANAGER.cmd** 
   > - This will start PowerShell with the correct execution policy and launch the manager.
   > - On first start it will automatically :  
   >   - add Windows Firewall exceptions to allow adb.exe to talk with headsets over the network.
   >   - add Windows Firewall exceptions to allow mediamtx to restream over the network.
   >   - add Windows Firewall exceptions to allow the programm to scan mdns headsets over the network.
   >   - create a config file from the template
   
3. **Add headset**
   > - Connect with USB your Meta Quest Headset (⚠️ Developper mode must be already enabled)
   > - In the [Headset Management Console], press **A** to add a headset
   > - Follow the instructions to add your headset (IP address, Firendly name...)
   > - Installation of [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) is proposed to start ADB Wifi from the headset without USB connection required.
   
5. **Press the key corresponding to the ID if the headset to start screen miroring (scrcpy) manually**

6. **Modify headset parameters**
   Use different options to manage you headsets. You can enable recording, enable the auto-restart of the screen miroring, etc...

7. **Modify VR HEADSET MANAGER parameters**
   You can adapt configuration in the ./config/config.json file following [this guide](/docs/config.md)
   Optionnally you can start the script with another custom config file by passing it as a parameter

---

## Prerequisites

Before using the tool, make sure the following requirements are met:
- ✅ This program folder must include **VR_HEADSET_MANAGER** in the name
- ✅ The Meta Quest headset must be in **Developer Mode**
- ✅ The Meta Quest headset must be connecter over WIFI, and reachable from the computer you execute the script
  *Note : To limit lacencies I recommand a dedicated WIFI SSID and channels for headsets only, and an ethernet connexion for the computer which is executing VR HEADSET MANAGER.*
- ✅ **ADB over WiFi must be enabled** on the headset >> [You can follow this process to enable it !](/docs/docs_HowToEnableADBWifi.md)

> [!IMPORTANT]
> Without these prerequisites, the headset will not be reachable over the network and scrcpy streaming will not work.

---

## Roadmap 🎯

### 🐞Known issues
- [ ] When stream auto restart is enabled, the headset stream starts sometimes 2 times if the fist stream didn't had time to start (duplicate scrcpy process)
- [ ] known_headsets.csv : Do not update correctly the serial number
- [ ] Bug on adding a headset from the IP address
	> Test every combination by adding/modifying/deleting headset...

### Improvements
#### 🏃Startup checks
- [ ] ⚠️ [TO TEST : KO] Keep the computer awake while the script is running to prevent screen lockout or hibernation.
- [x] [To validate] Firewall authorization for adb.exe on soft startup
- [ ] Setup powershell execution >> To test on fresh installed pc
- [ ] If no headset in the known headset file, propose to add it or search over the network (mdns scan ? usb ?)
- [x] Test if the app is not already running... If yes, warn the user and ask if he really wants to start it...

#### 🛠️ Backend
- [x] [IN TEST] include a json validator or tester (and warn config json is broken, and open a web page with json validator...) then propose to try reload or create a new file based on the template (overwrite existing file)
- [ ] :key: Save by a secured manner the Wifi Password with [Marshal](https://www.secureideas.com/blog/secure-password-management-in-powershell-best-practices) (ConvertTo-SecureString / ConvertFrom-SecureString)
- [ ] REST API to provide a web page to manage it from a phone, or by Stream Deck hitself ?


#### ⚙️ Headsets management (Headset Management Console)
- [ ] Review of Meta Quest configuration and ADB activation (by connecting with USB) for headsets that are not already known and configured in VR Heaset Manager
	> - Install config : Do you want to modify headset parameters ? Y/N and test it on a brand new headset
 		> - Test pushing parameters using ADB Wifi
 		> - Provide parameters customization for each headset using the HMC
	> - if headset has the same serial : update the IP in the known headsets (need to manage serial in known_headets.csv)
	> - If headset is connected to usb, propose to add it automatically...
 		> - If the headset is not connected to the right Wifi, let's propose to connect to...
    > - If not installed, propose to install oculus-wireless-adb
- [ ] Scan network process to review
  > mdns to test for a headset in developper mode enabled
  > check all devices availabiel with 5555 opened

#### 📺 VR Headset Screen capture
- [ ] Manage scrcpy profiles for each headse
  -  Save these parameters in known_headsets.csv (Left/right eye; audio duplicate or not ; bandwidth ; FPS ) [L/R]-[D/N]-45-20
  - Parameters in config.json defines only template parameters common parameters like crop, angle, video codec, video encoder and video buffer and stay awake for each headset type
  - Restart the current headset stream if template changed

#### 🎨 UI and Visual customization
- [ ] ⚠️ Add controllers battery level for OBS view
- [ ] - [ ] Web page to allow configuration and screen miroring visualization


#### 🧪 New functionalities

- [ ] ⚠️ [⛏️IN PROCESS] implement a local resteam functionality that allows to give access to the headset screen from any other computer or phone
  > [mediamtx](https://github.com/bluenviron/mediamtx)

- [ ] ⚠️ [⛏️IN PROCESS] Dev of a Stream deck plugin
  > - Manage communication with Stream Deck Plugin...
  > - [Named Pipe ?](https://rkeithhill.wordpress.com/2014/11/01/windows-powershell-and-named-pipes/)



- [ ] Detect while a new headset is connected on the USB port and propose to start adding process




### Code improvement
- [ ] Review all powershell code with PSScriptAnalyzer
- [x] [DONE] Translate all text (IHM + comments) in [EN] instead of [FR] - To do by IA... [like this](/docs/translation_fr.xml)
- [x] [DONE] Review adb_functions.ps1 to pass device adb object in parameter of all request functions, to allow either USB or Wifi ADB device (Get-HeadsetModel, Get-QuestControllerBatteryStatus, Get-HeadsetBatteryStatus...)
    Note : Implemented for ADB Wifi only, not for USB.

---

## Sources

This project is based on :
- [scrcpy project](https://github.com/Genymobile/scrcpy) for screen miroring
- [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) for enabling ADB over Wifi on Meta Quest VR headsets
- [Powershell Pode module](https://github.com/Badgerati/Pode) as web server
- [Powershell EPS module](https://github.com/straightdave/eps) as templating tool for editing values in web pages
- [MediaMTX : A real-time media server used for restream screen capture](https://github.com/bluenviron/mediamtx)
- [Emoji cheat sheet](https://github.com/ikatyang/emoji-cheat-sheet)

Streamdeck usefull plugins :
- [**Stream Countdown Timer**](https://marketplace.elgato.com/product/stream-countdown-timer-625838c6-85ce-4be7-a754-30f00c809b34) by [BarRaider](https://barraider.com/)
  - *[[FR]YT tutorial to use the timer in OBS](https://www.youtube.com/watch?v=vi4xlhSECeA)*
