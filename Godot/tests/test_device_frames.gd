# test_device_frames.gd
# Headless tests for device frames (spec 022): PluginGuiSlot viewport math, DeviceFrame tabs and
# pages, and DeviceWindowManager grouping, chain edits, attach/detach, tear-off and closing.
#
# Frames, the manager and DeviceInstance reference autoloads by bare name, so scripts are load()ed
# inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_device_frames.gd -- --test
extends TestBase

const EQ_ID := "sonara.builtin.eq"
const SPECTRUM_ID := "sonara.builtin.spectrum_analyzer"

var _slot_script: GDScript
var _frame_script: GDScript
var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _view_factory: GDScript
var _manager: Node
var _settings: Node
var _host: Control


## Stands in for the Editor's Primary area.
class FakeAttachHost extends Control:
	var attached: Control = null
	var shown_count := 0

	func attach_frame(frame: Control) -> void:
		attached = frame
		if frame.get_parent():
			frame.get_parent().remove_child(frame)
		add_child(frame)

	func detach_frame(frame: Control) -> void:
		if frame == attached:
			attached = null
			remove_child(frame)

	func show_attached_frame() -> void:
		shown_count += 1


func suite_name() -> String:
	return "Device frame tests"


func run_tests() -> void:
	_slot_script = load("res://devices/frame/PluginGuiSlot.gd")
	_frame_script = load("res://devices/frame/DeviceFrame.gd")
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_view_factory = load("res://devices/DeviceViewFactory.gd")
	_manager = root.get_node("DeviceWindowManager")
	_settings = root.get_node("Settings")
	_host = FakeAttachHost.new()
	_host.size = Vector2(1200, 700)
	root.add_child(_host)
	_manager.attach_host = _host

	_test_viewport_fits_centered()
	_test_viewport_larger_scrolls()
	_test_viewport_one_bar_wide()
	_test_viewport_scroll_clamped()
	_test_viewport_unknown_size_fills()
	await _test_frame_chrome()
	await _test_frame_pages()
	await _test_tab_click_does_not_tear_off()
	await _test_per_channel()
	await _test_chain_edits()
	await _test_per_device()
	await _test_nested_own_frame()
	await _test_toggle_semantics()
	await _test_attach_detach()
	await _test_tear_off()
	await _test_close_frees_window()
	await _test_window_min_size()
	await _test_plugin_tab_without_embedding()


# ============================================================================
# Helpers
# ============================================================================

func _builtin(device_id: String, display: String) -> Object:
	var device = _device_script.new(device_id, display, _device_script.DeviceCategory.Effect)
	_view_factory.register_builtin_views(device)
	return device


func _plain_instrument() -> Object:
	return _device_script.new("test.frames.synth", "Synth", _device_script.DeviceCategory.Instrument)


func _plugin_device() -> Object:
	return _device_script.new("test.frames.clap", "Room", _device_script.DeviceCategory.Effect, _device_script.DeviceType.CLAP)


## A channel holding Synth (nothing to show) → EQ → Spectrum, as the design's Polysynth → EQ → Reverb.
func _channel_with_chain() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Lead").channel
	var synth: Object = _device_instance_script.new(_plain_instrument(), ch.id, 0)
	var eq: Object = _device_instance_script.new(_builtin(EQ_ID, "EQ"), ch.id, 0)
	var spectrum: Object = _device_instance_script.new(_builtin(SPECTRUM_ID, "Spectrum"), ch.id, 0)
	ch.add_device(synth)
	ch.add_device(eq)
	ch.add_device(spectrum)
	return {"project": project, "ch": ch, "synth": synth, "eq": eq, "spectrum": spectrum}


func _close_all_frames() -> void:
	for frame in _manager.get_frames():
		_manager.close_frame(frame)
	await process_frame
	await process_frame


func _set_grouping(value: String) -> void:
	root.get_node("Sonara").set_config("devices/window_grouping", value)


func _titles(frame: Object) -> Array:
	return Array(frame.get_tab_titles())


# ============================================================================
# PluginGuiSlot.compute_viewport (T-007)
# ============================================================================

func _test_viewport_fits_centered() -> void:
	var vp: Dictionary = _slot_script.compute_viewport(Rect2(0, 0, 1200, 600), Vector2(920, 345), Vector2.ZERO)
	_assert(not vp.need_h and not vp.need_v, "920x345 in 1200x600 needs no scrollbars")
	_assert(vp.view == Rect2(140, 127.5, 920, 345), "920x345 is centered in 1200x600 (got %s)" % vp.view)
	vp = _slot_script.compute_viewport(Rect2(10, 30, 1200, 600), Vector2(920, 345), Vector2.ZERO)
	_assert(vp.view.position == Vector2(150, 157.5), "the area's position offsets the view (got %s)" % vp.view)


