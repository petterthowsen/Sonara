@tool
class_name MixerChannel extends PanelContainer

var logger : Log = Log.make("MixerChannel")

# UI References
@onready var header: Panel = $HBox/VBox/Header
@onready var title: SmartLineEdit = $HBox/VBox/Header/VBox/SmartLineEdit
@onready var foldout_toggle: Button = $HBox/VBox/Header/VBox/FoldoutToggle

@onready var children_slide = $HBox/Children # fold-out pane

@onready var big_meter: Meter = $HBox/VBox/BigMeter

@onready var controls: PanelContainer = $HBox/VBox/Controls
@onready var arm_toggle: Button = $HBox/VBox/Controls/FlowContainer/ArmToggle
@onready var solo_toggle: Button = $HBox/VBox/Controls/FlowContainer/SoloMute/SoloToggle
@onready var mute_toggle: Button = $HBox/VBox/Controls/FlowContainer/SoloMute/MuteToggle

@onready var io: PanelContainer = $HBox/VBox/IO
@onready var output_menu_buttton: MenuButton = $HBox/VBox/IO/OutputMenuButtton

@onready var pan_control: PanControl = $HBox/VBox/Panning

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
		if is_selected == selected:
			return
		is_selected = selected
		if is_inside_tree():
			var bc = border_color_selected if is_selected else border_color
			var stylebox: StyleBoxFlat = get_theme_stylebox("panel")
			stylebox.border_color = bc
			_apply_selection_layout()


signal request_move(new_index : int)
signal request_show_context_menu

# Data binding
var channel: Channel = null
var project: Project = null  # Reference to project for accessing other channels
var _header_fill: StyleBoxFlat = null

# Pinning - when true, this channel stays on the right side of the mixer
@export var pinned: bool = false:
	set(p):
		pinned = p
		_update_container_sizing()

enum Mode {COMPACT, LARGE}

const compact_min_width = 50
const large_min_width = 100

## Extra width for the focused/selected strip so compact device parameters are usable.
@export var selected_min_width := 120

@export var mode = Mode.COMPACT:
	set = set_mode

func _ready():
	_update_container_sizing()
	_apply_selection_layout()
	_init_details_pane()
	set_process(false)

	# Connect UI signals
	if solo_toggle:
		solo_toggle.toggled.connect(_on_solo_toggled)
	if mute_toggle:
		mute_toggle.toggled.connect(_on_mute_toggled)
	if arm_toggle:
		arm_toggle.toggled.connect(_on_arm_toggled)
	if bottom_volume_slider:
		bottom_volume_slider.value_changed.connect(_on_volume_changed)
	
	big_meter.volume_changed.connect(_on_volume_changed)
	bottom_small_meter.volume_changed.connect(_on_volume_changed)
	
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	if title:
		title.value_changed.connect(_on_title_value_changed)

	if header:
		header.gui_input.connect(_on_header_gui_input)
		# Full-rect layout control must not eat clicks meant for the header panel (move / select).
		var header_layout := header.get_node_or_null("VBox") as Control
		if header_layout:
			header_layout.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if foldout_toggle:
		foldout_toggle.toggled.connect(_on_foldout_toggled)
		if not Engine.is_editor_hint():
			foldout_toggle.visible = false
	if children_slide:
		if children_slide.contents_changed.is_connected(_update_size_for_mode) == false:
			children_slide.contents_changed.connect(_update_size_for_mode)
		if not Engine.is_editor_hint():
			children_slide.visible = false

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
		channel.route_changed.disconnect(_on_channel_route_changed)
		channel.device_added.disconnect(_on_channel_device_added)
		channel.device_removed.disconnect(_on_channel_device_removed)
		channel.color_changed.disconnect(_on_channel_color_changed)
		channel.record_armed_changed.disconnect(_on_channel_record_armed_changed)
		if channel.hierarchy_changed.is_connected(_on_channel_hierarchy_changed):
			channel.hierarchy_changed.disconnect(_on_channel_hierarchy_changed)

	channel = ch
	project = proj
	pan_control.bind_to_channel(channel)

	# Connect to channel signals
	if channel:
		channel.name_changed.connect(_on_channel_name_changed)
		channel.volume_changed.connect(_on_channel_volume_changed)
		channel.mute_changed.connect(_on_channel_mute_changed)
		channel.solo_changed.connect(_on_channel_solo_changed)
		channel.peak_updated.connect(_on_channel_peak_updated)
		channel.route_changed.connect(_on_channel_route_changed)
		channel.device_added.connect(_on_channel_device_added)
		channel.device_removed.connect(_on_channel_device_removed)
		channel.color_changed.connect(_on_channel_color_changed)
		channel.record_armed_changed.connect(_on_channel_record_armed_changed)
		channel.hierarchy_changed.connect(_on_channel_hierarchy_changed)

		# Bind device list to channel
		if device_list and device_list is ChannelDeviceList:
			device_list.bind_to_channel(channel)
		
		# Bind sends panel to channel
		if sends_panel and sends_panel is SendsPanel:
			sends_panel.bind_to_channel(channel, project)

	# Update UI from channel data
	_update_from_channel()
	_rebuild_output_menu()
	_sync_children_slide()


