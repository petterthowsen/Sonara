# ClipInstanceCreateCommand.gd
# Undoable creation of a clip instance (optionally adding the clip to the project pool).
class_name ClipInstanceCreateCommand extends Command

## Track that owns the instance.
var track: Track = null

## Clip content referenced by the instance.
var clip: Clip = null

## Project that owns the clip pool (needed when creating the clip too).
var project: Project = null

## Whether this command also added `clip` to the project pool.
var added_clip_to_project: bool = false

## The instance (kept for identity-preserving undo/redo).
var instance: ClipInstance = null

## Start position used when (re)creating.
var start_ticks: int = 0

## Duration used when (re)creating.
var duration_ticks: int = -1


## Create a command that adds clip (+optional pool add) and creates an instance.
func _init(
	p_track: Track = null,
	p_clip: Clip = null,
	p_start: int = 0,
	p_duration: int = -1,
	p_project: Project = null,
	p_added_clip: bool = false,
	p_instance: ClipInstance = null
) -> void:
	name = "Create Clip"
	track = p_track
	clip = p_clip
	start_ticks = p_start
	duration_ticks = p_duration
	project = p_project
	added_clip_to_project = p_added_clip
	instance = p_instance


## Create instance (and clip in pool if needed).
func do() -> void:
	if track == null or clip == null:
		return
	if added_clip_to_project and project != null:
		if not project.clips.has(clip.id):
			project.add_clip(clip)
	if instance != null:
		if instance in track.clip_instances:
			return
		instance.start_ticks = start_ticks
		if duration_ticks > 0:
			instance.duration_ticks = duration_ticks
		track.add_clip_instance(instance)
	else:
		instance = track.create_clip_instance(clip, start_ticks, duration_ticks)


## Remove instance (and clip from pool if we added it and nothing else references it).
func undo() -> void:
	if track == null or instance == null:
		return
	track.remove_clip_instance(instance)
	if added_clip_to_project and project != null and clip != null:
		if project.get_clip_instance_count(clip.id) == 0:
			project.remove_clip(clip.id)
