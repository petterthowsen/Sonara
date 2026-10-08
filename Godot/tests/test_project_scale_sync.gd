# test_project_scale_sync.gd
# Spec 027 (REQ-015): the project scale reaches the engine as a 12-bit pitch-class mask on
# /project/scale, and the Transpose "Scale Type" labels match the scale catalogue.
# Run: godot --headless --path Godot -s tests/test_project_scale_sync.gd -- --test
#
# Headless the OSC client never becomes ready, so sends queue in AudioEngineOSC._pending_sends.
extends TestBase

## Transpose parameter 12 (Scale Type) choices as the engine advertises them: MusicalScale.TYPES
## labels in order, without "None".
const ENGINE_SCALE_TYPES := ["Major", "Natural Minor", "Harmonic Minor", "Melodic Minor", "Dorian", "Phrygian", "Lydian", "Mixolydian", "Locrian", "Major Pentatonic", "Minor Pentatonic", "Blues"]

var _osc: Node


func suite_name() -> String:
	return "Project scale sync"


func run_tests() -> void:
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	var scale_script: GDScript = load("res://data/MusicalScale.gd")
	_test_mask(scale_script)
	_test_set_scale()
	_test_labels(scale_script)


func _scale_sends() -> Array:
	return _osc._pending_sends.filter(func(item) -> bool: return item.address == "/project/scale")


func _test_mask(scale_script: GDScript) -> void:
	_assert(scale_script.make(0, "major").mask() == 2741, "C major mask is 2741: %d" % scale_script.make(0, "major").mask())
	# D natural minor = D E F G A A# C -> bits 2 4 5 7 9 10 0
	_assert(scale_script.make(2, "natural_minor").mask() == 0b011010110101, "D natural minor mask: %d" % scale_script.make(2, "natural_minor").mask())
	_assert(scale_script.make(5, "none").mask() == 0, "none has mask 0")
	_assert(scale_script.make(0, "blues").mask() == (1 | 1 << 3 | 1 << 5 | 1 << 6 | 1 << 7 | 1 << 10), "C blues mask")


func _test_set_scale() -> void:
	var project: Object = load("res://data/Project.gd").new()
	_osc._pending_sends.clear()
	# Not connected yet: the scale waits for the project sync.
	project.set_scale(2, "natural_minor")
	_assert(_scale_sends().is_empty(), "no send while disconnected")
	project._connection_state = project.ConnectionState.CONNECTED
	project.set_scale(2, "natural_minor")
	_assert(_scale_sends().is_empty(), "an unchanged scale sends nothing")
	project.set_scale(0, "major")
	project.set_scale(2, "natural_minor")
	var sent := _scale_sends()
	_assert(sent.size() == 2 and sent[0].args == [2741] and sent[1].args == [0b011010110101], "set_scale sends the mask: %s" % [sent])
	_osc._pending_sends.clear()
	project.set_scale(2, "none")
	sent = _scale_sends()
	_assert(sent.size() == 1 and sent[0].args == [0], "none sends 0: %s" % [sent])
	_osc._pending_sends.clear()
	project._send_scale_to_engine()
	_assert(_scale_sends().size() == 1 and _scale_sends()[0].args == [0], "project sync sends the current mask")


func _test_labels(scale_script: GDScript) -> void:
	var labels: Array = []
	for entry in scale_script.TYPES:
		if entry["id"] != scale_script.NONE_ID:
			labels.append(entry["label"])
	_assert(labels == ENGINE_SCALE_TYPES, "Transpose Scale Type labels match MusicalScale.TYPES minus None: %s" % [labels])
