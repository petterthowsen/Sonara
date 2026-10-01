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
@onready var size_mode_button: Button = $Toolbar/HBox/Toggles/SizeMode
@onready var compact_toggle: Button = $Toolbar/HBox/Toggles/Compact
@onready var io_toggle: Button = $Toolbar/HBox/Toggles/IO
@onready var sends_toggle: Button = $Toolbar/HBox/Toggles/Sends
@onready var devices_toggle: Button = $Toolbar/HBox/Toggles/Devices
@onready var big_meters_toggle: Button = $Toolbar/HBox/Toggles/BigMeters

## Narrow/medium/wide size-mode cycle button, in enum order.
const SIZE_MODE_LABELS := ["Narrow", "Medium", "Wide"]
var current_size_mode: MixerChannel.SizeMode = MixerChannel.SizeMode.MEDIUM

@onready var channel_ctx_menu : ChannelContextMenu = $ChannelContextMenu

# Project reference
var current_project: Project = null
## Channel -> the bound hierarchy_changed callable, kept so it can be disconnected.
var _channel_hierarchy_cbs: Dictionary[Channel, Callable] = {}

# Export property to control whether channels can be resized
@export var resizable_channels: bool = true

## Color of the strip drag insert line and group header glow.
@export var drop_indicator_color := DropIndicator.DEFAULT_COLOR

## Glowing strip drag overlay (top-level, so it never takes layout space), created on first use.
var _drop_indicator: DropIndicator = null

# ============================================================================
# Selection
# ============================================================================
enum LeftAddItem { INSTRUMENT_CHANNEL, GROUP_TRACK }

## Mixer pane a device drop on empty space adds a channel to (see new_channel_side).
const SIDE_NONE := -1
const SIDE_TRACKS := 0
const SIDE_BUSES := 1

var selection : Array[Channel] = []
var focused_channel : Channel = null

signal selection_changed(selection : Array[Channel])
signal channel_selected(channel : Channel)
signal channel_deselected(channel : Channel)
signal channel_focused(channel : Channel)


## The Mixer that owns `node`, or null.
static func of(node: Node) -> Mixer:
	while node:
		if node is Mixer:
			return node as Mixer
		node = node.get_parent()
	return null


## The other selected channels an edit to `channel` should also apply to (mixer multi-edit).
## Empty unless `channel` is one of several selected channels.
func get_multi_edit_peers(channel: Channel) -> Array[Channel]:
	var peers: Array[Channel] = []
	if selection.size() < 2 or not selection.has(channel):
		return peers
	for ch in selection:
		if ch != channel:
			peers.append(ch)
	return peers


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
	size_mode_button.text = SIZE_MODE_LABELS[current_size_mode]
	size_mode_button.pressed.connect(_on_size_mode_pressed)
	compact_toggle.toggled.connect(_on_compact_toggled)
	io_toggle.toggled.connect(_on_io_toggled)
	sends_toggle.toggled.connect(_on_sends_toggled)
	devices_toggle.toggled.connect(_on_devices_toggled)
	big_meters_toggle.toggled.connect(_on_big_meters_toggled)
	
	# Connect context menu signals
	channel_ctx_menu.delete_requested.connect(_on_channel_delete_requested)
	channel_ctx_menu.unnest_requested.connect(_on_channel_unnest_requested)
	
	# Strip drags (un-nest, reorder) and devices dropped on empty space (new channel) on both panes.
	var left_hbox := left_pane.get_node_or_null("HBox") as Control
	for node: Control in [left_pane, left_hbox, left_channels, right_pane, right_pane_hbox, right_channels]:
		if node:
			node.set_drag_forwarding(Callable(), _can_drop_data, _drop_data)

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


## Delete a channel from the context menu, with its linked tracks, as one undoable step.
func _on_channel_delete_requested(channel: Channel) -> void:
	if not current_project or channel == null or channel.is_master or channel.is_plugin_return():
		return
	HistoryUtil.execute(ChannelDeleteCommand.new(current_project, channel))


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


