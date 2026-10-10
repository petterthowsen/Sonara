# OSC Protocol Specification

Communication between Godot (UI) and Rust (Audio Engine) over UDP on localhost.

**Ports:**
- Godot sends to: `127.0.0.1:7000` (Rust listens)
- Rust sends to: `127.0.0.1:7001` (Godot listens)

Parameter values cross as normalized 0.0–1.0 floats. The source of truth is `Engine/src/osc/routes/` for messages from Godot (one file per
address area, argument parsing in `osc/parse.rs`) and `Engine/src/osc/encode.rs` for messages to
Godot: when you add or change a message, update the route or `encode_status` there, the command in
`audio/commands/`, and this file.

**Device addresses.** `{device}` below is short for `/channel/{id}/device/{path}`, built by
`DevicePath::to_osc_addr` (`Engine/src/audio/devices/containers/container.rs`). `{path}` is `{position}` at the
channel root, or `{position}/child/{i}/child/{j}/...` for devices nested in containers.

## Message Types

### Transport Control (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/transport/play` | - | Start playback |
| `/transport/pause` | - | Pause playback |
| `/transport/stop` | - | Stop and reset to 0 |
| `/transport/seek` | `i:ticks` | Seek to tick position |
| `/transport/loop` | `i:enabled, i:start, i:end` | Godot → engine. Loop playback over `[start, end)` ticks. While enabled with `end > start`, the audio callback wraps the playhead from the loop end to the loop start on the exact frame (clip notes released, MIDI and audio clips re-seated at the loop start). A playhead already at or past the end plays on without wrapping. `enabled = 0`, or an empty region, clears the loop. Not persisted by the engine: Godot resends it on connect, and `/project/clear` clears it |
| `/transport/tempo` | `f:bpm` | Set tempo |
| `/transport/time_signature_map` | `i:bar, i:numerator, i:denominator, …` (triples) | Godot → engine. Replace the whole time signature map: changes after the base signature (`/transport/time_signature`), 1-based bars ≥ 2. No args clears it. Numerator 1–32 and denominator 1/2/4/8/16/32 only; invalid triples are dropped with a warning, and a repeated bar keeps the last |
| `/transport/tempo_map` | `i:tick, f:bpm, …` (pairs) | Godot → engine. Replace the whole tempo map. No args clears it and the static tempo applies |
| `/transport/time_signature` | `i:numerator, i:denominator` | Set time signature |

### Transport Status (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/status/playhead` | `i:ticks` | Current playhead position (sent at ~20 Hz while playing) |
| `/status/playing` | `i:0_or_1` | Playback state (0=stopped, 1=playing) |
| `/status/connected` | `i:1` | Engine ready confirmation (sent after `/project/init`) |
| `/status/heartbeat` | `i:1` | Periodic heartbeat (sent every 1 second to detect disconnection) |
| `/status/engine_stats` | see below | Audio callback load and dropout counters (2 Hz) |

#### `/status/engine_stats`

Sent by the audio callback at 2 Hz, also while the engine state lock is busy. Counters are running
totals since the engine started (they survive a stream restart), so a dropped packet loses nothing.
Rate = difference between two reports. Counters are clamped to int32.

| # | Type | Meaning |
|---|---|---|
| 0 | f | `load_avg`: processing time / block time over the last 0.5 s (1.0 = 100%) |
| 1 | f | `load_peak`: worst single block in that interval, same unit |
| 2 | i | `xruns`: cpal stream errors plus callback gaps longer than 1.5× the previous block |
| 3 | i | `lock_misses`: callbacks that output silence because the state lock stayed busy |
| 4 | i | `callbacks` |
| 5 | i | `frames`: frames in the last block |
| 6 | i | `plugin_underruns`: CLAP plugin blocks padded with silence because the plugin's output wasn't ready (audible dropouts) |

### Engine Logging (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/log` | `s:level, s:message` | Warning/error logs from engine (level: "warn" or "error") |

WARN and ERROR lines a plugin host logs arrive on `/log` like the engine's own, prefixed with the
plugin and host (`Plugin Dragonfly Room Reverb (instance 3, host instance-3 (pid 1234)): …`).

### Project Setup (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/project/init` | `f:tempo, i:numerator, i:denominator, i:ppq, i:sample_rate` | Initialize project settings |
| `/project/clear` | - | Clear all channels and tracks |
| `/project/scale` | `i:mask` | Godot → engine. Project scale as a 12-bit pitch-class mask (bit 0 = C, C major = 2741), 0 = no scale. Sent after `/project/init` and whenever the scale changes. Only note effects read it (Transpose in Follow Project mode, spec 027) |

### Channel Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/create` | `s:name` | Create channel with ID |
| `/channel/{id}/remove` | - | Remove channel by ID |
| `/channel/{id}/volume` | `f:db` | Set channel volume in dB |
| `/channel/{id}/pan` | `f:pan, f:pan_right?` | Set pan (-1.0 to 1.0). The second value is the right pan in `STEREO_DUAL` mode |
| `/channel/{id}/pan_mode` | `i:mode` | 0 = stereo combined (default), 1 = stereo dual (separate L/R), 2 = stereo balance, 3 = mono |
| `/channel/{id}/mute` | `i:0_or_1` | Set mute state |
| `/channel/{id}/solo` | `i:0_or_1` | Set solo state |
| `/channel/{id}/route` | `i:output_channel_id` | Set output routing (-1 for none; 1000+ = hardware outputs, see below) |
| `/channel/{id}/aux_out` | `i:bus_index, i:target_channel_id` | Map extra device bus `bus_index` to a child channel (0 clears) |
| `/channel/{id}/send/{target_id}/add` | `f:amount_db, i:pre_fader` | Add send to BUS channel (default: -12 dB, post-fader) |
| `/channel/{id}/send/{target_id}/remove` | - | Remove send to target channel |
| `/channel/{id}/send/{target_id}/amount` | `f:amount_db` | Set send level in dB (-60 to +12) |
| `/channel/{id}/send/{target_id}/pre_fader` | `i:0_or_1` | Set pre/post fader (1=pre, 0=post) |
| `/channel/{id}/send/{target_id}/mute` | `i:0_or_1` | Mute/unmute send |

**Hardware outputs.** IDs 1000 and up are stereo output pairs on the running device: 1000 is
outputs 1/2, 1001 is 3/4, and so on (`/channel/1/route [1001]` puts master on outputs 3/4). A pair
the device doesn't have plays on 1/2, and the engine logs a warning; the route is kept for a device
that has it.

### Channel Metering (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/peak` | `f:peak_left, f:peak_right, f:rms_left, f:rms_right` | Peak and RMS levels (linear 0.0-1.0+) |

### Live MIDI (Godot -> Rust)

Device IDs: `-3` none, `-2` all devices, `-1` virtual keyboard, `0+` physical.

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/midi_input_device` | `i:device_id` | Which MIDI source this channel accepts |
| `/channel/{id}/record_armed` | `i:0_or_1` | Arm channel to receive live MIDI |
| `/channel/{id}/midi_event` | `i:channel_id, i:message, i:midi_channel, i:pitch, i:velocity, i:timestamp_us` | Note / generic MIDI event. Engine stamps arrival; Godot timestamp is ignored |
| `/channel/{id}/midi_cc` | `i:channel_id, i:midi_channel, i:cc_number, i:cc_value, i:timestamp_us` | Control change (message type 11) |

### Track Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/track/{id}/create` | `i:channel_id` | Create track with ID, routed to channel |
| `/track/{id}/route` | `i:channel_id` | Update track output routing to channel (-1 for none) |

### Automation (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/track/{id}/automation/create` | `s:lane_id, s:target` | Create a lane on the track. An unparseable target is ignored with a warning |
| `/track/{id}/automation/{lane_id}/delete` | - | Delete the lane |
| `/track/{id}/automation/{lane_id}/bypass` | `i:0_or_1` | Bypass the lane (the target keeps its manual value) |
| `/track/{id}/automation/{lane_id}/add_point` | `i:point_id, i:tick, f:value, s:curve, f:tension?` | Add a point |
| `/track/{id}/automation/{lane_id}/update_point` | `i:point_id, i:tick, f:value, s:curve, f:tension?` | Replace the point with the same id |
| `/track/{id}/automation/{lane_id}/remove_point` | `i:point_id` | Remove a point |
| `/track/{id}/automation/{lane_id}/clear` | - | Remove every point in the lane |

