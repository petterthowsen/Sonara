## Shows a CLAP plugin's native GUI in a device frame tab (spec 022, ADR 0016).
##
## With embedding on, the engine reparents the plugin's X11 host window into the Godot window this
## slot is in, and clips it to the slot's viewport. The slot draws black behind it, adds scrollbars
## when the GUI is bigger than the area, and drives the engine through DeviceInstance:
## open/embed when it first shows or moves to another window, bounds on layout and scroll changes,
## visibility from is_visible_in_tree(). It compares against what it last sent once per frame, so
## every cause (resize, attach, tab switch, scrolling) goes through the same path.
##
## With embedding off (or a plugin that refused it), the plugin runs in its own window and the slot
## shows a note with a "Show window" button instead.
class_name PluginGuiSlot extends Control

## A floating frame should grow or shrink to show `size` (canvas units): the GUI opened, or a
## fixed-size GUI resized itself (REQ-019).
signal fit_requested(size: Vector2)
## The plugin opened in its own window although embedding is on; the frame can't attach it.
signal floating_changed(floating: bool)

## Scrollbar thickness, canvas units
const BAR := 12.0
## Smallest area the slot asks for; bigger GUIs scroll.
const MIN_SIZE := Vector2(160, 90)

enum Mode { CLOSED, EMBEDDED, OWN_WINDOW }

var logger: Log = Log.make("PluginGuiSlot")

var device: DeviceInstance
var _mode := Mode.CLOSED
## Plugin host died: show the crash note until it reports "ready" again.
var _crashed := false
## Engine connection lost: show "unavailable".
var _engine_lost := false
## close() ran: stop driving the engine.
var _closing := false
## Last values sent while embedded, so only changes go out.
var _sent_xid := 0
var _sent_rect := Rect2i()
var _sent_scroll := Vector2i.ZERO
var _sent_visible := true
## Shown on the previous frame: a closed GUI opens when its tab becomes shown, not while it stays
## shown (the user closed the plugin's own window), unless _open_now asks for it.
var _was_visible := false
var _open_now := false
## Last size asked of a resizable plugin, and the frame that asked (one request per frame).
var _requested_size := Vector2i.ZERO
var _fit_pending := false

var _hbar: HScrollBar
var _vbar: VScrollBar
var _note: VBoxContainer
var _note_label: Label
var _note_button: Button


# ============================================================================
# Layout math
# ============================================================================

## Where a `gui_size` GUI shows in `area`, scrolled by `scroll` (all canvas units).
## Returns { view: Rect2, need_h: bool, need_v: bool, scroll: Vector2, max_scroll: Vector2 }:
## - `view` is the visible part of the GUI, inside `area`, never under a scrollbar.
## - An axis that fits is centered and doesn't scroll; one that doesn't fits the area and scrolls.
## - A scrollbar takes BAR from the other axis, which can make that one need a scrollbar too.
## - `scroll` is clamped to 0..max_scroll.
## An unknown (zero) GUI size fills the area.
static func compute_viewport(area: Rect2, gui_size: Vector2, scroll: Vector2, bar: float = BAR) -> Dictionary:
	var gui := gui_size if gui_size.x > 0 and gui_size.y > 0 else area.size
	var need_h := gui.x > area.size.x
	var need_v := gui.y > area.size.y
	need_h = need_h or (need_v and gui.x > area.size.x - bar)
	need_v = need_v or (need_h and gui.y > area.size.y - bar)
	var avail := Vector2(
		maxf(area.size.x - (bar if need_v else 0.0), 0.0),
		maxf(area.size.y - (bar if need_h else 0.0), 0.0))
	var max_scroll := Vector2(
		maxf(gui.x - avail.x, 0.0) if need_h else 0.0,
		maxf(gui.y - avail.y, 0.0) if need_v else 0.0)
	var clamped := Vector2(clampf(scroll.x, 0.0, max_scroll.x), clampf(scroll.y, 0.0, max_scroll.y))
	var view := Rect2(area.position, avail)
	if not need_h:
		view.position.x += (avail.x - gui.x) / 2.0
		view.size.x = gui.x
	if not need_v:
		view.position.y += (avail.y - gui.y) / 2.0
		view.size.y = gui.y
	return {
		"view": view,
		"need_h": need_h,
		"need_v": need_v,
		"scroll": clamped,
		"max_scroll": max_scroll,
	}


