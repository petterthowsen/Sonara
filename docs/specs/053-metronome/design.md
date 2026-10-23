# Metronome — Design

Implements [requirements.md](./requirements.md).

## Context

Engine (`Engine/src/audio/`):

- `processing/mod.rs` `process_audio`: while playing, it fills `render_scratch.tick_events`
  (`Vec<(Tick, usize)>`: every tick crossed this block and its frame) and
  `render_scratch.loop_wraps` (indices of the first event after each wrap) through
  `timeline::collect_tick_events_looped`. While stopped it clears `tick_events`. Both lists are
  back in `render_scratch` when it returns.
- `stream.rs` `run_live_block`: per chunk it runs `process_audio` → `mix_and_output` → the browser
  preview (`state.preview.mix_into(chunk, channels, sample_rate)`, spec 037), which adds straight
  into the interleaved hardware buffer *after* the master. The callback returns silence while
  `rendering` is set.
- `render/worker.rs` (offline export) reads channel buffers directly; it never reads the hardware
  buffer `mix_and_output` writes ("the render reads channels directly"). So anything mixed only
  into the hardware buffer is absent from exports for free (REQ-007).
- `mixing/mod.rs` `write_hardware_outputs`: master plays on pair
  `output_channel_id - HARDWARE_OUTPUT_BASE` (fallback pair 0), delayed by
  `channel.latency.hw_delay` frames (spec 042 latency compensation).
- `time_signature_map.rs` `TimeSignatureMap::segment_at(tick, base_num, base_den, ppq)` returns
  `SignatureSegment { bar_index, bar_start_tick, numerator, denominator }`. It does a linear walk
  over the changes and doesn't allocate. `MAX_NUMERATOR = 32`; denominators are 1, 2, 4, 8, 16 or 32.
- `devices/instruments/drums/`: `DrumHost<V: DrumVoice>` (`host.rs`) has sample-accurate
  `send_note_event(NoteEvent::On{..}, frame_offset)`, a two-slot 3 ms retrigger crossfade,
  interleaved stereo `process_block` output, a velocity curve `gain = 1 − sens·(1 − v²)`
  (`velocity_gain`), the shared `OUTPUT` dB parameter (`params.rs`, ID 91) and a 100 ms sleep.
  `kick.rs` `KickVoice` (Tune 20–200 Hz, Decay 0.03–3 s, Punch, Click, Keytrack root note 36)
  and `snare.rs` `SnareVoice` (Tune 80–400 Hz, Snappy, Snap, Keytrack root 38) both transpose by
  note number when `KEYTRACK` is on. Their parameter-ID consts are private today.
- `devices/factory.rs` `create_drum("sonara.builtin.kick" | "sonara.builtin.snare", sr, max_frames)`
  returns a prepared `Box<dyn AudioDevice>`. Command thread only (allocates).
- `command_worker/audio_config.rs` (around line 306–318) re-`prepare`s every device when the device
  sample rate changes.
- `commands/mod.rs`: the `AudioCommand` enum plus `process_command`, the fast path under the lock.
  Slow commands are listed in the `other @ (...)` arm. `osc/routes/mod.rs` dispatches on the first
  address part (`Some("stage") => stage::route(...)`).

Godot (`Godot/`):

- `editor/Editor.tscn`: `Header/Top/Transport/TransportControls/Buttons` holds `PlayButton` and
  `StopButton`. `editor/Editor.gd` `_setup_transport_buttons` sets their tooltips from
  `_chord_text(...)`. `_handle_transport_hotkey` dispatches the transport hotkeys.
- `editor/EnginePanel.gd`: an existing top-bar button that opens a `PopupPanel`
  (`PerformancePopup`). It's the precedent for the popup.
- `data/Stage.gd` `VirtualStage`: a project sub-model with `set_project` (weak ref), `get_state` /
  `set_state` snapshots for undo, `osc_args` / `sync_to_engine`, and `to_json` / `from_json`.
  `data/Project.gd` calls `_sync_stage_to_engine()` in the connect handshake and
  writes/reads `"stage"` in `to_json` / `from_json`. The metronome patterns follow this model.
- `history/HistoryUtil.gd` `record_property(label, target, "set_state", old, new)`: snapshot
  undo, as `stage/StageCanvas.gd` uses it.
