# VR HEADSET MANAGER

## Timer system — how it works and how to use it externally

---

### Overview

Each headset has an independent countdown or count-up timer. The timer state is managed
by the PowerShell web server (`modules/Pode_WebServer/web_server.ps1`) and persisted in two
places:

| File | Purpose |
|---|---|
| `website/timer/<DisplayName>[timer].txt` | Current display value, written every second by a background job |
| `website/timer/<DisplayName>[timer].run` | Run-token used to kill orphaned background jobs |

`<DisplayName>` is the headset's display name with spaces replaced by underscores
(e.g. `Q3 RED` → `Q3_RED`), consistent with `Q3_RED[video].html` and `Q3_RED[monitoring].html`. Timer configuration (duration, mode) is stored per-headset
in `data/timer.csv`.

---

### Timer modes

| Mode | Behaviour |
|---|---|
| `dec` (default) | Counts **down** from the configured duration to `00:00`, then shows `Time's up !` |
| `inc` | Counts **up** from `00:00` to the configured duration, then shows `Time's up !` |

---

### API reference

**Base URL:** `http://<server-ip>:<port>/api/timer`

All requests use **HTTP GET** so they work directly from a browser address bar, a Stream Deck
URL action, OBS browser source custom URL, `curl`, or any HTTP client without CORS or POST
setup.

#### Headset identification

Every request must identify the target headset using **one** of:

| Parameter | Format | Example |
|---|---|---|
| `id` | Numeric headset ID (from `known_headsets.csv`) | `id=1` |
| `name` | Headset display name (spaces allowed or replaced by `_`) | `name=Q3_RED` or `name=Q3 RED` |

---

#### Actions

##### `start` — Start (or restart) the timer

Starts the timer using the currently saved configuration. If a timer is already running it
is stopped first and restarted from the beginning.

```
GET /api/timer?name=Q3_RED&action=start
```

Response:
```json
{"ok":true}
```

---

##### `pause` — Pause a running timer

Freezes the timer at its current value. The display file retains the frozen time so it
stays visible in OBS overlays.

```
GET /api/timer?name=Q3_RED&action=pause
```

Response (success):
```json
{"ok":true}
```

Response (timer not running):
```json
{"ok":false,"error":"timer not found"}
```

---

##### `resume` — Resume a paused timer

Continues counting from where the timer was paused. Works correctly for both `dec` and `inc`
modes.

```
GET /api/timer?name=Q3_RED&action=resume
```

Response (success):
```json
{"ok":true}
```

Response (timer not paused):
```json
{"ok":false,"error":"timer not found or not paused"}
```

---

##### `reset` — Stop and clear the timer

Stops the timer and clears the display file. The overlay disappears.

```
GET /api/timer?name=Q3_RED&action=reset
```

Response:
```json
{"ok":true}
```

---

##### `status` — Query the current state

Returns the full current state of the timer. All pages poll this endpoint every second to
keep button colours and the displayed value in sync across all open windows.

```
GET /api/timer?name=Q3_RED&action=status
```

Response:
```json
{
  "ok": true,
  "active": true,
  "paused": false,
  "value": "04:32",
  "minutes": 5,
  "seconds": 0,
  "mode": "dec"
}
```

| Field | Type | Description |
|---|---|---|
| `active` | bool | Timer job is running (counting) |
| `paused` | bool | Timer is paused (frozen mid-count) |
| `value` | string | Current display value (`"04:32"`, `"Time's up !"`, or `""` when idle) |
| `minutes` | int | Configured duration — minutes part |
| `seconds` | int | Configured duration — seconds part |
| `mode` | string | `"dec"` or `"inc"` |

---

##### `config` — Save timer configuration

Sets the duration and mode. The new values are stored in `data/timer.csv` and used the next
time `start` is called. Does **not** affect a currently running timer.

```
GET /api/timer?name=Q3_RED&action=config&minutes=10&seconds=0&mode=dec
```

| Parameter | Required | Default | Description |
|---|---|---|---|
| `minutes` | no | `5` | Duration minutes part (integer >= 0) |
| `seconds` | no | `0` | Duration seconds part (integer 0-59) |
| `mode` | no | `dec` | `dec` (countdown) or `inc` (count-up) |

Response:
```json
{"ok":true}
```

---

### Error responses

Any request with a missing or unresolvable headset identifier, or an unknown action, returns
HTTP 400:

```json
{"ok":false,"error":"Missing id or action"}
```

---

### Timer file — direct access

The display value is also available as a plain-text static file served by the web server:

```
GET /timer/<DisplayName>[timer].txt
```

Example: `http://192.168.1.37:8080/timer/Q3_RED[timer].txt` → `04:32`

The file is overwritten every second while the timer runs. It is cleared (empty) when the
timer is stopped or reset. This is useful for OBS text sources that read from a URL.

> **Note:** All web pages in VR Headset Manager use the `status` API endpoint rather than the
> static file, so that pause/active state stays synchronised across windows.

---

### External use examples

#### curl (Linux / macOS / Windows)

```bash
# Start a 5-minute countdown on Q3 RED
curl "http://192.168.1.37:8080/api/timer?name=Q3_RED&action=start"

# Pause it
curl "http://192.168.1.37:8080/api/timer?name=Q3_RED&action=pause"

# Resume
curl "http://192.168.1.37:8080/api/timer?name=Q3_RED&action=resume"

# Check status
curl "http://192.168.1.37:8080/api/timer?name=Q3_RED&action=status"

# Set a 10-minute count-up timer, then start it
curl "http://192.168.1.37:8080/api/timer?name=Q3_RED&action=config&minutes=10&seconds=0&mode=inc"
curl "http://192.168.1.37:8080/api/timer?name=Q3_RED&action=start"
```

#### PowerShell

```powershell
$base = "http://192.168.1.37:8080/api/timer"
Invoke-RestMethod "$base?name=Q3_RED&action=start"
Invoke-RestMethod "$base?name=Q3_RED&action=status"
```

#### Stream Deck (URL action plugin)

Configure a URL action button pointing to:
```
http://192.168.1.37:8080/api/timer?name=Q3_RED&action=start
```

One button per action (start / pause / resume / reset). Because all actions are plain GET
requests there is no authentication or content-type header required.

#### OBS text source (read timer file)

In OBS, add a **Text (GDI+)** source, enable **"Read from file"**, and point it to the
`website/timer/Q3_RED.txt` file on disk, or use a **Browser** source with the URL:
```
http://192.168.1.37:8080/timer/Q3_RED.txt
```

---

### State machine

```
              [idle]
                |
         action=start
                |
                v
           [running] <------- action=resume
                |                    ^
         action=pause                |
                |                    |
                v                    |
            [paused] ----------------+
                |
         action=reset
                |
                v
             [idle]

  [running] --action=reset--> [idle]
  [running] --expires-------> [idle]  (file shows "Time's up !" for last tick)
```
