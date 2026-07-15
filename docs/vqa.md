# Video Quality Automation (VQA)

[← Back to documentation home](README.md)

Capturing several headsets is heavy. When the computer starts to choke, streams stutter for everyone. **Video Quality Automation** watches the machine and reacts *before* that happens: it computes quality reductions (resolution, framerate, bitrate) that would bring the load back to a safe level, and either **recommends** them to you or **applies them automatically**.

## The idea in one diagram

```
                 CPU / GPU load (from computer monitoring)
                                  │
              ┌───────────────────┴───────────────────┐
        load ≥ 80 % (max threshold)             load back under 60 % (mitigation)
              │                                        │
        recommend "down"                        recommend "up"
   (reduce resolution / fps / bitrate)      (restore towards the originals)
              │
   auto-apply only after N consecutive "down" cycles (default 5)
```

- Nothing is ever reduced below the configured floors: **min resolution 480 px**, **min 15 fps**, **min 3 Mbps**
- Every change VQA applies is **snapshotted first** — one click restores your original settings
- After any change, a **cooldown** (default 5 monitoring cycles) lets the system stabilize before VQA acts again

## Recommendation vs auto-apply

VQA works on three independent sections, each with its own auto-apply switch:

| Section | What gets adjusted |
|---|---|
| **Profiles** | The per-model capture profiles (`max_size` resolution cap) |
| **Headsets** | The profile string of currently-running captures (fps, bitrate) |
| **MediaMTX** | The restream `stream_framerate` / `stream_bitrate` (when [re-encoding](streaming.md#re-encoding-bandwidth-control) is on) |

With all switches **off** (the default), VQA only *recommends*: the Monitoring page shows what it would change and you decide. Turn a section's switch **on** and VQA applies that section automatically after enough consecutive "down" recommendations.

> 📸 **SCREENSHOT TO ADD** — save as `docs/pics/web_vqa_section.png`
> *What to capture:* the Monitoring web page with `VideoQualityAutomation.enabled = true` in the config, showing the VQA panel: the three per-section auto-apply toggles, the Video Quality Auto-Optimizer ON/OFF badge, and a current recommendation table if one is displayed.

<!-- ![VQA panel on the Monitoring page](pics/web_vqa_section.png) -->

## Restoring your settings

Whenever VQA has applied changes, a **Restore** action (web Monitoring page) reverts everything to the snapshot taken before the first automatic change. Manual edits you made *after* the snapshot are detected field by field and preserved. Originals are also restored automatically at application startup if a previous session left changes applied.

## Configuration

Section `VideoQualityAutomation` of [config.json](configuration.md):

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master switch (also controls the panel on the Monitoring page) |
| `auto_apply_profiles` / `auto_apply_headsets` / `auto_apply_mediamtx` | `false` | Per-section automatic apply |
| `cpu_max_threshold_percent` / `gpu_max_threshold_percent` | `80` | Load at which a "down" recommendation is produced |
| `cpu_mitigation_threshold_percent` / `gpu_mitigation_threshold_percent` | `60` | Load under which restoring ("up") becomes possible |
| `downscale_step_percent` | `20` | Size of each reduction step |
| `min_max_size_px` / `min_fps` / `min_bitrate_mbps` | `480` / `15` / `3` | Hard floors — never reduced below |
| `fps_round_step` | `5` | Framerates are rounded down to multiples of this |
| `default_uncapped_max_size_px` | `1280` | Starting cap applied to profiles that had no cap (`max_size = 0`) |
| `vqo_consecutive_count` | `5` | Consecutive "down" cycles required before auto-apply triggers |
| `cooldown_cycles` | `5` | Cycles to wait after any change before evaluating again |

A history of every recommendation is kept in `data\vqa_history.csv` for diagnosis.
