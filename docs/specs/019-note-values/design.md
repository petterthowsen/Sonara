# 019: Note values and the value lane — Design

Implements [requirements.md](./requirements.md).

Status: draft, awaiting approval.

## Decisions from the design interview

These were settled before the requirements were written. They are recorded here so later specs
(expression curves) build on them instead of re-deciding them.

| # | Decision |
|---|---|
| Q1 | A note has **static values** (velocity, release) and, later, optional **expression curves**. A constant curve is a one-point curve, so there are no separate static timbre or pressure fields. |
| Q2 | Values are normalized floats everywhere. They are stored under the new keys `vel` and `rel`, migrated from `velocity / 127`. Release defaults to 0.5. |
| Q3 | Generative properties (chance, repeats) are deferred. The lane is built on **note value descriptors** so they can be added later. |
| Q4 | The expression vocabulary is a closed enum: `pitch`, `gain`, `pan`, `timbre`, `pressure`, in natural units following CLAP (pitch in semitones, gain as linear amplitude, pan centred at 0.5, timbre and pressure 0–1). |
| Q5 | Devices receive a `NoteEvent` (`On`/`Off`/`Expression`) carrying a runtime **sounding-note id**, which containers forward unchanged. |
| Q6 | Release reaches CLAP and sfizz, and a `release` modulator kind is added. The MIDI/MPE dialect translation waits for the curves spec. |
| Q7 | A stack of lane scenes in a resizable pane. Which lanes are open is an editor preference, not project data. |
| Q8 | Left-drag paints, Alt-drag shifts, Ctrl+Alt-drag scales, Ctrl-drag draws a line. Release stems sit at the note end. Velocity runs over `(0, 1]`. |
| Q9 | Editable notes get stems, context notes get none, and loop repeats and linked instances get ghost stems. Clicking a drum row header selects all of that row's notes. |
| Q10 | Formats for the curves phase: an `expr` map of automation-style points, a whole-curve OSC message per note and kind, and expression events every 64 samples. Not built here. |
| Q11 | New notes inherit velocity and release from the last touched note. One copy helper on the note model replaces the field-by-field copies. |
| Q12 | Phase 1 includes the Set, Randomize and Scale transforms. Order: foundation, then UI. |

## Context

**Godot model and persistence**
- `Godot/data/MidiNote.gd`: `MidiNoteData` with `velocity: int` and `to_json`/`from_json`
  (key `"velocity"`).
- `Godot/data/Clip.gd`:
  - `add_midi_note(note_id, note, velocity: int, start_tick, duration)` sends `/clip/{id}/add_note`.
  - `update_midi_note` sends `/clip/{id}/update_note`.
  - The split path (line 355) copies fields by hand.
  - `to_json`/`from_json` go through `_serialize_midi_notes`/`_deserialize_midi_notes`.
- `Godot/data/Project.gd`:
  - The clip sync loop (around line 551) sends `add_note` per note.
  - `to_json`/`from_json` (lines 1691/1724) have no format version.
- Notes are copied field by field in:
  - `Godot/data/NoteSelection.gd` (6 sites)
  - `Godot/clip_editor/note_editor/NoteEditor.gd` (lines 1151, 1328)
  - `Godot/history/commands/MakeClipUniqueCommand.gd`
  - `Godot/history/ClipMergeActions.gd`
  - `Godot/ai/clip_text/ClipTextGrid.gd`
- Notes are snapshotted field by field for undo in:
  - `Godot/history/commands/ClipNotesStateCommand.gd` (`_snapshot_note`, `_same_fields`, `_restore`)
  - `NoteEditor._history_snapshots_equal`
- `Godot/ai/clip_text/ClipTextKey.gd` maps dynamic tiers 1–9 to 7-bit velocities.
  `ClipTextEvents.gd` clamps to 1–127. `Godot/ai/tools/WriteClipTool.gd` compares
  `"velocity"` keys.
- `Godot/dawproject/DawProjectImporter.gd`:
  - `_import_notes` writes `"velocity"` via `DawUnits.normalized_to_velocity`.
  - It reports `TransferReport.NOTE_RELEASE`.
- `DawProjectExporter._write_notes` writes `vel` only.
- `Godot/midi/MidiManager.gd`:
  - The virtual keyboard and `send_note_to_channel` send note-off velocity 0.
  - `Channel.send_midi_event` sends 7-bit `/channel/{id}/midi_event`.

**Clip editor UI**
- `Godot/clip_editor/ClipEditor.tscn`: `HSplit/MainPanel/VBox` holds the ruler header and
  `MidiEditor` (a `ScrollContainer` with `HBox/{VPiano, DrumRowHeader, NoteArea}`).
  `BottomPanel/Toolbar` holds the note-map buttons, `Quantize` and `AuditionToggle`.
- `Godot/clip_editor/MidiEditor.gd`:
  - It owns `note_editors: Array[NoteEditor]` (one per track in track mode), `grid_helper`,
    `lane_layout`, `drum_view`, `_start_preview_note` and the audition.
  - `_set_h_scroll` mirrors the horizontal scroll into `GridHelper.scroll_position`.
  - Selecting in one editor clears the others (lines 539, 583).
- `Godot/clip_editor/note_editor/NoteContainer.gd`:
  - It builds `VisualNote`s (`visual_notes_by_id`, `_visuals_of`, `_repeats`).
  - It positions them with `NotePlacement.note_rect` / `repeat_rect`, and hides notes an
    instance doesn't play.
  - It emits `notes_changed`.
