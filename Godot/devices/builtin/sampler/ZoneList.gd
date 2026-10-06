## The multisample editor's sample list (spec 023, REQ-042, REQ-048): the visible zones by name,
## filtered by the search field (case-insensitive substring). The `ItemList`'s own multi-select
## gives click, Ctrl-click and Shift-click; the clicked zone becomes focused and the selection is
## the editor's, shared with the zone map. Missing zones show dimmed with the reason as a tooltip.
## Right-click opens the batch menu; Delete and Ctrl+A work while the list has focus. The layout
## lives in `ZoneList.tscn`.
class_name ZoneList extends VBoxContainer

const MISSING_COLOR := Color(0.85, 0.45, 0.45, 0.7)

@onready var search: LineEdit = %Search
@onready var items: ItemList = %Items

var editor: MultisampleEditor = null
## Zone id of each row.
var row_ids: Array[int] = []
var _syncing := false
var _links: Array = []


func _ready() -> void:
	search.text_changed.connect(func(_t: String) -> void: rebuild())
	items.item_clicked.connect(_on_item_clicked)
	items.empty_clicked.connect(_on_empty_clicked)
	items.gui_input.connect(_on_items_input)


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