- `settings/Settings.gd`: `_register(Setting.new(key, label, Type, default, CATEGORY_AUDIO, ...)).sub(...).range(...)`,
  `get_value` / `set_value`, and `signal setting_changed(key, value)`.
- `input/HotkeyActions.gd`: the action table (`{ "id": "transport_loop_toggle", ... "defaults": ["L"] }`).
- `components/StepLane.gd`: a step row (`Mode.BARS`) with `step_count`, `group_size`,
  `min_value` / `max_value` / `value_step`, `set_values_no_signal`, `value_edited(step, value)`,
  `edit_started` / `edit_ended`, `set_flash(k, level)` / `clear_flashes()`, and one `bar` colour
  from its theme colours.
- `components/LabeledKnob.gd`: the knob control used by the device views.
- `core/theme/ThemePalette.gd`: the role table (`r[&"accent_primary"]`, …).
  `core/theme/ThemeBuilder.gd` publishes every role as a colour on theme type `ROLE_TYPE = &"Sonara"`.
- `arranger/Arranger.tscn`: `BeatsToggle` uses `assets/icons/metronome.svg` (`2_rl012`) for the
  beats-ruler row.

## Approach

**An engine-owned `Metronome`, outside the channel graph, mixed after the master like the browser
preview.** `EngineState` gets a `metronome: Metronome` that owns two preallocated drum hosts (Kick
for Beep, Snare for Wood), a fixed-capacity pattern table and a small pending-trigger queue. After
`mix_and_output` and the preview, `run_live_block` calls `state.metronome.render(...)`. It reads
the block's `tick_events` / `loop_wraps`, finds the ticks that land on a pattern step, queues a
trigger at `frame + master.latency.hw_delay`, feeds the due triggers into the active drum host,
renders both hosts (a sleeping host costs nothing) into a preallocated stereo scratch, and adds
it, times a gain, into master's hardware pair. The click never enters a channel, so it skips
master's devices and fader. The offline render never sees it (REQ-007). It's on the same
callback, under the same lock, so scheduling is sample-accurate and needs no new sync
(REQ-004/006).

Rejected: **a hidden metronome channel holding a drum device, fed with generated MIDI.** It would
reuse the device and MIDI paths, but the channel would be in the graph. That means routing, solo
and meters. Export would have to special-case it, it would sit before master's fader and
effects, and every channel-walking pass (solo, latency plans, pool jobs) would need to skip it.
Also rejected: **scheduling clicks in Godot** (sending live MIDI at beat times). That's jittery
by a UI frame and breaks REQ-004's ±0-frame acceptance.

**Step scheduling.** The pattern step grid is deterministic from the time signature map, so the
scheduler doesn't search per tick. At the start of each monotonic run of `tick_events` (block
start, and each `loop_wraps` index) it computes `next = step_at_or_after(first_tick)`: one
`segment_at` call, then integer maths. While iterating the run's events, `tick == next.tick` fires
`next.level` (if not Off) and advances to the following step. Advancing to the next bar calls
`segment_at` again, so the next bar's signature (and its pattern) applies (REQ-006a). Ticks in a
run step by exactly 1, so equality can't skip a step. `collect_tick_events_looped` doesn't repeat
the boundary tick, so blocks never double-fire. A seek or play emits the playhead tick itself, so
a click exactly at the playhead plays (REQ-006).

**Sound mapping (command thread).** The UI sends real values: Tune Hz, Decay s, Tone 0–1, Level
dB, Emphasis Volume dB and Emphasis Pitch st. `Metronome::set_sound` turns them into drum
parameters. Both voices run with `KEYTRACK` on, `velocity_sens = 1` (global `VELOCITY`, ID 90, at
100 %) and the global `OUTPUT` (ID 91) = Level.

- **Pitch.** Tune is reached as `base_note` + a voice Tune inside its range: `base_note =
  root + ceil(12·log2(tune_hz / voice_max_hz))`, and the voice Tune is set to
  `tune_hz / 2^((base_note − root)/12)`. That's exact. A hit at level `e` plays note
  `base_note − round(pitch_st·(4−e)/3)` (REQ-023). Integer notes keep it sample-accurate.
- **Volume.** A hit at level `e` uses velocity `v = sqrt(10^(−vol_db·(4−e)/3 / 20))`. With sens 1
  the host's gain is `v²`, which is exactly the target gain (REQ-022).
