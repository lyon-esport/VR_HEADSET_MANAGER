# VR HEADSET MANAGER

## Overview

**VR HEADSET MANAGER** is a PowerShell-based automation tool designed to manage, monitor, and stream **Meta Quest VR headsets** on flat screen using **ADB** and **scrcpy**.

It provides:

- Automated wireless ADB activation
- Headset detection over local network
- One-click scrcpy streaming
- Optional session recording
- Log management
- OBS status file generation
- Firewall rule automation
- CSV-based headset configuration management

The tool is intended for **VR labs, demo environments, training centers, and multi-headset deployments**.

I personally use it during showrooms and gaming exhibitions to capture the live video feeds from multiple headsets simultaneously. These video streams are then managed inside OBS to present visitors with a global, real-time view of all active VR experiences.

## Installation

1. **Place the project folder on your machine**  
   > Copy or clone the `VR_HEADSET_MANAGER` folder to your local computer.

2. **Run the launcher**  
   > - Double-click on: **START_VR_HEADSET_MANAGER.cmd**
   > - This will start PowerShell with the correct execution policy and launch the manager.
   > - On first start it will automatically :  
   >   - add Windows Firewall exceptions to allow adb.exe to talk with headsets over the network.
   >   - create a config file from the template
   
3. **Add headset**
   > - In the CONFIG PowerShell console, press **A** to add a headset
   > - Follow the instructions to add your headset (IP address, Firendly name...)
   
4. **Press the number to start screen miroring (scrcpy) of the headset**

5. **Modify headset parameters**
   Use different options to manage you headsets. You can enable recording, enable the auto-restart of the screen miroring, etc...

---

## Prerequisites

Before using the tool, make sure the following requirements are met:

- ✅ The Meta Quest headset must be in **Developer Mode**
- ✅ The Meta Quest headset must be connecter over WIFI, and reachable from the computer you execute the script
  *Note : To limit lacencies I recommand a dedicated WIFI SSID and channels for headsets only, and an ethernet connexion for the computer which is executing VR HEADSET MANAGER.*
- ✅ **ADB over WiFi must be enabled** on the headset >> [You can follow this process to enable it !](/docs/docs_HowToEnableADBWifi.md)

Without these prerequisites, the headset will not be reachable over the network and scrcpy streaming will not work.

---

## Roadmap

### Known issues
- When stream auto restart is enabled, the headset stream starts 2 times (duplicate scrcpy process)


### Improvements
- On startup add following changes :
	> - Setup powershell execution >> To test on fresh installed pc
	> - Test if the app is not already running... If yes, warn the user and ask if he really wants to start it...
	> - Test if the computer have screen saver or auto lock screen
	>   - If ran as administrator : Propose to remove the parameters
	>   - If ran as a normal user : Warn the user
 	> - If no headset in the known headset file, propose to add it
 	>  - include a json validator or tester (and warn config json is broken, and open a web page with json validator...) then propose to try reload or create a new file based on the template (overwrite existing file)
- Review of Meta Quest configuration and ADB activation (by connecting with USB) for headsets that are not already known and configured in VR Heaset Manager
	> - Install config : Do you want to modify headset parameters ? Y/N and test it on a brand new headset
	> - if headset has the same serial : update the IP in the known headsets (need to manage serial in known_headets.csv)
	> - in headset is connected to usb, propose to add it automatically...
	> - If the headset is not connected to the right Wifi, let's propose to connect to...
- [To validate] Firewall authorization for adb.exe on soft startup

- Bug on adding a headset from the IP address
	> Tester every combination by adding/modifying/deleting headset...

- Save by a secured manner the Wifi Password with [Marshal](https://www.secureideas.com/blog/secure-password-management-in-powershell-best-practices) (ConvertTo-SecureString / ConvertFrom-SecureString)



### New functionalities
- Manage scrcpy profiles for each headset ; save these parameters in known_headsets.csv (Left/right eye; audio duplicate or not ; bandwidth ; FPS ) [L/R]-[D/N]-45-20
  - Parameters in config.json defines only basics parameters common parameters like crop, angle, video codec, video encoder and video buffer and stay awake
  - Restart the current headset stream if template changed
- [in process] Dev of a Stream deck plugin
  > - Manage communication with Stream Deck Plugin...
  > - [Named Pipe ?](https://rkeithhill.wordpress.com/2014/11/01/windows-powershell-and-named-pipes/)
  > - REST API to get a web page to manage it from a phone, or by Stream Deck hitself ?
- Add controllers battery level for OBS view
  > Check functions *Get-QuestControllerBatteryStatus* and *Get-HeadsetBatteryStatus*
- Web page to allow configuration and screen miroring visualization

### Code improvement
- Translate all text (IHM + comments) in [EN] instead of [FR] - To do by IA... [like this](/docs/translation_fr.xml)
- Review adb_functions.ps1 to pass device adb object in parameter of all request functions, to allow either USB or Wifi ADB device (Get-HeadsetModel, Get-QuestControllerBatteryStatus, Get-HeadsetBatteryStatus...)
- Review all powershell code with PSScriptAnalyzer


---

## Sources

This project is based on :
- [scrcpy project](https://github.com/Genymobile/scrcpy) for screen miroring
- [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) for enabling ADB over Wifi on Meta Quest VR headsets
- [Powershell Pode module](https://github.com/Badgerati/Pode) as web server
- [Powershell EPS module](https://github.com/straightdave/eps) as templating tool for editing values in web pages

Streamdeck usefull plugins :
- [**Stream Countdown Timer**](https://marketplace.elgato.com/product/stream-countdown-timer-625838c6-85ce-4be7-a754-30f00c809b34) by [BarRaider](https://barraider.com/)
  - *[[FR]YT tutorial to use the timer in OBS](https://www.youtube.com/watch?v=vi4xlhSECeA)*
