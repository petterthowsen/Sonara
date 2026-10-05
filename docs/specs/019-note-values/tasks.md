# 019: Note values and the value lane — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Gates before a task is marked `[x]`:
- Engine tasks: `cargo test` and `cargo fmt` (run from `Engine/`).
- GDScript tasks: the named `Godot/tests/run_all.sh <word>` run.
- Scene edits: made with the Godot MCP tools, never by hand-editing `.tscn`.

OSC sends in Godot tests are counted from `AudioEngineOSC._pending_sends`. In test mode the
client never binds, so every `send()` queues there. Clear it before the action under test. Clips
must be marked synced (`Clip.mark_synced_to_engine()`) for `update_midi_note` to send.

Phase order: **A. Foundation** (engine, then the Godot model, then interop, then an A-gate live
check), then **B. UI**, then **C. Docs**, then **D. Live verification**. Phase B starts only once
T-016 is verified.

## Phase A1: Engine

The device-interface switch runs through a temporary shim (T-004 to T-009), so every sitting
ends on a green build: `send_note_event` defaults to forwarding into the old `send_midi_event`
until every device is migrated, and T-009 deletes the shim.

- [x?] **T-001** [REQ-013] Add the note event types.
  - _Files_: `Engine/src/audio/midi_types.rs`
  - _Output_: `SoundingNoteId`, `NoteExpression` (5 kinds), `NoteEvent` (`On`/`Off`/`Expression`)
    with `key()`, `note_id()` and `with_key()`, and `DEFAULT_RELEASE = 0.5`.
  - _Verify_: `cargo test note_event_helpers`. `with_key` changes only the key, and
    `size_of::<NoteEvent>() <= 16`.
  - _Depends on_: —

- [x?] **T-002** [REQ-007] Add the `ActiveNotes` table.
  - _Files_: `Engine/src/audio/active_notes.rs` (new), `Engine/src/audio/mod.rs`
  - _Output_: a fixed `[ActiveNote; 256]` table with `note_on`, `note_off`, `release_clip`, and
    `NoteSource::{Clip, Live}`. Ids are never 0 and wrap below 2^31. When full, the oldest entry
    is released.
  - _Verify_: `cargo test active_notes`. Cases:
    - pairing by clip-note id after a key change
    - pairing by (channel, key) for live notes
    - two overlapping plays of one clip note getting distinct ids, with each off matching its on
    - eviction when full
    - id wrap
    - `release_clip` using the stored release and leaving live entries alone
  - _Depends on_: T-001

- [x?] **T-003** [REQ-006] Make clip notes carry float velocity and release, from OSC to `ClipNote`.
  - _Files_: `Engine/src/audio/types.rs` (`ClipNote`), `Engine/src/audio/commands.rs`
    (`AddNoteToClip`, `UpdateClipNote` and their apply arms), `Engine/src/osc/server.rs`
    (`add_note`, `update_note`), `Engine/src/audio/processing.rs` (the temporary u8 conversion)
  - _Output_:
    - `ClipNote { velocity: f32, release: f32 }`.
    - The handlers parse `i i i i f f`.
    - Any other argument shape logs `warn!` with the address and the argument types.
    - Playback still feeds devices through a temporary `(velocity * 127).round() as u8`
      conversion in `processing.rs`, until T-004 replaces it.
  - _Verify_: `cargo test`. A new `cargo test clip_note_command_stores_float_values` applies
    `AddNoteToClip` with 0.5039 / 0.25 and reads the values back. Sending
    `oscsend localhost 7000 /clip/x/add_note iiiii 1 60 0 480 100` against a running engine logs
    the warning (live, optional).
  - _Depends on_: —

