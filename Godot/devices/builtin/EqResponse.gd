## Magnitude response of the built-in EQ (`sonara.builtin.eq`), computed with the same formulas as
## the engine (`Engine/src/audio/devices/eq.rs`: one `BandFilter` per band, made of Simper SVF
## stages plus an optional one-pole). The curve editor draws these, so the curve shows what the
## engine applies, cramping near Nyquist included.
##
## `Godot/tests/test_eq_response.gd` checks this file against `tests/fixtures/eq_response.json`,
## which the ignored Rust test `eq::tests::write_response_fixture` regenerates. Change a formula
## in one place and the test fails until the other follows.
##
## A band is a Dictionary: {enabled: bool, type: int, freq: Hz, gain: dB, q: float, slope: int,
## stereo: int}, with `type`, `slope` and `stereo` as enum indices.
class_name EqResponse extends RefCounted

const BAND_COUNT := 8
## Parameter IDs: band n owns n * BAND_STRIDE + offset; Output is at 80.
const BAND_STRIDE := 10
const P_ENABLED := 0
const P_TYPE := 1
const P_FREQ := 2
const P_GAIN := 3
const P_Q := 4
const P_SLOPE := 5
const P_STEREO := 6
const OUTPUT_GAIN := 80
const LISTEN_BAND := 81

enum Type { BELL, LOW_SHELF, HIGH_SHELF, LOW_CUT, HIGH_CUT, NOTCH, BAND_PASS, TILT }
const TYPE_NAMES: Array[String] = ["Bell", "Low Shelf", "High Shelf", "Low Cut", "High Cut", "Notch", "Band Pass", "Tilt"]
const SLOPE_NAMES: Array[String] = ["6 dB/oct", "12 dB/oct", "18 dB/oct", "24 dB/oct", "36 dB/oct", "48 dB/oct"]
const STEREO_NAMES: Array[String] = ["Stereo", "Left", "Right", "Mid", "Side"]

const MIN_FREQ := 20.0
const MAX_FREQ := 20000.0
const MIN_Q := 0.1
const MAX_Q := 30.0
const MAX_GAIN := 24.0

## Butterworth section Qs per slope index (6, 12, 18, 24, 36, 48 dB/oct).
const CUT_Q: Array = [
	[],
	[0.70710678],
	[1.0],
	[0.5411961, 1.3065630],
	[0.5176381, 0.70710678, 1.9318517],
	[0.5097956, 0.6013449, 0.8999762, 2.5629154],
]
const CUT_HAS_POLE: Array[bool] = [true, false, true, false, false, false]

## SVF shapes (engine `SvfShape`).
enum Shape { LOW_PASS, HIGH_PASS, BAND_PASS, NOTCH, BELL, LOW_SHELF, HIGH_SHELF }

const _MAX_FREQ_RATIO := 0.499
const _MIN_SVF_Q := 0.025


static func type_uses_gain(type: int) -> bool:
	return type == Type.BELL or type == Type.LOW_SHELF or type == Type.HIGH_SHELF or type == Type.TILT


static func type_is_cut(type: int) -> bool:
	return type == Type.LOW_CUT or type == Type.HIGH_CUT


## One SVF stage as {g, k, m0, m1, m2} (engine `SvfCoefs::new`).
static func svf_stage(shape: int, freq: float, q: float, gain_db: float, sample_rate: float) -> Dictionary:
	freq = clampf(freq, 1.0, sample_rate * _MAX_FREQ_RATIO)
	q = maxf(q, _MIN_SVF_Q)
	var base_g := tan(PI * freq / sample_rate)
	var a := pow(10.0, gain_db / 40.0)
	var k := 1.0 / q
	match shape:
		Shape.LOW_PASS:
			return {"g": base_g, "k": k, "m0": 0.0, "m1": 0.0, "m2": 1.0}
		Shape.HIGH_PASS:
			return {"g": base_g, "k": k, "m0": 1.0, "m1": -k, "m2": -1.0}
		Shape.BAND_PASS:
			return {"g": base_g, "k": k, "m0": 0.0, "m1": 1.0, "m2": 0.0}
		Shape.NOTCH:
			return {"g": base_g, "k": k, "m0": 1.0, "m1": -k, "m2": 0.0}
		Shape.BELL:
			var bell_k := 1.0 / (q * a)
			return {"g": base_g, "k": bell_k, "m0": 1.0, "m1": bell_k * (a * a - 1.0), "m2": 0.0}
		Shape.LOW_SHELF:
			return {"g": base_g / sqrt(a), "k": k, "m0": 1.0, "m1": k * (a - 1.0), "m2": a * a - 1.0}
		_:
			return {"g": base_g * sqrt(a), "k": k, "m0": a * a, "m1": k * (1.0 - a) * a, "m2": 1.0 - a * a}


## Magnitude in dB of one SVF stage at `freq` (engine `SvfCoefs::magnitude_db`).
static func svf_magnitude_db(stage: Dictionary, freq: float, sample_rate: float) -> float:
	var w: float = tan(PI * clampf(freq, 0.0, sample_rate * _MAX_FREQ_RATIO) / sample_rate) / float(stage["g"])
	var k: float = stage["k"]
	var m0: float = stage["m0"]
	var m1: float = stage["m1"]
	var m2: float = stage["m2"]
	var num_re := m0 * (1.0 - w * w) + m2
	var num_im := (m0 * k + m1) * w
	var den_re := 1.0 - w * w
	var den_im := k * w
	var mag_sq := (num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im)
	return 10.0 * log(maxf(mag_sq, 1e-30)) / log(10.0)