## Replace the selection without emitting (selection mirrored from the arranger).
func set_selection_silent(channels: Array[Channel], focused: Channel) -> void:
	for ch in selection:
		var old_ui := find_mixer_channel_ui_for_channel(ch)
		if old_ui:
			old_ui.is_selected = false
	selection.clear()
	for ch in channels:
		if ch == null or selection.has(ch):
			continue
		selection.append(ch)
		var mc := find_mixer_channel_ui_for_channel(ch)
		if mc:
			mc.is_selected = true
	focused_channel = focused


func _on_channel_item_gui_input(event : InputEvent, channel : Channel):
	if event is InputEventMouseButton:
		var me = event as InputEventMouseButton
		if me.button_index == MOUSE_BUTTON_LEFT and me.pressed:
			click_select_channel(channel, me.ctrl_pressed, me.shift_pressed)
			accept_event()
		elif me.button_index == MOUSE_BUTTON_LEFT and not me.pressed:
			click_released_on_channel(channel, me.ctrl_pressed, me.shift_pressed)


## Selection for a click on a strip: Shift selects the range from the focused strip, Ctrl toggles-adds.
func click_select_channel(ch: Channel, ctrl: bool, shift: bool) -> void:
	if shift:
		select_range(ch)
	elif not ctrl and selection.size() > 1 and selection.has(ch):
		# Pressing inside a multi-selection may start dragging all of it; a plain release collapses it.
		if focused_channel != ch:
			focused_channel = ch
			channel_focused.emit(ch)
	else:
		select_channel(ch, ctrl)


## A click that ended without dragging on a strip of a multi-selection selects just that strip.
func click_released_on_channel(ch: Channel, ctrl: bool, shift: bool) -> void:
	if not ctrl and not shift and selection.size() > 1 and selection.has(ch):
		select_channel(ch)


## Visible strips' channels in on-screen order: left pane (nested strips after their group), then
## the right pane.
func get_visible_channels_in_order() -> Array[Channel]:
	var entries: Array = []
	for node in get_tree().get_nodes_in_group("mixer_channel"):
		var mc := node as MixerChannel
		if mc == null or mc.channel == null or mc.is_queued_for_deletion() or not is_ancestor_of(mc) or not mc.is_visible_in_tree():
			continue
		var pane := 0 if left_pane.is_ancestor_of(mc) else 1
		entries.append([pane, mc.get_global_rect().position.x, mc.get_path().get_name_count(), mc.channel])
	entries.sort_custom(func(a, b):
		if a[0] != b[0]:
			return a[0] < b[0]
		if not is_equal_approx(a[1], b[1]):
			return a[1] < b[1]
		return a[2] < b[2])
	var result: Array[Channel] = []
	for e in entries:
		result.append(e[3])
	return result


## Strips a drag started on `primary` moves: the whole selection when `primary` is part of a
## multi-selection (same kind only, skipping ones already carried by a selected ancestor), in
## on-screen order; otherwise just `primary`.
func get_strip_drag_channels(primary: Channel) -> Array[Channel]:
	var result: Array[Channel] = [primary]
	if selection.size() < 2 or not selection.has(primary) or current_project == null:
		return result
	result.clear()
	for ch in get_visible_channels_in_order():
		if not selection.has(ch) or not MixerChannelDrag.can_drag(ch) or ch.is_bus != primary.is_bus:
			continue
		if _has_selected_ancestor(ch):
			continue
		result.append(ch)
	if not result.has(primary):
		return [primary]
	return result


func _has_selected_ancestor(ch: Channel) -> bool:
	var parent := current_project.get_channel_by_id(ch.parent_channel_id) if ch.parent_channel_id >= 0 else null
	while parent:
		if selection.has(parent):
			return true
		parent = current_project.get_channel_by_id(parent.parent_channel_id) if parent.parent_channel_id >= 0 else null
	return false


