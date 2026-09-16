# AutomationLaneDeleteCommand.gd
# Undoable deletion of an automation lane. `lane.points` is never cleared, so undo (which
# re-attaches the same lane object via Track.add_automation_lane) resyncs every point through
# AutomationLane.sync_to_engine() automatically - nothing extra to restore here.
class_name AutomationLaneDeleteCommand extends Command

## Track the lane is detached from / re-attached to.
var track: Object = null

## The lane being deleted.
var lane: Object = null


func _init(p_name: String = "Delete Lane", p_track: Object = null, p_lane: Object = null) -> void:
	name = p_name
	track = p_track
	lane = p_lane


## Detach the lane from the track (deletes it from the engine when connected).
func do() -> void:
	if track == null or lane == null:
		return
	track.remove_automation_lane(lane)


## Re-attach the lane, restoring every point via AutomationLane.sync_to_engine().
func undo() -> void:
	if track == null or lane == null:
		return
	track.add_automation_lane(lane)
