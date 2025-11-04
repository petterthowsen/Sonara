class_name MidiDevice
extends RefCounted

## Represents a MIDI input device (physical or virtual keyboard).


enum DeviceType {
	PHYSICAL,           # Hardware MIDI controller/keyboard
	VIRTUAL_KEYBOARD    # Computer keyboard emulation
}


var device_id: int
var device_name: String
var device_type: DeviceType
var enabled: bool = false


func _init(id: int, name: String, type: DeviceType):
	device_id = id
	device_name = name
	device_type = type


func is_virtual_keyboard() -> bool:
	return device_type == DeviceType.VIRTUAL_KEYBOARD
