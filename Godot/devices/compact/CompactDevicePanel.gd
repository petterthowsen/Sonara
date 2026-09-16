# CompactDevicePanel.gd
#
# Foldable panel showing a device instance via the universal ParameterList.
# For use in ChannelDeviceList.

class_name CompactDevicePanel extends VBoxContainer

var logger : Log = Log.make("CompactDevicePanel")

# ============================================================================
# NODE REFS
# ============================================================================
@onready var parameters : PanelContainer = $Parameters
@onready var parameters_box : VBoxContainer = $Parameters/VBox
@onready var header : PanelContainer = $Header
@onready var device_light: DeviceLightButton = $Header/HBoxContainer/DeviceLight
@onready var name_label : SmartLineEdit = $Header/HBoxContainer/Name
@onready var collapse_button : ToggleIconButton = $Header/HBoxContainer/CollapseToggle

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

# ============================================================================
# SIGNALS
# ============================================================================
signal request_context_menu()


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	collapse_button.toggled.connect(_on_collapse_button_toggled)
	collapse_button.set_state(not collapsed)
	name_label.value_changed.connect(_on_name_edited)

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
	"""Handle GUI input: single-click selects the channel, double-click opens the device."""
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click:
			_on_double_clicked()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_select_channel(mb.ctrl_pressed)
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


## Update UI visibility based on collapsed and hide_parameters states
func _update_ui_visibility() -> void:
	"""Update visibility of parameters panel and collapse button based on state."""
	# The collapse toggle stays visible regardless of selection; only the parameters
	# panel itself is forced hidden when hide_parameters is set (channel not selected).
	collapse_button.visible = true
	parameters.visible = not hide_parameters and not collapsed


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_collapse_button_toggled(button_pressed: bool) -> void:
	"""Handle collapse button toggle."""
	collapsed = not button_pressed
	
	# Update parameters panel visibility
	parameters.visible = not collapsed
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
	
	# Find the corresponding DevicePanel in the DeviceLane and grab focus
	var device_panel: DevicePanel = Sonara.editor.device_lane.find_device_panel(device_instance)
	if device_panel:
		device_panel.grab_focus()
		logger.info("Grabbed focus on DevicePanel for device: %s" % device_instance.device.name)
	else:
		push_warning("[CompactDevicePanel] Could not find DevicePanel for device: %s" % device_instance.device.name)


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Start a device drag (a DeviceDrag payload). Nothing moves until the drop.
func _get_drag_data(_at_position: Vector2) -> Variant:
	return DeviceDrag.start(self, device_instance)


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
