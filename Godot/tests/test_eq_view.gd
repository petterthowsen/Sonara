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
	_test_display_menu_sends_analyser_options()
	_test_tilt_lifts_the_highs()
	_test_analyser_interpolates_over_time()
	_test_selection_and_piano()
	_test_hidden_view_stops_interaction()
	_test_footer_band_selector()
	_test_footer_solo_enabled_type()
	_test_type_icons_cover_all_types()
	_test_disabled_band_stays_editable()
	_test_companion_solo_and_type()
	_test_companion_strips_show_toggle_and_solo()
	_test_spectrum_smoothing()
	_test_note_and_cents()
	_test_piano_toggle_and_cursor_readout()
	_test_companion_slope_and_value_knobs()
	_test_footer_modulation_follows_the_band()
	_test_editor_draws_live_modulation()
	_test_view_feeds_live_modulation()
	ModLive.reset()
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
		freq.is_modulatable = true
		device.add_parameter(freq)
		var gain := DeviceParameter.new(base + EqResponse.P_GAIN, "Gain", "dB")
		gain.min_value = -24.0
		gain.max_value = 24.0
		gain.default_value = 0.0
		gain.is_modulatable = true
		device.add_parameter(gain)
		var q := DeviceParameter.new(base + EqResponse.P_Q, "Q")
		q.min_value = 0.1
		q.max_value = 30.0
		q.is_logarithmic = true
		q.default_value = 0.71
		q.is_modulatable = true
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
	var mix := DeviceParameter.new(EqResponse.MIX, "Mix", "%")
	mix.min_value = 0.0
	mix.max_value = 100.0
	mix.default_value = 100.0
	device.add_parameter(mix)
	var listen := DeviceParameter.new(EqResponse.LISTEN_BAND, "Listen Band")
	listen.param_type = "enum"
	listen.enum_values.assign(["Off", "1", "2", "3", "4", "5", "6", "7", "8"])
	device.add_parameter(listen)
	return _instance_script.new(device, 2, 0)


func _test_note_and_cents() -> void:
	var a3 := FreqAxis.hz_to_note_cents(440.0)
	_assert(a3["note"] == 69 and a3["cents"] == 0, "440 Hz is MIDI 69 with no offset")
	_assert(FreqAxis.format_note_cents(440.0) == "A3 +0¢", "440 Hz reads A3 +0¢ (C3 = 60)")
	_assert(FreqAxis.format_note_cents(261.6256) == "C3 +0¢", "middle C is C3")
	_assert(FreqAxis.format_note_cents(440.0 * pow(2.0, 20.0 / 1200.0)) == "A3 +20¢", "20 cents sharp")
	_assert(FreqAxis.format_note_cents(440.0 * pow(2.0, -30.0 / 1200.0)) == "A3 -30¢", "30 cents flat")
	_assert(FreqAxis.format_note_cents(440.0 * pow(2.0, 70.0 / 1200.0)) == "A#3 -30¢", "past a quarter tone it names the next note")
	_assert(FreqAxis.format_hz_long(440.0) == "440 Hz", "below 1 kHz in Hz")
	_assert(FreqAxis.format_hz_long(1250.0) == "1.25 kHz", "above 1 kHz in kHz")
	_assert(FreqAxis.format_hz_long(2000.0) == "2 kHz", "a round kHz has no decimals")
	_assert(FreqAxis.hz_to_note_cents(0.0)["note"] == 0, "zero Hz does not crash")


func _test_piano_toggle_and_cursor_readout() -> void:
	var inst := _make_instance()
	var view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	view.set_view_type(Device.ViewType.Window)
	var saved := {}
	view.load_config = func(_key: String) -> Variant: return {}
	view.save_config = func(key: String, value: Variant) -> void: saved[key] = value
	view.bind_to_device(inst)
	root.add_child(view)  # bound before entering the tree, as the panel does
	_assert(view._piano_button != null and view._piano_button.button_pressed and view.editor.show_piano, "the window view starts with the piano on and a toggle")
	view._piano_button.toggled.emit(false)
	_assert(not view.editor.show_piano and not view.editor.state.piano, "the toggle hides the piano strip")
	_assert(saved.has(EqViewState.CONFIG_KEY) and saved[EqViewState.CONFIG_KEY]["piano"] == false, "the choice is saved in the view state")
	_assert(EqViewState.from_dict(saved[EqViewState.CONFIG_KEY]).piano == false, "and round-trips")
	_assert(EqViewState.new().piano, "the piano defaults to on")
	var editor: EqCurveEditor = view.editor
	_assert(editor.show_cursor_readout, "the window view has the cursor readout")
	editor.size = Vector2(640, 262)
	editor._update_layout()
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(editor.freq_axis.hz_to_x(440.0), 100)
	editor._gui_input(motion)
	_assert(editor.cursor_readout_text() == "440 Hz  A3 +0¢", "the readout names the hovered frequency: %s" % editor.cursor_readout_text())
	view.free()
	var panel = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	panel.load_config = func(_key: String) -> Variant: return {}
	panel.save_config = func(_key: String, _value: Variant) -> void: pass
	panel.bind_to_device(inst)
	root.add_child(panel)  # bound before entering the tree, as the panel does
	_assert(not panel._piano_button.visible and not panel.editor.show_cursor_readout and not panel.editor.show_piano, "the panel view hides the piano toggle and has no cursor line")
	panel.free()


