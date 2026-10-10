# Modulator drag-to-swap (spec 033 phase 2): ModulatorDrag.resolve maps the mouse to a panel cell
# (invalid over placeholders, the dragged panel, another device or outside the grid), commit swaps
# through DeviceInstance.swap_modulators, the DropIndicator outlines the target, and a panel selects
# only on a click that stays under the drag threshold.
# Run: godot --headless --path Godot -s tests/test_modulator_drag.gd -- --test
#
# Autoload-referencing scripts are loaded with load(), as in test_modulators_ui.gd.
extends TestBase

const SYNTH_ID := "test.synth9"

var _inst_script: GDScript
var _pane_script: GDScript
var _drag_script: GDScript


func suite_name() -> String:
	return "Modulator drag"


func run_tests() -> void:
	_inst_script = load("res://data/DeviceInstance.gd")
	_pane_script = load("res://devices/modulators/ModulatorsPane.gd")
	_drag_script = load("res://devices/modulators/ModulatorDrag.gd")
	_setup()
	await _test_resolve_targets()
	await _test_commit_swaps()
	await _test_click_selects_but_drag_does_not()


# --- fixtures ------------------------------------------------------------------------------

func _setup() -> void:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	registry._on_modulator_kind_received(_lfo_kind_args())
	registry._on_modulator_kind_received(["velocity", "Velocity", 0, 0])
	var asset_registry: Object = root.get_node("AssetService").device_registry
	for kind_id in ["lfo", "velocity"]:
		asset_registry.modulator_kinds[kind_id] = registry.get_modulator_kind(kind_id)
	registry._on_builtin_info_received([
		SYNTH_ID, "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		1,
		31, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1, 1,
		0,
		0,
	])
	asset_registry._devices[SYNTH_ID] = registry.get_device(SYNTH_ID)


func _float_param(id: int, name: String, unit: String, minv: float, maxv: float, default_value: float, is_log: bool) -> Array:
	return [id, name, unit, "float", 1, minv, maxv, default_value, 1 if is_log else 0, 1.0, 0, "", 1, 0]


func _enum_param(id: int, name: String, values: Array, default_index: int) -> Array:
	var args: Array = [id, name, "", "enum", 1, 0.0, float(values.size() - 1), float(default_index), 0, 1.0, values.size()]
	args.append_array(values)
	args.append_array(["", 1, 0])
	return args


func _lfo_kind_args() -> Array:
	var args: Array = ["lfo", "LFO", 1, 5]
	args.append_array(_enum_param(0, "Shape", ["Sine", "Triangle", "Saw"], 0))
	args.append_array(_float_param(10, "Rate", "Hz", 0.02, 40.0, 2.0, true))
	args.append_array(_enum_param(20, "Sync", ["Off", "1/4", "1/8"], 0))
	args.append_array(_enum_param(30, "Retrigger", ["Free", "Note"], 0))
	args.append_array(_float_param(40, "Phase", "deg", 0.0, 360.0, 0.0, false))
	return args


## A pane bound to a fresh synth instance with `n` modulators, laid out.
func _pane_bound(n: int) -> Array:
	var inst = _inst_script.new(root.get_node("AssetService").device_registry.get_device(SYNTH_ID), 2, 0)
	var pane = _pane_script.new()
	root.add_child(pane)
	pane.size = Vector2(420, 330)
	for i in range(n):
		inst.add_modulator("lfo" if i == 0 else "velocity")
	await pane.bind_to_device(inst)
	await process_frame
	await process_frame
	return [pane, inst]


