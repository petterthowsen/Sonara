# ClipInstanceDeleteCommand.gd
# Undoable removal of a clip instance (keeps the same RefCounted for redo).
class_name ClipInstanceDeleteCommand extends Command

## Track the instance was removed from.
var track: Track = null

## Instance kept for re-add on undo.
var instance: ClipInstance = null


## Create a delete-instance command (instance must still be on the track).
func _init(p_track: Track = null, p_instance: ClipInstance = null) -> void:
	name = "Delete Clip"
	track = p_track
	instance = p_instance


## Remove the instance from its track.
func do() -> void:
	if track == null or instance == null:
		return
	track.remove_clip_instance(instance)


## Re-add the same instance object.
func undo() -> void:
	if track == null or instance == null:
		return
	track.add_clip_instance(instance)
