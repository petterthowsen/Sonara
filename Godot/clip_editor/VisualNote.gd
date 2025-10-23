# VisualNote.gd
# Visual representation of a MIDI note in the piano roll editor
# Note: All interaction handling is done by NoteEditor, this class is purely visual

class_name VisualNote extends PanelContainer

# UI references
@onready var label: Label = $Label

# Data reference
var midi_note_data: MidiNoteData = null  # Reference to data layer MidiNoteData

# Visual state
var is_selected: bool = false
@export var base_color: Color = Color(0.3, 0.6, 0.9)
@export var selected_color: Color = Color(0.5, 0.8, 1.0)

# Resize handle size (pixels from right edge)
const RESIZE_HANDLE_WIDTH: float = 8.0

func _ready():
	mouse_filter = Control.MOUSE_FILTER_PASS
	
	# Allow resizing below default minimum (important for vertical zoom)
	custom_minimum_size = Vector2.ZERO

	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	
	# Update visual state
	_update_visual()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if _is_over_resize_handle(event.position):
			mouse_default_cursor_shape = Control.CURSOR_HSIZE
		else:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func bind_to_note(note: MidiNoteData) -> void:
	"""Bind this visual note to a data layer MidiNoteData."""
	midi_note_data = note
	_update_visual()

func set_selected(selected: bool) -> void:
	"""Set selection state."""
	is_selected = selected
	_update_visual()

func _update_visual() -> void:
	"""Update visual appearance based on state and data."""
	if not is_node_ready():
		return
	
	# Update color
	var color = selected_color if is_selected else base_color
	if has_theme_stylebox_override("panel"):
		var style: StyleBoxFlat = get_theme_stylebox("panel")
		if style:
			style.bg_color = color
	
	# Update label
	if label and midi_note_data:
		var note_name = Midi.midi_to_note_name(midi_note_data.note)
		label.text = note_name
		label.add_theme_color_override("font_color", Color.WHITE)

func update_label_visibility(target_height: float) -> void:
	"""Update label visibility based on target note height from MidiEditor."""
	if not label:
		return

	if target_height < 26.0:
		label.visible = false
	else:
		label.visible = true


func _is_over_resize_handle(pos: Vector2) -> bool:
	"""Check if mouse is over the resize handle."""
	return pos.x >= size.x - RESIZE_HANDLE_WIDTH
