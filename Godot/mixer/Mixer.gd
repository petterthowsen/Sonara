# Mixer.gd
# 
# A two-pane Mixer interface with track/instrument channels on the left pane
# and buses on the right pane.
# 
# default Master mus should go at the end of RightPane/HBox
class_name Mixer extends VBoxContainer

# CONSTANTS
const MixerChannelScene = preload("res://mixer/MixerChannel.tscn")

# ============================================================================
# NODE REFERENCES
# ============================================================================
@onready var h_split: HSplitContainer = $HSplit
@onready var toolbar: PanelContainer = $Toolbar

@onready var left_pane: ScrollContainer = $HSplit/LeftPane
@onready var left_channels: HBoxContainer = $HSplit/LeftPane/HBox/Channels
@onready var left_add_button: Button = $HSplit/LeftPane/HBox/Options/AddButton

@onready var right_pane: ScrollContainer = $HSplit/RightPane

# need a ref for this hbox to put master track there
@onready var right_pane_hbox: HBoxContainer = $HSplit/RightPane/HBox
@onready var right_channels: HBoxContainer = $HSplit/RightPane/HBox/Channels
@onready var right_add_button: Button = $HSplit/RightPane/HBox/Options/AddButton

# Toolbar toggles
@onready var compact_toggle: Button = $Toolbar/HBox/Toggles/Compact
@onready var io_toggle: Button = $Toolbar/HBox/Toggles/IO
@onready var sends_toggle: Button = $Toolbar/HBox/Toggles/Sends
@onready var big_meters_toggle: Button = $Toolbar/HBox/Toggles/BigMeters

@onready var channel_ctx_menu : ChannelContextMenu = $ChannelContextMenu

# Project reference
var current_project: Project = null

# Export property to control whether channels can be resized
@export var resizable_channels: bool = true

# ============================================================================
# Selection
# ============================================================================
var selection : Array[Channel] = []
var focused_channel : Channel = null

signal selection_changed(selection : Array[Channel])
signal channel_selected(channel : Channel)
signal channel_deselected(channel : Channel)
signal channel_focused(channel : Channel)

func _ready():
	# clear
	_clear_all_channels()

	# Connect to Editor signals
	if Sonara and Sonara.editor:
		Sonara.editor.project_opened.connect(_on_project_opened)
		Sonara.editor.project_closed.connect(_on_project_closed)

	# Connect add buttons
	left_add_button.pressed.connect(_on_left_add_button_pressed)
	right_add_button.pressed.connect(_on_right_add_button_pressed)

	# Connect toolbar toggles
	compact_toggle.toggled.connect(_on_compact_toggled)
	io_toggle.toggled.connect(_on_io_toggled)
	sends_toggle.toggled.connect(_on_sends_toggled)
	big_meters_toggle.toggled.connect(_on_big_meters_toggled)
	
	# Connect context menu signals
	channel_ctx_menu.delete_requested.connect(_on_channel_delete_requested)
	
	# Enable drag and drop on left pane for devices and SFZ files
	left_pane.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)

# ============================================================================
# EDITOR/PROJECT SIGNAL CALLBACKS
# ============================================================================

func _on_project_opened(project: Project) -> void:
	"""Called when a project is opened - build UI for all channels."""
	print("[Mixer] Project opened: ", project.project_name)

	current_project = project

	# Connect to project signals
	project.channel_added.connect(_on_channel_added)
	project.channel_removed.connect(_on_channel_removed)

	# Build UI for existing channels
	for i in range(project.channels.size()):
		_on_channel_added(project.channels[i])


func _on_project_closed() -> void:
	"""Clear all channel items when project closes."""
	current_project = null
	_clear_all_channels()


func _on_channel_added(channel: Channel) -> void:
	"""Create a MixerChannel UI element for the new channel."""
	if MixerChannelScene == null:
		push_warning("[Mixer] No MixerChannelScene assigned")
		return

	# Instantiate MixerChannel
	var channel_item = MixerChannelScene.instantiate() as MixerChannel

	# Add to appropriate container FIRST (so _ready() fires)
	if channel.is_master:
		# Master bus goes directly to right_pane_hbox (special position)
		right_pane_hbox.add_child(channel_item)
	elif channel.is_bus:
		# Buses go to right ChannelsBox
		right_channels.add(channel_item)
	else:
		# Regular tracks go to left ChannelsBox
		left_channels.add(channel_item)

	# Now bind to channel data after _ready() has fired, with project reference
	channel_item.bind_to_channel(channel, current_project)

	# Apply current toggle states to the new channel
	_apply_toggle_states_to_channel(channel_item)

	# Update routing menus for all channels since new channel can be a routing target
	_rebuild_all_routing_menus()
	
	# If a BUS channel was added, rebuild all sends panels since this is a new send target
	if channel.is_bus:
		_rebuild_all_sends_panels()
	
	# listen for right-click
	channel_item.request_show_context_menu.connect(_on_channel_request_context_menu.bind(channel))
	
	# listen for click to select
	channel_item.gui_input.connect(_on_channel_item_gui_input.bind(channel))
	
	print("[Mixer] Channel added: ", channel.name, " with ID ", channel.id, " and order ", channel.order)


