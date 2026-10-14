# Sidechain modulator view (spec 044): the kind 4 history decode, the scrolling output line, the
# spectrum blob and plot, and the parameter defaults of an old project.
# Run: godot --headless --path Godot -s tests/test_sidechain_view.gd -- --test
extends TestBase

const SYNTH_ID := "test.synth44"

var _inst_script: GDScript
var _display_script: GDScript
var _live_script: GDScript


func suite_name() -> String:
	return "Sidechain view"


func run_tests() -> void:
	# Loaded at runtime: parse-time references would compile DeviceInstance before the autoloads.
	_inst_script = load("res://data/DeviceInstance.gd")
	_display_script = load("res://devices/modulators/ModulatorDisplay.gd")
	_live_script = load("res://devices/modulators/ModLive.gd")
	_setup()
	_test_old_project_defaults()
	_test_ext_decode()
	await _test_history_store()
	await _test_line_peak_and_scale()
	await _test_mini_spectrum()
	await _test_options_stream()


# --- fixtures ------------------------------------------------------------------------------

func _setup() -> void:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	var float_param := func(id: int, name: String, unit: String, minv: float, maxv: float, def: float, is_log: bool) -> Array:
		return [id, name, unit, "float", 1, minv, maxv, def, 1 if is_log else 0, 1.0, 0, "", 1, 0]
	var args: Array = ["sidechain", "Sidechain", 0, 7]
	args.append_array(float_param.call(0, "Low Cut", "Hz", 20.0, 20000.0, 20.0, true))
	args.append_array(float_param.call(10, "High Cut", "Hz", 20.0, 20000.0, 20000.0, true))
	args.append_array(float_param.call(20, "Attack", "ms", 0.0, 500.0, 5.0, false))
	args.append_array(float_param.call(30, "Release", "ms", 5.0, 2000.0, 150.0, false))
	args.append_array(float_param.call(40, "Source", "", 0.0, 999.0, 0.0, false))
	args.append_array(float_param.call(50, "Gain", "dB", -24.0, 24.0, 0.0, false))
	args.append_array(float_param.call(60, "Amount", "%", 0.0, 100.0, 100.0, false))
	registry._on_modulator_kind_received(args)
	var asset_registry: Object = root.get_node("AssetService").device_registry
	asset_registry.modulator_kinds["sidechain"] = registry.get_modulator_kind("sidechain")
	registry._on_builtin_info_received([
		SYNTH_ID, "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		1,
		31, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1, 1,
		0,
		0,
	])
	asset_registry._devices[SYNTH_ID] = registry.get_device(SYNTH_ID)


func _device() -> Object:
	return _inst_script.new(root.get_node("AssetService").device_registry.get_device(SYNTH_ID), 2, 0)


## A `modulation` payload with no kind 0/1 records and the given ext records
## (`[kind, body]` pairs; `len` is the body size).
func _payload(records: Array) -> PackedByteArray:
	var b := PackedByteArray()
	b.append_array([0, 0])
	b.append(records.size())
	b.append(0)
	for record in records:
		b.append(record[0])
		b.append((record[1] as PackedByteArray).size())
		b.append_array(record[1])
	return b


func _kind2(mod_id: int, value: float) -> PackedByteArray:
	var b := PackedByteArray([mod_id, 0])
	b.append_array(PackedFloat32Array([0.0, value]).to_byte_array())
	return b


func _kind3(mod_id: int, param: int, offset: float) -> PackedByteArray:
	var b := PackedByteArray([mod_id])
	b.resize(9)
	b.encode_u32(1, param)
	b.encode_float(5, offset)
	return b


func _kind4(mod_id: int, point_seconds: float, peaks: Array) -> PackedByteArray:
	var b := PackedByteArray([mod_id])
	b.append_array(PackedFloat32Array([point_seconds]).to_byte_array())
	b.append(peaks.size())
	for p in peaks:
		b.append(int(round(float(p) * 255.0)))
	return b


func _spectrum_blob(mod_id: int, low_cut: float, high_cut: float) -> PackedByteArray:
	var floats := PackedFloat32Array([float(mod_id), 48000.0, low_cut, high_cut, 20.0, 20000.0])
	for i in 128:
		floats.append(-20.0 - float(i) * 0.5)
	for i in 128:
		floats.append(-60.0)
	return floats.to_byte_array()


