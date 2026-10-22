@tool
## Reverb constants, the decay-map model and the `"envelope"` stream decoder (spec 050), shared by
## the panel view (`ReverbDefaultView`), the drawn controls (`ReverbDecayMap`,
## `ReverbEnvelopeStrip`) and the tests. Pure static functions, no node dependencies.
##
## The decay map is computed here, not measured: this file MIRRORS the engine's decay math in
## `Engine/src/audio/devices/effects/reverb.rs` -- the `Absorbent` shelves (`shelf_db`, two
## cascaded TPT one-pole sections per shelf), the early-reflection tables (`EARLY_ROOM`,
## `EARLY_HALL`, `EARLY_PLATE`, `EARLY_RMS_GAIN`, `early_norms`), `SIZE_MIN_SCALE` /
## `SIZE_MAX_SCALE` and the tone filters. Keep the two in step.
##
## A values dictionary maps parameter id -> real value (see `DEFAULTS`).
##
## `"envelope"` blob (little-endian): `u32 count`, `f32 record_seconds`, then `count` records of
## `f32 in_peak_db, f32 wet_peak_db` (the engine floors at -160 dB).
class_name ReverbData extends RefCounted

# Parameter ids (reverb.rs).
const P_ALGORITHM := 0
const P_SIZE := 1
const P_DECAY := 2
const P_PREDELAY := 3
const P_DIFFUSION := 4
const P_EARLY := 5
const P_LOW_MULT := 10
const P_LOW_FREQ := 11
const P_HIGH_MULT := 12
const P_HIGH_FREQ := 13
const P_RATE := 20
const P_DEPTH := 21
const P_LOW_CUT := 30
const P_HIGH_CUT := 31
const P_DUCKING := 40
const P_FREEZE := 41
const P_WIDTH := 50
const P_MIX := 51

const ALGORITHM_NAMES: Array[String] = ["Room", "Hall", "Plate"]
const SLOT_TANK_FX := "tank_fx"
const SLOT_WET_FX := "wet_fx"

## The engine's default real values.
const DEFAULTS := {
	P_ALGORITHM: 1.0, P_SIZE: 50.0, P_DECAY: 2.2, P_PREDELAY: 20.0, P_DIFFUSION: 80.0, P_EARLY: 50.0,
	P_LOW_MULT: 1.2, P_LOW_FREQ: 250.0, P_HIGH_MULT: 0.5, P_HIGH_FREQ: 4000.0,
	P_RATE: 0.8, P_DEPTH: 30.0, P_LOW_CUT: 80.0, P_HIGH_CUT: 14000.0,
	P_DUCKING: 0.0, P_FREEZE: 0.0, P_WIDTH: 100.0, P_MIX: 30.0,
}

## Real value ranges of the parameters the map edits (min, max); all of them are logarithmic
## except Pre-Delay (a skewed 0..500 ms), which the map treats as linear.
const RANGES := {
	P_DECAY: Vector2(0.1, 30.0),
	P_PREDELAY: Vector2(0.0, 500.0),
	P_LOW_MULT: Vector2(0.25, 2.0),
	P_LOW_FREQ: Vector2(50.0, 1000.0),
	P_HIGH_MULT: Vector2(0.1, 1.0),
	P_HIGH_FREQ: Vector2(1000.0, 20000.0),
	P_LOW_CUT: Vector2(20.0, 1000.0),
	P_HIGH_CUT: Vector2(1000.0, 20000.0),
}

## reverb.rs `SIZE_MIN_SCALE` / `SIZE_MAX_SCALE`: early tap times scale by
## `SIZE_MIN_SCALE + size * (SIZE_MAX_SCALE - SIZE_MIN_SCALE)`.
const SIZE_MIN_SCALE := 0.5
const SIZE_MAX_SCALE := 1.5
## reverb.rs `EARLY_RMS_GAIN`.
const EARLY_RMS_GAIN := 1.25

## The line length (s) the engine's shelf gains are evaluated at. On the shelf plateaus the band
## T60 is exactly Decay x Mult whatever the length; in between it follows the engine's skirts.
const REF_LINE_S := 0.05
## Sample rate the filter shapes are evaluated at (only the skirts near Nyquist depend on it).
const REF_SAMPLE_RATE := 48000.0

const FREQ_MIN := 20.0
const FREQ_MAX := 20000.0
## Floor of every dB value the model returns.
const FLOOR_DB := -120.0

