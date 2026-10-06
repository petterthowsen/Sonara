# Owns every device frame (spec 022): floating FrameWindows and the one frame attached to the
# Editor's Primary area. The DeviceLane rebuilds its panels whenever the track selection changes;
# frames live here so they survive those rebuilds.
#
# Grouping ("devices/window_grouping"): per channel, a channel's top-level chain devices share one
# frame with a tab each; per device, every device gets its own frame. Nested devices (pads, layer
# slots) always get their own frame. A tab torn off its channel frame becomes a frame of its own.
#
# Public API (DevicePanel, CompactDevicePanel): is_open / toggle / open / close and
# state_changed(device). A device is "open" when it owns a frame, is the shown tab of a frame, or
# its plugin GUI is open in its own window without a frame.
extends Node

signal state_changed(device: DeviceInstance)

## A frame window waits this long for the engine to confirm its plugin GUIs moved out
## (`gui/embedded`) before it hides or is freed anyway (REQ-023). The engine answers in
## milliseconds; this only matters when it's gone.
const VACATE_TIMEOUT_SEC := 2.0

var logger: Log = Log.make("DeviceWindowManager")

## Open frames, attached one included
var _frames: Array[DeviceFrame] = []
## DeviceFrame -> FrameWindow. Kept (hidden) while the frame is attached, for detach.
var _windows: Dictionary = {}
## The frame in the Primary area, or null
var _attached: DeviceFrame = null
## Plugins whose GUI is open in their own window without a frame (embedding off): dev -> true
var _standalone: Dictionary = {}
## Hosts the attached frame; the Editor registers itself. Implements attach_frame(frame),
## detach_frame(frame) and show_attached_frame().
var attach_host: Object = null
## Signal connections per watched object: Object -> Array of [Signal, Callable]
var _watches: Dictionary = {}
## Frame windows waiting for their plugin GUIs to move out before they hide or are freed
## (see _when_vacated): { window, xid, devs, then, deadline }
var _vacating: Array[Dictionary] = []


func _ready() -> void:
	set_process(false)


# ============================================================================
# Settings
# ============================================================================

## Plugin GUIs embed into frames: the experimental setting is on and the display server can do it.
func embedding_enabled() -> bool:
	return bool(Settings.get_value("plugins/embed_gui")) and Settings.is_available("plugins/embed_gui")


func _per_device() -> bool:
	return Settings.get_value("devices/window_grouping") == "Per device"


# ============================================================================
# Public API
# ============================================================================

func is_open(dev: DeviceInstance) -> bool:
	if dev == null:
		return false
	if _standalone.has(dev) or _own_frame(dev) != null:
		return true
	for frame in _frames:
		if frame.get_shown_device() == dev:
			return true
	return false


## Close what `dev` shows in (its frame, or the frame it's the shown tab of); otherwise open it.
func toggle(dev: DeviceInstance) -> void:
	if dev == null:
		return
	if is_open(dev):
		close(dev)
	else:
		open(dev)


## Open `dev`: raise its own frame, or select its tab in its channel frame (creating either).
func open(dev: DeviceInstance) -> void:
	if dev == null or dev.device == null:
		return
	if not (dev.device.has_gui() or dev.device.has_window_view()):
		return
	var own := _own_frame(dev)
	if own:
		_raise(own)
		return
	if _standalone.has(dev):
		dev.open_gui()  # raises its window
		return
	var ch := dev.get_channel()
	var grouped := ch != null and dev.get_parent_device() == null and not _per_device()
	var channel_frame := _channel_frame(ch) if grouped else null
	if dev.device.has_gui() and not embedding_enabled() and channel_frame == null:
		# Embedding off: the plugin opens in its own window, as before frames (REQ-017).
		_standalone[dev] = true
		dev.open_gui()
		_after_change()
		return
	if grouped:
		if channel_frame == null:
			channel_frame = _create_frame(ch, null, _chain_devices(ch))
		channel_frame.select_device(dev)
		_raise(channel_frame)
	else:
		_raise(_create_frame(null, dev, [dev]))
	_after_change()


func close(dev: DeviceInstance) -> void:
	if dev == null:
		return
	if _standalone.has(dev):
		_standalone.erase(dev)
		dev.close_gui()
		_after_change([dev])
		return
	var own := _own_frame(dev)
	if own:
		close_frame(own)
		return
	for frame in _frames:
		if frame.get_shown_device() == dev:
			close_frame(frame)
			return


