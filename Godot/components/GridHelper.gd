@tool
class_name GridHelper extends Resource

# Centralized grid calculation and snapping logic
# Used by Ruler, Timeline, and MidiEditor for consistent grid behavior

@export var ppq: int = 960
@export var time_numerator: int = 4:
	set(n):
		if time_numerator != n:
			time_numerator = n
			changed.emit()
		
@export var time_denominator: int = 4:
	set(d):
		if time_denominator != d:
			time_denominator = d
			changed.emit()

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
		if tempo_map != null and tempo_map.changed.is_connected(changed.emit):
			tempo_map.changed.disconnect(changed.emit)
		tempo_map = m
		if tempo_map != null:
			tempo_map.changed.connect(changed.emit)
		changed.emit()

@export var pixels_per_beat: float = 64.0:
	set(p):
		if pixels_per_beat != p:
			pixels_per_beat = p
			changed.emit()

@export var scroll_position: float = 0.0:
	set(s):
		if scroll_position != s:
			scroll_position = s
			changed.emit()

## Minimum on-screen gap in pixels between adjacent grid lines. Beat lines, then
## 1/2, 1/4 and 1/8 beat subdivisions, appear (and become snap targets) only
## once their spacing reaches this. Bar lines always show. At runtime this
## follows the "appearance/grid_min_line_spacing" setting.
@export var min_line_spacing: float = 10.0:
	set(v):
		if min_line_spacing != v:
			min_line_spacing = v
			changed.emit()

func _init(ppq_val: int = 960, time_num: int = 4, time_denom: int = 4, tempo_val : float = 120.0):
	ppq = ppq_val
	time_numerator = time_num
	time_denominator = time_denom
	tempo = tempo_val
	_follow_spacing_setting()

const SPACING_SETTING := "appearance/grid_min_line_spacing"

func _follow_spacing_setting() -> void:
	"""Take min_line_spacing from Settings and track live changes (not in the Godot editor)."""
	if Engine.is_editor_hint():
		return
	# Looked up via the tree: this @tool script can be parsed before autoloads resolve by name.
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree else null
	if settings == null:
		return
	min_line_spacing = float(settings.get_value(SPACING_SETTING))
	settings.setting_changed.connect(_on_setting_changed)

func _on_setting_changed(key: String, value) -> void:
	if key == SPACING_SETTING:
		min_line_spacing = float(value)

static func from_project(p : Project) -> GridHelper:
	return new(p.ppq, p.time_numerator, p.time_denominator, p.tempo)

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
	return bbt_of(ticks, ppq, time_numerator, time_denominator)

func get_snap_interval() -> int:
	"""Get the current snap interval in ticks - matches finest visible grid line."""
	# Snap to the finest visible grid line
	var subdivision_interval = get_subdivision_interval()
	if subdivision_interval > 0:
		# If subdivisions are visible, snap to them
		return subdivision_interval
	elif beat_lines_visible():
		# If beats are visible, snap to beats
		return get_ticks_per_beat()
	else:
		# Otherwise snap to bars
		return get_ticks_per_bar()

## True when beats are at least min_line_spacing apart on screen.
func beat_lines_visible() -> bool:
	return ticks_to_pixels(get_ticks_per_beat()) >= min_line_spacing

## Finest 1/2, 1/4 or 1/8 beat subdivision that keeps lines min_line_spacing apart, or 0 for none.
func get_subdivision_interval() -> int:
	for div in [8, 4, 2]:
		@warning_ignore("integer_division")
		var interval: int = maxi(1, ppq / div)
		if interval < get_ticks_per_beat() and ticks_to_pixels(interval) >= min_line_spacing:
			return interval
	return 0

# ============================================================================
# SNAPPING
# ============================================================================

func snap_ticks(ticks: int) -> int:
	"""Snap ticks to the current grid interval."""
	var interval = get_snap_interval()
	if interval > 0:
		# Use rounding instead of truncation for better snapping behavior
		return roundi(float(ticks) / float(interval)) * interval
	return ticks

## Snap ticks down to the current grid interval (the grid line at or before `ticks`).
func floor_ticks(ticks: int) -> int:
	var interval := get_snap_interval()
	if interval > 0:
		return floori(float(ticks) / float(interval)) * interval
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
	
	func _init(x_pos: float, line_type: GridLineType, bar_num: int = 0):
		x = x_pos
		type = line_type
		bar_number = bar_num

func get_visible_grid_lines(start_x: float, end_x: float, offset_x: float = 0.0, use_scroll: bool = true) -> Array[GridLine]:
	"""
	Generate grid lines for the visible range.
	start_x/end_x are in pixel space (before scroll adjustment).
	offset_x is horizontal offset (e.g., piano keyboard width).
	use_scroll: if true, adjust for scroll_position (for fixed overlays like Ruler). If false, don't adjust (for scrolled content like Timeline).
	Returns array of GridLine objects ready for drawing.
	"""
	var lines: Array[GridLine] = []
	
	# Convert to ticks, accounting for scroll position if requested
	var scroll_offset = scroll_position if use_scroll else 0.0
	var start_ticks = pixels_to_ticks(start_x + scroll_offset)
	var end_ticks = pixels_to_ticks(end_x + scroll_offset)
	
	var ticks_per_bar = get_ticks_per_bar()
	var ticks_per_beat = get_ticks_per_beat()
	var ticks_per_subdivision = get_subdivision_interval()
	
	# Generate bar lines
	@warning_ignore("integer_division")
	var first_bar_tick = (start_ticks / ticks_per_bar) * ticks_per_bar
	@warning_ignore("integer_division")
	var bar_number = 1 + (first_bar_tick / ticks_per_bar)
	var tick = first_bar_tick
	
	while tick <= end_ticks:
		var x = ticks_to_pixels(tick) - scroll_offset + offset_x
		lines.append(GridLine.new(x, GridLineType.BAR, bar_number))
		tick += ticks_per_bar
		bar_number += 1
	
	# Generate beat lines (skip bars)
	if beat_lines_visible():
		@warning_ignore("integer_division")
		var first_beat_tick = (start_ticks / ticks_per_beat) * ticks_per_beat
		tick = first_beat_tick
		
		while tick <= end_ticks:
			if (tick % ticks_per_bar) != 0:  # Skip if it's a bar line
				var x = ticks_to_pixels(tick) - scroll_offset + offset_x
				lines.append(GridLine.new(x, GridLineType.BEAT))
			tick += ticks_per_beat
	
	# Generate subdivision lines (skip bars and beats)
	if ticks_per_subdivision > 0:
		@warning_ignore("integer_division")
		var first_sub_tick = (start_ticks / ticks_per_subdivision) * ticks_per_subdivision
		tick = first_sub_tick
		
		while tick <= end_ticks:
			# Skip if it's a bar or beat line
			if (tick % ticks_per_bar) != 0 and (tick % ticks_per_beat) != 0:
				var x = ticks_to_pixels(tick) - scroll_offset + offset_x
				lines.append(GridLine.new(x, GridLineType.SUBDIVISION))
			tick += ticks_per_subdivision
	
	return lines
