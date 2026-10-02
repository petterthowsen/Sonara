# AnalysisFormat.gd
# Turns an engine AnalysisResult (parsed JSON, see Engine/src/audio/analysis) into the text grid the
# `analyze` tool returns. Pure: no project or engine access, so tests feed it fixtures. The digit scale
# mirrors Engine/src/audio/analysis/scale.rs; bump SCALE_VERSION there and here together.
class_name AnalysisFormat extends RefCounted

const SCALE_VERSION := 1
const DIGIT_FLOOR_DB := -33.0
const DIGIT_STEP_DB := 3.0
## At or below this a value is silence (`.`).
const SILENCE_DB := -70.0
const MASTER_TAP := 1
## Bands quieter than this digit are too faint to count as masking.
const MASK_MIN_DIGIT := 3
const MASK_WINDOW_DB := 3.0
const MASK_MAX_NAMES := 4
const LABEL_WIDTH := 8


## "0"–"9" for a loudness or band level in dB, "." for silence.
static func digit(db: float) -> String:
	if is_nan(db) or db <= SILENCE_DB:
		return "."
	return str(clampi(int(round((db - DIGIT_FLOOR_DB) / DIGIT_STEP_DB)), 0, 9))


## `ctx` keys (all optional):
##   names: Dictionary channel id -> display name
##   markers: Array of {name, start_ticks, end_ticks} (end exclusive)
##   roots: Array of String, one per analyzed bar/beat (omit for no root row)
static func format(result: Dictionary, ctx: Dictionary = {}) -> String:
	var header: Dictionary = result.get("header", {})
	var spans: Array = result.get("bars", [])
	if spans.is_empty():
		return "Nothing was analyzed: the range holds no bars."
	var taps: Array = header.get("taps", [])
	var band_names: Array = header.get("band_names", [])
	var beat_res: bool = str(header.get("resolution", "bar")) == "beat"
	var labels: PackedStringArray = []
	for s in spans:
		labels.append("%d.%d" % [int(s.bar), int(s.beat)] if beat_res else str(int(s.bar)))
	var width := 2
	for l in labels:
		width = maxi(width, l.length())
	var bounds := _boundaries(spans, ctx.get("markers", []))

	var out: PackedStringArray = [_legend(header)]
	if int(header.get("scale_version", SCALE_VERSION)) != SCALE_VERSION:
		out.append("Warning: result scale version %d differs from the formatter's %d, so digits may not match older results." % [int(header.scale_version), SCALE_VERSION])
	out.append(_row("bars", Array(labels), width, bounds))
	var marker_row := _marker_row(bounds, spans.size(), width)
	if marker_row != "":
		out.append(marker_row)

	var names: Dictionary = ctx.get("names", {})
	var omitted := 0
	var channel_taps: Array = []
	for t in taps.size():
		var id := int(taps[t])
		if id != MASTER_TAP and _is_silent(spans, t):
			omitted += 1
			continue
		if id != MASTER_TAP:
			channel_taps.append(t)
		if taps.size() > 1:
			out.append("[%s]" % (str(names.get(id, "Master")) if id == MASTER_TAP else str(names.get(id, "ch%d" % id))))
		out.append_array(_block(spans, t, band_names, width, bounds, ctx.get("roots", []) if id == MASTER_TAP else []))
	if omitted > 0:
		out.append("(%d silent channel%s omitted)" % [omitted, "" if omitted == 1 else "s"])
	if channel_taps.size() >= 2:
		out.append_array(_masking(spans, taps, channel_taps, band_names, names, bounds))
	return "\n".join(out)


static func _legend(header: Dictionary) -> String:
	var edges: Array = header.get("band_edges_hz", [])
	var names: Array = header.get("band_names", [])
	var bands: PackedStringArray = []
	for i in names.size():
		if i < edges.size():
			bands.append("%s %s–%s" % [names[i], _hz(float(edges[i][0])), _hz(float(edges[i][1]))])
	return "Digits 0–9 are %d dB steps (9 = %d dB or louder, 0 = %d dB or quieter). loud is LUFS; bands are relative to pink noise, so an even row is a balanced spectrum. `.` = silent, `!` = sample peak over 0 dBFS. Bands (Hz): %s." % [
		int(DIGIT_STEP_DB), int(DIGIT_FLOOR_DB + 9 * DIGIT_STEP_DB), int(DIGIT_FLOOR_DB), ", ".join(bands)]


static func _hz(hz: float) -> String:
	if hz >= 1000.0:
		return "%sk" % String.num(hz / 1000.0, 1).trim_suffix(".0")
	return str(int(hz))


