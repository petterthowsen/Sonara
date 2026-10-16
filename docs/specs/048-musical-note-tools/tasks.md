# Musical Note Tools — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Test commands use the AGENTS.md forms: `Godot/tests/run_all.sh <words>` or
`godot --headless --path Godot -s tests/<script>.gd -- --test`.

## Phase 1 — Pure music logic (no UI)

- [x] **T-001** [REQ-020, REQ-021] `NoteVoices`: `ranks`, `select`, `invert`.
  - _Files_: `Godot/clip_editor/harmony/NoteVoices.gd`, `Godot/tests/test_note_voices.gd`
  - _Output_: voice ranks per chord (via `NoteTransforms.group_by_start`) and inversion up/down
    with the 0–127 guard
  - _Verify_: `Godot/tests/run_all.sh note_voices` passes. It covers the REQ-020 chord pair for
    Top, Bottom, Voice 2 and Voice 4, the REQ-021 sequence C3–E3–G3 → Up → Up → Down, Up then Down
    restoring the notes, one-note chords and the range edge
  - _Depends on_: —

- [x] **T-002** [REQ-012] `KeyDetector.histogram` and `detect`.
  - _Files_: `Godot/clip_editor/harmony/KeyDetector.gd`, `Godot/tests/test_key_detect.gd`
  - _Output_: a duration-weighted histogram, Krumhansl–Kessler correlation over 24 keys, a result
    dict with confidence, and the "Not enough notes" thresholds
  - _Verify_: `Godot/tests/run_all.sh key_detect` passes. C-major and A-minor material is detected
    correctly at all 12 transpositions, the below-threshold cases return `ok == false`, and a long
    tonic outweighs short passing notes
  - _Depends on_: —

- [x] **T-003** [REQ-010, REQ-011] `KeyDetector.collect(project, from_tick, to_tick)`.
  - _Files_: `Godot/clip_editor/harmony/KeyDetector.gd`, `Godot/tests/test_key_detect.gd`
  - _Output_: `[pitch, duration]` pairs from the non-drum, unmuted instances in the span, in song
    ticks
  - _Verify_: test cases where a drum-view channel's notes are excluded, a muted instance is
    excluded, and notes outside the span are excluded
  - _Depends on_: T-002

