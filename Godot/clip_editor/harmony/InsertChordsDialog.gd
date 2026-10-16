## Options of Insert Chords (spec 048, REQ-032..034): the progression (Roman numerals, with a
## parse error and presets), the chord length, a chord count (only without a selection range),
## the note range, voicing and inversion. All remembered (REQ-004). Confirming emits `applied`;
## ClipEditor runs NoteEditor.insert_chords with the options.
class_name InsertChordsDialog extends ConfirmationDialog

## The user confirmed: options in the form NoteEditor.insert_chords / chords_options take.
signal applied(options: Dictionary)

## Chord length choices: [label, ticks] (960 ticks per quarter note, bars in 4/4).
const LENGTHS: Array = [
	["1/16 note", 240], ["1/8 note", 480], ["1/4 note", 960], ["1/2 note", 1920],
	["1 bar", 3840], ["2 bars", 7680],
]

var progression_edit: LineEdit
var error_label: Label
var preset_option: OptionButton
var seventh_check: CheckBox
var length_option: OptionButton
var count_row: HBoxContainer
var count_spin: SpinBox
var range_row: PitchRangeRow
var voicing_option: OptionButton
var inversion_option: OptionButton
var scale_notice: Label


func _init() -> void:
	title = "Insert Chords"
	ok_button_text = "Insert"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size.x = 380
	add_child(box)

	box.add_child(_label("Progression (Roman numerals, a 7 after a numeral makes a 7th chord)"))
	progression_edit = LineEdit.new()
	progression_edit.placeholder_text = "I V vi IV"
	progression_edit.tooltip_text = "Upper or lower case, separated by spaces or dashes. The chords follow the key at each position."
	progression_edit.text_changed.connect(func(_t: String): _validate())
	box.add_child(progression_edit)
	error_label = Label.new()
	error_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.4))
	box.add_child(error_label)

	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 8)
	box.add_child(preset_row)
	preset_row.add_child(_label("Preset"))
	preset_option = OptionButton.new()
	preset_option.add_item("Custom", 0)
	for i in ChordTheory.PRESETS.size():
		preset_option.add_item(ChordTheory.PRESETS[i].name, i + 1)
	preset_option.item_selected.connect(_on_preset_selected)
	preset_row.add_child(preset_option)
	seventh_check = CheckBox.new()
	seventh_check.text = "7th chords"
	seventh_check.tooltip_text = "Make every chord of the progression a 7th chord."
	seventh_check.toggled.connect(_on_seventh_toggled)
	preset_row.add_child(seventh_check)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	grid.add_child(_label("Chord length"))
	length_option = OptionButton.new()
	for i in LENGTHS.size():
		length_option.add_item(LENGTHS[i][0], LENGTHS[i][1])
	grid.add_child(length_option)
	count_row = HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 12)
	box.add_child(count_row)
	count_row.add_child(_label("Number of chords"))
	count_spin = SpinBox.new()
	count_spin.min_value = 1
	count_spin.max_value = 256
	count_spin.step = 1
	count_spin.tooltip_text = "How many chords to insert from the edit position. With a selection range the range sets it."
	count_row.add_child(count_spin)
	grid.add_child(_label("Voicing"))
	voicing_option = OptionButton.new()
	voicing_option.add_item("Close", ChordTheory.Voicing.CLOSE)
	voicing_option.add_item("Spread", ChordTheory.Voicing.SPREAD)
	voicing_option.tooltip_text = "Close keeps a chord within an octave. Spread distributes its notes over more than an octave."
	grid.add_child(voicing_option)
	grid.add_child(_label("Inversion"))
	inversion_option = OptionButton.new()
	inversion_option.add_item("Root position", 0)
	inversion_option.add_item("Smooth (voice leading)", 1)
	inversion_option.tooltip_text = "Smooth picks, for each chord, the inversion that moves the least from the previous chord."
	grid.add_child(inversion_option)

	box.add_child(_label("Note range"))
	range_row = PitchRangeRow.new()
	range_row.tooltip_text = "Every inserted note stays inside this range."
	box.add_child(range_row)
	scale_notice = Label.new()
	scale_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scale_notice.visible = false
	box.add_child(scale_notice)
	confirmed.connect(_on_confirmed)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


