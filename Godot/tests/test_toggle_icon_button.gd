extends TestBase

var _tib: GDScript
var _fired: int = 0


func suite_name() -> String:
	return "ToggleIconButton tests"


func _on_toggled(_on: bool) -> void:
	_fired += 1


func run_tests() -> void:
	_tib = load("res://support/ToggleIconButton.gd")
	var default := load("res://assets/icons/chevron-right.svg")
	var pressed := load("res://assets/icons/chevron-down.svg")
	var b: Button = _tib.new()
	b.icon_default = default
	b.icon_pressed = pressed
	b.toggle_mode = true
	root.add_child(b)  # so _ready connects toggled -> _update_icon
	b.toggled.connect(_on_toggled)
	b.set_state(true)
	_assert(b.button_pressed == true and b.icon == pressed, "set_state presses and swaps icon")
	_assert(_fired == 0, "set_state does not emit toggled")
	b.set_state(false)
	_assert(_fired == 0 and b.icon == default, "set_state reflects without toggled")
	# The normal user path still works through the toggled signal.
	b.set_pressed(true)
	_assert(_fired == 1 and b.icon == pressed, "set_pressed emits and swaps icon")
	b.free()