- [x?] **T-004** [REQ-006, REQ-007, REQ-009] Route the channel's notes through `NoteEvent` and
  `ActiveNotes`.
  - _Files_: `Engine/src/audio/devices/mod.rs` (add `send_note_event` with a shim default:
    `On` → `send_midi_event(key, u7(vel), true)`, `Off` → `(key, 0, false)`, `Expression`
    dropped), `Engine/src/audio/types.rs` (`Channel::active_notes` replaces `held_clip_notes`;
    `send_clip_note(&ClipNoteEvent, offset)`, `release_clip_notes`,
    `send_note_event_to_devices`, `dispatch_scheduled_midi`), `Engine/src/audio/render_scratch.rs`
    (`ClipNoteEvent`), `Engine/src/audio/processing.rs` (collect `ClipNoteEvent`s including
    loop-wrap offs; update the tests at lines 632–644), `Engine/src/audio/render/worker.rs`,
    `Engine/src/audio/commands.rs` (stop/seek callers)
  - _Output_:
    - Clip notes and live MIDI reach devices as `NoteEvent`s with sounding-note ids.
    - A live note-off carries `v/127` as its release.
    - A note-on with velocity 0 becomes `Off` with release 0.5.
  - _Verify_: `cargo test clip_note_reaches_device_with_float_values
    overlapping_instances_get_distinct_note_ids live_note_off_carries_release
    live_note_on_zero_is_release_default`, using a probe device that implements
    `send_note_event`. Then the full `cargo test`, which includes the existing release-on-stop tests.
  - _Depends on_: T-002, T-003

- [x?] **T-005** [REQ-008] Move the containers onto `send_note_event`.
  - _Files_: `Engine/src/audio/devices/chain.rs`, `container.rs`, `layer.rs`, `drum_machine.rs`
  - _Output_:
    - Chain and container forward the event unchanged.
    - Layer forwards `with_key(mapped)`, and `held` stores `(out_key, note_id)` so a retrigger
      while held releases with the right id.
    - Drum Machine routes by `key()` and chokes on `On`.
  - _Verify_: `cargo test layer_keeps_note_id_through_remap layer_retrigger_releases_held_id
    drum_machine`. Then the full `cargo test`.
  - _Depends on_: T-004

- [x?] **T-006** [REQ-012] Move the modulators to f32 and add the `Release` modulator kind.
  - _Files_: `Engine/src/audio/modulation/kinds.rs`, `state.rs`, `host.rs` (`ModulatedDevice`
    queues `NoteEvent`, implements `send_note_event`), `voice.rs`
  - _Output_:
    - `ModulatorKind::Release`: `"release"`, unipolar, no params.
    - Note-on resets it to 0.5 and note-off latches the release.
    - The `note_on`, `note_off`, `gate_voice_on`, `gate_voice_off` and `update_note` API takes f32.
  - _Verify_: `cargo test release_modulator_latches_on_note_off` (per voice and mono paths).
    Then the full `cargo test`. `/builtin/modulator_kind` advertises `release` (covered by the
    kinds listing test, extended).
  - _Depends on_: T-004

- [x?] **T-007** [REQ-006, REQ-011, REQ-012] Move the instruments onto `send_note_event`.
  - _Files_: `Engine/src/audio/devices/polysynth/mod.rs`, `polysynth/voice.rs`
    (`Voice::release(release)`, `trigger_mods` without u8), `sampler.rs`, `drums/host.rs`,
    `sfizz_device.rs` (quantize at the binding)
  - _Output_:
    - Instruments take float velocity.
    - PolySynth voices pass release to their `release` modulators.
    - sfizz receives a 7-bit release on note-off.
  - _Verify_: `cargo test sfizz_release_reaches_binding polysynth_release_modulator_sees_release`.
    Then the full `cargo test`, including `drum_conformance`.
  - _Depends on_: T-005, T-006

- [x?] **T-008** [REQ-010] Give CLAP plugins the note id and the float values.
  - _Files_: `Engine/src/audio/ipc/protocol.rs` (`BlockEvent::note(…, note_id, key, value,
    on)`), `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs`,
    `Engine/src/plugin_host/audio_thread.rs` (`Pckn::new(0, 0, key, event.id)`),
    `Engine/src/audio/devices/clap_host/adapter.rs` (mechanical)
  - _Output_:
    - CLAP note-on and note-off carry the sounding-note id and the float velocity or release.
    - The subprocess adapter drops `Expression`.
  - _Verify_: `cargo test block_event_note_round_trips_id`. Then the full `cargo test`.
  - _Depends on_: T-004

- [x?] **T-009** [REQ-013] Remove the shim and check that expression events are ignored.
  - _Files_: `Engine/src/audio/devices/mod.rs` (delete `send_midi_event`; the default
    `send_note_event` becomes a no-op), every remaining `mod tests` device,
    `Engine/src/audio/devices/effect_conformance.rs`, `drum_conformance.rs`
  - _Output_: a single note path. Conformance sends an `Expression` event to every built-in.
  - _Verify_:
    - `grep -rn "send_midi_event" Engine/src` is empty.
    - `cargo test expression_event_is_ignored` passes.
    - The full `cargo test` and `cargo fmt --check` are clean.
  - _Depends on_: T-005, T-006, T-007, T-008

