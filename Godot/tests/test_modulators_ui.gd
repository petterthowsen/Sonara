# Modulators pane (spec 018 phase 8): tiles from the model, the + menu, the tile context menu,
# assign mode reaching a child device's controls but not a sibling's, Esc, and the SimpleControl
# wiring.
# Run: godot --headless --path Godot -s tests/test_modulators_ui.gd -- --test
extends TestBase

const SYNTH_ID := "test.synth8"
const CHAIN_ID := "test.chain8"

var _registry: Object
var _inst_script: GDScript
var _project_script: GDScript

# Loaded at runtime: a parse-time reference would compile DeviceInstance (through ModulatorsPane)
# before the autoloads exist, as in test_mod_assign_ui.gd.
var _mod_assign: GDScript
var _pane_script: GDScript
var _drag_script: GDScript


func suite_name() -> String:
	return "Modulators UI"


func run_tests() -> void:
	_inst_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_mod_assign = load("res://devices/modulators/ModAssign.gd")
	_pane_script = load("res://devices/modulators/ModulatorsPane.gd")
	_drag_script = load("res://devices/modulators/ModulatorDrag.gd")
	_setup()
	await _test_pane_tiles_and_add()
	await _test_context_menu_routes()
	await _test_column_major_grid()
	await _test_square_sizing()
	await _test_placeholder_add_and_max()
	await _test_placeholder_icon()
	await _test_panel_selection_and_wire()
	await _test_assign_reaches_child_not_sibling()
	await _test_control_shows_only_focused_source()
	await _test_esc_exits_assign()
	await _test_simple_control_assign()
	await _test_panel_tab_and_dot()
	await _test_xy_pad_pane()
	await _test_xy_pad_drag()
	await _test_xy_wire_buttons()
	await _test_xy_pad_panel_model()
	await _test_sidechain_source_menu()
	await _test_options_fit_the_panel()
	_mod_assign.end()


# --- fixtures ------------------------------------------------------------------------------

func _setup() -> void:
	_registry = load("res://data/DeviceRegistry.gd").new()
	_registry._on_modulator_kind_received(_lfo_kind_args())
	_registry._on_modulator_kind_received(_adsr_kind_args())
	_registry._on_modulator_kind_received(["velocity", "Velocity", 0, 0])
	_registry._on_modulator_kind_received(_knob_kind_args())
	_registry._on_modulator_kind_received(_xy_kind_args("xyx", "XY X"))
	_registry._on_modulator_kind_received(_xy_kind_args("xyy", "XY Y"))
	_registry._on_modulator_kind_received(_sidechain_kind_args())
	var asset_registry: Object = root.get_node("AssetService").device_registry
	for kind_id in ["lfo", "adsr", "velocity", "knob", "xyx", "xyy", "sidechain"]:
		asset_registry.modulator_kinds[kind_id] = _registry.get_modulator_kind(kind_id)
	_registry._on_builtin_info_received([
		SYNTH_ID, "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		1,
		31, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1, 1,
		0,
		0,
	])
	_registry._on_builtin_info_received([
		CHAIN_ID, "Chain", "utility", "", 0, 2, 2, 0, "", 0, 0, 1,
	])
	for device_id in [SYNTH_ID, CHAIN_ID]:
		asset_registry._devices[device_id] = _registry.get_device(device_id)


func _enum_param(id: int, name: String, values: Array, default_index: int) -> Array:
	var args: Array = [id, name, "", "enum", 1, 0.0, float(values.size() - 1), float(default_index), 0, 1.0, values.size()]
	args.append_array(values)
	args.append_array(["", 1, 0])
	return args


func _float_param(id: int, name: String, unit: String, minv: float, maxv: float, default_value: float, is_log: bool) -> Array:
	return [id, name, unit, "float", 1, minv, maxv, default_value, 1 if is_log else 0, 1.0, 0, "", 1, 0]


func _lfo_kind_args() -> Array:
	var args: Array = ["lfo", "LFO", 1, 5]
	args.append_array(_enum_param(0, "Shape", ["Sine", "Triangle", "Saw"], 0))
	args.append_array(_float_param(10, "Rate", "Hz", 0.02, 40.0, 2.0, true))
	args.append_array(_enum_param(20, "Sync", ["Off", "1/4", "1/8"], 0))
	args.append_array(_enum_param(30, "Retrigger", ["Free", "Note"], 0))
	args.append_array(_float_param(40, "Phase", "deg", 0.0, 360.0, 0.0, false))
	return args


func _adsr_kind_args() -> Array:
	var args: Array = ["adsr", "Envelope", 0, 4]
	args.append_array(_float_param(0, "Attack", "s", 0.0005, 10.0, 0.005, false))
	args.append_array(_float_param(10, "Decay", "s", 0.0005, 10.0, 0.3, false))
	args.append_array(_float_param(20, "Sustain", "", 0.0, 1.0, 0.5, false))
	args.append_array(_float_param(30, "Release", "s", 0.0005, 10.0, 0.3, false))
	return args


