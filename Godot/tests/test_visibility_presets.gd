# test_visibility_presets.gd
# Spec 047: the visibility preset model (VisibilityPresets), its project serialization,
# Project.batch_visibility, the undo commands and the TrackVisibility service.
# Project, HistoryUtil, the commands and TrackVisibility reference autoloads, so they are load()ed.
#
# Run: godot --headless --path Godot -s tests/test_visibility_presets.gd -- --test
extends TestBase

## Loaded in run_tests(): compiling these before the first frame fails on the autoload references.
var _project_script: GDScript
var _tv: GDScript
var _history: GDScript
var _state_cmd_script: GDScript
var _presets_cmd_script: GDScript

var _recorded: Array = []


func suite_name() -> String:
	return "Visibility presets"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_tv = load("res://editor/track_list/TrackVisibility.gd")
	_history = load("res://history/HistoryUtil.gd")
	_state_cmd_script = load("res://history/commands/VisibilityStateCommand.gd")
	_presets_cmd_script = load("res://history/commands/VisibilityPresetsStateCommand.gd")
	_test_model_basics()
	_test_model_move_remove_active()
	_test_model_json()
	_test_snapshot_restore()
	_test_project_round_trip()
	_test_batch_visibility()
	_test_state_command()
	_test_presets_state_command()
	_test_capture_and_apply()
	_test_shared_channel()
	_test_show_all_undo()
	_test_apply_is_one_command()
	_test_show_only()
	_test_show_branch_and_mixed()
	_test_add_preset_naming()
	_test_move_undo()
	_test_rename_delete()
	_test_dirty_and_label()
	_test_save_and_reset()
	_test_step_preset()
	_test_track_delete_pruning()
	_test_hotkeys()


## A, F{B, C}, D: A, B, C and D are instrument tracks with their own channels; F is a folder with
## no channel (so it is its own visibility target). Visual order: A, F, B, C, D.
func _fixture() -> Dictionary:
	var project = _project_script.new()
	var a: Object = project.create_instrument_track("A").track
	var f: Object = project.create_folder_track("F").track
	var b: Object = project.create_instrument_track("B").track
	var c: Object = project.create_instrument_track("C").track
	var d: Object = project.create_instrument_track("D").track
	project.place_track(f, -1, a)
	project.place_track(b, f.id, null)
	project.place_track(c, f.id, b)
	project.place_track(d, -1, f)
	return {"project": project, "a": a, "f": f, "b": b, "c": c, "d": d}


func _start_recording() -> void:
	_recorded.clear()
	_history.test_recorder = func(cmd) -> void: _recorded.append(cmd)


func _stop_recording() -> void:
	_history.test_recorder = Callable()


## Undo the most recent recorded command.
func _undo_last() -> void:
	_recorded.pop_back().undo()


func _hidden_names(f: Dictionary) -> Array:
	var names: Array = []
	for key in ["a", "f", "b", "c", "d"]:
		if f[key].hidden:
			names.append(key)
	return names


# ---------------------------------------------------------------- T-001

func _test_model_basics() -> void:
	var presets := VisibilityPresets.new()
	var changes := [0]
	presets.changed.connect(func() -> void: changes[0] += 1)
	var i := presets.add("Orchestra", [7, 4, 7, 12])
	_assert(i == 0 and presets.count() == 1, "add returns the index")
	_assert(presets.display_name(0) == "1: Orchestra", "display_name is 1-based")
	_assert(presets.get_preset(0)["hidden_track_ids"] == [4, 7, 12], "ids are sorted and de-duplicated")
	_assert(presets.active_index == -1, "add does not activate")
	presets.add("Drums", [])
	presets.set_active(1)
	_assert(presets.active_index == 1, "set_active")
	presets.set_active(5)
	_assert(presets.active_index == -1, "out of range active becomes -1")
	presets.rename(0, "Strings")
	_assert(presets.display_name(0) == "1: Strings", "rename")
	presets.set_hidden_ids(0, [3])
	_assert(presets.get_preset(0)["hidden_track_ids"] == [3], "set_hidden_ids")
	_assert(changes[0] == 6, "changed is emitted on every mutation (%d)" % changes[0])
	_assert(presets.get_preset(9).is_empty() and presets.display_name(9) == "", "out of range lookups are empty")


