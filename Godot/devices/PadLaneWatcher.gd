# PadLaneWatcher.gd
# Emits `changed` (once per frame) when a drum pad (or Layer slot) return's lane may look
# different: its own devices, the Drum Machine's or Layer's children, the parent channel's devices,
# or its nesting changed.
# Views that list a channel's devices bind one and rebuild from PadLane.devices() while active().
class_name PadLaneWatcher extends RefCounted

signal changed

var channel: Channel = null

## [Signal, Callable] pairs currently connected.
var _connections: Array = []
var _queued := false


## Watch `p_channel` (null stops watching).
func bind(p_channel: Channel) -> void:
	_disconnect_all()
	channel = p_channel
	if channel == null:
		return
	_watch(channel.hierarchy_changed, _on_changed)
	_watch(channel.device_added, _on_changed.unbind(2))
	_watch(channel.device_removed, _on_changed.unbind(2))
	_watch(channel.device_moved, _on_changed.unbind(2))
	var project := channel.get_project()
	if project == null or channel.parent_channel_id < 0:
		return
	var parent := project.get_channel_by_id(channel.parent_channel_id)
	if parent == null:
		return
	_watch(parent.device_added, _on_changed.unbind(2))
	_watch(parent.device_removed, _on_changed.unbind(2))
	var drum := AuxReturnSync.get_pad_drum(channel)
	if drum:
		_watch(drum.child_added, _on_changed.unbind(2))
		_watch(drum.child_removed, _on_changed.unbind(2))
		_watch(drum.child_moved, _on_changed.unbind(2))
	var slot := AuxReturnSync.get_layer_slot(channel)
	var layer := slot.get_parent_device() if slot else null
	if layer:
		_watch(layer.child_added, _on_changed.unbind(2))
		_watch(layer.child_removed, _on_changed.unbind(2))
		_watch(layer.child_moved, _on_changed.unbind(2))
		_watch(slot.slot_changed, _on_changed)
	# The lane lists the source chain's devices (pad or Layer slot), so follow them too.
	var src := PadLane.front_device(channel)
	if src:
		_watch(src.child_added, _on_changed.unbind(2))
		_watch(src.child_removed, _on_changed.unbind(2))
		_watch(src.child_moved, _on_changed.unbind(2))


## True while the bound channel is shown as a pad lane.
func active() -> bool:
	return PadLane.is_pad_lane(channel)


func _watch(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_connections.append([sig, cb])


func _disconnect_all() -> void:
	for pair in _connections:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	_connections.clear()


func _on_changed() -> void:
	if _queued:
		return
	_queued = true
	_flush.call_deferred()


## Re-bind (the Drum Machine or parent may have changed), then notify.
func _flush() -> void:
	_queued = false
	if channel == null:
		return
	bind(channel)
	changed.emit()