func _test_viewport_larger_scrolls() -> void:
	var vp: Dictionary = _slot_script.compute_viewport(Rect2(0, 0, 600, 300), Vector2(920, 345), Vector2.ZERO, 12)
	_assert(vp.need_h and vp.need_v, "920x345 in 600x300 needs both scrollbars")
	_assert(vp.view == Rect2(0, 0, 588, 288), "the view leaves room for both scrollbars (got %s)" % vp.view)
	_assert(vp.max_scroll == Vector2(332, 57), "max scroll is GUI minus view (got %s)" % vp.max_scroll)
	vp = _slot_script.compute_viewport(Rect2(0, 0, 600, 400), Vector2(920, 345), Vector2.ZERO, 12)
	_assert(vp.need_h and not vp.need_v, "920x345 in 600x400: only horizontal")
	_assert(vp.view == Rect2(0, (388 - 345) / 2.0, 600, 345), "vertical axis stays centered above the bar (got %s)" % vp.view)


func _test_viewport_one_bar_wide() -> void:
	# Height doesn't fit, so a vertical bar takes 12 px of width: 920 no longer fits in 920.
	var vp: Dictionary = _slot_script.compute_viewport(Rect2(0, 0, 920, 340), Vector2(920, 345), Vector2.ZERO, 12)
	_assert(vp.need_v and vp.need_h, "a vertical bar in an exactly-wide area makes a horizontal bar needed")
	# One bar wider and it fits beside the vertical bar.
	vp = _slot_script.compute_viewport(Rect2(0, 0, 932, 340), Vector2(920, 345), Vector2.ZERO, 12)
	_assert(vp.need_v and not vp.need_h, "an area one bar wider needs only the vertical bar")
	_assert(vp.view == Rect2(0, 0, 920, 340), "the GUI fills the width beside the bar (got %s)" % vp.view)
	vp = _slot_script.compute_viewport(Rect2(0, 0, 920, 345), Vector2(920, 345), Vector2.ZERO, 12)
	_assert(not vp.need_v and not vp.need_h and vp.view == Rect2(0, 0, 920, 345), "an exact fit needs no bars")


func _test_viewport_scroll_clamped() -> void:
	var vp: Dictionary = _slot_script.compute_viewport(Rect2(0, 0, 600, 300), Vector2(920, 345), Vector2(1000, -5), 12)
	_assert(vp.scroll == Vector2(332, 0), "scroll is clamped to 0..max (got %s)" % vp.scroll)
	vp = _slot_script.compute_viewport(Rect2(0, 0, 1200, 600), Vector2(920, 345), Vector2(50, 50), 12)
	_assert(vp.scroll == Vector2.ZERO, "a GUI that fits doesn't scroll")


func _test_viewport_unknown_size_fills() -> void:
	var vp: Dictionary = _slot_script.compute_viewport(Rect2(5, 5, 400, 300), Vector2.ZERO, Vector2.ZERO)
	_assert(vp.view == Rect2(5, 5, 400, 300) and not vp.need_h and not vp.need_v, "an unknown GUI size fills the area")


# ============================================================================
# DeviceFrame (T-008)
# ============================================================================

func _test_frame_chrome() -> void:
	var c := _channel_with_chain()
	var frame: Object = _frame_script.new()
	root.add_child(frame)
	frame.set_title("Lead — EQ")
	frame.set_devices([c.eq])
	_assert(frame.get_title() == "Lead — EQ", "title text is shown")
	_assert(not frame.is_tab_strip_visible(), "one device: no tab strip (REQ-014)")
	_assert(frame._minimize_button.visible and frame._maximize_button.visible, "floating: minimize and maximize shown")
	frame.set_mode(false)
	_assert(not frame._minimize_button.visible and not frame._maximize_button.visible, "attached: minimize and maximize hidden")
	_assert(frame._attach_button.visible and frame._close_button.visible, "attached: detach and close stay")
	frame.set_devices([c.eq, c.spectrum])
	_assert(frame.is_tab_strip_visible(), "two devices: tab strip shown")
	frame.close_all()
	frame.queue_free()
	await process_frame