## Spec 036 kinds (same fixtures as test_device_modulators.gd).
func _knob_kind_args() -> Array:
	var args: Array = ["knob", "Knob", 0, 2]
	args.append_array(_float_param(0, "Value", "", 0.0, 1.0, 0.0, false))
	args.append_array(_enum_param(10, "Polarity", ["Unipolar", "Bipolar"], 0))
	return args


func _xy_kind_args(kind_id: String, kind_name: String) -> Array:
	var args: Array = [kind_id, kind_name, 1, 1]
	args.append_array(_float_param(0, "Position", "", 0.0, 1.0, 0.5, false))
	return args


func _sidechain_kind_args() -> Array:
	var args: Array = ["sidechain", "Sidechain", 0, 7]
	args.append_array(_float_param(0, "Low Cut", "Hz", 20.0, 20000.0, 20.0, true))
	args.append_array(_float_param(10, "High Cut", "Hz", 20.0, 20000.0, 20000.0, true))
	args.append_array(_float_param(20, "Attack", "ms", 0.0, 500.0, 5.0, false))
	args.append_array(_float_param(30, "Release", "ms", 5.0, 2000.0, 150.0, false))
	args.append_array(_float_param(40, "Source", "", 0.0, 999.0, 0.0, false))
	args.append_array(_float_param(50, "Gain", "dB", -24.0, 24.0, 0.0, false))
	args.append_array(_float_param(60, "Amount", "%", 0.0, 100.0, 100.0, false))
	return args


func _synth() -> Object:
	return root.get_node("AssetService").device_registry.get_device(SYNTH_ID)


func _chain() -> Object:
	return root.get_node("AssetService").device_registry.get_device(CHAIN_ID)


func _instance() -> Object:
	return _inst_script.new(_synth(), 2, 0)


func _knob() -> RotaryKnob:
	var knob := RotaryKnob.new()
	knob.position = Vector2(100, 100)
	knob.size = Vector2(60, 60)
	root.add_child(knob)
	knob.size = Vector2(60, 60)
	return knob


func _kind_index(popup: PopupMenu, kind_id: String) -> int:
	for i in popup.item_count:
		if str(popup.get_item_metadata(i)) == kind_id:
			return i
	return -1

