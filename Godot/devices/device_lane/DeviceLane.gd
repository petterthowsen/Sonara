class_name DeviceLane extends HBoxContainer

## Gap between the parent header and the channel header, in pixels.
const PARENT_HEADER_GAP := 4

var logger : Log = Log.make("DeviceLane")

@onready var header: Panel = $Header
@onready var header_label: VerticalLabel = $Header/Label

## The channel's devices; open container slots sit beside their container (DeviceLaneItem).
@onready var devices: DeviceRow = $Content/ScrollContainer/Devices

@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu

var channel : Channel
## Mixer parent of the bound channel, shown as a clickable header left of the channel header.
var _parent_channel: Channel = null
var _parent_header: Panel = null
var _parent_header_label: VerticalLabel = null
## Spacer between the parent header and the channel header; visible with the parent header.
var _parent_header_gap: Control = null
## Device row drop rules; DeviceDropTarget resolves drops for this lane and its open slots.
var drop_host := DeviceChainDropHost.new()
## Glowing drop overlay (top-level, so it never takes layout space), created on first use.
var _drop_indicator: DropIndicator = null
## A drum pad return shows its pad lane (pad device + own devices), rebuilt on every change.
var _pad_lane := PadLaneWatcher.new()
var current_project: Project = null  # Track which project we're listening to
## Devices whose panels this lane selected (see DevicePanel.select_requested). Dragging one of
## them moves the whole block (DeviceDrag.devices).
signal device_selection_changed(selected: Array[DeviceInstance])
var selected_devices: Array[DeviceInstance] = []
var _selection_anchor: DeviceInstance = null
## Multi-selected device of the last press; on release without a drag the block collapses to it.
var _pending_single: DeviceInstance = null
var _scroll_tween: Tween = null

func _ready():
	# Root panels start below the color strip of the slots beside them, so the two line up.
	devices.panel_top_inset = DeviceSlotGroup.STRIP_HEIGHT
	devices.context_menu_requested.connect(_on_device_context_menu_requested)
	drop_host.attach(self, devices, false)
	drop_host.trailing_margin = DeviceRow.PANEL_MARGIN
	add_to_group(DeviceDropTarget.ROOT_GROUP)
	set_process(false)
	_create_parent_header()
	drop_host.attach(self, devices, false)
	drop_host.trailing_margin = DeviceRow.PANEL_MARGIN
	devices.selection_requested.connect(_on_panel_select_requested)
	devices.selection_released.connect(_on_panel_select_released)
	
	# No editor in headless tests: the lane is bound directly.
	if Sonara.editor == null:
		return
	# Connect to the Mixer's channel_focused signal via Sonara.editor
	Sonara.editor.channel_focused.connect(_on_channel_focused)
	
	# Connect to project lifecycle to clean up when project closes
	Sonara.editor.project_closed.connect(_on_project_closed)
	
	# Connect to project opened to listen for channel removal
	Sonara.editor.project_opened.connect(_on_project_opened)
	
	# If project already exists, connect to it
	if Sonara.editor.project:
		_connect_to_project(Sonara.editor.project)


func _on_channel_focused(focused_channel: Channel):
	"""Called when a channel is focused in the mixer."""
	if focused_channel:
		bind_to_channel(focused_channel)


func _on_project_opened(project: Project):
	"""Called when a project is opened - connect to channel removal signal."""
	_connect_to_project(project)


func _connect_to_project(project: Project):
	"""Connect to project's channel_removed signal."""
	# Disconnect from previous project if any
	if current_project:
		if current_project.channel_removed.is_connected(_on_channel_removed):
			current_project.channel_removed.disconnect(_on_channel_removed)
	
	# Connect to new project
	current_project = project
	if project:
		project.channel_removed.connect(_on_channel_removed)


