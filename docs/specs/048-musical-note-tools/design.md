# Musical Note Tools — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/clip_editor/note_editor/NoteTransforms.gd`: pure, headless selection math (quantize,
  mirror, strum, scale stepping). `group_by_start(notes, tolerance)` and `STRUM_TOLERANCE_TICKS`
  (60) define the requirements' *chord*. `step_in_scale(pitch, steps, pcs)` already does REQ-031's
  "scale steps from the in-scale pitch below, keep the chromatic offset".
- `Godot/clip_editor/note_editor/NoteEditor.gd`:
  - `_apply_selection_edit(history_name, edit)` runs an edit on the selected `MidiNoteData`.
    Afterwards it cuts same-pitch overlaps (`_sync_edited_notes`), syncs the engine and records one
    step through `_history_begin_selection` / `_history_commit`. That step is
    `ClipNotesStateCommand.commit_many` plus a `SelectionStateCommand`.
  - `strum_selection()` shows how to keep chords per clip (`clip_of` map).
  - `get_paste_tick()` is the edit position.
  - `_transfer_note_between_clips()` moves one note between instances.
  - `selection_manager.has_range()` and `box_selection_start_tick` / `_end_tick` give the time range.
- `Godot/clip_editor/ClipEditor.gd`:
  - `_setup_selection_tools()` / `_register_selection_tool(button, run, works_in_drum_view,
    needs_scale)` wire the tool buttons in `ToolsGroup` (`ClipEditor.tscn`).
  - `_sync_selection_tools()` enables them: with a selection (or in clip mode), not in Drum View
    unless the tool allows it, and not with `scale_context.scale.is_none()` for scale tools.
  - The Quantize and Strum option popups (`_on_quantize_options_pressed`) are the pattern for
    remembered options.
- `ClipEditor.gd:286-292`: `scale_context.scale` is `Project.get_scale_at_tick(instance start)`.
- `Godot/data/Project.gd`: `get_scale_at_tick(tick)` → `key_change_map.scale_at_tick(tick,
  scale_root, scale_type)` (spec 034). `create_clip`, `tracks`.
- `Godot/data/MusicalScale.gd`: `make(root, type_id)`, `pitch_classes()`, `is_none()`, `root`,
  `type_id`. The catalogue ids include `major` and `natural_minor` (spec 038).
- `Godot/editor/ScalePicker.gd`: root and type dropdowns that emit `scale_picked(root,
  type_id)`. One instance is the transport's (`Editor.gd:72`, `scale_picker`), and another lives
  in `KeyChangeTrack`'s popup (`arranger/ruler/KeyChangeTrack.gd`, `open_dropdown(change_id, …)`,
  where change id 0 is the start key).
- `Godot/data/KeyChangeMap.gd`: `changes` (sorted dicts with tick, root and type),
  `index_of(change_id)`, `snapshot()`/`restore()`. It is undone through `KeyChangeMapStateCommand`.
- `Godot/data/NoteMapResolver.gd`: `wants_drum_view(channel)`. This is how REQ-010 excludes drum
  tracks without an open editor.
- `Godot/editor/Editor.gd`: `selected_tracks: Array[Track]` and `tracks_selected` (the arranger
  and Track List selection).
- History: `history/ClipActions.gd` `create_clip()` executes its own step, so it is not usable
  inside a combined step. We use `ClipInstanceCreateCommand`, `ClipInstanceTransformCommand`,
  `ClipNotesStateCommand` and `HistoryUtil.record_many(label, cmds)` / `execute_many` directly.
  `AudioClipTiming.instances_of(project, clip)` lists every instance of a clip, which is how a
  linked clip is detected (REQ-043).
- `Godot/input/HotkeyActions.gd`: the `ACTIONS` table, context `clip_editor`, with `requires:
  "note_selection"`.
- `Godot/components/HDualSlider.gd`: the dual-handle slider for the note ranges (REQ-034, 035).

## Approach

**Pure music logic, thin UI.** All the music theory lives in four new static,
scene-free classes under a new `Godot/clip_editor/harmony/` folder, just as `NoteTransforms` does
for the existing tools. They take `Array[MidiNoteData]` plus plain values and return plans or new
notes, so every REQ example can be checked in a headless unit test without building an editor.

- `NoteVoices`: voice ranks and inversion.
- `KeyDetector`: key estimate from a pitch-class histogram.
- `ChordTheory`: progression parsing, diatonic chords, voicing and root detection.
- `HarmonyGenerators`: harmonize, chords and bassline.

