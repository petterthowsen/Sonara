# Popup Menu to manage a channel
# 
# Can popup at any location given a Channel instance
class_name ChannelContextMenu extends PopupPanel

var logger : Log = Log.make("ChannelContextMenu")

signal delete_requested(channel: Channel)
signal unnest_requested(channel: Channel)

var channel : Channel = null

# ---------------------------------
# NODE REFS
# ---------------------------------
@onready var color_picker: ColorPickerButton = $VBoxContainer/Header/HBox/ColorPicker
@onready var label: SmartLineEdit = $VBoxContainer/Header/HBox/Label
@onready var active_checkbox: CheckButton = $VBoxContainer/ActiveCheckbox
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
	label.value_changed.connect(_on_label_changed)
	active_checkbox.toggled.connect(_on_active_toggled)
	if unnest_button:
		unnest_button.pressed.connect(_on_unnest_pressed)
	delete_button.pressed.connect(_on_delete_pressed)


## Connect the nested ColorPicker once it exists.
func _on_color_picker_pressed() -> void:
	var picker := color_picker.get_picker()
	if picker and not picker.color_changed.is_connected(_on_color_changed):
		picker.color_changed.connect(_on_color_changed)

func bind_to_channel(ch : Channel):
	channel = ch
	color_picker.color = channel.color
	# Ensure SmartLineEdit exits edit mode before updating value
	if label.is_editing:
		label.cancel_editing()
	label.set_value(channel.name)
	
	# Disable delete button for master channel
	delete_button.disabled = channel.is_master
	if unnest_button:
		unnest_button.visible = MixerChannelDrag.can_unnest(channel)

func _on_color_changed(color : Color):
	if not channel:
		push_warning("[ChannelContextMenu] color_changed with no channel")
		return
	logger.info("color → channel %d '%s' routed_tracks=%d" % [
		channel.id, channel.name, channel.routed_tracks.size()
	])
	channel.set_color(color)

func _on_label_changed(new_name : String):
	if not channel: return
	channel.set_name(new_name)
	# Show the final name: it may have been suffixed ("Drums 2") to stay unique.
	label.set_value(channel.name)

func _on_active_toggled(_active : bool):
	if not channel: return
	# TODO: channels don't have active/inactive state yet.
	#channel.set_active(_active)


## Un-nest this mixer child from its Group parent.
func _on_unnest_pressed() -> void:
	if not channel:
		return
	unnest_requested.emit(channel)
	hide()


func _on_delete_pressed():
	if not channel: return
	delete_requested.emit(channel)
	hide()  # Close the context menu
