# Draws a ruler with vertical lines at real-time positions (seconds, minutes, hours)
# Shows time labels and automatically adjusts major unit based on zoom level
@tool
class_name RealTimeRuler extends BaseRuler

@export var min_major_spacing: float = 100.0  # Minimum pixels between major lines

enum TimeUnit { MILLISECONDS, SECONDS, MINUTES, HOURS }

# Ruler scale configuration
# Each entry defines: [time_unit, major_interval, minor_subdivisions]
# major_interval is in the unit specified by time_unit
const RULER_SCALES = [
	# Millisecond scales (very zoomed in)
	[TimeUnit.MILLISECONDS, 10, 10],     # 10ms major, 1ms minor
	[TimeUnit.MILLISECONDS, 20, 4],      # 20ms major, 5ms minor
	[TimeUnit.MILLISECONDS, 50, 5],      # 50ms major, 10ms minor
	[TimeUnit.MILLISECONDS, 100, 10],    # 100ms major, 10ms minor
	[TimeUnit.MILLISECONDS, 200, 4],     # 200ms major, 50ms minor
	[TimeUnit.MILLISECONDS, 500, 5],     # 500ms major, 100ms minor

	# Second scales
	[TimeUnit.SECONDS, 1, 10],           # 1s major, 100ms minor
	[TimeUnit.SECONDS, 2, 4],            # 2s major, 500ms minor
	[TimeUnit.SECONDS, 5, 5],            # 5s major, 1s minor
	[TimeUnit.SECONDS, 10, 10],          # 10s major, 1s minor
	[TimeUnit.SECONDS, 15, 3],           # 15s major, 5s minor
	[TimeUnit.SECONDS, 30, 6],           # 30s major, 5s minor

	# Minute scales
	[TimeUnit.MINUTES, 1, 6],            # 1min major, 10s minor
	[TimeUnit.MINUTES, 2, 4],            # 2min major, 30s minor
	[TimeUnit.MINUTES, 5, 5],            # 5min major, 1min minor
	[TimeUnit.MINUTES, 10, 10],          # 10min major, 1min minor
	[TimeUnit.MINUTES, 15, 3],           # 15min major, 5min minor
	[TimeUnit.MINUTES, 30, 6],           # 30min major, 5min minor

	# Hour scales (very zoomed out)
	[TimeUnit.HOURS, 1, 6],              # 1hr major, 10min minor
	[TimeUnit.HOURS, 2, 4],              # 2hr major, 30min minor
	[TimeUnit.HOURS, 6, 6],              # 6hr major, 1hr minor
	[TimeUnit.HOURS, 12, 12],            # 12hr major, 1hr minor
]

## Represents a ruler scale with unit, major interval, and subdivision count
class RulerScale:
	var unit: TimeUnit
	var major_interval: float  # In the unit specified by 'unit'
	var subdivisions: int

	func _init(u: TimeUnit, interval: float, subdiv: int):
		unit = u
		major_interval = interval
		subdivisions = subdiv

	func get_pixels_per_major(grid: GridHelper) -> float:
		"""Calculate pixel spacing for one major interval."""
		match unit:
			TimeUnit.MILLISECONDS:
				return grid.get_pixels_per_second() * (major_interval / 1000.0)
			TimeUnit.SECONDS:
				return grid.get_pixels_per_second() * major_interval
			TimeUnit.MINUTES:
				return grid.get_pixels_per_minute() * major_interval
			TimeUnit.HOURS:
				return grid.get_pixels_per_hour() * major_interval
		return 0.0


func _determine_best_scale() -> RulerScale:
	"""Find the best scale based on current zoom level."""
	var best_scale = null
	var best_spacing = 0.0

	for scale_data in RULER_SCALES:
		var scale = RulerScale.new(scale_data[0], scale_data[1], scale_data[2])
		var spacing = scale.get_pixels_per_major(grid_helper)

		# Find the scale that gets closest to min_major_spacing without going under
		if spacing >= min_major_spacing:
			if best_scale == null or spacing < best_spacing:
				best_scale = scale
				best_spacing = spacing

	# Fallback to the largest scale if nothing fits
	if best_scale == null:
		var last = RULER_SCALES[RULER_SCALES.size() - 1]
		best_scale = RulerScale.new(last[0], last[1], last[2])

	return best_scale

