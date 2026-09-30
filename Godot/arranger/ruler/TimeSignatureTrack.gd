# TimeSignatureTrack.gd
# Time signature lane in the ruler area. Each change is a `TimeSignatureItem` at its bar line.
# Double-click empty space (or right-click > Add) adds a change at the nearest bar, double-click a
# change edits it, dragging moves it along bar lines between its neighbours, and the item menu
# deletes it. Every edit is one undo step (`TimeSignatureMapStateCommand`).
class_name TimeSignatureTrack extends Control

@export var bg_color: Color = Color(0.10, 0.10, 0.10, 1.0)

var grid_helper: GridHelper = null
var project: Project = null

var _items: Dictionary = {}  # change id → TimeSignatureItem
var _menu: PopupMenu = null
var _menu_change_id: int = -1
var _menu_bar: int = 2

var _drag_id: int = -1
var _drag_before: Array[Dictionary] = []
## Map without the dragged change, so the cursor-to-bar conversion doesn't shift as it moves.
var _drag_ref: TimeSignatureMap = null


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = 30

	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(_menu)


func set_grid_helper(gh: GridHelper) -> void:
	if grid_helper and grid_helper.changed.is_connected(_layout_items):
		grid_helper.changed.disconnect(_layout_items)
	grid_helper = gh
	if grid_helper and not grid_helper.changed.is_connected(_layout_items):
		grid_helper.changed.connect(_layout_items)
	_rebuild_items()


## Bind to a project's time signature map; pass null to clear.
func bind_project(p: Project) -> void:
	if project and project.time_signature_map.changed.is_connected(_rebuild_items):
		project.time_signature_map.changed.disconnect(_rebuild_items)
	project = p
	if project and not project.time_signature_map.changed.is_connected(_rebuild_items):
		project.time_signature_map.changed.connect(_rebuild_items)
	_drag_id = -1
	_rebuild_items()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_items()


func items() -> Array:
	return _items.values()


# ============================================================================
# ITEMS
# ============================================================================

func _rebuild_items() -> void:
	var wanted: Dictionary = {}
	if project != null and grid_helper != null:
		for c in project.time_signature_map.changes:
			wanted[c["id"]] = c
	for id in _items.keys():
		if not wanted.has(id):
			_items[id].queue_free()
			_items.erase(id)
	for id in wanted:
		var c: Dictionary = wanted[id]
		var item: TimeSignatureItem = _items.get(id)
		if item == null:
			item = TimeSignatureItem.new()
			item.pressed.connect(_on_item_pressed)
			item.dragged.connect(_on_item_dragged)
			item.released.connect(_on_item_released)
			item.edit_committed.connect(apply_edit)
			item.menu_requested.connect(_on_item_menu_requested)
			add_child(item)
			_items[id] = item
		item.set_signature(id, c["numerator"], c["denominator"])
	_layout_items()
	queue_redraw()


func _layout_items() -> void:
	if project == null or grid_helper == null:
		return
	var map := project.time_signature_map
	for c in map.changes:
		var item: TimeSignatureItem = _items.get(c["id"])
		if item == null:
			continue
		var tick := map.tick_of_bar(c["bar"], project.time_numerator, project.time_denominator, project.ppq)
		item.position = Vector2(grid_helper.ticks_to_pixels(tick) - grid_helper.scroll_position, 2.0)
		item.size = Vector2(item.custom_minimum_size.x, maxf(size.y - 4.0, 4.0))
	queue_redraw()


# ============================================================================
# EDIT ACTIONS (each one undo step)
# ============================================================================

## Add a change at `bar` (bar 1 becomes bar 2) with the signature in effect there. A change
## already on that bar is left alone and its id returned. Returns the change id.
func add_change_at_bar(bar: int) -> int:
	var map := project.time_signature_map
	bar = maxi(2, bar)
	var existing := map.index_at_bar(bar)
	if existing >= 0:
		return map.changes[existing]["id"]
	var tick := map.tick_of_bar(bar, project.time_numerator, project.time_denominator, project.ppq)
	var sig := map.signature_at_tick(tick, project.time_numerator, project.time_denominator, project.ppq)
	var before := map.snapshot()
	var id := map.add_change(bar, sig.x, sig.y)
	_record("Add Time Signature", before)
	return id


## Apply "N/D" text to a change. Invalid text keeps the old value and returns false.
func apply_edit(change_id: int, text: String) -> bool:
	var sig := TimeSignatureMap.parse(text)
	if sig == Vector2i.ZERO:
		return false
	var map := project.time_signature_map
	var index := map.index_of(change_id)
	if index < 0:
		return false
	var before := map.snapshot()
	map.update_change(change_id, map.changes[index]["bar"], sig.x, sig.y)
	_record("Edit Time Signature", before)
	return true


