## Remembers the main window's screen, mode, position and size between launches.
##
## Stored as internal (unregistered) UI state under `window/main` in config.json via
## `_sonara().get_config` / `set_config` / `save_config`:
## `{screen: int, mode: "windowed"|"maximized", position: [x, y], size: [w, h]}`.
## `position` and `size` are the last *windowed* rectangle in screen pixels, so un-maximizing after
## a restart returns to a sensible size. Saved on quit (`save_now`) and every `SAVE_INTERVAL`
## seconds (only when something changed) in case the app crashes.
##
## Restore clamps the rectangle to a connected screen. Wayland does not let a client place its
## window, so only size and maximized state come back there. Does nothing in test mode or when
## embedded in the Godot editor.
class_name WindowGeometry extends Node

const CONFIG_KEY := "window/main"
## Seconds between writes (the window rectangle is sampled every second).
const SAVE_INTERVAL := 10

var _window: Window
var _windowed_rect := Rect2i()
var _timer: Timer
var _ticks := 0


## True where saving and restoring are skipped.
static func disabled() -> bool:
	return Utils.is_test_mode() or Engine.is_embedded_in_editor()


## `rect` moved/shrunk to lie inside `area` (the usable rect of a screen). Size is limited to the
## area and raised to `min_size` where the area allows.
static func clamp_to_area(rect: Rect2i, area: Rect2i, min_size: Vector2i = Vector2i.ZERO) -> Rect2i:
	var size := rect.size.min(area.size).max(min_size.min(area.size))
	var pos := rect.position.clamp(area.position, area.end - size)
	return Rect2i(pos, size)


## Index of the screen that holds the centre of `rect`, else `fallback` when it is a valid screen,
## else -1.
static func screen_for(rect: Rect2i, screen_rects: Array[Rect2i], fallback: int) -> int:
	var centre := rect.position + rect.size / 2
	for i in screen_rects.size():
		if screen_rects[i].has_point(centre):
			return i
	return fallback if fallback >= 0 and fallback < screen_rects.size() else -1


## Whether `rect` just fills `area`, as a window caught half way into maximizing does.
static func fills_area(rect: Rect2i, area: Rect2i) -> bool:
	return rect.size.x >= area.size.x and rect.size.y >= area.size.y


func _init(window: Window = null) -> void:
	name = "WindowGeometry"
	_window = window


func _ready() -> void:
	if disabled():
		return
	if _window == null:
		_window = get_window()
	restore()
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	_timer.start()


## The Sonara autoload by path, so this script compiles without the autoload (headless tests).
func _sonara() -> Node:
	return get_node("/root/Sonara")


func _screen_usable_rects() -> Array[Rect2i]:
	var rects: Array[Rect2i] = []
	for i in DisplayServer.get_screen_count():
		rects.append(DisplayServer.screen_get_usable_rect(i))
	return rects


func restore() -> void:
	var saved: Variant = _sonara().get_config(CONFIG_KEY, null)
	if not saved is Dictionary:
		return
	var pos_a: Variant = saved.get("position", null)
	var size_a: Variant = saved.get("size", null)
	if not (size_a is Array and size_a.size() == 2):
		return
	var rect := Rect2i(Vector2i.ZERO, Vector2i(int(size_a[0]), int(size_a[1])))
	var has_pos: bool = pos_a is Array and pos_a.size() == 2
	if has_pos:
		rect.position = Vector2i(int(pos_a[0]), int(pos_a[1]))
	if rect.size.x < 100 or rect.size.y < 100:
		return
	var rects := _screen_usable_rects()
	if rects.is_empty():
		return
	var fallback := int(saved.get("screen", -1))
	var screen := screen_for(rect, rects, fallback)
	if screen < 0:
		screen = DisplayServer.get_primary_screen()
		# The saved position belongs to a screen that is gone: centre on the primary one.
		rect.position = rects[screen].position + (rects[screen].size - rect.size) / 2
	var fitted := clamp_to_area(rect, rects[screen], _window.min_size)
	_window.mode = Window.MODE_WINDOWED
	_window.size = fitted.size
	if has_pos and DisplayServer.get_name() != "Wayland":
		_window.position = fitted.position
	_windowed_rect = fitted
	if str(saved.get("mode", "windowed")) == "maximized":
		_window.mode = Window.MODE_MAXIMIZED


## Track the windowed rectangle (cheap; no disk I/O).
func sample() -> void:
	if _window == null or _window.mode != Window.MODE_WINDOWED:
		return
	var rect := Rect2i(_window.position, _window.size)
	var area := DisplayServer.screen_get_usable_rect(_window.current_screen)
	# A window caught half way into maximizing still reports windowed mode.
	if area.has_area() and fills_area(rect, area) and _windowed_rect.has_area():
		return
	_windowed_rect = rect


func _current_state() -> Dictionary:
	return {
		"screen": _window.current_screen,
		"mode": "maximized" if _window.mode == Window.MODE_MAXIMIZED else "windowed",
		"position": [_windowed_rect.position.x, _windowed_rect.position.y],
		"size": [_windowed_rect.size.x, _windowed_rect.size.y],
	}


## Write the window state to config.json when it differs from what is stored.
func save_now() -> void:
	if disabled() or _window == null:
		return
	sample()
	if not _windowed_rect.has_area() or _window.mode == Window.MODE_MINIMIZED:
		return
	var state := _current_state()
	if _sonara().get_config(CONFIG_KEY, null) == state:
		return
	_sonara().set_config(CONFIG_KEY, state)
	_sonara().save_config()


func _on_tick() -> void:
	sample()
	_ticks += 1
	if _ticks >= SAVE_INTERVAL:
		_ticks = 0
		save_now()
