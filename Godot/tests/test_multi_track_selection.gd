# test_multi_track_selection.gd
# Phase 3 of docs/multi-track-note-editing-plan.md: the note selection spans tracks. Box select,
# Ctrl+click, Ctrl+Alt+A and the pitch header pick notes of every editable track; the focus
# switch keeps the selection; a track that is hidden or no longer editable drops its notes;
# edits act on all selected notes as one undo step.
#
# Run: godot --headless --path Godot -s tests/test_multi_track_selection.gd -- --test
extends TestBase

const BIG := Rect2(-100000, -100000, 200000, 200000)

var _project_script: GDScript
var _track_script: GDScript
var _instance_script: GDScript
var _placement_script: GDScript
var _clip_editor_scene: PackedScene


func suite_name() -> String:
	return "Multi-track note selection"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_placement_script = load("res://clip_editor/note_editor/NotePlacement.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	await _test_box_select_over_editable_tracks()
	await _test_ctrl_click_adds_without_focus_switch()
	await _test_plain_press_on_selected_context_note()
	await _test_focus_switch_keeps_selection()
	await _test_unavailable_tracks_drop_their_notes()
	await _test_delete_across_tracks_is_one_undo_step()
	await _test_undo_after_focus_switch()
	await _test_select_all_tracks_and_row_select()
	await _test_key_edit_across_tracks()
	await _test_transfer_needs_one_track()
	await _test_queries_follow_loop_and_window_rules()


func _typed_tracks(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _track_script)


func _typed_instances(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


## A ClipEditor in track mode over A, B and C (C is visible but not editable). Every clip
## instance starts at tick 0. Notes: A 60 and 64, B 62 and 72, C 65.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var out := {"project": project, "tracks": [], "cis": []}
	var pitches := {"A": [60, 64], "B": [62, 72], "C": [65]}
	for key in ["A", "B", "C"]:
		var pair: Dictionary = project.create_instrument_track(key)
		var clip: Object = project.create_clip("Clip" + key)
		project.add_clip(clip)
		var ci: Object = pair.track.create_clip_instance(clip, 0, 3840)
		for i in pitches[key].size():
			clip.add_midi_note(project.allocate_note_id(), pitches[key][i], MidiNoteData.from_midi_velocity(100), i * 960, 480)
		out[key.to_lower()] = pair.track
		out["ci_" + key.to_lower()] = ci
		out.tracks.append(pair.track)
		out.cis.append(ci)
	var clip_editor: Control = _clip_editor_scene.instantiate()
	root.add_child(clip_editor)
	clip_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clip_editor.size = Vector2(1200, 700)
	await process_frame
	var midi: Object = clip_editor.midi_editor
	var clips := _typed_instances(out.cis)
	midi.bind_to_clips(clips, _typed_tracks(out.tracks))
	midi.set_track_views(_typed_tracks(out.tracks), clips)
	midi.editable_tracks = _typed_tracks([out.a, out.b])
	midi.focus_track = out.a
	await process_frame
	await process_frame
	out["clip_editor"] = clip_editor
	out["midi"] = midi
	out["editor"] = midi.note_editors[0]
	out["clips"] = clips
	return out


func _finish(ctx: Dictionary) -> void:
	ctx.clip_editor.queue_free()
	await process_frame


func _data(ctx: Dictionary, key: String, pitch: int) -> Object:
	for nd in ctx["ci_" + key].clip.midi_notes:
		if nd.note == pitch:
			return nd
	return null


func _ref(ctx: Dictionary, key: String, pitch: int) -> Object:
	return load("res://clip_editor/note_editor/NoteRef.gd").new(ctx["ci_" + key], _data(ctx, key, pitch), 0)


## Global centre of a note of a track the context layer draws.
func _context_center(ctx: Dictionary, key: String, pitch: int) -> Vector2:
	var nd := _data(ctx, key, pitch)
	var rect: Rect2 = _placement_script.note_rect(nd, ctx["ci_" + key].content_origin_ticks(), ctx.midi.lane_layout, ctx.midi.grid_helper)
	return ctx.midi.context_layer.get_global_transform() * rect.get_center()


func _mouse(gp: Vector2, pressed: bool, ctrl := false) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	ev.global_position = gp
	ev.position = gp
	return ev


func _click(ctx: Dictionary, gp: Vector2, ctrl := false) -> void:
	var midi: Object = ctx.midi
	midi._handle_left_mouse_press(ctx.editor.make_canvas_position_local(gp), _mouse(gp, true, ctrl))
	midi._handle_left_mouse_release(ctx.editor.make_canvas_position_local(gp), _mouse(gp, false, ctrl))


func _record(call: Callable) -> Array:
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	call.call()
	history_util.test_recorder = Callable()
	return recorded


func _test_box_select_over_editable_tracks() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var editor: Object = ctx.editor
	var sm: Object = editor.selection_manager
	var notes: Array = midi._notes_in_box(editor, BIG)
	_assert(notes.size() == 4, "a box over everything finds A's and B's 4 notes, not C's (view-only): %d" % notes.size())
	sm.start_box_selection(Vector2.ZERO)
	sm.end_box_selection(notes)
	var model: Object = midi.note_selection
	_assert(model.size() == 4 and model.tracks().size() == 2, "box select puts notes of two tracks in the selection")
	_assert(not model.has(_data(ctx, "c", 65)), "the view-only track's note is not selected")
	_assert(model.range.y > model.range.x, "the range covers the notes: %s" % [model.range])
	# A smaller box: only the pitch band of 72 (B's note, a context note).
	var rect: Rect2 = _placement_script.note_rect(_data(ctx, "b", 72), 0, midi.lane_layout, midi.grid_helper)
	var small: Array = midi._notes_in_box(editor, editor.get_global_transform().affine_inverse() * (midi.context_layer.get_global_transform() * rect.grow(-2.0)))
	_assert(small.size() == 1 and small[0].data == _data(ctx, "b", 72), "a small box finds just B's note")
	await _finish(ctx)


func _test_ctrl_click_adds_without_focus_switch() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	var picked: Array = []
	midi.note_track_picked.connect(func(t): picked.append(t))
	model.select(Array([_ref(ctx, "a", 60)], TYPE_OBJECT, &"RefCounted", load("res://clip_editor/note_editor/NoteRef.gd")))
	_click(ctx, _context_center(ctx, "b", 72), true)
	_assert(midi.focus_track == ctx.a and picked.is_empty(), "Ctrl+click on B's note keeps the focus on A")
	_assert(model.size() == 2 and model.has(_data(ctx, "b", 72)), "and adds the note to the selection")
	_click(ctx, _context_center(ctx, "b", 72), true)
	_assert(model.size() == 1 and not model.has(_data(ctx, "b", 72)), "Ctrl+click again takes it out")
	await _finish(ctx)


func _test_plain_press_on_selected_context_note() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	var refs := Array([_ref(ctx, "a", 60), _ref(ctx, "b", 72)], TYPE_OBJECT, &"RefCounted", load("res://clip_editor/note_editor/NoteRef.gd"))
	model.select(refs)
	var gp := _context_center(ctx, "b", 72)
	midi._handle_left_mouse_press(ctx.editor.make_canvas_position_local(gp), _mouse(gp, true))
	_assert(model.size() == 2 and midi.focus_track == ctx.a, "pressing a selected note of B keeps the selection and the focus")
	midi._handle_left_mouse_release(ctx.editor.make_canvas_position_local(gp), _mouse(gp, false))
	_assert(midi.focus_track == ctx.b and model.size() == 1 and model.has(_data(ctx, "b", 72)),
		"releasing without a drag selects it alone and moves the focus (REQ-034)")
	# A plain press on an unselected note of another track selects it alone at once.
	model.select(Array([_ref(ctx, "b", 62)], TYPE_OBJECT, &"RefCounted", load("res://clip_editor/note_editor/NoteRef.gd")))
	await _finish(ctx)


func _test_focus_switch_keeps_selection() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	var range_before: Vector2i = model.range
	midi.focus_track = ctx.b
	await process_frame
	_assert(model.size() == 4 and model.range == range_before, "switching the focus keeps the notes and the range")
	var lit := 0
	for vn in ctx.editor.get_all_visual_notes():
		lit += 1 if vn.is_selected else 0
	_assert(lit == 2, "B's own selected notes are drawn selected after the rebind: %d" % lit)
	midi.focus_track = ctx.a
	await process_frame
	_assert(model.size() == 4, "and back")
	await _finish(ctx)


func _test_unavailable_tracks_drop_their_notes() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	midi.editable_tracks = _typed_tracks([ctx.a])
	_assert(model.size() == 2 and model.tracks() == [ctx.a], "a track that stops being editable drops its notes")
	midi.editable_tracks = _typed_tracks([ctx.a, ctx.b])
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	midi.set_track_views(_typed_tracks([ctx.a, ctx.c]), ctx.clips)
	_assert(model.size() == 2 and model.tracks() == [ctx.a], "so does a track that is hidden")
	await _finish(ctx)


func _test_delete_across_tracks_is_one_undo_step() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	var recorded := _record(func(): ctx.editor._delete_selection())
	_assert(ctx.ci_a.clip.midi_notes.is_empty() and ctx.ci_b.clip.midi_notes.is_empty(), "Delete removed the notes of both tracks")
	_assert(ctx.ci_c.clip.midi_notes.size() == 1, "and left the view-only track alone")
	_assert(recorded.size() == 1 and model.is_empty(), "one undo step, nothing selected")
	recorded[0].undo()
	_assert(ctx.ci_a.clip.midi_notes.size() == 2 and ctx.ci_b.clip.midi_notes.size() == 2, "one undo brings both tracks' notes back")
	_assert(model.size() == 4 and model.tracks().size() == 2, "and selects them again")
	await _finish(ctx)


func _test_undo_after_focus_switch() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	var recorded := _record(func(): ctx.editor._delete_selection())
	midi.focus_track = ctx.b
	await process_frame
	recorded[0].undo()
	_assert(model.size() == 4, "undo after a focus switch restores the selection on both tracks: %d" % model.size())
	_assert(midi.focus_track == ctx.b, "and leaves the focus where it is")
	await _finish(ctx)


func _key(keycode: Key, ctrl: bool, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	event.pressed = true
	return event


func _test_select_all_tracks_and_row_select() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var model: Object = midi.note_selection
	ctx.editor.handle_key_input(_key(KEY_A, true))
	_assert(model.size() == 2 and model.tracks() == [ctx.a], "Ctrl+A selects the focus track only")
	ctx.editor.handle_key_input(_key(KEY_A, true, true))
	_assert(model.size() == 4 and model.tracks().size() == 2, "Ctrl+Alt+A (notes_select_all_tracks) selects every editable track")
	model.clear()
	midi._select_pitch(62, false)
	_assert(model.size() == 1 and model.has(_data(ctx, "b", 62)), "a pitch header click finds the note on B too")
	midi._select_pitch(60, true)
	_assert(model.size() == 2, "and adds when asked")
	await _finish(ctx)


func _test_key_edit_across_tracks() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	var a60: Object = _data(ctx, "a", 60)
	var b72: Object = _data(ctx, "b", 72)
	var recorded := _record(func(): ctx.editor._transpose_selection(1))
	_assert(a60.note == 61 and b72.note == 73, "transpose moves the notes of both tracks")
	_assert(_data(ctx, "c", 65) != null, "the view-only note is untouched")
	_assert(recorded.size() == 1, "as one undo step")
	recorded[0].undo()
	_assert(a60.note == 60 and b72.note == 72, "which undoes both")
	await _finish(ctx)


func _test_transfer_needs_one_track() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	midi.note_selection.select(Array([_ref(ctx, "a", 60)], TYPE_OBJECT, &"RefCounted", load("res://clip_editor/note_editor/NoteRef.gd")))
	_assert(not ctx.editor.selection_spans_tracks() and ctx.editor.can_transfer(), "one track: Transfer Notes is available")
	ctx.editor.selection_manager.select_all(midi._notes_in_box(ctx.editor, BIG))
	_assert(ctx.editor.selection_spans_tracks() and not ctx.editor.can_transfer(), "two tracks: it is off")
	_assert(ctx.editor.split_voices() == 0, "and so is Split Voices")
	await _finish(ctx)


func _test_queries_follow_loop_and_window_rules() -> void:
	var ctx := await _setup()
	var midi: Object = ctx.midi
	var layer: Object = midi.context_layer
	# A looped instance on A: two bars, loop of half a bar; the instance's played window trims
	# content before tick 0 of its offset.
	ctx.ci_a.set_loop(true, 0, 1920)
	ctx.ci_a.set_position(0)
	ctx.ci_a.set_duration(7680)
	var all: Array = layer.notes_of([ctx.a])
	var by_note := {}
	for ref in all:
		by_note[ref.data] = ref
	_assert(all.size() == 2 and by_note.size() == 2, "notes_of lists each note once, repeats included in the pass search: %d" % all.size())
	# A box over the third pass only: the note that plays there is found through that pass.
	var gh: Object = midi.grid_helper
	var box := Rect2(gh.ticks_to_pixels(2 * 1920), -1000.0, gh.ticks_to_pixels(1920) - 1.0, 100000.0)
	var found: Array = layer.notes_in_rect(box, [ctx.a])
	var passes_ok := not found.is_empty()
	for ref in found:
		passes_ok = passes_ok and ref.pass_index >= 1
	_assert(passes_ok, "a box over a later loop pass finds the notes through that pass")
	_assert(layer.notes_in_range(0, 100, [ctx.a, ctx.b]).size() == 2, "notes_in_range finds what starts in the range on both tracks")
	await _finish(ctx)
