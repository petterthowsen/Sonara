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

func _update_icon(on = false) -> void:
	icon = icon_pressed if on else icon_default