func _test_companion_slope_and_value_knobs() -> void:
	var inst := _make_instance()
	var companion = load("res://devices/builtin/eq/EqBandsCompanionView.tscn").instantiate()
	companion.bind_to_device(inst)
	root.add_child(companion)  # bound before entering the tree, as the panel does
	# Band 1 is a Low Cut by default, band 2 a Bell.
	_assert(not companion._items[0].slope.disabled, "a cut band offers its slope")
	_assert(companion._items[1].slope.disabled, "a bell has no slope")
	_assert(companion._items[0].slope.get_parent() == companion._items[0].type.get_parent(), "type and slope sit side by side")
	companion._items[0].slope.item_selected.emit(3)
	_assert(int(_real(inst, 0, EqResponse.P_SLOPE)) == 3, "the slope box writes the band's slope")
	_assert(companion._items[0].slope.selected == 3, "and shows it")
	_assert(companion._items[0].toggle.get_parent() == companion._items[0].solo.get_parent(), "enabled and solo sit side by side")
	var freq: LabeledKnob = companion._items[0].freq
	_assert(freq.display_mode == LabeledKnob.DisplayMode.VALUE and freq.value_label.visible and not freq.label.visible, "companion knobs show the value only")
	_assert(freq.value_label.text != "" and freq.value_label.text.ends_with("Hz"), "the value text uses the freq format: %s" % freq.value_label.text)
	companion.free()


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
	state.resolution = EqViewState.Resolution.MAX
	state.speed = EqViewState.Speed.SLOW
	state.tilt_db = 4.5
	var restored := EqViewState.from_dict(JSON.parse_string(JSON.stringify(state.to_dict())))
	_assert(restored.equals(state), "state survives a JSON save and reload")
	var bad := EqViewState.from_dict({"analyser": "sideways", "range_db": 7.0, "resolution": "huge", "speed": 9, "tilt_db": 5.0})
	_assert(bad.analyser == EqViewState.Analyser.POST and bad.range_db == 12.0, "junk falls back to the defaults")
	_assert(bad.resolution == EqViewState.Resolution.MEDIUM and bad.speed == EqViewState.Speed.MEDIUM and bad.tilt_db == 0.0, "junk analyser options too")
	_assert(EqViewState.from_dict({"analyser": "pre"}).resolution == EqViewState.Resolution.MEDIUM, "state saved before the options existed loads")
	_assert(EqViewState.from_dict(null).range_db == 12.0, "missing state is the defaults")


func _test_view_persists_state() -> void:
	var store := {}
	var load_fn := func(key: String) -> Variant: return store.get(key, {})
	var save_fn := func(key: String, value: Variant) -> void: store[key] = value
	var inst := _make_instance()
	var view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	view.load_config = load_fn
	view.save_config = save_fn
	view.bind_to_device(inst)
	root.add_child(view)  # bound before entering the tree, as the panel does
	_assert(view.editor.state.analyser == EqViewState.Analyser.POST and view.editor.state.range_db == 12.0, "a new view starts with the default state")
	view.editor.set_analyser_mode(EqViewState.Analyser.OFF)
	view.editor.set_range_db(6.0)
	_assert(store.has(EqViewState.CONFIG_KEY), "changing the state writes it to the config")
	var reloaded = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	reloaded.load_config = load_fn
	reloaded.save_config = save_fn
	root.add_child(reloaded)  # this one enters the tree first, then binds
	reloaded.bind_to_device(_make_instance())
	_assert(reloaded.editor.state.analyser == EqViewState.Analyser.OFF and reloaded.editor.state.range_db == 6.0, "a view created later picks the saved state up")
	_assert(reloaded._analyser_option.selected == EqViewState.Analyser.OFF and reloaded._range_option.selected == 0, "and shows it in the toolbar")
	# The knobs show the band's parameters.
	_enable(inst, 2, EqResponse.Type.HIGH_SHELF, 4000.0, 5.0)
	_assert(view.editor.selected_band == 2 and view._band == 2, "enabling a band selects it, and the view follows")
	_assert(absf(view._freq_slider.value - 4000.0) < 1.0 and absf(view._gain_slider.value - 5.0) < 0.05, "the sliders show the selected band")
	_assert(view._type_option.selected == EqResponse.Type.HIGH_SHELF, "and its type")
	view._freq_slider.value_changed.emit(5000.0)
	_assert(absf(_real(inst, 2, EqResponse.P_FREQ) - 5000.0) < 0.5, "a knob writes the selected band")
	view._type_option.item_selected.emit(EqResponse.Type.LOW_CUT)
	_assert(int(_real(inst, 2, EqResponse.P_TYPE)) == EqResponse.Type.LOW_CUT, "the type box writes the selected band")
	_assert(not view.editor.show_piano, "the panel view has no piano strip")
	_enable(inst, 4, EqResponse.Type.BELL, 800.0, 1.0)
	view.editor.disable_band(2)
	_assert(view.editor.selected_band == 4 and view._band == 4, "disabling the selected band selects another enabled one")
	view.free()
	reloaded.free()


