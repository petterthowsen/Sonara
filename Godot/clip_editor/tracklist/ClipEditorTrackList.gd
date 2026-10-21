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
# True for a drag that started on an item body (shows the passed items) rather than a toggle.
var _painting_items := false
var _paint_shift := false
var _paint_kind := 0
var _paint_value := false
var _rebuild_queued := false
var _watched_groups: Array[Track] = []
var _watched_channels: Array[Channel] = []

signal track_selected(track: Track)
## Shift+press on an item: select it without taking editing away from other tracks.
signal track_selected_additive(track: Track)
## The listed tracks changed (project add/remove/reorder).
signal tracks_changed


func _ready() -> void:
	clear()


## Lists every instrument track of `p` (and group track that holds MIDI clips or note/instrument
## devices, see Track.is_note_editor_track), in visual order, and follows the project's changes.
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
	_painting_items = false
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
	# Groups are watched whether or not they are listed, so one can enter the list.
	for t in _watched_groups:
		if is_instance_valid(t):
			if t.clip_instance_added.is_connected(_on_group_content_changed):
				t.clip_instance_added.disconnect(_on_group_content_changed)
			if t.clip_instance_removed.is_connected(_on_group_content_changed):
				t.clip_instance_removed.disconnect(_on_group_content_changed)
	_watched_groups.clear()
	for ch in _watched_channels:
		if is_instance_valid(ch):
			if ch.device_added.is_connected(_on_group_devices_changed):
				ch.device_added.disconnect(_on_group_devices_changed)
			if ch.device_removed.is_connected(_on_group_devices_changed):
				ch.device_removed.disconnect(_on_group_devices_changed)
	_watched_channels.clear()


func _watch_group(t: Track) -> void:
	_watched_groups.append(t)
	t.clip_instance_added.connect(_on_group_content_changed)
	t.clip_instance_removed.connect(_on_group_content_changed)
	var ch := t.get_linked_channel()
	if ch:
		_watched_channels.append(ch)
		ch.device_added.connect(_on_group_devices_changed)
		ch.device_removed.connect(_on_group_devices_changed)


func _on_group_content_changed(_instance: ClipInstance) -> void:
	_queue_rebuild()


func _on_group_devices_changed(_a, _b) -> void:
	_queue_rebuild()


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
			if t.is_group():
				_watch_group(t)
			if t.is_note_editor_track() and _is_listed(t):
				tracks.append(t)
				t.order_changed.connect(_on_track_order_changed)
	selected_track = kept if tracks.has(kept) else null
	for t in tracks:
		_create_track_item(t)
	tracks_changed.emit()


## Hidden tracks (own or through a folder) are skipped unless the arranger shows hidden tracks.
func _is_listed(t: Track) -> bool:
	return ItemVisibility.is_listed(project.arranger_view, ItemVisibility.track_hidden(project, t), false)


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
	if not _painting and not _painting_items:
		return
	if event is InputEventMouseMotion:
		var item := _item_at_global_y(event.global_position.y)
		if item:
			if _painting_items:
				_show_dragged(item.track)
			else:
				toggle_state.set_on(item.track, _paint_kind, _paint_value)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed:
		_painting = false
		_painting_items = false


## Drag over item bodies: the passed track is shown, and also made editable with Shift.
func _show_dragged(t: Track) -> void:
	toggle_state.set_on(t, TrackToggleState.Kind.VISIBLE, true)
	if _paint_shift:
		toggle_state.set_on(t, TrackToggleState.Kind.EDITABLE, true)


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


func _on_item_pressed(shift: bool, track: Track):
	"""Handle track item press; dragging on from it shows the items passed over."""
	selected_track = track
	_update_selection()
	_painting_items = toggle_state != null
	_paint_shift = shift
	if shift:
		track_selected_additive.emit(track)
	else:
		track_selected.emit(track)
