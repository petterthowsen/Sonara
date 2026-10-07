@tool
class_name GridHelper extends Resource

# Centralized grid calculation and snapping logic
# Used by Ruler, Timeline, and MidiEditor for consistent grid behavior

## Emitted when tick <-> pixel conversion or snapping may have changed (zoom, ppq, time
## signature, tempo map, grid spacing), but not on scroll. `changed` still fires for
## everything, scroll included. Content that scrolls inside a ScrollContainer (the clip
## editor's notes) only needs this one.
signal scale_changed

@export var ppq: int = 960:
	set(p):
		if ppq != p:
			ppq = p
			_emit_scale_changed()
@export var time_numerator: int = 4:
	set(n):
		if time_numerator != n:
			time_numerator = n
			_emit_scale_changed()
		
@export var time_denominator: int = 4:
	set(d):
		if time_denominator != d:
			time_denominator = d
			_emit_scale_changed()

@export var tempo: float = 120.0:
	set(t):
		if tempo != t:
			tempo = t
			changed.emit()

## Tempo automation for the time ruler. When set and non-empty, seconds follow the ramps.
var tempo_map: TempoMap = null:
	set(m):
		if tempo_map == m:
			return
		if tempo_map != null and tempo_map.changed.is_connected(_emit_scale_changed):
			tempo_map.changed.disconnect(_emit_scale_changed)
		tempo_map = m
		if tempo_map != null:
			tempo_map.changed.connect(_emit_scale_changed)
		_emit_scale_changed()

## Time signature changes after the base signature. When set, bars, beats and snapping follow it.
var time_signature_map: TimeSignatureMap = null:
	set(m):
		if time_signature_map == m:
			return
		if time_signature_map != null and time_signature_map.changed.is_connected(_emit_scale_changed):
			time_signature_map.changed.disconnect(_emit_scale_changed)
		time_signature_map = m
		if time_signature_map != null:
			time_signature_map.changed.connect(_emit_scale_changed)
		_emit_scale_changed()

var _empty_signature_map := TimeSignatureMap.new()


func _emit_scale_changed() -> void:
	scale_changed.emit()
	changed.emit()

@export var pixels_per_beat: float = 64.0:
	set(p):
		if pixels_per_beat != p:
			pixels_per_beat = p
			_emit_scale_changed()

@export var scroll_position: float = 0.0:
	set(s):
		if scroll_position != s:
			scroll_position = s
			changed.emit()

## Minimum on-screen gap in pixels between adjacent grid lines. Beat lines, then
## 1/2, 1/4, 1/8 and 1/16 beat subdivisions (8th, 16th, 32nd and 64th notes),
## appear (and become snap targets) only once their spacing reaches this. Bar
## lines always show. At runtime this follows the instance's `spacing_setting`
## key (below).
@export var min_line_spacing: float = 10.0:
	set(v):
		if min_line_spacing != v:
			min_line_spacing = v
			_emit_scale_changed()

func _init(ppq_val: int = 960, time_num: int = 4, time_denom: int = 4, tempo_val : float = 120.0):
	ppq = ppq_val
	time_numerator = time_num
	time_denominator = time_denom
	tempo = tempo_val
	_follow_spacing_setting()

## Settings key an instance follows for min_line_spacing. The arranger's timeline
## and rulers use the default; the clip editor's MIDI editor follows its own key,
## so the two views can want different gaps.
const SPACING_SETTING := "appearance/grid_min_line_spacing"
const MIDI_EDITOR_SPACING_SETTING := "appearance/midi_editor_min_line_spacing"

## Subdivision levels as divisors of a quarter note, finest first: 1/2, 1/4, 1/8 and 1/16 beat.
const SUBDIVISION_DIVS := [16, 8, 4, 2]
## Bar lines are 2 px wide and carry numbers, so they want this many times min_line_spacing.
const BAR_SPACING_FACTOR := 2.0
## Bar numbers are drawn on bars at least this many pixels apart.
const BAR_LABEL_MIN_SPACING := 48.0
## Line strength steps from the finest visible level up to the strongest.
const WEIGHT_STEPS := 3.0

