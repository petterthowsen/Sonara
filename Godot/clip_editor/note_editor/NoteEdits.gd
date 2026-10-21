## The shared edit path of the note editor: gestures, key edits and selection tools all go
## through it, working on NoteRefs (and so on MidiNoteData) rather than on VisualNotes.
##
## An edit is: `begin()` snapshots the clips it may change and the selection, the caller mutates
## `ref.data` freely (mid-gesture too), `refresh()` shows the data on the visuals, `sync()` cuts
## same-pitch overlaps and sends the notes to the engine, and `commit(name)` records one undo
## step: a ClipNotesStateCommand per changed clip plus the two SelectionStateCommands when the
## selection changed. `cancel()` puts the snapshot back (Esc mid-gesture).
class_name NoteEdits extends RefCounted

static var logger := Log.make("NoteEdits")

## The selection the edits act on.
var model: NoteSelectionModel
## The note editor whose visuals show refs (null: nothing to refresh).
var editor: NoteEditor = null
## Draws the notes of the other tracks; redrawn for refs the editor has no visual for.
var context_layer: Control = null

var _snapshots: Dictionary = {}  # Clip -> note snapshot
var _selection_before: Dictionary = {}


func _init(p_model: NoteSelectionModel) -> void:
	model = p_model


## True while an edit is open (begun, not yet committed, cancelled or discarded).
func is_open() -> bool:
	return not _snapshots.is_empty()


## Start an edit on the clips of the selected notes plus `extra_clips` (clips that gain notes but
## own no selected note). Call before mutating.
func begin(extra_clips: Array = []) -> void:
	var clips: Array = model.clips()
	for extra in extra_clips:
		if extra is Clip and extra not in clips:
			clips.append(extra)
	begin_clips(clips)


## Start an edit on exactly `clips` (placing, erasing and pasting know their clips).
func begin_clips(clips: Array) -> void:
	_snapshots = ClipNotesStateCommand.capture_many(clips)
	_selection_before = model.capture()


## Show the current data of `refs` (default: the selection) on their visuals: the editor's for
## notes it shows, a redraw of the context layer for the rest.
func refresh(refs: Variant = null) -> void:
	var list: Array = refs if refs != null else model.refs
	var context_dirty := false
	for ref: NoteRef in list:
		if editor != null and editor.visual_of_ref(ref) != null:
			editor.refresh_note(ref.data, ref.clip)
		else:
			context_dirty = true
	if context_dirty and context_layer != null:
		context_layer.queue_redraw()
	if editor != null:
		editor.notes_refreshed.emit()


## Cut same-pitch overlaps made by the edit and send the notes to the engine (default: the
## selection). Call after the mutation, before `commit`.
func sync(refs: Variant = null) -> void:
	var list: Array = refs if refs != null else model.refs
	for ref: NoteRef in list:
		var data := ref.data
		var note_clip := ref.clip
		if note_clip == null:
			continue
		note_clip.cut_overlapping_notes_at_pitch(
			data.note, data.start_tick, data.start_tick + data.duration_ticks,
			note_clip.allocate_note_id, data.id)
		note_clip.update_midi_note(data)


## Record the edit as one undo step. Nothing is recorded when nothing changed, and not twice.
func commit(action_name: String) -> void:
	if _snapshots.is_empty():
		return
	var before := _snapshots
	var selection_before := _selection_before
	_snapshots = {}
	_selection_before = {}
	var first: Array[Command] = []
	var last: Array[Command] = []
	var selection_now := model.capture()
	if not NoteSelectionModel.same_state(selection_before, selection_now):
		first.append(SelectionStateCommand.new(action_name, model, selection_before, selection_now, true))
		last.append(SelectionStateCommand.new(action_name, model, selection_before, selection_now, false))
	ClipNotesStateCommand.commit_many(action_name, before, first, last)


## Drop the open edit without recording or restoring anything (the caller undid it itself, or
## nothing changed).
func discard() -> void:
	_snapshots = {}
	_selection_before = {}


## Put the clips back to how they were at `begin` and restore the selection. No undo step.
func cancel() -> void:
	if _snapshots.is_empty():
		return
	var before := _snapshots
	var selection_before := _selection_before
	discard()
	for c: Clip in before:
		ClipNotesStateCommand.new("Cancel", c, before[c], before[c]).undo()
	model.restore(selection_before)
	refresh()
