# test_clip_reverse.gd
# Headless tests for the audio-clip reverse flag: serialization/override plumbing in
# ClipInstance and the audio-only Reverse checkbox in the clip context menu.
#
# The scripts under test reference autoloads (AudioEngineOSC, Sonara), so they are loaded at
# run time rather than named as global classes: a test naming them would compile before the
# autoloads exist.
#
# Run: godot --headless --path Godot -s tests/test_clip_reverse.gd -- --test
extends TestBase

const CLIP_AUDIO := 0  # Clip.ClipType.AUDIO
const CLIP_MIDI := 1   # Clip.ClipType.MIDI

var _instance_script: GDScript
var _clip_script: GDScript


func suite_name() -> String:
	return "Clip reverse"


func run_tests() -> void:
	_instance_script = load("res://data/ClipInstance.gd")
	_clip_script = load("res://data/Clip.gd")
	_test_serialization_round_trip()
	_test_copy_overrides()
	await _test_context_menu()


func _make_instance(clip_type: int) -> RefCounted:
	var clip = _clip_script.new("c")
	clip.type = clip_type
	var inst = _instance_script.new("i", "c")
	inst.clip = clip
	return inst


## `bind_to_instances` wants Array[ClipInstance]; build one without naming the global class.
func _bind(menu: Object, instances: Array) -> void:
	var typed := Array([], TYPE_OBJECT, &"RefCounted", _instance_script)
	for inst in instances:
		typed.append(inst)
	menu.bind_to_instances(typed)


func _test_serialization_round_trip() -> void:
	var inst = _make_instance(CLIP_AUDIO)
	inst.reverse_enabled = true
	var restored = _instance_script.from_json(inst.to_json())
	_assert(restored.reverse_enabled, "reverse survives a save/load round trip")
	var plain = _instance_script.from_json(_make_instance(CLIP_AUDIO).to_json())
	_assert(not plain.reverse_enabled, "a clip saved before reverse existed loads as forward")


func _test_copy_overrides() -> void:
	var source = _make_instance(CLIP_AUDIO)
	source.reverse_enabled = true
	var copy = _make_instance(CLIP_AUDIO)
	copy.copy_overrides_from(source)
	_assert(copy.reverse_enabled, "copy_overrides_from carries the reverse flag")


func _test_context_menu() -> void:
	var scene: PackedScene = load("res://arranger/timeline/ClipContextMenu.tscn")
	var menu = scene.instantiate()
	root.add_child(menu)
	await process_frame

	var midi_inst = _make_instance(CLIP_MIDI)
	_bind(menu, [midi_inst])
	_assert(not menu.reverse_checkbox.visible, "reverse checkbox is hidden for a MIDI clip")

	var audio_inst = _make_instance(CLIP_AUDIO)
	_bind(menu, [audio_inst])
	_assert(menu.reverse_checkbox.visible, "reverse checkbox shows for an audio clip")
	_assert(not menu.reverse_checkbox.button_pressed, "a forward audio clip shows unchecked")

	audio_inst.reverse_enabled = true
	_bind(menu, [audio_inst])
	_assert(menu.reverse_checkbox.button_pressed, "a reversed instance shows checked")

	var toggled_inst = _make_instance(CLIP_AUDIO)
	_bind(menu, [toggled_inst])
	menu._on_reverse_toggled(true)
	_assert(toggled_inst.reverse_enabled, "toggling the checkbox reverses the instance")
	menu._on_reverse_toggled(false)
	_assert(not toggled_inst.reverse_enabled, "toggling off restores forward playback")

	_bind(menu, [audio_inst, midi_inst])
	_assert(not menu.reverse_checkbox.visible, "reverse hides when the selection mixes clip types")

	menu.free()
