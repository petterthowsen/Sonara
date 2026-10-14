# Popup Menu to manage a channel
# 
# Can popup at any location given a Channel instance
class_name ChannelContextMenu extends PopupPanel

var logger : Log = Log.make("ChannelContextMenu")

signal delete_requested(channel: Channel)
signal unnest_requested(channel: Channel)
## Delete several selected channels as one undo step (the Mixer filters and executes).
signal delete_many_requested(channels: Array[Channel])

## The right-clicked channel (the one single-channel items act on).
var channel : Channel = null
## Every channel the menu acts on: `channel` alone, or the whole multi-selection.
var channels : Array[Channel] = []
## Colours before the current colour-picker session, to record one undo step (multi only).
var _color_old : Dictionary = {}

# ---------------------------------
# NODE REFS
# ---------------------------------
@onready var color_picker: ColorPickerButton = $VBoxContainer/Header/HBox/ColorPicker
@onready var label: SmartLineEdit = $VBoxContainer/Header/HBox/Label
@onready var active_checkbox: CheckButton = $VBoxContainer/ActiveCheckbox
var hidden_checkbox: CheckBox
var sends_hidden_checkbox: CheckBox
@onready var unnest_button: Button = $VBoxContainer/UnnestButton
@onready var delete_button: Button = $VBoxContainer/DeleteButton


func _ready() -> void:
	# ColorPickerButton opens a nested Window; keep this menu alive so color_changed fires.
	exclusive = false
	transient = false
	color_picker.edit_alpha = false
	color_picker.edit_intensity = false
	color_picker.color_changed.connect(_on_color_changed)
	color_picker.pressed.connect(_on_color_picker_pressed)
	color_picker.popup_closed.connect(_flush_color_history)
	popup_hide.connect(_flush_color_history)
	label.value_changed.connect(_on_label_changed)
	active_checkbox.toggled.connect(_on_active_toggled)
	# Issue 70: Hidden is visual only; Enabled (the Active checkbox) also deactivates the devices.
	hidden_checkbox = CheckBox.new()
	hidden_checkbox.text = "Hidden"
	hidden_checkbox.tooltip_text = "Leave out of the mixer (visual only). Show Hidden brings it back"
	hidden_checkbox.toggled.connect(_on_hidden_toggled)
	active_checkbox.add_sibling(hidden_checkbox)
	# Issue 88: buses only; other channels get no send knob for this bus.
	sends_hidden_checkbox = CheckBox.new()
	sends_hidden_checkbox.text = "Hide Sends"
	sends_hidden_checkbox.tooltip_text = "Other channels show no send knob for this bus (visual only). Existing sends keep working"
	sends_hidden_checkbox.toggled.connect(_on_sends_hidden_toggled)
	hidden_checkbox.add_sibling(sends_hidden_checkbox)
	active_checkbox.tooltip_text = "Off deactivates this channel's devices (and its children's) to save CPU"
	if unnest_button:
		unnest_button.pressed.connect(_on_unnest_pressed)
	delete_button.pressed.connect(_on_delete_pressed)


## Connect the nested ColorPicker once it exists.
func _on_color_picker_pressed() -> void:
	var picker := color_picker.get_picker()
	if picker and not picker.color_changed.is_connected(_on_color_changed):
		picker.color_changed.connect(_on_color_changed)

func is_multi() -> bool:
	return channels.size() > 1


## Selected channels a batch hide/enable applies to (the master can't be).
func _batch_targets() -> Array[Channel]:
	var out : Array[Channel] = []
	for c in channels:
		if not c.is_master:
			out.append(c)
	return out


## Selected channels a batch delete removes: not the master, not plugin returns, and not ones
## that go with a selected ancestor anyway.
func deletable_channels() -> Array[Channel]:
	var out : Array[Channel] = []
	var project := channel.get_project() if channel else null
	for c in channels:
		if c.is_master or c.is_plugin_return() or _has_selected_ancestor(c, project):
			continue
		out.append(c)
	return out


func _has_selected_ancestor(c : Channel, project : Project) -> bool:
	if project == null:
		return false
	var parent := project.get_channel_by_id(c.parent_channel_id) if c.parent_channel_id >= 0 else null
	while parent:
		if channels.has(parent):
			return true
		parent = project.get_channel_by_id(parent.parent_channel_id) if parent.parent_channel_id >= 0 else null
	return false


