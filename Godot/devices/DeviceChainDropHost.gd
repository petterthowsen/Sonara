# DeviceChainDropHost.gd
# Drop handling for one row of device panels: a channel's root chain or a container's children.
# Owns the insert-point spacers between panels and the accept/drop rules, so DeviceLane,
# ChannelDeviceList and NestedDeviceList behave the same.
class_name DeviceChainDropHost extends RefCounted

## Channel whose devices the row shows.
var channel: Channel = null

## Container whose children the row shows, or null for the channel root.
var parent: DeviceInstance = null

## Spacers currently interleaved with the panels.
var drop_zones: Array[DropZone] = []

var _vertical: bool = true
var _gap: float = 16.0
var _empty_zone: bool = true


## `vertical` spacers sit between panels in an HBox; horizontal ones between rows in a VBox.
## `empty_zone` adds a single spacer when there are no panels.
func _init(vertical: bool = true, gap: float = 16.0, empty_zone: bool = true) -> void:
	_vertical = vertical
	_gap = gap
	_empty_zone = empty_zone


## Point the row at `p_channel`'s root chain, or at `p_parent`'s children.
func bind(p_channel: Channel, p_parent: DeviceInstance = null) -> void:
	channel = p_channel
	parent = p_parent


## Lay out `row` as [spacer][panel]...[panel][spacer]. `index_for_panel` maps a visible
## panel index to the host insert index (defaults to the same index).
func rebuild(row: Node, panels: Array, index_for_panel: Callable = Callable()) -> void:
	drop_zones = DropZone.rebuild_insert_layout(
		row,
		panels,
		func(i: int) -> DropZone:
			return _make_zone(int(index_for_panel.call(i)) if index_for_panel.is_valid() else i),
		_empty_zone
	)


## Free every spacer.
func clear() -> void:
	for drop_zone in drop_zones:
		if is_instance_valid(drop_zone):
			var zone_parent := drop_zone.get_parent()
			if zone_parent:
				zone_parent.remove_child(drop_zone)
			drop_zone.queue_free()
	drop_zones.clear()


## Whether `data` (a DeviceInstance or Asset) can be inserted at `position` (-1 = append).
func can_drop(data: Variant, position: int = -1) -> bool:
	if channel == null:
		return false
	if data is DeviceInstance:
		var inst := data as DeviceInstance
		if not DeviceDropUtil.can_drop_instance_on_host(channel, inst, parent):
			return false
		return position < 0 or inst.get_parent_device() != parent or inst.position != position
	if not data is Asset:
		return false
	if parent:
		return DeviceDropUtil.can_drop_on_container(channel, parent, data)
	return DeviceDropUtil.can_drop_asset_on_channel(channel, data)


## Insert (or move) `data` at `position` (-1 = append).
func drop(data: Variant, position: int = -1) -> void:
	if not can_drop(data, position):
		return
	if data is DeviceInstance:
		DeviceDropUtil.drop_instance(channel, data, parent, position)
	elif data is Asset:
		DeviceDropUtil.drop_asset(channel, data, position, parent)


func _make_zone(position: int) -> DropZone:
	var zone := DropZone.create_insert_spacer(_vertical, _gap)
	zone.set_drag_forwarding(_no_drag, _can_drop_at.bind(position), _drop_at.bind(position))
	return zone


func _no_drag(_at_position: Vector2) -> Variant:
	return null


func _can_drop_at(_at_position: Vector2, data: Variant, position: int) -> bool:
	return can_drop(data, position)


func _drop_at(_at_position: Vector2, data: Variant, position: int) -> void:
	drop(data, position)