func _on_channel_removed(channel: Channel) -> void:
	"""Remove the MixerChannel UI element when a channel is removed."""
	var mixer_channel = find_mixer_channel_ui_for_channel(channel)
	if mixer_channel:
		# Remove from selection if selected
		if selection.has(channel):
			deselect_channel(channel)
		
		# Remove from focused if focused
		if focused_channel == channel:
			focused_channel = null
		
		# Remove the UI element
		mixer_channel.queue_free()
		
		# Update routing menus for remaining channels
		_rebuild_all_routing_menus()
		
		# If a BUS channel was removed, rebuild all sends panels since a send target is gone
		if channel.is_bus:
			_rebuild_all_sends_panels()
		
		print("[Mixer] Channel removed from UI: ", channel.name, " (ID: ", channel.id, ")")


func _on_channel_delete_requested(channel: Channel) -> void:
	"""Handle delete request from context menu."""
	if not current_project:
		return
	
	# Confirm deletion (skip for now, directly delete)
	current_project.remove_channel(channel.id)


func deselect_channel(ch : Channel, erase := true, emit_deselect := true, emit_changed := true):
	if selection.has(ch):
		var mc = find_mixer_channel_ui_for_channel(ch)
		if not mc:
			push_error("[Mixer] Cannot find MixerChannel ui for Channel ", ch.id)
			return
		
		mc.is_selected = false
		if erase:
			selection.erase(ch)
		
		if emit_deselect:
			channel_deselected.emit(ch)
		
		if emit_changed:
			selection_changed.emit(selection)


func select_channel(ch : Channel, multi := false, emit_select := true, emit_changed := true):
	# deselect others
	if not multi:
		for c in selection:
			deselect_channel(c, false, true, false)
		selection.clear()
	
	if not selection.has(ch):
		# select it
		selection.append(ch)
		var mc := find_mixer_channel_ui_for_channel(ch)
		mc.is_selected = true
		if emit_select:
			channel_selected.emit(ch)
	
	if emit_changed:
		selection_changed.emit(selection)

	# focus it
	if focused_channel != ch:
		focused_channel = ch
		channel_focused.emit(ch)


func _on_channel_item_gui_input(event : InputEvent, channel : Channel):
	if event is InputEventMouseButton:
		var me = event as InputEventMouseButton
		if me.button_index == MOUSE_BUTTON_LEFT and me.pressed:
			select_channel(channel, me.ctrl_pressed)
			accept_event()


func find_mixer_channel_ui_for_channel(channel : Channel) -> MixerChannel:
	for mc in left_channels.get_children():
		if mc.channel == channel:
			return mc
	
	for mc in right_channels.get_children():
		if mc.channel == channel:
			return mc
	
	# Master channel is in right_pane_hbox, not in right_channels
	for mc in right_pane_hbox.get_children():
		if mc is MixerChannel and mc.channel == channel:
			return mc

	return null


func _on_left_add_button_pressed() -> void:
	"""Add a new instrument channel to the left pane."""
	if not Sonara or not Sonara.editor or not Sonara.editor.project:
		push_warning("[Mixer] No project open")
		return

	var project = Sonara.editor.project
	var channel = project.create_channel("Instrument %d" % (project.channels.size()), Channel.ChannelType.INSTRUMENT)
	channel.output_channel_id = 1  # Route to master
	print("[Mixer] Added new instrument channel: ", channel.name)


