# test_note_group_scale.gd
# Group length-scale (plan phase 3): pure NoteTransforms.scale math and the NoteEditor drag
# (live preview from a snapshot, one undo step, cancel restores).
#
# Run: godot --headless --path Godot -s tests/test_note_group_scale.gd -- --test
extends TestBase

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Note group scale"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_test_double_and_half()
	_test_anchor_does_not_move()
	_test_min_clamp()
	_test_snapshot_has_no_drift()
	await _test_editor_drag_commit_and_undo()
	await _test_editor_drag_cancel()
	await _test_handle_visibility()


func _note(pitch: int, start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _pair() -> Array[MidiNoteData]:
	return [_note(60, 960, 480), _note(64, 1920, 960)]


func _test_double_and_half() -> void:
	var n := _pair()
	NoteTransforms.scale(n, 960, 2.0)
	_assert(n[0].start_tick == 960 and n[0].duration_ticks == 960, "factor 2: first note doubles its length")
	_assert(n[1].start_tick == 2880 and n[1].duration_ticks == 1920, "factor 2: second note starts twice as far from the anchor")
	NoteTransforms.scale(n, 960, 0.5)
	_assert(n[1].start_tick == 1920 and n[1].duration_ticks == 960 and n[0].duration_ticks == 480, "factor 0.5 undoes factor 2")


func _test_anchor_does_not_move() -> void:
	var n := _pair()
	NoteTransforms.scale(n, 960, 1.7)
	_assert(n[0].start_tick == 960, "the anchor note keeps its start")


func _test_min_clamp() -> void:
	var n: Array[MidiNoteData] = [_note(60, 0, 3), _note(64, 100, 400)]
	var f := NoteTransforms.min_scale_factor(PackedInt32Array([3, 400]))
	_assert(is_equal_approx(f, 1.0 / 3.0), "min factor is 1 / shortest duration")
	NoteTransforms.scale(n, 0, 0.0001)
	_assert(n[0].duration_ticks == 1 and n[1].duration_ticks == 1, "no note collapses below one tick")


func _test_snapshot_has_no_drift() -> void:
	var n := _pair()
	var starts := PackedInt32Array([960, 1920])
	var durations := PackedInt32Array([480, 960])
	for f in [1.1, 1.37, 0.83, 2.0, 1.0]:
		NoteTransforms.scale(n, 960, f, starts, durations)
	_assert(n[0].start_tick == 960 and n[0].duration_ticks == 480 and n[1].start_tick == 1920 and n[1].duration_ticks == 960, "factor back to 1 restores the originals exactly")


func _make_editor(starts: Array) -> Array:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var datas: Array = []
	for s in starts:
		datas.append(clip.add_midi_note(project.allocate_note_id(), 60 + datas.size(), MidiNoteData.from_midi_velocity(100), s, 480))
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	var instances := Array([track.create_clip_instance(clip, 0, 7680)], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	ed.bind_to_clips(instances, track)
	await process_frame
	return [ed, datas]


func _test_editor_drag_commit_and_undo() -> void:
	var made := await _make_editor([960, 1920])
	var ed = made[0]
	var a: MidiNoteData = made[1][0]
	var b: MidiNoteData = made[1][1]
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.begin_group_scale()
	# Group spans 960..2400; drag the end to 3840 (factor 2 about the first start).
	ed.update_group_scale(3840)
	ed.update_group_scale(2500)
	ed.update_group_scale(3840)
	_assert(a.start_tick == 960 and a.duration_ticks == 960 and b.start_tick == 2880, "preview scales from the snapshot")
	ed.end_group_scale()
	history_util.test_recorder = Callable()
	_assert(recorded.size() == 1, "a scale drag is one undo step")
	recorded[0].undo()
	_assert(a.duration_ticks == 480 and b.start_tick == 1920 and b.duration_ticks == 480, "undo restores the notes")
	ed.queue_free()


func _test_editor_drag_cancel() -> void:
	var made := await _make_editor([960, 1920])
	var ed = made[0]
	var a: MidiNoteData = made[1][0]
	var b: MidiNoteData = made[1][1]
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.begin_group_scale()
	ed.update_group_scale(4000)
	ed.cancel_group_scale()
	history_util.test_recorder = Callable()
	_assert(a.start_tick == 960 and a.duration_ticks == 480 and b.start_tick == 1920 and b.duration_ticks == 480, "cancel restores the original notes")
	_assert(recorded.is_empty(), "cancel records no undo step")
	_assert(ed.interaction_mode == 0, "cancel ends the gesture")
	ed.queue_free()


func _test_handle_visibility() -> void:
	var made := await _make_editor([960, 1920])
	var ed = made[0]
	_assert(ed.group_scale_handle_rect().size == Vector2.ZERO, "no handle without a selection")
	var visuals: Array[VisualNote] = ed.get_all_visual_notes()
	var one: Array[VisualNote] = [visuals[0]]
	ed.selection_manager.select_visuals(one)
	_assert(ed.group_scale_handle_rect().size == Vector2.ZERO, "no handle for a single note")
	ed.selection_manager.select_all(visuals)
	var r: Rect2 = ed.group_scale_handle_rect()
	_assert(r.size != Vector2.ZERO, "handle with two selected notes")
	var last: VisualNote = visuals[0] if visuals[0].position.x > visuals[1].position.x else visuals[1]
	_assert(r.position.x > last.position.x + last.size.x and r.position.x < last.position.x + last.size.x + 12.0, "handle sits just past the end of the right-most note")
	_assert(ed.is_over_group_scale_handle(r.get_center()), "handle hit test")
	ed.queue_free()
