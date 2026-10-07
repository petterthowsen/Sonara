# PanControl.gd
# Channel pan strip for the four pan modes: a single slider (Balance, Mono) or a dual slider
# (Dual, Combined), with a right-click mode menu. Reads and writes the bound Channel through its
# setters and records undo as set_pan_state snapshots. The value readout is a plain overlay
# drawn over the slider, on the side away from the knob, while it is hovered or dragged, so a long value never widens the strip.
class_name PanControl extends PanelContainer

@onready var _single_slider: HorSlider = $HSlider
@onready var _dual_slider: HDualSlider = $DualPanSlider
@onready var _mode_popup: PopupMenu = $PanModePopup

## Pixels kept between the knob and the readout.
const KNOB_CLEARANCE := 6.0

var channel: Channel = null
var _drag_start_pan := 0.0
var _value_tip: ValueTooltip
var _hovered := false
var _dragging := false
## Where the pointer sits on the dual slider (HDualSlider.pick_at); picks the Combined readout.
var _hover_part := HDualSlider.DragMode.NONE


func _ready() -> void:
	_single_slider.value_changed.connect(_on_single_slider_changed)
	_dual_slider.values_changed.connect(_on_dual_values_changed)
	_dual_slider.pair_dragged.connect(_on_pair_dragged)
	_dual_slider.handle_dragged.connect(_on_handle_dragged)
	_single_slider.reset_requested.connect(_on_single_slider_reset)
	_single_slider.drag_started.connect(_on_drag_started)
	_single_slider.drag_ended.connect(_on_drag_ended)
	_dual_slider.drag_started.connect(_on_drag_started)
	_dual_slider.drag_ended.connect(_on_drag_ended)
	gui_input.connect(_on_gui_input)
	_mode_popup.id_pressed.connect(_on_mode_selected)
	for slider: Control in [_single_slider, _dual_slider]:
		slider.mouse_entered.connect(_set_hovered.bind(true))
		slider.mouse_exited.connect(_set_hovered.bind(false))
	_dual_slider.gui_input.connect(_on_dual_slider_input)
	_value_tip = ValueTooltip.attach(self)
	_value_tip.set_plain(true)
	set_process(false)
	_refresh()


## Show `p_channel`'s pan (null clears the binding).
func bind_to_channel(p_channel: Channel) -> void:
	_unbind()
	channel = p_channel
	if channel:
		channel.pan_mode_changed.connect(_on_channel_pan_mode_changed)
		channel.pan_changed.connect(_on_channel_pan_changed)
	_refresh()


func _unbind() -> void:
	if channel:
		if channel.pan_mode_changed.is_connected(_on_channel_pan_mode_changed):
			channel.pan_mode_changed.disconnect(_on_channel_pan_mode_changed)
		if channel.pan_changed.is_connected(_on_channel_pan_changed):
			channel.pan_changed.disconnect(_on_channel_pan_changed)
	channel = null


## Not _exit_tree(): DockHost reparents docks (see godot-architecture.mdc, Signal lifecycle).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and _value_tip and not is_visible_in_tree():
		_hovered = false
		_dragging = false
		_refresh_value_tip()


## Balance and Mono use the single slider; Dual and Combined use the dual slider.
func _uses_dual_slider() -> bool:
	return channel.pan_mode == Channel.PanMode.STEREO_DUAL or channel.pan_mode == Channel.PanMode.STEREO_COMBINED


## The dual slider's handles in Combined: position -/+ width, clamped to the range.
func _combined_handles() -> Vector2:
	return Vector2(clampf(channel.pan - channel.pan_width, -1.0, 1.0), clampf(channel.pan + channel.pan_width, -1.0, 1.0))


## Match slider visibility, values and the menu check marks to the channel.
func _refresh() -> void:
	if channel == null or not is_node_ready():
		return
	var dual_slider := _uses_dual_slider()
	_single_slider.visible = not dual_slider
	_dual_slider.visible = dual_slider
	if channel.pan_mode == Channel.PanMode.STEREO_COMBINED:
		var handles := _combined_handles()
		_dual_slider.set_values_no_signal(handles.x * 100, handles.y * 100)
	elif dual_slider:
		_dual_slider.set_values_no_signal(channel.pan_left * 100, channel.pan_right * 100)
	else:
		_single_slider.set_value_no_signal(channel.pan * 100)
	for i in _mode_popup.item_count:
		_mode_popup.set_item_checked(i, _mode_popup.get_item_id(i) == channel.pan_mode)
	_refresh_value_tip()


## Apply `mutate` to the channel and record the change. Mergeable so a drag is one undo step.
## With several channels selected the change applies to all of them (see ChannelMultiEdit).
func _record_drag(mutate: Callable, kind := ValueEditKind.Kind.DRAG) -> void:
	var old_state := channel.get_pan_state()
	mutate.call()
	var peers := ChannelMultiEdit.peers_of(channel, self)
	if not peers.is_empty():
		ChannelMultiEdit.apply_pan(channel, old_state, channel.get_pan_state(), peers, kind)
		return
	var cmd := PropertyCommand.new("Set Pan", channel, "set_pan_state", old_state, channel.get_pan_state())
	cmd.set_mergeable(true)
	HistoryUtil.record(cmd)


