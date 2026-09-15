# Mixer.gd
# 
# A two-pane Mixer interface with track/instrument channels on the left pane
# and buses on the right pane.
# 
# default Master mus should go at the end of RightPane/HBox
class_name Mixer extends VBoxContainer

var logger : Log = Log.make("Mixer")

# CONSTANTS
const MixerChannelScene = preload("res://mixer/MixerChannel.tscn")

# ============================================================================
# NODE REFERENCES
# ============================================================================
@onready var h_split: HSplitContainer = $HSplit
@onready var toolbar: PanelContainer = $Toolbar

@onready var left_pane: ScrollContainer = $HSplit/LeftPane
@onready var left_channels: HBoxContainer = $HSplit/LeftPane/HBox/Channels
@onready var left_add_button: MenuButton = $HSplit/LeftPane/HBox/Options/AddButton

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
## Channel -> the bound hierarchy_changed callable, kept so it can be disconnected.
var _channel_hierarchy_cbs: Dictionary[Channel, Callable] = {}

# Export property to control whether channels can be resized
@export var resizable_channels: bool = true

# ============================================================================
# Selection
# ============================================================================
enum LeftAddItem { INSTRUMENT_CHANNEL, GROUP_TRACK }

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
	_setup_left_add_menu()
	right_add_button.pressed.connect(_on_right_add_button_pressed)

	# Connect toolbar toggles
	compact_toggle.toggled.connect(_on_compact_toggled)
	io_toggle.toggled.connect(_on_io_toggled)
	sends_toggle.toggled.connect(_on_sends_toggled)
	big_meters_toggle.toggled.connect(_on_big_meters_toggled)
	
	# Connect context menu signals
	channel_ctx_menu.delete_requested.connect(_on_channel_delete_requested)
	channel_ctx_menu.unnest_requested.connect(_on_channel_unnest_requested)
	
	# Enable drag and drop on left pane for devices, SFZ files, and un-nesting
	left_pane.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	var left_hbox := left_pane.get_node_or_null("HBox") as Control
	if left_hbox:
		left_hbox.set_drag_forwarding(Callable(), _can_drop_data, _drop_data)
	left_channels.set_drag_forwarding(Callable(), _can_drop_data, _drop_data)

# ============================================================================
# EDITOR/PROJECT SIGNAL CALLBACKS
# ============================================================================

func _on_project_opened(project: Project) -> void:
	"""Called when a project is opened - build UI for all channels."""
	logger.info("Project opened: ", project.project_name)

	_unbind()
	_clear_all_channels()
	current_project = project

	# Connect to project signals
	project.channel_added.connect(_on_channel_added)
	project.channel_removed.connect(_on_channel_removed)

	# Nested children spawn inside fold-outs; root panes list parent_channel_id < 0, sorted by order.
	var roots: Array[Channel] = []
	for ch in project.channels:
		_connect_channel_mixer_signals(ch)
		if ch.parent_channel_id < 0:
			roots.append(ch)
	roots.sort_custom(func(a, b):
		if a.order != b.order:
			return a.order < b.order
		return a.id < b.id
	)
	for ch in roots:
		_spawn_root_channel_ui(ch)


func _on_project_closed() -> void:
	"""Clear all channel items when project closes."""
	_unbind()
	_clear_all_channels()


## Disconnect from the current project and its channels. Idempotent.
func _unbind() -> void:
	if current_project:
		if current_project.channel_added.is_connected(_on_channel_added):
			current_project.channel_added.disconnect(_on_channel_added)
		if current_project.channel_removed.is_connected(_on_channel_removed):
			current_project.channel_removed.disconnect(_on_channel_removed)
		for ch in current_project.channels:
			_disconnect_channel_mixer_signals(ch)
	# Channels removed without a channel_removed signal still hold a callable here.
	for ch in _channel_hierarchy_cbs.keys():
		_disconnect_channel_mixer_signals(ch)
	current_project = null
	selection.clear()
	focused_channel = null


## Unbind on free (not _exit_tree: DockHost reparents the mixer).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


func _on_channel_added(channel: Channel) -> void:
	"""Create a MixerChannel UI element for the new channel."""
	_connect_channel_mixer_signals(channel)

	# Nested children are spawned by the parent fold-out; skip root panes.
	if channel.parent_channel_id >= 0:
		_rebuild_all_routing_menus()
		logger.info("Nested channel skipped for root panes: ", channel.name, " with ID ", channel.id)
		return

	_spawn_root_channel_ui(channel)


## Listen for rename/hierarchy on a channel whether it is a root strip or nested.
func _connect_channel_mixer_signals(channel: Channel) -> void:
	if channel == null:
		return
	if not channel.name_changed.is_connected(_on_any_channel_renamed):
		channel.name_changed.connect(_on_any_channel_renamed)
	if not _channel_hierarchy_cbs.has(channel):
		var hierarchy_cb := _on_channel_hierarchy_changed.bind(channel)
		_channel_hierarchy_cbs[channel] = hierarchy_cb
		channel.hierarchy_changed.connect(hierarchy_cb)