func _test_model_move_remove_active() -> void:
	var presets := VisibilityPresets.new()
	presets.add("A", [])
	presets.add("B", [])
	presets.add("C", [])
	presets.set_active(1)
	presets.move(1, 0)
	_assert(presets.display_name(0) == "1: B" and presets.active_index == 0, "active follows the moved preset")
	presets.move(2, 0)  # C jumps over the active one
	_assert(presets.display_name(0) == "1: C" and presets.active_index == 1, "active shifts down when another preset moves above it")
	presets.move(0, 2)
	_assert(presets.display_name(2) == "3: C" and presets.active_index == 0, "active shifts up when another preset moves below it")
	presets.remove(2)
	_assert(presets.count() == 2 and presets.active_index == 0, "removing after the active one keeps it")
	presets.remove(0)
	_assert(presets.active_index == -1, "removing the active one clears it")
	presets.add("D", [])
	presets.add("E", [])
	presets.set_active(1)
	presets.remove(0)
	_assert(presets.active_index == 0, "removing before the active one shifts it")


func _test_model_json() -> void:
	var empty := VisibilityPresets.from_json({})
	_assert(empty.count() == 0 and empty.active_index == -1, "from_json({}) is empty with no active preset")
	_assert(VisibilityPresets.from_json(null).count() == 0, "from_json tolerates a non-dictionary")
	var presets := VisibilityPresets.from_json({"active": 5, "presets": [
		{"name": "X", "hidden_track_ids": [1, 2]}, "junk", {"name": "Y"}]})
	_assert(presets.count() == 2 and presets.active_index == -1, "malformed entries are skipped, out of range active is -1")
	_assert(presets.get_preset(1)["hidden_track_ids"] == [], "a missing id list is empty")
	presets.set_active(0)
	presets.prune({1: true})
	_assert(presets.get_preset(0)["hidden_track_ids"] == [1], "prune drops unknown ids")
	var json := presets.to_json({})
	_assert(json["active"] == 0 and json["presets"][0]["hidden_track_ids"] == [], "to_json with an existing set filters ids")
	_assert(presets.to_json()["presets"][0]["hidden_track_ids"] == [1], "to_json without a set writes every id")


func _test_snapshot_restore() -> void:
	var presets := VisibilityPresets.new()
	presets.add("A", [1])
	presets.add("B", [2])
	presets.set_active(1)
	var snap := presets.snapshot()
	presets.move(1, 0)
	presets.remove(0)
	presets.restore(snap)
	_assert(presets.count() == 2 and presets.display_name(1) == "2: B" and presets.active_index == 1,
		"restore brings back the order and the active index")
	presets.rename(0, "Z")
	_assert(snap["presets"][0]["name"] == "A", "a snapshot is a deep copy")


# ---------------------------------------------------------------- T-002

func _test_project_round_trip() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [f.b.id, f.d.id])
	project.visibility_presets.add("Drums", [f.a.id])
	project.visibility_presets.set_active(1)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded = _project_script.from_json(data)
	var presets: VisibilityPresets = loaded.visibility_presets
	_assert(presets.count() == 2, "both presets are saved")
	_assert(presets.display_name(0) == "1: Orchestra" and presets.display_name(1) == "2: Drums", "order and names survive")
	_assert(presets.active_index == 1, "active preset survives")
	_assert(presets.get_preset(0)["hidden_track_ids"] == [f.b.id, f.d.id], "stored ids survive")

	var stale: Dictionary = data.duplicate(true)
	stale["visibility_presets"]["presets"][0]["hidden_track_ids"].append(999)
	var pruned = _project_script.from_json(stale)
	_assert(pruned.visibility_presets.get_preset(0)["hidden_track_ids"] == [f.b.id, f.d.id], "a stale id is dropped on load")

	var out_of_range: Dictionary = data.duplicate(true)
	out_of_range["visibility_presets"]["active"] = 7
	_assert(_project_script.from_json(out_of_range).visibility_presets.active_index == -1, "out of range active becomes -1 on load")

	data.erase("visibility_presets")
	var legacy = _project_script.from_json(data)
	_assert(legacy.visibility_presets.count() == 0 and legacy.visibility_presets.active_index == -1,
		"a project without the key loads with no presets")


