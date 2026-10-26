## One lane of the MIDI editor's automation pane: a resize grip on top, then a header column
## (name, value range, bypass, close) and the editable ClipAutomationLaneRow (spec 055).
## Built from AutomationPaneLane.tscn. The height is the open lane's own (it is stored in
## Track.clip_editor_lanes by the pane); the lane's Arranger height is never touched.
class_name AutomationPaneLane extends PanelContainer

## The close button: closes the lane in the pane only, the lane itself stays.
signal close_requested(lane: AutomationLane)
## The grip was released at `height`; the pane stores it.
signal height_changed(lane: AutomationLane, height: float)

@onready var resize_grip: Control = %ResizeGrip
@onready var header: PanelContainer = %Header
@onready var name_label: Label = %NameLabel
@onready var max_label: Label = %MaxLabel
@onready var min_label: Label = %MinLabel
@onready var bypass_button: Button = %BypassButton
@onready var close_button: Button = %CloseButton
## A ClipAutomationLaneRow. Untyped: a class_name added this session may not be in the cache yet.
@onready var row = %Row

var lane: AutomationLane = null
var track: Track = null
var _height: float = ValueLane.DEFAULT_HEIGHT
var _grip_dragging := false
var _grip_press_y := 0.0
var _grip_press_height := 0.0


func _ready() -> void:
	close_button.pressed.connect(func(): close_requested.emit(lane))
	bypass_button.toggled.connect(_on_bypass_toggled)
	resize_grip.gui_input.connect(_on_grip_input)
	_refresh_header()


## Show `p_lane` of `p_track` in `editor`'s time axis, at `p_height`. `manager` is the pane's
## point selection.
func setup(p_lane: AutomationLane, p_track: Track, editor: MidiEditor, manager: AutomationPointSelectionManager, p_height: float) -> void:
	lane = p_lane
	track = p_track
	row.bind_to_clip_editor(lane, track, editor, manager)
	lane.bypass_changed.connect(_on_lane_flag_changed)
	lane.resolved_changed.connect(_on_lane_flag_changed)
	set_lane_height(p_height)
	if is_node_ready():
		_refresh_header()


func set_header_width(w: float) -> void:
	header.custom_minimum_size.x = w


func lane_height() -> float:
	return _height


## The smallest the row can be: never below what the header column needs, or the row would be
## taller than its stored height and a grip drag would start from the wrong place.
func min_row_height() -> float:
	return maxf(ValueLane.MIN_HEIGHT, header.get_combined_minimum_size().y)


func set_lane_height(h: float) -> void:
	_height = clampf(h, ValueLane.MIN_HEIGHT, ValueLane.MAX_HEIGHT)
	row.set_row_height(maxf(_height, min_row_height()) if is_node_ready() else _height)


func _refresh_header() -> void:
	if lane == null or lane.target == null:
		return
	var channel: Channel = track.get_linked_channel() if track else null
	var label := lane.target.display_name(channel)
	if not lane.resolved:
		label = "%s (missing)" % label
	name_label.text = label
	name_label.tooltip_text = label
	max_label.text = lane.target.format_value(channel, 1.0)
	min_label.text = lane.target.format_value(channel, 0.0)
	bypass_button.set_pressed_no_signal(lane.bypassed)
	name_label.modulate.a = 0.5 if lane.bypassed else 1.0


func _on_lane_flag_changed(_value: bool) -> void:
	_refresh_header()


func _on_bypass_toggled(bypassed: bool) -> void:
	if lane == null:
		return
	HistoryUtil.execute_property(
		"Bypass Lane" if bypassed else "Enable Lane",
		lane, "set_bypassed", not bypassed, bypassed
	)


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_grip_dragging = event.pressed
		_grip_press_y = event.global_position.y
		_grip_press_height = row.size.y
		if not event.pressed and lane:
			height_changed.emit(lane, _height)
		accept_event()
	elif event is InputEventMouseMotion and _grip_dragging:
		# The grip is the lane's top edge and the pane grows upwards from the bottom of the
		# editor split, so dragging up grows the lane and the edge stays under the pointer.
		set_lane_height(_grip_press_height - (event.global_position.y - _grip_press_y))
		accept_event()