func _test_selection_and_piano() -> void:
	var inst := _make_instance()
	_enable(inst, 0, EqResponse.Type.BELL, 200.0, 3.0)
	_enable(inst, 1, EqResponse.Type.BELL, 2000.0, -3.0)
	var editor := _make_editor(inst)
	_assert(editor.selected_band == 0, "the first enabled band starts selected")
	editor.select_band(-1)
	var pos := editor.node_position(editor.bands[1])
	editor._gui_input(_button(pos, MOUSE_BUTTON_LEFT, true))
	_assert(editor.selected_band == 1, "pressing a node selects it")
	var with_piano := editor.plot_rect().size.y
	editor.show_piano = false
	_assert(editor.plot_rect().size.y == editor.size.y and with_piano < editor.size.y, "hiding the piano gives its height to the plot")
	editor.free()
	var companion_view = load("res://devices/builtin/eq/EqBandsCompanionView.tscn").instantiate()
	companion_view.bind_to_device(inst)
	root.add_child(companion_view)  # bound before entering the tree, as the panel does
	_assert(companion_view._items[0].toggle.button_pressed and not companion_view._items[2].toggle.button_pressed, "the companion view toggles show which bands are on")
	companion_view._items[2].toggle.toggled.emit(true)
	_assert(_real(inst, 2, EqResponse.P_ENABLED) >= 0.5, "a toggle enables its band")
	companion_view._items[1].q.knob.value_changed.emit(2.0)
	_assert(absf(_real(inst, 1, EqResponse.P_Q) - 2.0) < 0.05, "a knob writes its band")
	companion_view.free()
	var window_view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	window_view.set_view_type(Device.ViewType.Window)
	window_view.load_config = func(_key: String) -> Variant: return {}
	window_view.save_config = func(_key: String, _value: Variant) -> void: pass
	window_view.bind_to_device(inst)
	root.add_child(window_view)  # bound before entering the tree, as the panel does
	_assert(window_view.editor.show_piano, "the window view keeps the piano strip")
	window_view.free()


func _test_hidden_view_stops_interaction() -> void:
	var inst := _make_instance()
	_enable(inst, 0, EqResponse.Type.BELL, 500.0, 3.0)
	var view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	view.load_config = func(_key: String) -> Variant: return {}
	view.save_config = func(_key: String, _value: Variant) -> void: pass
	view.bind_to_device(inst)
	root.add_child(view)  # bound before entering the tree, as the panel does
	view._on_view_shown()
	var pos: Vector2 = view.editor.node_position(view.editor.bands[0])
	view.editor.size = Vector2(640, 262)
	view.editor._gui_input(_button(pos, MOUSE_BUTTON_MIDDLE, true))
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 1, "listening")
	view._on_view_hidden()
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 0, "hiding the view stops listening")
	_assert(not view._subscribed, "and unsubscribes from the analyser")
	view.free()


