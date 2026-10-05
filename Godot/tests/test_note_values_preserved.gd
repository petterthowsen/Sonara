# Run: godot --headless --path Godot -s tests/test_note_values_preserved.gd -- --test
# Every copy, split and snapshot path keeps a note's vel 0.3 / rel 0.8 (spec 019, REQ-005).
extends TestBase

const VEL := 0.3
const REL := 0.8

var _clip_script: GDScript
var _project_script: GDScript
var _state_cmd: GDScript
var _unique_cmd: GDScript


func suite_name() -> String:
	return "Note values: preserved across copies and undo"


func run_tests() -> void:
	_clip_script = load("res://data/Clip.gd")
	_project_script = load("res://data/Project.gd")
	_state_cmd = load("res://history/commands/ClipNotesStateCommand.gd")
	_unique_cmd = load("res://history/commands/MakeClipUniqueCommand.gd")
	_test_selection_copy_paste()
	_test_split()
	_test_undo_redo()
	_test_make_unique()


func _note(id: int = 1, start: int = 0) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.id = id
	n.note = 60
	n.velocity = VEL
	n.release = REL
	n.start_tick = start
	n.duration_ticks = 960
	return n


func _has_values(n: MidiNoteData) -> bool:
	return is_equal_approx(n.velocity, VEL) and is_equal_approx(n.release, REL)


func _test_selection_copy_paste() -> void:
	var sel := NoteSelection.from_midi_notes([_note()] as Array[MidiNoteData])
	_assert(_has_values(sel.notes[0]), "copy keeps vel and rel")
	var pasted := sel.get_notes_at_position(1920)
	_assert(_has_values(pasted[0]) and pasted[0].start_tick == 1920, "paste keeps vel and rel and moves the note")
	_assert(_has_values(sel.duplicate().notes[0]), "selection duplicate keeps vel and rel")
	var dup := _note().duplicate_note()
	_assert(_has_values(dup) and dup.id == -1, "duplicate_note keeps vel and rel")


func _test_split() -> void:
	var clip = _clip_script.new()
	clip.midi_notes.append(_note())
	var next_id := [10]
	var allocate := func() -> int:
		next_id[0] += 1
		return next_id[0]
	clip.cut_overlapping_notes_at_pitch(60, 300, 600, allocate)
	_assert(clip.midi_notes.size() == 2, "a note is split in two (got %d)" % clip.midi_notes.size())
	_assert(clip.midi_notes.all(func(n): return _has_values(n)), "both halves keep vel and rel")


func _test_undo_redo() -> void:
	var clip = _clip_script.new()
	clip.mark_synced_to_engine()
	clip.midi_notes.append(_note())
	var before = _state_cmd.capture_clip_notes(clip)
	var n: MidiNoteData = clip.midi_notes[0]
	n.velocity = 0.9
	n.release = 0.1
	var after = _state_cmd.capture_clip_notes(clip)
	_assert(not _state_cmd.snapshots_equal(before, after), "a value-only change is a change")
	var cmd = _state_cmd.new("Edit", clip, before, after)
	cmd.undo()
	_assert(_has_values(clip.midi_notes[0]), "undo restores vel and rel")
	cmd.do()
	_assert(is_equal_approx(clip.midi_notes[0].velocity, 0.9) and is_equal_approx(clip.midi_notes[0].release, 0.1), "redo reapplies them")
	var removed_before = _state_cmd.capture_clip_notes(clip)
	clip.remove_midi_note(clip.midi_notes[0])
	var gone = _state_cmd.new("Delete", clip, removed_before, _state_cmd.capture_clip_notes(clip))
	gone.undo()
	_assert(clip.midi_notes.size() == 1 and is_equal_approx(clip.midi_notes[0].release, 0.1), "undoing a delete restores the note's values")


func _test_make_unique() -> void:
	var project = _project_script.new()
	var clip = project.create_clip("Src", _clip_script.ClipType.MIDI)
	clip.midi_notes.append(_note())
	var cmd = _unique_cmd.new(project, null)
	var copy = cmd._duplicate_clip(clip)
	_assert(copy.midi_notes.size() == 1 and _has_values(copy.midi_notes[0]), "make unique keeps vel and rel")
