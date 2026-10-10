# AutomationParameterPicker.gd
# The "what should this lane drive?" dropdown (REQ-015, REQ-016). Built from the track's linked
# Channel: channel volume, pan, a top-level MIDI CC submenu (spec 030), one entry per send, then
# one submenu per device in `channel.devices` order carrying that device's `"param"` group and,
# per modulator (spec 018), its parameters, as separate groups.
#
# Two kinds of entry are left out: a parameter whose `is_automation_safe` is false (the device
# says driving it from the audio thread is unsafe), and a parameter that already has a lane on
# this track - one target, one lane.
class_name AutomationParameterPicker extends PopupMenu

static var logger := Log.make("AutomationParameterPicker")

## The chosen target. The caller creates the lane, so this stays free of history concerns.
signal parameter_chosen(track: Track, target: AutomationTarget)

## Item ids in the root menu. Device and modulator parameters live in submenus and carry their
## own ids; their targets travel as item metadata.
const ID_VOLUME := 0
const ID_PAN := 1
const ID_SEND_BASE := 100

var track: Track = null
var channel: Channel = null

## Submenu -> the device path its entries address, so one handler serves every device.
var _submenu_paths: Dictionary = {}
## Next unique id handed to a device/modulator parameter item in the submenus.
var _next_item_id: int = 1000


func _ready() -> void:
	theme_type_variation = &"ContextMenuList"
	if not id_pressed.is_connected(_on_root_id_pressed):
		id_pressed.connect(_on_root_id_pressed)


## Rebuild for `p_track` and pop up at `global_position`. Does nothing when the track has no
## linked channel - there is nothing to automate.
func open_for(p_track: Track, global_position: Vector2) -> void:
	track = p_track
	channel = track.get_linked_channel() if track else null
	if channel == null:
		logger.warn("No linked channel for track %s; nothing to automate" % (track.name if track else "<null>"))
		return
	_rebuild()
	if get_item_count() == 0:
		logger.info("Every automatable parameter on %s already has a lane" % track.name)
		return
	popup(Rect2(global_position, Vector2.ZERO))


func _rebuild() -> void:
	# free_submenus so a rebuild doesn't leak the previous run's submenu nodes.
	clear(true)
	_submenu_paths.clear()
	_next_item_id = 1000

	if not _has_lane(AutomationTarget.channel_volume()):
		add_item("Volume", ID_VOLUME)
	if not _has_lane(AutomationTarget.channel_pan()):
		add_item("Pan", ID_PAN)

	_add_cc_menu()

	var send_items := 0
	for i in range(channel.send_channels.size()):
		var target := AutomationTarget.send_amount(i)
		if _has_lane(target):
			continue
		if send_items == 0:
			add_separator("Sends")
		send_items += 1
		add_item(target.display_name(channel), ID_SEND_BASE + i)

	for i in range(channel.devices.size()):
		_add_device(channel.devices[i], [i])


## The top-level `MIDI CC` submenu (spec 030): instrument-labelled controllers first (an SFZ
## sampler contributes labels through its controller parameters), then CC0-CC119 named by
## `Midi.cc_display_name`. Searchable like the device submenus; controllers that already have a
## lane on this track are omitted, and labelled ones don't repeat in the generic list.
func _add_cc_menu() -> void:
	var labelled: Array = []
	var labelled_ids: Dictionary = {}
	for instance in AutomationTarget._devices_recursive(channel.devices):
		for param in instance.get_parameters():
			if param.id < 0 or param.id > Midi.CC_LANE_MAX or not param.is_automation_safe:
				continue
			if not instance.is_controller_parameter(param) or param.name == "":
				continue
			if labelled_ids.has(param.id):
				continue
			var target := AutomationTarget.midi_cc(param.id)
			if _has_lane(target):
				continue
			labelled.append({"cc": param.id, "label": Midi.cc_display_name(param.id, param.name), "target": target})
			labelled_ids[param.id] = true
	labelled.sort_custom(func(a, b): return a["cc"] < b["cc"])

	var generic: Array = []
	for cc in range(Midi.CC_LANE_MAX + 1):
		if labelled_ids.has(cc) or _has_lane(AutomationTarget.midi_cc(cc)):
			continue
		generic.append({"cc": cc, "label": Midi.cc_display_name(cc), "target": AutomationTarget.midi_cc(cc)})

	var entries: int = labelled.size() + generic.size()
	if entries == 0:
		return
	var submenu := PopupMenu.new()
	submenu.theme_type_variation = &"ContextMenuList"
	submenu.set_search_bar_enabled(true)
	for entry in labelled:
		_add_target_item(submenu, entry["label"], entry["target"])
	if not labelled.is_empty() and not generic.is_empty():
		submenu.add_separator()
	for entry in generic:
		_add_target_item(submenu, entry["label"], entry["target"])
	submenu.id_pressed.connect(_on_device_id_pressed.bind(submenu))
	add_submenu_node_item("MIDI CC", submenu)


