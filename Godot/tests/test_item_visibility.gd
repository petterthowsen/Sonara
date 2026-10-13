# test_item_visibility.gd
# Headless tests for issue 70: hidden/enabled on tracks and channels. Linked tracks follow their
# channel, folders cascade to children, the arranger row order and the mixer filter honour the
# Show Hidden / Show Disabled toggles, and both states survive save/load.
#
# Run: godot --headless --path Godot -s tests/test_item_visibility.gd -- --test
extends TestBase

var _project_script: GDScript
var _row_order: GDScript


func suite_name() -> String:
	return "Item visibility tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_row_order = load("res://arranger/AutomationRowOrder.gd")
	_test_linked_sync()
	_test_folder_cascade()
	_test_row_order_filter()
	_test_channel_filter_and_effective_enabled()
	_test_persistence()


func _names(rows: Array) -> Array:
	return rows.map(func(r): return r["track"].name)


## Folder with children A and B, then a root track After.
func _make_project() -> Dictionary:
	var project: Object = _project_script.new()
	var folder: Object = project.create_folder_track("Folder").track
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var after: Dictionary = project.create_instrument_track("After")
	project.place_track(a.track, folder.id, null)
	project.place_track(b.track, folder.id, a.track)
	project.place_track(after.track, -1, folder)
	return {"project": project, "folder": folder, "a": a, "b": b, "after": after}


func _test_linked_sync() -> void:
	var p := _make_project()
	var a: Dictionary = p.a
	a.track.set_hidden(true)
	_assert(a.channel.hidden, "hiding a linked track hides its channel")
	a.channel.set_hidden(false)
	_assert(not a.track.hidden, "showing the channel shows the linked track")
	a.channel.set_enabled(false)
	_assert(not a.track.enabled, "disabling the channel disables the linked track")
	a.track.set_enabled(true)
	_assert(a.channel.enabled, "enabling the track enables the channel")


func _test_folder_cascade() -> void:
	var p := _make_project()
	p.folder.set_hidden(true)
	var project: Object = p.project
	_assert(ItemVisibility.track_hidden(project, p.a.track), "children of a hidden folder are hidden")
	_assert(not p.a.track.hidden, "the child's own flag is untouched")
	_assert(not ItemVisibility.track_hidden(project, p.after.track), "a sibling after the folder is not")
	p.folder.set_hidden(false)
	p.folder.set_enabled(false)
	_assert(ItemVisibility.track_disabled(project, p.b.track), "children of a disabled folder are disabled")


func _test_row_order_filter() -> void:
	var p := _make_project()
	var project: Object = p.project
	_assert(_names(_row_order.build(project)) == ["Folder", "A", "B", "After"], "all listed by default")

	p.a.track.set_hidden(true)
	_assert(_names(_row_order.build(project)) == ["Folder", "B", "After"], "hidden track left out")
	project.set_arranger_view("show_hidden", true)
	_assert(_names(_row_order.build(project)) == ["Folder", "A", "B", "After"], "Show Hidden brings it back")
	project.set_arranger_view("show_hidden", false)

	p.folder.set_hidden(true)
	_assert(_names(_row_order.build(project)) == ["After"], "hiding the folder hides its children")
	p.folder.set_hidden(false)

	p.b.track.set_enabled(false)
	_assert(not _names(_row_order.build(project)).has("B"), "disabled track left out")
	project.set_arranger_view("show_disabled", true)
	_assert(_names(_row_order.build(project)).has("B"), "Show Disabled brings it back")


func _test_channel_filter_and_effective_enabled() -> void:
	var p := _make_project()
	var project: Object = p.project
	var master: Object = project.get_channel_by_id(1)
	master.hidden = true
	_assert(ItemVisibility.channel_listed(project, master), "master is always listed")

	p.a.channel.set_hidden(true)
	_assert(not ItemVisibility.channel_listed(project, p.a.channel), "hidden strip not listed")
	project.set_mixer_view("show_hidden", true)
	_assert(ItemVisibility.channel_listed(project, p.a.channel), "Show Hidden lists it")

	# A strip follows its tracks when they are all disabled through the folder.
	p.folder.set_enabled(false)
	_assert(ItemVisibility.channel_disabled(project, p.b.channel), "child strip disabled with the folder")
	_assert(p.b.channel.enabled, "the strip's own flag is untouched")
	p.folder.set_enabled(true)
	_assert(not ItemVisibility.channel_disabled(project, p.b.channel), "re-enabling restores it")

	# A nested group child inherits the parent's state.
	var group: Dictionary = project.create_group_track("G")
	var child: Dictionary = project.create_instrument_track("C")
	project.place_track(child.track, group.track.id, null)
	group.channel.set_enabled(false)
	_assert(ItemVisibility.channel_disabled(project, child.channel), "group child strip follows the group")


func _test_persistence() -> void:
	var p := _make_project()
	p.a.track.set_hidden(true)
	p.b.channel.set_enabled(false)
	p.project.set_arranger_view("show_hidden", true)
	p.project.set_mixer_view("show_disabled", true)
	var loaded: Object = _project_script.from_json(p.project.to_json())
	var a_ch: Object = loaded.get_channel_by_id(p.a.channel.id)
	var b_ch: Object = loaded.get_channel_by_id(p.b.channel.id)
	_assert(a_ch.hidden and a_ch.enabled, "hidden channel round-trips")
	_assert(not b_ch.enabled and not b_ch.hidden, "disabled channel round-trips")
	_assert(loaded.get_track_by_id(p.a.track.id).hidden, "linked track reads hidden after load")
	_assert(loaded.get_arranger_view("show_hidden") and loaded.get_mixer_view("show_disabled"),
		"view toggles round-trip")
	_assert(not loaded.get_arranger_view("show_disabled") and not loaded.get_mixer_view("show_hidden"),
		"other toggles stay off")
