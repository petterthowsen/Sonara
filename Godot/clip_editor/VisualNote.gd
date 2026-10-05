# VisualNote.gd
# Visual representation of a MIDI note in the piano roll editor
# Note: All interaction handling is done by NoteEditor, this class is purely visual

class_name VisualNote extends Panel

# UI references
@onready var label: Label = $Label

# Data reference
var midi_note_data: MidiNoteData = null  # Reference to data layer MidiNoteData

## Track mode: the ClipInstance this note is shown through (a clip used several times
## on a track gets one VisualNote per instance). Null in clip mode and for pending duplicates.
## Untyped on purpose: naming ClipInstance (or NoteContainer below) here would make every
## script that names VisualNote compile them too, before the autoloads they use exist.
var clip_instance = null

## Track mode, looped instance: 0 for the note where the instance first plays it, k >= 1 for
## its repeat in the k-th loop segment (ClipInstance.get_loop_segments). A repeat shares the
## note's MidiNoteData, so editing it edits the note (and every other repeat of it).
var repeat_pass: int = 0

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

## A Ctrl+drag duplicate that isn't in any clip yet: drawn translucent, ignored by
## hit-testing, selection and playback until the drag commits it.
var is_pending: bool = false:
	set(p):
		is_pending = p
		modulate.a = 0.6 if p else 1.0

## True while the note is drawn as a Drum View hit marker rather than a bar.
## The stored duration is untouched either way (REQ-022).
var drum_mode: bool = false

## Velocity brightness is rounded to this many steps, so the notes of one colour share a
## small set of styleboxes (see NoteContainer.note_style).
const VELOCITY_SHADES: int = 16

## The scene's stylebox, before any shared per-colour box replaces it.
var _base_style: StyleBoxFlat = null
## Fallback box for a note with no NoteContainer parent (it can't share one).
var _own_style: StyleBoxFlat = null
## The box currently applied as the panel override.
var _applied_style: StyleBoxFlat = null
## Row height update_label_visibility last applied, or -1 to force the next one.
var _label_row_height: float = -1.0
var _label_text_color: Color = Color(-1, -1, -1)

func _ready():
	# NoteEditor does all hit-testing on its own (MidiEditor._note_hit) and sets the
	# hover cursor, so notes never take part in GUI picking.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	if label:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base_style = get_theme_stylebox("panel") as StyleBoxFlat
	_apply_absolute_layout()
	if label:
		label.visible = not drum_mode
	_update_visual()


## Keep the note in absolute piano-roll coordinates. Fill-parent layout stretches
## notes with the editor, which hides horizontal zoom on the focused (expanded) editor.
## Only needed once: nothing changes these afterwards.
func _apply_absolute_layout() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	anchor_right = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	custom_minimum_size = Vector2.ZERO


## Piano roll: the note is a bar spanning its duration, with a pitch label.
func prepare_piano_roll_layout() -> void:
	set_drum_mode(false)


## Drum View: the note is a hit marker at its start instead of a bar spanning its
## duration. Velocity shading is kept, the pitch label is hidden (a whole row is
## one pitch already) and the note cannot be resized (REQ-022).
func prepare_drum_layout() -> void:
	set_drum_mode(true)


## Switch between bar and hit marker. Does nothing when the note is already in that mode,
## so repositioning every note on zoom stays cheap.
func set_drum_mode(on: bool) -> void:
	if drum_mode == on:
		return
	drum_mode = on
	_label_row_height = -1.0
	if label:
		label.visible = not on


## Height of the hit marker for a given row height: it fills the row, minus a
## hairline so neighbouring rows stay readable.
static func drum_marker_height(row_height: float) -> float:
	return maxf(3.0, row_height - 2.0)


## Cursor for the mouse at `local_pos` over this note (NoteEditor shows it while hovering).
func cursor_shape_at(local_pos: Vector2) -> Control.CursorShape:
	return Control.CURSOR_HSIZE if _is_over_resize_handle(local_pos) else Control.CURSOR_POINTING_HAND


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
		# Map velocity (1/127..1) to brightness (0.2-0.8)
		var velocity = midi_note_data.velocity
		var velocity_normalized = (velocity * 127.0 - 1.0) / 126.0  # Normalize to 0.0-1.0
		velocity_normalized = roundf(velocity_normalized * (VELOCITY_SHADES - 1)) / (VELOCITY_SHADES - 1)
		var brightness = lerp(0.2, 0.8, velocity_normalized)
		
		display_color = Color.from_hsv(
			display_color.h,
			display_color.s,
			brightness
		)
	
	# Override with full brightness if selected
	if is_selected:
		display_color.v = clamp(display_color.v + selection_brightness_boost, 0.0, 1.0)

	_apply_bg_color(Utils.display_color(display_color))

	# Update label
	if label and midi_note_data:
		var note_name = Midi.midi_to_note_name(midi_note_data.note)
		if label.text != note_name:
			label.text = note_name
		_apply_label_color(Utils.contrasting_text_color(display_color))


## Use the container's shared stylebox for this colour instead of editing a per-note copy.
func _apply_bg_color(color: Color) -> void:
	if _base_style == null:
		return
	var box: StyleBoxFlat
	var container := get_parent()
	if container and container.has_method(&"note_style"):
		box = container.note_style(_base_style, color)
	else:
		if _own_style == null:
			_own_style = _base_style.duplicate()
		_own_style.bg_color = color
		box = _own_style
	if box != _applied_style:
		_applied_style = box
		add_theme_stylebox_override("panel", box)


func _apply_label_color(text_color: Color) -> void:
	if text_color == _label_text_color:
		return
	_label_text_color = text_color
	var container := get_parent()
	if container and container.has_method(&"note_label_settings") and label.label_settings:
		label.label_settings = container.note_label_settings(label.label_settings, text_color)
		_label_row_height = -1.0
	else:
		Utils.apply_label_font_color(label, text_color)

## Label font size at full row height, and the smallest size still worth drawing.
const LABEL_FONT_SIZE_MAX: int = 16
const LABEL_FONT_SIZE_MIN: int = 7

## Font size that fits a row of the given height, or 0 when the row is too short
## for any readable label.
static func label_font_size_for(row_height: float) -> int:
	var fs := mini(LABEL_FONT_SIZE_MAX, int(row_height * 0.6))
	return fs if fs >= LABEL_FONT_SIZE_MIN else 0


func update_label_visibility(target_height: float) -> void:
	"""Show the label at a font size that fits the row, hiding it once too small.

	The notes of one NoteContainer share its LabelSettings (one per text colour), and
	every note in the editor has the same row height, so writing the font size here
	resizes all labels together through a single resource change instead of per-note
	theme overrides. Skipped when the row height hasn't changed since the last call."""
	if not label:
		return

	if drum_mode:
		label.visible = false
		return

	if target_height == _label_row_height:
		return
	_label_row_height = target_height
	var fs := label_font_size_for(target_height)
	label.visible = fs > 0
	if fs > 0 and label.label_settings and label.label_settings.font_size != fs:
		label.label_settings.font_size = fs


func _is_over_resize_handle(pos: Vector2) -> bool:
	"""Check if mouse is over the resize handle."""
	if drum_mode:
		# Hit markers have no length to drag (REQ-022).
		return false
	return pos.x >= size.x - RESIZE_HANDLE_WIDTH
