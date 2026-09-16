# TrackItemContextMenu.gd
# Right-click menu for track headers. One track: color, name, bus/channel routing, delete and
# duplicate (with or without the channel). Several selected tracks: read-only "N tracks" title and
# delete/duplicate for all of them as one undo step.
class_name TrackItemContextMenu extends PopupPanel

var logger : Log = Log.make("TrackItemContextMenu")

const BUS_NONE := TrackLinkBusCommand.UNLINK
const BUS_NEW := TrackLinkBusCommand.CREATE_NEW

const ROUTE_NONE := TrackRouteChannelCommand.UNROUTE
const ROUTE_NEW := TrackRouteChannelCommand.CREATE_NEW

@onready var color_picker_button: ColorPickerButton = $VBoxContainer/ColorAndName/ColorPickerButton
@onready var name_label: SmartLineEdit = $VBoxContainer/ColorAndName/Name
@onready var delete_button: Button = $VBoxContainer/Buttons/Delete

var current_track: Track = null
var current_project: Project = null
## Every track the menu acts on (the selection); a single entry for a single track.
var current_tracks: Array[Track] = []
var duplicate_button: Button = null
var delete_with_channel_button: Button = null
var duplicate_with_channel_button: Button = null
var bus_link_option: OptionButton = null
var channel_route_option: OptionButton = null


func _ready() -> void:
	# ColorPickerButton opens a nested Window; keep this menu alive so color_changed fires.
	exclusive = false
	transient = false
	if color_picker_button:
		color_picker_button.edit_alpha = false
		color_picker_button.edit_intensity = false
		color_picker_button.pressed.connect(_on_color_picker_pressed)
	if delete_button:
		delete_button.pressed.connect(_on_delete_pressed.bind(false))
	_ensure_action_buttons()
	_ensure_bus_link_control()
	_ensure_channel_route_control()
	hide()


## Add Delete & Channel and the duplicate buttons next to the scene's Delete button.
func _ensure_action_buttons() -> void:
	if duplicate_button or delete_button == null:
		return
	var buttons := delete_button.get_parent()
	delete_with_channel_button = _make_button(buttons, _on_delete_pressed.bind(true))
	duplicate_button = _make_button(buttons, _on_duplicate_pressed.bind(false))
	duplicate_with_channel_button = _make_button(buttons, _on_duplicate_pressed.bind(true))


