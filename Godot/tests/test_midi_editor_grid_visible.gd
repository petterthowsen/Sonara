# test_midi_editor_grid_visible.gd
# Regression test: the MIDI editor time grid stopped drawing because the
# GridRenderer node was saved with visible = false in ClipEditor.tscn
# (nothing else draws those lines and no code toggles its visibility).
#
# Run: godot --headless --path Godot -s tests/test_midi_editor_grid_visible.gd -- --test
extends TestBase

var _project_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "MIDI editor grid visibility"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	await _test_grid_renderer_visible_and_fed()


func _test_grid_renderer_visible_and_fed() -> void:
	var scene: PackedScene = load("res://clip_editor/ClipEditor.tscn")
	var editor: Control = scene.instantiate()
	root.add_child(editor)
	await process_frame

	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Riff")
	var inst: Object = pair.track.create_clip_instance(clip, 3840, 1920)

	editor.bound_clip_instance = inst
	editor.midi_editor.bind_to_clip_instance(inst)
	await process_frame
	await process_frame

	var renderer: Object = editor.midi_editor.grid_renderer
	_assert(renderer != null, "the MIDI editor has a GridRenderer node")
	if renderer == null:
		editor.queue_free()
		await process_frame
		return
	_assert(renderer.visible, "GridRenderer is visible in the scene (regression: saved hidden)")
	_assert(renderer.grid_helper != null, "GridRenderer receives the shared GridHelper")
	if renderer.grid_helper != null:
		var lines: Array = renderer.grid_helper.get_visible_grid_lines(0.0, 800.0)
		_assert(lines.size() > 0, "the grid helper yields lines for a visible window: %d" % lines.size())
	editor.queue_free()
	await process_frame