# ============================================================================
# Lifecycle
# ============================================================================

func _init() -> void:
	name = "PluginGuiSlot"
	custom_minimum_size = MIN_SIZE
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_hbar = HScrollBar.new()
	_vbar = VScrollBar.new()
	for bar in [_hbar, _vbar]:
		bar.visible = false
		bar.step = 1.0
		add_child(bar)
	_note = VBoxContainer.new()
	_note.alignment = BoxContainer.ALIGNMENT_CENTER
	_note.add_theme_constant_override("separation", 8)
	_note_label = Label.new()
	_note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_child(_note_label)
	_note_button = Button.new()
	_note_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_note_button.pressed.connect(_on_note_button_pressed)
	_note.add_child(_note_button)
	_note.visible = false
	add_child(_note)
	_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_note.offset_left = 16
	_note.offset_right = -16


func bind(dev: DeviceInstance) -> void:
	device = dev
	_crashed = dev.loading_state.begins_with("crashed:")
	dev.gui_opened.connect(_on_gui_opened)
	dev.gui_size_changed.connect(_on_gui_size_changed)
	dev.plugin_gui_closed.connect(_on_plugin_gui_closed)
	dev.crashed.connect(_on_crashed)
	dev.loading_state_changed.connect(_on_loading_state_changed)
	AudioEngineOSC.engine_disconnected.connect(_on_engine_disconnected)
	AudioEngineOSC.engine_connected.connect(_on_engine_connected)


func _exit_tree() -> void:
	# Freed without close() (e.g. the app quits): leave the engine's GUI alone, just stop listening.
	if is_queued_for_deletion():
		_unbind()


func _unbind() -> void:
	if device == null:
		return
	for pair in [
			[device.gui_opened, _on_gui_opened],
			[device.gui_size_changed, _on_gui_size_changed],
			[device.plugin_gui_closed, _on_plugin_gui_closed],
			[device.crashed, _on_crashed],
			[device.loading_state_changed, _on_loading_state_changed],
			[AudioEngineOSC.engine_disconnected, _on_engine_disconnected],
			[AudioEngineOSC.engine_connected, _on_engine_connected]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])


## Close the plugin GUI (the frame is closing). Returns true when a GUI was open, so the caller
## can wait for `plugin_gui_closed` before freeing the window it was embedded in.
func close() -> bool:
	_closing = true
	set_process(false)
	var was_open := _mode != Mode.CLOSED
	if was_open and device:
		device.close_gui()
	_mode = Mode.CLOSED
	_unbind()
	return was_open


## The GUI is open in this slot (embedded, or in its own window).
func is_gui_open() -> bool:
	return _mode != Mode.CLOSED


## The plugin runs in its own window although embedding is on (it refused embedding).
func is_floating() -> bool:
	return device != null and device.gui_floating and _mode == Mode.OWN_WINDOW


## Embedding applies: the setting is on and available, and this window has an X11 handle.
func _want_embed(xid: int) -> bool:
	return xid != 0 and DeviceWindowManager.embedding_enabled() and not (device.gui_floating and _mode != Mode.CLOSED)


func _window_xid() -> int:
	var window := get_window()
	if window == null:
		return 0
	return DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())


func _shown() -> bool:
	var window := get_window()
	return is_visible_in_tree() and window != null and window.visible and size.x >= 1 and size.y >= 1


# ============================================================================
# Driving the engine
# ============================================================================