## Select every visible strip between the focused one (the anchor) and `ch`.
func select_range(ch: Channel) -> void:
	var ordered := get_visible_channels_in_order()
	var to := ordered.find(ch)
	var from := ordered.find(focused_channel) if focused_channel else -1
	if to < 0 or from < 0:
		select_channel(ch)
		return
	for c in selection.duplicate():
		deselect_channel(c, true, true, false)
	var lo := mini(from, to)
	var hi := maxi(from, to)
	for i in range(lo, hi + 1):
		select_channel(ordered[i], true, true, false)
	# The anchor stays the focus so the range can be re-aimed with another Shift-click.
	focused_channel = ordered[from]
	selection_changed.emit(selection)
	channel_focused.emit(focused_channel)


# ============================================================================
# KEYBOARD
# ============================================================================

## Left/Right move the selection, Up/Down nudge the fader (1 dB, 0.1 dB with Shift), Enter renames.
## Only while the pointer is over the mixer and no text field has focus.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or current_project == null or not is_visible_in_tree():
		return
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		return
	if not get_global_rect().has_point(get_global_mouse_position()):
		return
	match key.keycode:
		KEY_LEFT, KEY_RIGHT:
			_select_adjacent(-1 if key.keycode == KEY_LEFT else 1)
		KEY_UP, KEY_DOWN:
			_nudge_volume((1.0 if key.keycode == KEY_UP else -1.0) * (0.1 if key.shift_pressed else 1.0))
		KEY_ENTER, KEY_KP_ENTER:
			if key.echo or not _rename_focused():
				return
		_:
			return
	get_viewport().set_input_as_handled()


## Select the strip `step` places after (or before) the focused one.
func _select_adjacent(step: int) -> void:
	var ordered := get_visible_channels_in_order()
	if ordered.is_empty():
		return
	var index := ordered.find(focused_channel)
	if index < 0:
		index = 0 if step > 0 else ordered.size() - 1
	else:
		index = clampi(index + step, 0, ordered.size() - 1)
	select_channel(ordered[index])


## Change the volume of the selected channels (the focused one when nothing else is selected) by `delta_db`.
func _nudge_volume(delta_db: float) -> void:
	var primary := focused_channel
	if primary == null and not selection.is_empty():
		primary = selection[0]
	if primary == null:
		return
	var old_volume := primary.volume
	primary.set_volume(clampf(old_volume + delta_db, ChannelMultiEdit.MIN_DB, ChannelMultiEdit.MAX_DB))
	var peers := get_multi_edit_peers(primary)
	if peers.is_empty():
		HistoryUtil.record_property("Set Volume", primary, "set_volume", old_volume, primary.volume, true)
	else:
		ChannelMultiEdit.apply_volume(primary, old_volume, peers, ValueEditKind.Kind.DRAG)


## Start renaming the focused channel. Returns true when an editor opened.
func _rename_focused() -> bool:
	var mc := find_mixer_channel_ui_for_channel(focused_channel)
	if mc == null or mc.title == null:
		return false
	mc.title.start_editing()
	return mc.title.is_editing


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

## Cycle the narrow/medium/wide base width for every strip.
func _on_size_mode_pressed() -> void:
	current_size_mode = ((current_size_mode + 1) % SIZE_MODE_LABELS.size()) as MixerChannel.SizeMode
	size_mode_button.text = SIZE_MODE_LABELS[current_size_mode]
	get_tree().call_group("mixer_channel", "set_size_mode", current_size_mode)
	logger.info("Size mode: ", SIZE_MODE_LABELS[current_size_mode])


func _on_compact_toggled(pressed: bool) -> void:
	"""Toggle Tall vs Compact layout. Compact moves DeviceList/Sends into each strip's SidePane,
	which only shows (and slides out) while that strip is selected."""
	var layout := MixerChannel.LayoutMode.COMPACT if pressed else MixerChannel.LayoutMode.TALL
	get_tree().call_group("mixer_channel", "set_strip_layout_mode", layout)
	logger.info("Compact layout: ", pressed)


