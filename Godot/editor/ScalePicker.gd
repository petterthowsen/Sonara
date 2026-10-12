## Main toolbar control for the project scale (spec 026): a root and a scale type dropdown side
## by side. The root is disabled while the type is None.
class_name ScalePicker extends HBoxContainer

## The user picked a root or a type.
signal scale_picked(root: int, type_id: String)

var _root_option: OptionButton
var _type_option: OptionButton


func _init() -> void:
	_root_option = OptionButton.new()
	for i in MusicalScale.ROOT_LABELS.size():
		_root_option.add_item(MusicalScale.ROOT_LABELS[i], i)
	_root_option.tooltip_text = "Scale root"
	_type_option = OptionButton.new()
	# Item id = catalogue index; group headings are separators, which take item indices of their
	# own, so selection goes through get_item_index / get_selected_id.
	var last_group := ""
	for i in MusicalScale.TYPES.size():
		var entry: Dictionary = MusicalScale.TYPES[i]
		var group: String = entry["group"]
		if group != last_group and not group.is_empty():
			_type_option.add_separator(group)
			last_group = group
		_type_option.add_item("No scale" if entry["id"] == MusicalScale.NONE_ID else entry["label"], i)
	_type_option.tooltip_text = "Project scale: tints and highlights lanes in the piano roll"
	for option in [_root_option, _type_option]:
		option.flat = true
		option.add_theme_font_size_override("font_size", 12)
		add_child(option)
	_root_option.item_selected.connect(func(_i): _emit_picked())
	_type_option.item_selected.connect(func(_i): _emit_picked())
	set_scale_display(0, MusicalScale.NONE_ID)


func _emit_picked() -> void:
	_sync_root_enabled()
	scale_picked.emit(_root_option.get_selected_id(), _selected_type_id())


func _selected_type_id() -> String:
	var idx := _type_option.get_selected_id()
	return MusicalScale.TYPES[idx]["id"] if idx >= 0 and idx < MusicalScale.TYPES.size() else MusicalScale.NONE_ID


func _sync_root_enabled() -> void:
	_root_option.disabled = _selected_type_id() == MusicalScale.NONE_ID


## Show the given scale without emitting scale_picked.
func set_scale_display(root: int, type_id: String) -> void:
	var s := MusicalScale.make(root, type_id)
	_root_option.select(_root_option.get_item_index(s.root))
	for i in MusicalScale.TYPES.size():
		if MusicalScale.TYPES[i]["id"] == s.type_id:
			_type_option.select(_type_option.get_item_index(i))
			break
	_sync_root_enabled()


## The selection as display text ("D Dorian", "No scale"), for tests and tooltips.
func display_text() -> String:
	return MusicalScale.make(_root_option.get_selected_id(), _selected_type_id()).display_name()
