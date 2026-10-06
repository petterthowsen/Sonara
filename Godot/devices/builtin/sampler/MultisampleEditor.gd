## The Sampler's multisample editor in its Window view (spec 023, REQ-040): the group filter bar on
## top, then the sample list and the zone map side by side. The layout lives in
## `MultisampleEditor.tscn`.
##
## Owns the view-local state its children share: the selected zones (REQ-042, REQ-045) and the
## visible groups (REQ-041). The focused zone is model state (`SamplerMultisample.set_focus`), so
## the Panel and Companion views follow it too. Edits go through `SamplerActions`, one undo step
## each.
class_name MultisampleEditor extends VBoxContainer

signal selection_changed()
signal visible_groups_changed()
signal snap_changed()

## `click_zone` modes: a plain click, Ctrl-click and Shift-click.
enum SelectMode { REPLACE, TOGGLE, RANGE }

## `filter_group` id for the "All" button.
const ALL_GROUPS := -1

@onready var group_bar: ZoneGroupBar = %ZoneGroupBar
@onready var zone_list: ZoneList = %ZoneList
@onready var zone_map: ZoneMap = %ZoneMap
@onready var batch_menu: ZoneBatchMenu = %ZoneBatchMenu
@onready var batch_dialog: ZoneBatchDialog = %ZoneBatchDialog

var device: DeviceInstance = null
var model: SamplerMultisample = null
## Selected zone ids in the order they were selected; `selected_in_order()` gives list order.
var selected_ids: Array[int] = []
## Group ids whose zones show; empty shows every zone ("All").
var visible_groups: Array[int] = []
## Zone drags snap to neighbouring zones (header toggle; Shift bypasses). View-local, on by default.
var snap_enabled := true


func _ready() -> void:
	if device != null:
		_bind_children()


func bind(p_device: DeviceInstance) -> void:
	unbind()
	device = p_device
	model = device.ensure_multisample()
	model.zones_changed.connect(_prune_selection)
	model.groups_changed.connect(_prune_visible_groups)
	if is_node_ready():
		_bind_children()


func unbind() -> void:
	if is_node_ready():
		group_bar.unbind()
		zone_list.unbind()
		zone_map.unbind()
	if model != null:
		model.zones_changed.disconnect(_prune_selection)
		model.groups_changed.disconnect(_prune_visible_groups)
	model = null
	device = null
	selected_ids.clear()
	visible_groups.clear()


func _bind_children() -> void:
	group_bar.bind(self)
	zone_list.bind(self)
	zone_map.bind(self)
	batch_menu.bind(self)


func set_snap(on: bool) -> void:
	if snap_enabled != on:
		snap_enabled = on
		snap_changed.emit()


# --- visibility ------------------------------------------------------------

func is_zone_visible(zone: SamplerZone) -> bool:
	return visible_groups.is_empty() or visible_groups.has(zone.group_id)


## The zones the list and map show, in list order.
func visible_zones() -> Array[SamplerZone]:
	var out: Array[SamplerZone] = []
	if model == null:
		return out
	for zone in model.zones:
		if is_zone_visible(zone):
			out.append(zone)
	return out


## A group filter button was clicked (REQ-041). `group_id` is `ALL_GROUPS` for "All". A plain click
## shows only that group; `additive` (Ctrl-click) adds it to or removes it from the visible set.
func filter_group(group_id: int, additive: bool = false) -> void:
	if group_id == ALL_GROUPS:
		visible_groups.clear()
	elif not additive:
		visible_groups = [group_id]
	elif visible_groups.has(group_id):
		visible_groups.erase(group_id)
	else:
		visible_groups.append(group_id)
	visible_groups_changed.emit()
	_prune_selection()


func _prune_visible_groups() -> void:
	var before := visible_groups.size()
	visible_groups = visible_groups.filter(func(gid: int) -> bool: return model.has_group(gid))
	if visible_groups.size() != before:
		visible_groups_changed.emit()
	_prune_selection()


# --- selection -------------------------------------------------------------

func is_selected(zone_id: int) -> bool:
	return selected_ids.has(zone_id)


## The selected zone ids in list order (what batch operations use).
func selected_in_order() -> Array[int]:
	var out: Array[int] = []
	if model == null:
		return out
	for zone in model.zones:
		if selected_ids.has(zone.id):
			out.append(zone.id)
	return out


## Replace the selection. `focus_id` (when not 0) becomes the focused zone.
func set_selection(ids: Array, focus_id: int = 0) -> void:
	var clean: Array[int] = []
	for zone_id in ids:
		var zone := model.get_zone(int(zone_id)) if model else null
		if zone != null and is_zone_visible(zone) and not clean.has(zone.id):
			clean.append(zone.id)
	var changed := clean != selected_ids
	selected_ids = clean
	if focus_id != 0 and model != null:
		model.set_focus(focus_id)
	if changed:
		selection_changed.emit()


## A click on a zone in the list or the map. REPLACE selects only it, TOGGLE adds or removes it,
## RANGE selects the zones of `order` between the focused zone and it. The clicked zone becomes
## focused in every mode.
func click_zone(zone_id: int, mode: SelectMode = SelectMode.REPLACE, order: Array = []) -> void:
	match mode:
		SelectMode.REPLACE:
			set_selection([zone_id], zone_id)
		SelectMode.TOGGLE:
			var ids := selected_ids.duplicate()
			if ids.has(zone_id):
				ids.erase(zone_id)
			else:
				ids.append(zone_id)
			set_selection(ids, zone_id)
		SelectMode.RANGE:
			var ids_in_order: Array = order if not order.is_empty() else visible_zones().map(func(z: SamplerZone) -> int: return z.id)
			var anchor := ids_in_order.find(model.focused_zone_id)
			var target := ids_in_order.find(zone_id)
			if anchor < 0 or target < 0:
				set_selection([zone_id], zone_id)
				return
			set_selection(ids_in_order.slice(mini(anchor, target), maxi(anchor, target) + 1), zone_id)


func clear_selection() -> void:
	set_selection([])


## Ctrl+A (REQ-048): every visible zone.
func select_all() -> void:
	set_selection(visible_zones().map(func(z: SamplerZone) -> int: return z.id))


## Delete (REQ-048): remove the selected zones, one undo step.
func delete_selected() -> void:
	var ids := selected_in_order()
	if not ids.is_empty():
		SamplerActions.delete_zones(device, ids)


func _prune_selection() -> void:
	if model == null:
		return
	set_selection(selected_ids)


## Delete and Ctrl+A for the list and the map. Returns true when `event` was one of them.
func handle_shortcut(event: InputEvent) -> bool:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return false
	var key := event as InputEventKey
	if key.keycode == KEY_DELETE:
		delete_selected()
		return true
	if key.keycode == KEY_A and key.is_command_or_control_pressed():
		select_all()
		return true
	return false


# --- menus -----------------------------------------------------------------

## The batch operations menu for the selection (REQ-047), with `zones_under` (the map's stack under
## the pointer, REQ-046) listed first.
func open_batch_menu(screen_position: Vector2, zones_under: Array = []) -> void:
	batch_menu.open(screen_position, zones_under)
