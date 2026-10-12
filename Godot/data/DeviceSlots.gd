## Device slots (spec 040): fixed, named slot chains built into the PolySynth, Delay and Reverb.
## The engine owns the chains. It advertises them in `/builtin/info` (`Device.slots`: `{key, name,
## kind}` with kind "note", "audio" or "loop"), and Godot mirrors them as children of the
## `DeviceInstance` in spec order, but never sends `add_device`, `remove_device` or `move_device`
## for a slot chain itself. Devices inside a slot use the ordinary `{device}/child/{slot}` paths.
## This class is the single source for slot behaviour, like `Multiband` for the band chains.
class_name DeviceSlots extends RefCounted

const KIND_NOTE := "note"
const KIND_AUDIO := "audio"
const KIND_LOOP := "loop"


## True when `inst` is a built-in device with device slots.
static func is_slotted(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.has_device_slots()


## The slot specs `{key, name, kind}` of `inst`, in slot order (empty for a plain device).
static func specs(inst: DeviceInstance) -> Array[Dictionary]:
	if not is_slotted(inst):
		return [] as Array[Dictionary]
	return inst.device.slots


## Index of the slot chain `chain` in its slotted parent, or -1.
static func slot_index(chain: DeviceInstance) -> int:
	if chain == null:
		return -1
	var parent := chain.get_parent_device()
	if not is_slotted(parent):
		return -1
	return parent.children.find(chain)


## True for the engine-owned slot chain of a slotted device (a direct child of one).
static func is_slot_chain(inst: DeviceInstance) -> bool:
	var index := slot_index(inst)
	return index >= 0 and index < specs(inst.get_parent_device()).size()


## The spec `{key, name, kind}` of slot chain `chain`, or an empty Dictionary.
static func spec_of(chain: DeviceInstance) -> Dictionary:
	if not is_slot_chain(chain):
		return {}
	return specs(chain.get_parent_device())[slot_index(chain)]


## The slot kind that governs a device added into `host`: the kind of the innermost device slot
## chain at or above `host` ("note", "audio" or "loop"), or "" when `host` isn't inside a slot.
static func kind_for_host(host: DeviceInstance) -> String:
	var current := host
	while current != null:
		if is_slot_chain(current):
			return String(spec_of(current).get("kind", ""))
		current = current.get_parent_device()
	return ""


## True when a device of the registry entry `device` may live in a slot of `kind`. An empty kind
## accepts everything. Containers are judged by their own category only; use `accepts_instance`
## for the devices inside them.
static func accepts(kind: String, device: Device) -> bool:
	if kind.is_empty():
		return true
	if device == null:
		return false
	match kind:
		KIND_NOTE:
			return device.is_note_effect()
		KIND_AUDIO:
			return device.category != Device.DeviceCategory.Instrument and not device.is_note_effect()
		KIND_LOOP:
			return accepts(KIND_AUDIO, device) and not device.is_plugin()
	return true


## `accepts` for a device instance and, recursively, every device inside it.
static func accepts_instance(kind: String, inst: DeviceInstance) -> bool:
	if kind.is_empty():
		return true
	if inst == null or not accepts(kind, inst.device):
		return false
	for child in inst.children:
		if not accepts_instance(kind, child):
			return false
	return true


## The slot chain a device dropped *onto* slotted device `inst` goes into: the open slot if it
## accepts `device`, else the first slot that does, else null (nothing fits, so the drop is refused).
static func target_chain(inst: DeviceInstance, device: Device) -> DeviceInstance:
	if not is_slotted(inst):
		return null
	for key in inst.open_slot_keys():
		var open := inst.slot_chain(key)
		if open != null and accepts(String(spec_of(open).get("kind", "")), device):
			return open
	for chain in inst.children:
		if is_slot_chain(chain) and accepts(String(spec_of(chain).get("kind", "")), device):
			return chain
	return null


## True when some slot of `inst` takes `device`.
static func has_slot_for(inst: DeviceInstance, device: Device) -> bool:
	return target_chain(inst, device) != null


## Fixed colour of a slot of `kind`: the secondary accent for note slots, the primary accent for
## audio and loop slots (REQ-021).
static func role_color(kind: String) -> Color:
	return UiColors.role(&"accent_secondary" if kind == KIND_NOTE else &"accent_primary")


## Give `inst` exactly its device slots: saved chains are adopted by spec name, then by position,
## missing ones are created empty, and the children are ordered and named by spec (REQ-001,
## REQ-030). Saved children that no spec claims are dropped. No-op for other devices.
static func ensure_chains(inst: DeviceInstance) -> void:
	if not is_slotted(inst):
		return
	var wanted := specs(inst)
	var pool: Array[DeviceInstance] = []
	pool.assign(inst.children)
	var ordered: Array[DeviceInstance] = []
	for spec in wanted:
		var found: DeviceInstance = null
		for child in pool:
			if child.name == String(spec["name"]):
				found = child
				break
		ordered.append(found)
		if found != null:
			pool.erase(found)
	for i in ordered.size():
		if ordered[i] == null and not pool.is_empty():
			ordered[i] = pool.pop_front()
		if ordered[i] == null:
			ordered[i] = SlotChain.empty(inst.channel_id, String(wanted[i]["name"]))
		if ordered[i] == null:
			return  # no Chain device registered (yet): leave the instance alone
	inst.children.clear()
	for i in ordered.size():
		var chain := ordered[i]
		chain.name = String(wanted[i]["name"])
		chain.position = i
		chain.set_parent_device(inst)
		inst.children.append(chain)
