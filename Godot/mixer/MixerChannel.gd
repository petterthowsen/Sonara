@tool
class_name MixerChannel extends PanelContainer

# UI References
@onready var header: Panel = $HBox/VBox/Header
@onready var title: SmartLineEdit = $HBox/VBox/Header/SmartLineEdit

@onready var big_meter: Meter = $HBox/VBox/BigMeter

@onready var controls: PanelContainer = $HBox/VBox/Controls
@onready var arm_toggle: Button = $HBox/VBox/Controls/FlowContainer/ArmToggle
@onready var solo_toggle: Button = $HBox/VBox/Controls/FlowContainer/SoloMute/SoloToggle
@onready var mute_toggle: Button = $HBox/VBox/Controls/FlowContainer/SoloMute/MuteToggle

@onready var io: PanelContainer = $HBox/VBox/IO
@onready var output_menu_buttton: MenuButton = $HBox/VBox/IO/OutputMenuButtton

@onready var panning: PanelContainer = $HBox/VBox/Panning
@onready var panning_combined_slider: HorSlider = $HBox/VBox/Panning/HSlider
@onready var panning_dual_slider: HDualSlider = $HBox/VBox/Panning/DualPanSlider
@onready var pan_mode_popup: PopupMenu = $PanModePopup

# main volume, fader and/or volume
@onready var volume: PanelContainer = $HBox/VBox/Volume
@onready var bottom_volume_slider: VolumeSlider = $HBox/VBox/Volume/HBox/Fader
@onready var bottom_small_meter: Meter = $HBox/VBox/Volume/HBox/CompactMeter

# extra details on the right side can be shown/hidden
@onready var details: VBoxContainer = $HBox/Details

# compact devices parameter control
@onready var device_list: ChannelDeviceList = $HBox/VBox/DeviceList

# sends panel
@onready var sends_panel: SendsPanel = $HBox/VBox/Sends/SendsPanel

# Details pane visibility
var details_visible := false
var details_pane_width := 0

# Resizing
var is_resizing := false
var resize_mouse_start := Vector2.ZERO
var resize_width_start := 0

# Property to control whether this channel can be resized
@export var resizable: bool = true:
	set(value):
		resizable = value
		# Update mouse cursor when resizable state changes
		if not is_resizing:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

@export var border_color := Color("#333")
@export var border_color_selected := Color("#999")

# Moving (re-ordering)
var is_moving := false
var move_index_start := 0
var move_mouse_start := Vector2.ZERO
var move_awaiting := false

var is_selected := false:
	set(selected):
		if is_selected != selected:
			is_selected = selected
			var bc = border_color_selected if is_selected else border_color
			var stylebox : StyleBoxFlat = get_theme_stylebox("panel")
			stylebox.border_color = bc


signal request_move(new_index : int)
signal request_show_context_menu

# Data binding
var channel: Channel = null
var project: Project = null  # Reference to project for accessing other channels

# Pinning - when true, this channel stays on the right side of the mixer
@export var pinned: bool = false:
	set(p):
		pinned = p
		_update_container_sizing()

enum Mode {COMPACT, LARGE}

const compact_min_width = 50
const large_min_width = 100

@export var mode = Mode.COMPACT:
	set = set_mode

func _ready():
	_update_container_sizing()
	_init_details_pane()

	# Connect UI signals
	if solo_toggle:
		solo_toggle.toggled.connect(_on_solo_toggled)
	if mute_toggle:
		mute_toggle.toggled.connect(_on_mute_toggled)
	if bottom_volume_slider:
		bottom_volume_slider.value_changed.connect(_on_volume_changed)
	
	big_meter.volume_changed.connect(_on_volume_changed)
	bottom_small_meter.volume_changed.connect(_on_volume_changed)
	
	panning_combined_slider.value_changed.connect(_on_pan_changed)
	panning_dual_slider.values_changed.connect(_on_pan_changed)

	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	title.value_changed.connect(_on_title_value_changed)

	header.gui_input.connect(_on_header_gui_input)

	# panning mode control
	panning.gui_input.connect(_on_panning_gui_input)
	pan_mode_popup.id_pressed.connect(_on_pan_mode_selected)

	# output routing menu
	if output_menu_buttton:
		output_menu_buttton.get_popup().id_pressed.connect(_on_output_menu_selected)

	# Enable drag and drop of devices onto ourself plus headerr and device list.
	for node in [self, device_list, big_meter, header]:
		node.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


