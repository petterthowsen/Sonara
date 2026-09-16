# A piano keyboard in vertical orientation
# supporting component for midi note editor

@tool
class_name VPiano extends Control

## Shared pitch <-> row <-> Y math, handed down by MidiEditor. Defaults to its own
## chromatic layout so the @tool preview still renders in the Godot editor.
var layout: LaneLayout = LaneLayout.chromatic():
	set(l):
		if layout == l:
			return
		if layout and layout.changed.is_connected(_on_layout_changed):
			layout.changed.disconnect(_on_layout_changed)
		layout = l if l else LaneLayout.chromatic()
		layout.changed.connect(_on_layout_changed)
		_on_layout_changed()

## Row height. Kept as an export so the scene and the @tool preview still set it;
## it simply forwards to the shared layout.
@export var key_height := 20.0:
	get:
		return layout.row_height if layout else 20.0
	set(kh):
		if layout and not is_equal_approx(layout.row_height, kh):
			layout.row_height = kh

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

## Effective note map. Mapped keys show the entry name in place of the note name
## and are tinted with the entry colour (REQ-013). Null means no map.
var note_map: NoteMap = null:
	set(m):
		note_map = m
		queue_redraw()

## How strongly a mapped key is tinted with its entry colour.
@export_range(0.0, 1.0) var map_tint_strength := 0.55:
	set(t):
		map_tint_strength = t
		queue_redraw()

## Tint applied to the key under the mouse in the note area (or on the piano).
@export var hover_color := Color(0.45, 0.55, 1.0, 0.35):
	set(hc):
		hover_color = hc
		queue_redraw()

## Fraction of the key width at each end that clamps to min/max velocity.
@export_range(0.0, 0.45) var velocity_padding := 0.2

## Emitted when a key is clicked (or entered while dragging) with a velocity
## mapped from the horizontal click position: quiet at the left, loud at the right.
signal key_pressed(note: int, velocity: int)
signal key_released(note: int)

## Note lane to highlight, -1 for none. Set by the owner (e.g. MidiEditor hover).
var hovered_note := -1:
	set(hn):
		if hovered_note != hn:
			hovered_note = hn
			queue_redraw()

## Key currently held down by the mouse, -1 for none.
var pressed_note := -1:
	set(pn):
		if pressed_note != pn:
			pressed_note = pn
			queue_redraw()

var logger := Log.make("VPiano")


func _ready() -> void:
	# Pass so wheel scroll/zoom and middle-drag panning still reach MidiEditor.
	mouse_filter = Control.MOUSE_FILTER_PASS
	if layout and not layout.changed.is_connected(_on_layout_changed):
		layout.changed.connect(_on_layout_changed)


func _on_layout_changed() -> void:
	update_minimum_size()
	queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(minimum_width, layout.total_height())

# returns the top Y value of the given note lane
func note_to_y(note : int) -> float:
	return layout.pitch_to_y(note)

# returns the bottom Y value of the given note lane
func note_to_y_bottom(note : int) -> float:
	return layout.pitch_to_y_bottom(note)

# returns the center Y value of the given note lane
func note_to_y_center(note : int) -> float:
	return layout.pitch_to_y_center(note)

func get_note_width(note : int) -> int:
	if Midi.is_black_key(note):
		return size.x * black_white_ratio - 1
	else:
		return size.x - 1

# note rect is expanded vertically to account for differing white key heights
func get_note_rect(note : int) -> Rect2:
	var h := layout.row_height
	var r = Rect2(0, note_to_y(note), get_note_width(note), h)
	
	var n = Midi.get_note_in_octave(note)
	
	if n == 0 or n == 5: # grow top
		r = r.grow_side(SIDE_TOP, h * 0.5)
	if n == 2 or n == 7 or n == 9: # grow both
		r = r.grow_side(SIDE_TOP, h * 0.5)
		r = r.grow_side(SIDE_BOTTOM, h * 0.5)
	if n == 4 or n == 11: # grow down
		r = r.grow_side(SIDE_BOTTOM, h * 0.5)
	
	return r

# can later choose to only draw C, or a certain key/scale/mode
func note_has_label(note : int) -> bool:
	if Midi.get_note_in_octave(note) == 0:
		return true
	return true


