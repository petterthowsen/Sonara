# Minimize, Maximize and Close Buttons
class_name WindowButtons extends HBoxContainer

@onready var minimize: Button = $Minimize
@onready var maximize: Button = $Maximize
@onready var quit: Button = $Quit

const ICON_MAXIMIZE := preload("res://assets/icons/square.svg")
const ICON_RESTORE := preload("res://assets/icons/minimize-2.svg")


func _ready() -> void:
	minimize.pressed.connect(_on_minimize_pressed)
	maximize.pressed.connect(_on_maximize_pressed)
	quit.pressed.connect(_on_quit_pressed)
	get_window().size_changed.connect(_update_maximize_icon)
	_update_maximize_icon()


func _update_maximize_icon() -> void:
	var maximized := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED
	maximize.icon = ICON_RESTORE if maximized else ICON_MAXIMIZE
	maximize.tooltip_text = "Restore" if maximized else "Maximize"


func _on_minimize_pressed() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)


func _on_maximize_pressed() -> void:
	var current_mode = DisplayServer.window_get_mode()
	if current_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


func _on_quit_pressed() -> void:
	# Delegate shutdown to Editor for unified behavior
	Sonara.editor.quit()
