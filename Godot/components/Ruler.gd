# Draws a ruler with vertical lines at grid positions (beats, bars, ticks)
# Shows bar numbers and beat markers. Clicks snap to the visible musical grid
# (BaseRuler's default); scrubbing and time-range gestures come from BaseRuler.
@tool
class_name Ruler extends BaseRuler

## Bar lines with numbers, then half-height beat and quarter-height subdivision ticks.
func _draw_ruler() -> void:
	var bar_line_color = ruler_color(&"bar_line_color")
	var beat_line_color = ruler_color(&"beat_line_color")
	var subdivision_line_color = ruler_color(&"subdivision_line_color")

	# GridHelper accounts for scroll, so line.x is already in ruler space
	var grid_lines = grid_helper.get_visible_grid_lines(0.0, size.x - offset_x, offset_x)
	for line in grid_lines:
		var x = line.x
		if x < offset_x or x > size.x:
			continue
		match line.type:
			GridHelper.GridLineType.BAR:
				# Whole-pixel rect at the rounded x, exactly as GridRenderer draws its bar
				# lines, so ruler and note-grid bars land on the same pixel columns.
				draw_rect(Rect2(roundf(x) - 1.0, 0.0, 2.0, size.y), bar_line_color, true, -1.0, false)
				draw_string(ThemeDB.fallback_font, Vector2(x + 4, size.y - 4), str(line.bar_number), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
			GridHelper.GridLineType.BEAT:
				_draw_tick_line(x, 0.5, beat_line_color)
			GridHelper.GridLineType.SUBDIVISION:
				_draw_tick_line(x, 0.25, subdivision_line_color)
