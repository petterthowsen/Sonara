# Compressor panel: the `"dynamics"` blob decodes the way the engine writes it, dragging the
# transfer curve's corner writes Threshold and Ratio, the history's threshold line writes
# Threshold, and the whole view draws in the tree.
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
	_test_blob_rejects_junk()
	_test_static_curve_matches_the_engine()
	_test_corner_drag_sets_threshold_and_ratio()
	_test_corner_drag_up_raises_the_ratio()
	_test_history_threshold_drag()
	_test_history_keeps_the_window()
	_test_history_past_columns_are_static()
	await _test_draws_in_the_tree()


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


func _make_blob(records: Array) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(4 + records.size() * 12)
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


func _test_history_threshold_drag() -> void:
	var inst := _make_instance()
	var history := CompressorHistory.new()
	history.size = Vector2(400, 160)
	history.device = inst
	var start := Vector2(200.0, history.threshold_y())
	_assert(history.threshold_at(start), "the threshold line is grabbable")
	_assert(not history.threshold_at(Vector2(200.0, 4.0)), "the top of the strip is not the line")
	history._gui_input(_button(start, MOUSE_BUTTON_LEFT, true))
	var target_y := history.db_to_y(-6.0)
	history._gui_input(_motion(Vector2(200.0, target_y)))
	_assert(
		absf(inst.get_parameter_real(CompressorData.P_THRESHOLD) + 6.0) < 0.5,
		"dragging the line sets Threshold (got %s)" % inst.get_parameter_real(CompressorData.P_THRESHOLD)
	)
	history._gui_input(_button(Vector2(200.0, target_y), MOUSE_BUTTON_LEFT, false))
	_assert(not history.dragging, "releasing ends the drag")
	history.free()


## Columns that have scrolled into the past must not change when newer records arrive.
func _test_history_past_columns_are_static() -> void:
	var history := CompressorHistory.new()
	history.size = Vector2(200, 160)
	history.capacity = 400
	var push := func(count: int, base: int) -> void:
		var records := []
		for i in count:
			records.append([float((base + i * 7) % 50) - 60.0, 0.0, 0.0])
		history.push_records(CompressorData.decode(_make_blob(records)))
	push.call(64, 0)
	push.call(64, 64)
	var before := history._columns()
	push.call(64, 128)
	var after := history._columns()
	var shift := int(after["first"]) - int(before["first"])
	var same := true
	for j in int(before["count"]) - 1:
		if before["in"][j] != after["in"][j + shift]:
			same = false
	_assert(same, "columns in the past keep their values when new records arrive")
	history.free()


func _test_history_keeps_the_window() -> void:
	var history := CompressorHistory.new()
	history.capacity = 8
	for i in 100:
		var decoded := CompressorData.decode(_make_blob([[float(i), 0.0, 0.0]]))
		history.push_records(decoded)
	_assert(history.record_count() == history.retained_count(), "only the retained window is kept (%s)" % history.record_count())
	history.clear()
	_assert(history.record_count() == 0, "clearing empties it")
	history.free()


## The whole panel draws in the tree (curve, history, meters, knobs, style buttons, detector
## pane) without a script error; run_all.sh fails a script that prints one.
func _test_draws_in_the_tree() -> void:
	var inst := _make_instance()
	inst.set_parameter_real(CompressorData.P_STYLE, 2.0)
	inst.set_parameter_real(CompressorData.P_SC_LOW_CUT, 120.0)
	var view_script: GDScript = load("res://devices/builtin/CompressorDefaultView.gd")
	var view = view_script.new()
	view.size = Vector2(640, 320)
	view.bind_to_device(inst)
	root.add_child(view)
	view._on_view_shown()
	var records: Array = []
	for i in 120:
		records.append([-40.0 + float(i) * 0.2, -35.0 + float(i) * 0.1, float(i % 7)])
	view._apply_dynamics(CompressorData.decode(_make_blob(records)))
	view._on_detector_toggled(true)
	await process_frame
	await process_frame
	_assert(view.curve.live_input_db > -40.0, "the live dot follows the stream")
	_assert(view.history.record_count() == 120, "the history holds the records")
	_assert(view._detector_pane.visible, "the Detector pane opens")
	_assert(view._style_buttons[2].button_pressed, "the Style control shows the device's style")
	view._on_view_hidden()
	_assert(not view._subscribed, "hiding the view unsubscribes from the stream")
	view.queue_free()
	await process_frame
