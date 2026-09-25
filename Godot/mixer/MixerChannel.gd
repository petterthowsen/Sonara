@tool
class_name MixerChannel extends PanelContainer

var logger : Log = Log.make("MixerChannel")

# UI References
@onready var header: Panel = $HBox/VBox/Header
@onready var title: SmartLineEdit = $HBox/VBox/Header/VBox/SmartLineEdit
@onready var foldout_toggle: Button = $HBox/VBox/Header/VBox/FoldoutToggle

@onready var children_clip: Control = $HBox/ChildrenClip # clips the fold-out while it slides
@onready var children_slide = $HBox/ChildrenClip/Children # fold-out pane

@onready var main_pane: VBoxContainer = $HBox/VBox/MainAndSideBox/MainPane
@onready var main_vsplit: VSplitContainer = $HBox/VBox/MainAndSideBox/MainPane/VSplit
@onready var side_pane: Control = $HBox/VBox/MainAndSideBox/SidePane
@onready var side_vsplit: VSplitContainer = $HBox/VBox/MainAndSideBox/SidePane/VSplit

@onready var big_meter: Meter = $HBox/VBox/MainAndSideBox/MainPane/BigMeter

@onready var controls: PanelContainer = $HBox/VBox/MainAndSideBox/MainPane/Controls
@onready var arm_toggle: Button = $HBox/VBox/MainAndSideBox/MainPane/Controls/FlowContainer/ArmToggle
@onready var solo_toggle: Button = $HBox/VBox/MainAndSideBox/MainPane/Controls/FlowContainer/SoloMute/SoloToggle
@onready var mute_toggle: Button = $HBox/VBox/MainAndSideBox/MainPane/Controls/FlowContainer/SoloMute/MuteToggle

@onready var io: PanelContainer = $HBox/VBox/MainAndSideBox/MainPane/IO
@onready var output_menu_buttton: MenuButton = $HBox/VBox/MainAndSideBox/MainPane/IO/OutputMenuButtton

@onready var pan_control: PanControl = $HBox/VBox/MainAndSideBox/MainPane/Panning

# main volume, fader and/or volume
@onready var volume: PanelContainer = $HBox/VBox/MainAndSideBox/MainPane/Volume
@onready var bottom_volume_slider: VolumeSlider = $HBox/VBox/MainAndSideBox/MainPane/Volume/Fader
@onready var bottom_small_meter: Meter = $HBox/VBox/MainAndSideBox/MainPane/Volume/CompactMeter

# compact devices parameter control; lives in MainPane/VSplit (Tall mode) or SidePane/VSplit (Compact mode)
@onready var device_list: ChannelDeviceList = $HBox/VBox/MainAndSideBox/MainPane/VSplit/DeviceList

# sends panel; lives in MainPane/VSplit (Tall mode) or SidePane/VSplit (Compact mode)
@onready var sends: ScrollContainer = $HBox/VBox/MainAndSideBox/MainPane/VSplit/Sends
@onready var sends_panel: SendsPanel = $HBox/VBox/MainAndSideBox/MainPane/VSplit/Sends/SendsPanel

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

## Base strip width. Narrow has no floor (shrink to content); medium and wide are fixed floors.
enum SizeMode {NARROW, MEDIUM, WIDE}
const NARROW_WIDTH := 0
const MEDIUM_BASE_WIDTH := 108
const WIDE_WIDTH := 138

## Tall keeps DeviceList/Sends in the main column. Compact moves them into the SidePane,
## which only shows (and slides out) while this strip is selected.
enum LayoutMode {TALL, COMPACT}
const SIDE_PANE_ANIM_DURATION := 0.2

## Height of the parent-colored bar above nested strips in this strip's fold-out. Nested strip
## headers shrink by the same amount so every header ends on the same row.
@export var children_header_height := 12:
	set(value):
		children_header_height = value
		if is_inside_tree() and children_slide and not Engine.is_editor_hint():
			children_slide.apply_header_height(value)

## Nested headers never shrink below this, so the title stays readable.
const MIN_NESTED_HEADER_HEIGHT := 24.0

## Header height from the scene, before nesting shrinks it.
var _base_header_height := 0.0

@export var size_mode: SizeMode = SizeMode.MEDIUM:
	set = set_size_mode

@export var strip_layout_mode: LayoutMode = LayoutMode.TALL:
	set = set_strip_layout_mode

## Width of the SidePane when slid open (Compact + selected). SidePane is a plain Control so
## its content never forces the width; this value (animated) is the only thing that sizes it.
@export var side_pane_width := 180.0
var _side_pane_tween: Tween

## 0..1 fraction of the fold-out's width currently revealed; tweened when toggling.
var _children_reveal := 0.0
var _children_tween: Tween

