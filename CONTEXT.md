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
- **Fader / pan** — applied in the fader pass, and once per route target when it finishes — never while routing. A Stage source's pan is the identity; the stage pass places it.
- **Virtual Stage** — the project's one shoebox room (spec 051, ADR-0024). A channel in pan mode Stage is placed in it instead of panned; the engine renders direct sound, early reflections and a shared late tail. Godot class `VirtualStage` (`data/Stage.gd`; a global `Stage` clashes with `Envelope.Stage`).
- **Stage source** — a channel whose pan mode is Stage (value 4). Has a position (X, Y, Z in meters from the room's front-left floor corner), a Size (width of a stereo source), a Rotation and a size-0 sum mode (`L+R` or `Mid`). Instrument, audio and group channels can be one; master, the Stage return and other buses can't.
- **Stage return** — the one bus that receives every stage source's reflections (through the stage edge, `stage_feed`) and adds the tail before its own devices. Created automatically; can't be deleted while stage sources exist.
- **Stage pass** — the mixing pass after fader/pan that renders stage sources (pooled, `JobKind::Stage`). A stage source's pan is the identity.
- **Room model / Room preset** — the room's dimensions, six surface materials (gain, HF damping), listener position, tail decay and level, Distance delay and Output mode. A Room preset is a named set of these (five built in); editing one marks it modified.
- **Has room** — per-source flag for material recorded with its own room: it is positioned but sends no reflections or tail to the Stage return.
- **Output mode** — Full (reflections and tail), Reflections only (for an external reverb on the Stage return) or Direct only (nothing reaches the Stage return).
- **Mic setup** — the stereo mic array the Stage listener records with (spec 052, ADR-0025): Pan (the default constant-power panner), XY, Blumlein, Mid/Side, AB, ORTF or Decca tree. It sits at the Listener position and faces the front wall. Godot `VirtualStage.mic_setup`; engine `RoomModel::mic`.
- **Coincident setup / Spaced setup** — a mic setup whose capsules sit at one point (XY, Blumlein, Mid/Side: left and right differ in level and sign only) or some distance apart (AB, ORTF, Decca tree: they also differ in arrival time).
- **Depth** (of a stage source) — the front-to-back extent of its rectangle in meters, measured across its line. Visual only; the engine never sees it.
- **Display mode** — how the Stage view fills a source's rectangle: Block (a filled rectangle) or Section (an outline with one person icon per player).
- **Section / Players / Footprint** — a Section-mode source shows its Players (1 to 64, default 8). Its rectangle always holds them at the Footprint, 1.0 m wide by 1.2 m deep per player (floor(size / 1.0) x floor(depth / 1.2) >= players); edits stop at that minimum, automation does not.
- **Processing thread** — a thread, other than the audio callback's, that runs channels' device chains during a block (`sonara-worker-N`, the `ChannelPool`, ADR-0020). The callback takes jobs too and keeps fader/pan, routing and summing. The **Processing threads** setting is Auto (`min(cores / 2, 8) − 1`) or 1..cores; 1 means everything runs on the callback thread.
- **Device latency** — the frames by which a device delays its output, as it reports them (`AudioDevice::latency_frames()`). A bypassed device keeps it.
- **Path latency** — the latency a channel's signal has accumulated when it reaches a route or send target: its own chain's device latency plus the largest path latency among its inputs. Shown per channel in the Engine panel; the total before the hardware output is the plugin latency.
- **Compensation** — delaying the earlier signals that meet at a channel (a bus, master, a hardware pair) so all of them arrive aligned to the sample (ADR-0021). Capped at 1 s per channel.
- **Track** — a sequencer lane, separate from channels; points at one via `default_channel_id`.
- **Clip** — note or audio content living on a track. Audio clips carry `recorded_bpm` for BPM-based time-stretching (`stretch = project_bpm / recorded_bpm`).
- **ClipInstance** — a placement of a clip on a track, with a tick position (and per-instance fractional playback position for stretched audio).

## Devices

- **AudioDevice** — a processing unit in a channel's ordered chain (`Engine/src/audio/devices/`). MIDI goes only to the first device.
- **Built-in device** — first-party device advertised to Godot at runtime via `/builtin/request` → `/builtin/info` (`sonara.builtin.polysynth|delay|sfizz|sampler|chain|layer|drum_machine`).
- **Container** — a built-in device that owns child devices (`is_container`): **Chain** (serial), **Layer** (parallel mix), **Multiband FX** (frequency-split bands) and **Drum Machine** (parallel, MIDI routed per pad). Nested devices are addressed by a **device path** (`{position}/child/{i}/…`).
- **Slot** — a chain of devices inside a container, shown in the device lane beside the container under a bracket in the slot's color. A Chain has one slot: its own children. Each child of a Layer or Drum Machine is a **slot chain** (a Chain holding that slot's devices) with its own volume/mute/solo; a Drum Machine slot (a **pad**) also has a trigger note, and exists even while empty.
- **Device slot** — a fixed, named chain of devices built into a **slotted device** (spec 040), unlike a container's user-managed children. Always exists, even empty; created by the engine, never added, removed or moved by the user. Has a **kind**: `note` (note effects only), `audio` (effects only) or `loop`. Addressed as `{device}/child/{slot}`. Slots: PolySynth Note FX and FX, Delay FB FX, Reverb Tank FX and Wet FX.
- **Grain** (Pitch Shifter) — one windowed pass of a read tap through the delay line. The Grain rate in Hz (or a synced division) is how often each tap restarts; the taps are staggered so the windows always sum to 1. A shifted sine comes out as a comb of lines one grain rate apart, so shifts smaller than the grain rate are smeared.
- **Slotted device** — a built-in device that owns device slots instead of user children: PolySynth, Delay and Reverb. Reports `is_container`, but is not a user container: it keeps its Simple View, creates no instrument track and takes no drops directly (only onto one of its slots). Each slotted device decides where in its signal path each slot runs; an empty or all-bypassed slot leaves its plain code path sample-identical.
- **Loop slot** — a device slot (Delay FB FX, Reverb Tank FX) that processes the signal inside the device's feedback loop, once per repeat. Runs in `LOOP_BLOCK` (64-frame) sub-blocks, so while a loop slot holds an enabled device the loop delay has a floor of `LOOP_BLOCK + 2` samples, and it takes no CLAP plugin or asynchronous device.
- **CLAP plugin** — third-party plugin hosted out-of-process in the `plugin_host` binary (see ADR-0001).
- **VST3 plugin** — a plugin hosted the same way as a CLAP plugin, through the parallel `plugin_host/vst3/` path. Identified by its processor class ID and `.vst3` bundle path (ADR-0019). A plugin installed in both formats appears twice in the browser, tagged CLAP and VST3.
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
- **Punch** — a drum's pitch envelope (the Kick's and Snare's `Punch` and `Punch Time` controls): the body starts `Punch` semitones above its tune and falls to it over `Punch Time`. Rendered with `dsp::sweep_osc`.
- **Keytrack root** — the note a keytracked drum plays at exactly its Tune (Kick C1/36, Snare D1/38); other notes transpose from it, so Tune means the same with Keytrack on or off.
- **Choke target** — a Drum Machine pad that another pad's note-on chokes, so a closed hat cuts an open one. Directed: a pad lists its own targets (ADR-0015).
- **Choked by** — the pads that list a given pad as a choke target. Derived from the other pads' targets, never stored.
- **Grab** — the Cymbal's choke on note-off: with Grab on, a note-off fades the cymbal out over 30 ms (a hand on the plate); off, note-off is ignored like any other one-shot drum.
- **Choke group** — retired (ADR-0012). Old projects' groups load as mutual choke targets.

