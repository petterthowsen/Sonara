# AutomationLaneHeader.gd
# The tracklist-side row for one automation lane: a `Device / Param` label, a bypass toggle, a
# delete button, and the same bottom-gutter resize gesture as TrackItem - except that it writes
# `lane.height` instead of `track.height` (REQ-013, REQ-017).
#
# Built in code rather than from a .tscn: nothing authors this row in the editor, and the timeline
# side (AutomationLaneRow) is code-built too, so keeping both in one file each keeps the two
# halves of a row readable side by side. `TimelineTrack` is instantiated the same way.
class_name AutomationLaneHeader extends PanelContainer

static var logger := Log.make("AutomationLaneHeader")

## Bypass/delete are routed up rather than applied here so TrackList owns the history entry.
signal bypass_toggled(lane: AutomationLane, bypassed: bool)
signal delete_requested(lane: AutomationLane)

const RESIZE_GUTTER := 4.0
const MIN_HEIGHT := 20

var lane: AutomationLane = null
var track: Track = null
var current_project: Project = null

var _label: Label = null
var _bypass_button: Button = null
var _delete_button: Button = null

var _is_resizing: bool = false
var _resize_start_y: float = 0.0
var _resize_start_height: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_build_ui()
	_refresh()


## Release the lane/track signal connections when the row is freed. NOTIFICATION_PREDELETE rather
## than _exit_tree, matching TrackItem: DockHost reparents the arranger.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


func _build_ui() -> void:
	if _label != null:
		return

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.13, 0.13, 1.0)
	style.content_margin_left = 6.0
	style.content_margin_right = 4.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	_label = Label.new()
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_label.clip_text = true
	_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_label)

	_bypass_button = Button.new()
	_bypass_button.text = "B"
	_bypass_button.toggle_mode = true
	_bypass_button.focus_mode = Control.FOCUS_NONE
	_bypass_button.custom_minimum_size = Vector2(20, 16)
	_bypass_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bypass_button.tooltip_text = "Bypass this lane (the parameter returns to its base value)"
	_bypass_button.toggled.connect(_on_bypass_toggled)
	row.add_child(_bypass_button)

	_delete_button = Button.new()
	_delete_button.text = "x"
	_delete_button.focus_mode = Control.FOCUS_NONE
	_delete_button.custom_minimum_size = Vector2(20, 16)
	_delete_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_delete_button.tooltip_text = "Delete this lane"
	_delete_button.pressed.connect(_on_delete_pressed)
	row.add_child(_delete_button)


# ============================================================================
# BINDING
# ============================================================================

func bind_to_lane(p_lane: AutomationLane, p_track: Track, project: Project) -> void:
	_unbind()

	lane = p_lane
	track = p_track
	current_project = project

	if lane:
		lane.bypass_changed.connect(_on_lane_bypass_changed)
		lane.height_changed.connect(_on_lane_height_changed)
		lane.resolved_changed.connect(_on_lane_resolved_changed)
	if track:
		track.color_changed.connect(_on_track_color_changed)
		track.parent_changed.connect(_on_track_parent_changed)

	_build_ui()
	_refresh()


func _unbind() -> void:
	if lane:
		if lane.bypass_changed.is_connected(_on_lane_bypass_changed):
			lane.bypass_changed.disconnect(_on_lane_bypass_changed)
		if lane.height_changed.is_connected(_on_lane_height_changed):
			lane.height_changed.disconnect(_on_lane_height_changed)
		if lane.resolved_changed.is_connected(_on_lane_resolved_changed):
			lane.resolved_changed.disconnect(_on_lane_resolved_changed)
	if track:
		if track.color_changed.is_connected(_on_track_color_changed):
			track.color_changed.disconnect(_on_track_color_changed)
		if track.parent_changed.is_connected(_on_track_parent_changed):
			track.parent_changed.disconnect(_on_track_parent_changed)
	lane = null
	track = null
	current_project = null


func _refresh() -> void:
	if lane == null or _label == null:
		return

	custom_minimum_size.y = lane.height
	size.y = lane.height

	var channel: Channel = track.get_linked_channel() if track else null
	var label_text := lane.target.display_name(channel) if lane.target else "Unknown"
	# An unresolvable lane keeps every point but drives nothing; say so rather than showing a
	# parameter name that no longer exists (REQ-024).
	if not lane.resolved:
		_label.text = "%s (missing)" % label_text
		_label.modulate = Color(1.0, 0.55, 0.45)
	else:
		_label.text = label_text
		_label.modulate = Color(1, 1, 1, 0.85 if not lane.bypassed else 0.45)
	_label.tooltip_text = str(lane.target) if lane.target else ""

	_bypass_button.set_pressed_no_signal(lane.bypassed)
	_update_style()


## Tint the row from the track color (a shade darker than the track header) and indent it one
## level deeper so a lane reads as belonging to the track above it.
func _update_style() -> void:
	var style := get_theme_stylebox("panel") as StyleBoxFlat
	if style == null or track == null:
		return
	var c := Utils.display_color(track.color)
	c.v = clampf(c.v * 0.35, 0.0, 1.0)
	c.s = clampf(c.s * 0.5, 0.0, 1.0)
	if not lane.resolved:
		c = c.lerp(Color(0.35, 0.1, 0.1), 0.5)
	style.bg_color = c

	var nesting := track.get_nesting_level(current_project) if current_project else 0
	style.border_width_left = nesting * 12 + 10
	style.border_color = Utils.display_color(track.color)


# ============================================================================
# RESIZE GESTURE (mirrors TrackItem's bottom gutter, writing lane.height)
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	var mouse := get_local_mouse_position()

	if mouse.y >= size.y - RESIZE_GUTTER:
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and not _is_resizing:
				_is_resizing = true
				_resize_start_y = get_global_mouse_position().y
				_resize_start_height = lane.height if lane else int(custom_minimum_size.y)
				accept_event()
			elif event.is_released() and _is_resizing:
				_is_resizing = false
				accept_event()
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW


func _input(event: InputEvent) -> void:
	if not _is_resizing:
		return
	if event is InputEventMouseMotion:
		var delta_y := get_global_mouse_position().y - _resize_start_y
		var new_height := maxi(MIN_HEIGHT, _resize_start_height + int(delta_y))
		if lane:
			lane.set_height(new_height)
		else:
			custom_minimum_size.y = new_height
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
		_is_resizing = false
		accept_event()


# ============================================================================
# SIGNAL CALLBACKS
# ============================================================================

func _on_bypass_toggled(pressed: bool) -> void:
	if lane:
		bypass_toggled.emit(lane, pressed)


func _on_delete_pressed() -> void:
	if lane:
		delete_requested.emit(lane)


func _on_lane_bypass_changed(_bypassed: bool) -> void:
	_refresh()


func _on_lane_height_changed(new_height: int) -> void:
	custom_minimum_size.y = new_height
	size.y = new_height


func _on_lane_resolved_changed(_resolved: bool) -> void:
	_refresh()


func _on_track_color_changed(_c: Color) -> void:
	_update_style()


func _on_track_parent_changed(_parent_id: int) -> void:
	_update_style()
