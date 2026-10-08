## Note effects (spec 027): MIDI-processing devices that sit before an instrument in a chain, plus
## the two note containers (Note Layer, Note Selector) whose branches hold only note effects.
## Static helpers for the places that treat them differently from audio devices: drop rules,
## the Layer slot "Out" row and the device lane. A device is a note effect through its
## `Device.DeviceCategory.NoteEffect` category; note containers are note effects too.
class_name NoteFx extends RefCounted

const CONTAINER_IDS: Array[String] = ["sonara.builtin.note_layer", "sonara.builtin.note_selector"]


## True when `inst` is a Note Layer or Note Selector.
static func is_note_container(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id in CONTAINER_IDS


## True for a branch of a note container (its slot chain).
static func is_note_branch(inst: DeviceInstance) -> bool:
	return inst != null and SlotChain.is_chain(inst) and is_note_container(inst.get_parent_device())


## True when `host` (a drop target parent; null = channel root) is a note container, one of its
## branches, or sits anywhere inside one.
static func is_inside_note_container(host: DeviceInstance) -> bool:
	while host != null:
		if is_note_container(host):
			return true
		host = host.get_parent_device()
	return false


## True when `host` is a Multiband FX or sits anywhere inside one of its bands. No notes arrive there.
static func is_inside_multiband(host: DeviceInstance) -> bool:
	while host != null:
		if Multiband.is_multiband(host):
			return true
		host = host.get_parent_device()
	return false


## True when `inst` is a note effect or holds one anywhere in its children (a Chain of note effects).
static func contains_note_effect(inst: DeviceInstance) -> bool:
	if inst == null:
		return false
	if inst.device != null and inst.device.is_note_effect():
		return true
	for child in inst.children:
		if contains_note_effect(child):
			return true
	return false


## How many note effects lead `devices` (a chain, in order). The instrument and everything after
## the first non-note-effect device don't count.
static func leading_note_effect_count(devices: Array) -> int:
	var count := 0
	for inst in devices:
		if inst == null or inst.device == null or not inst.device.is_note_effect():
			break
		count += 1
	return count
