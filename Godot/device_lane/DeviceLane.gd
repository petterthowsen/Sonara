class_name DeviceLane extends HBoxContainer

const DevicePanelScene : PackedScene = preload("res://device_lane/DevicePanel.tscn")

@onready var header: Panel = $Header
@onready var header_label: VerticalLabel = $Header/Label

@onready var devices: HBoxContainer = $Content/ScrollContainer/Devices

var channel : Channel

func _get_header_stylebox() -> StyleBoxFlat:
	return header.get_theme_stylebox("panel")


func unbind():
	channel.name_changed.disconnect(_on_channel_name_changed)
	channel.color_changed.disconnect(_on_channel_color_changed)
	channel.device_added.disconnect(_add_device)
	channel.device_removed.disconnect(_on_channel_device_remmoved)


func clear():
	header_label.text = "N/A"
	var sb := _get_header_stylebox()
	sb.bg_color = Color.DIM_GRAY
	
	for node in devices.get_children():
		node.queue_free()


func bind_to_channel(channel : Channel):
	# already bound to this channel?
	if self.channel == channel:
		return
	
	# unbind to previously shown channel
	if self.channel:
		unbind()
	
	# clear any device controls
	clear()
	
	# bind to new channel
	self.channel = channel
	
	# set heade label and bg color
	header_label.text = channel.name
	var sb := _get_header_stylebox()
	sb.bg_color = channel.color
	
	# set up all devices
	for device_inst : DeviceInstance in channel.devices:
		_add_device(device_inst, 0)
	
	# connect to channel events
	channel.name_changed.connect(_on_channel_name_changed)
	channel.color_changed.connect(_on_channel_color_changed)
	channel.device_added.connect(_add_device)
	channel.device_removed.connect(_on_channel_device_remmoved)


func _add_device(device_instance : DeviceInstance, position : int):
	var dp:DevicePanel = DevicePanelScene.instantiate()
	dp.bind_to_device(device_instance)
	devices.add_child(dp)

func find_device_panel(device_instance : DeviceInstance) -> DevicePanel:
	for dp in devices.get_children():
		if dp is DevicePanel:
			if dp.device == device_instance:
				return dp
	
	return null

func _on_channel_device_remmoved(device_instance : DeviceInstance):
	pass

func _on_channel_name_changed(ch_name : String):
	header_label.text = ch_name

func _on_channel_color_changed(c : Color):
	var sb := _get_header_stylebox()
	sb.bg_color = c