# --- tests ---------------------------------------------------------------------------------

func _test_old_project_defaults() -> void:
	var inst = _device()
	var sc = inst.add_modulator("sidechain")
	sc.params.erase(50)
	sc.params.erase(60)
	var gain: DeviceParameter = sc.get_parameter(50)
	var amount: DeviceParameter = sc.get_parameter(60)
	_assert(gain != null and amount != null, "the sidechain kind advertises Gain and Amount")
	_assert(is_equal_approx(gain.normalized_to_value(sc.get_param(50)), 0.0),
		"a sidechain loaded without Gain reads 0 dB")
	_assert(is_equal_approx(amount.normalized_to_value(sc.get_param(60)), 100.0),
		"a sidechain loaded without Amount reads 100 %")
	_assert(sc.get_param(99) == 0.0, "an unknown parameter still reads 0")
	sc.params[60] = 0.25
	_assert(is_equal_approx(sc.get_param(60), 0.25), "a stored value wins over the default")


func _test_ext_decode() -> void:
	var peaks := [0.0, 0.5, 1.0]
	var blob := _payload([
		[2, _kind2(1, 0.4)],
		[9, PackedByteArray([1, 2, 3, 4])],
		[3, _kind3(1, 20, 0.25)],
		[4, _kind4(1, 0.001, peaks)],
	])
	var ext: Variant = _live_script._decode_ext(blob)
	_assert(ext != null and ext.size() == 3, "kinds 2, 3 and 4 decode and the unknown kind 9 is skipped")
	if ext == null or ext.size() != 3:
		return
	_assert(ext[0]["kind"] == 2 and is_equal_approx(ext[0]["value"], 0.4), "kind 2 state")
	_assert(ext[1]["kind"] == 3 and ext[1]["param"] == 20 and is_equal_approx(ext[1]["offset"], 0.25),
		"kind 3 offset after the unknown record")
	var rec: Dictionary = ext[2]
	_assert(rec["kind"] == 4 and rec["mod_id"] == 1 and is_equal_approx(rec["point_seconds"], 0.001),
		"kind 4 carries the mod id and the point spacing")
	var decoded: PackedFloat32Array = rec["peaks"]
	_assert(decoded.size() == 3 and is_equal_approx(decoded[0], 0.0) and is_equal_approx(decoded[1], 128.0 / 255.0)
		and is_equal_approx(decoded[2], 1.0), "kind 4 peaks map u8 / 255")
	# A record claiming more peaks than its length is dropped, not misread.
	var bad := _kind4(1, 0.001, peaks)
	bad[5] = 9
	var ext_bad: Variant = _live_script._decode_ext(_payload([[4, bad]]))
	_assert(ext_bad != null and ext_bad.is_empty(), "a kind 4 record shorter than its count is dropped")


func _test_history_store() -> void:
	var inst = _device()
	var sc = inst.add_modulator("sidechain")
	var live = _live_script.holder()
	live._paths[inst.osc_path()] = {"device": inst, "count": 1}
	_assert(_live_script.sidechain_history(inst, sc.mod_id).is_empty(), "no history before a payload")
	live._on_data(inst.osc_path(), "modulation", _payload([[2, _kind2(sc.mod_id, 0.2)],
		[4, _kind4(sc.mod_id, 0.001, [0.1, 0.9])]]))
	var history: Dictionary = _live_script.sidechain_history(inst, sc.mod_id)
	_assert(history.has("peaks") and history["peaks"].size() == 2 and is_equal_approx(history["point_seconds"], 0.001),
		"a payload stores the history per device and modulator")
	live._on_data(inst.osc_path(), "modulation", _payload([[2, _kind2(sc.mod_id, 0.2)]]))
	_assert(_live_script.sidechain_history(inst, sc.mod_id).is_empty(), "the next payload replaces it")
	_live_script.reset()


func _display(inst: Object, sc: Object) -> ModulatorDisplay:
	var display: ModulatorDisplay = _display_script.new()
	root.add_child(display)
	display.size = Vector2(202, 106)
	display.setup(inst, sc.mod_id)
	return display


