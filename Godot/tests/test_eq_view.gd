# EQ panel: the curve editor's gestures end up as parameter writes on the right parameters
# (through the DeviceInstance setter, never OSC), double-click enables the first free band, and
# the view state (analyser mode, dB range) survives a save and reload.
# Run: godot --headless --path Godot -s tests/test_eq_view.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "EQ view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_test_drag_writes_freq_and_gain()
	_test_fine_drag_is_slower()
	_test_cut_drag_changes_only_frequency()
	_test_double_click_enables_first_free_band()
	_test_double_click_on_a_node_disables_it()
	_test_wheel_changes_q()
	_test_listen_follows_the_button()
	_test_view_state_round_trip()
	_test_view_persists_state()
	_test_hidden_view_stops_interaction()
	await _test_draws_in_the_tree()


## A device with the engine's EQ parameters (ids, ranges and defaults as in eq.rs).
func _make_instance() -> Object:
	var device: Object = _device_script.new("sonara.builtin.eq", "EQ", _device_script.DeviceCategory.Effect)
	var freqs := [50.0, 110.0, 240.0, 520.0, 1150.0, 2500.0, 5500.0, 12000.0]
	for band in EqResponse.BAND_COUNT:
		var base: int = band * EqResponse.BAND_STRIDE
		var enabled := DeviceParameter.new(base + EqResponse.P_ENABLED, "Enabled")
		enabled.param_type = "bool"
		enabled.default_value = 0.0
		device.add_parameter(enabled)
		var type := DeviceParameter.new(base + EqResponse.P_TYPE, "Type")
		type.param_type = "enum"
		type.enum_values.assign(EqResponse.TYPE_NAMES)
		type.default_value = 3.0 if band == 0 else (4.0 if band == 7 else 0.0)
		device.add_parameter(type)
		var freq := DeviceParameter.new(base + EqResponse.P_FREQ, "Freq", "Hz")
		freq.min_value = 20.0
		freq.max_value = 20000.0
		freq.is_logarithmic = true
		freq.default_value = freqs[band]
		device.add_parameter(freq)
		var gain := DeviceParameter.new(base + EqResponse.P_GAIN, "Gain", "dB")
		gain.min_value = -24.0
		gain.max_value = 24.0
		gain.default_value = 0.0
		device.add_parameter(gain)
		var q := DeviceParameter.new(base + EqResponse.P_Q, "Q")
		q.min_value = 0.1
		q.max_value = 30.0
		q.is_logarithmic = true
		q.default_value = 0.71
		device.add_parameter(q)
		var slope := DeviceParameter.new(base + EqResponse.P_SLOPE, "Slope")
		slope.param_type = "enum"
		slope.enum_values.assign(EqResponse.SLOPE_NAMES)
		slope.default_value = 1.0
		device.add_parameter(slope)
		var stereo := DeviceParameter.new(base + EqResponse.P_STEREO, "Stereo")
		stereo.param_type = "enum"
		stereo.enum_values.assign(EqResponse.STEREO_NAMES)
		device.add_parameter(stereo)
	var out := DeviceParameter.new(EqResponse.OUTPUT_GAIN, "Gain", "dB")
	out.min_value = -24.0
	out.max_value = 24.0
	out.default_value = 0.0
	device.add_parameter(out)
	var listen := DeviceParameter.new(EqResponse.LISTEN_BAND, "Listen Band")
	listen.param_type = "enum"
	listen.enum_values.assign(["Off", "1", "2", "3", "4", "5", "6", "7", "8"])
	device.add_parameter(listen)
	return _instance_script.new(device, 2, 0)


func _make_editor(instance: Object) -> EqCurveEditor:
	var editor := EqCurveEditor.new()
	editor.size = Vector2(640, 262)  # a 250 px plot and the piano strip
	editor.device = instance
	return editor


func _real(instance: Object, band: int, offset: int) -> float:
	return instance.get_parameter_real(band * EqResponse.BAND_STRIDE + offset)


func _enable(instance: Object, band: int, type: int, freq: float, gain: float) -> void:
	var base := band * EqResponse.BAND_STRIDE
	instance.set_parameter_real(base + EqResponse.P_TYPE, float(type))
	instance.set_parameter_real(base + EqResponse.P_FREQ, freq)
	instance.set_parameter_real(base + EqResponse.P_GAIN, gain)
	instance.set_parameter_real(base + EqResponse.P_ENABLED, 1.0)


