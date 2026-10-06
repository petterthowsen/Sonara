## The multisample editor's sample list (spec 023, REQ-042, REQ-048): the visible zones by name,
## filtered by the search field (case-insensitive substring). The `ItemList`'s own multi-select
## gives click, Ctrl-click and Shift-click; the clicked zone becomes focused and the selection is
## the editor's, shared with the zone map. Missing zones show dimmed with the reason as a tooltip.
## Dragging one or more selected rows up or down reorders them (list order is the order the batch
## operations hand ranges out in). Right-click opens the batch menu; Delete and Ctrl+A work while the list has focus. The layout
## lives in `ZoneList.tscn`.
class_name ZoneList extends VBoxContainer

const MISSING_COLOR := Color(0.85, 0.45, 0.45, 0.7)
const DROP_LINE_COLOR := Color(0.35, 0.62, 1.0)
## Drag data key holding the dragged zone ids.
const DRAG_KEY := "sampler_zones"

@onready var search: LineEdit = %Search
@onready var items: ItemList = %Items

var editor: MultisampleEditor = null
## Zone id of each row.
var row_ids: Array[int] = []
var _syncing := false
## Reorder drop in progress: the zone the dragged ones would go before (0 = the end) and the
## list y of the indicator line (-1 = none).
var _drop_before := 0
var _drop_line_y := -1.0
var _links: Array = []


func _ready() -> void:
	search.text_changed.connect(func(_t: String) -> void: rebuild())
	items.item_clicked.connect(_on_item_clicked)
	items.empty_clicked.connect(_on_empty_clicked)
	items.gui_input.connect(_on_items_input)
	items.set_drag_forwarding(_get_drag_data_on_items, _can_drop_on_items, _drop_on_items)
	items.draw.connect(_draw_drop_line)


func bind(p_editor: MultisampleEditor) -> void:
	unbind()
	editor = p_editor
	var m := editor.model
	_link(m.zones_changed, rebuild)
	_link(m.zone_changed, _on_zone_changed)
	_link(editor.selection_changed, _sync_selection)
	_link(editor.visible_groups_changed, rebuild)
	rebuild()