## Main/SidePane VSplit offset (device list vs sends/meter divider), shared across every strip.
## Dragging it on one strip applies to all others. -1 means "use the scene default".
static var _shared_vsplit_offset := -1

var _peak_readout: Label

func _ready():
	if header:
		_base_header_height = header.custom_minimum_size.y
	if side_pane:
		side_pane.custom_minimum_size.x = 0
		side_pane.clip_contents = true
	_update_container_sizing()
	_apply_layout_mode()
	_apply_selection_layout()
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
	_setup_peak_readout()
	
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	if title:
		title.value_changed.connect(_on_title_value_changed)

	if main_vsplit:
		main_vsplit.dragged.connect(_on_vsplit_dragged)
	if side_vsplit:
		side_vsplit.dragged.connect(_on_vsplit_dragged)
	_apply_shared_vsplit_offset()

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
			children_clip.visible = false

	# output routing menu
	if output_menu_buttton:
		output_menu_buttton.get_popup().id_pressed.connect(_on_output_menu_selected)
		# Master lists the running device's output pairs, which change with the audio settings.
		output_menu_buttton.about_to_popup.connect(_rebuild_output_menu)

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
	_apply_nested_header_height()
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

	# Master has no sends target (nothing to route to); keep it hidden
	# regardless of the mixer-wide "show sends" toggle.
	if channel.is_master and sends:
		sends.remove_from_group("mixer_channel_sends")
		sends.visible = false


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
		if not is_resizing:
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

func _start_resize():
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
	else:
		# Not resizing: nothing to poll, stop ticking.
		set_process(false)

func _stop_resize():
	is_resizing = false
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_process(false)

func _on_title_value_changed(new_name : String) -> void:
	channel.set_name(new_name)
	# Show the final name: it may have been suffixed ("Drums 2") to stay unique.
	title.set_value(channel.name)

func _on_header_gui_input(event : InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if foldout_toggle and foldout_toggle.visible and foldout_toggle.get_global_rect().has_point(get_global_mouse_position()):
			return
		var mouse_event = event as InputEventMouseButton

		if mouse_event.pressed:
			_request_mixer_selection(mouse_event.ctrl_pressed)


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


## Max-peak readout above the big meter. Clicking it or either meter's bars resets both meters.
func _setup_peak_readout() -> void:
	_peak_readout = Label.new()
	_peak_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_peak_readout.add_theme_font_size_override("font_size", 11)
	_peak_readout.mouse_filter = Control.MOUSE_FILTER_STOP
	_peak_readout.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_peak_readout.tooltip_text = "Max peak (click to reset)"
	big_meter.add_sibling(_peak_readout)
	big_meter.get_parent().move_child(_peak_readout, big_meter.get_index())
	_peak_readout.visible = big_meter.visible
	big_meter.visibility_changed.connect(func(): _peak_readout.visible = big_meter.visible)
	_peak_readout.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_reset_peak_memory())
	big_meter.peak_memory_reset_requested.connect(_reset_peak_memory)
	bottom_small_meter.peak_memory_reset_requested.connect(_reset_peak_memory)
	big_meter.max_peak_changed.connect(_on_max_peak_changed)
	_on_max_peak_changed(-INF)


func _reset_peak_memory() -> void:
	big_meter.reset_peak_memory()
	bottom_small_meter.reset_peak_memory()


func _on_max_peak_changed(db: float) -> void:
	if db == -INF:
		_peak_readout.text = "-inf"
		_peak_readout.remove_theme_color_override("font_color")
	else:
		_peak_readout.text = "%.1f" % db
		if db >= 0.0:
			_peak_readout.add_theme_color_override("font_color", big_meter.bar_color_clip)
		else:
			_peak_readout.remove_theme_color_override("font_color")


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


## Base width from the size mode: narrow has no floor, medium/wide are fixed floors.
func _base_width() -> int:
	match size_mode:
		SizeMode.NARROW:
			return NARROW_WIDTH
		SizeMode.WIDE:
			return WIDE_WIDTH
		_:
			return MEDIUM_BASE_WIDTH


## MainPane keeps the base width in every mode; the SidePane adds on top of it.
func _strip_min_width() -> int:
	return _base_width()


## Widen the selected strip and expose compact device parameters on it.
func _apply_selection_layout() -> void:
	if device_list:
		device_list.hide_parameters = not is_selected
	_update_side_pane()
	_update_size_for_mode()


## Cycle/apply the narrow-medium-wide base width.
func set_size_mode(m: SizeMode) -> void:
	size_mode = m
	_update_size_for_mode()


## Switch Tall/Compact layout: Compact moves DeviceList/Sends into the SidePane, which only
## shows (and slides out) while the strip is selected. Tall keeps them in the main column.
func set_strip_layout_mode(m: LayoutMode) -> void:
	strip_layout_mode = m
	if is_inside_tree():
		_apply_layout_mode()
	_update_size_for_mode()


