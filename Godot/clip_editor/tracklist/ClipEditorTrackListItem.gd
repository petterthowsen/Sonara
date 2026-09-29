# An item in the ClipEditor track list: track name on the track colour, plus a visibility and an
# editability toggle.
class_name ClipEditorTrackListItem extends PanelContainer

const SOLO_COLOR := Color("#ffb13b")
const EYE_ON := preload("res://assets/icons/eye.svg")
const EYE_OFF := preload("res://assets/icons/eye-off.svg")
const PENCIL_ON := preload("res://assets/icons/pencil.svg")
const PENCIL_OFF := preload("res://assets/icons/pencil-off.svg")
## Edit toggle alpha while the track is hidden (REQ-023).
const DIMMED_ALPHA := 0.4

@onready var label: Label = $HBox/Label
@onready var visible_toggle: Button = $HBox/VisibleToggle
@onready var edit_toggle: Button = $HBox/EditToggle

var track: Track:
	set = set_track

var _selected := false

signal pressed
## kind is a TrackToggleState.Kind.
signal toggle_pressed(kind: int, shift: bool)


func set_track(t: Track):
	"""Set the track and update visuals."""
	if track == t:
		return
	
	# Disconnect from old track signals
	if track:
		if track.name_changed.is_connected(_on_track_name_changed):
			track.name_changed.disconnect(_on_track_name_changed)
		if track.color_changed.is_connected(_on_track_color_changed):
			track.color_changed.disconnect(_on_track_color_changed)
	
	track = t
	
	# Connect to new track signals
	if track:
		track.name_changed.connect(_on_track_name_changed)
		track.color_changed.connect(_on_track_color_changed)
	
	if is_inside_tree():
		_update_label()
		_update_style()


func _ready():
	visible_toggle.gui_input.connect(_on_toggle_gui_input.bind(TrackToggleState.Kind.VISIBLE))
	edit_toggle.gui_input.connect(_on_toggle_gui_input.bind(TrackToggleState.Kind.EDITABLE))
	_update_label()
	_update_style()


func set_selected(selected: bool):
	"""Set selection state and update visuals."""
	if _selected != selected:
		_selected = selected
		_update_label()
		_update_style()


func _update_label():
	"""Update label text with track name."""
	if track:
		label.text = track.name
		label.modulate.a = 1.0 if _selected else 0.7
		_update_label_color()


## Track-coloured panel: soft border, or a white one when selected (REQ-012).
func _update_style() -> void:
	if not track:
		return
	var bg := Utils.display_color(track.color)
	bg.a = 1.0 if _selected else 0.7
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(4)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	if _selected:
		style.set_border_width_all(2)
		style.border_color = Color.WHITE
	else:
		style.set_border_width_all(1)
		var border := bg.lightened(0.25)
		border.a = 0.5
		style.border_color = border
	add_theme_stylebox_override("panel", style)
	_update_label_color()


## Black/white label based on the drawn track color.
func _update_label_color() -> void:
	if not track or not label:
		return
	var bg := Utils.display_color(track.color)
	Utils.apply_label_font_color(label, Utils.contrasting_text_color(bg))


## Sets the toggle icons, the solo colour and the dimmed edit toggle from `state`.
func refresh_toggles(state: TrackToggleState) -> void:
	if not track or not state:
		return
	var visible_on := state.is_on(track, TrackToggleState.Kind.VISIBLE)
	var edit_on := state.is_on(track, TrackToggleState.Kind.EDITABLE)
	visible_toggle.icon = EYE_ON if visible_on else EYE_OFF
	edit_toggle.icon = PENCIL_ON if edit_on else PENCIL_OFF
	edit_toggle.modulate.a = 1.0 if visible_on else DIMMED_ALPHA
	_set_toggle_color(visible_toggle, state.soloed_track(TrackToggleState.Kind.VISIBLE) == track)
	_set_toggle_color(edit_toggle, state.soloed_track(TrackToggleState.Kind.EDITABLE) == track)


func _set_toggle_color(button: Button, soloed: bool) -> void:
	var c := SOLO_COLOR if soloed else Utils.contrasting_text_color(Utils.display_color(track.color))
	button.add_theme_color_override("icon_normal_color", c)
	button.add_theme_color_override("icon_hover_color", c)
	button.add_theme_color_override("icon_pressed_color", c)
	button.add_theme_color_override("icon_hover_pressed_color", c)


func _on_track_name_changed(_new_name: String):
	"""Handle track name changes."""
	_update_label()


func _on_track_color_changed(_new_color: Color):
	"""Handle track color changes."""
	_update_label()
	_update_style()


func _on_toggle_gui_input(event: InputEvent, kind: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		toggle_pressed.emit(kind, event.shift_pressed)
		# Keeps the item from also treating this as a track selection.
		accept_event()


func _gui_input(event: InputEvent):
	"""Handle mouse input."""
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()