- `NoteEditor.gd`:
  - It extends `NoteContainer` and has a `selection_manager: NoteSelectionManager` (`selected_notes`, `selection_changed`).
  - Alt-drag edits velocity (`DragMode.VELOCITY`, 2 px per step), and drag end calls
    `Clip.update_midi_note`.
  - New notes are placed with velocity 100 (line 329).
- `Godot/clip_editor/VisualNote.gd`: `midi_note_data`, `clip_instance`, `repeat_pass`, and
  velocity brightness on a 1–127 scale (line 151).
  `note_editor/ContextNotesLayer.gd._shade_of(velocity: int)` mirrors that brightness.
- `Godot/components/GridHelper.gd`:
  - `scale_changed` fires on zoom.
  - `changed` fires on zoom and scroll.
  - Use `ticks_to_pixels` / `pixels_to_ticks` for conversion.
- `Godot/clip_editor/DrumRowHeader.gd` (no click selection) and `Godot/components/VPiano.gd`
  (`key_pressed`/`key_released`, left click auditions).
- Reusable value UI: `components/FineDrag.gd` (0.15× Shift), `components/ValueTooltip.gd`,
  `components/FloatingValueEditor.gd`. The interaction rules are in
  `docs/subsystems/godot-ui-components.md`.
- Persistence:
  - Internal UI state uses `Sonara.get_config` (e.g. `ClipEditor.AUDITION_CONFIG_KEY`).
  - User-facing settings are registered in `Godot/settings/Settings.gd` (`Type.CHOICE`).
  - Shortcuts are `project.godot` input actions, listed in Settings' keybinding groups (line 679).
- The undo helpers are `HistoryUtil.record_many` and `ClipNotesStateCommand.capture_clip_notes`.

**Engine**
- `Engine/src/audio/types.rs`:
  - `ClipNote { id: NoteId(u64), note, velocity: u8, start_tick, duration_ticks }`.
  - `Channel` holds `held_clip_notes: [u8; 128]` (per-key counts), `scheduled_midi_events`
    (live MIDI), `dispatch_scheduled_midi`, `send_clip_note`, `release_clip_notes` and
    `send_midi_event_to_devices`.
- `Engine/src/audio/processing.rs`:
  - `schedule_live_midi_events` drains `midi_queue`.
  - The clip loop collects `(track, key, velocity, is_on)` into
    `render_scratch.note_events`, and loop wraps send note-offs.
- `Engine/src/audio/render_scratch.rs`: `pub type NoteEvent = (TrackId, MidiNote, MidiVelocity, bool)`.
  **That name collides with the planned device event** and is renamed.
- `Engine/src/audio/devices/mod.rs`: `AudioDevice::send_midi_event(note: u8, velocity: u8,
  is_note_on, frame_offset)`.
- It is implemented by:
  - `chain.rs` and `container.rs`
  - `layer.rs` (remaps keys, tracks `held` per input key)
  - `drum_machine.rs` (routes by key, chokes)
  - `drums/host.rs`, `polysynth/mod.rs`, `sampler.rs`, `sfizz_device.rs`
  - `clap_host/subprocess_adapter/mod.rs`
  - `clap_host/adapter.rs` (an in-process adapter that nothing constructs outside its own file)
  - `audio/modulation/host.rs` (`ModulatedDevice`)
  - test devices in several `mod tests` blocks
- `Engine/src/audio/modulation/`:
  - `kinds.rs` `ModulatorKind` (`Velocity` and others; it is advertised to Godot over
    `/builtin/modulator_kind`, so Godot needs no kind list).
  - `state.rs` `ModulatorState::note_on(note, velocity: u8)`, `note_off`, `gate_voice_on`,
    `gate_voice_off`, `update_note`.
  - `polysynth/voice.rs` `trigger_mods` re-quantizes an f32 velocity to u8, and
    `Voice::release()`.
- `Engine/src/audio/ipc/protocol.rs`: `BlockEvent { sample_offset, kind, note, _reserved, value,
  id }`. `BlockEvent::note` sets `id: 0`.
- `Engine/src/plugin_host/audio_thread.rs` builds `Pckn::new(0, 0, key, key)`, so the CLAP
  note_id is currently the key.
- `Engine/src/osc/server.rs`:
  - `["clip", id, "add_note"|"update_note"]` match `OscType::Int` for velocity, and a
    mismatched type is **silently dropped**.
  - `["channel", id, "midi_event"]` carries raw 7-bit MIDI.
- `Engine/src/audio/commands.rs`: `AddNoteToClip` / `UpdateClipNote { velocity: MidiVelocity }`,
  and `MidiEvent` pushes to `channel.midi_queue`.
- The sfizz binding (`petterthowsen/rust-sfizz`) exposes only `note_on(note: u8, velocity: u8)`
  and `note_off(note: u8, velocity: u8)`.

## Approach

**Foundation.**

*Godot model.* `MidiNoteData` gets float `velocity` and `release`, plus the helpers every other
site uses:
- `copy_values_from`, `duplicate_note`
- `values`/`apply_values`/`values_equal` for undo snapshots
- `from_midi_velocity`/`to_midi_velocity` for the 7-bit edges (live MIDI, audition, AI tiers,
  the sfizz binding)

Every field-by-field copy and snapshot moves onto these, so the next note field (`expr`) is
added in one place. The project file gets `"format_version": 2`. Notes migrate by key presence
(`vel` wins, otherwise `velocity / 127`), so the migration doesn't depend on the version.
Godot's JSON parser can't tell `1` from `1.0`, and that's why the key has to change.

*Engine.* The device interface becomes
`send_note_event(&NoteEvent, frame_offset)`.

