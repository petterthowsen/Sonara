# test_note_fx_category.gd
# Spec 027 (REQ-034): engine devices advertised with the category "note_effect" land in the Note
# Effect category and the "Note Effects" browser group, and nowhere else.
# Run: godot --headless --path Godot -s tests/test_note_fx_category.gd -- --test
extends TestBase

const NOTE_FX := ["transpose", "note_filter", "velocity", "chord", "arpeggiator", "step_sequencer", "note_echo", "chance", "note_length", "latch"]
const NOTE_CONTAINERS := ["note_layer", "note_selector"]


func suite_name() -> String:
	return "Note effect category"


func run_tests() -> void:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	for n in NOTE_FX:
		registry._on_builtin_info_received(["sonara.builtin." + n, n, "note_effect", "", 1, 2, 2, 0, "", 0, 0, 0])
	for n in NOTE_CONTAINERS:
		registry._on_builtin_info_received(["sonara.builtin." + n, n, "note_effect", "", 1, 2, 2, 0, "", 0, 0, 1])
	registry._on_builtin_info_received(["sonara.builtin.polysynth", "Polysynth", "instrument", "", 1, 0, 2, 0, "", 0, 0, 0])
	registry._on_builtin_info_received(["sonara.builtin.delay", "Delay", "effect", "", 0, 2, 2, 0, "", 0, 0, 0])
	registry._on_builtin_info_received(["sonara.builtin.utility", "Utility", "utility", "", 0, 2, 2, 0, "", 0, 0, 0])

	var in_group: Array = []
	for device in registry.get_devices():
		if device.get_browser_group() == "Note Effects":
			in_group.append(device.device_id)
	_assert(in_group.size() == NOTE_FX.size() + NOTE_CONTAINERS.size(), "all 12 note devices are under Note Effects: %d" % in_group.size())
	for n in NOTE_FX + NOTE_CONTAINERS:
		var device: Object = registry.get_device("sonara.builtin." + n)
		_assert(device.category == Device.DeviceCategory.NoteEffect and device.is_note_effect(), "%s is a note effect" % n)
		_assert(device.get_category_string() == "Note Effect", "%s category string" % n)
		_assert(device.creates_instrument_track(), "%s creates an instrument track" % n)
		_assert(device.get_icon() != "", "%s has an icon" % n)
	for id in ["polysynth", "delay", "utility"]:
		var other: Object = registry.get_device("sonara.builtin." + id)
		_assert(not other.is_note_effect() and other.get_browser_group() != "Note Effects", "%s is not under Note Effects" % id)
	_assert(registry.get_device("sonara.builtin.delay").get_browser_group() == "Effect", "effects keep their group")

	# The device cache stores the category by enum key and reads it back.
	var data: Dictionary = registry._device_to_cache_data(registry.get_device("sonara.builtin.transpose"))
	_assert(data["category"] == "NoteEffect", "cache key: %s" % data["category"])
	_assert(registry._device_from_cache_data(data).category == Device.DeviceCategory.NoteEffect, "cache round trip")