func _on_project_closed():
	"""Called when a project is closed - clean up device lane."""
	# Disconnect from project signals
	if current_project:
		if current_project.channel_removed.is_connected(_on_channel_removed):
			current_project.channel_removed.disconnect(_on_channel_removed)
		current_project = null
	
	# Unbind from current channel if any
	if channel:
		unbind()
		channel = null
	
	# Clear all device panels
	clear()


func _on_channel_removed(removed_channel: Channel):
	"""Called when a channel is removed from the project."""
	# If the removed channel is the one we're bound to, clear ourselves
	if channel and channel.id == removed_channel.id:
		logger.info("[DeviceLane] Bound channel removed, clearing device lane")
		unbind()
		channel = null
		clear()

func _get_header_stylebox() -> StyleBoxFlat:
	return header.get_theme_stylebox("panel")


func unbind():
	_bind_parent_header(null)
	channel.hierarchy_changed.disconnect(_refresh_parent_header)
	channel.name_changed.disconnect(_on_channel_name_changed)
	channel.color_changed.disconnect(_on_channel_color_changed)
	channel.device_added.disconnect(_add_device)
	channel.device_removed.disconnect(_on_channel_device_remmoved)
	channel.device_moved.disconnect(_on_channel_device_moved)
	drop_host.bind(null)
	_pad_lane.bind(null)


func clear():
	header_label.text = "N/A"
	_bind_parent_header(null)
	_clear_devices()


## Empty the lane, its panels and the device selection.
func _clear_devices() -> void:
	devices.clear()
	selected_devices.clear()
	_selection_anchor = null
	_pending_single = null


## Show the channel's devices (a pad return's pad lane) in order, keeping panels that stay.
func _sync_devices() -> void:
	if channel == null:
		return
	devices.sync(PadLane.devices(channel) if _pad_lane.active() else channel.devices)
	_refresh_selection()

func _on_pad_lane_changed() -> void:
	if _pad_lane.active():
		_sync_devices()


func bind_to_channel(channel : Channel):
	# already bound to this channel?
	if self.channel == channel:
		return
	
	# unbind to previously shown channel
	if self.channel:
		unbind()
	
	# clear any device controls
	clear()
	
	# bind to new channel
	self.channel = channel
	drop_host.bind(channel)
	_pad_lane.bind(channel)
	
	# set heade label and bg color
	header_label.text = channel.name
	var sb := _get_header_stylebox()
	sb.bg_color = channel.color
	
	# set up all devices
	_sync_devices()
	
	# connect to channel events
	channel.hierarchy_changed.connect(_refresh_parent_header)
	_refresh_parent_header()
	channel.name_changed.connect(_on_channel_name_changed)
	channel.color_changed.connect(_on_channel_color_changed)
	channel.device_added.connect(_add_device)
	channel.device_removed.connect(_on_channel_device_remmoved)
	channel.device_moved.connect(_on_channel_device_moved)


func _add_device(_device_instance : DeviceInstance, _position : int):
	if not _pad_lane.active():
		_sync_devices()


## Panel showing `device_instance`, at the root or inside an open container slot.
func find_device_panel(device_instance : DeviceInstance) -> DevicePanel:
	return devices.find_panel(device_instance)