func _on_right_add_button_pressed() -> void:
	"""Add a new bus channel to the right pane."""
	if not Sonara or not Sonara.editor or not Sonara.editor.project:
		push_warning("[Mixer] No project open")
		return

	var project = Sonara.editor.project
	var channel = project.create_channel("Bus %d" % (project.channels.size()), Channel.ChannelType.BUS)
	channel.output_channel_id = 1  # Route to master
	print("[Mixer] Added new bus channel: ", channel.name)

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _clear_all_channels() -> void:
	"""Remove all channel items from both panes."""
	# Clear master bus if it exists
	for child in right_pane_hbox.get_children():
		if child is MixerChannel:
			child.queue_free()

	# Clear all channels from both ChannelsBoxes
	for child in left_channels.get_children():
		child.queue_free()
	for child in right_channels.get_children():
		child.queue_free()

	print("[Mixer] All channels cleared")


# ============================================================================
# TOOLBAR TOGGLE CALLBACKS
# ============================================================================

func _on_compact_toggled(pressed: bool) -> void:
	"""Toggle compact mode - sets all mixer channels to compact or large mode."""
	var mode = MixerChannel.Mode.COMPACT if pressed else MixerChannel.Mode.LARGE
	get_tree().call_group("mixer_channel", "set_mode", mode)

	# When in compact mode, disable free resizing; when in large mode, enable it
	resizable_channels = not pressed
	get_tree().call_group("mixer_channel", "set_resizable", resizable_channels)

	print("[Mixer] Compact mode: ", pressed, " | Resizable channels: ", resizable_channels)


func _on_io_toggled(pressed: bool) -> void:
	"""Toggle IO panel visibility."""
	get_tree().call_group("mixer_channel_io", "set", "visible", pressed)
	print("[Mixer] IO panel: ", pressed)


func _on_sends_toggled(pressed: bool) -> void:
	"""Toggle Sends panel visibility."""
	get_tree().call_group("mixer_channel_sends", "set", "visible", pressed)
	print("[Mixer] Sends panel: ", pressed)

func _on_big_meters_toggled(pressed: bool):
	get_tree().call_group("mixer_channel_big_meters", "set", "visible", pressed)
	get_tree().call_group("mixer_channel_compact_meter", "set", "visible", not pressed)
	get_tree().call_group("mixer_channel_fader", "set", "visible", pressed)


func _apply_toggle_states_to_channel(channel_item: MixerChannel) -> void:
	"""Apply current toggle states to a newly created mixer channel."""
	# Apply compact mode toggle
	var compact_mode = MixerChannel.Mode.COMPACT if compact_toggle.button_pressed else MixerChannel.Mode.LARGE
	channel_item.set_mode(compact_mode)
	channel_item.set_resizable(resizable_channels)

	# Apply IO panel visibility toggle
	if channel_item.has_node("HBox/VBox/IO"):
		channel_item.get_node("HBox/VBox/IO").visible = io_toggle.button_pressed

	# Apply Sends panel visibility toggle
	if channel_item.has_node("HBox/VBox/Sends"):
		channel_item.get_node("HBox/VBox/Sends").visible = sends_toggle.button_pressed


# ============================================================================
# ROUTING MENU HELPERS
# ============================================================================

func _rebuild_all_routing_menus() -> void:
	"""Rebuild routing menus for all mixer channels."""
	# Update left pane channels
	for child in left_channels.get_children():
		if child is MixerChannel:
			child._rebuild_output_menu()

	# Update right pane channels
	for child in right_channels.get_children():
		if child is MixerChannel:
			child._rebuild_output_menu()


func _rebuild_all_sends_panels() -> void:
	"""Rebuild sends panels for all mixer channels when a new bus is added."""
	print("[Mixer] Rebuilding all sends panels")
	
	# Update left pane channels (instrument/audio channels)
	for child in left_channels.get_children():
		if child is MixerChannel and child.sends_panel:
			child.sends_panel._rebuild_sends_ui()
	
	# Update right pane channels (bus channels)
	for child in right_channels.get_children():
		if child is MixerChannel and child.sends_panel:
			child.sends_panel._rebuild_sends_ui()
	
	# Update master channel if it exists
	for child in right_pane_hbox.get_children():
		if child is MixerChannel and child.sends_panel:
			child.sends_panel._rebuild_sends_ui()

	# Update master channel
	for child in right_pane_hbox.get_children():
		if child is MixerChannel and child.channel and child.channel.is_master:
			child._rebuild_output_menu()


func _on_channel_request_context_menu(channel : Channel):
	var mc : MixerChannel = find_mixer_channel_ui_for_channel(channel)
	if mc:
		channel_ctx_menu.bind_to_channel(channel)
		var c_pos = get_global_mouse_position()
		var c_size = channel_ctx_menu.get_contents_minimum_size()
		channel_ctx_menu.popup(Rect2(c_pos, c_size))


