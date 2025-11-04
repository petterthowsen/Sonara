class_name PlayheadLine extends Control

@export var color: Color = Color.WHITE:
	set(c):
		color = c
		queue_redraw()

@export var playing_texture: Texture:
	set(t):
		playing_texture = t
		queue_redraw()

var is_playing: bool = false:
	set(value):
		is_playing = value
		set_process(is_playing)
		queue_redraw()

var current_pps := -1

func _process(_delta: float) -> void:
	var pps = Sonara.editor.arranger.grid_helper.get_pixels_per_second()
	if pps != current_pps:
		current_pps = pps
		queue_redraw()

func _draw():
	# if playing, draw the texture
	var length = 16.0 * (current_pps / 100)
	length = clamp(length, 1, 128)
		
	if is_playing and length > 1:
		draw_texture_rect(playing_texture, Rect2(-length, 0, length, size.y), false, Color.WHITE)
	else:
		draw_line(Vector2(-1, 0), Vector2(1, size.y), color, 1.0, true)