## The key this instance follows (see SPACING_SETTING). Setting it re-reads the
## value and keeps tracking changes of the new key.
var spacing_setting: String = SPACING_SETTING:
	set(key):
		if spacing_setting == key:
			return
		spacing_setting = key
		_follow_spacing_setting()

func _follow_spacing_setting() -> void:
	"""Take min_line_spacing from Settings and track live changes (not in the Godot editor)."""
	if Engine.is_editor_hint():
		return
	# Looked up via the tree: this @tool script can be parsed before autoloads resolve by name.
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree else null
	if settings == null:
		return
	min_line_spacing = float(settings.get_value(spacing_setting))
	if not settings.setting_changed.is_connected(_on_setting_changed):
		settings.setting_changed.connect(_on_setting_changed)

func _on_setting_changed(key: String, value) -> void:
	if key == spacing_setting:
		min_line_spacing = float(value)

static func from_project(p : Project) -> GridHelper:
	var grid := new(p.ppq, p.time_numerator, p.time_denominator, p.tempo)
	grid.time_signature_map = p.time_signature_map
	return grid

# ============================================================================
# GRID INTERVAL CALCULATION
# ============================================================================

## Ticks in one beat. A beat is a 1/denominator note (an eighth in 6/8).
static func beat_ticks(ppq_val: int, denominator: int) -> int:
	@warning_ignore("integer_division")
	return maxi(1, maxi(1, ppq_val) * 4 / maxi(1, denominator))

## Ticks in one bar (numerator beats).
static func bar_ticks(ppq_val: int, numerator: int, denominator: int) -> int:
	return maxi(1, numerator) * beat_ticks(ppq_val, denominator)

## Ticks to 1-based bar/beat/sixteenth plus the tick remainder within the sixteenth.
@warning_ignore("integer_division")
static func bbt_of(ticks: int, ppq_val: int, numerator: int, denominator: int) -> Dictionary:
	var tpbar := bar_ticks(ppq_val, numerator, denominator)
	var tpbeat := beat_ticks(ppq_val, denominator)
	var tpsix := maxi(1, maxi(1, ppq_val) / 4)
	var t := maxi(0, ticks)
	var rem := t % tpbar
	var beat_rem := rem % tpbeat
	return {
		"bar": t / tpbar + 1,
		"beat": rem / tpbeat + 1,
		"sixteenth": beat_rem / tpsix + 1,
		"tick": beat_rem % tpsix,
	}

func get_ticks_per_bar() -> int:
	"""Get the number of ticks in one bar."""
	return bar_ticks(ppq, time_numerator, time_denominator)

func get_ticks_per_beat() -> int:
	"""Get the number of ticks in one beat."""
	return beat_ticks(ppq, time_denominator)

func ticks_to_bbt(ticks: int) -> Dictionary:
	return _signature_map().bbt_at_tick(ticks, time_numerator, time_denominator, ppq)

## The map in use: the project's, or an empty one (a single base-signature stretch).
func _signature_map() -> TimeSignatureMap:
	return time_signature_map if time_signature_map != null else _empty_signature_map

## Stretches of constant signature (see TimeSignatureMap.segments). Read-only.
func get_signature_segments() -> Array[Dictionary]:
	return _signature_map().segments(time_numerator, time_denominator, ppq)

func _segment_at(ticks: int) -> Dictionary:
	var segs := get_signature_segments()
	return segs[_signature_map().segment_index_at_tick(ticks, time_numerator, time_denominator, ppq)]

## Ticks in one bar / beat at `ticks`, following the time signature changes.
func get_ticks_per_bar_at(ticks: int) -> int:
	return _segment_at(ticks)["bar_ticks"]

func get_ticks_per_beat_at(ticks: int) -> int:
	return _segment_at(ticks)["beat_ticks"]

func get_snap_interval() -> int:
	"""Get the current snap interval in ticks - matches finest visible grid line."""
	return _snap_interval_for(get_ticks_per_beat(), get_ticks_per_bar())

## Snap interval for the stretch containing `ticks`.
func get_snap_interval_at(ticks: int) -> int:
	var seg := _segment_at(ticks)
	return _snap_interval_for(seg["beat_ticks"], seg["bar_ticks"])