## Propagate a manual VSplit drag (MainPane or SidePane) to every mixer strip.
func _on_vsplit_dragged(offset: int) -> void:
	_shared_vsplit_offset = offset
	get_tree().call_group("mixer_channel", "_apply_shared_vsplit_offset")


## Apply the shared VSplit offset (from whichever strip was last dragged) to this strip.
func _apply_shared_vsplit_offset() -> void:
	if _shared_vsplit_offset < 0:
		return
	if main_vsplit and main_vsplit.split_offset != _shared_vsplit_offset:
		main_vsplit.split_offset = _shared_vsplit_offset
	if side_vsplit and side_vsplit.split_offset != _shared_vsplit_offset:
		side_vsplit.split_offset = _shared_vsplit_offset


## Move DeviceList/Sends between MainPane and SidePane to match the current layout mode.
func _apply_layout_mode() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if _side_pane_tween and _side_pane_tween.is_valid():
		_side_pane_tween.kill()
	match strip_layout_mode:
		LayoutMode.TALL:
			_reparent_into(device_list, main_vsplit)
			_reparent_into(sends, main_vsplit)
			if side_pane:
				side_pane.visible = false
				side_pane.custom_minimum_size.x = 0
		LayoutMode.COMPACT:
			_reparent_into(device_list, side_vsplit)
			_reparent_into(sends, side_vsplit)
			_update_side_pane()


## Move `node` under `new_parent`, preserving it (no-op if already there).
func _reparent_into(node: Control, new_parent: Node) -> void:
	if node == null or new_parent == null or node.get_parent() == new_parent:
		return
	var old_parent := node.get_parent()
	if old_parent:
		old_parent.remove_child(node)
	new_parent.add_child(node)


## Slide the SidePane open (Compact + selected) or closed, animating its width.
func _update_side_pane() -> void:
	if side_pane == null or Engine.is_editor_hint() or not is_inside_tree():
		return
	var should_show := strip_layout_mode == LayoutMode.COMPACT and is_selected
	# Skip in the common Tall-mode case: already collapsed and staying that way.
	if not should_show and side_pane.custom_minimum_size.x <= 0.0 and not side_pane.visible:
		return
	if _side_pane_tween and _side_pane_tween.is_valid():
		_side_pane_tween.kill()
	if should_show:
		side_pane.visible = true
	_side_pane_tween = create_tween()
	var target := side_pane_width if should_show else 0.0
	_side_pane_tween.tween_method(_set_side_pane_width, side_pane.custom_minimum_size.x, target, SIDE_PANE_ANIM_DURATION)
	if not should_show:
		_side_pane_tween.finished.connect(_hide_side_pane)


func _set_side_pane_width(w: float) -> void:
	if side_pane:
		side_pane.custom_minimum_size.x = w
	_update_size_for_mode()


func _hide_side_pane() -> void:
	if side_pane:
		side_pane.visible = false


func _update_size_for_mode() -> void:
	"""Update custom_minimum_size based on size mode, layout mode, selection, and children."""
	custom_minimum_size.x = _total_min_width()
	if main_pane:
		main_pane.custom_minimum_size.x = _strip_min_width()
	_update_children_clip()
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


## Strip floor plus the SidePane's current (possibly mid-animation) width and expanded nested children.
func _total_min_width() -> int:
	var w := _strip_min_width()
	if side_pane:
		w += maxi(int(side_pane.custom_minimum_size.x), 0)
	if children_clip and children_clip.visible:
		w += maxi(int(children_clip.custom_minimum_size.x), 0)
	return w


## Size the clip to the revealed fraction of the fold-out, and pin the fold-out at its full width.
func _update_children_clip() -> void:
	if children_clip == null or children_slide == null:
		return
	var full: float = children_slide.get_combined_minimum_size().x
	children_slide.offset_left = 0.0
	children_slide.offset_right = full
	children_clip.custom_minimum_size.x = full * _children_reveal


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


## Master's choices: the stereo output pairs of the running audio device (AudioConfig). A saved
## pair the device lacks stays listed, marked, and plays on 1/2 until a device has it.
func _populate_device_outputs(popup: PopupMenu) -> void:
	var pairs := AudioConfig.output_pairs()
	for pair in pairs:
		var output_id := AudioConfig.HARDWARE_OUTPUT_BASE + pair
		popup.add_check_item(AudioConfig.output_label(output_id), output_id)
		if channel.device_output_id == output_id:
			popup.set_item_checked(popup.get_item_count() - 1, true)
	var current := channel.device_output_id
	if current >= AudioConfig.HARDWARE_OUTPUT_BASE + pairs:
		popup.add_check_item("%s (not on this device)" % AudioConfig.output_label(current), current)
		popup.set_item_checked(popup.get_item_count() - 1, true)


