# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

const CompactParameterControlScene = preload("res://components/device/compact/CompactParameterControl.tscn")

@onready var header : PanelContainer = $VBoxContainer/Header

# light button toggles inactive/active and enabled/disabled
@onready var device_light: DeviceLightButton = $VBoxContainer/Header/HBox/DeviceLight
@onready var name_label : Label = $VBoxContainer/Header/HBox/Name
@onready var tab_buttons : HBoxContainer = $VBoxContainer/Header/HBox/TabButtons
@onready var params_button : Button = $VBoxContainer/Header/HBox/TabButtons/Parameters
@onready var file_button: Button = $VBoxContainer/Header/HBox/TabButtons/File
@onready var visual_button: Button = $VBoxContainer/Header/HBox/TabButtons/Visual

# Left side: scollcontainer of parameters and file selection
@onready var content_left : Control = $VBoxContainer/Content/HBoxContainer/ContentLeft

@onready var parameters_scroll : ScrollContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/Parameters
@onready var parameters_box : VBoxContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/Parameters/VBox
@onready var file_box: VBoxContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/File

# right side: visual UI
@onready var content_right : Control = $VBoxContainer/Content/HBoxContainer/ContentRight
@onready var visual_container: Control = $VBoxContainer/Content/HBoxContainer/ContentRight

# For Opening files for devices that support file loading
@onready var file_dialog: FileDialog = $FileDialog
@onready var file_status_label: Label = $VBoxContainer/Content/HBoxContainer/ContentLeft/File/StatusLabel
@onready var file_load_button: Button = $VBoxContainer/Content/HBoxContainer/ContentLeft/File/LoadButton

var device : DeviceInstance
var loaded_file_path: String = ""

## Visual scene state
var _current_visual_scene: DeviceView = null


func _ready() -> void:
	# Connect tab buttons
	params_button.toggled.connect(_on_params_tab_toggled)
	file_button.toggled.connect(_on_file_tab_toggled)
	visual_button.toggled.connect(_on_visual_tab_toggled)
	
	# Connect file loading
	file_load_button.pressed.connect(_on_load_file_pressed)
	file_dialog.file_selected.connect(_on_file_selected)
	
	# Initial tab state: show Parameters on the left; Visual visibility follows button state
	params_button.button_pressed = true
	file_button.button_pressed = false
	_show_parameters_tab()
	# Right pane visibility controlled by visual_button state
	visual_container.visible = visual_button.button_pressed
	
	# Enable drag and drop for SFZ files on the panel and key child nodes
	header.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	parameters_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	file_box.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


## This should not really happen.
func _unbind_from_device(_dev : DeviceInstance):
	_clear_parameter_controls()
	_clear_visual_scene()


func bind_to_device(dev : DeviceInstance):
	if device:
		_unbind_from_device(device)
	device = dev
	
	await ready
	device_light.bind_to_device_instance(dev)
	name_label.text = dev.get_display_name()
	_create_parameter_controls()
	
	# Configure Visual tab
	if dev.device.has_visual():
		visual_button.visible = true
		_load_visual_scene(dev.device.visual_scene_path)
		# Default: do not auto-show visual unless user toggles it
		visual_container.visible = visual_button.button_pressed
	else:
		visual_button.visible = false
		_clear_visual_scene()
	
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


func _on_visual_tab_toggled(pressed: bool) -> void:
	# Right pane visibility directly follows toggle; independent from left pane
	if pressed:
		_show_visual_tab()
	else:
		_hide_visual_tab()


func _show_parameters_tab() -> void:
	parameters_scroll.visible = true
	file_box.visible = false


func _show_file_tab() -> void:
	parameters_scroll.visible = false
	file_box.visible = true


func _show_visual_tab() -> void:
	visual_container.visible = true
	
	if _current_visual_scene:
		_current_visual_scene._on_view_shown()


func _hide_visual_tab() -> void:
	visual_container.visible = false
	if _current_visual_scene:
		_current_visual_scene._on_view_hidden()


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
	"""Return drag data (not used for this panel)."""
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
## VISUAL SCENE MANAGEMENT
## ============================================================================

## Load and instantiate a visual scene for this device
func _load_visual_scene(scene_path: String) -> void:
	_clear_visual_scene()
	
	var scene = load(scene_path)
	if not scene:
		push_error("[DevicePanel] Failed to load visual scene: " + scene_path)
		return
	
	_current_visual_scene = scene.instantiate()
	if not _current_visual_scene is DeviceView:
		push_error("[DevicePanel] Visual scene must extend DeviceView: " + scene_path)
		_current_visual_scene.queue_free()
		_current_visual_scene = null
		return
	
	visual_container.add_child(_current_visual_scene)
	_current_visual_scene.bind_to_device(device)
	print("[DevicePanel] Loaded visual scene: ", scene_path)


## Clear the current visual scene
func _clear_visual_scene() -> void:
	if _current_visual_scene:
		# Ensure unsubscribe is called
		if _current_visual_scene.has_method("_on_view_hidden"):
			_current_visual_scene._on_view_hidden()
		_current_visual_scene.queue_free()
		_current_visual_scene = null
