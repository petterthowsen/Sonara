## DeviceView - Abstract base class for all device visual scenes
##
## Provides lifecycle hooks for subscription management and device binding.
## Subclasses must implement _on_bind() to handle device-specific setup.

@abstract class_name DeviceView extends Control

var device: DeviceInstance
var channel_id: int
var device_position: int


## Bind this view to a device instance
## Subclasses should override _on_bind() for device-specific setup
func bind_to_device(dev_instance: DeviceInstance) -> void:
	device = dev_instance
	channel_id = dev_instance.channel_id
	device_position = dev_instance.position

	# auomatically listen to parameter changes
	device.parameter_changed.connect(_on_device_parameter_changed)

	_on_bind()


## Override this in subclasses to handle binding
## Called after device_instance, channel_id, and device_position are set
@abstract func _on_bind() -> void

## Called when view becomes visible (subscribe to data streams)
## Override to subscribe to device data (e.g., spectrum, oscilloscope)
func _on_view_shown() -> void:
	pass


## Called when view becomes hidden (unsubscribe)
## Override to unsubscribe from device data
func _on_view_hidden() -> void:
	pass

## Called when a device parameter changes
## Override to handle parameter changes
func _on_device_parameter_changed(param_id: int, value: float) -> void:
	pass
