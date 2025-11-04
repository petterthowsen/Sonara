# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

const CompactParameterControlScene = preload("res://devices/compact/CompactParameterControl.tscn")

@onready var header : PanelContainer = $VBoxContainer/Header

# light button toggles inactive/active and enabled/disabled
@onready var device_light: DeviceLightButton = $VBoxContainer/Header/HBox/DeviceLight
@onready var name_label : Label = $VBoxContainer/Header/HBox/Name
@onready var tab_buttons : HBoxContainer = $VBoxContainer/Header/HBox/TabButtons
@onready var params_button : Button = $VBoxContainer/Header/HBox/TabButtons/Parameters
@onready var file_button: Button = $VBoxContainer/Header/HBox/TabButtons/File
@onready var large_button: Button = $VBoxContainer/Header/HBox/TabButtons/Large

# Left side: scollcontainer of parameters and file selection
@onready var content_left : Control = $VBoxContainer/Content/HBoxContainer/ContentLeft

@onready var parameters_scroll : ScrollContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/Parameters
@onready var parameters_box : VBoxContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/Parameters/VBox
@onready var file_box: VBoxContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/File

# right side: visual UI
@onready var content_right : Control = $VBoxContainer/Content/HBoxContainer/ContentRight

# For Opening files for devices that support file loading
@onready var file_dialog: FileDialog = $FileDialog
@onready var file_status_label: Label = $VBoxContainer/Content/HBoxContainer/ContentLeft/File/StatusLabel
@onready var file_load_button: Button = $VBoxContainer/Content/HBoxContainer/ContentLeft/File/LoadButton

# Large window popup
# set in _create_large_window()
# freed in _close_large()
var _large_popup: Window = null

var device : DeviceInstance
var loaded_file_path: String = ""

## View state
var _panel_view: DeviceView = null
var _aux_view: DeviceView = null
var _large_view: DeviceView = null
var _large_open: bool = false

signal request_context_menu()

func _ready() -> void:
	# make parameters box wider
	parameters_box.custom_minimum_size.x = 100
	
	# Connect tab buttons
	params_button.toggled.connect(_on_params_tab_toggled)
	file_button.toggled.connect(_on_file_tab_toggled)
	large_button.toggled.connect(_on_large_toggled)
	
	# Connect file loading
	file_load_button.pressed.connect(_on_load_file_pressed)
	file_dialog.file_selected.connect(_on_file_selected)
	
	# Initial tab state: show Parameters on the left
	params_button.button_pressed = true
	file_button.button_pressed = false
	_show_parameters_tab()
	# Right pane visibility will be managed when binding to a device
	
	# Enable drag and drop for SFZ files on the panel and key child nodes
	header.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	parameters_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	file_box.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			request_context_menu.emit()


## This should not really happen.
func _unbind_from_device(_dev : DeviceInstance):
	# Disconnect signal
	if _dev.plugin_gui_closed.is_connected(_on_plugin_gui_closed):
		_dev.plugin_gui_closed.disconnect(_on_plugin_gui_closed)
	_clear_parameter_controls()
	_clear_panel_and_aux()


func bind_to_device(dev : DeviceInstance):
	if device:
		_unbind_from_device(device)
	device = dev

	await ready
	device_light.bind_to_device_instance(dev)
	name_label.text = dev.get_display_name()
	_create_parameter_controls()
	# PanelView (right pane default)
	if dev.device.has_panel_view():
		_load_panel_view(dev)
		_show_right_pane_current()
	else:
		_clear_panel_and_aux()
		content_right.visible = false

	# Large toggle visibility (native GUI or LargeView scene)
	large_button.visible = dev.device.has_gui() or dev.device.has_large_view()
	large_button.button_pressed = false

	# Listen for GUI closed events from engine
	dev.plugin_gui_closed.connect(_on_plugin_gui_closed)

	# Configure file tab visibility and file dialog
	_configure_file_loading()
	
	# Listen for parameter list updates (when plugins load params asynchronously)
	# Individual CompactParameterControls already listen to parameter value changes
	var channel = Sonara.editor.project.get_channel_by_id(dev.channel_id)
	if channel:
		if not channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
			channel.device_parameters_updated.connect(_on_device_parameters_updated)


func _create_parameter_controls() -> void:
	if not device:
		return

	for param in device.device.get_parameters():
		_create_parameter_control_for_param(param)


## Clear all parameter controls
func _clear_parameter_controls() -> void:
	if parameters_box:
		for child in parameters_box.get_children():
			child.queue_free()


## Create and add a parameter control UI for a specific parameter
func _create_parameter_control_for_param(param: DeviceParameter) -> void:
	# Instantiate parameter control
	var control: CompactParameterControl
	if CompactParameterControlScene:
		control = CompactParameterControlScene.instantiate()
	else:
		# Fallback: create control dynamically
		control = CompactParameterControl.new()

	# Setup the control with device instance and parameter ID
	control.setup(device, param.id)
	parameters_box.add_child(control)


