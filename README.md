# VR HEADSET MANAGER

## Overview

**VR HEADSET MANAGER** is a PowerShell-based automation tool designed to manage, monitor, and capture screens of **Meta Quest VR headsets** on flat screen using **ADB** over wifi and [**scrcpy**](https://github.com/Genymobile/scrcpy).

It has been developped exclusively to manage Meta Quests headsets (Quest 2 and Quest 3), but should work for many more headsets based on Android (as it's using ADB Wifi).

Please contact me if you need to add support of a new headset model/brands. If you wana offer me a different headset, i'll be pleased to support it in a next realase :laughing:.

It provides:
- Headsets screen capture (thanks scrcpy) with auto-restart and streaming over a web page, WHEP, RTSP or HLS
- Optional screen capture session recording
- Web page to manage headsets, display screen captures with extra low latency
- Graphic reporting of each headset (headsets and controllers batteries, charge status, temperature), with HTML generation for OBS integration
- Timer for each headset (for limiting gaming sessions for players)
- Automated wireless ADB activation while connecting the headset to the computer with USB
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

4. **Open the web page**
   > - The webserver is automatically started once the application is running.
   > - Let's open the web page - the link is provided on the main console - by default : **http://<your_server_ip>:8080**
   
4. **Add headset**
   > - Connect with USB your Meta Quest Headset (⚠️ Developper mode must be already enabled)
   > - In the web server go to the tab [CONFIG] >> Manage New Devices
   OR
   > - In the [Headset Management Console], press **A** to add a headset
   > - Follow the instructions to add your headset (IP address, Firendly name...)
   > - Installation of [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) is proposed to start ADB Wifi from the headset without USB connection required.
   
5. **in CLI, press the key corresponding to the ID if the headset to start screen miroring (scrcpy) manually**
5. **in Web server, enable Auto-restart scrcpy to start screen capture automatically when the headset is available**
   
6. **Modify headset parameters**
   - Use different options to manage you headsets. You can enable recording, enable the auto-restart of the screen miroring, etc...

7. **Modify VR HEADSET MANAGER parameters**
   - Use the web server to adapt parameters as you want.
   - You can adapt configuration in the ./config/config.json file following [this guide](/docs/docs_config.md)
   - Optionnally you can start the script with another custom config file by passing it as a parameter
   - Control per-headset timers from any external tool (Stream Deck, OBS, curl...) using the [Timer API](/docs/docs_timer_api.md)

---

## Prerequisites

Before using the tool, make sure the following requirements are met:
- ✅ This program folder must include **VR_HEADSET_MANAGER** in the name
- ✅ The Meta Quest headset must be in **Developer Mode**
- ✅ The Meta Quest headset must be connected over WIFI, and reachable from the computer where you execute the script
  *Note : To limit lacencies I recommand a dedicated WIFI SSID and channels for headsets only, and an ethernet connexion for the computer which is executing VR HEADSET MANAGER.*
- ✅ **ADB over WiFi must be enabled** on the headset >> [You can follow this process to enable it !](/docs/docs_HowToEnableADBWifi.md)

> [!IMPORTANT]
> Without these prerequisites, the headset will not be reachable over the network and scrcpy streaming will not work.

---
## WEBSITE & API
A dedicated website is available to manage your heasets and handle many options in addition of the CLI.
I recommand to use the web interface to interract with your headsets as I added many functionalities (like headsets applications management and launcher).

The web server is enabled by default to port 8080. This port can be modified in the config.json file.

---
## HEADSETS VIDEO CAPURE AND RESTREAM


---
## Roadmap 🎯

### 🐞Known issues
- At the moment it seems stable, let's report issues using Github Issues section

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

#### 📚 Translations
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