func delete_change(change_id: int) -> void:
	var map := project.time_signature_map
	var before := map.snapshot()
	map.remove_change(change_id)
	_record("Delete Time Signature", before)


## Move a change to `bar`, kept between its neighbours.
func move_change(change_id: int, bar: int) -> void:
	var before := project.time_signature_map.snapshot()
	_apply_move(change_id, bar)
	_record("Move Time Signature", before)


func _apply_move(change_id: int, bar: int) -> void:
	var map := project.time_signature_map
	var index := map.index_of(change_id)
	if index < 0:
		return
	var c: Dictionary = map.changes[index]
	map.update_change(change_id, bar, c["numerator"], c["denominator"])


func _record(label: String, before: Array[Dictionary]) -> void:
	var map := project.time_signature_map
	var after := map.snapshot()
	if after != before:
		HistoryUtil.record(TimeSignatureMapStateCommand.new(label, map, before, after))


# ============================================================================
# COORDINATES
# ============================================================================

## Nearest bar (1-based) to a lane x position, measured on `map`.
func _bar_at_x(x: float, map: TimeSignatureMap) -> int:
	var tick := maxi(0, grid_helper.pixels_to_ticks(x + grid_helper.scroll_position))
	var bn := project.time_numerator
	var bd := project.time_denominator
	var bar := map.bar_at_tick(tick, bn, bd, project.ppq)
	var start := map.tick_of_bar(bar, bn, bd, project.ppq)
	var seg := map.segments(bn, bd, project.ppq)[map.segment_index_at_tick(tick, bn, bd, project.ppq)]
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
	if project == null or grid_helper == null:
		return
	for line in grid_helper.get_visible_grid_lines(0.0, size.x):
		if line.type == GridHelper.GridLineType.BAR:
			draw_line(Vector2(line.x, 0), Vector2(line.x, size.y), Color(1, 1, 1, 0.08))
	if project.time_signature_map.is_empty():
		var font := get_theme_default_font()
		draw_string(font, Vector2(6, size.y * 0.5 + 5.0), "%d/%d" % [project.time_numerator, project.time_denominator],
			HORIZONTAL_ALIGNMENT_LEFT, -1, TimeSignatureItem.FONT_SIZE, Color(TimeSignatureItem.TAB_COLOR, 0.7))


func _gui_input(event: InputEvent) -> void:
	if project == null or grid_helper == null:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			_add_and_edit(_bar_at_x(event.position.x, project.time_signature_map))
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_menu_change_id = -1
			_menu_bar = _bar_at_x(event.position.x, project.time_signature_map)
			_open_menu(event.global_position)
			accept_event()


func _add_and_edit(bar: int) -> void:
	var id := add_change_at_bar(bar)
	var item: TimeSignatureItem = _items.get(id)
	if item:
		item.begin_edit()


func _on_item_pressed(change_id: int) -> void:
	_drag_id = change_id
	_drag_before = project.time_signature_map.snapshot()
	_drag_ref = TimeSignatureMap.new()
	var others: Array[Dictionary] = []
	for c in _drag_before:
		if c["id"] != change_id:
			others.append(c)
	_drag_ref.restore(others)


func _on_item_dragged(change_id: int, track_x: float) -> void:
	if change_id != _drag_id or _drag_ref == null:
		return
	_apply_move(change_id, _bar_at_x(track_x, _drag_ref))


func _on_item_released(change_id: int) -> void:
	if change_id != _drag_id:
		return
	_drag_id = -1
	_drag_ref = null
	_record("Move Time Signature", _drag_before)


func _on_item_menu_requested(change_id: int, global_pos: Vector2) -> void:
	_menu_change_id = change_id
	_open_menu(global_pos)


func _open_menu(global_pos: Vector2) -> void:
	_menu.clear()
	if _menu_change_id >= 0:
		_menu.add_item("Edit", 0)
		_menu.add_item("Delete", 1)
	else:
		_menu.add_item("Add Time Signature", 2)
	_menu.popup(Rect2(global_pos - Vector2.ONE * 10, Vector2.ZERO))


func _on_menu_id_pressed(id: int) -> void:
	match id:
		0:
			var item: TimeSignatureItem = _items.get(_menu_change_id)
			if item:
				item.begin_edit()
		1:
			delete_change(_menu_change_id)
		2:
			_add_and_edit(_menu_bar)