## Slider values are -100..100; the channel stores -1..1.
func _on_single_slider_changed(value: float) -> void:
	if channel == null:
		return
	_record_drag(func(): channel.set_pan(value / 100.0), _single_slider.last_edit_kind)


## Ctrl/Cmd-click on the slider. With a multi-selection, the whole selection re-centers, even
## when this channel already was (then value_changed never fired).
func _on_single_slider_reset() -> void:
	if channel == null or ChannelMultiEdit.peers_of(channel, self).is_empty():
		return
	_record_drag(func(): channel.set_pan(0.0), ValueEditKind.Kind.RESET)


func _on_dual_values_changed(left: float, right: float) -> void:
	if channel == null or channel.pan_mode != Channel.PanMode.STEREO_DUAL:
		return
	_record_drag(func(): channel.set_pan_dual(left / 100.0, right / 100.0))


## Combined: the fill moves the position by the drag offset. Computed from the model, not the
## slider's clamped handles, so the width survives a handle pinned at an edge.
func _on_pair_dragged(delta: float) -> void:
	if channel == null or channel.pan_mode != Channel.PanMode.STEREO_COMBINED:
		return
	_record_drag(func(): channel.set_pan(_drag_start_pan + delta / 100.0))


## Combined: a handle sets the width, measured from the position.
func _on_handle_dragged(which: int, value: float) -> void:
	if channel == null or channel.pan_mode != Channel.PanMode.STEREO_COMBINED:
		return
	var v := value / 100.0
	var width := channel.pan - v if which == HDualSlider.DragMode.A_VALUE else v - channel.pan
	_record_drag(func(): channel.set_pan_width(width))


## The readout for the current mode. Combined shows only the part under the pointer: the width
## on a handle (or the empty space beside one), the position on the fill.
func get_value_text() -> String:
	if channel == null:
		return ""
	match channel.pan_mode:
		Channel.PanMode.STEREO_DUAL:
			return "%s / %s" % [_format_pan(channel.pan_left), _format_pan(channel.pan_right)]
		Channel.PanMode.STEREO_COMBINED:
			var part := _dual_slider.get_drag_mode() if _dragging else _hover_part
			if part == HDualSlider.DragMode.A_VALUE or part == HDualSlider.DragMode.B_VALUE:
				return "W: %d" % roundi(channel.pan_width * 100.0)
	return _format_pan(channel.pan)


## Show the readout over the slider while hovered or dragged; hide it otherwise.
func _refresh_value_tip() -> void:
	if _value_tip == null:
		return
	var should_show := channel != null and (_hovered or _dragging) and is_visible_in_tree()
	_value_tip.visible = should_show
	set_process(should_show)
	if should_show:
		_value_tip.set_text(get_value_text())
		_place_value_tip()


## Follow the strip while visible (scroll containers move it).
func _process(_delta: float) -> void:
	_place_value_tip()


## Where the knob (the middle of the handles) sits along the strip, 0 = left edge, 1 = right edge.
func _knob_fraction() -> float:
	var pan := channel.pan
	match channel.pan_mode:
		Channel.PanMode.STEREO_DUAL:
			pan = (channel.pan_left + channel.pan_right) * 0.5
		Channel.PanMode.STEREO_COMBINED:
			var handles := _combined_handles()
			pan = (handles.x + handles.y) * 0.5
	return clampf((pan + 1.0) * 0.5, 0.0, 1.0)


## Center the readout in the half of the strip the knob is not in, so it never covers the knob.
func _place_value_tip() -> void:
	if channel == null:
		return
	var rect := get_global_rect()
	var knob_x := rect.position.x + rect.size.x * _knob_fraction()
	if knob_x > rect.get_center().x:
		rect.end.x = knob_x - KNOB_CLEARANCE
	else:
		rect.position.x = knob_x + KNOB_CLEARANCE
	_value_tip.place_over(rect)


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_refresh_value_tip()


func _on_dual_slider_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _dragging:
		var part := _dual_slider.pick_at(event.position)
		if part != _hover_part:
			_hover_part = part
			_refresh_value_tip()


## Signed percent: -100 is hard left, 100 hard right.
func _format_pan(p: float) -> String:
	return str(roundi(p * 100.0))


func _on_drag_started() -> void:
	if channel == null:
		return
	_drag_start_pan = channel.pan
	_dragging = true
	_refresh_value_tip()


func _on_drag_ended() -> void:
	_dragging = false
	# The pointer may rest on another part than it pressed; motion updates it only when it moves.
	_hover_part = _dual_slider.pick_at(_dual_slider.get_local_mouse_position())
	_refresh_value_tip()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_mode_popup.popup(Rect2(global_position, Vector2.ZERO))


func _on_mode_selected(pan_mode_id: int) -> void:
	if channel == null:
		return
	if pan_mode_id == channel.pan_mode:
		return
	# One non-mergeable command, so a mode change never merges into a drag.
	var old_state := channel.get_pan_state()
	var new_state := Channel.convert_pan_state(old_state, pan_mode_id as Channel.PanMode)
	HistoryUtil.execute(PropertyCommand.new("Set Pan Mode", channel, "set_pan_state", old_state, new_state))


func _on_channel_pan_mode_changed(_pan_mode: Channel.PanMode) -> void:
	_refresh()


func _on_channel_pan_changed(_pan_left: float, _pan_right: float = 0.0) -> void:
	_refresh()