func _test_line_peak_and_scale() -> void:
	var inst = _device()
	var sc = inst.add_modulator("sidechain")
	var display := _display(inst, sc)
	await process_frame
	var rect := Rect2(Vector2(3, 3), display.size - Vector2(6, 6))
	var now := Time.get_ticks_usec() / 1000000.0
	# 80 points of low level with one peak at 0.8; arrived a second ago so all are drawable.
	var peaks := PackedFloat32Array()
	peaks.resize(80)
	for i in 80:
		peaks[i] = 0.1
	peaks[37] = 0.8
	display.ingest_sidechain(peaks, 1.0 / 750.0, now - 1.0)
	var line := display.sidechain_points(rect, now)
	_assert(line.size() >= 2, "the history draws a line")
	var highest := INF
	for p in line:
		highest = minf(highest, p.y)
	_assert(is_equal_approx(highest, rect.position.y + (1.0 - 0.8) * rect.size.y),
		"the highest line point is the history's peak despite decimation (%f)" % highest)

	var display2 := _display(inst, sc)
	var half := PackedFloat32Array([0.5])
	display2.ingest_sidechain(half, 1.0 / 750.0, now - 1.0)
	var dot: Variant = display2.dot_position()
	_assert(dot != null, "the newest point carries the dot")
	if dot != null:
		_assert(absf(dot.y - (rect.position.y + rect.size.y * 0.5)) < 0.5, "a value of 0.5 sits at mid-height")
		_assert(is_equal_approx(dot.x, rect.end.x), "at the right edge")
	# The window scrolls with time: two seconds later nothing is left to draw.
	_assert(display2.sidechain_points(rect, now + 3.0).is_empty(), "points scroll out of the 2 s window")
	display.queue_free()
	display2.queue_free()


func _test_mini_spectrum() -> void:
	var blob := _spectrum_blob(1, 200.0, 0.0)
	var decoded := MiniSpectrum.decode_points(blob, 16)
	_assert(not decoded.is_empty() and decoded["a"].size() == 128 and decoded["b"].size() == 128,
		"the blob decodes 128 + 128 values")
	_assert(is_equal_approx(decoded["lo_hz"], 20.0) and is_equal_approx(decoded["hi_hz"], 20000.0), "with lo_hz and hi_hz")
	_assert(is_equal_approx(decoded["a"][2], -21.0) and is_equal_approx(decoded["b"][127], -60.0), "and the right values")
	_assert(MiniSpectrum.decode_points(PackedByteArray([1, 2, 3]), 0).is_empty(), "a short blob decodes to nothing")

	var plot := MiniSpectrum.new()
	plot.size = Vector2(300, 100)
	root.add_child(plot)
	plot.size = Vector2(300, 100)
	var axis := FreqAxis.new()
	axis.rect = Rect2(Vector2.ZERO, plot.size)
	_assert(is_equal_approx(plot.marker_x(200.0), axis.hz_to_x(200.0)), "a 200 Hz marker sits at hz_to_x(200)")
	_assert(plot.marker_x(0.0) < 0.0, "a marker of 0 is hidden")
	plot.set_curves(PackedFloat32Array([-60.0, -60.0, -60.0]), PackedFloat32Array([-60.0, -60.0, -60.0]), 20.0, 20000.0)
	plot.set_curves(PackedFloat32Array([0.0, 0.0, 0.0]), PackedFloat32Array([0.0, 0.0, 0.0]), 20.0, 20000.0)
	plot._process(0.05)
	_assert(plot._front[0] > -60.0 and plot._front[0] < 0.0, "the plot eases toward a new frame")
	plot.queue_free()


func _test_options_stream() -> void:
	var inst = _device()
	var sc = inst.add_modulator("sidechain")
	var scene: PackedScene = load("res://devices/modulators/options/SidechainOptions.tscn")
	var options = scene.instantiate()
	root.add_child(options)
	options.setup(sc)
	await process_frame
	_assert(not options.apply_blob(_spectrum_blob(sc.mod_id + 1, 100.0, 0.0)), "a blob for another modulator is ignored")
	_assert(options.apply_blob(_spectrum_blob(sc.mod_id, 200.0, 0.0)), "a blob for this modulator is applied")
	_assert(options.spectrum.markers.size() == 2 and is_equal_approx(options.spectrum.markers[0], 200.0)
		and options.spectrum.markers[1] == 0.0, "the cuts become markers, a bypassed one is 0")
	_assert(options.spectrum.marker_x(options.spectrum.markers[1]) < 0.0, "so the bypassed cut draws nothing")
	options.queue_free()