func _format_time_label(ticks: int, scale: RulerScale) -> String:
	"""Format a time label for the given ticks and scale."""
	var total_seconds = grid_helper.ticks_to_seconds(ticks)
	var hours = int(total_seconds / 3600.0)
	var minutes = int((total_seconds - hours * 3600.0) / 60.0)
	var seconds = total_seconds - hours * 3600.0 - minutes * 60.0
	var whole_seconds = int(seconds)
	var milliseconds = int((seconds - whole_seconds) * 1000.0)

	match scale.unit:
		TimeUnit.MILLISECONDS:
			# For milliseconds, show SS.mmm format
			return "%d.%03d" % [whole_seconds, milliseconds]
		TimeUnit.SECONDS:
			# Show MM:SS or MM:SS.m depending on interval
			if scale.major_interval < 1.0:
				# Sub-second intervals show milliseconds
				return "%02d:%02d.%03d" % [minutes, whole_seconds, milliseconds]
			elif scale.major_interval < 10.0:
				# Short intervals can show decimals
				return "%02d:%02d.%01d" % [minutes, whole_seconds, milliseconds / 100]
			else:
				# Longer intervals just show seconds
				return "%02d:%02d" % [minutes, whole_seconds]
		TimeUnit.MINUTES:
			# Show HH:MM:SS format
			return "%02d:%02d:%02d" % [hours, minutes, whole_seconds]
		TimeUnit.HOURS:
			# Show HH:MM format
			return "%02d:%02d" % [hours, minutes]

	return ""