## The Display menu changes the view state, and the view sends resolution and speed to the
## engine after subscribing and on change, but not again when nothing changed. In test mode the
## OSC autoload queues sends in `_pending_sends` instead of sending them.
func _test_display_menu_sends_analyser_options() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	if osc == null:
		_assert(false, "AudioEngineOSC autoload is present")
		return
	var store := {}
	var view_script: GDScript = load("res://devices/builtin/eq/EqDefaultView.gd")
	var view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	view.load_config = func(key: String) -> Variant: return store.get(key, {})
	view.save_config = func(key: String, value: Variant) -> void: store[key] = value
	view.bind_to_device(_make_instance())
	root.add_child(view)  # bound before entering the tree, as the panel does
	osc._pending_sends.clear()
	view._on_view_shown()
	var configures := func() -> Array:
		return osc._pending_sends.filter(func(item): return str(item["address"]).ends_with("/data/configure")).map(func(item): return item["args"])
	_assert(configures.call() == [["spectrum", "resolution", 1.0], ["spectrum", "speed", 1.0]], "subscribing sends both options: %s" % [configures.call()])
	osc._pending_sends.clear()
	view._on_display_item(view_script.MENU_RESOLUTION + 3)
	_assert(view.editor.state.resolution == EqViewState.Resolution.MAX, "the menu sets the resolution")
	_assert(configures.call() == [["spectrum", "resolution", 3.0]], "and sends only that: %s" % [configures.call()])
	osc._pending_sends.clear()
	view._on_display_item(view_script.MENU_TILT + 2)
	_assert(view.editor.state.tilt_db == 4.5, "the menu sets the tilt")
	_assert(configures.call().is_empty(), "tilt is drawing only: nothing sent")
	var popup: PopupMenu = view._display_menu.get_popup()
	_assert(popup.is_item_checked(popup.get_item_index(view_script.MENU_RESOLUTION + 3)), "the menu ticks the new resolution")
	_assert(EqViewState.from_dict(store[EqViewState.CONFIG_KEY]).tilt_db == 4.5, "and the config keeps it")
	view._on_view_hidden()
	osc._pending_sends.clear()
	view.free()


func _spectrum_frame(flag: float, points: int, db: float) -> PackedFloat32Array:
	var frame := PackedFloat32Array([flag, 48000.0, 20.0, 20000.0])
	for i in points:
		frame.append(db)
	return frame


## New analyser frames set a target; the drawn spectrum moves linearly toward it over one frame
## interval in `_process`, then stops, and snaps when the first frame arrives or the point count changes.
func _test_analyser_interpolates_over_time() -> void:
	var editor := EqCurveEditor.new()
	editor.size = Vector2(600, 300)
	root.add_child(editor)
	editor.on_spectrum_frame(_spectrum_frame(1.0, 64, -60.0))
	_assert(editor._post_points[10] == -60.0, "the first frame snaps")
	_assert(editor.is_processing() and editor._post_target[10] == -60.0, "a frame starts processing")
	editor._process(0.1)
	_assert(not editor.is_processing(), "no processing once settled")
	editor.on_spectrum_frame(_spectrum_frame(1.0, 64, -20.0))
	_assert(editor._post_points[10] == -60.0 and editor._post_target[10] == -20.0, "a new frame does not jump")
	editor._frame_interval = 0.05
	editor._process(0.025)
	_assert(absf(editor._post_points[10] + 40.0) < 0.001, "halfway through the frame interval it is halfway (linear)")
	_assert(editor.is_processing(), "still processing while interpolating")
	editor.on_spectrum_frame(_spectrum_frame(1.0, 64, 0.0))
	_assert(absf(editor._post_points[10] + 40.0) < 0.001, "a frame mid-way restarts from where the line is")
	editor._frame_interval = 0.05
	editor._process(0.025)
	_assert(absf(editor._post_points[10] + 20.0) < 0.001, "and blends linearly toward the new target")
	editor._process(0.05)
	_assert(editor._post_points[10] == 0.0, "it lands exactly on the target")
	_assert(not editor.is_processing(), "processing stops when it arrives")
	editor.on_spectrum_frame(_spectrum_frame(1.0, 128, -30.0))
	_assert(editor._post_points.size() == 128 and editor._post_points[100] == -30.0, "a point count change snaps")
	editor.clear_analyser()
	_assert(editor._post_points.is_empty() and editor._post_target.is_empty() and not editor.is_processing(), "clear drops both buffers and stops")
	editor.set_analyser_mode(EqViewState.Analyser.OFF)
	editor.on_spectrum_frame(_spectrum_frame(1.0, 64, -20.0))
	_assert(not editor.is_processing(), "no processing while the analyser is off")
	editor.free()


