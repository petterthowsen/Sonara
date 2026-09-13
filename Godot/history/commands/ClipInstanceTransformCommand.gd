# ClipInstanceTransformCommand.gd
# Undoable move/resize of a clip instance (position, duration, clip offset).
class_name ClipInstanceTransformCommand extends Command

## Instance being transformed.
var instance: ClipInstance = null

## Position/duration/offset before the gesture.
var old_start: int = 0
var old_duration: int = 0
var old_offset: int = 0

## Position/duration/offset after the gesture.
var new_start: int = 0
var new_duration: int = 0
var new_offset: int = 0


## Capture a move/resize of one clip instance.
func _init(
	p_name: String = "Move Clip",
	p_instance: ClipInstance = null,
	p_old_start: int = 0,
	p_old_duration: int = 0,
	p_old_offset: int = 0,
	p_new_start: int = 0,
	p_new_duration: int = 0,
	p_new_offset: int = 0
) -> void:
	name = p_name
	instance = p_instance
	old_start = p_old_start
	old_duration = p_old_duration
	old_offset = p_old_offset
	new_start = p_new_start
	new_duration = p_new_duration
	new_offset = p_new_offset


## Apply the new transform.
func do() -> void:
	_apply(new_start, new_duration, new_offset)


## Restore the old transform.
func undo() -> void:
	_apply(old_start, old_duration, old_offset)


## Write position, duration, and clip offset via setters.
func _apply(start: int, duration: int, offset: int) -> void:
	if instance == null:
		return
	instance.set_position(start)
	instance.set_duration(duration)
	instance.set_clip_offset(offset)
