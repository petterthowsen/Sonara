# ConversationList.gd
# Compact dropdown of per-project conversations.
class_name ConversationList extends OptionButton


signal conversation_chosen(id: String)


var _ids: PackedStringArray = []
var _guard: bool = false


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_selected.connect(_on_item_selected)


## Refresh entries and select `active_id`.
func rebuild(entries: Array, active_id: String) -> void:
	_guard = true
	clear()
	_ids.clear()
	var select := 0
	for i in range(entries.size()):
		var entry = entries[i]
		if not entry is Dictionary:
			continue
		var id := str(entry.get("id", ""))
		var title := str(entry.get("title", "New chat"))
		if title.is_empty():
			title = "New chat"
		add_item(title)
		_ids.append(id)
		if id == active_id:
			select = _ids.size() - 1
	if item_count == 0:
		add_item("New chat")
		_ids.append("")
	if item_count > 0:
		selected = clampi(select, 0, item_count - 1)
	_guard = false


func _on_item_selected(index: int) -> void:
	if _guard or index < 0 or index >= _ids.size():
		return
	var id := _ids[index]
	if not id.is_empty():
		conversation_chosen.emit(id)
