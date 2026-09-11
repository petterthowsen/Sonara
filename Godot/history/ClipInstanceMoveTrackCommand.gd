# ClipInstanceMoveTrackCommand.gd
# Undoable move of a clip instance between tracks (same object identity).
class_name ClipInstanceMoveTrackCommand extends Command

## Instance being moved between tracks.
var instance: ClipInstance = null

## Source track.
var from_track: Track = null

## Destination track.
var to_track: Track = null

## Start ticks before the move.
var old_start: int = 0

## Start ticks after the move.
var new_start: int = 0


## Move an instance from one track to another (same object identity).
func _init(
	p_instance: ClipInstance = null,
	p_from: Track = null,
	p_to: Track = null,
	p_old_start: int = 0,
	p_new_start: int = 0
) -> void:
	name = "Move Clip to Track"
	instance = p_instance
	from_track = p_from
	to_track = p_to
	old_start = p_old_start
	new_start = p_new_start


## Move to destination track at new_start.
func do() -> void:
	_move(from_track, to_track, new_start)


## Move back to source track at old_start.
func undo() -> void:
	_move(to_track, from_track, old_start)


## Remove from one track and add to another, then set position.
func _move(src: Track, dst: Track, start: int) -> void:
	if instance == null or src == null or dst == null:
		return
	if instance.track == src:
		src.remove_clip_instance(instance)
	if instance.track != dst:
		dst.add_clip_instance(instance)
	instance.set_position(start)