# ============================================================================
# DRAG AND DROP (LEFT PANE ONLY - for creating instrument channels)
# ============================================================================

func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Return drag data (not used for mixer)."""
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Check if we can drop data (device/SFZ assets) on the left pane."""
	if not current_project:
		return false

	# Check if data is a single asset
	if data is Asset:
		if data.type == Asset.TYPE.Device or data.type == Asset.TYPE.SFZ:
			return true
	
	# Check if data is an array of assets
	if data is Array:
		for item in data:
			if not item is Asset:
				return false
			if item.type != Asset.TYPE.Device and item.type != Asset.TYPE.SFZ:
				return false
		return data.size() > 0

	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping device or SFZ assets (single or multiple) on the left pane."""
	if not current_project:
		return
	
	# Handle array of assets
	if data is Array:
		print("[Mixer] Dropping %d assets" % data.size())
		for asset in data:
			if asset is Asset:
				_handle_single_asset_drop(asset)
		return
	
	# Handle single asset
	if data is Asset:
		_handle_single_asset_drop(data)


func _handle_single_asset_drop(asset: Asset) -> void:
	"""Handle dropping a single asset on the left pane."""
	# Handle SFZ asset drops
	if asset.type == Asset.TYPE.SFZ:
		print("[Mixer] SFZ dropped: ", asset.name, " (", asset.path, ")")
		_create_sfz_instrument_channel(asset.path, asset.name)
		return
	
	# Handle device asset drops
	if asset.type == Asset.TYPE.Device:
		print("[Mixer] Device dropped: ", asset.name, " (", asset.path, ")")
		
		# Get the device metadata
		var device = AssetService.get_device(asset.path)
		if not device:
			push_error("[Mixer] Failed to get device: ", asset.path)
			return
		
		# Only create instrument channels for instrument devices
		if device.category == Device.DeviceCategory.Instrument:
			_create_instrument_channel_with_device(device)
		else:
			push_warning("[Mixer] Cannot drop effect device on empty area. Drop on existing channel instead.")


func _create_instrument_channel_with_device(device: Device) -> void:
	"""Create a new instrument channel with the specified device."""
	print("[Mixer] Creating instrument channel with device: ", device.name)
	
	# Create new instrument track + channel pair
	var result = current_project.create_instrument_track(device.name)
	if not result:
		push_error("[Mixer] Failed to create instrument track")
		return
	
	var track = result["track"] as Track
	var channel = result["channel"] as Channel
	
	if not track or not channel:
		push_error("[Mixer] Invalid track or channel returned")
		return
	
	print("[Mixer] Created track: ", track.name, " (id=", track.id, ", channel_id=", track.default_channel_id, ")")
	print("[Mixer] Created channel: ", channel.name, " (id=", channel.id, ")")
	
	# Create device instance and add to channel
	var device_instance = DeviceInstance.new(device, channel.id, 0)
	channel.add_device(device_instance, -1)


func _create_sfz_instrument_channel(sfz_path: String, sfz_name: String) -> void:
	"""Create a new instrument channel with sfizz device and load the SFZ file."""
	print("[Mixer] Creating SFZ instrument channel: ", sfz_name)
	
	# Get the sfizz device from AssetService
	var sfizz_device = AssetService.get_device("sonara.builtin.sfizz")
	if not sfizz_device:
		push_error("[Mixer] Failed to get sfizz device")
		return
	
	# Create new instrument track + channel pair
	var result = current_project.create_instrument_track(sfz_name)
	if not result:
		push_error("[Mixer] Failed to create instrument track")
		return
	
	var track = result["track"] as Track
	var channel = result["channel"] as Channel
	
	if not track or not channel:
		push_error("[Mixer] Invalid track or channel returned")
		return
	
	print("[Mixer] Created track: ", track.name, " (id=", track.id, ", channel_id=", track.default_channel_id, ")")
	print("[Mixer] Created channel: ", channel.name, " (id=", channel.id, ")")
	
	# Create sfizz device instance and add to channel
	var device_instance = DeviceInstance.new(sfizz_device, channel.id, 0)
	channel.add_device(device_instance, -1)
	
	# Load the SFZ file into the device
	# Give the engine a moment to create the device before loading the file
	await get_tree().create_timer(0.1).timeout
	device_instance.load_file(sfz_path)