## Tilt rotates the drawn analyser around 1 kHz: a flat spectrum rises towards the highs.
func _test_tilt_lifts_the_highs() -> void:
	var editor := EqCurveEditor.new()
	editor.size = Vector2(600, 300)
	editor.show_piano = false
	editor.freq_axis.rect = editor.plot_rect()
	var frame := PackedFloat32Array([1.0, 48000.0, 20.0, 20000.0])
	for i in 256:
		frame.append(-40.0)
	editor.on_spectrum_frame(frame)
	_assert(editor._post_points.size() == 256 and editor._points_hi_hz == 20000.0, "a frame is parsed into points")
	editor.on_spectrum_frame(PackedFloat32Array([1.0, 48000.0, 20.0]))
	_assert(editor._post_points.size() == 256, "a short frame is ignored")
	editor.set_tilt_db(6.0)
	_assert(editor.state.tilt_db == 6.0, "tilt is view state")
	editor.free()


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
	var view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	view.load_config = func(_key: String) -> Variant: return {}
	view.save_config = func(_key: String, _value: Variant) -> void: pass
	view.size = Vector2(700, 300)
	view.bind_to_device(inst)
	root.add_child(view)
	view._on_view_shown()
	var frame := PackedFloat32Array([0.0, 48000.0, 20.0, 20000.0])
	var post := PackedFloat32Array([1.0, 48000.0, 20.0, 20000.0])
	for i in 256:
		frame.append(-30.0 - 0.15 * i)
		post.append(-25.0 - 0.15 * i)
	view.editor.on_spectrum_frame(frame)
	view.editor.on_spectrum_frame(post)
	view.editor.hover_band = 1
	await process_frame
	await process_frame
	view.editor.set_range_db(24.0)
	view.editor.set_analyser_mode(EqViewState.Analyser.PRE)
	view.editor.set_tilt_db(4.5)
	view.editor.drag_band = 2
	await process_frame
	view.editor._open_menu(1, Vector2(100, 100))
	await process_frame
	_assert(view.editor._curves.size() == EqResponse.BAND_COUNT and view.editor._total.size() > 32, "curves were computed for drawing")
	_assert(view.editor._total[0] < -10.0, "the low cut shows in the drawn total at 20 Hz")
	# The footer's compact sliders must get a real rect from the layout: a Control with no
	# intrinsic minimum size lays out 0 px tall in the HBox and then can't receive any input.
	_assert(view._freq_slider.size.y > 0.0 and view._freq_slider.get_global_rect().size.y > 0.0,
		"the footer sliders have clickable height after layout")
	_assert(view.get_minimum_size().x >= view._footer.get_combined_minimum_size().x,
		"the panel width follows the footer row's natural width")
	view._on_view_hidden()
	view.queue_free()
	await process_frame


# ============================================================================
# REQ-007 / REQ-009: the footer's band selector, toggles and type dropdown
# ============================================================================

## A panel view bound to `inst` with the config stubs the other view tests use.
func _make_panel_view(inst: Object) -> Object:
	var view = load("res://devices/builtin/eq/EqDefaultView.tscn").instantiate()
	view.load_config = func(_key: String) -> Variant: return {}
	view.save_config = func(_key: String, _value: Variant) -> void: pass
	view.bind_to_device(inst)
	root.add_child(view)  # bound before entering the tree, as the panel does
	return view


func _test_footer_band_selector() -> void:
	var inst := _make_instance()
	_enable(inst, 1, EqResponse.Type.BELL, 2000.0, -3.0)
	_enable(inst, 3, EqResponse.Type.BELL, 520.0, 2.0)
	var view = _make_panel_view(inst)
	_assert(view._band_option.selected == 1 and view._band == 1, "the selector shows the first enabled band")
	# Editor selection drives the selector and the sliders.
	view.editor.select_band(3)
	_assert(view._band_option.selected == 3 and view._band == 3, "selecting a band in the editor moves the selector")
	_assert(absf(view._freq_slider.value - 520.0) < 1.0 and absf(view._gain_slider.value - 2.0) < 0.05, "the sliders follow the selection")
	# And the selector drives the editor back.
	view._band_option.item_selected.emit(1)
	_assert(view.editor.selected_band == 1 and view._band == 1, "choosing a band moves the editor's selection")
	_assert(absf(view._freq_slider.value - 2000.0) < 1.0, "and the sliders re-aim at that band")
	# REQ-009: a lost editor selection never leaves the footer without a band.
	view.editor.select_band(-1)
	_assert(view._band == 1 and view._band_option.selected == 1, "a -1 editor selection leaves the footer's band alone")
	_assert(view._band_option.selected >= 0 and view._band_option.selected < EqResponse.BAND_COUNT, "the selector always has a band (1-8, none state never reached)")
	view.free()


