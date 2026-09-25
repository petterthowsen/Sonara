# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

var logger : Log = Log.make("DevicePanel")

const ICON_FOLDOUT_CLOSED: Texture2D = preload("res://assets/icons/chevron-right.svg")
const ICON_FOLDOUT_OPEN: Texture2D = preload("res://assets/icons/chevron-left.svg")

## Top header: light, name, children foldout. Drops onto it go onto the device.
@onready var header : PanelContainer = $VBox/TopHeader

# light button toggles inactive/active and enabled/disabled
@onready var device_light: DeviceLightButton = $VBox/TopHeader/HBox/DeviceLight
@onready var name_label : SmartLineEdit = $VBox/TopHeader/HBox/Name
@onready var folder_button: Button = $VBox/TopHeader/HBox/FoldoutToggle

## Shown only while the bound device is crashed/failed; reloads the plugin host.
@onready var reload_button: Button = $VBox/TopHeader/HBox/Reload

# Left header: View and Window toggles, then the Parameters/CCs/File tabs (one ButtonGroup)
@onready var tab_buttons : BoxContainer = $VBox/HBox/LeftHeader/TabButtons
@onready var view_button: Button = $VBox/HBox/LeftHeader/TabButtons/View
@onready var window_button: Button = $VBox/HBox/LeftHeader/TabButtons/Window
## Switches between a device's own Panel view and the generated Simple View (REQ-011 decision).
## Visible only for a device that has both.
@onready var simple_button: Button = $VBox/HBox/LeftHeader/TabButtons/Simple
@onready var params_button : Button = $VBox/HBox/LeftHeader/TabButtons/Parameters
@onready var file_button: Button = $VBox/HBox/LeftHeader/TabButtons/File

## MIDI CC tab (duplicated from Parameters at runtime until it gets its own icon)
var cc_button: Button
var ccs_pane: Control
var ccs_scroll: ScrollContainer
var ccs_box: VBoxContainer

# Content row: [Parameters | CCs | File] [View] [children folder]
@onready var content_hbox: HBoxContainer = $VBox/HBox/Content/HBox
@onready var parameters_pane: Control = $VBox/HBox/Content/HBox/Parameters
@onready var parameters_scroll : ScrollContainer = $VBox/HBox/Content/HBox/Parameters/Scroll
@onready var parameters_box : VBoxContainer = $VBox/HBox/Content/HBox/Parameters/Scroll/VBox
@onready var file_box: Control = $VBox/HBox/Content/HBox/File

# Custom UI (Panel view, or Companion view while the device window is open)
@onready var view_pane : Control = $VBox/HBox/Content/HBox/View

# For Opening files for devices that support file loading
@onready var file_dialog: FileDialog = $FileDialog
@onready var file_status_label: Label = $VBox/HBox/Content/HBox/File/VBox/StatusLabel
@onready var file_load_button: Button = $VBox/HBox/Content/HBox/File/VBox/LoadButton

# Device window popup (Window view)
# set in _get_window()
# freed in _close_window()
var _window_popup: Window = null

var device : DeviceInstance
## Channel whose device_parameters_updated this panel listens to.
var _channel: Channel = null
var loaded_file_path: String = ""

## View state
var _panel_view: DeviceView = null
var _companion_view: DeviceView = null
var _window_view: DeviceView = null
var _window_open: bool = false

## Universal parameter lists (Parameters and CCs tabs)
var _param_list: ParameterList
var _cc_list: ParameterList

## Container children slide-out (to the right of params + custom UI)
var folder: ContainerFolder
var _folder_focus: DeviceInstance = null

signal request_context_menu()

