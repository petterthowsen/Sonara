# DeviceDropTarget.gd
# Where a device or asset drag lands under the pointer: insert between panels of a device row, or
# drop onto a device (into a container, or load a file). Nothing moves while dragging; drop handlers
# and the drop indicator both resolve through here so the indicator shows what releasing does.
class_name DeviceDropTarget extends RefCounted

enum Kind { NONE, INSERT, ONTO }

## Controls that resolve and draw device drops for their subtree (DeviceLane, ChannelDeviceList).
const ROOT_GROUP := &"device_drop_root"

## Controls that take device drops themselves (drum pads); no insert target over them.
const OWN_DROPS_GROUP := &"device_drop_self"

## Near a panel's ends (along the row), a file drop inserts beside the panel instead of loading.
const EDGE := 24.0

var kind: Kind = Kind.NONE

## Row the drop lands in.
var host: DeviceChainDropHost = null

## Host insert index for INSERT.
var position: int = -1

## Device (and its panel) for ONTO.
var device: DeviceInstance = null
var panel: Control = null

## Global rect to draw: a thin insert line, or the rect to outline.
var indicator_rect: Rect2 = Rect2()

## True when the indicator outlines a rect (a device header or an empty row).
var outline: bool = false


## True when a drop here would do something.
func is_valid() -> bool:
	return kind != Kind.NONE


## True for data a device row can take.
static func accepts(data: Variant) -> bool:
	return data is DeviceDrag or data is Asset


## Resolve the target for `data` at global `mouse` inside `root`.
static func resolve(root: Control, data: Variant, mouse: Vector2) -> DeviceDropTarget:
	var target := DeviceDropTarget.new()
	if root == null or not accepts(data) or not DragDrop.is_point_visible(root, mouse):
		return target
	if _over_own_drop_control(root, mouse):
		return target
	var row_host := _deepest_host_at(root, mouse)
	if row_host == null or row_host.channel == null:
		return target

	var list := row_host.panels()
	var along := mouse.y if row_host.vertical else mouse.x
	for i in list.size():
		var p := list[i]
		if not DragDrop.is_point_visible(p, mouse):
			continue
		var inst := DeviceChainDropHost.panel_device(p)
		var header := DeviceChainDropHost.panel_header_rect(p)
		if header.has_point(mouse) and target._try_onto(p, inst, data, header):
			return target
		var rect := p.get_global_rect()
		var start := rect.position.y if row_host.vertical else rect.position.x
		var length := rect.size.y if row_host.vertical else rect.size.x
		var edge := minf(EDGE, length * 0.25)
		var payload: Variant = DeviceDrag.unwrap(data)
		if payload is Asset and along > start + edge and along < start + length - edge:
			if DeviceDropUtil.can_drop_file_on_device(inst, payload) and target._try_onto(p, inst, data, header):
				return target
		target._try_insert(row_host, list, i + 1 if along > start + length * 0.5 else i, data)
		return target

	# Gap or empty space: insert before the first panel past the pointer.
	var index := 0
	for p in list:
		var center := p.get_global_rect().get_center()
		if along > (center.y if row_host.vertical else center.x):
			index += 1
	target._try_insert(row_host, list, index, data)
	return target


## Resolve at the mouse for a drop handler on `node` (or any control inside a device drop root).
static func resolve_for(node: Node, data: Variant) -> DeviceDropTarget:
	var root := find_root(node)
	if root == null:
		return DeviceDropTarget.new()
	return resolve(root, data, root.get_global_mouse_position())


## Nearest ancestor (or `node` itself) in ROOT_GROUP.
static func find_root(node: Node) -> Control:
	while node:
		if node is Control and node.is_in_group(ROOT_GROUP):
			return node as Control
		node = node.get_parent()
	return null


## Apply this target through the model and history. Returns true when something changed.
func commit(data: Variant) -> bool:
	var changed := false
	match kind:
		Kind.INSERT:
			changed = host.drop(data, position)
		Kind.ONTO:
			var added := DeviceDropUtil.drop_on_device(device, data)
			if is_instance_valid(panel) and panel is DevicePanel:
				(panel as DevicePanel).after_drop_onto(added)
			changed = true
	if changed and data is DeviceDrag:
		(data as DeviceDrag).did_commit = true
	return changed


