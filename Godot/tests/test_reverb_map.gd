# Reverb decay-map model (spec 050): contour times, engine plateau values, the time span,
# Freeze, early ticks, the Diffusion onset estimate, the square-root time axis and the "envelope"
# blob decoder.
# Run: godot --headless --path Godot -s tests/test_reverb_map.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Reverb map model"


func _values(overrides := {}) -> Dictionary:
	var values := ReverbData.DEFAULTS.duplicate()
	for id in overrides:
		values[id] = overrides[id]
	return values


func _spec_values() -> Dictionary:
	# REQ-003: Decay 2.0, Low x1.5 @ 250 Hz, High x0.5 @ 4 kHz, Pre-Delay 20 ms.
	return _values({
		ReverbData.P_DECAY: 2.0, ReverbData.P_LOW_MULT: 1.5, ReverbData.P_LOW_FREQ: 250.0,
		ReverbData.P_HIGH_MULT: 0.5, ReverbData.P_HIGH_FREQ: 4000.0, ReverbData.P_PREDELAY: 20.0,
	})


func run_tests() -> void:
	_test_contour_times()
	_test_engine_plateaus()
	_test_levels()
	_test_span()
	_test_freeze()
	_test_early_ticks()
	_test_onset()
	_test_time_axis()
	_test_envelope_decode()
	_test_format()


func _near(actual: float, expected: float, tolerance: float) -> bool:
	return absf(actual - expected) / expected <= tolerance


func _test_contour_times() -> void:
	var v := _spec_values()
	var t1k := ReverbData.contour_time(1000.0, v)
	_assert(_near(t1k, 2.02, 0.10), "1 kHz contour is Decay + Pre-Delay +-10 %% (%.3f)" % t1k)
	var t30 := ReverbData.contour_time(30.0, v)
	_assert(_near(t30, 3.02, 0.05), "30 Hz contour is Decay x Low Mult +-5 %% (%.3f)" % t30)
	var t18k := ReverbData.contour_time(18000.0, v)
	_assert(_near(t18k, 1.02, 0.05), "18 kHz contour is Decay x High Mult +-5 %% (%.3f)" % t18k)
	# A smooth knee: the contour is monotone between the plateaus.
	var previous := INF
	var monotone := true
	for i in 40:
		var f := 30.0 * pow(18000.0 / 30.0, float(i) / 39.0)
		var t := ReverbData.contour_time(f, v)
		if t > previous + 1e-4:
			monotone = false
		previous = t
	_assert(monotone, "the contour falls monotonically from the low to the high plateau")


## The plateau values the engine test `decay_eq_moves_the_band_t60s` asserts.
func _test_engine_plateaus() -> void:
	var v := _values({ReverbData.P_DECAY: 1.5})
	_assert(_near(ReverbData.band_t60(60.0, v), 1.5 * 1.2, 0.2), "default 60 Hz plateau is Decay x Low Mult")
	_assert(_near(ReverbData.band_t60(10000.0, v), 1.5 * 0.5, 0.2), "default 10 kHz plateau is Decay x High Mult")
	v[ReverbData.P_LOW_MULT] = 2.0
	v[ReverbData.P_HIGH_MULT] = 0.25
	_assert(_near(ReverbData.band_t60(60.0, v), 1.5 * 2.0, 0.2), "Low x2 plateau")
	_assert(_near(ReverbData.band_t60(10000.0, v), 1.5 * 0.25, 0.2), "High x0.25 plateau")


func _test_levels() -> void:
	var v := _spec_values()
	_assert(ReverbData.level_db(0.01, 1000.0, v) <= ReverbData.FLOOR_DB, "nothing before Pre-Delay")
	var start := ReverbData.level_db(0.02, 1000.0, v)
	_assert(absf(start) < 0.5, "the tail starts at 0 dB in the passband (%.2f)" % start)
	var at_contour := ReverbData.level_db(ReverbData.contour_time(1000.0, v), 1000.0, v)
	_assert(absf(at_contour + 60.0) < 1.0, "the level is -60 dB at the contour (%.2f)" % at_contour)
	_assert(ReverbData.cut_db(20.0, v) < -20.0, "below Low Cut is faded out")
	_assert(ReverbData.cut_db(20000.0, v) < -3.0, "above High Cut is faded out")
	_assert(absf(ReverbData.cut_db(1000.0, v)) < 0.1, "the passband is untouched")


func _test_span() -> void:
	var short := ReverbData.span_target(_values({ReverbData.P_DECAY: 0.3}))
	_assert(short <= 1.0, "Decay 0.3 s gives a span <= 1 s (%s)" % short)
	var long_span := ReverbData.span_target(_values({ReverbData.P_DECAY: 20.0}))
	_assert(long_span >= 20.0, "Decay 20 s gives a span >= 20 s (%s)" % long_span)
	_assert(ReverbData.SPAN_STEPS.has(short) and ReverbData.SPAN_STEPS.has(long_span), "spans snap to the readable steps")
	var pre_long := ReverbData.span_target(_values({ReverbData.P_DECAY: 0.3, ReverbData.P_PREDELAY: 500.0}))
	_assert(pre_long > short, "Pre-Delay lengthens the span")
	# Drag lock lives on the map control (ReverbDecayMap): it is covered by test_reverb_view.gd.