# ---------------------------------------------------------------- T-003

func _test_batch_visibility() -> void:
	var project = _project_script.new()
	var tracks: Array = []
	for i in 300:
		tracks.append(project.create_instrument_track("T%d" % i).track)
	var notified := [0]
	project.item_visibility_changed.connect(func() -> void: notified[0] += 1)
	var start := Time.get_ticks_msec()
	project.batch_visibility(func() -> void:
		for t in tracks:
			t.set_hidden(true))
	var elapsed := Time.get_ticks_msec() - start
	_assert(notified[0] == 1, "300 hides in one batch notify once (%d)" % notified[0])
	_assert(tracks[0].hidden and tracks[299].hidden, "the batch applied the change")
	_assert(elapsed < 50, "300 hides in a batch take under 50 ms (%d ms)" % elapsed)

	notified[0] = 0
	project.batch_visibility(func() -> void:
		tracks[0].set_hidden(false)
		project.batch_visibility(func() -> void:
			tracks[1].set_hidden(false))
		_assert(notified[0] == 0, "the inner batch does not notify"))
	_assert(notified[0] == 1, "nested batches notify once (%d)" % notified[0])

	notified[0] = 0
	project.batch_visibility(func() -> void: pass)
	_assert(notified[0] == 0, "a batch with no change does not notify")
	tracks[2].set_hidden(false)
	_assert(notified[0] == 1, "outside a batch each change notifies")


# ---------------------------------------------------------------- T-004

func _test_state_command() -> void:
	var f := _fixture()
	var project = f.project
	var channel: Object = f.b.get_linked_channel()
	var cmd = _state_cmd_script.new("Test", project, {channel: false, f.f: false}, {channel: true, f.f: true})
	cmd.do()
	_assert(f.b.hidden and channel.hidden and f.f.hidden, "do hides a channel target and a channel-less track target")
	cmd.undo()
	_assert(not f.b.hidden and not f.f.hidden, "undo restores both")
	var notified := [0]
	project.item_visibility_changed.connect(func() -> void: notified[0] += 1)
	cmd.do()
	_assert(notified[0] == 1, "do notifies once")
	var gone := Node.new()
	var skip = _state_cmd_script.new("Skip", project, {}, {gone: true})
	gone.free()
	skip.do()
	_assert(true, "a freed target is skipped without error")


func _test_presets_state_command() -> void:
	var presets := VisibilityPresets.new()
	presets.add("A", [])
	presets.add("B", [])
	presets.set_active(1)
	var before := presets.snapshot()
	presets.move(1, 0)
	var cmd = _presets_cmd_script.new("Move", presets, before, presets.snapshot())
	cmd.undo()
	_assert(presets.display_name(0) == "1: A" and presets.active_index == 1, "undo restores the order and the active index")
	cmd.do()
	_assert(presets.display_name(0) == "1: B" and presets.active_index == 0, "do re-applies them")


# ---------------------------------------------------------------- T-005

func _test_capture_and_apply() -> void:
	var f := _fixture()
	var project = f.project
	f.c.set_hidden(true)
	_assert(_tv.capture(project) == [f.c.id], "capture lists the tracks whose own flag is set")
	project.visibility_presets.add("P", _tv.capture(project))
	f.c.set_hidden(false)
	var e: Object = project.create_instrument_track("E").track
	f.a.set_hidden(true)
	_assert(_tv.apply_preset(project, 0), "apply_preset returns true")
	_assert(_hidden_names(f) == ["c"] and not e.hidden, "only the stored track is hidden, a later track is visible")
	_assert(project.visibility_presets.active_index == 0, "the applied preset is active")
	_assert(not _tv.apply_preset(project, 4), "an index past the end does nothing")
	_assert(_hidden_names(f) == ["c"], "...and changes nothing")
	_assert(_tv.target_of(project, f.f) == f.f and _tv.target_of(project, f.b) == f.b.get_linked_channel(),
		"target_of is the linked channel, or the track itself")


