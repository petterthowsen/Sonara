# test_time_format.gd
# Headless tests for TimeFormat and the time-unit display of knobs, sliders and DeviceParameter.
# Run: godot --headless --path Godot -s tests/test_time_format.gd -- --test
extends TestBase


func suite_name() -> String:
	return "TimeFormat tests"


func run_tests() -> void:
	_test_format()
	_test_parse()
	_test_envelope_matches()
	_test_device_parameter()
	_test_knob()


func _test_format() -> void:
	_assert(TimeFormat.format_seconds(0.0005) == "0.5 ms", "sub-10ms keeps a decimal")
	_assert(TimeFormat.format_seconds(0.25) == "250 ms", "250 ms")
	_assert(TimeFormat.format_seconds(1.2) == "1.20 s", "1.20 s")
	_assert(TimeFormat.format_seconds(1.0) == "1.00 s", "1 s boundary shows seconds")
	_assert(TimeFormat.format_ms(250.0) == "250 ms", "ms input below 1000")
	_assert(TimeFormat.format_ms(1200.0) == "1.20 s", "ms input above 1000")
	_assert(TimeFormat.format(0.5, "s") == "500 ms", "s input below 1 drops to ms")
	_assert(TimeFormat.format(2.5, "s") == "2.50 s", "s input above 1")
	_assert(TimeFormat.format(1.0, "Hz") == "", "other units are not handled")


func _test_parse() -> void:
	_assert(is_equal_approx(TimeFormat.parse("250", "ms"), 250.0), "bare number in ms")
	_assert(is_equal_approx(TimeFormat.parse("1.2 s", "ms"), 1200.0), "s suffix into ms")
	_assert(is_equal_approx(TimeFormat.parse("250 ms", "ms"), 250.0), "ms suffix into ms")
	_assert(is_equal_approx(TimeFormat.parse("250ms", "s"), 0.25), "ms suffix into s")
	_assert(is_equal_approx(TimeFormat.parse("2 S", "s"), 2.0), "s suffix into s, case-insensitive")
	_assert(is_nan(TimeFormat.parse("abc", "ms")), "garbage is NAN")
	_assert(is_nan(TimeFormat.parse("", "s")), "empty is NAN")


func _test_envelope_matches() -> void:
	var control: GDScript = load("res://components/EnvelopeControl.gd")
	for seconds in [0.0005, 0.25, 1.2]:
		_assert(control.format_time(seconds) == TimeFormat.format_seconds(seconds), "envelope uses the helper at %s" % seconds)


func _test_device_parameter() -> void:
	var p := DeviceParameter.new(0, "T")
	p.unit = "ms"
	p.param_type = "float"
	p.min_value = 0.0
	p.max_value = 5000.0
	_assert(p.format_value(250.0) == "250 ms", "ms param: %s" % p.format_value(250.0))
	_assert(p.format_value(1200.0) == "1.20 s", "ms param over 1000: %s" % p.format_value(1200.0))
	_assert(is_equal_approx(p.parse_edit_text("1.5s"), 1500.0), "ms param accepts s suffix")
	_assert(is_equal_approx(p.parse_edit_text("40 ms"), 40.0), "ms param accepts ms suffix")
	p.unit = "s"
	_assert(p.format_value(0.5) == "500 ms", "s param under 1: %s" % p.format_value(0.5))
	_assert(is_equal_approx(p.parse_edit_text("300ms"), 0.3), "s param accepts ms suffix")


func _test_knob() -> void:
	var knob := RotaryKnob.new()
	knob.min_value = 0.0
	knob.max_value = 5000.0
	knob.unit = "ms"
	knob.value = 1200.0
	_assert(knob.get_value_text() == "1.20 s", "knob ms -> s: %s" % knob.get_value_text())
	knob.value = 250.0
	_assert(knob.get_value_text() == "250 ms", "knob stays ms: %s" % knob.get_value_text())
	knob.unit = "Hz"
	_assert(knob.get_value_text().ends_with("Hz"), "other units unchanged")
	knob.free()
