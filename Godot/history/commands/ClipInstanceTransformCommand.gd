# ClipInstanceTransformCommand.gd
# Undoable move/resize of a clip instance (position, duration, clip offset), optionally with its loop and the source clip's length.
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

## Loop state [enabled, start_ticks, length_ticks] before/after the gesture; empty leaves the loop alone.
var old_loop: Array = []
var new_loop: Array = []

## Source clip content length before/after; -1 leaves the clip's length alone.
var old_content_length: int = -1
var new_content_length: int = -1


## Capture a move/resize of one clip instance.
func _init(
	p_name: String = "Move Clip",
	p_instance: ClipInstance = null,
	p_old_start: int = 0,
	p_old_duration: int = 0,
	p_old_offset: int = 0,
	p_new_start: int = 0,
	p_new_duration: int = 0,
	p_new_offset: int = 0,
	p_old_loop: Array = [],
	p_new_loop: Array = [],
	p_old_content_length: int = -1,
	p_new_content_length: int = -1
) -> void:
	name = p_name
	instance = p_instance
	old_start = p_old_start
	old_duration = p_old_duration
	old_offset = p_old_offset
	new_start = p_new_start
	new_duration = p_new_duration
	new_offset = p_new_offset
	old_loop = p_old_loop
	new_loop = p_new_loop
	old_content_length = p_old_content_length
	new_content_length = p_new_content_length


## Apply the new transform.
func do() -> void:
	_apply(new_start, new_duration, new_offset, new_loop, new_content_length)


## Restore the old transform.
func undo() -> void:
	_apply(old_start, old_duration, old_offset, old_loop, old_content_length)


## Write position, duration, clip offset and loop via setters.
func _apply(start: int, duration: int, offset: int, loop: Array, content_length: int) -> void:
	if instance == null:
		return
	instance.set_position(start)
	instance.set_duration(duration)
	if content_length >= 0 and instance.clip:
		instance.clip.set_content_length(content_length)
	instance.set_clip_offset(offset)
	if loop.size() == 3:
		instance.set_loop(loop[0], loop[1], loop[2])
