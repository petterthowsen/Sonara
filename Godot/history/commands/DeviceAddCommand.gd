# DeviceAddCommand.gd
# Undoable addition of a DeviceInstance to a Channel (keeps instance identity). A device added
# straight into a Layer or Drum Machine goes in wrapped in a new slot chain (SlotChain.for_parent);
# `device_instance` is then that slot chain. A device added straight into a slotted device (PolySynth,
# Delay, Reverb) goes into the slot that takes it, and `device_instance` stays null when none does or
# when the slot's kind refuses the device.
class_name DeviceAddCommand extends Command

## Channel that receives the device.
var channel: Channel = null

## Device instance being added.
var device_instance: DeviceInstance = null

## Insertion position (-1 = append).
var position: int = -1

## Container parent, or null to insert at the channel root.
var parent: DeviceInstance = null


## Create an add-device command.
func _init(
	p_channel: Channel = null,
	p_device: DeviceInstance = null,
	p_position: int = -1,
	p_parent: DeviceInstance = null
) -> void:
	name = "Add Device"
	channel = p_channel
	position = p_position
	parent = p_parent
	if Multiband.is_multiband(parent) and not Multiband.is_band_chain(p_device):
		# A Multiband FX always has its six band chains: the device goes into one of them.
		var band := Multiband.target_chain(parent)
		if band != null:
			parent = band
			position = -1
	var refused := false
	if DeviceSlots.is_slotted(parent):
		# A slotted device's chains are fixed: the device goes into the slot that takes it
		# (the open one first), and nothing is added when no slot does (spec 040 REQ-014..018).
		parent = DeviceSlots.target_chain(parent, p_device.device) if p_device != null else null
		position = -1
		refused = parent == null
	if parent != null and p_device != null and not DeviceSlots.accepts_instance(DeviceSlots.kind_for_host(parent), p_device):
		refused = true  # the slot's kind refuses it, or a device inside it
	if refused:
		device_instance = null  # do() and undo() become no-ops
		return
	device_instance = SlotChain.for_parent(parent, p_device)


## Add the device at the stored position.
func do() -> void:
	if channel == null or device_instance == null:
		return
	channel.add_device(device_instance, position, parent)


## Remove the device by its current parent/position.
func undo() -> void:
	if channel == null or device_instance == null:
		return
	channel.remove_device_instance(device_instance)
