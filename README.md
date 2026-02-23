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
  _Note : To limit lacencies I recommand a dedicated WIFI network and channels for headsets, and an ethernet connexion for the computer which is executing VR HEADSET MANAGER.
- ✅ **ADB over WiFi must be enabled** on the headset  
  _TODO: A dedicated article will explain how to enable ADB WiFi properly. The app [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) is available in **_sources\ADB Wireless activator**

Without these prerequisites, the headset will not be reachable over the network and scrcpy streaming will not work.

---

## Known issues

- Many... It's getting better days after days :-)

---

## Roadmap

- Dev of a Stream deck plugin
- Review of Meta Quest configuration and ADB activation (by connecting with USB) for headsets that are not already known and configured in VR Heaset Manager
- Web page to allow configuration and screen miroring visualization
- Many ideas...

---

## Sources

This project is based on :
- [scrcpy project](https://github.com/Genymobile/scrcpy) for screen miroring
- [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) for enabling ADB over Wifi on Meta Quest VR headsets
- [Powershell Pode module](https://github.com/Badgerati/Pode) as web server
- [Powershell EPS module](https://github.com/straightdave/eps) as templating tool for editing values in web pages
