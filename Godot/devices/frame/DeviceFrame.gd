## A device frame (spec 022): title bar, a tab per device, and the selected device's page.
##
## The same frame is either floating (inside a FrameWindow) or attached (inside the Editor's
## Primary area); changing mode reparents it, so its pages (device views, plugin GUI slots) are
## never recreated (REQ-009). DeviceWindowManager decides which devices a frame holds.
##
## Pages are created on first selection: a DeviceView (Window view) for built-ins, a PluginGuiSlot
## for plugins. Only the selected page is visible; show_view()/hide_view() follow selection and
## whether the frame itself is shown.
class_name DeviceFrame extends VBoxContainer

signal close_requested
signal attach_requested
signal detach_requested
signal minimize_requested
signal maximize_requested
## Left press on the title bar (not a tab or button): a floating frame starts a window drag.
signal title_bar_pressed
## A tab was dragged out of the frame and dropped at `screen_pos` (REQ-013).
signal tab_torn_off(dev: DeviceInstance, screen_pos: Vector2i)
## A tab was dragged onto another tab of the same frame: move `dev` to where `target` is in the
## channel chain.
signal tab_reorder_requested(dev: DeviceInstance, target: DeviceInstance)
signal active_device_changed(dev: DeviceInstance)
## A tab whose device shows in another frame (torn off) was selected; the frame keeps its
## current tab and the manager raises the other frame.
signal elsewhere_tab_selected(dev: DeviceInstance)
## The active page wants this much content area (canvas units); a floating frame fits it.
signal fit_requested(frame_size: Vector2)

const TITLE_HEIGHT := 26.0
## A tab dropped this far outside the frame is torn off.
const TEAR_OFF_DISTANCE := 24.0
## ...and only after a drag at least this long, so a click never tears off.
const TEAR_OFF_MIN_DRAG := 16.0

const ICON_ATTACH := preload("res://assets/icons/square-arrow-out-down-right.svg")
const ICON_DETACH := preload("res://assets/icons/square-arrow-out-up-right.svg")
const ICON_MINIMIZE := preload("res://assets/icons/minus.svg")
const ICON_MAXIMIZE := preload("res://assets/icons/maximize.svg")
const ICON_RESTORE := preload("res://assets/icons/minimize.svg")
const ICON_CLOSE := preload("res://assets/icons/x.svg")
const CONTEXT_MENU := preload("res://devices/DeviceContextMenu.tscn")

const LIGHT_DIAMETER := 18.0
const TAB_DOT_SIZE := 10
const TAB_DOT_ON := Color(1.0, 0.65, 0.0)
const TAB_DOT_OFF := Color(0.45, 0.2, 0.2)
## Tab reorder insert marker (the shared drop indicator accent).
const REORDER_MARKER_COLOR := Color("#5aa0ff")
const REORDER_MARKER_WIDTH := 3.0

## Channel this frame groups (a channel frame), or null.
var channel: Channel = null
## Device this frame belongs to (its own frame, or a torn-off tab), or null.
var owner_device: DeviceInstance = null
var floating := true

var _devices: Array[DeviceInstance] = []
var _active: DeviceInstance = null
## DeviceInstance -> page Control
var _pages: Dictionary = {}
## DeviceView -> true while show_view() is in effect, so show/hide stay balanced
var _shown_views: Dictionary = {}
## DeviceInstance -> true: its tab stays here but it shows in another frame
var _elsewhere: Dictionary = {}
var _syncing_tabs := false
var _refresh_queued := false
## Tab index pressed on the tab bar, for tear-off (-1 = none)
var _press_tab := -1
## Where that press happened, in the tab bar's coordinates
var _press_pos := Vector2.ZERO
## Tab a drag in progress would be moved onto (-1 = none)
var _reorder_target := -1
## Devices whose enabled state the tab dots follow
var _dot_watched: Dictionary = {}
static var _dot_textures: Dictionary = {}

