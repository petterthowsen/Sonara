# ClipActions.gd
# Undoable clip creation shared by the timeline, the note editor and the AI tools.
class_name ClipActions extends RefCounted


## An empty `clip_name` names the clip after `track` (see `ClipNaming`); a given name is custom.
## Create an empty clip (MIDI by default) in `project`'s pool, colored like `track`, and place one instance of
## `length_ticks` at `start_ticks`. Recorded as one "Create Clip" step. Returns the instance.
static func create_clip(
	project: Project,
	track: Track,
	start_ticks: int,
	length_ticks: int,
	clip_name: String = "",
	clip_type: Clip.ClipType = Clip.ClipType.MIDI
) -> ClipInstance:
	if project == null or track == null:
		return null
	var auto_named := clip_name.is_empty()
	var clip := project.create_clip(ClipNaming.next_name(project, track) if auto_named else clip_name, clip_type)
	if auto_named:
		clip.auto_name_track = track.name
	clip.color = track.get_color()
	clip.content_length_ticks = length_ticks
	var cmd := ClipInstanceCreateCommand.new(track, clip, start_ticks, length_ticks, project, true)
	HistoryUtil.execute(cmd)
	return cmd.instance
