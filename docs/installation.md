# Installation

[← Back to documentation home](README.md)

## Prerequisites

### Computer

- **Windows 10 or 11**
- Windows PowerShell 5.1 (built into Windows — nothing to install)
- The unzipped folder name must contain **`VR_HEADSET_MANAGER`** (the launcher checks this)
- Connected to the **same network** as the headsets — a **wired Ethernet connection is strongly recommended** for the PC

### Hardware sizing

Streaming VR headsets is demanding. As a baseline for **4 headsets**:

| Resource | Minimum |
|---|---|
| CPU | 4 cores |
| RAM | 16 GB |
| GPU | 2 GB dedicated VRAM |

The more headsets you capture — and the more viewers watch the restreams — the more resources you need. If the PC gets overloaded, [Video Quality Automation](vqa.md) can recommend or automatically apply resolution and bitrate reductions.

### Network

> [!TIP]
> To keep latency low, dedicate a WiFi SSID (and ideally a radio channel) to the headsets only, and connect the VRHM computer over Ethernet.

### Headsets

- The headset must be in **Developer Mode** ([official Meta tutorial](https://developers.meta.com/horizon/documentation/native/android/mobile-device-setup/))
- **ADB over WiFi** must be enabled — VRHM enables it automatically when you add a headset over USB, or you can use the bundled headset app: see [Enable ADB over WiFi](docs_HowToEnableADBWifi.md)
- The headset must be connected to WiFi and reachable from the PC

> [!IMPORTANT]
> Without these prerequisites the headset is not reachable over the network, and screen capture will not work.

## Install and first run

1. **Download** the [latest release](https://github.com/lyon-esport/VR_HEADSET_MANAGER/releases) and **unzip** it anywhere on your machine (keep `VR_HEADSET_MANAGER` in the folder name).

2. **Run `START_VR_HEADSET_MANAGER.cmd`** (double-click). It starts PowerShell with the correct execution policy and launches the manager.

> 📸 **SCREENSHOT TO ADD** — save as `docs/pics/console_first_start.png`
> *What to capture:* the PowerShell console right after the first launch of `START_VR_HEADSET_MANAGER.cmd`, showing the welcome banner, the first-run setup messages (firewall configuration), and the main menu with the web server URL displayed.

<!-- ![Console on first start](pics/console_first_start.png) -->

3. **First-run setup** happens automatically:

   - ⚠️ **A User Account Control (admin) prompt appears once.** It is used to run the initial computer setup:
     - Windows Firewall rules so `adb.exe` can talk to the headsets
     - Windows Firewall rules so MediaMTX can restream on the network
     - Windows Firewall rules for the web server and the mDNS headset scan
   - You are asked whether you want to **exclude the application folder from Windows Defender**. This is optional but recommended: real-time scanning of the video pipeline can cause high CPU usage.
   - The runtime configuration is created from the template (`config\config.json`).

4. **Open the web interface.** The web server starts automatically; its URL is printed in the console — by default:

   ```
   http://<your-pc-ip>:8080
   ```

   You can open it from the VRHM PC itself or from any device on the same LAN (some management features, like installing APK files, are only available when browsing from the VRHM PC itself).

5. Continue with [Getting started](getting-started.md) to add your first headset.

## Updating

1. Quit VR HEADSET MANAGER (`0` in the console, or **Config → Help & Diagnostics → Shutdown Application** in the web UI).
2. Unzip the new release into a **new folder**.
3. Copy your personal data from the old folder if you want to keep it:
   - `config\config.json` — your configuration
   - `data\` — headset registry, app caches, WiFi credentials
4. Start the new version.

## Uninstalling

VRHM does not install anything system-wide except the firewall rules and the URL reservation it created on first run. To remove it completely:

1. Delete the application folder.
2. Optionally remove the firewall rules: search for rules containing `VR_HEADSET_MANAGER` in **Windows Defender Firewall → Advanced Settings → Inbound Rules**.
3. Optionally remove the Windows Defender exclusion (**Windows Security → Virus & threat protection → Exclusions**) if you accepted it during setup.

---

Next: [Getting started →](getting-started.md)
