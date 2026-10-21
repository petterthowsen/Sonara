# Multi-track note editing

Plan for letting the clip editor select and edit notes on several tracks at once in track mode:
box select across tracks, then move, resize, change velocity (and the other note values), delete,
nudge and run the selection tools on all of them as one undo step.

This plan comes from reading the code at `8b6d17e`. Nothing has been measured yet.

## Checklist

- [x] Phase 1: Data-level selection (`NoteRef`, `NoteSelectionModel`), with no change in behaviour
- [ ] Phase 2: Edits run on refs (`NoteEdits`), not on `VisualNote`s
- [ ] Phase 3: Selecting across tracks (click, Ctrl+click, box, ruler range, Ctrl+A), drawn on the context layer
- [ ] Phase 4: Gestures across tracks (drag, resize, velocity drag, keyboard edits)
- [ ] Phase 5: Value lanes, clipboard, tools and group scale across tracks
- [ ] Phase 6 (optional): `clip-editor-performance-plan.md` Phase 3, draw the focus track too and retire `VisualNote`

Each phase ships on its own. After each one, run `Godot/tests/run_all.sh` and the
`bench_clip_editor.gd` benchmark, and update the Clip Editor section of
`docs/subsystems/godot-architecture.md` in the same change.

## Why it is limited today

Track mode has **one** `NoteEditor`. It is bound to `MidiEditor.current_track` and holds a
`VisualNote` per note of that track. Every other visible track is drawn by `ContextNotesLayer`, one
`_draw()` with no nodes. That split is deliberate: it is Phase 2 of
`docs/clip-editor-performance-plan.md`, and it took binding 100 tracks from 8.9 s to 144 ms.

The limit comes from where the selection lives:

- `NoteSelectionManager.selected_notes` is an `Array[VisualNote]`, owned by the editor. Notes on
  other tracks have no `VisualNote`, so they can't be put in it.
- Every edit path reads that array: drag, resize and velocity drag (`_on_drag_updated` and
  `drag_start_positions`), the key edits in `handle_key_input`, `_apply_selection_edit` (every
  selection tool and harmony tool), `_history_begin_selection`, `capture_selection_state` and
  `SelectionStateCommand` (which holds the `NoteEditor` itself).
- `MidiEditor.value_stems()` builds the value lane stems from the editor's `VisualNote`s, so other
  tracks' notes get no stems.
- Switching `current_track` rebinds the editor, which drops the note selection. Only the time range
  is carried over (`apply_selection_range_song`).
- Spec 007 made this a rule: REQ-038 keeps box select, Ctrl+A, copy, paste, delete and the arrow
  keys on the selected track, and its "Out of scope" list names "box select, Ctrl+A or copy across
  several tracks at once". This plan replaces REQ-038 and drops that line.

The edit code itself is mostly ready for several tracks. Track mode already handles notes from many
clips with different origins, each `VisualNote` carries its `clip_instance`,
`ClipNotesStateCommand.capture_many` / `commit_many` snapshot any set of clips, and the value lanes
edit `{note_data, clip}` pairs. What is missing is a selection that isn't made of nodes.

## Options

**A. One `NoteEditor` per editable track.** This was the pre-Phase-2 design. Every existing edit
path would work across tracks with a thin coordinator, but the node count would come back: making
100 tracks editable would cost seconds to bind and hundreds of ms per scroll step again. Rejected.

**B. "Guest" `VisualNote`s.** The focus editor would build visuals for selected notes on other
tracks, so the existing `Array[VisualNote]` code keeps working. But `NoteContainer` assumes one
track (`track`, `clip_instances`, `get_or_create_clip_at_position`, the clip signal wiring, loop
repeats, `_on_instance_modified`). Guests would also have to appear and disappear with the selection,
including on undo and redo, and the context layer would have to skip them. That adds lifecycle
bookkeeping on top of a 2,600-line file. Rejected.