func _button(pos: Vector2, button: int, pressed: bool, double_click := false, alt := false) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = button
	ev.pressed = pressed
	ev.double_click = double_click
	ev.alt_pressed = alt
	return ev


func _motion(pos: Vector2, shift := false) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.shift_pressed = shift
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	return ev


func _test_drag_writes_freq_and_gain() -> void:
	var inst := _make_instance()
	_enable(inst, 3, EqResponse.Type.BELL, 1000.0, 0.0)
	var editor := _make_editor(inst)
	_assert(editor.bands[3]["enabled"] and is_equal_approx(editor.bands[3]["freq"], 1000.0), "editor reads the band from the device")
	var start := editor.node_position(editor.bands[3])
	_assert(editor.band_at(start + Vector2(3, 2)) == 3, "a click near the node hits it")
	_assert(editor.band_at(start + Vector2(60, 0)) == -1, "a click far from every node hits nothing")
	editor._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	var target := start + Vector2(80, -40)
	editor._gui_input(_motion(target))
	editor._gui_input(_button(target, MOUSE_BUTTON_LEFT, false))
	var want_freq := editor.freq_axis.x_to_hz(target.x)
	var want_gain := editor.db_grid.y_to_db(target.y)
	_assert(absf(_real(inst, 3, EqResponse.P_FREQ) / want_freq - 1.0) < 0.01, "drag sets Freq of band 4 (got %s, want %s)" % [_real(inst, 3, EqResponse.P_FREQ), want_freq])
	_assert(absf(_real(inst, 3, EqResponse.P_GAIN) - want_gain) < 0.1, "drag sets Gain of band 4 (got %s, want %s)" % [_real(inst, 3, EqResponse.P_GAIN), want_gain])
	_assert(_real(inst, 2, EqResponse.P_FREQ) == 240.0 and _real(inst, 4, EqResponse.P_FREQ) > 1100.0, "other bands are untouched")
	_assert(editor.drag_band == -1, "releasing ends the drag")
	editor.free()


func _test_fine_drag_is_slower() -> void:
	var inst := _make_instance()
	_enable(inst, 1, EqResponse.Type.BELL, 1000.0, 0.0)
	var editor := _make_editor(inst)
	var start := editor.node_position(editor.bands[1])
	editor._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	editor._gui_input(_motion(start + Vector2(100, 0), true))
	var fine := editor.freq_axis.x_to_hz(start.x + 15.0)
	_assert(absf(_real(inst, 1, EqResponse.P_FREQ) / fine - 1.0) < 0.01, "Shift moves at 0.15x (got %s, want %s)" % [_real(inst, 1, EqResponse.P_FREQ), fine])
	editor._gui_input(_button(start, MOUSE_BUTTON_LEFT, false))
	editor.free()


func _test_cut_drag_changes_only_frequency() -> void:
	var inst := _make_instance()
	_enable(inst, 0, EqResponse.Type.LOW_CUT, 80.0, 0.0)
	var editor := _make_editor(inst)
	var start := editor.node_position(editor.bands[0])
	_assert(is_equal_approx(start.y, editor.db_grid.db_to_y(0.0)), "a cut's node sits on the 0 dB line")
	editor._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	editor._gui_input(_motion(start + Vector2(40, -60)))
	editor._gui_input(_button(start, MOUSE_BUTTON_LEFT, false))
	_assert(_real(inst, 0, EqResponse.P_FREQ) > 100.0, "the cut's frequency follows the drag")
	_assert(_real(inst, 0, EqResponse.P_GAIN) == 0.0, "its gain stays put")
	editor.free()


