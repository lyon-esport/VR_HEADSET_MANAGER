# VRHM ADB WiFi — headset app

**VRHM ADB WiFi** is a small Android app for **Meta Quest 2 and Quest 3** that switches the headset to
**ADB over Wi-Fi** (classic `adb tcpip` mode) from inside the headset — no computer needed after a
one-time setup. It is the on-device equivalent of running `adb tcpip 5555`.

Source: [`android_adb_wifi/`](../android_adb_wifi)

## Features

| Setting | Default | What it does |
|---|---|---|
| **ADB TCP port** | `5555` | Port adbd listens on. Any port from 1024 to 65535; press **Enable** to apply a new one. |
| **Enable at application launch** | on | Enables ADB over Wi-Fi as soon as the app opens. |
| **Auto start on headset startup** | off | Enables ADB over Wi-Fi in the background when the headset boots (waits up to 2 min for Wi-Fi, 3 attempts). A notification shows the result. |
| **Auto hide the window once enabled** | off | Closes the window 1.5 s after an *automatic* activation (at launch or startup) succeeds. A manual press of **Enable** never hides it. |

The window shows the status, the `adb connect <ip>:<port>` command to use from your computer, a
**Disable** button (puts adbd back in USB-only mode) and a log.

## How it works

An Android app is not allowed to restart adbd itself, so the app talks to adbd with an embedded
`adb` client (the same approach as [oculus-wireless-adb](https://github.com/thedroidgeek/oculus-wireless-adb)):

1. If adbd already listens on the chosen port: nothing to do.
2. If adbd listens on another port (port changed in the app): connect to it and run `tcpip <new port>`.
3. Otherwise: turn on Android *wireless debugging* (needs `WRITE_SECURE_SETTINGS`), find its random
   TLS port with mDNS (only this headset's own advert is used, so it works in a room full of
   headsets), connect to it and run `tcpip <port>`.

Steps 2 and 3 need the embedded client to be **authorized once** by the headset — see setup below.

## Build

Open `android_adb_wifi/` in Android Studio (Ladybug or newer), or with the Android SDK installed:

```bash
cd android_adb_wifi
./gradlew assembleRelease        # gradlew.bat on Windows
```

The APK is `app/build/outputs/apk/release/app-release.apk` (signed with the debug key, for sideloading only).

## One-time setup (per headset, with a computer)

The headset must be in [Developer Mode](https://developers.meta.com/horizon/documentation/native/android/mobile-device-setup/)
and plugged in over USB.

```bash
# 1. Install
adb install -r app-release.apk

# 2. Allow the app to turn on wireless debugging (required to work without a computer)
adb shell pm grant com.vrheadsetmanager.adbwifi android.permission.WRITE_SECURE_SETTINGS

# 3. Optional - lets the window also open at headset startup
#    (without it, startup activation still runs in the background)
adb shell appops set com.vrheadsetmanager.adbwifi SYSTEM_ALERT_WINDOW allow

# 4. Authorize the app's embedded adb client: enable TCP mode once, then open the app
adb tcpip 5555
adb shell am start -n com.vrheadsetmanager.adbwifi/.MainActivity
```

At step 4, **put the headset on**: it asks *"Allow USB debugging?"* for the app's key — tick
**Always allow** and accept. The *Setup* section of the app then shows
"✔ Built-in adb client authorized". You can unplug the headset.

From now on, after every reboot, the app (opened by hand, or automatically with *Auto start on
headset startup*) brings ADB over Wi-Fi back on the chosen port by itself.

In the headset, the app is in **Library → Unknown sources**.

## Troubleshooting

| Message | Fix |
|---|---|
| `WRITE_SECURE_SETTINGS missing` | Run step 2 of the setup. |
| `Built-in adb client not authorized yet` | Run step 4 of the setup and accept the prompt with *Always allow*. If you revoked USB debugging authorizations in the headset, do it again. |
| `Wireless debugging port not found` | The headset must be on Wi-Fi. If the headset showed *"Allow wireless debugging on this network?"*, accept it (tick *Always allow on this network*) and press **Enable** again. |
| `USB debugging is off` | Developer mode / USB debugging was turned off on the headset. |
| Nothing happens at startup | *Auto start on headset startup* must be ticked and the app must have been opened at least once after install. Startup only runs after a full reboot, not when waking from sleep. |
