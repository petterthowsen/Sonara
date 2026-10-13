# test_mixer_group_width.gd
# A group strip's fold-out hugs its nested strips, in narrow and normal modes and after toggling.
# Run: godot --headless --path Godot -s tests/test_mixer_group_width.gd -- --test
extends TestBase

var _mixer: Object
var _group: Object


func suite_name() -> String:
	return "Mixer group width tests"


func run_tests() -> void:
	var project: Object = load("res://data/Project.gd").new()
	_mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	root.size = Vector2i(1400, 900)
	_mixer.size = Vector2(1400, 900)
	root.add_child(_mixer)
	_mixer._on_project_opened(project)
	var group: Dictionary = project.create_group_track("Group")
	for n in ["A"]:
		var t: Dictionary = project.create_instrument_track(n)
		project.place_track(t.track, group.track.id)
	group.channel.is_children_expanded = true
	await _frames(8)
	_group = _mixer.find_mixer_channel_ui_for_channel(group.channel)
	# MixerChannel.SizeMode NARROW=0, MEDIUM=1, WIDE=2 (named enums would compile before autoloads).
	for mode: int in [0, 1, 2, 0, 1, 0]:
		root.get_tree().call_group("mixer_channel", "set_size_mode", mode)
		await _frames(6)
		_check("mode %d" % mode)
	_mixer.free()


func _check(when: String) -> void:
	var children = _group.children_slide
	var box: Control = children.channels_box
	var sum := 0.0
	for c in box.get_children():
		sum += c.get_combined_minimum_size().x
	var box_w := box.get_combined_minimum_size().x
	_assert(is_equal_approx(box_w, sum), "%s: child box min width %s equals children sum %s" % [when, box_w, sum])
	_assert(is_equal_approx(box.size.x, sum), "%s: child box width %s equals children sum %s" % [when, box.size.x, sum])
	_assert(is_equal_approx(children.size.x, sum), "%s: fold-out width %s equals children sum %s" % [when, children.size.x, sum])
	_assert(is_equal_approx(children.get_combined_minimum_size().x, sum),
			"%s: fold-out min width %s equals children sum %s" % [when, children.get_combined_minimum_size().x, sum])


func _frames(n: int) -> void:
	for i in n:
		await process_frame