## Select `device_instance` alone and smoothly scroll the lane so its panel is in view.
## Returns false when no panel shows it.
func reveal_device(device_instance: DeviceInstance, duration := 0.2) -> bool:
	var panel := find_device_panel(device_instance)
	if panel == null:
		return false
	selected_devices = [device_instance]
	_selection_anchor = device_instance
	_refresh_selection()
	device_selection_changed.emit(selected_devices.duplicate())
	panel.grab_focus()

	var scroll: ScrollContainer = $Content/ScrollContainer
	var left := panel.global_position.x - devices.global_position.x
	var right := left + panel.size.x
	var target := scroll.scroll_horizontal
	if left < scroll.scroll_horizontal:
		target = int(left)
	elif right > scroll.scroll_horizontal + scroll.size.x:
		target = int(right - scroll.size.x)
	target = clampi(target, 0, maxi(0, int(devices.size.x - scroll.size.x)))
	if _scroll_tween:
		_scroll_tween.kill()
	_scroll_tween = create_tween()
	_scroll_tween.tween_property(scroll, "scroll_horizontal", target, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return true


## A device left the root chain (removed, nested into a container or moved to another channel).
func _on_channel_device_remmoved(_position : int, _device_id : String):
	if not _pad_lane.active():
		_sync_devices()


func _on_channel_device_moved(_from_position: int, _to_position: int):
	if not _pad_lane.active():
		_sync_devices()


func _on_channel_name_changed(ch_name : String):
	header_label.text = ch_name


func _on_channel_color_changed(c : Color):
	var sb := _get_header_stylebox()
	sb.bg_color = c


# ============================================================================
# PARENT HEADER
# ============================================================================

## Build the parent header as a copy of the channel header, placed to its left.
func _create_parent_header() -> void:
	_parent_header = header.duplicate() as Panel
	_parent_header.name = "ParentHeader"
	_parent_header.custom_minimum_size.x = 32
	_parent_header.add_theme_stylebox_override("panel", _get_header_stylebox().duplicate())
	_parent_header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_parent_header_label = _parent_header.get_node("Label") as VerticalLabel
	_parent_header_label.font_size = 16
	_parent_header_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent_header.gui_input.connect(_on_parent_header_gui_input)
	_parent_header.visible = false
	add_child(_parent_header)
	move_child(_parent_header, header.get_index())

	# Separate the two headers so the parent doesn't read as part of the channel header.
	_parent_header_gap = Control.new()
	_parent_header_gap.name = "ParentHeaderGap"
	_parent_header_gap.custom_minimum_size.x = PARENT_HEADER_GAP
	_parent_header_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent_header_gap.visible = false
	add_child(_parent_header_gap)
	move_child(_parent_header_gap, header.get_index())


## Show the bound channel's mixer parent, or hide the header for a top-level channel.
func _refresh_parent_header() -> void:
	var parent: Channel = null
	if channel and channel.parent_channel_id >= 0:
		var project := channel.get_project()
		if project:
			parent = project.get_channel_by_id(channel.parent_channel_id)
	_bind_parent_header(parent)


## Point the parent header at `parent` (null hides it) and follow its name and color.
func _bind_parent_header(parent: Channel) -> void:
	if _parent_header == null or parent == _parent_channel:
		return
	if _parent_channel:
		_parent_channel.name_changed.disconnect(_on_parent_name_changed)
		_parent_channel.color_changed.disconnect(_on_parent_color_changed)
	_parent_channel = parent
	_parent_header.visible = parent != null
	if _parent_header_gap:
		_parent_header_gap.visible = parent != null
	if parent == null:
		return
	parent.name_changed.connect(_on_parent_name_changed)
	parent.color_changed.connect(_on_parent_color_changed)
	_on_parent_name_changed(parent.name)
	_on_parent_color_changed(parent.color)


func _on_parent_name_changed(ch_name: String) -> void:
	_parent_header_label.text = ch_name
	_parent_header.tooltip_text = "Go to %s" % ch_name


func _on_parent_color_changed(c: Color) -> void:
	(_parent_header.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = c


## Clicking the parent header selects the parent the same way a mixer click does.
func _on_parent_header_gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or _parent_channel == null:
		return
	accept_event()
	Sonara.editor.mixer.select_channel(_parent_channel)


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

## A Drum Machine pad's slot chain, asked for from its pad (`in_slot`), offers Remove Pad (the pad
## and its return); in the pad's own lane Remove only empties the pad.
func _on_device_context_menu_requested(device_instance : DeviceInstance, in_slot: bool) -> void:
	device_context_menu.removes_drum_pad = in_slot
	device_context_menu.bind_to_device(device_instance)
	var c_pos = get_global_mouse_position()
	var c_size = device_context_menu.get_contents_minimum_size()
	device_context_menu.popup(Rect2(c_pos, c_size))
	device_context_menu.show()

# ============================================================================
# DEVICE SELECTION
# ============================================================================

## A panel was clicked: plain clicks select one device, ctrl/cmd adds or removes, shift takes
## the visual range from the anchor. A plain click on part of a multi-selection keeps the block
## (so the drag moves it all) and collapses on release.
func _on_panel_select_requested(panel: DevicePanel, additive: bool, range_select: bool) -> void:
	var inst := panel.device
	if inst == null:
		return
	_pending_single = null
	if not additive and not range_select and selected_devices.size() > 1 and selected_devices.has(inst):
		_pending_single = inst
		return
	if additive:
		if selected_devices.has(inst):
			selected_devices.erase(inst)
		else:
			selected_devices.append(inst)
		_selection_anchor = inst
	elif range_select and _selection_anchor != null:
		selected_devices = _devices_in_visual_range(_selection_anchor, inst)
	else:
		if not (selected_devices.size() == 1 and selected_devices[0] == inst):
			selected_devices = [inst]
		_selection_anchor = inst
	_refresh_selection()
	device_selection_changed.emit(selected_devices.duplicate())


## The click was released: a multi-selection held for a drag collapses to the clicked device.
func _on_panel_select_released(panel: DevicePanel) -> void:
	var inst := panel.device
	if inst != null and inst == _pending_single:
		selected_devices = [inst]
		_selection_anchor = inst
		_refresh_selection()
		device_selection_changed.emit(selected_devices.duplicate())
	_pending_single = null


## Devices shown between `a` and `b` in this lane (inclusive), or `b` alone when there is no
## order between them.
func _devices_in_visual_range(a: DeviceInstance, b: DeviceInstance) -> Array[DeviceInstance]:
	var order := devices.collect_panels().map(func(p): return p.device)
	var start := order.find(a)
	var end := order.find(b)
	if start < 0 or end < 0:
		return [b]
	if start > end:
		var t := start
		start = end
		end = t
	return order.slice(start, end + 1)


## Drop devices no longer shown and push the selection onto the panels.
func _refresh_selection() -> void:
	var shown := devices.collect_panels().map(func(p): return p.device)
	selected_devices = selected_devices.filter(func(d): return d != null and shown.has(d)) as Array[DeviceInstance]
	if not shown.has(_selection_anchor):
		_selection_anchor = null
	if not shown.has(_pending_single):
		_pending_single = null
	for panel in devices.collect_panels():
		panel.is_selected = selected_devices.has(panel.device)


## The lane's selection when it contains `inst` (for DeviceDrag.start), else empty.
func selection_containing(inst: DeviceInstance) -> Array[DeviceInstance]:
	if not selected_devices.has(inst):
		return []
	return selected_devices.duplicate()


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Show where a device or asset drag lands (only while one is in progress).
func _process(_delta: float) -> void:
	_drop_indicator = DeviceDropTarget.update_indicator(self, _drop_indicator)


## Resolve drops only while a device or asset drag is in progress; let child controls forward them.
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		var data: Variant = DragDrop.current_drag(self)
		if DeviceDropTarget.accepts(data):
			DragDrop.forward_drops(self, _can_drop_data, _drop_data, DeviceDropTarget.OWN_DROPS_GROUP)
			set_process(true)
	elif what == NOTIFICATION_DRAG_END:
		set_process(false)
		DropIndicator.hide_indicator(_drop_indicator)


## Drops anywhere on the lane resolve from the pointer (insert between panels, or onto a device).
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return DeviceDropTarget.resolve_for(self, data).is_valid()


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	DeviceDropTarget.resolve_for(self, data).commit(data)
	DropIndicator.hide_indicator(_drop_indicator)
