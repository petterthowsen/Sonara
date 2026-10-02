# Modulation UI: the shared drawing/assign contract on RotaryKnob, HorSlider, VolumeSlider and
# Volumeter, the SimpleControl wiring (assign mode, route arcs, undo command), and the envelope
# compound's knobs.
# Run: godot --headless --path Godot -s tests/test_mod_assign_ui.gd -- --test
extends TestBase

# Loaded at runtime: compiling SimpleControl pulls in DeviceInstance before the autoloads exist.
var _emitted: Array[float] = []


func suite_name() -> String:
	return "Modulation UI"


func run_tests() -> void:
	_test_display_maths()
	await _test_component(_add(RotaryKnob.new()), "knob")
	await _test_component(_add(HorSlider.new(), true), "hslider")
	await _test_component(_add(Volumeter.new()), "volumeter")
	await _test_component(_add(Fader.new()), "fader")
	await _test_volume_slider()
	await _test_simple_control_assign()
	await _test_envelope_compound()
	await _test_simple_view_loop()
	_test_footprint()


func _add(node: Control, slider := false) -> Control:
	if slider:
		node.min_value = 0.0
		node.max_value = 1.0
		node.bidirectional = false
	# away from the headless pointer at (0, 0)
	node.position = Vector2(100, 100)
	node.size = Vector2(60, 60)
	root.add_child(node)
	node.size = Vector2(60, 60)
	return node


func _click(node: Control, double := false, pressed := true) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.position = Vector2(30, 30)
	node._gui_input(e)


