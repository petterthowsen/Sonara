## UI scale (`appearance/ui_scale`) applied to the main window and to every native window.
##
## Godot detects the OS scale only on Wayland and macOS (`DisplayServer.screen_get_scale()` is 1.0
## on X11), so the user can pick one. "Auto" uses the detected value. The factor goes to
## `Window.content_scale_factor`: the main window here, floating device frames (`FrameWindow`
## applies it itself) and any other native (`force_native`) window as it enters the tree.
## Embedded windows (dialogs, popups) are drawn inside the main window and scale with it.
##
## `Window.min_size` is in screen pixels, not content units, so callers multiply their minimum by
## `scaled()` and refresh it on `scale_changed`.
##
## Registered after `Settings` in project.godot. Headless test runs always use 1.0.
extends Node

## Emitted after the factor changed and the windows were updated.
signal scale_changed(factor: float)

const SETTING := "appearance/ui_scale"
const AUTO := "Auto"
const MIN_FACTOR := 0.5
const MAX_FACTOR := 4.0

var _factor := 1.0


func _ready() -> void:
	if Utils.is_test_mode():
		return
	_factor = _read_factor()
	_apply_to(get_tree().root)
	get_tree().node_added.connect(_on_node_added)
	Settings.setting_changed.connect(_on_setting_changed)


## The current scale factor (1.0 = unscaled).
func factor() -> float:
	return _factor


## `size` (content units) in screen pixels at the current factor, rounded up. For `min_size`.
func scaled(size: Vector2i) -> Vector2i:
	return Vector2i((Vector2(size) * _factor).ceil())


## Content scale factor for a stored choice. "Auto" (or anything unknown) uses `auto_scale`.
static func factor_for_choice(choice: String, auto_scale: float) -> float:
	if choice.ends_with("%") and choice.trim_suffix("%").is_valid_float():
		return clampf(choice.trim_suffix("%").to_float() / 100.0, MIN_FACTOR, MAX_FACTOR)
	return clampf(auto_scale, MIN_FACTOR, MAX_FACTOR)


## Set the current factor on `window`. FrameWindow and the main window call this.
func apply_to(window: Window) -> void:
	_apply_to(window)


## Native windows other than the main one keep their pixel size and minimum in step with the
## factor, so their content keeps the same share of the window.
func _apply_to(window: Window) -> void:
	if window == null:
		return
	var old := window.content_scale_factor
	if is_equal_approx(old, _factor):
		return
	window.content_scale_factor = _factor
	if window != get_tree().root:
		var ratio := _factor / old
		window.min_size = Vector2i((Vector2(window.min_size) * ratio).round())
		window.size = Vector2i((Vector2(window.size) * ratio).round())


func _read_factor() -> float:
	var screen := DisplayServer.window_get_current_screen()
	return factor_for_choice(str(Settings.get_value(SETTING)), DisplayServer.screen_get_scale(screen))


func _on_setting_changed(key: String, _value) -> void:
	if key != SETTING:
		return
	var new_factor := _read_factor()
	if is_equal_approx(new_factor, _factor):
		return
	_factor = new_factor
	_apply_to(get_tree().root)
	for node in get_tree().get_nodes_in_group(&"ui_scaled_windows"):
		_apply_to(node as Window)
	scale_changed.emit(_factor)


## Native windows that appear later (context menu popups) get the factor too. `force_native` can
## be set right after construction, so look once the node has settled.
func _on_node_added(node: Node) -> void:
	if node is Window and node != get_tree().root and not node is FrameWindow:
		_adopt.call_deferred(node)


func _adopt(window: Window) -> void:
	if is_instance_valid(window) and window.force_native:
		window.add_to_group(&"ui_scaled_windows")
		_apply_to(window)
