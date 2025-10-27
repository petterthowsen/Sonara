# An item in the ClipEditor track list
class_name ClipEditorTrackListItem extends BoxContainer

@onready var label: Label = $Label

var track: Track:
	set = set_track

var _selected := false

signal pressed


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
		queue_redraw()


func _ready():
	_update_label()


func set_selected(selected: bool):
	"""Set selection state and update visuals."""
	if _selected != selected:
		_selected = selected
		queue_redraw()


func _update_label():
	"""Update label text with track name."""
	if track:
		label.text = track.name
		label.modulate.a = 1.0 if _selected else 0.7


func _draw():
	"""Draw track color background with opacity based on selection."""
	if not track:
		return
	
	var rect = Rect2(Vector2.ZERO, size)
	var opacity = 1.0 if _selected else 0.7
	var color = track.track_color
	color.a = opacity
	
	draw_rect(rect, color, true, -1.0, true)


func _on_track_name_changed(_new_name: String):
	"""Handle track name changes."""
	_update_label()


func _on_track_color_changed(_new_color: Color):
	"""Handle track color changes."""
	queue_redraw()


func _gui_input(event: InputEvent):
	"""Handle mouse input."""
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()