## Undo _connect_channel_mixer_signals.
func _disconnect_channel_mixer_signals(channel: Channel) -> void:
	if channel == null:
		return
	if channel.name_changed.is_connected(_on_any_channel_renamed):
		channel.name_changed.disconnect(_on_any_channel_renamed)
	var hierarchy_cb: Callable = _channel_hierarchy_cbs.get(channel, Callable())
	if hierarchy_cb.is_valid() and channel.hierarchy_changed.is_connected(hierarchy_cb):
		channel.hierarchy_changed.disconnect(hierarchy_cb)
	_channel_hierarchy_cbs.erase(channel)


## Place a top-level MixerChannel in the left or right pane and bind it.
func _spawn_root_channel_ui(channel: Channel) -> void:
	if MixerChannelScene == null:
		push_warning("[Mixer] No MixerChannelScene assigned")
		return
	if find_mixer_channel_ui_for_channel(channel):
		return

	var channel_item = MixerChannelScene.instantiate() as MixerChannel

	if channel.is_master:
		right_pane_hbox.add_child(channel_item)
	elif channel.is_bus:
		right_channels.add(channel_item)
	else:
		left_channels.add(channel_item)

	channel_item.bind_to_channel(channel, current_project)
	wire_channel_item(channel_item)

	_rebuild_all_routing_menus()
	if channel.is_bus:
		_rebuild_all_sends_panels()

	logger.info("Channel added: ", channel.name, " with ID ", channel.id, " and order ", channel.order)


## Wire selection, context menu, and toolbar toggles for a strip (root or nested).
func wire_channel_item(channel_item: MixerChannel) -> void:
	if channel_item == null or channel_item.channel == null:
		return
	var channel := channel_item.channel
	if not channel_item.request_show_context_menu.is_connected(_on_channel_request_context_menu.bind(channel)):
		channel_item.request_show_context_menu.connect(_on_channel_request_context_menu.bind(channel))
	if not channel_item.gui_input.is_connected(_on_channel_item_gui_input.bind(channel)):
		channel_item.gui_input.connect(_on_channel_item_gui_input.bind(channel))
	_apply_toggle_states_to_channel(channel_item)
	if selection.has(channel):
		channel_item.is_selected = true


## Move a strip between root panes and nested fold-outs when parent_channel_id changes.
func _on_channel_hierarchy_changed(channel: Channel) -> void:
	if channel == null:
		return
	if channel.parent_channel_id >= 0:
		var nested_ui := find_mixer_channel_ui_for_channel(channel)
		if nested_ui and _is_root_mixer_channel(nested_ui):
			nested_ui.queue_free()
		_rebuild_all_routing_menus()
		return

	if channel.is_master or channel.is_bus:
		_rebuild_all_routing_menus()
		return

	var mc := find_mixer_channel_ui_for_channel(channel)
	if mc and not _is_root_mixer_channel(mc):
		mc.queue_free()
		mc = null
	if mc == null:
		_spawn_root_channel_ui(channel)
	_rebuild_all_routing_menus()


## True when this MixerChannel sits in a mixer pane rather than a group fold-out.
func _is_root_mixer_channel(mc: MixerChannel) -> bool:
	if mc == null:
		return false
	var p := mc.get_parent()
	return p == left_channels or p == right_channels or p == right_pane_hbox


func _on_channel_removed(channel: Channel) -> void:
	"""Remove the MixerChannel UI element when a channel is removed."""
	_disconnect_channel_mixer_signals(channel)

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
		
		logger.info("Channel removed from UI: ", channel.name, " (ID: ", channel.id, ")")


## Un-nest a group child from the mixer context menu.
func _on_channel_unnest_requested(channel: Channel) -> void:
	if not current_project or channel == null:
		return
	MixerChannelDrag.commit(current_project, channel, null)


func _on_channel_delete_requested(channel: Channel) -> void:
	"""Handle delete request from context menu."""
	if not current_project:
		return
	
	# Confirm deletion (skip for now, directly delete)
	current_project.remove_channel(channel.id)


func deselect_channel(ch : Channel, erase := true, emit_deselect := true, emit_changed := true):
	if selection.has(ch):
		var mc = find_mixer_channel_ui_for_channel(ch)
		if mc:
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
		if mc:
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
	if channel == null or not is_inside_tree():
		return null
	for node in get_tree().get_nodes_in_group("mixer_channel"):
		if not (node is MixerChannel):
			continue
		if node.is_queued_for_deletion() or not node.is_inside_tree():
			continue
		if (node as MixerChannel).channel == channel:
			return node
	return null


