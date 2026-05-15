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
   - :warning: Run as admin on the first time :warning: **START_VR_HEADSET_MANAGER.cmd** 
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
   
4. **Press the key corresponding to the ID if the headset to start screen miroring (scrcpy) manually**

5. **Modify headset parameters**
   - Use different options to manage you headsets. You can enable recording, enable the auto-restart of the screen miroring, etc...

6. **Modify VR HEADSET MANAGER parameters**
   - You can adapt configuration in the ./config/config.json file following [this guide](/docs/docs_config.md)
   - Optionnally you can start the script with another custom config file by passing it as a parameter
   - Control per-headset timers from any external tool (Stream Deck, OBS, curl...) using the [Timer API](/docs/docs_timer_api.md)

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

### Improvements
#### 🏃Startup checks
- [ ] ⚠️ [🔄 TO TEST : KO] Keep the computer awake while the script is running to prevent screen lockout or hibernation.
- [x] [🔄 To validate] Firewall authorization for adb.exe on soft startup
- [ ] Setup powershell execution >> To test on fresh installed pc
- [ ] If no headset in the known headset file, propose to add it or search over the network (mdns scan ? usb ?)
- [ ] Check available json config files in /config folder, and propose to select the right one if any

#### 🛠️ Backend
- [x] [🔄 IN TEST] include a json validator or tester (and warn config json is broken, and open a web page with json validator...) then propose to try reload or create a new file based on the template (overwrite existing file)
- [ ] :key: Save by a secured manner the Wifi Password with [Marshal](https://www.secureideas.com/blog/secure-password-management-in-powershell-best-practices) (ConvertTo-SecureString / ConvertFrom-SecureString)
- [ ] REST API to provide a web page to manage it from a phone, or by Stream Deck (already done for timers)


#### ⚙️ Headsets management (Headset Management Console)
- [ ] Review of Meta Quest configuration and ADB activation (by connecting with USB) for headsets that are not already known and configured in VR Heaset Manager
	> - Install config : Do you want to modify headset parameters ? Y/N and test it on a brand new headset
 		> - Test pushing parameters using ADB Wifi
 		> - Provide parameters customization for each headset using the HMC
- [ ] Scan network process to review
  > mdns to test for a headset in developper mode enabled
  > check all devices availabiel with 5555 opened

#### 📺 VR Headset Screen capture


#### 🎨 UI and Visual customization

#### Headset info scrapping and interaction
- [ ] Force the screen to get out of the game and switch to passthrough mode
- [ ] Force recenter

#### 🧪 New functionalities

- [ ] ⚠️ [⛏️ IN PROCESS] Dev of a Stream deck plugin
  > - Manage communication with Stream Deck Plugin...
  > - [Named Pipe ?](https://rkeithhill.wordpress.com/2014/11/01/windows-powershell-and-named-pipes/)

#### Translations
- [x] [DONE] Translate all text (IHM + comments) in [EN] instead of [FR] - To do by IA... [like this](/docs/translation_fr.xml)
- [ ] Translation of the website

### Code improvement
- [ ] Review all powershell code with PSScriptAnalyzer and claude code...

---

## Sources

This project is based on :
- [scrcpy project](https://github.com/Genymobile/scrcpy) for screen miroring
- [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) for enabling ADB over Wifi on Meta Quest VR headsets
- [MetaMetadata : THE database that links package name to app name and related icons](https://github.com/threethan/MetaMetadata)
- [Powershell Pode module](https://github.com/Badgerati/Pode) as web server
- [Powershell EPS module](https://github.com/straightdave/eps) as templating tool for editing values in web pages
- [MediaMTX : A real-time media server used for restream screen capture](https://github.com/bluenviron/mediamtx)
- [Emoji cheat sheet](https://github.com/ikatyang/emoji-cheat-sheet)

Streamdeck usefull plugins :
- [**Stream Countdown Timer**](https://marketplace.elgato.com/product/stream-countdown-timer-625838c6-85ce-4be7-a754-30f00c809b34) by [BarRaider](https://barraider.com/)
  - *[[FR]YT tutorial to use the timer in OBS](https://www.youtube.com/watch?v=vi4xlhSECeA)*
