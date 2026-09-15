class_name DeviceContextMenu extends PopupPanel

@onready var v_box_container: VBoxContainer = $VBoxContainer

@onready var label: SmartLineEdit = $VBoxContainer/Label
@onready var remove: Button = $VBoxContainer/Remove

var device : DeviceInstance = null

## When true (the Drum Machine folder), Remove on a pad device removes the whole pad and its
## return channel. Elsewhere (the pad's own lane) it only empties the pad.
var removes_drum_pad := false

func _enter_tree() -> void:
	# Packed scene is visible for editor authoring; instances must start hidden.
	hide()


func _ready() -> void:
	remove.pressed.connect(_on_remove_pressed)
	label.value_changed.connect(_on_label_changed)


func bind_to_device(device_instance : DeviceInstance) -> void:
	if self.device:
		unbind()
	
	device = device_instance
	label.set_value(device.get_display_name())
	remove.text = "Remove Pad" if _pad_return() else "Remove"


func unbind() -> void:
	device = null


## Commit a display-name edit from the context menu.
func _on_label_changed(value) -> void:
	if device == null:
		return
	var new_name := str(value).strip_edges()
	if new_name.is_empty() or new_name == device.name:
		return
	HistoryUtil.execute_property("Rename Device", device, "set_name", device.name, new_name)
	label.set_value(device.name)


func _on_remove_pressed() -> void:
	if device:
		var channel := device.get_channel()
		var pad_return := _pad_return()
		if pad_return:
			HistoryUtil.execute(ChannelDeleteCommand.new(channel.get_project(), pad_return))
		elif channel:
			HistoryUtil.execute(DeviceRemoveCommand.new(channel, device, device.position))
	hide()


## Return channel of the pad `device` plays, when Remove should take the whole pad.
func _pad_return() -> Channel:
	if not removes_drum_pad or device == null or not AuxReturnSync.is_drum_machine(device.get_parent_device()):
		return null
	var channel := device.get_channel()
	var project := channel.get_project() if channel else null
	var ret := project.get_channel_by_id(device.return_channel_id) if project else null
	return ret if ret and ret.is_pad_return() else null