func _test_freeze() -> void:
	var frozen := _values({ReverbData.P_FREEZE: 1.0})
	_assert(is_inf(ReverbData.band_t60(1000.0, frozen)), "Freeze: band T60 is infinite")
	for f in [20.0, 100.0, 1000.0, 10000.0, 20000.0]:
		_assert(is_inf(ReverbData.contour_time(f, frozen)), "Freeze: contour time at %d Hz is infinite" % int(f))
	_assert(absf(ReverbData.level_db(5.0, 1000.0, frozen)) < 0.5, "Freeze: full level far into the tail")
	_assert(ReverbData.span_target(frozen) == ReverbData.span_target(_values()), "Freeze keeps the unfrozen span")


func _test_early_ticks() -> void:
	var room := ReverbData.early_ticks(_values({ReverbData.P_ALGORITHM: 0.0}))
	var hall := ReverbData.early_ticks(_values({ReverbData.P_ALGORITHM: 1.0}))
	var plate := ReverbData.early_ticks(_values({ReverbData.P_ALGORITHM: 2.0}))
	_assert(room.size() == 20 and hall.size() == 14 and plate.size() == 10, "tap counts per algorithm (%d/%d/%d)" % [room.size(), hall.size(), plate.size()])
	_assert(room[0]["t"] != hall[0]["t"], "the algorithm changes the ticks")
	var small := ReverbData.early_ticks(_values({ReverbData.P_SIZE: 0.0}))
	var big := ReverbData.early_ticks(_values({ReverbData.P_SIZE: 100.0}))
	_assert(big[big.size() - 1]["t"] > small[small.size() - 1]["t"], "Size spreads the ticks")
	var first_delayed := ReverbData.early_ticks(_values({ReverbData.P_PREDELAY: 100.0}))
	_assert(first_delayed[0]["t"] > 0.1, "Pre-Delay shifts the ticks")
	var quiet := ReverbData.early_ticks(_values({ReverbData.P_EARLY: 25.0}))
	var loud := ReverbData.early_ticks(_values({ReverbData.P_EARLY: 100.0}))
	_assert(loud[0]["db"] > quiet[0]["db"], "Early raises the tick level")
	_assert(ReverbData.early_ticks(_values({ReverbData.P_EARLY: 0.0})).is_empty(), "Early 0 draws no ticks")


func _test_onset() -> void:
	var smooth := _values({ReverbData.P_DIFFUSION: 100.0})
	var grainy := _values({ReverbData.P_DIFFUSION: 0.0})
	_assert(ReverbData.tail_build_s(smooth) < ReverbData.tail_build_s(grainy), "Diffusion shortens the tail build-up")
	_assert(ReverbData.early_blur_s(smooth) > 0.0 and ReverbData.early_blur_s(grainy) == 0.0, "Diffusion blurs the early taps, 0 % leaves them sharp")
	var pre := ReverbData.DEFAULTS[ReverbData.P_PREDELAY] * 0.001
	_assert(ReverbData.tail_onset(pre - 0.001, grainy) == 0.0, "no tail before Pre-Delay")
	var mid := pre + ReverbData.tail_build_s(grainy) * 0.5
	_assert(ReverbData.tail_onset(mid, smooth) > ReverbData.tail_onset(mid, grainy), "a diffuse tail is denser early on")
	_assert(is_equal_approx(ReverbData.tail_onset(pre + 1.0, grainy), 1.0), "the tail is fully built after the onset")


func _test_time_axis() -> void:
	var map := ReverbDecayMap.new()
	map.size = Vector2(434, 134)
	map.span = 3.0
	var plot := map.plot_rect()
	for t: float in [0.0, 0.02, 0.1, 1.0, 3.0]:
		_assert(absf(map.t_of_x(map.x_of_t(t)) - t) < 1e-4, "x_of_t / t_of_x round-trip at %s s" % t)
	_assert(is_equal_approx(map.x_of_t(3.0), plot.end.x), "the span ends at the right edge")
	_assert(map.x_of_t(0.1) - plot.position.x > plot.size.x * 0.15, "the first 100 ms get over 15 % of a 3 s map")
	_assert(ReverbDecayMap.time_label(0.05) == "50 ms" and ReverbDecayMap.time_label(2.0) == "2.0 s", "grid labels: ms under 1 s")
	map.free()


func _test_envelope_decode() -> void:
	var in_db := PackedFloat32Array([0.0, -20.0, -160.0])
	var wet_db := PackedFloat32Array([-160.0, -12.0, -30.0])
	var blob := ReverbData.build_envelope(256.0 / 48000.0, in_db, wet_db)
	_assert(blob.size() == 8 + 3 * 8, "the blob is header + 8 bytes per record")
	var decoded := ReverbData.decode_envelope(blob)
	_assert(bool(decoded["valid"]), "a hand-built blob decodes")
	_assert(is_equal_approx(decoded["record_seconds"], 256.0 / 48000.0), "record_seconds round-trips")
	_assert(decoded["in_db"] == in_db and decoded["wet_db"] == wet_db, "records round-trip")
	_assert(not bool(ReverbData.decode_envelope(PackedByteArray())["valid"]), "an empty blob is refused")
	_assert(not bool(ReverbData.decode_envelope(blob.slice(0, blob.size() - 4))["valid"]), "a short blob is refused")


func _test_format() -> void:
	_assert(ReverbData.format_value(ReverbData.P_DECAY, 2.2) == "2.20 s", "Decay text")
	_assert(ReverbData.format_value(ReverbData.P_HIGH_FREQ, 4000.0) == "4.0 kHz", "kHz above 1000")
	_assert(ReverbData.format_value(ReverbData.P_LOW_FREQ, 250.0) == "250 Hz", "Hz below 1000")
	_assert(ReverbData.format_value(ReverbData.P_LOW_MULT, 1.2) == "×1.20", "Mult text")