## Modulation

- **Modulator** — a signal source that belongs to one device *instance* (an LFO, envelope, velocity, keytrack, random, release or CC). It has a stable `mod_id` within the device, its kind's parameters, and a list of routes. Saved with the instance; a device supplies only its *default modulators* (ADR-0014).
- **Modulator kind** — what a modulator is (`lfo`, `adsr`, `ad`, `velocity`, `keytrack`, `random`, `release`, `cc`). It defines the modulator's parameter table and its polarity: LFO, keytrack and random are bipolar (−1..1); envelopes, velocity, release and cc are unipolar (0..1). The `cc` kind reads the channel's MIDI controller stream (CC Number 0–119, optional one-pole smoothing) and is evaluated on the mono path only (spec 032).
- **Route** — a link from one modulator to one modulatable parameter: on its own device, on a device nested inside it, or on another modulator of the same device. Device state, sent as `{device}/modulator/{mod_id}/route/set`, not a parameter (ADR-0011, ADR-0014).
- **Amount** — a route's strength, −1..1 in normalized parameter units per unit of modulator. Amount 0 removes the route.
- **Modulation offset** — the summed `amount × modulator value` that the engine (mono) or a poly-capable device (poly) adds to a parameter *next to* its base value: `effective = clamp(base_or_automation + Σ offset, 0, 1)`. The base is never written back and the modulated value is never echoed or saved (ADR-0010, ADR-0014).
- **Mono / poly modulation** — *mono* is the host path: the engine evaluates a device's modulators once per control step and applies offsets to any target. *Poly* is a device-internal path: a device that supports voice modulation runs one modulator instance per voice for routes into its own parameters (PolySynth in v1).

## Engine ↔ UI protocol