func _update_from_channel() -> void:
	"""Update all UI elements from channel data."""
	if channel == null:
		return

	# Update title
	if title:
		title.set_value(channel.name)

	# Update header color from channel color
	_apply_header_color(channel.color)
	if children_slide:
		children_slide.apply_header_color(channel.color)

	# Update toggles
	solo_toggle.set_pressed_no_signal(channel.solo)

	mute_toggle.set_pressed_no_signal(channel.mute)

	if arm_toggle:
		arm_toggle.set_pressed_no_signal(channel.record_armed)

	# Update volume slider and meter faders (scene default is -6 dB for regular channels)
	_apply_volume_to_ui(channel.volume)

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
		HistoryUtil.execute_property("Solo", channel, "set_solo", channel.solo, pressed)


func _on_mute_toggled(pressed: bool) -> void:
	if channel:
		HistoryUtil.execute_property("Mute", channel, "set_mute", channel.mute, pressed)


func _on_arm_toggled(pressed: bool) -> void:
	if channel:
		channel.set_record_armed(pressed)


func _on_volume_changed(value: float) -> void:
	if channel:
		var old_volume := channel.volume
		channel.set_volume(value)
		HistoryUtil.record_property("Set Volume", channel, "set_volume", old_volume, channel.volume, true)


func _on_mouse_entered() -> void:
	_update_hover_cursor(get_local_mouse_position())

func _on_mouse_exited() -> void:
	if not is_resizing:
		mouse_default_cursor_shape = Control.CURSOR_ARROW

## Update the resize-cursor hint from a known local mouse position, without polling every frame.
func _update_hover_cursor(local_mouse: Vector2) -> void:
	if is_resizing:
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	elif resizable and local_mouse.x >= size.x - 8:
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW

