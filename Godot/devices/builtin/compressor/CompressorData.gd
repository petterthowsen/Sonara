@tool
## Compressor constants, the static curve and the `"dynamics"` blob decoder, shared by the
## panel view (`CompressorDefaultView`) and the tests.
##
## The curve repeats the engine's gain computer (`Engine/src/audio/devices/compressor.rs`,
## `gain_reduction_db`) so the drawn transfer curve is exactly what the engine applies.
class_name CompressorData extends RefCounted

## Parameter IDs (see `compressor.rs`).
const P_THRESHOLD := 0
const P_RATIO := 1
const P_KNEE := 2
const P_RANGE := 3
const P_ATTACK := 10
const P_RELEASE := 11
const P_AUTO_RELEASE := 12
const P_STYLE := 20
const P_DETECTION := 21
const P_STEREO_LINK := 22
const P_CHANNELS := 23
const P_SC_LOW_CUT := 24
const P_SC_LISTEN := 25
const P_MAKEUP := 30
const P_AUTO_GAIN := 31
const P_MIX := 32

const STYLE_NAMES: Array[String] = ["Clean", "Glue", "Punch", "Opto"]
const DETECTION_NAMES: Array[String] = ["Peak", "RMS"]
const CHANNELS_NAMES: Array[String] = ["Stereo", "Mid", "Side"]

## Ratio the knob's top of travel reaches; the label reads infinity there.
const RATIO_MAX := 30.0

## The transfer curve's axes: input −60..0 dBFS, output −60..+24 dB.
const MIN_DB := -60.0
const MAX_DB := 24.0

## Frames per `"dynamics"` record (engine `RECORD_FRAMES`).
const RECORD_FRAMES := 64
## Floats in one record: in_peak_db, out_peak_db, gr_db.
const RECORD_VALUES := 3
## The meter summary after the records, in blob order (engine `MeterWindow::summary`), all dB.
const SUMMARY_KEYS: Array[String] = [
	"in_peak_l", "in_peak_r", "out_peak_l", "out_peak_r",
	"in_rms_l", "in_rms_r", "out_rms_l", "out_rms_r",
	"detector_db", "gr_max_db",
]


## Gain reduction in dB of the soft-knee static curve (Giannoulis/Massberg/Reiss).
static func gain_reduction_db(
	level_db: float,
	threshold_db: float,
	ratio: float,
	knee_db: float,
	range_db: float
) -> float:
	var r := maxf(ratio, 1.0)
	var over := 2.0 * (level_db - threshold_db)
	var out_db: float
	if knee_db <= 0.0:
		out_db = level_db if over < 0.0 else threshold_db + (level_db - threshold_db) / r
	elif over < -knee_db:
		out_db = level_db
	elif over <= knee_db:
		var x := level_db - threshold_db + knee_db * 0.5
		out_db = level_db + (1.0 / r - 1.0) * x * x / (2.0 * knee_db)
	else:
		out_db = threshold_db + (level_db - threshold_db) / r
	return clampf(level_db - out_db, 0.0, maxf(range_db, 0.0))


## Output level in dB for an input level, the curve the transfer view draws.
static func static_curve_db(
	level_db: float,
	threshold_db: float,
	ratio: float,
	knee_db: float,
	range_db: float
) -> float:
	return level_db - gain_reduction_db(level_db, threshold_db, ratio, knee_db, range_db)


## Auto Gain makes up half the reduction at this level (engine `AUTO_GAIN_REFERENCE_DB`).
const AUTO_GAIN_REFERENCE_DB := -6.0


## The makeup Auto Gain applies in place of the manual Makeup, as the engine computes it.
static func auto_makeup_db(threshold_db: float, ratio: float, knee_db: float, range_db: float) -> float:
	return 0.5 * gain_reduction_db(AUTO_GAIN_REFERENCE_DB, threshold_db, ratio, knee_db, range_db)


## "4:1", "1:1", or "∞:1" at the top of the Ratio knob.
static func format_ratio(ratio: float) -> String:
	if ratio >= RATIO_MAX - 0.5:
		return "∞:1"
	return "%.1f:1" % ratio


## Decode a `"dynamics"` blob: `u32 count`, `count` records of three little-endian f32s, then
## the meter summary of `SUMMARY_KEYS.size()` f32s. Returns {count, in_peak_db, out_peak_db,
## gr_db, summary} with one entry per record. `summary` maps `SUMMARY_KEYS` to dB, and is empty
## when the blob ends after the records (an older engine).
static func decode(blob: PackedByteArray) -> Dictionary:
	var empty := {
		"count": 0,
		"in_peak_db": PackedFloat32Array(),
		"out_peak_db": PackedFloat32Array(),
		"gr_db": PackedFloat32Array(),
		"summary": {},
	}
	if blob.size() < 4:
		return empty
	var count := int(blob.decode_u32(0))
	if blob.size() < 4 + count * RECORD_VALUES * 4:
		return empty
	var input := PackedFloat32Array()
	var output := PackedFloat32Array()
	var reduction := PackedFloat32Array()
	input.resize(count)
	output.resize(count)
	reduction.resize(count)
	for i in count:
		var base := 4 + i * RECORD_VALUES * 4
		input[i] = blob.decode_float(base)
		output[i] = blob.decode_float(base + 4)
		reduction[i] = blob.decode_float(base + 8)
	var summary := {}
	var summary_at := 4 + count * RECORD_VALUES * 4
	if blob.size() >= summary_at + SUMMARY_KEYS.size() * 4:
		for k in SUMMARY_KEYS.size():
			summary[SUMMARY_KEYS[k]] = blob.decode_float(summary_at + k * 4)
	return {
		"count": count, "in_peak_db": input, "out_peak_db": output, "gr_db": reduction,
		"summary": summary,
	}
