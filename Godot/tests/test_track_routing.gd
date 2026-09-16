# test_track_routing.gd
# Headless tests for the channel-less "New Track" option and the track routing dropdown:
# TrackCreateCommand kind "track", Project.route_track_to_channel / create_and_link_track_channel,
# and TrackRouteChannelCommand do/undo/redo.
#
# Project, Track and the commands reference autoloads (AudioEngineOSC) by bare name, so they are
# loaded with load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_track_routing.gd -- --test
extends TestBase

const TRACK_TYPE_INSTRUMENT := 1

var _project_script: GDScript
var _track_create: GDScript
var _track_route: GDScript
var _track_delete: GDScript
var _track_reorder: GDScript


func suite_name() -> String:
	return "Track routing tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_create = load("res://history/commands/TrackCreateCommand.gd")
	_track_route = load("res://history/commands/TrackRouteChannelCommand.gd")
	_track_delete = load("res://history/commands/TrackDeleteCommand.gd")
	_track_reorder = load("res://history/commands/TrackReorderCommand.gd")
	_test_create_bare_track()
	_test_route_to_new_channel()
	_test_route_to_existing_channel()
	_test_unroute()
	_test_shared_channel_keeps_own_identity()
	_test_delete_bare_track()
	_test_move_track_into_group_nests_channel()
	_test_nest_after_bare_sibling()
	_test_route_inside_group_nests_new_channel()
	_test_mixer_nest_reparents_track()


## A "New Track" leaves the mixer untouched.
func _test_create_bare_track() -> void:
	var project: Object = _project_script.new()
	var channels_before: int = project.channels.size()

	var cmd: Object = _track_create.new(project, "track")
	cmd.do()
	var track: Object = cmd.track

	_assert(track != null, "bare track created")
	_assert(cmd.channel == null, "no channel created alongside it")
	_assert(project.channels.size() == channels_before, "mixer channel count unchanged")
	_assert(track.default_channel_id == -1, "track is unrouted")
	_assert(not track.name_by_channel, "unrouted track owns its name")
	_assert(not track.color_by_channel, "unrouted track owns its color")
	_assert(cmd.name == "Create Track", "command named 'Create Track': %s" % cmd.name)

	cmd.undo()
	_assert(project.get_track_by_id(track.id) == null, "undo removes the track")
	cmd.do()
	_assert(project.get_track_by_id(track.id) == track, "redo restores the same track")


## "New Channel" creates a strip, pairs it with the track, and undo takes it back out.
func _test_route_to_new_channel() -> void:
	var project: Object = _project_script.new()
	var track: Object = project.create_bare_track("Lead")
	var channels_before: int = project.channels.size()

	var cmd: Object = _track_route.new(project, track, null, true)
	cmd.do()
	var channel: Object = cmd.channel

	_assert(channel != null, "channel created")
	_assert(project.channels.size() == channels_before + 1, "one channel added")
	_assert(track.default_channel_id == channel.id, "track routed to the new channel")
	_assert(channel.routed_tracks.has(track), "channel knows about the track")
	_assert(track.name_by_channel and track.color_by_channel, "sole track adopts the strip identity")
	_assert(channel.output_channel_id == 1, "new channel routed to Master")

	cmd.undo()
	_assert(project.get_channel_by_id(channel.id) == null, "undo removes the created channel")
	_assert(track.default_channel_id == -1, "undo leaves the track unrouted")
	_assert(project.channels.size() == channels_before, "channel count back to where it started")

	cmd.do()
	_assert(track.default_channel_id == channel.id, "redo reuses the same channel id")
	_assert(project.get_channel_by_id(channel.id) == channel, "redo re-adds the same channel object")


## Picking an existing strip reroutes the track without touching the mixer.
func _test_route_to_existing_channel() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Bass")
	var track: Object = project.create_bare_track("Lead")
	var channels_before: int = project.channels.size()

	var cmd: Object = _track_route.new(project, track, pair.channel, false)
	cmd.do()
	_assert(track.default_channel_id == pair.channel.id, "track routed to the existing channel")
	_assert(project.channels.size() == channels_before, "no channel created")
	_assert(pair.channel.routed_tracks.has(track), "channel registered the second track")

	cmd.undo()
	_assert(track.default_channel_id == -1, "undo restores the unrouted state")
	_assert(not pair.channel.routed_tracks.has(track), "channel unregistered the track")


## " - None - " detaches a routed track from its strip, leaving the strip in place.
func _test_unroute() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Keys")
	var track: Object = pair.track
	var channel: Object = pair.channel

	var cmd: Object = _track_route.new(project, track, null, false)
	cmd.do()
	_assert(track.default_channel_id == -1, "track unrouted")
	_assert(project.get_channel_by_id(channel.id) == channel, "the strip itself is kept")
	_assert(not channel.routed_tracks.has(track), "strip unregistered the track")

	cmd.undo()
	_assert(track.default_channel_id == channel.id, "undo restores the routing")
	_assert(track.name_by_channel, "undo restores name syncing")


## A second track on an occupied strip keeps its own name, so the two stay distinguishable.
func _test_shared_channel_keeps_own_identity() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Strings")
	var track: Object = project.create_bare_track("Strings Div")
	track.type = TRACK_TYPE_INSTRUMENT
	var own_name: String = track.name

	var cmd: Object = _track_route.new(project, track, pair.channel, false)
	cmd.do()
	_assert(track.default_channel_id == pair.channel.id, "second track routed to the shared strip")
	_assert(not track.name_by_channel, "second track does not adopt the strip name")
	_assert(track.name == own_name, "second track kept its own name: %s" % track.name)
	_assert(pair.track.name == pair.channel.name, "the paired track still mirrors the strip")

	cmd.undo()
	_assert(track.name == own_name, "name survives undo: %s" % track.name)


