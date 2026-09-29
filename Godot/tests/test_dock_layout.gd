# Dock layout: tab groups via center drops, dissolving one-panel tab groups,
# hidden empty docks, persisting tab groups in `ui/docks`, and real mouse drags
# against the drop zones.
extends TestBase

# Dock classes reference autoloads, so they are loaded at runtime rather than by class name.
var _host_script: GDScript
var _dock_script: GDScript
var Z: Dictionary


func suite_name() -> String:
	return "DockLayout"


func run_tests() -> void:
	_host_script = load("res://editor/docks/DockHost.gd")
	_dock_script = load("res://editor/docks/SideDock.gd")
	Z = _dock_script.Zone
	await _test_center_drop_creates_tab_group()
	await _test_last_panel_out_dissolves_tab_group()
	await _test_empty_dock_hidden_until_drag()
	await _test_tab_groups_round_trip_through_config()
	await _test_hide_panel_from_tab_group()
	await _test_mouse_drop_on_title_bar_tabs()
	await _test_mouse_drop_on_body_center_tabs()
	await _test_mouse_drop_above_tab_group_stacks()
	await _test_mouse_drop_at_dock_bottom_stacks()
	await _test_new_stack_item_gets_even_share()


## Build a DockHost with inspector on the left and browser + assistant on the right.
func _make_host(saved: Variant = {}) -> Control:
	_sonara().set_config(_host_script.CONFIG_KEY, saved)
	var host: Control = _host_script.new()
	host.name = "LeftRightSplit"
	host.size = Vector2(1200, 800)
	var center_split := HSplitContainer.new()
	center_split.name = "LeftCenterSplit"
	center_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.add_child(center_split)
	var left: Control = _dock_script.new()
	left.name = "LeftDock"
	left.add_child(_content("Inspector"))
	center_split.add_child(left)
	center_split.add_child(_content("Center"))
	var right: Control = _dock_script.new()
	right.name = "RightDock"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_content("BrowserPanel"))
	right.add_child(_content("AssistantPanel"))
	host.add_child(right)
	var holder := Control.new()
	holder.size = Vector2(1200, 800)
	root.size = Vector2i(1200, 800)
	root.add_child(holder)
	holder.add_child(host)
	await process_frame
	await process_frame
	return host


func _sonara() -> Node:
	return root.get_node("/root/Sonara")


func _content(node_name: String) -> Control:
	var control := Control.new()
	control.name = node_name
	return control


func _free_host(host: Control) -> void:
	host.get_parent().queue_free()
	await process_frame


func _panel(host: Control, id: String) -> Control:
	for panel in host.left_dock.get_panels() + host.right_dock.get_panels():
		if panel.panel_id == id:
			return panel
	return null


func _test_center_drop_creates_tab_group() -> void:
	var host := await _make_host()
	var inspector: Variant = _panel(host, "inspector")
	var browser: Variant = _panel(host, "browser")
	host.drop_panel(inspector, host.right_dock, {"zone": Z.CENTER, "item": browser, "tab": -1})
	var items: Array = host.right_dock.get_items()
	_assert(items.size() == 2, "right dock has tab group + assistant (got %d)" % items.size())
	_assert(items[0] is TabContainer, "tab group replaced the browser slot")
	var tabs: TabContainer = items[0]
	_assert(Array(tabs.get_panels()) == [browser, inspector], "tab order is target then dropped panel")
	_assert(tabs.get_tab_title(1) == "Inspector", "tab title comes from the panel title")
	_assert(host.left_dock.get_items().is_empty(), "left dock is empty after its only panel moved")
	_assert(host.is_panel_visible("inspector"), "tabbed panel still counts as visible")
	var layout: Array = _sonara().get_config(_host_script.CONFIG_KEY)["right"]
	_assert(layout[0] is Dictionary and layout[0]["tabs"] == ["browser", "inspector"], "tab group saved as {tabs}")
	await _free_host(host)


