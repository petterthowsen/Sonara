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
	_test_add_new_with_no_lanes()
	_test_lane_toggle_and_add_new_together()
	_test_cc_menu_generic_range()
	_test_cc_menu_sfz_labels_first_and_no_device_submenu()
	_test_cc_menu_omits_laned_controller()
	_test_device_submenu_skips_controller_params()


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
	_assert(menu.get_item_count() == 1, "empty track shows only '+ Add new'")
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
	_assert(menu.get_item_count() == 3, "lane checkbox + separator + '+ Add new'")
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
