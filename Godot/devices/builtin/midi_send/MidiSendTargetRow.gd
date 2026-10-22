## One target of a MIDI Send: the channel's color and name, a "loops" mark when the engine refused
## the target because it would close a MIDI loop, and a remove button in list mode. The nodes live
## in `MidiSendTargetRow.tscn`; `setup()` fills them.
extends HBoxContainer

signal remove_pressed(channel_id: int)
signal send_toggled(channel_id: int, on: bool)

@onready var send_check: CheckBox = %SendCheck
@onready var swatch: ColorRect = %Swatch
@onready var name_label: Label = %NameLabel
@onready var blocked_label: Label = %BlockedLabel
@onready var remove_button: Button = %RemoveButton

var channel_id := -1


func _ready() -> void:
	remove_button.pressed.connect(func() -> void: remove_pressed.emit(channel_id))
	send_check.toggled.connect(func(on: bool) -> void: send_toggled.emit(channel_id, on))
	blocked_label.add_theme_color_override("font_color", UiColors.role(&"accent_secondary"))


## Show `channel` (null for a missing one). `removable` shows the remove button; `blocked` marks the
## row. `togglable` shows the send checkbox (children mode), set to `sending`; an off row is dimmed.
func setup(channel: Channel, removable: bool, blocked: bool, togglable := false, sending := true) -> void:
	send_check.visible = togglable
	send_check.set_pressed_no_signal(sending)
	modulate.a = 1.0 if sending else 0.5
	blocked = blocked and sending
	channel_id = channel.id if channel != null else -1
	swatch.color = channel.color if channel != null else Color.GRAY
	name_label.text = channel.name if channel != null else "(missing)"
	remove_button.visible = removable
	blocked_label.visible = blocked
	tooltip_text = "Not sent: this would loop back to the sender" if blocked else ""
