# test_multi_track_gestures.gd
# Phase 4 of docs/multi-track-note-editing-plan.md: drag, resize and the Alt velocity drag act on
# the whole note selection, whatever tracks its notes are on, and start from a note of any track.
# Each note keeps its track and its per-note rules (loop fold, played window, drop into another
# clip of its own track). One undo step per gesture; Esc puts everything back.
#
# Run: godot --headless --path Godot -s tests/test_multi_track_gestures.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_script: GDScript
var _instance_script: GDScript
var _placement_script: GDScript
var _ref_script: GDScript
var _clip_editor_scene: PackedScene


func suite_name() -> String:
	return "Multi-track note gestures"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_placement_script = load("res://clip_editor/note_editor/NotePlacement.gd")
	_ref_script = load("res://clip_editor/note_editor/NoteRef.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	await _test_drag_selection_over_two_tracks()
	await _test_drag_from_a_context_note()
	await _test_resize_from_a_context_note()
	await _test_velocity_drag_across_tracks()
	await _test_escape_cancels_across_tracks()
	await _test_drop_transfer_stays_on_the_track()
	await _test_per_note_rules()
	await _test_ctrl_press_adds_and_drags()


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


func _test_drag_selection_over_two_tracks() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var grabbed: Object = editor.get_visual_note(a60.id)
	var start: Vector2 = grabbed.position + Vector2(2, 2)
	var recorded := _record(func():
		editor._on_drag_started(grabbed, start)
		editor._on_drag_updated(grabbed, start + Vector2(gh.ticks_to_pixels(960), -editor.layout.row_height))
		editor._on_drag_ended(grabbed))
	_assert(a60.start_tick == 960 and a60.note == 61, "the grabbed note moved a beat and a row: %d, %d" % [a60.start_tick, a60.note])
	_assert(b72.start_tick == 1920 and b72.note == 73, "so did B's note, which has no node: %d, %d" % [b72.start_tick, b72.note])
	_assert(_data(ctx, "b", 73) == b72 and ctx.ci_b.clip.midi_notes.has(b72), "and it is still in B's clip")
	_assert(recorded.size() == 1, "one undo step for the whole drag: %d" % recorded.size())
	recorded[0].undo()
	_assert(a60.start_tick == 0 and a60.note == 60 and b72.start_tick == 960 and b72.note == 72, "which undoes both tracks")
	_assert(ctx.midi.note_selection.size() == 2, "and keeps the selection")
	await _finish(ctx)


func _test_drag_from_a_context_note() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var gp := _context_center(ctx, "b", 72)
	var recorded := _record(func():
		_press(ctx, gp)
		_assert(editor.gestures.kind == 1 and ctx.midi.focus_track == ctx.a,
			"pressing a selected note of B starts a drag with no focus switch")
		editor.gestures.update_drag(editor.make_canvas_position_local(gp) + Vector2(gh.ticks_to_pixels(480), 0))
		_release(ctx, gp + Vector2(gh.ticks_to_pixels(480), 0)))
	_assert(b72.start_tick == 1440 and a60.start_tick == 480, "the whole selection followed: B %d, A %d" % [b72.start_tick, a60.start_tick])
	_assert(ctx.midi.focus_track == ctx.a and ctx.midi.note_selection.size() == 2, "the focus and the selection are kept")
	_assert(recorded.size() == 1, "one undo step")
	recorded[0].undo()
	_assert(b72.start_tick == 960 and a60.start_tick == 0, "undone")
	# A press with Ctrl on an unselected note of B adds it and drags.
	_select(ctx, [_ref(ctx, "a", 60)])
	_press(ctx, _context_center(ctx, "b", 72), true)
	_assert(ctx.midi.note_selection.size() == 2 and editor.gestures.kind == 1 and ctx.midi.focus_track == ctx.a,
		"Ctrl+press on an unselected note of B adds it and drags, without a focus switch")
	editor.gestures.cancel()
	await _finish(ctx)


func _test_resize_from_a_context_note() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var rect := _note_rect(ctx, "b", 72)
	var edge: Vector2 = ctx.midi.context_layer.get_global_transform() * Vector2(rect.end.x - 2.0, rect.get_center().y)
	var recorded := _record(func():
		_press(ctx, edge)
		_assert(editor.gestures.kind == 2 and ctx.midi.focus_track == ctx.a,
			"pressing the right edge of a selected note of B starts a resize, with no focus switch")
		editor.gestures.update_resize(editor.make_canvas_position_local(edge) + Vector2(gh.ticks_to_pixels(480), 0))
		_release(ctx, edge))
	_assert(b72.duration_ticks == 960 and a60.duration_ticks == 960, "both notes grew by the same amount: B %d, A %d" % [b72.duration_ticks, a60.duration_ticks])
	_assert(recorded.size() == 1, "one undo step")
	recorded[0].undo()
	_assert(b72.duration_ticks == 480 and a60.duration_ticks == 480, "undone")
	await _finish(ctx)


func _test_velocity_drag_across_tracks() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var settings: Object = root.get_node_or_null("Settings")
	var key := "midi_editor/note_drag_modifiers"
	var previous: Variant = settings.get_value(key)
	settings.set_value(key, settings.MODS_CTRL_ALT)
	var before_a: float = a60.velocity
	var before_b: float = b72.velocity
	editor.gestures.key_held = func(key: int) -> bool: return key == KEY_ALT
	var grabbed: Object = editor.get_visual_note(a60.id)
	var start: Vector2 = grabbed.position + Vector2(2, 2)
	var recorded := _record(func():
		editor._on_drag_started(grabbed, start)
		editor._on_drag_updated(grabbed, start)  # the mode switch re-anchors here
		editor._on_drag_updated(grabbed, start + Vector2(0, -40))
		editor._on_drag_ended(grabbed))
	settings.set_value(key, previous)
	_assert(a60.velocity > before_a and b72.velocity > before_b, "dragging up with Alt raised the velocity of both tracks' notes")
	_assert(is_equal_approx(a60.velocity - before_a, b72.velocity - before_b), "by the same amount")
	_assert(a60.start_tick == 0 and b72.start_tick == 960, "and moved nothing")
	_assert(recorded.size() == 1, "one undo step")
	await _finish(ctx)


func _test_escape_cancels_across_tracks() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	var recorded := _record(func():
		var gp := _context_center(ctx, "b", 72)
		_press(ctx, gp)
		editor.gestures.update_drag(editor.make_canvas_position_local(gp) + Vector2(gh.ticks_to_pixels(960), 0))
		_assert(b72.start_tick == 1920 and a60.start_tick == 960, "mid-drag both tracks' notes moved")
		editor.handle_key_input(esc)
		_release(ctx, gp))
	_assert(b72.start_tick == 960 and a60.start_tick == 0, "Esc put both back")
	_assert(recorded.is_empty(), "and recorded nothing")
	_assert(not editor.gestures.is_active() and ctx.midi.note_selection.size() == 2, "the gesture is over and the selection kept")
	# Resize too.
	var rect := _note_rect(ctx, "b", 72)
	var edge: Vector2 = ctx.midi.context_layer.get_global_transform() * Vector2(rect.end.x - 2.0, rect.get_center().y)
	recorded = _record(func():
		_press(ctx, edge)
		editor.gestures.update_resize(editor.make_canvas_position_local(edge) + Vector2(gh.ticks_to_pixels(960), 0))
		editor.handle_key_input(esc)
		_release(ctx, edge))
	_assert(b72.duration_ticks == 480 and a60.duration_ticks == 480 and recorded.is_empty(), "Esc cancels a resize across tracks too")
	await _finish(ctx)


func _test_drop_transfer_stays_on_the_track() -> void:
	var ctx := await _setup(true)
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	# A note far to the right in each first clip makes the clips longer than their instances, so
	# a note can be dragged past its instance's end (the played-window bound is the content).
	ctx.ci_a.clip.add_midi_note(ctx.project.allocate_note_id(), 70, MidiNoteData.from_midi_velocity(100), 6000, 480)
	ctx.ci_b.clip.add_midi_note(ctx.project.allocate_note_id(), 80, MidiNoteData.from_midi_velocity(100), 6000, 480)
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 62)])
	var a60 := _data(ctx, "a", 60)
	var grabbed: Object = editor.get_visual_note(a60.id)
	var start: Vector2 = grabbed.position + Vector2(2, 2)
	var recorded := _record(func():
		editor._on_drag_started(grabbed, start)
		editor._on_drag_updated(grabbed, start + Vector2(gh.ticks_to_pixels(4800), 0))
		editor._on_drag_ended(grabbed))
	_assert(not ctx.ci_a.clip.midi_notes.any(func(n): return n.note == 60), "A's note left A's first clip")
	_assert(ctx.ci_a2.clip.midi_notes.any(func(n): return n.note == 60 and n.start_tick == 960), "and landed in A's second clip")
	_assert(not ctx.ci_b.clip.midi_notes.any(func(n): return n.note == 62), "B's note left B's first clip")
	_assert(ctx.ci_b2.clip.midi_notes.any(func(n): return n.note == 62 and n.start_tick == 960), "and landed in B's second clip, not in A's")
	_assert(ctx.ci_a2.clip.midi_notes.size() == 1 and ctx.ci_b2.clip.midi_notes.size() == 1, "no note crossed to the other track")
	_assert(recorded.size() == 1, "the drag and both transfers are one undo step: %d" % recorded.size())
	recorded[0].undo()
	_assert(ctx.ci_a.clip.midi_notes.size() == 3 and ctx.ci_b.clip.midi_notes.size() == 3 and ctx.ci_a2.clip.midi_notes.is_empty()
		and ctx.ci_b2.clip.midi_notes.is_empty(), "undo moves them back")
	await _finish(ctx)


