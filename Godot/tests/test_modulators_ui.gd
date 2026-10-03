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


func suite_name() -> String:
	return "Modulators UI"


func run_tests() -> void:
	_inst_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_mod_assign = load("res://devices/modulators/ModAssign.gd")
	_pane_script = load("res://devices/modulators/ModulatorsPane.gd")
	_setup()
	await _test_pane_tiles_and_add()
	await _test_context_menu_routes()
	await _test_assign_reaches_child_not_sibling()
	await _test_control_shows_only_focused_source()
	await _test_esc_exits_assign()
	await _test_simple_control_assign()
	await _test_panel_tab_and_dot()
	_mod_assign.end()


# --- fixtures ------------------------------------------------------------------------------

func _setup() -> void:
	_registry = load("res://data/DeviceRegistry.gd").new()
	_registry._on_modulator_kind_received(_lfo_kind_args())
	_registry._on_modulator_kind_received(_adsr_kind_args())
	var asset_registry: Object = root.get_node("AssetService").device_registry
	for kind_id in ["lfo", "adsr"]:
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

	var popup: PopupMenu = pane._add_button.get_popup()
	_assert(popup.item_count == 2, "the + menu lists the advertised kinds")
	var index := _kind_index(popup, "adsr")
	_assert(index >= 0, "the envelope kind is in the menu")
	pane._on_add_kind(index)
	_assert(inst.modulators.size() == 2, "the + menu adds a modulator")
	_assert(pane._tiles.size() == 2 and pane._selected_mod_id == inst.modulators[1].mod_id, "the new tile is selected")
	_assert(pane._envelope_control != null and pane._envelope.stages == "adsr", "the envelope detail shows an EnvelopeControl")
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
	inst.add_modulator("lfo")
	await panel.bind_to_device(inst)
	await process_frame
	_assert(panel.modulators_button.visible, "the Modulators tab is available")
	panel.modulators_button.set_pressed_no_signal(true)
	panel._update_tab_panes()
	_assert(panel.modulators_pane.visible, "pressing the tab shows the pane")
	_assert(panel.modulators._tiles.size() == 1, "the pane built a tile")
	panel._set_collapsed(true)
	_assert(panel._mod_dot.visible, "the collapsed header marks a device with modulators")
	panel.free()
