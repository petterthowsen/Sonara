# TrackDeleteCommand.gd
# Undoable track deletion: the track subtree plus each linked mixer channel no other track uses
# (keeps Track + Channel identity for redo).
class_name TrackDeleteCommand extends Command

## Project that owns the track.
var project: Project = null

## Track being deleted (subtree root).
var track: Track = null

## What the last do() removed and how to put it back.
var _snapshot: LinkedDeleteSnapshot = null


## Create a delete-track command.
func _init(p_project: Project = null, p_track: Track = null) -> void:
	name = "Delete Track"
	project = p_project
	track = p_track


## Remove the track subtree and its linked channels.
func do() -> void:
	if project == null or track == null:
		return
	var roots: Array[Track] = [track]
	_snapshot = LinkedDeleteSnapshot.new(project, roots)
	name = "Delete Track and Channel" if _snapshot.channel_count() > 0 else "Delete Track"
	_snapshot.remove()


## Re-add the deleted tracks and channels and restore routing and layout.
func undo() -> void:
	if _snapshot != null:
		_snapshot.restore()


## Channels removed by the last do() (empty before the first do()).
func removed_channels() -> Array[Channel]:
	return _snapshot.channels if _snapshot else ([] as Array[Channel])