var title_bar: PanelContainer
var _title_label: Label
## Enabled/active light of the selected device (click bypasses it, ctrl-click sleeps it)
var _light: DeviceLightButton
var _reorder_marker: ColorRect
var _menu: DeviceContextMenu
var _tabs: TabBar
var _attach_button: Button
var _minimize_button: Button
var _maximize_button: Button
var _close_button: Button
var _content: MarginContainer


func _init() -> void:
	name = "DeviceFrame"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)
	_build_title_bar()
	_content = MarginContainer.new()
	_content.name = "Content"
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.clip_contents = true
	add_child(_content)
	set_mode(true)


func _build_title_bar() -> void:
	title_bar = PanelContainer.new()
	title_bar.name = "TitleBar"
	title_bar.custom_minimum_size = Vector2(0, TITLE_HEIGHT)
	title_bar.theme_type_variation = "SectionHeader"
	title_bar.gui_input.connect(_on_title_bar_input)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	title_bar.add_child(row)

	_light = DeviceLightButton.new()
	_light.diameter = LIGHT_DIAMETER
	_light.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_light.visible = false
	row.add_child(_light)

	_title_label = Label.new()
	_title_label.clip_text = true
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 12)
	_title_label.custom_minimum_size.x = 60
	_title_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_title_label)

	_tabs = TabBar.new()
	_tabs.clip_tabs = true
	_tabs.drag_to_rearrange_enabled = false  # reordering goes through the chain (_on_tabs_input)
	_tabs.focus_mode = Control.FOCUS_NONE
	_tabs.tab_changed.connect(_on_tab_changed)
	_tabs.gui_input.connect(_on_tabs_input)
	# Fills the title bar (a narrow one would scroll its tabs out of reach); a press on its empty
	# part drags the window like the rest of the title bar.
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_tabs)

	_reorder_marker = ColorRect.new()
	_reorder_marker.color = REORDER_MARKER_COLOR
	_reorder_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reorder_marker.z_index = 10
	_reorder_marker.visible = false
	_tabs.add_child(_reorder_marker)

	_attach_button = _make_button(ICON_ATTACH, func():
		if floating:
			attach_requested.emit()
		else:
			detach_requested.emit())
	_minimize_button = _make_button(ICON_MINIMIZE, minimize_requested.emit, "Minimize")
	_maximize_button = _make_button(ICON_MAXIMIZE, maximize_requested.emit, "Maximize")
	_close_button = _make_button(ICON_CLOSE, close_requested.emit, "Close")
	for button in [_attach_button, _minimize_button, _maximize_button, _close_button]:
		row.add_child(button)
	add_child(title_bar)


func _make_button(icon: Texture2D, on_pressed: Callable, tooltip: String = "") -> Button:
	var button := Button.new()
	button.icon = icon
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(TITLE_HEIGHT, 0)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", 14)
	button.pressed.connect(on_pressed)
	return button


# ============================================================================
# Mode and chrome
# ============================================================================

## Floating frames show minimize and maximize; attached ones don't (REQ-003).
func set_mode(is_floating: bool) -> void:
	floating = is_floating
	_minimize_button.visible = floating
	_maximize_button.visible = floating
	_attach_button.icon = ICON_ATTACH if floating else ICON_DETACH
	_update_attach_tooltip()
	title_bar.mouse_default_cursor_shape = Control.CURSOR_MOVE if floating else Control.CURSOR_ARROW
	_queue_refresh()


func set_maximized(maximized: bool) -> void:
	_maximize_button.icon = ICON_RESTORE if maximized else ICON_MAXIMIZE
	_maximize_button.tooltip_text = "Restore" if maximized else "Maximize"


func set_title(text: String) -> void:
	_title_label.text = text
	_title_label.tooltip_text = text


