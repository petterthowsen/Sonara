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

func _init(ppq_val: int = 960, time_num: int = 4, time_denom: int = 4):
	ppq = ppq_val
	time_numerator = time_num
	time_denominator = time_denom

static func from_project(p : Project) -> GridHelper:
	return new(p.ppq, p.time_numerator, p.time_denominator)

# ============================================================================
# GRID INTERVAL CALCULATION
# ============================================================================

func get_ticks_per_bar() -> int:
	"""Get the number of ticks in one bar."""
	return ppq * time_numerator

func get_ticks_per_beat() -> int:
	"""Get the number of ticks in one beat."""
	return ppq

func get_snap_interval() -> int:
	"""Get the current snap interval in ticks - matches finest visible grid line."""
	# Snap to the finest visible grid line
	var subdivision_interval = get_subdivision_interval()
	if subdivision_interval > 0:
		# If subdivisions are visible, snap to them
		return subdivision_interval
	elif pixels_per_beat >= 32.0:
		# If beats are visible, snap to beats
		return ppq
	else:
		# Otherwise snap to bars
		return get_ticks_per_bar()

func get_subdivision_interval() -> int:
	"""Get subdivision grid interval (finer grid lines shown at higher zoom levels)."""
	if pixels_per_beat < 64.0:
		# Don't show subdivisions when zoomed out
		return 0
	elif pixels_per_beat < 256.0:
		# Show quarter beat subdivisions
		@warning_ignore("integer_division")
		return ppq / 4
	else:
		# Show eighth beat subdivisions
		@warning_ignore("integer_division")
		return ppq / 8

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

func snap_pixels(pixels: float) -> float:
	"""Snap pixels to the current grid interval."""
	var ticks = pixels_to_ticks(pixels)
	var snapped_ticks = snap_ticks(ticks)
	return ticks_to_pixels(snapped_ticks)

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

func get_visible_grid_lines(start_x: float, end_x: float, offset_x: float = 0.0) -> Array[GridLine]:
	"""
	Generate grid lines for the visible range.
	start_x/end_x are in pixel space (before scroll adjustment).
	offset_x is horizontal offset (e.g., piano keyboard width).
	Returns array of GridLine objects ready for drawing.
	"""
	var lines: Array[GridLine] = []
	
	# Convert to ticks, accounting for scroll position
	var start_ticks = pixels_to_ticks(start_x + scroll_position)
	var end_ticks = pixels_to_ticks(end_x + scroll_position)
	
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
		var x = ticks_to_pixels(tick) - scroll_position + offset_x
		lines.append(GridLine.new(x, GridLineType.BAR, bar_number))
		tick += ticks_per_bar
		bar_number += 1
	
	# Generate beat lines (skip bars)
	if pixels_per_beat >= 32.0:  # Only show beats if zoomed in enough
		@warning_ignore("integer_division")
		var first_beat_tick = (start_ticks / ticks_per_beat) * ticks_per_beat
		tick = first_beat_tick
		
		while tick <= end_ticks:
			if (tick % ticks_per_bar) != 0:  # Skip if it's a bar line
				var x = ticks_to_pixels(tick) - scroll_position + offset_x
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
				var x = ticks_to_pixels(tick) - scroll_position + offset_x
				lines.append(GridLine.new(x, GridLineType.SUBDIVISION))
			tick += ticks_per_subdivision
	
	return lines