## Key under a local position. Black keys sit on top, so they win where they overlap.
func get_note_at_position(pos: Vector2) -> int:
	if pos.x < 0 or pos.x > size.x or layout.row_height <= 0:
		return -1
	var lane := layout.y_to_pitch(pos.y)
	for note in [lane, lane + 1, lane - 1]:
		if note >= 0 and note <= 127 and Midi.is_black_key(note) and get_note_rect(note).has_point(pos):
			return note
	for note in [lane, lane + 1, lane - 1]:
		if note >= 0 and note <= 127 and not Midi.is_black_key(note) and get_note_rect(note).has_point(pos):
			return note
	return lane


## Map a horizontal position across the key to a MIDI velocity (1-127).
func get_velocity_at_position(note: int, x: float) -> int:
	var width := float(get_note_width(note))
	if width <= 0:
		return 100
	var usable := 1.0 - velocity_padding * 2.0
	var t := clampf((x / width - velocity_padding) / usable, 0.0, 1.0)
	return clampi(roundi(lerpf(1.0, 127.0, t)), 1, 127)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_at(mb.position)
			else:
				_release_pressed()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			# Keep right-clicks from reaching MidiEditor's erase handling.
			accept_event()
	elif event is InputEventMouseMotion and pressed_note >= 0:
		# Glide across keys while held.
		var note := get_note_at_position(event.position)
		if note >= 0 and note != pressed_note:
			_release_pressed()
			_press_at(event.position)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_release_pressed()
	elif what == NOTIFICATION_PREDELETE:
		_release_pressed()


func _press_at(pos: Vector2) -> void:
	var note := get_note_at_position(pos)
	if note < 0:
		return
	pressed_note = note
	key_pressed.emit(note, get_velocity_at_position(note, pos.x))


func _release_pressed() -> void:
	if pressed_note < 0:
		return
	var note := pressed_note
	pressed_note = -1
	key_released.emit(note)


func _draw_key(note : int):
	var black = Midi.is_black_key(note)
	var color = key_color_black if black else key_color_white
	if invert_colors:
		color = key_color_black if not black else key_color_white

	# A mapped key takes its entry's colour and name (REQ-013).
	var entry_name := note_map.get_name(note) if note_map else ""
	var entry_color := note_map.get_color(note) if note_map else Color(0, 0, 0, 0)
	var mapped := entry_color.a > 0.0
	if mapped and map_tint_strength > 0.0:
		color = color.lerp(Color(entry_color.r, entry_color.g, entry_color.b, 1.0), map_tint_strength)
	
	var note_rect: Rect2 = get_note_rect(note)
	var is_pressed := note == pressed_note
	
	if is_pressed:
		# Depressed: the key sinks back (shorter), darkens, and its front edge casts a shadow.
		draw_rect(note_rect, color.darkened(0.25), true, -1.0, true)
		note_rect = note_rect.grow_side(SIDE_RIGHT, -3.0)
		color = color.darkened(0.12)
	
	# draw key
	draw_rect(note_rect, color, true, -1.0, true)
	
	if note == hovered_note or is_pressed:
		var hc := hover_color
		if is_pressed:
			hc.a = minf(1.0, hover_color.a * 1.6)
		draw_rect(note_rect, hc, true, -1.0, true)
	
	if is_pressed:
		var shadow := Color(0, 0, 0, 0.35)
		var edge_x := note_rect.end.x
		draw_rect(Rect2(edge_x - 2.0, note_rect.position.y, 2.0, note_rect.size.y), shadow, true, -1.0, false)
		draw_rect(Rect2(note_rect.position.x, note_rect.position.y, note_rect.size.x, 2.0), shadow, true, -1.0, false)
	
	# draw border
	if not black:
		draw_rect(note_rect, key_color_border, false, 0.5, true)
	
	# draw label?
	if note_has_label(note) or not entry_name.is_empty():
		var font = get_theme_default_font()
		var font_size = 14
		var label := entry_name if not entry_name.is_empty() else Midi.midi_to_note_name(note)
		var label_size = font.get_string_size(label,HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, TextServer.JUSTIFICATION_NONE,TextServer.DIRECTION_LTR,TextServer.ORIENTATION_HORIZONTAL)
		var label_y = note_to_y_center(note) + (label_size.y * 0.3)
		var label_color = key_color_white if black else key_color_black
		if invert_colors:
			label_color = key_color_black if black else key_color_white
		if mapped:
			# The tinted key can be any brightness, so pick text that reads on it.
			label_color = Utils.contrasting_text_color(color)
		var max_width := note_rect.size.x - 6.0
		draw_string(font, Vector2(4, label_y), label, HORIZONTAL_ALIGNMENT_LEFT, int(max_width), font_size, label_color)

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
