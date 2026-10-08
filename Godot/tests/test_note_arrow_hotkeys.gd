# test_note_arrow_hotkeys.gd
# Keyboard edits of the selection: grow the range, move by the selection's length, velocity
# and length steps. Each is one undo step and a shared (linked) note is edited once.
#
# Run: godot --headless --path Godot -s tests/test_note_arrow_hotkeys.gd -- --test
extends TestBase

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Note arrow hotkeys"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	await _test_range_grows_by_snap_interval()
	await _test_box_select_grows_range_to_notes()
	await _test_nudge_moves_range()
	await _test_undo_restores_range()
	await _test_undo_restores_selection()
	await _test_move_by_selection_length()
	await _test_velocity_and_length_steps()
	await _test_transpose_by_scale_step()


## One clip with notes at 960 (480 long) and 1920 (480 long), both selected.
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


func _test_range_grows_by_snap_interval() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	var step: int = ed.get_snap_interval()
	_assert(sm.box_selection_start_tick == 960 and sm.box_selection_end_tick == 2400, "setup: range covers the notes")
	ed._resize_selection_range(0, step)
	_assert(sm.box_selection_start_tick == 960 and sm.box_selection_end_tick == 2400 + step, "end later grows the range")
	ed._resize_selection_range(0, -step)
	_assert(sm.box_selection_end_tick == 2400, "end earlier shrinks it back")
	ed._resize_selection_range(-step, 0)
	_assert(sm.box_selection_start_tick == 960 - step and sm.box_selection_end_tick == 2400, "start earlier grows the range")
	ed._resize_selection_range(step, 0)
	_assert(sm.box_selection_start_tick == 960, "start later shrinks it back")
	ed._resize_selection_range(-100000, 0)
	_assert(sm.box_selection_start_tick == 0, "the start stops at tick 0")
	ed._resize_selection_range(0, -100000)
	_assert(sm.box_selection_end_tick == 2400, "the end cannot pass the start")
	_assert(ctx.a.start_tick == 960 and ctx.b.start_tick == 1920, "notes do not move")


func _test_nudge_moves_range() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	ed._move_selection_horizontal(240)
	_assert(ctx.a.start_tick == 1200 and sm.box_selection_start_tick == 1200 and sm.box_selection_end_tick == 2640, "nudging moves the range with the notes")
	ed._move_selection_horizontal(-100000)
	_assert(sm.box_selection_start_tick == 0 and sm.box_selection_end_tick == 1440, "the range stops at tick 0 with its length intact")


func _test_move_by_selection_length() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	var length: int = 2400 - 960
	ed._move_selection_by_its_length(1)
	_assert(ctx.a.start_tick == 960 + length and ctx.b.start_tick == 1920 + length, "right moves the notes by the range length")
	_assert(sm.box_selection_start_tick == 960 + length and sm.box_selection_end_tick == 2400 + length, "the range goes with them")
	ed._move_selection_by_its_length(-1)
	_assert(ctx.a.start_tick == 960 and sm.box_selection_start_tick == 960, "left undoes it")
	ed._move_selection_by_its_length(-1)
	_assert(ctx.a.start_tick == 0 and ctx.b.start_tick == 960, "the group stops at tick 0 without squashing")


func _test_velocity_and_length_steps() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var v0: float = ctx.a.velocity
	ed._adjust_selection_velocity(ed.KEY_VELOCITY_STEP)
	_assert(ctx.a.velocity > v0 and ctx.b.velocity > v0, "velocity up raises every selected note")
	ed._adjust_selection_velocity(-10.0)
	_assert(ctx.a.velocity == MidiNoteData.MIN_VELOCITY, "velocity stops at the minimum")
	ed._adjust_selection_velocity(10.0)
	_assert(ctx.a.velocity == 1.0, "velocity stops at 1.0")
	var step: int = ed.get_snap_interval()
	ed._adjust_selection_length(step)
	_assert(ctx.a.duration_ticks == 480 + step and ctx.b.duration_ticks == 480 + step, "length grows by the snap interval")
	ed._adjust_selection_length(-100000)
	_assert(ctx.a.duration_ticks == step, "length never drops below one snap interval")


