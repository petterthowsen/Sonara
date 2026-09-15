# test_name_style.gd
# Headless tests for the "Capitalized Lower Case" naming convention (NameStyle) and the
# normalized name comparisons built on it.
# Run: godot --headless --path Godot -s tests/test_name_style.gd -- --test
extends TestBase


func suite_name() -> String:
	return "NameStyle tests"


func run_tests() -> void:
	_test_key()
	_test_format()
	_test_naming_helpers()


func _test_key() -> void:
	_assert(NameStyle.key("  Bass   Line ") == "bass line", "key trims, collapses and lowercases")
	_assert(NameStyle.same("capitalized_lower_case", "Capitalized Lower Case"), "underscores match spaces")
	_assert(NameStyle.same("DRUM bus", "drum Bus"), "casing ignored")
	_assert(not NameStyle.same("Hi-Hat", "Hi Hat"), "hyphens are significant")


func _test_format() -> void:
	_assert(NameStyle.format("capitalized_lower_case") == "Capitalized Lower Case", "snake_case → Title Case")
	_assert(NameStyle.format("bass line") == "Bass Line", "lower → Title Case")
	_assert(NameStyle.format("CITY GROOVE") == "City Groove", "shouting → Title Case")
	_assert(NameStyle.format("hi-hat") == "Hi-Hat", "hyphen parts capitalized")
	_assert(NameStyle.format("drum FX") == "Drum FX", "short acronyms kept")
	_assert(NameStyle.format("TR-808 kick") == "TR-808 Kick", "parts with digits kept")
	_assert(NameStyle.format("PolySynth pad") == "PolySynth Pad", "mixed case kept")
	_assert(NameStyle.format("delay 2") == "Delay 2", "numbers kept")
	_assert(NameStyle.format("   ") == "", "blank stays blank")


func _test_naming_helpers() -> void:
	var existing := PackedStringArray(["Bass Line"])
	_assert(DeviceNaming.is_taken(existing, "bass_line"), "is_taken uses the normalized key")
	_assert(DeviceNaming.unique_in(existing, "Bass  Line") == "Bass Line 2", "unique_in suffixes normalized collisions")
	_assert(DeviceNaming.names_equal("drum_bus", "Drum Bus"), "names_equal uses the normalized key")