## Populate the left-pane + menu: channel-only instrument, or a Group track.
func _setup_left_add_menu() -> void:
	if left_add_button == null:
		return
	var popup := left_add_button.get_popup()
	popup.clear()
	popup.add_item("New Instrument Channel", LeftAddItem.INSTRUMENT_CHANNEL)
	popup.add_item("New Group Track", LeftAddItem.GROUP_TRACK)
	if not popup.id_pressed.is_connected(_on_left_add_menu_pressed):
		popup.id_pressed.connect(_on_left_add_menu_pressed)


## Handle left-pane + menu: instrument channel (no track) or Group track.
func _on_left_add_menu_pressed(id: int) -> void:
	if not Sonara or not Sonara.editor or not Sonara.editor.project:
		push_warning("[Mixer] No project open")
		return
	var project := Sonara.editor.project
	match id:
		LeftAddItem.INSTRUMENT_CHANNEL:
			var channel := project.create_channel(
				"Instrument %d" % project.channels.size(),
				Channel.ChannelType.INSTRUMENT
			)
			channel.output_channel_id = 1
			logger.info("Added new instrument channel: ", channel.name)
		LeftAddItem.GROUP_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "group", "Group"))


func _on_right_add_button_pressed() -> void:
	"""Add a new bus channel to the right pane."""
	if not Sonara or not Sonara.editor or not Sonara.editor.project:
		push_warning("[Mixer] No project open")
		return

	var project = Sonara.editor.project
	var channel = project.create_channel("Bus %d" % (project.channels.size()), Channel.ChannelType.BUS)
	channel.output_channel_id = 1  # Route to master
	logger.info("Added new bus channel: ", channel.name)

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

	logger.info("All channels cleared")


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

	logger.info("Compact mode: ", pressed, " | Resizable channels: ", resizable_channels)


func _on_io_toggled(pressed: bool) -> void:
	"""Toggle IO panel visibility."""
	get_tree().call_group("mixer_channel_io", "set", "visible", pressed)
	logger.info("IO panel: ", pressed)


func _on_sends_toggled(pressed: bool) -> void:
	"""Toggle Sends panel visibility."""
	get_tree().call_group("mixer_channel_sends", "set", "visible", pressed)
	logger.info("Sends panel: ", pressed)

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

	# Apply IO / Sends / meters from the toolbar so nested strips match roots.
	if channel_item.io:
		channel_item.io.visible = io_toggle.button_pressed
	if channel_item.sends_panel:
		channel_item.sends_panel.get_parent().visible = sends_toggle.button_pressed
	if channel_item.big_meter:
		channel_item.big_meter.visible = big_meters_toggle.button_pressed
	if channel_item.bottom_small_meter:
		channel_item.bottom_small_meter.visible = not big_meters_toggle.button_pressed
	if channel_item.bottom_volume_slider:
		channel_item.bottom_volume_slider.visible = big_meters_toggle.button_pressed


# ============================================================================
# ROUTING MENU HELPERS
# ============================================================================

## Refresh routing dropdowns when any channel (usually a bus) is renamed.
func _on_any_channel_renamed(_new_name: String) -> void:
	_rebuild_all_routing_menus()


func _rebuild_all_routing_menus() -> void:
	"""Rebuild routing menus for all mixer channels, including nested strips."""
	if not is_inside_tree():
		return
	get_tree().call_group("mixer_channel", "_rebuild_output_menu")


func _rebuild_all_sends_panels() -> void:
	"""Rebuild sends panels for all mixer channels when a bus is added or removed."""
	logger.info("Rebuilding all sends panels")
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("mixer_channel"):
		if node is MixerChannel and node.sends_panel:
			node.sends_panel._rebuild_sends_ui()


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
	"""Accept an un-nest to the left-pane root, or device/SFZ assets that create channels."""
	if not current_project:
		return false

	if data is MixerChannelDrag:
		return MixerChannelDrag.can_unnest((data as MixerChannelDrag).channel)

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
	"""Handle dropping a nested strip (un-nest) or device/SFZ assets on the left pane."""
	if not current_project:
		return

	if data is MixerChannelDrag:
		var drag := data as MixerChannelDrag
		if MixerChannelDrag.commit(current_project, drag.channel, null):
			drag.destination = self
			drag.did_commit = true
		return
	
	# Handle array of assets
	if data is Array:
		logger.info("Dropping %d assets" % data.size())
		for asset in data:
			if asset is Asset:
				_handle_single_asset_drop(asset)
		return
	
	# Handle single asset
	if data is Asset:
		_handle_single_asset_drop(data)


## Instruments and SFZ files dropped on empty mixer space get their own instrument channel.
func _handle_single_asset_drop(asset: Asset) -> void:
	if DeviceDropUtil.creates_instrument_track(asset):
		DeviceDropUtil.create_instrument_track_for_asset(current_project, asset)
	elif asset.type == Asset.TYPE.Device:
		push_warning("[Mixer] Cannot drop %s on empty area. Drop on an existing channel instead." % asset.get_display_name())
