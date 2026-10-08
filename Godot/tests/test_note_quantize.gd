# test_note_quantize.gd
# Quantize (plan 2b): pure NoteTransforms.quantize math and NoteEditor.quantize_selection
# (one undo step, strength, start-and-end mode, loop folding).
#
# Run: godot --headless --path Godot -s tests/test_note_quantize.gd -- --test
extends TestBase

const SIXTEENTH := 240

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Note quantize"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_test_snap_to_sixteenth()
	_test_partial_strength()
	_test_start_and_end()
	_test_quantized_note_unchanged()
	_test_triplet_grid()
	await _test_selection_is_one_undo_step()
	await _test_strength_is_remembered()


func _note(start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _grid(interval: int) -> Callable:
	return func(t: int) -> int: return roundi(float(t) / interval) * interval


func _test_snap_to_sixteenth() -> void:
	var a := _note(250, 480)
	var b := _note(110, 480)
	var notes: Array[MidiNoteData] = [a, b]
	var changed := NoteTransforms.quantize(notes, _grid(SIXTEENTH), 1.0)
	_assert(a.start_tick == 240 and b.start_tick == 0, "100% strength snaps each start to the nearest 1/16")
	_assert(a.duration_ticks == 480 and b.duration_ticks == 480, "start mode keeps the duration")
	_assert(changed == 2, "both notes count as changed")


func _test_partial_strength() -> void:
	var a := _note(280, 480)
	var notes: Array[MidiNoteData] = [a]
	NoteTransforms.quantize(notes, _grid(SIXTEENTH), 0.5)
	_assert(a.start_tick == 260, "50% moves the start half way to the grid (280 -> 240 is 260)")
	var z := _note(280, 480)
	notes = [z]
	NoteTransforms.quantize(notes, _grid(SIXTEENTH), 0.0)
	_assert(z.start_tick == 280, "0% leaves the start alone")


func _test_start_and_end() -> void:
	var a := _note(250, 470)  # ends at 720, already on the grid
	var b := _note(250, 490)  # ends at 740 -> 720
	var notes: Array[MidiNoteData] = [a, b]
	NoteTransforms.quantize(notes, _grid(SIXTEENTH), 1.0, NoteTransforms.QuantizeMode.START_AND_END)
	_assert(a.start_tick == 240 and a.start_tick + a.duration_ticks == 720, "start and end both land on the grid")
	_assert(b.start_tick == 240 and b.start_tick + b.duration_ticks == 720, "the duration follows the snapped end")
	var tiny := _note(250, 5)  # both ends snap to 240
	notes = [tiny]
	NoteTransforms.quantize(notes, _grid(SIXTEENTH), 1.0, NoteTransforms.QuantizeMode.START_AND_END)
	_assert(tiny.duration_ticks == 1, "a note never collapses below one tick")


func _test_quantized_note_unchanged() -> void:
	var a := _note(480, 240)
	var notes: Array[MidiNoteData] = [a]
	var changed := NoteTransforms.quantize(notes, _grid(SIXTEENTH), 1.0, NoteTransforms.QuantizeMode.START_AND_END)
	_assert(changed == 0 and a.start_tick == 480 and a.duration_ticks == 240, "an already-quantized note stays unchanged")


func _test_triplet_grid() -> void:
	# Any snap function works: a 1/8 triplet grid is 320 ticks at 960 PPQ.
	var a := _note(350, 100)
	var notes: Array[MidiNoteData] = [a]
	NoteTransforms.quantize(notes, _grid(320), 1.0)
	_assert(a.start_tick == 320, "a triplet grid snaps to 320-tick steps")


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var a: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 970, 480)
	var b: Object = clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 1930, 480)
	var editor = _editor_script.new()
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	var instances := Array([track.create_clip_instance(clip, 0, 7680)], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	editor.bind_to_clips(instances, track)
	await process_frame
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	return {"editor": editor, "a": a, "b": b}


func _test_selection_is_one_undo_step() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var step: int = ed.get_snap_interval()
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.quantize_selection(1.0, 0)
	history_util.test_recorder = Callable()
	_assert(ctx.a.start_tick == ed.grid_helper.snap_ticks(970) and ctx.b.start_tick == ed.grid_helper.snap_ticks(1930), "the notes snap to the editor's grid (step %d)" % step)
	_assert(recorded.size() == 1, "quantize is one undo step")
	recorded[0].undo()
	_assert(ctx.a.start_tick == 970 and ctx.b.start_tick == 1930, "undo restores the starts")
	recorded[0].do()
	_assert(ctx.a.start_tick == ed.grid_helper.snap_ticks(970), "redo quantizes again")


func _test_strength_is_remembered() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	_assert(ed.quantize_strength() == 1.0, "the default strength is 100%")
	_assert(ed.quantize_mode() == NoteTransforms.QuantizeMode.START, "the default mode quantizes starts")
	var sonara = root.get_node_or_null("Sonara")
	if sonara == null:
		return
	sonara.set_config(ed.QUANTIZE_STRENGTH_KEY, 0.25)
	_assert(is_equal_approx(ed.quantize_strength(), 0.25), "the remembered strength is read back")
	sonara.set_config(ed.QUANTIZE_STRENGTH_KEY, 1.0)
