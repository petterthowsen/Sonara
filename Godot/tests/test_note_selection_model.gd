# test_note_selection_model.gd
# NoteSelectionModel / NoteRef: the note selection as data. A note is one MidiNoteData, however
# many instances (a clip used twice) or loop passes show it; the model forgets notes that leave
# their clip; capture/restore survive rebinding the editor; undo of an edit restores the selection.
#
# Run: godot --headless --path Godot -s tests/test_note_selection_model.gd -- --test
extends TestBase

const LOOP := 1920

var _project_script: GDScript
var _editor_script: GDScript
var _instance_script: GDScript
var _grid_script: GDScript
var _ref_script: GDScript
var _model_script: GDScript


func suite_name() -> String:
	return "Note selection model"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_ref_script = load("res://clip_editor/note_editor/NoteRef.gd")
	_model_script = load("res://clip_editor/note_editor/NoteSelectionModel.gd")
	_test_dedup_of_shared_data()
	_test_loop_pass_is_kept_on_the_ref()
	_test_forgets_removed_notes()
	_test_toggle_and_range()
	await _test_editor_selects_shared_note_once()
	await _test_capture_restore_across_rebind()
	await _test_undo_restores_selection()
	await _test_shared_note_edited_once_and_one_undo_step()
	await _test_edits_cancel()


## A typed Array[NoteRef]. The scripts are loaded at runtime because naming them here would
## compile them before the autoloads they depend on exist.
func _arr(list: Array) -> Array:
	return Array(list, TYPE_OBJECT, &"RefCounted", _ref_script)


func _typed(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _instance_script)


## A track with two instances of one clip holding two notes (a linked clip).
func _linked_setup() -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var ci_a: Object = track.create_clip_instance(clip, 0, 3840)
	var ci_b: Object = track.create_clip_instance(clip, 3840, 3840)
	var n1: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 0, 480)
	var n2: Object = clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 960, 480)
	return {"project": project, "track": track, "clip": clip, "a": ci_a, "b": ci_b, "n1": n1, "n2": n2}


func _test_dedup_of_shared_data() -> void:
	var ctx := _linked_setup()
	var model: Object = _model_script.new()
	var changes := [0, 0]
	model.changed.connect(func(): changes[0] += 1)
	model.set_changed.connect(func(): changes[1] += 1)
	# The same note through both instances is one note; the first ref wins.
	model.select(_arr([_ref_script.new(ctx.a, ctx.n1), _ref_script.new(ctx.b, ctx.n1), _ref_script.new(ctx.b, ctx.n2)]))
	_assert(model.size() == 2, "a note shown by two instances is selected once, got %d" % model.size())
	_assert(model.ref_of(ctx.n1).instance == ctx.a, "the ref keeps the instance the note was first selected through")
	_assert(model.has(ctx.n1) and model.has(ctx.n2), "has() answers by note data")
	_assert(changes[0] == 1 and changes[1] == 1, "select emits changed and set_changed once: %s" % [changes])
	model.add(_arr([_ref_script.new(ctx.b, ctx.n1)]))
	_assert(model.size() == 2 and model.ref_of(ctx.n1).instance == ctx.a, "adding a selected note again changes nothing")
	_assert(model.clips().size() == 1 and model.clips()[0] == ctx.clip, "the notes share one clip to snapshot")
	_assert(model.tracks().size() == 1 and model.tracks()[0] == ctx.track, "and one track")
	model.select(_arr([_ref_script.new(ctx.a, ctx.n1)]), true)
	_assert(changes[0] == 2 and changes[1] == 3, "a silent select only emits set_changed: %s" % [changes])


func _test_loop_pass_is_kept_on_the_ref() -> void:
	var ctx := _linked_setup()
	ctx.a.set_loop(true, 0, LOOP)
	var through_pass: Object = _ref_script.new(ctx.a, ctx.n1, 1)
	_assert(through_pass.song_start() == LOOP and through_pass.song_end() == LOOP + 480,
		"a ref through pass 1 is positioned in that pass: %d-%d" % [through_pass.song_start(), through_pass.song_end()])
	var own: Object = _ref_script.new(ctx.a, ctx.n1)
	_assert(own.song_start() == 0 and own.song_end() == 480, "pass 0 is the note itself")
	var model: Object = _model_script.new()
	model.select(_arr([through_pass, own]))
	_assert(model.size() == 1 and model.refs[0].pass_index == 1, "the pass the user grabbed is the one kept")


