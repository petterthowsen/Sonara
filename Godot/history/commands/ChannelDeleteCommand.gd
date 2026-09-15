# ChannelDeleteCommand.gd
# Undoable mixer channel deletion: the channel, its aux returns, and every track linked to them
# (keeps Channel + Track identity for redo).
class_name ChannelDeleteCommand extends Command

## Project that owns the channel.
var project: Project = null

## Channel being deleted.
var channel: Channel = null

## What the last do() removed and how to put it back.
var _snapshot: LinkedDeleteSnapshot = null


## Create a delete-channel command.
func _init(p_project: Project = null, p_channel: Channel = null) -> void:
	name = "Delete Channel"
	project = p_project
	channel = p_channel


## Remove the channel and its linked tracks.
func do() -> void:
	if project == null or channel == null or channel.is_master:
		return
	var roots: Array[Channel] = [channel]
	_snapshot = LinkedDeleteSnapshot.new(project, [] as Array[Track], roots)
	name = "Delete Channel and Track" if not _snapshot.tracks.is_empty() else "Delete Channel"
	_snapshot.remove()


## Re-add the deleted channels and tracks and restore routing and layout.
func undo() -> void:
	if _snapshot != null:
		_snapshot.restore()


## Tracks removed by the last do() (empty before the first do()).
func removed_tracks() -> Array[Track]:
	return _snapshot.tracks if _snapshot else ([] as Array[Track])
