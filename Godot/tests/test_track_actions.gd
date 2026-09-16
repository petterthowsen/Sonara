# test_track_actions.gd
# Headless tests for the TrackItem context menu actions: Delete Track (keeps the channel) vs
# Delete Track & Channel, Duplicate Track (shares the channel) vs Duplicate Track & Channel (copies
# settings, sends, routing and group nesting), multi-track delete/duplicate as one undo step, and
# the menu's single/multi layout.
#
# Project, the commands and the menu reference autoloads, so they are loaded with load().
# Run: godot --headless --path Godot -s tests/test_track_actions.gd -- --test
extends TestBase

var _project_script: GDScript
var _menu_script: GDScript
var _duplicate: GDScript


func suite_name() -> String:
	return "Track action tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_menu_script = load("res://arranger/tracklist/TrackItemContextMenu.gd")
	_duplicate = load("res://history/commands/TrackDuplicateCommand.gd")
	_test_delete_keeps_channel()
	_test_delete_with_channel()
	_test_multi_delete()
	_test_duplicate_shares_channel()
	_test_duplicate_with_channel()
	_test_multi_duplicate()
	await _test_menu_layout()


func _typed_tracks(items: Array) -> Array:
	var script: Script = load("res://data/Track.gd")
	return Array(items, TYPE_OBJECT, script.get_instance_base_type(), script)


func _add_clip(project: Object, track: Object, start: int) -> Object:
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	return track.create_clip_instance(clip, start, 960)


func _test_delete_keeps_channel() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Keys")
	var channels_before: int = project.channels.size()

	var cmd: Object = _menu_script.delete_command(project, _typed_tracks([pair.track]), false)
	cmd.do()
	_assert(cmd.name == "Delete Track", "named Delete Track: %s" % cmd.name)
	_assert(project.get_track_by_id(pair.track.id) == null, "track removed")
	_assert(project.get_channel_by_id(pair.channel.id) == pair.channel, "channel kept")
	_assert(project.channels.size() == channels_before, "no channel removed")
	_assert(not pair.channel.routed_tracks.has(pair.track), "kept channel forgot the deleted track")

	cmd.undo()
	_assert(project.get_track_by_id(pair.track.id) == pair.track, "undo restores the track")
	_assert(pair.channel.routed_tracks.has(pair.track), "undo re-registers the track on its channel")
	_assert(pair.track.default_channel_id == pair.channel.id, "undo keeps the routing")
	cmd.do()
	_assert(project.get_track_by_id(pair.track.id) == null and project.get_channel_by_id(pair.channel.id) != null, "redo deletes the track only")


func _test_delete_with_channel() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Bass")
	var cmd: Object = _menu_script.delete_command(project, _typed_tracks([pair.track]), true)
	cmd.do()
	_assert(cmd.name == "Delete Track and Channel", "named Delete Track and Channel: %s" % cmd.name)
	_assert(project.get_channel_by_id(pair.channel.id) == null, "channel removed with the track")
	cmd.undo()
	_assert(project.get_channel_by_id(pair.channel.id) == pair.channel, "undo restores the channel")
	_assert(project.get_track_by_id(pair.track.id) == pair.track, "undo restores the track")


func _test_multi_delete() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var c: Dictionary = project.create_instrument_track("C")
	var cmd: Object = _menu_script.delete_command(project, _typed_tracks([a.track, c.track]), true)
	cmd.do()
	_assert(cmd.name == "Delete Tracks and Channels", "plural name: %s" % cmd.name)
	_assert(project.tracks == [b.track], "only B is left")
	_assert(project.get_channel_by_id(a.channel.id) == null and project.get_channel_by_id(c.channel.id) == null, "both channels removed")
	cmd.undo()
	_assert(project.tracks.size() == 3, "one undo restores both tracks")
	_assert(a.track.order == 0 and b.track.order == 1 and c.track.order == 2, "undo restores order")


func _test_duplicate_shares_channel() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Lead")
	var first: Dictionary = project.create_instrument_track("After")
	var instance: Object = _add_clip(project, pair.track, 0)

	var cmd: Object = _menu_script.duplicate_command(project, _typed_tracks([pair.track]), false)
	cmd.do()
	var copy: Object = cmd.track
	_assert(copy != null and copy != pair.track, "copy created")
	_assert(copy.name != pair.track.name, "copy has its own name: %s" % copy.name)
	_assert(copy.default_channel_id == pair.channel.id, "copy plays through the same channel")
	_assert(pair.channel.name == "Lead" and pair.track.name == "Lead", "original pair keeps its name")
	_assert(copy.clip_instances.size() == 1, "clips copied")
	_assert(copy.clip_instances[0].id != instance.id, "clip instance gets a fresh id")
	_assert(copy.clip_instances[0].clip == instance.clip, "copy references the same pooled clip")
	_assert(copy.clip_instances[0].track == copy, "copied instance belongs to the copy")
	_assert(copy.order == pair.track.order + 1 and first.track.order == copy.order + 1, "copy sits right after the original")

	cmd.undo()
	_assert(project.get_track_by_id(copy.id) == null, "undo removes the copy")
	_assert(not pair.channel.routed_tracks.has(copy), "undo unregisters the copy from the shared channel")
	_assert(first.track.order == 1, "undo restores the order")
	cmd.do()
	_assert(project.get_track_by_id(copy.id) == copy and copy.order == 1, "redo re-adds the same copy in place")
	_assert(pair.channel.routed_tracks.has(copy), "redo re-registers the copy")


