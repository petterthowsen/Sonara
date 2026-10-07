# CompactDevicePanel.gd
#
# Foldable panel showing a device instance via the universal ParameterList.
# For use in ChannelDeviceList.

class_name CompactDevicePanel extends PanelContainer

var logger : Log = Log.make("CompactDevicePanel")

# ============================================================================
# NODE REFS
# ============================================================================
@onready var parameters : PanelContainer = %Parameters
@onready var parameters_box : VBoxContainer = %Parameters/VBox
@onready var header : PanelContainer = %Header
@onready var device_light: DeviceLightButton = %DeviceLight
@onready var name_label : SmartLineEdit = %Name
@onready var collapse_button : ToggleIconButton = %CollapseToggle

const ICON_WINDOW := preload("res://assets/icons/square-arrow-out-up-right.svg")

# ============================================================================
# PROPERTIES
# ============================================================================

@export var collapsed := false
@export var hide_parameters := false:
	set(hp):
		hide_parameters = hp
		if is_inside_tree():
			_update_ui_visibility()

var device_instance: DeviceInstance = null
var _param_list: ParameterList = null
var _hovered := false

## True while the ChannelDeviceList selected this panel's device. Selection swaps the theme
## variation (`DeviceCard` / `DeviceCardSelected`), the same border as DevicePanel.
var is_selected := false:
	set(selected):
		is_selected = selected
		theme_type_variation = &"DeviceCardSelected" if selected else &"DeviceCard"
var _button_hovered := false
var _name_hovered := false

# ============================================================================
# SIGNALS
# ============================================================================
signal request_context_menu()
## Left click. The ChannelDeviceList owns the selection; ctrl/cmd = additive, shift = range.
## Released without a drag collapses a multi-selection.
signal select_requested(panel: CompactDevicePanel, additive: bool, range_select: bool)
signal select_released(panel: CompactDevicePanel)


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	collapse_button.toggled.connect(_on_collapse_button_toggled)
	collapse_button.set_state(not collapsed)
	collapse_button.gui_input.connect(_on_collapse_button_gui_input)
	collapse_button.mouse_entered.connect(_set_button_hovered.bind(true))
	collapse_button.mouse_exited.connect(_set_button_hovered.bind(false))
	# Rename lives in the context menu; the name is a shift+click window target instead.
	name_label.edit_via_click = false
	name_label.mouse_entered.connect(_set_name_hovered.bind(true))
	name_label.mouse_exited.connect(_set_name_hovered.bind(false))
	name_label.value_changed.connect(_on_name_edited)
	# Fires for children too (Godot 4.2+), so the whole panel counts as hovered.
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	set_process(false)

	# Apply initial state
	_update_ui_visibility()


## Release engine subscriptions when the panel is freed (e.g. the channel's
## device list rebuilding, or a parent being freed), matching DevicePanel.
## Not _exit_tree(): DockHost reparents docks, which would wipe the parameter
## list with nothing to rebuild it.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


## Disconnect from the bound device instance. Idempotent.
func _unbind() -> void:
	if device_instance and device_instance.name_changed.is_connected(_on_device_name_changed):
		device_instance.name_changed.disconnect(_on_device_name_changed)
	if _param_list:
		_param_list.unbind()
	device_instance = null


func _gui_input(event: InputEvent) -> void:
	"""Handle GUI input: click selects the device (and channel), double-click opens the device."""
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.shift_pressed \
				and _name_hovered and _can_open_window():
			DeviceWindowManager.toggle(device_instance)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click:
			_on_double_clicked()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var additive := mb.ctrl_pressed or mb.meta_pressed
				select_requested.emit(self, additive, mb.shift_pressed)
				if not additive and not mb.shift_pressed:
					_select_channel()
			else:
				select_released.emit(self)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			request_context_menu.emit()


## Selecting a compact device also selects the channel it belongs to.
func _select_channel(multi := false) -> void:
	if not device_instance:
		return
	var channel := device_instance.get_channel()
	if channel:
		Sonara.editor.mixer.select_channel(channel, multi)


# ============================================================================
# PUBLIC METHODS
# ============================================================================

## Setup this panel with a device instance
func setup(p_device_instance: DeviceInstance, position: int) -> void:
	"""Setup this panel to show parameters for a device instance.

	Args:
		p_device_instance: The DeviceInstance to display
		position: Position in device chain (for display)
	"""
	logger.info("setup() called for device: %s at position %d" % [p_device_instance.get_display_name(), position])
	_unbind()
	device_instance = p_device_instance

	# Not `await ready`: setup() also runs on panels already in the tree (re-bind),
	# where awaiting an already-emitted `ready` would hang forever.
	if not is_node_ready():
		await ready

	# Set panel title to instance name
	_refresh_name_label()
	if not device_instance.name_changed.is_connected(_on_device_name_changed):
		device_instance.name_changed.connect(_on_device_name_changed)
	
	device_light.bind_to_device_instance(device_instance)
	
	tooltip_text = device_instance.device.name
	
	_ensure_param_list()
	_param_list.bind_to_device(device_instance, "param")


## Show the instance name in the compact header.
func _refresh_name_label() -> void:
	if device_instance == null or name_label == null:
		return
	name_label.set_value(device_instance.get_display_name())
	var type_name := device_instance.device.name if device_instance.device else ""
	name_label.tooltip_text = type_name
	tooltip_text = type_name


## Keep the compact header in sync with instance renames.
func _on_device_name_changed(_new_name: String) -> void:
	_refresh_name_label()


## Commit an inline rename from the header's SmartLineEdit.
func _on_name_edited(value) -> void:
	if device_instance == null:
		return
	name_label.set_value(DeviceActions.rename(device_instance, str(value)))