func _on_io_toggled(pressed: bool) -> void:
	"""Toggle IO panel visibility."""
	get_tree().call_group("mixer_channel_io", "set", "visible", pressed)
	logger.info("IO panel: ", pressed)


func _on_sends_toggled(pressed: bool) -> void:
	"""Toggle Sends panel visibility."""
	get_tree().call_group("mixer_channel_sends", "set", "visible", pressed)
	logger.info("Sends panel: ", pressed)

## Narrow strips hide the device list regardless of this toggle.
func _on_devices_toggled(pressed: bool) -> void:
	get_tree().call_group("mixer_channel", "set_devices_visible", pressed)
	logger.info("Devices panel: ", pressed)


func _on_big_meters_toggled(pressed: bool):
	get_tree().call_group("mixer_channel_big_meters", "set", "visible", pressed)
	get_tree().call_group("mixer_channel_compact_meter", "set", "visible", not pressed)
	get_tree().call_group("mixer_channel_fader", "set", "visible", pressed)


func _apply_toggle_states_to_channel(channel_item: MixerChannel) -> void:
	"""Apply current toggle states to a newly created mixer channel."""
	channel_item.set_size_mode(current_size_mode)
	var layout := MixerChannel.LayoutMode.COMPACT if compact_toggle.button_pressed else MixerChannel.LayoutMode.TALL
	channel_item.set_strip_layout_mode(layout)
	channel_item.set_resizable(resizable_channels)
	channel_item.set_devices_visible(devices_toggle.button_pressed)

	# Apply IO / Sends / meters from the toolbar so nested strips match roots.
	if channel_item.io:
		channel_item.io.visible = io_toggle.button_pressed
	if channel_item.sends_panel and channel_item.sends_panel.is_in_group("mixer_channel_sends"):
		channel_item.sends_panel.visible = sends_toggle.button_pressed
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
# DRAG AND DROP (strips, and devices dropped on empty space to create a channel)
# ============================================================================

## True when a strip drag would nest, insert, un-nest, or reorder at the pointer.
func can_drop_channel_drag(drag: MixerChannelDrag) -> bool:
	return MixerChannelDropTarget.resolve(self, drag, get_global_mouse_position()).is_valid()


## Apply a strip drag at the pointer through history.
func drop_channel_drag(drag: MixerChannelDrag) -> void:
	var target := MixerChannelDropTarget.resolve(self, drag, get_global_mouse_position())
	_hide_drop_indicator()
	if target.commit(self, drag):
		drag.destination = self
		drag.did_commit = true


## Move a root strip to sit after `after` (null = first) in its pane and persist the order.
## Returns true when the strip moved.
func place_root_strip(ch: Channel, after: Channel) -> bool:
	var mc := find_mixer_channel_ui_for_channel(ch)
	if mc == null:
		return false
	var box := mc.get_parent() as ChannelsBox
	if box != left_channels and box != right_channels:
		return false
	var index := 0
	if after:
		var after_ui := find_mixer_channel_ui_for_channel(after)
		if after_ui and after_ui.get_parent() == box:
			index = after_ui.get_index() + 1
			if after_ui.get_index() > mc.get_index():
				index -= 1
	index = clampi(index, 0, box.get_child_count() - 1)
	if index == mc.get_index():
		return false
	box.move_child(mc, index)
	box.sync_channel_order()
	return true


# ============================================================================
# DROP INDICATOR
# ============================================================================

