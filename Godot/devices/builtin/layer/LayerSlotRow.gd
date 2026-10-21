## One Layer slot: device light, name (double-click to rename), separate-output toggle and a
## volume knob, with the slot color along the left edge.
## Clicking the row (not the light or knob) shows or hides the slot; an open slot is highlighted.
## The layout and both panel styles live in `LayerSlotRow.tscn`; instantiate that, not the script.
class_name LayerSlotRow extends PanelContainer

signal activated
## Right-click: the slot chain's context menu.
signal context_requested

var container: DeviceInstance = null
var instance: DeviceInstance = null

## Panel styles for a closed and an open slot; the slot color goes on their left border (the
## color bar). Copied per row in `_ready`, as each row tints its own.
@export var idle_style: StyleBoxFlat
@export var open_style: StyleBoxFlat

@onready var _light: DeviceLightButton = %Light
@onready var _name: SmartLineEdit = %Name
@onready var _knob: RotaryKnob = %Knob
@onready var _out: Button = %Out
var _channel: Channel = null
## The slot's return channel while its separate output is on: the knob drives its volume.
var _return: Channel = null
var _idle_style: StyleBoxFlat = null
var _open_style: StyleBoxFlat = null


## Take this row's own copies of the panel styles and hook the controls.
func _ready() -> void:
	_idle_style = idle_style.duplicate()
	_open_style = open_style.duplicate()
	add_theme_stylebox_override("panel", _idle_style)
	_name.value_changed.connect(_on_name_edited)
	# A single click still opens the slot; the double-click that starts renaming doesn't.
	_name.label.gui_input.connect(_on_name_gui_input)
	_out.toggled.connect(_on_out_toggled)
	_knob.value_changed.connect(_on_knob_changed)


## Bind this row to child `inst` of Layer `p_container`.
func setup(p_container: DeviceInstance, inst: DeviceInstance) -> void:
	container = p_container
	instance = inst
	if not is_node_ready():
		await ready
	refresh_slot()
	_light.bind_to_device_instance(inst)
	_set_name_text(inst.get_display_name())
	if not inst.name_changed.is_connected(_on_instance_name_changed):
		inst.name_changed.connect(_on_instance_name_changed)
	if not inst.slot_changed.is_connected(_on_slot_changed):
		inst.slot_changed.connect(_on_slot_changed)
	_bind_channel(p_container.get_channel())
	_on_slot_changed()


func _exit_tree() -> void:
	_bind_channel(null)
	_bind_return(null)


## While the separate output is on, the knob shows and sets the return channel's fader (dB);
## otherwise the Layer's own slot volume (normalized, 0.5 = unity).
func _bind_return(ch: Channel) -> void:
	if _return != ch:
		if _return and _return.volume_changed.is_connected(_on_return_volume_changed):
			_return.volume_changed.disconnect(_on_return_volume_changed)
		_return = ch
		if _return:
			_return.volume_changed.connect(_on_return_volume_changed)
	if _knob == null:
		return
	_knob.set_block_signals(true)
	if _return:
		_knob.min_value = AutomationTarget.VOLUME_DB_MIN
		_knob.max_value = AutomationTarget.VOLUME_DB_MAX
		_knob.value_default = 0.0
		_knob.value_format = "%.1f"
		_knob.unit = " dB"
		_knob.value = _return.volume
		_knob.tooltip_text = "%s channel volume" % _return.name
		ModAssign.detach(_knob)
	else:
		_knob.min_value = 0.0
		_knob.max_value = 1.0
		_knob.value_default = 0.5
		_knob.value_format = "%.2f"
		_knob.unit = ""
		_knob.value = instance.slot_volume if instance else 0.5
		_knob.tooltip_text = "Layer volume"
		if container != null and instance != null:
			ModAssign.retarget(_knob, container, DeviceInstance.LAYER_SLOT_VOLUME_PARAM_BASE + instance.position)
	_knob.set_block_signals(false)


func _on_return_volume_changed(_db: float) -> void:
	if _knob and _return:
		_knob.set_value_no_signal(_return.volume)