func _mouse_button(pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	return ev


func _mouse_motion(pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	ev.position = pos
	ev.global_position = pos
	return ev


# --- tests ---------------------------------------------------------------------------------

func _test_resolve_targets() -> void:
	var s := await _pane_bound(3)
	var pane = s[0]
	var inst = s[1]
	var panels: Array = pane._tiles
	var drag: Object = _drag_script.start(pane, inst.modulators[0])

	var target: Object = _drag_script.resolve(pane, drag, panels[1].get_global_rect().get_center())
	_assert(target.is_valid(), "an own-device panel resolves valid")
	_assert(target.mod_id == inst.modulators[1].mod_id, "the target is the panel under the pointer")
	_assert(target.indicator_rect == panels[1].get_global_rect(), "the indicator outlines the target panel")
	_assert(not _drag_script.resolve(pane, drag, panels[0].get_global_rect().get_center()).is_valid(),
		"the dragged panel itself is invalid")
	var placeholder: Button = pane._placeholders[0]
	_assert(not _drag_script.resolve(pane, drag, placeholder.get_global_rect().get_center()).is_valid(),
		"a placeholder is invalid")
	var other: Object = _drag_script.new(pane, "other-device", 0, null)
	_assert(not _drag_script.resolve(pane, other, panels[1].get_global_rect().get_center()).is_valid(),
		"another device's panel is invalid")
	var outside: Vector2 = pane.get_global_rect().end + Vector2(50, 50)
	_assert(not _drag_script.resolve(pane, drag, outside).is_valid(), "outside the grid is invalid")
	pane.queue_free()


func _test_commit_swaps() -> void:
	var s := await _pane_bound(3)
	var pane = s[0]
	var inst = s[1]
	var drag: Object = _drag_script.start(pane, inst.modulators[0])
	var target: Object = _drag_script.resolve(pane, drag, pane._tiles[2].get_global_rect().get_center())
	var fired: Array = []
	inst.modulators_reordered.connect(func(): fired.append(1))

	_assert(target.commit(drag), "commit swaps the panels")
	_assert(drag.did_commit, "the drag reports the drop")
	_assert(fired.size() == 1, "modulators_reordered fired once")
	_assert(inst.modulators[0].mod_id == 2 and inst.modulators[2].mod_id == 0 and inst.modulators[1].mod_id == 1,
		"the entries swapped and every id is kept")
	_assert(inst.get_modulator(0) != null and inst.get_modulator(2) != null, "ids still resolve")

	var self_target: Object = _drag_script.resolve(pane, drag, pane._tiles[2].get_global_rect().get_center())
	_assert(not self_target.commit(drag), "an invalid target changes nothing")
	_assert(fired.size() == 1, "still one reorder")
	pane.queue_free()


## A click without movement toggles selection; a drag past the threshold never does.
func _test_click_selects_but_drag_does_not() -> void:
	var s := await _pane_bound(2)
	var pane = s[0]
	var inst = s[1]
	var tile: Control = pane._tiles[0]
	var center: Vector2 = tile.get_global_rect().get_center()
	var clicked: Array = []
	tile.selected.connect(func(mod_id): clicked.append(mod_id))
	pane._select(-1)
	await process_frame

	tile._gui_input(_mouse_button(true, center))
	_assert(clicked.is_empty(), "a press alone doesn't select")
	tile._gui_input(_mouse_button(false, center))
	_assert(clicked == [inst.modulators[0].mod_id], "a release under the threshold selects")
	_assert(pane._selected_mod_id == inst.modulators[0].mod_id, "the pane followed the selection")
	tile._gui_input(_mouse_button(true, center))
	tile._gui_input(_mouse_button(false, center))
	_assert(clicked.size() == 2 and pane._selected_mod_id == -1, "a second click deselects")

	# Press + motion within the threshold: still a click, no drag.
	tile._gui_input(_mouse_button(true, center))
	tile._gui_input(_mouse_motion(center + Vector2(6, 0)))
	_assert(pane._drag == null, "moving exactly 6 px doesn't start a drag")
	# Past it: the pane owns a drag and nothing was selected.
	tile._gui_input(_mouse_motion(center + Vector2(10, 0)))
	_assert(pane._drag != null and pane._drag.mod_id == inst.modulators[0].mod_id, "past the threshold a drag starts")
	_assert(clicked.size() == 2, "a drag start doesn't select")

	var target_center: Vector2 = pane._tiles[1].get_global_rect().get_center()
	pane._input(_mouse_motion(target_center))
	_assert(pane._indicator != null and pane._indicator.visible, "the indicator shows over the target")
	# Releasing over the target commits the swap.
	pane._input(_mouse_button(false, target_center))
	_assert(inst.modulators[0].mod_id == 1 and inst.modulators[1].mod_id == 0, "the release swapped the modulators")
	_assert(pane._drag == null and not pane._indicator.visible, "the drag ended cleanly")
	pane.queue_free()