## Show the dialog with the remembered options for `editor`: the Count field is hidden when the
## chords will fill a selection range, and a notice appears for scales that are not 7-note.
func open_for(editor: NoteEditor) -> void:
	var opts := NoteEditor.chords_options()
	progression_edit.text = opts.progression
	preset_option.select(0)
	for i in ChordTheory.PRESETS.size():
		if ChordTheory.PRESETS[i].text == opts.progression:
			preset_option.select(i + 1)
	seventh_check.set_pressed_no_signal(opts.seventh_default)
	length_option.select(maxi(0, length_option.get_item_index(opts.length_ticks)))
	count_spin.set_value_no_signal(opts.count)
	count_row.visible = editor == null or not editor.chords_use_range()
	range_row.set_range(opts.range)
	voicing_option.select(voicing_option.get_item_index(opts.voicing))
	inversion_option.select(1 if opts.inversion == "smooth" else 0)
	var n := editor.scale_context.scale.pitch_classes().size() if editor else 7
	scale_notice.visible = n != 7
	scale_notice.text = "Chords follow this %d-note scale." % n
	_validate()
	popup_centered()


## True when the progression parses.
func is_valid() -> bool:
	return ChordTheory.parse_progression(progression_edit.text).error == ""


## Options in the form insert_chords takes.
func options() -> Dictionary:
	var r := range_row.range_value()
	return {
		"progression": progression_edit.text.strip_edges(),
		"length_ticks": length_option.get_selected_id(),
		"count": int(count_spin.value),
		"range": r,
		"voicing": voicing_option.get_selected_id() as ChordTheory.Voicing,
		"inversion": "smooth" if inversion_option.get_selected_id() == 1 else "root",
		"seventh_default": seventh_check.button_pressed,
	}


func _validate() -> void:
	var parsed := ChordTheory.parse_progression(progression_edit.text)
	error_label.text = parsed.error
	get_ok_button().disabled = parsed.error != ""


func _on_preset_selected(index: int) -> void:
	var id := preset_option.get_item_id(index)
	if id == 0:
		return
	progression_edit.text = ChordTheory.PRESETS[id - 1].text
	if seventh_check.button_pressed:
		_apply_sevenths(true)
	_validate()


func _on_seventh_toggled(on: bool) -> void:
	_apply_sevenths(on)
	_validate()


## Add (or remove) the 7 on every numeral of the progression text.
func _apply_sevenths(on: bool) -> void:
	var tokens := progression_edit.text.replace("-", " ").replace(",", " ").split(" ", false)
	if tokens.is_empty():
		return
	var out := PackedStringArray()
	for token in tokens:
		var base: String = token.trim_suffix("7")
		out.append(base + "7" if on else base)
	progression_edit.text = " ".join(out)
	preset_option.select(0)


func _on_confirmed() -> void:
	if not is_valid():
		return
	var o := options()
	NoteEditor.store_config(NoteEditor.CHORDS_PROGRESSION_KEY, o.progression)
	NoteEditor.store_config(NoteEditor.CHORDS_LENGTH_KEY, o.length_ticks)
	NoteEditor.store_config(NoteEditor.CHORDS_COUNT_KEY, o.count)
	NoteEditor.store_config(NoteEditor.CHORDS_RANGE_KEY, [o.range.x, o.range.y])
	NoteEditor.store_config(NoteEditor.CHORDS_VOICING_KEY, "spread" if o.voicing == ChordTheory.Voicing.SPREAD else "close")
	NoteEditor.store_config(NoteEditor.CHORDS_INVERSION_KEY, o.inversion)
	NoteEditor.store_config(NoteEditor.CHORDS_SEVENTH_KEY, o.seventh_default)
	applied.emit(o)
