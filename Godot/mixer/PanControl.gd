# PanControl.gd
# Channel pan strip: a combined slider or a dual L/R slider, with a right-click mode menu.
# Reads and writes the bound Channel through its setters and records undo for slider drags.
class_name PanControl extends PanelContainer

@onready var _combined_slider: HorSlider = $HSlider
@onready var _dual_slider: HDualSlider = $DualPanSlider
@onready var _mode_popup: PopupMenu = $PanModePopup

var channel: Channel = null


func _ready() -> void:
	_combined_slider.value_changed.connect(_on_slider_changed)
	_dual_slider.values_changed.connect(_on_slider_changed)
	gui_input.connect(_on_gui_input)
	_mode_popup.id_pressed.connect(_on_mode_selected)
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


## Match slider visibility, values and the menu check marks to the channel.
func _refresh() -> void:
	if channel == null or not is_node_ready():
		return
	var combined := channel.pan_mode == Channel.PanMode.STEREO_COMBINED
	_combined_slider.visible = combined
	_dual_slider.visible = not combined
	if combined:
		_combined_slider.set_value_no_signal(channel.pan * 100)
	else:
		_dual_slider.set_values_no_signal(channel.pan_left * 100, channel.pan_right * 100)
	_mode_popup.set_item_checked(0, combined)
	_mode_popup.set_item_checked(1, not combined)


## Slider values are -100..100; the channel stores -1..1. Mergeable so a drag is one undo step.
func _on_slider_changed(left: float, right: float = 0.0) -> void:
	if channel == null:
		return
	left /= 100.0
	right /= 100.0
	var dual := channel.pan_mode == Channel.PanMode.STEREO_DUAL
	var old_l := channel.pan_left if dual else channel.pan
	var old_r := channel.pan_right if dual else 0.0
	channel.set_pan(left, right)
	var cmd := PropertyCommand.new("Set Pan", channel, "set_pan", [old_l, old_r], [left, right])
	cmd.set_unpack_array(true).set_mergeable(true)
	HistoryUtil.record(cmd)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_mode_popup.popup(Rect2(global_position, Vector2.ZERO))


func _on_mode_selected(pan_mode_id: int) -> void:
	if channel == null:
		return
	if pan_mode_id == Channel.PanMode.STEREO_COMBINED:
		channel.set_pan_mode(Channel.PanMode.STEREO_COMBINED)
	else:
		channel.set_pan_mode(Channel.PanMode.STEREO_DUAL)


func _on_channel_pan_mode_changed(_pan_mode: Channel.PanMode) -> void:
	_refresh()


func _on_channel_pan_changed(_pan_left: float, _pan_right: float = 0.0) -> void:
	_refresh()
