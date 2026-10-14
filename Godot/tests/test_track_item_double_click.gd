# test_track_item_double_click.gd
# TrackItem emits double_clicked on a left double-click (after select_requested), but not for a
# single click, with Ctrl/Shift held, or when the pointer is in the resize gutter.
# Run: godot --headless --path Godot -s tests/test_track_item_double_click.gd -- --test
extends TestBase

const TRACK_ITEM_SCENE := "res://arranger/tracklist/TrackItem.tscn"

var _doubles := 0
var _selects := 0


func suite_name() -> String:
	return "TrackItem double-click tests"


func _click(item: Control, double: bool, ctrl := false, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.double_click = double
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	item._gui_input(e)


func run_tests() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var track: Object = project.create_instrument_track("Lead").track
	var item: Control = (load(TRACK_ITEM_SCENE) as PackedScene).instantiate()
	root.add_child(item)
	item.bind_to_track(track, 0, project)
	item.double_clicked.connect(func(_t): _doubles += 1)
	item.select_requested.connect(func(_t, _a, _r): _selects += 1)
	item.size = Vector2(200, 200)  # the pointer (0,0 headless) is far from the bottom gutter

	_click(item, false)
	_assert(_doubles == 0 and _selects == 1, "a single click selects without double_clicked")
	_click(item, true)
	_assert(_doubles == 1 and _selects == 2, "a double-click selects and emits double_clicked")
	_click(item, true, true)
	_click(item, true, false, true)
	_assert(_doubles == 1 and _selects == 4, "Ctrl/Shift double-clicks only select")

	# Move the item up so the pointer (0,0 headless) lands in its bottom gutter band.
	item.position = Vector2(0, -(item.size.y - 1.0))
	_assert(item._is_in_resize_gutter(), "the moved item puts the pointer in the gutter")
	var before := _doubles
	_click(item, true)
	_assert(_doubles == before, "a double-click in the resize gutter does not emit")