`NoteEditor` gets one public method per tool that wraps them in the existing
`_apply_selection_edit` path, so undo, overlap cutting and engine sync come for free. Generators
add notes, so they extend that path: the edit callable may return new notes to add, which
`NoteEditor` adds to the owning clip before `_history_commit`. `ClipNotesStateCommand` already
snapshots whole note lists, so additions undo correctly.

**Cross-track tools as a plan and a commit.** Transfer Notes and Split Voices touch other tracks'
clips and may create or extend instances. A new `NoteTransfer` class first computes a
*plan* from song-tick notes and a target track: for each run of notes, either an existing instance
(with an optional new start and duration) or a new clip span. It then applies the plan by
building `ClipInstanceCreateCommand`s, `ClipInstanceTransformCommand`s and
`ClipNotesStateCommand`s (for the source and target clips). These are recorded with one
`HistoryUtil.record_many("Transfer Notes", cmds)`, which satisfies REQ-001. Keeping the plan
separate also lets the dialog show the linked-clip warning (REQ-043) before anything changes.

**Key detection** uses the Krumhansl–Kessler major and minor profiles. It builds a
duration-weighted pitch-class histogram, takes the Pearson correlation for each of the 24 keys,
and picks the best one. Confidence comes from the gap between the best and the runner-up
(`High` ≥ 0.10, `Medium` ≥ 0.04, otherwise `Low`; these are tunable constants). The relative
major/minor pair is the classic near-tie, and the margin shows it honestly. The transport and the
key change popup share `ScalePicker`, so Detect is added to `ScalePicker` once, as an optional
row driven by a `detect_source: Callable` that the owner sets. The transport's source is "before
the first key change". `KeyChangeTrack`'s source is "this change up to the next one". Accepting
the result goes through the picker's existing `scale_picked` path, so the undo and engine sync
that already exist for scale edits are reused.

**Rejected alternatives:**
- *Generators as a new note effect on the engine side* (like Transpose, spec 027): that is
  non-destructive, but it is a different feature. These tools write notes the user then edits.
- *A note context menu*: right-click erases (requirements, REQ-005).
- *One combined "Harmony" dialog with tabs*: each tool has unrelated options, and separate dialogs
  match Quantize and Strum.

### Algorithms (the parts that need to be pinned down)

- **Voices (REQ-020).** Per clip, `NoteTransforms.group_by_start(notes, STRUM_TOLERANCE_TICKS)`.
  Inside each group, sort by pitch descending: index 0 is voice 1, and the last one is Bottom.
  Notes are always grouped *per clip*, because ticks are clip ticks (the same lesson as strum).
- **Inversion (REQ-021).** Per chord: Up does `lowest += 12` while `lowest <= highest_other`.
  Down mirrors that. The chord is skipped if the result leaves 0–127. Two notes of equal pitch:
  the moved note must end strictly above or below.
- **Diatonic chord (REQ-033).** Let `pcs` be the scale at the chord's song tick, as an ascending
  list of n pitch classes from the root. Degree `d` gives the tones `pcs[(d + 2k) mod n]` for
  `k = 0..2` (or `0..3` with `7`). For n ≠ 7 (pentatonic, octatonic) the same rule applies with
  degrees taken mod n. The dialog shows "Chords follow this n-note scale" so the result isn't a
  surprise.
- **Voicing (REQ-034).** *Close*: the stacked tones placed ascending, starting at the lowest
  pitch ≥ `range.lo` for the chosen inversion's bass tone. *Spread*: the same tones as Close, with
  the middle tone of a triad (or the 2nd and 4th of a 7th chord) moved up an octave. *Root*: the
  bass tone is the degree's root. *Smooth*: for chord i > 0, every inversion is tried as Close
  inside the range. The one with the smallest sum of |Δpitch| is picked, comparing sorted voices
  and padding with the nearest note when the chord sizes differ. If notes still fall outside the
  range, they are moved by octaves into it and the run is flagged (REQ-034 notice).
- **Chord fill (REQ-032).** With a range: `count = ceil((end - start) / length)`, and the last
  chord is cut at `end`. Without a range: `count` from the dialog, starting at `get_paste_tick()`.
  The degree for step `i` is `progression[i mod size]`.
- **Root detection (REQ-036).** Templates (intervals above the root): maj `0 4 7`, min `0 3 7`,
  dim `0 3 6`, aug `0 4 8`, maj7 `0 4 7 11`, 7 `0 4 7 10`, m7 `0 3 7 10`, m7b5 `0 3 6 10`, dim7
  `0 3 6 9`. Each of the chord's pitch classes is tried as a root, and the candidate is scored by
  template coverage: all template tones present, extra tones not allowed, except that a template
  missing its fifth still matches. The tie-break prefers the root equal to the lowest sounding
  note's pitch class. With no match, the root is the lowest note. C6 (`C E G A`) matches Am7 with
  root A and nothing with root C, so to meet REQ-036's example, the "prefer lowest" tie-break also
  applies when the bass tone is a template tone of a 4-note match: a chord whose bass pc forms a
  full triad with two other tones reports the bass as root. This rule is in the unit tests
  explicitly.
