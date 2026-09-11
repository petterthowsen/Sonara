# TrackDeleteCommand.gd
# Undoable track deletion (keeps Track + linked Channel for redo).
class_name TrackDeleteCommand extends Command

## Project that owns the track.
var project: Project = null

## Track being deleted.
var track: Track = null

## Create a delete-track command (mirrors Project.remove_track; does not remove channels).
func _init(p_project: Project = null, p_track: Track = null) -> void:
	name = "Delete Track"
	project = p_project
	track = p_track


## Remove the track from the project.
func do() -> void:
	if project == null or track == null:
		return
	project.remove_track(track.id)


## Re-add the same track object.
func undo() -> void:
	if project == null or track == null:
		return
	if project.get_track_by_id(track.id) == null:
		project.add_track(track)
