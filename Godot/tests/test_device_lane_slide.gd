# test_device_lane_slide.gd
# Headless tests for the Device Lane sliding open and shut in the real Editor, and for dragging
# the center divider past the lane's minimum height to close it.
# Run: godot --headless --path Godot -s tests/test_device_lane_slide.gd -- --test
#
# Editor references autoloads, so it is loaded with load() instead of named.
extends TestBase

var _editor: Control


func suite_name() -> String:
	return "Device lane slide"


func run_tests() -> void:
	root.size = Vector2i(1600, 1000)
	_editor = load("res://editor/Editor.tscn").instantiate()
	root.add_child(_editor)
	_editor.size = Vector2(1600, 1000)
	await _frames(3)
	_assert(not _editor.seconday_panel.visible, "the lane starts closed")
	await _test_slide_open()
	await _test_slide_shut()
	await _test_drag_closes()
	_editor.queue_free()
	await process_frame


func _test_slide_open() -> void:
	var expected: float = _editor.device_lane.get_combined_minimum_size().y
	_editor.open_device_lane()
	_assert(_editor.is_device_lane_open(), "open_device_lane opens it")
	await _wait(0.12)
	var mid: float = _editor.device_lane_reveal.size.y
	_assert(mid > 1.0 and mid < expected - 1.0, "mid-slide the lane is part open (%s of %s)" % [mid, expected])
	await _wait(0.35)
	_assert(_editor.seconday_panel.visible and _editor.device_lane.visible, "the lane is shown after the slide")
	_assert(is_equal_approx(_editor.device_lane_reveal.reveal_height, -1.0), "the reveal lets go after the slide")
	var h: float = _editor.device_lane_reveal.size.y
	_assert(absf(h - expected) <= 1.0, "the slide ends at the lane's own height (%s vs %s)" % [h, expected])


func _test_slide_shut() -> void:
	_editor.close_device_lane()
	await _wait(0.12)
	_assert(_editor.seconday_panel.visible, "mid-slide the lane is still shown")
	await _wait(0.35)
	_assert(not _editor.seconday_panel.visible, "the lane is hidden after sliding shut")


## Real mouse drags on the center divider: up never resizes the lane, a short drag down keeps
## it, and a long one closes it.
func _test_drag_closes() -> void:
	_editor.open_device_lane(false)
	await _frames(3)
	var vsplit: SplitContainer = _editor.center_vsplit
	var height: float = _editor.seconday_panel.size.y
	await _drag_divider(vsplit, -200)
	await _frames(2)
	_assert(is_equal_approx(_editor.seconday_panel.size.y, height), "dragging up doesn't resize the lane (%s vs %s)" % [_editor.seconday_panel.size.y, height])
	await _drag_divider(vsplit, 20)
	await _frames(2)
	_assert(_editor.is_device_lane_open() and is_equal_approx(_editor.seconday_panel.size.y, height), "a short drag down keeps the lane as it was")
	await _drag_divider(vsplit, 200)
	_assert(not _editor.is_device_lane_open(), "dragging well down closes the lane")
	await _wait(0.45)
	_assert(not _editor.seconday_panel.visible, "the lane slides shut after the drag")


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Drag `split`'s divider with real mouse events: grab its middle, move `dy` px, let go.
func _drag_divider(split: SplitContainer, dy: float) -> void:
	var dragger: Control = null
	for child in split.get_children(true):
		if child.get_class() == "SplitContainerDragger":
			dragger = child
	var at := dragger.get_global_rect().get_center()
	await _mouse(at, true)
	for step in 4:
		await _mouse(at + Vector2(0, dy * (step + 1) / 4.0))
	await _mouse(at + Vector2(0, dy), false)


func _mouse(at: Vector2, pressed: Variant = null) -> void:
	var ev: InputEventMouse
	if pressed == null:
		ev = InputEventMouseMotion.new()
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	else:
		ev = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	root.push_input(ev)
	await process_frame
