# A piano keyboard in vertical orientation
# supporting component for midi note editor

@tool
class_name VPiano extends Control

@export var key_height := 20.0:
	set(kh):
		if key_height != kh:
			key_height = kh
			update_minimum_size()
			queue_redraw()

@export var minimum_width := 100.0:
	set(mw):
		minimum_width = mw

@export var key_color_white := Color.WHITE_SMOKE:
	set(kcw):
		if key_color_white != kcw:
			key_color_white = kcw
			queue_redraw()
			
@export var key_color_black := Color("#222"):
	set(kcb):
		if key_color_black != kcb:
			key_color_black = kcb
			queue_redraw()

@export var invert_colors := false:
	set(ic):
		invert_colors = ic
		queue_redraw()

@export var key_color_border := Color("#444"):
	set(kcbo):
		if key_color_border != kcbo:
			key_color_border = kcbo
			queue_redraw()

@export var black_white_ratio := 0.7

@export var border_width := 1.0

@export var border_color := Color("#222"):
	set(bc):
		if border_color != bc:
			border_color = bc
			queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(minimum_width, note_to_y_bottom(0))

# returns the top Y value of the given note lane
func note_to_y(note : int):
	return (127.0 - note) * key_height

# returns the bottom Y value of the given note lane
func note_to_y_bottom(note : int):
	return note_to_y(note) + key_height

# returns the center Y value of the given note lane
func note_to_y_center(note : int):
	return note_to_y(note) + (key_height * 0.5)

func get_note_width(note : int) -> int:
	if Midi.is_black_key(note):
		return size.x * black_white_ratio - 1
	else:
		return size.x - 1

# note rect is expanded vertically to account for differing white key heights
func get_note_rect(note : int) -> Rect2:
	var r = Rect2(0, note_to_y(note), get_note_width(note), key_height)
	
	var n = Midi.get_note_in_octave(note)
	
	if n == 0 or n == 5: # grow top
		r = r.grow_side(SIDE_TOP, key_height * 0.5)
	if n == 2 or n == 7 or n == 9: # grow both
		r = r.grow_side(SIDE_TOP, key_height * 0.5)
		r = r.grow_side(SIDE_BOTTOM, key_height * 0.5)
	if n == 4 or n == 11: # grow down
		r = r.grow_side(SIDE_BOTTOM, key_height * 0.5)
	
	return r

# can later choose to only draw C, or a certain key/scale/mode
func note_has_label(note : int) -> bool:
	if Midi.get_note_in_octave(note) == 0:
		return true
	return true


func _draw_key(note : int):
	var black = Midi.is_black_key(note)
	var color = key_color_black if black else key_color_white
	if invert_colors:
		color = key_color_black if not black else key_color_white
	
	var note_rect = get_note_rect(note)
	
	# draw key
	draw_rect(note_rect, color, true, -1.0, true)
	
	# draw border
	if not black:
		draw_rect(note_rect, key_color_border, false, 0.5, true)
	
	# draw label?
	if note_has_label(note):
		var font = get_theme_default_font()
		var font_size = 14
		var label = Midi.midi_to_note_name(note)
		var label_size = font.get_string_size(label,HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, TextServer.JUSTIFICATION_NONE,TextServer.DIRECTION_LTR,TextServer.ORIENTATION_HORIZONTAL)
		var label_y = note_to_y_center(note) + (label_size.y * 0.3)
		var label_color = key_color_white if black else key_color_black
		if invert_colors:
			label_color = key_color_black if black else key_color_white
		draw_string(font, Vector2(4, label_y), Midi.midi_to_note_name(note), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, label_color)

func _draw():
	var count = 0
	
	# draw white keys
	for note in Midi.MIDI_MAX + 1:
		if Midi.is_white_key(note):
			_draw_key(note)
			count += 1
	
	# draw black keys
	for note in Midi.MIDI_MAX + 1:
		if Midi.is_black_key(note):
			_draw_key(note)
			count += 1
	
	# border
	if border_width > 0:
		draw_line(Vector2(size.x, 0), Vector2(size.x, size.y), border_color, border_width, true)
	
	print("drew ", count, " keys.")
