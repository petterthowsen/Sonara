# Modulation UI components: the shared drawing/assign contract on RotaryKnob, HorSlider,
# VolumeSlider and Volumeter (spec 018 reuses these from the Modulators pane).
# Run: godot --headless --path Godot -s tests/test_mod_assign_ui.gd -- --test
extends TestBase

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


func _test_footprint() -> void:
	_assert(SimpleControlKinds.footprint(SimpleControlKinds.ENVELOPE) == Vector2i(3, 3), "envelope footprint fits the knob row")
