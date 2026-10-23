# Console

[← Back to documentation home](../README.md#documentation)

The console window that opens with `START_VR_HEADSET_MANAGER.exe` is a full control panel. Everything the web interface does can also be done here — handy on the server PC, over remote desktop, or when the network is down. (A few features are web-only by design: the DIAG page and drawing crop rectangles in the visual view editor.)

> [!TIP]
> The console looks best in **Windows Terminal**, where the web addresses in the banner are also clickable links.

## The main screen

```
+==============================================================================+
| VR HEADSET MANAGER   v2026-10        MONITOR ok   WEB ok   MEDIAMTX ok        |
| CPU 22%  GPU0 (Intel) 0%  GPU1 (NVIDIA) 18%  RAM 61%  REC L: 445 GB  http://...|
+==============================================================================+
  ID  NAME        LINK          BATTERY  TEMP   CAPTURE  PROFILE            AUTO
   9  P4U         * USB          53%     25 C   live     square-R-N-45-10   on
  10  Q3 BLUE     * WiFi TLS     78%+    40 C   live     square-L-N-30-20   on
   5  Q3 RED      o offline        -       -     -       square-R-N-30-6    off

  +- HEADSETS ---------+ +- STREAMS ----------+ +- SITE -------------+ +- SYSTEM ----------+
  | H  Headsets        | | S  Auto-cast       | | K  Kiosks          | | V  Services       |
  | A  Apps            | | P  Profiles        | | W  Web monitor     | | C  Config         |
  |                    | | R  Recording       | | I  Internet        | | F  Files/logs     |
  +--------------------+ +--------------------+ +--------------------+ +-------------------+
  <id> open headset   <id>x kill   <id>s start   <id>r rec   <id>a auto-cast
  F1/? help   F5 reload   0 quit   00 restart   000 shut down PC
  >
```
*Illustration of the layout — colours, columns and values depend on your console width and fleet.*

- **Status banner** — the state of the background monitor, the web server and MediaMTX; CPU, every GPU, RAM and the free space of the recording drive; the web interface addresses.
- **Headset table** — refreshed in place every 5 seconds while nothing is typed (`Console.live_refresh_sec`). The **LINK** column shows how the headset is reached (`USB`, `WiFi`, `WiFi TLS`, `no ADB` when it only answers ping, `offline`).
- **Tiles** — type the letter of a tile and press Enter to open that area.
- **Input line** — type a command and press **Enter**.

### Main screen commands

| Type | Does |
|---|---|
| `<id>` (e.g. `10`) | Opens the **headset panel** of that headset |
| `<id>x` | Kills its current capture |
| `<id>s` | Starts its capture now |
| `<id>r` | Turns its recording on or off |
| `<id>a` | Turns its auto-cast (auto-restart) on or off |
| `F1` or `?` | Help: every shortcut, and every web address with its network interface |
| `F5` (or `U`) | Reloads the modules and the configuration |
| `0` / `00` / `000` | Quit / restart the application / shut down the PC (asks `YES`) |

The result of an action appears on the line under the table for a minute instead of pausing the screen.

### Tiles

| Key | Opens |
|---|---|
| **H** Headsets | Scan the network, add by IP, edit or remove a headset, enable WiFi ADB, add the USB headset, discovered devices (`8`), install the ADB auto-enable app (`9`) |
| **D** Discovered | Headsets found on the network and waiting for a decision — *only shown when there are some*. Add or forget them |
| **A** Apps | Launch an app on a headset |
| **S** Auto-cast | Every headset with its auto-restart switch — type an ID to toggle it |
| **P** (or **M**) Profiles | Capture profile of a headset (view, eye, fps, bitrate), eye merge, transparent corners |
| **R** Recording | Every headset with its recording switch — type an ID to toggle it |
| **K** Kiosks | [Kiosk screens](kiosk-screens.md): list, add, scan, push a URL or a headset wall, reboot/shut down a kiosk |
| **W** (or **B**) Web monitor | Opens the web interface in your browser |
| **I** Internet | Checks the internet connection |
| **V** Services | Restart the web server or MediaMTX, stop MediaMTX, the [benchmark](streaming.md#benchmark-what-each-option-costs-this-pc) (`B`) |
| **C** Config | WiFi networks (`W`), [ADB WiFi modes](connecting-headsets.md#wifi-adb-modes-classic-and-tls) (`A`), capture mode (`V`), Video Quality Automation (`Q`) |
| **F** Files/logs | Open the config, data and log folders; pick and open a log file (also `L`) |
| **Q** Quality | [Video Quality Automation](vqa.md) — only when it is enabled |

In every sub-menu, press the key shown in front of an option (no Enter); **0** or **Esc** goes back. Names, addresses and values are typed and confirmed with Enter.

## The headset panel

Type a headset's ID on the main screen to open its panel: a live status card (model, serial, address, link, battery, temperatures, capture, auto-cast, recording, profile, running app), refreshed in place, and one key per action.

| Key | Action | Key | Action |
|---|---|---|---|
| **1** | Auto-cast on/off | **7** | Launch an app |
| **2** | Start the capture now | **8** | Refresh rate of the headset display |
| **3** | Kill the capture | **9** | Push one of the server's WiFi networks |
| **4** | Recording on/off | **G** | Capture one frame and open it |
| **5** | Stream profile | **E** | Edit the headset fields |
| **6** | Eye merge (calibrate, enable, depth, main eye...) | **B** | Open its DIAG page in the browser |
|  |  | **X** | Remove the headset (asks for confirmation) |

**0** or **Esc** returns to the main screen.

## Supervision

While the console waits for input it also watches the background monitor: if the monitoring job dies, the banner says so and it is restarted automatically (at most 5 times in 10 minutes). Closing the console window or pressing **Ctrl+C** shuts the application down cleanly; if it is killed, a watchdog stops the services it left behind.