## Show where a strip drag lands, or where the strip for a new channel appears; hidden otherwise.
func _process(_delta: float) -> void:
	var data: Variant = DragDrop.current_drag(self)
	var mouse := get_global_mouse_position()
	if current_project == null or data == null:
		_hide_drop_indicator()
	elif data is MixerChannelDrag:
		var target := MixerChannelDropTarget.resolve(self, data as MixerChannelDrag, mouse)
		if target.is_valid():
			_drop_indicator = DropIndicator.place(self, _drop_indicator, target.indicator_rect, target.is_nest(), drop_indicator_color)
		else:
			_hide_drop_indicator()
	elif can_drop_new_channel(data, mouse):
		var rect := _new_channel_line_rect(new_channel_side(mouse) == SIDE_BUSES)
		_drop_indicator = DropIndicator.place(self, _drop_indicator, rect, false, drop_indicator_color)
	else:
		_hide_drop_indicator()


## Unbind on free (not _exit_tree: DockHost reparents the mixer); drop the indicator on drag end.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()
	elif what == NOTIFICATION_DRAG_END:
		_hide_drop_indicator()


func _hide_drop_indicator() -> void:
	DropIndicator.hide_indicator(_drop_indicator)


## Pane under `mouse` that a device drop would add a channel to: SIDE_TRACKS (left),
## SIDE_BUSES (right), or SIDE_NONE over a strip (strips take device drops themselves) or elsewhere.
func new_channel_side(mouse: Vector2) -> int:
	for node in get_tree().get_nodes_in_group("mixer_channel"):
		if node is MixerChannel and is_ancestor_of(node) and DragDrop.is_point_visible(node as Control, mouse):
			return SIDE_NONE
	if DragDrop.is_point_visible(left_pane, mouse):
		return SIDE_TRACKS
	if DragDrop.is_point_visible(right_pane, mouse):
		return SIDE_BUSES
	return SIDE_NONE


## True when `data` (a device drag, Device/SFZ asset, or an array of assets) dropped at `mouse`
## creates a channel: instruments make instrument tracks and effects audio tracks on the left,
## effects make buses on the right.
func can_drop_new_channel(data: Variant, mouse: Vector2) -> bool:
	var side := new_channel_side(mouse)
	if current_project == null or side == SIDE_NONE:
		return false
	var items: Array = data if data is Array else [data]
	if items.is_empty():
		return false
	for item in items:
		if DeviceDropUtil.new_channel_kind(item, side == SIDE_BUSES).is_empty():
			return false
	return true


## Create a channel per dropped item on the pane under `mouse`. Returns the channels created.
func drop_new_channel(data: Variant, mouse: Vector2) -> Array[Channel]:
	var created: Array[Channel] = []
	if not can_drop_new_channel(data, mouse):
		return created
	var buses := new_channel_side(mouse) == SIDE_BUSES
	for item in (data if data is Array else [data]):
		var channel := DeviceDropUtil.create_channel_for(current_project, item, buses)
		if channel:
			created.append(channel)
	if data is DeviceDrag and not created.is_empty():
		(data as DeviceDrag).did_commit = true
	return created


## Vertical line after the last strip of the pane where a new channel's strip will appear.
func _new_channel_line_rect(buses: bool) -> Rect2:
	var box: Control = right_channels if buses else left_channels
	var box_rect := box.get_global_rect()
	var x := box_rect.position.x
	for child in box.get_children():
		if child is MixerChannel and child.visible and not child.is_queued_for_deletion():
			x = maxf(x, (child as MixerChannel).get_global_rect().end.x)
	var clip := DragDrop.visible_rect(right_pane if buses else left_pane)
	var half := DropIndicator.LINE_WIDTH * 0.5
	x = clampf(x, clip.position.x + half, clip.end.x - half)
	return DropIndicator.line_rect(x, box_rect, true)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is MixerChannelDrag:
		return can_drop_channel_drag(data as MixerChannelDrag)
	return can_drop_new_channel(data, get_global_mouse_position())


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is MixerChannelDrag:
		drop_channel_drag(data as MixerChannelDrag)
		return
	_hide_drop_indicator()
	drop_new_channel(data, get_global_mouse_position())
