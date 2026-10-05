# Run: godot --headless --path Godot -s tests/test_value_lane_pane.gd -- --test
# The value lane pane in the real ClipEditor scene: default lane, add / close, toggle, the
# persisted lane list, and that none of it touches the project file (REQ-015, REQ-016).
extends TestBase

const KEY := "clip_editor/value_lanes"


func suite_name() -> String:
	return "Value lane: pane"


func _sonara() -> Node:
	return root.get_node("Sonara")


func _editor() -> Control:
	var scene: PackedScene = load("res://clip_editor/ClipEditor.tscn")
	var ed: Control = scene.instantiate()
	root.add_child(ed)
	await process_frame
	return ed


func _keys(pane, expected: Array) -> bool:
	return Array(pane.lane_keys()) == expected


func run_tests() -> void:
	var project_script: GDScript = load("res://data/Project.gd")
	var project: Object = project_script.new()
	var json_before: String = JSON.stringify(project.to_json())

	_sonara().set_config(KEY, {})
	var ed: Control = await _editor()
	var pane = ed.value_pane
	_assert(pane.visible, "the pane shows by default")
	_assert(_keys(pane, ["vel"]), "one velocity lane by default")
	_assert(ed.value_lanes_toggle.button_pressed, "the toolbar toggle matches")

	var rel = pane.add_lane("rel", 150.0)
	_assert(rel != null and pane.lane_keys().size() == 2, "+ Lane adds the release lane")
	_assert(pane.add_lane("rel") == null, "a lane already open is not added twice")
	_assert(is_equal_approx(rel.lane_height(), 150.0), "the lane takes the given height")
	var popup = pane.add_lane_button.get_popup()
	pane._rebuild_add_menu()
	var all_disabled := true
	for i in popup.item_count:
		all_disabled = all_disabled and popup.is_item_disabled(i)
	_assert(all_disabled, "lanes already open are disabled in the menu")

	rel.close_requested.emit(rel)
	await process_frame
	_assert(_keys(pane, ["vel"]), "the close button removes the lane")
	pane.add_lane("rel", 150.0)

	ed.value_lanes_toggle.button_pressed = false
	_assert(not pane.visible, "toggling off hides the pane")
	var cfg: Dictionary = _sonara().get_config(KEY)
	_assert(cfg.get("visible") == false and cfg.get("lanes").size() == 2, "visibility and lanes are saved in the config")

	ed.queue_free()
	await process_frame
	var ed2: Control = await _editor()
	_assert(not ed2.value_pane.visible, "a new editor restores the hidden pane")
	_assert(_keys(ed2.value_pane, ["vel", "rel"]), "and the same lanes")
	_assert(is_equal_approx(ed2.value_pane.lanes[1].lane_height(), 150.0), "and their heights")

	ed2.value_pane.visible = true
	ed2.size = Vector2(1100, 600)
	for _i in 3:
		await process_frame
	var area_x: float = ed2.value_pane.lanes[0].stem_area.global_position.x
	var note_x: float = ed2.midi_editor.note_area.global_position.x
	_assert(is_equal_approx(area_x, note_x), "the stem area starts where the note area does (%s vs %s)" % [area_x, note_x])
	_assert(not ed2.value_pane.lanes[0].resize_grip.visible, "the top lane has no grip (the editor split sizes it)")
	_assert(ed2.value_pane.lanes[1].resize_grip.visible, "the lanes below have one")
	await _test_grip_follows_pointer(ed2.value_pane.lanes[1], ed2.value_pane.lanes[0])
	await _test_split_sizes_top_lane(ed2)
	_assert(JSON.stringify(project.to_json()) == json_before, "the project JSON is unchanged")

	_sonara().set_config(KEY, {})
	await process_frame


func _grip_event(pressed: bool, y: float) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.global_position = Vector2(10, y)
	return e


