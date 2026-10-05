# test_loop_repeats.gd
# Track mode: the loop repeats of a looped instance are notes like any other. Each later pass
# shows the notes it plays as VisualNotes (labels and all) bound to the same MidiNoteData, so
# they can be hit, box-selected, copied, dragged, resized and erased, and notes can be placed
# and pasted onto them (landing in the loop region). Edits apply to the note once.
#
# Run: godot --headless --path Godot -s tests/test_loop_repeats.gd -- --test
extends TestBase

const LOOP := 1920  # half a bar at 960 PPQ; the instance is two bars, so four passes

var _project_script: GDScript
var _editor_script: GDScript
var _instance_script: GDScript
var _grid_script: GDScript


func suite_name() -> String:
	return "Loop repeats in the note editor"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_grid_script = load("res://components/GridHelper.gd")
	await _test_repeats_are_notes()
	await _test_hit_and_resize_handle()
	await _test_box_selection_and_copy()
	await _test_place_on_repeat()
	await _test_drag_repeat_wraps_and_follows_live()
	await _test_edits_apply_once()
	await _test_paste_onto_repeat()
	await _test_loop_changes_rebuild_repeats()
	_test_context_layer_hits_repeats()


func _typed(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _instance_script)


## One track with a looped instance (0..7680, loop 0..1920). Notes: C3 at 0 (480 long), E3 at
## 1440 (960 long, so the loop wrap cuts its repeats to 480) and G3 at 2400, past the loop end,
## which never plays.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var ci: Object = track.create_clip_instance(clip, 0, 7680)
	ci.set_loop(true, 0, LOOP)
	var c3: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 0, 480)
	var e3: Object = clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 1440, 960)
	clip.add_midi_note(project.allocate_note_id(), 67, MidiNoteData.from_midi_velocity(100), 2400, 240)
	var editor = _editor_script.new()
	editor.set_grid_helper(_grid_script.new())
	root.add_child(editor)
	editor.bind_to_clips(_typed([ci]), track)
	await process_frame
	return {"project": project, "track": track, "clip": clip, "ci": ci, "editor": editor, "c3": c3, "e3": e3}


func _visuals_of(editor, nd) -> Array:
	var out := []
	for vn in editor.get_all_visual_notes():
		if vn.midi_note_data == nd:
			out.append(vn)
	return out


func _repeat(editor, nd, pass_index: int):
	for vn in _visuals_of(editor, nd):
		if vn.repeat_pass == pass_index:
			return vn
	return null


func _at(editor, tick: int, pitch: int, dx: float = 2.0) -> Vector2:
	return Vector2(editor.grid_helper.ticks_to_pixels(tick) + dx, editor.layout.pitch_to_y(pitch) + 2.0)


func _test_repeats_are_notes() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var gh = editor.grid_helper
	var c3_visuals := _visuals_of(editor, ctx.c3)
	_assert(c3_visuals.size() == 4, "C3 shows in all four passes, got %d" % c3_visuals.size())
	var r2 = _repeat(editor, ctx.c3, 2)
	_assert(r2 != null and is_equal_approx(r2.position.x, gh.ticks_to_pixels(2 * LOOP)), "the second repeat starts at its pass")
	_assert(r2 != null and r2.label.text == "C3" and r2.label.visible, "a repeat carries the note label")
	_assert(r2 != null and r2.get_theme_stylebox("panel") == _repeat(editor, ctx.c3, 0).get_theme_stylebox("panel") if _repeat(editor, ctx.c3, 0) else false,
		"a repeat is drawn with the note's own style")
	var e3_repeat = _repeat(editor, ctx.e3, 1)
	_assert(e3_repeat != null and is_equal_approx(e3_repeat.size.x, gh.ticks_to_pixels(480)), "a repeat ends at the loop wrap")
	var pos: Dictionary = editor.get_note_song_position(e3_repeat)
	_assert(pos.start_tick == LOOP + 1440 and pos.end_tick == 2 * LOOP, "repeat song span %s" % [pos])
	var g3_visuals := 0
	for vn in editor.get_all_visual_notes():
		if vn.midi_note_data.note == 67:
			g3_visuals += 1
	_assert(g3_visuals == 0, "a note past the loop end never plays, so it has no visual")
	editor.queue_free()


