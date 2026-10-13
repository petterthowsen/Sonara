# VelocityRemap.gd
# Pure maths for the MIDI clip velocity adjustment: statistics of a velocity set, its histogram,
# and the linear remap from the current range into a new one. Velocities here are 7-bit values
# (1-127, as floats) because that is what the user sees; MidiNoteData stores them normalized.
class_name VelocityRemap extends RefCounted

const MIN_V := 1.0
const MAX_V := 127.0


## Normalized velocity to the 7-bit scale as a float.
static func to_v7(velocity: float) -> float:
	return velocity * 127.0


## Statistics of 7-bit `values`: {count, min, max, mean, median}. All zero for an empty set.
static func stats(values: Array) -> Dictionary:
	var out := {"count": values.size(), "min": 0.0, "max": 0.0, "mean": 0.0, "median": 0.0}
	if values.is_empty():
		return out
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for v: float in sorted:
		total += v
	var n := sorted.size()
	out["min"] = sorted[0]
	out["max"] = sorted[n - 1]
	out["mean"] = total / n
	out["median"] = sorted[n / 2] if n % 2 == 1 else (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5
	return out


## Counts of 7-bit `values` in `bins` equal slices of the 1-127 range.
static func histogram(values: Array, bins: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(bins)
	for v: float in values:
		var t := (v - MIN_V) / (MAX_V - MIN_V)
		out[clampi(int(t * bins), 0, bins - 1)] += 1
	return out


## Map `v` linearly from [src_lo, src_hi] to [dst_lo, dst_hi]. A set whose velocities are all the
## same (empty source span) lands in the middle of the target range. The result is rounded to a
## whole 7-bit step and kept within 1-127, so squashing at an edge never wraps or goes silent.
static func remap(v: float, src_lo: float, src_hi: float, dst_lo: float, dst_hi: float) -> float:
	var lo := minf(dst_lo, dst_hi)
	var hi := maxf(dst_lo, dst_hi)
	var t := 0.5
	if src_hi - src_lo > 0.0001:
		t = (v - src_lo) / (src_hi - src_lo)
	return clampf(roundf(lerpf(lo, hi, t)), MIN_V, MAX_V)


## Normalized velocity for a 7-bit value.
static func to_normalized(v7: float) -> float:
	return MidiNoteData.from_midi_velocity(roundi(v7))