func bind_to_channel(ch: Channel, proj: Project = null) -> void:
	"""Bind this UI element to a Channel data object."""
	# Disconnect from old channel if any
	if channel:
		channel.name_changed.disconnect(_on_channel_name_changed)
		channel.volume_changed.disconnect(_on_channel_volume_changed)
		channel.mute_changed.disconnect(_on_channel_mute_changed)
		channel.solo_changed.disconnect(_on_channel_solo_changed)
		channel.peak_updated.disconnect(_on_channel_peak_updated)
		channel.pan_mode_changed.disconnect(_on_channel_pan_mode_changed)
		channel.pan_changed.disconnect(_on_channel_pan_changed)
		channel.route_changed.disconnect(_on_channel_route_changed)
		channel.device_added.disconnect(_on_channel_device_added)
		channel.device_removed.disconnect(_on_channel_device_removed)
		channel.color_changed.disconnect(_on_channel_color_changed)

	channel = ch
	project = proj

	# Connect to channel signals
	if channel:
		channel.name_changed.connect(_on_channel_name_changed)
		channel.volume_changed.connect(_on_channel_volume_changed)
		channel.mute_changed.connect(_on_channel_mute_changed)
		channel.solo_changed.connect(_on_channel_solo_changed)
		channel.peak_updated.connect(_on_channel_peak_updated)
		channel.pan_mode_changed.connect(_on_channel_pan_mode_changed)
		channel.pan_changed.connect(_on_channel_pan_changed)
		channel.route_changed.connect(_on_channel_route_changed)
		channel.device_added.connect(_on_channel_device_added)
		channel.device_removed.connect(_on_channel_device_removed)
		channel.color_changed.connect(_on_channel_color_changed)

		# Bind device list to channel
		if device_list and device_list is ChannelDeviceList:
			device_list.bind_to_channel(channel)
		
		# Bind sends panel to channel
		if sends_panel and sends_panel is SendsPanel:
			sends_panel.bind_to_channel(channel, project)

	# Update UI from channel data
	_update_from_channel()
	_rebuild_output_menu()


func _update_from_channel() -> void:
	"""Update all UI elements from channel data."""
	if channel == null:
		return

	# Update title
	if title:
		title.set_value(channel.name)

	# Update header color from channel color
	var stylebox : StyleBoxFlat = header.get_theme_stylebox("panel")
	stylebox.bg_color = channel.color

	# Update toggles
	solo_toggle.set_pressed_no_signal(channel.solo)

	mute_toggle.set_pressed_no_signal(channel.mute)

	# Update volume slider
	bottom_volume_slider.set_value_no_signal(channel.volume)

	# Update meter (peak levels)
	big_meter.set_peak_levels(channel.peak_left, channel.peak_right)
	
	# Update output button text
	_update_output_button_text()

	pinned = channel.is_master


# ============================================================================
# DETAILS PANE MANAGEMENT
# ============================================================================
func _init_details_pane() -> void:
	"""Initialize the details pane as hidden by default."""
	if details:
		details.visible = false
		# Wait for layout to be ready
		await get_tree().process_frame  # Extra frame to ensure size calculation
		# Get the actual size when visible (will be used for toggling)
		details_pane_width = int(details.get_size().x)
		if details_pane_width == 0:
			# Fallback: use get_minimum_size if size is still 0
			details_pane_width = int(details.get_minimum_size().x)
			if details_pane_width == 0:
				details_pane_width = 140  # Conservative estimate


func _toggle_details_pane() -> void:
	"""Toggle the details pane visibility and adjust sizing."""
	if not details:
		return

	details_visible = !details_visible
	details.visible = details_visible

	# If showing details, wait a frame for layout to settle and capture actual width
	if details_visible:
		await get_tree().process_frame

		# Get the actual size the pane now occupies
		var actual_details_width = int(details.get_size().x)
		if actual_details_width > 0:
			details_pane_width = actual_details_width

	# Update size based on new state
	_update_size_for_mode()


# ============================================================================
# UI CALLBACKS - User interactions
# ============================================================================
func _on_solo_toggled(pressed: bool) -> void:
	if channel:
		channel.set_solo(pressed)


func _on_mute_toggled(pressed: bool) -> void:
	if channel:
		channel.set_mute(pressed)


func _on_volume_changed(value: float) -> void:
	if channel:
		channel.set_volume(value)

func _on_pan_changed(left : float, right: float = 0.0) -> void:
	left /= 100
	right /= 100
	print("pan changed, setting channel.pan to ", left, ", ", right)
	channel.set_pan(left, right)

