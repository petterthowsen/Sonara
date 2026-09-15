# ClipTextTime.gd
# Musical time for clip text: bar.beat.tick, grid resolution, note durations.
class_name ClipTextTime extends RefCounted


## Ticks in one bar. Beats are 1/denominator notes (see GridHelper.bar_ticks).
static func ticks_per_bar(ppq: int, numerator: int, denominator: int = 4) -> int:
	return GridHelper.bar_ticks(ppq, numerator, denominator)


## Ticks per grid step for a `1/N` resolution (N subdivisions of a whole note).
static func ticks_per_step(ppq: int, res_denom: int) -> int:
	var denom := maxi(1, res_denom)
	return maxi(1, int(maxi(1, ppq) * 4 / denom))


## Grid steps in one beat at this resolution.
static func steps_per_beat(ppq: int, res_denom: int, denominator: int = 4) -> int:
	return maxi(1, GridHelper.beat_ticks(ppq, denominator) / ticks_per_step(ppq, res_denom))


## Parse `1/16` / `16` into the resolution denominator. Defaults to 16.
static func parse_res(res: String) -> int:
	var s := res.strip_edges()
	if s.is_empty():
		return 16
	if s.begins_with("1/"):
		s = s.substr(2)
	var n := s.to_int()
	return n if n > 0 else 16


## Format a resolution denominator as `1/N`.
static func format_res(res_denom: int) -> String:
	return "1/%d" % maxi(1, res_denom)


## Clip-local bar.beat.tick (1-based bar/beat, tick within the beat).
static func ticks_to_bbt(ticks: int, ppq: int, numerator: int, denominator: int = 4) -> Dictionary:
	var tpb := ticks_per_bar(ppq, numerator, denominator)
	var beat_t := GridHelper.beat_ticks(ppq, denominator)
	var t := maxi(0, ticks)
	@warning_ignore("integer_division")
	var bar := t / tpb
	var rem := t % tpb
	@warning_ignore("integer_division")
	var beat := rem / beat_t
	var tick := rem % beat_t
	return {"bar": bar + 1, "beat": beat + 1, "tick": tick}


## Inverse of ticks_to_bbt. Bar and beat are 1-based.
static func bbt_to_ticks(bar: int, beat: int, tick: int, ppq: int, numerator: int, denominator: int = 4) -> int:
	var tpb := ticks_per_bar(ppq, numerator, denominator)
	var beat_t := GridHelper.beat_ticks(ppq, denominator)
	var b := maxi(1, bar)
	var be := maxi(1, beat)
	return (b - 1) * tpb + (be - 1) * beat_t + maxi(0, tick)


## `5.1.000` (bar.beat.tick). Tick is zero-padded to 3.
static func format_bbt(ticks: int, ppq: int, numerator: int, denominator: int = 4) -> String:
	var bbt := ticks_to_bbt(ticks, ppq, numerator, denominator)
	return "%d.%d.%03d" % [bbt.bar, bbt.beat, bbt.tick]


## Parse `5.1.000`, `5:1:000`, or a bare bar number. -1 on failure.
static func parse_bbt(text: String, ppq: int, numerator: int, denominator: int = 4) -> int:
	var s := text.strip_edges()
	if s.is_empty():
		return -1
	s = s.replace(":", ".")
	var parts := s.split(".", false)
	if parts.is_empty():
		return -1
	var bar := parts[0].to_int()
	if bar <= 0:
		return -1
	var beat := 1
	var tick := 0
	if parts.size() >= 2:
		beat = maxi(1, parts[1].to_int())
	if parts.size() >= 3:
		tick = maxi(0, parts[2].to_int())
	return bbt_to_ticks(bar, beat, tick, ppq, numerator, denominator)


## Inclusive bar range `5-8` → `{start:5, end:8, bars:4}`. Also accepts `2` as 1–2.
static func parse_bars(text: String) -> Dictionary:
	var s := text.strip_edges()
	if s.is_empty() or s.contains("/"):
		return {}
	if s.contains("-"):
		var parts := s.split("-", false)
		if parts.size() < 2:
			return {}
		var a := parts[0].strip_edges().to_int()
		var b := parts[1].strip_edges().to_int()
		if a <= 0 or b < a:
			return {}
		return {"start": a, "end": b, "bars": b - a + 1}
	var n := s.to_int()
	if n <= 0:
		return {}
	return {"start": 1, "end": n, "bars": n}


## `1-4` for an inclusive 1-based bar span.
static func format_bars(bar_count: int) -> String:
	var n := maxi(1, bar_count)
	return "1-%d" % n


## Clip length in whole bars (at least 1), rounded up from ticks.
static func bars_from_ticks(ticks: int, ppq: int, numerator: int, denominator: int = 4) -> int:
	var tpb := ticks_per_bar(ppq, numerator, denominator)
	return maxi(1, ceili(float(maxi(0, ticks)) / float(tpb)))


## Parse `1/4`, `1/4.`, `1/4t`, `240t`, or a raw tick count. -1 on failure.
static func parse_duration(text: String, ppq: int) -> int:
	var s := text.strip_edges().to_lower()
	if s.is_empty():
		return -1
	var p := maxi(1, ppq)
	if s.ends_with("t") and not s.contains("/"):
		var raw := s.substr(0, s.length() - 1)
		if raw.is_valid_int():
			return maxi(1, raw.to_int())
		return -1
	if s.is_valid_int():
		return maxi(1, s.to_int())
	var dotted := s.ends_with(".")
	if dotted:
		s = s.substr(0, s.length() - 1)
	var triplet := s.ends_with("t")
	if triplet:
		s = s.substr(0, s.length() - 1)
	if not s.begins_with("1/"):
		return -1
	var denom := s.substr(2).to_int()
	if denom <= 0:
		return -1
	var ticks := int(float(p) * 4.0 / float(denom))
	if dotted:
		ticks = int(round(float(ticks) * 1.5))
	if triplet:
		ticks = int(round(float(ticks) * 2.0 / 3.0))
	return maxi(1, ticks)


## Prefer a fraction (`1/4`, `1/8.`, `1/4t`); fall back to `Nt`.
static func format_duration(ticks: int, ppq: int) -> String:
	var p := maxi(1, ppq)
	var t := maxi(1, ticks)
	var denoms: Array[int] = [1, 2, 4, 8, 16, 32]
	for d in denoms:
		var straight := int(float(p) * 4.0 / float(d))
		if straight == t:
			return "1/%d" % d
		if int(round(float(straight) * 1.5)) == t:
			return "1/%d." % d
		if int(round(float(straight) * 2.0 / 3.0)) == t:
			return "1/%dt" % d
	return "%dt" % t


## Parse `+1/16` / `-12t` as a signed tick delta. 0 on failure.
static func parse_signed_delta(text: String, ppq: int) -> int:
	var s := text.strip_edges()
	if s.is_empty():
		return 0
	var sign := 1
	if s.begins_with("+"):
		s = s.substr(1)
	elif s.begins_with("-"):
		sign = -1
		s = s.substr(1)
	var dur := parse_duration(s, ppq)
	if dur < 0:
		return 0
	return sign * dur


## Nearest grid step for a clip-local tick.
static func quantize_step(ticks: int, step_ticks: int) -> int:
	var st := maxi(1, step_ticks)
	return int(round(float(ticks) / float(st)))


## Absolute offset from the nearest step (ticks).
static func step_offset(ticks: int, step_ticks: int) -> int:
	var st := maxi(1, step_ticks)
	var step := quantize_step(ticks, st)
	return ticks - step * st
