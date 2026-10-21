# Saturator panel view: the `"curve"` record decodes the frozen layout (header + 128 curve
# points + 16 harmonics), the curve control draws from a hand-built record, the scene-built view
# wires Type/Quality/Auto Gain/knobs/faders, the tape group dims for non-Tape types, and the
# view subscribes to `"curve"` while shown and unsubscribes when hidden.
# Run: godot --headless --path Godot -s tests/test_saturator_view.gd -- --test
extends TestBase

const OSC_PATH := "Sonara"


func suite_name() -> String:
	return "Saturator view"


var _device_script: GDScript
var _instance_script: GDScript


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_test_decode()
	_test_decode_rejects_junk()
	_test_curve_draws()
	_test_curve_clears()
	await _test_view_in_the_tree()
	await _test_bind_after_tree()


## The engine's 17 parameters (ids, ranges and defaults from design.md's table).
func _make_instance() -> Object:
	var device: Object = _device_script.new(
		"sonara.builtin.saturator", "Saturator", _device_script.DeviceCategory.Effect
	)
	var float_param := func(id: int, name: String, unit: String, min_v: float, max_v: float, default_v: float, log_v := false, skew := 1.0) -> DeviceParameter:
		var param := DeviceParameter.new(id, name, unit)
		param.min_value = min_v
		param.max_value = max_v
		param.default_value = default_v
		param.is_logarithmic = log_v
		param.skew = skew
		device.add_parameter(param)
		return param
	float_param.call(SaturatorData.P_TYPE, "Type", "", 0.0, 3.0, 0.0)
	float_param.call(SaturatorData.P_DRIVE, "Drive", "dB", 0.0, 36.0, 6.0)
	float_param.call(SaturatorData.P_BIAS, "Bias", "", -1.0, 1.0, 0.0)
	float_param.call(SaturatorData.P_LEVEL_DEPEND, "Dynamics", "%", 0.0, 100.0, 0.0)
	float_param.call(SaturatorData.P_INPUT, "Input", "dB", -24.0, 24.0, 0.0)
	float_param.call(SaturatorData.P_QUALITY, "Quality", "", 0.0, 2.0, 1.0)
	float_param.call(SaturatorData.P_PRE_HPF, "Low Cut", "Hz", 0.0, 1000.0, 0.0, false, 2.0)
	float_param.call(SaturatorData.P_POST_LPF, "High Cut", "Hz", 1000.0, 20000.0, 20000.0, true)
	float_param.call(SaturatorData.P_TILT, "Tone", "dB", -6.0, 6.0, 0.0)
	float_param.call(SaturatorData.P_HF_LOSS, "HF Loss", "%", 0.0, 100.0, 50.0)
	float_param.call(SaturatorData.P_HEAD_BUMP, "Head Bump", "dB", 0.0, 6.0, 2.0)
	float_param.call(SaturatorData.P_SQUASH, "Squash", "%", 0.0, 100.0, 30.0)
	float_param.call(SaturatorData.P_WOW, "Wow", "%", 0.0, 100.0, 0.0)
	float_param.call(SaturatorData.P_NOISE, "Noise", "dB", -90.0, -40.0, -90.0)
	float_param.call(SaturatorData.P_MIX, "Mix", "%", 0.0, 100.0, 100.0)
	float_param.call(SaturatorData.P_OUTPUT, "Output", "dB", -24.0, 24.0, 0.0)
	var bool_param := DeviceParameter.new(SaturatorData.P_AUTO_GAIN, "Auto Gain")
	bool_param.param_type = "bool"
	bool_param.default_value = 1.0
	device.add_parameter(bool_param)
	return _instance_script.new(device, 2, 0)


func _soft_curve() -> PackedFloat32Array:
	var curve := PackedFloat32Array()
	curve.resize(SaturatorData.CURVE_POINTS)
	for i in SaturatorData.CURVE_POINTS:
		curve[i] = SaturatorData.soft_curve_at(SaturatorData.curve_input(i), 6.0)
	return curve


func _make_blob() -> PackedByteArray:
	var harmonics := PackedFloat32Array()
	for i in SaturatorData.HARMONIC_COUNT:
		harmonics.append(-6.0 - float(i) * 4.0)
	return SaturatorData.build_record(9.5, -12.0, _soft_curve(), harmonics)