func _test_duplicate_with_channel() -> void:
	var project: Object = _project_script.new()
	var group: Dictionary = project.create_group_track("Group")
	var pair: Dictionary = project.create_instrument_track("Pad")
	var bus: Object = project.create_bus_channel("Verb")
	project.place_track(pair.track, group.track.id, null)
	pair.channel.set_volume(-3.0)
	pair.channel.add_send(bus.id, -9.0)

	var cmd: Object = _duplicate.new(project, pair.track, true)
	cmd.do()
	var copy: Object = cmd.track
	var ch: Object = cmd.channel
	_assert(ch != null and ch != pair.channel, "channel copied")
	_assert(copy.default_channel_id == ch.id, "copy routed to its own channel")
	_assert(ch.name == copy.name and copy.name_by_channel, "copy pairs with its channel identity")
	_assert(is_equal_approx(ch.volume, -3.0), "volume copied")
	_assert(ch.send_channels.size() == 1 and ch.send_channels[0].target_channel_id == bus.id, "sends copied")
	_assert(copy.parent_track_id == group.track.id, "copy sits in the group")
	_assert(ch.parent_channel_id == group.channel.id, "copied channel nested in the group")
	_assert(group.channel.child_channel_ids == [pair.channel.id, ch.id], "copied strip after the original: %s" % str(group.channel.child_channel_ids))
	_assert(ch.output_channel_id == group.channel.id, "copied channel routed to the group")

	cmd.undo()
	_assert(project.get_channel_by_id(ch.id) == null, "undo removes the copied channel")
	_assert(group.channel.child_channel_ids == [pair.channel.id], "undo leaves the group with the original")
	cmd.do()
	_assert(project.get_channel_by_id(ch.id) == ch, "redo re-adds the same channel")
	_assert(group.channel.child_channel_ids == [pair.channel.id, ch.id], "redo re-nests it: %s" % str(group.channel.child_channel_ids))
	_assert(copy.default_channel_id == ch.id and ch.routed_tracks.has(copy), "redo keeps the pairing")


func _test_multi_duplicate() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var folder: Object = project.create_folder_track("Folder").track
	var channels_before: int = project.channels.size()

	var cmd: Object = _menu_script.duplicate_command(project, _typed_tracks([a.track, b.track, folder]), true)
	cmd.do()
	_assert(cmd.name == "Duplicate Tracks and Channels", "macro named: %s" % cmd.name)
	_assert(project.tracks.size() == 5, "two copies (folder skipped): %d" % project.tracks.size())
	_assert(project.channels.size() == channels_before + 2, "two channels copied")
	cmd.undo()
	_assert(project.tracks.size() == 3 and project.channels.size() == channels_before, "one undo removes both copies")
	cmd.do()
	_assert(project.tracks.size() == 5 and project.channels.size() == channels_before + 2, "one redo restores both copies")


func _test_menu_layout() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var bare: Object = project.create_bare_track("Bare")
	var track_list: Object = (load("res://arranger/tracklist/TrackList.tscn") as PackedScene).instantiate()
	root.add_child(track_list)
	await process_frame
	var menu: Object = track_list.track_item_context_menu

	menu.bind_tracks(_typed_tracks([a.track]), a.track, project)
	_assert(not menu.is_multi(), "single track layout")
	_assert(menu.name_label.get_value() == "A" and not menu.name_label.disabled, "title is the editable name")
	_assert(menu.delete_button.text == "Delete Track" and menu.delete_with_channel_button.visible, "both delete variants")
	_assert(menu.duplicate_button.visible and menu.duplicate_with_channel_button.visible, "both duplicate variants")

	menu.bind_tracks(_typed_tracks([bare]), bare, project)
	_assert(not menu.delete_with_channel_button.visible and not menu.duplicate_with_channel_button.visible, "channel variants hidden without a channel")

	menu.bind_tracks(_typed_tracks([a.track, bare]), bare, project)
	_assert(menu.is_multi(), "multi-track layout")
	_assert(menu.name_label.get_value() == "2 tracks" and menu.name_label.disabled, "title is read-only N tracks")
	_assert(menu.delete_button.text == "Delete Tracks" and menu.duplicate_button.text == "Duplicate Tracks", "plural labels")
	_assert(not menu.channel_route_option.visible, "routing dropdown hidden for several tracks")
	menu._on_name_changed("Renamed")
	_assert(a.track.name == "A" and bare.name == "Bare", "renaming does nothing with several tracks")
	track_list.queue_free()