func _draw_ruler() -> void:
	"""Draw ruler with time markers."""

	var major_line_color = get_theme_color("bar_line_color", "Ruler")
	var minor_line_color = get_theme_color("beat_line_color", "Ruler")
	if not major_line_color:
		major_line_color = Color(0.8, 0.8, 0.8)
	if not minor_line_color:
		minor_line_color = Color(0.5, 0.5, 0.5)

	# Get the best scale for current zoom
	var scale = _determine_best_scale()

	# Calculate visible range (accounting for scroll)
	var scroll_offset = grid_helper.scroll_position
	var start_x = 0.0
	var end_x = size.x - offset_x

	# Convert visible pixel range to ticks
	var start_ticks = grid_helper.pixels_to_ticks(start_x + scroll_offset)
	var end_ticks = grid_helper.pixels_to_ticks(end_x + scroll_offset)

	# Convert to time units based on scale
	var start_time: float
	var end_time: float

	match scale.unit:
		TimeUnit.MILLISECONDS:
			start_time = grid_helper.ticks_to_seconds(start_ticks) * 1000.0
			end_time = grid_helper.ticks_to_seconds(end_ticks) * 1000.0
		TimeUnit.SECONDS:
			start_time = grid_helper.ticks_to_seconds(start_ticks)
			end_time = grid_helper.ticks_to_seconds(end_ticks)
		TimeUnit.MINUTES:
			start_time = grid_helper.ticks_to_minutes(start_ticks)
			end_time = grid_helper.ticks_to_minutes(end_ticks)
		TimeUnit.HOURS:
			start_time = grid_helper.ticks_to_hours(start_ticks)
			end_time = grid_helper.ticks_to_hours(end_ticks)

	# Find first major line (snap to major intervals)
	var first_major_time = floor(start_time / scale.major_interval) * scale.major_interval
	var current_time = first_major_time

	# Generate major and minor lines
	while current_time <= end_time + scale.major_interval:
		var current_ticks: int
		match scale.unit:
			TimeUnit.MILLISECONDS:
				current_ticks = grid_helper.seconds_to_ticks(current_time / 1000.0)
			TimeUnit.SECONDS:
				current_ticks = grid_helper.seconds_to_ticks(current_time)
			TimeUnit.MINUTES:
				current_ticks = grid_helper.minutes_to_ticks(current_time)
			TimeUnit.HOURS:
				current_ticks = grid_helper.hours_to_ticks(current_time)

		var x = grid_helper.ticks_to_pixels(current_ticks) - scroll_offset + offset_x

		# Only draw if within visible bounds
		if x >= offset_x and x <= size.x:
			# Draw major line (full height)
			draw_line(Vector2(x, 0), Vector2(x, size.y), major_line_color, 2.0, true)

			# Draw time label
			var label = _format_time_label(current_ticks, scale)
			draw_string(ThemeDB.fallback_font, Vector2(x + 4, size.y - 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

		# Draw minor subdivision lines
		if scale.subdivisions > 1:
			var minor_interval = scale.major_interval / float(scale.subdivisions)
			for i in range(1, scale.subdivisions):
				var minor_time = current_time + (minor_interval * i)
				var minor_ticks: int
				match scale.unit:
					TimeUnit.MILLISECONDS:
						minor_ticks = grid_helper.seconds_to_ticks(minor_time / 1000.0)
					TimeUnit.SECONDS:
						minor_ticks = grid_helper.seconds_to_ticks(minor_time)
					TimeUnit.MINUTES:
						minor_ticks = grid_helper.minutes_to_ticks(minor_time)
					TimeUnit.HOURS:
						minor_ticks = grid_helper.hours_to_ticks(minor_time)

				var minor_x = grid_helper.ticks_to_pixels(minor_ticks) - scroll_offset + offset_x

				if minor_x >= offset_x and minor_x <= size.x:
					_draw_tick_line(minor_x, 0.5, minor_line_color)

		current_time += scale.major_interval

func _gui_input(event: InputEvent) -> void:
	"""Handle ruler clicks to set start position (snapped to major grid lines)."""
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not grid_helper:
			return

		# Get click position relative to ruler (includes offset_x area)
		var click_x = event.position.x

		# Adjust for offset_x to get position in timeline coordinates
		var timeline_screen_x = click_x - offset_x

		# Convert from screen coordinates to timeline pixels (accounting for scroll)
		var timeline_pixel_x = grid_helper.scroll_position + timeline_screen_x

		# Convert timeline pixel position to ticks
		var clicked_ticks = grid_helper.pixels_to_ticks(timeline_pixel_x)

		# Get current scale and snap to major intervals
		var scale = _determine_best_scale()
		var snapped_ticks: int

		match scale.unit:
			TimeUnit.MILLISECONDS:
				var clicked_ms = grid_helper.ticks_to_seconds(clicked_ticks) * 1000.0
				var snapped_ms = round(clicked_ms / scale.major_interval) * scale.major_interval
				snapped_ticks = grid_helper.seconds_to_ticks(snapped_ms / 1000.0)
			TimeUnit.SECONDS:
				var clicked_seconds = grid_helper.ticks_to_seconds(clicked_ticks)
				var snapped_seconds = round(clicked_seconds / scale.major_interval) * scale.major_interval
				snapped_ticks = grid_helper.seconds_to_ticks(snapped_seconds)
			TimeUnit.MINUTES:
				var clicked_minutes = grid_helper.ticks_to_minutes(clicked_ticks)
				var snapped_minutes = round(clicked_minutes / scale.major_interval) * scale.major_interval
				snapped_ticks = grid_helper.minutes_to_ticks(snapped_minutes)
			TimeUnit.HOURS:
				var clicked_hours = grid_helper.ticks_to_hours(clicked_ticks)
				var snapped_hours = round(clicked_hours / scale.major_interval) * scale.major_interval
				snapped_ticks = grid_helper.hours_to_ticks(snapped_hours)

		# Emit signal to request start position change
		start_position_requested.emit(snapped_ticks)
		get_tree().root.set_input_as_handled()