func _ready() -> void:
	_create_cc_tab()
	_create_parameter_lists()
	_create_container_folder()

	# Parameters/CCs/File share a ButtonGroup; clicking the active tab collapses its pane.
	params_button.button_group.allow_unpress = true
	params_button.toggled.connect(_on_tab_toggled.unbind(1))
	cc_button.toggled.connect(_on_tab_toggled.unbind(1))
	file_button.toggled.connect(_on_tab_toggled.unbind(1))
	view_button.toggled.connect(_on_view_toggled)
	window_button.toggled.connect(_on_window_toggled)
	simple_button.toggled.connect(_on_simple_toggled)
	folder_button.toggled.connect(_on_folder_toggled)
	reload_button.pressed.connect(_on_reload_pressed)

	# Connect file loading
	file_load_button.pressed.connect(_on_load_file_pressed)
	file_dialog.file_selected.connect(_on_file_selected)

	# Inline rename of the device instance via the header's SmartLineEdit
	name_label.value_changed.connect(_on_name_edited)

	# Initial state: View and Parameters open; panes resolve when binding to a device
	view_button.set_pressed_no_signal(true)
	params_button.set_pressed_no_signal(true)
	folder_button.visible = false
	_update_tab_panes()

	# Drag the device from the header and content areas; drops resolve through DeviceDropTarget.
	header.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	parameters_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	ccs_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	file_box.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


## Duplicate the Parameters tab button and pane to make a CCs tab for MIDI CCs.
func _create_cc_tab() -> void:
	cc_button = params_button.duplicate()  # keeps the ButtonGroup
	cc_button.name = "CCs"
	cc_button.icon = null
	cc_button.text = "C"
	cc_button.tooltip_text = "MIDI CCs"
	cc_button.button_pressed = false
	cc_button.visible = false
	tab_buttons.add_child(cc_button)
	tab_buttons.move_child(cc_button, file_button.get_index())

	ccs_pane = parameters_pane.duplicate()
	ccs_pane.name = "CCs"
	ccs_pane.visible = false
	content_hbox.add_child(ccs_pane)
	content_hbox.move_child(ccs_pane, file_box.get_index())
	ccs_scroll = ccs_pane.get_node("Scroll")
	ccs_box = ccs_scroll.get_node("VBox")
	for child in ccs_box.get_children():
		child.queue_free()


## Host interchangeable ParameterList instances in the Parameters and CCs panes.
func _create_parameter_lists() -> void:
	_param_list = ParameterList.new()
	_param_list.group = "param"
	parameters_box.add_child(_param_list)
	if ccs_box:
		_cc_list = ParameterList.new()
		_cc_list.group = "cc"
		ccs_box.add_child(_cc_list)


## Slide-out children pane after the custom UI (toggled by the header's FoldoutToggle).
func _create_container_folder() -> void:
	folder_button.tooltip_text = "Show contained devices"
	folder = ContainerFolder.new()
	folder.name = "ContentFolder"
	content_hbox.add_child(folder)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			request_context_menu.emit()


## Release engine subscriptions and popups when the panel is freed (e.g.
## DeviceLane.clear()/_on_channel_device_removed(), or a parent being freed).
## Without this, custom views (like the spectrum analyzer) never get
## _on_view_hidden() and the window popup outlives the panel.
## Not _exit_tree(): DockHost reparents docks, which would wipe the parameter
## controls with nothing to rebuild them.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


## Disconnect from the bound device and tear down its views. Idempotent.
func _unbind() -> void:
	if device == null:
		return
	if _window_open:
		_close_window()
	if device.plugin_gui_closed.is_connected(_on_plugin_gui_closed):
		device.plugin_gui_closed.disconnect(_on_plugin_gui_closed)
	if device.name_changed.is_connected(_on_device_name_changed):
		device.name_changed.disconnect(_on_device_name_changed)
	if device.loading_state_changed.is_connected(_on_device_loading_state_changed):
		device.loading_state_changed.disconnect(_on_device_loading_state_changed)
	if reload_button:
		reload_button.visible = false
	if _channel and _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.disconnect(_on_device_parameters_updated)
	_channel = null
	_clear_parameter_controls()
	_clear_panel_and_companion()
	_folder_focus = null
	if folder:
		folder.set_open(false, false)
		folder.bind_to_container(null)
	if folder_button:
		folder_button.visible = false
		_set_foldout_pressed(false)
	device = null


## Show the Reload button only while the bound device needs a respawn.
func _update_reload_button_visibility() -> void:
	if reload_button == null:
		return
	var state: String = device.loading_state if device else ""
	reload_button.visible = state.begins_with("crashed:") or state.begins_with("failed:")


func _on_device_loading_state_changed(_state: String) -> void:
	_update_reload_button_visibility()