func _test_forgets_removed_notes() -> void:
	var ctx := _linked_setup()
	var model: Object = _model_script.new()
	model.select(_arr([_ref_script.new(ctx.a, ctx.n1), _ref_script.new(ctx.a, ctx.n2)]))
	var set_changes := [0]
	model.set_changed.connect(func(): set_changes[0] += 1)
	ctx.clip.remove_midi_note(ctx.n1)
	_assert(model.size() == 1 and not model.has(ctx.n1) and model.has(ctx.n2), "a note removed from its clip leaves the selection")
	_assert(set_changes[0] == 1, "and the set change is announced")
	ctx.clip.remove_midi_note(ctx.n2)
	_assert(model.is_empty(), "so does the last one")
	var again: Object = ctx.clip.add_midi_note(ctx.project.allocate_note_id(), 67, MidiNoteData.from_midi_velocity(100), 0, 480)
	model.select(_arr([_ref_script.new(ctx.a, again)]))
	model.clear()
	var announced: int = set_changes[0]
	ctx.clip.remove_midi_note(again)
	_assert(set_changes[0] == announced, "a cleared model no longer listens to the clip")


func _test_toggle_and_range() -> void:
	var ctx := _linked_setup()
	var model: Object = _model_script.new()
	_assert(model.toggle(_ref_script.new(ctx.a, ctx.n1)), "toggle selects an unselected note")
	_assert(not model.toggle(_ref_script.new(ctx.b, ctx.n1)), "and unselects it through any instance")
	_assert(model.is_empty(), "nothing is left")
	model.set_range(960, 1920)
	_assert(model.has_range() and model.range == Vector2i(960, 1920), "the range is kept in editor ticks")
	model.set_range(1920, 960)
	_assert(not model.has_range(), "an end before the start clears the range")
	model.set_range(0, 480)
	model.clear()
	_assert(not model.has_range(), "clear drops the range too")


func _editor_for(ctx: Dictionary, model: Object = null) -> Object:
	var editor = _editor_script.new()
	editor.set_grid_helper(_grid_script.new())
	root.add_child(editor)
	if model:
		editor.use_selection_model(model)
	editor.bind_to_clips(_typed([ctx.a, ctx.b]), ctx.track)
	await process_frame
	return editor


func _test_editor_selects_shared_note_once() -> void:
	var ctx := _linked_setup()
	var editor = await _editor_for(ctx)
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	_assert(editor.get_all_visual_notes().size() == 4, "setup: two notes on two instances show four visuals")
	_assert(editor.selection_model.size() == 2, "Ctrl+A selects two notes, not four visuals")
	var lit := 0
	for vn in editor.get_all_visual_notes():
		lit += 1 if vn.is_selected else 0
	_assert(lit == 4, "every visual of a selected note is drawn selected")
	editor.selection_manager.clear_selection()
	lit = 0
	for vn in editor.get_all_visual_notes():
		lit += 1 if vn.is_selected else 0
	_assert(lit == 0, "and none once it is cleared")
	editor.queue_free()


func _test_capture_restore_across_rebind() -> void:
	var ctx := _linked_setup()
	var model: Object = _model_script.new()
	var editor = await _editor_for(ctx, model)
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	var state: Dictionary = model.capture()
	_assert(state.notes.size() == 2 and state.range == Vector2i(0, 1440), "capture holds the notes and the range: %s" % [state.range])

	# Rebind the editor to another (empty) track: the editor's visuals go away, the model stays.
	var other: Object = ctx.project.create_instrument_track("Other").track
	editor.unbind()
	editor.bind_to_clips(_typed([]), other)
	await process_frame
	_assert(model.size() == 2, "the selection is data: rebinding the editor does not touch it")
	model.clear()
	_assert(model.is_empty() and not model.has_range(), "cleared")
	model.restore(state)
	_assert(model.size() == 2 and model.range == Vector2i(0, 1440), "restore puts the notes and the range back")
	_assert(model.has(ctx.n1) and model.has(ctx.n2), "the same notes")

	# A captured note that no longer exists is skipped.
	ctx.clip.remove_midi_note(ctx.n2)
	model.clear()
	model.restore(state)
	_assert(model.size() == 1 and model.has(ctx.n1), "restore skips notes that are gone")

	editor.bind_to_clips(_typed([ctx.a, ctx.b]), ctx.track)
	await process_frame
	var visual: Object = editor.visual_of_ref(model.refs[0])
	_assert(visual != null and visual.midi_note_data == ctx.n1, "a restored ref resolves to the rebound editor's visual")
	editor.queue_free()


