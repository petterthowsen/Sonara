@tool
class_name VerticalLabel extends Control

enum Direction {Up, Down}

@export var text : String = "Label":
	set(t):
		if text != t:
			text = t
			queue_redraw()

@export var direction : Direction = Direction.Up
@export var font_size := 16:
	set(fs):
		if font_size != fs:
			font_size = fs
			queue_redraw()

func _draw():
	# draw the text
	var center = Vector2(size.x / 2, size.y / 2)
	
	draw_set_transform(center, deg_to_rad(-90), Vector2.ONE)
	
	var font = get_theme_default_font()
	var display_text: String = text
	# Fit text within available vertical pixels (since it's rotated -90deg)
	var available: float = size.y
	if available > 0:
		var full_sz = font.get_string_size(display_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TextServer.JUSTIFICATION_NONE, TextServer.DIRECTION_LTR, TextServer.ORIENTATION_HORIZONTAL)
		if full_sz.x > available:
			var left: int = 0
			var right: int = display_text.length()
			var best: int = 0
			while left <= right:
				var mid: int = int(floor((left + right) / 2))
				var candidate: String = (display_text.substr(0, mid) + "...") if mid > 0 else "..."
				var csz = font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TextServer.JUSTIFICATION_NONE, TextServer.DIRECTION_LTR, TextServer.ORIENTATION_HORIZONTAL)
				if csz.x <= available:
					best = mid
					left = mid + 1
				else:
					right = mid - 1
			display_text = (display_text.substr(0, best) + "...") if best > 0 else "..."
	var sz = font.get_string_size(display_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TextServer.JUSTIFICATION_NONE,TextServer.DIRECTION_LTR,TextServer.ORIENTATION_HORIZONTAL)
	
	draw_string(font, Vector2(-sz.x/2, (sz.y / 3)), display_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE, TextServer.JUSTIFICATION_NONE,TextServer.DIRECTION_LTR,TextServer.ORIENTATION_HORIZONTAL)
