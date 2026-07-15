# Troubleshooting & FAQ

[← Back to documentation home](README.md)

## Where are the logs?

```
logs\<COMPUTERNAME>\log_<date>.txt
```

Increase verbosity in **Config → App Configuration → General** (`Logging.debugLevelToFile`, set to `DEBUG` while investigating). Logs older than 30 days are cleaned automatically.

## Headset problems

### The headset shows PING KO / is unreachable

- Is the headset **awake**? A sleeping Quest drops off WiFi. (When it is captured, VRHM keeps it awake with `stay_awake`.)
- Is it on the **same network/VLAN** as the PC? Guest WiFi networks often isolate clients.
- Did its **IP address change**? Check headset Settings → WiFi and update the IP on its card in **Headset Settings**, or re-add via USB (VRHM recognizes the serial and heals the IP automatically).

### PING OK but ADB KO

- ADB over WiFi is not (or no longer) enabled — it turns off at every reboot on some firmwares. Plug the headset in over USB once (auto re-enable), or use the in-headset app: [Enable ADB over WiFi](docs_HowToEnableADBWifi.md).
- The ADB **authorization prompt** inside the headset was never accepted: put the headset on and accept "Allow USB debugging", ticking *Always allow*.

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
- Many simultaneous viewers? Enable [re-encoding](streaming.md#re-encoding-bandwidth-control) to cap per-viewer bandwidth

## Web interface problems

### The web page does not load from another device

The Windows Firewall rules may be missing or stale (they are created on first run for the *configured* ports). If you changed a port, VRHM rebuilds the rules at next startup — accept the admin prompt. You can verify rules containing `VR_HEADSET_MANAGER` in **Windows Defender Firewall → Advanced Settings**.

### A port is already in use at startup

VRHM detects it and offers to: use the next free port (saved to the config automatically), enter a port manually, or kill the process that owns it. See [Configuration → Ports summary](configuration.md#ports-summary).

## Other

### High CPU usage on the PC

- Accept the **Windows Defender exclusion** proposed at first run (real-time scanning of the video pipeline is expensive) — or add it later in Windows Security
- Enable [Video Quality Automation](vqa.md)
- Keep re-encoding **off** unless you need the bandwidth cap (passthrough is nearly free)

### Recording refuses to enable / stopped by itself

The recording drive is under the free-space floor (`recordMinFreeSpaceGB`, default 5 GB). Free some space or point `recordFolder` to another drive — see [Configuration](configuration.md#headset-capture-profiles-scrcpy).

### My config.json is broken

At startup VRHM detects invalid JSON and offers **[R]** retry (after you fix it), **[T]** restore the template, or **[Q]** quit. From the web UI you can also use **Config → App Configuration → Reset to Template**.

### The application did not shut down cleanly

A watchdog (reaper) kills the child services (web server, MediaMTX, dashboard, orphan scrcpy) if the main process dies. If something survives anyway, check Task Manager for `mediamtx`, `scrcpy`, `ffmpeg` and PowerShell processes and end them.

## Still stuck?

Open an issue with your log file: [GitHub Issues](https://github.com/lyon-esport/VR_HEADSET_MANAGER/issues).