## Replace the title tooltip (e.g. to name a plugin's format). The next `set_title` resets it.
func set_title_tooltip(text: String) -> void:
	_title_label.tooltip_text = text


func get_title() -> String:
	return _title_label.text


## A plugin in this frame runs in its own window, so the frame can't attach it.
func can_attach() -> bool:
	if not floating:
		return true
	for page in _pages.values():
		if page is PluginGuiSlot and page.is_floating():
			return false
	return true


func _update_attach_tooltip() -> void:
	if not floating:
		_attach_button.disabled = false
		_attach_button.tooltip_text = "Detach into its own window"
	elif can_attach():
		_attach_button.disabled = false
		_attach_button.tooltip_text = "Attach to the main window"
	else:
		_attach_button.disabled = true
		_attach_button.tooltip_text = "Can't attach: a plugin here runs in its own window"


func _on_title_bar_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		_show_context_menu(_active)
		title_bar.accept_event()
		return
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if mb.double_click:
		if floating:
			maximize_requested.emit()
	else:
		title_bar_pressed.emit()
	title_bar.accept_event()


# ============================================================================
# Devices and tabs
# ============================================================================

func get_devices() -> Array[DeviceInstance]:
	return _devices.duplicate()


func has_device(dev: DeviceInstance) -> bool:
	return _devices.has(dev)


func get_active_device() -> DeviceInstance:
	return _active


## The device whose page is showing: the active one, unless it shows in another frame.
func get_shown_device() -> DeviceInstance:
	return _active if _active and not _elsewhere.has(_active) else null


func get_page(dev: DeviceInstance) -> Control:
	return _pages.get(dev)


func get_tab_titles() -> PackedStringArray:
	var titles := PackedStringArray()
	for i in _tabs.tab_count:
		titles.append(_tabs.get_tab_title(i))
	return titles


func is_tab_strip_visible() -> bool:
	return _tabs.visible


## Set the frame's devices in tab order. Pages of devices no longer listed are closed and freed;
## the selection stays when its device is still here, else moves to the nearest tab.
func set_devices(devs: Array) -> void:
	var old_index := _devices.find(_active)
	var keep: Array[DeviceInstance] = []
	for dev in devs:
		keep.append(dev)
	for dev in _devices:
		if not keep.has(dev):
			_dispose_page(dev)
			_elsewhere.erase(dev)
			_unwatch_enabled(dev)
	_devices = keep
	var previous := _active
	if _active == null or not _devices.has(_active):
		_active = null
		if not _devices.is_empty():
			_active = _devices[clampi(old_index, 0, _devices.size() - 1)]
	_rebuild_tabs()
	if _active:
		_ensure_page(_active)
	if _active != previous:
		active_device_changed.emit(_active)
	_queue_refresh()


## Refresh tab titles (device renamed).
func refresh_titles() -> void:
	_rebuild_tabs()


func _rebuild_tabs() -> void:
	_syncing_tabs = true
	_tabs.clear_tabs()
	for dev in _devices:
		_tabs.add_tab(dev.get_display_name(), _dot_texture(dev.enabled))
		_watch_enabled(dev)
	if _active:
		_tabs.current_tab = _devices.find(_active)
	_syncing_tabs = false
	_bind_light()
	# One device needs no tab strip (REQ-014); the title says what it is and takes its place.
	_tabs.visible = _devices.size() > 1
	_title_label.size_flags_horizontal = Control.SIZE_FILL if _tabs.visible else Control.SIZE_EXPAND_FILL


## Point the title bar light at the selected device.
func _bind_light() -> void:
	_light.bind_to_device_instance(_active)
	_light.visible = _active != null


func _watch_enabled(dev: DeviceInstance) -> void:
	if not _dot_watched.has(dev):
		_dot_watched[dev] = true
		dev.enabled_changed.connect(_on_device_enabled_changed)