## Close a frame and everything in it (REQ-004, REQ-023).
func close_frame(frame: DeviceFrame) -> void:
	if not _frames.has(frame):
		return
	_frames.erase(frame)
	var devs := frame.get_devices()
	frame.close_all()
	var window: FrameWindow = _windows.get(frame)
	_windows.erase(frame)
	if frame == _attached:
		# The engine moves plugin GUIs out of the main window on gui/close; its frame window is
		# hidden and holds nothing.
		_attached = null
		if attach_host:
			attach_host.detach_frame(frame)
		frame.queue_free()
		if window:
			window.queue_free()
	elif window:
		# gui/close takes each GUI out of the window first; hiding it before that would destroy
		# the plugin's window under it. The engine confirms in milliseconds.
		_when_vacated(window, devs, func():
			window.hide()
			window.queue_free())
	# A torn-off tab goes back to its channel frame
	if frame.owner_device:
		for other in _frames:
			other.set_elsewhere(frame.owner_device, false)
	_after_change(devs)


## Close every frame and plugin window (project closed).
func close_all() -> void:
	for frame in _frames.duplicate():
		close_frame(frame)
	for dev in _standalone.keys():
		close(dev)


## The frame `dev` shows in, or null.
func get_frame(dev: DeviceInstance) -> DeviceFrame:
	var own := _own_frame(dev)
	if own:
		return own
	for frame in _frames:
		if frame.get_shown_device() == dev:
			return frame
	return null


func get_frames() -> Array[DeviceFrame]:
	return _frames.duplicate()


func get_attached_frame() -> DeviceFrame:
	return _attached


func get_window_for(frame: DeviceFrame) -> FrameWindow:
	return _windows.get(frame)


# ============================================================================
# Attach and detach (REQ-005..009)
# ============================================================================

## Move `frame` into the Primary area; an already attached frame is detached first (REQ-007).
func attach(frame: DeviceFrame) -> void:
	if attach_host == null or frame == _attached or not _frames.has(frame) or not frame.can_attach():
		return
	if _attached:
		detach(_attached)
	var window: FrameWindow = _windows.get(frame)
	if window:
		window.release_frame()
	frame.set_mode(false)
	attach_host.attach_frame(frame)
	_attached = frame
	if window:
		# The plugin GUIs move to the main window on the next frame (PluginGuiSlot); hide the
		# frame window only once they're out, or it takes them down with it.
		_when_vacated(window, frame.get_devices(), func():
			if _windows.get(frame) == window and frame == _attached:
				window.hide())
	_after_change()


## Move the attached frame back into its window, at its last floating rect (REQ-008).
func detach(frame: DeviceFrame) -> void:
	if frame != _attached or frame == null:
		return
	_attached = null
	if attach_host:
		attach_host.detach_frame(frame)
	var window: FrameWindow = _windows.get(frame)
	if window == null:
		window = _new_window()
		_windows[frame] = window
	window.host(frame)
	window.show_frame()
	_after_change()


# ============================================================================
# Tear-off (REQ-013)
# ============================================================================

## Move `dev`'s tab out of `from` into a frame of its own at `screen_pos`. Its page moves along,
## so a plugin GUI isn't reopened.
func tear_off(from: DeviceFrame, dev: DeviceInstance, screen_pos: Vector2i) -> DeviceFrame:
	if not _frames.has(from) or not from.has_device(dev) or from.get_devices().size() < 2:
		return null
	var page := from.take_page(dev)
	from.set_elsewhere(dev, true)
	var frame := _create_frame(null, dev, [dev], page)
	_windows[frame].show_at(screen_pos)
	_after_change()
	return frame


# ============================================================================
# Frames
# ============================================================================

func _own_frame(dev: DeviceInstance) -> DeviceFrame:
	for frame in _frames:
		if frame.owner_device == dev:
			return frame
	return null


func _channel_frame(ch: Channel) -> DeviceFrame:
	if ch == null:
		return null
	for frame in _frames:
		if frame.channel == ch:
			return frame
	return null


