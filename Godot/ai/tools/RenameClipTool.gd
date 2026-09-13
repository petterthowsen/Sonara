# RenameClipTool.gd
class_name RenameClipTool extends AiTool


func get_name() -> String:
	return "rename_clip"


func get_description() -> String:
	return "Rename a clip. Every instance on the timeline shows the new name. Names must stay unique."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"clip": {"type": "string", "description": "Current clip name or clip_id"},
			"clip_id": {"type": "string", "description": "Clip id if the name is ambiguous"},
			"name": {"type": "string", "description": "New unique name"},
		},
		"required": ["clip", "name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var clip_v = resolve_clip(project, args)
	if clip_v is Dictionary:
		return clip_v
	var clip: Clip = clip_v
	var new_name := str(args.get("name", "")).strip_edges()
	if new_name.is_empty():
		return fail("name is required")
	for other in project.clips.values():
		if other is Clip and other != clip and other.name.to_lower() == new_name.to_lower():
			return fail("A clip named '%s' already exists" % other.name)
	HistoryUtil.execute_property("Rename Clip", clip, "set_name", clip.name, new_name)
	return ok(compact_clip(project, clip))