**Sounding-note ids.** Each channel gets an `ActiveNotes` table to issue them. It is a
fixed-capacity array that pairs every note-on with its note-off and remembers the id. It
replaces `held_clip_notes`:
- Clip notes pair by clip-note id, not by key. A note whose pitch or instance transpose
  changes while it's held still gets its note-off, which today's per-key count can't do.
- Live notes pair by (MIDI channel, key).
- Stop and seek release clip-sourced entries with the release value stored at note-on.

Containers forward the same `NoteEvent`, changing only `key` (Layer). Devices take float
velocity and release. sfizz quantizes at its binding. CLAP gets the id as the CLAP `note_id`.
`ModulatorState` moves to f32 and gains the `Release` kind.

**UI.** The value lanes follow the scene-first guideline (`godot-code-style.md`):
- `NoteValuePane.tscn` is instanced into `ClipEditor.tscn` under a new `VSplitContainer`, below
  `MidiEditor`. The pane instances one `ValueLane.tscn` per open lane.
- Each lane is a header column (name, scale, close, menu) plus a stem area that draws every
  stem in one `_draw()`. A node per stem would cost thousands of controls in a dense clip.
- The note values a lane can show are `NoteValueDescriptor` resources (`.tres`) that can be
  edited in the Godot editor.
- Stems read their x from the `VisualNote`s the note editors already lay out. Track mode, clip
  offsets, loop repeats and hidden (unplayed) notes then match the note area exactly, with no
  second placement path.
- The gesture maths and the transforms are static functions in their own scripts, so they can
  be tested headless without input simulation.

**Rejected alternatives**
- *Keep `velocity` as an int and add a `release_velocity` int.* It's the smallest diff, but
  everything stays at 7 bits, and the device interface would need a second rewrite for note
  ids (Q2, Q5).
- *Put velocity and release on the `AudioDevice` call as extra arguments* (`send_midi_event(key,
  vel: f32, rel: f32, …)`). It touches the same 12 implementations and 122 call sites as the
  enum does, and expressions would then touch them all again (Q5).
- *Lay stems out from note ticks in the lane.* It duplicates `NotePlacement` and the track-mode
  and loop logic, and would drift from the note area.
- *One node per stem.* It's simple input handling, but it doesn't scale to the clip sizes
  `test_clip_editor_performance.gd` covers.
- *Nested `VSplitContainer`s for the lane stack.* A changing number of lanes doesn't fit nested
  splits. Each lane has a bottom resize grip instead.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `Channel::active_notes: ActiveNotes` (fixed `[ActiveNote; 256]` + `len` + `next_id: u32`) | audio callback (under the state lock it already holds) | command thread only through `release_clip_notes` on stop/seek, which already runs under the state lock | yes: inline array, no allocation. When it's full, the oldest entry is released first. |
| `ClipNote.velocity: f32`, `ClipNote.release: f32` | command thread writes (`AddNoteToClip`/`UpdateClipNote`), audio callback reads | engine state lock, as today | yes |
| `RenderScratch::note_events: Vec<ClipNoteEvent>` | audio callback | preallocated (`MAX_NOTE_EVENTS`) | yes. Element is a `Copy` struct. |
| `ModulatorState.release: f32` | audio callback (inside the device) | n/a | yes |
| `ModulatedDevice` queued notes (`[QueuedNote; MIDI_QUEUE]`) | audio callback | n/a | yes, same fixed queue as today with a wider element |
| `SubprocessClapAdapter` input events | audio callback → shared memory | IPC ring, unchanged | yes |
| sfizz/sampler/drum queued events (`(usize, u8, f32, bool)`) | audio callback | existing preallocated queues | yes |

The `NoteEvent` enum is `Copy` and at most 16 bytes, and is passed by reference.

## Data and protocol changes

### Engine types (`Engine/src/audio/midi_types.rs`)

```rust
/// Engine-issued id of one sounding note (unique per channel while it sounds; never 0;
/// wraps below 2^31 so it fits a CLAP note_id).
pub type SoundingNoteId = u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoteExpression { Pitch, Gain, Pan, Timbre, Pressure }

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum NoteEvent {
    On { note_id: SoundingNoteId, key: u8, velocity: f32 },
    Off { note_id: SoundingNoteId, key: u8, release: f32 },
    Expression { note_id: SoundingNoteId, key: u8, kind: NoteExpression, value: f32 },
}
```

The `NoteEvent` helpers are `key()`, `note_id()` and `with_key(k)` (used by Layer).
`midi_types.rs` also gets `pub const DEFAULT_RELEASE: f32 = 0.5`.
`render_scratch.rs`'s tuple alias is renamed to
`ClipNoteEvent { track_id, clip_note_id: u64, key, velocity: f32, release: f32, is_on }`.

### Device trait (`Engine/src/audio/devices/mod.rs`)

`send_midi_event` is removed. In its place:

```rust
/// A note event taking effect `frame_offset` samples into the coming block. Containers forward
/// it with the same `note_id` (only `key` may change); devices that ignore expressions drop them.
fn send_note_event(&mut self, _event: &NoteEvent, _frame_offset: usize) {}
```

### Channel (`Engine/src/audio/types.rs`, new `Engine/src/audio/active_notes.rs`)

- `ActiveNotes::note_on(source: NoteSource, key, velocity, release) -> (Option<NoteEvent>, NoteEvent)`.
  The first event is an eviction note-off when the table is full.
- `ActiveNotes::note_off(source, key, release: Option<f32>) -> Option<NoteEvent>`.
  - It takes the oldest matching entry and uses the stored release when `release` is `None`.
  - `NoteSource::Clip { clip_note_id: u64 }` matches by clip-note id.
  - `NoteSource::Live { midi_channel: u8 }` matches by (midi channel, key).
