# Popup Menu to manage a channel
# 
# Can popup at any location given a Channel instance
class_name ChannelContextMenu extends PopupPanel

var channel : Channel = null

# ---------------------------------
# NODE REFS
# ---------------------------------
@onready var color_picker: ColorPickerButton = $VBoxContainer/Header/HBox/ColorPicker
@onready var label: SmartLineEdit = $VBoxContainer/Header/HBox/Label
@onready var active_checkbox: CheckButton = $VBoxContainer/ActiveCheckbox

func _ready() -> void:
	color_picker.color_changed.connect(_on_color_changed)
	label.value_changed.connect(_on_label_changed)
	active_checkbox.toggled.connect(_on_active_toggled)

func bind_to_channel(ch : Channel):
	channel = ch
	color_picker.color = channel.color
	# Ensure SmartLineEdit exits edit mode before updating value
	if label.is_editing:
		label.cancel_editing()
	label.set_value(channel.name)

func _on_color_changed(color : Color):
	if not channel: return
	channel.set_color(color)

func _on_label_changed(new_name : String):
	if not channel: return
	channel.set_name(new_name)

func _on_active_toggled(active : bool):
	if not channel: return
	# TODO: channels don't have active/inactive state yet.
	#channel.set_active(active)
