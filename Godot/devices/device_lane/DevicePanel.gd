# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

var logger : Log = Log.make("DevicePanel")

@onready var header : PanelContainer = $VBoxContainer/Header

# light button toggles inactive/active and enabled/disabled
@onready var device_light: DeviceLightButton = $VBoxContainer/Header/HBox/DeviceLight
@onready var name_label : Label = $VBoxContainer/Header/HBox/Name
@onready var tab_buttons : HBoxContainer = $VBoxContainer/Header/HBox/TabButtons
@onready var params_button : Button = $VBoxContainer/Header/HBox/TabButtons/Parameters
@onready var file_button: Button = $VBoxContainer/Header/HBox/TabButtons/File
@onready var large_button: Button = $VBoxContainer/Header/HBox/TabButtons/Large

## MIDI CC tab (created at runtime so it shares P-tab styles until we have icons)
var cc_button: Button
var ccs_scroll: ScrollContainer
var ccs_box: VBoxContainer

# Left side: scollcontainer of parameters and file selection
@onready var content_left : Control = $VBoxContainer/Content/HBoxContainer/ContentLeft

@onready var parameters_scroll : ScrollContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/Parameters
@onready var parameters_box : VBoxContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/Parameters/VBox
@onready var file_box: VBoxContainer = $VBoxContainer/Content/HBoxContainer/ContentLeft/File

# right side: custom / Immediate UI (not the parameter list, not container children)
@onready var content_right : Control = $VBoxContainer/Content/HBoxContainer/ContentRight
@onready var content_hbox: HBoxContainer = $VBoxContainer/Content/HBoxContainer

# For Opening files for devices that support file loading
@onready var file_dialog: FileDialog = $FileDialog
@onready var file_status_label: Label = $VBoxContainer/Content/HBoxContainer/ContentLeft/File/StatusLabel
@onready var file_load_button: Button = $VBoxContainer/Content/HBoxContainer/ContentLeft/File/LoadButton

# Large window popup
# set in _create_large_window()
# freed in _close_large()
var _large_popup: Window = null

var device : DeviceInstance
## Channel whose device_parameters_updated this panel listens to.
var _channel: Channel = null
var loaded_file_path: String = ""

## View state
var _panel_view: DeviceView = null
var _aux_view: DeviceView = null
var _large_view: DeviceView = null
var _large_open: bool = false

## Universal parameter lists (P tab and C tab)
var _param_list: ParameterList
var _cc_list: ParameterList

## Container children slide-out (to the right of params + custom UI)
var folder_button: Button
var folder: ContainerFolder
var _folder_focus: DeviceInstance = null

signal request_context_menu()

func _ready() -> void:
	# make parameters box wider
	parameters_box.custom_minimum_size.x = 100

	_create_cc_tab()
	_create_parameter_lists()
	_create_container_folder()

	# Connect tab buttons
	params_button.toggled.connect(_on_params_tab_toggled)
	cc_button.toggled.connect(_on_ccs_tab_toggled)
	file_button.toggled.connect(_on_file_tab_toggled)
	large_button.toggled.connect(_on_large_toggled)

	# Connect file loading
	file_load_button.pressed.connect(_on_load_file_pressed)
	file_dialog.file_selected.connect(_on_file_selected)

	# Initial tab state: show Parameters on the left
	params_button.button_pressed = true
	cc_button.button_pressed = false
	file_button.button_pressed = false
	_show_parameters_tab()
	# Right pane visibility will be managed when binding to a device

	# Enable drag and drop for SFZ files on the panel and key child nodes
	header.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	parameters_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	ccs_scroll.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	file_box.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


## Duplicate the P tab button and parameter scroller to make a C tab for MIDI CCs.
func _create_cc_tab() -> void:
	cc_button = params_button.duplicate()
	cc_button.name = "CCs"
	cc_button.text = "C"
	cc_button.button_pressed = false
	cc_button.visible = false
	tab_buttons.add_child(cc_button)
	tab_buttons.move_child(cc_button, file_button.get_index())

	ccs_scroll = parameters_scroll.duplicate()
	ccs_scroll.name = "CCs"
	ccs_scroll.visible = false
	content_left.add_child(ccs_scroll)
	content_left.move_child(ccs_scroll, file_box.get_index())
	ccs_box = ccs_scroll.get_node("VBox")
	ccs_box.custom_minimum_size.x = 100
	for child in ccs_box.get_children():
		child.queue_free()


## Host interchangeable ParameterList instances in the P and C scrollers.
func _create_parameter_lists() -> void:
	_param_list = ParameterList.new()
	_param_list.group = "param"
	parameters_box.add_child(_param_list)
	if ccs_box:
		_cc_list = ParameterList.new()
		_cc_list.group = "cc"
		ccs_box.add_child(_cc_list)