func _test_box_select_grows_range_to_notes() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	var gh = ed.grid_helper
	# A box over ticks 1200..2000 touches both notes (960..1440 and 1920..2400) without covering them.
	sm.start_box_selection(Vector2(gh.ticks_to_pixels(1200), 0))
	sm.update_box_selection(Vector2(gh.ticks_to_pixels(2000), 50))
	_assert(sm.box_selection_start_tick > 960 and sm.box_selection_end_tick < 2400, "the box starts narrower than the notes")
	sm.end_box_selection(ed.get_all_visual_notes())
	_assert(sm.box_selection_start_tick == 960 and sm.box_selection_end_tick == 2400, "the range grows to the notes' full span")
	# A box wider than its notes keeps its edges.
	sm.start_box_selection(Vector2(gh.ticks_to_pixels(0), 0))
	sm.update_box_selection(Vector2(gh.ticks_to_pixels(4800), 50))
	sm.end_box_selection(ed.get_all_visual_notes())
	_assert(sm.box_selection_start_tick == 0 and sm.box_selection_end_tick == 4800, "the range never shrinks to the notes")


func _test_undo_restores_range() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed._move_selection_horizontal(240)
	history_util.test_recorder = Callable()
	_assert(sm.box_selection_start_tick == 1200, "setup: nudge moved the range")
	_assert(recorded.size() == 1, "the nudge is one undo step")
	var cmd = recorded[0]
	cmd.undo()
	_assert(ctx.a.start_tick == 960 and sm.box_selection_start_tick == 960 and sm.box_selection_end_tick == 2400, "undo puts the range back with the notes")
	cmd.do()
	_assert(ctx.a.start_tick == 1200 and sm.box_selection_start_tick == 1200 and sm.box_selection_end_tick == 2640, "redo moves the range again")


func _test_undo_restores_selection() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	var sm = ed.selection_manager
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed._duplicate_selection()
	history_util.test_recorder = Callable()
	_assert(recorded.size() == 1, "duplicate is one undo step")
	var after_ids := []
	for vn in ed._selected_note_visuals():
		after_ids.append(vn.midi_note_data)
	_assert(after_ids.size() == 2 and not after_ids.has(ctx.a), "setup: the duplicates are selected")
	recorded[0].undo()
	var undone: Array = ed._selected_note_visuals()
	_assert(undone.size() == 2 and ctx.a in [undone[0].midi_note_data, undone[1].midi_note_data], "undo selects the original notes again")
	recorded[0].do()
	var redone: Array = ed._selected_note_visuals()
	_assert(redone.size() == 2 and not ctx.a in [redone[0].midi_note_data, redone[1].midi_note_data], "redo selects the duplicates again")


func _test_transpose_by_scale_step() -> void:
	var ctx := await _setup()
	var ed = ctx.editor
	ctx.a.note = 59
	ctx.b.note = 59
	ed.scale_context.scale = MusicalScale.make(9, "natural_minor")
	ed.scale_context.snap_enabled = true
	ed._transpose_selection(1)
	_assert(ctx.a.note == 60 and ctx.b.note == 60, "A Minor, Up on 59 -> 60 (next scale pitch)")
	ed._transpose_selection(-1)
	_assert(ctx.a.note == 59, "Down steps back")
	ed._move_selection_vertical(func(p: int) -> int: return ed.step_note(p, 12))
	_assert(ctx.a.note == 71, "the octave key moves 12 semitones (59 -> 71)")
	ed.scale_context.snap_enabled = false
	ctx.a.note = 59
	ctx.b.note = 59
	ed._transpose_selection(1)
	_assert(ctx.a.note == 60, "snap off: Up is one semitone (59 -> 60)")
	ctx.a.note = 60
	ed._transpose_selection(1)
	_assert(ctx.a.note == 61, "snap off: 60 -> 61, a semitone")
