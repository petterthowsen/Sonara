class_name TrackItemContextMenu extends PopupPanel

@onready var color_picker_button: ColorPickerButton = $VBoxContainer/ColorAndName/ColorPickerButton
@onready var name_label: SmartLineEdit = $VBoxContainer/ColorAndName/Name
@onready var delete_button: Button = $VBoxContainer/Buttons/Delete

var current_track: Track = null
var current_project: Project = null

func _ready() -> void:
	# Connect button signals
	if delete_button:
		delete_button.pressed.connect(_on_delete_pressed)
	
	# Hide initially
	hide()


func bind(track: Track, project: Project = null) -> void:
	"""Bind the context menu to a specific track."""
	# Disconnect from previous track if any
	_unbind()
	
	current_track = track
	current_project = project
	
	if not current_track:
		return
	
	# Update UI from track data
	if color_picker_button:
		color_picker_button.color = current_track.track_color
		if not color_picker_button.color_changed.is_connected(_on_color_changed):
			color_picker_button.color_changed.connect(_on_color_changed)
	
	if name_label:
		name_label.set_value(current_track.name)
		if not name_label.value_changed.is_connected(_on_name_changed):
			name_label.value_changed.connect(_on_name_changed)


func _unbind() -> void:
	"""Disconnect from current track."""
	if color_picker_button and color_picker_button.color_changed.is_connected(_on_color_changed):
		color_picker_button.color_changed.disconnect(_on_color_changed)
	
	if name_label and name_label.value_changed.is_connected(_on_name_changed):
		name_label.value_changed.disconnect(_on_name_changed)
	
	current_track = null
	current_project = null


func _on_color_changed(new_color: Color) -> void:
	"""Update track color when picker changes."""
	if current_track:
		current_track.set_color(new_color)


func _on_name_changed(new_name: String) -> void:
	"""Update track name when label changes."""
	if current_track:
		current_track.name = new_name


func _on_delete_pressed() -> void:
	"""Delete the track."""
	if current_track and current_project:
		print("[TrackItemContextMenu] Deleting track: ", current_track.name)
		current_project.remove_track(current_track.id)
		hide()