## Add one submenu for `instance` (and, recursively, for its children so rack/drum-machine slots
## are reachable). A device with nothing automatable left contributes no entry at all.
func _add_device(instance: DeviceInstance, path: Array) -> void:
	if instance == null:
		return

	var submenu := PopupMenu.new()
	submenu.theme_type_variation = &"ContextMenuList"
	submenu.name = "Device%s" % "_".join(PackedStringArray(path.map(func(i): return str(i))))
	# CLAP plugins can expose hundreds of parameters; let the user type to narrow them down.
	submenu.set_search_bar_enabled(true)
	var entries := 0

	entries += _add_param_group(submenu, instance, path, "param", "")
	for mod in instance.modulators:
		entries += _add_modulator_group(submenu, instance, path, mod)

	for child_index in range(instance.children.size()):
		_add_device(instance.children[child_index], path + [child_index])

	if entries == 0:
		submenu.queue_free()
		return

	submenu.id_pressed.connect(_on_device_id_pressed.bind(submenu))
	_submenu_paths[submenu] = path.duplicate()
	add_submenu_node_item(instance.name, submenu)


## Append `instance`'s parameters in `group` to `submenu`, skipping unsafe and already-automated
## ones. Controller parameters never appear here: they live in the top-level MIDI CC submenu
## (spec 030).
func _add_param_group(submenu: PopupMenu, instance: DeviceInstance, path: Array,
		group: String, separator_label: String) -> int:
	var added := 0
	for param in instance.get_parameters_in_group(group):
		if not param.is_automation_safe or instance.is_controller_parameter(param):
			continue
		var target := AutomationTarget.device_param(path, param.id)
		if _has_lane(target):
			continue
		if added == 0 and not separator_label.is_empty():
			submenu.add_separator(separator_label)
		_add_target_item(submenu, AutomationTarget.param_label(instance, param), target)
		added += 1
	return added


## Append one modulator's parameters under its name (spec 018), skipping ones already automated.
func _add_modulator_group(submenu: PopupMenu, instance: DeviceInstance, path: Array, mod: Modulator) -> int:
	var added := 0
	for param in mod.get_parameters():
		if not param.is_automation_safe:
			continue
		var target := AutomationTarget.device_modulator_param(path, mod.mod_id, param.id)
		if _has_lane(target):
			continue
		if added == 0:
			submenu.add_separator(mod.name)
		_add_target_item(submenu, param.name, target)
		added += 1
	return added


## One item with a unique id and its `AutomationTarget` as metadata.
func _add_target_item(submenu: PopupMenu, label: String, target: AutomationTarget) -> void:
	submenu.add_item(label, _next_item_id)
	submenu.set_item_metadata(submenu.get_item_count() - 1, target)
	_next_item_id += 1


## True when `track` already has a lane driving `target` (REQ-015).
func _has_lane(target: AutomationTarget) -> bool:
	return track != null and track.get_automation_lane_for(target) != null


func _on_root_id_pressed(id: int) -> void:
	var target: AutomationTarget = null
	if id == ID_VOLUME:
		target = AutomationTarget.channel_volume()
	elif id == ID_PAN:
		target = AutomationTarget.channel_pan()
	elif id >= ID_SEND_BASE:
		target = AutomationTarget.send_amount(id - ID_SEND_BASE)
	if target:
		_emit(target)


func _on_device_id_pressed(id: int, submenu: PopupMenu) -> void:
	var index := submenu.get_item_index(id)
	if index < 0:
		return
	var target: AutomationTarget = submenu.get_item_metadata(index)
	if target == null:
		return
	_emit(target)


func _emit(target: AutomationTarget) -> void:
	hide()
	logger.info("Automate %s on track %s" % [str(target), track.name if track else "<null>"])
	parameter_chosen.emit(track, target)