**C. Selection and edits on data (recommended).** The selection becomes a set of note references,
`(ClipInstance, MidiNoteData)`, owned by `MidiEditor` for the whole view. Edits take refs and
mutate `MidiNoteData`. `VisualNote` and `ContextNotesLayer` only display, both reading "is
selected" from the model. Node cost stays tied to the focus track, any editable track can join a
selection, and track switches no longer touch the selection. It is also the groundwork for the
performance plan's Phase 3, which retires `VisualNote` altogether.

## Design

### Terms

- **Focus track** is what `current_track` / "the selected track" is today. It is the track that
  gets placed and pasted notes, whose note map labels the keys, whose channel previews and drives
  the held keys, and which has `VisualNote`s. Rename `current_track` to `focus_track` in code and
  use "focus track" in docs and tests, so it stops sounding like it has anything to do with the
  note selection.
- **Editable** (the pencil toggle) now also means "can join the note selection". Hidden or
  view-only tracks still ignore the mouse (REQ-039 stands).
- **Note selection** is any set of notes on editable tracks, plus a time range.

### `NoteRef` (`clip_editor/note_editor/NoteRef.gd`)

A small `RefCounted` with `instance: ClipInstance`, `data: MidiNoteData` and `pass: int` (the loop
pass the user grabbed it through, 0 = the note itself), plus `clip`, `track`, `song_start()` and
`song_end()` derived from them.

- **Identity is the `MidiNoteData`.** Linked instances and loop repeats share it, so the model
  stores each note once (keyed by data) and keeps the `instance` it was selected through for song
  positioning. This replaces `_selected_note_visuals()`.
- `drag_start_positions` and `resize_start_durations` are keyed by `note_id` today. Key snapshots by
  `MidiNoteData` instead, because a shared clip shows the same ids on several instances.

### `NoteSelectionModel` (`clip_editor/note_editor/NoteSelectionModel.gd`)

One per `MidiEditor`, replacing the selection half of `NoteSelectionManager`:

- `refs` (ordered, unique by data), `range: Vector2i` in **editor ticks** (song ticks in track mode,
  clip-content ticks in clip mode, as now), `has(data)`, `is_empty()`, `tracks()` (the distinct
  tracks), `clips()` (the distinct clips, for snapshots).
- `select(refs)`, `add(refs)`, `toggle(ref)`, `remove_data(data)`, `clear()`, `set_range()`.
- Signals: `changed` (set or range) and `set_changed` (set only). Today's `selection_changed` /
  `selection_set_changed` pair maps onto these.
- `capture()` / `restore(state)`, moved here from `NoteEditor`. The state is
  `{range, notes: [[ClipInstance, MidiNoteData], ...]}`. `SelectionStateCommand` points at the
  model, not at a `NoteEditor`, so undo restores selections on any track, even after a focus
  switch.
- It forgets a note when that note's clip emits `midi_note_removed`, or when its track stops
  being editable. Today `_forget_visual` does this.

`NoteSelectionManager` keeps the box geometry (`box_selection_rect`, snapping) and the static
clipboard, and loses `selected_notes` / `selected_note`. Since the range is no longer per editor,
`get_selection_range_song` / `apply_selection_range_song` and the carry-over in the `current_track`
setter go away in track mode.

### Queries on data

Hit-testing, box select and "all notes" all run over the editable tracks. `ContextNotesLayer`
already does this from its per-clip sorted index (`note_at`). Pull that index and the queries out
into `NoteQuery` (or keep them in the layer, but make them cover the focus track too), so there is
one code path:

- `note_at(pos) -> NoteRef` keeps REQ-035's priority (focus track first, then list order). The
  focus track can still answer from its `VisualNote`s for the resize-edge and hover-cursor logic
  in `NoteEditor.update_hover_cursor`.
- `notes_in_rect(rect, tracks) -> Array[NoteRef]` for box select, culled through the index the same
  way drawing is. It must apply the same played-window and loop-repeat rules as
  `NoteContainer._get_notes_in_box`. `NotePlacement` stays the only place those rules live.
- `notes_in_range(start, end, tracks)` for the ruler's Ctrl+drag, and `notes_of(tracks)` for Ctrl+A
  and row select.

