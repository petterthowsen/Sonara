@tool
## Pointer tracker for absolute-position sliders with Shift precision.
## Follows the mouse 1:1, but while Shift is held it moves at `scale`. The tracked
## point never snaps back to the real pointer, so pressing or releasing Shift
## mid-drag doesn't make the value jump.
class_name FineDrag extends RefCounted

## Motion multiplier while Shift is held.
const DEFAULT_SCALE := 0.15

var scale := DEFAULT_SCALE
var _point := Vector2.ZERO
var _last_mouse := Vector2.ZERO


func _init(fine_scale: float = DEFAULT_SCALE) -> void:
	scale = fine_scale


## Start tracking at `mouse` (the press position, which the value jumps to).
func begin(mouse: Vector2) -> Vector2:
	_point = mouse
	_last_mouse = mouse
	return _point


## Advance by the mouse motion since the last call and return the tracked point,
## clamped to `bounds` when it has an area.
func update(mouse: Vector2, fine: bool, bounds := Rect2()) -> Vector2:
	var delta := mouse - _last_mouse
	_last_mouse = mouse
	_point += delta * (scale if fine else 1.0)
	if bounds.has_area():
		_point = _point.clamp(bounds.position, bounds.end)
	return _point


## Start from a point other than the mouse (for controls that grab a handle
## without moving the value on press).
func begin_at(point: Vector2, mouse: Vector2) -> void:
	_point = point
	_last_mouse = mouse