## Onset estimate (`tail_build_s`, `early_blur_s`): the tail builds over MIN + (1 - Diffusion)
## x RANGE seconds (times the Size scale), and Diffusion 100 % smears each early tap over
## +/- EARLY_BLUR_MAX_S.
const TAIL_BUILD_MIN_S := 0.015
const TAIL_BUILD_RANGE_S := 0.12
const EARLY_BLUR_MAX_S := 0.012

## The time spans (s) the map snaps to.
const SPAN_STEPS: Array[float] = [0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 10.0, 15.0, 20.0, 30.0, 45.0, 60.0]
## Headroom over the longest predicted tail.
const SPAN_HEADROOM := 1.1

# reverb.rs `EARLY_ROOM` / `EARLY_HALL` / `EARLY_PLATE`: per algorithm, the left and right
# channel's taps as [ms at Size 50 %, gain].
const EARLY_TAPS := [
	[ # Room
		[[3.2, 0.80], [5.7, 0.60], [8.3, 0.75], [11.1, 0.50], [14.7, 0.65], [18.3, 0.45],
			[23.1, 0.50], [28.7, 0.35], [34.1, 0.40], [41.3, 0.30]],
		[[4.1, 0.70], [6.9, 0.55], [9.7, 0.50], [12.9, 0.70], [16.3, 0.60], [20.9, 0.55],
			[25.3, 0.40], [31.3, 0.45], [37.9, 0.30], [44.3, 0.35]],
	],
	[ # Hall
		[[17.3, 0.60], [23.7, 0.45], [31.1, 0.55], [41.7, 0.40], [53.3, 0.50], [67.7, 0.35],
			[83.1, 0.40]],
		[[19.9, 0.35], [27.1, 0.55], [35.9, 0.30], [47.3, 0.50], [59.9, 0.35], [73.1, 0.45],
			[89.3, 0.30]],
	],
	[ # Plate
		[[11.3, 0.50], [19.7, 0.40], [29.3, 0.45], [43.1, 0.35], [61.7, 0.30]],
		[[13.7, 0.40], [23.3, 0.50], [34.9, 0.35], [49.3, 0.45], [67.1, 0.35]],
	],
]


# ============================================================================
# VALUES
# ============================================================================

## A values dictionary from a bound device (missing parameters keep their defaults).
static func values_from_device(device: Object) -> Dictionary:
	var values := DEFAULTS.duplicate()
	if device == null:
		return values
	for id in DEFAULTS:
		if device.get_parameter(id) != null:
			values[id] = device.get_parameter_real(id)
	return values


static func is_frozen(values: Dictionary) -> bool:
	return float(values.get(P_FREEZE, 0.0)) >= 0.5


static func _v(values: Dictionary, id: int) -> float:
	return float(values.get(id, DEFAULTS[id]))


## Text a knob (and the map's handle tooltip) shows for parameter `id`.
static func format_value(id: int, value: float) -> String:
	match id:
		P_DECAY:
			return "%.2f s" % value
		P_LOW_MULT, P_HIGH_MULT:
			return "×%.2f" % value
		P_LOW_FREQ, P_HIGH_FREQ, P_LOW_CUT, P_HIGH_CUT:
			return "%.1f kHz" % (value / 1000.0) if value >= 1000.0 else "%.0f Hz" % value
		P_PREDELAY:
			return "%.0f ms" % value
		P_SIZE, P_DIFFUSION, P_EARLY, P_DEPTH, P_DUCKING, P_WIDTH, P_MIX:
			return "%d %%" % roundi(value)
		P_RATE:
			return "%.2f Hz" % value
		P_FREEZE:
			return "On" if value >= 0.5 else "Off"
		P_ALGORITHM:
			return ALGORITHM_NAMES[clampi(roundi(value), 0, 2)]
	return "%.2f" % value


# ============================================================================
# DECAY MODEL
# ============================================================================

## reverb.rs `shelf_db`: absorbent shelf gain in dB for a band whose T60 is `t60 * mult`.
static func _shelf_db(delay_s: float, t60: float, mult: float) -> float:
	return (60.0 * delay_s / maxf(t60, 1e-4)) * ((mult - 1.0) / maxf(mult, 1e-4))


## |1 + j a|^2 helpers for the TPT one-pole low-pass `LP(f) = 1 / (1 + j * tan(pi f / fs) / g)`.
## Returns [re, im] of LP at `freq` for a section with cutoff `cutoff`.
static func _one_pole_lp(freq: float, cutoff: float, sr: float) -> Vector2:
	var g := tan(PI * clampf(cutoff, 1.0, sr * 0.499) / sr)
	var w := tan(PI * clampf(freq, 1.0, sr * 0.499) / sr)
	var a := w / g
	var den := 1.0 + a * a
	return Vector2(1.0 / den, -a / den)