func _test_per_note_rules() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	var gh: Object = ctx.midi.grid_helper
	# A loops its first beat; B's instance is one bar with nothing after it.
	ctx.ci_a.set_loop(true, 0, 960)
	ctx.ci_a.set_duration(3840)
	_select(ctx, [_ref(ctx, "a", 60), _ref(ctx, "b", 72)])
	var a60 := _data(ctx, "a", 60)
	var b72 := _data(ctx, "b", 72)
	var grabbed: Object = editor.get_visual_note(a60.id)
	var start: Vector2 = grabbed.position + Vector2(2, 2)
	editor._on_drag_started(grabbed, start)
	editor._on_drag_updated(grabbed, start + Vector2(gh.ticks_to_pixels(1920), 0))
	_assert(a60.start_tick == 0, "A's note in the loop folds back into it: %d" % a60.start_tick)
	_assert(b72.start_tick == 960 + 1920, "while B's note, in the same drag, simply moves: %d" % b72.start_tick)
	editor._on_drag_updated(grabbed, start + Vector2(gh.ticks_to_pixels(96000), 0))
	_assert(b72.start_tick <= 3840 - b72.duration_ticks, "far right, B's note stops at the end of its instance's window: %d" % b72.start_tick)
	editor.gestures.cancel()
	await _finish(ctx)


func _test_ctrl_press_adds_and_drags() -> void:
	var ctx := await _setup()
	var editor: Object = ctx.editor
	# Ctrl+press on a focus note still toggles on release (and Ctrl+drag duplicates there).
	_select(ctx, [_ref(ctx, "b", 72)])
	var gp: Vector2 = editor.get_visual_note(_data(ctx, "a", 60).id).get_global_rect().get_center()
	_press(ctx, gp, true)
	_release(ctx, gp)
	_assert(ctx.midi.note_selection.size() == 2 and ctx.midi.note_selection.has(_data(ctx, "a", 60)),
		"Ctrl+click on a focus note adds it, as before")
	await _finish(ctx)
