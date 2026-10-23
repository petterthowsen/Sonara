# test_step_lane.gd
# Headless tests for StepLane: column geometry, the pure maths, BARS and TOGGLES gestures,
# fine drag, reset painting, typed entry. The lane sits away from (0, 0) so the headless pointer
# never hovers it.
# Run: godot --headless --path Godot -s tests/test_step_lane.gd -- --test
extends TestBase

var _lane: StepLane
var _edits: Array = []
var _started := 0
var _ended := 0


func suite_name() -> String:
	return "StepLane"


func run_tests() -> void:
	_test_maths()
	await _test_geometry()
	await _test_draw_and_fill()
	await _test_pitch_values()
	await _test_percent_values()
	await _test_fine()
	await _test_reset()
	await _test_off_and_length()
	await _test_level_colors()
	await _test_no_signal_without_change()
	await _test_toggles()
	await _test_typed_entry()


func _make(pitch := true, mode := StepLane.Mode.BARS) -> StepLane:
	if _lane:
		_lane.queue_free()
	var lane := StepLane.new()
	lane.mode = mode
	if pitch:
		lane.min_value = -24.0
		lane.max_value = 24.0
		lane.origin = 0.0
		lane.default_value = 0.0
	else:
		lane.min_value = 0.0
		lane.max_value = 100.0
		lane.origin = 0.0
		lane.default_value = 100.0
	if mode == StepLane.Mode.TOGGLES:
		lane.min_value = 0.0
		lane.max_value = 1.0
	root.add_child(lane)
	lane.position = Vector2(200, 150)
	lane.size = Vector2(480, 100)
	_edits.clear()
	_started = 0
	_ended = 0
	lane.value_edited.connect(func(k, v): _edits.append([k, v]))
	lane.edit_started.connect(func(): _started += 1)
	lane.edit_ended.connect(func(): _ended += 1)
	_lane = lane
	return lane


func _x(lane: StepLane, k: int) -> float:
	return lane.column_rect(k).get_center().x


func _y(lane: StepLane, v: float) -> float:
	return lane.size.y * (1.0 - (v - lane.min_value) / (lane.max_value - lane.min_value))