### `NoteEdits` (`clip_editor/note_editor/NoteEdits.gd`)

The shared edit path that the gestures, keys and tools all call, lifted out of `NoteEditor`
(`_history_begin_*`, `_history_commit`, `_apply_selection_edit`, `_refresh_notes`,
`_sync_edited_notes`, `_add_generated_notes`):

1. `begin(name)` snapshots `model.clips()` plus any extra clips, and captures the selection.
2. The caller mutates `ref.data` freely, mid-gesture as now.
3. `refresh()` calls `refresh_note` on the focus editor for refs on the focus track and
   `queue_redraw` on the context layer for the rest. It emits one `notes_refreshed`.
4. `commit()` cuts same-pitch overlaps and calls `update_midi_note` per note (the engine sync),
   then records one `ClipNotesStateCommand` macro with the two `SelectionStateCommand`s.
   `cancel()` restores the snapshot (Esc mid-drag).

This uses a clip's own `allocate_note_id`, so nothing changes about id ownership.

### Drawing

- `VisualNote.selected` is set from `model.has(data)` on `model.set_changed`. Only the focus
  track's visuals are touched, so this is O(focus notes).
- `ContextNotesLayer` draws selected notes in a second pass, straight from `model.refs` (not from
  the index), at full alpha with the selected outline. The first pass skips data that is in the
  model. Mid-gesture, notes move without clip signals, so the sorted index goes stale. Drawing
  the selection from the refs avoids culling them by their old position, and each clip in the
  gesture gets its index marked dirty on `commit`/`cancel`.
- The selection overlays (range band and box rectangle in `_update_selection_overlays`) already
  sit above everything and only need the model's range.

### Gestures

The press, motion and release handling moves from `NoteEditor` (`_on_drag_started` /
`_on_drag_updated` / `_on_drag_ended`, `_on_resize_*`) into a `NoteGestures` helper that
`MidiEditor` owns and that works on `NoteRef`s plus the shared `GridHelper` and `LaneLayout`.
`NoteEditor` keeps placement, Ctrl+drag pending duplicates (until Phase 5) and its visuals.

A left press on a note:

| Press on | Without Ctrl | With Ctrl |
|---|---|---|
| A selected note (any editable track) | Drag the whole selection. The focus does not change, which avoids the rebuild on press (130 ms in the benchmark). | Toggle it out, as now |
| An unselected note on the focus track | Select it alone and drag, as now | Add it and drag |
| An unselected note on another editable track | Switch focus to its track (REQ-034), select it alone and drag | Add it to the selection, keep the focus, drag |

The resize edge of a note on another track is found from its `NotePlacement.note_rect`, so resize
works without a focus switch. Erase is unchanged (REQ-037): it already works on data.

Per-note rules that already exist stay per note: clamping to the instance's played window, folding
into the loop region, and moving between clips on drop (`_handle_cross_clip_transfers`). Moving
between clips only ever happens within the note's own track, because a vertical drag changes pitch
and never the track. `get_or_create_clip_at_position` moves to a track-level static helper, since
it can no longer rely on `NoteContainer.track`.

## Behaviour per operation

| Operation | Across tracks | Notes |
|---|---|---|
| Click, Ctrl+click | Yes | See the gesture table |
| Box select | Every editable track | Shift/Ctrl keeps adding, as now |
| Ruler Ctrl+drag (time range) | Every editable track | |
| Ctrl+A | Focus track | Ctrl+Shift+A selects every editable track (new hotkey `notes_select_all_tracks`) |
| Row/pitch header click | Every editable track | Drum View rows are already the union of the visible tracks' rows |
| Move, transpose, arrows, nudge by length | Yes | Drum View moves by rows of the shared layout. See open question 2 |
| Resize, length keys | Yes | One snapped delta from the grabbed note, as now |
| Velocity drag (Alt), velocity keys | Yes | |
| Value lanes (velocity, other note values) | Yes | Stems for the focus track's notes plus every selected note, coloured by track |
| Delete, cut | Yes | |
| Quantize, flip V/H, strum, conform to scale | Yes | They already group per clip. Flip H mirrors in song ticks over the whole selection |
| Harmonize, invert, select voices | Yes | Chords are grouped per clip, so voices never mix across tracks |
| Transfer notes, split voices | Single source track only | Disabled (with a tooltip) when the selection spans tracks |
| Insert chords, insert bassline | Focus track | They create notes, like placement |
| Group scale handle | Phase 5 | Today it needs one clip. Scale in song ticks about the earliest start, then convert per instance |
| Copy, paste | Phase 5 | See open question 1 |
| Ctrl+drag duplicate | Phase 5 | Pending notes for other tracks are drawn by the context layer |
| Audition while dragging | Grabbed note's track | Previews on that note's channel, not the focus channel |
| Place, paste target | Focus track | Unchanged (REQ-036) |
| Clip mode | Unchanged | The model holds refs of one instance |

