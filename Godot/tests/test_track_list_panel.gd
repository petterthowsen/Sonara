# test_track_list_panel.gd
# Spec 047: the Track List panel (TrackListPanel / TrackListRow): the tree, live updates, the name
# filter, eye clicks and drag painting, selection, rename, context menu, keyboard and the preset
# header. The rules behind it are covered by test_visibility_presets.gd.
# Project, HistoryUtil, TrackVisibility and the panel reference autoloads, so they are load()ed.
#
# Run: godot --headless --path Godot -s tests/test_track_list_panel.gd -- --test
extends TestBase

## Stands in for the Editor: the shared track selection and the reveal calls.
class StubSelection extends Node:
	signal tracks_selected(tracks: Array)
	var selected_tracks: Array = []
	var revealed: Array = []

	func select_tracks(tracks: Array, _active: Object) -> void:
		selected_tracks = tracks.duplicate()
		tracks_selected.emit(selected_tracks)

	func reveal_track(track: Object) -> void:
		revealed.append(track)


var _project_script: GDScript
var _history: GDScript
var _tv: GDScript
var _panel_scene: PackedScene
var _recorded: Array = []


func suite_name() -> String:
	return "Track List panel"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_history = load("res://history/HistoryUtil.gd")
	_tv = load("res://editor/track_list/TrackVisibility.gd")
	_panel_scene = load("res://editor/track_list/TrackListPanel.tscn")
	await _test_listing_and_dimming()
	await _test_live_updates()
	await _test_filter()
	await _test_eye_click_and_paint()
	await _test_show_only_and_mixed()
	await _test_selection()
	await _test_rename()
	await _test_context_menu()
	await _test_keyboard()
	await _test_preset_header()
	_history.test_recorder = Callable()


## A, F{B, C}, D: A, B, C and D are instrument tracks with their own channels; F is a folder with
## no channel. Visual order: A, F, B, C, D.
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


## Adds a panel bound to `project` and a stub selection source, and lets the layout settle.
func _make_panel(project: Object) -> Dictionary:
	var root := Control.new()
	root.size = Vector2(300, 600)
	get_root().add_child(root)
	var panel: Control = _panel_scene.instantiate()
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var stub := StubSelection.new()
	root.add_child(stub)
	panel.bind(project, stub)
	await process_frame
	await process_frame
	return {"root": root, "panel": panel, "stub": stub}


func _free_panel(ctx: Dictionary) -> void:
	ctx.panel.bind(null)
	ctx.root.queue_free()
	await process_frame


func _start_recording() -> void:
	_recorded.clear()
	_history.test_recorder = func(cmd) -> void: _recorded.append(cmd)


func _undo_last() -> void:
	_recorded.pop_back().undo()


func _ids(tracks: Array) -> Array:
	var out: Array = []
	for t in tracks:
		out.append(t.id)
	return out


func _hidden_count(f: Dictionary) -> int:
	var n := 0
	for key in ["a", "f", "b", "c", "d"]:
		if f[key].hidden:
			n += 1
	return n


func _mouse_button(pressed: bool, shift: bool = false, pos: Vector2 = Vector2.ZERO) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.shift_pressed = shift
	e.position = pos
	e.global_position = pos
	return e