## Deleting a channel-less track is a plain track delete, and undo brings it back unrouted.
func _test_delete_bare_track() -> void:
	var project: Object = _project_script.new()
	var track: Object = project.create_bare_track("Sketch")
	var channels_before: int = project.channels.size()

	var cmd: Object = _track_delete.new(project, track)
	cmd.do()
	_assert(project.get_track_by_id(track.id) == null, "bare track deleted")
	_assert(project.channels.size() == channels_before, "no channel removed with it")

	cmd.undo()
	var restored: Object = project.get_track_by_id(track.id)
	_assert(restored == track, "undo restores the bare track")
	_assert(restored.default_channel_id == -1, "restored track is still unrouted")


## Arranger drag of an instrument track into a Group nests its strip; one undo step restores both.
func _test_move_track_into_group_nests_channel() -> void:
	var project: Object = _project_script.new()
	var group_cmd: Object = _track_create.new(project, "group", "Group")
	group_cmd.do()
	var inst_cmd: Object = _track_create.new(project, "instrument", "Inst")
	inst_cmd.do()
	var group: Object = group_cmd.track
	var track: Object = inst_cmd.track
	var ch: Object = inst_cmd.channel

	var before: Dictionary = _track_reorder.capture_layout(project)
	_assert(project.place_track(track, group.id, null), "track placed into group")
	var after: Dictionary = _track_reorder.capture_layout(project)
	_assert(ch.parent_channel_id == group_cmd.channel.id, "strip nested under the group channel")
	_assert(group_cmd.channel.child_channel_ids == [ch.id], "group channel lists the strip")
	_assert(ch.output_channel_id == group_cmd.channel.id, "strip routed to the group")

	var cmd: Object = _track_reorder.new(project, before, after)
	cmd.undo()
	_assert(track.parent_track_id == -1, "undo moves the track back to the root")
	_assert(ch.parent_channel_id == -1, "undo un-nests the strip")
	_assert(group_cmd.channel.child_channel_ids.is_empty(), "undo empties the group fold-out")
	_assert(ch.output_channel_id == 1, "undo routes the strip back to Master")
	cmd.do()
	_assert(track.parent_track_id == group.id, "redo re-parents the track")
	_assert(ch.parent_channel_id == group_cmd.channel.id, "redo re-nests the strip")


## A channel-less sibling above the moved track must not block nesting.
func _test_nest_after_bare_sibling() -> void:
	var project: Object = _project_script.new()
	var group: Dictionary = project.create_group_track("Group")
	var first: Dictionary = project.create_instrument_track("First")
	var bare: Object = project.create_bare_track("Sketch")
	var inst: Dictionary = project.create_instrument_track("Inst")

	project.place_track(first.track, group.track.id, null)
	project.place_track(bare, group.track.id, first.track)
	project.place_track(inst.track, group.track.id, bare)
	_assert(inst.track.parent_track_id == group.track.id, "track sits after the bare sibling")
	_assert(inst.channel.parent_channel_id == group.channel.id, "strip nested despite the bare sibling")
	_assert(
		group.channel.child_channel_ids == [first.channel.id, inst.channel.id],
		"mixer order follows track order: %s" % str(group.channel.child_channel_ids)
	)

	# Reordering in place keeps the mixer order aligned too.
	project.place_track(inst.track, group.track.id, null)
	_assert(
		group.channel.child_channel_ids == [inst.channel.id, first.channel.id],
		"reorder inside the group updates mixer order: %s" % str(group.channel.child_channel_ids)
	)


## Giving a bare track inside a Group a new channel nests that strip in the group.
func _test_route_inside_group_nests_new_channel() -> void:
	var project: Object = _project_script.new()
	var group: Dictionary = project.create_group_track("Group")
	var bare: Object = project.create_bare_track("Lead")
	project.place_track(bare, group.track.id, null)

	var cmd: Object = _track_route.new(project, bare, null, true)
	cmd.do()
	_assert(cmd.channel.parent_channel_id == group.channel.id, "new strip nested under the group")
	_assert(group.channel.child_channel_ids == [cmd.channel.id], "group lists the new strip")
	_assert(bare.parent_track_id == group.track.id, "track stays inside the group")

	cmd.undo()
	_assert(group.channel.child_channel_ids.is_empty(), "undo removes the strip from the group")


## Nesting in the mixer re-parents the paired track; un-nesting takes it back out.
func _test_mixer_nest_reparents_track() -> void:
	var project: Object = _project_script.new()
	var group: Dictionary = project.create_group_track("Group")
	var inst: Dictionary = project.create_instrument_track("Inst")

	var before: Dictionary = _track_reorder.capture_layout(project)
	_assert(project.nest_channel(inst.channel, group.channel, null), "strip nested in the mixer")
	_assert(inst.track.parent_track_id == group.track.id, "paired track moved into the group track")
	var after: Dictionary = _track_reorder.capture_layout(project)

	_assert(project.unnest_channel(inst.channel), "strip un-nested in the mixer")
	_assert(inst.track.parent_track_id == -1, "paired track moved back to the root")

	var cmd: Object = _track_reorder.new(project, before, after)
	cmd.do()
	_assert(inst.track.parent_track_id == group.track.id, "layout redo restores the track side")
	_assert(inst.channel.parent_channel_id == group.channel.id, "layout redo restores the mixer side")
