class_name DeviceContextMenu extends PopupPanel

@onready var v_box_container: VBoxContainer = $VBoxContainer

@onready var label: SmartLineEdit = $VBoxContainer/Label
@onready var remove: Button = $VBoxContainer/Remove
## CLAP only: keep this plugin in a host process of its own whatever the hosting setting says.
@onready var host_individually: CheckBox = $VBoxContainer/HostIndividually

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
	host_individually.toggled.connect(_on_host_individually_toggled)


func bind_to_device(device_instance : DeviceInstance) -> void:
	if self.device:
		unbind()
	
	device = device_instance
	label.set_value(device.get_display_name())
	remove.text = "Remove Pad" if _pad_return() else "Remove"
	var is_plugin := device.device.device_type == Device.DeviceType.CLAP
	host_individually.visible = is_plugin
	if is_plugin:
		host_individually.set_pressed_no_signal(
			AssetService.plugin_hosting.is_hosted_individually(device.device.device_id))
		host_individually.tooltip_text = "Run every instance of this plugin in a plugin host process of its own, whatever Settings › Audio › Plugin Hosting says. Useful for a plugin that crashes."
		var host := device.host_description()
		if not host.is_empty():
			host_individually.tooltip_text += "\n\n" + host


func unbind() -> void:
	device = null


## Commit a display-name edit from the context menu.
func _on_label_changed(value) -> void:
	if device == null:
		return
	label.set_value(DeviceActions.rename(device, str(value)))


func _on_host_individually_toggled(pressed: bool) -> void:
	if device == null:
		return
	AssetService.plugin_hosting.set_hosted_individually(device.device.device_id, pressed)


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