func _on_reload_pressed() -> void:
	if device:
		device.reload()


## Refresh the header when the instance is renamed.
func _on_device_name_changed(new_name: String) -> void:
	if name_label:
		name_label.set_value(new_name)
	if _window_popup:
		_window_popup.title = new_name


## Commit an inline rename from the header's SmartLineEdit.
func _on_name_edited(value) -> void:
	if device == null:
		return
	name_label.set_value(DeviceActions.rename(device, str(value)))


func bind_to_device(dev : DeviceInstance):
	_unbind()
	device = dev

	if not is_node_ready():
		await ready
	device_light.bind_to_device_instance(dev)
	name_label.set_value(dev.get_display_name())
	if not dev.name_changed.is_connected(_on_device_name_changed):
		dev.name_changed.connect(_on_device_name_changed)
	if not dev.loading_state_changed.is_connected(_on_device_loading_state_changed):
		dev.loading_state_changed.connect(_on_device_loading_state_changed)
	_update_reload_button_visibility()
	# Listen for parameter list updates (when plugins load params asynchronously)
	# Individual CompactParameterControls already listen to parameter value changes.
	# Connected before any `await` below: the engine can advertise params
	# (param/count + param/info) while a panel view scene is still loading,
	# and a listener connected only after that await would miss the signal,
	# leaving the parameters pane stuck hidden.
	_channel = dev.get_channel()
	if _channel:
		if not _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
			_channel.device_parameters_updated.connect(_on_device_parameters_updated)

	_create_parameter_controls()
	_update_cc_tab_visibility()
	# PanelView = custom UI only (not ParameterList, not container children). A device with no
	# Panel view of its own still gets one when it qualifies for the generated Simple View.
	if dev.device.has_panel_view() or dev.device.uses_simple_view(dev.get_parameters()):
		await _load_panel_view(dev)
		_show_right_pane_current()
	else:
		_clear_panel_and_companion()
	_update_view_toggle_visibility()
	_update_view_pane_visibility()

	_configure_container_folder(dev)

	# Window toggle visibility (native GUI or Window view scene)
	window_button.visible = dev.device.has_gui() or dev.device.has_window_view()
	window_button.set_pressed_no_signal(false)

	# Listen for GUI closed events from engine
	if not dev.plugin_gui_closed.is_connected(_on_plugin_gui_closed):
		dev.plugin_gui_closed.connect(_on_plugin_gui_closed)

	# Configure file tab visibility and file dialog
	_configure_file_loading()
	_update_left_pane_visibility()


## Bind the universal parameter lists (same API for builtins and plugins).
func _create_parameter_controls() -> void:
	if not device:
		return
	if _param_list:
		_param_list.bind_to_device(device, "param")
	if _cc_list:
		_cc_list.bind_to_device(device, "cc")


## Clear all parameter controls
func _clear_parameter_controls() -> void:
	if _param_list:
		_param_list.clear()
	if _cc_list:
		_cc_list.clear()


## Handle device parameters updated (for plugins that load parameters asynchronously)
func _on_device_parameters_updated(device_instance: DeviceInstance) -> void:
	if not device:
		return
	if device == device_instance:
		if _param_list:
			_param_list.refresh()
		if _cc_list:
			_cc_list.refresh()
		_update_cc_tab_visibility()
		_refresh_panel_view_for_params()


## Re-evaluate the Panel view once a plugin/SFZ device's parameter list arrives or changes: a
## device that qualifies for the Simple View only once it has visible parameters (`uses_simple_view`)
## may not have had a Panel view loaded yet. A view that's already showing reconciles and rebuilds
## itself from its own `parameters_updated` subscription (`SimpleView._on_parameters_updated`), so
## this only needs to create one where there wasn't one before.
func _refresh_panel_view_for_params() -> void:
	if device == null:
		return
	_update_view_toggle_visibility()
	if _panel_view == null and (device.device.has_panel_view() or device.device.uses_simple_view(device.get_parameters())):
		await _load_panel_view(device)
		_show_right_pane_current()
	_update_view_pane_visibility()