func _unwatch_enabled(dev: DeviceInstance) -> void:
	if _dot_watched.erase(dev) and is_instance_valid(dev) and dev.enabled_changed.is_connected(_on_device_enabled_changed):
		dev.enabled_changed.disconnect(_on_device_enabled_changed)


## Tab dots show which devices are enabled, so a bypassed one is visible without selecting it.
func _on_device_enabled_changed(_enabled: bool) -> void:
	for i in _devices.size():
		_tabs.set_tab_icon(i, _dot_texture(_devices[i].enabled))


static func _dot_texture(on: bool) -> Texture2D:
	if _dot_textures.has(on):
		return _dot_textures[on]
	var color := TAB_DOT_ON if on else TAB_DOT_OFF
	var img := Image.create(TAB_DOT_SIZE, TAB_DOT_SIZE, false, Image.FORMAT_RGBA8)
	var c := TAB_DOT_SIZE * 0.5
	for y in TAB_DOT_SIZE:
		for x in TAB_DOT_SIZE:
			var d := Vector2(x + 0.5 - c, y + 0.5 - c).length()
			var a := clampf(c - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	var tex := ImageTexture.create_from_image(img)
	_dot_textures[on] = tex
	return tex


func select_device(dev: DeviceInstance) -> void:
	if not _devices.has(dev):
		return
	if _elsewhere.has(dev):
		_sync_tab_to_active()
		elsewhere_tab_selected.emit(dev)
		return
	if dev == _active:
		return
	_active = dev
	_sync_tab_to_active()
	_bind_light()
	_ensure_page(dev)
	_queue_refresh()
	_update_attach_tooltip()
	active_device_changed.emit(dev)


func _sync_tab_to_active() -> void:
	_syncing_tabs = true
	if _active:
		_tabs.current_tab = _devices.find(_active)
	_syncing_tabs = false


func _on_tab_changed(index: int) -> void:
	if _syncing_tabs or index < 0 or index >= _devices.size():
		return
	select_device(_devices[index])


func _on_tabs_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_reorder_marker((event as InputEventMouseMotion).position)
		return
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		var idx := _tabs.get_tab_idx_at_point(mb.position)
		_show_context_menu(_devices[idx] if idx >= 0 and idx < _devices.size() else _active)
		return
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_press_tab = _tabs.get_tab_idx_at_point(mb.position)
		_press_pos = mb.position
		if _press_tab < 0:
			_on_title_bar_input(mb)  # empty tab bar area: move or maximize the window
		return
	var tab := _press_tab
	var target := _reorder_target_at(mb.position)
	_press_tab = -1
	_hide_reorder_marker()
	if tab < 0 or tab >= _devices.size() or _devices.size() < 2:
		return
	# Only the two events' own positions: the window's idea of its screen position (and so
	# get_local_mouse_position) can be off while a plugin GUI is embedded in it.
	if mb.position.distance_to(_press_pos) < TEAR_OFF_MIN_DRAG:
		return
	if target >= 0:
		tab_reorder_requested.emit(_devices[tab], _devices[target])
		return
	# Tab bar -> row -> title bar -> frame coordinates
	var row := _tabs.get_parent() as Control
	var release := title_bar.get_transform() * row.get_transform() * _tabs.get_transform() * mb.position
	var outside := Rect2(Vector2.ZERO, size).grow(TEAR_OFF_DISTANCE)
	if not outside.has_point(release):
		tab_torn_off.emit(_devices[tab], DisplayServer.mouse_get_position())


## Tab a drag from the pressed tab would drop onto at `pos` (tab bar coordinates), or -1 when the
## pointer is off the bar, the drag is too short, or this frame isn't a channel's tab group.
func _reorder_target_at(pos: Vector2) -> int:
	if channel == null or _press_tab < 0 or _devices.size() < 2:
		return -1
	if pos.distance_to(_press_pos) < TEAR_OFF_MIN_DRAG or not Rect2(Vector2.ZERO, _tabs.size).has_point(pos):
		return -1
	var idx := _tabs.get_tab_idx_at_point(pos)
	if idx < 0:
		idx = _tabs.tab_count - 1 if pos.x > _tabs.get_tab_rect(_tabs.tab_count - 1).end.x else 0
	return idx if idx != _press_tab else -1


## Show where the dragged tab would land: on the far side of the tab it is dragged onto.
func _update_reorder_marker(pos: Vector2) -> void:
	_reorder_target = _reorder_target_at(pos)
	if _reorder_target < 0:
		_hide_reorder_marker()
		return
	var rect := _tabs.get_tab_rect(_reorder_target)
	var x := rect.position.x if _reorder_target < _press_tab else rect.end.x
	_reorder_marker.position = Vector2(x - REORDER_MARKER_WIDTH * 0.5, rect.position.y)
	_reorder_marker.size = Vector2(REORDER_MARKER_WIDTH, rect.size.y)
	_reorder_marker.visible = true


func _hide_reorder_marker() -> void:
	_reorder_target = -1
	_reorder_marker.visible = false


## Remove, copy, paste and duplicate for `dev` (the same menu as the device panels).
func _show_context_menu(dev: DeviceInstance) -> void:
	if dev == null:
		return
	if _menu == null:
		_menu = CONTEXT_MENU.instantiate()
		# A native popup: an embedded one is drawn by Godot, under a plugin's own X window, and
		# can't leave its parent window (a frame's title bar sits at the top of it).
		_menu.hide()
		_menu.force_native = true
		add_child(_menu)
	_menu.removes_drum_pad = false
	_menu.targets = [dev]
	_menu.bind_to_device(dev)
	var menu_size := Vector2(_menu.get_contents_minimum_size())
	var at: Vector2
	var bounds: Rect2
	if _menu.is_embedded():
		at = get_global_mouse_position()
		bounds = Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	else:
		at = Vector2(DisplayServer.mouse_get_position())
		var screen := DisplayServer.get_screen_from_rect(Rect2(at, Vector2.ONE))
		bounds = Rect2(DisplayServer.screen_get_usable_rect(screen))
	_menu.popup(Rect2(menu_rect_origin(at, menu_size, bounds), menu_size))


## Top-left for a menu of `menu_size` opened at `at` inside `bounds`. A plugin's own window covers
## whatever opens over the page below the title bar, so the menu opens upwards (its bottom edge at
## the pointer). With no room above it opens downwards instead, on whichever side of the pointer
## has more room horizontally (the left side when the right can't hold it).
static func menu_rect_origin(at: Vector2, menu_size: Vector2, bounds: Rect2) -> Vector2:
	var origin := at
	if at.y - menu_size.y >= bounds.position.y:
		origin.y = at.y - menu_size.y
	else:
		var right_room := bounds.end.x - at.x
		var left_room := at.x - bounds.position.x
		if right_room < menu_size.x and left_room > right_room:
			origin.x = at.x - menu_size.x
	origin.x = clampf(origin.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - menu_size.x))
	origin.y = clampf(origin.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - menu_size.y))
	return origin