## Squared magnitude of `re + j im`.
static func _mag2(c: Vector2) -> float:
	return c.x * c.x + c.y * c.y


## The Decay EQ's gain in dB at `freq` for a reference line length: two cascaded low-shelf
## sections at Low Freq and two high-shelf sections at High Freq (reverb.rs `Absorbent`).
static func shelf_gain_db(freq: float, values: Dictionary, sr: float = REF_SAMPLE_RATE) -> float:
	var decay := _v(values, P_DECAY)
	var low_g := pow(10.0, _shelf_db(REF_LINE_S, decay, _v(values, P_LOW_MULT)) * 0.5 / 20.0)
	var high_g := pow(10.0, _shelf_db(REF_LINE_S, decay, _v(values, P_HIGH_MULT)) * 0.5 / 20.0)
	var low_lp := _one_pole_lp(freq, _v(values, P_LOW_FREQ), sr)
	var high_lp := _one_pole_lp(freq, _v(values, P_HIGH_FREQ), sr)
	# Low shelf section: 1 + (G - 1) LP. High shelf section: G + (1 - G) LP.
	var low_h := Vector2(1.0 + (low_g - 1.0) * low_lp.x, (low_g - 1.0) * low_lp.y)
	var high_h := Vector2(high_g + (1.0 - high_g) * high_lp.x, (1.0 - high_g) * high_lp.y)
	var mag2 := _mag2(low_h) * _mag2(low_h) * _mag2(high_h) * _mag2(high_h)
	return 10.0 * log(maxf(mag2, 1e-30)) / log(10.0)


## T60 in seconds of the band at `freq`, ignoring Freeze.
static func band_t60_raw(freq: float, values: Dictionary, sr: float = REF_SAMPLE_RATE) -> float:
	var decay := _v(values, P_DECAY)
	var loss := 60.0 * REF_LINE_S / maxf(decay, 1e-4)
	return 60.0 * REF_LINE_S / maxf(loss - shelf_gain_db(freq, values, sr), 1e-6)


## T60 in seconds of the band at `freq`; infinite while Freeze is on.
static func band_t60(freq: float, values: Dictionary, sr: float = REF_SAMPLE_RATE) -> float:
	if is_frozen(values):
		return INF
	return band_t60_raw(freq, values, sr)


## The time (s from the input) the -60 dB contour reaches at `freq`: Pre-Delay plus the band T60.
static func contour_time(freq: float, values: Dictionary) -> float:
	return _v(values, P_PREDELAY) * 0.001 + band_t60(freq, values)


## Level in dB of the wet tone filters (12 dB/oct Butterworth high-pass at Low Cut and low-pass
## at High Cut) at `freq`.
static func cut_db(freq: float, values: Dictionary) -> float:
	var hp := pow(freq / maxf(_v(values, P_LOW_CUT), 1.0), 4.0)
	var lp := pow(freq / maxf(_v(values, P_HIGH_CUT), 1.0), 4.0)
	var mag2 := (hp / (1.0 + hp)) * (1.0 / (1.0 + lp))
	return maxf(10.0 * log(maxf(mag2, 1e-30)) / log(10.0), FLOOR_DB)


## The tail's level in dB at time `t` (s) and frequency `freq`: nothing before Pre-Delay, then
## -60 dB per band T60, plus the tone filters.
static func level_db(t: float, freq: float, values: Dictionary) -> float:
	var pre := _v(values, P_PREDELAY) * 0.001
	if t < pre:
		return FLOOR_DB
	var t60 := band_t60(freq, values)
	var decay_db := 0.0 if is_inf(t60) else -60.0 * (t - pre) / t60
	return maxf(decay_db + cut_db(freq, values), FLOOR_DB)


## Visual estimate (not mirrored from the engine) of how long the late tail takes to build to
## full density after Pre-Delay. The diffuser smears the input over its ~30 ms of all-passes
## before the tank, so a high Diffusion gives a dense onset at once; a low one lets discrete
## echoes through and the tail fills in over a few line lengths.
static func tail_build_s(values: Dictionary) -> float:
	var diffusion := clampf(_v(values, P_DIFFUSION) / 100.0, 0.0, 1.0)
	var scale := SIZE_MIN_SCALE + (_v(values, P_SIZE) / 100.0) * (SIZE_MAX_SCALE - SIZE_MIN_SCALE)
	return (TAIL_BUILD_MIN_S + (1.0 - diffusion) * TAIL_BUILD_RANGE_S) * scale


