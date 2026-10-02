# DeviceAddCommand.gd
# Undoable addition of a DeviceInstance to a Channel (keeps instance identity). A device added
# straight into a Layer or Drum Machine goes in wrapped in a new slot chain (SlotChain.for_parent);
# `device_instance` is then that slot chain.
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