## Column index -> section label (possibly "") for every column where a marker starts or ends.
## Column 0 is always present so it opens the first section.
static func _boundaries(spans: Array, markers: Array) -> Dictionary:
	var bounds := {0: ""}
	var sorted := markers.duplicate()
	sorted.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	var last_end := float(spans[spans.size() - 1].end_tick)
	for m in sorted:
		var start := _col_at(spans, float(m.start_ticks))
		if start < 0:
			if float(m.start_ticks) < float(spans[0].start_tick) and float(m.end_ticks) > float(spans[0].start_tick):
				start = 0
			else:
				continue
		bounds[start] = str(m.name)
		if float(m.end_ticks) < last_end:
			var end := _col_at(spans, float(m.end_ticks))
			if end > start and not bounds.has(end):
				bounds[end] = ""
	return bounds


static func _col_at(spans: Array, tick: float) -> int:
	for i in spans.size():
		if tick >= float(spans[i].start_tick) and tick < float(spans[i].end_tick):
			return i
	return -1


## `label: c c c | c c c`, cells right-aligned to `width`, " | " at section boundaries.
static func _row(label: String, cells: Array, width: int, bounds: Dictionary) -> String:
	var s := ("%s:" % label).rpad(LABEL_WIDTH)
	for i in cells.size():
		if i > 0:
			s += " | " if bounds.has(i) else " "
		s += str(cells[i]).lpad(width)
	return s


static func _marker_row(bounds: Dictionary, count: int, width: int) -> String:
	var starts: Array = bounds.keys()
	starts.sort()
	var any := false
	var s := "marker:".rpad(LABEL_WIDTH)
	for k in starts.size():
		var from: int = starts[k]
		var to: int = starts[k + 1] if k + 1 < starts.size() else count
		var room := (to - from) * width + (to - from - 1)
		var text: String = str(bounds[from])
		any = any or text != ""
		if k > 0:
			s += " | "
		s += text.substr(0, room).rpad(room)
	return s.strip_edges(false, true) if any else ""


static func _block(spans: Array, t: int, band_names: Array, width: int, bounds: Dictionary, roots: Array) -> PackedStringArray:
	var rows: PackedStringArray = []
	var loud: Array = []
	var peak: Array = []
	for s in spans:
		var m: Dictionary = s.taps[t]
		loud.append(digit(float(m.lufs)))
		peak.append("!" if m.get("clipped", false) else ".")
	rows.append(_row("loud", loud, width, bounds))
	for b in band_names.size():
		var cells: Array = []
		for s in spans:
			cells.append(digit(float(s.taps[t].bands_db[b])))
		rows.append(_row(str(band_names[b]), cells, width, bounds))
	rows.append(_row("peak", peak, width, bounds))
	if roots.size() == spans.size():
		rows.append(_row("root", roots, width, bounds))
	return rows


static func _is_silent(spans: Array, t: int) -> bool:
	for s in spans:
		var m: Dictionary = s.taps[t]
		if digit(float(m.lufs)) != ".":
			return false
		for db in m.bands_db:
			if digit(float(db)) != ".":
				return false
	return true


## Per band and section: the channels within MASK_WINDOW_DB of the loudest, when there are two or more.
static func _masking(spans: Array, taps: Array, channel_taps: Array, band_names: Array, names: Dictionary, bounds: Dictionary) -> PackedStringArray:
	var starts: Array = bounds.keys()
	starts.sort()
	var lines: PackedStringArray = []
	for k in starts.size():
		var from: int = starts[k]
		var to: int = starts[k + 1] if k + 1 < starts.size() else spans.size()
		for b in band_names.size():
			var levels: Array = []
			for t in channel_taps:
				var power := 0.0
				for i in range(from, to):
					var db := float(spans[i].taps[t].bands_db[b])
					if db > SILENCE_DB:
						power += pow(10.0, db / 10.0)
				var db_avg := 10.0 * log(power / float(to - from)) / log(10.0) if power > 0.0 else -INF
				levels.append({"name": str(names.get(int(taps[t]), "ch%d" % int(taps[t]))), "db": db_avg})
			levels.sort_custom(func(x, y): return x.db > y.db)
			var top: float = levels[0].db
			if digit(top) == "." or int(digit(top)) < MASK_MIN_DIGIT:
				continue
			var near: PackedStringArray = []
			for l in levels:
				if l.db >= top - MASK_WINDOW_DB and near.size() < MASK_MAX_NAMES:
					near.append("%s %s" % [l.name, digit(l.db)])
			if near.size() >= 2:
				var first := int(spans[from].bar)
				var last := int(spans[to - 1].bar)
				var where := "bar %d" % first if first == last else "bars %d–%d" % [first, last]
				lines.append("%s %s: %s" % [band_names[b], where, ", ".join(near)])
	var out: PackedStringArray = []
	if lines.is_empty():
		out.append("Masking: no band where two or more channels are within %d dB of each other." % int(MASK_WINDOW_DB))
	else:
		out.append("Masking (channels within %d dB of the loudest in a band, per section; digit = average level):" % int(MASK_WINDOW_DB))
		out.append_array(lines)
	return out
