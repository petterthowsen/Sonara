# test_note_clip_ownership.gd
# Regression tests for MIDI note ownership in track mode (multi-clip NoteEditor).
#
# The bug: NoteEditor's reactive _on_clip_note_added created a visual note for EVERY
# clip instance on the track, not just the instances of the clip that actually gained
# the note. Those phantom visuals claimed ownership, so the id -> clip lookup used by
# erase/resize/move resolved to the wrong clip. Clip.remove_midi_note() then silently
# returned false and the note could be placed but never removed.
#
# Run: godot --headless --path Godot -s tests/test_note_clip_ownership.gd -- --test
extends TestBase

var _project_script: GDScript
var _editor_script: GDScript
var _clip_instance_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Note clip ownership (track mode) tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_clip_instance_script = load("res://data/ClipInstance.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	await _test_note_added_only_to_its_own_clip()
	await _test_repeated_instances_of_same_clip_both_get_visuals()
	await _test_erase_removes_note_from_correct_clip()
	await _test_remove_from_wrong_clip_is_rejected()


## bind_to_clips() wants a typed instance array. The element type is applied at
## runtime here: naming the class in a `-s` test script breaks the global class
## lookup that Track.create_clip_instance() relies on, and its new() then fails.
func _typed(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _clip_instance_script)


## Track carrying two instances of two DIFFERENT clips, plus a bound NoteEditor.
## Returns {project, track, clip_a, clip_b, inst_a, inst_b, editor}.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var result: Dictionary = project.create_instrument_track("Violins")
	var track: Object = result.track

	var clip_a: Object = project.create_clip("2nd Violins 10")
	var clip_b: Object = project.create_clip("1st Violins Melody")
	var inst_a: Object = track.create_clip_instance(clip_a, 0, 3840)
	var inst_b: Object = track.create_clip_instance(clip_b, 3840, 3840)

	var editor = _editor_script.new()
	# Notes are positioned through the grid helper; without one every layout pass errors.
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	editor.bind_to_clips(_typed([inst_a, inst_b]), track)
	await process_frame

	return {
		"project": project, "track": track,
		"clip_a": clip_a, "clip_b": clip_b,
		"inst_a": inst_a, "inst_b": inst_b,
		"editor": editor,
	}


## Every VisualNote in the editor carrying `note_id`.
func _visuals_for(editor: Object, note_id: int) -> Array:
	var out: Array = []
	for child in editor.get_children():
		if child.get("midi_note_data") != null and child.midi_note_data.id == note_id:
			out.append(child)
	return out


func _teardown(ctx: Dictionary) -> void:
	ctx.editor.queue_free()


func _test_note_added_only_to_its_own_clip() -> void:
	var ctx := await _setup()
	var note_id: int = ctx.project.allocate_note_id()
	ctx.clip_a.add_midi_note(note_id, 48, 100, 240, 240)
	await process_frame

	var visuals := _visuals_for(ctx.editor, note_id)
	_assert(visuals.size() == 1, "note added to one clip makes exactly one visual, not one per clip on the track: %d" % visuals.size())
	if visuals.size() == 1:
		var ci: Object = visuals[0].get_meta("clip_instance")
		_assert(ci == ctx.inst_a, "the visual belongs to the clip that gained the note")
	_teardown(ctx)


func _test_repeated_instances_of_same_clip_both_get_visuals() -> void:
	var ctx := await _setup()
	# A second instance of clip_a: the same note content, played twice on the track.
	var inst_a2: Object = ctx.track.create_clip_instance(ctx.clip_a, 7680, 3840)
	ctx.editor.bind_to_clips(_typed([ctx.inst_a, ctx.inst_b, inst_a2]), ctx.track)
	await process_frame

	var note_id: int = ctx.project.allocate_note_id()
	ctx.clip_a.add_midi_note(note_id, 48, 100, 240, 240)
	await process_frame

	var visuals := _visuals_for(ctx.editor, note_id)
	_assert(visuals.size() == 2, "both instances of the same clip show the note: %d" % visuals.size())
	_teardown(ctx)


func _test_erase_removes_note_from_correct_clip() -> void:
	var ctx := await _setup()
	var note_id: int = ctx.project.allocate_note_id()
	ctx.clip_a.add_midi_note(note_id, 48, 100, 240, 240)
	await process_frame

	var visuals := _visuals_for(ctx.editor, note_id)
	_assert(visuals.size() == 1, "setup: one visual for the placed note")
	if visuals.size() != 1:
		_teardown(ctx)
		return

	ctx.editor.erase_note(visuals[0])
	await process_frame

	_assert(ctx.clip_a.midi_notes.size() == 0, "erasing a placed note removes it from its clip")
	_assert(_visuals_for(ctx.editor, note_id).is_empty(), "erasing a placed note removes its visual")
	_teardown(ctx)


func _test_remove_from_wrong_clip_is_rejected() -> void:
	var ctx := await _setup()
	var note_id: int = ctx.project.allocate_note_id()
	var note: Object = ctx.clip_a.add_midi_note(note_id, 48, 100, 240, 240)

	_assert(ctx.clip_b.remove_midi_note(note) == false, "removing a note via a clip that doesn't own it reports failure")
	_assert(ctx.clip_a.midi_notes.size() == 1, "the note survives a removal aimed at the wrong clip")
	_teardown(ctx)