func _gui_input(event: InputEvent):
	if event is InputEventMouseMotion:
		if not is_resizing and not is_moving:
			_update_hover_cursor(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
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
	if is_moving and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
			_stop_move()
			accept_event()

func _start_resize():
	if is_moving:
		return
	
	var mouse = get_global_mouse_position()
	resize_mouse_start = mouse
	resize_width_start = int(size.x)
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	is_resizing = true
	set_process(true)


func _process(_delta : float):
	if is_resizing:
		var mouse = get_global_mouse_position()
		var mouse_delta = resize_mouse_start.x - mouse.x

		var new_width = resize_width_start - mouse_delta

		new_width = max(new_width, _total_min_width())

		custom_minimum_size.x = new_width
	elif is_moving:
		_update_move()
	else:
		# Neither resizing nor moving: nothing to poll, stop ticking.
		set_process(false)

func _stop_resize():
	is_resizing = false
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	if not is_moving:
		set_process(false)

func _on_title_value_changed(new_name : String) -> void:
	channel.set_name(new_name)

func _on_header_gui_input(event : InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if foldout_toggle and foldout_toggle.visible and foldout_toggle.get_global_rect().has_point(get_global_mouse_position()):
			return
		var mouse_event = event as InputEventMouseButton

		if mouse_event.pressed:
			_request_mixer_selection(mouse_event.ctrl_pressed)

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
	set_process(true)


func _move_completed() -> void:
	move_index_start = get_index()
	move_mouse_start = get_global_mouse_position()
	move_awaiting = false


## Reorder by the mouse's position among sibling midpoints so a fast drag can skip multiple channels.
func _update_move():
	var parent := get_parent()
	if parent == null:
		return

	var mouse_x := get_global_mouse_position().x
	var current_index := get_index()
	var target_index := current_index

	for i in range(current_index):
		var sibling := parent.get_child(i) as Control
		if sibling == null:
			continue
		if mouse_x < sibling.get_global_rect().get_center().x:
			target_index = i
			break

	for i in range(current_index + 1, parent.get_child_count()):
		var sibling := parent.get_child(i) as Control
		if sibling == null:
			continue
		if mouse_x > sibling.get_global_rect().get_center().x:
			target_index = i
		else:
			break

	if target_index != current_index:
		request_move.emit(target_index)
		_move_completed()


func _stop_move():
	is_moving = false
	move_awaiting = false
	if not is_resizing:
		set_process(false)


## Forward header clicks to the owning Mixer selection logic (strip body uses Mixer.gui_input).
func _request_mixer_selection(multi: bool) -> void:
	if channel == null or Engine.is_editor_hint():
		return
	var mixer := _find_mixer()
	if mixer:
		mixer.select_channel(channel, multi)


## Walk ancestors to the Mixer that owns this strip (root or nested).
func _find_mixer() -> Mixer:
	var n: Node = self
	while n:
		if n is Mixer:
			return n as Mixer
		n = n.get_parent()
	return null


# ============================================================================
# CHANNEL SIGNAL CALLBACKS - Data changes from Channel
# ============================================================================
func _on_channel_name_changed(new_name : String) -> void:
	"""React to name changes from Channel."""
	title.set_value(new_name)

func _on_channel_volume_changed(db: float) -> void:
	"""React to volume changes from Channel."""
	_apply_volume_to_ui(db)


func _apply_volume_to_ui(db: float) -> void:
	"""Copy volume onto the hidden slider and both meter faders without re-emitting."""
	if bottom_volume_slider:
		bottom_volume_slider.set_value_no_signal(db)
	if bottom_small_meter:
		bottom_small_meter.volume_db = db
	if big_meter:
		big_meter.volume_db = db


func _on_channel_mute_changed(value: bool) -> void:
	"""React to mute changes from Channel."""
	if mute_toggle:
		mute_toggle.set_pressed_no_signal(value)


func _on_channel_solo_changed(value: bool) -> void:
	"""React to solo changes from Channel."""
	if solo_toggle:
		solo_toggle.set_pressed_no_signal(value)


func _on_channel_record_armed_changed(armed: bool) -> void:
	"""React to record armed changes from Channel."""
	if arm_toggle:
		arm_toggle.set_pressed_no_signal(armed)


## Keep the header fill and title contrast in sync with the channel color.
func _on_channel_color_changed(new_color : Color) -> void:
	_apply_header_color(new_color)
	if children_slide:
		children_slide.apply_header_color(new_color)


## Tint the mixer header with the stored channel color; clamp only for drawing.
func _apply_header_color(new_color: Color) -> void:
	if header == null:
		return
	var drawn := Utils.display_color(new_color)
	if _header_fill == null:
		var base := header.get_theme_stylebox("panel")
		_header_fill = base.duplicate() as StyleBoxFlat if base is StyleBoxFlat else StyleBoxFlat.new()
		header.add_theme_stylebox_override("panel", _header_fill)
	_header_fill.bg_color = drawn
	header.queue_redraw()
	if title:
		title.set_font_color(Utils.contrasting_text_color(drawn))


func _on_channel_peak_updated(peak_left: float, peak_right: float, rms_left: float, rms_right: float) -> void:
	"""React to peak meter updates from Channel."""
	big_meter.set_peak_levels(peak_left, peak_right)
	big_meter.set_rms_levels(rms_left, rms_right)
	bottom_small_meter.set_peak_levels(peak_left, peak_right)
	bottom_small_meter.set_rms_levels(rms_left, rms_right)

# ============================================================================
# HELPERS, SIZING
# ============================================================================
## Report the current layout floor so containers don't shrink a selected strip.
func _get_minimum_size() -> Vector2:
	return Vector2(_total_min_width(), 0)


## Compact or large floor, raised when this channel is selected.
func _mode_min_width() -> int:
	var w := compact_min_width if mode == Mode.COMPACT else large_min_width
	if is_selected:
		w = maxi(w, selected_min_width)
	return w


## Widen the selected strip and expose compact device parameters on it.
func _apply_selection_layout() -> void:
	if device_list:
		device_list.hide_parameters = not is_selected
	_update_size_for_mode()


## Switch compact/large layout and refresh width plus device-parameter visibility.
func set_mode(m : Mode):
	mode = m
	if is_inside_tree():
		_apply_selection_layout()
	else:
		_update_size_for_mode()


func _update_size_for_mode() -> void:
	"""Update custom_minimum_size based on current mode, selection, details, and children."""
	custom_minimum_size.x = _total_min_width()
	var strip := get_node_or_null("HBox/VBox") as Control
	if strip:
		strip.custom_minimum_size.x = _mode_min_width()
	update_minimum_size()
	_notify_parent_mixer_channel_size()


## Nested fold-outs grow this strip; tell the enclosing MixerChannel to include the new width.
func _notify_parent_mixer_channel_size() -> void:
	var n := get_parent()
	while n:
		if n is MixerChannel and n != self:
			n._update_size_for_mode()
			return
		n = n.get_parent()


## Strip floor plus open details pane and expanded nested children.
func _total_min_width() -> int:
	var w := _mode_min_width()
	if details_visible and details_pane_width > 0:
		w += details_pane_width
	if children_slide and children_slide.visible:
		w += maxi(int(children_slide.get_combined_minimum_size().x), 0)
	return w


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
	output_menu_buttton.disabled = false

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

	# Route to BUS and GROUP (not instrument/audio, not self, not a descendant)
	for ch in project.channels:
		if _is_valid_route_target(ch):
			popup.add_item(ch.name, ch.id)
			if channel.output_channel_id == ch.id:
				popup.set_item_checked(popup.item_count - 1, true)

	output_menu_buttton.disabled = channel.route_locked()
	_update_output_button_text()


## True when this strip may route to `target` (BUS or GROUP, no cycles).
func _is_valid_route_target(target: Channel) -> bool:
	if target == null or channel == null or project == null:
		return false
	if target.id == channel.id or target.is_master:
		return false
	if target.channel_type != Channel.ChannelType.BUS and target.channel_type != Channel.ChannelType.GROUP:
		return false
	if project.channel_is_in_subtree(target.id, channel):
		return false
	return true


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
	if channel.route_locked():
		return

	# Master channel: set device output
	if channel.is_master:
		channel.device_output_id = item_id
		_update_output_button_text()
		logger.info("Master routed to device %d" % item_id)
	else:
		# Regular channel: set channel routing
		channel.set_route(item_id)
		logger.info("Channel %d routed to %d" % [channel.id, item_id])


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


## Rebuild the output menu and nested fold-out when mixer parent/children change.
func _on_channel_hierarchy_changed() -> void:
	if is_queued_for_deletion():
		return
	_rebuild_output_menu()
	_sync_children_slide()


## Toggle nested children visibility and persist `is_children_expanded`.
func _on_foldout_toggled(pressed: bool) -> void:
	if channel == null:
		return
	channel.is_children_expanded = pressed
	_sync_children_slide()


## Show the fold-out for GROUP channels or any channel that already has children.
func _shows_children_foldout() -> bool:
	if channel == null:
		return false
	return channel.is_group_channel or not channel.child_channel_ids.is_empty()


## Update fold-out chrome, spawn nested strips, and refresh this strip's width.
func _sync_children_slide() -> void:
	var show_fold := _shows_children_foldout()
	var expanded := show_fold and channel != null and channel.is_children_expanded

	if foldout_toggle:
		foldout_toggle.visible = show_fold
		foldout_toggle.set_pressed_no_signal(expanded)

	if children_slide:
		children_slide.visible = expanded
		if show_fold and channel:
			children_slide.bind_to_parent(channel, project, self)

	_update_size_for_mode()


func _on_channel_device_added(device_instance: DeviceInstance, position: int) -> void:
	"""React to device added to channel."""
	# ChannelDeviceList handles UI updates via bind_to_channel
	logger.info("Device added at position %d: %s" % [position, device_instance.device.name])


func _on_channel_device_removed(position: int, device_id: String) -> void:
	"""React to device removed from channel."""
	# ChannelDeviceList handles UI updates via its internal signal listeners
	logger.info("Device removed from position %d: %s" % [position, device_id])


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Start a mixer reparent drag from the header; sibling slide stays a separate header gesture."""
	if Engine.is_editor_hint() or is_resizing or is_moving:
		return null
	if not MixerChannelDrag.can_drag(channel):
		return null
	if header == null or not header.get_global_rect().has_point(get_global_mouse_position()):
		return null
	if foldout_toggle and foldout_toggle.visible and foldout_toggle.get_global_rect().has_point(get_global_mouse_position()):
		return null

	var preview := MixerChannelDrag.make_preview(channel)
	var drag_data := MixerChannelDrag.new(self, channel, preview)
	set_drag_preview(preview)
	logger.info("Started nest drag: ", channel.name)
	return drag_data


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	"""Accept a mixer nest onto this GROUP strip, a sibling insert in a fold-out, or a device/SFZ asset."""
	if data is MixerChannelDrag:
		if _can_drop_channel_nest(data as MixerChannelDrag):
			return true
		var kids := _enclosing_children_pane()
		return kids != null and kids._can_drop_data(at_position, data)
	return channel != null and data is Asset and DeviceDropUtil.can_drop_asset_on_channel(channel, data)


func _drop_data(at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a nested mixer channel, device, or SFZ file on this strip."""
	if data is MixerChannelDrag:
		if _can_drop_channel_nest(data as MixerChannelDrag):
			_drop_channel_nest(data as MixerChannelDrag)
			return
		var kids := _enclosing_children_pane()
		if kids:
			kids._drop_data(at_position, data)
		return
	if channel and data is Asset:
		DeviceDropUtil.drop_asset(channel, data, -1, null)


## True when this GROUP or instrument strip can take `data.channel` as a nested child.
func _can_drop_channel_nest(data: MixerChannelDrag) -> bool:
	if data == null or data.channel == null or channel == null or project == null:
		return false
	if data.channel == channel:
		return false
	# Already a child: sibling header-slide owns reorder inside this group.
	if data.channel.parent_channel_id == channel.id:
		return false
	return project.can_nest_channel(data.channel, channel)


## Nest the dragged strip under this GROUP, appending after the current last child.
func _drop_channel_nest(data: MixerChannelDrag) -> void:
	if not _can_drop_channel_nest(data):
		return
	data.destination = self
	var after := MixerChannelDrag.last_child(project, channel)
	if MixerChannelDrag.commit(project, data.channel, channel, after):
		data.did_commit = true


## Fold-out pane that owns this strip when nested under a Group.
func _enclosing_children_pane() -> MixerChannelChildren:
	var n := get_parent()
	while n:
		if n is MixerChannelChildren:
			return n as MixerChannelChildren
		n = n.get_parent()
	return null
