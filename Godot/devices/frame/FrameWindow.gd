## A floating device frame's native window (spec 022): borderless, so the DeviceFrame's title bar
## is the only chrome. The window manager moves and resizes it (window_start_drag /
## window_start_resize), which keeps snapping and works on any display server (REQ-002, 003).
##
## While its frame is attached the window is kept, hidden, and hosts the frame again on detach at
## the rect it had (REQ-008). A plugin GUI embedded in it moves out before it is hidden or freed.
class_name FrameWindow extends Window

## Edge grip thickness, canvas units
const GRIP := 5.0
## Size before a GUI or view says otherwise
const DEFAULT_SIZE := Vector2i(480, 320)

var frame: DeviceFrame = null
## Last floating rect (position, size), kept across attach/detach; empty until first shown.
var last_rect := Rect2i()

var _grips: Array[Control] = []


func _init() -> void:
	# force_native can only be set while hidden (visible defaults true).
	visible = false
	force_native = true
	borderless = true
	unresizable = false
	# No always_on_top: X11 refuses to make popups transient to an on-top window.
	handle_input_locally = false
	wrap_controls = false
	size = DEFAULT_SIZE
	initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	visibility_changed.connect(_on_visibility_changed)
	_build_grips()


func _build_grips() -> void:
	var specs := [
		[DisplayServer.WINDOW_EDGE_TOP_LEFT, Control.CURSOR_FDIAGSIZE],
		[DisplayServer.WINDOW_EDGE_TOP, Control.CURSOR_VSIZE],
		[DisplayServer.WINDOW_EDGE_TOP_RIGHT, Control.CURSOR_BDIAGSIZE],
		[DisplayServer.WINDOW_EDGE_LEFT, Control.CURSOR_HSIZE],
		[DisplayServer.WINDOW_EDGE_RIGHT, Control.CURSOR_HSIZE],
		[DisplayServer.WINDOW_EDGE_BOTTOM_LEFT, Control.CURSOR_BDIAGSIZE],
		[DisplayServer.WINDOW_EDGE_BOTTOM, Control.CURSOR_VSIZE],
		[DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT, Control.CURSOR_FDIAGSIZE],
	]
	for spec in specs:
		var grip := Control.new()
		grip.name = "Grip%d" % spec[0]
		grip.set_meta("edge", spec[0])
		grip.mouse_filter = Control.MOUSE_FILTER_STOP
		grip.mouse_default_cursor_shape = spec[1]
		grip.gui_input.connect(_on_grip_input.bind(spec[0]))
		_grips.append(grip)
		add_child(grip)
	_layout_grips()


## Corners are GRIP square; edges span between them.
func _layout_grips() -> void:
	for grip in _grips:
		var edge: int = grip.get_meta("edge")
		var w := float(size.x)
		var h := float(size.y)
		var r := Rect2()
		match edge:
			DisplayServer.WINDOW_EDGE_TOP_LEFT: r = Rect2(0, 0, GRIP, GRIP)
			DisplayServer.WINDOW_EDGE_TOP: r = Rect2(GRIP, 0, w - 2 * GRIP, GRIP)
			DisplayServer.WINDOW_EDGE_TOP_RIGHT: r = Rect2(w - GRIP, 0, GRIP, GRIP)
			DisplayServer.WINDOW_EDGE_LEFT: r = Rect2(0, GRIP, GRIP, h - 2 * GRIP)
			DisplayServer.WINDOW_EDGE_RIGHT: r = Rect2(w - GRIP, GRIP, GRIP, h - 2 * GRIP)
			DisplayServer.WINDOW_EDGE_BOTTOM_LEFT: r = Rect2(0, h - GRIP, GRIP, GRIP)
			DisplayServer.WINDOW_EDGE_BOTTOM: r = Rect2(GRIP, h - GRIP, w - 2 * GRIP, GRIP)
			DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT: r = Rect2(w - GRIP, h - GRIP, GRIP, GRIP)
		grip.position = r.position
		grip.size = r.size
		# No resizing while maximized
		grip.visible = mode == Window.MODE_WINDOWED


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_layout_grips()
		if frame:
			frame.set_maximized(mode == Window.MODE_MAXIMIZED)


