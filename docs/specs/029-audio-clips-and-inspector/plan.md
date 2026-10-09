# 029 — Audio clips and the Inspector: implementation plan

Make audio clips usable in arrangements. They need correct playback speed, stretch modes with a
clip tempo, clip gain and fades. Alongside that, replace the Inspector placeholder with a real
panel that shows the selected clips.

This is a lightweight plan, not a full Kiro spec. Work phase by phase. Each phase ends with
something that builds, passes tests and can be checked by hand. Commit at the end of each phase.

## Checklist

- [x?] Phase 0: Fix audio clip playback speed and per-instance gain mixing
- [x?] Phase 1: Inspector framework and `ClipInspector`
- [x?] Phase 2: Clip gain
- [x?] Phase 3: Stretch modes Raw and Repitch, clip tempo and `AudioClipInspector`
- [ ] Phase 4: Stretch mode (pitch-preserving, Signalsmith Stretch)
- [ ] Phase 5: Fades
- [ ] Phase 6: DAWproject, docs, ADR and glossary

## Ground rules

- Follow the audio thread contract (`AGENTS.md`, ADR 0002). Allocate nothing on the callback.
  Stretchers and scratch buffers are built on the command thread with the lock released, then
  swapped in.
- Models sync themselves (ADR 0006). The inspector calls model setters such as
  `inst.set_gain_offset()` and never sends OSC.
- Every inspector edit is undoable. Use `PropertyCommand` / `HistoryUtil.execute_many` the way
  `ClipContextMenu._on_reverse_toggled` does. A drag on a slider or knob is one undo step,
  recorded on release (`HistoryUtil.record_property`).
- Read `docs/subsystems/engine-architecture.md` (section "Audio Clip BPM-Based Time Stretching"),
  `engine-audio-thread.md`, `godot-architecture.md`, `godot-osc.md`, `godot-ui-components.md`,
  `dawproject.md` and ADRs 0002, 0006 and 0007 before starting.
- Engine: `cargo build --release`, `cargo test`, `cargo fmt` (from `Engine/`). Godot:
  `Godot/tests/run_all.sh`. Don't run more than 2–3 cargo builds in parallel.
- Each new OSC message goes in `osc/routes/`, `audio/commands/` and `docs/subsystems/osc-protocol.md`.

## Where things live today

| Concern | File |
|---|---|
| Engine clip data, instance data, stretch maths | `Engine/src/audio/clip.rs` (`Clip`, `ClipInstance`, `AudioPlayback`) |
| Audio clip render (per frame, linear interpolation) | `Engine/src/audio/processing/clip_audio.rs` (`render_audio_clips`, `mix_instance_frame`) |
| Clip load completion and engine-side content length | `Engine/src/audio/commands/clip.rs` |
| Tempo map (`bpm_at`, `seconds_at`) | `Engine/src/audio/tempo_map.rs` |
| Offline render (export and analyze) | `Engine/src/audio/render/worker.rs` |
| Godot clip model | `Godot/data/Clip.gd` (`recorded_bpm`, `update_content_length_from_metadata`, `set_name`) |
| Godot instance model | `Godot/data/ClipInstance.gd` (`gain_offset`, `fade_in_ticks` and `fade_out_ticks` are stored but not synced) |
| Load-state handling that sets content length | `Godot/data/Project.gd` (`_on_audiofile_decode_ready`, load_state handler) |
| Waveform on the timeline | `Godot/arranger/timeline/clip/TimelineClip.gd` `_update_waveform` |
| Waveform shader view (already has `gain`, `fade_in_frames`, `fade_out_frames`, `fade_curve`) | `Godot/support/waveform/WaveformView.gd` |
| Clip context menu (reverse, mute) | `Godot/arranger/timeline/ClipContextMenu.gd` |
| Clip selection | `Godot/data/ClipSelection.gd`, `arranger.timeline.clip_selection_manager` |
| Inspector placeholder (dummy buttons and label) | `Godot/editor/Editor.tscn` node `.../LeftDock/Inspector` |
| Dock chrome and layout | `Godot/editor/docks/DockHost.gd`, `DockPanel.gd` |

