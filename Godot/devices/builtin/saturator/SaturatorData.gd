@tool
## Saturator constants and the `"curve"` data-stream decoder, shared by the panel view
## (`SaturatorDefaultView`), the curve drawing (`SaturatorCurve`) and the tests.
##
## The record layout is frozen and identical in byte encoding to the compressor's
## `"dynamics"` record (see `Engine/src/audio/devices/effects/saturator.rs`, `BYTES`):
## 146 little-endian f32s —
##   0: effective_drive_db   the drive the engine actually applied this block
##   1: env_db               the pre-shaper envelope level, dBFS
##   2..129: 128 transfer-curve points, evenly spaced over input -1…+1, output = the
##           shaper's own output at the current static settings
##   130..145: 16 harmonic magnitudes in dB (sine at the current operating level)
class_name SaturatorData extends RefCounted

## Parameter IDs (see `saturator.rs`, blocks of ten).
const P_TYPE := 0
const P_DRIVE := 1
const P_BIAS := 2
const P_LEVEL_DEPEND := 3
const P_INPUT := 4
const P_QUALITY := 5
const P_PRE_HPF := 10
const P_POST_LPF := 11
const P_TILT := 12
const P_HF_LOSS := 20
const P_HEAD_BUMP := 21
const P_SQUASH := 22
const P_WOW := 23
const P_NOISE := 24
const P_FLUTTER := 25
const P_DRIFT := 26
const P_MIX := 30
const P_OUTPUT := 31
const P_AUTO_GAIN := 32

const TYPE_NAMES: Array[String] = ["Soft", "Tube", "Tape", "Hard"]
const QUALITY_NAMES: Array[String] = ["1x", "2x", "4x"]

## Type whose tape-only stages are audible (HF Loss, Head Bump, Squash, Wow, Flutter, Drift,
## Noise).
const TYPE_TAPE := 2

## The transfer curve's 128 points span input -1…+1.
const CURVE_POINTS := 128
const HARMONIC_COUNT := 16
## Floats in one record: 2 header + 128 curve + 16 harmonics.
const RECORD_VALUES := 2 + CURVE_POINTS + HARMONIC_COUNT
## Bytes in one record.
const BYTES := RECORD_VALUES * 4

## dB floor used when mapping harmonic magnitudes to bar heights.
const HARMONIC_FLOOR_DB := -90.0


## Decode a `"curve"` blob. Returns a dictionary with `valid`, `effective_drive_db`, `env_db`,
## `curve` (128 f32 over input -1…+1) and `harmonics` (16 dB values). An invalid blob decodes
## to `valid = false` and empty arrays.
static func decode(blob: PackedByteArray) -> Dictionary:
	var empty := {
		"valid": false,
		"effective_drive_db": 0.0,
		"env_db": NAN,
		"curve": PackedFloat32Array(),
		"harmonics": PackedFloat32Array(),
	}
	if blob.size() < BYTES:
		return empty
	var curve := PackedFloat32Array()
	curve.resize(CURVE_POINTS)
	var harmonics := PackedFloat32Array()
	harmonics.resize(HARMONIC_COUNT)
	for i in CURVE_POINTS:
		curve[i] = blob.decode_float(8 + i * 4)
	for i in HARMONIC_COUNT:
		harmonics[i] = blob.decode_float(8 + CURVE_POINTS * 4 + i * 4)
	return {
		"valid": true,
		"effective_drive_db": blob.decode_float(0),
		"env_db": blob.decode_float(4),
		"curve": curve,
		"harmonics": harmonics,
	}


## Build a valid record by hand (the tests, and the view's fallback for engines without the
## stream yet).
static func build_record(
	effective_drive_db: float,
	env_db: float,
	curve: PackedFloat32Array,
	harmonics: PackedFloat32Array
) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(BYTES)
	blob.encode_float(0, effective_drive_db)
	blob.encode_float(4, env_db)
	for i in CURVE_POINTS:
		blob.encode_float(8 + i * 4, curve[i] if i < curve.size() else 0.0)
	for i in HARMONIC_COUNT:
		blob.encode_float(8 + CURVE_POINTS * 4 + i * 4, harmonics[i] if i < harmonics.size() else HARMONIC_FLOOR_DB)
	return blob


## The curve point's input for index `i`, evenly spread over -1…+1.
static func curve_input(i: int) -> float:
	return -1.0 + 2.0 * float(i) / float(CURVE_POINTS - 1)


## The shaper output the engine would produce at `input` (-1…+1) with drive `drive_db`,
## replicating `dsp/saturate.rs`'s `drive`/`soft_clip` so a hand-built fallback matches.
static func soft_curve_at(input: float, drive_db: float) -> float:
	var gain := pow(10.0, drive_db / 20.0)
	var x: float = clampf(input * gain, -3.0, 3.0)
	return x / (1.0 + absf(x))