func _test_double_click_enables_first_free_band() -> void:
	var inst := _make_instance()
	var editor := _make_editor(inst)
	var pos := Vector2(300, 60)
	editor._gui_input(_button(pos, MOUSE_BUTTON_LEFT, true, true))
	_assert(_real(inst, 0, EqResponse.P_ENABLED) == 1.0, "double-click enables the first free band (band 1)")
	_assert(_real(inst, 1, EqResponse.P_ENABLED) == 0.0, "and only that one")
	_assert(int(_real(inst, 0, EqResponse.P_TYPE)) == EqResponse.Type.BELL, "a mid-range click makes the default Low Cut band a Bell")
	_assert(absf(_real(inst, 0, EqResponse.P_FREQ) / editor.freq_axis.x_to_hz(pos.x) - 1.0) < 0.01, "the band lands at the click's frequency")
	_assert(absf(_real(inst, 0, EqResponse.P_GAIN) - editor.db_grid.y_to_db(pos.y)) < 0.1, "and at its gain")
	editor._gui_input(_button(Vector2(500, 150), MOUSE_BUTTON_LEFT, true, true))
	_assert(_real(inst, 1, EqResponse.P_ENABLED) == 1.0, "the next double-click takes the next free band")
	# At the far left edge a double-click keeps the Low Cut of a fresh EQ.
	var fresh := _make_instance()
	var edge_editor := _make_editor(fresh)
	edge_editor._gui_input(_button(Vector2(1, 100), MOUSE_BUTTON_LEFT, true, true))
	_assert(int(_real(fresh, 0, EqResponse.P_TYPE)) == EqResponse.Type.LOW_CUT, "a click in the lowest octave keeps band 1 a Low Cut")
	editor.free()
	edge_editor.free()


func _test_double_click_on_a_node_disables_it() -> void:
	var inst := _make_instance()
	_enable(inst, 2, EqResponse.Type.BELL, 800.0, 4.0)
	var editor := _make_editor(inst)
	editor._gui_input(_button(editor.node_position(editor.bands[2]), MOUSE_BUTTON_LEFT, true, true))
	_assert(_real(inst, 2, EqResponse.P_ENABLED) == 0.0, "double-click on a node disables the band")
	_assert(not editor.bands[2]["enabled"], "the editor follows")
	editor.free()


func _test_wheel_changes_q() -> void:
	var inst := _make_instance()
	_enable(inst, 4, EqResponse.Type.BELL, 1000.0, 3.0)
	var editor := _make_editor(inst)
	var pos := editor.node_position(editor.bands[4])
	var before := _real(inst, 4, EqResponse.P_Q)
	editor._gui_input(_button(pos, MOUSE_BUTTON_WHEEL_UP, true))
	var up := _real(inst, 4, EqResponse.P_Q)
	_assert(up > before * 1.05, "wheel up narrows the band (Q %s -> %s)" % [before, up])
	editor._gui_input(_button(pos, MOUSE_BUTTON_WHEEL_DOWN, true))
	_assert(absf(_real(inst, 4, EqResponse.P_Q) - before) < 0.02, "wheel down widens it again")
	editor.free()


func _test_listen_follows_the_button() -> void:
	var inst := _make_instance()
	_enable(inst, 5, EqResponse.Type.BELL, 2000.0, 6.0)
	var editor := _make_editor(inst)
	var pos := editor.node_position(editor.bands[5])
	editor._gui_input(_button(pos, MOUSE_BUTTON_MIDDLE, true))
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 6, "middle button listens to band 6")
	editor._gui_input(_button(pos, MOUSE_BUTTON_MIDDLE, false))
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 0, "releasing stops listening")
	editor._gui_input(_button(pos, MOUSE_BUTTON_LEFT, true, false, true))
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 6, "Alt + press listens too")
	editor._gui_input(_button(pos, MOUSE_BUTTON_LEFT, false))
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 0, "and stops on release")
	editor.free()


func _test_view_state_round_trip() -> void:
	var state := EqViewState.new()
	state.analyser = EqViewState.Analyser.PRE
	state.range_db = 24.0
	var restored := EqViewState.from_dict(JSON.parse_string(JSON.stringify(state.to_dict())))
	_assert(restored.equals(state), "state survives a JSON save and reload")
	var bad := EqViewState.from_dict({"analyser": "sideways", "range_db": 7.0})
	_assert(bad.analyser == EqViewState.Analyser.POST and bad.range_db == 12.0, "junk falls back to the defaults")
	_assert(EqViewState.from_dict(null).range_db == 12.0, "missing state is the defaults")