func _test_shared_channel() -> void:
	var f := _fixture()
	var project = f.project
	project.route_track_to_channel(f.c, f.b.get_linked_channel())
	_assert(f.b.get_linked_channel() == f.c.get_linked_channel(), "B and C share a channel")
	var cmd = _tv.hidden_changes(project, [f.c.id])
	_assert(cmd != null and cmd.new_values.size() == 1, "two tracks on one channel are one target")
	cmd.do()
	_assert(f.b.hidden and f.c.hidden, "any hidden track hides the shared target")
	_assert(_tv.hidden_changes(project, [f.c.id]) == null, "nothing to change gives null")


func _test_show_all_undo() -> void:
	var f := _fixture()
	var project = f.project
	f.b.set_hidden(true)
	f.d.set_hidden(true)
	_start_recording()
	_tv.show_all(project)
	_stop_recording()
	_assert(_hidden_names(f).is_empty(), "show_all shows everything")
	_assert(_recorded.size() == 1, "show_all is one command")
	_undo_last()
	_assert(_hidden_names(f) == ["b", "d"], "one undo hides B and D again")


func _test_apply_is_one_command() -> void:
	var f := _fixture()
	var project = f.project
	f.d.set_hidden(true)
	project.visibility_presets.add("P", [f.d.id])
	project.visibility_presets.add("Q", [f.a.id])
	_tv.apply_preset(project, 0)
	_start_recording()
	_tv.apply_preset(project, 1)
	_stop_recording()
	_assert(_recorded.size() == 1 and _recorded[0] is MacroCommand, "applying is one macro command")
	_assert(_hidden_names(f) == ["a"] and project.visibility_presets.active_index == 1, "visibility and active index changed")
	_undo_last()
	_assert(_hidden_names(f) == ["d"] and project.visibility_presets.active_index == 0, "one undo restores both")
	# Nothing to change (same preset, same state): no command at all.
	_start_recording()
	_tv.apply_preset(project, 0)
	_stop_recording()
	_assert(_recorded.is_empty(), "re-applying the active, clean preset records nothing")


# ---------------------------------------------------------------- T-006

func _test_show_only() -> void:
	var f := _fixture()
	var project = f.project
	_start_recording()
	_tv.show_only(project, f.b)
	_stop_recording()
	_assert(_hidden_names(f) == ["a", "c", "d"], "show_only(B) hides A, C and D, keeps F and B visible: %s" % [_hidden_names(f)])
	_assert(_recorded.size() == 1, "one command")
	_assert(_tv.is_only_visible_branch(project, f.b), "B is now the only visible branch")
	_assert(not _tv.is_only_visible_branch(project, f.c), "C is not")
	_tv.show_only(project, f.b)
	_assert(_hidden_names(f).is_empty(), "a second show_only shows everything")
	_tv.show_only(project, f.f)
	_assert(_hidden_names(f) == ["a", "d"], "show_only on a folder keeps its descendants visible")


func _test_show_branch_and_mixed() -> void:
	var f := _fixture()
	var project = f.project
	_assert(not _tv.is_mixed(project, f.f), "a fully visible folder is not mixed")
	f.c.set_hidden(true)
	_assert(_tv.is_mixed(project, f.f), "a visible folder with a hidden child is mixed")
	_assert(not _tv.is_mixed(project, f.c), "a leaf is never mixed")
	f.f.set_hidden(true)
	_assert(not _tv.is_mixed(project, f.f), "a hidden folder is not mixed")
	f.b.set_hidden(true)
	f.d.set_hidden(true)
	_start_recording()
	_tv.show_branch(project, f.f)
	_stop_recording()
	_assert(not f.f.hidden and not f.b.hidden and not f.c.hidden, "show_branch shows F, B and C")
	_assert(f.d.hidden, "...and leaves other tracks as they were")
	_assert(_recorded.size() == 1, "in one command")


# ---------------------------------------------------------------- T-007