func _make_button(parent: Node, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.alignment = delete_button.alignment
	button.flat = delete_button.flat
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	return button


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


## Add the channel-routing dropdown above Delete (instrument/audio tracks only).
func _ensure_channel_route_control() -> void:
	if channel_route_option:
		return
	var vbox := $VBoxContainer as VBoxContainer
	if vbox == null:
		return
	channel_route_option = OptionButton.new()
	channel_route_option.name = "ChannelRoute"
	channel_route_option.fit_to_longest_item = false
	channel_route_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	channel_route_option.item_selected.connect(_on_channel_route_selected)
	channel_route_option.tooltip_text = "Mixer channel this track plays through"
	var popup := channel_route_option.get_popup()
	popup.exclusive = false
	popup.transient = false
	var buttons := vbox.get_node_or_null("Buttons")
	var insert_at := buttons.get_index() if buttons else vbox.get_child_count()
	vbox.add_child(channel_route_option)
	vbox.move_child(channel_route_option, insert_at)


## Connect the nested ColorPicker once it exists so drags apply while the menu stays open.
func _on_color_picker_pressed() -> void:
	if color_picker_button == null:
		return
	var picker := color_picker_button.get_picker()
	if picker and not picker.color_changed.is_connected(_on_color_changed):
		picker.color_changed.connect(_on_color_changed)


## Bind the context menu to a specific track.
func bind(track: Track, project: Project = null) -> void:
	bind_tracks([track] as Array[Track], track, project)


## Bind to the selected `tracks`, with `track` the one right-clicked. Two or more tracks switch
## to the multi-track layout.
func bind_tracks(tracks: Array[Track], track: Track, project: Project = null) -> void:
	_unbind()

	current_track = track
	current_project = project
	for t in tracks:
		if t and not current_tracks.has(t):
			current_tracks.append(t)
	if track and not current_tracks.has(track):
		current_tracks = [track] as Array[Track]

	if not current_track:
		return
	var multi := is_multi()

	if color_picker_button:
		color_picker_button.color = current_track.color
		if not color_picker_button.color_changed.is_connected(_on_color_changed):
			color_picker_button.color_changed.connect(_on_color_changed)

	if name_label:
		name_label.set_value("%d tracks" % current_tracks.size() if multi else current_track.name)
		name_label.disabled = multi
		if not name_label.value_changed.is_connected(_on_name_changed):
			name_label.value_changed.connect(_on_name_changed)

	_update_action_buttons()
	if multi:
		# Routing is per track; hide the dropdowns rather than apply one track's choice to all.
		if bus_link_option:
			bus_link_option.visible = false
		if channel_route_option:
			channel_route_option.visible = false
		return
	_rebuild_bus_link_menu()
	_rebuild_channel_route_menu()


## True when the menu acts on more than one track.
func is_multi() -> bool:
	return current_tracks.size() > 1


## Label and show the delete/duplicate buttons for the bound tracks.
func _update_action_buttons() -> void:
	_ensure_action_buttons()
	var multi := is_multi()
	var any_channel := false
	var any_duplicable := false
	var any_duplicable_with_channel := false
	for t in current_tracks:
		var has_channel := t.default_channel_id >= 0
		any_channel = any_channel or has_channel
		if TrackDuplicateCommand.can_duplicate(t):
			any_duplicable = true
			any_duplicable_with_channel = any_duplicable_with_channel or has_channel
	if delete_button:
		delete_button.text = "Delete Tracks" if multi else "Delete Track"
		delete_button.tooltip_text = "Delete, keeping mixer channels" if any_channel else ""
	if delete_with_channel_button:
		delete_with_channel_button.text = "Delete Tracks & Channels" if multi else "Delete Track & Channel"
		delete_with_channel_button.visible = any_channel
	if duplicate_button:
		duplicate_button.text = "Duplicate Tracks" if multi else "Duplicate Track"
		duplicate_button.visible = any_duplicable
		duplicate_button.tooltip_text = "Copy clips; the copy plays through the same channel"
	if duplicate_with_channel_button:
		duplicate_with_channel_button.text = "Duplicate Tracks & Channels" if multi else "Duplicate Track & Channel"
		duplicate_with_channel_button.visible = any_duplicable_with_channel
		duplicate_with_channel_button.tooltip_text = "Copy clips and the channel (devices, sends, routing)"


## Disconnect from current track.
func _unbind() -> void:
	if color_picker_button and color_picker_button.color_changed.is_connected(_on_color_changed):
		color_picker_button.color_changed.disconnect(_on_color_changed)
	
	if name_label and name_label.value_changed.is_connected(_on_name_changed):
		name_label.value_changed.disconnect(_on_name_changed)
	
	current_track = null
	current_project = null
	current_tracks.clear()
	if name_label:
		name_label.disabled = false


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


## Fill the channel dropdown: None, New Channel, then every strip a track may play through.
func _rebuild_channel_route_menu() -> void:
	_ensure_channel_route_control()
	if channel_route_option == null:
		return
	# Folders use the bus dropdown; a group's channel is its identity and stays put.
	var routable := current_track != null and (
		current_track.type == Track.TrackType.INSTRUMENT
		or current_track.type == Track.TrackType.AUDIO
	)
	channel_route_option.visible = routable
	if not routable:
		return

	channel_route_option.set_block_signals(true)
	channel_route_option.clear()
	channel_route_option.add_item(" - None - ", ROUTE_NONE)
	channel_route_option.add_item("New Channel", ROUTE_NEW)
	channel_route_option.add_separator()

	var selected_id := ROUTE_NONE
	if current_track.default_channel_id >= 0:
		selected_id = current_track.default_channel_id

	if current_project:
		for ch in current_project.channels:
			# Only mixer strips a track can play into: buses, groups and the master are
			# routing destinations for channels, not for tracks.
			if ch.is_master or ch.is_bus or ch.is_group_channel:
				continue
			channel_route_option.add_item(ch.name, ch.id)

	_select_channel_route_item(selected_id)
	channel_route_option.set_block_signals(false)


## Select the routing item whose id matches `item_id`, falling back to None.
func _select_channel_route_item(item_id: int) -> void:
	for i in range(channel_route_option.item_count):
		if channel_route_option.is_item_separator(i):
			continue
		if channel_route_option.get_item_id(i) == item_id:
			channel_route_option.select(i)
			return
	channel_route_option.select(0)


## Apply None / New Channel / existing channel to the bound track.
func _on_channel_route_selected(index: int) -> void:
	if current_track == null or current_project == null or channel_route_option == null:
		return
	var item_id := channel_route_option.get_item_id(index)
	if item_id == ROUTE_NEW:
		HistoryUtil.execute(TrackRouteChannelCommand.new(current_project, current_track, null, true))
		_rebuild_channel_route_menu()
		return
	if item_id == ROUTE_NONE:
		if current_track.default_channel_id < 0:
			return
		HistoryUtil.execute(TrackRouteChannelCommand.new(current_project, current_track, null, false))
		_rebuild_channel_route_menu()
		return
	if item_id == current_track.default_channel_id:
		return
	var channel := current_project.get_channel_by_id(item_id)
	if channel == null:
		return
	HistoryUtil.execute(TrackRouteChannelCommand.new(current_project, current_track, channel, false))
	_rebuild_channel_route_menu()


func _on_color_changed(new_color: Color) -> void:
	"""Update track color when picker changes."""
	if not current_track:
		push_warning("[TrackItemContextMenu] color_changed with no current_track")
		return
	var ch := current_track.get_linked_channel()
	logger.info("color → track %d '%s' linked_channel=%s" % [
		current_track.id,
		current_track.name,
		("%d" % ch.id) if ch else "none"
	])
	for t in current_tracks:
		t.set_color(new_color)


func _on_name_changed(new_name: String) -> void:
	"""Update track name when label changes."""
	if current_track and not is_multi():
		current_track.name = new_name
		# Show the final name: it may have been suffixed ("Drums 2") to stay unique.
		if name_label:
			name_label.set_value(current_track.name)


## Delete the bound tracks as one step, keeping their channels unless `with_channels`.
func _on_delete_pressed(with_channels: bool) -> void:
	if current_track == null or current_project == null:
		return
	HistoryUtil.execute(delete_command(current_project, current_tracks, with_channels))
	hide()


## Duplicate every duplicable bound track as one step, copying channels when `with_channels`.
func _on_duplicate_pressed(with_channels: bool) -> void:
	if current_track == null or current_project == null:
		return
	var cmd := duplicate_command(current_project, current_tracks, with_channels)
	if cmd:
		HistoryUtil.execute(cmd)
	hide()


## One undoable delete for `tracks` (nested tracks go with their selected parent).
static func delete_command(project: Project, tracks: Array[Track], with_channels: bool) -> TrackDeleteCommand:
	var more: Array[Track] = tracks.slice(1)
	return TrackDeleteCommand.new(project, tracks[0] if not tracks.is_empty() else null, not with_channels, more)


## One undoable duplicate for `tracks`: a TrackDuplicateCommand per clip track, grouped in a
## MacroCommand when there are several. Null when nothing can be duplicated.
static func duplicate_command(project: Project, tracks: Array[Track], with_channels: bool) -> Command:
	var cmds: Array[Command] = []
	for t in tracks:
		if TrackDuplicateCommand.can_duplicate(t):
			cmds.append(TrackDuplicateCommand.new(project, t, with_channels and t.default_channel_id >= 0))
	if cmds.is_empty():
		return null
	if cmds.size() == 1:
		return cmds[0]
	var label := "Duplicate Tracks and Channels" if with_channels else "Duplicate Tracks"
	return MacroCommand.new(label, cmds)