## Handle device parameters updated (for plugins that load parameters asynchronously)
func _on_device_parameters_updated(device_pos: int) -> void:
	if not device:
		return
	
	# Check if this update is for our device
	if device.position == device_pos:
		_clear_parameter_controls()
		_create_parameter_controls()


## ============================================================================
## TAB SWITCHING
## ============================================================================

func _on_params_tab_toggled(pressed: bool) -> void:
	if pressed:
		# Left pane: Parameters/File are mutually exclusive
		file_button.button_pressed = false
		_show_parameters_tab()
	else:
		# Ensure one left tab stays active
		if not file_button.button_pressed:
			params_button.button_pressed = true


func _on_file_tab_toggled(pressed: bool) -> void:
	if pressed:
		# Left pane: Parameters/File are mutually exclusive
		params_button.button_pressed = false
		_show_file_tab()
	else:
		# Ensure one left tab stays active
		if not params_button.button_pressed:
			file_button.button_pressed = true


func _on_large_toggled(pressed: bool) -> void:
	if pressed:
		_open_large()
	else:
		_close_large()


func _show_parameters_tab() -> void:
	parameters_scroll.visible = true
	file_box.visible = false


func _show_file_tab() -> void:
	parameters_scroll.visible = false
	file_box.visible = true


## Right-pane visibility is managed via Panel/Aux switching


## ============================================================================
## FILE LOADING
## ============================================================================

## Configure file loading UI based on device capabilities
func _configure_file_loading() -> void:
	if not device:
		return
	
	# Show/hide file tab based on device support
	if device.device.supports_file_loading:
		file_button.visible = true
		
		# Configure file dialog
		file_dialog.title = "Load %s" % device.device.file_type_description
		
		# Build filter string for file dialog
		var filters: PackedStringArray = []
		for ext in device.device.supported_file_extensions:
			filters.append("*%s ; %s Files" % [ext, ext.to_upper().trim_prefix(".")])
		file_dialog.filters = filters
		
		# Restore loaded file status from device instance (for project load)
		if device.loaded_file_path != "":
			loaded_file_path = device.loaded_file_path
			var filename = loaded_file_path.get_file()
			file_status_label.text = filename
		else:
			loaded_file_path = ""
			file_status_label.text = "No File Loaded"
	else:
		file_button.visible = false
		# Switch to parameters tab if file tab is hidden
		if file_button.button_pressed:
			params_button.button_pressed = true


## Handle load file button pressed
func _on_load_file_pressed() -> void:
	if not device:
		return
	
	# Open file dialog
	file_dialog.popup_centered()