## Phase A2: Godot model and interop

- [ ] **T-010** [REQ-001, REQ-002, REQ-003] Make the note model float and give it value helpers.
  - _Files_: `Godot/data/MidiNote.gd`
  - _Output_:
    - Float `velocity` (asserts on values ≥ 2, clamps to [1/127, 1]) and `release` (clamps to
      [0, 1]).
    - The constants and `VALUE_FIELDS`.
    - `copy_values_from`, `duplicate_note`, `values`, `apply_values`, `values_equal`,
      `from_midi_velocity` and `to_midi_velocity`.
    - JSON `vel` / `rel` (the default is omitted), with the fallback from `velocity`.
  - _Verify_: `Godot/tests/run_all.sh note_values_model note_values_persistence` (new
    `Godot/tests/test_note_values_model.gd` and `test_note_values_persistence.gd`; the second
    covers the `velocity` 100 / 1 fixture and the key assertions).
  - _Depends on_: —

- [ ] **T-011** [REQ-001] Update the test suite's integer velocities.
  - _Files_: `Godot/tests/*.gd` (about 50 `add_midi_note(…, <int>, …)` and `.velocity = <int>`
    sites)
  - _Output_: tests pass velocities through `MidiNoteData.from_midi_velocity(n)`.
  - _Verify_: `grep -rnE "add_midi_note\([^)]*, [0-9]+, [0-9]+, [0-9]+\)" Godot/tests` is
    empty. Full `Godot/tests/run_all.sh` passes (except tests that depend on T-012–T-015,
    which are listed in the task note when marking `[x?]`).
  - _Depends on_: T-010

- [ ] **T-012** [REQ-002, REQ-004, REQ-006] Make Clip and Project sync and save the new values.
  - _Files_: `Godot/data/Clip.gd` (`add_midi_note(…, velocity: float, …, release := DEFAULT)`,
    `update_midi_note`, split via `copy_values_from`), `Godot/data/Project.gd` (sync loop,
    `format_version: 2` in `to_json`, read in `from_json`)
  - _Output_:
    - `add_note` and `update_note` send `[id, note, start, dur, vel, rel]`, with floats.
    - Projects save version 2.
  - _Verify_: `Godot/tests/run_all.sh note_values_persistence`. Extend it to assert the
    `_pending_sends` payload types (`float` at index 4 and 5) and `format_version`.
  - _Depends on_: T-010

- [ ] **T-013** [REQ-005] Route every copy and snapshot site through the note helpers.
  - _Files_: `Godot/data/NoteSelection.gd`, `Godot/history/commands/ClipNotesStateCommand.gd`
    (snapshots via `values()`; new `capture_many` / `commit_many`),
    `Godot/history/commands/MakeClipUniqueCommand.gd`, `Godot/history/ClipMergeActions.gd`,
    `Godot/clip_editor/note_editor/NoteEditor.gd` (copy sites, `_history_snapshots_equal`,
    history helpers delegate)
  - _Output_: no remaining field-by-field note copy outside `MidiNote.gd`.
  - _Verify_:
    - `grep -rn "\.velocity = " Godot --include=*.gd | grep -v tests` lists only `MidiNote.gd`,
      the NoteEditor Alt-drag and the AI tier edge.
    - `Godot/tests/run_all.sh note_values_preserved` passes. The new
      `test_note_values_preserved.gd` covers copy/paste, duplicate, split, merge, make-unique,
      quantize and undo/redo with `vel` 0.3 / `rel` 0.8.
  - _Depends on_: T-012

- [ ] **T-014** [REQ-005, REQ-009] Update the remaining velocity consumers.
  - _Files_: `Godot/clip_editor/VisualNote.gd`, `note_editor/ContextNotesLayer.gd`,
    `note_editor/NoteEditor.gd` (Alt-drag in 1/127 steps), `Godot/clip_editor/MidiEditor.gd`
    (`_start_preview_note` takes float), `Godot/midi/MidiManager.gd` (note-off velocity 64),
    `Godot/ai/clip_text/ClipTextEvents.gd`, `ClipTextGrid.gd`, `ClipTextKey.gd`,
    `Godot/ai/tools/WriteClipTool.gd`
  - _Output_:
    - Brightness shades and AI tiers behave as before.
    - The virtual keyboard sends release 64.
  - _Verify_: `Godot/tests/run_all.sh clip_text drum_view context_notes loop_repeats` passes,
    along with `Godot/ai/tests`. Then the full `Godot/tests/run_all.sh`.
  - _Depends on_: T-011, T-013