func _test_decode() -> void:
	var decoded := SaturatorData.decode(_make_blob())
	_assert(bool(decoded["valid"]), "a full record decodes")
	_assert(is_equal_approx(decoded["effective_drive_db"], 9.5), "effective drive from the header")
	_assert(is_equal_approx(decoded["env_db"], -12.0), "envelope level from the header")
	_assert(decoded["curve"].size() == SaturatorData.CURVE_POINTS, "128 curve points")
	_assert(decoded["harmonics"].size() == SaturatorData.HARMONIC_COUNT, "16 harmonics")
	_assert(is_equal_approx(decoded["curve"][0], SaturatorData.soft_curve_at(-1.0, 6.0)), "curve starts at input -1")
	_assert(is_equal_approx(decoded["harmonics"][3], -18.0), "harmonics decode in order")
	_assert(SaturatorData.BYTES == 584, "the record is 146 f32 = 584 bytes")


func _test_decode_rejects_junk() -> void:
	_assert(not bool(SaturatorData.decode(PackedByteArray())["valid"]), "an empty blob decodes to nothing")
	var blob := _make_blob()
	_assert(not bool(SaturatorData.decode(blob.slice(0, blob.size() - 4))["valid"]), "a short blob is refused")
	_assert(bool(SaturatorData.decode(blob)["valid"]), "and a full one passes")


func _test_curve_draws() -> void:
	var curve := SaturatorCurve.new()
	curve.size = Vector2(320, 160)
	_assert(curve.curve_polyline().is_empty(), "an empty curve control draws nothing")
	curve.set_record(SaturatorData.decode(_make_blob()))
	_assert(curve.has_record(), "a record arrives")
	var points := curve.curve_polyline()
	_assert(points.size() == SaturatorData.CURVE_POINTS, "one pixel point per curve point")
	var finite := true
	for p in points:
		if is_nan(p.x) or is_nan(p.y):
			finite = false
	_assert(finite, "every point has finite pixel coordinates")
	_assert(absf(points[0].x) < 2.0 and absf(points[points.size() - 1].x - curve.size.x) < 2.0, "the curve spans the plot width")
	# The dot sits at env_db -12 dBFS -> input 0.25, on the curve.
	var dot := curve.dot_position()
	_assert(not is_nan(dot.x) and not is_nan(dot.y), "the operating-point dot has a position")
	var amp := pow(10.0, -12.0 / 20.0)
	_assert(absf(curve.dot_input() - amp) < 0.01, "the dot's input is env_db's amplitude")
	_assert(absf(dot.y - curve.output_to_y(curve.output_at(curve.dot_input()))) < 0.01, "the dot sits on the curve")
	var bars := curve.bar_rects()
	_assert(bars.size() == SaturatorData.HARMONIC_COUNT, "one bar per harmonic")
	var bars_finite := true
	for r in bars:
		if r.position.y + r.size.y > curve.size.y + 0.01 or is_nan(r.size.y):
			bars_finite = false
	_assert(bars_finite, "every bar sits inside the strip")
	_assert(curve.odd_color != curve.even_color, "odd and even harmonics are coloured differently")
	curve.free()


func _test_curve_clears() -> void:
	var curve := SaturatorCurve.new()
	curve.size = Vector2(320, 160)
	curve.set_record(SaturatorData.decode(_make_blob()))
	_assert(curve.has_record(), "a record arrives")
	curve.set_record({})
	_assert(not curve.has_record(), "an invalid record clears the drawing")
	_assert(curve.curve_polyline().is_empty() and curve.bar_rects().is_empty(), "nothing is drawn after clearing")
	curve.free()


func _fake_osc() -> Node:
	var script := GDScript.new()
	script.source_code = """
extends Node
signal device_data_received(osc_path: String, data_type: String, blob: PackedByteArray)

var subscribed := {}

func subscribe_device_data(osc_path: String, data_type: String) -> void:
	subscribed[osc_path + "|" + data_type] = true

func unsubscribe_device_data(osc_path: String, data_type: String) -> void:
	subscribed.erase(osc_path + "|" + data_type)
"""
	script.reload()
	var osc := Node.new()
	osc.name = "AudioEngineOSC"
	osc.set_script(script)
	return osc


