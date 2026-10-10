# test_track_item_foldout.gd
# The TrackItem fold button only appears on folders/groups that actually have child tracks: an
# empty group or folder shows none, and a track whose mixer channel nests child channels (like a
# drum machine's pad returns) shows none either. Non-container tracks are unchanged (no button).
# Run: godot --headless --path Godot -s tests/test_track_item_foldout.gd -- --test
extends TestBase

const TRACK_ITEM_SCENE := "res://arranger/tracklist/TrackItem.tscn"


func suite_name() -> String:
	return "TrackItem foldout visibility tests"


func _item_for(track: Object, project: Object) -> Control:
	var item: Control = (load(TRACK_ITEM_SCENE) as PackedScene).instantiate()
	root.add_child(item)
	item.bind_to_track(track, 0, project)
	return item


func run_tests() -> void:
	var project: Object = load("res://data/Project.gd").new()

	# Empty group: no child tracks, no fold button.
	var group: Object = project.create_group_track("Group").track
	var group_item: Control = _item_for(group, project)
	_assert(group_item.foldout_toggle != null, "the scene has a foldout toggle")
	_assert(not group_item.foldout_toggle.visible, "an empty group shows no fold button")

	# A child track under the group makes the button appear.
	var child: Object = project.create_instrument_track("Child").track
	_assert(project.add_track_to_folder(child.id, group.id), "the child nests into the group")
	group_item._update_foldout_toggle()
	_assert(group_item.foldout_toggle.visible, "a group with child tracks shows the fold button")

	# Removing the last child hides it again.
	project.remove_track(child.id)
	group_item._update_foldout_toggle()
	_assert(not group_item.foldout_toggle.visible, "a group back to zero children hides the button")

	# A track whose mixer channel nests child channels (drum machine pad returns) has no child
	# tracks, so no fold button.
	var drum: Object = project.create_instrument_track("Drums").track
	drum.get_linked_channel().child_channel_ids.append(999)
	var drum_item: Control = _item_for(drum, project)
	_assert(drum.can_contain_tracks(), "the channel children still allow nesting into the track")
	_assert(not drum_item.foldout_toggle.visible, "a channel with nested child channels but no child tracks shows no fold button")

	# An empty folder behaves like an empty group.
	var folder: Object = project.create_folder_track("Folder").track
	var folder_item: Control = _item_for(folder, project)
	_assert(not folder_item.foldout_toggle.visible, "an empty folder shows no fold button")

	# A plain instrument track: unchanged, no button.
	var plain: Object = project.create_instrument_track("Lead").track
	var plain_item: Control = _item_for(plain, project)
	_assert(not plain_item.foldout_toggle.visible, "a plain track shows no fold button")

	for item: Control in [group_item, drum_item, folder_item, plain_item]:
		item.queue_free()
	await process_frame
