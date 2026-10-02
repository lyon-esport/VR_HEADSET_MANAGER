# Web interface tour

[← Back to documentation home](README.md)

The web interface is served by VR HEADSET MANAGER's built-in web server, enabled by default on port **8080** (changeable in the [configuration](configuration.md#webserver)). It is reachable from **any device on your LAN**:

```
http://<your-pc-ip>:8080
```

> [!NOTE]
> A few operations that need direct file access (like picking a local APK file to sideload) are only available when you browse from the computer running VRHM.

## Video Monitor (home page)

The live video wall. One tile per headset showing the real-time stream (WHEP/WebRTC, very low latency), with overlays for battery, controllers, charge status and the session timer.

![Video Monitor](pics/hero_video_monitor.png)

Top-bar controls:

- **Filters** — choose which headsets are displayed
- **Status** — toggle status overlays (battery, controllers, temperature)
- **Timer** — show/hide and control per-headset session timers
- **Wall view** (eye-slash icon) — hides the whole top bar and switches to a live-streams-only filter, so the page fills the window edge-to-edge for a lobby TV / showroom wall. A small restore control stays in the corner to bring the bar back. The state is reflected in the URL as `?hidetopbar=1`, so it can be bookmarked or pushed straight to a [kiosk screen](kiosk-screens.md#casting-a-headsets-video-feed-to-a-kiosk). Add `&nooverlay=1` to also suppress the status/timer overlays on every tile from the start (skips starting the per-headset timer polling too, for a lighter wall view) — e.g. `http://<pc-ip>:8080/?hidetopbar=1&nooverlay=1`.
- Per-tile **launch app** button (▶) — start an installed application inside the headset without touching it

Tiles of offline headsets show their last known status; the video reconnects automatically when the stream comes back.

## Monitoring

A status table of the whole fleet, refreshed live:

![Monitoring page](pics/web_monitoring.png)

- Per headset: ping / ADB (shown as **USB** or **WiFi**: the link in use) / scrcpy status, charging state and power draw (W), battery percentages (headset + left/right controllers), estimated remaining time, battery temperature, **CPU temperature** (hover for the last hour, click for the history graph, which also offers GPU and skin temperatures), model, and the **application currently running** in the headset
- **Computer statistics**: CPU, RAM, recording drive usage and type, per-GPU load/VRAM, and the workload of the capture processes (scrcpy, ffmpeg, PowerShell)
- When [Video Quality Automation](vqa.md) is enabled, its recommendation panel and auto-apply toggles appear on this page

## Headset Settings

One card per headset with every day-to-day control:

![Headset Settings](pics/web_headset_settings.png)

- Live status dots (PING / ADB / SCRCPY) and running app, with launch button
- **IP address**, model, **serial number**, and the assigned [capture profile](streaming.md#scrcpy-capture-profiles) — all editable
- **Auto-restart scrcpy** — keep the capture running automatically
- **Recording** — record the capture to disk ([details](streaming.md#recording))
- **Timer** — set and start a session countdown
- **Advanced Settings** (Configure) — brightness, guardian, proximity sensor, OTA update blocking, firmware info...
- **DIAG** — opens the [headset diagnostics page](#headset-diag)
- **Power** — reboot or shut the headset down remotely
- Top bar: **Manage New Devices** (add headsets — see [Getting started](getting-started.md#2-add-your-first-headset)), the **capture mode** selector (see [Streaming → capture modes](streaming.md#capture-modes)), and **Shutdown All**

![Manage New Devices dialog](pics/web_add_headset.png)
*Manage New Devices: USB detection with WiFi/ADB status checks, plus manual add by IP address.*

**Shutdown All** powers off every ADB-connected headset at once (with a confirmation dialog — it can optionally close the VRHM application too):

![Shutdown All confirmation](pics/web_shutdown.png)

## Headset DIAG

`headset_diag.html?id=<ID>`, opened from the **DIAG** button of a headset card. One page per headset, refreshed with the **Refresh** button and automatically every 30 s (`Diag.auto_refresh_sec`). Each card shows whether it was read over **USB** or **WiFi**.

- **Firmware** — OS version, system UI version, build, product, Meta components, pending OTA and its progress, updater package state, Private DNS, and the headset's firmware history (one row per change, recorded by the monitor every 10 minutes)
- **Fleet firmware** — every headset's last recorded firmware next to the newest one seen on the same model, flagging headsets that are **behind**. Built from the history only, no internet lookup
- **Health** — CPU / GPU / skin / battery / USB-port temperatures (click a tile for its history graph) and thermal throttling, battery health (learned vs design capacity), fan, CPU/GPU level, controllers (model, battery, firmware), top processes, memory, boot stage, clock drift against the PC, time zone, camera frame timeouts
- **Wireless** — SSID/BSSID, signal, band, WiFi standard, link speeds, saved networks, Meta server reachability, Bluetooth state and bonded devices
- **USB / cable** (only while the headset is plugged in) — link speed, recent Windows USB events and problem devices for Meta/PICO, and a **cable test** (32 MB push/pull passes)
- **Operator actions** — Bluetooth on/off, open Bluetooth settings in the headset (to pair haptic vests), clock sync (with the browser's time zone), Private DNS reset, disable/enable the updater package, list/disable/enable an app, send a message to the player (*experimental*), type text into the focused field, wake / Home / restart shell / restart SystemUX. Destructive actions ask for confirmation
- **ADB shell** — presets (`Diag.command_presets`) or free text. Shell commands only, every run is logged; bootloader, recovery, wipe, fastboot and `rm -rf /` are refused
- **ADB over TLS** (*experimental*) — reads and enables Android wireless debugging and tries the mDNS-advertised TLS port. Investigation only: the normal WiFi ADB setup is unchanged

The page runs one ADB call per card, one card after the other, so it never blocks the rest of the web interface for long.

## Config menu

### App Configuration

Edit the whole application configuration from the browser. Changes are saved automatically; most take effect immediately, streaming-related changes restart the affected services on the fly.

![App Configuration](pics/web_app_config.png)

Sections: General, WiFi Networks, Headset Capture Profiles, Headsets Monitoring & Alerts, Streaming & Recording, Video Quality Automation, Services & Network, Advanced/Internal. The **Edit config.json** button opens the raw file, and **Reset to Template** restores defaults. See the [Configuration reference](configuration.md).

### Headsets Apps (Application Manager)

Install, uninstall, update, and launch applications per headset — see the dedicated [Applications manager](apps-manager.md) page.

![Application Manager](pics/web_apps_manager.png)

### Known Apps

The shared catalog that maps Android package names to friendly display names and icons, fed by the [MetaMetadata](https://github.com/threethan/MetaMetadata) database:

![Known Apps manager](pics/web_known_apps.png)

See [Applications manager → Known apps catalog](apps-manager.md#known-apps-catalog).

### Help & Diagnostics

Service control and troubleshooting from the browser:

![Help & Diagnostics](pics/web_help_links.png)

- **Shutdown Application**, **Restart Web Server**, **Restart MediaMTX** (with live PIDs)
- **Stream Links — VLC & OBS**: ready-to-copy RTSP / HLS / WHEP URLs for every headset, with LIVE/OFFLINE badges — paste them straight into VLC or OBS ([more](streaming.md#stream-urls))
- The MediaMTX API endpoints for advanced diagnostics

### Timer control

A dedicated page to drive all session timers at once; the same functions are exposed by the [Timer API](docs_timer_api.md) for Stream Deck / OBS integration.

### Kiosk Screens

Remote-control browser displays on the LAN (lobby TVs, showroom monitors) — push a URL, cast a headset's live feed to a screen, or kill its browser. See the dedicated [Kiosk screens](kiosk-screens.md) page.
