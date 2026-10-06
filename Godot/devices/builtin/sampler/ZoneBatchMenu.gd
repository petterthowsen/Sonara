## The batch operations menu for the selected zones (spec 023, REQ-047), shared by the zone map and
## the sample list. The map lists the zones under the pointer first (REQ-046): choosing one selects
## and focuses it. Assign and distribute open the `ZoneBatchDialog` for their range; the rest
## apply at once. Each operation is one undo step (`SamplerActions.apply_batch`).
##
## A node in `MultisampleEditor.tscn`, with its "Move to Group" submenu as a child.
class_name ZoneBatchMenu extends PopupMenu

## Item ids of the operations: their index in `SamplerActions.BATCH_OPS`.
const OP_TEXTS := {
	"assign_velocity": "Assign Velocity…",
	"assign_note": "Assign Note…",
	"distribute_velocity": "Distribute on Velocity…",
	"distribute_notes": "Distribute on Notes…",
	"flip_velocity": "Flip Velocity",
	"mirror_notes": "Mirror Notes",
	"set_root_from_name": "Set Root from Name",
	"sort_by_name": "Sort by Name",
	"move_to_group": "Move to Group",
	"delete": "Delete",
}
## Operations that ask for a range first.
const DIALOG_OPS := ["assign_velocity", "assign_note", "distribute_velocity", "distribute_notes"]
## Zone items (the stack under the pointer) use ids from here up.
const ZONE_ID_BASE := 1000

@onready var groups_menu: PopupMenu = $GroupsMenu

var editor: MultisampleEditor = null
## Zone ids listed at the top, by item order.
var _zone_items: Array[int] = []
var _screen_position := Vector2.ZERO


func _ready() -> void:
	id_pressed.connect(_on_id_pressed)
	groups_menu.id_pressed.connect(_on_group_chosen)


func bind(p_editor: MultisampleEditor) -> void:
	editor = p_editor


## Rebuild the items for the current selection, with `zones_under` (SamplerZones) on top.
func fill(zones_under: Array = []) -> void:
	clear()
	_zone_items.clear()
	var focused := editor.model.focused_zone_id if editor and editor.model else 0
	for zone in zones_under:
		add_radio_check_item(zone.name, ZONE_ID_BASE + _zone_items.size())
		set_item_checked(item_count - 1, zone.id == focused)
		_zone_items.append(zone.id)
	if not _zone_items.is_empty():
		add_separator()
	var has_selection := editor != null and not editor.selected_ids.is_empty()
	for i in SamplerActions.BATCH_OPS.size():
		var op: String = SamplerActions.BATCH_OPS[i]
		if op == "delete":
			add_separator()
		if op == "move_to_group":
			_fill_groups()
			add_submenu_node_item(OP_TEXTS[op], groups_menu, i)
		else:
			add_item(OP_TEXTS[op], i)
		set_item_disabled(item_count - 1, not has_selection)


func _fill_groups() -> void:
	groups_menu.clear()
	groups_menu.add_item(SamplerZoneGroup.UNGROUPED_NAME, SamplerZoneGroup.UNGROUPED_ID)
	if editor == null or editor.model == null:
		return
	for group in editor.model.groups:
		groups_menu.add_item(group.name, group.id)


func open(screen_position: Vector2, zones_under: Array = []) -> void:
	_screen_position = screen_position
	fill(zones_under)
	popup(Rect2i(Vector2i(screen_position), Vector2i.ZERO))


## The operation texts in item order, without separators or zone items (for tests).
func op_texts() -> Array[String]:
	var out: Array[String] = []
	for i in item_count:
		if not is_item_separator(i) and get_item_id(i) < ZONE_ID_BASE:
			out.append(get_item_text(i))
	return out


func _on_id_pressed(id: int) -> void:
	if editor == null or editor.device == null:
		return
	if id >= ZONE_ID_BASE:
		var zone_id := _zone_items[id - ZONE_ID_BASE]
		editor.set_selection([zone_id], zone_id)
		return
	run(SamplerActions.BATCH_OPS[id])


## Run operation `op` on the selection: open the range dialog, or apply it at once.
func run(op: String) -> void:
	var ids := editor.selected_in_order()
	if ids.is_empty():
		return
	if op in DIALOG_OPS:
		editor.batch_dialog.open_for(editor.device, op, ids, _screen_position)
	elif op != "move_to_group":
		SamplerActions.apply_batch(editor.device, op, ids)


func _on_group_chosen(group_id: int) -> void:
	if editor != null and editor.device != null:
		SamplerActions.apply_batch(editor.device, "move_to_group", editor.selected_in_order(), {"group": group_id})