func _test_hit_and_resize_handle() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var gh = editor.grid_helper
	var hit = editor.get_note_at_position(_at(editor, LOOP + 100, 60))
	_assert(hit != null and hit.repeat_pass == 1 and hit.midi_note_data == ctx.c3, "a click on a repeat hits that repeat")
	_assert(editor.get_note_at_position(_at(editor, LOOP + 1000, 60)) == null, "empty space in a pass is not a hit")
	var edge := Vector2(gh.ticks_to_pixels(2 * LOOP) - 2.0, editor.layout.pitch_to_y(64) + 2.0)
	var cut = editor.get_note_at_position(edge)
	_assert(cut != null and cut._is_over_resize_handle(edge - cut.position), "the cut-off repeat's right edge is a resize handle")
	editor.queue_free()


func _test_box_selection_and_copy() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var gh = editor.grid_helper
	var sm = editor.selection_manager
	# A box over the third pass only, across both played pitches.
	var box := Rect2(Vector2(gh.ticks_to_pixels(2 * LOOP), 0), Vector2(gh.ticks_to_pixels(LOOP) - 1.0, editor.layout.total_height()))
	sm.start_box_selection(box.position)
	sm.update_box_selection(box.end)
	sm.end_box_selection(editor.get_notes_in_box(sm.box_selection_rect))
	_assert(sm.selected_notes.size() == 2, "the box selects the two notes of that pass, got %d" % sm.selected_notes.size())
	var passes_ok := true
	for vn in sm.selected_notes:
		passes_ok = passes_ok and vn.repeat_pass == 2 and vn.is_selected
	_assert(passes_ok, "the selected visuals are the pass's repeats, drawn selected")
	_assert(_repeat(editor, ctx.c3, 0).is_selected == false, "the first pass keeps its own selection state")
	var snapshot = sm.snapshot_selection()
	var starts := []
	for nd in snapshot.notes:
		starts.append(nd.start_tick)
	starts.sort()
	_assert(snapshot.start_tick == 2 * LOOP and starts == [0, 1440], "copy is relative to the range in that pass: %s" % [starts])
	editor.queue_free()


func _test_place_on_repeat() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var placed = editor.place_note_at_position(_at(editor, 3 * LOOP + 960, 62))
	_assert(placed != null and placed.repeat_pass == 3, "the placed note is the visual under the mouse")
	var nd = placed.midi_note_data if placed else null
	_assert(nd != null and nd.start_tick == 960, "placing in a repeat adds the note to the loop region, at %s" % [nd.start_tick if nd else "-"])
	_assert(nd != null and _visuals_of(editor, nd).size() == 4, "and it shows in every pass")
	editor.queue_free()


func _test_drag_repeat_wraps_and_follows_live() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var gh = editor.grid_helper
	var grabbed = _repeat(editor, ctx.c3, 1)
	var start := _at(editor, LOOP + 100, 60)
	editor._on_drag_started(grabbed, start)
	# Right by 960: still in the loop, and every pass follows before the drop.
	editor._on_drag_updated(grabbed, start + Vector2(gh.ticks_to_pixels(960), 0))
	_assert(ctx.c3.start_tick == 960, "dragged within the loop, got %d" % ctx.c3.start_tick)
	var r2 = _repeat(editor, ctx.c3, 2)
	_assert(r2 != null and is_equal_approx(r2.position.x, gh.ticks_to_pixels(2 * LOOP + 960)), "other passes move live")
	# Right by 1920 + 960 in total: past the loop end, the note comes in again at the start.
	editor._on_drag_updated(grabbed, start + Vector2(gh.ticks_to_pixels(LOOP + 960), 0))
	_assert(ctx.c3.start_tick == 960, "past the loop end it folds back into the loop, got %d" % ctx.c3.start_tick)
	editor._on_drag_ended(editor.dragging_note)
	_assert(ctx.clip.midi_notes.has(ctx.c3) and ctx.c3.start_tick == 960, "the drop keeps the note in its clip")
	editor.queue_free()