## A minimal `modulation` payload: no kind 0/1 records, one kind 2 display-state record
## (mod id, stage, x, value) in the trailing ext block, as the engine writes it.
func _modulation_payload(mod_id: int, x: float, value: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array([0, 0])          # u16 record count = 0
	b.append_array([1, 0])          # u16 ext count = 1
	b.append(2)                    # kind 2
	b.append(10)                    # record length
	b.append(mod_id)
	b.append(0)                     # stage
	b.append_array(PackedFloat32Array([x]).to_byte_array())
	b.append_array(PackedFloat32Array([value]).to_byte_array())
	return b


## Container with two synth children plus a top-level sibling on a project channel.
## Returns `[container, a, b, lfo_mod, sibling]`.
func _container_with_children() -> Array:
	var project = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var container = _inst_script.new(_chain(), ch.id, -1)
	ch.add_device(container)
	var a = _inst_script.new(_synth(), ch.id, -1)
	var b = _inst_script.new(_synth(), ch.id, -1)
	ch.add_device(a, -1, container)
	ch.add_device(b, -1, container)
	var sibling = _inst_script.new(_synth(), ch.id, -1)
	ch.add_device(sibling)
	return [container, a, b, container.add_modulator("lfo"), sibling]


# --- tests ---------------------------------------------------------------------------------

func _test_pane_tiles_and_add() -> void:
	var inst = _instance()
	var mod = inst.add_modulator("lfo")
	var pane = _pane_script.new()
	root.add_child(pane)
	await pane.bind_to_device(inst)
	await process_frame
	_assert(pane._tiles.size() == 1 and pane._tiles[0].modulator == mod, "the pane builds a tile per modulator")

	var popup: PopupMenu = pane._kind_menu
	_assert(popup.item_count == 6, "the + menu lists the advertised kinds (xyy hidden)")
	var index := _kind_index(popup, "adsr")
	_assert(index >= 0, "the envelope kind is in the menu")
	pane._on_add_kind(index)
	_assert(inst.modulators.size() == 2, "the + menu adds a modulator")
	_assert(pane._tiles.size() == 2 and pane._selected_mod_id == inst.modulators[1].mod_id, "the new tile is selected")
	_assert(pane._options.get("envelope_control") != null and pane._options.envelope.stages == "adsr",
		"the envelope detail shows an EnvelopeControl")
	pane.queue_free()


func _test_context_menu_routes() -> void:
	var inst = _instance()
	var mod = inst.add_modulator("lfo")
	inst.set_route_amount(mod.mod_id, "param/31", 0.35)
	var pane = _pane_script.new()
	root.add_child(pane)
	await pane.bind_to_device(inst)
	await process_frame
	var tile = pane._tiles[0]
	tile._open_menu()
	var route_index := -1
	for i in tile._menu.item_count:
		if str(tile._menu.get_item_metadata(i)) == "param/31":
			route_index = i
			_assert(tile._menu.get_item_text(i).begins_with("Cutoff"), "the route entry names its target (%s)" % [tile._menu.get_item_text(i)])
			_assert(tile._menu.get_item_text(i).contains("+35 %"), "and its amount")
	_assert(route_index >= 0, "the context menu lists the route")
	tile._on_menu_id(route_index)
	_assert(inst.get_modulator(mod.mod_id).routes.is_empty(), "the route entry disconnects it")
	pane.queue_free()


## A pane bound to a fresh synth instance with `n` modulators, laid out at `pane_size`.
func _pane_bound(n: int, pane_size := Vector2(420, 330)) -> Array:
	var inst = _instance()
	var pane = _pane_script.new()
	root.add_child(pane)
	pane.size = pane_size
	for i in range(n):
		inst.add_modulator("lfo" if i == 0 else "velocity")
	await pane.bind_to_device(inst)
	await process_frame
	await process_frame
	return [pane, inst]


## Column-major: panels fill column 0 top to bottom, placeholders trail.
func _test_column_major_grid() -> void:
	var s := await _pane_bound(0)
	var pane = s[0]
	var inst = s[1]
	_assert(pane._grid.get_child_count() == 1, "an empty device shows one column")
	var empty_column: VBoxContainer = pane._grid.get_child(0)
	_assert(empty_column.get_child_count() == 3, "with three placeholder cells")
	_assert(empty_column.get_child(0) is Button, "empty cells are placeholder buttons")

	for i in range(3):
		inst.add_modulator("velocity")
		await process_frame
	await process_frame
	_assert(pane._grid.get_child_count() == 2, "three modulators grow a second column: %d" % pane._grid.get_child_count())
	var column0: VBoxContainer = pane._grid.get_child(0)
	for cell in column0.get_children():
		_assert(cell is ModulatorPanel, "the first column holds the panels")
	for cell in pane._grid.get_child(1).get_children():
		_assert(cell is Button, "the second column holds only placeholders")

	inst.add_modulator("velocity")
	await process_frame
	await process_frame
	var column1: VBoxContainer = pane._grid.get_child(1)
	_assert(pane._grid.get_child_count() == 2, "four modulators still fit two columns")
	_assert(column1.get_child(0) is ModulatorPanel and column1.get_child(0).modulator == inst.modulators[3],
		"panel 3 sits at column 1, row 0")
	_assert(column1.get_child(1) is Button and column1.get_child(2) is Button, "with two trailing placeholders")

	inst.remove_modulator(inst.modulators[3].mod_id)
	await process_frame
	await process_frame
	_assert(pane._grid.get_child_count() == 2, "deleting 4 → 3 keeps two columns")
	inst.remove_modulator(inst.modulators[2].mod_id)
	await process_frame
	await process_frame
	_assert(pane._grid.get_child_count() == 1, "deleting 3 → 2 shrinks to one column")
	pane.queue_free()


## Square cells sized from the pane height, applied only when the side changes.
func _test_square_sizing() -> void:
	var s := await _pane_bound(4)
	var pane = s[0]
	var side: int = pane._side
	_assert(side > 0, "the side follows the pane height (%d)" % side)
	_assert(pane._layout_count > 0, "the layout ran")
	var count_before: int = pane._layout_count
	pane._layout_panel_size()
	pane._layout_panel_size()
	_assert(pane._layout_count == count_before, "the same height doesn't re-trigger a layout")
	for column in pane._grid.get_children():
		for cell in column.get_children():
			_assert(absf(cell.size.x - side) < 1.5 and absf(cell.size.y - side) < 1.5,
				"every cell is %d × %d" % [side, side])
			_assert(absf(cell.size.x - cell.size.y) <= 1.0, "and laid out square")
	var column0: VBoxContainer = pane._grid.get_child(0)
	var a: Control = column0.get_child(0)
	var b: Control = column0.get_child(1)
	_assert(absf(b.position.y - (a.position.y + a.size.y) - pane.SEP) <= 1.0, "vertical neighbours are 2 px apart")
	var col1: VBoxContainer = pane._grid.get_child(1)
	_assert(absf(col1.position.x - (column0.position.x + column0.size.x) - pane.SEP) <= 1.0, "columns are 2 px apart")
	pane.queue_free()

	# Three modulators fill column 0; column 1 holds only placeholders and stays narrow.
	s = await _pane_bound(3)
	pane = s[0]
	await process_frame
	var narrow: VBoxContainer = pane._grid.get_child(1)
	for cell in narrow.get_children():
		_assert(cell is Button, "the second column holds only placeholders")
		_assert(absf(cell.size.x - pane.PLACEHOLDER_COLUMN_WIDTH) < 1.5 and absf(cell.size.y - pane._side) < 1.5,
			"a placeholder-only column is a narrow rectangle (%s)" % str(cell.size))
	pane.queue_free()


## Placeholders add through the shared kind menu; the grid caps at MAX_MODULATORS.
func _test_placeholder_add_and_max() -> void:
	var s := await _pane_bound(0)
	var pane = s[0]
	var inst = s[1]
	for placeholder in pane._placeholders:
		_assert(not placeholder.disabled and placeholder.tooltip_text == "Add modulator",
			"placeholders offer the + menu")
	var index := _kind_index(pane._kind_menu, "lfo")
	_assert(index >= 0, "the placeholder menu lists every registry kind")
	_assert(_kind_index(pane._kind_menu, "adsr") >= 0, "including the envelope kind")
	pane._on_add_kind(index)
	await process_frame
	await process_frame
	_assert(inst.modulators.size() == 1, "picking a kind appends the modulator")
	_assert(pane._selected_mod_id == inst.modulators[0].mod_id, "and selects it")
	_assert(pane._detail_title != null and pane._detail_title.text == inst.modulators[0].name,
		"the detail column shows the new modulator")

	for i in range(inst.MAX_MODULATORS - 1):
		inst.add_modulator("velocity")
	await process_frame
	await process_frame
	_assert(pane._placeholders.size() == 1, "at the cap exactly one placeholder remains")
	_assert(pane._placeholders[0].disabled, "and it is disabled")
	_assert(pane._placeholders[0].tooltip_text == "Maximum of 32 modulators", "with the capacity tooltip")
	pane._on_add_kind(index)
	_assert(inst.modulators.size() == 32, "the disabled menu still can't exceed the maximum")
	pane.queue_free()


## The `+` is the placeholder button's own icon: centered, at its own size, whatever the cell's.
func _test_placeholder_icon() -> void:
	var s := await _pane_bound(1)
	var pane = s[0]
	_assert(pane._placeholders.size() == 2, "two placeholders trail one panel")
	for placeholder in pane._placeholders:
		_assert(placeholder.icon != null and placeholder.get_child_count() == 0,
			"the + is the button's icon, not a positioned child")
		_assert(not placeholder.expand_icon, "the icon keeps its own size")
		_assert(placeholder.icon_alignment == HORIZONTAL_ALIGNMENT_CENTER
			and placeholder.vertical_icon_alignment == VERTICAL_ALIGNMENT_CENTER, "and is centered")
	pane.queue_free()


## Selection swaps the DeviceCard variation; the wire button is centered at the bottom.
func _test_panel_selection_and_wire() -> void:
	var s := await _pane_bound(1)
	var pane = s[0]
	var inst = s[1]
	var tile: ModulatorPanel = pane._tiles[0]
	pane._select(-1)
	await process_frame
	_assert(tile.theme_type_variation == &"DeviceCard", "an unselected panel is a DeviceCard")
	pane._select(inst.modulators[0].mod_id)
	_assert(tile.theme_type_variation == &"DeviceCardSelected", "the selected panel is DeviceCardSelected")
	_assert(tile.get_theme_stylebox("panel") != null, "the variation provides a style")
	pane._select(-1)
	_assert(tile.theme_type_variation == &"DeviceCard", "deselecting restores DeviceCard")
	var wire_rect: Rect2 = tile._wire.get_global_rect()
	var panel_rect: Rect2 = tile.get_global_rect()
	_assert(absf(wire_rect.get_center().x - panel_rect.get_center().x) <= 1.0, "the wire button is centered")
	_assert(wire_rect.end.y <= panel_rect.end.y + 0.5, "and sits at the bottom")
	pane.queue_free()


func _test_assign_reaches_child_not_sibling() -> void:
	var setup := _container_with_children()
	var container = setup[0]
	var a = setup[1]
	var b = setup[2]
	var mod = setup[3]
	var sibling = setup[4]
	var knob_a := _knob()
	var knob_b := _knob()
	var knob_sibling := _knob()
	_mod_assign.attach(knob_a, a, 31)
	_mod_assign.attach(knob_b, b, 31)
	_mod_assign.attach(knob_sibling, sibling, 31)
	_mod_assign.begin(container, mod.mod_id)
	await process_frame
	_assert(knob_a.mod_assign_active and knob_b.mod_assign_active, "a container's assign mode reaches its children's controls")
	_assert(not knob_sibling.mod_assign_active, "but not a device beside it")
	_assert(knob_a.mod_assign_color == _mod_assign.active_color(), "the child control takes the source colour")

	knob_a.mod_amount_changed.emit(0.4)
	_assert(is_equal_approx(float(container.get_modulator(mod.mod_id).get_route("child/0/param/31")), 0.4),
		"dragging the child's control writes the relative route")
	_assert(knob_a.mod_ranges.size() == 1, "the control draws the route")
	_assert(not _mod_assign.is_target(sibling), "the neighbouring device is not an assign target")
	knob_a.queue_free()
	knob_b.queue_free()
	knob_sibling.queue_free()


func _test_control_shows_only_focused_source() -> void:
	_mod_assign.end()
	var inst = _instance()
	var lfo = inst.add_modulator("lfo")
	var env = inst.add_modulator("lfo")
	inst.set_route_amount(lfo.mod_id, "param/31", 0.3)
	inst.set_route_amount(env.mod_id, "param/31", -0.2)
	var knob := _knob()
	_mod_assign.attach(knob, inst, 31)
	await process_frame
	_assert(knob.mod_ranges.is_empty(), "with no modulator focused, the control shows no range")
	_mod_assign.set_hover(inst, env.mod_id, true)
	_assert(knob.mod_ranges.size() == 1, "hovering a modulator shows one range")
	_assert(is_equal_approx(float(knob.mod_ranges[0]["amount"]), -0.2), "and it is the hovered modulator's route")
	_mod_assign.set_hover(inst, env.mod_id, false)
	_assert(knob.mod_ranges.is_empty(), "leaving the modulator hides the range again")
	knob.queue_free()


func _test_esc_exits_assign() -> void:
	var setup := _container_with_children()
	_mod_assign.begin(setup[0], setup[3].mod_id)
	var pane = _pane_script.new()
	root.add_child(pane)
	await process_frame
	_assert(_mod_assign.is_active(), "assign mode is on")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	pane._unhandled_input(esc)
	_assert(not _mod_assign.is_active(), "Esc leaves assign mode")
	pane.queue_free()


func _test_simple_control_assign() -> void:
	var setup := _container_with_children()
	var container = setup[0]
	var a = setup[1]
	var mod = setup[3]
	var control = load("res://devices/simple_view/SimpleControl.tscn").instantiate()
	control.position = Vector2(100, 100)
	control.size = Vector2(120, 90)
	root.add_child(control)
	control.bind(a, {"kind": "knob", "params": [31], "rect": [0, 0, 1, 1]})
	await process_frame
	var knob: RotaryKnob = control._inner
	_assert(knob != null, "the SimpleControl built its knob")
	_mod_assign.begin(container, mod.mod_id)
	await process_frame
	_assert(knob.mod_assign_active, "assign mode reaches a Simple View knob")
	knob.size = Vector2(60, 60)
	knob.mod_amount_changed.emit(0.5)
	_assert(is_equal_approx(float(container.get_modulator(mod.mod_id).get_route("child/0/param/31")), 0.5),
		"the Simple View drag sets the route")
	_mod_assign.end()
	await process_frame
	_assert(not knob.mod_assign_active, "leaving assign mode clears the knob")
	control.queue_free()


## The DevicePanel wiring: the tab is there for every device, opens the pane, and the collapsed
## header marks a device that has modulators.
func _test_panel_tab_and_dot() -> void:
	var panel = load("res://devices/device_lane/DevicePanel.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	var inst = _instance()
	var mod = inst.add_modulator("lfo")
	await panel.bind_to_device(inst)
	await process_frame
	_assert(panel.modulators_button.visible, "the Modulators tab is available")
	panel.modulators_button.set_pressed_no_signal(true)
	panel._update_tab_panes()
	_assert(panel.modulators_pane.visible, "pressing the tab shows the pane")
	_assert(panel.modulators._tiles.size() == 1, "the pane built a tile")
	for i in 10:
		await process_frame
	# The pane was built hidden; the reveal settles its height. The display must be sized
	# from the SETTLED height (it was sized from a transient one and drew nothing at
	# zero height until a click resized the pane).
	var tile: ModulatorPanel = panel.modulators._tiles[0]
	_assert(tile._display.size.y > 0.0,
		"revealing the tab sizes the display (got %s)" % str(tile._display.size))
	# A stream payload lights the display's dot without any further interaction.
	ModLive.view_shown(inst)
	ModLive.holder()._on_data(inst.osc_path(), "modulation", _modulation_payload(mod.mod_id, 0.25, 0.5))
	await process_frame
	_assert(tile._display.has_dot(), "the display has its live dot after a payload")
	ModLive.view_hidden(inst)
	panel._set_collapsed(true)
	_assert(panel._mod_dot.visible, "the collapsed header marks a device with modulators")
	panel.free()


# --- spec 036 -------------------------------------------------------------------------------

## A fresh pane bound to a cleared instance.
func _pane_for(inst: Object) -> Object:
	var pane = _pane_script.new()
	root.add_child(pane)
	pane.size = Vector2(420, 330)
	await pane.bind_to_device(inst)
	await process_frame
	await process_frame
	return pane


func _test_xy_pad_pane() -> void:
	var inst = _instance()
	inst.modulators.clear()
	var pane = await _pane_for(inst)
	var xy_index := _kind_index(pane._kind_menu, "xyx")
	_assert(xy_index >= 0, "the + menu lists the XY Pad")
	_assert(_kind_index(pane._kind_menu, "xyy") == -1, "and hides the Y slot kind")
	_assert(pane._kind_menu.get_item_text(xy_index) == "XY Pad", "the entry is labelled XY Pad")
	pane._on_add_kind(xy_index)
	_assert(inst.modulators.size() == 2 and inst.modulators[0].kind == "xyx"
		and inst.modulators[1].kind == "xyy", "picking XY Pad adds the two slots adjacent")
	_assert(pane._tiles.size() == 1, "one tile for the pair")
	var tile: ModulatorPanel = pane._tiles[0]
	_assert(tile.pad != null and tile.pad.x == inst.modulators[0] and tile.pad.y == inst.modulators[1],
		"the tile is a pair tile")
	_assert(tile._display is XYPadPanel, "its display is an XYPadPanel")
	_assert(pane._selected_mod_id == inst.modulators[0].mod_id, "the pair is selected")
	_assert(pane._detail_pad != null and pane._detail_pad.x == tile.pad.x
		and pane._detail_pad.y == tile.pad.y and pane._options.get("slider") != null,
		"the detail shows the pair's XY slider")
	_assert(pane._detail_title.text == tile.pad.name, "titled after the pad")

	inst.rename_modulator(tile.pad.x.mod_id, "Macro")
	_assert(tile.pad.y.name == "Macro Y", "renaming X renames the pair's Y")
	_assert(tile._name_label.text == "Macro", "the tile header shows the pair name")

	var dup: XYPad = inst.duplicate_xy_pad(tile.pad)
	_assert(dup != null and inst.xy_pairs().size() == 2 and pane._tiles.size() == 2,
		"duplicating adds one more tile")
	inst.remove_xy_pad(dup)
	await process_frame
	await process_frame
	_assert(inst.modulators.size() == 2 and pane._tiles.size() == 1, "deleting removes the pair's tile")
	pane.queue_free()


func _test_xy_pad_drag() -> void:
	# Plain first, then a pair. A drop on another tile swaps the two cells; the pair stays adjacent.
	var inst = _instance()
	inst.modulators.clear()
	var plain = inst.add_modulator("velocity")
	var pad: XYPad = inst.add_xy_pad()
	var pane = await _pane_for(inst)
	_assert(pane._tiles.size() == 2, "a pair renders as one tile")

	var drag: Object = _drag_script.start(pane, plain)
	_assert(drag.mod_count == 1, "a plain modulator drags as one entry")
	var target: Object = _drag_script.resolve(pane, drag, pane._tiles[1].get_global_rect().get_center())
	_assert(target.is_valid() and target.mod_id == pad.x.mod_id, "the pair tile is a target")
	_assert(target.commit(drag), "the drop commits")
	pane._end_drag()
	await process_frame
	await process_frame
	_assert(inst.modulators[0].kind == "xyx" and inst.modulators[1].kind == "xyy"
		and inst.modulators[2].kind == "velocity", "the plain tile swapped past the pair, still adjacent")
	_assert(pad.x.cell == 0 and pad.y.cell == 0 and plain.cell == 1, "both pair slots share the pair's cell")

	drag = _drag_script.start(pane, pad.x)
	_assert(drag.mod_count == 2, "the pair drags as one block of two")
	target = _drag_script.resolve(pane, drag, pane._tiles[1].get_global_rect().get_center())
	_assert(target.is_valid() and target.mod_id == plain.mod_id, "the plain tile is a target")
	_assert(target.commit(drag), "committed")
	pane._end_drag()
	await process_frame
	await process_frame
	_assert(inst.modulators[0].kind == "velocity" and inst.modulators[1].kind == "xyx"
		and inst.modulators[2].kind == "xyy", "the pair swapped back, still adjacent")
	_assert(inst.xy_pairs().size() == 1, "the pair is intact after both drags")

	drag = _drag_script.start(pane, pad.x)
	_assert(not _drag_script.resolve(pane, drag, pane._tiles[1].get_global_rect().get_center()).is_valid(),
		"the dragged pair's own tile is invalid")
	pane.queue_free()


func _test_xy_wire_buttons() -> void:
	var inst = _instance()
	inst.modulators.clear()
	var pad: XYPad = inst.add_xy_pad()
	var plain = inst.add_modulator("velocity")
	var pane = await _pane_for(inst)
	var pair_tile: ModulatorPanel = pane._tiles[0]
	_assert(pair_tile._wire == null and pair_tile._wire_buttons.size() == 2, "a pair tile has two wire buttons")
	for i in 2:
		var button: Button = pair_tile._wire_buttons[i]
		_assert(button.toggle_mode and button.flat, "the X/Y buttons are flat toggles (REQ-010)")
		_assert(button.text == ("X" if i == 0 else "Y"), "labelled X and Y")
		_assert(button.icon != null, "with the cable icon")
	var x_color: Color = ModDisplay.source_color(0)
	var y_color: Color = ModDisplay.source_color(1)
	_assert(pair_tile._wire_buttons[0].get_theme_color("font_color") == x_color, "X carries its slot colour")
	_assert(pair_tile._wire_buttons[1].get_theme_color("font_color") == y_color, "Y carries its slot colour")
	_assert(pair_tile._wire_buttons[0].get_theme_color("icon_normal_color") == x_color,
		"and the icon carries it too")
	_assert(pair_tile._wire_buttons[1].get_theme_color("font_pressed_color") == y_color,
		"the pressed state is coloured as well")

	pair_tile._on_wire_toggled(true, pad.x.mod_id)
	_assert(_mod_assign.is_active_for(inst, pad.x.mod_id), "X begins assign for the xyx slot")
	_assert(not _mod_assign.is_active_for(inst, pad.y.mod_id), "and not for xyy")
	_assert(pair_tile._wire_buttons[0].button_pressed and not pair_tile._wire_buttons[1].button_pressed,
		"only the X button shows active")
	pair_tile._on_wire_toggled(false, pad.x.mod_id)
	_assert(not _mod_assign.is_active(), "releasing X ends assign")
	pair_tile._on_wire_toggled(true, pad.y.mod_id)
	_assert(_mod_assign.is_active_for(inst, pad.y.mod_id), "Y begins assign for the xyy slot")
	_mod_assign.end()

	var plain_tile: ModulatorPanel = pane._tiles[1]
	_assert(plain_tile._wire.flat, "the plain wire button is flat too (REQ-010)")
	_assert(plain_tile._wire.get_theme_color("font_color") == ModDisplay.source_color(2),
		"coloured by its array index")
	plain_tile._on_wire_toggled(true, plain.mod_id)
	_assert(_mod_assign.is_active_for(inst, plain.mod_id), "the plain button starts assign for its modulator")
	plain_tile._on_wire_toggled(false, plain.mod_id)
	pane.queue_free()


func _test_xy_pad_panel_model() -> void:
	var inst = _instance()
	inst.modulators.clear()
	var pad: XYPad = inst.add_xy_pad()
	var pane = await _pane_for(inst)
	var xy_panel: XYPadPanel = pane._tiles[0]._display
	xy_panel.set_values(0.3, 0.8)
	_assert(is_equal_approx(pad.x.get_param(0), 0.3) and is_equal_approx(pad.y.get_param(0), 0.8),
		"the compact pad writes both slots' Position")
	_assert(is_equal_approx(pane._options.slider.value_x, 0.3)
		and is_equal_approx(pane._options.slider.value_y, 0.8),
		"the options pad follows the compact pad")
	inst.set_modulator_param(pad.x.mod_id, 0, 0.6)
	_assert(is_equal_approx(xy_panel._slider.value_x, 0.6), "the compact pad follows the model")
	inst.set_modulator_param(pad.y.mod_id, 0, 0.1)
	_assert(is_equal_approx(xy_panel._slider.value_y, 0.1), "for either slot")
	pane.queue_free()


func _test_sidechain_source_menu() -> void:
	var project = _project_script.new()
	var ch_a: Object = project.create_instrument_track("Inst").channel
	var ch_b: Object = project.create_instrument_track("Other").channel
	var inst = _inst_script.new(_synth(), ch_a.id, -1)
	ch_a.add_device(inst)
	var sc = inst.add_modulator("sidechain")
	_assert(sc != null and sc.kind == "sidechain", "a sidechain can be added")
	var pane = await _pane_for(inst)
	pane._select(sc.mod_id)
	await process_frame
	var menu: OptionButton = pane._options.get("source_menu")
	_assert(menu != null, "the sidechain detail has a Source menu")
	_assert(pane._options.controls.has(50) and pane._options.controls.has(0)
		and pane._options.controls.has(10) and pane._options.controls.has(20)
		and pane._options.controls.has(30), "Gain and the four knobs are bound")
	_assert(pane._options.controls.get(50) is RotaryKnob, "Gain is a knob")
	_assert(pane._options.controls.get(60) is CompactSlider, "Amount is a CompactSlider")
	var amount: CompactSlider = pane._options.controls[60]
	_assert(is_equal_approx(amount.value, 1.0) and is_equal_approx(amount.default_value, 1.0),
		"Amount reads its 100 % default")
	amount.value = 0.5
	_assert(is_equal_approx(sc.get_param(60), 0.5), "dragging Amount sets the model parameter")
	_assert(pane._options.spectrum != null, "the options carry the spectrum plot")
	_assert(menu.get_item_text(0) == "Device In" and int(menu.get_item_metadata(0)) == 0,
		"Device In is item 0 with channel id 0")
	var ids: Array = []
	for i in range(1, menu.item_count):
		ids.append(int(menu.get_item_metadata(i)))
		_assert(menu.get_item_text(i) == project.get_channel_by_id(int(menu.get_item_metadata(i))).name,
			"channel items carry the channel name")
	_assert(ids.has(ch_a.id) and ids.has(ch_b.id), "the menu lists the project channels by id")
	var hardware := false
	for id in ids:
		if id >= 1000:
			hardware = true
	_assert(not hardware, "hardware outputs are excluded")

	var b_index := -1
	for i in menu.item_count:
		if int(menu.get_item_metadata(i)) == ch_b.id:
			b_index = i
	pane._options._on_source_selected(b_index)
	var param = sc.get_parameter(40)
	_assert(is_equal_approx(sc.get_param(40), param.value_to_normalized(float(ch_b.id))),
		"picking a channel stores its id normalized through set_modulator_param")

	inst.set_modulator_param(sc.mod_id, 40, param.value_to_normalized(777.0))
	pane._select(-1)
	pane._select(sc.mod_id)
	await process_frame
	var found_missing := false
	for i in pane._options.source_menu.item_count:
		if pane._options.source_menu.get_item_text(i) == "(missing channel)":
			found_missing = true
	_assert(found_missing, "a stored id that no longer exists shows as (missing channel)")

	var count_before: int = pane._options.source_menu.item_count
	project.create_instrument_track("Third")
	await process_frame
	_assert(pane._options.source_menu != null and pane._options.source_menu.item_count == count_before + 1,
		"a channel-list change rebuilds the menu")
	pane.queue_free()


## Every options scene stays under `ModulatorOptions.MAX_HEIGHT`, and in a real DevicePanel no
## kind's options grow the panel past its fixed height (they may widen it). The options content
## is centered in the detail column.
func _test_options_fit_the_panel() -> void:
	var max_height: float = load("res://devices/modulators/options/ModulatorOptions.gd").MAX_HEIGHT
	var paths: Array = _pane_script.OPTIONS_SCENES.values()
	paths.append_array([_pane_script.XY_PAD_OPTIONS, _pane_script.GENERIC_OPTIONS])
	for path in paths:
		var scene: Control = load(path).instantiate()
		root.add_child(scene)
		var min_size := scene.get_combined_minimum_size()
		_assert(min_size.y <= max_height, "%s is at most %d px tall (%s)" % [path.get_file(), max_height, min_size])
		scene.free()

	var panel_height: float = load("res://devices/device_lane/DevicePanel.gd").HEIGHT
	var panel = load("res://devices/device_lane/DevicePanel.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	var inst = _instance()
	inst.modulators.clear()
	for kind in ["lfo", "adsr", "knob", "sidechain", "velocity"]:
		inst.add_modulator(kind)
	inst.add_xy_pad()
	await panel.bind_to_device(inst)
	panel.modulators_button.set_pressed_no_signal(true)
	panel._update_tab_panes()
	await create_timer(0.3).timeout
	var pane = panel.modulators
	for mod in inst.modulators:
		if mod.kind == "xyy":
			continue
		pane._select(mod.mod_id)
		await process_frame
		await process_frame
		var options: Control = pane._options
		_assert(options != null, "%s has an options scene" % mod.kind)
		_assert(panel.get_combined_minimum_size().y <= panel_height + 0.5 and panel.size.y <= panel_height + 0.5,
			"%s options keep the panel at %d px (min %.0f, size %.0f)"
				% [mod.kind, panel_height, panel.get_combined_minimum_size().y, panel.size.y])
		var grid_right: float = pane._grid.get_global_rect().end.x
		var last_column: Control = pane._grid.get_child(pane._grid.get_child_count() - 1)
		_assert(absf(last_column.get_global_rect().end.x - grid_right) <= 1.0,
			"%s: no empty space between the grid's last column and the options" % mod.kind)
		var content: Control = options.get_child(0)
		var offset := content.get_global_rect().get_center() - options.get_global_rect().get_center()
		_assert(absf(offset.x) <= 1.0 and absf(offset.y) <= 1.0,
			"%s options are centered in the detail column (off by %s)" % [mod.kind, offset])
	panel.free()
