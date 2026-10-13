# Run: godot --headless --path Godot -s tests/test_tracklist_hotkeys.gd -- --test
# Arranger tracklist hotkeys: Up/Down move the active track, Shift extends the selection,
# Enter renames, Ctrl+A selects siblings and a double tap selects every track.
# TrackList and the project reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _list: Control
var _project: Object


func suite_name() -> String:
	return "Tracklist hotkeys"


func run_tests() -> void:
	await _test_arrow_navigation()
	await _test_collapsed_folder_skipped()
	await _test_shift_extends()
	await _test_rename()
	await _test_select_siblings_and_all()
	_list.free()


func _key(keycode: Key, shift := false, ctrl := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	return ev


## Folder holding A and B, then root tracks C and D. Visual order: Folder, A, B, C, D.
func _setup() -> Dictionary:
	if _list:
		_list.free()
	_project = (load("res://data/Project.gd") as GDScript).new()
	var folder: Object = _project.create_folder_track("Folder").track
	var a: Object = _project.create_instrument_track("A").track
	var b: Object = _project.create_instrument_track("B").track
	var c: Object = _project.create_instrument_track("C").track
	var d: Object = _project.create_instrument_track("D").track
	_project.place_track(a, folder.id, null)
	_project.place_track(b, folder.id, a)
	_project.place_track(c, -1, folder)
	_project.place_track(d, -1, c)
	for t in [folder, a, b, c, d]:
		t.height = 60
	_list = (load("res://arranger/tracklist/TrackList.tscn") as PackedScene).instantiate()
	_list.size = Vector2(320, 800)
	root.add_child(_list)
	_list._on_project_activated(_project)
	await process_frame
	await process_frame
	_list._clear_selection(false)
	return {"folder": folder, "a": a, "b": b, "c": c, "d": d}


func _test_arrow_navigation() -> void:
	var t := await _setup()
	_assert(_list._handle_hotkey(_key(KEY_DOWN)), "Down is handled")
	_assert(_list.active_track == t.folder, "Down with nothing active starts at the first track")
	_list._handle_hotkey(_key(KEY_DOWN))
	_assert(_list.active_track == t.a and _list.selected_tracks == [t.a], "Down moves to the next track")
	_list._handle_hotkey(_key(KEY_UP))
	_assert(_list.active_track == t.folder, "Up moves back")
	_list._handle_hotkey(_key(KEY_UP))
	_assert(_list.active_track == t.folder, "Up stops at the first track")
	_list._select_track(t.d, false, false)
	_list._handle_hotkey(_key(KEY_DOWN))
	_assert(_list.active_track == t.d, "Down stops at the last track")
	# A plain move replaces a multi-selection.
	_list._select_track(t.c, false, false)
	_list._select_track(t.d, false, true)
	_list._handle_hotkey(_key(KEY_UP))
	_assert(_list.selected_tracks.size() == 1, "plain move leaves one track selected")


func _test_collapsed_folder_skipped() -> void:
	var t := await _setup()
	t.folder.is_folder_expanded = false
	await create_timer(0.6).timeout
	_list._select_track(t.folder, false, false)
	_list._handle_hotkey(_key(KEY_DOWN))
	_assert(_list.active_track == t.c, "Down skips tracks hidden in a collapsed folder")


func _test_shift_extends() -> void:
	var t := await _setup()
	_list._select_track(t.a, false, false)
	_list._handle_hotkey(_key(KEY_DOWN, true))
	_list._handle_hotkey(_key(KEY_DOWN, true))
	_assert(_list.selected_tracks == [t.a, t.b, t.c], "Shift+Down extends the selection: %d" % _list.selected_tracks.size())
	_assert(_list.active_track == t.c, "the newest track is active")
	_list._handle_hotkey(_key(KEY_UP, true))
	_assert(_list.selected_tracks == [t.a, t.b], "Shift+Up shrinks it again")


func _test_rename() -> void:
	var t := await _setup()
	_assert(not _list.rename_active_track(), "rename with no active track does nothing")
	_list._select_track(t.b, false, false)
	_assert(_list._handle_hotkey(_key(KEY_ENTER)), "Enter is handled")
	var item = _list._find_track_item(t.b)
	_assert(item.label.is_editing, "Enter opens the name field of the active track")


func _test_select_siblings_and_all() -> void:
	var t := await _setup()
	_list._select_track(t.a, false, false)
	_list._handle_hotkey(_key(KEY_A, false, true))
	_assert(_list.selected_tracks.size() == 2 and _list.selected_tracks.has(t.a) and _list.selected_tracks.has(t.b),
			"Ctrl+A selects the siblings inside the folder")
	_assert(_list.active_track == t.a, "the active track is kept")
	# A second press within the double-tap window selects everything.
	_list._handle_hotkey(_key(KEY_A, false, true))
	_assert(_list.selected_tracks.size() == 5, "Ctrl+A twice selects all tracks: %d" % _list.selected_tracks.size())
	# Top-level siblings are the other top-level tracks (folder, C, D).
	await create_timer(0.6).timeout
	_list._select_track(t.c, false, false)
	_list._handle_hotkey(_key(KEY_A, false, true))
	_assert(_list.selected_tracks.size() == 3 and not _list.selected_tracks.has(t.a), "top-level siblings exclude folder children")