- **OSC address** — resource-based path with embedded IDs, RESTful style: `/channel/{id}/volume`, `/clip/{id}/load_state`. Full catalog: `docs/subsystems/osc-protocol.md`.
- **EngineStatus** — the command/status channel payload type; statuses flow audio/command threads → main thread → OSC → Godot at ~20 Hz.
- **AudioCommand** — the command type; OSC server → command thread, which applies it to `EngineState` (slow work with the lock released).
- **`req_id`** — request token correlating async audio-file jobs (decode, waveform) with their completions. Stale completions must be ignored.
- **Driver** — how the engine talks to the sound system: `pipewire` (native PipeWire through cpal, the default) or `alsa`. Device ids belong to one driver, so changing the driver resets the output device to the system default. Setting `audio/driver`, sent as the 4th argument of `/audio/config/set`.
- **Forced quantum** — PipeWire's `clock.force-quantum` / `clock.force-rate`, which the engine sets itself (via `pw-metadata`) to the buffer size and sample rate while it plays on the PipeWire driver, and restores on exit or when switching to ALSA. If another application changes them, the engine follows and reports it in `mismatch`.
- **LoadState** — lifecycle of a clip or device: Idle → Loading → Ready/Failed; plugins can also go Ready → **Crashed** when their host process dies, and come back through a **Reload**. While Loading, Failed or Crashed, the audio thread passes audio through (or outputs silence for instruments).

## Automation

- **Automation lane** — a list of points on a track that drives one **target** relative to the track's channel (`channel/volume`, `channel/pan`, `channel/send/{index}`, `device/{path}/param/{id}`). Values are normalized 0.0–1.0.
- **Automation override** — the resolved lane value applied alongside the target's **base value** (the user's manual setting), never written into it (see ADR-0010).

## Godot data model

- **Data model / self-synchronizing model** — `Godot/data/` classes (Project, Track, Channel, Clip, ClipInstance, DeviceInstance). The pattern: UI calls a setter → model updates state, sends OSC, emits a signal → UI refreshes from the signal. UI never sends OSC directly.
- **`sync_to_engine()`** — full-state resync method on data models, used on (re)connect/project load.
- **Paste anchor** — where an arranger paste lands: `ClipSelectionManager.anchor_track` (the insertion track) and `anchor_tick`. Set by the last click on a lane, clip or ruler, and by selecting a track in the tracklist (its active track). A range selection is time-only (start/end ticks); it does not contain the anchor track, which only picks the lane that receives the topmost pasted clip. Pasting uses the range start, else `anchor_tick`, else the playhead.
- **GridHelper** — the shared tempo/zoom/scroll/snap object converting ticks ↔ pixels; views share one instance.
- **Note map** — labels/colours per pitch on a channel (`NONE`/`AUTO`/`NAMED` mode). Labels only, never sent to the engine. An Auto map comes from the first Drum Machine (pad names) or zoned Layer (slot names per mapped input note) on the root chain.
- **Project scale** — the key at the start of the project: one root pitch class (C–B) plus a scale type (`MusicalScale`), or none; saved with the project, set from the main toolbar. Its 12-bit mask reaches the engine on `/project/scale` as the base key (specs 026/027).
- **Key change** — an arranger-ruler marker (Key lane) that changes the project scale from its tick onward; root + type picked from a `ScalePicker` dropdown, snapped to bar lines. Tick-anchored (spec 034).
- **Key change map** — the ordered set of key changes (`KeyChangeMap`), synced to the engine whole-map on `/project/scale_map` as `(tick, mask)` pairs; a change's mask 0 = "no scale from here". The engine resolves the mask per note-on frame; changing a scale never touches existing notes (spec 026 REQ-020).
- **Scale step** — a move from an in-scale pitch to the next one above or below. An out-of-scale note moves by scale steps counted from the in-scale pitch below it and keeps its semitone offset.
- **Scale snap** — clip editor toggle (per project) that keeps placed, dragged and transposed notes on in-scale pitches; Shift bypasses it like grid snap; keyswitch keys are never snapped.
- **Fold to scale** — optional clip editor toggle (per project, off by default) that hides out-of-scale rows in the piano roll, keeping rows for pitches that notes use.
- **Device view** — Godot visual for a device, one of four types: Panel, Window, Companion, Compact; all extend `DeviceView.gd`. **SimpleView** is the generated-panel fallback.
- **Device frame** — a Sonara-drawn device window: title bar, a tab per device, and the selected device's page (`devices/frame/DeviceFrame.gd`). **Floating** in its own borderless window, or **attached** to the Primary area (one at a time). Owned by `DeviceWindowManager`. A **channel frame** holds a channel's top-level chain devices as tabs (the "Per channel" grouping); a **torn-off** tab becomes a frame of its own.
- **Embedded plugin GUI** — a CLAP plugin's GUI shown inside a device frame: the engine reparents its **host window** (the plugin's CLAP parent) into the Godot window, so the GUI is never reopened when the frame moves. Experimental and X11 only (`plugins/embed_gui`, ADR-0016).
- **Asset provider** — pluggable source of browser assets (files, SFZ, devices) behind `AssetService`; keyed by absolute path or device ID.
- **Settings** — the registered-settings layer over the raw `Sonara.get_config`/`set_config` JSON store at `~/.config/sonara/config.json`; defaults live only in `Settings._register_all_settings()`.

## Conventions not covered elsewhere

- Engine logs: `~/.local/state/sonara/logs/engine/last_{info,warn,combined}.log`, rotated by `/project/init` into `session_<timestamp>_*.log` keeping the 5 newest.
- Undo/redo: mutations go through `Sonara.editor.history` (`HistoryUtil.execute`/`record`); data-object setters never push history themselves.