func _motion(node: Control, relative: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.relative = relative
	e.position = Vector2(30, 30) + relative
	node._gui_input(e)


func _test_display_maths() -> void:
	var band := ModDisplay.span(0.5, 0.3, false)
	_assert(is_equal_approx(band.x, 0.5) and is_equal_approx(band.y, 0.8), "unipolar span runs base → base+amount")
	band = ModDisplay.span(0.5, -0.3, false)
	_assert(is_equal_approx(band.x, 0.2) and is_equal_approx(band.y, 0.5), "negative unipolar runs down")
	band = ModDisplay.span(0.5, 0.3, true)
	_assert(is_equal_approx(band.x, 0.2) and is_equal_approx(band.y, 0.8), "bipolar span goes both ways")
	band = ModDisplay.span(0.9, 0.5, true)
	_assert(is_equal_approx(band.y, 1.0), "span clamps to 1")
	_assert(ModDisplay.step_amount(0.9, 0.5) == 1.0 and ModDisplay.step_amount(-0.9, -0.5) == -1.0, "amount clamps to ±1")
	_assert(ModDisplay.default_amount_text(0.35) == "+35 %", "default amount text")


## The API every component shares: assign drags emit the amount and leave the value alone,
## double-click asks for 0, outside assign mode nothing is emitted.
func _test_component(node: Control, label: String) -> void:
	await process_frame
	_emitted.clear()
	node.mod_amount_changed.connect(func(a): _emitted.append(a))
	_click(node)
	_motion(node, Vector2(0, -20))
	_click(node, false, false)
	_assert(_emitted.is_empty(), "%s: no amount events outside assign mode" % label)
	var value_before = node.get("value") if node.get("value") != null else node.get("volume_db")

	node.mod_assign_active = true
	node.mod_assign_color = Color.RED
	node.mod_assign_amount = 0.0
	_click(node)
	_motion(node, Vector2(20, -20))
	_click(node, false, false)
	_assert(not _emitted.is_empty(), "%s: assign drag emits mod_amount_changed" % label)
	_assert(_emitted.back() > 0.0 and _emitted.back() <= 1.0, "%s: dragging up/right raises the amount (%s)" % [label, _emitted.back()])
	var value_after = node.get("value") if node.get("value") != null else node.get("volume_db")
	_assert(is_equal_approx(float(value_before), float(value_after)), "%s: the value is untouched in assign mode" % label)

	_emitted.clear()
	_motion(node, Vector2(20, -20))
	_assert(_emitted.is_empty(), "%s: motion without a press changes nothing" % label)
	_click(node)
	_motion(node, Vector2(500, -500))
	_click(node, false, false)
	_assert(node.mod_assign_amount == 1.0, "%s: amount clamps at 1" % label)

	_emitted.clear()
	_click(node, true)
	_assert(_emitted == [0.0] and node.mod_assign_amount == 0.0, "%s: double-click removes the route" % label)

	var range: Array[Dictionary] = [{"amount": 0.3, "color": Color.BLUE, "source": "lfo1", "bipolar": true}]
	node.mod_ranges = range
	node.mod_live_values = PackedFloat32Array([0.4, 0.6])
	node.mod_assign_active = false
	node.queue_redraw()
	await process_frame
	_assert(node.mod_ranges.size() == 1, "%s: ranges and live markers draw without error" % label)
	node.queue_free()


func _test_volume_slider() -> void:
	var scene: PackedScene = load("res://mixer/MixerChannel.tscn")
	var channel := scene.instantiate()
	var slider: VolumeSlider = _find_volume_slider(channel)
	_assert(slider != null, "mixer scene has a VolumeSlider")
	if slider == null:
		return
	root.add_child(channel)
	await process_frame
	slider.position = Vector2(100, 100)
	slider.size = Vector2(20, 60)
	_emitted.clear()
	slider.mod_amount_changed.connect(func(a): _emitted.append(a))
	var before := slider.value
	slider.mod_assign_active = true
	slider.mod_assign_amount = 0.0
	_click(slider)
	_motion(slider, Vector2(0, -12))
	_click(slider, false, false)
	_assert(not _emitted.is_empty() and _emitted.back() > 0.0, "volume slider: assign drag emits")
	_assert(slider.value == before, "volume slider: value untouched")
	slider.mod_ranges = [{"amount": 0.2, "color": Color.RED, "source": "x", "bipolar": false}] as Array[Dictionary]
	await process_frame
	channel.queue_free()


func _find_volume_slider(node: Node) -> VolumeSlider:
	if node is VolumeSlider:
		return node
	for child in node.get_children():
		var found := _find_volume_slider(child)
		if found:
			return found
	return null


## Registers a synth with a Cutoff (log Hz) and an ADSR (skew 4 times), one unipolar source, and
## returns a fresh instance.
func _instance():
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	registry._on_builtin_info_received([
		"test.synth", "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		5,
		31, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1,
		50, "Attack", "s", "float", 1, 0.0005, 10.0, 0.002, 0, 4.0, 0, "", 1,
		51, "Decay", "s", "float", 1, 0.0005, 10.0, 0.3, 0, 4.0, 0, "", 1,
		52, "Sustain", "", "float", 1, 0.0, 1.0, 0.5, 0, 1.0, 0, "", 1,
		53, "Release", "s", "float", 1, 0.0005, 10.0, 0.2, 0, 4.0, 0, "", 1,
		0,
		2, "filter_env", "Filter Env", 0, "lfo1", "LFO 1", 1,
		0,
	])
	return load("res://data/DeviceInstance.gd").new(registry.get_device("test.synth"), 2, 0)


func _control(inst, data: Dictionary):
	var control = load("res://devices/simple_view/SimpleControl.tscn").instantiate()
	control.position = Vector2(100, 100)
	control.size = Vector2(160, 120)
	root.add_child(control)
	control.bind(inst, data)
	return control


func _test_simple_control_assign() -> void:
	var inst = _instance()
	var control = _control(inst, {"kind": "knob", "params": [31], "rect": [0, 0, 1, 1]})
	await process_frame
	_assert(control.is_modulatable(), "a float knob on a modulated device is a target")
	var knob: RotaryKnob = control._inner
	knob.size = Vector2(60, 60)
	var value_before: float = inst.get_parameter_normalized(31)

	control.set_mod_assign("lfo1", Color.RED)
	_assert(knob.mod_assign_active and knob.mod_assign_color == Color.RED, "assign mode reaches the knob")
	_click(knob)
	_motion(knob, Vector2(0, -40))
	_click(knob, false, false)
	var amount: float = inst.get_mod_amount("lfo1", 31)
	_assert(amount > 0.0, "dragging in assign mode sets the route amount (%s)" % amount)
	_assert(is_equal_approx(inst.get_parameter_normalized(31), value_before), "the parameter value is untouched")
	control.refresh_mod()
	_assert(knob.mod_ranges.size() == 1 and knob.mod_ranges[0]["source"] == "lfo1"
		and knob.mod_ranges[0]["bipolar"] == true and is_equal_approx(knob.mod_ranges[0]["amount"], amount),
		"mod_ranges follows the model, with the source's polarity")
	_assert(control.has_route_from("lfo1") and not control.has_route_from("filter_env"), "has_route_from")
	_assert(knob.mod_amount_text_callback.call(0.25).ends_with("oct"), "log Hz shows octaves: %s" % knob.mod_amount_text_callback.call(0.25))

	_click(knob, true)
	_assert(inst.get_mod_amount("lfo1", 31) == 0.0, "double-click in assign mode removes the route")
	control.refresh_mod()
	_assert(knob.mod_ranges.is_empty(), "the arc disappears with the route")

	control.set_mod_assign("")
	_assert(not knob.mod_assign_active, "leaving assign mode")
	_click(knob)
	_motion(knob, Vector2(0, -40))
	_click(knob, false, false)
	_assert(inst.get_parameter_normalized(31) > value_before, "a normal drag edits the value again")
	control.queue_free()

	# enum and bool parameters are not modulatable
	var none = _control(inst, {"kind": "knob", "params": [999], "rect": [0, 0, 1, 1]})
	_assert(not none.is_modulatable(), "an unknown parameter is not a target")
	none.queue_free()


func _test_envelope_compound() -> void:
	var inst = _instance()
	var control = _control(inst, {"kind": "envelope", "params": [50, 51, 52, 53], "rect": [0, 0, 4, 3]})
	await process_frame
	_assert(control._env_knobs.size() == 4, "an ADSR envelope builds four knobs")
	_assert(control._inner is VBoxContainer and control._inner.get_child(0) is EnvelopeControl, "display sits above the knobs")
	_assert(control._mod_targets.size() == 4, "every envelope knob is a modulation target")

	control._env_knobs[1].value = 0.6
	control.refresh()
	var decay: float = inst.get_parameter(51).normalized_to_value(0.6)
	_assert(is_equal_approx(inst.get_parameter_normalized(51), 0.6), "a knob change reaches the device")
	_assert(is_equal_approx(control._envelope.get_stage_value(Envelope.Stage.DECAY), decay),
		"and moves the display's stage value")

	control._envelope.decay = 0.9
	control.refresh()
	_assert(is_equal_approx(control._env_knobs[1].value, inst.get_parameter_normalized(51)), "a display drag moves the knob")
	_assert(is_equal_approx(control._env_knobs[1].value, inst.get_parameter(51).value_to_normalized(0.9)), "…to the matching position")
	control.queue_free()

	var ads = _control(inst, {"kind": "envelope", "params": [50, 51, 52], "stages": "ads", "rect": [0, 0, 4, 3]})
	await process_frame
	_assert(ads._env_knobs.size() == 3, "an 'ads' envelope builds three knobs")
	ads.queue_free()


func _test_footprint() -> void:
	_assert(SimpleControlKinds.footprint(SimpleControlKinds.ENVELOPE) == Vector2i(3, 3), "envelope footprint fits the knob row")


## The whole loop in a SimpleView: the source column appears, clicking a source enters assign mode,
## dragging a knob adds a route, the button count and arc follow, Esc leaves.
func _test_simple_view_loop() -> void:
	var inst = _instance()
	var view = load("res://devices/simple_view/SimpleView.tscn").instantiate()
	root.add_child(view)
	view.bind_to_device(inst)
	view._on_view_shown()
	await process_frame
	_assert(view._mods.visible and view._mod_grid.get_child_count() == 2, "the column shows one button per source")
	_assert(view._mod_grid.columns == 2, "sources sit two to a row")
	var lfo_button: Button = view._mod_buttons["lfo1"]
	_assert(is_equal_approx(lfo_button.size.x, lfo_button.size.y), "source buttons are square (%s)" % lfo_button.size)
	_assert(view._mods.position.x < view._grid.position.x, "the source column is left of the page")
	_assert(lfo_button.text == "LFO 1", "a source's button is labelled with its name: %s" % lfo_button.text)
	lfo_button.button_pressed = true
	lfo_button.toggled.emit(true)
	_assert(view._assign_source == "lfo1", "clicking a source enters assign mode")
	var target = null
	for control in view._controls:
		if control.is_modulatable():
			target = control
			break
	_assert(target != null, "the page has a modulatable control")
	if target != null:
		var node: Control = target._mod_targets[0]["node"]
		_assert(node.mod_assign_active, "assign mode reaches the controls")
		var param_id: int = target._param_ids[target._mod_targets[0]["index"]]
		node.size = Vector2(60, 60)
		node.position = Vector2(300, 300)
		_click(node)
		_motion(node, Vector2(0, -30))
		_click(node, false, false)
		_assert(inst.get_mod_amount("lfo1", param_id) > 0.0, "the drag added a route")
		_assert(lfo_button.text == "LFO 1\n1", "the button shows its route count: %s" % lfo_button.text)
		_assert(node.mod_ranges.size() == 1, "the control's arc follows the signal")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	view._unhandled_input(esc)
	_assert(view._assign_source == "" and not lfo_button.button_pressed, "Esc leaves assign mode")
	view.queue_free()
