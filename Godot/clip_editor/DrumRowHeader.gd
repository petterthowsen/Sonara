# The Drum View replacement for VPiano: one labelled, coloured row per LaneLayout
# row (REQ-017, REQ-018).
#
# It emits the same `key_pressed` / `key_released` signals as VPiano and takes the
# same slot in MidiEditor's HBox, so MidiEditor doesn't care which header is
# showing — audition, hover highlighting and note preview all keep working.
@tool
class_name DrumRowHeader extends Control

## Same contract as VPiano: velocity comes from the horizontal click position.
signal key_pressed(note: int, velocity: int)
signal key_released(note: int)

## Shared pitch <-> row <-> Y math, handed down by MidiEditor.
var layout: LaneLayout = LaneLayout.chromatic():
	set(l):
		if layout == l:
			return
		if layout and layout.changed.is_connected(_on_layout_changed):
			layout.changed.disconnect(_on_layout_changed)
		layout = l if l else LaneLayout.chromatic()
		layout.changed.connect(_on_layout_changed)
		_on_layout_changed()

## Effective map supplying row names and colours. Rows with no entry fall back to
## the note name and a muted style (REQ-017).
var note_map: NoteMap = null:
	set(m):
		note_map = m
		queue_redraw()

@export var minimum_width := 100.0:
	set(mw):
		minimum_width = mw
		update_minimum_size()

## Background of a row whose pitch has a map entry (tinted with the entry colour).
@export var row_color := Color("#3a3a3a"):
	set(c):
		row_color = c
		queue_redraw()

## Background of a row whose pitch is unmapped (REQ-017).
@export var unmapped_row_color := Color("#252525"):
	set(c):
		unmapped_row_color = c
		queue_redraw()

@export var border_color := Color("#1c1c1c"):
	set(c):
		border_color = c
		queue_redraw()

## How strongly a mapped row is tinted with its entry colour.
@export_range(0.0, 1.0) var map_tint_strength := 0.55:
	set(t):
		map_tint_strength = t
		queue_redraw()

@export var hover_color := Color(0.45, 0.55, 1.0, 0.35):
	set(hc):
		hover_color = hc
		queue_redraw()

## Fraction of the row width at each end that clamps to min/max velocity.
@export_range(0.0, 0.45) var velocity_padding := 0.2

## Row pitch to highlight, -1 for none. Set by the owner (MidiEditor hover).
var hovered_note := -1:
	set(hn):
		if hovered_note != hn:
			hovered_note = hn
			queue_redraw()

## Row currently held down by the mouse, -1 for none.
var pressed_note := -1:
	set(pn):
		if pressed_note != pn:
			pressed_note = pn
			queue_redraw()


func _ready() -> void:
	# Pass so wheel scroll/zoom and middle-drag panning still reach MidiEditor,
	# exactly as VPiano does.
	mouse_filter = Control.MOUSE_FILTER_PASS
	if layout and not layout.changed.is_connected(_on_layout_changed):
		layout.changed.connect(_on_layout_changed)


func _on_layout_changed() -> void:
	update_minimum_size()
	queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(minimum_width, layout.total_height())


## Row pitch under a local position, or -1 outside the control.
func get_note_at_position(pos: Vector2) -> int:
	if pos.x < 0 or pos.x > size.x or layout.row_height <= 0 or layout.row_count() == 0:
		return -1
	if pos.y < 0 or pos.y >= layout.total_height():
		return -1
	return layout.y_to_pitch(pos.y)


## Same velocity mapping as VPiano, so a row label plays like a key.
func get_velocity_at_position(x: float) -> int:
	var width := size.x
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
		# Glide across rows while held.
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
	key_pressed.emit(note, get_velocity_at_position(pos.x))


func _release_pressed() -> void:
	if pressed_note < 0:
		return
	var note := pressed_note
	pressed_note = -1
	key_released.emit(note)


func _draw() -> void:
	var font := get_theme_default_font()
	var font_size := 13
	var h := layout.row_height
	var w := size.x

	for row in layout.row_count():
		var note := layout.pitch_at_row(row)
		var y := layout.row_to_y(row)
		var entry_name := note_map.get_name(note) if note_map else ""
		var entry_color := note_map.get_color(note) if note_map else Color(0, 0, 0, 0)
		var mapped := entry_color.a > 0.0

		var bg := row_color if mapped else unmapped_row_color
		if mapped and map_tint_strength > 0.0:
			bg = bg.lerp(Color(entry_color.r, entry_color.g, entry_color.b, 1.0), map_tint_strength)

		var rect := Rect2(0, y, w, h)
		var is_pressed := note == pressed_note
		if is_pressed:
			bg = bg.lightened(0.15)
		draw_rect(rect, bg, true, -1.0, false)

		if note == hovered_note or is_pressed:
			var hc := hover_color
			if is_pressed:
				hc.a = minf(1.0, hover_color.a * 1.6)
			draw_rect(rect, hc, true, -1.0, false)

		# Unmapped rows are marked: a note name, dimmer and italic-ish by way of a
		# leading dot, so they read as "this row only exists because it has notes".
		var label := entry_name if not entry_name.is_empty() else "· " + Midi.midi_to_note_name(note)
		var text_color := Utils.contrasting_text_color(bg)
		if not mapped:
			text_color.a = 0.65
		var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			TextServer.JUSTIFICATION_NONE, TextServer.DIRECTION_LTR, TextServer.ORIENTATION_HORIZONTAL)
		var label_y := y + h * 0.5 + label_size.y * 0.3
		draw_string(font, Vector2(6, label_y), label, HORIZONTAL_ALIGNMENT_LEFT,
			int(maxf(0.0, w - 12.0)), font_size, text_color)

		draw_line(Vector2(0, y + h), Vector2(w, y + h), border_color, 1.0, false)

	# Right-hand edge, matching VPiano's border.
	draw_line(Vector2(w, 0), Vector2(w, layout.total_height()), border_color, 1.0, true)
