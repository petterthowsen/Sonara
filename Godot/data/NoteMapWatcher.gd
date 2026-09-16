# NoteMapWatcher.gd
# Emits `changed` (once per frame) when a channel's *effective* note map may look
# different: the assignment itself, the device chain, a Drum Machine's pads, a pad
# device's name, or a pad return channel's colour (REQ-004).
#
# Modelled on PadLaneWatcher: every flush re-binds before notifying, so pads that
# appeared or disappeared since the last frame are picked up and stale connections
# to removed pads are dropped.
class_name NoteMapWatcher extends RefCounted

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

	# The assignment (mode, embedded map, Drum View preference).
	_watch(channel.note_map_changed, _on_changed)
	# A Drum Machine arriving on or leaving the chain changes the Auto source.
	_watch(channel.device_added, _on_changed.unbind(2))
	_watch(channel.device_removed, _on_changed.unbind(2))
	_watch(channel.device_moved, _on_changed.unbind(2))

	var drum := NoteMapResolver.find_drum_machine(channel)
	if drum == null:
		return
	_watch(drum.child_added, _on_changed.unbind(2))
	_watch(drum.child_removed, _on_changed.unbind(2))
	_watch(drum.child_moved, _on_changed.unbind(2))

	var project := channel.get_project()
	for i in drum.children.size():
		var pad: DeviceInstance = drum.children[i]
		if pad == null:
			continue
		# Renaming a pad renames its entry; moving it to another note moves the row.
		_watch(pad.name_changed, _on_changed.unbind(1))
		_watch(pad.slot_changed, _on_changed)
		if project == null:
			continue
		var ret := AuxReturnSync.get_return_channel(project, drum, i)
		if ret:
			_watch(ret.color_changed, _on_changed.unbind(1))


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


## Re-bind (pads may have come or gone), then notify. Coalesced to one emit per
## frame however many of the watched signals fired.
func _flush() -> void:
	_queued = false
	if channel == null:
		return
	bind(channel)
	changed.emit()
