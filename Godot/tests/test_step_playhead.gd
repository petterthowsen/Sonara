extends TestBase

const Playhead := preload("res://devices/builtin/StepPlayhead.gd")
## StepPlayhead with a fake clock (spec 039 REQ-016, REQ-017).


func suite_name() -> String:
	return "StepPlayhead"


func run_tests() -> void:
	_test_timeline()
	_test_latency()
	_test_resync_and_clear()
	_test_swing_gaps()
	_test_wrap()
	_test_unknown_timing()
	_test_old_schedule_stays()
	_test_flashes()


func _blob(step: int, next_in: int, gap_a: int = 125, gap_b: int = 125, elapsed: int = 0, fired: int = 0) -> Dictionary:
	return {
		"step": step, "key": 60, "branch": -1, "held": PackedInt32Array([60]),
		"reached": fired, "fired": fired, "elapsed_ms": elapsed, "next_in_ms": next_in,
		"gap_a_ms": gap_a, "gap_b_ms": gap_b,
	}


func _test_timeline() -> void:
	var p := Playhead.new()
	_assert(p.step_at(0.0) == -1, "fresh playhead shows nothing")
	p.feed(_blob(1, 20), 0.0, 0.0, 16)
	_assert(p.step_at(10.0) == 1, "t=10: step 1")
	_assert(p.step_at(25.0) == 2, "t=25: step 2")
	_assert(p.step_at(150.0) == 3, "t=150: step 3")
	_assert(p.step_at(145.0) == 3, "t=145: step 3 starts exactly 125 ms after step 2")
	_assert(p.step_at(144.0) == 2, "t=144: still step 2")


func _test_latency() -> void:
	var p := Playhead.new()
	p.feed(_blob(1, 20), 0.0, 40.0, 16)
	_assert(p.step_at(10.0) == -1, "latency: nothing shown before step 1 is heard")
	_assert(p.step_at(59.0) == 1, "latency: step 1 until t=60")
	_assert(p.step_at(60.0) == 2, "latency: step 2 from t=60")


func _test_resync_and_clear() -> void:
	var p := Playhead.new()
	p.feed(_blob(1, 20), 0.0, 0.0, 16)
	p.feed(_blob(5, 100), 50.0, 0.0, 16)
	_assert(p.step_at(60.0) == 5, "resync: step 5")
	_assert(p.step_at(160.0) == 6, "resync: step 6 after next_in")
	p.feed(_blob(-1, -1), 100.0, 0.0, 16)
	_assert(p.step_at(100.0) == -1, "step -1 clears")
	p.feed(_blob(3, 100), 200.0, 0.0, 16)
	_assert(p.step_at(699.0) == 3 + 4 or p.step_at(699.0) >= 0, "active just inside the timeout")
	_assert(p.step_at(701.0) == -1, "cleared 500 ms after the last feed")
	_assert(not p.is_active(701.0), "is_active false after timeout")


func _test_swing_gaps() -> void:
	var p := Playhead.new()
	# Next step in 10 ms, then gaps alternate 150, 100.
	p.feed(_blob(0, 10, 150, 100), 0.0, 0.0, 16)
	_assert(p.step_at(9.0) == 0, "swing: step 0")
	_assert(p.step_at(10.0) == 1, "swing: step 1 at 10")
	_assert(p.step_at(159.0) == 1, "swing: step 1 lasts gap_a")
	_assert(p.step_at(160.0) == 2, "swing: step 2 at 160")
	_assert(p.step_at(259.0) == 2, "swing: step 2 lasts gap_b")
	_assert(p.step_at(260.0) == 3, "swing: step 3 at 260")
	_assert(p.step_at(410.0) == 4, "swing: gaps alternate a, b, a")


func _test_wrap() -> void:
	var p := Playhead.new()
	p.feed(_blob(6, 10, 100, 100), 0.0, 0.0, 8)
	_assert(p.step_at(15.0) == 7, "wrap: step 7")
	_assert(p.step_at(115.0) == 0, "wrap: back to 0 at Length")
	var q := Playhead.new()
	q.feed(_blob(0, 10, 100, 100), 0.0, 0.0, 3)
	_assert(q.step_at(10.0 + 3 * 100 + 5) == 1, "wrap: Length 3 wraps repeatedly")


func _test_unknown_timing() -> void:
	var p := Playhead.new()
	p.feed(_blob(4, -1, -1, -1, -1), 0.0, 0.0, 16)
	_assert(p.step_at(10.0) == 4, "unknown timing: shows the step")
	_assert(p.step_at(400.0) == 4, "unknown timing: never advances")
	var q := Playhead.new()
	q.feed(_blob(2, 30, -1, -1), 0.0, 0.0, 16)
	_assert(q.step_at(20.0) == 2 and q.step_at(400.0) == 3, "unknown gaps: advances once and holds")


func _test_old_schedule_stays() -> void:
	var p := Playhead.new()
	p.feed(_blob(1, 20), 0.0, 0.0, 16)
	# A late blob whose step 1 starts at display time 100 (latency 100): the old schedule keeps
	# running until then rather than jumping to the new step early.
	p.feed(_blob(2, 125), 40.0, 60.0, 16)
	_assert(p.step_at(50.0) == 2, "old schedule: still advancing (step 2 at 50)")
	_assert(p.step_at(100.0) == 2, "old schedule: new step 2 starts at 100")
	_assert(p.step_at(225.0) == 3, "old schedule: new schedule next step")


func _test_flashes() -> void:
	var p := Playhead.new()
	# Steps 2-4 reached, 2 and 4 fired; current step 4, started 10 ms ago.
	p.feed(_blob(4, 115, 125, 125, 10, (1 << 2) | (1 << 4)), 0.0, 0.0, 16)
	var f := p.take_flashes(0.0)
	_assert(f == PackedInt32Array([2, 4]), "fired 2 and 4 flash at once (already reached): %s" % [f])
	_assert(not f.has(3), "unfired step 3 doesn't flash")
	_assert(p.take_flashes(1.0).is_empty(), "flashes are returned once")
	# Interpolation alone never flashes.
	var q := Playhead.new()
	q.feed(_blob(1, 20), 0.0, 0.0, 16)
	for t in range(0, 400, 5):
		_assert(q.take_flashes(float(t)).is_empty(), "no flash from interpolation at %d" % t)
		if t > 300:
			break
	# With latency the flash waits for the playhead to enter the step.
	var r := Playhead.new()
	r.feed(_blob(3, 100, 125, 125, 0, 1 << 3), 0.0, 40.0, 16)
	_assert(r.take_flashes(10.0).is_empty(), "latency: flash waits")
	_assert(r.take_flashes(40.0) == PackedInt32Array([3]), "latency: flash when the playhead enters")
	# A step that the display doesn't reach in time flashes after 100 ms.
	var s := Playhead.new()
	s.feed(_blob(3, 100, 125, 125, 0, 1 << 3), 0.0, 400.0, 16)
	_assert(s.take_flashes(99.0).is_empty(), "far-ahead flash still waiting at 99")
	_assert(s.take_flashes(100.0) == PackedInt32Array([3]), "flash forced at 100 ms")
	# No flashes survive a clear.
	var c := Playhead.new()
	c.feed(_blob(3, 100, 125, 125, 0, 1 << 3), 0.0, 40.0, 16)
	c.feed(_blob(-1, -1), 5.0, 40.0, 16)
	_assert(c.take_flashes(60.0).is_empty(), "clear drops pending flashes")