## Why the imported file played at the wrong speed

Three places disagree on how fast an audio clip plays:

1. **The engine** stretches every audio clip by `project_bpm / clip.recorded_bpm`
   (`clip_audio.rs`). Godot never sends `recorded_bpm`; there is no OSC message for it. The engine
   therefore always uses its default of 120.
2. **The Godot clip length** is computed from the project tempo
   (`Clip.update_content_length_from_metadata(tempo, ppq)`). In effect it assumes the file plays at
   its natural speed at the current tempo.
3. **The waveform** maps ticks to frames with `clip.recorded_bpm`. That is 120 by default for
   imported files.

At 120 BPM all three agree. At any other tempo the file plays `tempo / 120` times too fast or too
slow, and too high or too low in pitch, because the current mode only repitches. The clip box is
sized for normal speed. The waveform matches neither the audio nor the box. If the project was at
120 BPM when you heard the problem, this isn't the cause. In that case, check next whether
`clip.audio_sample_rate` is the native rate or the resampled rate when the playback buffer is
resampled (`commands/clip.rs`).

Two more bugs are in the same function. `mix_instance_frame` applies the instance gain to the
track's running sum, so overlapping instances scale each other. For mono clips it copies that
running sum into the right channel.

## Decisions

- **Stretch mode and clip tempo belong to the Clip.** They describe the source material, so all
  instances of a shared clip use them. "Make Unique" copies them (it already copies
  `recorded_bpm`).
- **Gain, fades, transpose, position, length, offset, loop, reverse and mute belong to the
  ClipInstance.** That matches where `gain_offset` and the fade fields already are.
- **Name and colour belong to the Clip.** A per-instance colour comes from `color_override`. The
  inspector edits the clip's colour and offers "reset override" when an instance has one.
- **Modes in v1:**
  - **Raw**: the clip plays at its native speed and ignores the project tempo. Content ticks
    become source seconds through the tempo map at the instance's position: source time of
    content tick `c` = `seconds_at(origin + c) − seconds_at(origin)`, where
    `origin = start_tick − clip_offset`. If you change the tempo, the length in beats stays the
    same and the audio ends earlier or later inside the clip. Bitwig does the same.
  - **Repitch**: varispeed, which is what the engine does now. Rate = `bpm_at(tick) / clip_tempo`.
    Pitch follows speed.
  - **Stretch**: rate as in Repitch, with pitch kept, through Signalsmith Stretch. Instance
    `transpose` (semitones) applies to audio only in this mode.
  - Not in v1: élastique (proprietary and licensed), Beats/slicing, Textures, warp markers.
- **Stretch library:** [`signalsmith-stretch`](https://github.com/colinmarc/signalsmith-stretch-rs)
  (MIT, wraps the C++ Signalsmith Stretch). Its streaming `process` takes input and output of
  different lengths. It has `seek`, `input_latency` and `output_latency`. Rubber Band is GPL and
  doesn't fit.
- **Clip tempo means "BPM of the material".** One place derives a clip's content length from it:
  `content_length_ticks = duration_s × clip_tempo / 60 × ppq`. Godot computes it and sends it.
  The engine no longer assumes 120.
- **Defaults on import:**
  - Mode Raw.
  - Clip tempo = the project tempo at the drop position. Switching to Repitch or Stretch then
    starts at 1:1.
  - If the file name contains a tempo (`120bpm`, `120 BPM`, `_120_`, with a sanity range of
    60–200), use that tempo and mode Stretch instead.
  - Automatic tempo detection isn't in v1.
- **Old projects** load with mode Repitch and their saved `recorded_bpm`, so the waveform
  doesn't change. (The engine used 120, so only DAWproject imports with a different tempo will
  sound different. Those were wrong before.)
- **Changing the clip tempo** of an existing clip rescales the content length. It also rescales
  each instance's duration, offset and loop region by `new_bpm / old_bpm`, so every instance
  still covers the same stretch of audio. It's one undo step.
