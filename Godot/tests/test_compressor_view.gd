# Compressor panel: the `"dynamics"` blob decodes the way the engine writes it, dragging the
# transfer curve's corner writes Threshold and Ratio, the scope's threshold line writes
# Threshold, the scope paints its three parts, and the scene-based view wires its faders, tabs and
# meters.
# Run: godot --headless --path Godot -s tests/test_compressor_view.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "Compressor view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_test_blob_decodes()
	_test_blob_decodes_the_summary()
	_test_blob_rejects_junk()
	_test_static_curve_matches_the_engine()
	_test_corner_drag_sets_threshold_and_ratio()
	_test_corner_drag_up_raises_the_ratio()
	_test_scope_threshold_drag()
	_test_scope_mirrors()
	_test_scope_segments()
	_test_scope_keeps_the_window()
	_test_scope_past_columns_are_static()
	_test_auto_makeup()
	await _test_view_in_the_tree()


## A device with the engine's compressor parameters (ids, ranges and defaults as in
## compressor.rs).
func _make_instance() -> Object:
	var device: Object = _device_script.new(
		"sonara.builtin.compressor", "Compressor", _device_script.DeviceCategory.Effect
	)
	var float_param := func(id: int, name: String, unit: String, min_v: float, max_v: float, default_v: float, log_v := false) -> DeviceParameter:
		var param := DeviceParameter.new(id, name, unit)
		param.min_value = min_v
		param.max_value = max_v
		param.default_value = default_v
		param.is_logarithmic = log_v
		device.add_parameter(param)
		return param
	float_param.call(CompressorData.P_THRESHOLD, "Threshold", "dB", -60.0, 0.0, -18.0)
	float_param.call(CompressorData.P_RATIO, "Ratio", "", 1.0, 30.0, 4.0)
	float_param.call(CompressorData.P_KNEE, "Knee", "dB", 0.0, 24.0, 6.0)
	float_param.call(CompressorData.P_RANGE, "Range", "dB", 0.0, 60.0, 60.0)
	float_param.call(CompressorData.P_ATTACK, "Attack", "ms", 0.05, 200.0, 10.0, true)
	float_param.call(CompressorData.P_RELEASE, "Release", "ms", 5.0, 2000.0, 150.0, true)
	float_param.call(CompressorData.P_STEREO_LINK, "Stereo Link", "%", 0.0, 100.0, 100.0)
	float_param.call(CompressorData.P_SC_LOW_CUT, "SC Low Cut", "Hz", 0.0, 500.0, 0.0)
	float_param.call(CompressorData.P_MAKEUP, "Makeup", "dB", -12.0, 24.0, 0.0)
	float_param.call(CompressorData.P_MIX, "Mix", "%", 0.0, 100.0, 100.0)
	var bool_param := func(id: int, name: String, default_v: float) -> void:
		var param := DeviceParameter.new(id, name)
		param.param_type = "bool"
		param.default_value = default_v
		device.add_parameter(param)
	bool_param.call(CompressorData.P_AUTO_RELEASE, "Auto Release", 0.0)
	bool_param.call(CompressorData.P_AUTO_GAIN, "Auto Gain", 1.0)
	bool_param.call(CompressorData.P_SC_LISTEN, "SC Listen", 0.0)
	var enum_param := func(id: int, name: String, names: Array[String], default_v: float) -> void:
		var param := DeviceParameter.new(id, name)
		param.param_type = "enum"
		param.enum_values.assign(names)
		param.default_value = default_v
		device.add_parameter(param)
	enum_param.call(CompressorData.P_STYLE, "Style", CompressorData.STYLE_NAMES, 0.0)
	enum_param.call(CompressorData.P_DETECTION, "Detection", CompressorData.DETECTION_NAMES, 0.0)
	enum_param.call(CompressorData.P_CHANNELS, "Channels", CompressorData.CHANNELS_NAMES, 0.0)
	return _instance_script.new(device, 2, 0)


func _make_blob(records: Array, summary := []) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(4 + records.size() * 12 + summary.size() * 4)
	for k in summary.size():
		blob.encode_float(4 + records.size() * 12 + k * 4, summary[k])
	blob.encode_u32(0, records.size())
	for i in records.size():
		var record: Array = records[i]
		blob.encode_float(4 + i * 12, record[0])
		blob.encode_float(4 + i * 12 + 4, record[1])
		blob.encode_float(4 + i * 12 + 8, record[2])
	return blob


