# Sampler multisample editor (spec 023, T-021–T-025): the group filter bar, the sample list, the
# zone map's hit testing, drags, click cycling, key-strip audition and drops, and the batch menu
# and dialog. No live engine: AudioEngineOSC queues sends in `_pending_sends`, and
# HistoryUtil.test_recorder collects the undo steps.
# Run: godot --headless --path Godot -s tests/test_sampler_zone_map.gd -- --test
extends TestBase

const SAMPLER_ID := "sonara.builtin.sampler"
const ENUMS := {"Loop Mode": ["Off", "On", "Ping-Pong"]}

var _project_script: GDScript
var _device_script: GDScript
var _instance_script: GDScript
var _history_util: GDScript
var _asset_script: GDScript
var _actions: GDScript
var _osc: Node
var _recorded: Array = []


func suite_name() -> String:
	return "Sampler zone map"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_asset_script = load("res://browser/Asset.gd")
	_actions = load("res://devices/builtin/sampler/SamplerActions.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	await _test_editor_visibility()
	await _test_group_filter()
	await _test_mute_solo_and_group_menu()
	await _test_list_search_and_selection()
	await _test_list_delete()
	await _test_hit_testing()
	await _test_click_cycling()
	await _test_resize()
	await _test_move()
	await _test_drop_at_key()
	await _test_audition()
	await _test_batch_menu()
	await _test_batch_dialog()
	_history_util.test_recorder = Callable()


# --- helpers ---------------------------------------------------------------

func _make_device() -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(SAMPLER_ID)
	if device != null:
		return device
	device = _device_script.new(SAMPLER_ID, "Sampler", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.supports_file_loading = true
	device.supported_file_extensions.assign([".wav", ".flac"])
	var add := func(id: int, name: String, min_v: float, max_v: float, default_v: float, type := "float") -> void:
		var param := DeviceParameter.new(id, name)
		param.min_value = min_v
		param.max_value = max_v
		param.default_value = default_v
		param.param_type = type
		if type == "enum":
			param.enum_values.assign(ENUMS[name])
		device.add_parameter(param)
	add.call(1, "Tune", -24.0, 24.0, 0.0)
	add.call(3, "Root", 0.0, 127.0, 60.0)
	add.call(7, "Start", 0.0, 1.0, 0.0)
	add.call(8, "End", 0.0, 1.0, 1.0)
	add.call(14, "Fine", -100.0, 100.0, 0.0)
	add.call(20, "Reverse", 0.0, 1.0, 0.0, "bool")
	add.call(21, "Loop Mode", 0.0, 2.0, 0.0, "enum")
	add.call(22, "Loop Start", 0.0, 1.0, 0.0)
	add.call(23, "Loop End", 0.0, 1.0, 1.0)
	add.call(24, "Crossfade", 0.0, 100.0, 0.0)
	registry._devices[SAMPLER_ID] = device
	return device


## A Sampler on a project channel holding zones for `paths` (none = single mode), and an editor
## bound to it: {"inst", "model", "editor"}.
func _setup(paths: Array = []) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Sampler").channel
	var inst: Object = _instance_script.new(_make_device(), ch.id, -1)
	ch.add_device(inst)
	var model: Object = inst.ensure_multisample()
	if not paths.is_empty():
		model.add_files(paths)
	var editor: Control = (load("res://devices/builtin/sampler/MultisampleEditor.tscn") as PackedScene).instantiate()
	root.add_child(editor)
	editor.size = Vector2(900, 420)
	editor.bind(inst)
	await process_frame
	await process_frame
	_clear()
	return {"inst": inst, "model": model, "editor": editor}


func _teardown(s: Dictionary) -> void:
	s.editor.queue_free()


func _clear() -> void:
	_osc._pending_sends.clear()
	_recorded.clear()


func _sent(suffix: String) -> Array:
	return _osc._pending_sends \
		.filter(func(item) -> bool: return str(item.address).ends_with(suffix)) \
		.map(func(item): return item.args)


func _audio(path: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Audio
	asset.path = path
	return asset


## Three zones stacked on C3–E3 over all velocities.
func _stacked() -> Dictionary:
	var s := await _setup(["/tmp/one.wav", "/tmp/two.wav", "/tmp/three.wav"])
	for zone in s.model.zones:
		s.model.set_zone_fields(zone.id, {"key": [60, 64], "vel": [1, 127]})
	_clear()
	return s


func _center(map: Control, zone: Object) -> Vector2:
	return map.zone_rect(zone).get_center()


# --- editor and group bar --------------------------------------------------

func _test_editor_visibility() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Sampler").channel
	var inst: Object = _instance_script.new(_make_device(), ch.id, -1)
	ch.add_device(inst)
	var factory: GDScript = load("res://devices/DeviceViewFactory.gd")
	factory.register_builtin_views(inst.device)
	var window: Control = factory.create(inst, _device_script.ViewType.Window)
	_assert(window != null, "the factory returns the Sampler Window view")
	if window == null:
		return
	root.add_child(window)
	window.bind_to_device(inst)
	await process_frame
	_assert(not window.editor.visible, "the multisample editor is hidden in single mode")
	_actions.convert_to_multisample(inst)
	_assert(window.editor.visible, "the editor shows after converting")
	_actions.convert_to_single(inst)
	_assert(not window.editor.visible, "and hides again after converting back")
	window.queue_free()


func _test_group_filter() -> void:
	var s := await _setup(["/tmp/Soft_C3.wav", "/tmp/Soft_E3.wav", "/tmp/Hard_C3.wav"])
	var model: Object = s.model
	var editor: Control = s.editor
	var soft: int = model.add_group("Soft")
	model.move_to_group([model.zones[0].id, model.zones[1].id], soft)
	var bar: Control = editor.group_bar
	_assert(bar.chip_for(-1) != null and bar.chip_for(0) != null and bar.chip_for(soft) != null, "chips for All, Ungrouped and each group")
	_assert(bar.chip_for(-1).name_button.button_pressed, "All is active by default")
	bar.click_group(soft)
	_assert(editor.visible_groups == [soft], "clicking a group shows only that group")
	_assert(editor.visible_zones().size() == 2 and editor.zone_list.row_ids.size() == 2, "the list shows only its zones")
	_assert(bar.chip_for(soft).name_button.button_pressed and not bar.chip_for(-1).name_button.button_pressed, "the clicked chip is active")
	bar.click_group(0, true)
	_assert(editor.visible_groups == [soft, 0] and editor.visible_zones().size() == 3, "Ctrl-click adds Ungrouped to the visible set")
	bar.click_group(soft, true)
	_assert(editor.visible_groups == [0] and editor.visible_zones().size() == 1, "Ctrl-click again removes it")
	bar.click_group(-1)
	_assert(editor.visible_groups.is_empty() and editor.visible_zones().size() == 3, "All shows every zone")
	# Hiding a group drops its zones from the selection.
	editor.set_selection([model.zones[0].id, model.zones[2].id])
	bar.click_group(0)
	_assert(editor.selected_ids == [model.zones[2].id], "hidden zones leave the selection")
	_teardown(s)


func _test_mute_solo_and_group_menu() -> void:
	var s := await _setup(["/tmp/a.wav", "/tmp/b.wav"])
	var model: Object = s.model
	var bar: Control = s.editor.group_bar
	_actions.add_group(s.inst, "Soft")
	var soft: int = model.groups[0].id
	_assert(bar.chip_for(soft) != null, "+ / add_group adds a chip")
	_clear()
	bar.chip_for(soft).mute_button.button_pressed = true
	_assert(model.get_group(soft).mute, "M mutes the group")
	_assert(not _sent("zone_group/%d/set" % soft).is_empty(), "the mute reaches the engine")
	_assert(_recorded.size() == 1, "muting is one undo step")
	bar.chip_for(0).solo_button.button_pressed = true
	_assert(model.ungrouped.solo, "S solos Ungrouped")
	bar.fill_group_menu(0)
	var menu: PopupMenu = bar.group_menu
	_assert(menu.theme_type_variation == &"ContextMenuList", "the group menu uses the context-menu style")
	_assert(menu.is_item_disabled(menu.get_item_index(bar.MenuId.RENAME)), "Ungrouped can't be renamed")
	bar.fill_group_menu(soft)
	_assert(not menu.is_item_disabled(menu.get_item_index(bar.MenuId.DELETE)), "a group can be deleted")
	bar.play_mode_menu.id_pressed.emit(1)
	_assert(model.get_group(soft).play_mode == 1, "the play mode submenu sets round robin")
	bar.chip_for(soft).name_committed.emit("Hard")
	_assert(model.get_group(soft).name == "Hard" and bar.chip_for(soft).name_button.text == "Hard", "renaming a chip renames the group")
	# The gain popup records one step for the whole session.
	_clear()
	bar.open_gain_popup(soft)
	bar.gain_knob.knob.value = 0.5
	bar.gain_knob.knob.value = 0.25
	bar.gain_popup.hide()
	_assert(is_equal_approx(model.get_group(soft).gain, 0.25), "the gain knob sets the group gain")
	_assert(_recorded.size() == 1, "a gain popup session is one undo step (got %d)" % _recorded.size())
	menu.id_pressed.emit(bar.MenuId.DELETE)
	_assert(model.groups.is_empty() and bar.chip_for(soft) == null, "Delete removes the group and its chip")
	_teardown(s)


# --- list ------------------------------------------------------------------

func _test_list_search_and_selection() -> void:
	var s := await _setup(["/tmp/Soft_C3.wav", "/tmp/soft_E3.wav", "/tmp/Hard_C3.wav", "/tmp/Hard_E3.wav"])
	var list: Control = s.editor.zone_list
	var model: Object = s.model
	_assert(list.row_ids.size() == 4, "the list shows every zone")
	list.search.text = "SOFT"
	list.search.text_changed.emit("SOFT")
	_assert(list.row_ids.size() == 2, "the search filters case-insensitively")
	_assert(list.items.get_item_text(0).to_lower().contains("soft"), "matching names remain")
	list.search.text = ""
	list.search.text_changed.emit("")
	# A Shift-range in the ItemList becomes the editor's selection and shows in the map.
	list.items.select(0, true)
	list.items.select(1, false)
	list.items.select(2, false)
	list.apply_list_selection(2)
	var ids: Array = [model.zones[0].id, model.zones[1].id, model.zones[2].id]
	_assert(s.editor.selected_in_order() == ids, "a shift-range selection reaches the editor's selected_ids")
	_assert(model.focused_zone_id == model.zones[2].id, "the clicked zone becomes focused")
	_assert(ids.all(func(id: int) -> bool: return s.editor.is_selected(id)), "the map sees the same selection")
	s.editor.click_zone(model.zones[3].id)
	_assert(list.items.get_selected_items() == PackedInt32Array([3]), "a map click updates the list selection")
	# Missing zones are dimmed with the reason.
	model.set_zone_loading_state(model.zones[1].id, "failed:file not found")
	_assert(list.items.get_item_tooltip(1).contains("file not found"), "a missing zone shows the reason as a tooltip")
	_assert(list.items.get_item_custom_fg_color(1) == list.MISSING_COLOR, "a missing zone is dimmed")
	_teardown(s)


func _test_list_delete() -> void:
	var s := await _setup(["/tmp/a.wav", "/tmp/b.wav", "/tmp/c.wav"])
	var model: Object = s.model
	var keep: int = model.zones[1].id
	s.editor.set_selection([model.zones[0].id, model.zones[2].id])
	var key := InputEventKey.new()
	key.keycode = KEY_DELETE
	key.pressed = true
	s.editor.zone_list._on_items_input(key)
	_assert(model.zones.size() == 1 and model.zones[0].id == keep, "Delete removes the selected zones")
	_assert(_recorded.size() == 1, "the delete is one undo step")
	if _recorded.size() == 1:
		_recorded[0].undo()
		_assert(model.zones.size() == 3, "one undo restores them")
	var select_all := InputEventKey.new()
	select_all.keycode = KEY_A
	select_all.ctrl_pressed = true
	select_all.pressed = true
	s.editor.zone_map._gui_input(select_all)
	_assert(s.editor.selected_ids.size() == 3, "Ctrl+A selects every visible zone")
	_teardown(s)


# --- map -------------------------------------------------------------------

func _test_hit_testing() -> void:
	var s := await _stacked()
	var map: Control = s.editor.zone_map
	var zones: Array = s.model.zones
	_assert(map.size.x > 100.0 and map.size.y > 60.0, "the map has a size")
	var center := _center(map, zones[0])
	var under: Array = map.zones_at(center)
	_assert(under.size() == 3, "zones_at returns every stacked zone")
	_assert(under[0] == zones[2] and under[2] == zones[0], "the top (last drawn) zone comes first")
	_assert(map.zones_at(Vector2(map.zone_rect(zones[0]).end.x + 20, center.y)).is_empty(), "nothing outside the zones")
	var rect: Rect2 = map.zone_rect(zones[0])
	var right: Dictionary = map.edge_at(Vector2(rect.end.x - 1, center.y))
	_assert(not right.is_empty() and right["edge"] == map.Edge.RIGHT, "edge_at finds the right edge")
	var top: Dictionary = map.edge_at(Vector2(center.x, rect.position.y + 1))
	_assert(not top.is_empty() and top["edge"] == map.Edge.TOP, "edge_at finds the top edge")
	_assert(map.edge_at(center).is_empty(), "the middle of a zone is not an edge")
	_assert(map.label_rotated(Rect2(0, 0, 8, 100)), "a tall rectangle rotates its label")
	_assert(not map.label_rotated(Rect2(0, 0, 100, 8)), "a wide one doesn't")
	var strip_top: float = map.map_height() + 2.0
	var strip_bottom: float = map.size.y - 2.0
	_assert(map.strip_velocity(strip_top) > 110 and map.strip_velocity(strip_bottom) < 20, "key strip velocity rises with height")
	_assert(map.vel_at(1.0) == 127 and map.vel_at(map.map_height() - 1.0) == 1, "velocity runs bottom (1) to top (127)")
	_teardown(s)


func _test_click_cycling() -> void:
	var s := await _stacked()
	var map: Control = s.editor.zone_map
	var center := _center(map, s.model.zones[0])
	var focused: Array = []
	for i in 3:
		map.press(center)
		map.release()
		focused.append(s.model.focused_zone_id)
	var ids: Array = s.model.zones.map(func(z) -> int: return z.id)
	_assert(focused == [ids[2], ids[1], ids[0]], "three clicks cycle through three stacked zones (got %s)" % [focused])
	_assert(s.editor.selected_ids == [ids[0]], "the cycled zone is the selection")
	_assert(_recorded.is_empty(), "clicks record no undo steps")
	# Ctrl-click toggles, a click on empty space clears.
	map.press(center, true)
	map.release()
	_assert(s.editor.selected_ids.size() == 2, "Ctrl-click adds the top zone")
	map.press(Vector2(map.size.x - 5, 5))
	map.release()
	_assert(s.editor.selected_ids.is_empty(), "a click on empty space clears the selection")
	_teardown(s)


func _test_resize() -> void:
	var s := await _setup(["/tmp/only.wav"])
	var model: Object = s.model
	var map: Control = s.editor.zone_map
	var zone: Object = model.zones[0]
	model.set_zone_fields(zone.id, {"key": [60, 64], "vel": [1, 127]})
	_clear()
	var rect: Rect2 = map.zone_rect(zone)
	var grab := Vector2(rect.end.x - 1, rect.get_center().y)
	map.press(grab)
	map.drag_to(grab + Vector2(map.key_width() * 2.0, 0))
	map.drag_to(grab + Vector2(map.key_width() * 2.0, 1))
	map.release()
	_assert(zone.key_lo == 60 and zone.key_hi == 66, "dragging the right edge two keys right gives C3–F#3")
	_assert(_recorded.size() == 1, "a resize drag is one undo step (got %d)" % _recorded.size())
	rect = map.zone_rect(zone)
	grab = Vector2(rect.end.x - 1, rect.get_center().y)
	map.press(grab)
	map.drag_to(Vector2(2, grab.y))
	map.release()
	_assert(zone.key_lo == 60 and zone.key_hi == 60, "dragging it far left stops at a one-key range")
	if _recorded.size() == 2:
		_recorded[1].undo()
		_assert(zone.key_hi == 66, "undo restores the previous range")
	_teardown(s)


func _test_move() -> void:
	var s := await _setup(["/tmp/a_C3.wav", "/tmp/b_C4.wav"])
	var model: Object = s.model
	var map: Control = s.editor.zone_map
	var a: Object = model.zones[0]
	var b: Object = model.zones[1]
	model.set_zone_fields(a.id, {"key": [48, 52], "vel": [1, 64]})
	model.set_zone_fields(b.id, {"key": [60, 64], "vel": [65, 127]})
	s.editor.set_selection([a.id, b.id])
	_clear()
	var start := _center(map, a)
	map.press(start)
	_assert(s.editor.selected_ids.size() == 2, "pressing a selected zone keeps the multi-selection")
	map.drag_to(start + Vector2(map.key_width() * 3.0, 0))
	map.release()
	_assert(a.key_lo == 51 and a.key_hi == 55 and b.key_lo == 63 and b.key_hi == 67, "a two-zone move shifts both by the same amount")
	_assert(a.vel_lo == 1 and b.vel_hi == 127, "a horizontal move keeps the velocity ranges")
	_assert(_recorded.size() == 1, "the move is one undo step")
	# The move is clamped as a whole: b can't go past 127 velocity, so neither moves up.
	start = _center(map, a)
	map.press(start)
	map.drag_to(start - Vector2(0, map.vel_height() * 10.0))
	map.release()
	_assert(a.vel_lo == 1 and b.vel_hi == 127, "a move stops where the first zone hits the range end")
	# Without a move, the click collapses the selection to the clicked zone.
	map.press(_center(map, b))
	map.release()
	_assert(s.editor.selected_ids == [b.id], "a click without a move selects only that zone")
	_teardown(s)


func _test_drop_at_key() -> void:
	var s := await _setup(["/tmp/a_C1.wav", "/tmp/b_D1.wav", "/tmp/c_E1.wav", "/tmp/d_F1.wav"])
	var map: Control = s.editor.zone_map
	var f3 := 65
	var x: float = (f3 + 0.5) * map.key_width()
	_assert(map._can_drop_data(Vector2(x, 20), [_audio("/tmp/kick.wav")]), "the map accepts audio files")
	_assert(not map._can_drop_data(Vector2(x, 20), "nope"), "and refuses anything else")
	map._drop_data(Vector2(x, 20), [_audio("/tmp/kick.wav"), _audio("/tmp/snare.wav")])
	var zones: Array = s.model.zones
	_assert(zones.size() == 6, "two dropped files add two zones")
	_assert(zones[4].key_lo == f3 and zones[5].key_lo == f3 + 1, "the new zones start at F3, the key under the pointer")
	_assert(_recorded.size() == 1, "the drop is one undo step")
	_teardown(s)


func _test_audition() -> void:
	var s := await _setup(["/tmp/a.wav"])
	var map: Control = s.editor.zone_map
	var c3 := 60
	var x: float = (c3 + 0.5) * map.key_width()
	map.press(Vector2(x, map.map_height() + 2.0))
	var on := _sent("/audition")
	_assert(on.size() == 1 and on[0][0] == c3 and on[0][2] == 1, "pressing the key strip auditions C3")
	_assert(on.size() == 1 and on[0][1] > 100, "near the top of the key it plays loud")
	map.release()
	var all := _sent("/audition")
	_assert(all.size() == 2 and all[1][0] == c3 and all[1][2] == 0, "releasing sends the note-off")
	_clear()
	map.press(Vector2(x, map.size.y - 2.0))
	map.release()
	var quiet := _sent("/audition")
	_assert(quiet.size() == 2 and quiet[0][1] < 20, "near the bottom it plays quietly")
	_assert(_recorded.is_empty(), "auditioning records nothing")
	_teardown(s)


# --- batch -----------------------------------------------------------------

func _test_batch_menu() -> void:
	var s := await _stacked()
	var menu: PopupMenu = s.editor.batch_menu
	_assert(menu.theme_type_variation == &"ContextMenuList", "the batch menu uses the context-menu style")
	s.editor.select_all()
	menu.fill()
	_assert(menu.op_texts() == ["Assign Velocity…", "Assign Note…", "Distribute on Velocity…", "Distribute on Notes…", "Set Root from Name", "Move to Group", "Delete"], "the batch menu offers the REQ-047 operations (got %s)" % [menu.op_texts()])
	_assert(menu.groups_menu.theme_type_variation == &"ContextMenuList", "the group submenu uses the context-menu style too")
	# The map's right-click lists the zones under the pointer first; choosing one focuses it.
	var under: Array = s.editor.zone_map.zones_at(_center(s.editor.zone_map, s.model.zones[0]))
	menu.fill(under)
	_assert(menu.get_item_text(0) == under[0].name and menu.get_item_text(2) == under[2].name, "the zones under the pointer come first")
	menu.id_pressed.emit(menu.get_item_id(1))
	_assert(s.model.focused_zone_id == under[1].id and s.editor.selected_ids == [under[1].id], "choosing the second zone selects and focuses it")
	# Delete and Move to Group apply at once.
	var soft: int = s.model.add_group("Soft")
	s.editor.select_all()
	_clear()
	menu.fill()
	menu.groups_menu.id_pressed.emit(soft)
	_assert(s.model.zones.all(func(z) -> bool: return z.group_id == soft), "Move to Group moves the selection")
	_assert(_recorded.size() == 1, "Move to Group is one undo step")
	menu.id_pressed.emit(_actions.BATCH_OPS.find("delete"))
	_assert(s.model.zones.is_empty(), "Delete removes the selection")
	menu.fill()
	_assert(menu.is_item_disabled(menu.get_item_index(0)), "operations are disabled with nothing selected")
	_teardown(s)


func _test_batch_dialog() -> void:
	var s := await _stacked()
	await process_frame
	var zones: Array = []
	zones.assign(s.model.zones)
	s.model.add_files(["/tmp/four.wav"])
	zones.assign(s.model.zones)
	s.editor.select_all()
	_clear()
	var dialog: PopupPanel = s.editor.batch_dialog
	dialog.configure(s.inst, "distribute_velocity", s.editor.selected_in_order())
	_assert(dialog.mode_row.visible and not dialog.single_check.visible, "distribute shows Stretch/Gaps, not Single value")
	_assert(dialog.lo_spin.value == 1 and dialog.hi_spin.value == 127, "velocity starts from the whole range")
	dialog.apply()
	var ranges: Array = zones.map(func(z) -> Array: return [z.vel_lo, z.vel_hi])
	_assert(ranges == [[1, 32], [33, 64], [65, 96], [97, 127]], "distributing four zones on velocity gives the REQ-047 example (got %s)" % [ranges])
	_assert(_recorded.size() == 1, "applying the dialog is one undo step")
	# Assign note with a single value.
	dialog.configure(s.inst, "assign_note", s.editor.selected_in_order())
	_assert(dialog.single_check.visible and dialog.lo_note.visible, "assign note shows Single value and note names")
	dialog.lo_spin.value = 62
	dialog.single_check.button_pressed = true
	_assert(dialog.options()["hi"] == 62, "Single value makes high equal low")
	dialog.apply()
	_assert(zones.all(func(z) -> bool: return z.key_lo == 62 and z.key_hi == 62), "assign note gives every zone D3")
	# Gaps.
	dialog.configure(s.inst, "distribute_velocity", s.editor.selected_in_order())
	dialog.mode_option.select(dialog.Split.GAPS)
	dialog.mode_option.item_selected.emit(dialog.Split.GAPS)
	_assert(dialog.slice_row.visible, "Gaps shows the slice size")
	dialog.slice_spin.value = 10
	dialog.apply()
	_assert(zones[1].vel_lo == 11 and zones[1].vel_hi == 20, "gaps use equal slices of the given size")
	_teardown(s)