## Handle file selected from dialog
func _on_file_selected(path: String) -> void:
	if not device:
		return
	
	print("[DevicePanel] Loading file: %s" % path)
	
	# Load file into device
	device.load_file(path)
	
	# Update UI
	loaded_file_path = path
	var filename = path.get_file()
	file_status_label.text = filename
	
	print("[DevicePanel] ✓ File loaded: %s" % filename)


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Return drag data for reordering - returns DeviceInstance."""
	if device:
		return device
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Check if we can drop an SFZ file on this device."""
	if not device or not data is Asset:
		return false
	
	# Only accept SFZ files
	if data.type != Asset.TYPE.SFZ:
		return false
	
	# Only allow drops on devices that support file loading (sfizz)
	return device.device.supports_file_loading


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping an SFZ file on this device."""
	if not data is Asset or not device:
		return
	
	var asset = data as Asset
	if asset.type != Asset.TYPE.SFZ:
		return
	
	print("[DevicePanel] SFZ dropped on device: %s" % asset.name)
	
	# Load the SFZ file into the device
	device.load_file(asset.path)
	
	# Update UI
	loaded_file_path = asset.path
	var filename = asset.path.get_file()
	file_status_label.text = filename
	
	print("[DevicePanel] ✓ SFZ loaded: %s" % filename)


## ============================================================================
## VIEW MANAGEMENT (Panel / Auxiliary / Large)
## ============================================================================

func _load_panel_view(dev: DeviceInstance) -> void:
	_clear_panel_view()
	_panel_view = dev.create_view(Device.ViewType.Panel)
	if _panel_view:
		# Bind first so view has device context before any show/subscription
		_panel_view.bind_to_device(dev)
		content_right.add_child(_panel_view)
		_panel_view.visible = true
		if not _panel_view.is_node_ready():
			await _panel_view.ready


func _clear_panel_view() -> void:
	if _panel_view:
		if _panel_view.has_method("_on_view_hidden"):
			_panel_view._on_view_hidden()
		_panel_view.queue_free()
		_panel_view = null


func _load_aux_view(dev: DeviceInstance) -> void:
	_clear_aux_view()
	_aux_view = dev.create_view(Device.ViewType.Auxiliary)
	if _aux_view:
		# Bind first so view has device context before any show/subscription
		_aux_view.bind_to_device(dev)
		content_right.add_child(_aux_view)
		_aux_view.visible = false
		if not _aux_view.is_node_ready():
			await _aux_view.ready


func _clear_aux_view() -> void:
	if _aux_view:
		if _aux_view.has_method("_on_view_hidden"):
			_aux_view._on_view_hidden()
		_aux_view.queue_free()
		_aux_view = null


func _clear_panel_and_aux() -> void:
	_clear_panel_view()
	_clear_aux_view()
	content_right.visible = false


func _show_panel_in_right() -> void:
	if _panel_view and _panel_view.visible:
		print("[DevicePanel] showing panel view")

		if not _panel_view.is_node_ready():
			print("[DevicePanel] waiting for panel view to be ready...")
			await _panel_view.ready

		print("[DevicePanel] panel view is ready, calling _on_view_shown...")
		_panel_view.show()
		_panel_view._on_view_shown()
	
	if _aux_view and _aux_view.visible:
		print("[DevicePanel] hiding aux view")

		if not _aux_view.is_node_ready():
			print("[DevicePanel] waiting for aux view to be ready...")
			await _aux_view.ready

		print("[DevicePanel] aux view is ready, calling _on_view_hidden...")
		_aux_view.hide()
		_aux_view._on_view_hidden()
	
	content_right.visible = _panel_view != null

func _show_aux_in_right() -> void:
	if _aux_view and not _aux_view.visible:
		if not _aux_view.is_node_ready():
			print("[DevicePanel] waiting for aux view to be ready...")
			await _aux_view.ready

		print("[DevicePanel] aux view is ready, calling _on_view_shown...")
		_aux_view.show()
		_aux_view._on_view_shown()
	
	if _panel_view and _panel_view.visible:
		if not _panel_view.is_node_ready():
			print("[DevicePanel] waiting for panel view to be ready...")
			await _panel_view.ready

		print("[DevicePanel] panel view is ready, calling _on_view_hidden...")
		_panel_view.hide()
		_panel_view._on_view_hidden()
	
	content_right.visible = _aux_view != null


func _hide_aux_show_panel() -> void:
	_show_panel_in_right()


func _show_right_pane_current() -> void:
	if _large_open and _aux_view:
		_show_aux_in_right()
	else:
		_show_panel_in_right()


## Get or create large window popup for Large View
func _get_large_window() -> Window:
	# create large window if not already created
	if not _large_popup:
		var popup := Window.new()
		popup.name = "DeviceWindowLarge_%s" % device.device.name
		popup.unresizable = false
		popup.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
		popup.handle_input_locally = false # we want to still accept input events the window doesn't handle.
		popup.size = Vector2i(300, 200) # initial size
		popup.title = device.device.name
		popup.always_on_top = true # always on top of other windows
		popup.wrap_controls = true # sized by content
		popup.force_native = false # not native
		popup.minimize_disabled = true # cannot minimize
		popup.maximize_disabled = true # cannot maximize
		popup.close_requested.connect(_on_large_window_request_close)
		_large_popup = popup

	# return large window
	return _large_popup


## Large window management (native GUI or Large view scene)
func _open_large() -> void:
	if not device:
		return
	
	if device.device.has_gui():
		device.open_gui()
		_large_open = true
		_apply_large_state()
		return
	
	if device.device.has_large_view():
		# create large view
		_large_view = device.create_view(Device.ViewType.Large)
		
		# add large view to window
		var popup = _get_large_window()
		popup.add_child(_large_view)
		
		# bind large view to device
		_large_view.bind_to_device(device)

		# add window to editor
		Sonara.editor.add_child(popup)

		# wait for large view to be ready
		if not _large_view.is_node_ready():
			await _large_view.ready

		# show window
		popup.popup_centered(Vector2(300, 200))
		# notify large view it is now visible so it can subscribe
		_large_view._on_view_shown()

		# set large open flag
		_large_open = true
		_apply_large_state()


func _on_large_window_request_close() -> void:
	_close_large()


## Handle plugin GUI closed notification from engine
func _on_plugin_gui_closed() -> void:
	print("[DevicePanel] Plugin GUI closed notification received")
	_large_open = false
	large_button.button_pressed = false
	_apply_large_state()


func _close_large() -> void:
	# has plugin gui?
	if device.device.has_gui():
		device.close_gui()
		_large_open = false
		_apply_large_state()
		return

	# has large view?
	if _large_view and _large_open:
		_large_popup.hide()

		Sonara.editor.remove_child(_large_popup)
		_large_popup.queue_free()
		_large_popup = null

		_large_view._on_view_hidden()
		_large_view.queue_free()
		_large_view = null
	
	_large_open = false
	_apply_large_state()


func _apply_large_state() -> void:
	if _large_open and device and device.device.has_auxiliary_view():
		if _aux_view == null:
			_load_aux_view(device)
		_show_aux_in_right()
	else:
		_hide_aux_show_panel()

	large_button.button_pressed = _large_open