func _test_blob_decodes() -> void:
	var records := [[-12.0, -18.0, 6.0], [-6.0, -12.5, 6.5], [-30.0, -30.0, 0.0]]
	var decoded := CompressorData.decode(_make_blob(records))
	_assert(decoded["count"] == 3, "three records")
	_assert(decoded["in_peak_db"].size() == 3 and decoded["gr_db"].size() == 3, "one entry per record")
	_assert(is_equal_approx(decoded["in_peak_db"][0], -12.0), "input peak of the first record")
	_assert(is_equal_approx(decoded["out_peak_db"][2], -30.0), "output peak of the last record")
	_assert(is_equal_approx(decoded["gr_db"][1], 6.5), "gain reduction of the middle record")


func _test_blob_decodes_the_summary() -> void:
	var summary := [-6.0, -160.0, -7.0, -160.0, -9.0, -160.0, -10.0, -160.0, -12.5, 4.0]
	var decoded := CompressorData.decode(_make_blob([[-12.0, -18.0, 6.0]], summary))
	_assert(decoded["count"] == 1 and decoded["summary"].size() == 10, "records and summary both decode")
	_assert(is_equal_approx(decoded["summary"]["in_peak_l"], -6.0), "in peak L")
	_assert(is_equal_approx(decoded["summary"]["out_rms_l"], -10.0), "out rms L")
	_assert(is_equal_approx(decoded["summary"]["detector_db"], -12.5), "detector level")
	_assert(is_equal_approx(decoded["summary"]["gr_max_db"], 4.0), "largest reduction")
	var old := CompressorData.decode(_make_blob([[-12.0, -18.0, 6.0]]))
	_assert(old["count"] == 1 and old["summary"].is_empty(), "a blob without a summary still decodes")
	var partial := _make_blob([[-12.0, -18.0, 6.0]], summary).slice(0, 4 + 12 + 20)
	_assert(CompressorData.decode(partial)["summary"].is_empty(), "a partial summary is ignored")


func _test_blob_rejects_junk() -> void:
	_assert(CompressorData.decode(PackedByteArray()).get("count") == 0, "an empty blob decodes to nothing")
	var truncated := _make_blob([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]])
	truncated = truncated.slice(0, truncated.size() - 5)
	_assert(CompressorData.decode(truncated).get("count") == 0, "a short blob is refused")
	var lying := PackedByteArray()
	lying.resize(8)
	lying.encode_u32(0, 99)
	_assert(CompressorData.decode(lying).get("count") == 0, "a count longer than the blob is refused")


## The drawn curve is the engine's gain computer: -10 dBFS in with threshold -20 and ratio 4:1
## comes out at -17.5 dBFS.
func _test_static_curve_matches_the_engine() -> void:
	var out_db := CompressorData.static_curve_db(-10.0, -20.0, 4.0, 0.0, 60.0)
	_assert(absf(out_db + 17.5) < 1e-3, "static curve at -10 dBFS: %s" % out_db)
	_assert(is_equal_approx(CompressorData.gain_reduction_db(-30.0, -20.0, 4.0, 0.0, 60.0), 0.0), "nothing below the threshold")
	_assert(is_equal_approx(CompressorData.gain_reduction_db(0.0, -20.0, 4.0, 0.0, 60.0), 15.0), "15 dB at full scale")
	_assert(CompressorData.format_ratio(30.0) == "∞:1", "the top of the Ratio knob reads infinity")
	_assert(CompressorData.format_ratio(4.0) == "4.0:1", "and the rest reads N:1")


