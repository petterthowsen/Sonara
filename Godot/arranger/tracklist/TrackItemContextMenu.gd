class_name TrackItemContextMenu extends PopupPanel

const BUS_NONE := TrackLinkBusCommand.UNLINK
const BUS_NEW := TrackLinkBusCommand.CREATE_NEW

@onready var color_picker_button: ColorPickerButton = $VBoxContainer/ColorAndName/ColorPickerButton
@onready var name_label: SmartLineEdit = $VBoxContainer/ColorAndName/Name
@onready var delete_button: Button = $VBoxContainer/Buttons/Delete

var current_track: Track = null
var current_project: Project = null
var bus_link_option: OptionButton = null


func _ready() -> void:
	# ColorPickerButton opens a nested Window; keep this menu alive so color_changed fires.
	exclusive = false
	transient = false
	if color_picker_button:
		color_picker_button.edit_alpha = false
		color_picker_button.edit_intensity = false
		color_picker_button.pressed.connect(_on_color_picker_pressed)
	if delete_button:
		delete_button.pressed.connect(_on_delete_pressed)
	_ensure_bus_link_control()
	hide()


## Add the bus-link dropdown above Delete (folders only).
func _ensure_bus_link_control() -> void:
	if bus_link_option:
		return
	var vbox := $VBoxContainer as VBoxContainer
	if vbox == null:
		return
	bus_link_option = OptionButton.new()
	bus_link_option.name = "BusLink"
	bus_link_option.fit_to_longest_item = false
	bus_link_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bus_link_option.item_selected.connect(_on_bus_link_selected)
	bus_link_option.tooltip_text = "Link this folder to a mixer bus (Folder Bus)"
	var popup := bus_link_option.get_popup()
	popup.exclusive = false
	popup.transient = false
	var buttons := vbox.get_node_or_null("Buttons")
	var insert_at := buttons.get_index() if buttons else vbox.get_child_count()
	vbox.add_child(bus_link_option)
	vbox.move_child(bus_link_option, insert_at)


## Connect the nested ColorPicker once it exists so drags apply while the menu stays open.
func _on_color_picker_pressed() -> void:
	if color_picker_button == null:
		return
	var picker := color_picker_button.get_picker()
	if picker and not picker.color_changed.is_connected(_on_color_changed):
		picker.color_changed.connect(_on_color_changed)


## Bind the context menu to a specific track.
func bind(track: Track, project: Project = null) -> void:
	_unbind()
	
	current_track = track
	current_project = project
	
	if not current_track:
		return
	
	if color_picker_button:
		color_picker_button.color = current_track.color
		if not color_picker_button.color_changed.is_connected(_on_color_changed):
			color_picker_button.color_changed.connect(_on_color_changed)
	
	if name_label:
		name_label.set_value(current_track.name)
		if not name_label.value_changed.is_connected(_on_name_changed):
			name_label.value_changed.connect(_on_name_changed)

	_rebuild_bus_link_menu()


## Disconnect from current track.
func _unbind() -> void:
	if color_picker_button and color_picker_button.color_changed.is_connected(_on_color_changed):
		color_picker_button.color_changed.disconnect(_on_color_changed)
	
	if name_label and name_label.value_changed.is_connected(_on_name_changed):
		name_label.value_changed.disconnect(_on_name_changed)
	
	current_track = null
	current_project = null


## Fill the bus dropdown: None, New Bus, then existing buses.
func _rebuild_bus_link_menu() -> void:
	_ensure_bus_link_control()
	if bus_link_option == null:
		return
	var is_folder := current_track != null and current_track.type == Track.TrackType.FOLDER
	bus_link_option.visible = is_folder
	if not is_folder:
		return

	bus_link_option.set_block_signals(true)
	bus_link_option.clear()
	bus_link_option.add_item(" - None - ", BUS_NONE)
	bus_link_option.add_item("New Bus", BUS_NEW)
	bus_link_option.add_separator()

	var selected_id := BUS_NONE
	if current_track.default_channel_id >= 0:
		selected_id = current_track.default_channel_id

	if current_project:
		for ch in current_project.channels:
			if ch.is_bus and not ch.is_master:
				bus_link_option.add_item(ch.name, ch.id)

	_select_bus_item(selected_id)
	bus_link_option.set_block_signals(false)


## Select the OptionButton item whose id matches `item_id`.
func _select_bus_item(item_id: int) -> void:
	for i in range(bus_link_option.item_count):
		if bus_link_option.is_item_separator(i):
			continue
		if bus_link_option.get_item_id(i) == item_id:
			bus_link_option.select(i)
			return
	bus_link_option.select(0)


## Apply None / New Bus / existing bus to the bound folder track.
func _on_bus_link_selected(index: int) -> void:
	if current_track == null or current_project == null or bus_link_option == null:
		return
	if current_track.type != Track.TrackType.FOLDER:
		return
	var item_id := bus_link_option.get_item_id(index)
	if item_id == BUS_NEW:
		HistoryUtil.execute(TrackLinkBusCommand.new(current_project, current_track, null, true))
		_rebuild_bus_link_menu()
		return
	if item_id == BUS_NONE:
		if current_track.default_channel_id < 0:
			return
		HistoryUtil.execute(TrackLinkBusCommand.new(current_project, current_track, null, false))
		_rebuild_bus_link_menu()
		return
	if item_id == current_track.default_channel_id:
		return
	var bus := current_project.get_channel_by_id(item_id)
	if bus == null:
		return
	HistoryUtil.execute(TrackLinkBusCommand.new(current_project, current_track, bus, false))
	_rebuild_bus_link_menu()


func _on_color_changed(new_color: Color) -> void:
	"""Update track color when picker changes."""
	if not current_track:
		push_warning("[TrackItemContextMenu] color_changed with no current_track")
		return
	if current_project and current_track._project_ref == null:
		current_track.set_project_ref(current_project)
	var ch := current_track.get_linked_channel()
	print("[TrackItemContextMenu] color → track %d '%s' linked_channel=%s" % [
		current_track.id,
		current_track.name,
		("%d" % ch.id) if ch else "none"
	])
	current_track.set_color(new_color)


func _on_name_changed(new_name: String) -> void:
	"""Update track name when label changes."""
	if current_track:
		current_track.name = new_name


func _on_delete_pressed() -> void:
	"""Delete the track."""
	if current_track and current_project:
		print("[TrackItemContextMenu] Deleting track: ", current_track.name)
		HistoryUtil.execute(TrackDeleteCommand.new(current_project, current_track))
		hide()