## The tail's density at `t` (s from the input), 0 before Pre-Delay rising to 1 over
## `tail_build_s` (a smoothstep). Multiplies the drawn opacity; the dB model is unchanged.
static func tail_onset(t: float, values: Dictionary) -> float:
	var since := t - _v(values, P_PREDELAY) * 0.001
	if since <= 0.0:
		return 0.0
	return smoothstep(0.0, tail_build_s(values), since)


## How far (s) Diffusion smears each early reflection on the map, a visual estimate: 0 at
## Diffusion 0, `EARLY_BLUR_MAX_S` at 100 %.
static func early_blur_s(values: Dictionary) -> float:
	return clampf(_v(values, P_DIFFUSION) / 100.0, 0.0, 1.0) * EARLY_BLUR_MAX_S


## The early reflections the current Algorithm, Size, Pre-Delay and Early produce: an array of
## `{t: seconds from the input, db: level, channel: 0|1}`, sorted by time. Early 0 gives none.
static func early_ticks(values: Dictionary) -> Array[Dictionary]:
	var ticks: Array[Dictionary] = []
	var early := _v(values, P_EARLY) / 100.0
	if early <= 0.0:
		return ticks
	var algo := clampi(roundi(_v(values, P_ALGORITHM)), 0, 2)
	var scale := SIZE_MIN_SCALE + (_v(values, P_SIZE) / 100.0) * (SIZE_MAX_SCALE - SIZE_MIN_SCALE)
	var pre := _v(values, P_PREDELAY) * 0.001
	for channel in 2:
		var taps: Array = EARLY_TAPS[algo][channel]
		var energy := 0.0
		for tap in taps:
			energy += float(tap[1]) * float(tap[1])
		var norm := EARLY_RMS_GAIN / sqrt(energy)
		for tap in taps:
			var gain := float(tap[1]) * norm * early
			ticks.append({
				"t": pre + float(tap[0]) * 0.001 * scale,
				"db": maxf(20.0 * log(gain) / log(10.0), FLOOR_DB),
				"channel": channel,
			})
	ticks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["t"] < b["t"])
	return ticks


## The longest band tail, Freeze ignored (the span keeps its last unfrozen size while frozen).
static func longest_tail(values: Dictionary) -> float:
	var longest := 0.0
	var steps := 32
	for i in steps + 1:
		var f := FREQ_MIN * pow(FREQ_MAX / FREQ_MIN, float(i) / steps)
		longest = maxf(longest, band_t60_raw(f, values))
	return longest


## The time span (s) the map should show: Pre-Delay plus the longest band tail with headroom,
## snapped up to the next readable step.
static func span_target(values: Dictionary) -> float:
	var needed := (_v(values, P_PREDELAY) * 0.001 + longest_tail(values)) * SPAN_HEADROOM
	for step in SPAN_STEPS:
		if step >= needed:
			return step
	return SPAN_STEPS[SPAN_STEPS.size() - 1]


# ============================================================================
# ENVELOPE STREAM
# ============================================================================

## Decode an `"envelope"` blob: `{valid, record_seconds, in_db, wet_db}` (the dB arrays are
## PackedFloat32Array, one entry per record). A short or malformed blob is invalid.
static func decode_envelope(blob: PackedByteArray) -> Dictionary:
	var result := {
		"valid": false,
		"record_seconds": 0.0,
		"in_db": PackedFloat32Array(),
		"wet_db": PackedFloat32Array(),
	}
	if blob.size() < 8:
		return result
	var count := blob.decode_u32(0)
	if blob.size() != 8 + count * 8:
		return result
	var seconds := blob.decode_float(4)
	if not (seconds > 0.0) or is_inf(seconds):
		return result
	var in_db := PackedFloat32Array()
	var wet_db := PackedFloat32Array()
	in_db.resize(count)
	wet_db.resize(count)
	for i in count:
		in_db[i] = blob.decode_float(8 + i * 8)
		wet_db[i] = blob.decode_float(12 + i * 8)
	result["valid"] = true
	result["record_seconds"] = seconds
	result["in_db"] = in_db
	result["wet_db"] = wet_db
	return result


## Build a blob (tests and the editor preview).
static func build_envelope(record_seconds: float, in_db: PackedFloat32Array, wet_db: PackedFloat32Array) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(8 + in_db.size() * 8)
	blob.encode_u32(0, in_db.size())
	blob.encode_float(4, record_seconds)
	for i in in_db.size():
		blob.encode_float(8 + i * 8, in_db[i])
		blob.encode_float(12 + i * 8, wet_db[i])
	return blob
