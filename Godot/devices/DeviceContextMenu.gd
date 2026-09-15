class_name DeviceContextMenu extends PopupPanel

@onready var v_box_container: VBoxContainer = $VBoxContainer

@onready var label: SmartLineEdit = $VBoxContainer/Label
@onready var remove: Button = $VBoxContainer/Remove

var device : DeviceInstance = null

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
		if channel:
			HistoryUtil.execute(DeviceRemoveCommand.new(channel, device, device.position))
	hide()
