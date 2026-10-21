## The note selection of one MidiEditor: a set of NoteRefs plus a time range.
##
## It holds data, not nodes, so it survives rebinding the note editor. Each note is stored once,
## keyed by its MidiNoteData (linked instances and loop repeats share it); the ref keeps the
## instance and loop pass the note was selected through. The range is in editor ticks (song ticks
## in track mode, clip-content ticks in clip mode). A note that leaves its clip is forgotten.
class_name NoteSelectionModel extends RefCounted

## The selection (set or range) was changed by an operation. Listeners that follow the whole
## selection (hotkey conditions, overlays, value lanes) use this.
signal changed
## The set of notes changed (also mid-gesture, e.g. while a box grows). Visuals that depend on
## the set redraw on this.
signal set_changed
## An undo or redo put a captured selection back.
signal restored

## The selected notes in selection order, each note (MidiNoteData) once.
var refs: Array[NoteRef] = []
## The selected time range as (start, end) in editor ticks. A range with end <= start is none.
var range := Vector2i.ZERO

var _by_data: Dictionary = {}  # MidiNoteData -> NoteRef
var _clip_counts: Dictionary = {}  # Clip -> number of refs, for the removal signal


func has(data: MidiNoteData) -> bool:
	return data != null and _by_data.has(data)


## The ref that selects `data`, or null.
func ref_of(data: MidiNoteData) -> NoteRef:
	return _by_data.get(data)


func is_empty() -> bool:
	return refs.is_empty()


func size() -> int:
	return refs.size()


## True when a time range is set.
func has_range() -> bool:
	return range.y > range.x


## The distinct tracks of the selected notes.
func tracks() -> Array[Track]:
	var out: Array[Track] = []
	for ref in refs:
		var t := ref.track
		if t != null and t not in out:
			out.append(t)
	return out


## The distinct clips of the selected notes (what an edit has to snapshot).
func clips() -> Array[Clip]:
	var out: Array[Clip] = []
	for c in _clip_counts:
		out.append(c)
	return out


## Make `new_refs` the selection (a note listed twice counts once). `silent` skips `changed`
## and only emits `set_changed`, for mid-gesture updates.
func select(new_refs: Array[NoteRef], silent := false) -> void:
	_drop_all()
	for ref in new_refs:
		_insert(ref)
	_emit(silent)


## Add `new_refs` to the selection; notes already in it keep their ref.
func add(new_refs: Array[NoteRef], silent := false) -> void:
	for ref in new_refs:
		_insert(ref)
	_emit(silent)


## Select `ref`'s note, or unselect it when it is selected. True when it is selected now.
func toggle(ref: NoteRef, silent := false) -> bool:
	if ref == null or ref.data == null:
		return false
	if _by_data.has(ref.data):
		_erase(ref.data)
		_emit(silent)
		return false
	_insert(ref)
	_emit(silent)
	return true


## Unselect a note. Does nothing when it is not selected.
func remove_data(data: MidiNoteData, silent := false) -> void:
	if not has(data):
		return
	_erase(data)
	_emit(silent)


## Unselect every note and drop the range.
func clear(silent := false) -> void:
	_drop_all()
	range = Vector2i.ZERO
	_emit(silent)


## Set the range (editor ticks) and emit `changed`. An end at or before the start clears it.
func set_range(start_tick: int, end_tick: int) -> void:
	range = Vector2i(start_tick, end_tick) if end_tick > start_tick else Vector2i.ZERO
	changed.emit()


## The selection as { "range": Vector2i, "notes": [[ClipInstance, MidiNoteData, pass], ...] },
## for undo.
func capture() -> Dictionary:
	var notes: Array = []
	for ref in refs:
		notes.append([ref.instance, ref.data, ref.pass_index])
	return {"range": range, "notes": notes}


## True when two captured states select the same notes (by data) over the same range.
static func same_state(a: Dictionary, b: Dictionary) -> bool:
	if a.get("range") != b.get("range") or a.notes.size() != b.notes.size():
		return false
	var data_in_a := {}
	for entry in a.notes:
		data_in_a[entry[1]] = true
	for entry in b.notes:
		if not data_in_a.has(entry[1]):
			return false
	return true


## Put a captured selection back (undo/redo). Notes are found again by id in their clip, because
## undoing a delete re-creates the note as a new MidiNoteData. Notes that no longer exist are skipped.
func restore(state: Dictionary) -> void:
	var by_id: Dictionary = {}  # Clip -> { note id: MidiNoteData }, built once per clip
	var picked: Array[NoteRef] = []
	for entry in state.get("notes", []):
		var instance: ClipInstance = entry[0]
		var old: MidiNoteData = entry[1]
		if instance == null or instance.clip == null or old == null:
			continue
		var ids: Dictionary = by_id.get(instance.clip, {})
		if ids.is_empty():
			for n in instance.clip.midi_notes:
				ids[n.id] = n
			by_id[instance.clip] = ids
		var live: MidiNoteData = ids.get(old.id)
		if live != null:
			picked.append(NoteRef.new(instance, live, entry[2] if entry.size() > 2 else 0))
	_drop_all()
	for ref in picked:
		_insert(ref)
	range = state.get("range", Vector2i.ZERO)
	set_changed.emit()
	changed.emit()
	restored.emit()


func _emit(silent: bool) -> void:
	set_changed.emit()
	if not silent:
		changed.emit()


func _insert(ref: NoteRef) -> void:
	if ref == null or ref.data == null or _by_data.has(ref.data):
		return
	refs.append(ref)
	_by_data[ref.data] = ref
	var c := ref.clip
	if c != null:
		var n: int = _clip_counts.get(c, 0)
		if n == 0:
			c.midi_note_removed.connect(_on_midi_note_removed)
		_clip_counts[c] = n + 1


func _erase(data: MidiNoteData) -> void:
	var ref: NoteRef = _by_data[data]
	_by_data.erase(data)
	refs.erase(ref)
	_release_clip(ref.clip)


func _release_clip(c: Clip) -> void:
	if c == null or not _clip_counts.has(c):
		return
	var n: int = _clip_counts[c] - 1
	if n > 0:
		_clip_counts[c] = n
		return
	_clip_counts.erase(c)
	if c.midi_note_removed.is_connected(_on_midi_note_removed):
		c.midi_note_removed.disconnect(_on_midi_note_removed)


func _drop_all() -> void:
	for c in _clip_counts.keys():
		if c.midi_note_removed.is_connected(_on_midi_note_removed):
			c.midi_note_removed.disconnect(_on_midi_note_removed)
	_clip_counts.clear()
	_by_data.clear()
	refs.clear()


func _on_midi_note_removed(note: MidiNoteData) -> void:
	remove_data(note)
