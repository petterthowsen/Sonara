# test_multi_track_clipboard.gd
# Phase 5 of docs/multi-track-note-editing-plan.md: value lane edits, copy and paste, group scale
# and Ctrl+drag duplicate work on a selection that spans tracks, each as one undo step.
#
# Run: godot --headless --path Godot -s tests/test_multi_track_clipboard.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_script: GDScript
var _instance_script: GDScript
var _placement_script: GDScript
var _ref_script: GDScript
var _clip_editor_scene: PackedScene


func suite_name() -> String:
	return "Multi-track clipboard, scale, duplicate and value lanes"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_placement_script = load("res://clip_editor/note_editor/NotePlacement.gd")
	_ref_script = load("res://clip_editor/note_editor/NoteRef.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	await _test_value_lane_edit_across_tracks()
	await _test_copy_paste_back_onto_source_tracks()
	await _test_single_track_copy_pastes_onto_the_focus()
	await _test_source_track_not_editable_falls_back()
	await _test_group_scale_across_tracks()
	await _test_duplicate_across_tracks()


func _typed_tracks(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _track_script)


func _typed_instances(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


func _refs(list: Array) -> Array:
	return Array(list, TYPE_OBJECT, &"RefCounted", _ref_script)


## A ClipEditor in track mode over A and B (both editable). One instance each at tick 0 (a
## bar), plus, with `second`, another clip at bar 2. Notes: A 60 (tick 0) and 64 (960), B 62 (0)
## and 72 (960).
func _setup(second := false) -> Dictionary:
	var project: Object = _project_script.new()
	var out := {"project": project, "tracks": [], "cis": []}
	var pitches := {"A": [60, 64], "B": [62, 72]}
	for key in ["A", "B"]:
		var pair: Dictionary = project.create_instrument_track(key)
		var clip: Object = project.create_clip("Clip" + key)
		project.add_clip(clip)
		var ci: Object = pair.track.create_clip_instance(clip, 0, 3840)
		for i in 2:
			clip.add_midi_note(project.allocate_note_id(), pitches[key][i], MidiNoteData.from_midi_velocity(100), i * 960, 480)
		out[key.to_lower()] = pair.track
		out["ci_" + key.to_lower()] = ci
		out.tracks.append(pair.track)
		out.cis.append(ci)
		if second:
			var clip2: Object = project.create_clip("Clip" + key + "2")
			project.add_clip(clip2)
			var ci2: Object = pair.track.create_clip_instance(clip2, 3840, 3840)
			out["ci_" + key.to_lower() + "2"] = ci2
			out.cis.append(ci2)
	var clip_editor: Control = _clip_editor_scene.instantiate()
	root.add_child(clip_editor)
	clip_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clip_editor.size = Vector2(1200, 700)
	await process_frame
	var midi: Object = clip_editor.midi_editor
	var clips := _typed_instances(out.cis)
	midi.bind_to_clips(clips, _typed_tracks(out.tracks))
	midi.set_track_views(_typed_tracks(out.tracks), clips)
	midi.editable_tracks = _typed_tracks(out.tracks)
	midi.focus_track = out.a
	await process_frame
	await process_frame
	out["clip_editor"] = clip_editor
	out["midi"] = midi
	out["editor"] = midi.note_editors[0]
	return out


func _finish(ctx: Dictionary) -> void:
	ctx.clip_editor.queue_free()
	await process_frame


func _data(ctx: Dictionary, key: String, pitch: int, clip_key := "") -> Object:
	for nd in ctx["ci_" + (clip_key if clip_key != "" else key)].clip.midi_notes:
		if nd.note == pitch:
			return nd
	return null


func _ref(ctx: Dictionary, key: String, pitch: int) -> Object:
	return _ref_script.new(ctx["ci_" + key], _data(ctx, key, pitch), 0)


func _select(ctx: Dictionary, list: Array) -> void:
	ctx.midi.note_selection.select(_refs(list))


func _note_rect(ctx: Dictionary, key: String, pitch: int) -> Rect2:
	return _placement_script.note_rect(_data(ctx, key, pitch), 0, ctx.midi.lane_layout, ctx.midi.grid_helper)


## Global centre of a note of a track the context layer draws.
func _context_center(ctx: Dictionary, key: String, pitch: int) -> Vector2:
	return ctx.midi.context_layer.get_global_transform() * _note_rect(ctx, key, pitch).get_center()


func _mouse(gp: Vector2, pressed: bool, ctrl := false) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	ev.global_position = gp
	ev.position = gp
	return ev


func _press(ctx: Dictionary, gp: Vector2, ctrl := false) -> void:
	ctx.midi._handle_left_mouse_press(ctx.editor.make_canvas_position_local(gp), _mouse(gp, true, ctrl))


func _release(ctx: Dictionary, gp: Vector2) -> void:
	ctx.midi._handle_left_mouse_release(ctx.editor.make_canvas_position_local(gp), _mouse(gp, false))


func _record(call: Callable) -> Array:
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	call.call()
	history_util.test_recorder = Callable()
	return recorded




func _test_value_lane_edit_across_tracks() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var stems: Array = midi.value_stems()
	var b_stem: Dictionary = {}
	for stem in stems:
		if stem.note_data == _data(ctx, "b", 72):
			b_stem = stem
	_assert(not b_stem.is_empty() and not b_stem.ghost and b_stem.selected and b_stem.clip == ctx.ci_b.clip,
		"the selected note of B has a stem, in B's clip")
	_assert(b_stem.get("color") == ctx.b.color, "in B's colour")
	_assert(midi.selected_note_data().size() == 2, "the lane edits act on both selected notes")
	ctx.clip_editor.value_pane.visible = true
	await process_frame
	await process_frame
	var area: Object = ctx.clip_editor.value_pane.lanes[0].stem_area
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var recorded := _record(func(): area.apply_exact_value(midi.selected_note_data(), 0.5))
	_assert(is_equal_approx(a60.velocity, 0.5) and is_equal_approx(b72.velocity, 0.5), "setting a value changed both tracks' notes")
	_assert(recorded.size() == 1, "as one undo step: %d" % recorded.size())
	recorded[0].undo()
	_assert(is_equal_approx(a60.velocity, 100.0 / 127.0) and is_equal_approx(b72.velocity, 100.0 / 127.0), "which undoes both")
	await _finish(ctx)


func _copy_then_paste(ctx: Dictionary, at_tick: int) -> Array:
	ctx.editor.copy_to_clipboard()
	return _record(func(): ctx.editor._paste_at_position(at_tick))


func _count(ctx: Dictionary, key: String, pitch: int) -> int:
	var n := 0
	for nd in ctx["ci_" + key].clip.midi_notes:
		n += 1 if nd.note == pitch else 0
	return n


func _test_copy_paste_back_onto_source_tracks() -> void:
	var ctx := await _setup()
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var recorded := _copy_then_paste(ctx, 1920)
	_assert(_count(ctx, "a", 60) == 2 and _count(ctx, "b", 72) == 2, "each note was pasted onto its own track")
	_assert(_count(ctx, "a", 72) == 0 and _count(ctx, "b", 60) == 0, "and none onto the other")
	var pasted_a: bool = ctx.ci_a.clip.midi_notes.any(func(n): return n.note == 60 and n.start_tick == 1920)
	var pasted_b: bool = ctx.ci_b.clip.midi_notes.any(func(n): return n.note == 72 and n.start_tick == 1920 + 960)
	_assert(pasted_a and pasted_b, "at the new time, keeping their offsets")
	_assert(ctx.midi.note_selection.size() == 2 and ctx.midi.note_selection.tracks().size() == 2, "the pasted notes are the selection")
	_assert(recorded.size() == 1, "one undo step: %d" % recorded.size())
	recorded[0].undo()
	_assert(_count(ctx, "a", 60) == 1 and _count(ctx, "b", 72) == 1, "undone on both tracks")
	await _finish(ctx)


func _test_single_track_copy_pastes_onto_the_focus() -> void:
	var ctx := await _setup()
	_select(ctx, [_ref(ctx, "a", 60)])
	ctx.editor.copy_to_clipboard()
	ctx.midi.focus_track = ctx.b
	await process_frame
	ctx.editor._paste_at_position(1920)
	_assert(_count(ctx, "b", 60) == 1 and _count(ctx, "a", 60) == 1, "a copy from one track pastes onto the focus track")
	await _finish(ctx)


func _test_source_track_not_editable_falls_back() -> void:
	var ctx := await _setup()
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	ctx.editor.copy_to_clipboard()
	ctx.midi.editable_tracks = _typed_tracks([ctx.a])
	ctx.editor._paste_at_position(1920)
	_assert(_count(ctx, "b", 72) == 1, "B is not editable: nothing was pasted onto it")
	_assert(_count(ctx, "a", 72) == 1 and _count(ctx, "a", 60) == 2, "its note fell back to the focus track")
	await _finish(ctx)


func _test_group_scale_across_tracks() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var handle: Rect2 = editor.group_scale_handle_rect()
	_assert(handle.size != Vector2.ZERO, "two notes on two tracks have a handle")
	var gh: Object = ctx.midi.grid_helper
	_assert(handle.position.x > gh.ticks_to_pixels(1440), "just past the right-most note, which is B's")
	var recorded := _record(func():
		editor.begin_group_scale(handle.get_center().x)
		editor.update_group_scale(2880)
		editor.end_group_scale())
	_assert(a60.start_tick == 0 and a60.duration_ticks == 960, "A's note kept its start and doubled: %d, %d" % [a60.start_tick, a60.duration_ticks])
	_assert(b72.start_tick == 1920 and b72.duration_ticks == 960, "B's note scaled in song ticks about the earliest start: %d, %d" % [b72.start_tick, b72.duration_ticks])
	_assert(recorded.size() == 1, "one undo step")
	recorded[0].undo()
	_assert(b72.start_tick == 960 and b72.duration_ticks == 480 and a60.duration_ticks == 480, "undone")
	# Esc cancels.
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	recorded = _record(func():
		editor.begin_group_scale(handle.get_center().x)
		editor.update_group_scale(2880)
		editor.handle_key_input(esc))
	_assert(b72.start_tick == 960 and a60.duration_ticks == 480 and recorded.is_empty(), "Esc puts both back, recording nothing")
	await _finish(ctx)


func _test_duplicate_across_tracks() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var pos := Vector2(100, ctx.midi.lane_layout.pitch_to_y_center(72))
	# Grab B's note, which only the context layer draws.
	var started: bool = editor.start_duplicate_drag_ref(_ref(ctx, "b", 72), pos)
	_assert(started and editor.get_pending_duplicates().size() == 1 and editor._dup_context.size() == 1,
		"A's note is a pending node, B's a pending copy for the context layer")
	_assert(ctx.midi.context_layer._pending.size() == 1, "which the layer draws")
	var recorded := _record(func():
		editor.update_duplicate_drag(pos + Vector2(gh.ticks_to_pixels(1920), 0))
		editor.finish_duplicate_drag())
	_assert(_count(ctx, "a", 60) == 2 and _count(ctx, "b", 72) == 2, "each copy went into its own track's clip")
	_assert(ctx.ci_b.clip.midi_notes.any(func(n): return n.note == 72 and n.start_tick == 960 + 1920), "at the dragged position")
	_assert(ctx.midi.context_layer._pending.is_empty() and ctx.midi.note_selection.size() == 2, "the pending copies are gone and the new notes are selected")
	_assert(recorded.size() == 1, "one undo step: %d" % recorded.size())
	recorded[0].undo()
	_assert(_count(ctx, "a", 60) == 1 and _count(ctx, "b", 72) == 1, "undone on both tracks")
	await _finish(ctx)
