# KeyChangeTrack.gd
# Key change lane in the ruler area. Each change is a `KeyChangeItem` at its tick; a start-key
# chip at x=0 shows the project base scale. Double-click empty space or right-click > "Add Key
# Change" adds one at the nearest bar line with the key in effect there, dragging moves it along
# bar lines between its neighbours (bar 2 earliest, tick 0 is the base key), the item menu deletes
# it, and the ▾ arrow / double-click / "Change Key" menu entry open a ScalePicker dropdown.
# Every edit is one undo step (`KeyChangeMapStateCommand`), recorded on release.
class_name KeyChangeTrack extends Control


@export var bg_color: Color = Color(0.10, 0.10, 0.10, 1.0)

var grid_helper: GridHelper = null
var project: Project = null

var _items: Dictionary = {}  # change id → KeyChangeItem
var _chip: KeyChangeItem = null
var _popup: PopupPanel = null
var _picker: ScalePicker = null
## What the open dropdown edits: -1 none, 0 the start-key chip, else a change id.
var _popup_target: int = -1
var _menu: PopupMenu = null
var _menu_change_id: int = -1
var _menu_bar: int = 2

var _drag_id: int = -1
var _drag_before: Array[Dictionary] = []


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = 30

	_chip = KeyChangeItem.new()
	add_child(_chip)
	_chip.set_key(0, 0, MusicalScale.NONE_ID)
	_chip.visible = false
	_chip.tooltip_text = "Start key"

	_menu = PopupMenu.new()
	_menu.theme_type_variation = &"ContextMenuList"
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(_menu)

	_popup = PopupPanel.new()
	_popup.theme_type_variation = &"ContextMenuList"
	_picker = ScalePicker.new()
	_picker.scale_picked.connect(_on_picker_scale_picked)
	_popup.add_child(_picker)
	add_child(_popup)


func set_grid_helper(gh: GridHelper) -> void:
	if grid_helper and grid_helper.changed.is_connected(_layout_items):
		grid_helper.changed.disconnect(_layout_items)
	grid_helper = gh
	if grid_helper and not grid_helper.changed.is_connected(_layout_items):
		grid_helper.changed.connect(_layout_items)
	_rebuild_items()


## Bind to a project; pass null to clear. The lane follows the key change map, the base scale and
## the time signature map (bar lines move under tick-anchored tabs).
func bind_project(p: Project) -> void:
	if project:
		if project.key_change_map != null and project.key_change_map.changed.is_connected(_rebuild_items):
			project.key_change_map.changed.disconnect(_rebuild_items)
		if project.scale_changed.is_connected(_on_base_scale_changed):
			project.scale_changed.disconnect(_on_base_scale_changed)
		if project.time_signature_map != null and project.time_signature_map.changed.is_connected(_layout_items):
			project.time_signature_map.changed.disconnect(_layout_items)
	project = p
	if project:
		project.key_change_map.changed.connect(_rebuild_items)
		project.scale_changed.connect(_on_base_scale_changed)
		project.time_signature_map.changed.connect(_layout_items)
	_drag_id = -1
	_rebuild_items()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_items()


func items() -> Array:
	return _items.values()


func chip() -> KeyChangeItem:
	return _chip


# ============================================================================
# ITEMS
# ============================================================================

func _rebuild_items() -> void:
	var wanted: Dictionary = {}
	if project != null and _chip != null:
		_chip.set_key(0, project.scale_root, project.scale_type)
	if project != null and grid_helper != null:
		for c in project.key_change_map.changes:
			wanted[c["id"]] = c
	for id in _items.keys():
		if not wanted.has(id):
			_items[id].queue_free()
			_items.erase(id)
	for id in wanted:
		var c: Dictionary = wanted[id]
		var item: KeyChangeItem = _items.get(id)
		if item == null:
			item = KeyChangeItem.new()
			item.pressed.connect(_on_item_pressed)
			item.dragged.connect(_on_item_dragged)
			item.released.connect(_on_item_released)
			item.menu_requested.connect(_on_item_menu_requested)
			item.dropdown_requested.connect(_on_item_dropdown_requested)
			add_child(item)
			_items[id] = item
		item.set_key(id, c["root"], c["type_id"])
	_layout_items()
	queue_redraw()


