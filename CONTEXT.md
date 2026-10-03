# Sonara Domain Context

Glossary of domain terms for Sonara, a Linux-first DAW: a Rust real-time audio engine (`Engine/`) plus a Godot 4.7 UI (`Godot/`), talking over OSC on localhost (Godot → engine port 7000, engine → Godot port 7001).

Subsystem deep-dives live in `docs/subsystems/`; decision records in `docs/adr/`.

## Sequencing & time

- **Tick** — the sequencing time unit. 960 ticks = one quarter note (**PPQ**, pulses per quarter note, fixed at 960).
- **frame_offset** — sample-accurate position of a MIDI event inside the current audio buffer. The callback computes `(tick, frame_offset)` pairs; devices consume `frame_offset` directly and never convert it back to ticks.
- **Master clock** — the audio callback. All transport time derives from it; Godot only interpolates the playhead between 20 Hz status updates.
- **sample_position** — a monotonically advancing per-callback counter of output samples, kept alongside `current_tick` for sub-tick precision.
- **Middle C** — C3 = MIDI note 60 (Sonara's octave-numbering convention).

## Channels & mixing

- **Channel** — a mixing strip. Types: `INSTRUMENT`, `AUDIO`, `BUS`. Channel IDs: 0 = none, 1 = master, 2–999 = user channels, 1000+ = hardware outputs.
- **Master** — channel ID 1. The only channel that feeds hardware outputs; it is an ID, not a separate type.
- **Route** — a channel's primary output, via `output_channel_id` (default 1). Processed in dependency order: a channel finishes once, after everything routing or sending into it.
- **Send** — a secondary tap into another channel: `Send { target_channel_id, amount_db, pre_fader, muted }`. Pre-fader sends tap the pre-pass copy; post-fader sends read the post-fader buffer.
- **Fader / pan** — applied in the fader pass, and once per route target when it finishes — never while routing.
- **Track** — a sequencer lane, separate from channels; points at one via `default_channel_id`.
- **Clip** — note or audio content living on a track. Audio clips carry `recorded_bpm` for BPM-based time-stretching (`stretch = project_bpm / recorded_bpm`).
- **ClipInstance** — a placement of a clip on a track, with a tick position (and per-instance fractional playback position for stretched audio).

## Devices

- **AudioDevice** — a processing unit in a channel's ordered chain (`Engine/src/audio/devices/`). MIDI goes only to the first device.
- **Built-in device** — first-party device advertised to Godot at runtime via `/builtin/request` → `/builtin/info` (`sonara.builtin.polysynth|delay|sfizz|sampler|spectrum_analyzer|chain|layer|drum_machine`).
- **Container** — a built-in device that owns child devices (`is_container`): **Chain** (serial), **Layer** (parallel mix), **Multiband FX** (frequency-split bands) and **Drum Machine** (parallel, MIDI routed per pad). Nested devices are addressed by a **device path** (`{position}/child/{i}/…`).
- **Slot** — a chain of devices inside a container, shown in the device lane beside the container under a bracket in the slot's color. A Chain has one slot: its own children. Each child of a Layer or Drum Machine is a **slot chain** (a Chain holding that slot's devices) with its own volume/mute/solo; a Drum Machine slot (a **pad**) also has a trigger note, and exists even while empty.
- **CLAP plugin** — third-party plugin hosted out-of-process in the `plugin_host` binary (see ADR-0001).
- **Host process** / **hosting mode** — a running `plugin_host` and the rule that picks which plugin instances share one: `individually` (default), `by_plugin`, `by_vendor`, `together`. A crash belongs to the host process and hits every instance in it (see ADR-0009).
- **DeviceSleepState** — a device sleeps after ~3 s of silence and no MIDI/parameter activity; its processing is skipped until woken by input.
- **Device data stream** — binary payloads (`subscribe_data`/`poll_device_data`) that visualization devices emit only while Godot holds a subscription (e.g. `"spectrum"`).
- **Normalized parameter** — all parameter values cross the OSC/IPC boundary as 0.0–1.0; min/max live in metadata (see ADR-0005).
- **Return channel** — a channel with no timeline track fed by a multi-out device's extra stereo outputs. Drum Machine: one per pad (`Channel.aux_pad_note`). Layer: one per slot with a separate output.
- **Slot note map** — a Layer slot's routing table: each input note (0–127) goes to one output note or is ignored (`data/LayerNoteMap.gd`). The **full map** (every note to itself) is the default; a slot with any other map is a **zoned slot**. Several slots mapping the same input note is **layering**, and an **overlap** when both are zoned.
- **Separate output** — a Layer slot sending its audio to its own return channel instead of the Layer output. Only for a Layer that is the first device on its channel. The slot and its return share a name and colour, and unlike other returns, a Layer return's output can be routed to any bus.

## Multiband FX

- **Multiband FX** — a built-in effect container (`sonara.builtin.multiband`) that splits its input into 2–6 frequency bands with Linkwitz-Riley crossovers, runs each band through its own slot chain, and sums them back.
- **Band** — one of six fixed positions in frequency order (band 1 lowest, band 6 highest). A band *position* always exists; it is *active* when its `Active` parameter is on. At least 2 are active. Band position = child index + 1.
- **Crossover** — the split point between two neighbouring active bands: the Low Edge of the higher one. K active bands have K−1 crossovers.
- **Low Edge** — the frequency at which a band starts (bands 2–6). The lowest active band ignores its Low Edge and extends down to 0 Hz.
- **Band slot chain** — the Chain child holding one band's devices. Always six exist; an inactive band's chain is empty.