func _test_edits_apply_once() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var sm = editor.selection_manager
	sm.select_all(editor.get_all_visual_notes())
	_assert(sm.selected_notes.size() == 8, "Ctrl+A selects every shown visual, got %d" % sm.selected_notes.size())
	editor._move_selection_vertical(1)
	_assert(ctx.c3.note == 61 and ctx.e3.note == 65, "Up moves each note one semitone, not once per pass")
	editor._move_selection_horizontal(480)
	_assert(ctx.c3.start_tick == 480, "Right moves each note once, got %d" % ctx.c3.start_tick)
	_assert(ctx.e3.start_tick == 0, "a note nudged past the loop end folds to the start, got %d" % ctx.e3.start_tick)
	sm.select_all(editor.get_all_visual_notes())
	editor._delete_selection()
	await process_frame
	_assert(ctx.clip.midi_notes.size() == 1, "Delete removes each note once, leaving the unplayed one")
	_assert(editor.get_all_visual_notes().is_empty() and sm.selected_notes.is_empty(), "and every visual and selection entry")
	editor.queue_free()


func _test_paste_onto_repeat() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var sm = editor.selection_manager
	sm.select_note(_repeat(editor, ctx.c3, 1))
	editor.copy_to_clipboard()
	editor._paste_at_position(3 * LOOP + 960)
	var pasted: Array = sm.selected_notes
	_assert(pasted.size() == 1 and pasted[0].repeat_pass == 3, "the pasted note is selected where it was pasted")
	_assert(pasted.size() == 1 and pasted[0].midi_note_data.start_tick == 960, "pasting into a repeat lands in the loop region")
	editor.queue_free()


func _test_loop_changes_rebuild_repeats() -> void:
	var ctx := await _setup()
	var editor = ctx.editor
	var sm = editor.selection_manager
	sm.select_note(_repeat(editor, ctx.c3, 3))
	ctx.ci.set_loop(true, 0, 3840)
	_assert(_visuals_of(editor, ctx.c3).size() == 2, "a longer loop means fewer passes")
	_assert(sm.selected_notes.is_empty(), "a freed repeat leaves the selection")
	ctx.ci.set_loop(false, 0, 3840)
	await process_frame
	_assert(_visuals_of(editor, ctx.c3).size() == 1, "no repeats once looping is off")
	_assert(editor.get_note_at_position(_at(editor, 3840 + 100, 60)) == null, "and nothing to hit where they were")
	editor.queue_free()


func _test_context_layer_hits_repeats() -> void:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Other").track
	var clip: Object = project.create_clip("Loop")
	var ci: Object = track.create_clip_instance(clip, 0, 7680)
	ci.set_loop(true, 0, LOOP)
	var nd: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 0, 480)
	var layer: Control = load("res://clip_editor/note_editor/ContextNotesLayer.gd").new()
	var layout: Object = load("res://clip_editor/LaneLayout.gd").chromatic(20.0)
	var grid: Object = _grid_script.new()
	layer.layout = layout
	layer.grid_helper = grid
	var tracks := Array([track], TYPE_OBJECT, &"RefCounted", load("res://data/Track.gd"))
	layer.set_tracks(tracks, tracks)
	var hit: Dictionary = layer.note_at(Vector2(grid.ticks_to_pixels(2 * LOOP + 100), layout.pitch_to_y(60) + 2.0))
	_assert(hit.get("data") == nd and hit.get("instance") == ci, "another track's repeat can be clicked")
	_assert(layer.note_at(Vector2(grid.ticks_to_pixels(2 * LOOP + 1000), layout.pitch_to_y(60) + 2.0)).is_empty(),
		"empty space in a pass is not a hit")
	layer.free()