## Folder toggle on the header and a slide-out pane after the custom UI.
func _create_container_folder() -> void:
	folder_button = Button.new()
	folder_button.name = "Folder"
	folder_button.toggle_mode = true
	folder_button.text = "▸"
	folder_button.tooltip_text = "Show contained devices"
	folder_button.visible = false
	folder_button.custom_minimum_size = Vector2(28, 0)
	folder_button.toggled.connect(_on_folder_toggled)
	tab_buttons.add_child(folder_button)

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
## _on_view_hidden() and the Large popup outlives the panel.
## Not _exit_tree(): DockHost reparents docks, which would wipe the parameter
## controls with nothing to rebuild them.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


## Disconnect from the bound device and tear down its views. Idempotent.
func _unbind() -> void:
	if device == null:
		return
	if _large_open:
		_close_large()
	if device.plugin_gui_closed.is_connected(_on_plugin_gui_closed):
		device.plugin_gui_closed.disconnect(_on_plugin_gui_closed)
	if device.name_changed.is_connected(_on_device_name_changed):
		device.name_changed.disconnect(_on_device_name_changed)
	if _channel and _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.disconnect(_on_device_parameters_updated)
	_channel = null
	_clear_parameter_controls()
	_clear_panel_and_aux()
	_folder_focus = null
	if folder:
		folder.set_open(false, false)
		folder.bind_to_container(null)
	if folder_button:
		folder_button.visible = false
		folder_button.set_pressed_no_signal(false)
	device = null


## Refresh the header when the instance is renamed.
func _on_device_name_changed(new_name: String) -> void:
	if name_label:
		name_label.text = new_name
	if _large_popup:
		_large_popup.title = new_name


func bind_to_device(dev : DeviceInstance):
	_unbind()
	device = dev

	if not is_node_ready():
		await ready
	device_light.bind_to_device_instance(dev)
	name_label.text = dev.get_display_name()
	if not dev.name_changed.is_connected(_on_device_name_changed):
		dev.name_changed.connect(_on_device_name_changed)
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
	# PanelView = custom UI only (not ParameterList, not container children)
	if dev.device.has_panel_view():
		await _load_panel_view(dev)
		_show_right_pane_current()
	else:
		_clear_panel_and_aux()
		content_right.visible = false

	_configure_container_folder(dev)

	# Large toggle visibility (native GUI or LargeView scene)
	large_button.visible = dev.device.has_gui() or dev.device.has_large_view()
	large_button.button_pressed = false

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


## ============================================================================
## TAB SWITCHING
## ============================================================================

func _on_params_tab_toggled(pressed: bool) -> void:
	if pressed:
		cc_button.button_pressed = false
		file_button.button_pressed = false
		_show_parameters_tab()
	else:
		_ensure_left_tab_active()


## Left-pane C tab (MIDI CCs the SFZ did not label as parameters).
func _on_ccs_tab_toggled(pressed: bool) -> void:
	if pressed:
		params_button.button_pressed = false
		file_button.button_pressed = false
		_show_ccs_tab()
	else:
		_ensure_left_tab_active()


func _on_file_tab_toggled(pressed: bool) -> void:
	if pressed:
		params_button.button_pressed = false
		cc_button.button_pressed = false
		_show_file_tab()
	else:
		_ensure_left_tab_active()


func _on_large_toggled(pressed: bool) -> void:
	if pressed:
		_open_large()
	else:
		_close_large()


func _show_parameters_tab() -> void:
	parameters_scroll.visible = true
	if ccs_scroll:
		ccs_scroll.visible = false
	file_box.visible = false


## Show the C tab's MIDI CC list in the left pane.
func _show_ccs_tab() -> void:
	parameters_scroll.visible = false
	if ccs_scroll:
		ccs_scroll.visible = true
	file_box.visible = false


func _show_file_tab() -> void:
	parameters_scroll.visible = false
	if ccs_scroll:
		ccs_scroll.visible = false
	file_box.visible = true


## Keep one left-pane tab pressed (P, C, or F).
func _ensure_left_tab_active() -> void:
	if params_button.button_pressed:
		return
	if cc_button and cc_button.visible and cc_button.button_pressed:
		return
	if file_button.visible and file_button.button_pressed:
		return
	params_button.button_pressed = true


## Show the C tab only when this device has unlabeled MIDI CCs.
func _update_cc_tab_visibility() -> void:
	if not cc_button:
		return
	var show_cc = device != null and device.has_cc_parameters()
	cc_button.visible = show_cc
	if not show_cc and cc_button.button_pressed:
		params_button.button_pressed = true
	_update_left_pane_visibility()


