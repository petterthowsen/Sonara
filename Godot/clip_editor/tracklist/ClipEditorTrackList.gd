# List of tracks for ClipEditor track-mode view
class_name ClipEditorTrackList extends PanelContainer

const ListItemScene = preload("res://clip_editor/tracklist/ClipEditorTrackListItem.tscn")

@onready var scroll: ScrollContainer = $Scroll
@onready var items: VBoxContainer = $Scroll/Items

var tracks: Array[Track] = []
var selected_track: Track = null

var project: Project = null
var toggle_state: TrackToggleState = null

# Drag-to-paint: while the left button is held after a plain press on a toggle, every item the
# pointer passes gets `_paint_value` for `_paint_kind`.
var _painting := false
var _paint_kind := 0
var _paint_value := false
var _rebuild_queued := false

signal track_selected(track: Track)
## The listed tracks changed (project add/remove/reorder).
signal tracks_changed


func _ready() -> void:
	clear()


## Lists every instrument track of `p`, in visual order, and follows the project's changes.
func set_project(p: Project) -> void:
	if project == p:
		return
	if project:
		project.track_added.disconnect(_on_project_tracks_changed)
		project.track_removed.disconnect(_on_project_tracks_changed)
		project.tracks_layout_changed.disconnect(_queue_rebuild)
	_disconnect_track_orders()
	project = p
	if project:
		project.track_added.connect(_on_project_tracks_changed)
		project.track_removed.connect(_on_project_tracks_changed)
		project.tracks_layout_changed.connect(_queue_rebuild)
	_rebuild()


## Rebuilds from the project right now (instead of at the end of the frame).
func rebuild_now() -> void:
	_rebuild()


func set_toggle_state(state: TrackToggleState) -> void:
	if toggle_state and toggle_state.changed.is_connected(_refresh_toggles):
		toggle_state.changed.disconnect(_refresh_toggles)
	toggle_state = state
	if toggle_state:
		toggle_state.changed.connect(_refresh_toggles)
	_refresh_toggles()


func listed_tracks() -> Array[Track]:
	return tracks.duplicate()


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
	_painting = false
	tracks.clear()
	for ti in items.get_children():
		if ti is ClipEditorTrackListItem:
			ti.free()


func _create_track_item(track: Track) -> ClipEditorTrackListItem:
	"""Create and add a track list item."""
	var item = ListItemScene.instantiate() as ClipEditorTrackListItem
	item.track = track
	item.pressed.connect(_on_item_pressed.bind(track))
	item.toggle_pressed.connect(_on_item_toggle_pressed.bind(track))
	items.add_child(item)
	item.set_selected(track == selected_track)
	item.refresh_toggles(toggle_state)
	return item


func _disconnect_track_orders() -> void:
	for t in tracks:
		if t.order_changed.is_connected(_on_track_order_changed):
			t.order_changed.disconnect(_on_track_order_changed)


func _on_project_tracks_changed(_track: Track) -> void:
	_queue_rebuild()


func _on_track_order_changed(_order: int) -> void:
	_queue_rebuild()


## Coalesces bursts of add/remove/reorder signals into one rebuild.
func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


## Rebuilds the items from the project. The selection is kept when its track is still listed.
func _rebuild() -> void:
	_rebuild_queued = false
	_disconnect_track_orders()
	var kept := selected_track
	clear()
	if project:
		for t in project.get_visual_track_list():
			if t.type == Track.TrackType.INSTRUMENT:
				tracks.append(t)
				t.order_changed.connect(_on_track_order_changed)
	selected_track = kept if tracks.has(kept) else null
	for t in tracks:
		_create_track_item(t)
	tracks_changed.emit()


func _refresh_toggles() -> void:
	for ti in items.get_children():
		if ti is ClipEditorTrackListItem:
			ti.refresh_toggles(toggle_state)


func _on_item_toggle_pressed(kind: int, shift: bool, track: Track) -> void:
	if not toggle_state:
		return
	if shift:
		toggle_state.toggle_solo(track, kind)
		return
	_paint_kind = kind
	_paint_value = not toggle_state.is_on(track, kind)
	_painting = true
	toggle_state.set_on(track, kind, _paint_value)


func _input(event: InputEvent) -> void:
	if not _painting:
		return
	if event is InputEventMouseMotion:
		var item := _item_at_global_y(event.global_position.y)
		if item:
			toggle_state.set_on(item.track, _paint_kind, _paint_value)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed:
		_painting = false


## The item whose rect contains global `y`, or null (e.g. in the gap between items).
func _item_at_global_y(y: float) -> ClipEditorTrackListItem:
	# Items scrolled out of view can't be painted.
	var view: Rect2 = scroll.get_global_rect()
	if y < view.position.y or y >= view.end.y:
		return null
	for ti in items.get_children():
		if ti is ClipEditorTrackListItem:
			var r: Rect2 = ti.get_global_rect()
			if y >= r.position.y and y < r.end.y:
				return ti
	return null


func select_track(t: Track):
	"""Select a track and emit signal."""
	select_track_no_signal(t)
	track_selected.emit(t)


func select_track_no_signal(t: Track):
	"""Select a track without emitting signal. null clears the selection."""
	if t == null:
		selected_track = null
		_update_selection()
		return
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
