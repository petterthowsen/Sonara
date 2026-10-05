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

	var rel = pane.add_lane("rel", 70.0)
	_assert(rel != null and pane.lane_keys().size() == 2, "+ Lane adds the release lane")
	_assert(pane.add_lane("rel") == null, "a lane already open is not added twice")
	_assert(is_equal_approx(rel.lane_height(), 70.0), "the lane takes the given height")
	var popup = pane.add_lane_button.get_popup()
	pane._rebuild_add_menu()
	var all_disabled := true
	for i in popup.item_count:
		all_disabled = all_disabled and popup.is_item_disabled(i)
	_assert(all_disabled, "lanes already open are disabled in the menu")

	rel.close_requested.emit(rel)
	await process_frame
	_assert(_keys(pane, ["vel"]), "the close button removes the lane")
	pane.add_lane("rel", 70.0)

	ed.value_lanes_toggle.button_pressed = false
	_assert(not pane.visible, "toggling off hides the pane")
	var cfg: Dictionary = _sonara().get_config(KEY)
	_assert(cfg.get("visible") == false and cfg.get("lanes").size() == 2, "visibility and lanes are saved in the config")

	ed.queue_free()
	await process_frame
	var ed2: Control = await _editor()
	_assert(not ed2.value_pane.visible, "a new editor restores the hidden pane")
	_assert(_keys(ed2.value_pane, ["vel", "rel"]), "and the same lanes")
	_assert(is_equal_approx(ed2.value_pane.lanes[1].lane_height(), 70.0), "and their heights")

	var w: float = ed2.midi_editor.key_column_width()
	_assert(is_equal_approx(ed2.value_pane.lanes[0].header.custom_minimum_size.x, w), "the lane header column matches the key column (%s)" % w)
	_assert(JSON.stringify(project.to_json()) == json_before, "the project JSON is unchanged")

	ed2.queue_free()
	_sonara().set_config(KEY, {})
	await process_frame