func _test_view_in_the_tree() -> void:
	var osc := _fake_osc()
	var inst := _make_instance()
	var view = load("res://devices/builtin/saturator/SaturatorDefaultView.tscn").instantiate()
	view.load_osc = func(_name: String): return osc
	view.size = Vector2(760, 250)
	view.bind_to_device(inst)
	root.add_child(view)
	await process_frame
	view._on_view_shown()
	await process_frame

	# Subscription lifecycle.
	_assert(view._subscribed, "showing the view subscribes to the curve stream")
	_assert(osc.subscribed.has(inst.osc_path() + "|curve"), "the fake osc saw the curve subscription")
	_assert(view.get_header_tabs().is_empty(), "a single page: no header tabs")

	# A hand-built record reaches the curve control.
	view._on_curve_received(inst.osc_path(), "curve", _make_blob())
	_assert(view.curve.has_record() and view.curve.curve_point_count() == SaturatorData.CURVE_POINTS, "the curve shows the record")
	# Other data types are ignored.
	view._on_curve_received(inst.osc_path(), "dynamics", _make_blob())
	_assert(view.curve.curve_point_count() == SaturatorData.CURVE_POINTS, "a foreign data type is ignored")

	# Controls reflect the device and write back.
	_assert(view.type_control.selected == 0, "the Type control shows Soft")
	_assert(view.type_control.items == PackedStringArray(SaturatorData.TYPE_NAMES), "Type names Soft/Tube/Tape/Hard")
	_assert(view.quality_control.selected == 1, "the Quality control shows 2x")
	_assert(is_equal_approx(view._knobs["Drive"].knob.value, 6.0), "the Drive knob shows the parameter")
	_assert(view.mix_fader.value > 99.0, "the Mix fader shows 100 %")
	_assert(view.auto_gain.button_pressed, "Auto Gain is on")

	view._knobs["Drive"].knob.value = 12.0
	_assert(is_equal_approx(inst.get_parameter_real(SaturatorData.P_DRIVE), 12.0), "a Drive knob drag sets Drive")
	view.mix_fader.value = 50.0
	_assert(is_equal_approx(inst.get_parameter_real(SaturatorData.P_MIX), 50.0), "a Mix fader drag sets Mix")
	view.output_fader.value = -6.0
	_assert(is_equal_approx(inst.get_parameter_real(SaturatorData.P_OUTPUT), -6.0), "an Output fader drag sets Output")
	view.type_control.selected = 2
	_assert(is_equal_approx(inst.get_parameter_real(SaturatorData.P_TYPE), 2.0), "the Type control sets Type")
	view.type_control.set_selected_no_signal(0)
	inst.set_parameter_real(SaturatorData.P_TYPE, 0.0)
	view.quality_control.selected = 2
	_assert(is_equal_approx(inst.get_parameter_real(SaturatorData.P_QUALITY), 2.0), "the Quality control sets Quality")
	inst.set_parameter_real(SaturatorData.P_QUALITY, 1.0)
	view.auto_gain.button_pressed = false
	_assert(inst.get_parameter_real(SaturatorData.P_AUTO_GAIN) < 0.5, "unchecking Auto Gain sets the parameter")
	view.auto_gain.button_pressed = true

	# The tape group dims unless Type is Tape.
	_assert(view.tape_row.modulate.a < 1.0, "Soft dims the tape row")
	inst.set_parameter_real(SaturatorData.P_TYPE, 2.0)
	_assert(is_equal_approx(view.tape_row.modulate.a, 1.0), "Tape un-dims the tape row")
	_assert(view.type_control.selected == 2, "the Type control follows the parameter")
	inst.set_parameter_real(SaturatorData.P_TYPE, 0.0)
	_assert(view.tape_row.modulate.a < 1.0, "back to Soft the tape row dims again")

	# The layout fits the panel's content height.
	var content: Vector2 = view._main_page.get_combined_minimum_size()
	_assert(content.y <= 250.0, "the panel fits DevicePanel's height below the header (%s)" % content)

	view._on_view_hidden()
	_assert(not view._subscribed, "hiding the view unsubscribes")
	_assert(osc.subscribed.is_empty(), "the fake osc saw the unsubscribe")
	_assert(not view.curve.has_record(), "hiding clears the curve")
	view.queue_free()
	await process_frame
	osc.free()


## The editor-preview case (no device) and a device bound after the view entered the tree.
func _test_bind_after_tree() -> void:
	var view = load("res://devices/builtin/saturator/SaturatorDefaultView.tscn").instantiate()
	view.load_osc = func(_name: String): return null
	root.add_child(view)
	await process_frame
	_assert(view._knobs.size() == 12, "the scene tags 12 knobs with their parameter (%d)" % view._knobs.size())
	_assert(view.curve != null and not view.curve.has_record(), "unbound: the curve is empty")
	var inst := _make_instance()
	inst.set_parameter_real(SaturatorData.P_DRIVE, 18.0)
	inst.set_parameter_real(SaturatorData.P_TYPE, 2.0)
	view.bind_to_device(inst)
	_assert(is_equal_approx(view._knobs["Drive"].knob.value, 18.0), "binding after ready shows Drive")
	_assert(view.type_control.selected == 2, "binding after ready shows Type")
	_assert(is_equal_approx(view.tape_row.modulate.a, 1.0), "binding after ready un-dims the tape row for Tape")
	_assert(view.curve.has_record(), "binding after ready draws the fallback curve")
	view._knobs["Noise"].knob.value = -60.0
	_assert(is_equal_approx(inst.get_parameter_real(SaturatorData.P_NOISE), -60.0), "a tape knob writes its parameter")
	view.queue_free()
	await process_frame
