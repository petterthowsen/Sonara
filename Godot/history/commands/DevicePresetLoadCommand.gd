# DevicePresetLoadCommand.gd
# Undoable "load preset into this device": replaces `old_device` with a fresh preset instance at the
# same parent and position. Both instances keep their identity, so undo and redo swap them back.
# What belongs to the slot the device sits in (mix, pad note, choke, note map, separate out and the
# pad/slot return) carries over from the old device; a name the user typed is kept.
class_name DevicePresetLoadCommand extends Command

var channel: Channel = null
var old_device: DeviceInstance = null
var new_device: DeviceInstance = null
var parent: DeviceInstance = null
var position: int = -1

var _carried := false


func _init(p_channel: Channel = null, p_old: DeviceInstance = null, p_new: DeviceInstance = null) -> void:
	name = "Load Preset"
	channel = p_channel
	old_device = p_old
	new_device = p_new
	if old_device != null:
		parent = old_device.get_parent_device()
		var host: Array[DeviceInstance] = parent.children if parent else channel.devices
		position = host.find(old_device)


## True when `inst_name` is the device's own name, alone or with a uniqueness suffix ("Delay 2").
static func has_default_name(inst: DeviceInstance) -> bool:
	if inst.name.is_empty() or inst.device == null:
		return true
	var base := inst.device.name
	if inst.name == base:
		return true
	return inst.name.begins_with(base + " ") and inst.name.substr(base.length() + 1).is_valid_int()


func do() -> void:
	if channel == null or old_device == null or new_device == null:
		return
	if not _carried:
		_carry_context()
		_carried = true
	var host: Array[DeviceInstance] = parent.children if parent else channel.devices
	var idx := host.find(old_device)
	if idx >= 0:
		position = idx
		channel.remove_device(idx, parent)
	_pass_slot_return()
	channel.add_device(new_device, position, parent)
	# Sibling pads target pads by id, so point them at the new instance.
	if parent != null:
		parent.replace_choke_target_id(old_device.id, new_device.id)


func undo() -> void:
	if channel == null or old_device == null or new_device == null:
		return
	channel.remove_device_instance(new_device)
	channel.add_device(old_device, position, parent)
	if parent != null:
		parent.replace_choke_target_id(new_device.id, old_device.id)


## Slot fields and the user's own name move to the new instance (first run only).
func _carry_context() -> void:
	new_device.slot_volume = old_device.slot_volume
	new_device.slot_mute = old_device.slot_mute
	new_device.slot_solo = old_device.slot_solo
	new_device.slot_note = old_device.slot_note
	new_device.choke_targets = old_device.choke_targets.duplicate()
	new_device.slot_note_map = old_device.slot_note_map.duplicate()
	new_device.slot_separate_out = old_device.slot_separate_out
	new_device.return_channel_id = old_device.return_channel_id
	if not has_default_name(old_device):
		new_device.name = old_device.name


## A removed slot (Layer) detaches its return onto itself; hand it to the replacement so
## AuxReturnSync re-adopts it instead of creating a blank one.
func _pass_slot_return() -> void:
	var id := old_device.return_channel_id
	if id >= 0 and old_device.detached_returns.has(id):
		new_device.detached_returns[id] = old_device.detached_returns[id]
