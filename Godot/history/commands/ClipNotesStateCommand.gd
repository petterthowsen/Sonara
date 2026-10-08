# ClipNotesStateCommand.gd
# Restores a clip's MIDI note list to a captured snapshot.
# Used for place/drag/erase gestures that may also cut overlapping notes.
class_name ClipNotesStateCommand extends Command

## Clip whose notes are restored.
var clip: Clip = null

## Snapshot of notes before the gesture (array of field dicts + note refs).
var before_state: Array = []

## Snapshot of notes after the gesture.
var after_state: Array = []


## Create a notes-state command. States are produced by capture_clip_notes().
func _init(
	p_name: String = "Edit Notes",
	p_clip: Clip = null,
	p_before: Array = [],
	p_after: Array = []
) -> void:
	name = p_name
	clip = p_clip
	before_state = p_before
	after_state = p_after


## Capture current midi_notes of a clip into a snapshot array.
static func capture_clip_notes(p_clip: Clip) -> Array:
	var snaps: Array = []
	if p_clip == null:
		return snaps
	for note in p_clip.midi_notes:
		snaps.append(_snapshot_note(note))
	return snaps


## Run `edit` (which changes `p_clip`'s notes) and record it as one undo step. Nothing is
## recorded when the notes came out the same. For edits made without a NoteEditor, such as
## erasing a note on a track the editor only draws.
static func record_edit(action_name: String, p_clip: Clip, edit: Callable) -> void:
	var before := capture_clip_notes(p_clip)
	edit.call()
	var after := capture_clip_notes(p_clip)
	if before.size() == after.size() and _same_fields(before, after):
		return
	HistoryUtil.record(ClipNotesStateCommand.new(action_name, p_clip, before, after))


static func _same_fields(a: Array, b: Array) -> bool:
	for i in a.size():
		var x: Dictionary = a[i]
		var y: Dictionary = b[i]
		if x["id"] != y["id"] or not MidiNoteData.values_equal(x, y):
			return false
	return true


## Snapshot every clip in `clips` (call before a gesture mutates them). Returns {Clip: snapshot}.
static func capture_many(clips: Array) -> Dictionary:
	var out: Dictionary = {}
	for c in clips:
		if c is Clip and not out.has(c):
			out[c] = capture_clip_notes(c)
	return out


## Record one undo step for every clip in `before` (from capture_many) whose notes changed.
## `first` and `last` commands (SelectionStateCommands) go before and after the note commands
## in the same step; they alone are enough to record one.
static func commit_many(action_name: String, before: Dictionary,
		first: Array[Command] = [], last: Array[Command] = []) -> void:
	var cmds: Array[Command] = []
	for c in before.keys():
		var b: Array = before[c]
		var after: Array = capture_clip_notes(c)
		if snapshots_equal(b, after):
			continue
		cmds.append(ClipNotesStateCommand.new(action_name, c, b, after))
	if cmds.is_empty() and first.is_empty() and last.is_empty():
		return
	cmds.assign(first + cmds + last)
	HistoryUtil.record_many(action_name, cmds)


## Compare two note snapshots for equality (id + values), ignoring order.
static func snapshots_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var by_id: Dictionary = {}
	for snap in b:
		by_id[snap["id"]] = snap
	for snap in a:
		if not by_id.has(snap["id"]):
			return false
		if not MidiNoteData.values_equal(snap, by_id[snap["id"]]):
			return false
	return true


## Deep-copy fields of a MidiNoteData into a dictionary (keeps object ref).
static func _snapshot_note(note: MidiNoteData) -> Dictionary:
	var snap := note.values()
	snap["ref"] = note
	snap["id"] = note.id
	return snap


## Apply the after snapshot (redo / initial record already applied).
func do() -> void:
	_restore(after_state)


## Apply the before snapshot.
func undo() -> void:
	_restore(before_state)


## Make clip.midi_notes match the given snapshot via add/remove/update setters.
func _restore(state: Array) -> void:
	if clip == null:
		return

	var desired_by_id: Dictionary = {}
	for snap in state:
		desired_by_id[snap["id"]] = snap

	# Remove notes that should not exist
	var current: Array = clip.midi_notes.duplicate()
	for note in current:
		if not desired_by_id.has(note.id):
			clip.remove_midi_note(note)

	# Add or update desired notes
	for snap in state:
		var note: MidiNoteData = snap["ref"]
		# Ensure fields match snapshot (ref may have been mutated since capture)
		note.id = snap["id"]
		note.apply_values(snap)

		var existing: MidiNoteData = null
		for n in clip.midi_notes:
			if n.id == note.id:
				existing = n
				break

		if existing == null:
			clip.add_midi_note_data(note)
		else:
			if existing != note:
				# Same id, different object — copy fields onto the live object
				existing.copy_values_from(note)
				clip.update_midi_note(existing)
			else:
				clip.update_midi_note(note)
