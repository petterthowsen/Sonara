# TrackDeleteCommand.gd
# Undoable track deletion (keeps Track + linked Channel for redo).
class_name TrackDeleteCommand extends Command

## Project that owns the track.
var project: Project = null

## Track being deleted (subtree root).
var track: Track = null

## Full subtree being deleted: `track` plus every descendant, in the order
## they must be re-added on undo (parents before children).
var _subtree: Array[Track] = []

## Layout snapshot (parent_track_id/order/child_track_ids/channel nest) for
## every track in the project, captured just before deletion, so undo can
## restore the deleted subtree's position among its siblings.
var _layout_snapshot: Dictionary = {}


## Create a delete-track command (mirrors Project.remove_track; does not remove channels).
func _init(p_project: Project = null, p_track: Track = null) -> void:
	name = "Delete Track"
	project = p_project
	track = p_track


## Remove the track (and its full subtree) from the project.
func do() -> void:
	if project == null or track == null:
		return

	# Snapshot the subtree and current layout before anything is removed,
	# so undo can restore children and position (parent + index among
	# siblings), not just the top track.
	_subtree = _collect_subtree(track)
	_layout_snapshot = TrackReorderCommand.capture_layout(project)

	project.remove_track(track.id)


## Re-add the deleted subtree and restore its layout.
func undo() -> void:
	if project == null or track == null:
		return

	for t in _subtree:
		if project.get_track_by_id(t.id) == null:
			project.add_track(t)

	if not _layout_snapshot.is_empty():
		project.apply_track_layout(_layout_snapshot)


## Collect `root` and all of its descendants (parents before children).
func _collect_subtree(root: Track) -> Array[Track]:
	var result: Array[Track] = [root]
	for child in project.get_track_children(root):
		result.append_array(_collect_subtree(child))
	return result
