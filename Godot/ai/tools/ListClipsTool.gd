# ListClipsTool.gd
class_name ListClipsTool extends AiTool


func get_name() -> String:
	return "list_clips"


func get_description() -> String:
	return "List named clips and every timeline placement. Same name = same clip (duplicates share notes). Optional track_id filter."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"track_id": {"type": "integer", "description": "Only clips placed on this track"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var filter_track: Track = null
	if args.has("track_id"):
		var t = resolve_track(project, args)
		if t is Dictionary:
			return t
		filter_track = t
	var seen: Dictionary = {}
	var clips: Array = []
	if filter_track:
		for inst in filter_track.clip_instances:
			if inst == null or inst.clip == null or seen.has(inst.clip.id):
				continue
			seen[inst.clip.id] = true
			clips.append(compact_clip(project, inst.clip))
	else:
		for clip_v in project.clips.values():
			if clip_v is Clip:
				clips.append(compact_clip(project, clip_v))
	return ok({"clips": clips})
