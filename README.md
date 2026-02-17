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
   On first start it will automatically create Windows Firewall exceptions to allow adb.exe to call with headsets over the network.

3. **Add headset**
   In the PowerShell console, press **A** to add a headset

4. **Press the number to start scrcpy of the headset**

---

## Prerequisites

Before using the tool, make sure the following requirements are met:

- ✅ The Meta Quest headset must be in **Developer Mode**
- ✅ The Meta Quest headset must be connecter over WIFI, and reachable from the computer you execute the script
  _Note : To limit lacencies I recommand a dedicated WIFI network and channels for headsets, and an ethernet connexion for the computer which is executing VR HEADSET MANAGER.
- ✅ **ADB over WiFi must be enabled** on the headset  
  _TODO: A dedicated article will explain how to enable ADB WiFi properly. The app [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb) is available in **_sources\ADB Wireless activator**

Without these prerequisites, the headset will not be reachable over the network and scrcpy streaming will not work.

   

