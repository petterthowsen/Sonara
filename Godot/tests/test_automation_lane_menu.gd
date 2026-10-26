# test_automation_lane_menu.gd
# Headless tests for the track-header automation dropdown (T-019, REQ-014): the "+ Add new"
# entry must emit add_lane_requested even when the track has no lanes yet (a negative
# PopupMenu item id gets auto-assigned by Godot, which used to swallow the click).
# Also covers the parameter picker's MIDI CC submenu (spec 030 T-011).
#
# Run: godot --headless --path Godot -s tests/test_automation_lane_menu.gd -- --test
extends TestBase

var _track_script: GDScript
var _lane_script: GDScript
var _menu_script: GDScript
var _picker_script: GDScript
var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _param_script: GDScript

var _requested: int = 0


func suite_name() -> String:
	return "Automation lane menu tests"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_menu_script = load("res://arranger/tracklist/AutomationLaneMenu.gd")
	_picker_script = load("res://arranger/tracklist/AutomationParameterPicker.gd")
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	var library: GDScript = load("res://data/PresetLibrary.gd")
	library.dir_override = OS.get_temp_dir().path_join("sonara_lane_menu_test_%d" % Time.get_ticks_usec())
	_test_add_new_with_no_lanes()
	_test_lane_toggle_and_add_new_together()
	_test_cc_menu_generic_range()
	_test_cc_menu_sfz_labels_first_and_no_device_submenu()
	_test_cc_menu_omits_laned_controller()
	_test_device_submenu_skips_controller_params()
	_test_menu_uses_clip_editor_view()
	_test_create_lane_for_opens_and_undoes()
	_test_create_lane_for_redo_reopens()
	_test_presets_section()
	library.dir_override = ""


func _make_menu(track: Object) -> Object:
	var menu: Object = _menu_script.new()
	_requested = 0
	menu.add_lane_requested.connect(_on_add_lane_requested)
	menu.track = track
	menu._rebuild()
	return menu


func _on_add_lane_requested(_track) -> void:
	_requested += 1


func _test_add_new_with_no_lanes() -> void:
	var track := _make_menu_track()
	var menu := _make_menu(track)
	_assert(menu.get_item_index(menu.ADD_NEW_ID) == 0, "empty track lists '+ Add new' first, no lane items")
	# The id Godot delivers for the item, looked up rather than assumed.
	var add_id: int = menu.get_item_id(menu.get_item_index(menu.ADD_NEW_ID))
	_assert(add_id == menu.ADD_NEW_ID, "'+ Add new' keeps its explicit id: %d" % add_id)
	menu._on_id_pressed(add_id)
	_assert(_requested == 1, "'+ Add new' emits add_lane_requested with no lanes: %d" % _requested)
	menu.free()


