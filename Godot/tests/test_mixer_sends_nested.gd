# test_mixer_sends_nested.gd
# Headless tests for sends paging across nested strips: a strip inside a group's fold-out gets
# the same sends height as a top-level strip, so paging one strip shows the same rows on all.
# Run: godot --headless --path Godot -s tests/test_mixer_sends_nested.gd -- --test
#
# Mixer references autoloads, so it is loaded with load() instead of named.
extends TestBase

var _mixer: Object
var _top: Object
var _group: Object
var _nested: Object


func suite_name() -> String:
	return "Mixer nested sends tests"


func run_tests() -> void:
	await _setup()
	_assert(_nested != null and _nested.sends_panel.is_visible_in_tree(), "nested strip shows sends")
	_test_same_sends_height("at the scene default divider")
	_test_controls_line_up("at the scene default divider")
	# Sends shorter than their knobs, so they overflow and page.
	await _drag(_top, 200)
	_test_same_sends_height("after a divider drag")
	await _test_paging_syncs_rows()
	await _drag(_nested, 260)
	_test_same_sends_height("after dragging the nested divider")
	await _test_width_mode_refits()
	await _test_divider_revalidates()
	# Taller than the strips' minimum, so they stretch to the mixer instead of their content.
	root.size = Vector2i(1400, 3000)
	_mixer.size = Vector2(1400, 3000)
	await _frames(6)
	_test_same_sends_height("after the mixer grows")
	await _drag(_group, 150)
	_test_same_sends_height("after a divider drag in a tall mixer")
	_test_controls_line_up("in a tall mixer")
	_mixer.free()


## A top-level strip, plus a group with one nested strip, and six buses so the sends overflow.
func _setup() -> void:
	var project: Object = load("res://data/Project.gd").new()
	_mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	root.size = Vector2i(1400, 900)
	_mixer.size = Vector2(1400, 900)
	root.add_child(_mixer)
	_mixer._on_project_opened(project)
	var top: Dictionary = project.create_instrument_track("Top")
	var group: Dictionary = project.create_group_track("Group")
	var nested: Dictionary = project.create_instrument_track("Nested")
	project.place_track(nested.track, group.track.id)
	for i in 6:
		project.create_bus_channel("FX %d" % i)
	group.channel.is_children_expanded = true
	_mixer._on_sends_toggled(true)
	await _frames(8)
	_top = _mixer.find_mixer_channel_ui_for_channel(top.channel)
	_group = _mixer.find_mixer_channel_ui_for_channel(group.channel)
	_nested = _mixer.find_mixer_channel_ui_for_channel(nested.channel)


## Drag `strip`'s divider to leave its sends `sends_height` tall.
func _drag(strip: Object, sends_height: int) -> void:
	var offset := roundi(strip.main_vsplit.size.y) - sends_height
	strip.main_vsplit.split_offset = offset
	strip._on_vsplit_dragged(offset)
	await _frames(4)
	_assert(absf(strip.sends_panel.size.y - sends_height) < 12.0,
			"drag leaves %s's sends about %d tall (%s)" % [strip.channel.name, sends_height, strip.sends_panel.size.y])


func _test_same_sends_height(when: String) -> void:
	for strip in [_group, _nested]:
		_assert(is_equal_approx(strip.sends_panel.size.y, _top.sends_panel.size.y),
				"%s: %s sends are as tall as a top-level strip's (%s vs %s)"
				% [when, strip.channel.name, strip.sends_panel.size.y, _top.sends_panel.size.y])


## Nested strips end on the same row as top-level ones, so faders and buttons line up.
func _test_controls_line_up(when: String) -> void:
	var top_y: float = _top.bottom_volume_slider.get_global_rect().end.y
	for strip in [_group, _nested]:
		var y: float = strip.bottom_volume_slider.get_global_rect().end.y
		_assert(is_equal_approx(y, top_y),
				"%s: %s fader ends on the top-level strip's row (%s vs %s)" % [when, strip.channel.name, y, top_y])


