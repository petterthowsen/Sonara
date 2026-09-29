# test_clip_placement_drag.gd
# Headless test for placing a clip with a double-click: the new clip is selected and moved by the
# arranger's clip drag while the placing press is held, and the release records the move.
# Headless there is no held mouse button, so the test starts the drag the way
# TimelineTrack._on_double_click does and drives it like Timeline._input.
#
# Run: godot --headless --path Godot -s tests/test_clip_placement_drag.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"


func suite_name() -> String:
	return "Clip placement drag"


func run_tests() -> void:
	await _test_new_clip_drags_into_place()


func _test_new_clip_drags_into_place() -> void:
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	await process_frame
	var project: Object = load("res://data/Project.gd").new()
	var track: Object = project.create_instrument_track("A").track
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame

	var timeline: Control = arranger.timeline
	var instance: Object = load("res://history/ClipActions.gd").create_clip(project, track, 960, 3840, "A 1")
	_assert(instance != null, "double-click creates a clip")
	timeline.begin_placement_drag(instance)
	_assert(timeline._drag_active, "placing a clip starts a move drag")
	_assert(timeline.clip_selection_manager.get_selected_instances() == [instance], "new clip is selected")

	var undo_before: int = editor.history.undo_count()
	timeline._drag_to(1920, 0)
	_assert(instance.start_ticks == 2880, "clip follows the drag (%d)" % instance.start_ticks)
	timeline._finish_drag()
	_assert(not timeline._drag_active, "release ends the drag")
	_assert(editor.history.undo_count() == undo_before + 1, "the move is one undo step")
	editor.history.undo()
	_assert(instance.start_ticks == 960, "undo returns the clip to where it was placed")

	root.free()
	editor.free()
	await process_frame