func _motion(pos: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	return e


func _key(keycode: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = keycode
	e.pressed = true
	return e


## Press the eye of `track`'s row and release it in place (a plain click).
func _click_eye(panel: Control, track: Object, shift: bool = false) -> void:
	var row = panel.get_row(track)
	var pos: Vector2 = row.get_global_rect().get_center()
	row.eye_button.gui_input.emit(_mouse_button(true, shift, pos))
	panel._input(_mouse_button(false, false, pos))


# ---------------------------------------------------------------- T-008

func _test_listing_and_dimming() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	_assert(_ids(panel.get_row_tracks()) == _ids([f.a, f.f, f.b, f.c, f.d]), "5 rows in arranger order")
	_assert(panel.get_row(f.a).depth == 0 and panel.get_row(f.f).depth == 0, "A and F are at the top level")
	_assert(panel.get_row(f.b).depth == 1 and panel.get_row(f.c).depth == 1, "B and C are indented one level")
	_assert(panel.get_row(f.f).shows_arrow(), "F has an arrow")
	_assert(not panel.get_row(f.a).shows_arrow() and not panel.get_row(f.b).shows_arrow()
		and not panel.get_row(f.d).shows_arrow(), "tracks without children have no arrow")
	_assert(panel.get_row(f.b).indent.custom_minimum_size.x > panel.get_row(f.a).indent.custom_minimum_size.x,
		"a child row is indented")

	var expanded_before: bool = f.f.is_folder_expanded
	panel.get_row(f.f).fold_button.pressed.emit()
	_assert(_ids(panel.get_row_tracks()) == _ids([f.a, f.f, f.d]), "collapsing F hides B and C in the list")
	_assert(f.f.is_folder_expanded == expanded_before, "the arranger's folder state is untouched")
	panel.get_row(f.f).fold_button.pressed.emit()
	_assert(panel.get_row_tracks().size() == 5, "expanding F lists B and C again")
	f.f.is_folder_expanded = not expanded_before
	await process_frame
	_assert(panel.get_row_tracks().size() == 5, "collapsing a folder in the arranger does not collapse it here")
	f.f.is_folder_expanded = expanded_before

	f.f.set_hidden(true)
	await process_frame
	for t in [f.f, f.b, f.c]:
		_assert(is_equal_approx(panel.get_row(t).modulate.a, 0.65), "%s is dimmed under the hidden folder" % t.name)
	_assert(is_equal_approx(panel.get_row(f.a).modulate.a, 1.0), "A is not dimmed")
	_assert(panel.get_row(f.b).is_eye_on() and panel.get_row(f.c).is_eye_on(), "B and C eyes show their own visible state")
	_assert(not panel.get_row(f.f).is_eye_on(), "F's eye shows hidden")
	f.f.set_hidden(false)
	f.d.set_enabled(false)
	await process_frame
	_assert(is_equal_approx(panel.get_row(f.d).modulate.a, 0.45), "a disabled track is dimmed more")
	await _free_panel(ctx)


# ---------------------------------------------------------------- T-009

func _test_live_updates() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	var project = f.project

	var e: Object = project.create_instrument_track("E").track
	await process_frame
	_assert(panel.get_row_tracks().size() == 6 and panel.get_row_tracks().back() == e, "an added track gets a row")

	f.a.set_name("Alpha")
	_assert(panel.get_row(f.a).name_label.text == "Alpha", "a rename shows in the row")

	var old_color: Color = panel.get_row(f.a).color_strip.color
	f.a.set_color(Color(0.2, 0.4, 0.6))
	var strip: Color = panel.get_row(f.a).color_strip.color
	_assert(strip != old_color and strip.is_equal_approx(f.a.color.clamp()), "a recolor shows in the strip")

	project.remove_track(e.id)
	await process_frame
	_assert(panel.get_row_tracks().size() == 5 and panel.get_row(e) == null, "a removed track loses its row")

	project.place_track(f.d, f.f.id, f.c)
	await process_frame
	_assert(panel.get_row(f.d).depth == 1, "a re-parented track is indented under its new parent")
	project.place_track(f.d, -1, f.f)
	await process_frame
	_assert(panel.get_row(f.d).depth == 0, "and back out again")

	_start_recording()
	var b_row_id: int = panel.get_row(f.b).get_instance_id()
	_tv.apply_hidden_set(project, [f.d.id])
	await process_frame
	await process_frame
	_assert(not panel.get_row(f.d).is_eye_on(), "a hide shows in the row")
	_assert(panel.get_row(f.b).get_instance_id() == b_row_id, "a visibility change refreshes rows without rebuilding them")
	_undo_last()
	_assert(panel.get_row(f.d).is_eye_on(), "an undone hide shows in the row")
	await _free_panel(ctx)


func _test_filter() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	panel.get_row(f.f).fold_button.pressed.emit()
	panel.set_filter("c")
	_assert(_ids(panel.get_row_tracks()) == _ids([f.f, f.c]), "filter 'c' shows C and its ancestor F")
	_assert(not panel.get_row(f.f).collapsed, "ancestors are shown expanded while filtering")
	panel.set_filter("")
	_assert(_ids(panel.get_row_tracks()) == _ids([f.a, f.f, f.d]), "clearing the filter restores the earlier fold state")
	panel.get_row(f.f).fold_button.pressed.emit()
	_assert(panel.get_row_tracks().size() == 5, "all five rows are back once F is expanded")
	panel.set_filter("C")
	_assert(panel.get_row_tracks().size() == 2, "the filter ignores case")
	await _free_panel(ctx)


# ---------------------------------------------------------------- T-010

func _test_eye_click_and_paint() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	_start_recording()

	_click_eye(panel, f.b)
	_assert(f.b.hidden, "clicking B's eye hides B")
	_assert(not ItemVisibility.track_listed(f.project, f.b), "the arranger no longer lists B")
	_assert(_recorded.size() == 1, "one click is one history entry")
	_click_eye(panel, f.b)
	_assert(not f.b.hidden, "clicking again shows B")
	_recorded.clear()

	# Press on A, jump straight to D (skipping the rows between), release.
	var row_a = panel.get_row(f.a)
	row_a.eye_button.gui_input.emit(_mouse_button(true, false, row_a.get_global_rect().get_center()))
	var end: Vector2 = panel.get_row(f.d).get_global_rect().get_center()
	panel._input(_motion(end))
	panel._input(_mouse_button(false, false, end))
	_assert(_hidden_count(f) == 5, "a fast drag from A to D hides every row it crossed")
	_assert(_recorded.size() == 1, "the whole drag is one history entry")
	_undo_last()
	_assert(_hidden_count(f) == 0, "one undo shows them all again")

	# A drag that starts on a hidden row shows what it passes.
	f.b.set_hidden(true)
	f.c.set_hidden(true)
	_recorded.clear()
	_click_eye_drag(panel, f.b, f.c)
	_assert(not f.b.hidden and not f.c.hidden, "dragging from a hidden eye shows the rows it passes")
	_assert(_recorded.size() == 1, "and it is one history entry")
	await _free_panel(ctx)


func _click_eye_drag(panel: Control, from: Object, to: Object) -> void:
	var row = panel.get_row(from)
	row.eye_button.gui_input.emit(_mouse_button(true, false, row.get_global_rect().get_center()))
	var end: Vector2 = panel.get_row(to).get_global_rect().get_center()
	panel._input(_motion(end))
	panel._input(_mouse_button(false, false, end))


func _test_show_only_and_mixed() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	_start_recording()

	_click_eye(panel, f.b, true)
	_assert(f.a.hidden and f.c.hidden and f.d.hidden and not f.f.hidden and not f.b.hidden,
		"shift-click on B shows only B and its ancestor F")
	_assert(_recorded.size() == 1, "shift-click is one history entry")
	_click_eye(panel, f.b, true)
	_assert(_hidden_count(f) == 0, "a second shift-click shows everything")

	f.c.set_hidden(true)
	await process_frame
	_assert(panel.get_row(f.f).is_mixed(), "F's eye is mixed while C is hidden")
	_assert(not panel.get_row(f.b).is_mixed(), "B's is not")
	_recorded.clear()
	_click_eye(panel, f.f)
	_assert(not f.c.hidden and not f.f.hidden and not f.b.hidden, "clicking a mixed eye shows the branch")
	_assert(_recorded.size() == 1, "in one history entry")
	await process_frame
	_assert(not panel.get_row(f.f).is_mixed(), "F is no longer mixed")

	_click_eye(panel, f.f)
	_assert(f.f.hidden and not f.b.hidden, "clicking a fully visible parent hides only the parent")
	await _free_panel(ctx)


# ---------------------------------------------------------------- T-011

func _test_selection() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	var stub: Node = ctx.stub

	panel.get_row(f.b).row_pressed.emit(false, false)
	_assert(_ids(stub.selected_tracks) == [f.b.id], "a click selects the track")
	_assert(stub.revealed.size() == 1 and stub.revealed[0] == f.b, "a plain click reveals the track")
	panel.get_row(f.d).row_pressed.emit(true, false)
	_assert(_ids(stub.selected_tracks) == [f.b.id, f.d.id], "ctrl-click adds D")
	_assert(stub.revealed.size() == 1, "ctrl-click does not reveal")
	_assert(panel.get_row(f.b).is_selected() and panel.get_row(f.d).is_selected()
		and not panel.get_row(f.a).is_selected(), "B and D are highlighted")
	panel.get_row(f.b).row_pressed.emit(true, false)
	_assert(_ids(stub.selected_tracks) == [f.d.id], "ctrl-click on a selected row removes it")

	stub.select_tracks([f.a], f.a)
	_assert(panel.get_row(f.a).is_selected() and not panel.get_row(f.d).is_selected(),
		"an outside selection updates the highlight")

	panel.get_row(f.a).row_pressed.emit(false, false)
	panel.get_row(f.c).row_pressed.emit(false, true)
	_assert(_ids(stub.selected_tracks) == _ids([f.a, f.f, f.b, f.c]), "shift-click selects the range of rows")
	await _free_panel(ctx)


# ---------------------------------------------------------------- T-012

func _test_rename() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	_start_recording()

	var row = panel.get_row(f.b)
	row.row_double_clicked.emit()
	_assert(row.is_renaming() and row.name_edit.visible, "a double-click edits the name in place")
	row.name_edit.text = "Strings"
	row.name_edit.text_submitted.emit("Strings")
	_assert(f.b.name == "Strings", "Enter applies the new name")
	_assert(not row.is_renaming() and row.name_label.text == "Strings", "the row shows the label again")
	_assert(_recorded.size() == 1, "the rename is one history entry")
	_undo_last()
	_assert(f.b.name == "B", "and it undoes")

	row.begin_rename()
	row.name_edit.text = "Nope"
	row.cancel_rename()
	_assert(f.b.name == "B" and not row.is_renaming(), "Escape cancels without renaming")
	await _free_panel(ctx)


func _test_context_menu() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	var stub: Node = ctx.stub
	_start_recording()

	panel.get_row(f.b).row_pressed.emit(false, false)
	panel.get_row(f.c).row_pressed.emit(true, false)
	panel.prepare_context_menu(f.b)
	panel.run_context_action(panel.MENU_ENABLE)
	_assert(not f.b.enabled and not f.c.enabled, "Disable disables both selected tracks")
	_assert(_recorded.size() == 1, "in one history entry")
	_undo_last()
	_assert(f.b.enabled and f.c.enabled, "one undo enables both")

	panel.prepare_context_menu(f.d)
	_assert(_ids(stub.selected_tracks) == [f.d.id], "right-clicking an unselected track selects it")
	_recorded.clear()
	panel.run_context_action(panel.MENU_HIDE)
	_assert(f.d.hidden, "Hide hides the track")
	_undo_last()
	_assert(not f.d.hidden, "and undoes")

	panel.run_context_action(panel.MENU_COLLAPSE_ALL)
	_assert(_ids(panel.get_row_tracks()) == _ids([f.a, f.f, f.d]), "Collapse All folds F")
	panel.run_context_action(panel.MENU_EXPAND_ALL)
	_assert(panel.get_row_tracks().size() == 5, "Expand All unfolds it")
	await _free_panel(ctx)


func _test_keyboard() -> void:
	var f := _fixture()
	var ctx: Dictionary = await _make_panel(f.project)
	var panel: Control = ctx.panel
	var stub: Node = ctx.stub
	_start_recording()

	panel.get_row(f.b).row_pressed.emit(false, false)
	panel._gui_input(_key(KEY_LEFT))
	_assert(_ids(stub.selected_tracks) == [f.f.id], "Left on a child moves to its parent")
	panel._gui_input(_key(KEY_LEFT))
	_assert(panel.get_row(f.f).collapsed and panel.get_row_tracks().size() == 3, "Left on an expanded parent collapses it")
	panel._gui_input(_key(KEY_LEFT))
	_assert(_ids(stub.selected_tracks) == [f.f.id], "Left on a collapsed root row stays put")
	panel._gui_input(_key(KEY_RIGHT))
	_assert(not panel.get_row(f.f).collapsed and panel.get_row_tracks().size() == 5, "Right expands it")
	panel._gui_input(_key(KEY_DOWN))
	_assert(_ids(stub.selected_tracks) == [f.b.id], "Down moves to the next row")
	panel._gui_input(_key(KEY_SPACE))
	_assert(not f.b.hidden, "Space is left to the transport and does not hide the track")
	panel._gui_input(_key(KEY_UP))
	_assert(_ids(stub.selected_tracks) == [f.f.id], "Up moves to the previous row")
	await _free_panel(ctx)


# ---------------------------------------------------------------- T-013

func _selector_items(panel: Control) -> Array:
	var out: Array = []
	for i in panel.preset_selector.item_count:
		out.append(panel.preset_selector.get_item_text(i))
	return out


func _selector_text(panel: Control) -> String:
	return panel.preset_selector.get_item_text(panel.preset_selector.selected)


func _test_preset_header() -> void:
	var f := _fixture()
	var project = f.project
	project.visibility_presets.add("Orchestra", [f.c.id])
	project.visibility_presets.add("Drums", [])
	var ctx: Dictionary = await _make_panel(project)
	var panel: Control = ctx.panel
	_start_recording()

	_assert(_selector_items(panel) == ["All", "1: Orchestra", "2: Drums"], "the selector lists All and the presets")
	_assert(panel.save_button.disabled and panel.reset_button.disabled, "Save and Reset are disabled when clean")

	panel.pick_preset_item(1)
	_assert(f.c.hidden and _hidden_count(f) == 1, "picking a preset applies it")
	_assert(_recorded.size() == 1, "in one history entry")
	_assert(_selector_text(panel) == "1: Orchestra", "the selector shows the active preset")

	f.d.set_hidden(true)
	_assert(_selector_text(panel) == "1: Orchestra *", "an unsaved change adds the asterisk")
	_assert(not panel.save_button.disabled and not panel.reset_button.disabled, "Save and Reset are enabled")
	panel.reset_active_preset()
	_assert(not f.d.hidden and _selector_text(panel) == "1: Orchestra", "Reset discards the change")

	f.d.set_hidden(true)
	panel.save_active_preset()
	_assert(_selector_text(panel) == "1: Orchestra" and panel.save_button.disabled, "Save stores it")

	panel.pick_preset_item(0)
	_assert(_hidden_count(f) == 0 and project.visibility_presets.active_index == -1, "All shows every track")
	_assert(_selector_text(panel) == "All", "and the selector reads All")
	f.b.set_hidden(true)
	_assert(_selector_text(panel) == "Custom", "a hand-made state reads Custom")
	_assert(not panel.save_button.disabled, "Save is enabled on Custom")
	panel.save_active_preset()
	_assert(project.visibility_presets.count() == 3 and project.visibility_presets.active_index == 2, "Save on Custom adds a preset")
	panel.delete_active_preset()
	f.b.set_hidden(false)

	panel.add_preset()
	_assert(_selector_items(panel).back() == "3: Vis Group 3", "Add appends 'Vis Group 3' as the third preset")
	_assert(_selector_text(panel) == "3: Vis Group 3", "and makes it active")
	panel.move_active_preset(-1)
	_assert(_selector_items(panel).slice(1) == ["1: Orchestra", "2: Vis Group 3", "3: Drums"], "Move up reorders the presets")
	_undo_last()
	_assert(_selector_items(panel).slice(1) == ["1: Orchestra", "2: Drums", "3: Vis Group 3"], "one undo restores the order")
	panel.rename_active_preset("Strings")
	_assert(_selector_text(panel) == "3: Strings", "Rename changes the active preset")
	panel.delete_active_preset()
	_assert(_selector_items(panel) == ["All", "1: Orchestra", "2: Drums"], "Delete removes it")
	await _free_panel(ctx)
