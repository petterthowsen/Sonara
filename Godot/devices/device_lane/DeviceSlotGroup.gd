## An open container slot in the device lane, right of the container's panel: a bracket in the
## slot color along the top, over a DeviceRow of the slot chain's devices. The row is a drop target
## of its own (see DeviceDropTarget); the gap before it and the bracket count as part of the slot.
## An empty slot (an empty chain, or a Drum Machine pad with no devices yet) shows an outlined
## drop zone.
class_name DeviceSlotGroup extends MarginContainer

## Height of the color bracket above the slot's panels, in pixels.
const STRIP_HEIGHT := 10

## Thickness of the bracket's bar and end ticks, in pixels.
const BAR := 4.0

## Width of an empty slot's drop zone.
const EMPTY_WIDTH := 200.0

signal context_menu_requested(device_instance: DeviceInstance, in_slot: bool)

var container: DeviceInstance = null
var key := ""
var row: DeviceRow = null
## Slot row drop rules (see DeviceDropTarget).
var drop_host := DeviceChainDropHost.new()
var _empty_hint: Label = null
## Slot chain whose child signals are connected (changes when an empty pad gets its first device).
var _chain: DeviceInstance = null


## Show slot `p_key` of `p_container`.
func setup(p_container: DeviceInstance, p_key: String) -> void:
	container = p_container
	key = p_key
	name = "Slot_%s" % key.validate_node_name()
	add_theme_constant_override("margin_left", DeviceRow.GAP)
	add_theme_constant_override("margin_top", STRIP_HEIGHT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	resized.connect(queue_redraw)

	row = DeviceRow.new()
	row.in_slot = true
	row.context_menu_requested.connect(context_menu_requested.emit)
	add_child(row)

	_empty_hint = Label.new()
	_empty_hint.text = "Drop devices here"
	_empty_hint.custom_minimum_size.x = EMPTY_WIDTH
	_empty_hint.size_flags_vertical = Control.SIZE_FILL
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	var zone := StyleBoxFlat.new()
	zone.bg_color = Color(1, 1, 1, 0.03)
	zone.set_border_width_all(1)
	zone.set_corner_radius_all(3)
	_empty_hint.add_theme_stylebox_override("normal", zone)
	_empty_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_empty_hint)

	drop_host.attach(self, row, false)
	drop_host.trailing_margin = DeviceRow.PANEL_MARGIN
	# Container signals cover slots opening, pads moving notes and slot chains coming and going.
	container.slots_changed.connect(_sync)
	container.child_added.connect(_on_children_changed)
	container.child_removed.connect(_on_children_changed)
	container.child_moved.connect(_on_children_changed)
	_sync()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or container == null:
		return
	_watch_chain(null)
	for sig in [container.slots_changed, container.child_added, container.child_removed, container.child_moved]:
		for method in [_sync, _on_children_changed]:
			if sig.is_connected(method):
				sig.disconnect(method)


## Follow the child list of slot chain `chain` (a Chain slot's is the container's own).
func _watch_chain(chain: DeviceInstance) -> void:
	if chain == _chain:
		return
	if _chain:
		for sig in [_chain.child_added, _chain.child_removed, _chain.child_moved, _chain.slot_changed]:
			if sig.is_connected(_on_children_changed):
				sig.disconnect(_on_children_changed)
	_chain = chain if chain != container else null
	if _chain:
		_chain.child_added.connect(_on_children_changed)
		_chain.child_removed.connect(_on_children_changed)
		_chain.child_moved.connect(_on_children_changed)
		_chain.slot_changed.connect(_on_children_changed)


func slot_color() -> Color:
	return container.slot_color(key)


func _on_children_changed(_a = null, _b = null) -> void:
	_sync()


## Show the slot's devices; the container's item frees this group once the slot is gone.
func _sync() -> void:
	if not container.has_slot(key):
		return
	drop_host.bind_slot(container.get_channel(), container, key)
	_watch_chain(container.slot_chain(key))
	var list := container.slot_devices(key)
	row.sync(list)
	_empty_hint.visible = list.is_empty()
	var zone := _empty_hint.get_theme_stylebox("normal") as StyleBoxFlat
	zone.border_color = Color(slot_color(), 0.5)
	tooltip_text = container.slot_title(key)
	queue_redraw()


## Bracket: a bar along the top with a tick down at each end, over the row (not the gap before it).
func _draw() -> void:
	var color := slot_color()
	var left := float(DeviceRow.GAP)
	draw_rect(Rect2(left, 0, size.x - left, BAR), color)
	draw_rect(Rect2(left, 0, BAR, STRIP_HEIGHT), color)
	draw_rect(Rect2(size.x - BAR, 0, BAR, STRIP_HEIGHT), color)


## Drops on the slot resolve from the pointer through the enclosing device lane.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return DeviceDropTarget.resolve_for(self, data).is_valid()


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	DeviceDropTarget.resolve_for(self, data).commit(data)