## Top-level chain devices that have something to show, in chain order.
func _chain_devices(ch: Channel) -> Array:
	var out: Array = []
	for dev in ch.devices:
		if dev.device and (dev.device.has_gui() or dev.device.has_window_view()):
			out.append(dev)
	return out


func _new_window() -> FrameWindow:
	var window := FrameWindow.new()
	window.close_requested.connect(func():
		if window.frame:
			close_frame(window.frame))
	get_tree().root.add_child(window)
	return window


## Create a floating frame (not shown yet; the caller raises it). `page` is an existing page for
## the single device of a torn-off frame.
func _create_frame(ch: Channel, owner: DeviceInstance, devs: Array, page: Control = null) -> DeviceFrame:
	var frame := DeviceFrame.new()
	frame.channel = ch
	frame.owner_device = owner
	if page and owner:
		frame.put_page(owner, page)
	frame.set_devices(devs)
	# Devices shown in their own (torn-off) frame keep their tab here but don't show here
	for dev in devs:
		if dev != owner and _own_frame(dev) != null:
			frame.set_elsewhere(dev, true)
	frame.close_requested.connect(close_frame.bind(frame))
	frame.attach_requested.connect(attach.bind(frame))
	frame.detach_requested.connect(detach.bind(frame))
	frame.tab_torn_off.connect(func(dev: DeviceInstance, pos: Vector2i): tear_off(frame, dev, pos))
	frame.active_device_changed.connect(_on_active_device_changed.bind(frame))
	frame.elsewhere_tab_selected.connect(func(dev: DeviceInstance):
		var other := _own_frame(dev)
		if other:
			_raise(other))
	_frames.append(frame)
	_update_title(frame)
	var window := _new_window()
	_windows[frame] = window
	window.host(frame)
	return frame


func _raise(frame: DeviceFrame) -> void:
	if frame == _attached:
		if attach_host:
			attach_host.show_attached_frame()
		return
	var window: FrameWindow = _windows.get(frame)
	if window:
		window.raise_frame()


## Run `then` once none of `devs`' plugin GUIs is in `window` any more (the engine confirmed the
## move with gui/embedded), or after VACATE_TIMEOUT_SEC. Godot destroys a native window's X
## window when it hides or frees it, and every child window with it: the plugin's included.
func _when_vacated(window: FrameWindow, devs: Array, then: Callable) -> void:
	var xid := 0
	if window.visible:
		xid = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
	var wait := {
		"window": window,
		"xid": xid,
		"devs": devs.duplicate(),
		"then": then,
		"deadline": Time.get_ticks_msec() + int(VACATE_TIMEOUT_SEC * 1000),
	}
	if not _try_finish_vacate(wait):
		_vacating.append(wait)
		set_process(true)


func _process(_delta: float) -> void:
	for wait in _vacating.duplicate():
		if _try_finish_vacate(wait):
			_vacating.erase(wait)
	if _vacating.is_empty():
		set_process(false)


## Runs the wait's `then` and returns true when its window is empty of plugin GUIs or it timed out.
func _try_finish_vacate(wait: Dictionary) -> bool:
	var xid: int = wait.xid
	var inside: bool = xid != 0 and wait.devs.any(func(dev): return dev.gui_parent_xid == xid)
	if inside and Time.get_ticks_msec() < wait.deadline:
		return false
	if inside:
		logger.warn("plugin GUIs didn't leave a frame window within %.0f s" % VACATE_TIMEOUT_SEC)
	var window: FrameWindow = wait.window
	if is_instance_valid(window) and not window.is_queued_for_deletion():
		wait.then.call()
	return true


func _update_title(frame: DeviceFrame) -> void:
	var text := ""
	if frame.owner_device:
		text = _device_title(frame.owner_device)
	elif frame.channel:
		var devs := frame.get_devices()
		text = _device_title(devs[0]) if devs.size() == 1 else frame.channel.name
	frame.set_title(text)
	var window: FrameWindow = _windows.get(frame)
	if window:
		window.refresh_title()


## "<channel> — <device>", e.g. "Drums — Reverb": the device name alone is ambiguous when several
## channels carry the same device.
func _device_title(dev: DeviceInstance) -> String:
	var ch := dev.get_channel()
	if ch:
		return "%s — %s" % [ch.name, dev.get_display_name()]
	return dev.get_display_name()


