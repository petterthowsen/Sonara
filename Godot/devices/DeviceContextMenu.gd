class_name DeviceContextMenu extends PopupPanel

@onready var v_box_container: VBoxContainer = $VBoxContainer

@onready var label: SmartLineEdit = $VBoxContainer/Label
@onready var remove: Button = $VBoxContainer/Remove

var device : DeviceInstance = null

func _ready() -> void:
	remove.pressed.connect(_on_remove_pressed)


func bind_to_device(device_instance : DeviceInstance) -> void:
	if self.device:
		unbind()
	
	device = device_instance
	label.set_value(device.device.name)


func unbind() -> void:
	pass

func _on_remove_pressed() -> void:
	if device:
		var project = Sonara.editor.project
		var channel = project.get_channel_by_id(device.channel_id)
		if channel:
			channel.remove_device(device.position)
	hide()