- `ActiveNotes::release_clip(&mut self, out: impl FnMut(NoteEvent))` releases every
  clip-sourced entry.
- `Channel::send_clip_note(&ClipNoteEvent, frame_offset)`, `Channel::release_clip_notes()`
  (same name, new body), and `Channel::send_note_event_to_devices(&NoteEvent, frame_offset)`
  (renamed from `send_midi_event_to_devices`).
- `dispatch_scheduled_midi` turns live `MidiEvent`s into `NoteEvent`s through `ActiveNotes`:
  - A note-on with velocity > 0 becomes `On` with velocity `v/127`.
  - A note-off becomes `Off` with release `v/127`.
  - A note-on with velocity 0 becomes `Off` with release `DEFAULT_RELEASE`.

### Clip notes (`types.rs`, `commands.rs`)

`ClipNote { …, velocity: f32, release: f32 }`. `AddNoteToClip` / `UpdateClipNote` carry
`velocity: f32, release: f32`. `MidiVelocity` stays for raw live MIDI only.

### OSC (`Engine/src/osc/server.rs`, `docs/subsystems/osc-protocol.md`)

| Address | Old args | New args |
|---|---|---|
| `/clip/{id}/add_note` | `i:note_id i:note i:start_tick i:duration i:velocity` | `i:note_id i:note i:start_tick i:duration f:vel f:rel` |
| `/clip/{id}/update_note` | same as above | same as `add_note` |
| `/channel/{id}/midi_event` | unchanged | unchanged. **Semantics documented:** a NOTE_OFF's velocity is its release velocity, and a NOTE_ON with velocity 0 is a note-off with release 64/127. |

The handlers match `OscType::Float` for `vel`/`rel`. A message with any other argument shape
now logs `warn!` with the address and the argument types instead of being dropped silently.

### CLAP IPC (`Engine/src/audio/ipc/protocol.rs`, `plugin_host/audio_thread.rs`)

`BlockEvent::note(sample_offset, note_id: u32, key: u8, value: f32, is_note_on)` puts `note_id`
in `id`. The struct layout is unchanged. The plugin host builds `Pckn::new(0, 0, key, note_id)`.
`Expression` events aren't sent over IPC yet: the subprocess adapter drops them, and the
`EVENT_NOTE_EXPRESSION` kind comes with the curves spec. This is documented in
`engine-plugin-architecture.md`.

### Modulation (`Engine/src/audio/modulation/`)

- `ModulatorKind::Release` has id `"release"`, name `"Release"`, unipolar, and no parameters.
  It's advertised like the other kinds, and Godot's `ModulatorsPane` lists whatever
  `DeviceRegistry.modulator_kinds` holds.
- `ModulatorState`:
  - `note_on(note, velocity: f32, frame)` and `note_off(note, release: f32, frame)`.
  - `gate_voice_on(note, velocity: f32)` and `gate_voice_off(release: f32)`.
  - `update_note(note, velocity: f32)`.
- The `release` value resets to `DEFAULT_RELEASE` on each note-on and latches on note-off.
- `polysynth/voice.rs`: `trigger_mods` drops the u8 re-quantization, and `Voice::release(release: f32)`.

### Godot model (`Godot/data/MidiNote.gd`)

```gdscript
const MIN_VELOCITY := 1.0 / 127.0
const DEFAULT_VELOCITY := 100.0 / 127.0
const DEFAULT_RELEASE := 0.5
## Fields copied, snapshotted and compared as a note's values (everything but `id`).
const VALUE_FIELDS: Array[String] = ["note", "velocity", "release", "start_tick", "duration_ticks"]

var velocity: float = DEFAULT_VELOCITY:  # set: assert(v < 2.0) (catches old 0–127 values), clamp to [MIN_VELOCITY, 1]
var release: float = DEFAULT_RELEASE:    # set: clamp to [0, 1]

func copy_values_from(other: MidiNoteData) -> void
func duplicate_note() -> MidiNoteData            # id = -1
func values() -> Dictionary                      # VALUE_FIELDS
func apply_values(v: Dictionary) -> void
static func values_equal(a: Dictionary, b: Dictionary) -> bool
static func from_midi_velocity(v7: int) -> float
static func to_midi_velocity(v: float) -> int    # round, clamp 1..127
```

JSON: `{"id", "note", "start_tick", "duration_ticks", "vel"}`, plus `"rel"` when it isn't
approximately `DEFAULT_RELEASE`. `from_json` reads `vel` and `rel`, or falls back to
`velocity / 127` and the default release.

`Clip.add_midi_note(note_id, note, velocity: float, start_tick, duration, release := MidiNoteData.DEFAULT_RELEASE)`.
`add_note` and `update_note` send `[id, note, start, dur, velocity, release]`, and so does
`Project`'s sync loop.

### Persisted settings and config

- **Setting:** `clip_editor/note_value_display`, `Type.CHOICE` with `["0–127", "Percent"]`,
  default `"0–127"`, category Appearance, sub "Clip Editor".
- **Config:** `clip_editor/value_lanes` →
  `{"visible": true, "pane_height": 120, "lanes": [{"key": "vel", "height": 96}]}`. This is
  internal UI state (`Sonara.get_config`), not a setting.
- **Input action:** `toggle_note_value_lanes`, added to the "View" keybinding group with no
  default key.

## UI structure

New directory: `Godot/clip_editor/value_lanes/`. Every scene is built and edited with the Godot
MCP tools, never by hand-editing `.tscn`. Nodes get sensible defaults (sizes, theme overrides,
labels) so they look right in the Godot editor.

