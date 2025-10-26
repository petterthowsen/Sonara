# Minimize, Maximize and Close Buttons
class_name WindowButtons extends HBoxContainer

@onready var minimize: Button = $Minimize
@onready var maximize: Button = $Maximize
@onready var quit: Button = $Quit


func _ready() -> void:
	minimize.pressed.connect(_on_minimize_pressed)
	maximize.pressed.connect(_on_maximize_pressed)
	quit.pressed.connect(_on_quit_pressed)


func _on_minimize_pressed() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)


func _on_maximize_pressed() -> void:
	var current_mode = DisplayServer.window_get_mode()
	if current_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


func _on_quit_pressed() -> void:
	get_tree().quit()
