# EqResponse.gd against the engine: `tests/fixtures/eq_response.json` holds magnitudes computed by
# the Rust EQ (regenerate with `cargo test --lib eq::tests::write_response_fixture -- --ignored`
# from Engine/). Every band setting must agree within 0.05 dB at every frequency.
# Run: godot --headless --path Godot -s tests/test_eq_response.gd -- --test
extends TestBase

const FIXTURE := "res://tests/fixtures/eq_response.json"
const TOLERANCE_DB := 0.05


func suite_name() -> String:
	return "EQ response vs engine"


func run_tests() -> void:
	var file := FileAccess.open(FIXTURE, FileAccess.READ)
	_assert(file != null, "fixture exists (run the ignored Rust test to create it)")
	if file == null:
		return
	var data: Dictionary = JSON.parse_string(file.get_as_text())
	var freqs: Array = data["freqs"]
	var cases: Array = data["cases"]
	_assert(cases.size() >= 24 and freqs.size() >= 32, "fixture has %d cases of %d points" % [cases.size(), freqs.size()])

	var worst := 0.0
	var worst_case := ""
	var failures := 0
	for c: Dictionary in cases:
		var rate: float = c["sample_rate"]
		var db: Array = c["db"]
		var case_worst := 0.0
		for i in freqs.size():
			var got := EqResponse.band_db(int(c["type"]), c["freq"], c["gain"], c["q"], int(c["slope"]), rate, freqs[i])
			var diff := absf(got - float(db[i]))
			case_worst = maxf(case_worst, diff)
		if case_worst > worst:
			worst = case_worst
			worst_case = "%s %s Hz gain %s q %s slope %s at %s Hz" % [
				EqResponse.TYPE_NAMES[int(c["type"])], c["freq"], c["gain"], c["q"], c["slope"], rate]
		if case_worst > TOLERANCE_DB:
			failures += 1
			print("  off by %.4f dB: %s type %d freq %s gain %s q %s slope %s rate %s" % [
				case_worst, EqResponse.TYPE_NAMES[int(c["type"])], int(c["type"]), c["freq"], c["gain"], c["q"], c["slope"], rate])
	_assert(failures == 0, "all %d cases within %.2f dB of the engine (worst %.4f dB: %s)" % [cases.size(), TOLERANCE_DB, worst, worst_case])
	_test_total_curve()


func _test_total_curve() -> void:
	var bands: Array = []
	for i in EqResponse.BAND_COUNT:
		bands.append(EqResponse.default_band(i))
	bands[2]["enabled"] = true
	bands[2]["gain"] = 6.0
	var freqs := EqResponse.log_frequencies(64)
	var curves := EqResponse.band_curves(bands, freqs, 48000.0)
	_assert(curves[0].is_empty() and curves[2].size() == 64, "disabled bands have no curve")
	var total := EqResponse.total_curve(curves, 64, -3.0)
	var peak := EqResponse.band_db(EqResponse.Type.BELL, 240.0, 6.0, 0.71, 1, 48000.0, 240.0)
	_assert(absf(peak - 6.0) < 0.01, "a +6 dB bell reads +6 dB at its centre")
	var mid := total[0] + 3.0
	_assert(absf(mid) < 0.5, "output gain is added to the curve and a bell leaves the far end flat (got %s)" % mid)
