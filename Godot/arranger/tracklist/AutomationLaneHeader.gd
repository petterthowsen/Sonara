# AutomationLaneHeader.gd
# The tracklist-side row for one automation lane: a `Device / Param` label, a bypass toggle, a
# delete button, and the same bottom-gutter resize gesture as TrackItem - except that it writes
# `lane.height` instead of `track.height` (REQ-013, REQ-017).
#
# Layout lives in AutomationLaneHeader.tscn; instantiate that scene rather than calling `new()`.
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
## The track's enclosing folders/groups, outermost first; drawn as the left-edge inset stripes.
var _ancestors: Array[Track] = []

@onready var _label: Label = %Label
@onready var _bypass_button: Button = %BypassButton
@onready var _delete_button: Button = %DeleteButton
## The row's content, kept so `_content_min_height()` can measure it without the ratchet of the
## node's own `custom_minimum_size` (which is the current `lane.height`).
@onready var _content: HBoxContainer = %Content

var _is_resizing: bool = false
var _resize_start_y: float = 0.0
var _resize_start_height: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# A theme font or button change can raise the content floor: keep the lane height above it.
	_content.minimum_size_changed.connect(_clamp_lane_height)
	_refresh()


## Paint the enclosing folders' inset stripes, same as the TrackItem above this row.
func _draw() -> void:
	NestingStripes.draw(self, _ancestors, size.y)
	# Separates stacked lanes.
	draw_rect(Rect2(0.0, size.y - 1.0, size.x, 1.0), Color(0, 0, 0, 1))


## Release the lane/track signal connections when the row is freed. NOTIFICATION_PREDELETE rather
## than _exit_tree, matching TrackItem: DockHost reparents the arranger.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


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
	_set_ancestors([])
	lane = null
	track = null
	current_project = null


func _refresh() -> void:
	if lane == null or _label == null:
		return

	_clamp_lane_height()
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
## level deeper so a lane reads as belonging to the track above it: the stripes of the
## ancestors and of the track itself (drawn in _draw) continue down the left edge.
func _update_style() -> void:
	var style := get_theme_stylebox("panel") as StyleBoxFlat
	if style == null or track == null:
		return
	var c := Utils.automation_lane_color(track.color, lane.resolved)
	style.bg_color = c

	# The owning track's stripe is the last one, so the lane sits inside its track.
	var chain := NestingStripes.ancestors_of(track, current_project)
	chain.append(track)
	_set_ancestors(chain)
	style.border_width_left = _ancestors.size() * NestingStripes.WIDTH
	# An explicit margin overrides the border-width default, so add the reserved inset back or the
	# label draws over the nesting stripes.
	style.content_margin_left = style.border_width_left + 6.0
	queue_redraw()


## Track the ancestor chain so a color change or reparent anywhere above restyles this row.
func _set_ancestors(chain: Array[Track]) -> void:
	NestingStripes.rebind(_ancestors, chain, _on_ancestor_changed)
	_ancestors = chain


# ============================================================================
# RESIZE GESTURE (mirrors TrackItem's bottom gutter, writing lane.height)
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if _is_in_resize_gutter():
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and not _is_resizing:
				_is_resizing = true
				_resize_start_y = get_global_mouse_position().y
				_resize_start_height = lane.height if lane else int(custom_minimum_size.y)
				accept_event()
			elif event.is_released() and _is_resizing:
				_is_resizing = false
				accept_event()


## True while the pointer sits in the bottom-edge resize band.
func _is_in_resize_gutter() -> bool:
	return get_local_mouse_position().y >= size.y - RESIZE_GUTTER


## Smallest height this row can realize: its content minimum plus the panel stylebox, never below
## `MIN_HEIGHT`. Measured from the content directly (not `get_combined_minimum_size()`, which
## already includes the current `custom_minimum_size` = `lane.height` and would ratchet).
func _content_min_height() -> int:
	var content_min := MIN_HEIGHT
	if _content:
		content_min = maxi(content_min, int(_content.get_combined_minimum_size().y))
	var stylebox := get_theme_stylebox("panel") as StyleBox
	if stylebox:
		content_min += int(stylebox.get_minimum_size().y)
	return content_min


## Raise `lane.height` to this row's content floor. Idempotent: the follow-up `height_changed`
## finds `lane.height` already at the floor and stops.
func _clamp_lane_height() -> void:
	if lane == null:
		return
	var floor := _content_min_height()
	if lane.height < floor:
		lane.set_height(floor)


## Keep the resize cursor truthful for the whole band (the buttons swallow motion, so deriving
## the shape in _gui_input alone left it stuck on the last value).
func _update_resize_cursor() -> void:
	if _is_in_resize_gutter() and get_global_rect().has_point(get_global_mouse_position()):
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _is_resizing:
		_update_resize_cursor()

	if not _is_resizing:
		return
	if event is InputEventMouseMotion:
		var delta_y := get_global_mouse_position().y - _resize_start_y
		var new_height := maxi(_content_min_height(), _resize_start_height + int(delta_y))
		if lane:
			lane.set_height(new_height)
		else:
			custom_minimum_size.y = new_height
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_released():
		_is_resizing = false
		_update_resize_cursor()
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
	# `AutomationLane.set_height` only knows its 20px minimum, not what this row's label and
	# buttons need. Push the content floor back into the model so the timeline lane row (which
	# sizes from `lane.height`) is never shorter than this header.
	_clamp_lane_height()


func _on_lane_resolved_changed(_resolved: bool) -> void:
	_refresh()


func _on_track_color_changed(_c: Color) -> void:
	_update_style()


func _on_track_parent_changed(_parent_id: int) -> void:
	_update_style()


func _on_ancestor_changed(_value) -> void:
	_update_style()
