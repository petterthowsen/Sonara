# VisualNote.gd
# Visual representation of a MIDI note in the piano roll editor
# Note: All interaction handling is done by NoteEditor, this class is purely visual

class_name VisualNote extends Panel

# UI references
@onready var label: Label = $Label

# Data reference
var midi_note_data: MidiNoteData = null  # Reference to data layer MidiNoteData

# Visual state
var is_selected: bool = false
var note_color: Color = Color(0.3, 0.6, 0.9)  # Base color (inherited from track)
@export var selection_brightness_boost: float = 0.3  # How much to brighten when selected

# Resize handle size (pixels from right edge)
const RESIZE_HANDLE_WIDTH: float = 8.0

## Width of a Drum View hit marker. Fixed on purpose: vertical zoom changes how
## tall a row is, never how long a hit looks. NoteContainer.drum_marker_size()
## still shrinks it to fit the grid step and the note's own length.
const DRUM_MARKER_WIDTH: float = 12.0

## True while the note is drawn as a Drum View hit marker rather than a bar.
## The stored duration is untouched either way (REQ-022).
var drum_mode: bool = false

func _ready():
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_NONE
	prepare_piano_roll_layout()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_update_visual()


## Keep the note in absolute piano-roll coordinates. Fill-parent layout stretches
## notes with the editor, which hides horizontal zoom on the focused (expanded) editor.
func prepare_piano_roll_layout() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	anchor_right = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	custom_minimum_size = Vector2.ZERO
	drum_mode = false
	if label:
		label.visible = true


## Drum View: the note is a hit marker at its start instead of a bar spanning its
## duration. Velocity shading is kept, the pitch label is hidden (a whole row is
## one pitch already) and the note cannot be resized (REQ-022).
func prepare_drum_layout() -> void:
	prepare_piano_roll_layout()
	drum_mode = true
	if label:
		label.visible = false


## Height of the hit marker for a given row height: it fills the row, minus a
## hairline so neighbouring rows stay readable.
static func drum_marker_height(row_height: float) -> float:
	return maxf(3.0, row_height - 2.0)


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


func set_color(color: Color) -> void:
	"""Set the base color for this note (typically from track color)."""
	note_color = color
	_update_visual()


func set_selected(selected: bool) -> void:
	"""Set selection state."""
	is_selected = selected
	_update_visual()

func _update_visual() -> void:
	"""Update visual appearance based on state and data."""
	if not is_node_ready():
		return
	
	# Start with base track color (clamp only for drawing)
	var display_color = Utils.display_color(note_color)
	
	# Always apply velocity-based brightness if we have note data
	if midi_note_data:
		# Map velocity (1-127) to brightness (0.2-0.8)
		var velocity = midi_note_data.velocity
		var velocity_normalized = (velocity - 1) / 126.0  # Normalize to 0.0-1.0
		var brightness = lerp(0.2, 0.8, velocity_normalized)
		
		display_color = Color.from_hsv(
			display_color.h,
			display_color.s,
			brightness
		)
	
	# Override with full brightness if selected
	if is_selected:
		display_color.v = clamp(display_color.v + selection_brightness_boost, 0.0, 1.0)

	# Update color
	var style: StyleBoxFlat = get_theme_stylebox("panel")
	if style:
		style.bg_color = Utils.display_color(display_color)

	# Update label
	if label and midi_note_data:
		var note_name = Midi.midi_to_note_name(midi_note_data.note)
		label.text = note_name
		Utils.apply_label_font_color(label, Utils.contrasting_text_color(display_color))

func update_label_visibility(target_height: float) -> void:
	"""Update label visibility based on target note height from MidiEditor."""
	if not label:
		return

	if drum_mode:
		label.visible = false
		return

	if target_height < 26.0:
		label.visible = false
	else:
		label.visible = true


func _is_over_resize_handle(pos: Vector2) -> bool:
	"""Check if mouse is over the resize handle."""
	if drum_mode:
		# Hit markers have no length to drag (REQ-022).
		return false
	return pos.x >= size.x - RESIZE_HANDLE_WIDTH