func _test_frame_pages() -> void:
	var c := _channel_with_chain()
	var frame: Object = _frame_script.new()
	root.add_child(frame)
	frame.set_devices([c.eq, c.spectrum])
	await process_frame
	var eq_page: Object = frame.get_page(c.eq)
	_assert(eq_page != null and frame.get_page(c.spectrum) == null, "only the selected tab has a page")
	_assert(frame._shown_views.has(eq_page), "the shown page's view got show_view()")
	var eq_id: int = eq_page.get_instance_id()
	frame.select_device(c.spectrum)
	await process_frame
	var sp_page: Object = frame.get_page(c.spectrum)
	_assert(sp_page != null and sp_page.visible and not eq_page.visible, "selecting shows only the new page")
	_assert(not frame._shown_views.has(eq_page) and frame._shown_views.has(sp_page), "hide_view on the old, show_view on the new")
	frame.select_device(c.eq)
	await process_frame
	_assert(frame.get_page(c.eq).get_instance_id() == eq_id, "reselecting keeps the same view (one per page)")
	frame.visible = false
	await process_frame
	_assert(frame._shown_views.is_empty(), "a hidden frame hides its views")
	frame.visible = true
	await process_frame
	_assert(frame._shown_views.has(eq_page), "showing the frame shows the selected view again")
	frame.close_all()
	frame.queue_free()
	await process_frame


