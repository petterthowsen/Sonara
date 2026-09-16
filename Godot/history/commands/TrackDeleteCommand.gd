# TrackDeleteCommand.gd
# Undoable track deletion: one or more track subtrees, plus each linked mixer channel no other track
# uses unless keep_channels is set (keeps Track + Channel identity for redo).
class_name TrackDeleteCommand extends Command

## Project that owns the tracks.
var project: Project = null

## First track being deleted (subtree root).
var track: Track = null

## Every subtree root being deleted, in one undo step.
var tracks: Array[Track] = []

## When true, the tracks' mixer channels stay in the mixer.
var keep_channels: bool = false

## What the last do() removed and how to put it back.
var _snapshot: LinkedDeleteSnapshot = null


## Delete `p_track` (and `p_more_tracks`); keep their channels when `p_keep_channels`.
func _init(
	p_project: Project = null,
	p_track: Track = null,
	p_keep_channels: bool = false,
	p_more_tracks: Array[Track] = []
) -> void:
	project = p_project
	track = p_track
	keep_channels = p_keep_channels
	if p_track:
		tracks.append(p_track)
	for t in p_more_tracks:
		if t and not tracks.has(t):
			tracks.append(t)
	name = _label(false)


## Remove the track subtrees and (unless kept) their linked channels.
func do() -> void:
	if project == null or tracks.is_empty():
		return
	_snapshot = LinkedDeleteSnapshot.new(project, tracks, [] as Array[Channel], not keep_channels)
	name = _label(_snapshot.channel_count() > 0)
	_snapshot.remove()


## Re-add the deleted tracks and channels and restore routing and layout.
func undo() -> void:
	if _snapshot != null:
		_snapshot.restore()


## Channels removed by the last do() (empty before the first do()).
func removed_channels() -> Array[Channel]:
	return _snapshot.channels if _snapshot else ([] as Array[Channel])


func _label(with_channels: bool) -> String:
	var plural := tracks.size() > 1
	var base := "Delete Tracks" if plural else "Delete Track"
	if with_channels:
		return base + (" and Channels" if plural else " and Channel")
	return base