func _on_panning_gui_input(event : InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		pan_mode_popup.popup(
			Rect2(panning.global_position, Vector2(0, 0))
		)

func _on_pan_mode_selected(pan_mode_id):
	if pan_mode_id == Channel.PanMode.STEREO_COMBINED:
		channel.set_pan_mode(Channel.PanMode.STEREO_COMBINED)
		print("set pan mode to stereo combined")
	else:
		channel.set_pan_mode(Channel.PanMode.STEREO_DUAL)
		print("set pan mode to stereo dual")


func _on_mouse_entered() -> void:
	var mouse = get_local_mouse_position()
	if is_resizing or (resizable and mouse.x >= size.x - 8):
		# right edge, can resize (only if resizable is true)
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW

func _on_mouse_exited() -> void:
	if not is_resizing:
		mouse_default_cursor_shape = Control.CURSOR_ARROW

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and not is_resizing:
			# start resize only if resizable is true and mouse is on the right edge
			var mouse = get_local_mouse_position()
			if resizable and mouse.x >= size.x - 8:
				_start_resize()
				accept_event()
		elif event.is_released() and is_resizing:
			_stop_resize()
			accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.is_pressed() and not is_resizing:
			request_show_context_menu.emit()

func _input(event: InputEvent) -> void:
	# stop resizing if mouse released anywhere
	if is_resizing and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
			_stop_resize()
			accept_event()

func _start_resize():
	if is_moving:
		return
	
	var mouse = get_global_mouse_position()
	resize_mouse_start = mouse
	resize_width_start = int(size.x)
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	is_resizing = true


func _process(_delta : float):
	if is_resizing:
		var mouse = get_global_mouse_position()
		var mouse_delta = resize_mouse_start.x - mouse.x

		var new_width = resize_width_start - mouse_delta

		if mode == Mode.COMPACT:
			new_width = max(new_width, compact_min_width)
		else:
			new_width = max(new_width, large_min_width)

		custom_minimum_size.x = new_width
	elif is_moving:
		_update_move()
	else:
		# show resize cursor when hovering on right edge (only if resizable)
		var local_mouse = get_local_mouse_position()
		if resizable and local_mouse.x >= size.x - 8:
			mouse_default_cursor_shape = Control.CURSOR_HSIZE
		else:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

func _stop_resize():
	is_resizing = false
	mouse_default_cursor_shape = Control.CURSOR_ARROW

func _on_title_value_changed(new_name : String) -> void:
	channel.set_name(new_name)

func _on_header_gui_input(event : InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_event = event as InputEventMouseButton
		
		if mouse_event.shift_pressed or mouse_event.ctrl_pressed:
			return
		
		if not is_moving and event.is_pressed():
			if get_local_mouse_position().x >= size.x - 8:
				return
			# start moving
			_start_move()
		elif is_moving  and event.is_released():
			_stop_move()



func _start_move():
	if is_resizing: return
	is_moving = true
	move_mouse_start = get_global_mouse_position()
	move_index_start = get_index()

func _move_completed() -> void:
	move_index_start = get_index()
	move_mouse_start = get_global_mouse_position()
	move_awaiting = false

func _update_move():
	# Don't process moves if we're already waiting for a reorder
	if move_awaiting:
		return
	
	var global_rect = get_global_rect()
	var global_mouse = get_global_mouse_position()
	var mouse_delta =  global_mouse - move_mouse_start
	
	if global_mouse.x > global_rect.end.x:
		# request move to the right
		move_awaiting = true
		request_move.emit(get_index() + 1)
		await get_parent().child_order_changed
		_move_completed()
	elif global_mouse.x < global_rect.position.x:
		# request move to left
		move_awaiting = true
		request_move.emit(get_index() - 1)
		await get_parent().child_order_changed
		_move_completed()

func _stop_move():
	is_moving = false
	move_awaiting = false


# ============================================================================
# CHANNEL SIGNAL CALLBACKS - Data changes from Channel
# ============================================================================
func _on_channel_name_changed(new_name : String) -> void:
	"""React to name changes from Channel."""
	title.set_value(new_name)

func _on_channel_volume_changed(db: float) -> void:
	"""React to volume changes from Channel."""
	if bottom_volume_slider:
		bottom_volume_slider.set_value_no_signal(db)
		bottom_small_meter.volume_db = db


func _on_channel_mute_changed(value: bool) -> void:
	"""React to mute changes from Channel."""
	if mute_toggle:
		mute_toggle.set_pressed_no_signal(value)


func _on_channel_solo_changed(value: bool) -> void:
	"""React to solo changes from Channel."""
	if solo_toggle:
		solo_toggle.set_pressed_no_signal(value)


func _on_channel_color_changed(new_color : Color) -> void:
	var stylebox : StyleBoxFlat = header.get_theme_stylebox("panel")
	stylebox.bg_color = new_color


func _on_channel_peak_updated(peak_left: float, peak_right: float, rms_left: float, rms_right: float) -> void:
	"""React to peak meter updates from Channel."""
	big_meter.set_peak_levels(peak_left, peak_right)
	big_meter.set_rms_levels(rms_left, rms_right)
	bottom_small_meter.set_peak_levels(peak_left, peak_right)
	bottom_small_meter.set_rms_levels(rms_left, rms_right)

func _on_channel_pan_mode_changed(pan_mode : Channel.PanMode):
	print("channel pan mode changed. applying to UI...")
	if pan_mode == Channel.PanMode.STEREO_COMBINED:
		panning_dual_slider.visible = false
		panning_combined_slider.visible = true
		panning_combined_slider.set_value_no_signal(channel.pan * 100)
		pan_mode_popup.set_item_checked(0, true)
		pan_mode_popup.set_item_checked(1, false)
	else:
		panning_combined_slider.visible = false
		panning_dual_slider.visible = true
		panning_dual_slider.set_values_no_signal(channel.pan_left * 100, channel.pan_right * 100)
		pan_mode_popup.set_item_checked(0, false)
		pan_mode_popup.set_item_checked(1, true)

func _on_channel_pan_changed(pan_left : float, pan_right : float = 0.0):
	if channel.pan_mode == Channel.PanMode.STEREO_COMBINED:
		panning_combined_slider.set_value_no_signal(pan_left * 100)
	else:
		panning_dual_slider.set_values_no_signal(pan_left * 100, pan_right * 100)

# ============================================================================
# HELPERS, SIZING
# ============================================================================
func _get_minimum_size() -> Vector2:
	if mode == Mode.COMPACT:
		return Vector2(compact_min_width, 0)
	else:
		return Vector2(large_min_width, 0)


func set_mode(m : Mode):
	mode = m
	if is_inside_tree():
		device_list.hide_parameters = true
	_update_size_for_mode()


func _update_size_for_mode() -> void:
	"""Update custom_minimum_size based on current mode and details pane visibility."""
	var base_width = compact_min_width if mode == Mode.COMPACT else large_min_width

	if details_visible and details_pane_width > 0:
		# If details pane is visible, add its width to the base
		custom_minimum_size.x = base_width + details_pane_width
	else:
		# Otherwise, just use the base width for this mode
		custom_minimum_size.x = base_width


func set_resizable(value: bool) -> void:
	"""Set whether this channel can be resized."""
	resizable = value


func _update_container_sizing() -> void:
	"""Update container size flags based on pinned state."""
	# disabled
	pass

	if pinned:
		# Pinned channels: shrink to end and expand to fill available space
		size_flags_horizontal = Control.SIZE_SHRINK_END | Control.SIZE_EXPAND
	else:
		# Normal channels: shrink to beginning (left side)
		size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


# ============================================================================
# OUTPUT ROUTING MENU
# ============================================================================

func _rebuild_output_menu() -> void:
	"""Rebuild the output routing menu based on available channels."""
	if not output_menu_buttton or not project or not channel:
		return

	var popup = output_menu_buttton.get_popup()
	popup.clear()

	# Master channel: show only device outputs
	if channel.is_master:
		_populate_device_outputs(popup)
		_update_output_button_text()
		return

	# Regular channels: show buses and master

	# Add master channel (ID 1)
	popup.add_item("Master", 1)
	if channel.output_channel_id == 1:
		popup.set_item_checked(popup.item_count - 1, true)

	# Add separator
	popup.add_separator()

	# Add buses (channels that can be routed to)
	# Only allow routing to BUS channels, not INSTRUMENT or AUDIO channels
	for ch in project.channels:
		# Exclude: self, master, and non-BUS channels
		if ch.id != channel.id and ch.id != 1 and ch.channel_type == Channel.ChannelType.BUS:
			popup.add_item(ch.name, ch.id)
			if channel.output_channel_id == ch.id:
				popup.set_item_checked(popup.item_count - 1, true)

	_update_output_button_text()


func _populate_device_outputs(popup: PopupMenu) -> void:
	"""Populate popup with device output options (for master channel)."""
	# For now, just show default output device
	popup.add_item("Default Output (1000)", 1000)
	if channel.device_output_id == 1000:
		popup.set_item_checked(0, true)

	# TODO: Add more device outputs when multi-device routing is supported
	# for device_id in range(1001, 1010):
	#     popup.add_item("Output %d" % (device_id - 1000), device_id)


func _on_output_menu_selected(item_id: int) -> void:
	"""Handle output menu selection."""
	if not channel or not project:
		return

	# Master channel: set device output
	if channel.is_master:
		channel.device_output_id = item_id
		_update_output_button_text()
		print("[MixerChannel] Master routed to device %d" % item_id)
	else:
		# Regular channel: set channel routing
		channel.set_route(item_id)
		print("[MixerChannel] Channel %d routed to %d" % [channel.id, item_id])


func _update_output_button_text() -> void:
	"""Update the output menu button text to show current routing."""
	if not output_menu_buttton or not channel:
		return

	var label = _get_output_label()
	output_menu_buttton.text = label


func _get_output_label() -> String:
	"""Get the label for the current output routing."""
	if not channel or not project:
		return "Output"

	# Master channel: show device output
	if channel.is_master:
		if channel.device_output_id == 1000:
			return "Default Output"
		else:
			return "Output %d" % (channel.device_output_id - 1000)

	# Regular channel: show routing target
	if channel.output_channel_id == 1:
		return "Master"
	else:
		# Find channel by ID
		var target_channel = project.get_channel_by_id(channel.output_channel_id)
		if target_channel:
			return target_channel.name
		return "Unknown"


func _on_channel_route_changed(output_id: int) -> void:
	"""React to routing changes from Channel."""
	_rebuild_output_menu()


func _on_channel_device_added(device_instance: DeviceInstance, position: int) -> void:
	"""React to device added to channel."""
	# ChannelDeviceList handles UI updates via bind_to_channel
	print("[MixerChannel] Device added at position %d: %s" % [position, device_instance.device.name])


func _on_channel_device_removed(position: int, device_id: String) -> void:
	"""React to device removed from channel."""
	# ChannelDeviceList handles UI updates via its internal signal listeners
	print("[MixerChannel] Device removed from position %d: %s" % [position, device_id])


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(at_position: Vector2) -> Variant:
	"""Return drag data from this node (not used for mixer, but required by set_drag_forwarding)."""
	return null


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	"""Check if we can drop a device or SFZ file on this channel."""
	if not channel or not data is Asset:
		return false

	# Handle SFZ file drops (can only be dropped on INSTRUMENT channels)
	if data.type == Asset.TYPE.SFZ:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT

	# Handle device drops
	if data.type != Asset.TYPE.Device:
		return false

	# Get the device metadata to check its category
	var device = AssetService.get_device(data.path)
	if not device:
		return false

	# INSTRUMENT devices can only be dropped on INSTRUMENT channels
	if device.category == Device.DeviceCategory.Instrument:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT

	# EFFECT devices can be dropped on any channel (not Master if we want to restrict)
	# Allow effects on regular channels and bus channels
	return not channel.is_master


func _drop_data(at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a device or SFZ file on this channel."""
	if not data is Asset or not channel:
		return

	var asset = data as Asset
	
	# Handle SFZ file drops
	if asset.type == Asset.TYPE.SFZ:
		_handle_sfz_drop(asset)
		return
	
	# Handle device drops
	if asset.type != Asset.TYPE.Device:
		return

	print("[MixerChannel] Device dropped on channel %d: %s" % [channel.id, asset.name])

	# Get the device metadata
	var device = AssetService.get_device(asset.path)
	if not device:
		push_error("[MixerChannel] Failed to get device: ", asset.path)
		return

	# Create device instance and add to channel
	var device_instance = DeviceInstance.new(device, channel.id, channel.get_device_count())
	channel.add_device(device_instance, -1)
	print("[MixerChannel] Device added to channel: %s" % device.device_id)


func _handle_sfz_drop(asset: Asset) -> void:
	"""Handle dropping an SFZ file on this channel."""
	print("[MixerChannel] SFZ dropped on channel %d: %s" % [channel.id, asset.name])
	
	# Get the sfizz device from AssetService
	var sfizz_device = AssetService.get_device("sonara.builtin.sfizz")
	if not sfizz_device:
		push_error("[MixerChannel] Failed to get sfizz device")
		return
	
	# Create sfizz device instance and add to channel
	var device_instance = DeviceInstance.new(sfizz_device, channel.id, channel.get_device_count())
	channel.add_device(device_instance, -1)
	
	# Load the SFZ file into the device
	# Give the engine a moment to create the device before loading the file
	await get_tree().create_timer(0.1).timeout
	device_instance.load_file(asset.path)
	
	print("[MixerChannel] SFZ loaded into channel: %s" % asset.name)
