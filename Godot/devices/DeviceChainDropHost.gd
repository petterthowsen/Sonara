# DeviceChainDropHost.gd
# One row of device panels that accepts drops: a channel's root chain (DeviceLane,
# ChannelDeviceList) or a container's children (NestedDeviceList). Knows the row's panels, their
# insert indices and the accept/drop rules. DeviceDropTarget picks the row under the pointer.
class_name DeviceChainDropHost extends RefCounted

## Owners of a host (controls with a `drop_host` property) join this group.
const GROUP := &"device_chain_drop_host"

## Channel whose devices the row shows.
var channel: Channel = null

## Container whose children the row shows, or null for the channel root.
var parent: DeviceInstance = null

## Control whose visible area accepts drops for this row.
var owner: Control = null

## Box holding the panels.
var row: BoxContainer = null

## True when panels stack top to bottom (compact list); false for a left-to-right lane.
var vertical: bool = false

## Maps a visible panel index (0..panel count) to the host insert index. Defaults to identity.
var index_for_panel: Callable = Callable()


## Register `p_owner` (which must expose this host as `drop_host`) with its panel `p_row`.
func attach(p_owner: Control, p_row: BoxContainer, p_vertical: bool, p_index_for_panel: Callable = Callable()) -> void:
	owner = p_owner
	row = p_row
	vertical = p_vertical
	index_for_panel = p_index_for_panel
	if owner and not owner.is_in_group(GROUP):
		owner.add_to_group(GROUP)


## Point the row at `p_channel`'s root chain, or at `p_parent`'s children. A drum pad return's
## root chain is its pad lane (see PadLane): positions are lane indices.
func bind(p_channel: Channel, p_parent: DeviceInstance = null) -> void:
	channel = p_channel
	parent = p_parent


## Device panels in the row, in display order.
func panels() -> Array[Control]:
	var out: Array[Control] = []
	if row == null:
		return out
	for child in row.get_children():
		if not child is Control or child.is_queued_for_deletion() or not child.visible:
			continue
		if panel_device(child) != null:
			out.append(child)
	return out


## Order plain chain panels by device position (pad lanes and containers build in order).
func sort_panels_by_position() -> void:
	var list := panels()
	list.sort_custom(func(a: Control, b: Control): return panel_device(a).position < panel_device(b).position)
	for i in list.size():
		row.move_child(list[i], i)


## Host insert index before visible panel `i` (`i` == panel count means after the last one).
func insert_index(i: int) -> int:
	return int(index_for_panel.call(i)) if index_for_panel.is_valid() else i


## The DeviceInstance a panel shows, or null for other nodes.
static func panel_device(panel: Node) -> DeviceInstance:
	if panel is DevicePanel:
		return (panel as DevicePanel).device
	if panel is CompactDevicePanel:
		return (panel as CompactDevicePanel).device_instance
	return null


## Global rect of a panel's header (drops there go onto the device).
static func panel_header_rect(panel: Control) -> Rect2:
	var header: Control = panel.get("header")
	return header.get_global_rect() if header else Rect2()


## Whether `data` (a DeviceDrag, DeviceInstance or Asset) can be inserted at `position` (-1 = append).
## Dropping a device back into its own slot is accepted; `is_noop` tells it apart.
func can_drop(data: Variant, position: int = -1) -> bool:
	data = DeviceDrag.unwrap(data)
	if channel == null:
		return false
	if parent == null and PadLane.is_pad_lane(channel):
		if data is DeviceInstance:
			return PadLane.devices(channel).has(data)
		return PadLane.can_drop(channel, data, position)
	if data is DeviceInstance:
		return DeviceDropUtil.can_drop_instance_on_host(channel, data, parent)
	if not data is Asset:
		return false
	if parent:
		return DeviceDropUtil.can_drop_on_container(channel, parent, data)
	return DeviceDropUtil.can_drop_asset_on_channel(channel, data)


## True when dropping `data` at `position` would leave everything where it is.
func is_noop(data: Variant, position: int = -1) -> bool:
	data = DeviceDrag.unwrap(data)
	if not data is DeviceInstance:
		return false
	var inst := data as DeviceInstance
	if parent == null and PadLane.is_pad_lane(channel):
		return not PadLane.can_drop(channel, inst, position)
	if inst.get_parent_device() != parent:
		return false
	var count := parent.children.size() if parent else channel.devices.size()
	var at := count if position < 0 or position > count else position
	return at == inst.position or at == inst.position + 1


## Insert (or move) `data` at `position` (-1 = append). Returns true when something changed.
func drop(data: Variant, position: int = -1) -> bool:
	if not can_drop(data, position) or is_noop(data, position):
		return false
	data = DeviceDrag.unwrap(data)
	if parent == null and PadLane.is_pad_lane(channel):
		PadLane.drop(channel, data, position)
	elif data is DeviceInstance:
		DeviceDropUtil.drop_instance(channel, data, parent, position)
	elif data is Asset:
		DeviceDropUtil.drop_asset(channel, data, position, parent)
	return true