## Create the shared ParameterList once and host it in the compact panel.
func _ensure_param_list() -> void:
	if _param_list:
		return
	if parameters_box:
		for child in parameters_box.get_children():
			child.queue_free()
	_param_list = ParameterList.new()
	parameters_box.add_child(_param_list)
	_param_list.controls_changed.connect(func(_count): _update_ui_visibility())


## Update UI visibility based on collapsed and hide_parameters states
func _update_ui_visibility() -> void:
	"""Update visibility of parameters panel and collapse button based on state."""
	# The chevron only shows on hover, and only for devices with parameters. Hidden, it
	# takes no space, so the name gets the full header width.
	var has_params := _has_parameters()
	collapse_button.visible = (has_params or _can_open_window()) and _hovered
	# Only the parameters panel itself is forced hidden when hide_parameters is set
	# (channel not selected).
	parameters.visible = has_params and not hide_parameters and not collapsed


func _can_open_window() -> bool:
	return device_instance != null and device_instance.device != null \
		and (device_instance.device.has_gui() or device_instance.device.has_window_view())


## Shift over the collapse button turns it into an "open window" button.
func _set_button_hovered(hovered: bool) -> void:
	_button_hovered = hovered
	set_process(hovered or _name_hovered or _pointer_inside())
	_refresh_collapse_icon()


func _set_name_hovered(hovered: bool) -> void:
	_name_hovered = hovered
	set_process(hovered or _button_hovered or _pointer_inside())
	_refresh_collapse_icon()


func _refresh_collapse_icon() -> void:
	if (_button_hovered or _name_hovered) and Input.is_key_pressed(KEY_SHIFT) and _can_open_window():
		collapse_button.icon = ICON_WINDOW
		collapse_button.tooltip_text = "Open External Window"
	else:
		collapse_button.set_state(not collapsed)
		collapse_button.tooltip_text = ""


## Shift+click opens (or closes) the plugin GUI / device window instead of folding.
func _on_collapse_button_gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT and mb.shift_pressed and _can_open_window():
		if mb.pressed:
			DeviceWindowManager.toggle(device_instance)
		# Swallow press and release so the button doesn't toggle.
		collapse_button.accept_event()
		collapse_button.release_focus()


func _has_parameters() -> bool:
	return _param_list != null and _param_list.get_control_count() > 0


func _set_hovered(hovered: bool) -> void:
	# A child with MOUSE_FILTER_STOP (e.g. a plugin's own control) cuts the panel out of the
	# hover chain while the pointer is still over it. Poll until the pointer really leaves.
	if not hovered and _pointer_inside():
		set_process(true)
		return
	set_process(_button_hovered or _name_hovered)
	if _hovered == hovered:
		return
	_hovered = hovered
	_update_ui_visibility()


func _process(_delta: float) -> void:
	if _button_hovered or _name_hovered:
		_refresh_collapse_icon()
	if _hovered and not _pointer_inside():
		_set_hovered(false)


func _pointer_inside() -> bool:
	return is_visible_in_tree() and get_global_rect().has_point(get_global_mouse_position())


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_collapse_button_toggled(button_pressed: bool) -> void:
	"""Handle collapse button toggle."""
	collapsed = not button_pressed
	# Parameters only show on the selected channel, so expanding selects it.
	if not collapsed and hide_parameters:
		_select_channel()
	_update_ui_visibility()
	logger.info("Collapsed state changed to: %s" % collapsed)


func _on_double_clicked() -> void:
	"""Handle double-click - for devices with native GUI, open it; otherwise open DeviceLane."""
	if not device_instance:	
		return
	
	# If device has a native GUI, open it
	if device_instance.device.has_gui():
		device_instance.open_gui()
		return
	
	# For built-in devices: get the channel and open DeviceLane
	var channel := device_instance.get_channel()
	if not channel:
		push_warning("[CompactDevicePanel] Cannot find channel with ID %d" % device_instance.channel_id)
		return
	
	# For built-in devices: Select the channel in the mixer (this will emit channel_focused)
	Sonara.editor.mixer.select_channel(channel)
	
	# Show DeviceLane if hidden
	if not Sonara.editor.device_lane.visible:
		Sonara.editor.seconday_panel.show()
		Sonara.editor.device_lane.show()
		# DeviceLane will auto-bind to the focused channel via channel_focused signal
	
	# Wait a frame for the DeviceLane to update with the new channel
	await get_tree().process_frame
	
	# Select the device in the lane and scroll it into view
	if not Sonara.editor.device_lane.reveal_device(device_instance):
		push_warning("[CompactDevicePanel] Could not find DevicePanel for device: %s" % device_instance.device.name)


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Start a device drag (a DeviceDrag payload). Nothing moves until the drop.
func _get_drag_data(_at_position: Vector2) -> Variant:
	var list: ChannelDeviceList = null
	var node := get_parent()
	while node and not list:
		list = node as ChannelDeviceList
		node = node.get_parent()
	return DeviceDrag.start(self, device_instance, list.selection_containing(device_instance) if list else [])


## Resolve from the pointer in the enclosing device list: insert beside this panel, or onto its
## header (child into a container, file load). Outside a list, only drops onto the device.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if DeviceDropTarget.find_root(self):
		return DeviceDropTarget.resolve_for(self, data).is_valid()
	return DeviceDropUtil.can_drop_on_device(device_instance, data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if DeviceDropTarget.find_root(self):
		DeviceDropTarget.resolve_for(self, data).commit(data)
	else:
		DeviceDropUtil.drop_on_device(device_instance, data)