- **Bassline (REQ-035).** Chords are groups of two or more notes. The span runs to the next
  group's start, and the last group's span is its longest note. The bass pitch is the root pc
  placed at the lowest octave inside the bass range. Pulse and Root–Fifth step by
  `grid_helper.snap_ticks` units (the current grid value). The fifth is the scale's 5th step above
  the root when it is in scale, otherwise +7 semitones, folded into the range.
- **Harmonize (REQ-030/031).** Intervals are scale-step counts: 3rd = ±2, 4th = ±3, 5th = ±4,
  6th = ±5, octave = ±7 (for n-note scales, an octave is ±n). Copy pitch =
  `NoteTransforms.step_in_scale(pitch, steps, pcs_at_note)`. A copy is skipped when a note of
  the same clip, start and pitch exists or was already generated.
- **Transfer plan (REQ-040).** Song-tick notes are sorted. A *run* is a maximal set of notes
  whose bar spans `[bar_floor(start), bar_ceil(end))` touch or overlap. For each run, the
  overlapping target instances are found, earliest first. The earliest instance takes every run
  note that starts inside its new span. That span extends start and/or end, bar-aligned, to cover
  those notes, unless the instance is *looped* (`get_loop_state()[0]`). A looped instance is
  never extended: notes inside its span are folded with `fold_into_loop`, and the others move on.
  The remaining notes repeat the step with the next overlapping instance, and finally become a new
  clip spanning their bars. Extending an instance's start earlier also shifts `clip_offset`, and
  `content_length_ticks` grows, so existing notes keep their song position.
- **Split Voices (REQ-041).** Targets are `Editor.selected_tracks`, sorted by index in
  `project.tracks`, keeping only instrument tracks. The source track keeps its place in that
  order if it is selected. Voice k goes to `targets[k-1]`. A voice whose target is the source
  track, or that has no target, stays. All the per-target plans are applied in one
  `record_many("Split Voices", …)`.

## Thread and ownership

Godot only, on the main thread. Nothing reaches the engine except through the existing
`Clip` / `ClipInstance` / `Project` setters, which already send OSC.

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| Dialog options | Godot main | `Sonara.get_config` / `set_config` (`NoteEditor._config_value` pattern) | n/a |
| Notes, instances and key changes changed by tools | Godot main | existing model setters, which sync to the engine | unchanged |

## Data and protocol changes

- **OSC:** none.
- **`.sonara`:** none. New notes, clips and instance spans use existing fields.
- **`config.json`:** new `clip_editor/*` keys, read with defaults so a missing key means default:
  - `harmonize_intervals` (Array of ints, default `[2]`) and `harmonize_velocity_offset`
    (float, `0.0`)
  - `chords_progression` (String, `"I V vi IV"`), `chords_length_ticks` (int, 3840 = 1 bar of
    4/4), `chords_count` (int, 4), `chords_range` (Vector2i stored as `[48, 72]`, which is C2–C4),
    `chords_voicing` (`"close"`), `chords_inversion` (`"root"`), `chords_seventh_default` (bool,
    false)
  - `bassline_pattern` (`"sustained"`) and `bassline_range` (`[36, 48]`, which is C1–C2)
  - `transfer_last_target` (track id, used only when that track still exists)