func _layout_items() -> void:
	if project == null or grid_helper == null:
		return
	var map := project.time_signature_map
	for c in project.key_change_map.changes:
		var item: KeyChangeItem = _items.get(c["id"])
		if item == null:
			continue
		item.position = Vector2(grid_helper.ticks_to_pixels(c["tick"]) - grid_helper.scroll_position, 2.0)
		item.size = Vector2(item.custom_minimum_size.x, maxf(size.y - 4.0, 4.0))
	if _chip != null:
		_chip.visible = project != null and _chip.get_parent() != null
		_chip.position = Vector2(1.0, 2.0)
		_chip.size = Vector2(_chip.custom_minimum_size.x, maxf(size.y - 4.0, 4.0))
	queue_redraw()


# ============================================================================
# EDIT ACTIONS (each one undo step)
# ============================================================================

## Add a change at `bar` (bar 1 means bar 2, tick 0 is the base key) with the key in effect
## there. A change already on that bar's tick is left alone and its id returned.
func add_change_at_bar(bar: int) -> int:
	var map := project.time_signature_map
	bar = maxi(2, bar)
	var tick := map.tick_of_bar(bar, project.time_numerator, project.time_denominator, project.ppq)
	var existing := project.key_change_map.index_at_tick(tick)
	if existing >= 0:
		return project.key_change_map.changes[existing]["id"]
	var scale := project.get_scale_at_tick(tick)
	var before := project.key_change_map.snapshot()
	var id := project.key_change_map.add_change(tick, scale.root, scale.type_id)
	_record("Add Key Change", before)
	return id


func delete_change(change_id: int) -> void:
	var before := project.key_change_map.snapshot()
	project.key_change_map.remove_change(change_id)
	_record("Delete Key Change", before)


## Move a change to the bar line at `bar`, kept between its neighbours (clamped in the map).
func move_change(change_id: int, bar: int) -> void:
	var before := project.key_change_map.snapshot()
	_apply_move(change_id, bar)
	_record("Move Key Change", before)


func _apply_move(change_id: int, bar: int) -> void:
	var index := project.key_change_map.index_of(change_id)
	if index < 0:
		return
	var c: Dictionary = project.key_change_map.changes[index]
	var tick := project.time_signature_map.tick_of_bar(
		maxi(2, bar), project.time_numerator, project.time_denominator, project.ppq)
	project.key_change_map.update_change(change_id, tick, c["root"], c["type_id"])


func _record(label: String, before: Array[Dictionary]) -> void:
	var map := project.key_change_map
	var after := map.snapshot()
	if after != before:
		HistoryUtil.record(KeyChangeMapStateCommand.new(label, map, before, after))


# ============================================================================
# COORDINATES
# ============================================================================

## Nearest bar (1-based) to a lane x position, measured on the time signature map.
func _bar_at_x(x: float) -> int:
	var tsm := project.time_signature_map
	var tick := maxi(0, grid_helper.pixels_to_ticks(x + grid_helper.scroll_position))
	var bn := project.time_numerator
	var bd := project.time_denominator
	var bar := tsm.bar_at_tick(tick, bn, bd, project.ppq)
	var start := tsm.tick_of_bar(bar, bn, bd, project.ppq)
	var seg := tsm.segments(bn, bd, project.ppq)[tsm.segment_index_at_tick(tick, bn, bd, project.ppq)]
	if tick - start > int(seg["bar_ticks"]) / 2:
		bar += 1
	return bar


# ============================================================================
# INPUT
# ============================================================================