func _snap_interval_for(beat: int, bar: int) -> int:
	# Snap to the finest line that is drawn at all, even one still fading in
	var subdivision_interval := _subdivision_for(beat)
	if subdivision_interval > 0:
		return subdivision_interval
	elif ticks_to_pixels(beat) >= min_line_spacing:
		return beat
	return bar

## True when beats are at least min_line_spacing apart on screen.
func beat_lines_visible() -> bool:
	return ticks_to_pixels(get_ticks_per_beat()) >= min_line_spacing

## Finest 1/2, 1/4, 1/8 or 1/16 beat subdivision that keeps lines min_line_spacing
## apart, or 0 for none. Finest first, so `ppq / 16` (a 64th note) is the floor.
func get_subdivision_interval() -> int:
	return _subdivision_for(get_ticks_per_beat())

func _subdivision_for(beat: int) -> int:
	for div in SUBDIVISION_DIVS:
		@warning_ignore("integer_division")
		var interval: int = maxi(1, ppq / div)
		if interval < beat and ticks_to_pixels(interval) >= min_line_spacing:
			return interval
	return 0

## How far a line level is faded in: 0 at `threshold` pixels of spacing, 1 at twice that.
## A level is only drawn once its spacing reaches the threshold, but it takes the same
## again before it is at full strength, so zooming brings lines in smoothly.
static func fade_of(spacing_px: float, threshold: float) -> float:
	var th := maxf(1.0, threshold)
	return clampf((spacing_px - th) / th, 0.0, 1.0)

# ============================================================================
# SNAPPING
# ============================================================================

func snap_ticks(ticks: int) -> int:
	"""Snap ticks to the grid interval of the signature stretch they are in. The result never
	passes the next stretch's first bar line."""
	var seg := _segment_at(ticks)
	var interval := _snap_interval_for(seg["beat_ticks"], seg["bar_ticks"])
	if interval > 0:
		var origin: int = seg["tick"]
		# Use rounding instead of truncation for better snapping behavior
		var snapped := origin + roundi(float(ticks - origin) / float(interval)) * interval
		if seg["end_tick"] >= 0:
			snapped = mini(snapped, seg["end_tick"])
		return snapped
	return ticks

## Snap ticks down to the grid interval (the grid line at or before `ticks`).
func floor_ticks(ticks: int) -> int:
	var seg := _segment_at(ticks)
	var interval := _snap_interval_for(seg["beat_ticks"], seg["bar_ticks"])
	if interval > 0:
		var origin: int = seg["tick"]
		return origin + floori(float(ticks - origin) / float(interval)) * interval
	return ticks

func snap_pixels(pixels: float) -> float:
	"""Snap pixels to the current grid interval."""
	var ticks = pixels_to_ticks(pixels)
	var snapped_ticks = snap_ticks(ticks)
	return ticks_to_pixels(snapped_ticks)


# ============================================================================
# TIME CONVERSION
# ============================================================================

func ticks_to_seconds(ticks: int) -> float:
	"""Convert ticks to seconds."""
	if tempo_map != null and not tempo_map.is_empty():
		return tempo_map.seconds_at_tick(ticks, tempo, ppq)
	var seconds_per_tick = 60.0 / (tempo * ppq)
	return ticks * seconds_per_tick

func seconds_to_ticks(seconds: float) -> int:
	"""Convert seconds to ticks."""
	if tempo_map != null and not tempo_map.is_empty():
		return roundi(tempo_map.tick_at_seconds(seconds, tempo, ppq))
	var seconds_per_tick = 60.0 / (tempo * ppq)
	return roundi(seconds / seconds_per_tick)

func ticks_to_minutes(ticks: int) -> float:
	"""Convert ticks to minutes."""
	return ticks_to_seconds(ticks) / 60.0

func minutes_to_ticks(minutes: float) -> int:
	"""Convert minutes to ticks."""
	return seconds_to_ticks(minutes * 60.0)

func ticks_to_hours(ticks: int) -> float:
	"""Convert ticks to hours."""
	return ticks_to_minutes(ticks) / 60.0

func hours_to_ticks(hours: float) -> int:
	"""Convert hours to ticks."""
	return minutes_to_ticks(hours * 60.0)

func get_pixels_per_second() -> float:
	"""Get pixels per second at current zoom level."""
	var seconds_per_beat = 60.0 / tempo
	var pixels_per_second = pixels_per_beat / seconds_per_beat
	return pixels_per_second

