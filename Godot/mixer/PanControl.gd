# PanControl.gd
# Channel pan strip for the four pan modes: a single slider (Balance, Mono) or a dual slider
# (Dual, Combined), with a right-click mode menu. Reads and writes the bound Channel through its
# setters and records undo as set_pan_state snapshots.
class_name PanControl extends PanelContainer

@onready var _single_slider: HorSlider = $HSlider
@onready var _dual_slider: HDualSlider = $DualPanSlider
@onready var _mode_popup: PopupMenu = $PanModePopup
@onready var _value_label: Label = $ValueLabel

var channel: Channel = null
var _drag_start_pan := 0.0


func _ready() -> void:
	_single_slider.value_changed.connect(_on_single_slider_changed)
	_dual_slider.values_changed.connect(_on_dual_values_changed)
	_dual_slider.pair_dragged.connect(_on_pair_dragged)
	_dual_slider.handle_dragged.connect(_on_handle_dragged)
	_single_slider.drag_started.connect(_on_drag_started)
	_single_slider.drag_ended.connect(_on_drag_ended)
	_dual_slider.drag_started.connect(_on_drag_started)
	_dual_slider.drag_ended.connect(_on_drag_ended)
	gui_input.connect(_on_gui_input)
	_mode_popup.id_pressed.connect(_on_mode_selected)
	_value_label.visible = false
	_value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	if _value_label.visible:
		_update_value_label()


## Apply `mutate` to the channel and record the change. Mergeable so a drag is one undo step.
func _record_drag(mutate: Callable) -> void:
	var old_state := channel.get_pan_state()
	mutate.call()
	var cmd := PropertyCommand.new("Set Pan", channel, "set_pan_state", old_state, channel.get_pan_state())
	cmd.set_mergeable(true)
	HistoryUtil.record(cmd)


## Slider values are -100..100; the channel stores -1..1.
func _on_single_slider_changed(value: float) -> void:
	if channel == null:
		return
	_record_drag(func(): channel.set_pan(value / 100.0))


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


## Refresh the tooltip label from the channel.
func _update_value_label() -> void:
	if channel == null:
		return
	match channel.pan_mode:
		Channel.PanMode.STEREO_DUAL:
			_value_label.text = "L %s / R %s" % [_format_pan(channel.pan_left), _format_pan(channel.pan_right)]
		Channel.PanMode.STEREO_COMBINED:
			_value_label.text = "%s, W %d%%" % [_format_pan(channel.pan), roundi(channel.pan_width * 100.0)]
		_:
			_value_label.text = _format_pan(channel.pan)


func _format_pan(p: float) -> String:
	if is_zero_approx(p):
		return "C"
	return "%dL" % roundi(-p * 100.0) if p < 0.0 else "%dR" % roundi(p * 100.0)


func _on_drag_started() -> void:
	if channel == null:
		return
	_drag_start_pan = channel.pan
	_update_value_label()
	_value_label.visible = true


func _on_drag_ended() -> void:
	_value_label.visible = false


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