## Magnitude in dB of the first-order stage (engine `one_pole_magnitude_db`).
static func one_pole_magnitude_db(g: float, high: bool, freq: float, sample_rate: float) -> float:
	var w: float = tan(PI * clampf(freq, 0.0, sample_rate * _MAX_FREQ_RATIO) / sample_rate) / g
	var mag_sq := w * w / (1.0 + w * w) if high else 1.0 / (1.0 + w * w)
	return 10.0 * log(maxf(mag_sq, 1e-30)) / log(10.0)


## The stages of one band as {svf: Array[Dictionary], pole: -1 none / 0 low / 1 high, pole_g, scale}
## (engine `BandFilter::new`).
static func band_filter(type: int, freq: float, gain_db: float, q: float, slope: int, sample_rate: float) -> Dictionary:
	var stages: Array[Dictionary] = []
	var pole := -1
	var pole_g := 0.0
	var scale := 1.0
	match type:
		Type.BELL:
			stages.append(svf_stage(Shape.BELL, freq, q, gain_db, sample_rate))
		Type.LOW_SHELF:
			stages.append(svf_stage(Shape.LOW_SHELF, freq, q, gain_db, sample_rate))
		Type.HIGH_SHELF:
			stages.append(svf_stage(Shape.HIGH_SHELF, freq, q, gain_db, sample_rate))
		Type.NOTCH:
			stages.append(svf_stage(Shape.NOTCH, freq, q, 0.0, sample_rate))
		Type.BAND_PASS:
			var bp := svf_stage(Shape.BAND_PASS, freq, q, 0.0, sample_rate)
			stages.append(bp)
			scale = bp["k"]
		Type.TILT:
			stages.append(svf_stage(Shape.LOW_SHELF, freq, q, -gain_db * 0.5, sample_rate))
			stages.append(svf_stage(Shape.HIGH_SHELF, freq, q, gain_db * 0.5, sample_rate))
		_:
			var high: bool = type == Type.LOW_CUT  # a low cut is a high pass
			slope = clampi(slope, 0, CUT_Q.size() - 1)
			if CUT_HAS_POLE[slope]:
				pole = 1 if high else 0
				pole_g = tan(PI * clampf(freq, 1.0, sample_rate * _MAX_FREQ_RATIO) / sample_rate)
			var qs: Array = CUT_Q[slope]
			for i in qs.size():
				var stage_q: float = qs[i]
				if i == qs.size() - 1:
					stage_q = stage_q * q / 0.70710678
				stages.append(svf_stage(Shape.HIGH_PASS if high else Shape.LOW_PASS, freq, stage_q, 0.0, sample_rate))
	return {"svf": stages, "pole": pole, "pole_g": pole_g, "scale": scale}


## Magnitude in dB of a `band_filter` at `at_hz`.
static func filter_db(filter: Dictionary, at_hz: float, sample_rate: float) -> float:
	var db := 0.0
	var pole: int = filter["pole"]
	if pole >= 0:
		db += one_pole_magnitude_db(filter["pole_g"], pole == 1, at_hz, sample_rate)
	for stage in filter["svf"]:
		db += svf_magnitude_db(stage, at_hz, sample_rate)
	return db + 20.0 * log(float(filter["scale"])) / log(10.0)


## Magnitude in dB of one band (given as its settings) at `at_hz`.
static func band_db(type: int, freq: float, gain_db: float, q: float, slope: int, sample_rate: float, at_hz: float) -> float:
	return filter_db(band_filter(type, freq, gain_db, q, slope, sample_rate), at_hz, sample_rate)


## Magnitude in dB of each enabled band at every frequency in `freqs`: one PackedFloat32Array per
## band (empty for a disabled band).
static func band_curves(bands: Array, freqs: PackedFloat32Array, sample_rate: float) -> Array[PackedFloat32Array]:
	var curves: Array[PackedFloat32Array] = []
	for band: Dictionary in bands:
		var curve := PackedFloat32Array()
		if band.get("enabled", false):
			var filter := band_filter(band["type"], band["freq"], band["gain"], band["q"], band["slope"], sample_rate)
			curve.resize(freqs.size())
			for i in freqs.size():
				curve[i] = filter_db(filter, freqs[i], sample_rate)
		curves.append(curve)
	return curves


## The whole EQ: the sum of the enabled bands' curves plus `output_gain_db`.
static func total_curve(curves: Array[PackedFloat32Array], point_count: int, output_gain_db := 0.0) -> PackedFloat32Array:
	var total := PackedFloat32Array()
	total.resize(point_count)
	for i in point_count:
		total[i] = output_gain_db
	for curve in curves:
		if curve.size() == point_count:
			for i in point_count:
				total[i] += curve[i]
	return total


## `count` log-spaced frequencies from `lo` to `hi`.
static func log_frequencies(count: int, lo := MIN_FREQ, hi := MAX_FREQ) -> PackedFloat32Array:
	var freqs := PackedFloat32Array()
	freqs.resize(count)
	for i in count:
		freqs[i] = lo * pow(hi / lo, float(i) / float(maxi(count - 1, 1)))
	return freqs


## A fresh band Dictionary with the engine's defaults for band `index` (0-7).
static func default_band(index: int) -> Dictionary:
	const FREQS := [50.0, 110.0, 240.0, 520.0, 1150.0, 2500.0, 5500.0, 12000.0]
	var type := Type.LOW_CUT if index == 0 else (Type.HIGH_CUT if index == BAND_COUNT - 1 else Type.BELL)
	return {"enabled": false, "type": type, "freq": FREQS[index], "gain": 0.0, "q": 0.71, "slope": 1, "stereo": 0}