## Drum instruments

- **Hit** — one trigger of a drum voice. A note-on starts a fresh voice (phase reset, so every hit sounds the same) while the previous voice fades out over 3 ms; note-off is ignored unless the drum has a gate mode.
- **Sweep** — a drum's pitch envelope: the body starts `Sweep` semitones above its tune and falls to it over `Sweep Time`. Rendered with `dsp::sweep_osc`.
- **Choke group** — a Drum Machine pad group (1–8; 0 = none). A note-on in a group chokes every other pad in it, so a closed hat cuts an open one.

## Modulation

- **Modulator** — a signal source that belongs to one device *instance* (an LFO, envelope, velocity, keytrack or random). It has a stable `mod_id` within the device, its kind's parameters, and a list of routes. Saved with the instance; a device supplies only its *default modulators* (ADR-0014).
- **Modulator kind** — what a modulator is (`lfo`, `adsr`, `ad`, `velocity`, `keytrack`, `random`). It defines the modulator's parameter table and its polarity: LFO, keytrack and random are bipolar (−1..1); envelopes and velocity are unipolar (0..1).
- **Route** — a link from one modulator to one modulatable parameter: on its own device, on a device nested inside it, or on another modulator of the same device. Device state, sent as `{device}/modulator/{mod_id}/route/set`, not a parameter (ADR-0011, ADR-0014).
- **Amount** — a route's strength, −1..1 in normalized parameter units per unit of modulator. Amount 0 removes the route.
- **Modulation offset** — the summed `amount × modulator value` that the engine (mono) or a poly-capable device (poly) adds to a parameter *next to* its base value: `effective = clamp(base_or_automation + Σ offset, 0, 1)`. The base is never written back and the modulated value is never echoed or saved (ADR-0010, ADR-0014).
- **Mono / poly modulation** — *mono* is the host path: the engine evaluates a device's modulators once per control step and applies offsets to any target. *Poly* is a device-internal path: a device that supports voice modulation runs one modulator instance per voice for routes into its own parameters (PolySynth in v1).

## Engine ↔ UI protocol

- **OSC address** — resource-based path with embedded IDs, RESTful style: `/channel/{id}/volume`, `/clip/{id}/load_state`. Full catalog: `docs/subsystems/osc-protocol.md`.
- **EngineStatus** — the command/status channel payload type; statuses flow audio/command threads → main thread → OSC → Godot at ~20 Hz.
- **AudioCommand** — the command type; OSC server → command thread, which applies it to `EngineState` (slow work with the lock released).
- **`req_id`** — request token correlating async audio-file jobs (decode, waveform) with their completions. Stale completions must be ignored.
- **LoadState** — lifecycle of a clip or device: Idle → Loading → Ready/Failed; plugins can also go Ready → **Crashed** when their host process dies, and come back through a **Reload**. While Loading, Failed or Crashed, the audio thread passes audio through (or outputs silence for instruments).

## Automation

- **Automation lane** — a list of points on a track that drives one **target** relative to the track's channel (`channel/volume`, `channel/pan`, `channel/send/{index}`, `device/{path}/param/{id}`). Values are normalized 0.0–1.0.
- **Automation override** — the resolved lane value applied alongside the target's **base value** (the user's manual setting), never written into it (see ADR-0010).

## Godot data model

- **Data model / self-synchronizing model** — `Godot/data/` classes (Project, Track, Channel, Clip, ClipInstance, DeviceInstance). The pattern: UI calls a setter → model updates state, sends OSC, emits a signal → UI refreshes from the signal. UI never sends OSC directly.
- **`sync_to_engine()`** — full-state resync method on data models, used on (re)connect/project load.
- **GridHelper** — the shared tempo/zoom/scroll/snap object converting ticks ↔ pixels; views share one instance.
- **Note map** — labels/colours per pitch on a channel (`NONE`/`AUTO`/`NAMED` mode). Labels only, never sent to the engine. An Auto map comes from the first Drum Machine (pad names) or zoned Layer (slot names per mapped input note) on the root chain.
- **Device view** — Godot visual for a device, one of four types: Panel, Window, Companion, Compact; all extend `DeviceView.gd`. **SimpleView** is the generated-panel fallback.
- **Asset provider** — pluggable source of browser assets (files, SFZ, devices) behind `AssetService`; keyed by absolute path or device ID.
- **Settings** — the registered-settings layer over the raw `Sonara.get_config`/`set_config` JSON store at `~/.config/sonara/config.json`; defaults live only in `Settings._register_all_settings()`.

## Conventions not covered elsewhere

- Engine logs: `Engine/logs/last_{info,warn,combined}.log`, rotated by `/project/init` into `session_<timestamp>_*.log` keeping the 5 newest.
- Undo/redo: mutations go through `Sonara.editor.history` (`HistoryUtil.execute`/`record`); data-object setters never push history themselves.