## Mark `dev` as showing in another frame (torn off): its tab stays, selecting it raises the
## other frame. Clearing it lets the tab show here again.
func set_elsewhere(dev: DeviceInstance, elsewhere: bool) -> void:
	if not _devices.has(dev):
		return
	if elsewhere:
		_elsewhere[dev] = true
		if _active == dev:
			# Show a neighbour instead
			for other in _devices:
				if not _elsewhere.has(other):
					select_device(other)
					break
	else:
		_elsewhere.erase(dev)
	_queue_refresh()


func is_elsewhere(dev: DeviceInstance) -> bool:
	return _elsewhere.has(dev)


# ============================================================================
# Pages
# ============================================================================

func _ensure_page(dev: DeviceInstance) -> Control:
	if _pages.has(dev):
		return _pages[dev]
	var page: Control = null
	if dev.device.has_gui():
		var slot := PluginGuiSlot.new()
		slot.bind(dev)
		slot.fit_requested.connect(_on_page_fit_requested.bind(dev))
		slot.floating_changed.connect(_on_page_floating_changed)
		page = slot
	else:
		var view: DeviceView = DeviceViewFactory.create(dev, Device.ViewType.Window)
		if view == null:
			push_warning("[DeviceFrame] no Window view for %s" % dev.get_display_name())
			return null
		page = view
	page.visible = false
	_content.add_child(page)
	if page is DeviceView:
		(page as DeviceView).bind_to_device(dev)
	_pages[dev] = page
	return page


