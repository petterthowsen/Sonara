# test_mixer_sends_split.gd
# Headless tests for the strip divider between the device list and the sends: it never gives the
# sends more height than their knobs need, even when dragged past its limit.
# Run: godot --headless --path Godot -s tests/test_mixer_sends_split.gd -- --test
#
# Mixer references autoloads, so it is loaded with load() instead of named.
extends TestBase

var _mixer: Object
var _strip: Object


func suite_name() -> String:
	return "Mixer sends split tests"


func run_tests() -> void:
	await _setup()
	_assert(_strip.sends_panel.is_visible_in_tree(), "sends are shown")
	await _test_over_drag_is_clamped(10, "below the device list minimum")
	await _test_over_drag_is_clamped(-5000, "past the top")
	await _test_snap_never_grows_past_need()
	await _test_drag_down_closes_sends()
	_mixer.free()


## A Mixer with one instrument strip and two buses, sends shown, tall enough to over-drag.
func _setup() -> void:
	var project: Object = load("res://data/Project.gd").new()
	_mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	root.size = Vector2i(1400, 1400)
	_mixer.size = Vector2(1400, 1400)
	root.add_child(_mixer)
	_mixer._on_project_opened(project)
	var track: Dictionary = project.create_instrument_track("A")
	project.create_bus_channel("FX 1")
	project.create_bus_channel("FX 2")
	_mixer._on_sends_toggled(true)
	await _frames(4)
	_strip = _mixer.find_mixer_channel_ui_for_channel(track.channel)


## The raw split offset can run past what the layout allows; the clamp must still bite.
func _test_over_drag_is_clamped(offset: int, where: String) -> void:
	_strip._on_vsplit_dragged(offset)
	(_strip.main_vsplit as SplitContainer).split_offset = offset
	await _frames(6)
	var needed: float = _strip._shared_sends_needed_height()
	_assert(_strip.sends_panel.size.y <= needed + 1.0,
			"over-drag %s: sends get no more than they need (%s > %s)" % [where, _strip.sends_panel.size.y, needed])


## Letting go snaps to whole rows without growing past what the sends need.
func _test_snap_never_grows_past_need() -> void:
	_strip._snap_vsplit_to_send_rows()
	await create_timer(0.3).timeout
	await _frames(4)
	var needed: float = _strip._shared_sends_needed_height()
	_assert(_strip.sends_panel.size.y <= needed + 1.0,
			"snapping never grows the sends past what they need (%s > %s)" % [_strip.sends_panel.size.y, needed])


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Releasing the divider a little past the sends' minimum keeps them; well past turns them off,
## and the divider goes back to where the drag started. Real mouse drags: Godot clamps the
## offset while dragging, so only the pointer shows the over-drag.
func _test_drag_down_closes_sends() -> void:
	var vsplit: SplitContainer = _strip.main_vsplit
	# Down to the sends' minimum first, so any further drag is past it.
	await _drag_divider(vsplit, 3000)
	_assert(not _strip.sends_panel.visible, "a long drag down turns the sends off")
	_assert(not _mixer.sends_toggle.button_pressed, "the Sends toggle goes off with them")
	_mixer._on_sends_toggled(true)
	await _frames(4)
	_assert(_strip.sends_panel.visible, "the sends come back on")
	var span_before: int = _strip._shared_sends_span
	var sends_min: float = _strip.sends_panel.get_combined_minimum_size().y
	var room: float = _strip.sends_panel.size.y - sends_min
	await _drag_divider(vsplit, room + 20)
	await _frames(4)
	_assert(_strip.sends_panel.visible, "a short drag past the minimum keeps the sends")
	await _frames(4)
	span_before = _strip._shared_sends_span
	await _drag_divider(vsplit, 200)
	await _frames(2)
	_assert(not _strip.sends_panel.visible, "dragging well past the minimum turns the sends off")
	_assert(_strip._shared_sends_span == span_before, "the divider goes back to where the drag started (%d vs %d)" % [_strip._shared_sends_span, span_before])
	_mixer._on_sends_toggled(true)
	await _frames(2)


## Drag `split`'s divider with real mouse events: grab its middle, move `dy` px, let go.
func _drag_divider(split: SplitContainer, dy: float) -> void:
	var dragger: Control = null
	for child in split.get_children(true):
		if child.get_class() == "SplitContainerDragger":
			dragger = child
	var at := dragger.get_global_rect().get_center()
	await _mouse(at, true)
	for step in 4:
		await _mouse(at + Vector2(0, dy * (step + 1) / 4.0))
	await _mouse(at + Vector2(0, dy), false)


func _mouse(at: Vector2, pressed: Variant = null) -> void:
	var ev: InputEventMouse
	if pressed == null:
		ev = InputEventMouseMotion.new()
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	else:
		ev = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	root.push_input(ev)
	await process_frame
