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
	var fh = font.get_height(font_size)
	var sz = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TextServer.JUSTIFICATION_NONE,TextServer.DIRECTION_LTR,TextServer.ORIENTATION_HORIZONTAL)

	draw_string(font, Vector2(-sz.x/2, (sz.y / 3)), text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE, TextServer.JUSTIFICATION_NONE,TextServer.DIRECTION_LTR,TextServer.ORIENTATION_HORIZONTAL)