- **Inspector structure:** the Inspector panel is a `VBoxContainer` of *inspector sections*. Each
  section declares which selections it handles. The panel stacks every matching section:
  `ClipInspector` for any clip, then `AudioClipInspector` for audio clips (you called this
  "AudioInstanceInspector"; it's renamed because it holds both clip and instance properties).
  `MidiClipInspector`, `TrackInspector` and others come later.
- **Multi-selection:** a field shows the shared value, or "—" when the values differ. An edit
  applies to every selected item as one undo step.

## Phase 0 — Fix audio clip playback speed and per-instance gain mixing

Goal: an imported file plays at the right speed and pitch at any project tempo, and the box and
waveform match the audio. This phase uses the existing Repitch behaviour only.

Engine:
- [x?] Add `/clip/{id}/set_tempo f:bpm` → `AudioCommand::SetClipTempo`. It sets
  `Clip.recorded_bpm` and resets the playback positions of that clip's instances. (Phase 3
  extends it to `set_timing` with a mode argument. Name it now so the message doesn't change
  twice. You can also add the `mode` argument now and accept only `repitch`.)
- [x?] Remove the 120-BPM content-length guess from `commands/clip.rs`. Godot owns the length and
  already sends it with the instance positions.
- [x?] `mix_instance_frame`: render the instance into a local `(l, r)` pair, apply gain, then add
  it to the track sum. Mono copies the instance's own left sample. Compute `db_to_gain` once per
  instance per buffer, not per frame.
- [x?] Tests:
  - two overlapping instances with different gains sum correctly
  - a mono clip doesn't leak into the right channel of another instance
  - after `SetClipTempo`, the 960-tick seek lands on the expected frame

Godot:
- [x?] Sync `Clip.recorded_bpm` in `sync_to_engine()` and through a setter `Clip.set_recorded_bpm()`.
- [x?] On import, set `recorded_bpm = project tempo at the drop tick`.
  `update_content_length_from_metadata` uses `recorded_bpm`, not the project tempo, so the
  length doesn't change when a project reloads at another tempo.
- [x?] Test (headless): import metadata at a project tempo of 140 gives a length of
  `duration × 140/60 × 960`, and the clip's tempo is 140.

Verify by hand: set the project to 90 BPM, drop a file, and check that it sounds like it does in
another player and that the waveform's end lines up with the clip's end.

## Phase 1 — Inspector framework and `ClipInspector`

Goal: select clips and see and edit their basic properties. Godot only.

- [x?] Replace the placeholder children of the Inspector node in `Editor.tscn` with
  `Godot/editor/inspector/InspectorPanel.tscn`. It's a `ScrollContainer` → `VBoxContainer`, plus
  an empty state ("Nothing selected").
- [x?] `InspectorPanel.gd`:
  - Listen to the clip selection manager (`changed`).
  - Keep a list of section scenes. For each selection, show the sections whose
    `static func handles(objects: Array) -> bool` is true, then call `bind(objects)` /
    `unbind()`.
  - Reuse section instances rather than rebuilding them on every selection change.
- [x?] `InspectorSection.gd` base class:
  - A collapsible header (reuse `CollapsingContainer`).
  - A two-column `GridContainer` of label and editor rows.
  - Helpers that show a "mixed" value and suppress feedback loops.
  - The section listens to model signals (`instance_modified`, `clip_modified`,
    `position_changed` and so on) and refreshes. It never polls.
- [x?] `ClipInspector`:
  - Name (`Clip.set_name`) and colour (clip colour plus an override reset).
  - Position, length and offset, as bars.beats.ticks fields that accept typed input. Use the
    existing BBT formatting and parsing in `TimeSignatureMap` / `GridHelper`. Don't add a new
    one.
  - Loop on/off with loop start and loop length.
  - Mute.
  - Read-only: clip type and "shared by N instances", with a "Make Unique" button.
- [x?] Edits go through `ClipInstanceTransformCommand` (position, length, offset) and
  `PropertyCommand` (everything else).
- [x?] Add `set_color` to `Clip.gd` if needed, so the timeline and inspector update from the
  signal.