```
ClipEditor.tscn
└─ HSplit/MainPanel/VBox
   ├─ PanelContainer (header + Ruler)                 (unchanged)
   └─ EditorSplit: VSplitContainer                    (new; MidiEditor moves under it)
      ├─ MidiEditor (ScrollContainer, unchanged inside)
      └─ NoteValuePane (instance of value_lanes/NoteValuePane.tscn)
BottomPanel/Toolbar  + ValueLanesToggle (Button, toggle) + NextValue (SpinBox: next note's velocity)

value_lanes/NoteValuePane.tscn — NoteValuePane.gd (class_name NoteValuePane extends VBoxContainer)
├─ Header: HBoxContainer
│  ├─ HeaderSpacer: Control        (width follows MidiEditor's key column)
│  └─ AddLaneButton: MenuButton    ("+ Lane"; lists descriptors not yet open)
└─ Lanes: VBoxContainer            (ValueLane instances; order = config order)

value_lanes/ValueLane.tscn — ValueLane.gd (class_name ValueLane extends VBoxContainer)
├─ Row: HBoxContainer (size_flags_vertical = fill/expand)
│  ├─ LaneHeader: PanelContainer   (width follows the key column)
│  │  └─ VBox: NameLabel, MaxLabel, MinLabel, HBox{MenuButton (transforms), CloseButton}
│  └─ StemArea: Control            (ValueLaneStemArea.gd: _draw + _gui_input; clip_contents)
└─ ResizeGrip: Control             (4 px; drag changes the lane's custom_minimum_size.y)

value_lanes/NoteValueTransformDialog.tscn — ConfirmationDialog
└─ VBox: PromptLabel, AmountSpinBox                   (Set / Randomize / Scale reuse one dialog)

value_lanes/descriptors/velocity.tres, release.tres   (NoteValueDescriptor resources)
```

### Scripts

| Script | Responsibility |
|---|---|
| `NoteValueDescriptor.gd` (`Resource`) | `key` (`"vel"`), `display_name`, `property` (`"velocity"`), `min_value`, `max_value`, `default_value`, `anchor` (`START`/`END`), `get_value(nd)`, `set_value(nd, v)`, `format(v, display_mode)`. |
| `NoteValueDescriptors.gd` (static) | Loads and lists the `.tres` descriptors. `by_key(key)`. |
| `NoteValuePane.gd` | Reads and writes `clip_editor/value_lanes`. Adds and removes `ValueLane` instances (`preload`ed `PackedScene`). Hands each lane the `MidiEditor` it reads from. Keeps the header column width in step with `MidiEditor.key_column_width_changed`. |
| `ValueLane.gd` | Owns the descriptor, height and header labels. Connects the menu to the transform dialog. Forwards to `ValueLaneStemArea`. |
| `ValueLaneStemArea.gd` | Draws the stems: full, ghost, selected or hovered, coloured by track. Hit-tests and runs the gesture state machine (paint / offset / scale / line / Ctrl+click / double-click). Shows `ValueTooltip`, uses `FineDrag`, and records one undo step per gesture. Redraws on `GridHelper.changed`, `NoteContainer.notes_changed`, `selection_changed` and hover. |
| `ValueLaneEdits.gd` (static) | Pure maths: `value_at_y`, `offset(values, delta)`, `scale(values, factor)`, `line_value(p0, p1, x)`, `stems_at_x(stems, x, tolerance)`. |
| `NoteValueTransforms.gd` (static) | `set_all`, `randomize(values, amount, rng)`, `scale_around_mean(values, percent)`, each clamped to the descriptor's range. |

### Where stems come from

`MidiEditor.value_stems() -> Array[Dictionary]`:
- It returns one entry per **visible** `VisualNote` in `note_editors`. Context notes live in
  `ContextNotesLayer`, not in `note_editors`, so they're excluded by construction.