## Bind to `ch`; `peers` are the other selected channels when `ch` is part of a multi-selection.
func bind_to_channel(ch : Channel, peers : Array[Channel] = []):
	_flush_color_history()
	channel = ch
	channels = [ch] as Array[Channel]
	channels.append_array(peers)
	var multi := is_multi()
	color_picker.color = channel.color
	# Ensure SmartLineEdit exits edit mode before updating value
	if label.is_editing:
		label.cancel_editing()
	# Names are unique, so a batch can't be renamed: show the count instead.
	label.set_value("%d channels" % channels.size() if multi else channel.name)
	label.disabled = multi
	var targets := _batch_targets()
	active_checkbox.set_pressed_no_signal(_all(targets, "enabled") if multi else channel.enabled)
	active_checkbox.disabled = targets.is_empty()
	hidden_checkbox.set_pressed_no_signal(_all(targets, "hidden") if multi else channel.hidden)
	hidden_checkbox.disabled = targets.is_empty()
	var buses := _bus_targets()
	sends_hidden_checkbox.visible = not buses.is_empty()
	sends_hidden_checkbox.set_pressed_no_signal(_all(buses, "sends_hidden") if multi else channel.sends_hidden)

	# Master can't be deleted; a plugin return only goes with its parent or its source device.
	if multi:
		var n := deletable_channels().size()
		delete_button.text = "Delete %d Channels" % n if n > 1 else "Delete Channel"
		delete_button.disabled = n == 0
	else:
		delete_button.text = "Delete Channel"
		delete_button.disabled = channel.is_master or channel.is_plugin_return()
	if unnest_button:
		unnest_button.visible = not multi and MixerChannelDrag.can_unnest(channel)
	_color_old = {}


static func _all(list : Array[Channel], prop : String) -> bool:
	if list.is_empty():
		return false
	for c in list:
		if not c.get(prop):
			return false
	return true


func _bus_targets() -> Array[Channel]:
	var out : Array[Channel] = []
	for c in channels:
		if c.is_bus:
			out.append(c)
	return out


## Set `setter` to `value` on every channel in `targets` as one undo step (a single channel
## keeps today's direct, unrecorded behaviour).
func _batch_set(targets : Array[Channel], getter : String, setter : String, label_text : String, value) -> void:
	if not is_multi():
		for c in targets:
			c.call(setter, value)
		return
	var cmds : Array[Command] = []
	for c in targets:
		var old = c.get(getter)
		if old != value:
			cmds.append(PropertyCommand.new(label_text, c, setter, old, value))
	HistoryUtil.execute_many(label_text, cmds)


## Record the colour edit made since the picker opened as one undo step (multi only).
func _flush_color_history() -> void:
	if _color_old.is_empty():
		return
	var cmds : Array[Command] = []
	for c in _color_old:
		if c.color != _color_old[c]:
			cmds.append(PropertyCommand.new("Set Channel Color", c, "set_color", _color_old[c], c.color))
	_color_old = {}
	HistoryUtil.record_many("Set Channel Color", cmds)

func _on_color_changed(color : Color):
	if not channel:
		push_warning("[ChannelContextMenu] color_changed with no channel")
		return
	logger.info("color → channel %d '%s' routed_tracks=%d" % [
		channel.id, channel.name, channel.routed_tracks.size()
	])
	if is_multi():
		if _color_old.is_empty():
			for c in channels:
				_color_old[c] = c.color
		for c in channels:
			c.set_color(color)
		return
	channel.set_color(color)

func _on_label_changed(new_name : String):
	if not channel or is_multi(): return
	channel.set_name(new_name)
	# Show the final name: it may have been suffixed ("Drums 2") to stay unique.
	label.set_value(channel.name)

func _on_active_toggled(_active : bool):
	if not channel: return
	_batch_set(_batch_targets(), "enabled", "set_enabled", "Set Channels Enabled", _active)
	ContextMenuPopup.close(self)


func _on_hidden_toggled(pressed: bool) -> void:
	if not channel: return
	_batch_set(_batch_targets(), "hidden", "set_hidden", "Set Channels Hidden", pressed)
	ContextMenuPopup.close(self)


func _on_sends_hidden_toggled(pressed: bool) -> void:
	if not channel: return
	_batch_set(_bus_targets(), "sends_hidden", "set_sends_hidden", "Set Sends Hidden", pressed)
	ContextMenuPopup.close(self)


## Un-nest this mixer child from its Group parent.
func _on_unnest_pressed() -> void:
	if not channel:
		return
	unnest_requested.emit(channel)
	ContextMenuPopup.close(self)


func _on_delete_pressed():
	if not channel: return
	if is_multi():
		delete_many_requested.emit(deletable_channels())
		ContextMenuPopup.close(self)
		return
	delete_requested.emit(channel)
	ContextMenuPopup.close(self)  # Close the context menu
