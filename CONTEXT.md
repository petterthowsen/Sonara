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
- **Built-in device** — first-party device advertised to Godot at runtime via `/builtin/request` → `/builtin/info` (`sonara.builtin.polysynth|delay|sfizz|spectrum_analyzer`).
- **CLAP plugin** — third-party plugin hosted out-of-process in the `plugin_host` binary (see ADR-0001).
- **DeviceSleepState** — a device sleeps after ~3 s of silence and no MIDI/parameter activity; its processing is skipped until woken by input.
- **Device data stream** — binary payloads (`subscribe_data`/`poll_device_data`) that visualization devices emit only while Godot holds a subscription (e.g. `"spectrum"`).
- **Normalized parameter** — all parameter values cross the OSC/IPC boundary as 0.0–1.0; min/max live in metadata (see ADR-0005).
- **Return channel** — a channel with no timeline track fed by a multi-out device's extra stereo outputs. Drum Machine: one per pad (`Channel.aux_pad_note`).

## Engine ↔ UI protocol

- **OSC address** — resource-based path with embedded IDs, RESTful style: `/channel/{id}/volume`, `/clip/{id}/load_state`. Full catalog: `docs/subsystems/osc-protocol.md`.
- **EngineStatus** — the command/status channel payload type; statuses flow audio/command threads → main thread → OSC → Godot at ~20 Hz.
- **AudioCommand** — the command type; OSC server → command thread, which applies it to `EngineState` (slow work with the lock released).
- **`req_id`** — request token correlating async audio-file jobs (decode, waveform) with their completions. Stale completions must be ignored.
- **LoadState** — lifecycle of a clip or plugin: Idle → Loading → Ready/Failed. While Loading or Failed, the audio thread passes audio through (or outputs silence for instruments).

## Godot data model

- **Data model / self-synchronizing model** — `Godot/data/` classes (Project, Track, Channel, Clip, ClipInstance, DeviceInstance). The pattern: UI calls a setter → model updates state, sends OSC, emits a signal → UI refreshes from the signal. UI never sends OSC directly.
- **`sync_to_engine()`** — full-state resync method on data models, used on (re)connect/project load.
- **GridHelper** — the shared tempo/zoom/scroll/snap object converting ticks ↔ pixels; views share one instance.
- **Note map** — labels/colours per pitch on a channel (`NONE`/`AUTO`/`NAMED` mode). Labels only, never sent to the engine.
- **Device view** — Godot visual for a device, one of four types: Panel, Window, Companion, Compact; all extend `DeviceView.gd`. **SimpleView** is the generated-panel fallback.
- **Asset provider** — pluggable source of browser assets (files, SFZ, devices) behind `AssetService`; keyed by absolute path or device ID.
- **Settings** — the registered-settings layer over the raw `Sonara.get_config`/`set_config` JSON store at `~/.config/sonara/config.json`; defaults live only in `Settings._register_all_settings()`.

## Conventions not covered elsewhere

- Engine logs: `Engine/logs/last_{info,warn,combined}.log`, rotated by `/project/init` into `session_<timestamp>_*>` keeping the 5 newest.
- Undo/redo: mutations go through `Sonara.editor.history` (`HistoryUtil.execute`/`record`); data-object setters never push history themselves.
