# Streaming, restreaming & OBS

[← Back to documentation home](README.md)

## How the pipeline works

```
┌──────────┐  WiFi ADB   ┌────────┐        ┌────────┐  RTSP   ┌──────────┐  RTSP / HLS / WHEP
│ Headset  │ ──────────► │ scrcpy │ ─────► │ ffmpeg │ ──────► │ MediaMTX │ ─────────────────► viewers
└──────────┘  (h264/h265)└────────┘ (pipe) └────────┘ publish └──────────┘   (web page, OBS, VLC...)
                              │
                              └──► local capture window on the VRHM PC
                              └──► optional recording to disk (-c copy)
```

1. **scrcpy** captures the headset screen over WiFi ADB, shows the local window, and writes the video to a relay pipe.
2. **ffmpeg** reads that pipe and publishes the stream to MediaMTX over RTSP. By default it **re-encodes the stream to a controlled framerate and bitrate** (30 fps / 6 Mbps), so the network load per viewer stays predictable — see [FFmpeg re-encoding](#ffmpeg-re-encoding-and-streaming-options).
3. **MediaMTX** makes the stream available to any number of viewers over three protocols simultaneously.

Everything is supervised: if a headset drops and comes back and **Auto-restart scrcpy** is enabled, the whole chain restarts by itself.

## Capture modes

The capture-mode selector in the **Headset Settings** top bar (config key `Performance.Capture_Mode`) chooses what happens with the scrcpy capture:

![Capture mode selector](pics/web_streamingMode_Settings.png)

| Mode | Effect |
|---|---|
| **Stream only** | Publish to MediaMTX, no window on the PC (lightest on the GPU display side) |
| **Stream + local scrcpy window** (default) | Publish to MediaMTX and show the local mirror window |
| **Local scrcpy window only** | Just the mirror window — nothing is restreamed |

## scrcpy capture profiles

VR headsets render one image per eye with lens distortion, so raw mirroring looks bad on a flat screen. VRHM ships **per-model crop profiles** that extract one eye and straighten it.

A profile is stored as a compact string on each headset (editable in **Headset Settings**):

```
view-EYE-AUDIO-FPS-BW
 │     │    │    │  └─ video bitrate in Mbps          (e.g. 8)
 │     │    │    └─── max framerate                   (e.g. 30, 45, 60)
 │     │    └──────── audio duplication: N (no) / Y   (keep audio in headset AND stream it)
 │     └───────────── eye: L or R                     (which eye to crop)
 └─────────────────── view: max / square / portrait / wide / fullscreen
```

Example — `max-R-N-30-8`: maximum-area crop of the right eye, no audio duplication, 30 fps, 8 Mbps.

Available views (per model, defined in the [configuration](configuration.md#headset-capture-profiles-scrcpy)):

| View | Use for |
|---|---|
| `max` | Largest usable area of one eye (default) |
| `square` | 1:1 tile, dense video walls |
| `portrait` | Vertical screens |
| `wide` | 16:9-ish landscape framing |
| `fullscreen` | Raw both-eyes output, no crop |

Profiles exist out of the box for **Quest 3**, **Quest 2**, and **PICO 4 Ultra** — you can tune the crop rectangles or add new models in the config.

## FFmpeg re-encoding and streaming options

After scrcpy captures the headset, ffmpeg publishes the video to MediaMTX. How it does that is controlled by the **Streaming** options in **Config → App Configuration → Streaming & Recording**:

![Streaming options in the App Configuration page](pics/web_vrhm_config_streamingEncoding.png)

| Option | Default | What it does |
|---|---|---|
| **Re-encode in FFmpeg** | **ON** | ON: ffmpeg re-encodes every stream to the framerate/bitrate below before pushing it to MediaMTX — the LAN bandwidth per viewer is capped and identical for all headsets. OFF: passthrough (`-c copy`) — the raw scrcpy stream is forwarded untouched (zero quality loss, minimal CPU, but each viewer receives the full bitrate of the headset's capture profile). |
| **Re-encode Codec** | **h264** | Codec used when re-encoding. `h264` is the most compatible. `h265` (HEVC) gives roughly 40-50% lower bitrate at the same quality, but the encoding GPU **and every viewer** must support HEVC. **OBS Browser source does not support H265** — see the OBS integration warning below. In passthrough mode the headset's native codec is always forwarded. |
| **Stream Framerate** | **30 fps** | Target framerate when re-encoding. |
| **Stream Bitrate** | **6M** | Target bitrate when re-encoding (examples: `4M`, `6M`, `8M`). |
| **Pause When Hidden** | **ON** | Web viewers automatically stop their WHEP stream when the browser tab is hidden (backgrounded tab, screen off) and reconnect when visible again — idle viewers stop consuming network and MediaMTX resources. |
| **Pause Delay** | **10 s** | How long a stream must stay hidden before it is paused, so a brief tab switch does not tear down the connection. |

More about re-encoding:

- The GPU encoder is **auto-detected** in priority order for your hardware — NVENC (NVIDIA), Quick Sync (Intel), AMF (AMD) — with CPU x264/x265 as the guaranteed fallback
- Changes take effect when scrcpy is (re)started; the web UI restarts the affected streams automatically after saving
- [Video Quality Automation](vqa.md) can lower the stream framerate/bitrate automatically under CPU/GPU pressure

> [!NOTE]
> Re-encoding trades PC CPU/GPU for network bandwidth. Turn it **off** (passthrough) if you have few viewers and want the lowest possible CPU usage. Recordings are **always** stored with the original capture quality (`-c copy`), never re-encoded.

## Stream URLs

Every headset stream is published under a path derived from its name (e.g. `Q3 BLUE` → `q3_blue`), on three protocols:

| Protocol | URL | Best for |
|---|---|---|
| WHEP (WebRTC) | `http://<pc-ip>:8889/<name>` | OBS Browser source, web pages — lowest latency |
| RTSP | `rtsp://<pc-ip>:8554/<name>` | VLC, OBS Media source, other software |
| HLS | `http://<pc-ip>:8888/<name>/index.m3u8` | Browsers/players without WebRTC, many viewers |

You never have to build these by hand: **Config → Help & Diagnostics → Stream Links** lists ready-to-copy URLs for every headset with a LIVE/OFFLINE badge:

![Stream links in Help & Diagnostics](pics/web_help_links.png)

## OBS integration

> [!WARNING]
> **OBS Browser source requires H264.** OBS's built-in browser (Chromium Embedded Framework) does **not** support H265/HEVC decoding for WHEP/WebRTC playback. If **Re-encode Codec** (see table above) is set to `h265`, the OBS Browser source will fail to display the video (it will work fine in a normal browser, which is why this is easy to miss). Set **Re-encode Codec** back to **h264** — or disable **Re-encode in FFmpeg** only if the headset's native passthrough codec is H264 — before adding a headset to OBS via Browser source.

A complete per-headset scene is typically built from three stacked **Browser sources** — live video, monitoring overlay, and session timer:

![OBS scene with a headset video feed, monitoring overlay and timer](pics/obs_integration.png)
*A per-headset OBS scene: the WHEP video source, the monitoring overlay (battery/controllers/temperature) and the remote timer, visible in the Sources panel.*

### 1. Video source

The video is added as a **Browser source** (recommended, lowest latency), and there are **two ways** to do it:

| Method | URL | When to use |
|---|---|---|
| **A. Direct WHEP stream** | `http://<pc-ip>:8889/<name>` | Raw video only, nothing else — the leanest option. Build your own overlays in OBS (methods 2 and 3 below). |
| **B. `[video].html` page** | `http://<pc-ip>:8080/<HEADSET_NAME>[video].html?nooverlay=1` | The VRHM player page. `?nooverlay=1` starts it clean (video only), but the built-in monitoring/timer overlays can still be toggled back on at any time (e.g. via OBS's *Interact* mode) — no extra sources needed. |

![OBS Browser source properties for the WHEP video](pics/obs_video_whep.png)
*Method A — Browser source properties with the raw WHEP URL and a small Custom CSS snippet (`body { background-color: rgba(0,0,0,0); margin: 0px auto; overflow: hidden; }`) for a clean transparent embed.*

> [!TIP]
> Alternative without the OBS browser: a **Media source** with the RTSP URL. Untick *Local file*, set *Input* to `rtsp://<pc-ip>:8554/<name>`, and reduce network buffering for lower latency.

### 2. Monitoring overlay

For headset health on stream, add a second **Browser source** pointing to the per-headset monitoring overlay:

```
http://<pc-ip>:8080/<HEADSET_NAME>[monitoring].html
```

It renders battery, controllers, charge and temperature with a transparent background, ready to overlay on the video (use the same transparent-background Custom CSS):

![OBS Browser source properties for the monitoring overlay](pics/obs_monitoring.png)

### 3. Session timer

To show the player's remaining session time, add a third **Browser source** with the per-headset timer page:

```
http://<pc-ip>:8080/<HEADSET_NAME>[timer].html
```

You can resize the digits from OBS with a one-line Custom CSS, e.g. `#timer-val { font-size: 112px !important; }`:

![OBS Browser source properties for the timer](pics/obs_timer.png)

The timer is controlled from the web interface or from any external tool (Stream Deck, curl...) via the [Timer API](docs_timer_api.md).

## Recording

Enable **Recording** on a headset's card in **Headset Settings** to save its capture sessions to disk.

- Files go to the configured record folder (default `C:\DATA\MEDIA\VR_Records`, see [configuration](configuration.md#headset-capture-profiles-scrcpy))
- The recording is a lossless copy of the capture (no re-encoding)
- A **minimum free space guard** (default 5 GB) automatically disables recording on all headsets when the drive runs low; the web UI shows a storage warning banner

---

Related: [Web interface tour](web-interface.md) · [Configuration reference](configuration.md) · [Video Quality Automation](vqa.md)