- Each entry has: `visual`, `note_data`, `clip` (`NoteEditor._clip_for_visual_note`), `color`
  (the track's colour in track mode), and `ghost`. A stem is a ghost when `repeat_pass > 0` or
  it isn't the first visual of its note data.
- It also has `x_start` (the visual's x in the `HScroll` content minus
  `GridHelper.scroll_position`) and `x_end`. `x_end` is `x_start + size.x`, or in Drum View,
  where hits have no length, `x_start + ticks_to_pixels(duration_ticks)`.

Editing a ghost edits its `note_data`, which is shared, so every visual of that note follows.
The selection is the union of `selected_notes` across `note_editors`.

### Gesture rules (REQ-021–025)

| Input | Effect |
|---|---|
| Left press/drag | Paint. The value comes from the pointer y. The target is the selection when one exists, otherwise all stems within ±3 px of the pointer x (a chord). Each stem the drag passes over is set once per pass. |
| Alt + drag | Offset. The target is the selection, or the stems at the press x. The delta is in value units per pixel of lane height. |
| Ctrl + Alt + drag | Scale toward 0 by the factor `(h − Δy) / h`. |
| Ctrl + drag (moved > 3 px) | Line preview. On release, stems inside the x span (selection only, if one exists) get `line_value`. |
| Shift (any drag) | `FineDrag` 0.15×, with no jump when pressed or released mid-drag. |
| Ctrl + click (no movement) | Reset to `default_value` (REQ-024 as amended). |
| Double-click a stem | `FloatingValueEditor`: type an exact value in the display format. The target follows the paint rule (selection, else the chord at that x). |
| Right-click | Lane context menu (Set…, Randomize…, Scale…). |

- **Undo:** each gesture snapshots the clips it touches first, using
  `ClipNotesStateCommand.capture_many(clips)` (extracted from `NoteEditor._history_begin_clips`).
  On release it commits with `ClipNotesStateCommand.commit_many(name, before)` (extracted from
  `NoteEditor._history_commit`).
- **Engine sync:** during the drag only `MidiNoteData` changes and the visuals refresh. On
  release, `Clip.update_midi_note` is called once per changed note, which sends the OSC message
  and the signal.
- **Audition:** while `MidiEditor.audition_enabled` is on and the gesture targets one note's
  velocity, the note is retriggered through `_start_preview_note` each time its quantized
  velocity changes.

### Selection and new notes (REQ-027, REQ-028)

- **Row selection:** `DrumRowHeader` emits `row_select_requested(row: int, additive: bool)` on
  a left click. `VPiano` emits `key_select_requested(note: int, additive: bool)` on a
  Ctrl+click, and doesn't emit `key_pressed` for it. `MidiEditor` handles both: it selects every
  editable visible visual whose pitch maps to that row (`lane_layout.row_of_pitch`), in the
  editors that own them.
- **Next-note values:** `MidiEditor` keeps a `NextNoteValues` object (`RefCounted`, `velocity`,
  `release`, a `changed` signal). Its defaults are `DEFAULT_VELOCITY` / `DEFAULT_RELEASE`.
  - `NoteEditor` emits `note_touched(note_data)` on a note click, drag start and resize start.
    `ValueLaneStemArea` emits it when a gesture ends.
  - `MidiEditor` copies the touched note's values in.
  - `NoteEditor._place_note_at_position` reads them instead of 100.
- **Toolbar readout:** the `NextValue` SpinBox shows the next note's velocity in the display
  format. A wheel or typed change writes `NextNoteValues.velocity` without editing notes.

## File-by-file change list

### Phase A: foundation

| File | Change |
|---|---|
| `Engine/src/audio/midi_types.rs` | `SoundingNoteId`, `NoteExpression`, `NoteEvent` (+ helpers), `DEFAULT_RELEASE`. |
| `Engine/src/audio/active_notes.rs` (new) | `ActiveNotes`, `ActiveNote`, `NoteSource`, plus unit tests (pairing, overlap, eviction, id wrap, clip release). Declared in `audio/mod.rs`. |
| `Engine/src/audio/render_scratch.rs` | `NoteEvent` alias → `ClipNoteEvent` struct. |
| `Engine/src/audio/types.rs` | `ClipNote` gets f32 `velocity`/`release`. `Channel`: `active_notes` replaces `held_clip_notes`, plus `send_clip_note`, `release_clip_notes`, `send_note_event_to_devices` and `dispatch_scheduled_midi` reworked. |
| `Engine/src/audio/processing.rs` | Collect `ClipNoteEvent`s (with `clip_note.id`, `velocity`, `release`, loop-wrap offs). Update the `send_clip_note` call and the tests at lines 632–644. |
| `Engine/src/audio/commands.rs` | `AddNoteToClip`/`UpdateClipNote` take f32 `velocity`, `release`, and apply them to `ClipNote`. |
| `Engine/src/osc/server.rs` | `add_note`/`update_note` take float `vel`/`rel`, and warn on a mismatched argument shape. |
| `Engine/src/audio/devices/mod.rs` | The trait gets `send_note_event` (replacing `send_midi_event`). Update the docs. |
| `Engine/src/audio/devices/chain.rs`, `container.rs` | Forward `NoteEvent`. Update the test devices. |
| `Engine/src/audio/devices/layer.rs` | Forward with `with_key(mapped)`. `held` keeps `(out_key, note_id)` per input so a retrigger releases with the right id. Add a test for REQ-008. |
| `Engine/src/audio/devices/drum_machine.rs` | Route by `event.key()`, choke on `On`, forward the same event. |
| `Engine/src/audio/devices/drums/host.rs` (+ `drums/mod.rs` if the voice API takes u8) | Queue `(frame, key, f32, on)`. A drum voice reads velocity as f32. |
| `Engine/src/audio/devices/polysynth/mod.rs`, `polysynth/voice.rs` | Note on/off take f32 velocity and release. `Voice::release(release)` and `trigger_mods` use f32. |
| `Engine/src/audio/devices/sampler.rs` | Queue f32 velocity and release (the sampler applies velocity as gain). |
| `Engine/src/audio/devices/sfizz_device.rs` | Queue f32. At the binding, `note_on(key, to_u7(vel))` and `note_off(key, to_u7(rel))`. |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs` | `BlockEvent::note(…, note_id, key, value, on)`. Drop `Expression`. |
| `Engine/src/audio/devices/clap_host/adapter.rs` | Mechanical signature migration (`note_id` into `NoteOnEvent`/`NoteOffEvent`). |
| `Engine/src/audio/ipc/protocol.rs` | `BlockEvent::note` takes and stores `note_id`. Add a round-trip test. |
| `Engine/src/plugin_host/audio_thread.rs` | `Pckn::new(0, 0, key, event.id)`. |
| `Engine/src/audio/modulation/kinds.rs`, `state.rs`, `host.rs`, `voice.rs` | `Release` kind. f32 note API. `ModulatedDevice` queues `NoteEvent`. Tests. |
| `Engine/src/audio/render/worker.rs` | Test devices get the new trait method (offline render uses the same `Channel` paths). |
| `Engine/src/audio/devices/effect_conformance.rs`, `drum_conformance.rs` | Send `NoteEvent`s. Add an "expression event is ignored" check (REQ-013). |
| Other `mod tests` implementing `AudioDevice` | Mechanical rename (`grep -rn "fn send_midi_event"` must come back empty). |
| `Godot/data/MidiNote.gd` | Float fields, constants, helpers, JSON `vel`/`rel` with migration. |
| `Godot/data/Clip.gd` | `add_midi_note` takes float `velocity`/`release`. OSC sends both. Split uses `copy_values_from`. |
| `Godot/data/Project.gd` | Sync sends `velocity, release`. `to_json` writes `format_version: 2`, and `from_json` reads it (missing = 1). |
| `Godot/data/NoteSelection.gd` | Its 6 copy sites use `duplicate_note`/`copy_values_from`. |
| `Godot/history/commands/ClipNotesStateCommand.gd` | Snapshots use `values()`/`apply_values`/`values_equal`. Add `capture_many`/`commit_many`. |
| `Godot/history/commands/MakeClipUniqueCommand.gd`, `Godot/history/ClipMergeActions.gd` | Use `duplicate_note`. |
| `Godot/clip_editor/note_editor/NoteEditor.gd` | Copy sites. `_history_snapshots_equal` → `values_equal`. History helpers delegate to `ClipNotesStateCommand`. Alt-drag velocity in float steps (1/127 per 2 px, as today). |
| `Godot/clip_editor/VisualNote.gd`, `note_editor/ContextNotesLayer.gd` | Brightness from float velocity (same shades). |
| `Godot/clip_editor/MidiEditor.gd` | `_start_preview_note` takes float and sends `to_midi_velocity`. |
| `Godot/midi/MidiManager.gd` | Note-offs from the virtual keyboard and `send_note_to_channel` send 64. |
| `Godot/ai/clip_text/ClipTextEvents.gd`, `ClipTextGrid.gd`, `ClipTextKey.gd`, `Godot/ai/tools/WriteClipTool.gd` | Convert at the tier/7-bit edge. Compare `velocity` as floats. |
| `Godot/dawproject/DawProjectImporter.gd` | `vel` at full precision, `rel` when present. Drop the `NOTE_RELEASE` report. |
| `Godot/dawproject/DawProjectExporter.gd` | Write `vel` directly, and `rel` when non-default. |
| `Godot/dawproject/TransferReport.gd` | Remove `NOTE_RELEASE`. |
| `Godot/dawproject/DawUnits.gd` | Remove `velocity_to_normalized`/`normalized_to_velocity` if nothing uses them any more. |
| Godot tests using `add_midi_note(…, <int velocity>, …)` or `.velocity = <int>` (~50 sites under `Godot/tests/`) | Use `MidiNoteData.from_midi_velocity(n)`. |

### Phase B: UI

| File | Change |
|---|---|
| `Godot/clip_editor/value_lanes/*` (new) | The scenes, scripts and descriptors listed under *UI structure*. |
| `Godot/clip_editor/ClipEditor.tscn` (via MCP) | `EditorSplit` with `MidiEditor` and a `NoteValuePane` instance. `ValueLanesToggle` and `NextValue` in the toolbar. |
| `Godot/clip_editor/ClipEditor.gd` | `midi_editor` path → `$HSplit/MainPanel/VBox/EditorSplit/MidiEditor`. Bind the pane, toggle, readout and shortcut. |
| `Godot/clip_editor/MidiEditor.gd` | `value_stems()`, `key_column_width_changed`, `NextNoteValues`, row/key selection handlers, `note_touched` wiring, and a hover cross-highlight API. |
| `Godot/clip_editor/note_editor/NoteEditor.gd` | `note_touched` signal. Placement reads `NextNoteValues`. A `hovered_note_changed` signal from `update_hover_cursor`. |
| `Godot/clip_editor/VisualNote.gd` | `set_value_hover(on)` highlight. |
| `Godot/clip_editor/DrumRowHeader.gd` | `row_select_requested` on left click (Shift = additive). |
| `Godot/components/VPiano.gd` | `key_select_requested` on Ctrl+click (Shift = additive). No audition for that click. |
| `Godot/settings/Settings.gd` | `clip_editor/note_value_display` setting. `toggle_note_value_lanes` in the View group. |
| `Godot/project.godot` | `toggle_note_value_lanes` input action. |

### Docs

| File | Change |
|---|---|
| `docs/subsystems/osc-protocol.md` | New `add_note`/`update_note` args. `midi_event` note-off semantics. Update the worked example at lines 764–780. |
| `docs/subsystems/engine-plugin-architecture.md` | `BlockEvent.id` carries the note id for notes. Expressions aren't on IPC yet. |
| `docs/subsystems/engine-architecture.md` | `NoteEvent`, `ActiveNotes`, sounding-note ids. |
| `docs/subsystems/godot-architecture.md` | Value lane pane, note value descriptors, `NextNoteValues`. |
| `docs/subsystems/dawproject.md` | `rel` is now transferred. Remove `note_release` from the report list. |
| `docs/adr/0015-per-note-values-and-sounding-note-ids.md` (new) | The Q1/Q2/Q4/Q5 decisions: normalized per-note values, the expression vocabulary, and the `NoteEvent` interface with sounding-note ids. |
| `CONTEXT.md` | **Note value**, **Release velocity**, **Note expression**, **Sounding-note id**, **Value lane**, **Last touched note**. |
| `AGENTS.md` | Channels-and-devices paragraph: MIDI → `NoteEvent` wording. |
| `TODO.md` | A spec 019 entry. Close "velocity of new notes is wrong" when REQ-028 is verified. |

## Migration and compatibility

- **Old projects:** a note without `vel` gets `velocity / 127` and release 0.5 (REQ-003). A file
  without `format_version` is version 1. The next save writes version 2 with the new keys, so
  older builds will then read every note at their default velocity (100). That's acceptable
  (Non-functional: compatibility).
- **Config:** `clip_editor/value_lanes` is new. A missing or malformed value falls back to the
  default (one velocity lane, visible, 120 px).
- **Clip `midi_events`** (raw `MidiEvent.gd` CC/program data) are untouched.
- **Engine and Godot version skew:** they're built together. The server warns on an old
  `add_note` shape, so a stale Godot build is visible in the logs and doesn't fail silently.

## Test plan

**Unit (Rust)**
- `cargo test active_notes`: pairing by clip-note id and by (channel, key); overlapping plays
  get distinct ids; eviction when full; ids never 0 and stay below 2^31; `release_clip` uses
  the stored release (REQ-007).
- `cargo test clip_note_reaches_device_with_float_values`: in `processing.rs`, a probe device
  sees 0.5039 / 0.25 (REQ-006).
- `cargo test overlapping_instances_get_distinct_note_ids`: in `processing.rs` (REQ-007).
- `cargo test layer_keeps_note_id_through_remap`: in `layer.rs` (REQ-008).
- `cargo test live_note_off_carries_release` / `live_note_on_zero_is_release_default`: in
  `types.rs` (REQ-009).
- `cargo test block_event_note_round_trips_id`: in `ipc/protocol.rs` (REQ-010).
- `cargo test sfizz_release_reaches_binding`: in `sfizz_device.rs`. It asserts that the queued
  note-off carries the quantized release. A sound check is live (REQ-011).
- `cargo test release_modulator_latches_on_note_off`: in `modulation/state.rs` (REQ-012).
- `cargo test expression_event_is_ignored`: in `effect_conformance.rs` and `drum_conformance.rs`
  (REQ-013).

**Godot** (`Godot/tests/run_all.sh <word>`)
- `test_note_values_model.gd`: clamping, assertion, defaults, `copy_values_from`, `values_equal`
  (REQ-001).
- `test_note_values_persistence.gd`: `vel`/`rel` keys, migration fixture (`velocity` 100 and 1),
  `format_version` (REQ-002–004).
- `test_note_values_preserved.gd`: copy/paste, duplicate, split, merge, make-unique, quantize,
  AI write, and undo/redo all keep `vel` 0.3 / `rel` 0.8 (REQ-005).
- `test_dawproject_import.gd`, `test_dawproject_export.gd`, `test_dawproject_roundtrip.gd`: `rel`
  cases (REQ-014).
- `test_device_modulators.gd`: a registry-fed `release` kind can be added and saved (REQ-012).
- `test_value_lane_pane.gd`: toggle, add and close lanes, config round trip, project JSON
  unchanged (REQ-015, REQ-016).
- `test_value_lane_stems.gd`: x alignment after zoom and scroll, release at the note end,
  geometry, track mode with context, loop and ghost stems (REQ-017–019).
- `test_value_lane_edits.gd`: `ValueLaneEdits` / `NoteValueTransforms` maths, plus
  `ValueLaneStemArea` gestures driven through synthetic `InputEventMouse*`: paint with and
  without a selection, offset, scale, line, reset, one history entry and the OSC send count
  (REQ-021–026).
- `test_row_selection.gd`: drum row header click / Shift-click and VPiano Ctrl-click (REQ-027).
- `test_next_note_values.gd`: inherit from the last touched note, the readout scroll (REQ-028).
- `test_clip_editor_performance.gd`: with the pane visible, must stay inside its existing
  budgets (Non-functional).

**Live**
- Draw notes, open release and velocity lanes, paint, play through PolySynth with a `release`
  modulator on the amp release, and hear the tail change.
- Load an SFZ with `trigger=release` regions, edit release, and check the level difference
  (REQ-011).
- A CLAP plugin that shows note ids or release velocity (e.g. a MIDI-monitor plugin) shows the
  edited values and distinct ids (REQ-010).
- Play a hardware controller with release velocity, and watch `last_info.log` (temporary
  logging) or the release modulator (REQ-009).
- Open a pre-019 project and check that it sounds the same, then save and reload.

## Risks

| Risk | Mitigation |
|---|---|
| A missed u8 → f32 site keeps 7-bit maths. | Rust's type errors catch the device side. On the Godot side, the setter asserts on values ≥ 2, and tests run with assertions on. |
| A note-off no longer finds its note-on (pairing changed from key to clip-note id), leaving hung notes. | `active_notes` tests cover overlaps, loop wraps, transposes and edits while held. Stop and seek still release everything. |
| Layer retrigger-while-held releases with the wrong id. | `held` stores `(out_key, note_id)`. A test covers a retrigger. |
| Drawing thousands of stems slows the clip editor. | One `_draw()` per lane, culled to the visible x range. Redraw only on the listed signals. `test_clip_editor_performance.gd` with the pane on. |
| Moving `MidiEditor` under `EditorSplit` breaks scene paths. | Only `ClipEditor.gd:26` references the path (verified). It's edited with the scene through MCP. |
| A plugin treats a `note_id` that changes per note differently from today's key-as-id. | CLAP requires plugins to accept unique ids, and the key and channel still match. Live check with a plugin GUI. |
| sfizz stays 7-bit. | Documented in REQ-011. The float HD API is a follow-up issue. |

## Open questions

Resolved at the design gate:

- [x] **REQ-024 follows the repo rule:** Ctrl+click resets and double-click types an exact value
  (`godot-ui-components.md` §3). `requirements.md` is amended.
- [x] **sfizz stays 7-bit** in this spec. Adding sfizz's float `hd_note_on`/`hd_note_off` to
  `rust-sfizz` is filed as a follow-up issue.
- [x] **`toggle_note_value_lanes` has no default key.** It's registered in the View group and
  bound in Settings. The toolbar toggle is always available.
