# Owns every floating device window (native plugin GUIs and Window-view popups),
# keyed by DeviceInstance. The DeviceLane rebuilds its panels whenever the track
# selection changes; windows live here so they survive those rebuilds instead of
# being torn down with the panel they were opened from.
extends Node

signal state_changed(device: DeviceInstance)

var logger: Log = Log.make("DeviceWindowManager")

## DeviceInstance -> Window (Window-view popups)
var _popups: Dictionary = {}
## DeviceInstance -> DeviceView hosted in the popup
var _views: Dictionary = {}
## DeviceInstance -> true while its native plugin GUI is open
var _guis: Dictionary = {}
## Devices whose popup view is still loading (open() awaited its ready signal)
var _opening: Dictionary = {}


func is_open(dev: DeviceInstance) -> bool:
	return dev != null and (_popups.has(dev) or _guis.has(dev) or _opening.has(dev))


func toggle(dev: DeviceInstance) -> void:
	if dev == null:
		return
	if is_open(dev):
		close(dev)
	else:
		open(dev)


func open(dev: DeviceInstance) -> void:
	if dev == null or dev.device == null or is_open(dev):
		return
	if dev.device.has_gui():
		_guis[dev] = true
		dev.open_gui()
		_watch(dev)
		state_changed.emit(dev)
		return
	if dev.device.has_window_view():
		_open_view_window(dev)


func _open_view_window(dev: DeviceInstance) -> void:
	_opening[dev] = true
	var view: DeviceView = DeviceViewFactory.create(dev, Device.ViewType.Window)
	if view == null:
		logger.warn("no Window view for %s" % dev.get_display_name())
		_opening.erase(dev)
		return
	var popup := Window.new()
	# Native window: it can be dragged off the main window, and popups opened
	# inside it embed into it. Embedded windows cannot host embedded subwindows,
	# so their popups get reparented into the root window at an offset instead.
	# force_native can only be set while the window is hidden (visible defaults true).
	popup.visible = false
	popup.force_native = true
	popup.name = "DeviceWindow_%s" % dev.get_display_name()
	popup.unresizable = false
	popup.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	popup.handle_input_locally = false # we want to still accept input events the window doesn't handle.
	popup.size = Vector2i(300, 200) # initial size
	popup.title = _window_title(dev)
	popup.wrap_controls = true # sized by content
	popup.minimize_disabled = true # cannot minimize
	popup.maximize_disabled = true # cannot maximize
	# No always_on_top: X11 refuses to make popups transient to an on-top
	# window (engine error on every popup open). Native windows float above
	# the main window by normal OS stacking anyway.
	popup.close_requested.connect(close.bind(dev))
	popup.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.bind_to_device(dev)
	get_tree().root.add_child(popup)
	if not view.is_node_ready():
		await view.ready
	# Size the popup to the view's minimum: a fixed 300x200 left the EQ cut off until reopened.
	var min_size := Vector2i(view.get_combined_minimum_size())
	popup.min_size = min_size
	popup.popup_centered(Vector2i(maxi(min_size.x, 300), maxi(min_size.y, 200)))
	# notify the view it is now visible so it can subscribe
	view._on_view_shown()
	_popups[dev] = popup
	_views[dev] = view
	_opening.erase(dev)
	_watch(dev)
	state_changed.emit(dev)


func close(dev: DeviceInstance) -> void:
	if dev == null:
		return
	if _guis.has(dev):
		_guis.erase(dev)
		_unwatch(dev)
		dev.close_gui()
		state_changed.emit(dev)
		return
	if not _popups.has(dev) and not _opening.has(dev):
		return
	var popup: Window = _popups.get(dev)
	var view: DeviceView = _views.get(dev)
	_views.erase(dev)
	_popups.erase(dev)
	_opening.erase(dev)
	_unwatch(dev)
	# The popup (and the view inside it) may already be gone when the editor
	# is freed on quit before this manager.
	if view and is_instance_valid(view):
		view._on_view_hidden()
		view.queue_free()
	if popup and is_instance_valid(popup):
		popup.hide()
		popup.queue_free()
	state_changed.emit(dev)


# ============================================================================
# Lifetime of the opened device: rename, plugin GUI closed, device removed
# ============================================================================

func _watch(dev: DeviceInstance) -> void:
	if not dev.plugin_gui_closed.is_connected(_on_plugin_gui_closed):
		dev.plugin_gui_closed.connect(_on_plugin_gui_closed.bind(dev))
	if not dev.name_changed.is_connected(_on_device_name_changed):
		dev.name_changed.connect(_on_device_name_changed.bind(dev))
	# A removed device closes its window: a pad leaves via its container's
	# child_removed, a chain device via its channel's device_removed.
	var parent := dev.get_parent_device()
	if parent and not parent.child_removed.is_connected(_on_child_removed):
		parent.child_removed.connect(_on_child_removed.bind(parent))
	var ch := dev.get_channel()
	if ch and not ch.device_removed.is_connected(_on_device_removed):
		ch.device_removed.connect(_on_device_removed.bind(ch))
	if ch and not ch.name_changed.is_connected(_on_channel_name_changed):
		ch.name_changed.connect(_on_channel_name_changed.bind(dev))


func _unwatch(dev: DeviceInstance) -> void:
	if dev.plugin_gui_closed.is_connected(_on_plugin_gui_closed):
		dev.plugin_gui_closed.disconnect(_on_plugin_gui_closed)
	if dev.name_changed.is_connected(_on_device_name_changed):
		dev.name_changed.disconnect(_on_device_name_changed)
	var parent := dev.get_parent_device()
	if parent and parent.child_removed.is_connected(_on_child_removed):
		parent.child_removed.disconnect(_on_child_removed)
	var ch := dev.get_channel()
	if ch and ch.device_removed.is_connected(_on_device_removed):
		ch.device_removed.disconnect(_on_device_removed)
	if ch and ch.name_changed.is_connected(_on_channel_name_changed):
		ch.name_changed.disconnect(_on_channel_name_changed)


func _on_device_name_changed(new_name: String, dev: DeviceInstance) -> void:
	var popup: Window = _popups.get(dev)
	if popup and is_instance_valid(popup):
		popup.title = _window_title(dev)

func _on_channel_name_changed(_new_name: String, dev: DeviceInstance) -> void:
	var popup: Window = _popups.get(dev)
	if popup and is_instance_valid(popup):
		popup.title = _window_title(dev)

func _window_title(dev: DeviceInstance) -> String:
	## "<channel> — <device>", e.g. "Drums — Reverb". The device name alone
	## is ambiguous when several channels carry the same device.
	var ch := dev.get_channel()
	if ch:
		return "%s — %s" % [ch.name, dev.get_display_name()]
	return dev.get_display_name()


func _on_plugin_gui_closed(dev: DeviceInstance) -> void:
	logger.info("Plugin GUI closed notification received for %s" % dev.get_display_name())
	_guis.erase(dev)
	_unwatch(dev)
	state_changed.emit(dev)


## device_id is the DeviceInstance.id of the removed device.
func _on_device_removed(_position: int, device_id: String, _channel: Channel) -> void:
	_close_by_instance_id(device_id)


func _on_child_removed(_position: int, device_id: String, _parent: DeviceInstance) -> void:
	_close_by_instance_id(device_id)


func _close_by_instance_id(device_id: String) -> void:
	for dev in _open_devices():
		if dev.id == device_id:
			close(dev)


func _open_devices() -> Array:
	var open: Array = []
	for dev in _popups:
		open.append(dev)
	for dev in _guis:
		open.append(dev)
	for dev in _opening:
		open.append(dev)
	return open
