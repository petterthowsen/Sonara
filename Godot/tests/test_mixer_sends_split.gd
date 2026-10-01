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