## Hide the left pane when this device has no parameters, CCs, or file tab.
func _update_left_pane_visibility() -> void:
	if device == null or content_left == null:
		return
	var has_params := not device.get_parameters_in_group("param").is_empty()
	var has_cc := cc_button != null and cc_button.visible
	var has_file := file_button != null and file_button.visible
	params_button.visible = has_params
	content_left.visible = has_params or has_cc or has_file


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

func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Return drag data for reordering - returns DeviceInstance."""
	if device:
		return device
	return null


## Accept sample files, or devices dropped onto a container.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return DeviceDropUtil.can_drop_on_device(device, data)


## Add into this container (and reveal the new child), or load a dropped file.
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if device == null:
		return
	if DeviceDropUtil.drop_on_device(device, data):
		_open_folder_after_drop()
	elif not device.loaded_file_path.is_empty():
		loaded_file_path = device.loaded_file_path
		file_status_label.text = loaded_file_path.get_file()


## ============================================================================
## VIEW MANAGEMENT (Panel / Auxiliary / Large)
## ============================================================================

func _load_panel_view(dev: DeviceInstance) -> void:
	_clear_panel_view()
	_panel_view = DeviceViewFactory.create(dev, Device.ViewType.Panel)
	if _panel_view:
		# Bind first so view has device context before any show/subscription
		_panel_view.bind_to_device(dev)
		if not _panel_view.container_child_requested.is_connected(open_container_folder):
			_panel_view.container_child_requested.connect(open_container_folder)
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
	_aux_view = DeviceViewFactory.create(dev, Device.ViewType.Auxiliary)
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
		logger.info("showing panel view")

		if not _panel_view.is_node_ready():
			logger.info("waiting for panel view to be ready...")
			await _panel_view.ready

		logger.info("panel view is ready, calling _on_view_shown...")
		_panel_view.show()
		_panel_view._on_view_shown()
	
	if _aux_view and _aux_view.visible:
		logger.info("hiding aux view")

		if not _aux_view.is_node_ready():
			logger.info("waiting for aux view to be ready...")
			await _aux_view.ready

		logger.info("aux view is ready, calling _on_view_hidden...")
		_aux_view.hide()
		_aux_view._on_view_hidden()
	
	content_right.visible = _panel_view != null

func _show_aux_in_right() -> void:
	if _aux_view and not _aux_view.visible:
		if not _aux_view.is_node_ready():
			logger.info("waiting for aux view to be ready...")
			await _aux_view.ready

		logger.info("aux view is ready, calling _on_view_shown...")
		_aux_view.show()
		_aux_view._on_view_shown()
	
	if _panel_view and _panel_view.visible:
		if not _panel_view.is_node_ready():
			logger.info("waiting for panel view to be ready...")
			await _panel_view.ready

		logger.info("panel view is ready, calling _on_view_hidden...")
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
		popup.name = "DeviceWindowLarge_%s" % device.get_display_name()
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
		_large_view = DeviceViewFactory.create(device, Device.ViewType.Large)
		
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
	logger.info("Plugin GUI closed notification received")
	_large_open = false
	large_button.button_pressed = false
	_apply_large_state()


func _close_large() -> void:
	if device == null:
		return
	# has plugin gui?
	if device.device.has_gui():
		device.close_gui()
		_large_open = false
		_apply_large_state()
		return

	# has large view?
	if _large_view and _large_open:
		# The popup (and the view inside it) may already be gone when the
		# editor is freed on quit before this panel.
		if is_instance_valid(_large_view):
			_large_view._on_view_hidden()
			_large_view.queue_free()
		_large_view = null

		if is_instance_valid(_large_popup):
			_large_popup.hide()
			if _large_popup.get_parent():
				_large_popup.get_parent().remove_child(_large_popup)
			_large_popup.queue_free()
		_large_popup = null
	
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


## ============================================================================
## CONTAINER FOLDER
## ============================================================================

## Show the folder toggle for container devices and bind the slide-out list.
func _configure_container_folder(dev: DeviceInstance) -> void:
	_folder_focus = null
	if folder_button:
		folder_button.visible = dev.is_container()
		folder_button.set_pressed_no_signal(false)
		folder_button.text = "▸"
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
		folder_button.set_pressed_no_signal(true)
		folder_button.text = "◂"
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
		folder_button.text = "▸"


## After a drop into this container, reveal the new child.
func _open_folder_after_drop() -> void:
	if device == null or not device.is_container():
		return
	if device.device.container_focuses_one_child() and not device.children.is_empty():
		open_container_folder(device.children[device.children.size() - 1])
	else:
		open_container_folder(null)