## Phases

### Phase 1: Data-level selection

No behaviour change. Add `NoteRef` and `NoteSelectionModel`. `NoteSelectionManager` keeps its API
for now, but stores refs and derives `selected_notes` (the focus editor's visuals for those refs)
so that callers keep compiling. `SelectionStateCommand` holds the model. `MidiEditor`,
`ClipEditor` (`_sync_selection_tools`, `_register_selection_tool`, `_sync_ruler_selection`),
`ValueLaneStemArea` and `VPiano` read the model. The focus switch still clears the selection, which
keeps today's behaviour exactly.

Tests: the existing suite passes unchanged except where tests touch `selected_notes` directly.
There are 27 test files that use `selection_manager`. Move them to the model API in this phase,
not with a shim. Add `test_note_selection_model.gd` (dedup of shared data, forgetting removed notes,
capture and restore across a rebind).

**Outcome.** Done. The suite passes as before (the two failures `test_modulators_ui` and
`test_note_values_preserved` fail on the base commit too); the benchmark is unchanged.
Deviations from the design above:

- `NoteRef.pass` is `pass_index`, because `pass` is a GDScript keyword.
- `NoteSelectionManager` has no `selected_notes` and no signals; it keeps its `VisualNote`-based
  API (`select_all`, `select_visuals`, `select_note`, `toggle_note_selection`) and converts through
  callbacks the editor sets, plus `selected_visuals()` (O(selected)). `box_selection_start_tick` /
  `box_selection_end_tick` forward to the model's `range`. The edit code in `NoteEditor` still works
  on visuals (`_selected_note_visuals()`); Phase 2 ports it to refs.
- The model has a third signal, `restored`, which replaces `NoteEditor.selection_range_restored`.
  Mutators take `silent` to keep today's split between `set_changed` (mid-gesture) and `changed`
  (operation done).
- `capture()` entries are `[instance, data, pass]`, and `restore()` finds notes again **by id** in
  their clip, not by object: undoing a delete re-creates the `MidiNoteData`, so identity alone loses
  the selection.
- Identity by data changes a few visible details. A selected note lights every visual that shows it
  (all loop passes, all linked instances), where it used to light only the visuals that were boxed;
  Ctrl+A on a loop selects each note once (8 visuals became 2 refs); a Ctrl+drag duplicate makes one
  copy per selected note, not one per selected repeat; and when the visual a ref was selected through
  is freed (a loop pass that goes away) the ref moves to another visual of the note, and the note only
  leaves the selection when it has none. Pressing a note's other visual no longer reselects it alone.
- "Forget a note when its track stops being editable" is not done: the focus switch still clears the
  selection, so it can't happen yet. Phase 3 needs it.

### Phase 2: Edits on refs

Add `NoteEdits`. Port `_apply_selection_edit`, the key edits, delete and cut, and the history
helpers onto it. Change `drag_start_positions` and `resize_start_durations` to be keyed by data.
Still single track.

Tests: `test_selection_edit_foundation`, `test_linked_note_nudge`, `test_loop_repeats`,
`test_note_arrow_hotkeys` and the tool tests cover this. Add a case that edits a note of a shared
clip through two instances once.

### Phase 3: Selecting across tracks

Make the focus switch keep the selection. Add the data queries, then box select, the ruler range,
Ctrl+click on a context note, row select and Ctrl+Shift+A over editable tracks. Context notes get
selected drawing. A track that stops being editable or visible drops its notes from the selection.
Key edits and tools now act on every selected note, which already works after Phase 2.

Tests: `test_multi_track_selection.gd`: box select over two editable tracks and one view-only
track, Ctrl+click adds without switching focus, a focus switch keeps the selection, hiding a track
drops its notes, delete across tracks is one undo step, and undo after a focus switch restores the
selection. Re-run the benchmark: binding and scroll must not regress, and a 5,000-note cross-track
selection must scroll without per-frame cost beyond drawing the visible notes.

### Phase 4: Gestures across tracks

Add `NoteGestures` and move drag, resize, velocity drag and their mode switches (Ctrl, Alt,
Shift, Alt auto-axis) out of `NoteEditor`. Press handling follows the gesture table. Context notes
redraw mid-gesture from the refs.

Tests: drag a selection spanning two tracks (each note stays on its track and its clip, and the
loop fold and played-window clamp apply per instance), resize from a context note, Alt velocity
drag across tracks, Esc cancels across tracks, and the drop-transfer between clips of one track
still works with another track in the selection.

### Phase 5: Value lanes, clipboard, tools, group scale, duplicates

- `value_stems()` adds stems for selected notes off the focus track, from `NotePlacement`, in
  their track colour. The stem area already edits `{note_data, clip}`.
- Clipboard and paste (see open question 1).
- Group scale over several clips in song ticks.
- Ctrl+drag duplicate across tracks: pending copies per track, written to each track's clip on
  release.
- `can_transfer` / `can_split_voices` are false for multi-track selections.

### Phase 6 (optional)

If the benchmark shows the focus track's `VisualNote`s are now the cost (dense drum clips), do the
performance plan's Phase 3. After this refactor, `VisualNote` is display-only, so replacing it with
the drawn layer is mostly a rendering change.

## Docs and specs

- Spec 007: mark REQ-038 superseded by this plan, and drop "box select, Ctrl+A or copy across
  several tracks" from Out of scope. REQ-034 still holds for unselected notes, and REQ-035/036/037/039
  are unchanged.
- `docs/subsystems/godot-architecture.md` Clip Editor section: the selection model, focus track,
  `NoteEdits`, `NoteGestures`, and the context layer's selected pass.
- `CHANGELOG.md`: one line under Unreleased per user-visible phase (3, 4 and 5).
- No OSC, engine or file-format change. Selection is never persisted.

## Risks

- **`NoteEditor` is 2,600 lines with many tests.** Phases 1 and 2 are refactors, so keep them
  free of behaviour changes and land them separately. That way a regression points at one phase.
- **Stale context index mid-gesture.** If selected notes are drawn from the index, they disappear
  while dragged. The selected pass (from refs) plus dirtying the index on commit handles this. Test
  it explicitly.
- **Large selections.** Ctrl+Shift+A over 100 tracks is 50,000 refs. Each edit is O(selected) by
  nature, but drawing must stay culled. Cull the selected pass by tick range, and keep refs sorted
  by song start when the selection is large, or bucket them per clip.
- **Linked clips across tracks.** If one clip has instances on two tracks, selecting it on both
  is one note (keyed by data), so it is edited once. That is right, but the stems and outlines
  must show both instances.

## Decisions

1. **Paste of a multi-track copy.** The clipboard records each note's source track. A copy from
   one track pastes onto the focus track, as now. A copy from several tracks pastes each note back
   onto its source track at the new time, falling back to the focus track if the source is gone or
   not editable.
2. **Vertical moves in Drum View across tracks with different kits.** Allowed: notes move by rows
   of the shared folded layout, even onto a pitch their own track has no pad for. Revisit if it
   bites.
3. **A plain click on another track's unselected note still switches focus (REQ-034).** Kept for
   now. It may change later, so keep the focus switch in one place in the press handling.
