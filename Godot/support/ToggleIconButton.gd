@tool class_name ToggleIconButton extends Button

@export var icon_default : Texture:
	set(id):
		icon_default = id
		if is_inside_tree():
			_update_icon(button_pressed)

@export var icon_pressed : Texture:
	set(ip):
		icon_pressed = ip
		if is_inside_tree():
			_update_icon(button_pressed)

func _ready() -> void:
	toggled.connect(_update_icon)
	_update_icon(button_pressed)

# Programmatic state change that doesn't emit `toggled` (so callers don't get a feedback
# loop when they're reflecting the model, e.g. TrackItem._update_automation_controls).
# Use this instead of set_pressed_no_signal(), which wouldn't move the icon.
func set_state(on: bool) -> void:
	set_pressed_no_signal(on)
	_update_icon(on)

func _update_icon(on = false) -> void:
	icon = icon_pressed if on else icon_default