func _test_view_persists_state() -> void:
	var store := {}
	var load_fn := func(key: String) -> Variant: return store.get(key, {})
	var save_fn := func(key: String, value: Variant) -> void: store[key] = value
	var view_script: GDScript = load("res://devices/builtin/EqDefaultView.gd")
	var inst := _make_instance()
	var view = view_script.new()
	view.load_config = load_fn
	view.save_config = save_fn
	view.bind_to_device(inst)
	_assert(view.editor.state.analyser == EqViewState.Analyser.POST and view.editor.state.range_db == 12.0, "a new view starts with the default state")
	view.editor.set_analyser_mode(EqViewState.Analyser.OFF)
	view.editor.set_range_db(6.0)
	_assert(store.has(EqViewState.CONFIG_KEY), "changing the state writes it to the config")
	var reloaded = view_script.new()
	reloaded.load_config = load_fn
	reloaded.save_config = save_fn
	reloaded.bind_to_device(_make_instance())
	_assert(reloaded.editor.state.analyser == EqViewState.Analyser.OFF and reloaded.editor.state.range_db == 6.0, "a view created later picks the saved state up")
	_assert(reloaded._analyser_option.selected == EqViewState.Analyser.OFF and reloaded._range_option.selected == 0, "and shows it in the toolbar")
	# The knobs show the band's parameters.
	_enable(inst, 2, EqResponse.Type.HIGH_SHELF, 4000.0, 5.0)
	_assert(view._items[2]["root"].visible and not view._items[3]["root"].visible, "only enabled bands show a knob strip")
	_assert(absf(view._items[2]["freq"].knob.value - 4000.0) < 1.0 and absf(view._items[2]["gain"].knob.value - 5.0) < 0.05, "knobs follow the device")
	view.free()
	reloaded.free()


func _test_hidden_view_stops_interaction() -> void:
	var inst := _make_instance()
	_enable(inst, 0, EqResponse.Type.BELL, 500.0, 3.0)
	var view_script: GDScript = load("res://devices/builtin/EqDefaultView.gd")
	var view = view_script.new()
	view.load_config = func(_key: String) -> Variant: return {}
	view.save_config = func(_key: String, _value: Variant) -> void: pass
	view.bind_to_device(inst)
	view._on_view_shown()
	var pos: Vector2 = view.editor.node_position(view.editor.bands[0])
	view.editor.size = Vector2(640, 262)
	view.editor._gui_input(_button(pos, MOUSE_BUTTON_MIDDLE, true))
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 1, "listening")
	view._on_view_hidden()
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 0, "hiding the view stops listening")
	_assert(not view._subscribed, "and unsubscribes from the analyser")
	view.free()


## Everything the view draws (grids, analyser, curves, nodes, readout, piano strip, menu) runs in
## the tree without script errors; run_all.sh fails a script that prints one.
func _test_draws_in_the_tree() -> void:
	var inst := _make_instance()
	_enable(inst, 0, EqResponse.Type.LOW_CUT, 60.0, 0.0)
	_enable(inst, 1, EqResponse.Type.BELL, 300.0, -6.0)
	_enable(inst, 2, EqResponse.Type.TILT, 1000.0, 4.0)
	_enable(inst, 3, EqResponse.Type.BAND_PASS, 2000.0, 0.0)
	_enable(inst, 4, EqResponse.Type.NOTCH, 3000.0, 0.0)
	_enable(inst, 5, EqResponse.Type.HIGH_SHELF, 6000.0, 8.0)
	_enable(inst, 7, EqResponse.Type.HIGH_CUT, 14000.0, 0.0)
	var view_script: GDScript = load("res://devices/builtin/EqDefaultView.gd")
	var view = view_script.new()
	view.load_config = func(_key: String) -> Variant: return {}
	view.save_config = func(_key: String, _value: Variant) -> void: pass
	view.size = Vector2(700, 300)
	view.bind_to_device(inst)
	root.add_child(view)
	view._on_view_shown()
	var frame := PackedFloat32Array([0.0, 48000.0])
	var post := PackedFloat32Array([1.0, 48000.0])
	for i in 2049:
		frame.append(-60.0 - 20.0 * log(1.0 + i / 40.0))
		post.append(-55.0 - 20.0 * log(1.0 + i / 40.0))
	view.editor.on_spectrum_frame(frame)
	view.editor.on_spectrum_frame(post)
	view.editor.hover_band = 1
	await process_frame
	await process_frame
	view.editor.set_range_db(24.0)
	view.editor.set_analyser_mode(EqViewState.Analyser.PRE)
	view.editor.drag_band = 2
	await process_frame
	view.editor._open_menu(1, Vector2(100, 100))
	await process_frame
	_assert(view.editor._curves.size() == EqResponse.BAND_COUNT and view.editor._total.size() > 32, "curves were computed for drawing")
	_assert(view.editor._total[0] < -10.0, "the low cut shows in the drawn total at 20 Hz")
	view._on_view_hidden()
	view.queue_free()
	await process_frame
