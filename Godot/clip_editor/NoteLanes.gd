# Renders horizontal note lines for note/key lanes,
@tool
class_name NoteLanes extends Control

var grid_helper : GridHelper = GridHelper.new()
@export var key_height := 20.0:
	set(kh):
		if key_height != kh:
			key_height = kh
			update_minimum_size()
			queue_redraw()

@export var note_lane_color_white := Color("666"):
	set(c):
		note_lane_color_white = c
		queue_redraw()

@export var note_lane_color_black := Color("444"):
	set(c):
		note_lane_color_black = c
		queue_redraw()

@export var border_color := Color("#252525"):
	set(c):
		border_color = c
		queue_redraw()

## Line between natural semitone neighbours (E/F and B/C).
@export var semitone_border_color := Color("#3a3a3a"):
	set(c):
		semitone_border_color = c
		queue_redraw()

func _get_minimum_size() -> Vector2:
	return Vector2(100, note_to_y_bottom(0))

# returns the top Y value of the given note lane
func note_to_y(note : int):
	return (127.0 - note) * key_height

# returns the bottom Y value of the given note lane
func note_to_y_bottom(note : int):
	return note_to_y(note) + key_height

# returns the center Y value of the given note lane
func note_to_y_center(note : int):
	return note_to_y(note) + (key_height * 0.5)

func _draw() -> void:
	_draw_lanes()

func _draw_lanes():
	var w = size.x
	
	for note in 128:
		var y = note_to_y(note)
		var bottom = note_to_y_bottom(note)
		var black = Midi.is_black_key(note)
		var c = note_lane_color_black if black else note_lane_color_white
		draw_rect(Rect2(0, y, w, key_height), c, true, -1.0, false)
		
		if note < 127:
			draw_line(Vector2(0, bottom), Vector2(size.x, bottom), border_color, 0.5, true)

	# E/F and B/C boundaries: the bottom edge of every F and C lane.
	for note in 128:
		var n = Midi.get_note_in_octave(note)
		if note > 0 and (n == 0 or n == 5):
			var bottom = note_to_y_bottom(note)
			draw_line(Vector2(0, bottom), Vector2(w, bottom), semitone_border_color, 1.0, false)
