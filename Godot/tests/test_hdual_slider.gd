# HDualSlider drag modes: single handle, both handles, overlap and Alt (pan-modes spec, REQ-009).
extends TestBase

const W := 200.0  # slider width in px; -1..1 maps to 0..200, so 100 px is 1.0

var _pair_deltas: Array = []
var _handle_events: Array = []


func suite_name() -> String:
	return "HDualSlider"


func run_tests() -> void:
	_test_fill_drag()
	_test_handle_drag()
	_test_overlap_drag()
	_test_overlap_alt()
	_test_single_handle_no_pair()


func _make(a: float, b: float) -> HDualSlider:
	var s := HDualSlider.new()
	s.size = Vector2(W, 20)
	s.set_values_no_signal(a, b)
	_pair_deltas.clear()
	_handle_events.clear()
	s.pair_dragged.connect(func(d): _pair_deltas.append(d))
	s.handle_dragged.connect(func(which, v): _handle_events.append([which, v]))
	return s


func _press(s: HDualSlider, x: float, alt := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.alt_pressed = alt
	e.position = Vector2(x, 10)
	s._gui_input(e)


func _move(s: HDualSlider, x: float, from_x: float) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(x, 10)
	e.relative = Vector2(x - from_x, 0)
	s._gui_input(e)


func _release(s: HDualSlider) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	s._gui_input(e)


func _test_fill_drag() -> void:
	# Handles at -0.5 (x=50) and 0.5 (x=150); press the fill at x=100.
	var s := _make(-0.5, 0.5)
	_press(s, 100)
	_assert(s._drag_mode == HDualSlider.DragMode.BOTH, "fill press starts a pair drag")
	_move(s, 190, 100)  # +0.9: past the right edge for b
	_assert(is_equal_approx(_pair_deltas.back(), 0.9), "pair_dragged delta is unclamped (0.9)")
	_assert(is_equal_approx(s.a_value, 0.4) and is_equal_approx(s.b_value, 1.0), "a moves, b clamps at the edge")
	_move(s, 100, 190)
	_assert(is_equal_approx(s.a_value, -0.5) and is_equal_approx(s.b_value, 0.5), "dragging back restores the pair")
	_assert(_handle_events.is_empty(), "no handle_dragged during a pair drag")
	_release(s)
	_assert(s._drag_mode == HDualSlider.DragMode.NONE, "release ends the drag")


func _test_handle_drag() -> void:
	var s := _make(-0.5, 0.5)
	_press(s, 52)  # within the grab radius of a (x=50)
	_assert(s._drag_mode == HDualSlider.DragMode.A_VALUE, "press on a handle grabs it")
	_move(s, 20, 52)
	_assert(not _handle_events.is_empty() and _handle_events.back()[0] == HDualSlider.DragMode.A_VALUE, "handle_dragged reports a")
	_assert(is_equal_approx(_handle_events.back()[1], -0.8), "handle_dragged value follows the mouse")
	_assert(is_equal_approx(s.b_value, 0.5), "other handle untouched")
	_release(s)
	_press(s, 149)
	_assert(s._drag_mode == HDualSlider.DragMode.B_VALUE, "press on b grabs b")
	_release(s)
	# Outside the fill and away from both handles: nearest handle jumps to the press.
	_press(s, 5)
	_assert(s._drag_mode == HDualSlider.DragMode.A_VALUE and is_equal_approx(s.a_value, -0.95), "outside press moves the nearest handle")


func _test_overlap_drag() -> void:
	var s := _make(0.0, 0.0)
	_press(s, 100)
	_assert(s._drag_mode == HDualSlider.DragMode.BOTH, "overlapped handles drag as a pair")
	_move(s, 130, 100)
	_assert(is_equal_approx(s.a_value, 0.3) and is_equal_approx(s.b_value, 0.3), "pair moves together")


func _test_overlap_alt() -> void:
	var s := _make(0.0, 0.0)
	_press(s, 100, true)
	_assert(s._drag_mode == HDualSlider.DragMode.PENDING, "Alt on overlapped handles waits for motion")
	_move(s, 130, 100)
	_assert(s._drag_mode == HDualSlider.DragMode.B_VALUE, "Alt drag to the right picks b")
	_assert(is_equal_approx(s.a_value, 0.0) and is_equal_approx(s.b_value, 0.3), "only b moves, spreading the handles")
	_release(s)
	var t := _make(0.0, 0.0)
	_press(t, 100, true)
	_move(t, 70, 100)
	_assert(t._drag_mode == HDualSlider.DragMode.A_VALUE and is_equal_approx(t.a_value, -0.3), "Alt drag to the left picks a")


func _test_single_handle_no_pair() -> void:
	var s := _make(-0.5, 0.5)
	_press(s, 50)
	_move(s, 60, 50)
	_assert(_pair_deltas.is_empty(), "no pair_dragged during a handle drag")
