# AutomationLaneCreateCommand.gd
# Undoable creation of an automation lane on a track.
class_name AutomationLaneCreateCommand extends Command

## Track the lane is attached to / detached from.
var track: Object = null

## The lane being created.
var lane: Object = null


func _init(p_name: String = "Create Lane", p_track: Object = null, p_lane: Object = null) -> void:
	name = p_name
	track = p_track
	lane = p_lane


## Attach the lane to the track (syncs to the engine when connected).
func do() -> void:
	if track == null or lane == null:
		return
	track.add_automation_lane(lane)


## Detach the lane from the track (deletes it from the engine when connected).
func undo() -> void:
	if track == null or lane == null:
		return
	track.remove_automation_lane(lane)