- `value` is normalized 0.0–1.0.
- `curve` is the shape of the segment starting at the point: `linear` or `step` (unknown names fall back to `linear`).
- `tension` is -1.0 to 1.0, default 0.0 (an exactly linear ramp).
- `target` is relative to the track's channel (`AutomationTarget::parse` in `audio/automation.rs`):
  - `channel/volume`
  - `channel/pan`
  - `channel/cc/{n}`: MIDI controller `n` on the channel (spec 030); `n` is an integer 0–119 — 120–127 and non-integers are rejected. Same `/track/{id}/automation/create` address as other targets.
  - `device/{i0}[/{i1}…]/param/{param_id}`: device path indices, then the parameter

### Clip Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/clip/create` | `s:clip_id, s:clip_type, s:name` | Create clip in global pool (type: "midi" or "audio") |
| `/clip/delete` | `s:clip_id` | Delete clip from pool |
| `/clip/{id}/add_note` | `i:note_id, i:note, i:start_tick, i:duration, i:velocity` | Add MIDI note to clip (relative to clip start) |
| `/clip/{id}/remove_note` | `i:note_id` | Remove MIDI note from clip |
| `/clip/{id}/update_note` | `i:note_id, i:note, i:start_tick, i:duration, i:velocity` | Update MIDI note in clip |
| `/clip/{id}/load_audio_file` | `s:abs_path, i:sample_rate_hint, i:channels_hint` | Request async audio decode + waveform generation via AudioFileService |
| `/clip/{id}/set_timing` | `s:mode, f:bpm` | Set an audio clip's stretch mode (`raw`, `repitch` or `stretch`) and tempo (BPM of the material, default 120). `raw` plays at native speed whatever the project tempo; `repitch` plays at `project_bpm / bpm` times natural speed; `stretch` plays like `repitch` until the pitch-preserving stretcher lands (spec 029 phase 4). Playing instances re-seat. An unknown mode is ignored with a warning. The engine does not derive the clip length from the tempo: Godot computes `duration_s x bpm / 60 x ppq` and sends it with the instance positions. Replaces `/clip/{id}/set_tempo f:bpm` |

