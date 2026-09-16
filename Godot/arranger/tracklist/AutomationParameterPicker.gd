# AutomationParameterPicker.gd
# The "what should this lane drive?" dropdown (REQ-015, REQ-016). Built from the track's linked
# Channel: channel volume, pan, one entry per send, then one submenu per device in
# `channel.devices` order carrying that device's `"param"` group and its `"cc"` group as two
# separate groups.
#
# Two kinds of entry are left out: a parameter whose `is_automation_safe` is false (the device
# says driving it from the audio thread is unsafe), and a parameter that already has a lane on
# this track - one target, one lane.
class_name AutomationParameterPicker extends PopupMenu

static var logger := Log.make("AutomationParameterPicker")

## The chosen target. The caller creates the lane, so this stays free of history concerns.
signal parameter_chosen(track: Track, target: AutomationTarget)

## Item ids in the root menu. Device parameters live in submenus and carry their own ids.
const ID_VOLUME := 0
const ID_PAN := 1
const ID_SEND_BASE := 100

var track: Track = null
var channel: Channel = null

## Submenu -> the device path its entries address, so one handler serves every device.
var _submenu_paths: Dictionary = {}


func _ready() -> void:
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

	if not _has_lane(AutomationTarget.channel_volume()):
		add_item("Volume", ID_VOLUME)
	if not _has_lane(AutomationTarget.channel_pan()):
		add_item("Pan", ID_PAN)

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


## Add one submenu for `instance` (and, recursively, for its children so rack/drum-machine slots
## are reachable). A device with nothing automatable left contributes no entry at all.
func _add_device(instance: DeviceInstance, path: Array) -> void:
	if instance == null:
		return

	var submenu := PopupMenu.new()
	submenu.name = "Device%s" % "_".join(PackedStringArray(path.map(func(i): return str(i))))
	# CLAP plugins can expose hundreds of parameters; let the user type to narrow them down.
	submenu.set_search_bar_enabled(true)
	var entries := 0

	entries += _add_param_group(submenu, instance, path, "param", "")
	entries += _add_param_group(submenu, instance, path, "cc", "CC")

	for child_index in range(instance.children.size()):
		_add_device(instance.children[child_index], path + [child_index])

	if entries == 0:
		submenu.queue_free()
		return

	submenu.id_pressed.connect(_on_device_id_pressed.bind(submenu))
	_submenu_paths[submenu] = path.duplicate()
	add_submenu_node_item(instance.name, submenu)


## Append `instance`'s parameters in `group` to `submenu`, skipping unsafe and already-automated
## ones. Returns how many were added. CC entries are named through `Midi.cc_display_name` so an
## unlabelled CC still reads as `CC1 Mod Wheel` rather than a bare number (REQ-016).
func _add_param_group(submenu: PopupMenu, instance: DeviceInstance, path: Array,
		group: String, separator_label: String) -> int:
	var added := 0
	for param in instance.get_parameters_in_group(group):
		if not param.is_automation_safe:
			continue
		if _has_lane(AutomationTarget.device_param(path, param.id)):
			continue
		if added == 0 and not separator_label.is_empty():
			submenu.add_separator(separator_label)
		var label: String = param.name
		if group == "cc":
			label = Midi.cc_display_name(param.id, param.name)
		submenu.add_item(label, param.id)
		added += 1
	return added


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


func _on_device_id_pressed(param_id: int, submenu: PopupMenu) -> void:
	var path: Array = _submenu_paths.get(submenu, [])
	if path.is_empty():
		return
	_emit(AutomationTarget.device_param(path, param_id))


func _emit(target: AutomationTarget) -> void:
	hide()
	logger.info("Automate %s on track %s" % [str(target), track.name if track else "<null>"])
	parameter_chosen.emit(track, target)