## Connect `fn` to `sig` until `unbind()`.
func _link(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_links.append([sig, fn])


func unbind() -> void:
	for link in _links:
		if (link[0] as Signal).is_connected(link[1]):
			(link[0] as Signal).disconnect(link[1])
	_links.clear()
	editor = null


## The zones the list shows: visible in the editor and matching the search.
func shown_zones() -> Array[SamplerZone]:
	var out: Array[SamplerZone] = []
	if editor == null:
		return out
	var needle := search.text.strip_edges().to_lower()
	for zone in editor.visible_zones():
		if needle.is_empty() or zone.name.to_lower().contains(needle):
			out.append(zone)
	return out


func rebuild() -> void:
	if not is_node_ready():
		return
	items.clear()
	row_ids.clear()
	for zone in shown_zones():
		var row := items.add_item(zone.name)
		row_ids.append(zone.id)
		_style_row(row, zone)
	_sync_selection()


func _style_row(row: int, zone: SamplerZone) -> void:
	items.set_item_text(row, zone.name)
	if zone.is_missing():
		items.set_item_custom_fg_color(row, MISSING_COLOR)
		items.set_item_tooltip(row, "Missing: %s\n%s" % [zone.missing_reason(), zone.path])
	else:
		items.set_item_custom_fg_color(row, Color())  # Color() = theme default
		items.set_item_tooltip(row, "%s\n%s–%s · velocity %d–%d" % [
			zone.path, Midi.midi_to_note_name(zone.key_lo), Midi.midi_to_note_name(zone.key_hi),
			zone.vel_lo, zone.vel_hi])


func _on_zone_changed(zone_id: int) -> void:
	var row := row_ids.find(zone_id)
	var zone := editor.model.get_zone(zone_id)
	if zone == null:
		return
	# A group change can move it in or out of the visible set.
	if (row >= 0) != (zone in shown_zones()):
		rebuild()
	elif row >= 0:
		_style_row(row, zone)


## Mirror the editor's selection onto the rows.
func _sync_selection() -> void:
	if editor == null or not is_node_ready():
		return
	_syncing = true
	items.deselect_all()
	for row in row_ids.size():
		if editor.is_selected(row_ids[row]):
			items.select(row, false)
	_syncing = false


func _on_item_clicked(row: int, at_position: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_RIGHT:
		if not editor.is_selected(row_ids[row]):
			editor.click_zone(row_ids[row])
		editor.open_batch_menu(items.get_screen_position() + at_position)
		return
	if mouse_button == MOUSE_BUTTON_LEFT:
		apply_list_selection(row)


## The ItemList changed its selection after a click on `row`: hand it to the editor and focus the
## clicked zone. Public so tests can drive Shift- and Ctrl-clicks through `ItemList.select`.
func apply_list_selection(row: int) -> void:
	if _syncing or row < 0 or row >= row_ids.size():
		return
	var ids: Array = []
	for selected_row in items.get_selected_items():
		ids.append(row_ids[selected_row])
	editor.set_selection(ids, row_ids[row])


func _on_empty_clicked(_at_position: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_LEFT:
		editor.clear_selection()


func _on_items_input(event: InputEvent) -> void:
	if editor != null and editor.handle_shortcut(event):
		items.accept_event()


# --- reorder ---------------------------------------------------------------

func _get_drag_data_on_items(at_position: Vector2) -> Variant:
	var row := items.get_item_at_position(at_position, true)
	if editor == null or row < 0 or row >= row_ids.size():
		return null
	var ids: Array = [row_ids[row]]
	if editor.is_selected(row_ids[row]):
		ids = editor.selected_in_order().filter(func(zone_id: int) -> bool: return row_ids.has(zone_id))
	var label := Label.new()
	label.text = items.get_item_text(row) if ids.size() == 1 else "%d samples" % ids.size()
	label.add_theme_font_size_override("font_size", 11)
	set_drag_preview(label)
	return {DRAG_KEY: ids}


## Where a drop at `at_position` would put the dragged zones: `{before, y}`, `before` being the
## zone id they go in front of (0 = the end) and `y` the indicator line.
func drop_target(at_position: Vector2) -> Dictionary:
	if row_ids.is_empty():
		return {"before": 0, "y": 0.0}
	var row := items.get_item_at_position(at_position, false)
	if row < 0:
		row = row_ids.size() - 1 if at_position.y > 0.0 else 0
	var rect := items.get_item_rect(row)
	var after := at_position.y >= rect.position.y + rect.size.y * 0.5
	var insert := row + 1 if after else row
	var before := 0
	if insert < row_ids.size():
		before = row_ids[insert]
	else:
		# Past the last shown row: in front of whatever follows it in the full list.
		var next := editor.model.zones.find(editor.model.get_zone(row_ids[-1])) + 1
		before = editor.model.zones[next].id if next < editor.model.zones.size() else 0
	return {"before": before, "y": rect.end.y if after else rect.position.y}


func _can_drop_on_items(at_position: Vector2, data: Variant) -> bool:
	if editor == null:
		return false
	if data is Dictionary and data.has(DRAG_KEY):
		var target := drop_target(at_position)
		_drop_before = target["before"]
		_drop_line_y = target["y"]
		items.queue_redraw()
		return true
	return _can_drop_data(at_position, data)


func _drop_on_items(at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and data.has(DRAG_KEY):
		var before := int(drop_target(at_position)["before"])
		_clear_drop_line()
		if editor != null and editor.device != null:
			SamplerActions.reorder_zones(editor.device, data[DRAG_KEY], before)
		return
	_drop_data(at_position, data)


func _draw_drop_line() -> void:
	if _drop_line_y >= 0.0:
		items.draw_line(Vector2(0.0, _drop_line_y), Vector2(items.size.x, _drop_line_y), DROP_LINE_COLOR, 2.0)


func _clear_drop_line() -> void:
	if _drop_line_y >= 0.0:
		_drop_line_y = -1.0
		items.queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_clear_drop_line()


# --- drops -----------------------------------------------------------------

## Audio files dropped on the list (or its search field) are added as zones, like on the map.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return editor != null and not SampleDisplay.audio_assets_in(data).is_empty()


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	drop_assets(SampleDisplay.audio_assets_in(data))


## Add the files of `assets` as zones.
func drop_assets(assets: Array) -> void:
	if editor != null and editor.device != null and not assets.is_empty():
		SamplerActions.drop_files(editor.device, assets.map(func(a: Asset): return a.path))