func _press(lane: StepLane, pos: Vector2, shift := false, ctrl := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	lane._gui_input(ev)


func _release(lane: StepLane, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = pos
	lane._gui_input(ev)


func _move(lane: StepLane, pos: Vector2, rel := Vector2.ZERO, shift := false, ctrl := false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.relative = rel
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	lane._gui_input(ev)


func _test_maths() -> void:
	_assert(StepLane.value_at_y(0.0, 100.0, -24.0, 24.0) == 24.0, "top maps to +24")
	_assert(StepLane.value_at_y(50.0, 100.0, -24.0, 24.0) == 0.0, "middle maps to 0")
	_assert(StepLane.value_at_y(100.0, 100.0, -24.0, 24.0) == -24.0, "bottom maps to -24")
	_assert(StepLane.value_at_y(-30.0, 100.0, -24.0, 24.0) == 24.0, "above the lane clamps")
	_assert(StepLane.value_at_y(500.0, 100.0, -24.0, 24.0) == -24.0, "below the lane clamps")
	var all_whole := true
	for y in range(0, 101, 3):
		var v := StepLane.value_at_y(float(y) + 0.37, 100.0, -24.0, 24.0)
		all_whole = all_whole and is_equal_approx(v, roundf(v))
	_assert(all_whole, "snapped values are whole units")
	_assert(StepLane.value_at_y(0.0, 100.0, 0.0, 100.0) == 100.0, "percent top is 100")
	_assert(StepLane.value_at_y(100.0, 100.0, 0.0, 100.0) == 0.0, "percent bottom is 0")
	var fill := StepLane.fill_between(2, 24.0, 6, 0.0)
	_assert(fill.size() == 5, "fill_between from 2 to 6 covers 5 columns (got %d)" % fill.size())
	_assert(fill[2] == 24.0 and fill[3] == 18.0 and fill[4] == 12.0 and fill[5] == 6.0 and fill[6] == 0.0,
		"fill_between steps down linearly")
	var back := StepLane.fill_between(6, 0.0, 2, 24.0)
	_assert(back[6] == 0.0 and back[2] == 24.0 and back[4] == 12.0, "fill_between works right to left")
	_assert(StepLane.fill_between(3, 1.0, 3, 9.0) == {3: 9.0}, "fill_between on one column is the target")
	_assert(StepLane.parse_entry("-9") == -9.0, "parse_entry reads -9")
	_assert(StepLane.parse_entry("+7 st") == 7.0, "parse_entry allows a st suffix")
	_assert(StepLane.parse_entry("80%") == 80.0, "parse_entry allows a % suffix")
	_assert(is_nan(StepLane.parse_entry("abc")), "parse_entry rejects text")


func _test_geometry() -> void:
	var lane := _make()
	await process_frame
	var ok := true
	for k in 16:
		ok = ok and lane.step_at_x(_x(lane, k)) == k
	_assert(ok, "step_at_x maps each column centre back to its step")
	_assert(lane.step_at_x(-50.0) == 0 and lane.step_at_x(5000.0) == 15, "outside the lane clamps")
	_assert(lane.column_rect(4).position.x > lane.column_rect(3).end.x, "groups are separated by a gap")
	_assert(is_equal_approx(lane.column_rect(15).end.x, lane.size.x), "the last column ends at the edge")



func _test_draw_and_fill() -> void:
	# REQ-005: press at step 2 (index 1) at the top, one motion to step 6 (index 5) at zero.
	var lane := _make()
	await process_frame
	_press(lane, Vector2(_x(lane, 1), 0.0))
	_move(lane, Vector2(_x(lane, 5), _y(lane, 0.0)))
	_release(lane, Vector2(_x(lane, 5), _y(lane, 0.0)))
	_assert(lane.get_value_at(1) == 24.0, "press sets step 2 to +24")
	_assert(lane.get_value_at(5) == 0.0, "drag end sets step 6 to 0")
	_assert(lane.get_value_at(2) == 18.0 and lane.get_value_at(3) == 12.0 and lane.get_value_at(4) == 6.0,
		"skipped steps get values along the path")
	_assert(lane.get_value_at(0) == 0.0 and lane.get_value_at(6) == 0.0, "neighbours outside the path are untouched")
	_assert(_started == 1 and _ended == 1, "one gesture emits edit_started and edit_ended once")


func _test_pitch_values() -> void:
	var lane := _make()
	await process_frame
	_press(lane, Vector2(_x(lane, 3), _y(lane, 12.0)))
	_release(lane, Vector2(_x(lane, 3), _y(lane, 12.0)))
	_assert(lane.get_value_at(3) == 12.0, "halfway between zero and the top writes +12")
	var whole := true
	for e in _edits:
		whole = whole and is_equal_approx(e[1], roundf(e[1]))
	_assert(whole, "every written pitch is a whole semitone")


func _test_percent_values() -> void:
	var lane := _make(false)
	await process_frame
	_press(lane, Vector2(_x(lane, 0), 0.0))
	_move(lane, Vector2(_x(lane, 1), lane.size.y))
	_move(lane, Vector2(_x(lane, 2), lane.size.y * 0.3333))
	_release(lane, Vector2(_x(lane, 2), 33.0))
	_assert(lane.get_value_at(0) == 100.0, "press at the top writes 100 %")
	_assert(lane.get_value_at(1) == 0.0, "press at the bottom writes 0 %")
	var whole := true
	for e in _edits:
		whole = whole and is_equal_approx(e[1], roundf(e[1]))
	_assert(whole, "every written percent is whole")


func _test_fine() -> void:
	# Shift-press step 4 (index 3) at +5, drag up 30 px.
	var lane := _make()
	await process_frame
	lane.set_value_no_signal(3, 5.0)
	var start := Vector2(_x(lane, 3), _y(lane, 5.0))
	_press(lane, start, true)
	_assert(lane.get_value_at(3) == 5.0 and _edits.is_empty(), "shift-press does not jump the value")
	_move(lane, start + Vector2(0, -30), Vector2(0, -30), true)
	_release(lane, start + Vector2(0, -30))
	var gained := lane.get_value_at(3) - 5.0
	var normal := 30.0 / lane.size.y * 48.0
	_assert(gained > 0.0 and gained < normal,
		"fine drag rises by less than a normal drag (%s vs %s)" % [gained, normal])
	_assert(lane.get_value_at(2) == 0.0 and lane.get_value_at(4) == 0.0, "neighbours are unchanged")
	# Sideways motion over other columns paints nothing.
	var lane2 := _make()
	await process_frame
	lane2.set_value_no_signal(3, 5.0)
	var s2 := Vector2(_x(lane2, 3), _y(lane2, 5.0))
	_press(lane2, s2, true)
	_move(lane2, Vector2(_x(lane2, 8), s2.y), Vector2(200, 0), true)
	_release(lane2, s2)
	_assert(_edits.is_empty(), "fine drag sideways changes nothing")


func _test_reset() -> void:
	var lane := _make()
	await process_frame
	for k in 4:
		lane.set_value_no_signal(k, 7.0)
	_press(lane, Vector2(_x(lane, 0), 10.0), false, true)
	_move(lane, Vector2(_x(lane, 2), 10.0), Vector2.ZERO, false, true)
	_release(lane, Vector2(_x(lane, 2), 10.0))
	_assert(lane.get_value_at(0) == 0.0 and lane.get_value_at(1) == 0.0 and lane.get_value_at(2) == 0.0,
		"ctrl-drag resets steps 1-3")
	_assert(lane.get_value_at(3) == 7.0, "step 4 keeps +7")


func _test_off_and_length() -> void:
	var lane := _make()
	await process_frame
	lane.off_mask = 1 << 2
	_press(lane, Vector2(_x(lane, 0), _y(lane, 10.0)))
	_move(lane, Vector2(_x(lane, 3), _y(lane, 10.0)))
	_release(lane, Vector2(_x(lane, 3), _y(lane, 10.0)))
	_assert(lane.get_value_at(2) == 10.0, "drawing changes an Off step's value")
	_assert(lane.is_step_off(2) and lane.off_mask == 4, "the step stays off")
	lane.length = 6
	_assert(lane.is_beyond_length(6) and lane.is_beyond_length(15) and not lane.is_beyond_length(5),
		"steps 7-16 are beyond length 6")
	_edits.clear()
	_press(lane, Vector2(_x(lane, 9), _y(lane, 7.0)))
	_release(lane, Vector2(_x(lane, 9), _y(lane, 7.0)))
	_assert(lane.get_value_at(9) == 7.0, "a beyond-length step is still editable")


func _test_level_colors() -> void:
	var lane := _make()
	await process_frame
	lane.set_values_no_signal(PackedFloat32Array([0.0, 1.0, 2.0, 5.0]))
	_assert(lane._bar_color_for(1) == lane.bar_color, "without level_colors a bar uses the lane colour")
	var colors := PackedColorArray([Color.BLACK, Color.RED, Color.GREEN, Color.BLUE])
	lane.level_colors = colors
	_assert(lane._bar_color_for(1) == colors[1] and lane._bar_color_for(2) == colors[2],
		"a bar is drawn in level_colors[value]")
	_assert(lane._bar_color_for(3) == lane.bar_color, "a value past the array keeps the lane colour")


func _test_no_signal_without_change() -> void:
	var lane := _make()
	await process_frame
	lane.set_values_no_signal(PackedFloat32Array([1.0, 2.0]))
	lane.set_value_no_signal(5, 3.0)
	_assert(_edits.is_empty(), "no_signal setters do not emit")
	_press(lane, Vector2(_x(lane, 0), _y(lane, 1.0)))
	_move(lane, Vector2(_x(lane, 0) + 1.0, _y(lane, 1.0)))
	_release(lane, Vector2(_x(lane, 0), _y(lane, 1.0)))
	_assert(_edits.is_empty(), "painting the existing value emits nothing")
	_assert(lane._gesture == StepLane.Gesture.NONE, "the gesture ends on release")


func _test_toggles() -> void:
	var lane := _make(true, StepLane.Mode.TOGGLES)
	await process_frame
	var y := lane.size.y * 0.5
	_press(lane, Vector2(_x(lane, 0), y))
	_move(lane, Vector2(_x(lane, 7), y))
	_release(lane, Vector2(_x(lane, 7), y))
	var all_on := true
	for k in 8:
		all_on = all_on and lane.get_value_at(k) == 1.0
	_assert(all_on, "press on step 1 and drag to 8 turn all eight on")
	_assert(lane.get_value_at(8) == 0.0, "step 9 is untouched")
	_press(lane, Vector2(_x(lane, 2), y))
	_move(lane, Vector2(_x(lane, 4), y))
	_release(lane, Vector2(_x(lane, 4), y))
	_assert(lane.get_value_at(2) == 0.0 and lane.get_value_at(3) == 0.0 and lane.get_value_at(4) == 0.0,
		"press on an on step 3 and drag to 5 turn 3-5 off")
	_assert(lane.get_value_at(1) == 1.0 and lane.get_value_at(5) == 1.0, "steps outside stay on")
	_edits.clear()
	_press(lane, Vector2(_x(lane, 1), y))
	_move(lane, Vector2(_x(lane, 3), y))
	_release(lane, Vector2(_x(lane, 3), y))
	_assert(lane.get_value_at(2) == 0.0 and lane.get_value_at(3) == 0.0, "already-matching steps emit nothing")
	_assert(_edits.size() == 1 and _edits[0][0] == 1, "only the one real change was emitted")


func _test_typed_entry() -> void:
	var lane := _make()
	await process_frame
	lane._edit_step = 4
	lane.commit_text("-9")
	_assert(lane.get_value_at(4) == -9.0, "typed -9 sets -9")
	lane._edit_step = 5
	lane.commit_text("30 st")
	_assert(lane.get_value_at(5) == 24.0, "30 st clamps to 24")
	lane._edit_step = 6
	lane.commit_text("3.6")
	_assert(lane.get_value_at(6) == 4.0, "typed values round to whole units")
	lane.commit_text("nonsense")
	_assert(lane.get_value_at(6) == 4.0, "non-numbers are ignored")
	# Double-click opens the editor above the column.
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.double_click = true
	ev.position = Vector2(_x(lane, 4), 40.0)
	lane._gui_input(ev)
	var found := false
	for c in lane.get_children():
		if c is FloatingValueEditor:
			found = true
	_assert(found and lane._edit_step == 4, "double-click opens a value editor for that step")