func _process(_delta: float) -> void:
	if device == null or _closing:
		return
	if _crashed or _engine_lost:
		_update_note()
		return
	var shown := _shown()
	var xid := _window_xid()
	var embed := _want_embed(xid)
	var layout := _layout()
	var rect: Rect2i = layout.rect
	var scroll: Vector2i = layout.scroll

	match _mode:
		Mode.CLOSED:
			if shown and (not _was_visible or _open_now):
				_open_now = false
				if embed:
					logger.info("open %s embedded in 0x%x at %s" % [device.get_display_name(), xid, rect])
					device.open_gui_embedded(xid, rect)
					_mode = Mode.EMBEDDED
					_remember(xid, rect, scroll, true)
				elif device.active:
					device.open_gui()
					_mode = Mode.OWN_WINDOW
		Mode.EMBEDDED:
			if not embed:
				# Embedding switched off, or this window lost its handle: hand it back to the WM.
				device.unembed_gui()
				_mode = Mode.OWN_WINDOW
			elif xid != _sent_xid:
				# The frame moved to another window (attach, detach, tear-off).
				device.embed_gui(xid, rect, scroll)
				_remember(xid, rect, scroll, _sent_visible)
			elif rect != _sent_rect or scroll != _sent_scroll:
				device.set_gui_bounds(rect, scroll)
				_sent_rect = rect
				_sent_scroll = scroll
			if _mode == Mode.EMBEDDED and shown != _sent_visible:
				device.set_gui_visible(shown)
				_sent_visible = shown
			if _mode == Mode.EMBEDDED and shown:
				_request_fill_size()
		Mode.OWN_WINDOW:
			if embed and shown:
				# Embedding switched on while the GUI is in its own window.
				device.embed_gui(xid, rect, scroll)
				_mode = Mode.EMBEDDED
				_remember(xid, rect, scroll, _sent_visible)
			elif shown and not _was_visible:
				# Selecting the tab raises the plugin's own window (REQ-017).
				device.open_gui()
	_was_visible = shown
	_update_note()


func _remember(xid: int, rect: Rect2i, scroll: Vector2i, visible_sent: bool) -> void:
	_sent_xid = xid
	_sent_rect = rect
	_sent_scroll = scroll
	_sent_visible = visible_sent


## Lay out the scrollbars for the current size and return the viewport in window pixels and the
## scroll offset in GUI pixels.
func _layout() -> Dictionary:
	var scale := _canvas_to_window_scale()
	var gui := Vector2(device.gui_size) / scale if device and device.gui_size != Vector2i.ZERO else Vector2.ZERO
	var embedded := _mode == Mode.EMBEDDED or _mode == Mode.CLOSED
	if not embedded:
		gui = Vector2.ZERO
	var vp := compute_viewport(Rect2(Vector2.ZERO, size), gui, Vector2(_hbar.value, _vbar.value))
	_layout_bar(_hbar, vp.need_h, gui.x, vp.view.size.x, vp.scroll.x)
	_layout_bar(_vbar, vp.need_v, gui.y, vp.view.size.y, vp.scroll.y)
	_hbar.position = Vector2(0, size.y - BAR)
	_hbar.size = Vector2(vp.view.size.x if vp.need_v else size.x, BAR)
	_vbar.position = Vector2(size.x - BAR, 0)
	_vbar.size = Vector2(BAR, vp.view.size.y if vp.need_h else size.y)
	var view_rect: Rect2 = vp.view
	var global := get_global_transform() * view_rect
	var px := get_viewport().get_final_transform() * global
	return {
		"rect": Rect2i(px.position.round(), px.size.round()),
		"scroll": Vector2i((vp.scroll * scale).round()),
	}


func _layout_bar(bar: Range, needed: bool, content: float, page: float, value: float) -> void:
	bar.visible = needed and _mode != Mode.OWN_WINDOW
	bar.max_value = content
	bar.page = page
	bar.set_value_no_signal(value if needed else 0.0)


## Window pixels per canvas unit (content scale).
func _canvas_to_window_scale() -> float:
	var vp := get_viewport()
	if vp == null:
		return 1.0
	var s := vp.get_final_transform().get_scale().x
	return s if s > 0.0 else 1.0