- [x?] Tests (`Godot/tests/test_inspector.gd`):
  - Sections appear and disappear with the selection.
  - Mixed values show "—".
  - Editing the name or position updates the model and undoes in one step.
- [x?] Update `godot-architecture.md` with a short "Inspector" section.

Phase 1 notes (deviations from the list above):
- `CollapsingContainer` hides children that don't fit; it is not a collapsible section. The
  section header is a flat toggle button with a chevron instead.
- Sections are scripts listed in `InspectorPanel.section_scripts()` and build their rows in code,
  not scenes. The panel gets the selection from `Editor.clips_selected` rather than listening to
  the selection manager itself.
- Nothing in the timeline draws `Clip.color` or `ClipInstance.color_override` yet (clips use the
  track colour), so the colour row edits data that has no visible effect until that is wired.
- Typed positions are not checked for overlap with neighbouring clips.

## Phase 2 — Clip gain

The engine already has `/track/{id}/instance/{id}/set_gain`.

- [x?] `ClipInstance.set_gain_offset(db)` with a signal, sent in `sync_to_engine()`.
- [x?] Add a gain row to the `AudioClipInspector` section. Create that section here with gain and
  source info only:
  - Gain row: a knob or slider from −inf to +24 dB, double-click to reset.
  - Source info, read-only: file name and path, format, sample rate, channels, duration.
- [x?] `TimelineClip` passes `db_to_linear(gain_offset)` to `WaveformView.gain`, so the waveform
  shows the gain.
- [x?] Optional: drag vertically on the clip's top edge to change gain, with a value tooltip. Do
  this only if it fits the clip interaction modes cleanly.
- [x?] Tests: the setter syncs, undo works, and the waveform gain follows the setting.

Phase 2 notes (deviations from the list above):
- `/track/{id}/instance/{id}/set_gain f:db` already existed and matches (route, `UpdateClipInstanceGain`,
  `Track` sync on instance add); no engine change.
