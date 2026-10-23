# Troubleshooting & FAQ

[← Back to documentation home](../README.md#documentation)

## Where are the logs?

```
logs\<COMPUTERNAME>\log_<date>.txt
```

Increase verbosity in **Config → App Configuration → General** (`Logging.debugLevelToFile`, set to `DEBUG` while investigating). Logs older than 30 days are cleaned automatically. You can read any log from **Config → Help & Diagnostics → Live Logs** or the console **F** tile.

## Headset problems

### The headset shows PING KO / is unreachable

- Is the headset **awake**? A sleeping Quest drops off WiFi. (When it is captured, VRHM keeps it awake with `stay_awake`.)
- Is it on the **same network/VLAN** as the PC? Guest WiFi networks often isolate clients.
- Did its **IP address change**? VRHM usually corrects it by itself (network discovery, USB, TLS announcements — see [IP address changes](connecting-headsets.md#ip-address-changes)). Otherwise plug it in over USB for a few seconds, or edit the IP on its card in **Headset Settings**.

### PING OK but ADB KO

- ADB over WiFi is not (or no longer) enabled — classic WiFi ADB turns off at every headset reboot. Plug the headset in over USB for a few seconds (auto re-enable), and install the **ADB auto-enable app** so it comes back by itself: [Keeping WiFi ADB on after a reboot](connecting-headsets.md#keeping-wifi-adb-on-after-a-reboot).
- With TLS (Wireless debugging), the headset must be on the **same network segment** as the PC: its announcements (mDNS) do not cross VLANs. On another VLAN, use classic WiFi ADB.
- The ADB **authorization prompt** inside the headset was never accepted: put the headset on and accept "Allow USB debugging", ticking *Always allow*.

### The headset uses WiFi although it is cabled

- `ADB.prefer_usb` must be `true` (default). A capture already running over WiFi only moves to USB after the cable has been in for 10 s and when it is not recording (`scrcpy.usb_switch_mode`, see [USB first](connecting-headsets.md#usb-first-capturing-over-the-cable)).
- Accept the USB debugging prompt inside the headset: an unauthorized cable cannot be used.

### A headset appears in "Discovered devices" but I do not want it

Open **Discovered devices** and click **Forget**: it is never proposed again, even after an IP change. Adding it manually later cancels that.

### The headset is not detected over USB

- Developer Mode must be **enabled before** connecting ([Meta tutorial](https://developers.meta.com/horizon/documentation/native/android/mobile-device-setup/))
- Accept the USB debugging prompt inside the headset
- Try another cable/port — charge-only cables exist

## Streaming problems

### The scrcpy window is black or closes immediately

- Wake the headset up (put it on, or press a controller button)
- The headset may be showing content scrcpy cannot capture (some DRM-protected apps)
- Check the assigned capture profile: a crop for the wrong model produces a black/garbage image. Set the correct model and profile in **Headset Settings**.

### The stream does not appear in the browser / OBS

- Check the stream status on **Config → Help & Diagnostics → Stream Links** (LIVE/OFFLINE badge) and try the RTSP URL in VLC
- **Restart MediaMTX** from the same page
- If viewing from another device: the firewall rules may be missing — see below

### Video is choppy / laggy

- Prefer **Ethernet for the PC** and a dedicated WiFi SSID for headsets
- Lower the profile's fps/bitrate (e.g. `max-R-N-30-8` → `max-R-N-30-4`) or the `max_size` cap
- Check the **Monitoring** page's computer statistics: if CPU/GPU are saturated, let [Video Quality Automation](vqa.md) recommend reductions
- Many simultaneous viewers? Keep [re-encoding](streaming.md#ffmpeg-re-encoding-and-streaming-options) enabled (the default) to cap per-viewer bandwidth

### The Headset Toolbox does not find the server

Its scan only covers the networks of the PC it runs on. Choose the manual entry and type `ip`, `ip:port` (another port) or a URL. Allow `adb.exe` through the Windows Firewall if asked — it is only needed for WiFi ADB from that PC. See [`README-Toolbox.md`](../website/headset-toolbox/README-Toolbox.md#troubleshooting).

## Web interface problems

### The web page does not load from another device

The Windows Firewall rules may be missing or stale (they are created on first run for the *configured* ports). If you changed a port, VRHM rebuilds the rules at next startup — accept the admin prompt. You can verify rules containing `VR_HEADSET_MANAGER` in **Windows Defender Firewall → Advanced Settings**.

### A port is already in use at startup

VRHM detects it and offers to: use the next free port (saved to the config automatically), enter a port manually, or kill the process that owns it. See [Configuration → Ports summary](configuration.md#ports-summary).

## Other

### High CPU usage on the PC

- Accept the **Windows Defender exclusion** proposed at first run (real-time scanning of the video pipeline is expensive) — or add it later in Windows Security
- Enable [Video Quality Automation](vqa.md)
- Turn [re-encoding](streaming.md#ffmpeg-re-encoding-and-streaming-options) **off** (passthrough) if you do not need the per-viewer bandwidth cap — passthrough is nearly free for the CPU/GPU

### Recording refuses to enable / stopped by itself

The recording drive is under the free-space floor (`recordMinFreeSpaceGB`, default 5 GB). Free some space (**Recordings → Delete old recordings...**) or point `recordFolder` to another drive — see [Recordings](recordings.md) and [Configuration](configuration.md#headset-capture-profiles-scrcpy).

### A recording shows as "interrupted"

The session was cut abruptly (application or PC stopped). VRHM repairs the file in the background and marks it done; nothing to do. If it stays interrupted, the file is probably still in use or the drive is full — see the log.

### The recording preview does not start, or shows a black picture

- **"Preview needs ..." message instead of a player**: the preview goes through MediaMTX. Make sure MediaMTX is enabled and running (**Help & Diagnostics → Restart MediaMTX**) and that the capture mode is not **LocalWindow**. The list, timeline and downloads work in any case.
- **"Too many previews running"**: close the player in another tab, or raise `Recordings.playback.max_sessions`. An abandoned tab frees its preview by itself after `idle_timeout_sec` (30 s).
- **Black picture although the player runs**: check the recording itself - download it and open it in VLC. A headset that was asleep or showing nothing was recorded as black, and the preview faithfully shows it.
- **Choppy preview**: the preview never drops frames; it shows the frame rate the recording was made at. A recording made while the PC or headset was overloaded (or with a low-fps profile, or after [Video Quality Automation](vqa.md) lowered the fps) stays choppy.
- **A recording is missing from the list**: click **Rescan folder**. Files are only listed when they are in `<record folder>\<yyyy-MM-dd>\<headset>\`.

### My config.json is broken

At startup VRHM detects invalid JSON and offers **[R]** retry (after you fix it), **[T]** restore the template, or **[Q]** quit. From the web UI you can also use **Config → App Configuration → Reset to Template**.

### The application did not shut down cleanly

A watchdog (reaper) kills the child services (web server, MediaMTX, mDNS responder, orphan scrcpy) if the main process dies. If something survives anyway, check Task Manager for `mediamtx`, `scrcpy`, `ffmpeg` and PowerShell processes and end them.

## Still stuck?

Open an issue with your log file: [GitHub Issues](https://github.com/lyon-esport/VR_HEADSET_MANAGER/issues).
