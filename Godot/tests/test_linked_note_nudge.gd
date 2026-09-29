# test_linked_note_nudge.gd
# Regression tests for keyboard nudging in track mode with linked clip instances.
#
# The bug: every instance of a clip on the track gets its own VisualNote, all bound to
# the same MidiNoteData. Select-all + Ctrl+Up stepped the shared note once per visual,
# so a clip used three times moved 36 semitones instead of 12. Left/Right had the
# same problem with ticks.
#
# Run: godot --headless --path Godot -s tests/test_linked_note_nudge.gd -- --test
extends TestBase

var _project_script: GDScript
var _editor_script: GDScript
var _clip_instance_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Linked-instance note nudge (track mode) tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_clip_instance_script = load("res://data/ClipInstance.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	await _test_vertical_nudge_moves_shared_note_once()
	await _test_horizontal_nudge_moves_shared_note_once()


## See test_note_clip_ownership.gd for why the element type is applied at runtime.
func _typed(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _clip_instance_script)


## Track with three instances of one clip holding one note, all notes selected.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var instances: Array = []
	for i in 3:
		instances.append(track.create_clip_instance(clip, i * 3840, 3840))

	var note_id: int = project.allocate_note_id()
	clip.add_midi_note(note_id, 60, 100, 960, 240)

	var editor = _editor_script.new()
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	editor.bind_to_clips(_typed(instances), track)
	await process_frame

	editor.selection_manager.select_all(editor.get_all_visual_notes())
	return {"clip": clip, "editor": editor, "note": clip.midi_notes[0]}


func _test_vertical_nudge_moves_shared_note_once() -> void:
	var ctx := await _setup()
	_assert(ctx.editor.selection_manager.selected_notes.size() == 3, "setup: one selected visual per instance")
	ctx.editor._move_selection_vertical(12)
	_assert(ctx.note.note == 72, "octave up moves the shared note 12 semitones, not once per instance: %d" % ctx.note.note)
	ctx.editor.queue_free()


func _test_horizontal_nudge_moves_shared_note_once() -> void:
	var ctx := await _setup()
	ctx.editor._move_selection_horizontal(240)
	_assert(ctx.note.start_tick == 1200, "nudge right moves the shared note one step, not once per instance: %d" % ctx.note.start_tick)
	ctx.editor.queue_free()