func _test_add_preset_naming() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Vis Group 1", [])
	project.visibility_presets.add("Orchestra", [])
	f.d.set_hidden(true)
	_start_recording()
	var index: int = _tv.add_preset(project)
	_stop_recording()
	_assert(index == 2 and project.visibility_presets.display_name(2) == "3: Vis Group 3", "Add gives 3: Vis Group 3")
	_assert(project.visibility_presets.get_preset(2)["hidden_track_ids"] == [f.d.id], "it holds the current hidden state")
	_assert(project.visibility_presets.active_index == 2, "and becomes active")
	_assert(_recorded.size() == 1, "one undo step")
	_undo_last()
	_assert(project.visibility_presets.count() == 2 and project.visibility_presets.active_index == -1, "undo removes it")


func _test_move_undo() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [])
	project.visibility_presets.add("Drums", [])
	_start_recording()
	_tv.move_preset(project, 1, 0)
	_stop_recording()
	_assert(project.visibility_presets.display_name(0) == "1: Drums" and project.visibility_presets.display_name(1) == "2: Orchestra",
		"move up swaps the positions")
	_undo_last()
	_assert(project.visibility_presets.display_name(0) == "1: Orchestra", "one undo restores the order")
	_start_recording()
	_tv.move_preset(project, 0, -1)
	_tv.move_preset(project, 1, 2)
	_stop_recording()
	_assert(_recorded.is_empty(), "moving past either end records nothing")


func _test_rename_delete() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [])
	project.visibility_presets.add("Drums", [])
	project.visibility_presets.set_active(1)
	_start_recording()
	_tv.rename_preset(project, 1, "  Kit ")
	_tv.rename_preset(project, 1, "   ")
	_assert(project.visibility_presets.display_name(1) == "2: Kit" and _recorded.size() == 1, "rename trims and ignores blank names")
	_undo_last()
	_assert(project.visibility_presets.display_name(1) == "2: Drums", "rename undoes")
	_tv.delete_preset(project, 1)
	_stop_recording()
	_assert(project.visibility_presets.count() == 1 and project.visibility_presets.active_index == -1, "delete removes it and clears active")
	_undo_last()
	_assert(project.visibility_presets.count() == 2 and project.visibility_presets.active_index == 1, "delete undoes with the active index")


func _test_dirty_and_label() -> void:
	var f := _fixture()
	var project = f.project
	_assert(_tv.selector_label(project) == "All" and not _tv.is_dirty(project), "nothing hidden, no preset: All")
	f.c.set_hidden(true)
	_assert(_tv.selector_label(project) == "Custom", "something hidden with no preset: Custom")
	f.c.set_hidden(false)
	project.visibility_presets.add("Orchestra", [f.b.id])
	_tv.apply_preset(project, 0)
	_assert(_tv.selector_label(project) == "1: Orchestra" and not _tv.is_dirty(project), "just applied: clean")
	f.d.set_hidden(true)
	_assert(_tv.selector_label(project) == "1: Orchestra *" and _tv.is_dirty(project), "hiding D marks it unsaved")
	f.d.set_hidden(false)
	_assert(_tv.selector_label(project) == "1: Orchestra", "showing D again clears the mark")
	_tv.show_all(project)
	_assert(_tv.selector_label(project) == "All", "All never shows unsaved changes")


func _test_save_and_reset() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [f.b.id])
	_tv.apply_preset(project, 0)
	f.d.set_hidden(true)
	_start_recording()
	_tv.save_preset(project)
	_stop_recording()
	_assert(_recorded.size() == 1 and not _tv.is_dirty(project), "save is one command and cleans the preset")
	_tv.show_all(project)
	_tv.apply_preset(project, 0)
	_assert(_hidden_names(f) == ["b", "d"], "re-applying keeps D hidden")
	f.d.set_hidden(true)
	f.a.set_hidden(true)
	_assert(_tv.reset_preset(project), "reset returns true")
	_assert(_hidden_names(f) == ["b", "d"], "reset restores the stored state (A visible)")
	project.visibility_presets.set_active(-1)
	_assert(not _tv.reset_preset(project), "reset with no active preset does nothing")


