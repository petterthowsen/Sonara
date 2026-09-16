# test_automation_curve_parity.gd
# Headless parity test for AutomationCurve against Engine/src/audio/automation.rs's
# `automation_curve_shapes` unit test. Expected values are copied from that passing Rust test,
# not derived from this GDScript implementation, so a sign error here cannot pass silently.
# Run: godot --headless --path Godot -s tests/test_automation_curve_parity.gd -- --test
extends TestBase

const TOLERANCE := 0.001


func suite_name() -> String:
	return "Automation curve parity tests"


func run_tests() -> void:
	_test_linear_tension_zero()
	_test_linear_tension_positive()
	_test_linear_tension_negative()
	_test_step()
	_test_endpoints_pinned_for_every_tension()


func _point(id: int, tick: int, value: float, curve: int = AutomationPoint.CurveType.LINEAR, tension: float = 0.0) -> AutomationPoint:
	return AutomationPoint.new(id, tick, value, curve, tension)


func _test_linear_tension_zero() -> void:
	var a := _point(1, 0, 0.0)
	var b := _point(2, 960, 1.0)
	var expected := {240: 0.25, 480: 0.5, 720: 0.75}
	for tick in expected:
		var value := AutomationCurve.evaluate(a, b, tick)
		_assert(absf(value - expected[tick]) < TOLERANCE,
			"linear tension 0.0 at %d = %f (expected %f)" % [tick, value, expected[tick]])
	_assert(AutomationCurve.evaluate(a, b, 480) == 0.5, "exactly 0.5 at the midpoint")


func _test_linear_tension_positive() -> void:
	var a := _point(1, 0, 0.0, AutomationPoint.CurveType.LINEAR, 0.5)
	var b := _point(2, 960, 1.0)
	var expected := {240: 0.0625, 480: 0.25, 720: 0.5625}
	for tick in expected:
		var value := AutomationCurve.evaluate(a, b, tick)
		_assert(absf(value - expected[tick]) < TOLERANCE,
			"linear tension +0.5 at %d = %f (expected %f)" % [tick, value, expected[tick]])


func _test_linear_tension_negative() -> void:
	var a := _point(1, 0, 0.0, AutomationPoint.CurveType.LINEAR, -0.5)
	var b := _point(2, 960, 1.0)
	var expected := {240: 0.5, 480: 0.7071068, 720: 0.8660254}
	for tick in expected:
		var value := AutomationCurve.evaluate(a, b, tick)
		_assert(absf(value - expected[tick]) < TOLERANCE,
			"linear tension -0.5 at %d = %f (expected %f)" % [tick, value, expected[tick]])


func _test_step() -> void:
	var a := _point(1, 0, 0.0, AutomationPoint.CurveType.STEP)
	var b := _point(2, 960, 1.0)
	for tick in [0, 240, 480, 720, 959]:
		var value := AutomationCurve.evaluate(a, b, tick)
		_assert(value == 0.0, "step holds 0.0 at %d, got %f" % [tick, value])
	_assert(AutomationCurve.evaluate(a, b, 960) == 1.0, "step jumps to 1.0 exactly at tick 960")


func _test_endpoints_pinned_for_every_tension() -> void:
	var b := _point(2, 960, 1.0)
	for tension in [0.0, 0.5, -0.5, 1.0, -1.0]:
		var a := _point(1, 0, 0.0, AutomationPoint.CurveType.LINEAR, tension)
		var at_start := AutomationCurve.evaluate(a, b, 0)
		var at_end := AutomationCurve.evaluate(a, b, 960)
		_assert(at_start == 0.0, "tension %f pins start, got %f" % [tension, at_start])
		_assert(at_end == 1.0, "tension %f pins end, got %f" % [tension, at_end])
