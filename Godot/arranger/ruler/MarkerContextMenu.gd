# MarkerContextMenu.gd
# Right-click menu for one song marker: color, name, add/split at the clicked tick, delete.
class_name MarkerContextMenu extends PopupPanel

signal add_marker_requested(marker: SongMarker, tick: int)
signal split_requested(marker: SongMarker, tick: int)
## The owner applies the rename (it knows the project, so the name can be made unique).
signal rename_requested(marker: SongMarker, new_name: String)
signal delete_requested(marker: SongMarker)

@onready var color_picker: ColorPickerButton = $VBoxContainer/Header/HBox/ColorPicker
@onready var label: SmartLineEdit = $VBoxContainer/Header/HBox/Label
@onready var add_button: Button = $VBoxContainer/AddMarkerButton
@onready var split_button: Button = $VBoxContainer/SplitButton
@onready var delete_button: Button = $VBoxContainer/DeleteButton

var marker: SongMarker = null
## Snapped tick under the cursor when the menu opened.
var tick: int = 0


func _ready() -> void:
	# ColorPickerButton opens a nested Window; keep this menu alive so color_changed fires.
	exclusive = false
	transient = false
	color_picker.edit_alpha = false
	color_picker.edit_intensity = false
	color_picker.color_changed.connect(_on_color_changed)
	color_picker.pressed.connect(_on_color_picker_pressed)
	label.value_changed.connect(_on_label_changed)
	add_button.pressed.connect(_on_add_pressed)
	split_button.pressed.connect(_on_split_pressed)
	delete_button.pressed.connect(_on_delete_pressed)


## Bind to `p_marker`; `p_tick` is where Add Marker Here / Split cut the marker.
func bind_to_marker(p_marker: SongMarker, p_tick: int) -> void:
	marker = p_marker
	tick = p_tick
	color_picker.color = marker.color
	if label.is_editing:
		label.cancel_editing()
	label.set_value(marker.name)
	var can_split := MarkerActions.can_split_at(marker, tick)
	add_button.disabled = not can_split
	split_button.disabled = not can_split


## Connect the nested ColorPicker once it exists.
func _on_color_picker_pressed() -> void:
	var picker := color_picker.get_picker()
	if picker and not picker.color_changed.is_connected(_on_color_changed):
		picker.color_changed.connect(_on_color_changed)


func _on_color_changed(color: Color) -> void:
	if marker == null or marker.color == color:
		return
	var old_color := marker.color
	marker.set_color(color)
	HistoryUtil.record_property("Marker Color", marker, "set_color", old_color, color)


func _on_label_changed(new_name: Variant) -> void:
	if marker == null:
		return
	var new_str := str(new_name).strip_edges()
	if new_str.is_empty() or new_str == marker.name:
		label.set_value(marker.name)
		return
	rename_requested.emit(marker, new_str)
	label.set_value(marker.name)


func _on_add_pressed() -> void:
	if marker:
		add_marker_requested.emit(marker, tick)
	hide()


func _on_split_pressed() -> void:
	if marker:
		split_requested.emit(marker, tick)
	hide()


func _on_delete_pressed() -> void:
	if marker:
		delete_requested.emit(marker)
	hide()
