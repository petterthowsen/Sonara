## Channel name with solo and mute toggles, shown beside the tab strip of a channel frame.
## Follows the channel both ways, with the same undo as the mixer strip.
class_name ChannelHeader extends HBoxContainer

var _channel: Channel = null
var _name_label: Label
var _solo: DragToggleButton
var _mute: DragToggleButton


func _init() -> void:
	name = "ChannelHeader"
	add_theme_constant_override("separation", 4)
	_name_label = Label.new()
	_name_label.clip_text = true
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.custom_minimum_size.x = 60
	add_child(_name_label)
	_solo = _make_toggle("S", "Solo", &"SoloButton", &"solo")
	_mute = _make_toggle("M", "Mute", &"MuteButton", &"mute")
	_solo.toggled.connect(_on_solo_toggled)
	_mute.toggled.connect(_on_mute_toggled)


func _make_toggle(text: String, tip: String, variation: StringName, group: StringName) -> DragToggleButton:
	var button := DragToggleButton.new()
	button.text = text
	button.tooltip_text = tip
	button.theme_type_variation = variation
	button.drag_group = group
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(22, 0)
	add_child(button)
	return button


func bind(channel: Channel) -> void:
	if channel == _channel:
		return
	_unbind()
	_channel = channel
	visible = channel != null
	if channel == null:
		return
	channel.name_changed.connect(_on_name_changed)
	channel.solo_changed.connect(_solo.set_pressed_no_signal)
	channel.mute_changed.connect(_mute.set_pressed_no_signal)
	_on_name_changed(channel.name)
	_solo.set_pressed_no_signal(channel.solo)
	_mute.set_pressed_no_signal(channel.mute)


func _unbind() -> void:
	if _channel and is_instance_valid(_channel):
		_channel.name_changed.disconnect(_on_name_changed)
		_channel.solo_changed.disconnect(_solo.set_pressed_no_signal)
		_channel.mute_changed.disconnect(_mute.set_pressed_no_signal)
	_channel = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


func get_channel_name() -> String:
	return _name_label.text


func _on_name_changed(new_name: String) -> void:
	_name_label.text = new_name
	_name_label.tooltip_text = new_name


func _on_solo_toggled(pressed: bool) -> void:
	if _channel:
		HistoryUtil.execute_property("Solo", _channel, "set_solo", _channel.solo, pressed)


func _on_mute_toggled(pressed: bool) -> void:
	if _channel:
		HistoryUtil.execute_property("Mute", _channel, "set_mute", _channel.mute, pressed)