- **Hotkeys** (new `ACTIONS` rows, context `clip_editor`, group "Clip Editor"):
  - `notes_invert_up` (`Ctrl+Shift+Up`) and `notes_invert_down` (`Ctrl+Shift+Down`). Neither
    chord is used in `HotkeyActions.gd` today, and `test_hotkeys_registry.gd` checks for conflicts.
  - `notes_select_voice_top`, `notes_select_voice_bottom`, `notes_harmonize`,
    `notes_insert_chords`, `notes_insert_bassline`, `notes_transfer` and `notes_split_voices`, all
    unbound by default.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/clip_editor/harmony/NoteVoices.gd` (new) | `class_name NoteVoices`: `ranks(notes) -> Dictionary` (note → `Vector2i(from_top, from_bottom)`), `select(notes, which: int) -> Array[MidiNoteData]` (which: `TOP=-1`, `BOTTOM=-2`, `1..n`), `invert(notes, up: bool) -> int` (changed count). Per-clip grouping is the caller's job: callers pass one clip's notes at a time |
| `Godot/clip_editor/harmony/KeyDetector.gd` (new) | `class_name KeyDetector`: profiles, `histogram(notes, weights_by_duration := true) -> PackedFloat32Array`, `detect(hist) -> Dictionary` `{ok, root, type_id, confidence: "High"/"Medium"/"Low", reason}`, `MIN_NOTES := 4`, `MIN_PCS := 3`. Also `collect(project, from_tick, to_tick) -> Array` gathers `[pitch, song_duration]` from every track whose channel isn't `NoteMapResolver.wants_drum_view`, and skips muted instances |
| `Godot/clip_editor/harmony/ChordTheory.gd` (new) | `class_name ChordTheory`: `parse_progression(text) -> Dictionary` `{steps: [{degree, seventh}], error: String}`, `PRESETS`, `chord_tones(scale, degree, seventh) -> PackedInt32Array`, `voice(tones, bass_index, range, voicing) -> PackedInt32Array`, `smooth_next(prev, tones, range) -> PackedInt32Array`, `detect_root(pitches) -> int` (pc) |
| `Godot/clip_editor/harmony/HarmonyGenerators.gd` (new) | `class_name HarmonyGenerators`: `harmonize(notes, steps, scale_at: Callable, vel_offset) -> Array[MidiNoteData]`, `chords(opts, scale_at, start, end_or_count) -> Dictionary` `{notes, clamped: bool}`, `bassline(notes, pattern, range, grid_ticks, scale_at) -> Array[MidiNoteData]`. `scale_at(clip_tick) -> MusicalScale` is supplied by the caller, which maps clip ticks to song ticks |
| `Godot/clip_editor/harmony/NoteTransfer.gd` (new) | `class_name NoteTransfer`: `plan(project, target: Track, song_notes: Array) -> Array` (one entry per run: instance or null, new start/duration, notes), `linked_targets(project, plan) -> Array[Clip]`, `apply(project, source_moves: Dictionary, plans: Array, label: String)`, which builds and records the commands as one step |
| `Godot/clip_editor/harmony/HarmonizeDialog.gd`, `InsertChordsDialog.gd`, `InsertBasslineDialog.gd`, `TransferNotesDialog.gd` (new) | `extends ConfirmationDialog`, built in code like `value_lanes/NoteValueTransformDialog.gd`. They load and save their `clip_editor/*` keys on OK. Insert Chords: a progression `LineEdit` with a parse error label, a preset `OptionButton`, a length `OptionButton` (1/16 … 2 bars), Count (shown only without a range), an `HDualSlider` for the range with a note-name readout, and Voicing/Inversion `OptionButton`s. Transfer: a target `OptionButton` and a linked-clip warning label |
| `Godot/clip_editor/note_editor/NoteEditor.gd` | `_apply_selection_edit`: the edit callable may return an `Array[MidiNoteData]` of notes to add. Each is added to its owning clip (a per-note clip map like strum's) before `_sync_edited_notes`, and the new notes join the selection for generators that select their output. New public methods: `select_voice(which)`, `invert_selection(up)`, `harmonize_selection()`, `insert_chords()`, `insert_bassline()`, `transfer_selection(target: Track)`, `split_voices()`. Also `_scale_at_clip_tick(clip, tick)` via `_instance_for_visual_note` → `clip_to_song_ticks` → `Project.get_scale_at_tick`. New config keys sit next to `STRUM_*_KEY` |
| `Godot/clip_editor/note_editor/NoteEditor.gd` (hotkeys) | In `handle_key_input`, next to `notes_strum`: `Hotkeys.pressed(event, "<id>")` branches for the nine new ids. The dialog ones ask `ClipEditor` to open their dialog through a new `harmony_dialog_requested(tool: StringName)` signal |
| `Godot/clip_editor/ClipEditor.gd` | In `_setup_selection_tools`: register `InvertUp` and `InvertDown` (not drum, no scale), and build the `Harmony` `MenuButton` popup (a Select Voices submenu with Top, Bottom, Voice 2–6, then Harmonize…, Insert Chords…, Insert Bassline…, a separator, Transfer Notes…, Split Voices). Extend `_sync_selection_tools` to enable each popup item with the same rules, plus REQ-042 (`Editor.selected_tracks` has a non-source instrument track) and the tooltips for REQ-002 and REQ-042. Insert Chords is enabled with no selection when a range or cursor exists |
| `Godot/clip_editor/ClipEditor.tscn` | Add `InvertUp`, `InvertDown` (`Button`) and `Harmony` (`MenuButton`) under `BottomPanel/Toolbar/ToolsGroup`, after `ConformToScale` |
| `Godot/input/HotkeyActions.gd` | The nine `ACTIONS` rows above |
| `Godot/editor/ScalePicker.gd` | `var detect_source: Callable` (unset means no Detect row). When it is set, add a Detect `Button`, then a result `Label` plus Use `Button` row. Use calls `set_scale_display` and emits `scale_picked`. "Not enough notes" is shown in the label with Use disabled |
| `Godot/editor/Editor.gd` | Set `scale_picker.detect_source` to a callable that runs `KeyDetector.collect(project, 0, first key change tick or song end)` and then `detect` |
| `Godot/arranger/ruler/KeyChangeTrack.gd` | In `open_dropdown`, set `_picker.detect_source` for the target change: the span from its tick to the next change (or the song end). For change 0 (the start key), the span runs up to the first change |
| `CHANGELOG.md` | One line under `[Unreleased]` per user-visible tool group |
| `docs/subsystems/godot-architecture.md` | A short "Harmony tools" paragraph in the clip/MIDI editor section, pointing at `clip_editor/harmony/` |

## Migration and compatibility

Nothing persisted changes shape. Older configs have no `clip_editor/*` harmony keys, so the
defaults apply. Projects are untouched. Undo history isn't persisted.

## Test plan

All headless, run as `godot --headless --path Godot -s tests/<script>.gd -- --test`, or through
`Godot/tests/run_all.sh harmony voices key_detect transfer`.

- **`tests/test_note_voices.gd`** (REQ-020, 021): the REQ-020 chord pair for every choice. The
  REQ-021 sequence, Up then Down restoring the notes, the 0–127 edge, and one-note chords left
  alone.
- **`tests/test_key_detect.gd`** (REQ-010–012): C-major and A-minor material over all 12
  transpositions, the threshold cases, and duration weighting. `collect` skips drum-view channels
  and respects the span.
- **`tests/test_chord_theory.gd`** (REQ-033, 034, 036): the parser (valid, invalid token,
  separators, case), diatonic chords in Major, Natural Minor and Harmonic Minor (`V7` in A minor
  is E G B D), range containment for every voicing and inversion, Smooth moving less than Root,
  and root detection for each quality and inversion plus C6.
- **`tests/test_harmony_generators.gd`** (REQ-003, 030–032, 035): the harmonize examples and
  C#3 → F3, chords filling 4 and 6 bars, the key-change example, and the three bassline patterns.
- **`tests/test_harmony_tools_editor.gd`** (REQ-001, 002, 004, 005, 022): builds a ClipEditor like
  the existing selection-tool tests and checks:
  - each tool adds exactly one history entry, and undo restores the snapshot;
  - the scale-gated tools are disabled with no scale;
  - options persist across reopening a dialog;
  - the menu items and their order;
  - the hotkey rows exist and dispatch.
- **`tests/test_note_transfer.gd`** (REQ-040–043): the covered, extended, new-clip and
  two-overlapping-clips cases, a looped target, Split Voices with the REQ-041 example, the
  disabled state, and the linked-clip warning with both instances updated. One undo restores
  everything.
- **`tests/test_hotkeys_registry.gd`** (existing): must stay green, which proves there are no
  chord conflicts.
- **Performance (non-functional):** `test_harmony_generators.gd` times harmonize, chords and
  inversion on 2,000 notes with `Time.get_ticks_usec` and asserts each is under 100 ms.
- **Live** (only checkable by ear and eye): run the app and the engine, play a progression made
  with Insert Chords, and check that Smooth sounds connected. Detect on an imported MIDI file of
  a known key. Transfer into a clip on a track with a different instrument, and listen that the
  notes play from it.

## Risks

| Risk | Mitigation |
|---|---|
| Key detection mislabels relative major/minor | Show the confidence, never auto-apply, and keep thresholds as constants to tune against real files |
| Extending a clip's start shifts other notes | Adjust `clip_offset` and content origin together, and test that existing notes keep their song ticks |
| Linked or looped targets give surprising results | The plan computes the effects first, the dialog warns, and looped instances are never extended (tested) |
| `_apply_selection_edit` change breaks existing tools | Additions are opt-in (a `null` return keeps today's path), and the existing strum, quantize and flip tests must stay green |
| Non-heptatonic scales give odd chords | A defined rule (degrees mod n, every other step) plus a dialog notice |

## Open questions

- [x] C6 versus Am7 (REQ-036): decided to favour the bass. When the bass pitch class forms a full
  triad with two other chord tones, the bass is reported as the root, so C E G A reads as C.