- Range is -60 to +24 dB. The floor is a stand-in for -inf: it shows "-inf", the waveform draws flat
  and `engine_gain_db()` sends -120 dB. (`gain_offset` is saved in JSON, which can't hold -inf.)
- Control is `HorSlider` plus a typed dB field, not a knob. `HorSlider` got an opt-in
  `double_click_resets`. The first click of a double-click already moves the value, so a
  double-click reset records two undo steps.
- Top-edge vertical drag skipped: the clip header/top edge is used by the move and select interactions, and I did not add a new interaction mode.
- Source info shows the file's own sample rate once peaks are loaded, else the playback rate.
- Tests in `Godot/tests/test_audio_clip_inspector.gd`.

## Phase 3 — Stretch modes Raw and Repitch, clip tempo and `AudioClipInspector`

Engine:
- [x?] `enum StretchMode { Raw, Repitch, Stretch }` on `Clip`. `Stretch` falls back to Repitch
  until Phase 4.
- [x?] Rename the message to `/clip/{id}/set_timing s:mode f:bpm` (or extend it, if Phase 0
  already used that name).
- [x?] Raw in `clip_audio.rs`:
  - Seek position comes from `tempo_map.seconds_at` relative to the instance origin, as defined
    under Decisions.
  - Advance per frame = `clip_sr / device_sr`.
  - Loop start and length are converted the same way.
  - Move the conversions into `AudioPlayback` and unit-test them there: constant tempo, a tempo
    ramp, a seek into a loop, and reverse.
- [x?] Check that offline render (`render/worker.rs`) goes through the same code path.

Godot:
- [x?] `Clip.stretch_mode` with a setter, saved in `to_json` / `from_json`. Old projects default
  to Repitch.
- [x?] `AudioClipInspector` controls:
  - mode selector (Raw / Repitch / Stretch)
  - clip tempo field, disabled in Raw
  - ×2 and ÷2 buttons
  - "Length in beats…", which sets the tempo from a typed length: `bpm = beats × 60 / duration_s`
  - reverse
- [x?] Changing the clip tempo rescales the content length and every instance (see Decisions) as
  one `MacroCommand`.
- [x?] Import defaults (Raw plus tempo from the project tempo, or Stretch plus a tempo parsed from
  the file name), in a small static `AudioImportDefaults.gd`, with tests for the file-name parser.
- [x?] `TimelineClip._update_waveform`:
  - Raw uses the project tempo at the instance start to find frames per tick. A tempo change
    under a Raw clip can draw slightly off. Note this as a known limitation.
  - Repitch and Stretch use the clip tempo.
- [x?] Show the mode on the clip header as a small badge (`R` / `P` / `S`), only when it isn't Raw.
- [x?] Tests: mode and tempo round-trip through save and load, tempo rescaling keeps the source
  region, and the waveform mapping is correct for each mode.

Phase 3 notes (deviations from the list above):
- Phase 0 had already named the message `set_tempo`; it is now `/clip/{id}/set_timing s:mode f:bpm` (`raw`, `repitch`, `stretch`; unknown mode warns and is ignored). Engine default for a new clip is Repitch at 120.
- Stretch is offered in the selector, labelled "Stretch (plays as Repitch)" with a tooltip, and the engine maps it to Repitch (`StretchMode::effective`). Phase 4 should drop the label.
- Raw advances at a constant `clip_sr / device_sr`; only the seek and the loop region use the tempo map. The Raw loop frames are computed when the instance is seated and cached on `ClipInstance`, so a tempo-map edit during playback only takes effect at the next seat.
- Offline render needs no separate code: `render/worker.rs` calls `process_audio`, which calls `render_audio_clips`.
- "Length in beats..." is an inline field (Enter applies), not a dialog.
- Tempo, x2, /2 and the beats field are disabled when every selected clip is Raw. Multi-selection applies to each clip.
- The clip's tempo edit is `AudioClipTiming.tempo_change_command` (one `MacroCommand`: clip tempo, content length, then a `ClipInstanceTransformCommand` per instance on every track).
- Import defaults are in `Godot/data/AudioImportDefaults.gd` (`for_file`, `parse_tempo`): an explicit `NNNbpm` wins over a bare `_NNN_`; both need 60-200.
- Phase 2 loose end fixed: a click on the gain slider that did not move is recorded 0.4 s later, so a double-click reset replaces it and the pair is one undo step. Selection change flushes a waiting click.
- Tests: Rust unit tests in `audio/clip.rs` and `processing/clip_audio.rs`; Godot `tests/test_audio_clip_timing.gd`.

## Phase 4 — Stretch mode (pitch-preserving, Signalsmith Stretch)

Read the `signalsmith-stretch` crate docs (Context7 `/colinmarc/signalsmith-stretch-rs`) before
starting. Begin with a spike: a test that stretches a 1 kHz sine at ratios 0.5, 1 and 2, and
checks the pitch (zero crossings) and the output length.

Engine:
- [ ] Add the dependency (C++ build through `cc`; check that it builds alongside sfizz).
- [ ] `ClipStretcher` (new, `audio/processing/clip_stretch.rs`):
  - Holds a `Stretch` plus preallocated interleaved input and output scratch, sized for
    `max_buffer × max_ratio` (cap the ratio at 4×; above that, fall back to Repitch and log a
    WARN once).
  - One per ClipInstance whose clip is in Stretch mode. The command worker builds it with the
    lock released when the mode, clip, channels or device sample rate change. It goes in
    `ClipInstance.stretcher: Option<Box<ClipStretcher>>`. The old one is dropped through
    `CommandEffects`.
- [ ] Render stretched instances per block, not per frame:
  - Work out the frame range the instance covers in this buffer and take the ratio at the start
    of the block. If the tempo map ramps, split into sub-blocks of 64 frames.
  - Gather `out_frames × ratio` source frames into the input scratch, handling the loop wrap and
    reverse while gathering.
  - Call `process`, then mix in with gain.
  - Transpose = `set_transpose_factor_semitones(inst.transpose)`.
- [ ] Re-seat (start, seek, transport loop wrap, instance loop wrap) with `seek()`, feeding
  `input_latency` frames before the target position. Offset the read position so output lines up
  with the timeline: test it by stretching a click at content tick X and checking that it lands
  at song tick X ± 1 ms at ratios 0.5, 1 and 2.
- [ ] Stretchers of instances that aren't playing do no work. Check CPU with 16 stretched
  instances in a release build; record the number in the PR.
- [ ] Offline render uses the same path. A test renders a stretched clip and compares its length.

Godot:
- [ ] Enable Stretch in the mode selector, and enable the transpose row (−24 to +24 semitones)
  for Stretch-mode audio clips.

## Phase 5 — Fades

Engine:
- [ ] `/track/{id}/instance/{id}/set_fades i:in_ticks, i:out_ticks, f:in_curve, f:out_curve`.
  Curves run from −1 to 1, with 0 linear. Add `fade_in_curve` and `fade_out_curve` to
  `ClipInstance` on both sides.
- [ ] Apply the fade envelope per frame after gain, in every mode. Measure it in song ticks from
  the instance start and end, so it follows the clip box rather than the source.
- [ ] Always apply a short declick (about 64 samples) at the instance start and end when no fade
  is set. Unit-test that a hard-cut sine starts and ends at 0.
- [ ] Tests: the envelope shape at 0, the midpoint and the end for each curve; fade in and fade
  out overlap on a short clip; the fades are correct after a seek.

Godot:
- [ ] `ClipInstance.set_fades(...)`, synced and saved. The fields already exist in the JSON.
- [ ] `AudioClipInspector`: fade-in and fade-out length (BBT or ms) and a curve knob for each.
- [ ] Timeline handles: small squares at the top corners of the clip. Drag horizontally to change
  the length (snapped; Shift for free movement) and vertically to change the curve. Register them
  with `Hotkeys` / help-bar interaction states like the other clip drags.
- [ ] `WaveformView` shows the fades through its existing `fade_in_frames`, `fade_out_frames`
  and `fade_curve` (add a separate out-curve if needed), plus a fade-line overlay on the clip.
- [ ] Check `ClipRangeActions` (split and trim) and `ClipMergeActions` against the fade
  semantics. A split must clear the fade on the inner edges; it already clears `fade_in`.

## Phase 6 — DAWproject, docs, ADR and glossary

- [ ] DAWproject export and import:
  - Raw = audio with `contentTimeUnit="seconds"` and no warps.
  - Repitch and Stretch = `Warps` as now.
  - Map the mode to and from `Audio@algorithm` where the spec allows it. Otherwise add a
    `TransferReport` note.
  - Fades go to and from `fadeInTime` / `fadeOutTime` (export already writes these).
- [ ] ADR 0020, "Audio clip stretch modes": the clip-level mode, Raw's anchoring semantics,
  Signalsmith Stretch, and why élastique and Rubber Band are out.
- [ ] `CONTEXT.md`: update **Clip**. Add **Stretch mode**, **Clip tempo** and **Fade**.
- [ ] Update `engine-architecture.md` (replace the stretching section), `osc-protocol.md` and
  `godot-architecture.md`.

## Later (not in this plan)

- Tempo detection on import (onset and autocorrelation on the `AudioFileService` worker).
- Beats mode (slicing at transients) and warp markers.
- A quality setting per clip (Signalsmith `preset_cheaper` vs `preset_default`).
- Crossfades between overlapping clips on a track, and clip gain envelopes.
- More inspector sections: `MidiClipInspector` (quantize, velocity, note count), `TrackInspector`,
  `NoteInspector` for MIDI editor selections, and a device inspector.

## Risks to watch

- **Stretch alignment.** Latency handling in `seek` is the part most likely to be off by a few
  ms. Write the click-alignment test before the render code.
- **CPU.** Signalsmith uses FFT. Many stretched clips playing at once may need the cheaper
  preset or a per-track limit.
- **Raw on a tempo map.** The waveform drawing is approximate until `WaveformView` can draw a
  non-linear tick-to-frame mapping.
- **Rescaling instances** when the clip tempo changes touches every instance of a shared clip,
  possibly on several tracks. It must be one undo step.
