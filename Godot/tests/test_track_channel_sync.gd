# test_track_channel_sync.gd
# Headless tests for track <-> channel state sync: selection mapping (SelectionSync) and the silent
# selection setters on Mixer and TrackList, and mute/solo with the channel as the single source of
# truth (Track reads it, TrackItem buttons follow channel signals).
#
# Project, the views and SelectionSync reference autoloads, so they are loaded with load().
# Run: godot --headless --path Godot -s tests/test_track_channel_sync.gd -- --test
extends TestBase

var _project_script: GDScript
var _sync: GDScript


func suite_name() -> String:
	return "Track/channel sync tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_sync = load("res://editor/SelectionSync.gd")
	_test_selection_mapping()
	await _test_silent_setters()
	_test_mute_solo_source_of_truth()
	await _test_track_item_follows_channel()


## Typed array of `script_path` objects, built without naming the class (it needs autoloads).
func _typed(items: Array, script_path: String) -> Array:
	var script: Script = load(script_path)
	return Array(items, TYPE_OBJECT, script.get_instance_base_type(), script)


func _test_selection_mapping() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var bare: Object = project.create_bare_track("Bare")
	var shared: Object = project.create_bare_track("Shared")
	project.route_track_to_channel(shared, a.channel)
	var bus: Object = project.create_bus_channel("Bus")

	var to_mixer: Dictionary = _sync.channels_for_tracks(project, _typed([a.track, bare, b.track, shared], "res://data/Track.gd"), b.track)
	_assert(to_mixer.channels == [a.channel, b.channel], "tracks map to their strips once: %s" % str(to_mixer.channels))
	_assert(to_mixer.focused == b.channel, "active track focuses its strip")

	var to_tracks: Dictionary = _sync.tracks_for_channels(project, _typed([b.channel, a.channel], "res://data/Channel.gd"), a.channel)
	_assert(to_tracks.tracks == [b.track, a.track, shared], "strips map to every routed track: %s" % str(to_tracks.tracks.map(func(t): return t.name)))
	_assert(to_tracks.active == a.track, "active strip picks its paired track")

	var bus_only: Dictionary = _sync.tracks_for_channels(project, _typed([bus], "res://data/Channel.gd"), bus)
	_assert(bus_only.tracks.is_empty() and bus_only.active == null, "a bus selects no tracks")


func _test_silent_setters() -> void:
	var project: Object = _project_script.new()
	var group: Dictionary = project.create_group_track("G")
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	project.place_track(a.track, group.track.id, null)
	group.track.set("_is_folder_expanded", false)

	var mixer: Object = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	root.add_child(mixer)
	mixer._on_project_opened(project)
	var track_list: Object = (load("res://arranger/tracklist/TrackList.tscn") as PackedScene).instantiate()
	root.add_child(track_list)
	track_list._on_project_activated(project)
	await process_frame

	var mixer_emits := [0]
	var list_emits := [0]
	mixer.selection_changed.connect(func(_s): mixer_emits[0] += 1)
	track_list.selection_changed.connect(func(_t, _a): list_emits[0] += 1)

	mixer.set_selection_silent(_typed([a.channel, b.channel], "res://data/Channel.gd"), b.channel)
	_assert(mixer.selection == [a.channel, b.channel], "mixer selection replaced")
	_assert(mixer.focused_channel == b.channel, "mixer focus set")
	_assert(mixer.find_mixer_channel_ui_for_channel(b.channel).is_selected, "strip shows selected")
	_assert(mixer_emits[0] == 0, "mixer setter does not emit")

	track_list.set_selection_silent(_typed([a.track], "res://data/Track.gd"), a.track)
	_assert(track_list.selected_tracks == [a.track] and track_list.active_track == a.track, "arranger selection replaced")
	_assert(list_emits[0] == 0, "track list setter does not emit")
	_assert(group.track.is_folder_expanded, "selecting a folded-away track unfolds its group")

	load("res://arranger/TrackFoldAnimation.gd").finish_all()
	mixer.queue_free()
	track_list.queue_free()


func _test_mute_solo_source_of_truth() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")

	a.track.set_mute(true)
	_assert(a.channel.mute, "track mute writes the channel")
	a.channel.set_solo(true)
	_assert(a.track.solo, "track reads solo from the channel")
	a.channel.set_mute(false)
	_assert(not a.track.muted, "channel unmute is seen by the track")

	# Rerouting does not push the track's old state into the new strip.
	a.channel.set_mute(true)
	project.route_track_to_channel(a.track, b.channel)
	_assert(not b.channel.mute, "new strip keeps its own mute")
	_assert(not a.track.muted, "rerouted track now reads the new strip")

	# Unrouting keeps the last strip state on the track.
	b.channel.set_solo(true)
	project.route_track_to_channel(a.track, null)
	_assert(a.track.solo, "unrouted track keeps the last solo")
	a.track.set_solo(false)
	_assert(not a.track.solo and b.channel.solo, "unrouted track solo is its own")


func _test_track_item_follows_channel() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var item: Object = (load("res://arranger/tracklist/TrackItem.tscn") as PackedScene).instantiate()
	root.add_child(item)
	await process_frame
	item.bind_to_track(a.track, 0, project)

	a.channel.set_mute(true)
	_assert(item.mute_toggle.button_pressed, "mute button follows the channel")
	a.channel.set_solo(true)
	_assert(item.solo_toggle.button_pressed, "solo button follows the channel")
	item.mute_toggle.button_pressed = false
	_assert(not a.channel.mute, "mute button writes the channel")
	item.queue_free()
