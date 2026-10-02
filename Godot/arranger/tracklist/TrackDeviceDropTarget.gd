# TrackDeviceDropTarget.gd
# Where a device drop (Device/SFZ asset, an array of them, or a DeviceDrag) lands on the arranger
# tracklist: the middle of a track header adds it to that track's channel; anywhere else creates a
# new track (instrument or audio, see DeviceDropUtil.new_channel_kind) at the insert position a
# track drag would use, including into folders. Nothing changes while dragging; TrackList's drop
# handlers and drop indicator both resolve through here.
class_name TrackDeviceDropTarget extends RefCounted

enum Kind { NONE, ONTO_TRACK, NEW_TRACK }

var kind: Kind = Kind.NONE

## Channel the devices go on (ONTO_TRACK).
var channel: Channel = null

## Parent track id and sibling the new track(s) go after (NEW_TRACK; -1 / null = root / first).
var parent_id: int = -1
var after_sibling: Track = null

## Global rect to draw: the header for ONTO_TRACK or a folder nest, an insert line otherwise.
var indicator_rect: Rect2 = Rect2()

var _outline := false
var _project: Project = null
var _items: Array = []


## True when a drop here would do something.
func is_valid() -> bool:
	return kind != Kind.NONE


## True when the indicator outlines a header rather than drawing an insert line.
func is_nest() -> bool:
	return _outline


## True when `data` is something this target can place (before looking at the pointer).
static func accepts(data: Variant) -> bool:
	return not _items_of(data).is_empty()


## Resolve the target for `data` at global `mouse` inside `list`.
static func resolve(list: TrackList, data: Variant, mouse: Vector2) -> TrackDeviceDropTarget:
	var target := TrackDeviceDropTarget.new()
	if list == null or list.current_project == null or not DragDrop.is_point_visible(list, mouse):
		return target
	target._items = _items_of(data)
	if target._items.is_empty():
		return target
	target._project = list.current_project
	target._resolve(list, mouse)
	return target


## Apply this target through history. Returns true when something changed.
func commit(data: Variant = null) -> bool:
	if not is_valid():
		return false
	var changed := false
	match kind:
		Kind.ONTO_TRACK:
			for item in _items:
				if item is DeviceInstance:
					DeviceDropUtil.drop_instance(channel, item, null, -1)
				else:
					DeviceDropUtil.drop_asset(channel, item, -1, null)
			changed = true
		Kind.NEW_TRACK:
			var after := after_sibling
			for item in _items:
				var ch := DeviceDropUtil.create_channel_for(_project, item, false, parent_id, after)
				var track := _project.get_channel_paired_track(ch)
				if track:
					after = track
					changed = true
			var parent := _project.get_track_by_id(parent_id) if parent_id >= 0 else null
			if changed and parent and not parent.is_folder_expanded:
				parent.is_folder_expanded = true
	if changed and data is DeviceDrag:
		(data as DeviceDrag).did_commit = true
	return changed


func _resolve(list: TrackList, mouse: Vector2) -> void:
	for child in list.get_children():
		if not child is TrackItem:
			continue
		var item := child as TrackItem
		if item.track == null or not item.visible:
			continue
		var rect := item.get_global_rect()
		if not rect.has_point(mouse):
			continue
		# Middle of a header: onto that track. Its top/bottom edges insert a new track beside it.
		var edge := rect.size.y * TrackDropTarget.NEST_EDGE
		if mouse.y > rect.position.y + edge and mouse.y < rect.end.y - edge:
			var ch := _project.get_track_mixer_channel(item.track)
			if _all_fit(ch):
				kind = Kind.ONTO_TRACK
				channel = ch
				indicator_rect = rect
				_outline = true
				return
			if _any_on(ch):
				return  # A device dropped back on its own track: nothing to do.
		break

	for item in _items:
		if DeviceDropUtil.new_channel_kind(item, false).is_empty():
			return
	var insert := TrackDropTarget.resolve_new_track(list, mouse)
	if not insert.is_valid():
		return
	kind = Kind.NEW_TRACK
	parent_id = insert.parent_id
	after_sibling = insert.after_sibling
	indicator_rect = insert.indicator_rect
	_outline = insert.is_nest()


## True when every dropped item may go on `ch`. A device already on `ch` doesn't count as a move.
func _all_fit(ch: Channel) -> bool:
	if ch == null:
		return false
	for item in _items:
		if item is DeviceInstance:
			if not DeviceDropUtil.can_transfer_to_channel(item, ch):
				return false
		elif not DeviceDropUtil.can_drop_asset_on_channel(ch, item):
			return false
	return true


## True when a dragged device already sits on `ch`.
func _any_on(ch: Channel) -> bool:
	for item in _items:
		if item is DeviceInstance and ch != null and (item as DeviceInstance).get_channel() == ch:
			return true
	return false


## Placeable items in `data`: Device/SFZ assets (single or array) or a dragged device instance.
static func _items_of(data: Variant) -> Array:
	var items: Array = []
	if data is DeviceDrag:
		var inst := (data as DeviceDrag).device
		if inst:
			items.append(inst)
		return items
	for item in (data if data is Array else [data]):
		if not item is Asset:
			return []
		var asset := item as Asset
		if asset.type != Asset.TYPE.Device and asset.type != Asset.TYPE.Preset and asset.type != Asset.TYPE.SFZ:
			return []
		items.append(asset)
	return items