func get_pixels_per_minute() -> float:
	"""Get pixels per minute at current zoom level."""
	return get_pixels_per_second() * 60.0

func get_pixels_per_hour() -> float:
	"""Get pixels per hour at current zoom level."""
	return get_pixels_per_minute() * 60.0


# ============================================================================
# COORDINATE CONVERSION
# ============================================================================

func ticks_to_pixels(ticks: int) -> float:
	"""Convert ticks to pixels."""
	var beats = float(ticks) / float(ppq)
	return beats * pixels_per_beat

func pixels_to_ticks(pixels: float) -> int:
	"""Convert pixels to ticks."""
	var beats = pixels / pixels_per_beat
	return roundi(beats * ppq)


# ============================================================================
# GRID LINE GENERATION
# ============================================================================

enum GridLineType { BAR, BEAT, SUBDIVISION }

class GridLine:
	var x: float
	var type: GridLineType
	var bar_number: int = 0  # Only for bar lines
	## 0 (faintest) to 1 (strongest). Rank among the visible levels, counted from the
	## finest, so a grid with few levels is quiet and each level added pushes the
	## coarser ones up a step. Continuous while the finest level fades in.
	var weight: float = 1.0
	## Opacity factor 0..1 for the level fading in or out with zoom.
	var alpha: float = 1.0
	## Bar lines only: draw the bar number here. Bar numbers thin out like bar lines do.
	var labeled: bool = false

	func _init(x_pos: float, line_type: GridLineType, bar_num: int = 0):
		x = x_pos
		type = line_type
		bar_number = bar_num

	## Colour for this line from a three-colour palette: `faint` (weight 0), `mid` and
	## `strong` (weight 1), with the level's fade folded into alpha. Even the faintest
	## line sits a quarter of the way to `mid`, so a lone level is always legible.
	func color(faint: Color, mid: Color, strong: Color) -> Color:
		var t := 0.25 + 0.75 * weight
		var c := faint.lerp(mid, t * 2.0) if t < 0.5 else mid.lerp(strong, (t - 0.5) * 2.0)
		c.a *= alpha
		return c

	## Whole-pixel width: bars read as heavier through width, the rest through colour.
	func width() -> float:
		return 2.0 if type == GridLineType.BAR else 1.0

## The line levels of one signature stretch, coarsest first. Each is a Dictionary:
## `interval` (ticks), `type`, `bars` (bar levels: draw every Nth bar), `fade`, `weight`.
## Bars come in power-of-two groups once they get too close, 1 bar, 2, 4 and so on;
## below them the beat and its 1/2, 1/4, 1/8 and 1/16 subdivisions.
func _levels_for(beat: int, bar: int) -> Array[Dictionary]:
	var th := maxf(1.0, min_line_spacing)
	var bar_th := th * BAR_SPACING_FACTOR
	var levels: Array[Dictionary] = []

	var k := 1
	while ticks_to_pixels(bar * k) < bar_th and k < (1 << 24):
		k *= 2
	var k_fade := fade_of(ticks_to_pixels(bar * k), bar_th)
	if k_fade < 1.0:
		# The group is still fading in; the next coarser one carries the grid meanwhile.
		levels.append({"interval": bar * k * 2, "type": GridLineType.BAR, "bars": k * 2, "fade": 1.0})
	levels.append({"interval": bar * k, "type": GridLineType.BAR, "bars": k, "fade": k_fade})

	if beat < bar and ticks_to_pixels(beat) >= th:
		levels.append({"interval": beat, "type": GridLineType.BEAT, "bars": 0, "fade": fade_of(ticks_to_pixels(beat), th)})
		for i in range(SUBDIVISION_DIVS.size() - 1, -1, -1):
			@warning_ignore("integer_division")
			var interval: int = maxi(1, ppq / int(SUBDIVISION_DIVS[i]))
			if interval < beat and ticks_to_pixels(interval) >= th:
				levels.append({"interval": interval, "type": GridLineType.SUBDIVISION, "bars": 0, "fade": fade_of(ticks_to_pixels(interval), th)})

	# Weights count from the finest level. The finest sits at the bottom; the next one up
	# rises with its fade, so nothing jumps when a level appears.
	var n := levels.size() - 1
	var finest_fade: float = levels[n]["fade"]
	for i in levels.size():
		var steps := 0.0 if i == n else clampf(float(n - i) - 1.0 + finest_fade, 0.0, WEIGHT_STEPS)
		var w := steps / WEIGHT_STEPS
		if levels[i]["type"] == GridLineType.BAR:
			w = 0.4 + 0.6 * w  # a bar is never the faintest thing on screen
		levels[i]["weight"] = w
	return levels