func _test_last_panel_out_dissolves_tab_group() -> void:
	var host := await _make_host()
	var browser: Variant = _panel(host, "browser")
	var assistant: Variant = _panel(host, "assistant")
	host.drop_panel(assistant, host.right_dock, {"zone": Z.CENTER, "item": browser, "tab": -1})
	var tabs: TabContainer = host.right_dock.get_items()[0]
	_assert(tabs != null and tabs.get_tab_count() == 2, "browser + assistant tabbed")
	host.drop_panel(assistant, host.left_dock, {"zone": Z.AFTER, "item": _panel(host, "inspector"), "tab": -1})
	var right_items: Array = host.right_dock.get_items()
	_assert(right_items.size() == 1 and right_items[0] == browser, "one-panel tab group dissolved back to the panel")
	_assert(browser._title_bar.visible, "dissolved panel gets its title bar back")
	_assert(host.left_dock.get_items().back() == assistant, "moved panel inserted after inspector")
	await _free_host(host)


func _test_empty_dock_hidden_until_drag() -> void:
	var host := await _make_host()
	var inspector: Variant = _panel(host, "inspector")
	var center_split: HSplitContainer = host.left_dock.get_parent()
	center_split.split_offsets = PackedInt32Array([180])
	host.drop_panel(inspector, host.right_dock, {"zone": Z.APPEND, "item": null, "tab": -1})
	_assert(not host.left_dock.visible, "empty dock is hidden")
	_assert(Array(host.left_dock.get_parent_split_offsets()) == [180], "user width stashed while empty")
	_assert(Array(_sonara().get_config(_host_script.CONFIG_KEY)["inner_offsets"]) == [180], "stashed width is what gets saved")
	_assert(host.left_dock.custom_minimum_size.x == host.left_dock.empty_min_width, "empty dock uses the thin strip width")
	host.left_dock._panel_drag_active = true
	host.left_dock._sync_empty_state()
	_assert(host.left_dock.visible, "empty dock shows as a drop strip during a panel drag")
	host.left_dock._panel_drag_active = false
	host.drop_panel(inspector, host.left_dock, {"zone": Z.APPEND, "item": null, "tab": -1})
	_assert(host.left_dock.visible, "dock visible again once occupied")
	_assert(host.left_dock.custom_minimum_size.x == host.left_dock.occupied_min_width, "occupied width restored")
	_assert(Array(center_split.split_offsets) == [180], "user split offset restored when re-occupied")
	await _free_host(host)


func _test_tab_groups_round_trip_through_config() -> void:
	var saved := {
		"left": [],
		"right": [{"tabs": ["assistant", "inspector", "browser"], "current": 1}],
	}
	var host := await _make_host(saved)
	_assert(not host.left_dock.visible, "saved-empty left dock starts hidden")
	var items: Array = host.right_dock.get_items()
	_assert(items.size() == 1 and items[0] is TabContainer, "saved tab group restored")
	var tabs: TabContainer = items[0]
	_assert(tabs.get_tab_count() == 3 and tabs.current_tab == 1, "tab order and current tab restored")
	_assert(tabs.get_tab_control(0).panel_id == "assistant", "first tab is assistant")
	await _free_host(host)


func _test_hide_panel_from_tab_group() -> void:
	var host := await _make_host()
	var browser: Variant = _panel(host, "browser")
	var assistant: Variant = _panel(host, "assistant")
	host.drop_panel(assistant, host.right_dock, {"zone": Z.CENTER, "item": browser, "tab": -1})
	host.set_panel_visible("assistant", false)
	_assert(not host.is_panel_visible("assistant"), "hidden tab leaves the dock")
	_assert(Array(host.right_dock.get_items()) == [browser], "remaining tab dissolved to a lone panel")
	host.set_panel_visible("assistant", true)
	_assert(host.right_dock.get_items().back() == assistant, "re-shown panel appended to right dock")
	await _free_host(host)