## Remove `dev`'s page without closing it, to move it to another frame (tear-off).
func take_page(dev: DeviceInstance) -> Control:
	var page: Control = _pages.get(dev)
	if page == null:
		return null
	_pages.erase(dev)
	if _shown_views.has(page):
		_shown_views.erase(page)
		(page as DeviceView).hide_view()
	if page is PluginGuiSlot:
		page.fit_requested.disconnect(_on_page_fit_requested)
		page.floating_changed.disconnect(_on_page_floating_changed)
	_content.remove_child(page)
	return page


## Adopt a page taken from another frame.
func put_page(dev: DeviceInstance, page: Control) -> void:
	if page == null or _pages.has(dev):
		return
	page.visible = false
	_content.add_child(page)
	if page is PluginGuiSlot:
		page.fit_requested.connect(_on_page_fit_requested.bind(dev))
		page.floating_changed.connect(_on_page_floating_changed)
	_pages[dev] = page
	_queue_refresh()


func _dispose_page(dev: DeviceInstance) -> bool:
	var page: Control = _pages.get(dev)
	if page == null:
		return false
	_pages.erase(dev)
	var had_gui := false
	if page is PluginGuiSlot:
		had_gui = (page as PluginGuiSlot).close()
	elif _shown_views.has(page):
		_shown_views.erase(page)
		(page as DeviceView).hide_view()
	_content.remove_child(page)
	page.queue_free()
	return had_gui


## Close every page: plugin GUIs get close_gui(), views hide and are freed (REQ-004).
## Returns the devices whose plugin GUI was open, to wait for their `plugin_gui_closed`.
func close_all() -> Array[DeviceInstance]:
	var closed: Array[DeviceInstance] = []
	for dev in _pages.keys():
		if _dispose_page(dev):
			closed.append(dev)
	_active = null
	return closed


func _on_page_floating_changed(_floating: bool) -> void:
	_update_attach_tooltip()


func _on_page_fit_requested(content_size: Vector2, dev: DeviceInstance) -> void:
	if dev == _active:
		fit_requested.emit(content_size + Vector2(0, title_bar.get_combined_minimum_size().y))


# ============================================================================
# Visibility
# ============================================================================

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED, NOTIFICATION_ENTER_TREE, NOTIFICATION_EXIT_TREE:
			_queue_refresh()


## Re-evaluate which page shows and which views are subscribed. Deferred so a reparent (attach,
## detach) ends where it started without hide/show churn.
func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	refresh_visibility.call_deferred()


func refresh_visibility() -> void:
	_refresh_queued = false
	if is_queued_for_deletion():
		return
	var window := get_window() if is_inside_tree() else null
	var frame_shown := is_inside_tree() and is_visible_in_tree() and window != null and window.visible
	var shown_dev := get_shown_device()
	for dev in _pages:
		var page: Control = _pages[dev]
		page.visible = dev == shown_dev
		if page is DeviceView:
			var want: bool = frame_shown and dev == shown_dev
			if want and not _shown_views.has(page):
				_shown_views[page] = true
				page.show_view()
			elif not want and _shown_views.has(page):
				_shown_views.erase(page)
				page.hide_view()
	_update_attach_tooltip()