func get_visible_grid_lines(start_x: float, end_x: float, offset_x: float = 0.0, use_scroll: bool = true) -> Array[GridLine]:
	"""
	Generate grid lines for the visible range.
	start_x/end_x are in pixel space (before scroll adjustment).
	offset_x is horizontal offset (e.g., piano keyboard width).
	use_scroll: if true, adjust for scroll_position (for fixed overlays like Ruler). If false, don't adjust (for scrolled content like Timeline).
	Returns array of GridLine objects ready for drawing. Each tick appears once, at the
	coarsest level it falls on; see _levels_for.
	"""
	var lines: Array[GridLine] = []

	# Convert to ticks, accounting for scroll position if requested
	var scroll_offset = scroll_position if use_scroll else 0.0
	var start_ticks = pixels_to_ticks(start_x + scroll_offset)
	var end_ticks = pixels_to_ticks(end_x + scroll_offset)

	var segs := get_signature_segments()
	for seg in segs:
		var seg_start: int = seg["tick"]
		var seg_end: int = seg["end_tick"]
		if seg_end >= 0 and seg_end <= start_ticks:
			continue
		if seg_start > end_ticks:
			break
		# A bar line on seg_end belongs to the next stretch
		var last_tick: int = end_ticks if seg_end < 0 else mini(end_ticks, seg_end - 1)
		var first_tick: int = maxi(start_ticks, seg_start)
		var ticks_per_bar: int = seg["bar_ticks"]
		var ticks_per_beat: int = seg["beat_ticks"]
		var first_bar: int = seg["bar"]

		var levels := _levels_for(ticks_per_beat, ticks_per_bar)

		# Numbers go on every Nth bar, N the smallest power of two that leaves them room
		var label_every := 1
		while ticks_to_pixels(ticks_per_bar * label_every) < BAR_LABEL_MIN_SPACING and label_every < (1 << 24):
			label_every *= 2

		var coarser_intervals: Array[int] = []  # beat and subdivision levels already emitted
		var coarser_bars := 0  # bar group of the level above
		for level in levels:
			var interval: int = level["interval"]
			var level_type: GridLineType = level["type"]
			var fade: float = level["fade"]
			var weight: float = level["weight"]

			if level_type == GridLineType.BAR:
				var every: int = level["bars"]
				@warning_ignore("integer_division")
				var idx: int = maxi(0, (first_tick - seg_start) / ticks_per_bar)
				# Step to the first bar of the group (bar numbers are global and 1-based)
				idx += posmod(-(first_bar - 1 + idx), every)
				var tick := seg_start + idx * ticks_per_bar
				while tick <= last_tick:
					var bar_number := first_bar + idx
					if coarser_bars == 0 or (bar_number - 1) % coarser_bars != 0:
						var line := GridLine.new(ticks_to_pixels(tick) - scroll_offset + offset_x, GridLineType.BAR, bar_number)
						line.weight = weight
						line.alpha = fade
						line.labeled = (bar_number - 1) % maxi(label_every, every) == 0
						lines.append(line)
					idx += every
					tick += every * ticks_per_bar
				coarser_bars = every
			else:
				@warning_ignore("integer_division")
				var tick := seg_start + ((first_tick - seg_start) / interval) * interval
				while tick <= last_tick:
					var rel := tick - seg_start
					var covered := rel % ticks_per_bar == 0
					for c in coarser_intervals:
						covered = covered or rel % c == 0
					if not covered:
						var line := GridLine.new(ticks_to_pixels(tick) - scroll_offset + offset_x, level_type)
						line.weight = weight
						line.alpha = fade
						lines.append(line)
					tick += interval
				coarser_intervals.append(interval)

	return lines
