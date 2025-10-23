# Popup Menu to manage a channel
# 
# Can popup at any location given a Channel instance
class_name ChannelContextMenu extends PopupPanel

var channel : Channel:
	set = set_channel

# ---------------------------------
# NODE REFS
# ---------------------------------
@onready var color_picker: ColorPickerButton = $VBoxContainer/Header/HBox/ColorPicker
@onready var label: SmartLineEdit = $VBoxContainer/Header/HBox/Label
@onready var disable_checkbox: CheckButton = $VBoxContainer/DisableCheckbox

func _ready() -> void:
	color_picker.color_changed.connect(_on_color_changed)
	label.value_changed.connect(_on_label_changed)
	disable_checkbox.toggled.connect(_on_disabled_toggled)

func set_channel(ch : Channel):
	channel = ch
	color_picker.color = channel.color
	label.set_value(ch.name)

func _on_color_changed(color : Color):
	if not channel: return
	channel.set_color(color)


func _on_label_changed(new_name : String):
	if not channel: return
	channel.set_name(new_name)

func _on_disabled_toggled(disabled : bool):
	if not channel: return
	channel.set_disabled(disabled)