func _test_lane_toggle_and_add_new_together() -> void:
	var track := _make_menu_track()
	var lane: Object = _lane_script.new("lane0", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	var menu := _make_menu(track)
	_assert(menu.get_item_index(menu.ADD_NEW_ID) == 2, "lane checkbox + separator + '+ Add new'")
	menu._on_id_pressed(0)
	_assert(lane.visible == false, "lane id 0 toggles visibility")
	menu._on_id_pressed(menu.ADD_NEW_ID)
	_assert(_requested == 1, "'+ Add new' still emits alongside lane checkboxes: %d" % _requested)
	menu.free()


func _make_menu_track() -> Object:
	return _track_script.new(1)

# ---------------------------------------------------------------------------
# parameter picker: the MIDI CC submenu (spec 030 T-011)
# ---------------------------------------------------------------------------

func _register(device: Object) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	registry._devices[device.device_id] = device
	return device


func _picker_track(synth: bool, sfz_specs: Array, existing_lanes: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var made: Dictionary = project.create_instrument_track("CC Track")
	var ch: Object = made.channel
	if synth:
		var synth_dev: Object = _register(_device_script.new("test.ccmenu_syn", "ccmenu_syn", DawEnums.CATEGORY_INSTRUMENT, DawEnums.DEVICE_BUILTIN))
		synth_dev.add_parameter(_param_script.new(0, "Tone"))
		var inst: Object = _device_instance_script.new(synth_dev, ch.id, ch.devices.size())
		inst.name = "Synth"
		ch.add_device(inst)
	if not sfz_specs.is_empty():
		var sfz_dev: Object = _register(_device_script.new("sonara.builtin.sfizz", "sfizz", DawEnums.CATEGORY_INSTRUMENT, DawEnums.DEVICE_BUILTIN))
		for spec in sfz_specs:
			sfz_dev.add_parameter(_param_script.new(spec[0], spec[1]))
		var sfz: Object = _device_instance_script.new(sfz_dev, ch.id, ch.devices.size())
		sfz.name = "Sampler"
		ch.add_device(sfz)
	for lane in existing_lanes:
		made.track.add_automation_lane(lane)
	var picker: Object = _picker_script.new()
	picker.track = made.track
	picker.channel = ch
	picker._rebuild()
	return {"picker": picker, "track": made.track}


func _cc_submenu(picker: Object) -> Object:
	for i in range(picker.get_item_count()):
		if picker.get_item_text(i) == "MIDI CC":
			return picker.get_node(picker.get_item_submenu(i))
	return null


func _texts(menu: Object) -> Array:
	var out: Array = []
	for i in range(menu.get_item_count()):
		out.append(menu.get_item_text(i))
	return out


func _item_texts_with_labels(picker: Object, substrings: Array) -> bool:
	var texts: Array = _texts(_cc_submenu(picker))
	for label in texts:
		for s in substrings:
			if label.begins_with(s):
				return false
	return true


func _test_cc_menu_generic_range() -> void:
	var made := _picker_track(true, [], [])
	var picker: Object = made["picker"]
	var cc: Object = _cc_submenu(picker)
	_assert(cc != null, "the picker has a top-level MIDI CC submenu")
	if cc == null:
		picker.free()
		return
	_assert(cc.is_search_bar_enabled(), "the CC submenu is searchable")
	var texts: Array = _texts(cc)
	_assert("CC11 Expression" in texts, "CC11 is offered: %s" % str(texts))
	_assert("CC74 Cutoff" in texts, "CC74 is offered")
	_assert(_item_texts_with_labels(picker, ["CC120", "CC121", "CC122", "CC123", "CC124", "CC125", "CC126", "CC127"]),
		"channel-mode messages 120-127 are not offered")
	# A built-in synth also contributes a device submenu with its own parameters.
	_assert(_texts(picker).has("Synth"), "the built-in keeps its device submenu")
	picker.free()


func _test_cc_menu_sfz_labels_first_and_no_device_submenu() -> void:
	var made := _picker_track(false, [[73, "Attack"], [72, "Release"], [1, "Dynamics"]], [])
	var picker: Object = made["picker"]
	var cc: Object = _cc_submenu(picker)
	var texts: Array = _texts(cc)
	_assert(texts.size() >= 3, "labelled and generic entries both present: %d" % texts.size())
	_assert(texts[0] == "CC1 Dynamics" and texts[1] == "CC72 Release" and texts[2] == "CC73 Attack", "instrument labels come first: %s" % str(texts.slice(0, 3)))
	_assert(not ("CC1 Dynamics" in texts.slice(2)), "a labelled controller is not repeated in the generic list")
	_assert("CC11 Expression" in texts and "CC74 Cutoff" in texts, "CC11 and CC74 are offered for an SFZ")
	# The SFZ contributes no device submenu: every parameter it has is a controller.
	var top: Array = _texts(picker)
	_assert(not top.has("Sampler"), "the SFZ contributes no device submenu: %s" % str(top))
	_assert(top.has("MIDI CC"), "the MIDI CC entry stays")
	picker.free()


func _test_cc_menu_omits_laned_controller() -> void:
	var lane: Object = _lane_script.new("lane0", AutomationTarget.midi_cc(1))
	var made := _picker_track(false, [[1, "Dynamics"]], [lane])
	var picker: Object = made["picker"]
	var texts: Array = _texts(_cc_submenu(picker))
	_assert(not ("CC1 Dynamics" in texts), "a controller with a lane is not offered again")
	_assert("CC11 Expression" in texts, "other controllers remain")
	picker.free()


func _test_device_submenu_skips_controller_params() -> void:
	var made := _picker_track(false, [[73, "Attack"], [1, "Dynamics"]], [])
	var picker: Object = made["picker"]
	var top: Array = _texts(picker)
	_assert(top.size() == 3, "volume, pan and MIDI CC only: %s" % str(top))
	for i in range(picker.get_item_count()):
		var sub: String = picker.get_item_submenu(i)
		if sub != "":
			var submenu: Object = picker.get_node(sub)
			var texts: Array = _texts(submenu)
			_assert(not texts.has("Dynamics"), "controller parameters are not listed under their device")
	picker.free()


# ---------------------------------------------------------------------------
# lane views and shared lane creation (spec 055 T-007)
# ---------------------------------------------------------------------------

func _test_menu_uses_clip_editor_view() -> void:
	var view: Object = load("res://clip_editor/automation/ClipEditorLaneView.gd").new()
	var track := _make_menu_track()
	var lane: Object = _lane_script.new("lane0", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	var menu: Object = _menu_script.new()
	menu.track = track
	menu.view = view
	menu._rebuild()
	_assert(not menu.is_item_checked(0), "a lane that isn't open in the MIDI editor is unchecked, whatever lane.visible says")
	menu._on_id_pressed(0)
	_assert(view.is_shown(track, lane) and lane.visible, "checking opens the lane and leaves lane.visible alone")
	_assert(menu.is_item_checked(0), "the item shows the new state")
	menu._on_id_pressed(0)
	_assert(not view.is_shown(track, lane) and lane.visible, "unchecking closes the lane but keeps it and its Arranger flag")
	_assert(track.automation_lanes.has(lane), "the lane still exists")
	menu.free()


func _test_create_lane_for_opens_and_undoes() -> void:
	var project: Object = _project_script.new()
	var made: Dictionary = project.create_instrument_track("Create Track")
	var track: Object = made.track
	var view: Object = load("res://clip_editor/automation/ClipEditorLaneView.gd").new()
	var actions: GDScript = load("res://history/AutomationLanePresetActions.gd")
	var util: GDScript = load("res://history/HistoryUtil.gd")
	var recorded: Array = []
	util.test_recorder = func(cmd: Object) -> void: recorded.append(cmd)
	var lane: Object = actions.create_lane_for(track, AutomationTarget.channel_pan(), view)
	util.test_recorder = Callable()
	_assert(lane != null and track.automation_lanes.has(lane), "create_lane_for attaches the lane")
	_assert(lane.points.size() == 1, "the lane is seeded with one point")
	_assert(view.is_shown(track, lane), "the clip editor view opens the created lane")
	_assert(recorded.size() == 1, "one history entry (%d)" % recorded.size())
	if not recorded.is_empty():
		recorded[0].undo()
	_assert(not track.automation_lanes.has(lane), "one undo removes the lane")
	_assert(track.clip_editor_lanes.is_empty(), "and its open-lane entry")


func _test_create_lane_for_redo_reopens() -> void:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Redo Track").track
	var view: Object = load("res://clip_editor/automation/ClipEditorLaneView.gd").new()
	var util: GDScript = load("res://history/HistoryUtil.gd")
	var recorded: Array = []
	util.test_recorder = func(cmd: Object) -> void: recorded.append(cmd)
	var lane: Object = load("res://history/AutomationLanePresetActions.gd").create_lane_for(track, AutomationTarget.channel_pan(), view)
	util.test_recorder = Callable()
	if recorded.is_empty():
		_assert(false, "create_lane_for records a step")
		return
	recorded[0].undo()
	recorded[0].do()
	_assert(track.automation_lanes.has(lane) and view.is_shown(track, lane), "redo re-attaches the lane and reopens it in the MIDI editor")


# ---------------------------------------------------------------------------
# presets section (spec 055 T-016)
# ---------------------------------------------------------------------------

func _preset_menu(track: Object, view: Object) -> Object:
	var menu: Object = _menu_script.new()
	menu.track = track
	menu.view = view
	menu._rebuild()
	return menu


func _test_presets_section() -> void:
	var store: GDScript = load("res://data/AutomationLanePresets.gd")
	for preset_name in store.names():
		store.delete(preset_name)
	var views := {
		"arranger": load("res://arranger/tracklist/ArrangerLaneView.gd").new(),
		"clip editor": load("res://clip_editor/automation/ClipEditorLaneView.gd").new(),
	}
	for kind in views:
		var view: Object = views[kind]
		var track := _make_menu_track()
		var lane: Object = _lane_script.new("lane0", AutomationTarget.channel_volume())
		track.add_automation_lane(lane)
		view.apply_shown(track, [])
		var menu := _preset_menu(track, view)
		var save_id: int = menu.SAVE_PRESET_ID
		_assert(menu.is_item_disabled(menu.get_item_index(save_id)), "%s: save is disabled with no shown lanes" % kind)
		menu.free()
		view.apply_shown(track, [lane])
		store.delete("Strings")
		store.save("Strings", [{"target": "channel/cc/1", "device_id": ""}])
		menu = _preset_menu(track, view)
		_assert(_texts(menu).has("Strings"), "%s: a stored preset is listed: %s" % [kind, str(_texts(menu))])
		_assert(not menu.is_item_disabled(menu.get_item_index(save_id)), "%s: save is enabled with a shown lane" % kind)
		_assert(_texts(menu).has("Delete preset"), "%s: a delete submenu is offered" % kind)
		store.save("Late", [{"target": "channel/pan", "device_id": ""}])
		menu._rebuild()
		_assert(_texts(menu).has("Late"), "%s: the store is re-read on rebuild" % kind)
		menu.free()
		store.delete("Strings")
		store.delete("Late")
