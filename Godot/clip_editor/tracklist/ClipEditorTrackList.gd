# List of tracks for ClipEditor track-mode view
class_name ClipEditorTrackList extends PanelContainer

const ListItemScene = preload("res://clip_editor/tracklist/ClipEditorTrackListItem.tscn")

@onready var items: VBoxContainer = $Items

var tracks: Array[Track] = []
var selected_track: Track = null

signal track_selected(track: Track)


func _ready() -> void:
	clear()


func set_tracks(track_list: Array[Track]):
	"""Set the track list and create track items."""
	clear()
	
	for track in track_list:
		if track:
			tracks.append(track)
			_create_track_item(track)


func set_tracks_from_clips(clip_instances: Array[ClipInstance]):
	"""Extract unique tracks from clip instances and set them."""
	clear()
	
	for ci in clip_instances:
		if ci.track and not tracks.has(ci.track):
			tracks.append(ci.track)
			_create_track_item(ci.track)


func clear():
	"""Remove all track items from the list."""
	tracks.clear()
	for ti in items.get_children():
		if ti is ClipEditorTrackListItem:
			ti.free()


func _create_track_item(track: Track) -> ClipEditorTrackListItem:
	"""Create and add a track list item."""
	var item = ListItemScene.instantiate() as ClipEditorTrackListItem
	item.track = track
	item.pressed.connect(_on_item_pressed.bind(track))
	items.add_child(item)
	return item


func select_track(t: Track):
	"""Select a track and emit signal."""
	select_track_no_signal(t)
	track_selected.emit(t)


func select_track_no_signal(t: Track):
	"""Select a track without emitting signal."""
	if not tracks.has(t):
		push_error("Cannot select track %s in ClipEditorTrackList. Not part of list." % t.name)
		return
	
	selected_track = t
	_update_selection()


func _update_selection():
	"""Update visual selection state of all items."""
	for ti in items.get_children():
		ti.set_selected(ti.track == selected_track)


func _on_item_pressed(track: Track):
	"""Handle track item press."""
	selected_track = track
	_update_selection()
	track_selected.emit(track)
