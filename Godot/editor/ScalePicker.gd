## Main toolbar control for the project scale (spec 026): a root and a scale type dropdown side
## by side. The root is disabled while the type is None.
class_name ScalePicker extends HBoxContainer

## The user picked a root or a type.
signal scale_picked(root: int, type_id: String)

var _root_option: OptionButton
var _type_option: OptionButton

## Returns a KeyDetector result dictionary (ok, root, type_id, confidence, reason) for the span
## this picker's owner cares about. Unset means no Detect row. Detect never changes the scale:
## the result is shown and only Use picks it (through scale_picked).
var detect_source: Callable = Callable():
	set(value):
		detect_source = value
		_sync_detect_row()

var detect_button: Button
var result_label: Label
var use_button: Button
## The last Detect result ({} before the first Detect or after clear_detection).
var last_result: Dictionary = {}


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
	_build_detect_row()
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


# --- Detect (spec 048, REQ-010, REQ-011) ---

func _build_detect_row() -> void:
	detect_button = Button.new()
	detect_button.text = "Detect"
	detect_button.flat = true
	detect_button.add_theme_font_size_override("font_size", 12)
	detect_button.tooltip_text = "Estimate the key from the MIDI notes. Nothing changes until you press Use."
	detect_button.pressed.connect(detect)
	add_child(detect_button)
	result_label = Label.new()
	result_label.add_theme_font_size_override("font_size", 12)
	result_label.visible = false
	add_child(result_label)
	use_button = Button.new()
	use_button.text = "Use"
	use_button.flat = true
	use_button.add_theme_font_size_override("font_size", 12)
	use_button.tooltip_text = "Set the detected key"
	use_button.visible = false
	use_button.pressed.connect(use_detected)
	add_child(use_button)
	_sync_detect_row()


func _sync_detect_row() -> void:
	if detect_button == null:
		return
	detect_button.visible = detect_source.is_valid()
	if not detect_source.is_valid():
		clear_detection()


## Run the detect source and show its result. Does not change the scale.
func detect() -> void:
	if not detect_source.is_valid():
		return
	var result: Variant = detect_source.call()
	last_result = result if result is Dictionary else {}
	var ok: bool = last_result.get("ok", false)
	if ok:
		result_label.text = "%s (%s)" % [MusicalScale.make(last_result.root, last_result.type_id).display_name(),
				last_result.confidence]
	else:
		result_label.text = str(last_result.get("reason", KeyDetector.NOT_ENOUGH_NOTES))
	result_label.visible = true
	use_button.visible = true
	use_button.disabled = not ok


## Apply the detected key: show it and emit scale_picked, like picking it by hand.
func use_detected() -> void:
	if not last_result.get("ok", false):
		return
	var root: int = last_result.root
	var type_id: String = last_result.type_id
	clear_detection()
	set_scale_display(root, type_id)
	scale_picked.emit(root, type_id)


## Hide the last result (a new target, or after Use).
func clear_detection() -> void:
	last_result = {}
	if result_label:
		result_label.visible = false
		result_label.text = ""
	if use_button:
		use_button.visible = false
