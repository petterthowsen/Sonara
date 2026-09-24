# OSC Protocol

Godot sends to the engine on UDP port 7000; the engine replies on port 7001. Parameter values cross
as normalized 0.0–1.0 floats.

This file is incomplete: it currently covers the messages changed for the Simple View
(`docs/specs/004-simple-view/`). The source of truth is `Engine/src/osc/server.rs`.

## Device addresses

`<device addr>` is the device's channel plus its path in the device chain, built by
`DevicePath::to_osc_addr` (`Engine/src/audio/devices/container.rs`). Nested devices (inside
containers) extend the path.

## Engine → Godot

### `<device addr>/param/count`

| # | Type | Meaning |
|---|---|---|
| 0 | i | Number of parameters. One `param/info` follows for each |

### `<device addr>/param/info`

| # | Type | Meaning |
|---|---|---|
| 0 | i | Parameter id |
| 1 | s | Name |
| 2 | f | Min (real value) |
| 3 | f | Max (real value) |
| 4 | f | Default (real value) |
| 5 | s | Group |
| 6 | s | `param_type`: `"float"`, `"bool"` or `"enum"` |
| 7 | i | `flags` bitmask: 1 = hidden, 2 = read-only, 4 = bypass |
| 8 | s | CLAP module path (`/`-separated), empty if none |
| 9 | i | `enum_count` |
| 10… | s | `enum_count` enum value labels; the index matches the engine value |

Args 6 onward were added later. Godot treats a missing trailing arg as its default (`float`, no
flags, no module, no enum values).

### `/plugin/info`

Sent once per plugin after `/plugin/scan`.

| # | Type | Meaning |
|---|---|---|
| 0 | s | Plugin id |
| 1 | s | Name |
| 2 | s | Vendor |
| 3 | s | Version |
| 4 | s | Category |
| 5 | s | Description, empty if none |
| 6 | s | Path to the `.clap` bundle |
| 7 | s | CLAP feature tags joined with `,` (e.g. `audio-effect,reverb,stereo`), may be empty |

`/plugin/scan_complete [count:i]` follows the last one.

### `/status/engine_stats`

Sent by the audio callback at 2 Hz, also while the engine state lock is busy. Replaces
`/status/engine_load`. Counters are running totals since the engine started (they survive a
stream restart), so a dropped packet loses nothing. Rate = difference between two reports.

| # | Type | Meaning |
|---|---|---|
| 0 | f | `load_avg`: processing time / block time over the last 0.5 s (1.0 = 100%) |
| 1 | f | `load_peak`: worst single block in that interval, same unit |
| 2 | i | `xruns`: cpal stream errors plus callback gaps longer than 1.5× the previous block |
| 3 | i | `lock_misses`: callbacks that output silence because the state lock stayed busy |
| 4 | i | `callbacks` |
| 5 | i | `frames`: frames in the last block |
| 6 | i | `plugin_underruns`: CLAP plugin blocks padded with silence because the plugin's output wasn't ready (audible dropouts) |

Counters are clamped to int32.