## Paging the top-level strip scrolls the nested one to the same rows, none faded differently.
func _test_paging_syncs_rows() -> void:
	var top_sc: PagedContainer = _top.sends_panel.scroll_container
	top_sc.scroll_step(true, 1)
	# Mid-scroll the strips that follow show both pages too, not only what is wholly in view.
	await create_timer(top_sc.animation_duration / 3.0).timeout
	for strip in [_group, _nested]:
		var sc: PagedContainer = strip.sends_panel.scroll_container
		_assert(_shown(sc) == _shown(top_sc),
				"mid-scroll %s shows the same knobs (%s vs %s)" % [strip.channel.name, _shown(sc), _shown(top_sc)])
	await create_timer(0.5).timeout
	_assert(top_sc.scroll_vertical > 0, "paging scrolls the top-level strip")
	for strip in [_group, _nested]:
		var sc: PagedContainer = strip.sends_panel.scroll_container
		_assert(sc.scroll_vertical == top_sc.scroll_vertical,
				"%s follows the scroll (%d vs %d)" % [strip.channel.name, sc.scroll_vertical, top_sc.scroll_vertical])
		_assert(_shown(sc) == _shown(top_sc),
				"%s shows the same rows (%s vs %s)" % [strip.channel.name, _shown(sc), _shown(top_sc)])
	# Hovering the panel re-checks blocked (looping) sends, which must not show hidden knobs.
	_top.sends_panel._refresh_blocked()
	_assert(_shown(top_sc) == _in_view(top_sc),
			"re-checking blocked sends keeps the knobs out of view hidden (%s vs %s)" % [_shown(top_sc), _in_view(top_sc)])


## Switching strip width re-wraps the knobs: every pager re-fits to a row start, and the knobs
## shown (opaque) are exactly the ones wholly in view.
func _test_width_mode_refits() -> void:
	# Enough buses that the sends still overflow two knobs to a row.
	for i in 10:
		_top.project.create_bus_channel("More %d" % i)
	await _frames(6)
	var top_sc: PagedContainer = _top.sends_panel.scroll_container
	top_sc.scroll_vertical = 0
	for i in 3:
		top_sc.scroll_step(true, 1)
		await create_timer(0.4).timeout
	# MixerChannel.SizeMode WIDE, then MEDIUM (named enums would compile it before the autoloads).
	for mode: int in [2, 1]:
		root.get_tree().call_group("mixer_channel", "set_size_mode", mode)
		await _frames(4)
		await process_frame
		var name := "WIDE" if mode == 2 else "MEDIUM"
		for strip in [_top, _group, _nested]:
			var sc: PagedContainer = strip.sends_panel.scroll_container
			var starts := sc._line_edges(true).map(func(l: Vector2) -> int: return roundi(minf(l.x, sc._max_scroll(true))))
			_assert(sc.scroll_vertical in starts, "%s: %s scroll sits on a row start (%d, rows %s)" % [name, strip.channel.name, sc.scroll_vertical, starts])
			_assert(_shown(sc) == _in_view(sc), "%s: %s shows exactly the knobs in view (%s vs %s)" % [name, strip.channel.name, _shown(sc), _in_view(sc)])
		_assert(_shown(_nested.sends_panel.scroll_container) == _shown(top_sc), "%s: nested shows the same knobs" % name)


## A new send knob, or a width switch, snaps the divider to whole rows without a manual touch.
func _test_divider_revalidates() -> void:
	await _drag(_top, 200)  # between rows: a drag without letting go doesn't snap
	_assert(not _whole_rows(_top), "the test starts between rows")
	_top.project.create_bus_channel("Late bus")
	await _settle()
	_assert(_whole_rows(_top), "a new bus snaps the divider to whole rows (view %s)" % _top.sends_panel.scroll_container.get_v_scroll_bar().page)
	_test_same_sends_height("after a new bus")
	for mode: int in [2, 1]:
		await _drag(_top, 200)
		root.get_tree().call_group("mixer_channel", "set_size_mode", mode)
		await _settle()
		_assert(_whole_rows(_top), "width mode %d snaps the divider to whole rows (view %s)" % [mode, _top.sends_panel.scroll_container.get_v_scroll_bar().page])
		_test_same_sends_height("after width mode %d" % mode)


## True when the sends view holds a whole number of knob rows.
func _whole_rows(strip: Object) -> bool:
	# The page itself is always trimmed to whole rows, so measure the container's outer height.
	var sc: PagedContainer = strip.sends_panel.scroll_container
	return absf(sc.snap_length(true, sc.size.y) - sc.size.y) <= 1.0


## Wait out the deferred revalidation and its snap animation.
func _settle() -> void:
	await _frames(4)
	await create_timer(0.4).timeout
	await _frames(2)


## Indices of the send knobs wholly inside the view.
func _in_view(sc: PagedContainer) -> Array[int]:
	var shown: Array[int] = []
	var items := sc._items()
	var top := float(sc.scroll_vertical)
	var bottom := top + sc.get_v_scroll_bar().page
	for i in items.size():
		var r: Rect2 = sc._item_rect(items[i], sc._content())
		if r.position.y >= top - 0.5 and r.end.y <= bottom + 0.5:
			shown.append(i)
	return shown


## Indices of the send knobs shown (not faded out).
func _shown(sc: PagedContainer) -> Array[int]:
	var shown: Array[int] = []
	var items := sc._items()
	for i in items.size():
		if items[i].modulate.a > 0.5:
			shown.append(i)
	return shown


func _frames(n: int) -> void:
	for i in n:
		await process_frame
