## Right-click menu of a Drum Machine pad: name, color, the pads it chokes, the pads that choke
## it, and Remove Pad. "Choked by" is derived (see `DeviceInstance.choked_by`): ticking X there
## adds this pad to X's targets.
class_name DrumPadContextMenu extends PopupPanel

@onready var _color_picker: ColorPickerButton = $VBoxContainer/Header/ColorPicker
@onready var _label: SmartLineEdit = $VBoxContainer/Header/Label
@onready var _targets_button: MenuButton = $VBoxContainer/ChokeTargets
@onready var _choked_by_button: MenuButton = $VBoxContainer/ChokedBy
@onready var _remove: Button = $VBoxContainer/Remove

var container: DeviceInstance = null
var pad: DeviceInstance = null


func _enter_tree() -> void:
	# Packed scene is visible for editor authoring; instances must start hidden.
	hide()


func _ready() -> void:
	# ColorPickerButton opens a nested Window; keep this menu alive so color_changed fires.
	exclusive = false
	transient = false
	_color_picker.edit_alpha = false
	_color_picker.edit_intensity = false
	_color_picker.color_changed.connect(_on_color_changed)
	_color_picker.pressed.connect(_on_color_picker_pressed)
	_label.value_changed.connect(_on_label_changed)
	for button in [_targets_button, _choked_by_button]:
		var popup: PopupMenu = button.get_popup()
		popup.theme_type_variation = &"ContextMenuList"
		popup.hide_on_checkable_item_selection = false
	_targets_button.about_to_popup.connect(_fill_menu.bind(_targets_button, true))
	_choked_by_button.about_to_popup.connect(_fill_menu.bind(_choked_by_button, false))
	_targets_button.get_popup().index_pressed.connect(_on_item_pressed.bind(true))
	_choked_by_button.get_popup().index_pressed.connect(_on_item_pressed.bind(false))
	_remove.pressed.connect(_on_remove_pressed)


## Bind to `pad_device`, a child of the Drum Machine `drum_machine`.
func bind_to_pad(drum_machine: DeviceInstance, pad_device: DeviceInstance) -> void:
	container = drum_machine
	pad = pad_device
	if _label.is_editing:
		_label.cancel_editing()
	_label.set_value(pad.get_display_name())
	_color_picker.color = container.slot_color(DeviceInstance.pad_slot_key(pad.slot_note))


func _on_color_picker_pressed() -> void:
	var picker := _color_picker.get_picker()
	if picker and not picker.color_changed.is_connected(_on_color_changed):
		picker.color_changed.connect(_on_color_changed)


func _on_color_changed(color: Color) -> void:
	if pad and container:
		container.set_slot_color(DeviceInstance.pad_slot_key(pad.slot_note), color)


func _on_label_changed(value) -> void:
	if pad:
		_label.set_value(DeviceActions.rename(pad, str(value)))


## Other occupied pads, ordered by note.
func other_pads() -> Array[DeviceInstance]:
	var pads: Array[DeviceInstance] = []
	if container == null:
		return pads
	for child in container.children:
		if child != pad:
			pads.append(child)
	pads.sort_custom(func(a: DeviceInstance, b: DeviceInstance) -> bool: return a.slot_note < b.slot_note)
	return pads


## Menu entry text, e.g. "C1 · Kick".
static func pad_label(p: DeviceInstance) -> String:
	return "%s · %s" % [Midi.midi_to_note_name(p.slot_note), p.get_display_name()]


## One check item per other pad. `targets` picks the list: pads this one chokes, or pads that
## choke it.
func _fill_menu(button: MenuButton, targets: bool) -> void:
	var popup := button.get_popup()
	popup.clear()
	if pad == null or container == null:
		return
	var checked := container.choke_target_pads(pad) if targets else container.choked_by(pad)
	var others := other_pads()
	for i in range(others.size()):
		popup.add_check_item(pad_label(others[i]))
		popup.set_item_checked(i, others[i] in checked)
	if others.is_empty():
		popup.add_item("No other pads")
		popup.set_item_disabled(0, true)


func _on_item_pressed(index: int, targets: bool) -> void:
	var others := other_pads()
	if pad == null or index < 0 or index >= others.size():
		return
	var other := others[index]
	var button := _targets_button if targets else _choked_by_button
	var popup := button.get_popup()
	var on := not popup.is_item_checked(index)
	popup.set_item_checked(index, on)
	if targets:
		pad.toggle_choke_target(other.id, on)
	else:
		other.toggle_choke_target(pad.id, on)


## Remove the pad and its return channel, as the device menu's Remove Pad does.
func _on_remove_pressed() -> void:
	if pad:
		var channel := pad.get_channel()
		var project := channel.get_project() if channel else null
		var ret := project.get_channel_by_id(pad.return_channel_id) if project else null
		if ret and ret.is_pad_return():
			HistoryUtil.execute(ChannelDeleteCommand.new(project, ret))
		elif channel:
			HistoryUtil.execute(DeviceRemoveCommand.new(channel, pad, pad.position))
	hide()
