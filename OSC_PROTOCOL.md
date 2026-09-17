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
