# test_note_mirror.gd
# Flip / mirror (plan 2c): NoteTransforms.mirror_pitch / mirror_time and the NoteEditor
# flip_selection_* wrappers (one undo step, selection range as axis).
#
# Run: godot --headless --path Godot -s tests/test_note_mirror.gd -- --test
extends TestBase

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Note mirror"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_test_pitch_mirror()
	_test_pitch_involution_and_clamp()
	_test_time_mirror()
	_test_single_note_is_a_no_op()
	await _test_editor_flips_with_one_undo_step()
	await _test_range_is_the_axis()


func _note(pitch: int, start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _test_pitch_mirror() -> void:
	var notes: Array[MidiNoteData] = [_note(60, 0, 100), _note(64, 0, 100), _note(67, 0, 100)]
	NoteTransforms.mirror_pitch(notes, 60, 67)
	_assert(notes[0].note == 67 and notes[1].note == 63 and notes[2].note == 60, "pitches invert around the middle of the range")


func _test_pitch_involution_and_clamp() -> void:
	var notes: Array[MidiNoteData] = [_note(48, 0, 100), _note(55, 0, 100), _note(72, 0, 100)]
	NoteTransforms.mirror_pitch(notes, 48, 72)
	NoteTransforms.mirror_pitch(notes, 48, 72)
	_assert(notes[0].note == 48 and notes[1].note == 55 and notes[2].note == 72, "flipping twice restores the pitches")
	var edge: Array[MidiNoteData] = [_note(0, 0, 10), _note(127, 0, 10)]
	NoteTransforms.mirror_pitch(edge, 0, 127)
	_assert(edge[0].note == 127 and edge[1].note == 0, "the extremes swap at pitch 0 and 127")
	var off: Array[MidiNoteData] = [_note(120, 0, 10)]
	NoteTransforms.mirror_pitch(off, 0, 20)
	_assert(off[0].note == 0, "a result below 0 clamps to 0")
	off = [_note(5, 0, 10)]
	NoteTransforms.mirror_pitch(off, 120, 127)
	_assert(off[0].note == 127, "a result above 127 clamps to 127")


func _test_time_mirror() -> void:
	var a := _note(60, 0, 240)
	var b := _note(62, 480, 480)
	var notes: Array[MidiNoteData] = [a, b]
	NoteTransforms.mirror_time(notes, 0, 960)
	_assert(a.start_tick == 720 and a.duration_ticks == 240, "the first note moves to the end, same length")
	_assert(b.start_tick == 0 and b.duration_ticks == 480, "the last note moves to the start, same length")
	NoteTransforms.mirror_time(notes, 0, 960)
	_assert(a.start_tick == 0 and b.start_tick == 480, "flipping twice restores the starts")
	var hit := _note(36, 100, 480)
	var hits: Array[MidiNoteData] = [hit]
	NoteTransforms.mirror_time(hits, 0, 960, false)
	_assert(hit.start_tick == 860, "without durations only the start point mirrors")


func _test_single_note_is_a_no_op() -> void:
	var n := _note(60, 480, 240)
	var notes: Array[MidiNoteData] = [n]
	var span := NoteTransforms.tick_bounds(notes)
	NoteTransforms.mirror_time(notes, span.x, span.y)
	var pitches := NoteTransforms.pitch_bounds(notes)
	NoteTransforms.mirror_pitch(notes, pitches.x, pitches.y)
	_assert(n.start_tick == 480 and n.note == 60, "a single note flips onto itself")


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var a: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 960, 480)
	var b: Object = clip.add_midi_note(project.allocate_note_id(), 67, MidiNoteData.from_midi_velocity(100), 1920, 240)
	var editor = _editor_script.new()
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	var instances := Array([track.create_clip_instance(clip, 0, 7680)], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	editor.bind_to_clips(instances, track)
	await process_frame
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	return {"editor": editor, "a": a, "b": b}


func _test_editor_flips_with_one_undo_step() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.flip_selection_vertical()
	history_util.test_recorder = Callable()
	_assert(ctx.a.note == 67 and ctx.b.note == 60, "vertical flip swaps the two pitches")
	_assert(recorded.size() == 1, "vertical flip is one undo step")
	recorded[0].undo()
	_assert(ctx.a.note == 60 and ctx.b.note == 67, "undo restores the pitches")
	recorded[0].do()
	_assert(ctx.a.note == 67, "redo flips again")


func _test_range_is_the_axis() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	# Notes span 960..2160; widen the range to 0..4000.
	sm.box_selection_start_tick = 0
	sm.box_selection_end_tick = 4000
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.flip_selection_horizontal()
	history_util.test_recorder = Callable()
	_assert(ctx.a.start_tick == 4000 - 1440 and ctx.b.start_tick == 4000 - 2160, "the selection range is the mirror axis")
	_assert(recorded.size() == 1, "horizontal flip is one undo step")
	recorded[0].undo()
	_assert(ctx.a.start_tick == 960 and ctx.b.start_tick == 1920, "undo restores the starts")
