# Renders start/end marker of current NoteSelections
# and marquee box when box-selecting
class_name MidiEditorOverlays extends Control

# Box selection (set by MidiEditor when actively selecting)
var is_box_selecting: bool = false
var box_selection_rect: Rect2 = Rect2()

# Selection range markers (set by MidiEditor when notes are selected)
var show_selection_markers: bool = false
var selection_start_x: float = 0.0
var selection_end_x: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_process(false)


func _draw() -> void:
	"""Draw selection box and range markers."""
	# Draw box selection while actively selecting
	if is_box_selecting and box_selection_rect.size.length() > 0:
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.1))
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.5), false, 2.0)

	# Draw selection range markers (vertical lines)
	if show_selection_markers:
		var line_color = Color(0.4, 0.8, 1.0, 0.6)
		var line_width = 2.0
		var height = size.y

		# Draw start marker
		draw_line(
			Vector2(selection_start_x, 0),
			Vector2(selection_start_x, height),
			line_color,
			line_width
		)

		# Draw end marker
		draw_line(
			Vector2(selection_end_x, 0),
			Vector2(selection_end_x, height),
			line_color,
			line_width
		)
