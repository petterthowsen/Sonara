# test_mixer_foldout_icon.gd
# A group strip's foldout icon matches its fold state as soon as it is created, for folded and
# unfolded groups, and the arranger TrackItem foldout does too.
# Run: godot --headless --path Godot -s tests/test_mixer_foldout_icon.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Mixer foldout icon tests"


func run_tests() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var mixer: Object = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	root.size = Vector2i(1400, 900)
	mixer.size = Vector2(1400, 900)
	root.add_child(mixer)
	mixer._on_project_opened(project)

	var open_g: Dictionary = project.create_group_track("Open")
	var closed_g: Dictionary = project.create_group_track("Closed")
	for g: Dictionary in [open_g, closed_g]:
		var t: Dictionary = project.create_instrument_track("Child")
		project.place_track(t.track, g.track.id)
	open_g.channel.is_children_expanded = true
	closed_g.channel.is_children_expanded = false
	await _frames(8)

	# Fresh strips bound to a channel with a preset fold state.
	for case: Array in [[open_g, true], [closed_g, false]]:
		var strip: Control = (load("res://mixer/MixerChannel.tscn") as PackedScene).instantiate()
		root.add_child(strip)
		strip.bind_to_channel(case[0].channel, project)
		_check_icon(strip.foldout_toggle, case[1], "fresh strip, expanded=%s" % case[1])
		strip.free()

	# The strips a freshly opened mixer builds for the already-folded/unfolded groups.
	mixer.free()
	mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	mixer.size = Vector2(1400, 900)
	root.add_child(mixer)
	mixer._on_project_opened(project)
	await _frames(8)
	for case: Array in [[open_g, true], [closed_g, false]]:
		var strip: Control = mixer.find_mixer_channel_ui_for_channel(case[0].channel)
		_check_icon(strip.foldout_toggle, case[1], "mixer strip, expanded=%s" % case[1])

	# Arranger track item uses the same pattern.
	for case: Array in [[open_g, true], [closed_g, false]]:
		case[0].track.is_folder_expanded = case[1]
		var item: Control = (load("res://arranger/tracklist/TrackItem.tscn") as PackedScene).instantiate()
		root.add_child(item)
		item.bind_to_track(case[0].track, 0, project)
		_check_icon(item.foldout_toggle, case[1], "track item, expanded=%s" % case[1])
		item.free()

	mixer.free()


func _check_icon(btn: Button, expanded: bool, when: String) -> void:
	_assert(btn.visible, "%s: foldout visible" % when)
	_assert(btn.button_pressed == expanded, "%s: pressed state matches" % when)
	var want: Texture = btn.icon_pressed if expanded else btn.icon_default
	_assert(btn.icon == want, "%s: icon matches fold state" % when)


func _frames(n: int) -> void:
	for i in n:
		await root.get_tree().process_frame