func _test_step_preset() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [f.a.id])
	project.visibility_presets.add("Drums", [f.d.id])
	_tv.step_preset(project, 1)
	_assert(project.visibility_presets.active_index == 0 and _hidden_names(f) == ["a"], "Next with no active preset applies preset 1")
	_tv.step_preset(project, 1)
	_assert(project.visibility_presets.active_index == 1, "Next again applies preset 2")
	_tv.step_preset(project, 1)
	_assert(project.visibility_presets.active_index == -1 and _hidden_names(f).is_empty(), "Next on the last preset applies All")
	_tv.step_preset(project, -1)
	_assert(project.visibility_presets.active_index == 1, "Previous from All wraps to the last preset")
	_tv.step_preset(project, -1)
	_tv.step_preset(project, -1)
	_assert(project.visibility_presets.active_index == -1, "Previous from preset 1 goes to All")


func _test_track_delete_pruning() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("P", [f.d.id, f.a.id])
	var tracked: Object = f.d
	project.remove_track(f.d.id)
	var ids: Array = project.to_json()["visibility_presets"]["presets"][0]["hidden_track_ids"]
	_assert(ids == [f.a.id], "a deleted track is gone from to_json")
	project.visibility_presets.set_active(0)
	f.a.set_hidden(true)
	_assert(not _tv.is_dirty(project), "...and ignored by is_dirty")
	project.add_track(tracked)  # undo of the delete
	ids = project.to_json()["visibility_presets"]["presets"][0]["hidden_track_ids"]
	_assert(ids.has(tracked.id) and ids.size() == 2, "undoing the delete restores it in the preset")


func _key(keycode: Key, ctrl := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = true
	ev.ctrl_pressed = ctrl
	return ev


## The 12 visibility actions exist with the right defaults, match their chords, don't collide with
## the computer-keyboard notes or any other action, and drive TrackVisibility as Editor does.
func _test_hotkeys() -> void:
	var hotkeys: Node = root.get_node("Hotkeys")
	var actions_script: GDScript = load("res://input/HotkeyActions.gd")
	var ids: Array[String] = ["visibility_show_all", "visibility_preset_next", "visibility_preset_previous"]
	for i in range(1, 10):
		ids.append("visibility_preset_%d" % i)
	for id in ids:
		var def: Dictionary = actions_script.get_action(id)
		_assert(not def.is_empty() and def.group == "View" and def.context == "global", "%s is a global View action" % id)
	_assert(actions_script.get_action("visibility_show_all").defaults == ["Ctrl+0"], "Show all defaults to Ctrl+0")
	_assert(actions_script.get_action("visibility_preset_2").defaults == ["Ctrl+2"], "preset 2 defaults to Ctrl+2")
	_assert(actions_script.get_action("visibility_preset_next").defaults.is_empty(), "next has no default chord")
	_assert(actions_script.get_action("visibility_preset_previous").defaults.is_empty(), "previous has no default chord")

	_assert(hotkeys.pressed(_key(KEY_2, true), "visibility_preset_2"), "Ctrl+2 presses visibility_preset_2")
	_assert(hotkeys.pressed(_key(KEY_0, true), "visibility_show_all"), "Ctrl+0 presses visibility_show_all")
	_assert(not hotkeys.pressed(_key(KEY_2, true), "visibility_preset_3"), "Ctrl+2 doesn't press preset 3")
	_assert(not hotkeys.pressed(_key(KEY_2, true), "keyboard_c#3"), "Ctrl+2 doesn't play the computer-keyboard C#3")
	_assert(not hotkeys.pressed(_key(KEY_2), "visibility_preset_2"), "a bare 2 doesn't apply a preset")
	for id in ids:
		for chord in hotkeys.get_chords(id):
			_assert(hotkeys.find_conflicts(id, chord).is_empty(), "%s default %s has no conflicts" % [id, chord])

	# What Editor._handle_visibility_hotkey does for each action.
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [f.a.id])
	project.visibility_presets.add("Drums", [f.d.id])
	_assert(_tv.apply_preset(project, 2 - 1), "Ctrl+2 applies preset 2")
	_assert(_hidden_names(f) == ["d"] and project.visibility_presets.active_index == 1, "...hiding only D")
	_assert(not _tv.apply_preset(project, 9 - 1), "Ctrl+9 with only two presets does nothing")
	_assert(_hidden_names(f) == ["d"] and project.visibility_presets.active_index == 1, "...and changes nothing")
	_tv.show_all(project)
	_assert(_hidden_names(f).is_empty(), "Ctrl+0 shows every track")