func _test_footer_solo_enabled_type() -> void:
	var inst := _make_instance()
	_enable(inst, 2, EqResponse.Type.BELL, 800.0, 4.0)
	var view = _make_panel_view(inst)
	# Solo: LISTEN_BAND = band + 1, pressing again goes back to Off.
	view._solo_button.toggled.emit(true)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 3, "soloing band 3 writes LISTEN_BAND 3")
	view._solo_button.toggled.emit(false)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 0, "pressing the solo again goes back to Off")
	inst.set_parameter_real(EqResponse.LISTEN_BAND, 3.0)
	view._on_device_parameter_changed(EqResponse.LISTEN_BAND, 3.0)
	_assert(view._solo_button.button_pressed, "the solo button reflects a LISTEN_BAND change")
	# Enabled: writes the selected band's P_ENABLED.
	view._enabled_button.toggled.emit(false)
	_assert(_real(inst, 2, EqResponse.P_ENABLED) == 0.0, "the enabled toggle turns the band off")
	view._enabled_button.toggled.emit(true)
	_assert(_real(inst, 2, EqResponse.P_ENABLED) == 1.0, "and on again")
	# Type: writes the selected band's P_TYPE and dims gain for gain-less types.
	view._type_option.item_selected.emit(EqResponse.Type.NOTCH)
	_assert(int(_real(inst, 2, EqResponse.P_TYPE)) == EqResponse.Type.NOTCH, "the type dropdown writes the selected band's type")
	_assert(view._type_option.selected == EqResponse.Type.NOTCH, "and its selection shows it")
	_assert(view._gain_slider.modulate.a < 1.0 and view._gain_slider.mouse_filter == Control.MOUSE_FILTER_IGNORE, "a Notch dims the gain slider")
	view._type_option.item_selected.emit(EqResponse.Type.BELL)
	_assert(view._gain_slider.modulate.a == 1.0 and view._gain_slider.mouse_filter == Control.MOUSE_FILTER_PASS, "a Bell lights it back up")
	view.free()


func _test_type_icons_cover_all_types() -> void:
	var color := EqCurveEditor.band_color(0)
	for i in EqResponse.TYPE_NAMES.size():
		var tex: ImageTexture = EqTypeIcon.texture(i, color)
		_assert(tex != null and tex.get_size().x > 0 and tex.get_size().y > 0, "type %d (%s) renders a non-empty icon" % [i, EqResponse.TYPE_NAMES[i]])


func _test_disabled_band_stays_editable() -> void:
	var inst := _make_instance()
	_enable(inst, 1, EqResponse.Type.BELL, 2000.0, 0.0)
	var view = _make_panel_view(inst)
	view._enabled_button.toggled.emit(false)
	_assert(_real(inst, 1, EqResponse.P_ENABLED) == 0.0, "the selected band is disabled")
	_assert(view._band_option.selected == 1, "the footer keeps showing it (no auto-deselect)")
	# A disabled band only dims: dragging its Freq slider still writes P_FREQ.
	view._freq_slider.value_changed.emit(5000.0)
	_assert(absf(_real(inst, 1, EqResponse.P_FREQ) - 5000.0) < 0.5, "a Freq drag on the disabled band still writes P_FREQ (param %d)" % (1 * EqResponse.BAND_STRIDE + EqResponse.P_FREQ))
	view._solo_button.toggled.emit(true)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 2, "a disabled band can still be soloed")
	view._solo_button.toggled.emit(false)
	view._type_option.item_selected.emit(EqResponse.Type.HIGH_SHELF)
	_assert(int(_real(inst, 1, EqResponse.P_TYPE)) == EqResponse.Type.HIGH_SHELF, "and its type stays adjustable")
	_assert(view._freq_slider.modulate.a < 1.0, "the disabled band's controls are dimmed, not inert")
	view.free()


func _test_companion_solo_and_type() -> void:
	var inst := _make_instance()
	_enable(inst, 3, EqResponse.Type.BELL, 520.0, 2.0)
	_enable(inst, 5, EqResponse.Type.BELL, 2500.0, 1.0)
	var companion = load("res://devices/builtin/eq/EqBandsCompanionView.tscn").instantiate()
	companion.bind_to_device(inst)
	root.add_child(companion)  # bound before entering the tree, as the panel does
	# Per-band solo writes n+1; pressing the active one again goes back to Off.
	companion._items[3].solo.toggled.emit(true)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 4, "band 4's solo button writes LISTEN_BAND 4")
	_assert(companion._items[3].solo.button_pressed, "and its own state shows it")
	companion._items[5].solo.toggled.emit(true)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 6, "soloing another band moves the listen band")
	companion._items[5].solo.toggled.emit(false)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 0, "pressing it again goes back to Off")
	# LISTEN_BAND is one device-level parameter: every strip's solo refreshes together.
	inst.set_parameter_real(EqResponse.LISTEN_BAND, 4.0)
	companion._on_device_parameter_changed(EqResponse.LISTEN_BAND, 4.0)
	_assert(companion._items[3].solo.button_pressed and not companion._items[5].solo.button_pressed and not companion._items[0].solo.button_pressed, "a LISTEN_BAND change updates every strip's solo state")
	# The type dropdown writes the band's P_TYPE.
	companion._items[5].type.item_selected.emit(EqResponse.Type.NOTCH)
	_assert(int(_real(inst, 5, EqResponse.P_TYPE)) == EqResponse.Type.NOTCH, "band 6's type dropdown writes its P_TYPE")
	_assert(companion._items[5].type.get_item_tooltip(companion._items[5].type.selected) == "Notch", "the item carries the type name as a tooltip")
	# And follows the device when the type changes from elsewhere.
	inst.set_parameter_real(5 * EqResponse.BAND_STRIDE + EqResponse.P_TYPE, float(EqResponse.Type.TILT))
	companion._on_device_parameter_changed(5 * EqResponse.BAND_STRIDE + EqResponse.P_TYPE, float(EqResponse.Type.TILT))
	_assert(companion._items[5].type.selected == EqResponse.Type.TILT, "the dropdown's selection follows the device")
	var icon: Texture2D = companion._items[5].type.get_item_icon(EqResponse.Type.TILT)
	_assert(icon != null and icon.get_size().x > 0, "and its item icon is the band-coloured curve")
	companion.free()