## Dragging a lane's top grip moves the grip with the pointer, both ways.
func _test_grip_follows_pointer(lane, top) -> void:
	var top_h: float = top.row.size.y
	var grip: Control = lane.resize_grip
	var h0: float = lane.lane_height()
	var y0: float = grip.global_position.y
	lane._on_grip_input(_grip_event(true, y0))
	var up := InputEventMouseMotion.new()
	up.global_position = Vector2(10, y0 - 30.0)
	lane._on_grip_input(up)
	for _i in 2:
		await process_frame
	_assert(is_equal_approx(lane.lane_height(), h0 + 30.0), "dragging the grip up grows the lane")
	_assert(is_equal_approx(grip.global_position.y, y0 - 30.0), "and the grip follows the pointer (%s vs %s)" % [grip.global_position.y, y0 - 30.0])
	_assert(is_equal_approx(top.row.size.y, top_h), "the top lane keeps its height (%s vs %s)" % [top.row.size.y, top_h])
	var down := InputEventMouseMotion.new()
	down.global_position = Vector2(10, y0 - 10.0)
	lane._on_grip_input(down)
	lane._on_grip_input(_grip_event(false, y0 - 10.0))
	for _i in 2:
		await process_frame
	_assert(is_equal_approx(lane.lane_height(), h0 + 10.0), "dragging back down shrinks it")
	_assert(is_equal_approx(grip.global_position.y, y0 - 10.0), "and the grip still follows (%s vs %s)" % [grip.global_position.y, y0 - 10.0])
	var bottom: float = lane.get_global_rect().end.y
	lane._on_grip_input(_grip_event(true, y0 - 10.0))
	var far := InputEventMouseMotion.new()
	far.global_position = Vector2(10, y0 + 500.0)
	lane._on_grip_input(far)
	lane._on_grip_input(_grip_event(false, y0 + 500.0))
	for _i in 2:
		await process_frame
	_assert(lane.row.size.y <= lane.lane_height() + 0.5, "a lane never gets taller than its stored height (header floor)")
	_assert(is_equal_approx(lane.get_global_rect().end.y, bottom), "the lane's bottom edge stays put")


## Dragging the editor split grows and shrinks the top lane (no empty space above it), and
## the height is saved.
func _test_split_sizes_top_lane(ed) -> void:
	var pane = ed.value_pane
	var split: SplitContainer = pane.get_parent()
	var top = pane.lanes[0]
	var h0: float = top.row.size.y
	split.split_offset = -roundi(pane.size.y + 80.0)
	split.dragged.emit(split.split_offset)
	for _i in 3:
		await process_frame
	_assert(is_equal_approx(top.row.size.y, h0 + 80.0), "dragging the split up grows the top lane (%s vs %s)" % [top.row.size.y, h0 + 80.0])
	_assert(is_equal_approx(top.lane_height(), h0 + 80.0), "and stores its height")
	_assert(is_equal_approx(top.global_position.y, pane.lanes_box.global_position.y), "with no empty space above it")
	split.split_offset = -roundi(pane.size.y - 40.0)
	split.dragged.emit(split.split_offset)
	for _i in 3:
		await process_frame
	split.drag_ended.emit()
	_assert(is_equal_approx(top.row.size.y, h0 + 40.0), "dragging it down shrinks the top lane")
	var saved: Array = _sonara().get_config(KEY).get("lanes")
	_assert(is_equal_approx(float(saved[0]["height"]), h0 + 40.0), "the release of the drag saves it")
	ed.queue_free()
	await process_frame
	var ed3: Control = await _editor()
	ed3.value_pane.visible = true
	ed3.size = Vector2(1100, 600)
	for _i in 4:
		await process_frame
	_assert(is_equal_approx(ed3.value_pane.lanes[0].row.size.y, h0 + 40.0), "a new editor gives the top lane its saved height (%s)" % ed3.value_pane.lanes[0].row.size.y)
	ed3.queue_free()
	await process_frame