- **Beep preset (Kick).** Punch 0 st (no sweep), Shape 0, Drive 0, Noise 0. Decay = knob
  (0.02–0.5 s, clamped to the voice's 0.03 s floor). Click = Tone·100 %.
- **Wood preset (Snare).** Snappy 0, Punch 1 st, Overtone 30 %. Decay = knob. Snap = Tone·100 %.

The preset values are constants in `metronome/sound.rs` and get tuned by ear in the live task.
Parameter norms come from each voice's `specs()` table (`ParamSpec::to_norm`), so the voices'
private ID consts become `pub(crate)`.

**Sound switch.** It changes `active` only. The previous host keeps rendering its tail and then
sleeps, so there's no cut (REQ-005, REQ-008). **Disable** stops scheduling new triggers and
clears pending ones; in-flight voices ring out (REQ-005). **Audition** (`/metronome/audition
i:level`) queues one trigger at frame 0 of the next block, playing or not (REQ-024). Godot
rate-limits it to one per 150 ms.

**Patterns.** The engine keeps `PatternTable { entries: [Pattern; 32], len }` with `Pattern { num:
u16, den: u16, resolution: u8 /* 4, 8 or 16 */, steps: u8, levels: [u8; 128] }`. An entry is
replaced in place, so there's no allocation under the lock. A signature with no entry, or an entry
whose `steps` doesn't match the signature at its resolution, uses `Pattern::default_for(num,
den)`: resolution `max(den, 4)` capped to 16, level 4 on step 0, level 2 on each beat start, Off
elsewhere (REQ-013). For `den ≤ 4`, 1/4 resolution with a 32 numerator is ≤ 128 steps, and the UI
never offers a resolution that would exceed `MAX_STEPS = 128`.

**Godot model.** `data/Metronome.gd` (`class_name Metronome`, RefCounted) is a project sub-model
like `VirtualStage`:

- **Patterns** are saved in the project: a Dictionary keyed `"num/den"` →
  `{ "resolution": int, "levels": PackedByteArray }`. Only edited signatures are stored.
- **The setting-backed sound and enabled state** are read and written through `Settings`. The
  model listens to `Settings.setting_changed` for `metronome/*` keys and sends.
- **Grid helpers** are pure static functions so they're testable without UI: `step_count(num,
  den, res)`, `allowed_resolutions(num, den)`, `default_levels(num, den)`, `group_size(den, res)`.

UI code calls the model's setters only; the model sends OSC.

**UI.** Two buttons go after `StopButton` in `TransportControls/Buttons`: a `MetronomeToggle`
(toggle mode, `metronome.svg`) and a `MetronomeMenuButton` (`chevron-down.svg`). The second opens
`editor/metronome/MetronomePopup.tscn`, a `PopupPanel` placed below the button, which closes on
an outside click as PopupPanel does. Inside the popup:

1. **Header row.** The signature being edited (follows the playhead's signature), a
   **resolution** `OptionButton` limited to `allowed_resolutions` (REQ-011), and **Reset**
   (REQ-014).
2. **Step grid.** One `StepLane` in `Mode.BARS`, `min_value 0`, `max_value 4`, `value_step 1`,
   `default_value 0`, `group_size` = steps per beat. Dragging a bar's height sets its level
   (0 = Off) and Ctrl-drag clears it, using StepLane's own gestures. `StepLane` gets one small
   addition: an optional `level_colors: PackedColorArray`. When set, a bar is drawn in
   `level_colors[int(value)]` instead of `bar`. The colours come from four new palette roles,
   `metronome_level_1` … `metronome_level_4`, published like the other roles (REQ-014). While
   playing, the popup flashes the current step (`set_flash`), computed from the playhead tick and
   the project's time signature map. There's no engine status for this.
3. **Sound row.** A Beep / Wood `OptionButton`, then six `LabeledKnob`s: Tune, Decay, Tone,
   Level, Emphasis Volume (labelled "Accent Vol") and Emphasis Pitch ("Accent Pitch").

A step edit or Reset is undoable: `edit_started` captures `metronome.get_state()` and
`edit_ended` calls `HistoryUtil.record_property("Edit Metronome", metronome, "set_state", old,
new)`. Knob and sound changes are settings, not project data, so they aren't undoable, the same
as other settings.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `EngineState.metronome.hosts: [Box<dyn AudioDevice>; 2]` | created by `EngineState::default()` (command/init thread) via `create_drum`; rendered by the audio callback | command thread sets parameters under the state lock (`set_parameter`, O(1)); audio callback renders under its `try_lock` | yes: `process_block` / `send_note_event` are the drum host's existing RT paths |
| `metronome.patterns: PatternTable` (fixed arrays) | command thread writes under the lock | audio callback reads under the lock | yes: copy into a fixed slot, no `Vec` |
| `metronome.pending: [(u32 frames_left, u8 level); 16]` | audio callback | audio callback only (audition pushes one under the lock from the command thread) | yes: when full, the new trigger is dropped |
| `metronome.scratch: Vec<f32>` (`MAX_BLOCK_FRAMES × 2`) | allocated in `Metronome::new` / `prepare` on the command thread | audio callback writes into it | yes: never resized on the callback |
| `metronome.enabled`, `active`, `base_note`, `pitch_st`, `vol_db` | command thread | audio callback reads | yes |
| Sample-rate change | command thread (`audio_config.rs`) | calls `metronome.prepare(sr, max_frames)` beside the device re-prepare, with the stream stopped | n/a (stream stopped) |
| Godot `Metronome` model | Godot main thread | `Project.metronome`; settings via the `Settings` autoload | n/a |

## Data and protocol changes

New OSC messages (Godot → Rust), all fast commands under the lock:

| Address | Args | Command |
|---|---|---|
| `/metronome/enabled` | `i:on` | `AudioCommand::SetMetronomeEnabled(bool)` |
| `/metronome/sound` | `i:sound (0 Beep, 1 Wood), f:tune_hz, f:decay_s, f:tone (0–1), f:level_db, f:emphasis_volume_db, f:emphasis_pitch_st` | `AudioCommand::SetMetronomeSound(MetronomeSound)` (values clamped engine-side) |
| `/metronome/pattern` | `i:num, i:den, i:resolution (4, 8 or 16), i:level × steps` (0–4). No levels = remove (back to default) | `AudioCommand::SetMetronomePattern { num, den, resolution, levels: Vec<u8> }`. The `Vec` is built on the main thread, copied into the table under the lock and dropped by `CommandEffects` / the command thread |
| `/metronome/clear` | — | `AudioCommand::ClearMetronomePatterns` (sent first on a full sync and on project load) |
| `/metronome/audition` | `i:level` (1–4) | `AudioCommand::MetronomeAudition(u8)` |

A malformed pattern (wrong step count for the signature and resolution, or a level above 4) is
warned and ignored. Nothing goes from Rust to Godot.

Godot persisted data:

- **`Settings.gd`**: `CATEGORY_AUDIO`, sub `"Metronome"`:
  - `metronome/enabled` BOOL false
  - `metronome/sound` INT 0 (0 Beep, 1 Wood; range 0–1)
  - `metronome/tune` FLOAT 1000 Hz (200–4000)
  - `metronome/decay` FLOAT 0.06 s (0.02–0.5)
  - `metronome/tone` FLOAT 0.5 (0–1)
  - `metronome/level` FLOAT −6 dB (−60–6)
  - `metronome/emphasis_volume` FLOAT 12 dB (0–24)
  - `metronome/emphasis_pitch` FLOAT 7 st (0–24, step 1)

  They show in the Settings dialog too. That's harmless and gives a second place to change them.
- **`.sonara`**: `Project.to_json` gets `"metronome": metronome.to_json()`, written only when at
  least one pattern was edited: `{ "patterns": { "7/8": { "resolution": 8, "levels": [4,0,2,0,2,0,0] } } }`.
  `from_json` reads `data.get("metronome", {})`.

`Project` connect handshake: after `_sync_stage_to_engine()`, call `metronome.sync_to_engine()`.
It sends `/metronome/clear`, every stored pattern, `/metronome/sound` and `/metronome/enabled`
(REQ-032).

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/metronome/mod.rs` (new) | `Metronome` struct: hosts, active sound, enabled, pending queue, scratch, gain. `new(sr, max_frames)`, `prepare`, `set_enabled`, `set_sound`, `set_pattern`, `clear_patterns`, `audition`. `render(&mut self, tick_events, loop_wraps, sig_map, settings, playing, data, channels, pair, delay)`. Unit tests |
| `Engine/src/audio/metronome/pattern.rs` (new) | `Pattern`, `PatternTable` (32 × 128 fixed), `Pattern::default_for`, `step_ticks`, `StepCursor::at_or_after(tick, sig_map, settings, table)` / `advance()`. Unit tests |
| `Engine/src/audio/metronome/sound.rs` (new) | `MetronomeSound` (real values + clamps), `SoundKind { Beep, Wood }`, Beep/Wood preset constants, `apply(host, kind, sound)` → base note, plus the velocity / note maths per level. Unit tests |
| `Engine/src/audio/mod.rs` | `pub mod metronome;` |
| `Engine/src/audio/state.rs` | `pub metronome: Metronome` field, built in `Default` with `MAX_BLOCK_FRAMES` |
| `Engine/src/audio/stream.rs` | In `run_live_block`, after the preview section: `rt_debug::section("metronome", ...)` calling `state.metronome.render(...)` with master's pair and `latency.hw_delay`. Destructure `EngineState` to split the borrows |
| `Engine/src/audio/devices/instruments/drums/kick.rs`, `snare.rs` | Make the parameter-ID consts and `KEYTRACK_ROOT` `pub(crate)`. No behaviour change |
| `Engine/src/audio/commands/metronome.rs` (new) | Handlers for the five commands |
| `Engine/src/audio/commands/mod.rs` | `mod metronome;`, five `AudioCommand` variants, `process_command` arms (fast path) |
| `Engine/src/audio/command_worker/audio_config.rs` | `state.metronome.prepare(sample_rate, max_frames)` beside the device re-prepare |
| `Engine/src/osc/routes/metronome.rs` (new) | `/metronome/*` parsing (with tests via the existing route harness) |
| `Engine/src/osc/routes/mod.rs` | `mod metronome;` and `Some("metronome") => ...` |
| `Godot/data/Metronome.gd` (new) | The model: patterns, static grid helpers, settings bridge, `get_state` / `set_state`, `to_json` / `from_json`, `sync_messages()` (pure, `[address, args]` pairs) and `sync_to_engine` (sends them), `audition(level)` with the 150 ms limit, `signal changed` |
| `Godot/data/Project.gd` | `var metronome := Metronome.new()`, `set_project`, handshake sync, `to_json` / `from_json` |
| `Godot/settings/Settings.gd` | The eight `metronome/*` settings |
| `Godot/input/HotkeyActions.gd` | `transport_metronome_toggle` (group Transport, context global, no defaults) |
| `Godot/editor/Editor.tscn` | `MetronomeToggle`, `MetronomeMenuButton`, `MetronomePopup` instance under the transport |
| `Godot/editor/Editor.gd` | `@onready` refs, wiring (toggle ↔ `metronome/enabled`), tooltip with chord, the hotkey branch in `_handle_transport_hotkey`, playhead → `popup.set_playhead_tick` while open |
| `Godot/editor/metronome/MetronomePopup.tscn` / `.gd` (new) | The popup: header row, `StepLane`, sound row, undo capture, playhead flash, audition on edits while stopped |
| `Godot/components/StepLane.gd` | Optional `level_colors: PackedColorArray` used by `_draw_bars` |
| `Godot/core/theme/ThemePalette.gd` | Roles `metronome_level_1` … `_4` (blue → green → amber → red, as dim → bright) |
| `Godot/assets/icons/ruler.svg` (new) | Lucide-style ruler icon |
| `Godot/arranger/Arranger.tscn` | `BeatsToggle` icon → `ruler.svg` (resolves the requirements' open question) |
| `docs/subsystems/osc-protocol.md` | New "Metronome (Godot -> Rust, spec 053)" section |
| `docs/subsystems/engine-architecture.md` | One line in the callback order: the metronome after the preview, post-master, hardware only |
| `docs/adr/0026-metronome-outside-channel-graph.md` (new) | Records the rejected hidden-channel alternative |
| `CHANGELOG.md` | `## [Unreleased]`: Metronome line |

## Migration and compatibility

- Projects without `"metronome"` load with no edited patterns, so every signature plays its
  default pattern. Nothing to migrate.
- New settings get their registered defaults; `config.json` gains keys on first write.
- An older engine logs `/metronome/*` as unknown routes and plays nothing. An older UI simply
  never sends them; the engine metronome stays disabled by default.

## Test plan

- **Unit (engine):**
  - `cargo test metronome`
    - `pattern::default_patterns`: 4/4 → `[4,2,2,2]` @1/4, 6/8 → 6 steps @1/8, 2/2 → 1/4 with
      beat starts (REQ-013).
    - `pattern::cursor_crosses_signature_change`: 4/4 then 3/4 from bar 2. The bar-2 downbeat
      uses the 3/4 pattern (REQ-006a, REQ-012).
    - `pattern::table_replace_and_remove`.
  - `metronome::clicks_on_exact_frames_across_block_sizes`: 120 BPM, 48 kHz, 4/4. Clicks at
    frames 0 / 24 000 / 48 000 / 72 000 for block sizes 64, 256 and 1024, detected by onset in
    the hardware buffer and by the trigger log (REQ-004).
  - `metronome::loop_wrap_replays_downbeat` (REQ-006b).
  - `metronome::tempo_ramp_clicks_on_beat_ticks`, against `frames_before_tick` (REQ-006c).
  - `metronome::silent_when_stopped_or_disabled_and_tail_rings` (REQ-005).
  - `metronome::bypasses_master_fader`, and `metronome::delayed_by_master_hw_delay` (REQ-007).
  - `sound::emphasis_volume_ratio` (−12 dB ±0.5 between levels 1 and 4) and
    `sound::emphasis_pitch_octave` (zero-crossing rate doubles at 12 st) (REQ-022/023).
  - `sound::level_floor` (< −55 dBFS at −60 dB) (REQ-021).
  - `sound::base_note_maps_tune_exactly` for 200, 1000 and 4000 Hz on both voices.
  - **Render:** a test in `render/worker.rs`: a range rendered with the metronome enabled
    equals one with it disabled, bit for bit (REQ-007).
  - **Routes:** `osc/routes/metronome.rs` tests: malformed pattern ignored, an empty pattern
    removes.
- **Godot:** `Godot/tests/test_metronome_model.gd`:
  - Grid helpers for 4/4@1/8, 7/8@1/8 and 6/8@1/16, plus `allowed_resolutions(7, 8)` (REQ-010/011).
  - Per-signature isolation and the default pattern (REQ-012/013).
  - `to_json` / `from_json` round trip, and undo via `set_state` (REQ-031).
  - Settings defaults and persistence (REQ-030).
  - `sync_messages()` returns `/metronome/clear`, every pattern, `/metronome/sound` and `/metronome/enabled`, in that order (REQ-032). `sync_to_engine` only sends that list; there is no OSC capture in tests.
  - The 150 ms audition rate limit (REQ-024).
- **Godot (shallow view, per the "UI tests surface level" memory):**
  `Godot/tests/test_metronome_popup.gd` instantiates the popup, sets a step through the model and
  checks the lane value and colour index. `test_hotkeys_registry.gd` covers the new action
  (REQ-001/003/014).
- **Live** (engine + UI):
  - Toggle on, play, and hear clicks on the beats with the accent on 1.
  - Change the signature to 7/8 mid-song and loop across it.
  - Drag every knob and paint steps during playback, watching the load popup for xruns (REQ-008).
  - Audition while stopped (REQ-024).
  - Export a WAV with the metronome on and confirm there's no click (REQ-007).
  - Tune the Beep and Wood presets by ear (REQ-020).

## Risks

| Risk | Mitigation |
|---|---|
| Kick/Snare voices sound poor at 1–4 kHz: the pitch envelope or click layer was tuned for low drums | Presets zero the sweep. The live task tunes the constants. If Beep still sounds wrong, Tone can lean on Click, or a later spec adds a dedicated click voice (noted, not now) |
| `tick_events` capacity overflow at extreme tempo and large blocks makes the scheduler miss a step | The scheduler only reads the list `process_audio` already relies on. Same exposure as clip MIDI; there's nothing new to handle |
| Retrigger at 1/16 and very high BPM: the 3 ms crossfade overlaps | It's the drum host's normal behaviour and inaudible on a short click |
| `hw_delay` changes (new latency plan) while triggers are pending | Pending triggers keep the delay they were queued with. One click may shift by the delta once; acceptable |
| A user with an all-Off pattern thinks the metronome is broken | The UI shows all-Off clearly; Reset is one click |
| Settings dialog now lists the metronome keys too | Intended; both edit the same setting and the popup follows `setting_changed` |

## Open questions

None. The requirements' open question (the beats-ruler icon) is resolved by switching it to
`ruler.svg`.
