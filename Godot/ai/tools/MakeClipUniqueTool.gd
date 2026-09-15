# MakeClipUniqueTool.gd
class_name MakeClipUniqueTool extends AiTool


func get_name() -> String:
	return "make_clip_unique"


func get_description() -> String:
	return "Give one placement of a shared clip its own copy, so write_clip can change it without affecting the other placements. Returns the new clip name."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"clip": {"type": "string", "description": "Shared clip name"},
			"track": {"type": "string", "description": "Track of the placement to copy"},
			"start": {"type": "string", "description": "bar.beat.tick or bar number of the placement to copy"},
		},
		"required": ["clip"],
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
	var all_instances := find_clip_instances(project, clip.id)
	if all_instances.size() <= 1:
		return fail("\"%s\" has only one placement, so it is not shared; edit it directly with write_clip" % clip.name)

	var instances := all_instances
	if args.has("track"):
		var track_v = resolve_track(project, args)
		if track_v is Dictionary:
			return track_v
		var track: Track = track_v
		instances = instances.filter(func(inst): return inst.track == track)
	if args.has("start"):
		var start_ticks := resolve_start_ticks(project, args)
		instances = instances.filter(func(inst): return inst.start_ticks == start_ticks)

	if instances.is_empty():
		return fail("No placement of \"%s\" matches. Placements: %s" % [clip.name, _describe(project, all_instances)])
	if instances.size() > 1:
		return fail("\"%s\" has %d matching placements (%s); pass track and start to pick one" % [
			clip.name, instances.size(), _describe(project, instances)
		])

	var instance: ClipInstance = instances[0]
	HistoryUtil.execute(MakeClipUniqueCommand.new(project, instance))
	var new_clip: Clip = instance.clip
	return ok_text(
		"The placement at %s is now its own clip \"%s\". Use that name to edit it; \"%s\" keeps its other placements." % [
			_describe(project, [instance]), new_clip.name, clip.name
		],
		compact_clip(project, new_clip)
	)


## "Track @ bar.beat.tick, ..." for a list of instances.
func _describe(project: Project, instances: Array) -> String:
	var descs: PackedStringArray = []
	for inst in instances:
		var c := compact_instance(project, inst)
		descs.append("%s @ %s" % [c.track, c.start])
	return ", ".join(descs)