func _test_undo_restores_selection() -> void:
	var ctx := _linked_setup()
	var model: Object = _model_script.new()
	var editor = await _editor_for(ctx, model)
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	var range_before: Vector2i = model.range
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	editor._delete_selection()
	history_util.test_recorder = Callable()
	_assert(ctx.clip.midi_notes.is_empty() and model.is_empty(), "deleting removes the notes and empties the selection")
	_assert(recorded.size() == 1, "the delete is one undo step")
	recorded[0].undo()
	_assert(ctx.clip.midi_notes.size() == 2, "undo brings the notes back")
	_assert(model.size() == 2 and model.range == range_before, "and selects them again over the same range: %d notes" % model.size())
	for ref in model.refs:
		_assert(ref.data in ctx.clip.midi_notes, "a restored ref is a note of the clip")
	recorded[0].do()
	_assert(model.is_empty(), "redo deletes and unselects again")
	editor.queue_free()


## Run `call` with HistoryUtil recording into the returned array.
func _record(call: Callable) -> Array:
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	call.call()
	history_util.test_recorder = Callable()
	return recorded


## A note shown through two instances of one clip is one ref: a key edit changes it once and
## undoes in one step, with the selection restored.
func _test_shared_note_edited_once_and_one_undo_step() -> void:
	var ctx := _linked_setup()
	var editor = await _editor_for(ctx)
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	var pitch: int = ctx.n1.note
	var recorded := _record(func(): editor._move_selection_vertical(func(p: int) -> int: return p + 12))
	_assert(ctx.n1.note == pitch + 12, "a note on two instances moved one octave, not two: %d" % (ctx.n1.note - pitch))
	_assert(recorded.size() == 1, "and it is one undo step")
	recorded[0].undo()
	_assert(ctx.n1.note == pitch, "one undo puts it back")
	_assert(editor.selection_model.size() == 2, "and the selection is still both notes")
	recorded[0].do()
	_assert(ctx.n1.note == pitch + 12, "redo moves it again")

	# A tool edit: the callback sees each shared note once.
	var seen: Array = []
	recorded = _record(func(): editor._apply_selection_edit("Test", func(notes): seen.append_array(notes)))
	_assert(seen.size() == 2, "a selection edit sees each note once, got %d" % seen.size())

	# Drag state is keyed by the note, so the two instances share one entry.
	var vn = editor.get_all_visual_notes()[0]
	editor._on_drag_started(vn, vn.position)
	_assert(editor.gestures.drag_start_positions.size() == 2 and editor.gestures.drag_start_positions.has(vn.midi_note_data),
		"drag start positions are keyed by MidiNoteData, one per note")
	editor.gestures.cancel()
	editor.queue_free()


func _test_edits_cancel() -> void:
	var ctx := _linked_setup()
	var model: Object = _model_script.new()
	var editor = await _editor_for(ctx, model)
	editor.selection_manager.select_all(editor.get_all_visual_notes())
	var edits: Object = editor.edits
	var start: int = ctx.n1.start_tick
	var recorded := _record(func():
		edits.begin()
		for ref in model.refs:
			ref.data.start_tick += 240
		edits.refresh()
		_assert(editor.get_visual_note(ctx.n1.id).position.x > editor.ticks_to_pixels(start), "refresh moves the visuals mid-gesture")
		edits.cancel())
	_assert(ctx.n1.start_tick == start, "cancel puts the notes back")
	_assert(recorded.is_empty(), "and records nothing")
	_assert(model.size() == 2, "the selection is kept")
	_assert(is_equal_approx(editor.get_visual_note(ctx.n1.id).position.x, editor.ticks_to_pixels(start)), "and the visuals follow")
	_assert(not edits.is_open(), "the edit is closed")
	editor.queue_free()
