## Panel view of the built-in MIDI Send (spec 049): the mode switch (Children / List), the Thru
## switch (parameter 0) and the targets by channel name. Children mode shows the channels nested
## directly under the sender, each with a toggle to leave it out; List mode lets you add and remove targets from the valid channels.
## A target the engine refused (it would close a MIDI loop) is marked on its row. Names follow
## renames and a deleted channel disappears. The static nodes live in `MidiSendDefaultView.tscn`;
## only the target rows, one per target, are made here.
class_name MidiSendDefaultView extends DeviceView

const RowScript := preload("res://devices/builtin/midi_send/MidiSendTargetRow.gd")
const ROW_SCENE: PackedScene = preload("res://devices/builtin/midi_send/MidiSendTargetRow.tscn")
const P_THRU := 0

@onready var children_button: Button = %ChildrenButton
@onready var list_button: Button = %ListButton
@onready var thru_check: CheckBox = %ThruCheck
@onready var target_list: VBoxContainer = %TargetList
@onready var empty_label: Label = %EmptyLabel
@onready var add_button: MenuButton = %AddButton
@onready var _box: VBoxContainer = %Box

## Channels whose rename we follow (the rows show their names).
var _watched: Array[Channel] = []
var _picker_ids := PackedInt32Array()


func _get_minimum_size() -> Vector2:
	return Vector2(220, 100)


func _ready() -> void:
	children_button.pressed.connect(func() -> void: _on_mode_pressed(DeviceInstance.MIDI_SEND_CHILDREN))
	list_button.pressed.connect(func() -> void: _on_mode_pressed(DeviceInstance.MIDI_SEND_LIST))
	thru_check.toggled.connect(_on_thru_toggled)
	add_button.about_to_popup.connect(_fill_picker)
	add_button.get_popup().id_pressed.connect(_on_picker_chosen)
	if device != null:
		_setup()


func _on_bind() -> void:
	if not device.midi_send_changed.is_connected(_refresh):
		device.midi_send_changed.connect(_refresh)
	if not device.midi_send_blocked_changed.is_connected(_refresh):
		device.midi_send_blocked_changed.connect(_refresh)
	var project := _project()
	if project != null:
		if not project.channel_added.is_connected(_on_channels_changed):
			project.channel_added.connect(_on_channels_changed)
		if not project.channel_removed.is_connected(_on_channels_changed):
			project.channel_removed.connect(_on_channels_changed)
	if is_node_ready():
		_setup()


func _on_unbind() -> void:
	if device.midi_send_changed.is_connected(_refresh):
		device.midi_send_changed.disconnect(_refresh)
	if device.midi_send_blocked_changed.is_connected(_refresh):
		device.midi_send_blocked_changed.disconnect(_refresh)
	var project := _project()
	if project != null:
		if project.channel_added.is_connected(_on_channels_changed):
			project.channel_added.disconnect(_on_channels_changed)
		if project.channel_removed.is_connected(_on_channels_changed):
			project.channel_removed.disconnect(_on_channels_changed)
	_unwatch_names()


func _project() -> Project:
	var channel := device.get_channel() if device != null else null
	return channel.get_project() if channel != null else null


func _setup() -> void:
	_refresh()


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if param_id == P_THRU:
		_refresh_thru()


func _on_channels_changed(_channel: Channel) -> void:
	_refresh()


# ============================================================================
# DISPLAY
# ============================================================================

func _refresh() -> void:
	if device == null or not is_node_ready():
		return
	var list_mode := device.midi_send_mode == DeviceInstance.MIDI_SEND_LIST
	children_button.set_pressed_no_signal(not list_mode)
	list_button.set_pressed_no_signal(list_mode)
	add_button.visible = list_mode
	_refresh_thru()
	_rebuild_rows(list_mode)


func _refresh_thru() -> void:
	if device == null or not is_node_ready():
		return
	var on := device.get_parameter_real(P_THRU) >= 0.5 if device.get_parameter(P_THRU) != null else true
	thru_check.set_pressed_no_signal(on)


## The ids shown: what the model sends to the engine (a refused one stays, marked as looping). In
## children mode every valid child is shown, with its send toggle, so a switched-off one can be
## switched back on.
func shown_target_ids() -> PackedInt32Array:
	if device == null:
		return PackedInt32Array()
	if device.midi_send_mode == DeviceInstance.MIDI_SEND_CHILDREN:
		var out := PackedInt32Array()
		for child_id in device.midi_send_children():
			if device.midi_send_can_target(int(child_id)) and not out.has(int(child_id)):
				out.append(int(child_id))
		return out
	return device.resolved_midi_send_targets()


func _rebuild_rows(list_mode: bool) -> void:
	_unwatch_names()
	for row in target_list.get_children():
		target_list.remove_child(row)
		row.queue_free()
	var project := _project()
	var ids := shown_target_ids()
	for target_id in ids:
		var channel := project.get_channel_by_id(target_id) if project != null else null
		if channel == null:
			continue
		var row: RowScript = ROW_SCENE.instantiate()
		target_list.add_child(row)
		row.setup(channel, list_mode, device.midi_send_blocked.has(target_id), not list_mode,
				not device.midi_send_excluded.has(target_id))
		row.remove_pressed.connect(_on_remove_pressed)
		row.send_toggled.connect(_on_send_toggled)
		_watch_name(channel)
	empty_label.visible = ids.is_empty()
	empty_label.text = "No channels nested under this one" if not list_mode else "No targets"


func _watch_name(channel: Channel) -> void:
	if _watched.has(channel):
		return
	_watched.append(channel)
	channel.name_changed.connect(_on_target_renamed)
	channel.color_changed.connect(_on_target_recolored)


func _unwatch_names() -> void:
	for channel in _watched:
		if is_instance_valid(channel):
			if channel.name_changed.is_connected(_on_target_renamed):
				channel.name_changed.disconnect(_on_target_renamed)
			if channel.color_changed.is_connected(_on_target_recolored):
				channel.color_changed.disconnect(_on_target_recolored)
	_watched.clear()


func _on_target_renamed(_name: String) -> void:
	_refresh()


func _on_target_recolored(_color: Color) -> void:
	_refresh()


# ============================================================================
# EDITS
# ============================================================================

func _on_mode_pressed(mode: String) -> void:
	if device != null:
		device.change_midi_send_mode(mode)
	_refresh()


func _on_thru_toggled(on: bool) -> void:
	if device != null:
		ParameterActions.set_real(device, P_THRU, 1.0 if on else 0.0)


func _on_remove_pressed(channel_id: int) -> void:
	if device != null:
		device.toggle_midi_send_target(channel_id, false)


func _on_send_toggled(channel_id: int, on: bool) -> void:
	if device != null:
		device.toggle_midi_send_child(channel_id, on)


func _fill_picker() -> void:
	var popup := add_button.get_popup()
	popup.clear()
	_picker_ids = PackedInt32Array()
	if device == null:
		return
	for channel in device.midi_send_valid_channels():
		if device.midi_send_targets.has(channel.id):
			continue
		popup.add_item(channel.name, channel.id)
		_picker_ids.append(channel.id)
	if _picker_ids.is_empty():
		popup.add_item("No channels to add", -1)
		popup.set_item_disabled(0, true)


func _on_picker_chosen(id: int) -> void:
	if device != null and _picker_ids.has(id):
		device.toggle_midi_send_target(id, true)
