# MakeClipUniquePerTrackCommand.gd
# Undoable "Make Unique Per Track" — one new copy of a clip for a track, shared by every given
# instance on that track. Instances on other tracks keep the original clip.
class_name MakeClipUniquePerTrackCommand extends MakeClipUniqueCommand

## Instances that move to the per-track copy (all on the same track, all using `original_clip`).
var instances: Array[ClipInstance] = []


func _init(p_project: Project = null, p_instances: Array[ClipInstance] = []) -> void:
	super._init(p_project, p_instances[0] if not p_instances.is_empty() else null)
	name = "Make Clip Unique Per Track"
	instances = p_instances.duplicate()


## Instances of `anchor`'s clip on `anchor`'s own track (including `anchor`).
static func same_track_instances(anchor: ClipInstance) -> Array[ClipInstance]:
	var result: Array[ClipInstance] = []
	if anchor == null or anchor.track == null:
		return result
	for inst in anchor.track.clip_instances:
		if inst.clip == anchor.clip:
			result.append(inst)
	return result


## True when `anchor`'s clip is also used on another track.
static func is_shared_across_tracks(project: Project, anchor: ClipInstance) -> bool:
	if project == null or anchor == null or anchor.clip == null or anchor.track == null:
		return false
	return project.get_clip_instance_count(anchor.clip.id) > same_track_instances(anchor).size()


func do() -> void:
	if project == null or instances.is_empty() or original_clip == null:
		return
	if unique_clip == null:
		unique_clip = _duplicate_clip(original_clip)
	if not project.clips.has(unique_clip.id):
		project.add_clip(unique_clip)
	for inst in instances:
		inst.set_clip(unique_clip)
		instance = inst
		_resync_instance()


func undo() -> void:
	if project == null or instances.is_empty() or original_clip == null:
		return
	for inst in instances:
		inst.set_clip(original_clip)
		instance = inst
		_resync_instance()
	if unique_clip != null and project.get_clip_instance_count(unique_clip.id) == 0:
		project.remove_clip(unique_clip.id)