## A resizable plugin is asked to fill the area (REQ-020), at most once per frame and only when
## the area changed since the last request.
func _request_fill_size() -> void:
	if not device.gui_resizable:
		return
	var want := Vector2i((size * _canvas_to_window_scale()).floor())
	if want.x < 1 or want.y < 1 or want == _requested_size or want == device.gui_size:
		return
	_requested_size = want
	device.request_gui_size(want)


# ============================================================================
# Engine answers
# ============================================================================

func _on_gui_opened(gui_size: Vector2i, resizable: bool, floating: bool) -> void:
	if _closing:
		return
	_requested_size = Vector2i.ZERO
	if floating:
		# The plugin refused embedding (REQ-024): it's in its own window, the engine dropped the host.
		logger.info("%s opened in its own window (no embedded mode)" % device.get_display_name())
		_mode = Mode.OWN_WINDOW
	elif _mode == Mode.CLOSED:
		# Opened by someone else (e.g. reopened after a crash) before we sent anything.
		_mode = Mode.OWN_WINDOW
	floating_changed.emit(floating)
	if _mode == Mode.EMBEDDED and not resizable:
		fit_requested.emit(Vector2(gui_size) / _canvas_to_window_scale())
	elif _mode == Mode.EMBEDDED and not _fit_pending:
		# A resizable GUI starts at the size it likes; the frame fits it once, then drives it.
		_fit_pending = true
		fit_requested.emit(Vector2(gui_size) / _canvas_to_window_scale())
	queue_redraw()


func _on_gui_size_changed(gui_size: Vector2i) -> void:
	if _closing:
		return
	if _mode == Mode.EMBEDDED and not device.gui_resizable:
		fit_requested.emit(Vector2(gui_size) / _canvas_to_window_scale())
	queue_redraw()


func _on_plugin_gui_closed() -> void:
	if _closing:
		return
	# Closed from its own window (or by the engine): it opens again when the tab is next selected,
	# or from the note's button. _was_visible stays as it is, so it doesn't reopen right away.
	_mode = Mode.CLOSED
	_fit_pending = false
	floating_changed.emit(false)


func _on_crashed(_reason: String, _stderr: String) -> void:
	_crashed = true
	_mode = Mode.CLOSED
	_fit_pending = false
	floating_changed.emit(false)


## After a Reload the plugin is "ready" again: reopen (embedded) on the next frame (REQ-026).
func _on_loading_state_changed(state: String) -> void:
	if state == "ready" and _crashed:
		_crashed = false
		_mode = Mode.CLOSED
		_was_visible = false


func _on_engine_disconnected() -> void:
	_engine_lost = true
	_mode = Mode.CLOSED
	_fit_pending = false


func _on_engine_connected() -> void:
	# A restarted engine has no GUI open; the next shown frame opens it again.
	_engine_lost = false
	_mode = Mode.CLOSED
	_was_visible = false


# ============================================================================
# Notes
# ============================================================================

func _update_note() -> void:
	var text := ""
	var button := ""
	if _engine_lost:
		text = "Plugin window unavailable: the audio engine isn't running."
	elif _crashed:
		text = "%s crashed." % device.get_display_name()
		button = "Reload"
	elif _mode == Mode.OWN_WINDOW:
		text = "%s is in its own window." % device.get_display_name()
		button = "Show window"
		if device.gui_floating:
			text += "\nThis plugin can't be embedded."
	elif _mode == Mode.CLOSED and _was_visible:
		text = "%s's window is closed." % device.get_display_name()
		button = "Open"
	_note.visible = not text.is_empty()
	if _note.visible:
		_note_label.text = text
		_note_button.text = button
		_note_button.visible = not button.is_empty()


func _on_note_button_pressed() -> void:
	if device == null:
		return
	if _crashed:
		device.reload()
	elif _mode == Mode.CLOSED:
		_open_now = true
	else:
		device.open_gui()


## The note shown instead of the plugin, or "" while the plugin shows (for tests and tooltips).
func get_note_text() -> String:
	return _note_label.text if _note.visible else ""


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