func _on_grip_input(event: InputEvent, edge: int) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mode == Window.MODE_WINDOWED:
		DisplayServer.window_start_resize(edge, get_window_id())


# ============================================================================
# Hosting the frame
# ============================================================================

func host(p_frame: DeviceFrame) -> void:
	frame = p_frame
	if frame.get_parent():
		frame.get_parent().remove_child(frame)
	add_child(frame)
	move_child(frame, 0)  # grips stay on top
	frame.visible = true  # an attached frame is hidden while another view shows
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.set_mode(true)
	frame.title_bar_pressed.connect(_on_title_bar_pressed)
	frame.minimize_requested.connect(_on_minimize_requested)
	frame.maximize_requested.connect(_on_maximize_requested)
	frame.minimum_size_changed.connect(_update_min_size)
	frame.fit_requested.connect(_on_fit_requested)
	frame.active_device_changed.connect(_on_active_device_changed)
	title = frame.get_title()
	_update_min_size()


## Give the frame up (attach); remembers the rect for the next show.
func release_frame() -> DeviceFrame:
	var released := frame
	if released == null:
		return null
	_remember_rect()
	released.title_bar_pressed.disconnect(_on_title_bar_pressed)
	released.minimize_requested.disconnect(_on_minimize_requested)
	released.maximize_requested.disconnect(_on_maximize_requested)
	released.minimum_size_changed.disconnect(_update_min_size)
	released.fit_requested.disconnect(_on_fit_requested)
	released.active_device_changed.disconnect(_on_active_device_changed)
	remove_child(released)
	frame = null
	return released


## Show at the remembered rect, or centered on the main window the first time.
func show_frame() -> void:
	if last_rect.has_area():
		size = last_rect.size
		position = last_rect.position
		show()
	else:
		popup_centered(size)
	_update_min_size()


## Show with the title bar under `screen_pos` (a torn-off tab).
func show_at(screen_pos: Vector2i) -> void:
	position = screen_pos - Vector2i(40, int(DeviceFrame.TITLE_HEIGHT / 2))
	show()
	_update_min_size()


func refresh_title() -> void:
	if frame:
		title = frame.get_title()


func raise_frame() -> void:
	if mode == Window.MODE_MINIMIZED:
		mode = Window.MODE_WINDOWED
	if not visible:
		show_frame()
	move_to_foreground()
	grab_focus()


func _remember_rect() -> void:
	if visible and mode == Window.MODE_WINDOWED:
		last_rect = Rect2i(position, size)


func _on_visibility_changed() -> void:
	if not visible:
		_remember_rect()
	if frame:
		frame.refresh_visibility()


# ============================================================================
# Size
# ============================================================================

## The minimum follows the active page (REQ-002); a smaller window grows to it.
func _update_min_size() -> void:
	if frame == null:
		return
	var min_px := Vector2i(frame.get_combined_minimum_size().ceil())
	min_size = min_px
	if size.x < min_px.x or size.y < min_px.y:
		size = Vector2i(maxi(size.x, min_px.x), maxi(size.y, min_px.y))


func _on_active_device_changed(_dev: DeviceInstance) -> void:
	title = frame.get_title()
	_update_min_size.call_deferred()


## A plugin GUI opened or resized itself: show all of it, within the screen.
func _on_fit_requested(frame_size: Vector2) -> void:
	if mode != Window.MODE_WINDOWED:
		return
	var want := Vector2i(frame_size.ceil())
	var screen := DisplayServer.screen_get_usable_rect(current_screen)
	if screen.has_area():
		want = want.min(screen.size)
	want = want.max(min_size)
	if want == size:
		return
	size = want
	# Keep it on screen
	if screen.has_area():
		position = position.clamp(screen.position, screen.end - size)


func _on_title_bar_pressed() -> void:
	if mode == Window.MODE_WINDOWED:
		DisplayServer.window_start_drag(get_window_id())


func _on_minimize_requested() -> void:
	mode = Window.MODE_MINIMIZED


func _on_maximize_requested() -> void:
	mode = Window.MODE_WINDOWED if mode == Window.MODE_MAXIMIZED else Window.MODE_MAXIMIZED
