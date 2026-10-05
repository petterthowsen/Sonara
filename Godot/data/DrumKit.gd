## The Drum Machine's "Synth Kit" preset (spec 013, Phase 4 wrap-up): the four drum voices laid
## out on their GM note numbers, with the two hats choking each other so a closed hat silences
## the open one. The notes are the GM numbers, which are the same whatever the octave naming.
##
## The two hats are the same device with different Decay, so the preset also sets that parameter:
## a kit of five identical hats would not play a pattern.

class_name DrumKit extends RefCounted

const DRUM_MACHINE_ID := "sonara.builtin.drum_machine"
## Hat Decay (parameters.rs ID 11).
const HAT_DECAY := 11

## One pad: `id` is the built-in device, `note` its GM note, `name` the pad's display name,
## `choke` (optional) the names of the kit pads it chokes and `decay` (optional) the drum's own
## Decay in seconds.
const SYNTH_KIT: Array[Dictionary] = [
	{"id": "sonara.builtin.kick", "note": 36, "name": "Kick"},
	{"id": "sonara.builtin.snare", "note": 38, "name": "Snare"},
	{"id": "sonara.builtin.clap", "note": 39, "name": "Clap"},
	{"id": "sonara.builtin.hat", "note": 42, "name": "Closed Hat", "choke": ["Open Hat"], "decay": 0.06},
	{"id": "sonara.builtin.hat", "note": 46, "name": "Open Hat", "choke": ["Closed Hat"], "decay": 0.6},
]


## True when `inst` is a Drum Machine.
static func is_drum_machine(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id == DRUM_MACHINE_ID


## Add the kit's pads to `drum_machine` on `channel`, as one history entry. `registry` defaults to
## the running AssetService's device registry. Returns the slot chains added (empty when a drum
## device is not registered).
static func apply(
	channel: Channel,
	drum_machine: DeviceInstance,
	registry: Object = null
) -> Array[DeviceInstance]:
	var pads: Array[DeviceInstance] = []
	if channel == null or not is_drum_machine(drum_machine):
		return pads
	if registry == null:
		registry = device_registry()

	var cmds: Array[Command] = []
	var entries: Array[Dictionary] = []
	for entry in SYNTH_KIT:
		var device: Device = registry.get_device(entry.id) if registry else null
		if device == null:
			push_warning("[DrumKit] Device %s is not registered; skipping its pad" % entry.id)
			continue
		var inst := DeviceInstance.new(device, channel.id, -1)
		inst.name = entry.name
		# The note travels onto the slot chain the add wraps this in (see SlotChain.wrap_device).
		inst.slot_note = entry.note
		var cmd := DeviceAddCommand.new(channel, inst, -1, drum_machine)
		cmds.append(cmd)
		pads.append(cmd.device_instance)
		entries.append(entry)

	# Choke targets are pad ids, so resolve the kit's pad names once every slot chain exists. They
	# are set before the add, so they reach the engine with the pads and undo with them.
	var by_name := {}
	for i in range(pads.size()):
		by_name[entries[i].name] = pads[i]
	for i in range(pads.size()):
		var targets := PackedStringArray()
		for target_name in entries[i].get("choke", []):
			if by_name.has(target_name):
				targets.append(by_name[target_name].id)
		pads[i].choke_targets = targets

	HistoryUtil.execute_many("Load Synth Kit", cmds)

	# The pads exist now; set each drum's Decay (the open hat rings, the closed one doesn't).
	for i in range(pads.size()):
		var decay: float = entries[i].get("decay", 0.0)
		if decay > 0.0:
			_set_real_param(pads[i], HAT_DECAY, decay)
	return pads


## The AssetService device registry through the tree, so this script never needs the autoload as
## a bare identifier (which a headless test script cannot resolve).
static func device_registry() -> Object:
	var loop := Engine.get_main_loop()
	if not loop is SceneTree:
		return null
	var service := (loop as SceneTree).root.get_node_or_null("AssetService")
	return service.device_registry if service != null else null


## Set parameter `id` on the drum inside pad `pad` to the real value `value`.
static func _set_real_param(pad: DeviceInstance, id: int, value: float) -> void:
	var target: DeviceInstance = pad
	if target.children.size() > 0:
		target = target.children[0]
	var param := target.get_parameter(id)
	if param == null:
		return
	target.set_parameter_normalized(id, param.value_to_normalized(value))