## Press on `from`, move to `to` in steps (past the drag threshold), release.
func _mouse_drag(from: Vector2, to: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	press.global_position = from
	Input.parse_input_event(press)
	await process_frame
	var steps := 10
	for i in range(1, steps + 1):
		var motion := InputEventMouseMotion.new()
		motion.position = from.lerp(to, float(i) / steps)
		motion.global_position = motion.position
		motion.relative = (to - from) / steps
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(motion)
		await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = to
	release.global_position = to
	Input.parse_input_event(release)
	await process_frame
	await process_frame


func _title_center(panel: Variant) -> Vector2:
	return panel.get_title_global_rect().get_center()


func _first_tab_center(tabs: TabContainer) -> Vector2:
	var bar := tabs.get_tab_bar()
	return bar.global_position + bar.get_tab_rect(0).get_center()


func _test_mouse_drop_on_title_bar_tabs() -> void:
	var host := await _make_host()
	var inspector: Variant = _panel(host, "inspector")
	var browser: Variant = _panel(host, "browser")
	await _mouse_drag(_title_center(inspector), _title_center(browser))
	var layout: Array = host.right_dock.get_layout()
	_assert(layout.size() == 2 and layout[0] is Dictionary, "dropping on a title bar tabs (got %s)" % [layout])
	await _free_host(host)


func _test_mouse_drop_on_body_center_tabs() -> void:
	var host := await _make_host()
	var inspector: Variant = _panel(host, "inspector")
	var assistant: Variant = _panel(host, "assistant")
	await _mouse_drag(_title_center(inspector), assistant.get_global_rect().get_center())
	var layout: Array = host.right_dock.get_layout()
	_assert(layout.size() == 2 and layout[1] is Dictionary, "dropping on a body center tabs (got %s)" % [layout])
	await _free_host(host)


func _test_mouse_drop_above_tab_group_stacks() -> void:
	var host := await _make_host()
	var browser: Variant = _panel(host, "browser")
	var assistant: Variant = _panel(host, "assistant")
	host.drop_panel(assistant, host.right_dock, {"zone": Z.CENTER, "item": browser, "tab": -1})
	var tabs: TabContainer = host.right_dock.get_items()[0]
	var dock_rect: Rect2 = host.right_dock.get_global_rect()
	await _mouse_drag(_first_tab_center(tabs), Vector2(dock_rect.get_center().x, dock_rect.position.y + 3))
	_assert(host.right_dock.get_layout() == ["browser", "assistant"], "top edge above a tab group stacks (got %s)" % [host.right_dock.get_layout()])
	await _free_host(host)


func _test_mouse_drop_at_dock_bottom_stacks() -> void:
	var host := await _make_host()
	var inspector: Variant = _panel(host, "inspector")
	var browser: Variant = _panel(host, "browser")
	var assistant: Variant = _panel(host, "assistant")
	host.drop_panel(assistant, host.right_dock, {"zone": Z.CENTER, "item": browser, "tab": -1})
	var dock_rect: Rect2 = host.right_dock.get_global_rect()
	await _mouse_drag(_title_center(inspector), Vector2(dock_rect.get_center().x, dock_rect.end.y - 4))
	var layout: Array = host.right_dock.get_layout()
	_assert(layout.size() == 2 and str(layout[1]) == "inspector", "dock bottom stacks below a tab group (got %s)" % [layout])
	await _free_host(host)


func _test_new_stack_item_gets_even_share() -> void:
	var host := await _make_host()
	var inspector: Variant = _panel(host, "inspector")
	host.drop_panel(inspector, host.right_dock, {"zone": Z.APPEND, "item": null, "tab": -1})
	await process_frame
	var heights: Array = []
	for item in host.right_dock.get_items():
		heights.append(item.size.y)
	_assert(heights.size() == 3 and absf(heights[0] - heights[2]) < 2.0, "stacked items share height evenly (got %s)" % [heights])
	await _free_host(host)
