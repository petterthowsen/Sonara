# InspectorBbt.gd
# Bars.beats.ticks text for the inspector fields. Positions are 1-based song positions that follow
# the project's time signature map. Lengths and offsets are 0-based amounts (a one-bar length reads
# `1.0.000`) measured with the signature in effect at a given tick. Both sit on top of
# TimeSignatureMap and ClipTextTime, so the ticks-per-beat rules live in one place.
class_name InspectorBbt extends RefCounted


## `bar.beat.tick` of song tick `ticks` (bar and beat count from 1, tick is within the beat).
static func format_position(project: Project, ticks: int) -> String:
	var bbt := project.time_signature_map.bbt_at_tick(
			ticks, project.time_numerator, project.time_denominator, project.ppq)
	var tick_in_beat: int = (int(bbt["sixteenth"]) - 1) * maxi(1, project.ppq >> 2) + int(bbt["tick"])
	return "%d.%d.%03d" % [bbt["bar"], bbt["beat"], tick_in_beat]


## Song tick for a typed position, or -1 when the text is not a valid position.
static func parse_position(project: Project, text: String) -> int:
	var s := text.strip_edges().replace(":", ".")
	var bar := s.get_slice(".", 0).to_int() if s.get_slice(".", 0).is_valid_int() else 0
	if bar < 1:
		return -1
	var map := project.time_signature_map
	var bar_start := map.tick_of_bar(bar, project.time_numerator, project.time_denominator, project.ppq)
	var sig := map.signature_at_tick(bar_start, project.time_numerator, project.time_denominator, project.ppq)
	var local := ClipTextTime.parse_bbt(s, project.ppq, sig.x, sig.y)
	if local < 0:
		return -1
	return bar_start + local - (bar - 1) * GridHelper.bar_ticks(project.ppq, sig.x, sig.y)


## `bars.beats.ticks` for an amount of ticks, using the signature in effect at song tick `at_tick`.
static func format_duration(project: Project, ticks: int, at_tick: int) -> String:
	var sig := _signature_at(project, at_tick)
	var bbt := ClipTextTime.ticks_to_bbt(ticks, project.ppq, sig.x, sig.y)
	return "%d.%d.%03d" % [int(bbt["bar"]) - 1, int(bbt["beat"]) - 1, bbt["tick"]]


## Ticks for a typed amount (`2`, `0.2`, `1.2.240`), or -1 when invalid.
static func parse_duration(project: Project, text: String, at_tick: int) -> int:
	var parts := text.strip_edges().replace(":", ".").split(".", false)
	if parts.is_empty() or parts.size() > 3:
		return -1
	var nums: Array[int] = [0, 0, 0]
	for i in parts.size():
		if not parts[i].is_valid_int() or parts[i].to_int() < 0:
			return -1
		nums[i] = parts[i].to_int()
	var sig := _signature_at(project, at_tick)
	var shifted := "%d.%d.%d" % [nums[0] + 1, nums[1] + 1, nums[2]]
	var r := ClipTextTime.check_bbt(shifted, project.ppq, sig.x, sig.y)
	return int(r["ticks"]) if r.has("ticks") else -1


static func _signature_at(project: Project, tick: int) -> Vector2i:
	return project.time_signature_map.signature_at_tick(
			tick, project.time_numerator, project.time_denominator, project.ppq)
