class_name TrackToggleState extends RefCounted
## Per-track visibility and editability flags for the clip editor's track list, plus the
## Shift+click "solo" behaviour for each kind. Pure state: no UI, no engine sync, not persisted.
##
## A track is only effectively editable while it is also visible (see is_editable), but its own
## edit flag is kept, so it applies again when the track is shown again.

enum Kind { VISIBLE, EDITABLE }

signal changed

# Track -> bool, one dictionary per Kind.
var _states: Array[Dictionary] = [{}, {}]
# Track order as last given to set_tracks / init_from_selection.
var _tracks: Array[Track] = []
# Per kind: the states remembered when a solo started, and the soloed track.
var _snapshots: Array[Dictionary] = [{}, {}]
var _soloed: Array[Track] = [null, null]


## Syncs the known tracks with the list. Known tracks keep their states, new tracks start
## hidden and not editable, removed tracks are forgotten. Removing a soloed track ends that solo
## and restores the remembered states.
func set_tracks(tracks: Array[Track]) -> void:
	var dirty := false
	for kind in [Kind.VISIBLE, Kind.EDITABLE]:
		var states := _states[kind]
		for track in states.keys():
			if not tracks.has(track):
				states.erase(track)
				dirty = true
		if _soloed[kind] != null and not tracks.has(_soloed[kind]):
			for track in _snapshots[kind]:
				if states.has(track):
					states[track] = _snapshots[kind][track]
			_end_solo(kind)
		for track in _snapshots[kind].keys():
			if not tracks.has(track):
				_snapshots[kind].erase(track)
		for track in tracks:
			if not states.has(track):
				states[track] = false
				dirty = true
	_tracks = tracks.duplicate()
	if dirty:
		changed.emit()


## Selected tracks start visible and editable, every other track hidden and not editable.
## Any active solo is cleared.
func init_from_selection(tracks: Array[Track], selected: Array[Track]) -> void:
	_tracks = tracks.duplicate()
	for kind in [Kind.VISIBLE, Kind.EDITABLE]:
		_states[kind].clear()
		for track in tracks:
			_states[kind][track] = selected.has(track)
		_end_solo(kind)
	changed.emit()


func is_on(track: Track, kind: int) -> bool:
	return _states[kind].get(track, false)


## Effectively editable: visible and edit flag on.
func is_editable(track: Track) -> bool:
	return is_on(track, Kind.VISIBLE) and is_on(track, Kind.EDITABLE)


## Sets one state. Setting the value a track already has does nothing. Changing a value while
## that kind is soloed ends the solo and keeps the current states.
func set_on(track: Track, kind: int, on: bool) -> void:
	if not _states[kind].has(track) or _states[kind][track] == on:
		return
	_end_solo(kind)
	_states[kind][track] = on
	changed.emit()


## True when every one of `tracks` has this kind on (false for an empty list).
func all_on(tracks: Array[Track], kind: int) -> bool:
	if tracks.is_empty():
		return false
	for track in tracks:
		if not is_on(track, kind):
			return false
	return true


## Sets this kind for all of `tracks` at once (the global toggles). Ends any solo of the kind.
func set_all(tracks: Array[Track], kind: int, on: bool) -> void:
	_end_solo(kind)
	for track in tracks:
		if _states[kind].has(track):
			_states[kind][track] = on
	changed.emit()


## Shift+click: solo `track` for this kind, or revert when it is already the soloed track.
## Moving the solo to another track keeps the originally remembered states.
func toggle_solo(track: Track, kind: int) -> void:
	if not _states[kind].has(track):
		return
	var states := _states[kind]
	if _soloed[kind] == track:
		for t in _snapshots[kind]:
			if states.has(t):
				states[t] = _snapshots[kind][t]
		_end_solo(kind)
	else:
		if _soloed[kind] == null:
			_snapshots[kind] = states.duplicate()
		_soloed[kind] = track
		for t in states.keys():
			states[t] = (t == track)
	changed.emit()


## The soloed track for this kind, or null when it is not soloed.
func soloed_track(kind: int) -> Track:
	return _soloed[kind]


## First effectively editable track, in the order given (null if none).
func first_editable(tracks: Array[Track]) -> Track:
	for track in tracks:
		if is_editable(track):
			return track
	return null


func _end_solo(kind: int) -> void:
	_soloed[kind] = null
	_snapshots[kind] = {}