func _button(pos: Vector2, button: int, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = button
	ev.pressed = pressed
	return ev


func _motion(pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	return ev


func _make_curve(instance: Object) -> CompressorCurve:
	var curve := CompressorCurve.new()
	curve.size = Vector2(640, 200)
	curve.device = instance
	return curve


func _test_corner_drag_sets_threshold_and_ratio() -> void:
	var inst := _make_instance()
	var curve := _make_curve(inst)
	var start: Vector2 = curve.corner_position()
	_assert(curve.corner_at(start), "the corner node is where the threshold is")
	curve._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	# Sideways: the threshold follows the pointer.
	var target := Vector2(start.x + 100.0, start.y)
	curve._gui_input(_motion(target))
	var want_threshold: float = curve.x_to_input_db(target.x)
	_assert(
		absf(inst.get_parameter_real(CompressorData.P_THRESHOLD) - want_threshold) < 0.5,
		"the drag sets Threshold (got %s, want %s)" % [inst.get_parameter_real(CompressorData.P_THRESHOLD), want_threshold]
	)
	# Downwards: the level at 0 dBFS rises, so the ratio falls.
	var bend := Vector2(curve.input_db_to_x(-18.0), curve.output_db_to_y(-6.0))
	curve._gui_input(_motion(bend))
	_assert(
		absf(inst.get_parameter_real(CompressorData.P_RATIO) - 1.5) < 0.05,
		"the vertical drag bends the curve to 1.5:1 (got %s)" % inst.get_parameter_real(CompressorData.P_RATIO)
	)
	curve._gui_input(_button(bend, MOUSE_BUTTON_LEFT, false))
	_assert(not curve.dragging, "releasing ends the drag")
	curve.free()


func _test_corner_drag_up_raises_the_ratio() -> void:
	var inst := _make_instance()
	inst.set_parameter_real(CompressorData.P_THRESHOLD, -24.0)
	inst.set_parameter_real(CompressorData.P_RATIO, 2.0)
	var curve := _make_curve(inst)
	curve.refresh()
	var start: Vector2 = curve.corner_position()
	curve._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	# Upwards towards the corner's own level: the compressed line gets steeper.
	var bend := Vector2(start.x, curve.output_db_to_y(-20.0))
	curve._gui_input(_motion(bend))
	_assert(
		inst.get_parameter_real(CompressorData.P_RATIO) > 4.0,
		"dragging up raises the ratio (got %s)" % inst.get_parameter_real(CompressorData.P_RATIO)
	)
	curve._gui_input(_button(bend, MOUSE_BUTTON_LEFT, false))
	curve.free()


func _make_scope(instance: Object, direction: int) -> CompressorScope:
	var scope := CompressorScope.new()
	scope.direction = direction
	scope.size = Vector2(400, 80)
	scope.device = instance
	return scope


func _test_scope_threshold_drag() -> void:
	var inst := _make_instance()
	var scope := _make_scope(inst, CompressorScope.Direction.UP)
	var start := Vector2(200.0, scope.threshold_y())
	_assert(scope.threshold_at(start), "the threshold line is grabbable")
	_assert(not scope.threshold_at(Vector2(200.0, scope.threshold_y() - 30.0)), "away from the line is not")
	scope._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	var target_y := scope.db_to_y(-6.0)
	scope._gui_input(_motion(Vector2(200.0, target_y)))
	_assert(
		absf(inst.get_parameter_real(CompressorData.P_THRESHOLD) + 6.0) < 0.5,
		"dragging the line sets Threshold (got %s)" % inst.get_parameter_real(CompressorData.P_THRESHOLD)
	)
	scope._gui_input(_button(Vector2(200.0, target_y), MOUSE_BUTTON_LEFT, false))
	_assert(not scope.dragging, "releasing ends the drag")
	scope.free()


## DOWN grows from the top edge: the same dB sits at the mirrored y, and dragging still works.
func _test_scope_mirrors() -> void:
	var inst := _make_instance()
	var up := _make_scope(inst, CompressorScope.Direction.UP)
	var down := _make_scope(inst, CompressorScope.Direction.DOWN)
	_assert(is_equal_approx(up.db_to_y(-60.0), 80.0), "UP: silence is at the bottom edge")
	_assert(is_equal_approx(down.db_to_y(-60.0), 0.0), "DOWN: silence is at the top edge")
	_assert(is_equal_approx(up.db_to_y(-20.0) + down.db_to_y(-20.0), 80.0), "the two halves mirror each other")
	_assert(absf(down.y_to_db(down.db_to_y(-24.0)) + 24.0) < 0.01, "DOWN: y and dB round-trip")
	down._gui_input(_button(Vector2(100.0, down.threshold_y()), MOUSE_BUTTON_LEFT, true))
	down._gui_input(_motion(Vector2(100.0, down.db_to_y(-30.0))))
	_assert(absf(inst.get_parameter_real(CompressorData.P_THRESHOLD) + 30.0) < 0.5, "DOWN: dragging sets Threshold")
	_assert(absf(up.threshold_db + 30.0) < 0.5, "the other half follows the parameter")
	down._gui_input(_button(Vector2.ZERO, MOUSE_BUTTON_LEFT, false))
	up.free()
	down.free()


## A column's three parts: -20 dBFS threshold on a 60 dB, 80 px scope is 53.3 px from the baseline.
## Input at -8 dBFS is 69.3 px: 53.3 primary and 16 gray. 6 dB of reduction hangs 8 px below the line.
func _test_scope_segments() -> void:
	var inst := _make_instance()
	inst.set_parameter_real(CompressorData.P_THRESHOLD, -20.0)
	var scope := _make_scope(inst, CompressorScope.Direction.UP)
	var px := 80.0 / 60.0
	var over: Dictionary = scope.column_segments(-8.0, 6.0)
	_assert(absf(over["primary"] - 40.0 * px) < 0.01, "primary runs to the threshold (%s)" % over["primary"])
	_assert(absf(over["beyond"] - 12.0 * px) < 0.01, "gray is the input above the threshold (%s)" % over["beyond"])
	_assert(absf(over["reduction"] - 6.0 * px) < 0.01, "red is the reduction in dB (%s)" % over["reduction"])
	var under: Dictionary = scope.column_segments(-35.0, 0.0)
	_assert(absf(under["primary"] - 25.0 * px) < 0.01 and under["beyond"] == 0.0 and under["reduction"] == 0.0,
		"below the threshold only the primary part")
	var deep: Dictionary = scope.column_segments(-8.0, 50.0)
	_assert(absf(deep["reduction"] - 40.0 * px) < 0.01, "red never hangs past the baseline")
	scope.free()


## Columns that have scrolled into the past must not change when newer records arrive.
func _test_scope_past_columns_are_static() -> void:
	var scope := CompressorScope.new()
	scope.size = Vector2(200, 160)
	scope.capacity = 400
	var push := func(count: int, base: int) -> void:
		var records := []
		for i in count:
			records.append([float((base + i * 7) % 50) - 60.0, 0.0, 0.0])
		scope.push_records(CompressorData.decode(_make_blob(records)))
	push.call(64, 0)
	push.call(64, 64)
	var before := scope._columns()
	push.call(64, 128)
	var after := scope._columns()
	var shift := int(after["first"]) - int(before["first"])
	var same := true
	for j in int(before["count"]) - 1:
		if before["in"][j] != after["in"][j + shift]:
			same = false
	_assert(same, "columns in the past keep their values when new records arrive")
	scope.free()


func _test_scope_keeps_the_window() -> void:
	var scope := CompressorScope.new()
	scope.capacity = 8
	for i in 100:
		scope.push_records(CompressorData.decode(_make_blob([[float(i), 0.0, 0.0]])))
	_assert(scope.record_count() == scope.retained_count(), "only the retained window is kept (%s)" % scope.record_count())
	scope.clear()
	_assert(scope.record_count() == 0, "clearing empties it")
	scope.free()


func _test_auto_makeup() -> void:
	_assert(is_equal_approx(CompressorData.auto_makeup_db(-20.0, 4.0, 0.0, 60.0), 5.25), "auto makeup is half the reduction at -6 dBFS")
	_assert(is_equal_approx(CompressorData.auto_makeup_db(-20.0, 1.0, 0.0, 60.0), 0.0), "1:1 adds nothing")


## The scene-based view: faders, sliders, header tabs, view state, meters and the fit to the panel.
func _test_view_in_the_tree() -> void:
	var inst := _make_instance()
	inst.set_parameter_real(CompressorData.P_STYLE, 2.0)
	inst.set_parameter_real(CompressorData.P_SC_LOW_CUT, 120.0)
	var saved := {}
	var view = load("res://devices/builtin/CompressorDefaultView.tscn").instantiate()
	view.load_config = func(_key: String) -> Variant: return saved
	view.save_config = func(_key: String, value: Variant) -> void: saved.merge(value, true)
	view.size = Vector2(780, 250)
	view.bind_to_device(inst)
	root.add_child(view)
	view._on_view_shown()
	await process_frame

	_assert(view.style_control.items == PackedStringArray(CompressorData.STYLE_NAMES), "the scene's Style items match the data")
	_assert(view.detection_control.items == PackedStringArray(CompressorData.DETECTION_NAMES), "and Detection")
	_assert(view.channels_control.items == PackedStringArray(CompressorData.CHANNELS_NAMES), "and Channels")
	_assert(view.style_control.selected == 2, "the Style control shows the device's style")
	_assert(is_equal_approx(view.threshold_fader.value, -18.0), "the Threshold fader shows the parameter")
	view.threshold_fader.value = -30.0
	_assert(is_equal_approx(inst.get_parameter_real(CompressorData.P_THRESHOLD), -30.0), "a Threshold fader drag sets Threshold")
	view.ratio_fader.value = 8.0
	_assert(absf(inst.get_parameter_real(CompressorData.P_RATIO) - 8.0) < 0.01, "a Ratio fader drag sets Ratio")
	view.auto_gain.button_pressed = false
	view.output_fader.value = 6.0
	_assert(is_equal_approx(inst.get_parameter_real(CompressorData.P_MAKEUP), 6.0), "an Output fader drag sets Makeup")
	_assert(is_equal_approx(view.threshold_fader.value, -30.0), "the fader follows the parameter")
	_assert(view.ratio_fader.value_to_position(1.0) > 0.99 and view.ratio_fader.value_to_position(30.0) < 0.01, "the Ratio fader is reversed: 1:1 at the top")
	view.auto_gain.button_pressed = true
	_assert(not view.output_fader.editable, "Auto Gain locks the Output fader")
	_assert(absf(view.output_fader.value - CompressorData.auto_makeup_db(-30.0, 8.0, 6.0, 60.0)) < 0.01, "and it shows the auto gain")
	view.auto_gain.button_pressed = false
	_assert(view.output_fader.editable and is_equal_approx(view.output_fader.value, 6.0), "turning it off returns the manual Makeup")
	var attack_param: DeviceParameter = inst.get_parameter(CompressorData.P_ATTACK)
	view.get_node("%AttackSlider").value = attack_param.value_to_normalized(1.0)
	_assert(absf(inst.get_parameter_real(CompressorData.P_ATTACK) - 1.0) < 0.01, "the Attack slider sets Attack through its taper")

	_assert(view.get_header_tabs() == PackedStringArray(["Main", "Detector"]), "Main and Detector header tabs")
	_assert(view.main_page.visible and not view.detector_page.visible, "the Main page shows first")
	view.select_header_tab(1)
	_assert(not view.main_page.visible and view.detector_page.visible and view.get_header_tab() == 1, "the Detector tab switches pages")
	view.select_header_tab(0)

	view.display_control.selected = 1  # Display.SCOPE (the view class can't be named here: it needs the autoloads)
	_assert(view.scope_stack.visible and not view.curve.visible, "Scope replaces the curve")
	_assert(int(saved.get("display", -1)) == 1, "the choice is saved")
	view.metering_control.selected = 1  # Metering.RMS
	_assert(view.in_meter.display == LevelMeter.Display.RMS and view.out_meter.display == LevelMeter.Display.RMS, "Peak | RMS switches the level meters")

	var records: Array = []
	for i in 120:
		records.append([-40.0 + float(i) * 0.2, -35.0 + float(i) * 0.1, float(i % 7)])
	var summary := [-6.0, -9.0, -7.0, -10.0, -12.0, -15.0, -13.0, -16.0, -20.0, 5.0]
	view._apply_dynamics(CompressorData.decode(_make_blob(records, summary)))
	await process_frame
	await process_frame
	_assert(view.scope_top.record_count() == 120 and view.scope_bottom.record_count() == 120, "both scope halves hold the records")
	_assert(view.in_meter.level_db(1) < -9.0 and view.gr_meter.level_db(0) > 0.0, "the meters receive the summary")
	_assert(absf(view.threshold_fader.overlay_level - (40.0 / 60.0)) < 0.01, "the Threshold fader's bar follows the detector level")
	_assert(view.curve.live_input_db > -60.0, "the live dot follows the detector level")

	var content: Vector2 = view.main_page.get_combined_minimum_size()
	_assert(content.x <= 780.0 and content.y <= 250.0, "the Main page fits the panel (%s)" % content)
	view._on_view_hidden()
	_assert(not view._subscribed, "hiding the view unsubscribes from the stream")
	_assert(view.scope_top.record_count() == 0, "hiding clears the scope")
	view.queue_free()
	await process_frame