## Show/hide the View toggle (any custom or Simple view exists) and the Simple toggle (only when
## the device has both its own Panel view and visible parameters to generate a Simple View from).
func _update_view_toggle_visibility() -> void:
	if device == null:
		return
	var can_simple := device.device.uses_simple_view(device.get_parameters())
	view_button.visible = device.device.has_panel_view() or device.device.has_companion_view() or can_simple
	simple_button.visible = device.device.has_panel_view() and can_simple
	simple_button.set_pressed_no_signal(bool(Sonara.get_config("devices/simple_view/%s" % device.device.device_id, false)))


## "Simple" toggle: switch the Panel pane between the device's own view and the generated Simple
## View, and remember the choice per device id (REQ-011 decision).
func _on_simple_toggled(pressed: bool) -> void:
	if device == null:
		return
	Sonara.set_config("devices/simple_view/%s" % device.device.device_id, pressed)
	await _load_panel_view(device)
	_show_right_pane_current()


## ============================================================================
## TAB SWITCHING
## ============================================================================

## Any of Parameters/CCs/File changed (the ButtonGroup keeps at most one pressed).
func _on_tab_toggled() -> void:
	_update_tab_panes()


## Show the pane of the pressed tab; a hidden tab never shows its pane.
func _update_tab_panes() -> void:
	parameters_pane.visible = params_button.visible and params_button.button_pressed
	if ccs_pane:
		ccs_pane.visible = cc_button.visible and cc_button.button_pressed
	file_box.visible = file_button.visible and file_button.button_pressed


## View toggle: show or hide the custom UI pane.
func _on_view_toggled(_pressed: bool) -> void:
	_update_view_pane_visibility()


## Window toggle: native plugin GUI or the Window view popup.
func _on_window_toggled(pressed: bool) -> void:
	if pressed:
		_open_window()
	else:
		_close_window()


## The View pane shows when toggled on and a Panel or Companion view is loaded.
func _update_view_pane_visibility() -> void:
	var has_view := _panel_view != null or _companion_view != null
	view_pane.visible = has_view and view_button.button_pressed


## Show the CCs tab only when this device has unlabeled MIDI CCs.
func _update_cc_tab_visibility() -> void:
	if not cc_button:
		return
	var show_cc = device != null and device.has_cc_parameters()
	cc_button.visible = show_cc
	if not show_cc and cc_button.button_pressed:
		params_button.button_pressed = true
	_update_left_pane_visibility()


## Hide tab buttons the device has nothing for, then refresh the panes.
func _update_left_pane_visibility() -> void:
	if device == null:
		return
	params_button.visible = not device.get_parameters_in_group("param").is_empty()
	# A pressed tab that just disappeared hands over to the first available one.
	var pressed := params_button.button_group.get_pressed_button()
	if pressed and not pressed.visible:
		pressed.set_pressed_no_signal(false)
		for tab in [params_button, cc_button, file_button]:
			if tab.visible:
				tab.set_pressed_no_signal(true)
				break
	_update_tab_panes()


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
	
	logger.info("Loading file: %s" % path)
	
	# Load file into device
	device.load_file(path)
	
	# Update UI
	loaded_file_path = path
	var filename = path.get_file()
	file_status_label.text = filename
	
	logger.info("✓ File loaded: %s" % filename)


# ============================================================================
# DRAG AND DROP
# ============================================================================

## Start a device drag (a DeviceDrag payload). Nothing moves until the drop.
func _get_drag_data(_at_position: Vector2) -> Variant:
	return DeviceDrag.start(self, device)


