## Every child of a Layer or Drum Machine is a **slot chain**: a Chain device that holds the slot's
## devices, so each slot takes any number of devices, like a channel's own chain. The slot's mix
## controls (volume/mute/solo), its pad note and its pad return stay on the slot chain. The engine
## needs nothing special: it is an ordinary Chain inside the container.
## DeviceAddCommand wraps a device added straight into a Layer or Drum Machine (`for_parent`), and
## projects saved before slot chains are wrapped on load (`DeviceInstance.from_json`).
class_name SlotChain extends RefCounted

const CHAIN_ID := "sonara.builtin.chain"


## True when children of `parent` must be slot chains (Layer, Drum Machine).
static func is_slot_parent(parent: DeviceInstance) -> bool:
	return parent != null and parent.device != null and parent.device.container_focuses_one_child()


## True for a Chain instance.
static func is_chain(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id == CHAIN_ID


## True for a child of a Layer or Drum Machine (the slot's own Chain).
static func is_slot_chain(inst: DeviceInstance) -> bool:
	return inst != null and is_slot_parent(inst.get_parent_device())


## What to add into `parent` for `inst`: `inst` itself, or a new slot chain holding it when
## `parent` is a Layer or Drum Machine and `inst` isn't a Chain already.
static func for_parent(parent: DeviceInstance, inst: DeviceInstance) -> DeviceInstance:
	if not is_slot_parent(parent) or inst == null or is_chain(inst):
		return inst
	return wrap_device(inst)


## New slot chain named after `inst`, holding it. `inst`'s slot controls move to the chain.
## Returns `inst` unchanged when no Chain device is registered.
static func wrap_device(inst: DeviceInstance) -> DeviceInstance:
	var chain := empty(inst.channel_id, inst.get_display_name())
	if chain == null:
		return inst
	chain.slot_volume = inst.slot_volume
	chain.slot_mute = inst.slot_mute
	chain.slot_solo = inst.slot_solo
	chain.slot_note = inst.slot_note
	chain.return_channel_id = inst.return_channel_id
	inst.slot_volume = 0.5
	inst.slot_mute = false
	inst.slot_solo = false
	inst.slot_note = -1
	inst.return_channel_id = -1
	inst.position = 0
	inst.set_parent_device(chain)
	chain.children.append(inst)
	return chain


## New slot chain with no devices, or null when no Chain device is registered. Its own slot starts
## open, so a pad lane shows the pad's devices beside it.
static func empty(channel_id: int, chain_name: String) -> DeviceInstance:
	var device := AssetService.get_device(CHAIN_ID)
	if device == null:
		push_warning("[SlotChain] No Chain device registered; slot left unwrapped")
		return null
	var chain := DeviceInstance.new(device, channel_id, -1)
	chain.name = chain_name
	chain.set_slot_open(DeviceInstance.CHAIN_SLOT, true)
	return chain