- [x] **T-004** [REQ-033] `ChordTheory.parse_progression`, `PRESETS` and `chord_tones`.
  - _Files_: `Godot/clip_editor/harmony/ChordTheory.gd`, `Godot/tests/test_chord_theory.gd`
  - _Output_: a Roman numeral parser (case-insensitive, optional `7`, space or dash separators)
    that reports the bad token, and diatonic chord tones by stacking every other scale note
    (degrees taken mod n for scales that don't have 7 notes)
  - _Verify_: `Godot/tests/run_all.sh chord_theory` passes. Valid, invalid, mixed case and
    separators parse as expected. `ii` in C Major is D F A. `V7` in A Natural Minor is E G B D.
    Harmonic Minor `V` is E G# B. A pentatonic case follows the mod-n rule
  - _Depends on_: —

- [x] **T-005** [REQ-034] `ChordTheory.voice` and `smooth_next`.
  - _Files_: `Godot/clip_editor/harmony/ChordTheory.gd`, `Godot/tests/test_chord_theory.gd`
  - _Output_: Close and Spread voicing inside a range, the inversion with the least movement, and
    folding notes by octaves when a chord can't fit, with a `clamped` flag
  - _Verify_: every note stays in range for every combination of voicing, inversion and range.
    `I IV V I` in C Major moves less in total with Smooth than with Root. A range that's too narrow
    sets `clamped`
  - _Depends on_: T-004

- [x] **T-006** [REQ-036] `ChordTheory.detect_root`.
  - _Files_: `Godot/clip_editor/harmony/ChordTheory.gd`, `Godot/tests/test_chord_theory.gd`
  - _Output_: template matching with the bass-favouring tie-break (the decision in design.md)
  - _Verify_: every quality (maj, min, dim, aug, maj7, 7, m7, m7b5, dim7) in root position and every
    inversion returns the right root. E3–G3–C4 → C. C3–E3–G3–A3 → C. An unmatched cluster returns
    the lowest note
  - _Depends on_: T-004

- [x] **T-007** [REQ-003, REQ-030, REQ-031, REQ-032, REQ-035] `HarmonyGenerators`: `harmonize`,
  `chords` and `bassline`.
  - _Files_: `Godot/clip_editor/harmony/HarmonyGenerators.gd`,
    `Godot/tests/test_harmony_generators.gd`
  - _Output_: new-note arrays built through a caller-supplied `scale_at` callable
  - _Verify_: `Godot/tests/run_all.sh harmony_generators` passes. It covers:
    - C D E harmonized a 3rd above gives E F G, and a 6th below gives E2 F2 G2. Two intervals at
      once work, and C#3 a 3rd above gives F3. Duplicates are skipped.
    - `I V vi IV` over 4 bars, and repeated over 6 bars.
    - The REQ-003 key change example.
    - Sustained, Pulse and Root–Fifth on the REQ-035 example.
  - _Depends on_: T-005, T-006

- [x] **T-008** [non-functional] Performance check on 2,000 notes.
  - _Files_: `Godot/tests/test_harmony_generators.gd`
  - _Output_: timing asserts for harmonize, chords, inversion and voice selection
  - _Verify_: each one runs in under 100 ms in the headless test
  - _Depends on_: T-001, T-007

- [x] **T-009** [REQ-040] `NoteTransfer.plan`.
  - _Files_: `Godot/clip_editor/harmony/NoteTransfer.gd`, `Godot/tests/test_note_transfer.gd`
  - _Output_: the run grouping, earliest-overlapping-instance assignment, bar-aligned extension,
    a looped instance folding without being extended, and new clip spans
  - _Verify_: plan-only tests for the covered, extended (bars 3–5 into a bars 1–4 clip),
    new-clip (a note on bar 9 with no stretch), two-overlapping-clips and looped-target cases
  - _Depends on_: —

## Phase 2 — Wire into the note editor (one undo step each)

- [x] **T-010** [REQ-001] Let `_apply_selection_edit` add notes.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`
  - _Output_: the edit callable may return `Array[MidiNoteData]`. Those notes are added to their
    owning clip before the sync and commit. A `null` return keeps today's path
  - _Verify_: `Godot/tests/run_all.sh strum quantize flip scale_snap` stays green, and a new case
    in `test_harmony_tools_editor.gd` checks that an edit adding notes is undone by one undo
  - _Depends on_: —

- [x] **T-011** [REQ-020, REQ-021, REQ-001] `select_voice(which)` and `invert_selection(up)` on
  `NoteEditor`.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`,
    `Godot/tests/test_harmony_tools_editor.gd`
  - _Output_: voices per clip (the `clip_of` map pattern from strum). Select Voices replaces the
    selection and falls back to all notes when nothing is selected. Inversion is one undo step
  - _Verify_: editor-level tests: the history grows by one per inversion, undo restores the notes,
    and Select Voices with no selection picks from all of the clip's notes
  - _Depends on_: T-001, T-010

- [x] **T-012** [REQ-003, REQ-030, REQ-032, REQ-035] `harmonize_selection`, `insert_chords` and
  `insert_bassline` on `NoteEditor`.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`,
    `Godot/tests/test_harmony_tools_editor.gd`
  - _Output_: `_scale_at_clip_tick`, which maps clip ticks to song ticks and then to
    `Project.get_scale_at_tick`. Insert Chords uses the selection range, or `get_paste_tick()` plus
    a count. Each method records one undo step
  - _Verify_: editor-level tests: one history entry per run with undo restoring the snapshot, the
    key-change example through the editor, and chords landing at the paste tick when there's no
    range
  - _Depends on_: T-007, T-010

- [x] **T-013** [REQ-040, REQ-043, REQ-001] `NoteTransfer.apply`, `linked_targets` and
  `NoteEditor.transfer_selection(target)`.
  - _Files_: `Godot/clip_editor/harmony/NoteTransfer.gd`,
    `Godot/clip_editor/note_editor/NoteEditor.gd`, `Godot/tests/test_note_transfer.gd`
  - _Output_: one `HistoryUtil.record_many("Transfer Notes", …)` made of create, transform and
    notes-state commands. Extending a clip's start earlier shifts `clip_offset` and the content
    length
  - _Verify_: after the transfer, every case has notes at the same song ticks on the target and
    none left on the source. One undo restores both tracks and all instance spans. A linked target
    is reported by `linked_targets`, and both of its instances show the notes. Existing notes in an
    extended clip keep their song ticks
  - _Depends on_: T-009

- [x] **T-014** [REQ-041, REQ-042] `NoteEditor.split_voices()`.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`, `Godot/tests/test_note_transfer.gd`
  - _Output_: targets are `Editor.selected_tracks` in project track order, instrument tracks only,
    with the source track keeping its place. Voice k goes to target k, and the rest stays. One
    undo step
  - _Verify_: the REQ-041 example (4 voices; the source plus 2 tracks selected) puts voices 1 and
    4 on the source and voices 2 and 3 on the targets. One undo restores everything. The "no
    targets" predicate is false with only the source selected
  - _Depends on_: T-001, T-013

## Phase 3 — UI: toolbar, dialogs, hotkeys, Detect

- [x] **T-015** [REQ-005, REQ-002, REQ-042] Toolbar: `InvertUp`, `InvertDown` and the `Harmony`
  menu button.
  - _Files_: `Godot/clip_editor/ClipEditor.tscn`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: the buttons registered through `_register_selection_tool`. The Harmony popup has
    the Select Voices submenu (Top, Bottom, Voice 2–6), Harmonize…, Insert Chords…, Insert
    Bassline…, a separator, Transfer Notes… and Split Voices. `_sync_selection_tools` enables the
    items, including the no-scale and no-target tooltips, and disables everything in Drum View
  - _Verify_: `test_harmony_tools_editor.gd` checks the item order, that the three generators are
    disabled with no scale and enabled with C Major, that Split Voices is disabled without targets,
    and that everything is disabled in Drum View
  - _Depends on_: T-011, T-012, T-014

- [x] **T-016** [REQ-030, REQ-004] `HarmonizeDialog`.
  - _Files_: `Godot/clip_editor/harmony/HarmonizeDialog.gd`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: interval checkboxes (3rd, 4th, 5th, 6th and octave, each above or below) and a
    velocity offset, stored in the `clip_editor/harmonize_*` config keys
  - _Verify_: test: confirm with non-default options, reopen, and the values are read back. OK
    runs `harmonize_selection`
  - _Depends on_: T-015

- [x] **T-017** [REQ-032, REQ-033, REQ-034, REQ-004] `InsertChordsDialog`.
  - _Files_: `Godot/clip_editor/harmony/InsertChordsDialog.gd`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: a progression field with the parse error and OK disabled on error, presets, length,
    a Count field (hidden when there is a range), an `HDualSlider` range with note names,
    voicing and inversion, and the clamp notice after inserting. The dialog also shows the
    non-heptatonic notice
  - _Verify_: test: an invalid token disables OK and names the token. Options persist across
    reopening. The Count field is hidden when a range exists
  - _Depends on_: T-015

- [x] **T-018** [REQ-035, REQ-004] `InsertBasslineDialog`.
  - _Files_: `Godot/clip_editor/harmony/InsertBasslineDialog.gd`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: a pattern choice and a bass range `HDualSlider`, which persist
  - _Verify_: test: options persist, and OK runs `insert_bassline`
  - _Depends on_: T-015

- [x] **T-019** [REQ-040, REQ-043, REQ-004] `TransferNotesDialog`.
  - _Files_: `Godot/clip_editor/harmony/TransferNotesDialog.gd`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: a target dropdown with the other instrument tracks. The default is the selected track
    if it isn't the source, otherwise the last target. The linked-clip warning label is driven by
    `NoteTransfer.linked_targets`
  - _Verify_: test: the default target rule works, the warning shows for a linked target, and OK
    transfers the notes
  - _Depends on_: T-013, T-015

- [x] **T-020** [REQ-022, REQ-005] Hotkey actions.
  - _Files_: `Godot/input/HotkeyActions.gd`, `Godot/clip_editor/note_editor/NoteEditor.gd`,
    `Godot/clip_editor/ClipEditor.gd`
  - _Output_: nine `ACTIONS` rows (`notes_invert_up` is Ctrl+Shift+Up and `notes_invert_down` is
    Ctrl+Shift+Down; the rest are unbound), `handle_key_input` branches, and a
    `harmony_dialog_requested` signal that opens the dialogs
  - _Verify_: `Godot/tests/run_all.sh hotkeys` stays green (no conflicts), and
    `test_harmony_tools_editor.gd` checks that the invert hotkeys trigger the tool and that every
    menu item has a registered action
  - _Depends on_: T-015, T-016, T-017, T-018, T-019

- [x] **T-021** [REQ-010, REQ-011] Detect in `ScalePicker`, wired for the transport and key
  changes.
  - _Files_: `Godot/editor/ScalePicker.gd`, `Godot/editor/Editor.gd`,
    `Godot/arranger/ruler/KeyChangeTrack.gd`, `Godot/tests/test_key_detect.gd`
  - _Output_: a `detect_source` callable, a Detect button, and a result label plus Use button.
    The transport span runs up to the first key change. A key change's span runs up to the next
    change, and the start key (id 0) spans up to the first change. Use goes through
    `scale_picked`
  - _Verify_: test: Detect alone doesn't change the project scale. Use sets it and is undoable.
    With two key changes over C-major and E-minor material, detecting on the second change proposes
    E Natural Minor. "Not enough notes" disables Use
  - _Depends on_: T-003

## Phase 4 — Docs

- [x] **T-022** [REQ-all] Changelog and architecture note.
  - _Files_: `CHANGELOG.md`, `docs/subsystems/godot-architecture.md`
  - _Output_: lines under `[Unreleased]` for key detection, chord inversion, Select Voices,
    Harmonize, Insert Chords, Insert Bassline, Transfer Notes and Split Voices, plus a "Harmony
    tools" paragraph pointing at `clip_editor/harmony/`
  - _Verify_: both files mention every tool. No OSC doc change is needed (no new messages)
  - _Depends on_: T-020, T-021

## Phase 5 — Full run and live verification

- [x] **T-023** [REQ-all] Full Godot test suite.
  - _Files_: —
  - _Output_: a green run
  - _Verify_: `Godot/tests/run_all.sh` reports 0 failures
  - _Depends on_: T-022

- [x] **T-024** [REQ-all] Live check with the engine and Godot running (by the user, or with their
  OK; the engine may already hold port 7000).
  - _Files_: —
  - _Output_: a comment on the tracking issue saying what was and wasn't checked
  - _Verify_: these steps, all of which must play correctly:
    1. Insert Chords `I V vi IV` with Smooth on a piano track: it plays the four chords and the
       voice leading sounds connected.
    2. Invert Up and Down with the hotkeys.
    3. Harmonize a melody a 3rd above: the result stays in key.
    4. Insert Bassline (Root–Fifth): it plays under the chords.
    5. Detect on an imported MIDI file of a known key gives the right key.
    6. Transfer Notes to a track with another instrument: the notes play from that instrument and
       the target clip is extended or created as specified.
    7. Split Voices across three selected tracks.
    8. Ctrl+Z after each step restores the previous state.
  - _Depends on_: T-023
