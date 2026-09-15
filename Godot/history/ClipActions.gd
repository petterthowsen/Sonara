# ClipActions.gd
# Undoable clip creation shared by the timeline, the note editor and the AI tools.
class_name ClipActions extends RefCounted


## Create an empty clip (MIDI by default) in `project`'s pool, colored like `track`, and place one instance of
## `length_ticks` at `start_ticks`. Recorded as one "Create Clip" step. Returns the instance.
static func create_clip(
	project: Project,
	track: Track,
	start_ticks: int,
	length_ticks: int,
	clip_name: String,
	clip_type: Clip.ClipType = Clip.ClipType.MIDI
) -> ClipInstance:
	if project == null or track == null:
		return null
	var clip := project.create_clip(clip_name, clip_type)
	clip.color = track.get_color()
	clip.content_length_ticks = length_ticks
	var cmd := ClipInstanceCreateCommand.new(track, clip, start_ticks, length_ticks, project, true)
	HistoryUtil.execute(cmd)
	return cmd.instance
