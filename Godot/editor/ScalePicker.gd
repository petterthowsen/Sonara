## Main toolbar control for the project scale (spec 026): a root and a scale type dropdown side
## by side. The root is disabled while the type is None.
class_name ScalePicker extends HBoxContainer

## The user picked a root or a type.
signal scale_picked(root: int, type_id: String)

var _root_option: OptionButton
var _type_option: OptionButton


func _init() -> void:
	_root_option = OptionButton.new()
	for i in Midi.NOTE_NAMES.size():
		_root_option.add_item(Midi.NOTE_NAMES[i], i)
	_root_option.tooltip_text = "Scale root"
	_type_option = OptionButton.new()
	for i in MusicalScale.TYPES.size():
		var label: String = MusicalScale.TYPES[i]["label"]
		_type_option.add_item("No scale" if MusicalScale.TYPES[i]["id"] == MusicalScale.NONE_ID else label, i)
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
	scale_picked.emit(_root_option.selected, MusicalScale.TYPES[_type_option.selected]["id"])


func _sync_root_enabled() -> void:
	_root_option.disabled = MusicalScale.TYPES[_type_option.selected]["id"] == MusicalScale.NONE_ID


## Show the given scale without emitting scale_picked.
func set_scale_display(root: int, type_id: String) -> void:
	var s := MusicalScale.make(root, type_id)
	_root_option.select(s.root)
	for i in MusicalScale.TYPES.size():
		if MusicalScale.TYPES[i]["id"] == s.type_id:
			_type_option.select(i)
			break
	_sync_root_enabled()


## The selection as display text ("D Dorian", "No scale"), for tests and tooltips.
func display_text() -> String:
	return MusicalScale.make(_root_option.selected, MusicalScale.TYPES[_type_option.selected]["id"]).display_name()
