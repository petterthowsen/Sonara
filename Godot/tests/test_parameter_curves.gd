# Parameter curves: DeviceParameter skew/log round trips, /builtin/info carrying them into
# DeviceParameter, and Envelope stage curves.
# Run: godot --headless --path Godot -s tests/test_parameter_curves.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Parameter curves"


func run_tests() -> void:
	_test_skew_round_trips()
	_test_skew_values()
	_test_log_ignores_skew()
	_test_builtin_info_carries_curve()
	_test_envelope_stage_curve()


func _param(lo: float, hi: float, skew: float, is_log := false) -> DeviceParameter:
	var p := DeviceParameter.new(0, "P")
	p.min_value = lo
	p.max_value = hi
	p.skew = skew
	p.is_logarithmic = is_log
	return p


func _test_skew_round_trips() -> void:
	for skew in [1.0, 3.0, 4.0]:
		var p := _param(0.0005, 10.0, skew)
		for n in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var back := p.value_to_normalized(p.normalized_to_value(n))
			_assert(absf(back - n) < 1e-4, "skew %s round trips n=%s (got %s)" % [skew, n, back])
		_assert(is_equal_approx(p.normalized_to_value(0.0), 0.0005), "skew %s: n=0 is min" % skew)
		_assert(is_equal_approx(p.normalized_to_value(1.0), 10.0), "skew %s: n=1 is max" % skew)


func _test_skew_values() -> void:
	var t := _param(0.0, 10.0, 4.0)
	_assert(is_equal_approx(t.normalized_to_value(0.5), 0.625), "skew 4 puts 625 ms at mid-knob")
	var glide := _param(0.0, 1.0, 3.0)
	_assert(glide.normalized_to_value(0.0) == 0.0, "glide 0 is exactly off")


func _test_log_ignores_skew() -> void:
	var a := _param(20.0, 20000.0, 4.0, true)
	var b := _param(20.0, 20000.0, 1.0, true)
	_assert(is_equal_approx(a.normalized_to_value(0.5), b.normalized_to_value(0.5)), "log ignores skew")


func _test_builtin_info_carries_curve() -> void:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	# id, name, category, description, midi, audio in/out, file loading, file desc, ext count,
	# param count, (id, name, unit, type, syncable, min, max, default, is_log, skew, enum count),
	# is_container
	registry._on_builtin_info_received([
		"test.curves", "Curves", "instrument", "", 1, 0, 2, 0, "", 0,
		2,
		1, "Attack", "s", "float", 1, 0.0005, 10.0, 0.01, 0, 4.0, 0, "", 1,
		2, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1,
		0,
	])
	var device: Device = registry.get_device("test.curves")
	_assert(device != null, "device registered from /builtin/info")
	if device == null:
		return
	var attack: DeviceParameter = device.get_parameter(1)
	var cutoff: DeviceParameter = device.get_parameter(2)
	_assert(attack != null and is_equal_approx(attack.skew, 4.0), "skew reaches DeviceParameter")
	_assert(attack != null and not attack.is_logarithmic, "linear flag reaches DeviceParameter")
	_assert(cutoff != null and cutoff.is_logarithmic, "log flag reaches DeviceParameter")
	_assert(cutoff != null and is_equal_approx(cutoff.default_value, 2000.0), "default stays real")


func _test_envelope_stage_curve() -> void:
	var env := Envelope.new()
	env.set_stage_range(Envelope.Stage.ATTACK, 0.0, 10.0)
	env.set_stage_curve(Envelope.Stage.ATTACK, 4.0)
	_assert(is_equal_approx(env.stage_to_fraction(Envelope.Stage.ATTACK, 0.625), 0.5),
		"envelope display position equals the knob position")
	_assert(is_equal_approx(env.fraction_to_stage(Envelope.Stage.ATTACK, 0.5), 0.625),
		"envelope inverse matches")
	env.set_stage_curve(Envelope.Stage.ATTACK, 1.0)
	_assert(is_equal_approx(env.stage_to_fraction(Envelope.Stage.ATTACK, 5.0), 0.5), "linear curve")
