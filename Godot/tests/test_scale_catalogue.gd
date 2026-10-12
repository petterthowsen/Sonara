# test_scale_catalogue.gd
# Spec 038: scale catalogue contents, key spelling, clip editor note names, grouped scale picker.
# Run: godot --headless --path Godot -s tests/test_scale_catalogue.gd -- --test
extends TestBase

## REQ-001 table: [group, label, intervals].
const ROWS: Array = [
	["Common", "Major", [0, 2, 4, 5, 7, 9, 11]],
	["Common", "Natural Minor", [0, 2, 3, 5, 7, 8, 10]],
	["Common", "Harmonic Minor", [0, 2, 3, 5, 7, 8, 11]],
	["Common", "Melodic Minor", [0, 2, 3, 5, 7, 9, 11]],
	["Common", "Dorian", [0, 2, 3, 5, 7, 9, 10]],
	["Common", "Phrygian", [0, 1, 3, 5, 7, 8, 10]],
	["Common", "Lydian", [0, 2, 4, 6, 7, 9, 11]],
	["Common", "Mixolydian", [0, 2, 4, 5, 7, 9, 10]],
	["Common", "Locrian", [0, 1, 3, 5, 6, 8, 10]],
	["Common", "Major Pentatonic", [0, 2, 4, 7, 9]],
	["Common", "Minor Pentatonic", [0, 3, 5, 7, 10]],
	["Common", "Blues", [0, 3, 5, 6, 7, 10]],
	["Melodic Minor Modes", "Dorian b2", [0, 1, 3, 5, 7, 9, 10]],
	["Melodic Minor Modes", "Lydian Augmented", [0, 2, 4, 6, 8, 9, 11]],
	["Melodic Minor Modes", "Lydian Dominant", [0, 2, 4, 6, 7, 9, 10]],
	["Melodic Minor Modes", "Mixolydian b6", [0, 2, 4, 5, 7, 8, 10]],
	["Melodic Minor Modes", "Half-Diminished", [0, 2, 3, 5, 6, 8, 10]],
	["Melodic Minor Modes", "Altered", [0, 1, 3, 4, 6, 8, 10]],
	["Harmonic Modes", "Locrian ♮6", [0, 1, 3, 5, 6, 9, 10]],
	["Harmonic Modes", "Ionian #5", [0, 2, 4, 5, 8, 9, 11]],
	["Harmonic Modes", "Ukrainian Dorian", [0, 2, 3, 6, 7, 9, 10]],
	["Harmonic Modes", "Phrygian Dominant", [0, 1, 4, 5, 7, 8, 10]],
	["Harmonic Modes", "Lydian #2", [0, 3, 4, 6, 7, 9, 11]],
	["Harmonic Modes", "Harmonic Major", [0, 2, 4, 5, 7, 8, 11]],
	["Exotic", "Double Harmonic", [0, 1, 4, 5, 7, 8, 11]],
	["Exotic", "Hungarian Minor", [0, 2, 3, 6, 7, 8, 11]],
	["Exotic", "Hungarian Major", [0, 3, 4, 6, 7, 9, 10]],
	["Exotic", "Neapolitan Major", [0, 1, 3, 5, 7, 9, 11]],
	["Exotic", "Neapolitan Minor", [0, 1, 3, 5, 7, 8, 11]],
	["Exotic", "Persian", [0, 1, 4, 5, 6, 8, 11]],
	["Exotic", "Enigmatic", [0, 1, 4, 6, 8, 10, 11]],
	["Symmetric", "Whole Tone", [0, 2, 4, 6, 8, 10]],
	["Symmetric", "Diminished (Half-Whole)", [0, 1, 3, 4, 6, 7, 9, 10]],
	["Symmetric", "Diminished (Whole-Half)", [0, 2, 3, 5, 6, 8, 9, 11]],
	["Symmetric", "Augmented", [0, 3, 4, 7, 8, 11]],
	["Bebop and Blues", "Bebop Dominant", [0, 2, 4, 5, 7, 9, 10, 11]],
	["Bebop and Blues", "Bebop Major", [0, 2, 4, 5, 7, 8, 9, 11]],
	["Bebop and Blues", "Bebop Dorian", [0, 2, 3, 4, 5, 7, 9, 10]],
	["Bebop and Blues", "Major Blues", [0, 2, 3, 4, 7, 9]],
	["Bebop and Blues", "Spanish 8-Tone", [0, 1, 3, 4, 5, 6, 8, 10]],
	["Pentatonic and World", "Egyptian", [0, 2, 5, 7, 10]],
	["Pentatonic and World", "Yo", [0, 2, 5, 7, 9]],
	["Pentatonic and World", "Hirajoshi", [0, 2, 3, 7, 8]],
	["Pentatonic and World", "In Sen", [0, 1, 5, 7, 10]],
	["Pentatonic and World", "Iwato", [0, 1, 5, 6, 10]],
	["Pentatonic and World", "Kumoi", [0, 2, 3, 7, 9]],
	["Pentatonic and World", "Pelog", [0, 1, 3, 7, 8]],
]

