# Reverb panel view (spec 050): one control per parameter and both slot tiles, signal-path order,
# the decay map following the parameters, drag/undo/reset on every handle, the envelope stream
# subscription lifetime, silence scrolling, the Tank FX mark and the slot tiles.
# Run: godot --headless --path Godot -s tests/test_reverb_view.gd -- --test
extends TestBase

const REVERB_ID := "sonara.builtin.reverb"
const CHAIN_ID := "sonara.builtin.chain"

var _device_script: GDScript
var _instance_script: GDScript
var _history: Object
var _util: GDScript
var _reverb_device: Object


func suite_name() -> String:
	return "Reverb view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_history = load("res://history/CommandHistory.gd").new()
	_util = load("res://history/HistoryUtil.gd")
	_util.test_recorder = func(cmd): _history.record(cmd)
	_register_devices()
	_test_registered_in_factory()
	await _test_controls_and_order()
	await _test_map_follows_parameters()
	await _test_handles()
	await _test_span_lock()
	await _test_subscription()
	await _test_silence_scrolls()
	await _test_tank_fx_mark()
	await _test_slot_tiles()
	_util.test_recorder = Callable()


## The Reverb as the engine advertises it (ids, ranges, defaults of reverb.rs) plus a fake
## container Chain for the slot chains and a plain effect for Tank FX.
func _register_devices() -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	var chain: Object = _device_script.new(CHAIN_ID, "Chain", _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	chain.is_container = true
	registry._devices[CHAIN_ID] = chain
	var fx: Object = _device_script.new("test.tank.fx", "Tank Fx", _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	registry._devices["test.tank.fx"] = fx
	var device: Object = _device_script.new(REVERB_ID, "Reverb", _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	device.is_container = true
	device.slots.append({"key": "tank_fx", "name": "Tank FX", "kind": "loop"})
	device.slots.append({"key": "wet_fx", "name": "Wet FX", "kind": "audio"})
	var add := func(id: int, name: String, min_v: float, max_v: float, default_v: float, log_v := false, skew := 1.0) -> void:
		var param := DeviceParameter.new(id, name)
		param.min_value = min_v
		param.max_value = max_v
		param.default_value = default_v
		param.is_logarithmic = log_v
		param.skew = skew
		device.add_parameter(param)
	var algorithm := DeviceParameter.new(ReverbData.P_ALGORITHM, "Algorithm")
	algorithm.param_type = "enum"
	algorithm.enum_values = ["Room", "Hall", "Plate"]
	algorithm.max_value = 2.0
	algorithm.default_value = 1.0
	device.add_parameter(algorithm)
	add.call(ReverbData.P_SIZE, "Size", 0.0, 100.0, 50.0)
	add.call(ReverbData.P_DECAY, "Decay", 0.1, 30.0, 2.2, true)
	add.call(ReverbData.P_PREDELAY, "Pre-Delay", 0.0, 500.0, 20.0, false, 2.5)
	add.call(ReverbData.P_DIFFUSION, "Diffusion", 0.0, 100.0, 80.0)
	add.call(ReverbData.P_EARLY, "Early", 0.0, 100.0, 50.0)
	add.call(ReverbData.P_LOW_MULT, "Low Mult", 0.25, 2.0, 1.2, true)
	add.call(ReverbData.P_LOW_FREQ, "Low Freq", 50.0, 1000.0, 250.0, true)
	add.call(ReverbData.P_HIGH_MULT, "High Mult", 0.1, 1.0, 0.5, true)
	add.call(ReverbData.P_HIGH_FREQ, "High Freq", 1000.0, 20000.0, 4000.0, true)
	add.call(ReverbData.P_RATE, "Rate", 0.05, 5.0, 0.8, true)
	add.call(ReverbData.P_DEPTH, "Depth", 0.0, 100.0, 30.0)
	add.call(ReverbData.P_LOW_CUT, "Low Cut", 20.0, 1000.0, 80.0, true)
	add.call(ReverbData.P_HIGH_CUT, "High Cut", 1000.0, 20000.0, 14000.0, true)
	add.call(ReverbData.P_DUCKING, "Ducking", 0.0, 100.0, 0.0)
	var freeze := DeviceParameter.new(ReverbData.P_FREEZE, "Freeze")
	freeze.param_type = "bool"
	freeze.default_value = 0.0
	device.add_parameter(freeze)
	add.call(ReverbData.P_WIDTH, "Width", 0.0, 200.0, 100.0)
	add.call(ReverbData.P_MIX, "Mix", 0.0, 100.0, 30.0)
	registry._devices[REVERB_ID] = device
	_reverb_device = device


func _make_instance() -> Object:
	return _instance_script.new(_reverb_device, 2, 0)


func _fake_osc() -> Node:
	var script := GDScript.new()
	script.source_code = """
extends Node
signal device_data_received(osc_path: String, data_type: String, blob: PackedByteArray)

var subscribed := {}
var log := []

func subscribe_device_data(osc_path: String, data_type: String) -> void:
	subscribed[osc_path + "|" + data_type] = true
	log.append("sub")

func unsubscribe_device_data(osc_path: String, data_type: String) -> void:
	subscribed.erase(osc_path + "|" + data_type)
	log.append("unsub")
"""
	script.reload()
	var osc := Node.new()
	osc.name = "AudioEngineOSC"
	osc.set_script(script)
	return osc


## A view bound to a fresh Reverb, in the tree and laid out at the panel's content size.
func _make_view(osc: Node = null, inst: Object = null) -> Array:
	var instance: Object = inst if inst != null else _make_instance()
	var view = load("res://devices/builtin/reverb/ReverbDefaultView.tscn").instantiate()
	view.load_osc = func(_name: String): return osc
	view.size = Vector2(900, 300)
	view.bind_to_device(instance)
	root.add_child(view)
	await process_frame
	await process_frame
	return [view, instance]


func _free_view(view: Node) -> void:
	view.queue_free()
	await process_frame


# ---------------------------------------------------------------------------

func _test_registered_in_factory() -> void:
	var factory: GDScript = load("res://devices/DeviceViewFactory.gd")
	_assert(factory.BUILTIN_PANEL_SCENES.has(REVERB_ID), "the Reverb has a registered panel view")


func _test_controls_and_order() -> void:
	var made := await _make_view()
	var view = made[0]
	var inst = made[1]
	# REQ-001: one control per parameter, one tile per slot.
	var missing := PackedStringArray()
	for param in inst.get_parameters():
		var found := false
		match param.name:
			"Algorithm":
				found = view.algorithm_control != null
			"Freeze":
				found = view.freeze_check != null
			_:
				found = view._knobs.has(param.name)
		if not found:
			missing.append(param.name)
	_assert(missing.is_empty(), "every parameter has a control (missing: %s)" % ", ".join(missing))
	_assert(view._knobs.size() == 16, "16 knobs plus Algorithm and Freeze = 18 parameters (%d)" % view._knobs.size())
	_assert(view._tiles.has("tank_fx") and view._tiles.has("wet_fx") and view._tiles.size() == 2, "one tile per slot key")
	_assert(view.tank_tile.container == inst and view.tank_tile.key == "tank_fx", "the Tank FX tile is bound to its slot")

	# REQ-002: left-to-right signal-path order.
	var ordered: Array[Control] = [view.algorithm_control]
	for name in ["Pre-Delay", "Early", "Diffusion", "Size", "Decay"]:
		ordered.append(view._knobs[name])
	ordered.append(view.freeze_check)
	for name in ["Low Mult", "Low Freq", "High Mult", "High Freq", "Rate", "Depth"]:
		ordered.append(view._knobs[name])
	ordered.append(view.tank_tile)
	for name in ["Low Cut", "High Cut"]:
		ordered.append(view._knobs[name])
	ordered.append(view.wet_tile)
	for name in ["Ducking", "Width", "Mix"]:
		ordered.append(view._knobs[name])
	var in_order := true
	var detail := ""
	for i in range(1, ordered.size()):
		if ordered[i].global_position.x < ordered[i - 1].global_position.x - 0.5:
			in_order = false
			detail = "%s before %s" % [ordered[i].name, ordered[i - 1].name]
	_assert(in_order, "controls run left to right in signal order (%s)" % detail)
	var groups: Array[Control] = [view._knobs["Pre-Delay"], view._knobs["Size"], view._knobs["Low Mult"],
		view._knobs["Low Freq"], view._knobs["High Mult"], view._knobs["High Freq"], view._knobs["Rate"],
		view._knobs["Depth"], view.tank_tile, view._knobs["Low Cut"], view.wet_tile, view._knobs["Ducking"]]
	var strict := true
	for i in range(1, groups.size()):
		if groups[i].global_position.x <= groups[i - 1].global_position.x:
			strict = false
	_assert(strict, "columns and the Decay EQ / Modulation row advance strictly")

	var content: Vector2 = view._main_page.get_combined_minimum_size()
	_assert(content.y <= 300.0, "the layout fits the panel below its header (%s)" % content)
	await _free_view(view)


func _test_map_follows_parameters() -> void:
	var made := await _make_view()
	var view = made[0]
	var inst = made[1]
	var before: float = view.decay_map.contour_time(1000.0)
	inst.set_parameter_real(ReverbData.P_DECAY, 6.0)
	var after: float = view.decay_map.contour_time(1000.0)
	_assert(after > before * 2.0, "setting Decay moves the 1 kHz contour (%.2f -> %.2f)" % [before, after])
	var high_before: float = view.decay_map.contour_time(18000.0)
	inst.set_parameter_real(ReverbData.P_HIGH_MULT, 1.0)
	_assert(view.decay_map.contour_time(18000.0) > high_before, "High Mult 1.0 lengthens the top of the map")
	inst.set_parameter_real(ReverbData.P_FREEZE, 1.0)
	_assert(view.decay_map.is_frozen() and view.freeze_check.button_pressed, "Freeze shows on the map and the toggle")
	_assert(is_inf(view.decay_map.contour_time(1000.0)), "a frozen map has no contour")
	inst.set_parameter_real(ReverbData.P_ALGORITHM, 2.0)
	_assert(view.algorithm_control.selected == 2, "the Algorithm control follows the parameter")
	view.algorithm_control.selected = 0
	_assert(is_equal_approx(inst.get_parameter_real(ReverbData.P_ALGORITHM), 0.0), "the Algorithm control sets the parameter")
	view._knobs["Size"].knob.value = 80.0
	_assert(is_equal_approx(inst.get_parameter_real(ReverbData.P_SIZE), 80.0), "a Size knob drag sets Size")
	await _free_view(view)


func _mouse_button(pos: Vector2, pressed: bool, double := false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.position = pos
	return e


func _mouse_motion(pos: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	return e


## Press on `handle`, move by `delta` in a few steps, release.
func _drag(map: ReverbDecayMap, handle: String, delta: Vector2) -> void:
	var start := map.handle_position(handle)
	map._gui_input(_mouse_button(start, true))
	for i in range(1, 5):
		map._gui_input(_mouse_motion(start + delta * (float(i) / 4.0)))
	map._gui_input(_mouse_button(start + delta, false))


func _test_handles() -> void:
	var made := await _make_view()
	var view = made[0]
	var inst = made[1]
	var map: ReverbDecayMap = view.decay_map
	map.size = Vector2(380, 150)
	map.snap_span()
	# handle, delta, [[param id, direction]]
	var cases := [
		[ReverbDecayMap.H_CONTOUR, Vector2(30, 0), [[ReverbData.P_DECAY, 1]]],
		[ReverbDecayMap.H_LOW_KNEE, Vector2(12, -15), [[ReverbData.P_LOW_MULT, 1], [ReverbData.P_LOW_FREQ, 1]]],
		[ReverbDecayMap.H_HIGH_KNEE, Vector2(-14, 15), [[ReverbData.P_HIGH_MULT, -1], [ReverbData.P_HIGH_FREQ, -1]]],
		[ReverbDecayMap.H_PREDELAY, Vector2(25, 0), [[ReverbData.P_PREDELAY, 1]]],
		[ReverbDecayMap.H_LOW_CUT, Vector2(0, -20), [[ReverbData.P_LOW_CUT, 1]]],
		[ReverbDecayMap.H_HIGH_CUT, Vector2(0, 20), [[ReverbData.P_HIGH_CUT, -1]]],
	]
	for case in cases:
		var handle: String = case[0]
		var start := map.handle_position(handle)
		_assert(map.hit_test(start) == handle, "%s is hit at its own position" % handle)
		var originals := {}
		for entry in case[2]:
			originals[entry[0]] = inst.get_parameter_real(entry[0])
		_history.clear()
		_drag(map, handle, case[1])
		for entry in case[2]:
			var now: float = inst.get_parameter_real(entry[0])
			var moved: float = (now - originals[entry[0]]) * entry[1]
			_assert(moved > 0.0, "dragging %s moves parameter %d the right way (%.3f -> %.3f)" % [handle, entry[0], originals[entry[0]], now])
		_assert(_history.undo_count() == 1, "dragging %s is one undo step (%d)" % [handle, _history.undo_count()])
		_assert(not map.is_dragging() and not map.span_locked, "%s: the drag ended on release" % handle)
		_history.undo()
		for entry in case[2]:
			_assert(absf(inst.get_parameter_real(entry[0]) - originals[entry[0]]) < 0.001 * maxf(1.0, absf(originals[entry[0]])),
				"undo restores parameter %d after dragging %s" % [entry[0], handle])
		# Far past the plot edge the value stays inside its range.
		_drag(map, handle, Vector2(-5000, -5000))
		_drag(map, handle, Vector2(5000, 5000))
		for entry in case[2]:
			var limits: Vector2 = ReverbData.RANGES[entry[0]]
			var value: float = inst.get_parameter_real(entry[0])
			_assert(value >= limits.x - 1e-3 and value <= limits.y + 1e-3, "%s keeps parameter %d in range (%.3f)" % [handle, entry[0], value])
		_history.undo_count()
		# Double-click resets to the default.
		for entry in case[2]:
			inst.set_parameter_real(entry[0], originals[entry[0]])
		_drag(map, handle, case[1])
		map._gui_input(_mouse_button(map.handle_position(handle), true, true))
		for entry in case[2]:
			var default_value: float = inst.get_parameter(entry[0]).default_value
			_assert(absf(inst.get_parameter_real(entry[0]) - default_value) < 0.001 * maxf(1.0, absf(default_value)),
				"double-click on %s resets parameter %d" % [handle, entry[0]])
		map._gui_input(_mouse_button(map.handle_position(handle), false))
		for entry in case[2]:
			inst.set_parameter_real(entry[0], originals[entry[0]])

	# Hover shows the highlight state and the tooltip.
	map._gui_input(_mouse_motion(map.handle_position(ReverbDecayMap.H_CONTOUR)))
	_assert(map.tooltip_visible(), "hovering a handle shows its value tooltip")
	_assert(map.handle_text(ReverbDecayMap.H_CONTOUR) == "Decay %s" % ReverbData.format_value(ReverbData.P_DECAY, inst.get_parameter_real(ReverbData.P_DECAY)), "the tooltip text is the knob's text")
	map._gui_input(_mouse_motion(Vector2(map.x_of_t(map.span * 0.6), map.y_of_f(3000.0))))
	_assert(not map.tooltip_visible(), "leaving the handle hides the tooltip")

	# Frozen: the decay handles are disabled.
	inst.set_parameter_real(ReverbData.P_FREEZE, 1.0)
	var decay_before: float = inst.get_parameter_real(ReverbData.P_DECAY)
	_drag(map, ReverbDecayMap.H_CONTOUR, Vector2(40, 0))
	_assert(absf(inst.get_parameter_real(ReverbData.P_DECAY) - decay_before) < 1e-4, "frozen: the contour handle does not edit Decay")
	var mult_before: float = inst.get_parameter_real(ReverbData.P_LOW_MULT)
	_drag(map, ReverbDecayMap.H_LOW_KNEE, Vector2(30, 0))
	_assert(absf(inst.get_parameter_real(ReverbData.P_LOW_MULT) - mult_before) < 1e-4, "frozen: the knee's horizontal drag does not edit its multiplier")
	await _free_view(view)


func _test_span_lock() -> void:
	var made := await _make_view()
	var view = made[0]
	var inst = made[1]
	var map: ReverbDecayMap = view.decay_map
	map.size = Vector2(380, 150)
	map.snap_span()
	var target_before: float = map.span_target
	map._gui_input(_mouse_button(map.handle_position(ReverbDecayMap.H_PREDELAY), true))
	inst.set_parameter_real(ReverbData.P_DECAY, 20.0)
	_assert(map.span_locked and is_equal_approx(map.span_target, target_before), "a drag in progress leaves the span target unchanged")
	map._gui_input(_mouse_button(map.handle_position(ReverbDecayMap.H_PREDELAY), false))
	_assert(map.span_target >= 20.0, "after release the span follows the longest tail (%s)" % map.span_target)
	var previous: float = map.span
	map.advance_span(0.05)
	_assert(map.span > previous and map.span < map.span_target, "the span eases instead of jumping")
	_assert(is_equal_approx(view.strip.span, map.span), "the strip spans the same time as the map")
	await _free_view(view)


func _test_subscription() -> void:
	var osc := _fake_osc()
	var made := await _make_view(osc)
	var view = made[0]
	var inst = made[1]
	_assert(osc.subscribed.is_empty(), "a view that is not shown does not subscribe")
	view._on_view_shown()
	_assert(osc.subscribed.has(inst.osc_path() + "|envelope"), "showing the view subscribes to the envelope stream")
	# A blob reaches the strip; other data types and paths are ignored.
	var blob := ReverbData.build_envelope(256.0 / 48000.0, PackedFloat32Array([-6.0, -30.0]), PackedFloat32Array([-20.0, -25.0]))
	view._on_envelope_received(inst.osc_path(), "envelope", blob)
	_assert(view.strip.history_seconds() > 0.0, "an envelope blob reaches the strip")
	var seconds_before: float = view.strip.history_seconds()
	view._on_envelope_received(inst.osc_path(), "dynamics", blob)
	view._on_envelope_received("/somewhere/else", "envelope", blob)
	_assert(is_equal_approx(view.strip.history_seconds(), seconds_before), "foreign data types and paths are ignored")
	view._on_view_hidden()
	_assert(osc.subscribed.is_empty(), "hiding the view unsubscribes")
	_assert(view.strip.history_seconds() == 0.0, "hiding clears the strip")
	view._on_view_shown()
	_assert(not osc.subscribed.is_empty(), "showing again subscribes again")
	await _free_view(view)
	_assert(osc.subscribed.is_empty(), "freeing a shown view unsubscribes")
	osc.free()


func _test_silence_scrolls() -> void:
	var osc := _fake_osc()
	var made := await _make_view(osc)
	var view = made[0]
	var inst = made[1]
	view._on_view_shown()
	var rs := 256.0 / 48000.0
	var loud := PackedFloat32Array()
	loud.resize(20)
	loud.fill(-10.0)
	view._on_envelope_received(inst.osc_path(), "envelope", ReverbData.build_envelope(rs, loud, loud))
	var strip: ReverbEnvelopeStrip = view.strip
	strip.advance(0.5)
	_assert(strip.head_lag() <= ReverbEnvelopeStrip.GAP_S + rs * 2.0, "0.5 s without data fills the gap (lag %.3f)" % strip.head_lag())
	var recent := strip.recent(0.3)
	var all_silent := recent[1].size() > 0
	for v in recent[1]:
		if v > -100.0:
			all_silent = false
	_assert(all_silent, "the appended records are silence")
	var seconds: float = strip.history_seconds()
	strip.advance(0.5)
	_assert(strip.history_seconds() > seconds, "the strip keeps scrolling")
	# Columns: a trace exists over the span for the loud part, none for the gap's floor.
	strip.span = 3.0
	var cols := strip.columns(true, 100)
	_assert(cols.size() == 100, "one column per pixel")
	await _free_view(view)
	osc.free()


func _test_tank_fx_mark() -> void:
	var made := await _make_view()
	var view = made[0]
	var inst = made[1]
	var chain = inst.slot_chain("tank_fx")
	_assert(chain != null, "the Reverb has a Tank FX chain")
	_assert(not view.decay_map.approximate, "an empty Tank FX leaves the map exact")
	var fx = _instance_script.new(load("res://data/Device.gd").new("x", "x", 0) if false else \
			root.get_node("AssetService").device_registry._devices["test.tank.fx"], 2, -1)
	chain.children.append(fx)
	fx.set_parent_device(chain)
	chain.child_added.emit(fx, 0)
	_assert(view.decay_map.approximate, "a device in Tank FX marks the map approximate")
	fx.enabled = false
	fx.enabled_changed.emit(false)
	_assert(not view.decay_map.approximate, "a bypassed Tank FX device clears the mark")
	fx.enabled = true
	fx.enabled_changed.emit(true)
	_assert(view.decay_map.approximate, "re-enabling it sets the mark again")
	chain.children.erase(fx)
	chain.child_removed.emit(0, "test.tank.fx")
	_assert(not view.decay_map.approximate, "removing the device clears the mark")
	await _free_view(view)


func _test_slot_tiles() -> void:
	var made := await _make_view()
	var view = made[0]
	var inst = made[1]
	for key in ["tank_fx", "wet_fx"]:
		var tile = view._tiles[key]
		_assert(not inst.is_slot_open(key), "%s starts closed" % key)
		tile._gui_input(_mouse_button(Vector2(10, 10), true))
		_assert(inst.is_slot_open(key), "clicking the %s tile opens its slot" % key)
		tile._gui_input(_mouse_button(Vector2(10, 10), true))
		_assert(not inst.is_slot_open(key), "clicking it again closes the slot")
	await _free_view(view)
