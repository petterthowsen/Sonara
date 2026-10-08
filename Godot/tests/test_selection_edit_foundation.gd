# test_selection_edit_foundation.gd
# Foundation of the selection tools (plan 2a): NoteTransforms helpers, the shared
# NoteEditor._apply_selection_edit path (one undo/redo step, shared notes once), and the
# toolbar's tool-button enabling.
#
# Run: godot --headless --path Godot -s tests/test_selection_edit_foundation.gd -- --test
extends TestBase

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Selection edit foundation"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_test_bounds()
	_test_group_by_start()
	await _test_edit_is_one_undo_step()
	await _test_empty_selection_is_a_no_op()
	await _test_clip_editor_tool_buttons()


func _note(pitch: int, start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _test_bounds() -> void:
	var notes: Array[MidiNoteData] = [_note(60, 960, 480), _note(72, 100, 50), _note(48, 2000, 10)]
	_assert(NoteTransforms.pitch_bounds(notes) == Vector2i(48, 72), "pitch bounds span the lowest and highest note")
	_assert(NoteTransforms.tick_bounds(notes) == Vector2i(100, 2010), "tick bounds span the earliest start and latest end")
	var none: Array[MidiNoteData] = []
	_assert(NoteTransforms.tick_bounds(none) == Vector2i.ZERO, "tick bounds of nothing are zero")


func _test_group_by_start() -> void:
	var notes: Array[MidiNoteData] = [_note(64, 965, 480), _note(60, 960, 480), _note(67, 1920, 480), _note(62, 960, 480)]
	var groups := NoteTransforms.group_by_start(notes, 15)
	_assert(groups.size() == 2, "two chords form two groups")
	_assert(groups[0].size() == 3 and groups[1].size() == 1, "starts within the tolerance share a group")


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var a: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 960, 480)
	var b: Object = clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 1920, 480)
	var editor = _editor_script.new()
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	var instances := Array([track.create_clip_instance(clip, 0, 7680)], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	editor.bind_to_clips(instances, track)
	await process_frame
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	return {"editor": editor, "a": a, "b": b}


func _test_edit_is_one_undo_step() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var seen: Array = []
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed._apply_selection_edit("Test Edit", func(notes: Array[MidiNoteData]):
		seen.append_array(notes)
		for n in notes:
			n.note += 2)
	history_util.test_recorder = Callable()
	_assert(seen.size() == 2, "the edit sees each selected note once")
	_assert(ctx.a.note == 62 and ctx.b.note == 66, "the edit mutated the notes")
	_assert(recorded.size() == 1, "the edit is one entry on the undo stack")
	recorded[0].undo()
	_assert(ctx.a.note == 60 and ctx.b.note == 64, "undo restores the notes")
	recorded[0].do()
	_assert(ctx.a.note == 62 and ctx.b.note == 66, "redo applies the edit again")


func _test_empty_selection_is_a_no_op() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	ed.selection_manager.clear_selection()
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	var ran := [false]
	ed._apply_selection_edit("Test Edit", func(_notes): ran[0] = true)
	history_util.test_recorder = Callable()
	_assert(not ran[0] and recorded.is_empty(), "with nothing selected the edit does not run or record")


func _test_clip_editor_tool_buttons() -> void:
	var ce: Node = load("res://clip_editor/ClipEditor.tscn").instantiate()
	root.add_child(ce)
	await process_frame
	var quantize: Button = ce.tools_group.find_child("Quantize", true, false)
	var extra := Button.new()
	ce.tools_group.add_child(extra)
	ce._sync_selection_tools()
	_assert(extra.disabled, "an unregistered tool stays disabled")
	_assert(not quantize.disabled, "clip mode: a tool is enabled with nothing selected (it acts on all notes)")
	ce.midi_editor.track_mode = true
	ce._sync_selection_tools()
	_assert(quantize.disabled, "track mode: a tool needs an explicit selection")
	ce.queue_free()