const OLD_IDS: Array[String] = [
	"major", "natural_minor", "harmonic_minor", "melodic_minor", "dorian", "phrygian", "lydian",
	"mixolydian", "locrian", "major_pentatonic", "minor_pentatonic", "blues",
]


func suite_name() -> String:
	return "Scale catalogue"


func run_tests() -> void:
	_test_catalogue_rows()
	_test_old_ids()
	_test_lydian_dominant()
	_test_spelling_examples()
	_test_midi_flat_names()
	_test_context_spelling()
	_test_picker()


func _test_catalogue_rows() -> void:
	_assert(MusicalScale.TYPES.size() == ROWS.size() + 1, "catalogue is none plus %d scales" % ROWS.size())
	_assert(MusicalScale.TYPES[0]["id"] == "none", "none is first")
	for i in ROWS.size():
		var row: Array = ROWS[i]
		var entry: Dictionary = MusicalScale.TYPES[i + 1]
		_assert(entry["label"] == row[1], "row %d label %s" % [i, row[1]])
		_assert(entry["group"] == row[0], "row %d (%s) group" % [i, row[1]])
		_assert(Array(entry["intervals"]) == row[2], "row %d (%s) intervals" % [i, row[1]])
		_assert(MusicalScale.group_for(entry["id"]) == row[0], "group_for %s" % row[1])
	var seen := {}
	for g in MusicalScale.GROUPS:
		seen[g] = true
	_assert(MusicalScale.GROUPS.size() == 7 and seen.size() == 7, "7 distinct groups")


func _test_old_ids() -> void:
	for id in OLD_IDS:
		_assert(MusicalScale.is_valid_type(id), "old id %s still resolves" % id)
		_assert(MusicalScale.make(0, id).type_id == id, "old id %s kept by make" % id)


func _test_lydian_dominant() -> void:
	_assert(Array(MusicalScale.make(0, "lydian_dominant").pitch_classes()) == [0, 2, 4, 6, 7, 9, 10], "C Lydian Dominant is C D E F# G A A#")


func _name(root: int, id: String) -> String:
	return MusicalScale.make(root, id).display_name()


func _test_spelling_examples() -> void:
	_assert(_name(10, "major") == "Bb Major", "Bb Major")
	_assert(_name(1, "major") == "Db Major", "Db Major")
	_assert(_name(6, "major") == "F# Major", "F# Major (tie, reference F#)")
	_assert(_name(2, "natural_minor") == "D Natural Minor", "D Natural Minor")
	_assert(_name(5, "natural_minor") == "F Natural Minor", "F Natural Minor")
	_assert(_name(10, "natural_minor") == "Bb Natural Minor", "Bb Natural Minor")
	_assert(_name(1, "natural_minor") == "C# Natural Minor", "C# Natural Minor")
	_assert(_name(3, "dorian") == "Eb Dorian", "Eb Dorian")
	_assert(_name(10, "minor_pentatonic") == "Bb Minor Pentatonic", "Bb Minor Pentatonic (tie, reference Db)")
	_assert(_name(3, "natural_minor") == "D# Natural Minor", "D# Natural Minor (tie, reference F#)")
	_assert(_name(5, "none") == "No scale", "none")
	_assert(not MusicalScale.make(10, "none").uses_flats(), "none never uses flats")
	var f := MusicalScale.make(10, "major")
	_assert(f.note_name(70) == "Bb" and f.note_name(61) == "Db" and f.root_name() == "Bb", "note_name and root_name follow the spelling")