### ClipInstance Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/track/{id}/add_instance` | `s:instance_id, s:clip_id, i:start_tick, i:duration` | Add clip instance to track timeline |
| `/track/{id}/remove_instance` | `s:instance_id` | Remove clip instance from track |
| `/track/{id}/instance/{id}/set_position` | `i:start_tick, i:duration, i:clip_offset` | Update instance position and content offset (ticks) |
| `/track/{id}/instance/{id}/set_transpose` | `i:semitones` | Set instance transpose (-12 to +12) |
| `/track/{id}/instance/{id}/set_gain` | `f:db` | Set instance gain offset in dB |
| `/track/{id}/instance/{id}/set_mute` | `i:0_or_1` | Set instance mute state |
| `/track/{id}/instance/{id}/set_loop` | `i:enabled, i:start_tick, i:length` | Configure instance looping. `start_tick` and `length` are clip content ticks (the same space as `clip_offset`), so the instance repeats that region of the content until its duration ends |
| `/track/{id}/instance/{id}/set_reverse` | `i:0_or_1` | Audio clips: read the source samples backwards (mirrored around the clip's centre). Loop wrapping and tempo stretch still advance forward in content time |

### Clip Load Status (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/clip/{id}/load_state` | `s:state, s:req_id, s:source_path, s:cache_key, i:sample_rate, i:channels, s:message` | Lifecycle updates for audio clips (`state`: `unloaded`, `loading`, `ready`, `failed`) |

`req_id` echoes the async identifier supplied when Godot called `/clip/{id}/load_audio_file`. `source_path` is the absolute path provided by Godot, `cache_key` is the waveform cache handle (empty until the clip is ready), and `message` contains an error description when `state` is `failed`.

**Clip Offset:** The `clip_offset` parameter (in ticks) allows a ClipInstance to play only a portion of its source Clip's content. A value of `0` plays from the beginning, while positive values skip the beginning of the clip (useful for trimming or resizing from the left edge). This allows multiple instances of the same Clip to play different portions.

### Device Management (Godot -> Rust)

Top-level device addresses are unchanged. Nested devices (inside Chain/Layer) insert `/child/{index}` segments after `/device/{n}` so action names never collide with child indices.

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/add_device` | `s:device_id, i:position, i:active?, i:enabled?, s:type?, s:file?` | Add device to the channel root list |
| `/channel/{id}/remove_device` | `i:position` | Remove a top-level device |
| `/channel/{id}/move_device` | `i:from_position, i:to_position` | Reorder top-level devices |
| `/channel/{id}/clear_devices` | - | Remove all devices from channel |
| `/channel/{id}/device/{path}/param/{param_id}` | `f:normalized_value` or `i:index` | Set device parameter |
| `/channel/{id}/device/{path}/modulator/add` | `i:mod_id, s:kind` | Add a modulator with its kind's default parameters (`lfo`, `adsr`, `ad`, `velocity`, `keytrack`, `random`, `release`, `cc`). Wraps the device if it has none (see Modulators) |
| `/channel/{id}/device/{path}/modulator/{mod_id}/remove` | - | Remove a modulator, its routes and every route into the removed slot; the last one unwraps the device |
| `/channel/{id}/device/{path}/modulator/{mod_id}/param/{id}/value` | `f:normalized` | Set a modulator parameter (floats clamp, enums and bools snap; the echo carries the canonical value) |
| `/channel/{id}/device/{path}/modulator/{mod_id}/route/set` | `s:target, f:amount` | Add, update or (amount 0) remove a route to `param/{id}`, `child/{i.j…}/param/{id}` or `mod/{mod_id}/param/{id}`; amount is clamped to −1..1. A `mod/{mod_id}/param/{id}` target (another modulator's parameter, spec 033) is evaluated, not just stored: it lands one control step (64 frames, ≈1.3 ms) later, which keeps evaluation independent of slot order and bounds mod→mod cycles to delayed feedback |
| `/channel/{id}/device/{path}/modulator/clear` | - | Remove every modulator and route |
| `/channel/{id}/device/{path}/activate` | `i:active` | Activate/deactivate device (1=load, 0=unload) |
| `/channel/{id}/device/{path}/enable` | `i:enabled` | Enable/disable device (1=on, 0=bypass) |
| `/channel/{id}/device/{path}/add_device` | `s:device_id, i:position, i:active?, i:enabled?, s:type?, s:file?` | Add a child into a container device |
| `/channel/{id}/device/{path}/remove_device` | `i:position` | Remove a child from a container |
| `/channel/{id}/device/{path}/move_device` | `i:from_position, i:to_position` | Reorder children inside a container |
| `/channel/{id}/device/{path}/slot/{n}/volume` | `f:normalized` | Layer slot volume (0–1, 0.5 = unity) |
| `/channel/{id}/device/{path}/slot/{n}/mute` | `i:0_or_1` | Layer slot mute |
| `/channel/{id}/device/{path}/slot/{n}/solo` | `i:0_or_1` | Layer slot solo (any solo mutes non-soloed slots) |
| `/channel/{id}/device/{path}/slot/{n}/note` | `i:midi` | Drum Machine: MIDI note that triggers child `n` |
| `/channel/{id}/device/{path}/slot/{n}/choke_targets` | `b:16_bytes` | Drum Machine: choke targets of child `n` as a little-endian `u128` note mask (bit *k* = the slot on note *k*). A note-on on the slot chokes every other slot whose note bit is set; its own bit is ignored. Any other length is logged and ignored |
| `/channel/{id}/device/{path}/slot/{n}/note_map` | `b:128_bytes` | Layer slot note map: byte *k* = output note for input note *k*, 255 = slot ignores it. Identity = the full map (default). Any other length is logged and ignored |
| `/channel/{id}/device/{path}/slot/{n}/separate_out` | `i:0_or_1` | Layer slot audio goes to extra bus *n* (its return channel, see `/channel/{id}/aux_out`) instead of the Layer output. Only when the Layer is the channel's first device |
| `/channel/{id}/device/{path}/slot/{n}/audition` | `i:note, i:velocity, i:on` | Play a note on Layer slot `n` directly, bypassing its note map (mapping window) |
| `/channel/{id}/device/{path}/load_file` | `s:abs_path, s:req_id?` | Load an SFZ into Sfizz, or an audio file into Sampler |
| `/channel/{id}/device/{path}/reload` | - | Reload a crashed plugin (see Plugin crash and reload) |
| `/channel/{id}/device/{path}/state/get` | - | Re-send the device's `loading_state`, for SFZ/CLAP devices its parameter list, and for devices with modulators the modulator list (see Recovering missed state) |

`{path}` is `{position}` at the channel root, or `{position}/child/{i}/child/{j}/...` for nested devices.

Examples:
- Top-level param: `/channel/2/device/0/param/1`
- Nested param: `/channel/2/device/0/child/1/param/1`
- Add into container: `/channel/2/device/0/add_device` `[id, position, ...]`

### Device State Updates (Rust -> Godot)

Status echoes use the same path as the command (`/active`, `/enabled`, `/loading_state`,
`/param/{id}/value`, `/modulator/...`, `/data`).

**Modulators** (`{device}/modulator/...`). A modulator belongs to one device instance and drives
parameters of that device, of a device nested inside it, or of another modulator (spec 033:
a `mod/{mod_id}/param/{id}` route target is evaluated with one control step of delay — see
`modulator/{id}/route/set` above). Its kind is one of `lfo`, `adsr`, `ad`, `velocity`,
`keytrack`, `random`, `release`, `cc`; each kind has
parameter table (advertised in the `/builtin/modulator_*` batch). `modulator/add` wraps the
device in a transparent `ModulatedDevice` the first time and `modulator/remove` (or
`modulator/clear`) unwraps it again, so a device without modulators costs nothing. Routes are
device state, not parameters, and are evaluated on the command thread's control step (64 frames),
next to the base value (ADR-0014). The engine echoes the applied state on the same address:
`modulator/add` (mod_id, kind), `modulator/{id}/remove`, `modulator/{id}/param/{p}/value` (the
canonical normalized value), `modulator/{id}/route/set` (target, clamped amount) and
`modulator/clear`. A route whose target can't resolve or isn't modulatable is logged as an error
and echoed with amount 0, so the UI drops it. Godot swallows the echoes of its own edits like
parameter echoes, and re-sends `modulator/clear` plus every modulator, parameter and route from
`DeviceInstance.sync_to_engine()`, so the project is authoritative.

**The `cc` kind** (spec 032) latches the channel's MIDI controller stream. Its parameters are
`CC Number` (slot 0, controller 0–119; channel-mode controllers 120–127 are excluded as in spec
030) and `CC Smooth` (slot 10, a one-pole lag of 0–500 ms; 0 snaps). Live CC and
`channel/cc/{n}` automation lane values both arrive through `Channel::send_cc_to_devices`, so
the modulator follows a lane identically to a knob (a lane owns the *controller*, not the
modulator). The value applies on the control step (64 frames). `cc` is evaluated on the mono
path only (`is_mono_only`): a wrapper hands its poly-capable inner device a `VoiceModSpec` that
excludes `cc` slots and routes, and applies those routes itself.

**Loading States** (`{device}/loading_state [s:state]`, sent on every transition):
- **`idle`**: No content loaded (e.g., SFZ sampler with no file loaded)
- **`loading`**: Device is loading in background thread (e.g., loading large SFZ file or initializing plugin subprocess)
- **`ready`**: Device fully loaded and ready to process audio
- **`failed:{error}`**: Loading never finished (e.g., "failed:File not found")
- **`crashed:{reason}`**: The plugin's host process died after loading. A crashed device passes audio through and the UI offers a Reload

Loading state updates are sent automatically during:
- CLAP plugin subprocess initialization (typically 100-500ms for complex plugins)
- SFZ file loading via `/channel/{id}/device/{path}/load_file` (can take several seconds for large sample libraries)
- Sampler audio loading via the same `load_file` address (optional `req_id` second arg). The engine decodes through AudioFileService; Godot maps `/audiofile/*` events by `req_id` to a `DeviceInstance` the same way it maps clip loads.
- Device activation/deactivation that requires loading/unloading resources

Use `loading_state_changed` signal in `DeviceInstance.gd` to show loading spinners or error messages in the UI.

**Recovering missed state** (`{device}/state/get`, no args). OSC runs over UDP, and the OS drops
packets when Godot stops polling for a while (e.g. building a large project while the engine
answers dozens of device loads). The engine replies with:
- `{device}/loading_state [s:state]`, for devices with a load lifecycle (Sfizz, Sampler, CLAP)
- `{device}/param/count` + `param/info`, only for devices whose parameters come from loaded
  content (Sfizz, CLAP) and only once that list is non-empty. Built-ins with fixed parameters
  keep Godot's registry metadata and get nothing.
- `{device}/modulator/clear` followed by one `{device}/modulator/add` per modulator, each of its
  `param/{id}/value` messages and each `route/set`, only for devices that carry modulators. Godot
  applies the clear, so modulators missing in the engine disappear locally too.

Godot asks for every device once, 1 s after the project connects (`Project._resync_device_states`),
and every 2 s for a device that stays `loading` (`DeviceInstance._schedule_loading_recheck`).
A re-advertised parameter list keeps Godot's current values and sends them back to the engine.

#### Built-In Devices

**PolySynth (`sonara.builtin.polysynth`)**
- **Type:** Instrument (receives MIDI)
- **Params (typed):** IDs are grouped ten per module (`ParamInfo.module`); the gaps are reserved
  for Filter (30s), Filter Env (50s) and LFOs (60s, 70s). Real ranges travel in `/builtin/info`;
  the source of truth is `audio/devices/instruments/polysynth/params.rs`.
  - `0`–`8` Osc 1, `10`–`18` Osc 2 (same offsets): `+0` Wave (enum: Sine, Triangle, Saw, Pulse),
    `+1` Pulse Width (5–95 %), `+2` Octave (enum −3…+3), `+3` Semi (enum −12…+12),
    `+4` Fine (±100 cents), `+5` Level (0–1), `+6` Unison (enum 1–16),
    `+7` Unison Detune (0–100 cents), `+8` Unison Spread (0–100 %)
  - `20`: Noise Level (0–1), `21`: Noise Color (0–100 %, dark → white → bright)
  - `40`–`43`: Amp Attack, Decay, Sustain, Release (times 0.5 ms–10 s, skew 4)
  - `80`: Voice Mode (enum: Poly, Mono, Legato), `81`: Polyphony (enum 1–64),
    `82`: Glide (0–1 s, skew 3), `83`: Velocity (0–100 % amp sensitivity)
  - `90`: Volume (−60…+6 dB, skew 0.5; the bottom is silence)

**Delay (`sonara.builtin.delay`)**
- **Type:** Effect
- **Params:**
  - `0`: Delay Time (1-5000ms, normalized 0.0-1.0)
  - `1`: Wet Amount (0.0-1.0)

**Spectrum Analyzer (`sonara.builtin.spectrum_analyzer`)**
- **Type:** Utility (analyzer)
- **Params (typed):**
  - `0`: FFT Size (enum: Tiny=512, Small=1024, Medium=2048, Large=4096)
  - `1`: Speed (enum: Freeze, Slow, Medium, Fast)
  - UI-only (not synced): Scale (enum: Log, Linear), Style (enum: Bars, Line)

**Chain (`sonara.builtin.chain`)**
- **Type:** Utility container (`is_container: true`, accepts MIDI)
- Serial child processing, then a single Volume. Empty chain is audio pass-through. Bypass skips children.
- MIDI is forwarded to every child.
- **Params:**
  - `0`: Volume (float 0.0–2.0 linear gain, default 1.0 / normalized 0.5 = unity)

**Layer (`sonara.builtin.layer`)**
- **Type:** Utility container (`is_container: true`, accepts MIDI)
- Parallel children mixed together. Empty layer is silence. Bypass is pass-through.
- MIDI goes to each child through its slot note map (`/slot/{n}/note_map`; default: every note unchanged), muted slots included. A note-off goes to wherever its note-on went, even if the map changed in between.
- No device-level params. Per-child mix via `/slot/{n}/volume|mute|solo`.
- Multi-out: one extra bus per child (bus = child index). A child with `/slot/{n}/separate_out 1` writes to its bus (after volume/mute/solo) when the Layer is the channel's first device; otherwise it mixes into the Layer output.

**Multiband FX (`sonara.builtin.multiband`)** (spec 016)
- **Type:** Effect container (`is_container: true`, no MIDI, no extra buses)
- Six fixed **band positions** in frequency order (band 1 lowest, band 6 highest); any 2–6 are active (default {1, 3, 5}). The input is split into the active bands with Linkwitz-Riley (LR4) crossovers, each band runs through its own child, and the bands are summed. Magnitude is flat when every band is empty (phase-aligned, zero latency).
- **Band position = child index + 1.** Godot always creates six children (slot chains). A missing child is a pass-through band; a 7th `insert_child` is dropped with a warning. Inactive bands are never processed, even if their child holds devices.
- **Low Edge semantics:** an active band covers `[its Low Edge, Low Edge of the next active band)`. The lowest active band extends to 0 Hz and ignores its Low Edge; the highest extends to Nyquist. With K active bands there are K−1 crossovers. The engine keeps them ascending (each at least 1.1× the previous, at most 20 kHz and below 0.45 × sample rate) whatever the stored values are.
- Per-band mix is by **parameters**, not `/slot/*`. Muted or soloed-out bands still process their child so compressor state and tails don't jump. Solo only considers active bands.
- Changing the active set fades the output out over 5 ms, switches topology, and fades back in.
- **Params** (band *p* = 1..6 uses block `10·p`):
  - `0`: Mix (0–100 %, default 100; the dry is phase-aligned to the bands)
  - `1`: Output (±24 dB, default 0)
  - `10·p + 0`: Band *p* Active (bool; defaults on for 1, 3, 5; **not automation-safe**)
  - `10·p + 1`: Band *p* Low Edge (p ≥ 2 only, log 20–20000 Hz; defaults 60 / 200 / 700 / 2500 / 8000)
  - `10·p + 2`: Band *p* Gain (±24 dB)
  - `10·p + 3`: Band *p* Mute (bool)
  - `10·p + 4`: Band *p* Solo (bool)
- No device data stream yet (planned `"bands"` stream, spec 016 E2.3).

**Sampler (`sonara.builtin.sampler`)**
- **Type:** Instrument (receives MIDI), file loading (`wav`/`mp3`/`ogg`)
- One-shot or gated playback of a single decoded sample. PCM stays in the engine; Godot draws the waveform from the AudioFileService cache.
- Playback rate: `speed * 2^((tune + keytrack*(note-root))/12)` (no timestretch).
- Retriggers overlap up to the Voices count; lowering Voices immediately silences extra slots.
- **Params:**
  - `0`: Volume (float 0.0–2.0 linear gain, default 1.0 / normalized 0.5 = unity)
  - `1`: Tune (float ±24 semitones)
  - `2`: Speed (float 0.25–4x, logarithmic, default 1.0)
  - `3`: Root (float MIDI 0–127, default 60 = C3)
  - `4`: Key Track (bool, default on)
  - `5`: Play Mode (enum: One-shot, Gated)
  - `6`: Velocity (float 0–1 amount)
  - `7`: Start (float 0–1 region)
  - `8`: End (float 0–1 region)
  - `9`: Attack (float 0.001–2s)
  - `10`: Decay (float 0.001–2s)
  - `11`: Sustain (float 0–1)
  - `12`: Release (float 0.001–2s)
  - `13`: Voices (float 1–64, default 16)

**Drum Machine (`sonara.builtin.drum_machine`)**
- **Type:** Instrument container (`is_container: true`, accepts MIDI)
- Parallel mix like Layer. MIDI is routed to the child whose `/slot/{n}/note` matches (unique notes; default C1 / 36 upward).
- Empty drum machine is silence. A pad may hold any device (Sampler, Chain, CLAP, …).
- No device-level params. Per-child note via `/slot/{n}/note`.
- Choke targets (closed/open hats) via `/slot/{n}/choke_targets`, a 16-byte note mask per slot.
  The relation is directed: a note-on chokes every other slot whose note is in the triggering
  slot's mask, with a ~3 ms fade starting at the same frame offset as the note. Godot stores
  targets by pad id and re-sends every mask when a pad's note changes or a pad is added or
  removed (see ADR-0015, which supersedes ADR-0012).

##### Built-in Parameter Advertisement (Rust → Godot)
`/builtin/info` sends device metadata and typed parameter descriptors. `category` is `instrument`, `effect`, `utility` or `note_effect` (spec 027: note effects, listed under Note Effects in the browser):
```
/builtin/info [
  s:id, s:name, s:category, s:description,
  i:accepts_midi, i:audio_in, i:audio_out,
  i:supports_file_loading, s:file_type_description,
  i:extension_count, ...extensions,
  i:param_count,
  repeat param_count times: (
    i:param_id, s:name, s:unit,
    s:type, i:syncable,
    f:min, f:max, f:default,
    i:is_logarithmic, f:skew,
    i:enum_count, ...enum_values,
    s:module, i:automatable, i:modulatable
  ),
  i:is_container,
  i:default_modulator_count,
  repeat default_modulator_count times: (
    s:kind, s:name,
    i:param_count, repeat: (i:param_id, f:normalized),
    i:route_count, repeat: (s:target, f:amount)
  )
]
```
- `type`: "float" | "bool" | "enum"
- `module`: group the parameter belongs to (EQ `Band 1`, `Output`), "" if none; the automation picker prefixes it when a name repeats. `automatable` 0 keeps the parameter out of the picker. `modulatable` 1 means a modulator can drive it (an automatable float).
- For `enum`, UI renders from `enum_values`. Runtime sets use either `i:index` or equivalent normalized `f`.
- `is_container`: 1 when the device can own nested children (Chain, Layer, Drum Machine).
- The default-modulator block follows `is_container`: one entry per modulator a fresh instance
  starts with, with its kind, name, normalized parameters (by the kind's IDs) and its routes into
  the device. Godot seeds a new `DeviceInstance` from them and does not re-send them on load. A
  device without a default patch sends `0`. PolySynth's default patch (Filter Env → Cutoff) lands
  here in spec 018 Phase 6.

##### Modulator Kinds (Rust → Godot)
The same `/builtin/request` batch advertises the modulator kinds, after the devices:
```
/builtin/modulator_info [i:kind_count]
repeat kind_count times:
  /builtin/modulator_kind [
    s:id, s:name, i:bipolar, i:param_count,
    repeat param_count times: (the same parameter tuple as /builtin/info)
  ]
/builtin/modulator_complete [i:kind_count]
```
`bipolar` 1 means the kind runs −1..1 (LFO, keytrack, random), else 0..1 (the envelopes,
velocity, release and cc). The kinds are engine-global, not per device. Godot stores each
kind's parameters as ordinary `DeviceParameter`s, so the Modulators pane builds its controls
from the same component set as a device. The `cc` kind's parameters (`CC Number` slot 0,
`CC Smooth` slot 10) arrive like any other table and need no special Godot handling.

#### Plugins (CLAP and VST3)

**Plugin Discovery (Godot -> Rust)**
```
/plugin/scan [clap_path:s]* ["--vst3" [vst3_path:s]*]
```
Scans the given CLAP directories (plus `CLAP_PATH`) and VST3 directories (plus `VST3_PATH`) and
discovers available plugins. Strings before the `--vst3` marker are CLAP paths, those after it
VST3 paths. An empty section falls back to the defaults (`~/.clap`, `/usr/lib/clap`,
`/usr/local/lib/clap`; `~/.vst3`, `/usr/lib/vst3`, `/usr/local/lib/vst3`). VST3 bundles are
scanned out of process (from `moduleinfo.json`, or by a throwaway `plugin_host --scan-vst3`),
never loaded into the engine.

**Response:** one `/plugin/info` per discovered plugin, then `/plugin/scan_complete [i:count]`.
Godot caches these to avoid scanning on every startup.

`/plugin/info`:

| # | Type | Meaning |
|---|---|---|
| 0 | s | Plugin id |
| 1 | s | Name |
| 2 | s | Vendor |
| 3 | s | Version |
| 4 | s | Category |
| 5 | s | Description, empty if none |
| 6 | s | Path to the `.clap` file, or the `.vst3` bundle directory |
| 7 | s | Feature tags joined with `,`: CLAP feature tags (e.g. `audio-effect,reverb,stereo`) or the lowercased VST3 subcategories (e.g. `fx,reverb`), may be empty |
| 8 | s | Format: `clap` or `vst3` |

For VST3 the id (arg 0) is the processor class ID as 32 uppercase hex characters. A plugin
installed in both formats is reported twice, once per format.

**Adding Devices**
```
/channel/{id}/add_device [s:device_id, i:position, i:active?, i:enabled?, s:type?, s:file?]
```
- **device_id**: Unique identifier (e.g., "sonara.builtin.polysynth", "michaelwillis.dragonfly.hall")
- **position**: Position in device chain (-1 = append)
- **active**: 1=load device (default), 0=don't load (save RAM)
- **enabled**: 1=process audio (default), 0=bypass
- **type**: Device type - "builtin", "clap", "lv2", "vst3" (defaults to "builtin")
- **file**: Path to plugin file (required for plugins, empty for built-ins). For `"vst3"` this is the `.vst3` bundle directory and `device_id` is the class ID (32 hex characters).

Examples:
```bash
# Built-in device (type and file optional)
/channel/2/add_device ["sonara.builtin.polysynth", -1, 1, 1, "builtin", ""]

# CLAP plugin with explicit type and file
/channel/2/add_device ["michaelwillis.dragonfly.room", -1, 1, 1, "clap", "/home/user/.clap/dragonfly-reverb.clap"]

# Load inactive (template with 200 plugins)
/channel/2/add_device ["com.heavysynth", -1, 0, 1, "clap", "/usr/lib/clap/heavysynth.clap"]

# Load bypassed
/channel/2/add_device ["in.lsp-plug.compressor_mono", -1, 1, 0, "clap", "/usr/lib/clap/lsp-plugins.clap"]
```

**Plugin State Management**
```
{device}/state/save [s:file_path]          Godot → Rust
{device}/state/saved [s:file_path, i:size]  Rust → Godot
{device}/state/load [s:file_path]          Godot → Rust
```
State blobs travel as files, since they rarely fit one OSC datagram (the engine reads 2 KB
packets). Paths are absolute. Godot uses `user://plugin_state/`.
- `state/save` asks a loaded CLAP plugin for its state and writes the raw blob to `file_path`.
  The engine always answers with `state/saved`. `size` is the byte count written, `0` when the
  device has no state (not a CLAP plugin, or no state extension), or `-1` when saving failed
  (no device, plugin not ready, write error). Godot reads the file and deletes it.
- `state/load` reads the raw blob from `file_path` and restores it into the loaded plugin. The
  blob also becomes the plugin's saved state for crash reload. Godot sends it when a
  project-loaded plugin first reports `ready`, and deletes the file 30 s later.
- In `.sonara` projects the blob is stored per device as base64 under `plugin_state`. Godot
  refreshes it from every ready plugin before writing the file (3 s timeout; a plugin that doesn't
  answer keeps its last saved blob).

**Device Lifecycle Control**
```
/channel/{id}/device/{position}/activate [i:active]
/channel/{id}/device/{position}/enable [i:enabled]
```
- **activate**: Load/unload device (affects RAM, parameters visible/hidden)
- **enable**: Bypass device (zero-latency, maintains state)

**Plugin GUI Control (CLAP plugins only)**

Godot → engine (`{device}` = `/channel/{id}/device/{path}`):
```
{device}/gui/open                                   # floating: the engine's own OS window
{device}/gui/open [i:parent_xid, i:x, i:y, i:w, i:h]  # embedded into a Godot window from the start
{device}/gui/embed [i:parent_xid, i:x, i:y, i:w, i:h, (i:scroll_x, i:scroll_y)]
{device}/gui/bounds [i:x, i:y, i:w, i:h, (i:scroll_x, i:scroll_y)]
{device}/gui/unembed
{device}/gui/visible [i:visible]
{device}/gui/size [i:w, i:h]
{device}/gui/close
```
- **open** without args opens the GUI in a floating window, as before spec 022. With args, the
  engine's host window is embedded into the X11 window `parent_xid` before it is first mapped, so
  no floating window flashes. The rect is the viewport in that window's pixels. Opening an open
  GUI reuses its window and shows it again.
- **embed** moves an open GUI's host window into another Godot window (attach, detach, tab
  tear-off) without reopening it. Scroll defaults to 0.
- **bounds** sets the viewport (window pixels) and the scroll offset of the GUI inside it. A GUI
  larger than the viewport is clipped; scrolling moves it.
- **unembed** makes an embedded host window a floating OS window again (embedding switched off).
- **visible** hides (`0`) or shows (`1`) the GUI without closing it, for a hidden tab or frame:
  CLAP `gui.hide()`/`show()` plus unmapping or mapping the host window.
- **size** asks a resizable plugin to resize. The plugin host runs `adjust_size` then `set_size`,
  and the size the plugin settles on comes back as `gui/size`.
- **close** first unmaps the host window and reparents it to the root (so Godot can free its window
  without destroying the plugin's), then closes the GUI. The host window is destroyed once the
  plugin confirms.
- Arguments are ints; longs and floats are accepted too. A short or malformed list is logged as a
  warning and ignored (`gui/open` then opens floating).
- Embedding needs X11 and is experimental (ADR 0016). Godot sends embed args only when
  `plugins/embed_gui` is on and available.
- Can be called while the plugin is active and processing audio. GUI state is managed by the
  plugin, not the host.

Engine → Godot:
```
{device}/gui/opened [i:w, i:h, i:resizable, i:floating]
{device}/gui/size [i:w, i:h]
{device}/gui/embedded [i:parent_xid]
{device}/gui/closed
```
- **opened** follows every successful open: the GUI's size, whether it accepts resizes, and
  `floating=1` when the plugin refused embedded mode and runs in its own window (the engine then
  destroys the unused host window).
- **size** reports the GUI's current size after a `gui/size` request, and when the plugin resizes
  itself.
- **embedded** confirms that the host window is now in `parent_xid` (`0` = in no Godot window),
  once the X server has the reparent. Sent after an embedded `gui/open`, `gui/embed`,
  `gui/unembed`, and the release on `gui/close`. Godot destroys a native window's X window when it
  hides it, so a frame window that holds plugin GUIs waits for this before it hides or is freed.
- **closed** (no args) is sent when a GUI closes on the engine side: the user closed its floating
  window, a hosting-mode move, or after `gui/close`.

**Query Parameters** (built-in and plugins)
```
/channel/{id}/device/{path}/get_parameters
/plugin/get_parameters [i:channel_id, i:device_position]
```
Responses:
- `{device}/param/count [i:count]`, followed by one `param/info` per parameter
- `{device}/param/info`, see the table below
- `{device}/param/{param_id}/value [f:normalized]` when the plugin or SFZ CC changes
- `{device}/sleep [i:0_or_1]` when the device sleeps or wakes
- `{device}/keys/info [i:count, count x (i:key, i:is_keyswitch, s:label), i:range_count, range_count x (i:lo, i:hi)]`,
  SFZ sampler only, once after every SFZ load (spec 014). Keys are `label_key` names and `sw_last`
  keyswitches (a keyswitch with no `sw_label` has an empty label); ranges are the inclusive key
  ranges the regions play, sorted and merged. Sent even when empty so Godot clears the previous
  file's data.

`{device}/param/info`:

| # | Type | Meaning |
|---|---|---|
| 0 | i | Parameter id |
| 1 | s | Name |
| 2 | f | Min (real value) |
| 3 | f | Max (real value) |
| 4 | f | Default (real value) |
| 5 | s | Group: `"param"` or `"cc"` |
| 6 | s | `param_type`: `"float"`, `"bool"` or `"enum"` |
| 7 | i | `flags` bitmask: 1 = hidden, 2 = read-only, 4 = bypass, 8 = modulatable |
| 8 | s | CLAP module path (`/`-separated), empty if none |
| 9 | i | `enum_count` |
| 10… | s | `enum_count` enum value labels; the index matches the engine value |
| next | s | Unit of the display values (`"Hz"`, `"dB"`, `"ms"`, …), empty if none |
| next | i | `display_count` |
| next… | f | `display_count` display values, sampled evenly from min to max (both ends included) |

Args 6 onward were added later. Godot treats a missing trailing arg as its default (`float`, no
flags, no module, no enum values, no unit, no display curve).

**Display curve (CLAP).** CLAP has no unit field; a host learns what a value means only from the
plugin's `value_to_text`. When parameters are queried, `plugin_host` samples that text at 33
evenly spaced plain values of every non-stepped parameter and parses each label into a number and
a unit (`plugin_host/value_text.rs`: `"1.20 kHz"` → 1200 Hz, `"-inf dB"` → −∞; "ms" and "s"
mixed → ms). The curve is sent when at least 75% of the labels parse with one unit and the values
change; labels that don't parse are NaN. Godot's `DeviceParameter.display_value` interpolates it
(geometrically between samples of one sign, so frequency curves are exact) and `format_value` shows
the result, so a ZeroEQ frequency that runs 0–1 reads 20 Hz … 20 kHz. Other devices send an empty
curve.

**Plugin Crash and Reload**

`{device}/crashed [s:reason, s:stderr, i:pid, s:log_path]` is sent once when a plugin's host process
dies or stops responding.
- `reason` is one line, e.g. `killed by signal 11 (SIGSEGV)` or `exited with code 7`.
- `stderr` holds the last lines the host printed before it died, newline-separated. It may be empty.
- `log_path` is the host's own log file. It is empty when unknown (e.g. under a debugger wrapper).
- A crash belongs to the host process, so a host shared by several instances (hosting modes) sends
  one per instance, all with the same `pid`.

`{device}/reload` (Godot → Rust, no args) respawns the host and restores the plugin's state on the
command thread. The device reports `loading` and later `ready` on `{device}/loading_state`. Every
other crashed device that was in the same host process is reloaded with it.

**Plugin Hosting Modes**

```
/plugins/hosting [s:mode, (s:plugin_id, s:mode)*]
```
How CLAP plugins are grouped into `plugin_host` processes. `mode` is one of:
- `individually`: one process per instance (the default)
- `by_plugin`: one per plugin
- `by_vendor`: one per vendor
- `together`: one for all

Each following pair overrides the mode for one plugin id. The message replaces the whole policy, so
Godot sends every override each time. An unknown global mode rejects the message; an unknown
override mode is skipped.

Plugins already loaded move live. The engine saves each affected plugin's state, closes its GUI
(`{device}/gui/closed`), respawns it in its new host and restores the state. Audio passes through
the plugin until it is `ready` again.

`{device}/host [s:mode, s:host_key, i:pid]` is sent when a plugin has loaded into a host process
(first load, reload or a move).
- `mode` is the hosting mode that picked the host.
- `host_key` is `instance-<id>`, `plugin:<id>`, `vendor:<name>` or `all`.

**Plugin Stats**

`{device}/stats` reports a CLAP plugin's processing over the last second, sent once a second while
it processes. A plugin that stops processing (asleep, or idle) gets one report with zeros and then
none until it processes again. The times cover the plugin's own `process()` call as measured inside
its host, so they exclude the IPC handshake.

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

### Device Data Subscriptions

Subscribe to device visualization data (spectrum analyzer, oscilloscope, phase meter, etc.):

**Subscribe to Data Stream (Godot → Rust):**
```
/channel/{id}/device/{path}/data/subscribe [s:data_type]
```

**Unsubscribe from Data Stream (Godot → Rust):**
```
/channel/{id}/device/{path}/data/unsubscribe [s:data_type]
```

**Set a Data Stream Option (Godot → Rust):**
```
/channel/{id}/device/{path}/data/configure [s:data_type, s:key, f:value]
```
Handled by `AudioDevice::configure_data`. An unknown stream, key or value logs a warning. An
option that needs new buffers (a new FFT size) has them built on the command thread with the
state lock released, then swapped in. Options are not saved by the engine: the view resends them
after subscribing.

**Data Types:**
- `"spectrum"` - Frequency spectrum (FFT magnitude bins in dB)
- `"oscilloscope"` - Time-domain waveform (future)
- `"phase"` - Stereo phase correlation (future)
- `"lufs"` - Integrated loudness (future)
- `"modulation"` - Live modulation values (spec 018 Phase 9), produced by the
  `ModulatedDevice` wrapper of a device that carries modulators, not the device itself

**Device Data Stream (Rust → Godot):**
```
/channel/{id}/device/{path}/data [s:data_type, blob:binary_data]
```

**Data Formats:**
- **Spectrum**: Binary array of f32 values (dB magnitude per frequency bin)
  - Array length depends on FFT size (e.g., 1025 bins for 2048 FFT)
  - Update rate: ~20Hz when subscribed
  - Range: typically -60dB to +12dB
- **Modulation**: little-endian, sent at ~20 Hz while subscribed even with no records, so
  the UI can drop stale entries (a heartbeat):
  ```
  u16 record_count
  per record:
    u8  kind: 0 = offset, 1 = values
    u8  depth: 0 = a parameter of the device itself, else the child-path length
    depth × u16  child indices, as a route target spells them
    u32 param_id
    u8  value_count
    value_count × f32 values (little-endian)
  ```
  - `offset` (kind 0): one value, the wrapper's own normalized contribution to the target.
    The UI sums the offsets of every wrapper in the chain onto the parameter's base value.
  - `values` (kind 1): the effective normalized value per sounding voice of a parameter of
    a voice-modulating device (PolySynth), newest voice last; `value_count` 0 means no voice
    is sounding. These already include the base and every enclosing wrapper's offset, so
    the UI uses them as-is and ignores `offset` records for the same parameter.

  Spec 033 appends a trailing block after the counted list (spec 033 T-018): the payload
  is built on the audio callback (sent at ~20 Hz while subscribed) into a fixed-capacity
  `Vec`, so it never reallocates or allocates at all.

  ```
  u16 ext_count            (record_count of kind 2/3 records; 0 when nothing to report)
  ext_count × record:
    u8  kind
    u8  len                (payload length in bytes; unknown kinds are skipped by len)
    len bytes
  ```

  - `modulator state` (kind 2, len 10): `u8 mod_id, u8 stage, f32 x, f32 value`, one per
    occupied modulator slot. `stage` is 0 for every non-envelope kind (an LFO reports
    `x` = its phase 0–1); an envelope (`adsr`, `ad`) reports its ADSR stage — 0 idle,
    1 attack, 2 decay, 3 sustain, 4 release — with `x` 0 and `value` the envelope level
    (every other kind reports `x` 0 and its current value).
  - `modulator-param offset` (kind 3, len 9): `u8 mod_id, u32 param_id, f32 offset`, one
    per evaluated mod→mod route target (`mod/{mod_id}/param/{param_id}`), the summed
    normalized offset currently applied to that modulator parameter.

  Old decoders stop after the counted kind 0/1 list and never read the trailing block;
  the block is purely additive, and decoders that walk it skip any kind they don't know
  via `len`.

**Example Usage:**
```gdscript
# Subscribe to spectrum data
AudioEngineOSC.subscribe_device_data(device.osc_path(), "spectrum")

# Listen for spectrum updates
AudioEngineOSC.device_spectrum_received.connect(func(osc_path, spectrum):
    if osc_path == device.osc_path():
        # spectrum is PackedFloat32Array of dB values
        update_visualization(spectrum)
)

# Unsubscribe when done
AudioEngineOSC.unsubscribe_device_data(device.osc_path(), "spectrum")
```

#### EQ analyser stream (`sonara.builtin.eq`)

Data type `"spectrum"`. The EQ uses the same data type and blob encoding (little-endian f32) with a four-value header. Godot receives it through `device_spectrum_received` as a `PackedFloat32Array`:
- `[0]` flag: `0.0` = pre-EQ (the input), `1.0` = post-EQ (the output, after Output Gain).
- `[1]` the engine sample rate in Hz (the view's curves use it).
- `[2]`, `[3]` `lo_hz` and `hi_hz`: 20 Hz and 20 kHz (lower when Nyquist is below 20 kHz).
- `[4..]` 256 dBFS points, log-spaced from `lo_hz` to `hi_hz` (point *i* is at `lo_hz * (hi_hz / lo_hz)^(i / 255)`), floor -160 dB. Each is the mean power of a fractional-octave band around it (Blackman-Harris FFT, DC removed), with attack/release ballistics in dB (`dsp/log_spectrum.rs`).
- Options (`data/configure` with data type `"spectrum"`):
  - `"resolution"` 0..3: FFT size 2048 / 4096 / 8192 / 16384 at 48 kHz (scaled up with the sample rate) and band width 1/3, 1/6, 1/12, 1/24 octave. Default 1.
  - `"speed"` 0..2 (fast, medium, slow): attack/release 10/120 ms, 30/350 ms, 80 ms/1 s. Default 1.
- The engine alternates pre and post frames, each about 30 Hz (about 60 messages a second; fewer with large audio buffers, since it polls once per buffer). The analyser (`sonara.builtin.spectrum_analyzer`) sends no header: don't mix the two parsers.
- While subscribed the EQ never sleeps, so the analyser decays on silence instead of freezing.

#### Compressor dynamics stream (`sonara.builtin.compressor`)

Data type `"dynamics"`. Unlike the analyser streams this one is not a spectrum: it is the level
history behind the compressor's meters and scrolling display. It arrives through
`device_data_received` as a `PackedByteArray`:

- The blob is little-endian: a `u32` record count, then that many records of three `f32`s:
  `in_peak_db`, `out_peak_db`, `gr_db` (the gain reduction as a positive number of dB).
- After the records comes a meter summary of ten `f32`s (dB) covering the whole poll window:
  `in_peak_l`, `in_peak_r`, `out_peak_l`, `out_peak_r`, `in_rms_l`, `in_rms_r`, `out_rms_l`,
  `out_rms_r`, `detector_db`, `gr_max_db`. RMS is the mean square over the window. `detector_db`
  is the level the gain computer sees (after SC Low Cut and Channels, RMS when Detection is RMS,
  the louder side). `gr_max_db` is the largest gain reduction. Silence reads -160 dB. The
  accumulators run only while subscribed. A decoder that stops after the records still works.
- On the audio thread the device appends one record every 64 frames, holding the peaks of that
  window and the largest gain reduction in it.
- Every poll (about 20 Hz while subscribed) drains the accumulated records into one blob, so the
  view gets a smooth history instead of 20 steps a second. A poll carries about 37 records at
  48 kHz.
- While subscribed the compressor never sleeps, so the meters and history keep moving in
  silence.
- `CompressorData.decode()` in Godot splits the blob into `{count, in_peak_db, out_peak_db,
  gr_db, summary}`. `summary` maps the names above to dB, and is empty when the blob has none.

#### Sampler playheads stream (`sonara.builtin.sampler`)

Data type `"playheads"`: where each sounding voice is in the file, for the sample display. It
arrives through `device_data_received` as a `PackedByteArray`, little-endian: a `u32` count, then
`count` records of three `f32`s:

- `position`: 0–1 over the whole file (not the play region). Same scale in reverse; points never flip.
- `velocity`: signed file-fractions per second (direction × rate), so the UI can extrapolate
  between packets. 0 for a voice holding at the end of a non-looping region.
- `level`: envelope × voice gain, 0–1, for the playhead's opacity.

The engine sends a record about every 33 ms of audio while a voice sounds (at most 64 × 12 + 4
bytes), and one record with `count = 0` after the last voice ends so the UI clears promptly.
Nothing is sent while idle. `poll_device_data` returns a fresh `Vec`, like the other streams.

#### Example Usage
```gdscript
# Add polysynth + delay to channel 2
AudioEngineOSC.send("/channel/2/add_device", ["sonara.builtin.polysynth", -1])
AudioEngineOSC.send("/channel/2/add_device", ["sonara.builtin.delay", -1])

# Delay: 250ms, 50% wet
AudioEngineOSC.send("/channel/2/device/1/param/0", [0.05])
AudioEngineOSC.send("/channel/2/device/1/param/1", [0.5])
```

## Timing and Synchronization

- **Audio engine is master**: Rust audio callback drives timing
- **Playhead updates**: Sent every ~50ms (20Hz) during playback
- **Godot playhead**: Interpolates smoothly between updates for UI
- **Corrective updates**: Godot adjusts if drift detected

## Connection Handshake

1. Godot starts and creates OSCClient + OSCServer
2. Rust engine starts listening on port 7000
3. Godot sends `/project/init` message
4. Rust responds with `/status/connected 1` to confirm engine is ready
5. Godot syncs all project data (clips, channels, tracks) after receiving confirmation
6. Engine sends `/status/heartbeat 1` every second to maintain connection
7. If Godot doesn't receive a heartbeat for 3 seconds, connection is marked as lost
8. Godot sends `/transport/play` to start playback

**Connection States:**
- **Disconnected**: No connection to engine (UI shows "Disconnected")
- **Connecting**: Waiting for engine response (UI shows "Connecting...")
- **Connected**: Engine confirmed and heartbeats received (UI shows "Connected")

**Note:** Heartbeat system ensures UI accurately reflects engine status, detecting crashes or process termination.

## Data Flow Example

### Playing MIDI Using Clip/ClipInstance Architecture

1. **Setup:**
   - Godot: `/project/init 120.0 4 4 960 48000`
   - Godot: `/channel/1/create "Master"` (master is always ID 1)
   - Godot: `/channel/2/create "Synth"`
   - Godot: `/channel/2/route 1` (route Synth -> Master)
   - Godot: `/track/0/create 2` (track 0 -> channel 2)

2. **Create Clip and Add MIDI Notes:**
   - Godot: `/clip/create "clip_001" "midi" "Bass Pattern"`
   - Godot: `/clip/clip_001/add_note 1 60 0 480 100` (C3 at tick 0, 1 beat)
   - Godot: `/clip/clip_001/add_note 2 64 960 480 100` (E3 at tick 960, 1 beat)

3. **Place Clip Instances on Timeline:**
   - Godot: `/track/0/add_instance "instance_001" "clip_001" 0 1920` (place at tick 0, 2 bars long)
   - Godot: `/track/0/add_instance "instance_002" "clip_001" 3840 1920` (place at tick 3840, transposed)
   - Godot: `/track/0/instance/instance_002/set_transpose 12` (transpose +12 semitones)
   - Godot: `/track/0/instance/instance_001/set_position 0 960 480` (trim: start at 480 ticks into clip, play 960 ticks)

4. **Playback:**
   - Godot: `/transport/play`
   - Rust: Resolves clip instances → notes from clip pool
   - Rust: Applies transpose to instance_002
   - Rust: `/status/playhead 0` then periodic playhead + `/channel/{id}/peak` updates

5. **Edit Clip (affects all instances):**
   - Godot: `/clip/clip_001/update_note 1 60 0 240 100` (shorten first note)
   - Rust: Both instance_001 and instance_002 now play shortened note

6. **Stop:**
   - Godot: `/transport/stop`
   - Rust: `/status/playing 0`
   - Rust: `/status/playhead 0`

## Audio File Service (Godot <-> Rust)

The AudioFileService decodes audio files to interleaved f32 PCM at the project sample rate (for playback) and builds a peak file for waveform display. Peaks are computed in source-sample space, at the file's own rate, so changing the project rate keeps every cached peak file. A cache hit skips the peak work but still decodes the PCM.

### Audio File Requests (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/audiofile/decode` | `s:req_id, s:abs_path` | Decode + peak file |
| `/audiofile/waveform/start` | `s:req_id, s:abs_path` | Same as `/audiofile/decode` |
| `/audiofile/waveform/cancel` | `s:req_id` | Cancel ongoing decode/waveform request |
| `/audiofile/samples` | `s:req_id, s:cache_key, i:channel, i:start_frame, i:count` | Raw samples at the file's own rate, for drawing at deep zoom. `cache_key` is the one from `/audiofile/decode/ready` (the peak file's name without `.swp`); the file must have been decoded in this engine session. `start_frame` is in native frames (`i` or `h`); `count` is capped at 4096 |

### Audio File Responses (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/audiofile/decode/ready` | `s:req_id, s:cache_key, i:channels, h:frames, i:sample_rate, f:duration_s, i:sample_count` | PCM decoded. `frames` and `sample_rate` are at the project (playback) rate. Always sent before `/audiofile/waveform/ready` |
| `/audiofile/waveform/ready` | `s:req_id, s:peak_file_path` | The peak file is complete and valid. Sent once per request |
| `/audiofile/progress` | `s:req_id, f:progress_0_1` | Real decode progress (native frames decoded / estimated total), at most every 100 ms, only when the container reports a frame count |
| `/audiofile/samples/data` | `s:req_id, i:channel, h:start_frame, b:samples` | Answer to `/audiofile/samples`: little-endian f32 samples of one channel (≤ 16 KB, one UDP packet). Shorter than requested at the end of the file, empty past it |
| `/audiofile/error` | `s:req_id, i:code, s:message` | Error occurred during processing. Code `-2`: a `/audiofile/samples` request failed (unknown cache key, bad channel, read error) |

Sample requests run on their own AudioFileService thread, so they never wait behind a decode. The engine re-reads the source file (seek plus a short decode) and keeps the last 64k-frame window per file, so neighbouring chunks and the other channel come from memory. Godot's UDP peer buffers about 64 KB per frame, so `WaveformSampleWindow` keeps at most two requests in flight.

### Waveform Cache Format

Peak files live in `$XDG_CACHE_HOME/sonara/waveforms/<key>.swp` (`~/.cache/...` without XDG). `<key>` is a 64-bit FNV-1a hash (16 hex digits) over the absolute path, the source file size, its mtime in nanoseconds and the format version. Files are written to `<key>.<pid>.<req_id>.tmp`, fsynced and renamed, so a partial file is never used. Stale `*.tmp` files older than an hour are deleted at startup. A cached file is used only if its magic, version and `complete` flag are right and its `src_size`/`src_mtime_ns` match the file on disk.

All values little-endian (`Engine/src/audio/io/waveform_cache.rs`):

```
Header (64 bytes)
  0  magic        [u8; 8] = "SONAPK02"
  8  version      u16 = 2
  10 channels     u16
  12 source_sr    u32     file's own sample rate
  16 frames       u64     native frames
  24 base_block   u32 = 64
  28 levels       u16
  30 tex_width    u16 = 4096
  32 src_size     u64
  40 src_mtime_ns u64
  48 complete     u8      written last
  49 reserved     (zero, to 64)

Level table (levels × 16 bytes)
  num_blocks u64, row_offset u32, rows u32

Planes, for each channel: plane A then plane B,
each total_rows × tex_width RGBA16F texels (8 bytes)
  plane A: (min, max, rms, 0)
  plane B: (low, mid, high, 0)   band RMS: <200 Hz, 200 Hz–2 kHz, >2 kHz
```

Level 0 has 64-frame blocks aligned to frame 0; each level merges two blocks of the level below (min of mins, max of maxes, frame-weighted mean of squares), so `num_blocks[L+1] = ceil(num_blocks[L] / 2)`. Levels stop when a level has one block or the block size would exceed 2^20 frames. All levels of a channel are stacked in one plane: each level starts on a new row and is zero-padded to a full row, so the texel for block `b` of level `L` is `(b % tex_width, row_offset[L] + b / tex_width)`. `total_rows` is capped at 16384 (the GPU texture height limit); longer files fail with `/audiofile/error`. Godot passes each plane's bytes straight to `Image.create_from_data(tex_width, total_rows, false, Image.FORMAT_RGBAH, bytes)`.

## Audio Device Settings (Godot <-> Rust)

### `/audio/devices/request` (Godot -> Rust)

No arguments. The engine lists its output devices on a background thread (it opens each one to
query it, which takes a moment). It answers with one `/audio/device` per device, then
`/audio/devices/complete [i:count]`.

### `/audio/device` (Rust -> Godot)

| # | Type | Meaning |
|---|---|---|
| 0 | s | `name`: the device name, as `/audio/config/set` expects it |
| 1 | i | `is_default`: 1 for the system default device |
| 2 | i | `min_buffer`: smallest buffer size (frames per callback) the device takes |
| 3 | i | `max_buffer`: largest, at most 2048 |
| 4 | i | `channels`: output channels the engine would open (0 when it couldn't query the device) |
| 5… | i | the sample rates it supports; none when the device is busy or has no f32 output |

### `/audio/config/set [s:device, i:rate, i:buffer]` (Godot -> Rust)

Run the output stream on `device` (`""` is the system default) at `rate` Hz with `buffer` frames
per callback (clamped to 32–2048).
- The engine stops the stream, prepares every device and plugin for the new rate, and starts it
  again, then sends `/audio/config`.
- A request equal to the running one only sends `/audio/config`.
- If the device is missing or won't open, the engine falls back to the default device, then to the
  default config (48 kHz, 1024 frames), and says so in `notice`.
- Godot sends this at start, on every engine (re)connect and before `/project/init`.

### `/audio/config/request` (Godot -> Rust)

No arguments. The engine answers with `/audio/config`.

### `/audio/config` (Rust -> Godot)

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

The buffer can be larger than requested. When PipeWire's quantum is larger than the ALSA buffer
(four buffers of the requested size), the engine reopens with a buffer that holds a whole graph
cycle. It returns to the requested size once the quantum drops.

### `/audio/config/changed [i:rate]` (Rust -> Godot)

The device sample rate changed. Audio clips were decoded at the old rate. They keep playing at the
right pitch (playback compensates for the clip's rate), and Godot re-sends `load_audio_file` for
each one so they're resampled properly. Files decode at the new rate from this message on.

## Offline Rendering (Godot <-> Rust)

The engine renders a range offline (`Engine/src/audio/render/`) on a worker thread with its own
clock. While a render runs:
- live output is silent and `/transport/play`, `/pause`, `/stop` and `/seek` are ignored with a
  warning. A playing transport is stopped first (`/status/playing 0`), and the playhead is restored
  afterwards (`/status/playhead`).
- devices are reset before and after, so nothing from live playback leaks in, and are kept awake
  for the whole render (no device sleep).
- CLAP plugins are switched to offline mode (CLAP render extension, when they have it) and may take
  up to 2 s per block. A plugin that misses that, or whose host crashes, fails the render instead of
  leaving a gap.
- live MIDI input is dropped.

Only one render runs at a time. Files are written as `<path>.part` and renamed when the render
succeeds, so a failed or cancelled render leaves nothing at the requested paths.

### `/render/start` (Godot -> Rust)

| # | Type | Meaning |
|---|---|---|
| 0 | s | `job_id`: chosen by Godot, echoed by every reply |
| 1 | i/h | `start_tick`: first tick of the range |
| 2 | i/h | `end_tick`: end of the range (exclusive). The range stops on the frame before this tick's MIDI would play, so a note on `end_tick` is not rendered |
| 3 | f | `tail_seconds`: tail rendered after the range with the transport stopped (0–600) |
| 4 | i | `until_silent`: 1 ends the tail once the master has stayed below −90 dBFS for 1 s, with `tail_seconds` as the cap; 0 renders exactly `tail_seconds` |
| 5 | s | `master_path`: stereo WAV of the master; `""` writes none |
| 6 | i | `bit_depth`: 16 or 24 (integer, clipped to ±1.0, no dither) or 32 (float, keeps overs) |
| 7 | i | `sample_rate`: 0 renders at the engine's rate, the only rate supported so far |
| 8 | i | `block_frames`: frames per block (32–8192); 0 uses 512 |
| 9… | i, s | stems: `(channel_id, path)` pairs. A stem is the channel's post-fader, post-pan output (what it sends on), so a muted channel, or one silenced by solo, is silent |

At least one of the master and the stems is required. Missing parent directories are created.
Before rendering, the engine waits up to 60 s for plugins and SFZ files that are still loading and
for audio clips in the range that are still decoding. A device that failed to load or crashed fails
the render; bypassed and deactivated devices are ignored. A malformed message is answered with
`/render/failed` at once.

### `/render/analyze [s:job_id, i:start_tick, i:end_tick, s:resolution, i:pre_roll_ticks, s:result_path, i:all_channels, i:channel_id…]` (Godot -> Rust)

Render the range offline and analyze it (loudness, six band levels, peak, crest, stereo) instead of
writing a WAV. `resolution` is `bar` or `beat`. The render starts `pre_roll_ticks` before
`start_tick`, or at tick 0 when that is negative, so held notes and tails are right at the start of
the range, but only `[start_tick, end_tick)` is analyzed. The master is always analyzed, plus every
channel when `all_channels` is non-zero, otherwise the listed channel IDs. The engine writes the
`AnalysisResult` JSON (`audio/analysis/mod.rs`) to `result_path`, creating its directory, and
reports `/render/done [job_id, result_path]`. Progress, cancel and failure are the same as for
`/render/start`; the two share the one-render-at-a-time rule.

### `/render/cancel [s:job_id]` (Godot -> Rust)

Stop the render after its current block. It ends with `/render/failed [job_id, "cancelled"]`.

### `/render/progress [s:job_id, f:fraction]` (Rust -> Godot)

About 10 times a second while rendering, 0.0–1.0. With an until-silent tail the estimate assumes the
whole cap, so it jumps to 1.0 when the tail ends early.

### `/render/done [s:job_id, s:path…]` (Rust -> Godot)

The render finished. The paths of the files written: the master first (when requested), then the
stems in request order.

### `/render/failed [s:job_id, s:error]` (Rust -> Godot)

The render failed or was cancelled (`error` is `cancelled`), or the request was rejected (bad
range, unknown stem channel, another render still running, …). No files were written.
