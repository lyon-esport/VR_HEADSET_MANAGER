# Kiosk Screens

[← Back to documentation home](README.md)

**Kiosk Screens** lets you remote-control any PC that's displaying a browser on-screen (a lobby TV, a showroom monitor, a second display at a booth) directly from VR HEADSET MANAGER: push a URL to it, cast a headset's live video feed to it, or stop its kiosk session - all without touching that PC. It reuses the same restreaming pipeline as the [Video Monitor](web-interface.md#video-monitor-home-page): any kiosk screen can be pushed the live WHEP feed of a headset, so it works as a lightweight "cast to a wall-mounted display" feature.

Under the hood it talks to Google Chrome / Chromium's **remote debugging protocol (CDP)** — it does not install anything on the kiosk PC. You only need a small helper script running there to launch the browser with debugging enabled.

## How it works

1. A **kiosk launcher script** runs on the target PC (Windows or Linux) and opens Chrome/Chromium in kiosk mode with CDP remote debugging enabled on a port (default `9222`).
2. VRHM discovers or is told the kiosk's IP address and registers it in `data\known_kiosks.csv`.
3. From the **Kiosk Screens** page (or the console `[K]` menu), you push any URL to one or more registered kiosks — VRHM sends a `Page.navigate` command over CDP, and Chrome switches page instantly, live, no interaction needed on the kiosk itself.
4. VRHM also polls each kiosk (ping + CDP) to show whether it's online and what URL is actually on screen right now — which can differ from the last URL you pushed if the kiosk PC or its browser restarted since.

## 1. Set up the kiosk PC

Quick start for a Windows kiosk:

1. Open **Kiosk Screens -> Add kiosk device -> Setup Scripts**.
2. Download `Start-Kiosk-ADVANCED.exe` and run it on the kiosk PC - a single file, no unzip step. It finds the VRHM server on the network automatically.
3. Back in VRHM, use **Add kiosk device -> Scan network** or add the kiosk IP manually, then push a headset or URL.

Advanced is recommended for normal use. It reports the kiosk device information, restarts Chrome if it crashes, and receives reboot/shutdown/session-stop commands. Basic is the fallback when you only need URL casting.

Download the launcher for the kiosk's OS from the **Kiosk Screens** page (**Download kiosk launcher** button) or grab it directly from `website\kiosk-launcher\` in the VRHM install:

| Script | Platform |
|---|---|
| `Start-Kiosk-ADVANCED.exe` | Windows advanced launcher, standalone single-file build of `Start-KioskAgent.ps1` below - the easiest way to set up a Windows kiosk |
| `Start-KioskAgent.ps1` | Windows advanced launcher with reporting and power/session control |
| `Start-KioskAgent-Linux.sh` | Debian / Raspberry Pi OS advanced launcher with reporting and power/session control |
| `Start-KioskChrome.ps1` | Windows (any PC with Google Chrome installed) |
| `Start-KioskChrome-Linux.sh` | Debian / Raspberry Pi OS (Raspbian) with Chromium |

Copy the file matching the kiosk's OS onto that PC and run it there — it's fully standalone and does not need any other VRHM file.

```powershell
# Windows - double-click also works, it self-elevates and shows a UAC prompt
.\Start-KioskChrome.ps1
.\Start-KioskChrome.ps1 -Url "https://example.com" -Port 9222
```

```bash
# Linux - run as your normal desktop user inside the kiosk's own graphical session
chmod +x Start-KioskChrome-Linux.sh
./Start-KioskChrome-Linux.sh
./Start-KioskChrome-Linux.sh "https://example.com" 9222
```

The script opens the firewall for the debug port, launches the browser in kiosk mode, and verifies the debug port is actually reachable from the LAN — automatically setting up an OS-level port relay if Chrome refuses to bind anything but loopback (a deliberate Chrome security restriction; see the full explanation and troubleshooting steps in [`website/kiosk-launcher/README-KioskChrome.md`](../website/kiosk-launcher/README-KioskChrome.md)).

Security note: Chrome DevTools Protocol can control the kiosk browser. Only expose the debug port on a trusted lab/showroom LAN, never on public Wi-Fi or an internet-routed network. The launcher opens the local firewall for the selected debug port because VRHM needs to reach Chrome from the server.

For an always-on kiosk, set the script to run on boot (autostart entry on Windows/Task Scheduler, or a `~/.config/autostart/*.desktop` file on Raspberry Pi OS) — see the README above for a ready-to-use example and the passwordless-`sudo` setup needed for unattended boots on Linux.

## 2. Register the kiosk in VRHM

Open **Config → Kiosk Screens** (or press **`[K]`** from the console main menu), then either:

- **Add kiosk device → Add manually** — enter the kiosk's IP, an optional friendly name (defaults to the IP), and its debug port (default `9222`)
- **Add kiosk device → Scan network** — pick a local network interface, scan its subnet for open CDP ports, and add the ones found

![Add kiosk device dialog](pics/web_kiosk_add.png)

Each registered kiosk is stored in `data\known_kiosks.csv` (`ID, Name, IPAddress, Port, PushedURL, LastPushedAt`).

## 3. Push a URL

![Kiosk Screens page](pics/web_kiosk_screens.png)

On the **Kiosk Screens** page: tick one or more screens in the table, then either paste a URL into the box and click **Push to selected screens**, or use the **Select headset to cast...** dropdown above it to push a headset's own video feed (or the whole fleet) instead — see [Casting a headset's video feed to a kiosk](#casting-a-headsets-video-feed-to-a-kiosk) below. VRHM sends `Page.navigate` to each selected kiosk's active Chrome tab immediately — no reload delay, no interaction needed on the kiosk PC.

- If the URL points at `localhost` / `127.0.0.1`, VRHM detects that it would resolve to the kiosk PC itself (not the VRHM server) and offers to replace it with the server's real LAN IP before pushing — confirm the suggestion to proceed.
- **Stop kiosk session** closes Chrome on the selected kiosk(s). For an advanced kiosk, VRHM sends an agent command that closes Chrome and stops the agent so the watchdog does not reopen the browser. For a basic kiosk, VRHM closes Chrome via CDP `Browser.close`; you'll need to relaunch it manually on that PC.
- For streaming a clean feed of the pushed page into Twitch or similar, the page links to [pwn.sh/tools/getstream.html](https://pwn.sh/tools/getstream.html) to strip page chrome from the capture.
- Selecting a headset (or the wall option) from the dropdown greys out the manual URL box, and vice versa — typing in the URL box resets the dropdown. The **Subtitles (YouTube links only)** row only appears once the pasted URL is recognized as a YouTube link (watch/playlist/shorts/`youtu.be`).

The table shows, per kiosk: current reachability (ping + CDP open), latency, and the pushed URL / last-pushed timestamp. Name, IP address, and port are editable inline (pencil icon); the **×** button removes a kiosk from the registry.

Kiosk actions are also logged server-side in `logs\<COMPUTERNAME>\kiosk_<date>.log`: add/edit/remove, scans, URL pushes, localhost replacements, power commands, session stops, and meaningful advanced-agent state changes. The log is intended for kiosk troubleshooting and avoids full raw agent payloads.

## Casting a headset's video feed to a kiosk

There are two equivalent ways to push a headset's live video feed to a kiosk screen:

- **From Kiosk Screens** — pick the headset by name from the **Select headset to cast...** dropdown in the push panel (see [Push a URL](#3-push-a-url) above). This is the quickest path when you're already managing kiosks and want to send a specific headset's feed without leaving the page.
- **From the Video Monitor** — any headset tile on the [Video Monitor](web-interface.md#video-monitor-home-page) page (and the standalone `[video].html` player) has a **cast** button that opens a **Cast to kiosk screen** popover, pre-filled with that headset's own live video URL:

![Cast to kiosk screen popover](pics/web_cast_to_kiosk.png)

1. Tick one or more kiosk screens (or, on Kiosk Screens, select the headset from the dropdown and the screens in the table)
2. Optionally untick **display monitor + timer overlay** (checked by default) to push a clean video feed without the battery/controller/timer HUD — this appends `?nooverlay=1` to the pushed URL, which the video player page reads to skip auto-showing those overlays (they remain toggleable by hand once pushed, via the same on-screen buttons)
3. Click **Push to kiosk screens** (or **Push to selected screens** on Kiosk Screens)

This is the fastest way to put a specific headset's feed on a lobby TV or showroom display: the kiosk shows exactly what the operator sees in that tile, live.

### Casting the whole fleet as a wall

Instead of picking one headset, the Kiosk Screens dropdown also offers **All headsets in a wall**, which pushes the [Video Monitor](web-interface.md#video-monitor-home-page) page itself in [wall view](web-interface.md#video-monitor-home-page) (`http://<pc-ip>:8080/?hidetopbar=1`) — a full-window grid of every headset's live feed, with the top bar hidden. The same **display monitor + timer overlay** checkbox applies here too: unticking it appends `&nooverlay=1`, which suppresses every tile's status/timer HUD from the start instead of just hiding the top bar.

## Console equivalent

The same operations are available from the console main menu under **`[K]` Kiosk Screens**, without opening a browser: list kiosks with live status, `[A]` add manually, `[S]` scan network, then select a row by number for **`[P]` push URL**, **`[E]` edit**, **`[I]` advanced-device info**, **`[R]` reboot**, **`[H]` shutdown**, or **`[D]` delete**. Pushing a URL from the console goes through the same localhost-detection prompt as the web UI.

## Troubleshooting

If a kiosk shows as unreachable or push fails, see the dedicated troubleshooting section in [`website/kiosk-launcher/README-KioskChrome.md`](../website/kiosk-launcher/README-KioskChrome.md) — it covers verifying the browser process and its bound address, confirming the port-relay is running, and testing reachability from the VRHM server. The general [Troubleshooting](troubleshooting.md) page covers the rest of the app.