func _draw() -> void:
	var sb := get_theme_stylebox("normal", "Ruler")
	if sb:
		draw_style_box(sb, Rect2(0, 0, size.x, size.y))
	else:
		draw_rect(Rect2(0, 0, size.x, size.y), bg_color)
	BaseRuler.draw_row_border(self)
	if project == null or grid_helper == null:
		return
	for line in grid_helper.get_visible_grid_lines(0.0, size.x):
		if line.type == GridHelper.GridLineType.BAR:
			draw_line(Vector2(line.x, 0), Vector2(line.x, size.y), Color(1, 1, 1, 0.08))


func _gui_input(event: InputEvent) -> void:
	if project == null or grid_helper == null:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			_open_add_menu_at_bar(add_change_at_bar(_bar_at_x(event.position.x)))
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_menu_change_id = -1
			_menu_bar = _bar_at_x(event.position.x)
			_open_menu(event.global_position)
			accept_event()


func _on_item_pressed(change_id: int) -> void:
	_drag_id = change_id
	_drag_before = project.key_change_map.snapshot()


func _on_item_dragged(change_id: int, track_x: float) -> void:
	if change_id != _drag_id:
		return
	_apply_move(change_id, _bar_at_x(track_x))


func _on_item_released(change_id: int) -> void:
	if change_id != _drag_id:
		return
	_drag_id = -1
	_record("Move Key Change", _drag_before)
	_drag_before = []


func _on_item_menu_requested(change_id: int, global_pos: Vector2) -> void:
	_menu_change_id = change_id
	_open_menu(global_pos)


func _on_item_dropdown_requested(change_id: int, global_pos: Vector2) -> void:
	open_dropdown(change_id, global_pos)


func _open_add_menu_at_bar(id: int) -> void:
	var item: KeyChangeItem = _items.get(id)
	if item:
		open_dropdown(id, item.global_position + Vector2(0, item.size.y))


func _open_menu(global_pos: Vector2) -> void:
	_menu.clear()
	if _menu_change_id >= 0:
		_menu.add_item("Change Key", 0)
		_menu.add_item("Delete", 1)
	else:
		_menu.add_item("Add Key Change", 2)
	ContextMenuPopup.popup_at_point(_menu, global_pos)


func _on_menu_id_pressed(id: int) -> void:
	match id:
		0:
			open_dropdown(_menu_change_id, Vector2(_menu.position) + Vector2(0, 8))
		1:
			delete_change(_menu_change_id)
		2:
			var new_id := add_change_at_bar(_menu_bar)
			# New entries keep the key in effect there; open the picker so the user picks one.
			open_dropdown(new_id, Vector2(_menu.position) + Vector2(0, 8))


# ============================================================================
# SCALE DROPDOWN
# ============================================================================

## Open the ScalePicker popup for the start-key chip (change_id 0) or a change id.
func open_dropdown(change_id: int, global_pos: Vector2) -> void:
	if project == null:
		return
	_popup_target = change_id
	var scale: MusicalScale
	if change_id == 0:
		scale = project.get_scale()
	else:
		var index := project.key_change_map.index_of(change_id)
		if index < 0:
			return
		var c: Dictionary = project.key_change_map.changes[index]
		scale = MusicalScale.make(c["root"], c["type_id"])
	_picker.set_scale_display(scale.root, scale.type_id)
	_picker.clear_detection()
	_picker.detect_source = func() -> Dictionary: return KeyDetector.detect_for_change(project, change_id)
	ContextMenuPopup.popup_at_point(_popup, global_pos)


func _on_picker_scale_picked(root: int, type_id: String) -> void:
	_popup.hide()
	if project == null:
		return
	if _popup_target == 0:
		# The base key stays with the project; Sonara.editor records the undo step.
		if Sonara and Sonara.editor:
			Sonara.editor.set_project_scale(root, type_id)
	elif _popup_target > 0:
		var index := project.key_change_map.index_of(_popup_target)
		if index < 0:
			return
		var before := project.key_change_map.snapshot()
		var c: Dictionary = project.key_change_map.changes[index]
		project.key_change_map.update_change(_popup_target, c["tick"], root, type_id)
		_record("Change Key", before)
	_popup_target = -1


func _on_base_scale_changed(_root: int, _type_id: String) -> void:
	_rebuild_items()
