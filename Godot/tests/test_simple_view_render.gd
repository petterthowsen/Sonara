# test_simple_view_render.gd
# Simple View rendering in a DevicePanel: integer enums render as a stepped RotaryKnob bound to the enum
# index, the view widens to its grid instead of scrolling sideways, and the DevicePanel opens
# its Parameters tab only for a device without a view. Group boxes grow into free space and spread
# their controls evenly; pages sit at the left and the view takes each page's width.
# Run: godot --headless --path Godot -s tests/test_simple_view_render.gd -- --test
extends TestBase

const PANEL_SCENE := "res://devices/device_lane/DevicePanel.tscn"

var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript

var _project: Object = null


func suite_name() -> String:
	return "Simple View render tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_project = _project_script.new()
	load("res://devices/simple_view/SimpleLayoutStore.gd").clear_cache()

	await _test_spinbox_for_integer_enum()
	await _test_view_widens_to_grid()
	await _test_parameters_tab_default()
	await _test_groups_fill_and_spread()
	await _test_fixed_height()
	await _test_slot_tiles_render_with_count()
	await _test_slot_tile_click_toggles()
	await _test_drop_on_slot_tile()
	await _test_edited_layout_gets_slot_tiles_appended()


## A device instance for a fake built-in device with `params`, on a fresh channel. Unique ids keep
## the layout store from reusing a layout saved by an earlier run.
func _instance(title: String, params: Array) -> Object:
	var device_id := "sonara.test.%s.%d" % [title.to_lower().replace(" ", "_"), Time.get_ticks_usec()]
	var device: Object = _device_script.new(device_id, title,
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	for param in params:
		device.add_parameter(param)
	root.get_node("AssetService").device_registry._devices[device_id] = device
	var channel: Object = _project.create_instrument_track(title).channel
	return _device_instance_script.new(device, channel.id, 0)


func _float_param(id: int, name: String) -> Object:
	var p: Object = _param_script.new(id, name)
	p.default_value = 0.5
	return p


func _octave_param(id: int) -> Object:
	var p: Object = _param_script.new(id, "Osc A Octave")
	p.param_type = "enum"
	p.enum_values.assign(["-2", "-1", "0", "+1", "+2"])
	p.default_value = 2.0
	return p


## A DevicePanel bound to `instance`, away from the headless pointer at (0, 0).
func _panel_for(instance: Object) -> Control:
	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.position = Vector2(200, 200)
	await panel.bind_to_device(instance)
	for _i in 4:
		await process_frame
	return panel


func _find(node: Node, type_name: String) -> Node:
	for child in node.get_children():
		if child.is_class(type_name) and not child.is_queued_for_deletion():
			return child
		var found := _find(child, type_name)
		if found:
			return found
	return null


func _find_knob(node: Node) -> RotaryKnob:
	for child in node.get_children():
		if child is RotaryKnob and not child.is_queued_for_deletion():
			return child
		var found := _find_knob(child)
		if found:
			return found
	return null


func _test_spinbox_for_integer_enum() -> void:
	var instance: Object = _instance("Spin Synth", [_octave_param(0)])
	var panel: Control = await _panel_for(instance)
	var spin: RotaryKnob = _find_knob(panel._panel_view)
	_assert(spin != null and spin.step == 1.0, "an integer enum renders as a stepped RotaryKnob")
	if spin == null:
		panel.queue_free()
		return
	_assert(spin.min_value == -2.0 and spin.max_value == 2.0, "the knob spans the labels (-2…+2)")
	instance._on_parameter_value_received([1.0], 0)  # engine echo: the only source of refreshes
	_assert(spin.value == 2.0, "the last enum index shows as +2 (got %s)" % spin.value)
	spin.value = -0.8  # snaps to whole steps
	_assert(spin.value == -1.0, "the knob snaps to whole numbers (got %s)" % spin.value)
	_assert(is_equal_approx(instance.get_parameter_normalized(0), 0.25),
		"-1 commits enum index 1 of 5 (got %.3f)" % instance.get_parameter_normalized(0))
	panel.queue_free()


func _test_view_widens_to_grid() -> void:
	var params := []
	for i in 14:
		params.append(_float_param(i, "Knob %d" % i))
	var instance: Object = _instance("Wide Plugin", params)
	var panel: Control = await _panel_for(instance)
	var view: Control = panel._panel_view
	var grid: Control = view.get_node("Grid")
	_assert(view.get_combined_minimum_size().x >= grid.custom_minimum_size.x,
		"the view is at least as wide as its grid (%.0f < %.0f)" % [view.get_combined_minimum_size().x, grid.custom_minimum_size.x])
	_assert(panel.size.x >= grid.custom_minimum_size.x,
		"the DevicePanel grows to fit the grid (%.0f < %.0f)" % [panel.size.x, grid.custom_minimum_size.x])
	panel.queue_free()

	# Many narrow pages with long titles (a hand-edited layout): the page tabs go in the panel's
	# header, and together they're wider than the grid, so they clip and scroll with arrow buttons.
	# The panel stays about grid-wide and the tabs stay inside it.
	var paged: Object = _instance("Paged Plugin", [_float_param(0, "Gain"), _float_param(1, "Mix")])
	panel = await _panel_for(paged)
	view = panel._panel_view
	_assert(not panel.header_tabs.visible, "a one-page view shows no header tabs")
	var one_knob: Dictionary = view.layout.pages[0].controls[0].duplicate(true)
	one_knob.rect = [0, 0, 1, 1]
	one_knob.erase("group")
	view.layout.pages.clear()
	for i in 8:
		view.layout.pages.append({"title": "A Long Page Title %d" % i, "groups": [], "controls": [one_knob.duplicate(true)]})
	view._build_page(0)
	view.header_tabs_changed.emit()
	for _i in 2:
		await process_frame
	var tabs: TabBar = panel.header_tabs
	_assert(tabs.visible and tabs.tab_count == 8, "the paged device shows its pages as header tabs (%d)" % tabs.tab_count)
	_assert(panel.header.is_ancestor_of(tabs), "the page tabs sit in the panel's top header")
	_assert(view.find_children("*", "TabBar", true, false).is_empty(), "the Simple View draws no tabs of its own")
	var all_tabs_width := 0.0
	for i in tabs.tab_count:
		all_tabs_width += tabs.get_tab_rect(i).size.x
	_assert(tabs.clip_tabs and tabs.get_offset_buttons_visible(),
		"the page tabs clip and show scroll arrows (all tabs %.0f px, bar %.0f px)" % [all_tabs_width, tabs.size.x])
	_assert(panel.size.x < all_tabs_width, "the tabs don't widen the panel to fit every tab (%.0f)" % panel.size.x)
	_assert(tabs.get_global_rect().position.x >= panel.get_global_rect().position.x
			and tabs.get_global_rect().end.x <= panel.get_global_rect().end.x,
		"the page tabs stay inside the DevicePanel (tabs %s, panel %s)" % [tabs.get_global_rect(), panel.get_global_rect()])
	var name_end: float = panel.name_label.get_global_rect().end.x
	_assert(tabs.get_global_rect().position.x - name_end <= 8.0 and tabs.get_tab_rect(0).position.x < 1.0,
		"the tabs are left-aligned, right after the name (name ends %.0f, tabs start %.0f)" % [name_end, tabs.get_global_rect().position.x])
	tabs.current_tab = 3
	_assert(view._current_page == 3, "picking a header tab switches the view's page")
	view.select_header_tab(5)
	view.header_tabs_changed.emit()
	_assert(tabs.current_tab == 5, "the header follows a page change in the view")
	panel.queue_free()

	# Two knobs use one row of the 4-row grid; the page is one full-size row, not stretched.
	var sparse: Object = _instance("Sparse Plugin", [_float_param(0, "Gain"), _float_param(1, "Mix")])
	panel = await _panel_for(sparse)
	view = panel._panel_view
	_assert(is_equal_approx(view._row_height, view.cell_size.y), "a one-row page keeps full-size rows (%.0f)" % view._row_height)
	panel.queue_free()


## The panel is DevicePanel.HEIGHT tall whatever its view holds: a full page with a title strip
## over every row shrinks its rows to fit instead of growing the panel.
func _test_fixed_height() -> void:
	var params := []
	for i in 16:
		params.append(_float_param(i, "Knob %d" % i))
	var instance: Object = _instance("Tall Plugin", params)
	var panel: Control = await _panel_for(instance)
	var view: Control = panel._panel_view
	var tall := {"title": "Tall", "groups": [], "controls": []}
	for row in 4:
		tall.groups.append({"id": "g%d" % row, "title": "Row %d" % row, "rect": [0, row, 4, 1]})
		for col in 4:
			tall.controls.append(_knob_control(row * 4 + col, [col, row, 1, 1], "g%d" % row))
	view.layout.pages.assign([tall])
	view._build_page(0)
	for _i in 2:
		await process_frame
	_assert(is_equal_approx(panel.size.y, panel.HEIGHT), "the panel is %.0f px tall (got %.0f)" % [panel.HEIGHT, panel.size.y])
	_assert(view._row_height < view.cell_size.y, "rows shrink to fit (%.0f)" % view._row_height)
	var grid_bottom: float = view._grid.get_global_rect().end.y
	var lowest := 0.0
	for control in view._controls:
		lowest = maxf(lowest, control.get_global_rect().end.y)
	_assert(lowest <= grid_bottom + 0.5, "every control stays inside the view (lowest %.0f, view bottom %.0f)" % [lowest, grid_bottom])
	_assert(view._grid.get_global_rect().end.y <= panel.get_global_rect().end.y, "the view stays inside the panel")
	panel.queue_free()


func _test_parameters_tab_default() -> void:
	var with_view: Object = _instance("With View", [_float_param(0, "Gain")])
	var panel: Control = await _panel_for(with_view)
	_assert(panel._panel_view != null, "a device with parameters gets a Simple View")
	_assert(not panel.parameters_pane.visible, "the parameter list is hidden when there's a view")
	panel.params_button.button_pressed = true
	_assert(panel.parameters_pane.visible, "the Parameters tab still opens the list on demand")
	panel.queue_free()

	# Plugins advertise their parameters after binding: no view yet → Parameters, which close
	# again once the Simple View arrives.
	var late: Object = _instance("Late Plugin", [])
	panel = await _panel_for(late)
	_assert(panel._panel_view == null, "no view for a device without parameters yet")
	late.device.add_parameter(_float_param(0, "Mix"))
	panel._on_device_parameters_updated(late)
	for _i in 4:
		await process_frame
	_assert(panel._panel_view != null, "the Simple View appears once parameters arrive")
	_assert(not panel.parameters_pane.visible, "the auto-opened Parameters close when the view arrives")
	panel.queue_free()


func _knob_control(param_id: int, rect: Array, group: String) -> Dictionary:
	return {"kind": "knob", "params": [param_id], "rect": rect, "group": group}


## Group boxes grow right and down into free space (never over another group), their controls
## spread evenly inside, and a narrower page sits at the left of a view that shrinks to fit it.
func _test_groups_fill_and_spread() -> void:
	var page := {"title": "Main", "groups": [
		{"id": "a", "title": "A", "rect": [0, 0, 4, 1]},
		{"id": "b", "title": "B", "rect": [0, 1, 2, 1]},
		{"id": "c", "title": "C", "rect": [4, 0, 2, 1]},
	], "controls": [
		_knob_control(0, [0, 0, 1, 1], "a"), _knob_control(1, [1, 0, 1, 1], "a"),
		_knob_control(2, [2, 0, 1, 1], "a"), _knob_control(3, [3, 0, 1, 1], "a"),
		_knob_control(4, [0, 1, 1, 1], "b"), _knob_control(5, [1, 1, 1, 1], "b"),
		_knob_control(6, [4, 0, 1, 1], "c"), _knob_control(7, [5, 0, 1, 1], "c"),
	]}
	var view_script: GDScript = load("res://devices/simple_view/SimpleView.gd")
	var fit: Dictionary = view_script.fit_groups(page, 6, 2)
	_assert(fit.a.box == Rect2i(0, 0, 4, 1), "a group with neighbours right and below keeps its size (%s)" % fit.a.box)
	_assert(fit.b.box == Rect2i(0, 1, 4, 1), "a narrow group grows right up to the next column (%s)" % fit.b.box)
	_assert(fit.c.box == Rect2i(4, 0, 2, 2), "a group with nothing below grows down (%s)" % fit.c.box)

	var params := []
	for i in 8:
		params.append(_float_param(i, "Knob %d" % i))
	var instance: Object = _instance("Spread Plugin", params)
	var panel: Control = await _panel_for(instance)
	var view: Control = panel._panel_view
	var narrow := {"title": "Narrow", "groups": [{"id": "n", "title": "N", "rect": [0, 0, 2, 1]}],
		"controls": [_knob_control(0, [0, 0, 1, 1], "n"), _knob_control(1, [1, 0, 1, 1], "n")]}
	view.layout.pages.assign([page, narrow])
	view._build_page(0)
	await process_frame
	var centers := {}
	for control in view._controls:
		centers[int(control.control_data.params[0])] = control.position.x + control.size.x * 0.5
	var cell: float = view.cell_size.x
	var gap := (4 * cell - 2 * cell) / 3.0  # gap, knob, gap, knob, gap
	_assert(absf(centers[4] - (gap + cell * 0.5)) < 1.0 and absf(centers[5] - (2 * gap + cell * 1.5)) < 1.0,
		"B's two knobs are spaced evenly across its grown box (centers %.0f, %.0f)" % [centers[4], centers[5]])
	_assert(absf(centers[1] - 1.5 * view.cell_size.x) < 1.0, "A's knobs stay on their cells (%.0f)" % centers[1])
	var title: Label = view._group_boxes[0].get_child(0)
	_assert(title.get_theme_color("font_color") == view.group_title_color, "group titles use the group title color")
	_assert(title.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "group titles are centered")
	var box_a: Control = view._group_boxes.filter(func(b): return b.get_child(0).text == "A")[0]
	var box_c: Control = view._group_boxes.filter(func(b): return b.get_child(0).text == "C")[0]
	var box_gap := box_c.position.x - (box_a.position.x + box_a.size.x)
	_assert(is_equal_approx(box_gap, view.group_margin * 2.0), "neighbouring group boxes are %.0f px apart" % box_gap)
	var knob_title: Label = view._controls[0].get_node("Title")
	_assert(knob_title.get_theme_color("font_color").a < title.get_theme_color("font_color").a,
		"control titles are dimmer than group titles")

	_assert(is_equal_approx(view._grid.custom_minimum_size.x, 6 * view.cell_size.x),
		"a 6-column page makes the grid 6 columns wide (%.0f)" % view._grid.custom_minimum_size.x)
	view._build_page(1)
	await process_frame
	var left: float = view._controls[0].position.x
	_assert(absf(left - view.cell_margin * 0.5) < 1.0, "a 2-column page starts at the left (first knob at %.0f)" % left)
	_assert(is_equal_approx(view._grid.custom_minimum_size.x, 2 * view.cell_size.x),
		"the grid shrinks to a 2-column page (%.0f)" % view._grid.custom_minimum_size.x)
	panel.queue_free()


## ----------------------------------------------------------------------------
## Slot tiles (spec 040, REQ-024 – REQ-028)
## ----------------------------------------------------------------------------

## A slotted fake device (a "PolySynth" with Note FX and FX slots, plus `Gain` and `Mix`) on a
## fresh channel, and the fake Transpose and Delay devices the tile tests use.
func _slotted_instance(title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	for id in ["sonara.builtin.chain", "sonara.builtin.transpose", "sonara.builtin.delay"]:
		if not registry._devices.has(id):
			var category: int = _device_script.DeviceCategory.NoteEffect if id.ends_with("transpose") \
				else _device_script.DeviceCategory.Effect
			var fake: Object = _device_script.new(id, id, category, _device_script.DeviceType.BuiltIn)
			fake.is_container = id.ends_with("chain")
			registry._devices[id] = fake
	var device_id := "sonara.test.slotted_%s.%d" % [title.to_lower(), Time.get_ticks_usec()]
	var device: Object = _device_script.new(device_id, title,
		_device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.is_container = true
	device.slots.append({"key": "note_fx", "name": "Note FX", "kind": "note"})
	device.slots.append({"key": "fx", "name": "FX", "kind": "audio"})
	device.add_parameter(_float_param(0, "Gain"))
	device.add_parameter(_float_param(1, "Mix"))
	registry._devices[device_id] = device
	var channel: Object = _project.create_instrument_track(title).channel
	var instance: Object = _device_instance_script.new(device, channel.id, 0)
	channel.add_device(instance)
	return instance


func _tiles(node: Node, out: Array = []) -> Array:
	for child in node.get_children():
		if child is Control and child.has_method("bind_to_slot") and not child.is_queued_for_deletion():
			out.append(child)
		_tiles(child, out)
	return out


func _tile_for(panel: Control, key: String) -> Control:
	for tile in _tiles(panel._panel_view):
		if tile.key == key:
			return tile
	return null


func _click(tile: Control) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	tile._gui_input(event)


func _test_slot_tiles_render_with_count() -> void:
	var instance: Object = _slotted_instance("Poly")
	var panel: Control = await _panel_for(instance)
	var tiles := _tiles(panel._panel_view)
	_assert(tiles.size() == 2, "the Simple View has one tile per slot (%d)" % tiles.size())
	var titles: Array = tiles.map(func(t): return t.container.slot_title(t.key))
	_assert(titles == ["Note FX", "FX"], "tiles are labelled with the slot names (%s)" % [titles])
	_assert(tiles.all(func(t): return t.show_count), "tiles show a device count")
	var note_tile := _tile_for(panel, "note_fx")
	_assert(note_tile != null and note_tile.device_count() == 0, "an empty slot counts 0")
	var channel: Object = instance.get_channel()
	var transpose: Object = _device_instance_script.new(
		root.get_node("AssetService").device_registry._devices["sonara.builtin.transpose"], channel.id, -1)
	channel.add_device(transpose, -1, instance.slot_chain("note_fx"))
	instance.slots_changed.emit()
	_assert(note_tile.device_count() == 1, "after adding a Transpose, the Note FX tile counts 1 (%d)" % note_tile.device_count())
	_assert(_tile_for(panel, "fx").device_count() == 0, "the FX tile still counts 0")
	panel.queue_free()


func _test_slot_tile_click_toggles() -> void:
	var instance: Object = _slotted_instance("PolyClick")
	var panel: Control = await _panel_for(instance)
	var fx := _tile_for(panel, "fx")
	_click(fx)
	_assert(instance.is_slot_open("fx") and fx.is_open(), "clicking the FX tile opens FX")
	_click(fx)
	_assert(not instance.is_slot_open("fx") and not fx.is_open(), "clicking it again closes it")
	_click(fx)
	_click(_tile_for(panel, "note_fx"))
	_assert(instance.is_slot_open("note_fx") and not instance.is_slot_open("fx"), "opening Note FX closes FX")
	panel.queue_free()


func _test_drop_on_slot_tile() -> void:
	var instance: Object = _slotted_instance("PolyDrop")
	var panel: Control = await _panel_for(instance)
	var fx := _tile_for(panel, "fx")
	var asset: Object = load("res://browser/Asset.gd").new()
	asset.type = load("res://browser/Asset.gd").TYPE.Device
	asset.path = "sonara.builtin.delay"
	_assert(fx._can_drop_data(Vector2.ZERO, asset), "the FX tile accepts a Delay")
	fx._drop_data(Vector2.ZERO, asset)
	var devices: Array = instance.slot_devices("fx")
	_assert(devices.size() == 1 and devices[0].device.device_id == "sonara.builtin.delay",
		"the Delay is the FX slot's last device (%d)" % devices.size())
	_assert(instance.is_slot_open("fx"), "the slot opens after the drop")
	_assert(not _tile_for(panel, "note_fx")._can_drop_data(Vector2.ZERO, asset), "the Note FX tile refuses a Delay")
	panel.queue_free()


func _test_edited_layout_gets_slot_tiles_appended() -> void:
	var store: Object = load("res://devices/simple_view/SimpleLayoutStore.gd")
	var instance: Object = _slotted_instance("PolyEdit")
	var device: Object = instance.device
	var layout = store.load_or_generate(device, device.parameters)
	var before: Array = []
	for control in layout.pages[0].controls:
		if control.kind != "slot":
			before.append(control.duplicate(true))
	# a user edit: the tiles are gone and the layout is marked edited
	layout.pages[0].controls = before.duplicate(true)
	layout.generated = false
	store.save(layout)
	store.clear_cache()
	var loaded = store.load_or_generate(device, device.parameters)
	var kept: Array = loaded.pages[0].controls.filter(func(c): return c.kind != "slot")
	var tiles: Array = loaded.pages[0].controls.filter(func(c): return c.kind == "slot")
	_assert(kept == before, "every other control stays where it was")
	_assert(tiles.map(func(t): return t.slot) == ["note_fx", "fx"], "both tiles are appended in table order")
	var right := 0
	for c in kept:
		right = maxi(right, c.rect[0] + c.rect[2])
	_assert(tiles.all(func(t): return t.rect[0] >= right), "the tiles sit at the end of Main")
	_assert(loaded.validate().is_empty(), "the layout stays valid: %s" % [loaded.validate()])
	_assert(loaded.reconcile_slots(PackedStringArray(["note_fx", "fx"])).is_empty(), "reconciling again adds nothing")
	store.clear_cache()