func _test_midi_flat_names() -> void:
	_assert(Midi.midi_to_note_name(70, true) == "Bb3", "70 with flats is Bb3")
	_assert(Midi.midi_to_note_name(70) == "A#3", "70 default is A#3")
	_assert(Midi.midi_to_note_name(60, true) == "C3", "natural notes unchanged")
	_assert(Midi.FLAT_NOTE_NAMES.size() == 12, "12 flat names")


func _test_context_spelling() -> void:
	var ctx := ScaleContext.new()
	_assert(not ctx.spell_flats(), "no scale: sharps")
	ctx.scale = MusicalScale.make(5, "major")
	_assert(ctx.spell_flats(), "F Major: flats")
	_assert(Midi.midi_to_note_name(70, ctx.spell_flats()) == "Bb3", "MIDI 70 is Bb3 with F Major")
	ctx.drum_view = true
	_assert(not ctx.spell_flats(), "Drum View keeps sharps")
	_assert(Midi.midi_to_note_name(70, ctx.spell_flats()) == "A#3", "MIDI 70 is A#3 in Drum View")
	ctx.drum_view = false
	ctx.scale = MusicalScale.new()
	_assert(Midi.midi_to_note_name(70, ctx.spell_flats()) == "A#3", "MIDI 70 is A#3 with no scale")


func _test_picker() -> void:
	var picker := ScalePicker.new()
	var type_option: OptionButton = picker._type_option
	var root_option: OptionButton = picker._root_option
	var headings := 0
	var heading_names: Array[String] = []
	for i in type_option.item_count:
		if type_option.is_item_separator(i):
			headings += 1
			heading_names.append(type_option.get_item_text(i))
			# Separators can't be chosen from the popup; get_item_id is -1 for them.
			_assert(type_option.get_item_id(i) < 0 or type_option.get_item_id(i) == i, "heading %d is a separator" % i)
	_assert(headings == 7, "type menu has 7 group headings")
	_assert(heading_names == MusicalScale.GROUPS, "headings in catalogue order")
	_assert(type_option.item_count == MusicalScale.TYPES.size() + 7, "every scale plus 7 headings")
	_assert(type_option.get_item_text(0) == "No scale", "No scale is first")
	_assert(type_option.is_item_separator(1) and type_option.get_item_text(1) == "Common", "first heading follows No scale")

	picker.set_scale_display(3, "hirajoshi")
	_assert(picker.display_text() == "D# Hirajoshi", "set_scale_display(3, hirajoshi) reads D# Hirajoshi, got '%s'" % picker.display_text())
	_assert(not root_option.disabled, "root enabled with a scale")
	picker.set_scale_display(0, "none")
	_assert(picker.display_text() == "No scale" and root_option.disabled, "none disables the root")

	var picked := []
	picker.scale_picked.connect(func(r, t): picked.append([r, t]))
	type_option.select(type_option.get_item_index(MusicalScale.TYPES.size() - 1))
	type_option.item_selected.emit(type_option.selected)
	_assert(picked == [[0, "pelog"]], "picking the last scale emits its id, got %s" % str(picked))

	var labels: Array[String] = []
	for i in root_option.item_count:
		labels.append(root_option.get_item_text(i))
	_assert(root_option.item_count == 12, "12 roots")
	_assert(labels == ["C", "C#/Db", "D", "D#/Eb", "E", "F", "F#/Gb", "G", "G#/Ab", "A", "A#/Bb", "B"], "root labels show both spellings")
	picker.free()