func _tab_event(pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	return ev


func _test_tab_click_does_not_tear_off() -> void:
	var c := _channel_with_chain()
	var frame: Object = _frame_script.new()
	root.add_child(frame)
	frame.size = Vector2(600, 400)
	frame.set_devices([c.eq, c.spectrum])
	await process_frame
	await process_frame
	var torn: Array = []
	frame.tab_torn_off.connect(func(dev, _pos): torn.append(dev))
	var tab_rect: Rect2 = frame._tabs.get_tab_rect(1)
	var on_tab := tab_rect.get_center()
	frame._on_tabs_input(_tab_event(true, on_tab))
	frame._on_tabs_input(_tab_event(false, on_tab + Vector2(2, 1)))
	_assert(torn.is_empty(), "clicking a tab doesn't tear it off")
	frame._on_tabs_input(_tab_event(true, on_tab))
	frame._on_tabs_input(_tab_event(false, on_tab + Vector2(0, frame.size.y + 200)))
	_assert(torn == [c.spectrum], "dragging a tab well outside the frame tears it off (got %s)" % [torn])
	frame.close_all()
	frame.queue_free()
	await process_frame


# ============================================================================
# DeviceWindowManager (T-010)
# ============================================================================

func _test_per_channel() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	_manager.open(c.eq)
	await process_frame
	var frames: Array = _manager.get_frames()
	_assert(frames.size() == 1, "opening EQ creates one frame")
	var frame: Object = frames[0]
	_assert(frame.channel == c.ch, "it is the channel frame")
	_assert(_titles(frame) == ["EQ", "Spectrum"], "tabs for the chain devices with something to show (got %s)" % [_titles(frame)])
	_assert(frame.get_active_device() == c.eq, "EQ selected")
	_assert(frame.get_title() == "Lead", "a channel frame is titled by its channel (got %s)" % frame.get_title())
	var window: Window = _manager.get_window_for(frame)
	_assert(window != null and window.visible and frame.get_parent() == window, "the frame shows in its own window")
	_manager.open(c.spectrum)
	await process_frame
	_assert(_manager.get_frames().size() == 1 and frame.get_active_device() == c.spectrum, "opening Spectrum selects it in the same frame")
	await _close_all_frames()


func _test_chain_edits() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	_manager.open(c.eq)
	await process_frame
	var frame: Object = _manager.get_frames()[0]
	var eq2: Object = _device_instance_script.new(_builtin(EQ_ID, "EQ"), c.ch.id, 0)
	c.ch.add_device(eq2)
	_assert(frame.get_devices() == [c.eq, c.spectrum, eq2], "an added device gets a tab")
	c.ch.move_device(c.spectrum.position, 1)  # Synth, Spectrum, EQ, EQ 2
	_assert(frame.get_devices() == [c.spectrum, c.eq, eq2], "moving a device reorders the tabs (got %s)" % [_titles(frame)])
	c.eq.set_name("Tone")
	_assert(_titles(frame).has("Tone"), "renaming a device renames its tab (got %s)" % [_titles(frame)])
	c.ch.set_name("Bass")
	await process_frame
	_assert(frame.get_title() == "Bass", "renaming the channel retitles the frame")
	c.ch.remove_device_instance(c.eq)
	_assert(frame.get_devices() == [c.spectrum, eq2], "removing a device drops its tab")
	_assert(frame.get_active_device() != c.eq, "the selection moved off the removed device")
	c.ch.remove_device_instance(c.spectrum)
	_assert(not frame.is_tab_strip_visible(), "one tab left: no tab strip")
	c.ch.remove_device_instance(eq2)
	await process_frame
	_assert(_manager.get_frames().is_empty(), "removing every device closes the frame")
	await _close_all_frames()


func _test_per_device() -> void:
	_set_grouping("Per device")
	var c := _channel_with_chain()
	_manager.open(c.eq)
	_manager.open(c.spectrum)
	await process_frame
	var frames: Array = _manager.get_frames()
	_assert(frames.size() == 2, "per device: two devices give two frames")
	_assert(not frames[0].is_tab_strip_visible() and not frames[1].is_tab_strip_visible(), "per device: no tab strips")
	_assert(frames[0].owner_device == c.eq and frames[0].get_title() == "Lead — EQ", "a device frame is titled channel — device")
	await _close_all_frames()
	_set_grouping("Per channel")


func _test_nested_own_frame() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	var pad: Object = _device_instance_script.new(_builtin(EQ_ID, "EQ"), c.ch.id, 0)
	c.ch.add_device(pad, -1, c.synth)
	_manager.open(c.eq)
	_manager.open(pad)
	await process_frame
	var frames: Array = _manager.get_frames()
	_assert(frames.size() == 2, "a nested device gets its own frame next to the channel frame")
	var pad_frame: Object = _manager.get_frame(pad)
	_assert(pad_frame != null and pad_frame.owner_device == pad and pad_frame.get_devices() == [pad], "the nested frame holds only the pad")
	_assert(not _manager.get_frame(c.eq).has_device(pad), "the channel frame has no tab for nested devices")
	c.ch.remove_device(0, c.synth)
	await process_frame
	_assert(_manager.get_frame(pad) == null, "removing the pad closes its frame")
	await _close_all_frames()


func _test_toggle_semantics() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	_manager.toggle(c.eq)
	await process_frame
	_assert(_manager.is_open(c.eq) and not _manager.is_open(c.spectrum), "the selected tab is open, the other isn't")
	_manager.toggle(c.spectrum)
	await process_frame
	var frame: Object = _manager.get_frames()[0]
	_assert(_manager.get_frames().size() == 1 and frame.get_active_device() == c.spectrum, "toggling another tab selects it")
	_assert(_manager.is_open(c.spectrum) and not _manager.is_open(c.eq), "is_open follows the selection")
	_manager.toggle(c.spectrum)
	await process_frame
	_assert(_manager.get_frames().is_empty(), "toggling the selected tab closes the frame")
	await _close_all_frames()


func _test_attach_detach() -> void:
	_set_grouping("Per device")
	var c := _channel_with_chain()
	_manager.open(c.eq)
	_manager.open(c.spectrum)
	await process_frame
	var eq_frame: Object = _manager.get_frame(c.eq)
	var sp_frame: Object = _manager.get_frame(c.spectrum)
	var view_id: int = eq_frame.get_page(c.eq).get_instance_id()
	var eq_window: Window = _manager.get_window_for(eq_frame)
	eq_window.position = Vector2i(123, 77)
	eq_window.size = Vector2i(700, 420)
	_manager.attach(eq_frame)
	await process_frame
	_assert(_host.attached == eq_frame and eq_frame.get_parent() == _host, "attach moves the frame into the host")
	_assert(not eq_window.visible, "its window hides while attached")
	_assert(not eq_frame.floating and not eq_frame._minimize_button.visible, "an attached frame is in attached mode")
	_assert(eq_frame.get_page(c.eq).get_instance_id() == view_id, "attach keeps the same DeviceView instance")
	_assert(_manager.is_open(c.eq), "an attached device is still open")
	_manager.attach(sp_frame)
	await process_frame
	_assert(_host.attached == sp_frame, "a second attach takes the host (REQ-007)")
	_assert(eq_frame.get_parent() == eq_window and eq_window.visible and eq_frame.floating, "the first frame went back to its window")
	_assert(eq_window.size == Vector2i(700, 420), "at its last floating size (got %s)" % eq_window.size)
	_assert(eq_frame.get_page(c.eq).get_instance_id() == view_id, "detach keeps the same DeviceView instance")
	var shown_before: int = _host.shown_count
	_manager.open(c.spectrum)
	_assert(_host.shown_count == shown_before + 1, "opening an attached device shows the attached frame")
	_manager.detach(sp_frame)
	await process_frame
	_assert(_host.attached == null and _manager.get_attached_frame() == null, "detach empties the host")
	await _close_all_frames()
	_set_grouping("Per channel")


func _test_tear_off() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	_manager.open(c.spectrum)
	await process_frame
	var frame: Object = _manager.get_frames()[0]
	var page_id: int = frame.get_page(c.spectrum).get_instance_id()
	var torn: Object = _manager.tear_off(frame, c.spectrum, Vector2i(300, 200))
	await process_frame
	_assert(torn != null and torn.owner_device == c.spectrum, "tear-off creates a frame for the device")
	_assert(torn.get_page(c.spectrum).get_instance_id() == page_id, "the page moved along (not recreated)")
	_assert(frame.get_devices() == [c.eq, c.spectrum] and frame.is_elsewhere(c.spectrum), "the channel frame keeps the tab, marked elsewhere")
	_assert(frame.get_active_device() == c.eq, "the channel frame shows another tab")
	_assert(_manager.get_frame(c.spectrum) == torn, "the device now shows in the torn-off frame")
	frame.select_device(c.spectrum)
	_assert(frame.get_active_device() == c.eq, "selecting the torn-off tab keeps the channel frame's selection (and raises the other)")
	_manager.open(c.spectrum)
	_assert(_manager.get_frames().size() == 2, "opening the torn-off device doesn't create another frame")
	_manager.close_frame(torn)
	await process_frame
	_assert(not frame.is_elsewhere(c.spectrum), "closing the torn-off frame gives the tab back")
	await _close_all_frames()


func _test_close_frees_window() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	_manager.open(c.eq)
	await process_frame
	var frame: Object = _manager.get_frames()[0]
	var window: Window = _manager.get_window_for(frame)
	var view: Object = frame.get_page(c.eq)
	_manager.close(c.eq)
	_assert(not window.visible, "closing hides the window at once")
	await process_frame
	await process_frame
	_assert(not is_instance_valid(window), "a frame with no plugin GUI frees its window right away")
	_assert(not is_instance_valid(view), "built-in views are freed")
	_assert(not _manager.is_open(c.eq), "the device is closed")


func _test_window_min_size() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	_manager.open(c.eq)
	await process_frame
	await process_frame
	var frame: Object = _manager.get_frames()[0]
	var window: Window = _manager.get_window_for(frame)
	var min_now := Vector2i(frame.get_combined_minimum_size().ceil())
	_assert(window.min_size == min_now, "window min_size follows the frame (%s vs %s)" % [window.min_size, min_now])
	_assert(window.size.x >= min_now.x and window.size.y >= min_now.y, "the window is at least its minimum")
	var eq_min: Vector2 = frame.get_page(c.eq).get_combined_minimum_size()
	_assert(min_now.y >= int(eq_min.y), "the minimum includes the EQ view's minimum height")
	await _close_all_frames()


## Headless isn't X11, so embedding is off: a plugin tab shows the "own window" note.
func _test_plugin_tab_without_embedding() -> void:
	_set_grouping("Per channel")
	var c := _channel_with_chain()
	var plugin: Object = _device_instance_script.new(_plugin_device(), c.ch.id, 0)
	c.ch.add_device(plugin)
	_assert(not _manager.embedding_enabled(), "embedding is off off X11")
	# No channel frame yet: the plugin opens in its own window, no frame (as before frames).
	_manager.open(plugin)
	_assert(_manager.get_frames().is_empty() and _manager.is_open(plugin), "a plugin alone opens without a frame")
	_manager.close(plugin)
	_assert(not _manager.is_open(plugin), "and closes")
	# With a channel frame open, its tab is selected and shows the note.
	_manager.open(c.eq)
	_manager.open(plugin)
	await process_frame
	await process_frame
	var frame: Object = _manager.get_frames()[0]
	_assert(frame.get_active_device() == plugin, "the plugin's tab is selected in the channel frame")
	var slot: Object = frame.get_page(plugin)
	_assert(slot != null and slot.get_note_text().contains("own window"), "the tab says it's in its own window (got '%s')" % (slot.get_note_text() if slot else ""))
	await _close_all_frames()
