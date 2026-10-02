# Headset DIAG page + USB-first ADB transport (inspired by Quas v7.0.0)

## Context
The user asked for an analysis of Quas (https://github.com/Varsett/Quas, v7.0.0), a Quest ADB multitool, to find features worth bringing into VRHM. After reviewing the full feature list, they chose:
1. A **DIAG page per headset** (`headset_diag.html?id=<ID>`), opened from a new **DIAG** button on each Headset Settings card. It has a refresh button and a 30 s auto-refresh. Sections: Firmware, Health, Wireless (WiFi + Bluetooth), Operator actions, USB/cable diagnostics, and a custom ADB command panel.
2. **CPU/GPU/skin temperatures** added to the **existing metric-history graph**.
3. **USB-first ADB transport everywhere** (all ADB calls + scrcpy capture), with automatic fallback to WiFi when the cable drops.
4. An **experimental ADB-over-TLS (mDNS)** probe, to test whether it can later replace re-enabling `tcpip 5555` after every reboot. It is investigation only and must not change the current enabling process.
5. **Tests** to run later on a PC with 2 headsets: one on USB, one on WiFi ADB.

Decisions taken with the user:
- **Web only, no console menu parity.** Logic still goes in module functions.
- **Firmware relevance = fleet comparison only**, no internet lookup.
- **ADB panel = presets + free text.** Shell only, with confirmation, and every run is logged.
- **No companion APK change.** Bluetooth and the player message use ADB only.
- **scrcpy live switch to USB is a config option** with 3 modes (see section 3).
- **Out of scope:** iperf, firmware zip analyzer/flashing, D1 (app reset), D5/D6/D7.

### Constraints the cloud session must know
`CLAUDE.md`, `docs/adr/` and `.dev/` are **gitignored**, so they are NOT in a git clone. The rules that matter are summarised here.
- **PowerShell 5.1.** `.ps1` files must contain **ASCII-only string literals** (ADR-0007). Always use `-LiteralPath` and explicit `-Encoding UTF8` (ADR-0006).
- **Translations:** `modules/translations/en-US.psd1` and `fr-FR.psd1` are at **495/500 top-level keys**. Put new strings in a **nested group** (new group `Diag`, plus `Headset` / `Transport` sub-keys), resolved with `Get-MessageString -Key 'Diag.X'`. Add each string to both files. Run `scripts/Test-TranslationParity.ps1`. Web pages are hardcoded English; `$msg` is only for logs and console.
- **Web server** (`modules/Pode_WebServer/web_server.ps1`): a plain `HttpListener`, **single-threaded** (ADR-0019's slow lane is not in code yet). Routes are `if ($request.HttpMethod -eq ... -and $request.Url.LocalPath -eq '/api/...') { try {...} finally { $response.Close() }; continue }`, using `Send-JsonResponse`. Static pages are served from `website/`. Endpoints must stay short: **one section per request and one `adb shell` spawn per section** (chain commands with `; echo ===VRHM===;` separators).
- **ADR-0012 amendment:** ADR-0012 requires CLI parity. The user explicitly asked for web-only, so record **ADR-0023** "Headset diagnostics are web-only; logic stays in modules". The adr skill and folder exist only on the user's local checkout, so write it in the PR description and the user files it locally.
- **ADR-0021 amendment:** ADR-0021 (single USB owner) **rejected USB as the scrcpy video transport**. The user now requires it, so record **ADR-0024** "USB-preferred transport with WiFi fallback". It supersedes option-4's rejection and keeps the single-USB-owner rule: **VRMonitor still owns USB probing, and others read its published snapshot**. Put it in the PR description too.
- **ADR-0018:** new metrics = new `headset_status` columns + one sample trigger each, in the generic `metric_history` table.
- Headset identity: most APIs take `name` (Name with spaces replaced by `_`). Metric APIs take numeric `id` (ADR-0016). The DIAG page uses `id`.

---

## 1. DIAG page

### Backend: new module `modules/headset_diag.ps1`
Dot-sourced wherever `adb_functions.ps1` is: `scripts_init.ps1` and the web server's module list.

Every function takes a resolved device (section 3), runs **one** combined `Invoke-AdbCmd` shell call, parses it, and returns a PSCustomObject.

| Function | ADB (single combined shell) | Returns |
|---|---|---|
| `Get-HeadsetDiagFirmware` | `getprop ro.hzos.build.display_name; getprop ro.vros.build.version; getprop ro.build.version.incremental; getprop ro.product.name; dumpsys package com.oculus.systemux` (`com.oculus.systemutilities` when product is `panther`/`xse_panther`) `\| grep versionName; dumpsys DumpsysProxy OculusUpdater; pm list packages -d \| grep updater; logcat -d -t 3000 \| grep -E 'Current progress\|OTA applying update\|OTA progress updated'; settings get global private_dns_mode; settings get global private_dns_specifier` | OsDisplay, FirmwareVersion (4 octets of versionName), EnvironmentRaw (17-digit incremental) + formatted build, Components (Integrity, Core Mobile Services, Library Quest, Device Settings, Assistant, Quest platform apex, Presence Service = `\|`-column 10), PendingOta (download_uri), OtaProgress %, UpdaterDisabled, PrivateDns, OldFirmwareWarning (major < 71). PICO: reuse the existing `Get-HeadsetFirmwareInfo` branch and return nulls for the Meta-only fields. |
| `Get-FleetFirmwareComparison` | DB only | newest FirmwareVersion per model across known headsets; flags `Behind` / `Mismatch` |
| `Get-HeadsetDiagHealth` | `dumpsys thermalservice; dumpsys hardware_properties; dumpsys FanMonitorService; getprop debug.oculus.cpuLevel; getprop debug.oculus.gpuLevel; dumpsys batterystats --charged \| grep -i 'battery capacity'; dumpsys battery; dumpsys OVRRemoteService \| grep 'Paired device'; top -m 10 -n 1 -b; dumpsys meminfo \| head -40; getprop service.bootanim.exit; getprop init.svc.bootanim; date +%s; getprop persist.sys.timezone; settings get global auto_time; logcat -d -t 5000 -s CAM_ERR` | Temps by type (CPU 0, GPU 1, battery 2, skin 3, USB 4; max per type + throttling status), fan speed/status/PWM, CPU/GPU level, battery health % (learned / design), controllers (Type, Model, HardwareRev, Firmware, Battery, isAttached, Status), top processes, memory summary, boot stage, ClockDriftSec vs PC, timezone, auto_time, camera error count (`Timedout waiting for frame ctx`) |
| `Get-HeadsetDiagWireless` | `dumpsys wifi \| grep -E 'mWifiInfo\|Wifi is'; cmd wifi list-networks; ip -4 addr show wlan0; ping -c 2 -W 2 graph.oculus.com; dumpsys bluetooth_manager` | SSID, BSSID, RSSI, link speed (tx/rx), frequency, band, Wi-Fi standard, IP; saved networks; Meta reachability; BT enabled/state, bonded devices (name, address) |
| `Get-HeadsetDiagUsb` | PC side only, no headset probe: published USB snapshot + `Get-UsbDeviceSpeed`; `Get-WinEvent` Kernel-PnP / DriverFrameworks-UserMode connect/disconnect events filtered on VID `2833` (Meta) / `2D40` (Pico); `Get-PnpDevice` for those VIDs with problem status | Only meaningful when the headset is on USB; otherwise `{OnUsb:false}` |
| `Test-HeadsetUsbCable` | push/pull of a 32 MB temp file N passes (default 3) over **USB only** | MB/s per pass, errors. Refused when `Test-UsbBusy` |

Actions:
- `Set-HeadsetBluetooth -Enable` (`cmd bluetooth_manager enable|disable`)
- `Open-HeadsetBluetoothSettings` (`am start -a android.settings.BLUETOOTH_SETTINGS`, so the player pairs bHaptics/ProTube from the headset)
- `Sync-HeadsetClock` (`settings put global auto_time 1` + `cmd network_time_update_service force_refresh`, optional timezone set to the PC's IANA zone)
- `Reset-HeadsetPrivateDns` (`settings put global private_dns_mode off`)
- `Set-HeadsetUpdaterDisabled` (`pm disable-user --user 0` / `pm enable` on the updater packages, as an extra on top of the existing appops block)
- `Set-HeadsetAppEnabled -Package -Enable` (D2: `pm disable-user --user 0` / `pm enable`; list via `pm list packages -d`)
- `Send-HeadsetPlayerMessage -Title -Text`: `cmd notification post -S bigtext -t '<title>' vrhm_msg '<text>'`. Text is escaped by doubling single quotes with `'\''`, and only printable ASCII is sent (strip the rest). The result is marked **experimental**, because visibility inside immersive apps must be confirmed by the tests.
- `Send-HeadsetText -Text` (`input text` with the Quas escaping, spaces become `%s`)
- `Invoke-HeadsetRecovery -Action Wake|Home|RestartShell|RestartSystemUX` (`input keyevent 224`; `am start -a android.intent.action.MAIN -c android.intent.category.HOME`; `am force-stop com.oculus.vrshell` + `am start -n com.oculus.vrshell/.HomeActivity`; `am force-stop com.oculus.systemux`)
- `Invoke-HeadsetCustomCommand -Command`: shell only. Rejects anything containing `reboot bootloader`, `rm -rf /`, `wipe` or `fastboot`. 20 s timeout, output truncated to 64 KB, logged with `Write-Log` at INFO (headset + command).

Experimental TLS: `Get-HeadsetAdbTlsStatus` (`settings get global adb_wifi_enabled`, plus the mDNS `_adb-tls-connect._tcp` port from `mdns_scanner.ps1`), `Enable-HeadsetAdbTls` (`settings put global adb_wifi_enabled 1`), `Connect-HeadsetAdbTls` (`adb connect ip:<mdnsPort>`). **Nothing in the existing enable flow calls these.**

### Firmware history (A12)
New migration `modules/db/schema/007_diag_temps_firmware.sql` (shared with section 2): table `firmware_history(headset_id, ts, firmware_version, environment)`. Rows are written by the monitor when FirmwareVersion changes (stage 2 already reads identity; add the version read at a slow cadence, every 10 min). Add named queries `firmware.history.sql` / `firmware.insert.sql` in `modules/db/queries/` (keep static named-query parity).

### API routes (`web_server.ps1`, next to `/api/headset-firmware` ~L1146)
- `GET /api/headset-diag?id=&section=firmware|health|wireless|usb|fleet`
- `POST /api/headset-diag/action`, body `{id, action, args}`. One dispatcher, with actions allow-listed to the functions above.
- `POST /api/headset-diag/command`, body `{id, command}` (free text or preset)
- `GET /api/headset-diag/presets`

Resolve the device with the new `Resolve-HeadsetAdbDevice` (section 3). Fix the existing bug at web_server.ps1 ~L2441 (`$headset.IP` should be `$headset.IPAddress`).

### Frontend
- `website/headset_diag.html` (self-contained, same look as `headsets_settings.html`, uses `assets/topbar.js`):
  - headset selector (from `/api/headsets-status`), Refresh button, auto-refresh toggle (30 s, default on)
  - per-section cards loaded **sequentially**, with a transport badge (USB/WiFi)
  - temperature tiles link to `metric_history.html?id=&metric=cpu_temp`
  - destructive actions ask for confirmation
  - the USB section only shows when on USB
  - the TLS panel is labelled Experimental
- DIAG button: `website/headsets_settings.html` `buildCards()` next to the Configure button (~L1477): `<a class="..." href="headset_diag.html?id='+cfg.ID+'">DIAG</a>`.

### Config (sync all 4 sites: `templates/config/config.json`, live config migration via the loader defaults, `modules/config_files_loader.ps1`, `website/vrhm_config.html`)
- `Diag.auto_refresh_sec` (30)
- `Diag.command_presets` (array of `{name, command}`; seeds: battery dump, wifi dump, top, list disabled packages)
- `Diag.cable_test_passes` (3)

## 2. Temperatures into the metric-history graph (B1)
- Monitor: in `Get-HeadsetInfoStage2Identity` (`modules/headsets_monitoring.ps1` ~L1315), add a `dumpsys thermalservice` read **throttled to every 30 s** per headset (runspace-local timestamp). Parse it with a shared `ConvertFrom-ThermalService` helper (in `adb_functions.ps1`, also used by the DIAG health section). Produce `CpuTemp`, `GpuTemp`, `SkinTemp` (max per type, 1 decimal, `'-'` when absent, e.g. PICO).
- Add the fields to `New-DefaultHeadsetInfo` (~L1208), the offline reset (~L442), the stage-2 `$out`, `Get-HeadsetInfosCsvColumn` (~L1181), the change fingerprint (~L754) and `$statusRows` (~L866).
- Migration 007: `ALTER TABLE headset_status ADD cpu_temp/gpu_temp/skin_temp TEXT DEFAULT '-'`. Recreate `v_headset_status`. Add 3 `trg_status_<x>_sample` triggers copied from 006 (keep the GLOB guard, `REPLACE(',','.')`, update-then-insert). Update `status.upsert.sql` (and the merged/list queries if they enumerate columns).
- `Get-HeadsetMetricDefinition` (~L1080): add `cpu_temp`, `gpu_temp`, `skin_temp` (Unit C, not percent).
- `website/assets/battery_chart.js` `METRICS` (~L51): 3 entries, reusing the temperature warn/crit config keys.
- Monitoring table: optional CPU temp column in `headsets_monitoring.html`, using the sparkline `metricButton` already there.
- Update `scripts/dbTests/Test-DbUnit.ps1` (~L437-530: trigger tests, "5 metrics" becomes 8) and the static migration checks.

## 3. USB-first ADB transport with WiFi fallback
### Published USB set (VRMonitor stays the only USB prober)
- In `Invoke-UsbHeadsetActions` / `Update-UsbWatchState` (`modules/usb_manager.ps1`, `adb_functions.ps1` ~L1221), the steady-state `adb devices` output is already available. Also publish **all** USB transports in state `device` to app_kv key `usb_devices`: `[{Serial, State, Since}]`, written on change only. Onboarding logic stays single-device as it is.
- New `Get-PublishedUsbDevices` (adb_functions.ps1, reading app_kv) replaces the web-server-local `Get-PublishedUsbSnapshot` usage for transport choice.

### Resolver
- `Resolve-HeadsetAdbDevice -Headset [-PreferTransport Auto|USB|WiFi]` in `adb_functions.ps1`. It becomes the body of `Get-BestAdbDevice`, which stays as an alias so its ~17 callers keep working.
  - If `Adb.prefer_usb` is set, `Headset.SerialNumber` is in `usb_devices`, and `-not (Test-UsbBusy)`: return a USB device object.
  - Otherwise use the existing `Get-AdbWifiDevice`.
  - No `adb devices` spawn per call: it reads the snapshot.
- Device object gains `SerialNumber`, `HeadsetIP`, `HeadsetPort` (the WiFi fallback target), alongside `DeviceId` / `ConnectionType` / `IP` / `Port`.
- `Invoke-AdbCmd` (~L350): when a **USB** object hits `Test-AdbTransportFailure` (or a "device not found" error) and `HeadsetIP` is set, it rebuilds a WiFi object through `Get-AdbWifiDevice` and retries once. It logs `Transport.FallbackToWifi`. It never falls back WiFi to USB (the snapshot handles that on the next call).
- Convert the hardcoded-WiFi call sites that target a **known headset** to the resolver:
  - monitor stage 2/3 (`headsets_monitoring.ps1` ~L402)
  - `Get-KnownHeadsetInfos` (~L1395)
  - `/api/installapk` job (pass the resolved id + fallback IP)
  - `Set-HeadsetGuardian`
  - other raw `& $adb -s <ip>` uses aimed at a known headset

  LAN discovery/scanner and USB onboarding stay as they are.
- Stage 1 reachability: `ADB` is true if TCP 5555 is open **or** the serial is in `usb_devices`. Publish a new status field `AdbTransport` (`USB` / `WiFi` / `-`), shown as a badge on the Headset Settings card, the Monitoring row and the DIAG page.

### scrcpy
- `start-screenCopy` (`modules/scrcpy_launcher.ps1` ~L561) takes the resolved device: `-s <serial>` for USB, `-s ip:port` for WiFi. The 5555 pre-check is skipped for USB. Add a stable marker to every launch so the process can be matched regardless of transport. Prefer `--window-title "VRHM <IP>"` when windowed. For `--no-window`, match the serial **or** the IP in the command line.
  - Update `Get-ScrcpyProcess` (~L229) and the stage-1 PID cache/WMI match (`headsets_monitoring.ps1` ~L1270-1304) to accept serial or IP.
- `Watch-ScrcpyProcesses` (~L751): compute the preferred transport, compare it with the running command line, and apply `scrcpy.usb_switch_mode`:
  - `stable` (default): switch to USB once the serial has been in `usb_devices` for `scrcpy.usb_switch_stable_sec` (10) **and** the headset is not recording.
  - `immediate`: switch on detection.
  - `next_start`: never interrupt; use USB on the next start or auto-restart.

  Always restart through `Stop-HeadsetPipeline` (ADR-0003). When USB disappears, scrcpy dies and the auto-restart path resolves to WiFi straight away (all modes).
- Config (4 sync sites): `ADB.prefer_usb` (true), `scrcpy.usb_switch_mode` (`stable|immediate|next_start`), `scrcpy.usb_switch_stable_sec` (10).

## 4. Tests (run later on: PC + headset A on USB, headset B on WiFi only)
- New section `scripts/nonRegressionTests/tests/85_diag_transport.ps1`, using the existing runner (`Invoke-RegressionTest`, `Assert-*`, `Skip-Test`, `Invoke-VrmApi`). Parameters/env: `VRHM_TEST_USB_HEADSET`, `VRHM_TEST_WIFI_HEADSET` (names). It is skipped when they are absent.
  - Transport: A reports `AdbTransport=USB`, B reports `WiFi`. An ADB command on A uses `-s <serial>` (checked via the log line). Physical prompt (skipped with `-Unattended`): **unplug A**, then within 15 s A is `WiFi`, an ADB command still succeeds and scrcpy restarts on `ip:port`. **Replug A**: it switches back to USB according to each `usb_switch_mode` (the test sets the mode through the config API).
  - DIAG API: every section returns 200 with non-null key fields for A and B. `fleet` lists both. `usb` has `OnUsb=true` only for A. Cable test on A returns MB/s; on B it is refused.
  - Temperatures: after 60 s, `/api/metric-history?id=A&metric=cpu_temp` has at least 1 point.
  - Actions: BT list; BT disable/enable round-trip; clock drift < 5 s after `Sync-HeadsetClock`; player message posted (manual confirmation prompt: "is it visible in the headset?"); recovery Wake/Home; custom preset + free-text `getprop ro.product.model`; blocked command rejected.
  - TLS experimental: report status / mDNS port / connect result for B, then reboot B (prompt) and record whether TLS is still enabled after the reboot. **Evidence only, no assert.**
- `scripts/dbTests`: migration 007 unit tests (3 new triggers, firmware_history insert/query) + static numbering/named-query parity.
- `20_webpages.ps1` already auto-fetches every `*.html`, so `headset_diag.html` is covered.

## Files touched (main)
- new: `modules/headset_diag.ps1`, `website/headset_diag.html`, `modules/db/schema/007_diag_temps_firmware.sql`, `modules/db/queries/firmware.*.sql`, `scripts/nonRegressionTests/tests/85_diag_transport.ps1`
- modified: `modules/adb_functions.ps1`, `modules/usb_manager.ps1`, `modules/headsets_monitoring.ps1`, `modules/scrcpy_launcher.ps1`, `modules/Pode_WebServer/web_server.ps1`, `modules/scripts_init.ps1`, `modules/config_files_loader.ps1`, `templates/config/config.json`, `website/vrhm_config.html`, `website/headsets_settings.html`, `website/headsets_monitoring.html`, `website/assets/battery_chart.js`, `modules/db/queries/status.upsert.sql`, `modules/translations/en-US.psd1` + `fr-FR.psd1` (nested `Diag` / `Transport` groups), `scripts/dbTests/*`, `docs/web-interface.md`, `docs/configuration.md`

## Verification (cloud session: static only; hardware tests run later locally)
1. PowerShell parse of every touched `.ps1` (`[System.Management.Automation.Language.Parser]::ParseFile`); ASCII-only check on `.ps1` literals.
2. `scripts/Test-TranslationParity.ps1`, `scripts/Test-ConfigSchema.ps1`, `scripts/dbTests/Invoke-DbTests.ps1 -Layer Static,Unit` (if `pwsh` is available in the cloud box; otherwise list them as pending for the local run).
3. Locally, with 2 headsets: `scripts/Invoke-NonRegressionTests.ps1 -Sections 20,85` (+ 30/50 for regression on streaming).
4. Deliver on branch `claude/quas-repo-analysis-d73ee0`, open a PR. The PR body includes the ADR-0023 / ADR-0024 texts for the user to file in their local `docs/adr/`, and the `.dev` devlog consolidation note.
