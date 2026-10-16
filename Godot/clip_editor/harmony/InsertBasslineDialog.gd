## Options of Insert Bassline (spec 048, REQ-035): the pattern and the bass note range. Both are
## remembered (REQ-004). Confirming emits `applied`; ClipEditor runs NoteEditor.insert_bassline.
class_name InsertBasslineDialog extends ConfirmationDialog

## The user confirmed: a HarmonyGenerators.Pattern and the bass range (lo, hi).
signal applied(pattern: int, bass_range: Vector2i)

## Pattern option items, in the order shown. The config strings are NoteEditor's.
const PATTERNS: Array = [
	["Sustained", HarmonyGenerators.Pattern.SUSTAINED, "sustained"],
	["Pulse", HarmonyGenerators.Pattern.PULSE, "pulse"],
	["Root and fifth", HarmonyGenerators.Pattern.ROOT_FIFTH, "root_fifth"],
]

var pattern_option: OptionButton
var range_row: PitchRangeRow


func _init() -> void:
	title = "Insert Bassline"
	ok_button_text = "Insert"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var prompt := Label.new()
	prompt.text = "Add bass notes under the chords among the selected notes."
	box.add_child(prompt)
	var pattern_row := HBoxContainer.new()
	pattern_row.add_theme_constant_override("separation", 8)
	box.add_child(pattern_row)
	var pattern_label := Label.new()
	pattern_label.text = "Pattern"
	pattern_row.add_child(pattern_label)
	pattern_option = OptionButton.new()
	for p: Array in PATTERNS:
		pattern_option.add_item(p[0], p[1])
	pattern_option.tooltip_text = "Sustained plays one note per chord. Pulse and Root and fifth step by the current grid value."
	pattern_row.add_child(pattern_option)
	var range_label := Label.new()
	range_label.text = "Bass range"
	box.add_child(range_label)
	range_row = PitchRangeRow.new()
	range_row.tooltip_text = "The bass notes stay inside this range."
	box.add_child(range_row)
	confirmed.connect(_on_confirmed)


## Show the dialog with the remembered options.
func open() -> void:
	pattern_option.select(pattern_option.get_item_index(NoteEditor.bassline_pattern()))
	range_row.set_range(NoteEditor.bassline_range())
	popup_centered()


func pattern() -> int:
	return pattern_option.get_selected_id()


func _on_confirmed() -> void:
	var config_name := "sustained"
	for p: Array in PATTERNS:
		if p[1] == pattern():
			config_name = p[2]
	NoteEditor.store_config(NoteEditor.BASSLINE_PATTERN_KEY, config_name)
	var r := range_row.range_value()
	NoteEditor.store_config(NoteEditor.BASSLINE_RANGE_KEY, [r.x, r.y])
	applied.emit(pattern(), r)