## Resolve from the pointer in the enclosing device lane: insert beside this panel, or onto its
## header (child into a container, file load). Outside a lane, only drops onto the device.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if DeviceDropTarget.find_root(self):
		return DeviceDropTarget.resolve_for(self, data).is_valid()
	return DeviceDropUtil.can_drop_on_device(device, data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if device == null:
		return
	if DeviceDropTarget.find_root(self):
		DeviceDropTarget.resolve_for(self, data).commit(data)
		return
	after_drop_onto(DeviceDropUtil.drop_on_device(device, data))


## After a drop onto this panel: reveal a child added to a container, or show a loaded file.
func after_drop_onto(added_child: bool) -> void:
	if device == null:
		return
	if added_child:
		_open_folder_after_drop()
	elif not device.loaded_file_path.is_empty():
		loaded_file_path = device.loaded_file_path
		file_status_label.text = loaded_file_path.get_file()


## ============================================================================
## VIEW MANAGEMENT (Panel / Companion / Window)
## ============================================================================

func _load_panel_view(dev: DeviceInstance) -> void:
	_clear_panel_view()
	_panel_view = DeviceViewFactory.create(dev, Device.ViewType.Panel)
	if _panel_view:
		# Bind first so view has device context before any show/subscription
		_panel_view.bind_to_device(dev)
		if not _panel_view.container_child_requested.is_connected(open_container_folder):
			_panel_view.container_child_requested.connect(open_container_folder)
		view_pane.add_child(_panel_view)
		_panel_view.visible = true
		if not _panel_view.is_node_ready():
			await _panel_view.ready


func _clear_panel_view() -> void:
	if _panel_view:
		if _panel_view.has_method("_on_view_hidden"):
			_panel_view._on_view_hidden()
		_panel_view.queue_free()
		_panel_view = null


func _load_companion_view(dev: DeviceInstance) -> void:
	_clear_companion_view()
	_companion_view = DeviceViewFactory.create(dev, Device.ViewType.Companion)
	if _companion_view:
		# Bind first so view has device context before any show/subscription
		_companion_view.bind_to_device(dev)
		view_pane.add_child(_companion_view)
		_companion_view.visible = false
		if not _companion_view.is_node_ready():
			await _companion_view.ready


func _clear_companion_view() -> void:
	if _companion_view:
		if _companion_view.has_method("_on_view_hidden"):
			_companion_view._on_view_hidden()
		_companion_view.queue_free()
		_companion_view = null


func _clear_panel_and_companion() -> void:
	_clear_panel_view()
	_clear_companion_view()
	_update_view_pane_visibility()


func _show_panel_view() -> void:
	if _panel_view and _panel_view.visible:
		logger.info("showing panel view")

		if not _panel_view.is_node_ready():
			logger.info("waiting for panel view to be ready...")
			await _panel_view.ready

		logger.info("panel view is ready, calling _on_view_shown...")
		_panel_view.show()
		_panel_view._on_view_shown()
	
	if _companion_view and _companion_view.visible:
		logger.info("hiding companion view")

		if not _companion_view.is_node_ready():
			logger.info("waiting for companion view to be ready...")
			await _companion_view.ready

		logger.info("companion view is ready, calling _on_view_hidden...")
		_companion_view.hide()
		_companion_view._on_view_hidden()
	
	_update_view_pane_visibility()

func _show_companion_view() -> void:
	if _companion_view and not _companion_view.visible:
		if not _companion_view.is_node_ready():
			logger.info("waiting for companion view to be ready...")
			await _companion_view.ready

		logger.info("companion view is ready, calling _on_view_shown...")
		_companion_view.show()
		_companion_view._on_view_shown()
	
	if _panel_view and _panel_view.visible:
		if not _panel_view.is_node_ready():
			logger.info("waiting for panel view to be ready...")
			await _panel_view.ready

		logger.info("panel view is ready, calling _on_view_hidden...")
		_panel_view.hide()
		_panel_view._on_view_hidden()
	
	_update_view_pane_visibility()


func _hide_companion_show_panel() -> void:
	_show_panel_view()


func _show_right_pane_current() -> void:
	if _window_open and _companion_view:
		_show_companion_view()
	else:
		_show_panel_view()


## Get or create the popup that hosts the Window view
func _get_window() -> Window:
	# create window if not already created
	if not _window_popup:
		var popup := Window.new()
		popup.name = "DeviceWindow_%s" % device.get_display_name()
		popup.unresizable = false
		popup.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
		popup.handle_input_locally = false # we want to still accept input events the window doesn't handle.
		popup.size = Vector2i(300, 200) # initial size
		popup.title = device.get_display_name()
		popup.always_on_top = true # always on top of other windows
		popup.wrap_controls = true # sized by content
		popup.force_native = false # not native
		popup.minimize_disabled = true # cannot minimize
		popup.maximize_disabled = true # cannot maximize
		popup.close_requested.connect(_on_window_request_close)
		_window_popup = popup

	# return window
	return _window_popup


## Device window: native plugin GUI or the Window view scene
func _open_window() -> void:
	if not device:
		return
	
	if device.device.has_gui():
		device.open_gui()
		_window_open = true
		_apply_window_state()
		return
	
	if device.device.has_window_view():
		# create window view
		_window_view = DeviceViewFactory.create(device, Device.ViewType.Window)
		
		# add window view to popup
		var popup = _get_window()
		popup.add_child(_window_view)
		
		# bind window view to device
		_window_view.bind_to_device(device)

		# add window to editor
		Sonara.editor.add_child(popup)

		# wait for window view to be ready
		if not _window_view.is_node_ready():
			await _window_view.ready

		# show window
		popup.popup_centered(Vector2(300, 200))
		# notify window view it is now visible so it can subscribe
		_window_view._on_view_shown()

		# set window open flag
		_window_open = true
		_apply_window_state()


func _on_window_request_close() -> void:
	_close_window()


## Handle plugin GUI closed notification from engine
func _on_plugin_gui_closed() -> void:
	logger.info("Plugin GUI closed notification received")
	_window_open = false
	window_button.set_pressed_no_signal(false)
	_apply_window_state()


func _close_window() -> void:
	if device == null:
		return
	# has plugin gui?
	if device.device.has_gui():
		device.close_gui()
		_window_open = false
		_apply_window_state()
		return

	# has window view?
	if _window_view and _window_open:
		# The popup (and the view inside it) may already be gone when the
		# editor is freed on quit before this panel.
		if is_instance_valid(_window_view):
			_window_view._on_view_hidden()
			_window_view.queue_free()
		_window_view = null

		if is_instance_valid(_window_popup):
			_window_popup.hide()
			if _window_popup.get_parent():
				_window_popup.get_parent().remove_child(_window_popup)
			_window_popup.queue_free()
		_window_popup = null
	
	_window_open = false
	_apply_window_state()


func _apply_window_state() -> void:
	if _window_open and device and device.device.has_companion_view():
		if _companion_view == null:
			_load_companion_view(device)
		_show_companion_view()
	else:
		_hide_companion_show_panel()

	window_button.set_pressed_no_signal(_window_open)


## ============================================================================
## CONTAINER FOLDER
## ============================================================================

## Show the folder toggle for container devices and bind the slide-out list.
func _configure_container_folder(dev: DeviceInstance) -> void:
	_folder_focus = null
	if folder_button:
		folder_button.visible = dev.is_container()
		_set_foldout_pressed(false)
	if folder:
		if dev.is_container():
			await folder.bind_to_container(dev)
			await folder.set_focus_child(null)
			folder.set_open(false, false)
		else:
			await folder.bind_to_container(null)
			folder.set_open(false, false)


## Open the children pane, optionally focused on one Layer/Drum slot.
func open_container_folder(child: DeviceInstance = null) -> void:
	if device == null or not device.is_container() or folder == null:
		return
	_folder_focus = child
	var single := device.device.container_focuses_one_child()
	if single and _folder_focus == null and not device.children.is_empty():
		_folder_focus = device.children[0]
	await folder.set_focus_child(_folder_focus if single else null)
	folder.set_open(true)
	if folder_button:
		_set_foldout_pressed(true)
	if _panel_view and _panel_view.has_method("set_focused_child"):
		_panel_view.set_focused_child(_folder_focus)


## Toggle the children pane from the folder header button.
func _on_folder_toggled(pressed: bool) -> void:
	if folder == null or device == null or not device.is_container():
		return
	if pressed:
		open_container_folder(_folder_focus)
	else:
		folder.set_open(false)
		_set_foldout_pressed(false)


## Sync the FoldoutToggle's pressed state and chevron without re-triggering it.
func _set_foldout_pressed(pressed: bool) -> void:
	folder_button.set_pressed_no_signal(pressed)
	folder_button.icon = ICON_FOLDOUT_OPEN if pressed else ICON_FOLDOUT_CLOSED


## After a drop into this container, reveal the new child.
func _open_folder_after_drop() -> void:
	if device == null or not device.is_container():
		return
	if device.device.container_focuses_one_child() and not device.children.is_empty():
		open_container_folder(device.children[device.children.size() - 1])
	else:
		open_container_folder(null)