func _on_active_device_changed(_dev: DeviceInstance, frame: DeviceFrame) -> void:
	_update_title(frame)
	_emit_states(frame.get_devices())


# ============================================================================
# Model changes: chain edits, renames, removal, plugin GUI closed
# ============================================================================

## Re-sync watches and tell panels after any change. `extra` are devices that may have left.
func _after_change(extra: Array = []) -> void:
	_sync_watches()
	var devs := extra.duplicate()
	for frame in _frames:
		devs.append_array(frame.get_devices())
		if frame.owner_device:
			devs.append(frame.owner_device)
	devs.append_array(_standalone.keys())
	_emit_states(devs)


func _emit_states(devs: Array) -> void:
	var seen := {}
	for dev in devs:
		if dev != null and not seen.has(dev):
			seen[dev] = true
			state_changed.emit(dev)


## Watch exactly the channels and devices that open frames and plugin windows depend on.
func _sync_watches() -> void:
	var wanted := {}
	for frame in _frames:
		var devs := frame.get_devices()
		if frame.channel:
			wanted[frame.channel] = true
		for dev in devs:
			wanted[dev] = true
			_want_context(dev, wanted)
	for dev in _standalone:
		wanted[dev] = true
		_want_context(dev, wanted)
	for obj in _watches.keys():
		if not wanted.has(obj):
			_unwatch(obj)
	for obj in wanted:
		if not _watches.has(obj):
			_watch(obj)


## The channel and parent a device's frame or tab depends on (rename, removal).
func _want_context(dev: DeviceInstance, wanted: Dictionary) -> void:
	var parent := dev.get_parent_device()
	if parent:
		wanted[parent] = true
	var ch := dev.get_channel()
	if ch:
		wanted[ch] = true


func _watch(obj: Object) -> void:
	var links: Array = []
	if obj is Channel:
		var ch := obj as Channel
		links = [
			[ch.device_added, _on_chain_changed.bind(ch).unbind(2)],
			[ch.device_moved, _on_chain_changed.bind(ch).unbind(2)],
			[ch.device_removed, _on_device_removed.bind(ch)],
			[ch.name_changed, _on_names_changed.unbind(1)],
		]
	elif obj is DeviceInstance:
		var dev := obj as DeviceInstance
		links = [
			[dev.name_changed, _on_names_changed.unbind(1)],
			[dev.child_removed, _on_child_removed.bind(dev)],
			[dev.plugin_gui_closed, _on_plugin_gui_closed.bind(dev)],
		]
	for link in links:
		link[0].connect(link[1])
	_watches[obj] = links


func _unwatch(obj: Object) -> void:
	for link in _watches.get(obj, []):
		if link[0].is_connected(link[1]):
			link[0].disconnect(link[1])
	_watches.erase(obj)


## Tabs follow the chain (REQ-012); a frame left with nothing closes (REQ-016).
func _on_chain_changed(ch: Channel) -> void:
	var frame := _channel_frame(ch)
	if frame == null:
		return
	var devs := _chain_devices(ch)
	if devs.is_empty():
		close_frame(frame)
		return
	frame.set_devices(devs)
	for dev in devs:
		frame.set_elsewhere(dev, _own_frame(dev) != null)
	_update_title(frame)
	_after_change()


## device_id is the DeviceInstance.id of the removed device.
func _on_device_removed(_position: int, device_id: String, ch: Channel) -> void:
	_close_by_instance_id(device_id)
	_on_chain_changed(ch)


func _on_child_removed(_position: int, device_id: String, _parent: DeviceInstance) -> void:
	_close_by_instance_id(device_id)


func _close_by_instance_id(device_id: String) -> void:
	for dev in _standalone.keys():
		if dev.id == device_id:
			close(dev)
	for frame in _frames.duplicate():
		if frame.owner_device and frame.owner_device.id == device_id:
			close_frame(frame)


func _on_names_changed() -> void:
	for frame in _frames:
		frame.refresh_titles()
		_update_title(frame)


func _on_plugin_gui_closed(dev: DeviceInstance) -> void:
	# Closed from the plugin's own window. Frames keep their tab (the slot shows a note).
	if _standalone.erase(dev):
		logger.info("Plugin GUI closed for %s" % dev.get_display_name())
		_after_change([dev])