## Regression (#133): the header (enabled toggle, solo) was built but never added to the strip.
func _test_companion_strips_show_toggle_and_solo() -> void:
	var inst := _make_instance()
	var companion = load("res://devices/builtin/eq/EqBandsCompanionView.tscn").instantiate()
	root.add_child(companion)  # minimum sizes are only computed in the tree
	companion.bind_to_device(inst)
	for band in EqResponse.BAND_COUNT:
		var item: Control = companion._items[band]
		for key in ["toggle", "solo"]:
			var control: Control = item.get(key)
			_assert(item.is_ancestor_of(control), "band %d's %s is inside its strip" % [band + 1, key])
			_assert(control.visible and control.get_combined_minimum_size().x > 0 and control.get_combined_minimum_size().y > 0, "band %d's %s has a size" % [band + 1, key])
	_assert(companion.get_combined_minimum_size().x > 0, "the companion asks for width")
	# Solo goes through ParameterActions like the other controls.
	companion._items[2].solo.toggled.emit(true)
	_assert(int(inst.get_parameter_real(EqResponse.LISTEN_BAND)) == 3, "solo still writes LISTEN_BAND")
	companion.free()


## The analyser's display interpolation: keeps the source points, never leaves the range of two
## neighbours (no dip below the floor, no peak overshoot) and reuses its buffer.
func _test_spectrum_smoothing() -> void:
	var src := PackedVector2Array()
	for ys in [100.0, 20.0, 20.0, 90.0, 95.0, 10.0, 100.0, 100.0]:
		src.append(Vector2(10.0 * src.size(), ys))
	var out := PackedVector2Array()
	var tangents := PackedFloat32Array()
	var sub := 6
	EqCurveEditor.smooth_monotone(src, sub, out, tangents)
	_assert(out.size() == (src.size() - 1) * sub + 1, "sub points per segment")
	var passes := true
	var bounded := true
	var increasing := true
	for k in src.size():
		if out[k * sub] != src[k]:
			passes = false
	for i in range(1, out.size()):
		if out[i].x <= out[i - 1].x:
			increasing = false
	for k in src.size() - 1:
		for j in range(sub + 1):
			var y := out[k * sub + j].y
			if y < minf(src[k].y, src[k + 1].y) - 0.0001 or y > maxf(src[k].y, src[k + 1].y) + 0.0001:
				bounded = false
	_assert(passes, "the curve passes through every source point")
	_assert(increasing, "x stays increasing")
	_assert(bounded, "between two points the curve stays within their range (no overshoot)")
	var rising := true
	for j in range(1, sub + 1):
		if out[2 * sub + j].y < out[2 * sub + j - 1].y - 0.0001:
			rising = false
	_assert(rising, "a rising segment is monotone")
	EqCurveEditor.smooth_monotone(src, sub, out, tangents)
	_assert(out.size() == (src.size() - 1) * sub + 1, "a second call reuses the buffer")
	var two := PackedVector2Array([Vector2(0, 5), Vector2(4, 9)])
	EqCurveEditor.smooth_monotone(two, 1, out, tangents)
	_assert(out.size() == 2 and out[1] == two[1], "sub 1 copies the points")


# ============================================================================
# Modulation: the footer shows the selected band's, the curve shows every band's
# ============================================================================

## Deliver a `modulation` payload of offset records `[[param, offset], ...]` for `inst`, as if
## the engine had sent it (ModLive subscribed to the device's stream).
func _emit_offsets(inst: Object, records: Array) -> void:
	var live := ModLive.holder()
	if not live._paths.has(inst.osc_path()):
		live._subscribe(inst)
	var blob := PackedByteArray()
	blob.resize(2)
	blob.encode_u16(0, records.size())
	for record in records:
		var entry := PackedByteArray()
		entry.resize(11)
		entry.encode_u8(0, 0)  # kind 0: offset
		entry.encode_u8(1, 0)  # no child path
		entry.encode_u32(2, int(record[0]))
		entry.encode_u8(6, 1)
		entry.encode_float(7, float(record[1]))
		blob.append_array(entry)
	live._on_data(inst.osc_path(), ModLive.DATA_TYPE, blob)