func _on_output_menu_selected(item_id: int) -> void:
	"""Handle output menu selection."""
	if not channel or not project:
		return
	if channel.route_locked():
		return

	# Master channel: set device output
	if channel.is_master:
		channel.set_device_output(item_id)
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
		return AudioConfig.output_label(channel.device_output_id)

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
	_sync_children_slide(true)


## Show the fold-out for GROUP channels or any channel that already has children.
func _shows_children_foldout() -> bool:
	if channel == null:
		return false
	return channel.is_group_channel or not channel.child_channel_ids.is_empty()


## Update fold-out chrome, spawn nested strips, and refresh this strip's width.
## `animate` slides the fold-out open/closed; otherwise it snaps (binding, hierarchy changes).
func _sync_children_slide(animate := false) -> void:
	var show_fold := _shows_children_foldout()
	var expanded := show_fold and channel != null and channel.is_children_expanded

	if foldout_toggle:
		foldout_toggle.visible = show_fold
		foldout_toggle.set_pressed_no_signal(expanded)

	if children_slide:
		if show_fold and channel:
			children_slide.bind_to_parent(channel, project, self)
		_slide_children(expanded, animate)

	_update_size_for_mode()


## Reveal or hide the fold-out, tweening `_children_reveal` when `animate` is set.
func _slide_children(expanded: bool, animate: bool) -> void:
	if children_clip == null or Engine.is_editor_hint():
		return
	var target := 1.0 if expanded else 0.0
	if _children_tween and _children_tween.is_valid():
		_children_tween.kill()
	if expanded:
		children_clip.visible = true
	if not animate or not is_inside_tree() or is_equal_approx(_children_reveal, target):
		_set_children_reveal(target)
		if not expanded:
			children_clip.visible = false
		return
	_children_tween = create_tween()
	_children_tween.tween_method(_set_children_reveal, _children_reveal, target, SIDE_PANE_ANIM_DURATION)
	if not expanded:
		_children_tween.finished.connect(_hide_children_clip)


func _set_children_reveal(r: float) -> void:
	_children_reveal = r
	_update_size_for_mode()


func _hide_children_clip() -> void:
	if children_clip:
		children_clip.visible = false
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
	"""Start a strip drag from the header. Nothing moves until the drop (see MixerChannelDropTarget)."""
	if Engine.is_editor_hint() or is_resizing:
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
	# Dim in place (modulate never changes layout) until the drag ends.
	modulate.a = 0.5
	drag_data.drag_completed.connect(_on_strip_drag_completed)
	logger.info("Started strip drag: ", channel.name)
	return drag_data


## Undim once our strip drag ends (method callable: auto-disconnects if a drop re-spawned us).
func _on_strip_drag_completed(_data: MixerChannelDrag) -> void:
	modulate.a = 1.0


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Accept a mixer strip drag (resolved by the Mixer from the pointer), a device drop on the
	device list, or a device/SFZ asset appended to the channel."""
	if data is MixerChannelDrag:
		var mixer := _find_mixer()
		return mixer != null and mixer.can_drop_channel_drag(data as MixerChannelDrag)
	if device_list and DeviceDropTarget.resolve_for(device_list, data).is_valid():
		return true
	return channel != null and data is Asset and DeviceDropUtil.can_drop_asset_on_channel(channel, data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a mixer strip (nest / insert / un-nest), device, or SFZ file on this strip."""
	if data is MixerChannelDrag:
		var mixer := _find_mixer()
		if mixer:
			mixer.drop_channel_drag(data as MixerChannelDrag)
		return
	if device_list:
		var target := DeviceDropTarget.resolve_for(device_list, data)
		if target.is_valid():
			target.commit(data)
			return
	if channel and data is Asset:
		DeviceDropUtil.drop_asset(channel, data, -1, null)


## Shrink the header by every enclosing fold-out's top offset so header bottoms line up.
func _apply_nested_header_height() -> void:
	if header == null or _base_header_height <= 0.0:
		return
	# Every nesting level also adds a strip panel's top margin inside the fold-out.
	var style := get_theme_stylebox("panel")
	var strip_margin := style.get_margin(SIDE_TOP) if style else 0.0
	var offset := 0.0
	var n := get_parent()
	while n:
		if n is MixerChannelChildren:
			offset += (n as MixerChannelChildren).get_children_top_offset() + strip_margin
		n = n.get_parent()
	header.custom_minimum_size.y = maxf(_base_header_height - offset, MIN_NESTED_HEADER_HEIGHT)


## Global rect of the strip itself, excluding the fold-out.
func get_strip_column_rect() -> Rect2:
	var column := get_node_or_null("HBox/VBox") as Control
	return column.get_global_rect() if column else get_global_rect()