## Follow the Layer's channel chain: separate outputs only work while the Layer is first.
func _bind_channel(ch: Channel) -> void:
	if _channel == ch:
		return
	for sig_name in ["device_added", "device_removed", "device_moved"]:
		if _channel and _channel.is_connected(sig_name, _refresh_out_enabled):
			_channel.disconnect(sig_name, _refresh_out_enabled)
		if ch and not ch.is_connected(sig_name, _refresh_out_enabled):
			ch.connect(sig_name, _refresh_out_enabled)
	_channel = ch
	_refresh_out_enabled()


## Enable the separate-output toggle only when the Layer is the first device on its channel's
## root chain, the one place the engine takes extra outputs from (REQ-007).
func _refresh_out_enabled(_a = null, _b = null) -> void:
	if _out == null:
		return
	var is_first := _channel != null and container != null and container.get_parent_device() == null \
		and not _channel.devices.is_empty() and _channel.devices[0] == container
	_out.disabled = not is_first
	if is_first:
		_out.tooltip_text = "Separate output: send this layer to its own mixer channel"
	else:
		_out.tooltip_text = "Separate outputs need the Layer to be the first device on its channel"


## Keep the slot label in sync with instance renames.
func _on_instance_name_changed(new_name: String) -> void:
	if _name:
		_set_name_text(new_name)


## Show `text` and widen the name to fit it, so the row (and the Layer view) grows instead of
## the name running under the OUT button.
func _set_name_text(text: String) -> void:
	_name.set_value(text)
	var label := _name.label
	var font: Font = label.label_settings.font if label.label_settings and label.label_settings.font else label.get_theme_font("font")
	var font_size: int = label.label_settings.font_size if label.label_settings else label.get_theme_font_size("font_size")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_name.custom_minimum_size.x = maxf(40.0, ceilf(width) + 8.0)


## Commit an inline rename (one undo step; a separate slot's return follows, REQ-017/018).
func _on_name_edited(value) -> void:
	if instance:
		_set_name_text(DeviceActions.rename(instance, str(value)))


## Follow the slot's color and open state.
func refresh_slot() -> void:
	if container == null or instance == null or _idle_style == null:
		return
	var key := container.slot_key_for(instance)
	var color := container.slot_color(key)
	var open := container.is_slot_open(key)
	_idle_style.border_color = color.darkened(0.3)
	_open_style.border_color = color
	add_theme_stylebox_override("panel", _open_style if open else _idle_style)
	tooltip_text = ("Hide %s" if open else "Show %s") % instance.get_display_name()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			activated.emit()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			context_requested.emit()
			accept_event()


func _on_name_gui_input(event: InputEvent) -> void:
	if _name.is_editing:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			activated.emit()
			accept_event()


func _on_knob_changed(value: float) -> void:
	if _return:
		# Same as the mixer fader: one mergeable undo step per drag, a reset isn't merged.
		var old := _return.volume
		var kind := _knob.last_edit_kind
		_return.set_volume(value)
		HistoryUtil.record_property("Set Volume", _return, "set_volume", old, _return.volume, kind != ValueEditKind.Kind.RESET)
	elif instance:
		instance.set_slot_volume(value)


## Turning OUT on also resets the slot's Layer volume to unity: the knob then drives the return
## channel's fader, and a leftover slot cut would sit hidden in front of it. One undo step.
func _on_out_toggled(on: bool) -> void:
	if instance == null or instance.slot_separate_out == on:
		return
	var label := "Separate Output" if on else "Merge Output"
	var cmds: Array[Command] = []
	if on and not is_equal_approx(instance.slot_volume, 0.5):
		cmds.append(PropertyCommand.new(label, instance, "set_slot_volume", instance.slot_volume, 0.5))
	cmds.append(PropertyCommand.new(label, instance, "set_slot_separate_out", not on, on))
	HistoryUtil.execute_many(label, cmds)


func _on_slot_changed() -> void:
	if instance == null or _knob == null:
		return
	var project := _channel.get_project() if _channel else null
	var ret: Channel = null
	if instance.slot_separate_out and project:
		ret = project.get_channel_by_id(instance.return_channel_id)
	_bind_return(ret)
	_out.set_pressed_no_signal(instance.slot_separate_out)

