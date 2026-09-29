# Mixer pan readout: a plain overlay shown on hover and drag that never widens the strip, with a
# per-part text in Stereo Combined.
extends TestBase

var _ch: GDScript


func suite_name() -> String:
	return "Pan readout"


func run_tests() -> void:
	_ch = load("res://data/Channel.gd")
	_test_hover_and_layout()
	_test_combined_parts()
	_test_dual_text()


## A PanControl (load()ed: it needs the autoloads) built like the one in MixerChannel.tscn, placed away from the headless pointer.
func _make_pan() -> Control:
	var pan := PanelContainer.new()
	var single := HorSlider.new()
	single.name = "HSlider"
	single.min_value = -100.0
	single.max_value = 100.0
	pan.add_child(single)
	var dual := HDualSlider.new()
	dual.name = "DualPanSlider"
	dual.min_value = -100.0
	dual.max_value = 100.0
	pan.add_child(dual)
	var popup := PopupMenu.new()
	popup.name = "PanModePopup"
	for i in 4:
		popup.add_check_item("mode", i)
	pan.add_child(popup)
	pan.set_script(load("res://mixer/PanControl.gd"))
	pan.position = Vector2(200, 200)
	pan.custom_minimum_size = Vector2(100, 24)
	root.add_child(pan)
	pan.size = Vector2(100, 24)
	return pan


func _tip(pan: Control) -> ValueTooltip:
	return pan.get_child(-1, true) as ValueTooltip


func _move(slider: Control, x: float) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(x, 12)
	slider.gui_input.emit(e)


func _test_hover_and_layout() -> void:
	var pan = _make_pan()
	var c = _ch.new(2)
	c.set_pan(-1.0)
	pan.bind_to_channel(c)
	var tip := _tip(pan)
	_assert(tip != null and tip.top_level and tip.mouse_filter == Control.MOUSE_FILTER_IGNORE, "readout is a top-level, click-through overlay")
	_assert(not tip.visible, "readout hidden at rest")
	var slider: Control = pan.get_node("HSlider")
	slider.mouse_entered.emit()
	_assert(tip.visible and pan.get_value_text() == "-100", "hover shows the balance value as a signed percent")
	var min_w: float = pan.get_combined_minimum_size().x
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	c.set_pan_dual(-1.0, 1.0)
	_assert(pan.get_combined_minimum_size().x == min_w, "a long readout doesn't widen the strip")
	slider.mouse_exited.emit()
	_assert(not tip.visible, "readout hides when the pointer leaves")
	pan.queue_free()


func _test_combined_parts() -> void:
	var pan = _make_pan()
	var c = _ch.new(2)
	c.set_pan_mode(_ch.PanMode.STEREO_COMBINED)
	c.set_pan(0.1)
	c.set_pan_width(0.4)
	pan.bind_to_channel(c)
	var dual: HDualSlider = pan.get_node("DualPanSlider")
	dual.size = Vector2(100, 24)
	dual.mouse_entered.emit()
	# Handles sit at x 35 and 75; the fill spans between them.
	_move(dual, 55)
	_assert(pan.get_value_text() == "10", "hovering the fill shows the position")
	_move(dual, 35)
	_assert(pan.get_value_text() == "W: 40", "hovering the left handle shows the width")
	_move(dual, 75)
	_assert(pan.get_value_text() == "W: 40", "hovering the right handle shows the width")
	_move(dual, 3)
	_assert(pan.get_value_text() == "W: 40", "empty space left of the fill shows the width")
	_move(dual, 97)
	_assert(pan.get_value_text() == "W: 40", "empty space right of the fill shows the width")
	pan.queue_free()


func _test_dual_text() -> void:
	var pan = _make_pan()
	var c = _ch.new(2)
	c.set_pan_mode(_ch.PanMode.STEREO_DUAL)
	c.set_pan_dual(-0.3, 0.8)
	pan.bind_to_channel(c)
	_assert(pan.get_value_text() == "-30 / 80", "dual readout is signed, with no L/R labels")
	pan.queue_free()
