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


## The clip's name and automatic-name track before this move renamed it (`_renamed` is false when it did not).
var _renamed: bool = false
var _old_name: String = ""
var _old_auto_track: String = ""


## Move to destination track at new_start. A clip with an automatic name that now lives on the
## destination track alone takes that track's name.
func do() -> void:
	_move(from_track, to_track, new_start)
	_rename_for_destination()


## Move back to source track at old_start, restoring the name.
func undo() -> void:
	if _renamed and instance != null and instance.clip != null:
		instance.clip.set_naming(_old_name, _old_auto_track)
	_renamed = false
	_move(to_track, from_track, old_start)


func _rename_for_destination() -> void:
	_renamed = false
	var clip: Clip = instance.clip if instance != null else null
	var project: Project = to_track.get_project_ref() if to_track != null else null
	if clip == null or project == null:
		return
	for other in project.tracks:
		if other == to_track:
			continue
		for inst in other.clip_instances:
			if inst.clip == clip:
				return
	var new_name := ClipNaming.name_after_track_change(project, clip, to_track)
	if new_name.is_empty():
		return
	_old_name = clip.name
	_old_auto_track = clip.auto_name_track
	_renamed = true
	clip.set_naming(new_name, to_track.name)


## Remove from one track and add to another, then set position.
func _move(src: Track, dst: Track, start: int) -> void:
	if instance == null or src == null or dst == null:
		return
	if instance.track == src:
		src.remove_clip_instance(instance)
	if instance.track != dst:
		dst.add_clip_instance(instance)
	instance.set_position(start)
