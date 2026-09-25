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

## Plugin crash and reload (Phase 4)

### `<device addr>/loading_state`

Sent on every load transition: `"idle"`, `"loading"`, `"ready"`, `"failed:<error>"` (loading never
finished) or `"crashed:<reason>"` (the host process died after loading). A crashed device passes
audio through and the UI offers a Reload.

### `<device addr>/crashed`

Sent once when a plugin's host process dies or stops responding. A crash belongs to the host
process, so a host shared by several instances (hosting modes) sends one per instance, all with the
same `pid`.

| # | Type | Meaning |
|---|---|---|
| 0 | s | `reason`: one line, e.g. `killed by signal 11 (SIGSEGV)` or `exited with code 7` |
| 1 | s | `stderr`: the last lines the host printed before it died, newline-separated, may be empty |
| 2 | i | `pid`: the dead host's process id |
| 3 | s | `log_path`: the host's own log file (Phase 6), empty when unknown (e.g. under a debugger wrapper) |

### `<device addr>/reload` (Godot → engine)

No arguments. Respawning the host and restoring the plugin's state happens on the engine's command
thread; the device reports `"loading"` and later `"ready"` on `<device addr>/loading_state`. Every
other crashed device that was in the same host process is reloaded with it.

## Plugin hosting modes (Phase 5)

### `/plugins/hosting [mode:s, (plugin_id:s, mode:s)*]` (Godot → engine)

How CLAP plugins are grouped into `plugin_host` processes. `mode` is one of `individually` (one
process per instance, the default), `by_plugin` (one per plugin), `by_vendor` (one per vendor) or
`together` (one for all). Each following pair overrides the mode for one plugin id. The message
replaces the whole policy, so Godot sends every override each time. An unknown global mode rejects
the message; an unknown override mode is skipped.

Plugins already loaded move live: the engine saves each affected plugin's state, closes its GUI
(`<device addr>/gui/closed`), respawns it in its new host and restores the state. Audio passes
through the plugin until it is `"ready"` again.

### `<device addr>/host`

Sent when a plugin has loaded into a host process (first load, reload or a move).

| # | Type | Meaning |
|---|---|---|
| 0 | s | `mode`: the hosting mode that picked the host (the names above) |
| 1 | s | `host_key`: `instance-<id>`, `plugin:<id>`, `vendor:<name>` or `all` |
| 2 | i | `pid`: the host's process id |

## Plugin debuggability (Phase 6)

### `<device addr>/stats`

A CLAP plugin's processing over the last second, sent once a second while it processes. A plugin
that stops processing (asleep, or idle) gets one report with zeros and then none until it
processes again. The times are the plugin's own `process()` call as measured inside its host, so
they exclude the IPC handshake.

| # | Type | Meaning |
|---|---|---|
| 0 | f | `load_avg`: process time / block time over the blocks it finished (1.0 = 100%) |
| 1 | f | `load_peak`: worst single block, same unit |
| 2 | f | `process_avg_us`: average `process()` time per block, µs |
| 3 | f | `process_max_us`: longest `process()` call, µs |
| 4 | i | `blocks`: blocks the engine gave it (finished or not) |
| 5 | i | `deadline_misses`: blocks it didn't finish before the callback deadline (dropouts) |
| 6 | i | `total_misses`: deadline misses since the device loaded |
| 7 | i | `struggling`: 1 when it missed 8 or more deadlines in a row in this interval |

WARN and ERROR lines a plugin host logs arrive on `/log` like the engine's own, prefixed with
the plugin and host (`Plugin Dragonfly Room Reverb (instance 3, host instance-3 (pid 1234)): …`).

### `/plugin/save_state [channel:i, device_position:i]` (Godot → engine)

Asks the plugin to serialize its state. The engine replies with `/plugin/state/saved
[channel:i, device_path:s, state_base64:s]`.

### `/plugin/load_state [channel:i, device_position:i, state_base64:s]` (Godot → engine)

Restores a state blob into a loaded plugin.


## Audio device settings (Phase 7)

### `/audio/devices/request` (Godot → engine)

No arguments. The engine lists its output devices on a background thread (it opens each one to
query it, which takes a moment) and answers with one `/audio/device` per device, then
`/audio/devices/complete [count:i]`.

### `/audio/device`

| # | Type | Meaning |
|---|---|---|
| 0 | s | `name`: the device name, as `/audio/config/set` expects it |
| 1 | i | `is_default`: 1 for the system default device |
| 2 | i | `min_buffer`: smallest buffer size (frames per callback) the device takes |
| 3 | i | `max_buffer`: largest, at most 2048 |
| 4 | i | `channels`: output channels the engine would open (0 when it couldn't query the device) |
| 5… | i | the sample rates it supports; none when the device is busy or has no f32 output |

### `/audio/config/set [device:s, rate:i, buffer:i]` (Godot → engine)

Run the output stream on `device` (`""` is the system default) at `rate` Hz with `buffer` frames
per callback (clamped to 32–2048). The engine stops the stream, prepares every device and plugin
for a new rate, and starts it again, then sends `/audio/config`. A request equal to the running one
only sends `/audio/config`. If the device is missing or won't open, the engine falls back to the
default device, then to the default config (48 kHz, 1024 frames), and says so in `notice`. Godot
sends this at start, on every engine (re)connect and before `/project/init`.

### `/audio/config/request` (Godot → engine)

No arguments; the engine answers with `/audio/config`.

### `/audio/config`

The running output configuration. Sent after every change (including PipeWire graph changes) and
on request.

| # | Type | Meaning |
|---|---|---|
| 0 | s | `device`: the running device; `""` when no stream could be opened |
| 1 | i | `rate`: its sample rate in Hz (0 without a stream) |
| 2 | i | `buffer`: frames per callback it was opened with; 0 when it only opened with its own default |
| 3 | f | `latency_ms`: one buffer in milliseconds |
| 4 | i | `output_pairs`: stereo output pairs (hardware outputs 1000 … 1000 + pairs − 1) |
| 5 | i | `is_default_device`: 1 when the running device is the system default |
| 6 | s | `requested_device`: what `/audio/config/set` asked for |
| 7 | i | `requested_rate` |
| 8 | i | `requested_buffer` |
| 9 | i | `graph_quantum`: PipeWire's running quantum (0 when unknown or not on PipeWire) |
| 10 | i | `graph_rate`: PipeWire's graph rate |
| 11 | s | `mismatch`: warning when the graph and the stream conflict (quantum larger than the buffer, other rate), with the `pw-metadata` command that forced it; `""` if none |
| 12 | s | `notice`: why the running config differs from the request (device missing, rate unsupported, no fixed buffer); `""` if none |

The buffer can be larger than requested: when PipeWire's quantum is larger than the ALSA buffer
(four buffers of the requested size), the engine reopens with a buffer that holds a whole graph
cycle, and returns to the requested size once the quantum drops.

### `/audio/config/changed [rate:i]`

The device sample rate changed. Audio clips were decoded at the old rate; they keep playing at the
right pitch (playback compensates for the clip's rate), and Godot re-sends `load_audio_file` for
each one so they're resampled properly. Files decode at the new rate from this message on.

### Hardware outputs

IDs 1000 and up are stereo output pairs on the running device: 1000 is outputs 1/2, 1001 is 3/4,
and so on (`/channel/1/route [1001]` puts master on outputs 3/4). A pair the device doesn't have
plays on 1/2, and the engine logs a warning; the route is kept for a device that has it.
