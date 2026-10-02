# test_level_meter.gd
# Headless tests for MeterBallistics and LevelMeter: release rate, hold then fall, RMS smoothing,
# Display switching, REDUCTION fill direction, zone colours and readout reset.
# Run: godot --headless --path Godot -s tests/test_level_meter.gd -- --test
extends TestBase


func suite_name() -> String:
	return "LevelMeter tests"


func run_tests() -> void:
	_test_peak_release_rate()
	_test_hold_then_fall()
	_test_rms_smoothing()
	_test_settles()
	_test_display_switch_moves_hold_and_readout()
	_test_reduction_fills_from_top()
	_test_zone_colours()
	_test_readout_reset_on_click()


func _run(meter: LevelMeter, seconds: float, dt := 0.01) -> void:
	for i in int(seconds / dt):
		meter.advance(dt)


func _new_meter() -> LevelMeter:
	var meter := LevelMeter.new()
	meter.size = Vector2(40, 100)
	root.add_child(meter)
	return meter


func _test_peak_release_rate() -> void:
	var b := MeterBallistics.new(-60.0)
	b.push(0.0)
	_assert(b.peak_db == 0.0, "peak attacks instantly")
	b.push(-60.0)
	for i in 100:
		b.step(0.01)
	_assert(absf(b.peak_db - -30.0) < 0.01, "peak falls 30 dB in 1 s (got %s)" % b.peak_db)
	for i in 300:
		b.step(0.01)
	_assert(b.peak_db == -60.0, "peak stops at the floor")


func _test_hold_then_fall() -> void:
	var b := MeterBallistics.new(-60.0)
	b.push(0.0)
	b.push(-60.0)
	for i in 100:
		b.step(0.01)
	_assert(b.peak_hold_db == 0.0, "hold line sticks during hold_time")
	for i in 100:
		b.step(0.01)
	_assert(b.peak_hold_db < 0.0 and b.peak_hold_db > -15.0, "hold line then falls (got %s)" % b.peak_hold_db)


func _test_rms_smoothing() -> void:
	var b := MeterBallistics.new(-60.0)
	b.push(0.0, 0.0)
	b.step(0.05)
	_assert(b.rms_db < -2.0 and b.rms_db > -8.0, "rms rises over its attack time, not at once (got %s)" % b.rms_db)
	for i in 100:
		b.step(0.01)
	_assert(absf(b.rms_db) < 0.1, "rms reaches the target (got %s)" % b.rms_db)
	b.push(-60.0, -60.0)
	b.step(0.3)
	_assert(b.rms_db > -20.0, "rms release is slower than a peak drop (got %s)" % b.rms_db)


func _test_settles() -> void:
	var meter := _new_meter()
	meter.push(0, 0.0, -6.0)
	meter.push(0, -60.0, -60.0)
	_run(meter, 6.0)
	_assert(not meter.is_processing(), "meter stops processing once settled")
	meter.push(0, -10.0)
	_assert(meter.is_processing(), "a new level wakes it")
	meter.free()


func _test_display_switch_moves_hold_and_readout() -> void:
	var meter := _new_meter()
	meter.push(0, -6.0, -12.0)
	_run(meter, 1.0)
	_assert(absf(meter.hold_db(0) - -6.0) < 0.01 and meter.readout_text(0) == "-6.0",
		"PEAK display holds and reads the peak (%s, %s)" % [meter.hold_db(0), meter.readout_text(0)])
	meter.display = LevelMeter.Display.RMS
	_assert(absf(meter.level_db(0) - -12.0) < 0.1, "RMS display shows the rms level")
	_assert(absf(meter.hold_db(0) - -12.0) < 0.1 and meter.readout_text(0) == "-12.0",
		"RMS display moves hold and readout to the rms (%s, %s)" % [meter.hold_db(0), meter.readout_text(0)])
	meter.free()


func _test_reduction_fills_from_top() -> void:
	var gr := _new_meter()
	gr.mode = LevelMeter.Mode.REDUCTION
	gr.min_db = 0.0
	gr.max_db = 24.0
	gr.push(0, 12.0)
	var bar := gr.bar_rect(0)
	var fill := gr.fill_rect(0)
	_assert(is_equal_approx(fill.position.y, bar.position.y), "REDUCTION fill starts at the top")
	_assert(is_equal_approx(fill.size.y, bar.size.y * 0.5), "12 of 24 dB fills half the bar")
	_assert(gr.readout_text(0) == "-12.0", "reduction readout is negative (%s)" % gr.readout_text(0))
	var lvl := _new_meter()
	lvl.push(0, -30.0)
	_assert(is_equal_approx(lvl.fill_rect(0).end.y, lvl.bar_rect(0).end.y), "LEVEL fill ends at the bottom")
	gr.free()
	lvl.free()


func _test_zone_colours() -> void:
	var meter := _new_meter()
	_assert(meter.zone_color(-20.0) == meter.safe_color, "below warn_db is the safe colour")
	_assert(meter.zone_color(-3.0) == meter.warn_color, "between warn_db and clip_db is the warn colour")
	_assert(meter.zone_color(0.0) == meter.clip_color, "at clip_db is the clip colour")
	meter.color_mode = LevelMeter.ColorMode.SOLID
	_assert(meter.zone_color(0.0) == meter.safe_color, "SOLID uses one colour at any level")
	meter.free()


func _test_readout_reset_on_click() -> void:
	var meter := _new_meter()
	meter.push(0, -3.0)
	_run(meter, 0.1)
	_assert(meter.readout_text(0) == "-3.0", "readout shows the held maximum")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	meter._gui_input(ev)
	_assert(meter.readout_text(0) == "-inf" and meter.hold_db(0) == -INF, "click clears readout and hold")
	meter.free()
