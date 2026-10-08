# test_note_drag_alt_axis.gd
# Note drag with Alt held (setting midi_editor/note_drag_modifiers = "Alt: length and velocity"):
# the drag stays pending until the mouse moves ALT_AXIS_THRESHOLD, then the dominant axis picks
# length (sideways) or velocity (up, down) and keeps it until Alt is released.
#
# Run: godot --headless --path Godot -s tests/test_note_drag_alt_axis.gd -- --test
extends TestBase

var _editor: Object


func suite_name() -> String:
	return "Note drag Alt axis"


func run_tests() -> void:
	_editor = load("res://clip_editor/note_editor/NoteEditor.gd").new()
	root.add_child(_editor)
	await process_frame
	var t: float = _editor.ALT_AXIS_THRESHOLD
	_editor.drag_start_mouse_pos = Vector2(100, 100)

	_editor.last_drag_mode = _editor.DragMode.POSITION
	_assert(_editor._alt_axis_mode(Vector2(100, 100)) == _editor.DragMode.PENDING, "Alt pressed mid-drag starts pending")

	_editor.last_drag_mode = _editor.DragMode.PENDING
	_assert(_editor._alt_axis_mode(Vector2(100 + t - 1, 100)) == _editor.DragMode.PENDING, "below the threshold stays pending")
	_assert(_editor._alt_axis_mode(Vector2(100 + t + 4, 100 + 2)) == _editor.DragMode.RESIZE, "sideways movement is length")
	_assert(_editor._alt_axis_mode(Vector2(100 - t - 4, 100 + 2)) == _editor.DragMode.RESIZE, "sideways to the left is length")
	_assert(_editor._alt_axis_mode(Vector2(100 + 2, 100 - t - 4)) == _editor.DragMode.VELOCITY, "upward movement is velocity")
	_assert(_editor._alt_axis_mode(Vector2(100 + 2, 100 + t + 4)) == _editor.DragMode.VELOCITY, "downward movement is velocity")

	_editor.last_drag_mode = _editor.DragMode.VELOCITY
	_assert(_editor._alt_axis_mode(Vector2(400, 100)) == _editor.DragMode.VELOCITY, "the axis stays locked once picked")
	_editor.last_drag_mode = _editor.DragMode.RESIZE
	_assert(_editor._alt_axis_mode(Vector2(100, 400)) == _editor.DragMode.RESIZE, "length stays locked once picked")
