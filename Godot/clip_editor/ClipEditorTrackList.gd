# List of tracks
class_name ClipEditorTrackList extends ItemList

var tracks : Array[Track] = []

var selected_track : Track = null

signal track_selected(tack : Track)

func set_tracks(track_list: Array[Track]):
	"""Set the track list directly."""
	tracks.clear()
	clear()
	
	for track in track_list:
		if track:
			tracks.append(track)
			add_item(track.name)


func set_tracks_from_clips(clipInstances : Array[ClipInstance]):
	"""Extract unique tracks from clip instances and set them."""
	tracks.clear()
	clear()
	
	for ci in clipInstances:
		if not tracks.has(ci.track):
			tracks.append(ci.track)
			add_item(ci.track.name)

func select_track(t : Track):
	select_track_no_signal(t)
	track_selected.emit(t)

func select_track_no_signal(t : Track):
	if not tracks.has(t):
		push_error("Cannot select track ", t.name, " in ClipEditorTrackList. Not part of list.")
		return
	
	var idx = tracks.find(t)
	select(idx, true) # single select

func _ready() -> void:
	item_selected.connect(_on_item_selected)

func _on_item_selected(idx : int):
	var track := tracks[idx]
	selected_track = track
	track_selected.emit(track)
