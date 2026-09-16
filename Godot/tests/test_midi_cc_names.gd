# test_midi_cc_names.gd
# Headless tests for Midi.cc_name / Midi.cc_display_name (REQ-016).
# Run: godot --headless --path Godot -s tests/test_midi_cc_names.gd -- --test
extends TestBase


func suite_name() -> String:
	return "MIDI CC name tests"


func run_tests() -> void:
	_test_standard_names()
	_test_unassigned_falls_back()
	_test_never_empty()
	_test_display_name_prefers_device_label()


func _test_standard_names() -> void:
	var expected := {
		1: "Mod Wheel",
		7: "Volume",
		10: "Pan",
		11: "Expression",
		64: "Sustain",
		74: "Cutoff",
	}
	for cc in expected:
		var name: String = Midi.cc_name(cc)
		_assert(name == expected[cc], "CC%d = %s (expected %s)" % [cc, name, expected[cc]])


func _test_unassigned_falls_back() -> void:
	var name: String = Midi.cc_name(3)
	_assert(name == "CC3", "unassigned CC3 falls back to CC3, got %s" % name)


func _test_never_empty() -> void:
	for cc in range(0, 128):
		var name: String = Midi.cc_name(cc)
		_assert(name != "", "CC%d must not return an empty name" % cc)


func _test_display_name_prefers_device_label() -> void:
	var standard: String = Midi.cc_display_name(1)
	_assert(standard == "CC1 Mod Wheel", "standard display name, got %s" % standard)
	var device_label: String = Midi.cc_display_name(1, "Vibrato")
	_assert(device_label.find("Vibrato") >= 0, "device-supplied label wins, got %s" % device_label)