func _test_footer_modulation_follows_the_band() -> void:
	ModLive.reset()
	var inst := _make_instance()
	_enable(inst, 1, EqResponse.Type.BELL, 2000.0, 0.0)
	_enable(inst, 3, EqResponse.Type.BELL, 520.0, 0.0)
	var view = _make_panel_view(inst)
	var gain_3 := 3 * EqResponse.BAND_STRIDE + EqResponse.P_GAIN
	_emit_offsets(inst, [[gain_3, -0.1]])
	_assert(view._band == 1 and view._gain_slider.mod_live_values.is_empty(), "band 2's gain slider shows no modulation from band 4")
	view.editor.select_band(3)
	var expected: float = inst.get_parameter_normalized(gain_3) - 0.1
	var markers: PackedFloat32Array = view._gain_slider.mod_live_values
	_assert(markers.size() == 1 and is_equal_approx(markers[0], expected), "selecting band 4 re-points the slider at its modulation (%s, expected %.3f)" % [str(markers), expected])
	view.editor.select_band(1)
	_assert(view._gain_slider.mod_live_values.is_empty(), "and back on band 2 the modulation leaves the slider")
	_emit_offsets(inst, [[gain_3, -0.2]])
	_assert(view._gain_slider.mod_live_values.is_empty(), "band 4's next payload doesn't reach the slider showing band 2")
	view.free()
	ModLive.reset()


func _test_editor_draws_live_modulation() -> void:
	var inst := _make_instance()
	_enable(inst, 2, EqResponse.Type.BELL, 1000.0, 6.0)
	var editor := _make_editor(inst)
	editor._update_curves()
	_assert(not editor.has_live() and editor._live_total.is_empty(), "without modulation there is no live curve")
	var values: Array = []
	for band in EqResponse.BAND_COUNT:
		values.append({"gain": -6.0} if band == 2 else {})
	editor.set_live(values)
	_assert(editor.has_live() and editor._live_dirty, "live values mark the live curves dirty")
	editor._update_live_curves()
	var at_1k := editor._curve_freqs.size() / 2
	for i in editor._curve_freqs.size():
		if absf(editor._curve_freqs[i] - 1000.0) < absf(editor._curve_freqs[at_1k] - 1000.0):
			at_1k = i
	_assert(editor._total[at_1k] > 5.0 and editor._live_total[at_1k] < -5.0, "the live total follows the modulated gain (set %.1f dB, live %.1f dB)" % [editor._total[at_1k], editor._live_total[at_1k]])
	_assert(editor._is_live(2) and not editor._is_live(1), "only the modulated band gets a live curve")
	var set_pos := editor.node_position(editor.bands[2])
	var live_pos := editor.node_position(editor.live_band(2))
	_assert(live_pos.y > set_pos.y + 10.0 and is_equal_approx(live_pos.x, set_pos.x), "the ghost node sits at the live gain")
	editor.clear_live()
	editor._update_live_curves()
	_assert(not editor.has_live() and editor._live_total.is_empty(), "clearing drops the live curves")
	editor.free()


func _test_view_feeds_live_modulation() -> void:
	ModLive.reset()
	var inst := _make_instance()
	_enable(inst, 4, EqResponse.Type.BELL, 1150.0, 3.0)
	var view = _make_panel_view(inst)
	view.show_view()
	var gain_5 := 4 * EqResponse.BAND_STRIDE + EqResponse.P_GAIN
	_emit_offsets(inst, [[gain_5, -0.125]])
	var expected: float = inst.get_parameter(gain_5).normalized_to_value(inst.get_parameter_normalized(gain_5) - 0.125)
	var live: Dictionary = view.editor.live_bands[4]
	_assert(live.has("gain") and absf(float(live["gain"]) - expected) < 0.01, "a payload hands band 5's live gain to the editor (%s, expected %.2f)" % [str(live.get("gain")), expected])
	_assert(view.editor.live_bands[0].is_empty() and is_nan(view.editor.live_output_gain_db), "unmodulated bands and Output stay set")
	_emit_offsets(inst, [])
	_assert(not view.editor.has_live(), "a heartbeat with no records clears the live display")
	_emit_offsets(inst, [[gain_5, -0.125]])
	view.hide_view()
	_assert(not view.editor.has_live(), "hiding the view drops the live display")
	_assert(not ModLive.holder().live_values_changed.is_connected(view._on_live_values_changed), "and its listener")
	view.free()
	ModLive.reset()
