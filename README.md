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
   Copy or clone the `VR_HEADSET_MANAGER` folder to your local computer.

2. **Run the launcher**  
   Double-click on: **START_VR_HEADSET_MANAGER.cmd**
   This will start PowerShell with the correct execution policy and launch the manager.
   On first start it will automatically create Windows Firewall exceptions to allow adb.exe to talk with headsets over the network.

3. **Add headset**
   In the CONFIG PowerShell console, press **A** to add a headset
   Follow the instructions to add your headset (IP address, Firendly name...)
   
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

## Known issues

- Many... It's getting better days after days :-)

---

## Roadmap

- Dev of a Stream deck plugin
- Review of Meta Quest configuration and ADB activation (by connecting with USB) for headsets that are not already known and configured in VR Heaset Manager
- Web page to allow configuration and screen miroring visualization
- Review adb_functions.ps1 to pass device adb object in parameter of all request functions, to allow either USB or Wifi ADB device (Get-HeadsetModel, Get-QuestControllerBatteryStatus, Get-HeadsetBatteryStatus...)
- Many ideas...

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
