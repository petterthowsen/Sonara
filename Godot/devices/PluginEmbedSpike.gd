# SPIKE (branch spike/plugin-gui-embed): embed a CLAP plugin GUI into Godot windows by
# having the engine reparent its X11 host window. Throwaway code: it sends OSC directly
# and hard-wires itself into DeviceWindowManager.
#
# F9 cycles the most recently opened plugin GUI through:
#   FLOATING  - the engine's own decorated winit window (current behavior)
#   ATTACHED  - X11 child of the main window, over a black placeholder covering Primary
#   WINDOW    - X11 child of a borderless Godot window with a custom title bar
# A plugin larger than its viewport is clipped and scrolled with the Godot scrollbars;
# a smaller one is centered.
extends Node

enum Mode { FLOATING, ATTACHED, WINDOW }

const TITLE_H := 28
const BAR := 12

var logger: Log = Log.make("PluginEmbedSpike")

var _dev: DeviceInstance
var _mode := Mode.FLOATING
var _plugin_size := Vector2i.ZERO

## ATTACHED / WINDOW: black area the plugin sits over, plus scrollbars
var _placeholder: Control
var _hbar: HScrollBar
var _vbar: VScrollBar
## WINDOW: the borderless Godot window
var _window: Window


func on_gui_opened(dev: DeviceInstance) -> void:
	if _dev and _dev != dev:
		_set_mode(Mode.FLOATING)
		_stop_listening()
	_dev = dev
	_mode = Mode.FLOATING
	_plugin_size = Vector2i.ZERO
	AudioEngineOSC.listen(dev.osc_addr("gui/size"), _on_gui_size)
	logger.info("tracking %s; F9 cycles floating/attached/window. Display driver: %s"
		% [dev.get_display_name(), DisplayServer.get_name()])


## Called before gui/close: get the plugin out of our windows before they are freed.
func before_close(dev: DeviceInstance) -> void:
	if dev == _dev and _mode != Mode.FLOATING:
		AudioEngineOSC.send(_dev.osc_addr("gui/unembed"), [])
		_mode = Mode.FLOATING


func on_gui_closed(dev: DeviceInstance) -> void:
	if dev != _dev:
		return
	_teardown()
	_stop_listening()
	_dev = null
	_mode = Mode.FLOATING


func _stop_listening() -> void:
	if _dev:
		AudioEngineOSC.unlisten(_dev.osc_addr("gui/size"), _on_gui_size)


func _on_gui_size(args: Array) -> void:
	if args.size() >= 2:
		_plugin_size = Vector2i(int(args[0]), int(args[1]))
		logger.info("plugin size %s" % _plugin_size)
		if _window:
			_window.size = Vector2i(_plugin_size.x, _plugin_size.y + TITLE_H)
		_relayout()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		if _dev == null:
			logger.warn("no plugin GUI open")
			return
		_set_mode((_mode + 1) % 3)
		get_viewport().set_input_as_handled()


func _set_mode(mode: Mode) -> void:
	if mode == _mode:
		return
	logger.info("mode %s -> %s" % [Mode.keys()[_mode], Mode.keys()[mode]])
	# Embedded -> embedded reparents directly; only going floating hands it back to the WM.
	if _mode != Mode.FLOATING and mode == Mode.FLOATING:
		AudioEngineOSC.send(_dev.osc_addr("gui/unembed"), [])
	var old_window := _window
	_window = null
	if _placeholder and is_instance_valid(_placeholder):
		_placeholder.queue_free()
	_placeholder = null
	_mode = mode
	match mode:
		Mode.ATTACHED:
			_build_placeholder(Sonara.editor.primary_panel)
			await get_tree().process_frame # let the placeholder lay out
			_embed(DisplayServer.MAIN_WINDOW_ID)
		Mode.WINDOW:
			_build_window()
			await get_tree().process_frame
			_embed(_window.get_window_id())
	# Free the old Godot window only after the plugin left it: destroying an X window
	# destroys its children, the plugin's GUI included.
	if old_window and is_instance_valid(old_window):
		await get_tree().create_timer(0.2).timeout
		old_window.queue_free()


func _embed(window_id: int) -> void:
	var xid := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window_id)
	logger.info("embedding into window %d, xid 0x%x" % [window_id, xid])
	var r := _viewport_rect()
	AudioEngineOSC.send(_dev.osc_addr("gui/embed"),
		[xid, r.position.x, r.position.y, r.size.x, r.size.y, int(_hbar.value), int(_vbar.value)])