## Show the indicator for the drag in progress over `root`, or hide it. Returns the indicator.
static func update_indicator(root: Control, indicator: DropIndicator) -> DropIndicator:
	var data: Variant = DragDrop.current_drag(root)
	var target := resolve(root, data, root.get_global_mouse_position()) if accepts(data) else DeviceDropTarget.new()
	if not target.is_valid():
		DropIndicator.hide_indicator(indicator)
		return indicator
	return DropIndicator.place(root, indicator, target.indicator_rect, target.outline)


## Drop onto `inst` (child into a container, or a file to load); `header` is outlined.
func _try_onto(p: Control, inst: DeviceInstance, data: Variant, header: Rect2) -> bool:
	if inst == null or not DeviceDropUtil.can_drop_on_device(inst, data):
		return false
	kind = Kind.ONTO
	device = inst
	panel = p
	indicator_rect = header
	outline = true
	return true


## Insert before visible panel `index` of `list` in `row_host` when allowed.
func _try_insert(row_host: DeviceChainDropHost, list: Array[Control], index: int, data: Variant) -> void:
	var at := row_host.insert_index(index)
	if not row_host.can_drop(data, at):
		return
	kind = Kind.INSERT
	host = row_host
	position = at
	if list.is_empty():
		indicator_rect = DragDrop.visible_rect(row_host.owner)
		outline = true
		return
	indicator_rect = _insert_line_rect(row_host, list, index, DragDrop.visible_rect(row_host.row))


## Thin line across the row in the gap before visible panel `index`, kept inside `clip`.
static func _insert_line_rect(row_host: DeviceChainDropHost, list: Array[Control], index: int, clip: Rect2) -> Rect2:
	var vertical := row_host.vertical
	var gap := float(row_host.row.get_theme_constant("separation"))
	var at: float
	if index <= 0:
		var first := list[0].get_global_rect()
		at = (first.position.y if vertical else first.position.x) - gap * 0.5
	elif index >= list.size():
		var last := list[list.size() - 1].get_global_rect()
		at = (last.end.y if vertical else last.end.x) + gap * 0.5
	else:
		var prev := list[index - 1].get_global_rect()
		var next := list[index].get_global_rect()
		at = ((prev.end.y + next.position.y) if vertical else (prev.end.x + next.position.x)) * 0.5
	var half := DropIndicator.LINE_WIDTH * 0.5
	if vertical:
		at = clampf(at, clip.position.y + half, clip.end.y - half)
	else:
		at = clampf(at, clip.position.x + half, clip.end.x - half)
	# A left-to-right lane gets a vertical line; a stacked list gets a horizontal one.
	return DropIndicator.line_rect(at, clip, not vertical)


## Innermost device row inside `root` under `mouse` (nested rows sit inside their parent's panels).
static func _deepest_host_at(root: Control, mouse: Vector2) -> DeviceChainDropHost:
	var best: DeviceChainDropHost = null
	var best_depth := -1
	for node in root.get_tree().get_nodes_in_group(DeviceChainDropHost.GROUP):
		if not node is Control or node.is_queued_for_deletion():
			continue
		if node != root and not root.is_ancestor_of(node):
			continue
		var row_host: DeviceChainDropHost = node.get("drop_host")
		if row_host == null or not DragDrop.is_point_visible(node as Control, mouse):
			continue
		var depth := node.get_path().get_name_count()
		if depth > best_depth:
			best = row_host
			best_depth = depth
	return best


## True when a control that handles its own device drops (a drum pad) is under `mouse`.
static func _over_own_drop_control(root: Control, mouse: Vector2) -> bool:
	for node in root.get_tree().get_nodes_in_group(OWN_DROPS_GROUP):
		if node is Control and root.is_ancestor_of(node) and DragDrop.is_point_visible(node as Control, mouse):
			return true
	return false