- [ ] **T-015** [REQ-014] Import and export release velocity in DAWproject.
  - _Files_: `Godot/dawproject/DawProjectImporter.gd`, `DawProjectExporter.gd`,
    `TransferReport.gd` (drop `NOTE_RELEASE`), `DawUnits.gd` (drop the unused velocity
    helpers), `Godot/tests/test_dawproject_import.gd`, `test_dawproject_export.gd`,
    `test_dawproject_roundtrip.gd`
  - _Output_: `vel` at full precision, `rel` imported, and `rel` exported when non-default.
  - _Verify_: `Godot/tests/run_all.sh dawproject` passes, including the new `vel="0.503"` /
    `rel="0.2"` cases.
  - _Depends on_: T-012

- [ ] **T-016** [REQ-003, REQ-006, REQ-009, REQ-010, REQ-011, REQ-012] **A-gate live check.**
  - _Files_: — (temporary `info!` logging in `send_clip_note` / the subprocess adapter if
    needed; removed afterwards)
  - _Output_: the foundation is confirmed with a running engine and Godot, and `STATUS.md` notes
    what was checked.
  - _Verify_:
    - A pre-019 project plays at the same loudness, saves with `vel` keys, and reloads.
    - Release velocity set to 0.9 and 0.2 (by editing JSON, since the UI isn't there yet)
      changes a PolySynth tail that has a `release` modulator routed to amp release.
    - An SFZ with `trigger=release` regions plays at different levels.
    - A CLAP plugin gets distinct note ids per note (the log or a monitor plugin).
    - The virtual keyboard still plays.
  - _Depends on_: T-009, T-014, T-015

## Phase B: UI

- [ ] **T-017** [REQ-020] Add the note value descriptors and the display setting.
  - _Files_: `Godot/clip_editor/value_lanes/NoteValueDescriptor.gd`,
    `NoteValueDescriptors.gd`, `descriptors/velocity.tres`, `descriptors/release.tres`
    (created via MCP), `Godot/settings/Settings.gd` (`clip_editor/note_value_display`)
  - _Output_: two descriptors with `format()` for 0–127 and percent, and the setting registered.
  - _Verify_: `Godot/tests/run_all.sh value_lane_edits` passes. Its formatter section shows 100/127
    as "100", or "79%" in percent mode.
  - _Depends on_: T-016

- [ ] **T-018** [REQ-021, REQ-022, REQ-023, REQ-026] Write the pure edit and transform maths.
  - _Files_: `Godot/clip_editor/value_lanes/ValueLaneEdits.gd`, `NoteValueTransforms.gd`
  - _Output_: `value_at_y`, `offset`, `scale`, `line_value`, `stems_at_x`, `set_all`,
    `randomize`, `scale_around_mean`, each clamped per descriptor.
  - _Verify_: `Godot/tests/run_all.sh value_lane_edits` passes. Cases:
    - offset of 0.4 / 0.6 by +0.2 gives 0.6 / 0.8
    - scale by half gives 0.2 / 0.3
    - a line over five stems gives 0.2…1.0
    - Scale 50% of 0.2 / 0.6 gives 0.3 / 0.5
    - seeded Randomize stays within ±0.1
  - _Depends on_: T-017

- [ ] **T-019** [REQ-015, REQ-016] Build the pane and lane scenes and wire them into the clip editor.
  - _Files_: `Godot/clip_editor/value_lanes/NoteValuePane.tscn` + `.gd`, `ValueLane.tscn` +
    `.gd`, `ValueLaneStemArea.gd` (empty `_draw` for now), `Godot/clip_editor/ClipEditor.tscn`
    (via MCP: `EditorSplit` VSplitContainer holding `MidiEditor` and a `NoteValuePane` instance;
    toolbar `ValueLanesToggle`), `Godot/clip_editor/ClipEditor.gd` (new `midi_editor` path,
    bindings), `Godot/project.godot` + `Godot/settings/Settings.gd` (`toggle_note_value_lanes`
    with no key, in the View group)
  - _Output_:
    - The pane shows below the note area and holds one velocity lane by default.
    - "+ Lane" adds and the close button removes.
    - Heights and visibility persist in `clip_editor/value_lanes`.
    - The header column tracks `MidiEditor.key_column_width_changed`.
  - _Verify_: `Godot/tests/run_all.sh value_lane_pane` passes. The new `test_value_lane_pane.gd`
    covers toggle, add, close, re-create, and project JSON unchanged. The scenes open cleanly in
    the Godot editor with visible defaults (MCP screenshot).
  - _Depends on_: T-017

- [ ] **T-020** [REQ-017, REQ-018, REQ-019] Draw the stems.
  - _Files_: `Godot/clip_editor/MidiEditor.gd` (`value_stems()`, `key_column_width_changed`,
    hover cross-highlight), `Godot/clip_editor/value_lanes/ValueLaneStemArea.gd` (draw, culling,
    redraw signals), `Godot/clip_editor/VisualNote.gd` (`set_value_hover`),
    `Godot/clip_editor/note_editor/NoteEditor.gd` (`hovered_note_changed`)
  - _Output_:
    - Velocity stems at the note start and release stems at the note end (the start plus the
      duration in Drum View).
    - Full stems for editable notes, track-coloured in track mode.
    - No stems for context notes. Ghost stems for repeats and linked visuals.
    - Selected and hovered states.
  - _Verify_: `Godot/tests/run_all.sh value_lane_stems` passes. The new `test_value_lane_stems.gd`
    covers alignment after zoom and scroll, stem geometry, and the track-mode, context and loop
    stem counts.
  - _Depends on_: T-019

- [ ] **T-021** [REQ-021, REQ-022, REQ-023, REQ-024, REQ-025] Implement the lane gestures.
  - _Files_: `Godot/clip_editor/value_lanes/ValueLaneStemArea.gd`,
    `Godot/history/commands/ClipNotesStateCommand.gd` (use `capture_many` / `commit_many`)
  - _Output_:
    - Paint, Alt offset, Ctrl+Alt scale, Ctrl line, Shift fine (`FineDrag`), Ctrl+click reset,
      double-click exact value (`FloatingValueEditor`), and a `ValueTooltip` while dragging.
    - One undo step per gesture. `update_midi_note` is called per changed note on release.
    - Audition on a single-note velocity drag while audition is on.
  - _Verify_: `Godot/tests/run_all.sh value_lane_edits` passes. Its gesture section uses synthetic
    mouse events and checks:
    - paint with and without a selection, including the chord case
    - offset, scale and line
    - Ctrl+click on a 0.9 release gives 0.5
    - double-click and "64" gives 64/127
    - one history entry, and five `update_note` sends in `_pending_sends` only after the release
    - undo restores the values
  - _Depends on_: T-018, T-020

- [ ] **T-022** [REQ-026] Add the transforms menu and dialog.
  - _Files_: `Godot/clip_editor/value_lanes/NoteValueTransformDialog.tscn` (via MCP) + script,
    `ValueLane.gd` (menu → dialog → `NoteValueTransforms`)
  - _Output_: Set…, Randomize… and Scale… act on the selection, or on every editable note when
    nothing is selected. Each is one undo step.
  - _Verify_: `Godot/tests/run_all.sh value_lane_edits` passes. Its transform section drives the
    dialog: Set 0.5 on all notes with no selection, and undo.
  - _Depends on_: T-021

- [ ] **T-023** [REQ-027] Select a row's notes from the drum row header and the piano keys.
  - _Files_: `Godot/clip_editor/DrumRowHeader.gd` (`row_select_requested`),
    `Godot/components/VPiano.gd` (`key_select_requested` on Ctrl+click, no audition),
    `Godot/clip_editor/MidiEditor.gd` (handlers)
  - _Output_:
    - A row header click selects that row's editable notes, and Shift adds.
    - Ctrl+click on a key selects that pitch.
  - _Verify_: `Godot/tests/run_all.sh row_selection` passes. The new `test_row_selection.gd` uses
    three rows, a Shift-add, and a piano Ctrl-click.
  - _Depends on_: T-016

- [ ] **T-024** [REQ-028] New notes inherit the last touched note's values.
  - _Files_: `Godot/clip_editor/MidiEditor.gd` (`NextNoteValues`), `note_editor/NoteEditor.gd`
    (`note_touched`; placement reads next values), `value_lanes/ValueLaneStemArea.gd` (emits
    touched), `Godot/clip_editor/ClipEditor.tscn` (via MCP: toolbar `NextValue` SpinBox),
    `ClipEditor.gd`, `TODO.md`
  - _Output_:
    - Drawn notes take the last touched note's `vel` and `rel` (defaults 100/127 and 0.5).
    - The toolbar SpinBox shows and changes the next velocity.
    - The `TODO.md` item "velocity of new notes is wrong" is marked `[x?]`.
  - _Verify_: `Godot/tests/run_all.sh next_note_values` passes. The new `test_next_note_values.gd`
    touches 0.3 / 0.7 and draws, then changes the readout and draws.
  - _Depends on_: T-021

- [ ] **T-025** [Non-functional] Check the clip editor's performance with the pane visible.
  - _Files_: `Godot/tests/test_clip_editor_performance.gd` (add a variant with the pane visible)
  - _Output_: the existing budgets hold with one velocity lane shown.
  - _Verify_: `Godot/tests/run_all.sh clip_editor_performance` passes.
  - _Depends on_: T-020

## Phase C: Docs

- [ ] **T-026** [REQ-006, REQ-009] Update the OSC protocol doc.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: the `add_note` / `update_note` args `f:vel f:rel`, the `midi_event` note-off and
    velocity-0 semantics, and the worked example (lines 764–780) updated.
  - _Verify_: `grep -n "add_note\|update_note" docs/subsystems/osc-protocol.md` shows only the
    new shapes.
  - _Depends on_: T-012

- [ ] **T-027** [REQ-007, REQ-010, REQ-013] Update the engine docs.
  - _Files_: `docs/subsystems/engine-architecture.md`, `engine-plugin-architecture.md`, `AGENTS.md`
  - _Output_: `NoteEvent`, `ActiveNotes` and sounding-note ids documented. `BlockEvent.id` for
    notes, and expressions not yet on IPC. The AGENTS.md devices paragraph updated.
  - _Verify_: `grep -rn "send_midi_event" docs AGENTS.md` is empty.
  - _Depends on_: T-009

- [ ] **T-028** [REQ-014, REQ-015] Update the Godot and DAWproject docs.
  - _Files_: `docs/subsystems/godot-architecture.md`, `docs/subsystems/dawproject.md`
  - _Output_: the value lane pane, descriptors and `NextNoteValues` documented. `rel` is
    transferred, and `note_release` is removed from the report list.
  - _Verify_: `grep -n "note_release" docs/subsystems/dawproject.md` is empty, and the value
    lanes section exists.
  - _Depends on_: T-024

- [ ] **T-029** [REQ-all] Write the ADR and the glossary entries.
  - _Files_: `docs/adr/0015-per-note-values-and-sounding-note-ids.md` (new), `CONTEXT.md`
  - _Output_:
    - The ADR records Q1, Q2, Q4 and Q5: normalized per-note values, the expression vocabulary,
      and `NoteEvent` with sounding-note ids that containers keep.
    - Glossary: Note value, Release velocity, Note expression, Sounding-note id, Value lane,
      Last touched note.
  - _Verify_: the ADR follows the existing ADR format (Status / Context / Decision /
    Consequences), and every glossary term appears in `CONTEXT.md`.
  - _Depends on_: T-009

## Phase D: Live verification

- [ ] **T-030** [REQ-all] Run the full live pass.
  - _Files_: `TODO.md`, `STATUS.md`
  - _Output_: the spec 019 `TODO.md` entry is marked `[x]` and the new-note velocity item `[x]`.
    `STATUS.md` notes what was checked.
  - _Verify_, with the engine and Godot running:
    1. Open velocity and release lanes. Paint a crescendo with Ctrl-drag. Alt-drag a chord.
       Ctrl+click reset, double-click and type a value, undo and redo. Watch that playback follows.
    2. In track mode, check that context tracks show no stems and loop repeats show ghosts.
    3. In Drum View, click the hat row header and paint only the hats.
    4. Draw new notes after touching a quiet note, and check they come in quiet.
    5. Restart and check that the lanes and heights come back.
    6. Repeat the T-016 sound checks (the PolySynth `release` modulator, an SFZ release, CLAP
       note ids) using the UI instead of JSON.
  - _Depends on_: T-022, T-023, T-024, T-025, T-026, T-027, T-028, T-029