# ============================================================================
# Layout
# ============================================================================

func _build_placeholder(parent: Control) -> void:
	_placeholder = ColorRect.new()
	_placeholder.color = Color.BLACK
	_placeholder.mouse_filter = Control.MOUSE_FILTER_STOP
	_hbar = HScrollBar.new()
	_vbar = VScrollBar.new()
	_placeholder.add_child(_hbar)
	_placeholder.add_child(_vbar)
	_hbar.value_changed.connect(func(_v): _relayout())
	_vbar.value_changed.connect(func(_v): _relayout())
	parent.add_child(_placeholder)
	_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_placeholder.resized.connect(_relayout)


func _build_window() -> void:
	_window = Window.new()
	_window.visible = false
	_window.force_native = true
	_window.borderless = true
	_window.title = _dev.get_display_name()
	var size := _plugin_size if _plugin_size != Vector2i.ZERO else Vector2i(800, 600)
	_window.size = Vector2i(size.x, size.y + TITLE_H)
	_window.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	_window.close_requested.connect(func(): DeviceWindowManager.close(_dev))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	_window.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = TITLE_H
	bar.gui_input.connect(_on_title_input)
	var row := HBoxContainer.new()
	bar.add_child(row)
	var title := Label.new()
	title.text = "  " + _window.title
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(title)
	for spec in [["Attach", func(): _set_mode(Mode.ATTACHED)],
			["_", func(): _window.mode = Window.MODE_MINIMIZED],
			["X", func(): DeviceWindowManager.close(_dev)]]:
		var b := Button.new()
		b.text = spec[0]
		b.flat = true
		b.pressed.connect(spec[1])
		row.add_child(b)
	root.add_child(bar)

	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	get_tree().root.add_child(_window)
	_build_placeholder(body)
	_window.show()


func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		DisplayServer.window_start_drag(_window.get_window_id())


## Plugin viewport in the host window's pixels: the placeholder minus visible scrollbars,
## or a centered plugin-sized rect when the plugin is smaller.
func _viewport_rect() -> Rect2i:
	var area := _placeholder.get_global_rect()
	var psize := Vector2(_plugin_size) if _plugin_size != Vector2i.ZERO else area.size
	var need_h := psize.x > area.size.x
	var need_v := psize.y > area.size.y
	# a scrollbar eats space and can make the other one necessary
	need_h = need_h or (need_v and psize.x > area.size.x - BAR)
	need_v = need_v or (need_h and psize.y > area.size.y - BAR)
	var view := Rect2(area.position, area.size - Vector2(BAR if need_v else 0, BAR if need_h else 0))
	_layout_bar(_hbar, need_h, psize.x, view.size.x)
	_layout_bar(_vbar, need_v, psize.y, view.size.y)
	_hbar.position = Vector2(0, _placeholder.size.y - BAR)
	_hbar.size = Vector2(view.size.x, BAR)
	_vbar.position = Vector2(_placeholder.size.x - BAR, 0)
	_vbar.size = Vector2(BAR, view.size.y)
	# center along any axis that fits
	if not need_h:
		view.position.x += (view.size.x - psize.x) / 2.0
		view.size.x = psize.x
	if not need_v:
		view.position.y += (view.size.y - psize.y) / 2.0
		view.size.y = psize.y
	# canvas -> window pixels (content scale)
	var px := _placeholder.get_viewport().get_final_transform() * view
	return Rect2i(px.position.round(), px.size.round())


func _layout_bar(bar: Range, needed: bool, content: float, page: float) -> void:
	bar.visible = needed
	bar.max_value = content
	bar.page = page
	if not needed:
		bar.set_value_no_signal(0)


func _relayout() -> void:
	if _placeholder == null or _dev == null or _mode == Mode.FLOATING:
		return
	var r := _viewport_rect()
	AudioEngineOSC.send(_dev.osc_addr("gui/bounds"),
		[r.position.x, r.position.y, r.size.x, r.size.y, int(_hbar.value), int(_vbar.value)])


func _teardown() -> void:
	if _placeholder and is_instance_valid(_placeholder):
		_placeholder.queue_free()
	_placeholder = null
	if _window and is_instance_valid(_window):
		_window.queue_free()
	_window = null
