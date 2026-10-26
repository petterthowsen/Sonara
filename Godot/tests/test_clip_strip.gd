# test_clip_strip.gd
# Headless tests for the clip editor's ClipStrip (spec 054): the bars it shows in clip and track
# mode, its own selection, and the gestures (move, trim, resize, create) as undo steps. Events are
# fed straight to _gui_input; layout and drawing are left to live checks.
# Run: godot --headless --path Godot -s tests/test_clip_strip.gd -- --test
extends TestBase

const BAR := 3840
const BEAT := 960
const PX_PER_BEAT := 200.0
const OFFSET_X := 50.0

var _strip_script: GDScript
var _project_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _grid_script: GDScript
var _history_util: GDScript
var _lane_script: GDScript

var _recorded: Array = []


func suite_name() -> String:
	return "ClipStrip tests"


func run_tests() -> void:
	_strip_script = load("res://clip_editor/ClipStrip.gd")
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_history_util.test_recorder = func(cmd: Object) -> void: _recorded.append(cmd)
	_test_clip_mode_bars()
	_test_track_mode_bars_and_focus_switch()
	_test_selection()
	_test_move()
	_test_move_stops_at_neighbour()
	_test_multi_move()
	_test_move_with_automation(true)
	_test_move_with_automation(false)
	_test_left_trim()
	_test_right_resize()
	_test_clip_mode_right_end()
	_test_double_click()
	_test_context_menu_signal()
	_test_shift_click_range()
	_test_ctrl_drag_copies()
	_test_duplicate_overwrites()
	_test_strip_actions_helpers()
	_history_util.test_recorder = Callable()


# --- fixtures -------------------------------------------------------------------

## An Array[ClipInstance] (the strip's signatures are typed) from plain elements.
func _typed(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


func _project_with_tracks(count: int) -> Dictionary:
	var project: Object = _project_script.new()
	var tracks: Array = []
	for i in count:
		var track: Object = _track_script.new(2 + i)
		track.set_project_ref(project)
		project.tracks.append(track)
		tracks.append(track)
	return {"project": project, "tracks": tracks}


func _place(project: Object, track: Object, start: int, duration: int = BAR, clip: Object = null) -> Object:
	if clip == null:
		clip = project.create_clip("Clip %d" % start, _clip_script.ClipType.MIDI)
		project.add_clip(clip)
		clip.content_length_ticks = duration
	var inst: Object = _instance_script.new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = duration
	track.add_clip_instance(inst)
	return inst


func _strip() -> Control:
	var strip: Control = _strip_script.new()
	var grid: Object = _grid_script.new()
	grid.pixels_per_beat = PX_PER_BEAT
	strip.grid_helper = grid
	strip.offset_x = OFFSET_X
	strip.size = Vector2(4000, 24)
	root.add_child(strip)
	return strip


func _x(strip: Control, tick: int) -> float:
	return strip._tick_to_x(tick)


func _mouse(strip: Control, x: float, pressed: bool, opts: Dictionary = {}) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = opts.get("button", MOUSE_BUTTON_LEFT)
	e.pressed = pressed
	e.position = Vector2(x, 12)
	e.double_click = opts.get("double", false)
	e.shift_pressed = opts.get("shift", false)
	e.ctrl_pressed = opts.get("ctrl", false)
	strip._gui_input(e)


func _move_to(strip: Control, x: float, shift: bool = false) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(x, 12)
	e.shift_pressed = shift
	strip._gui_input(e)


## Press at `from_x`, drag to `to_x`, release.
func _drag(strip: Control, from_x: float, to_x: float, opts: Dictionary = {}) -> void:
	_mouse(strip, from_x, true, opts)
	_move_to(strip, to_x, opts.get("shift", false) and opts.get("free", false))
	_mouse(strip, to_x, false, opts)


func _body_x(strip: Control, inst: Object) -> float:
	return _x(strip, inst.start_ticks + inst.duration_ticks / 2)


# --- binding --------------------------------------------------------------------

func _test_clip_mode_bars() -> void:
	var f := _project_with_tracks(1)
	var inst: Object = _place(f.project, f.tracks[0], 3840, 1920)
	inst.clip_offset = 960
	var strip := _strip()
	strip.bind_clip(inst)
	var bars: Array = strip.bars()
	_assert(bars.size() == 1, "clip mode shows one bar")
	_assert(bars[0].start == 960 and bars[0].end == 2880, "unlooped: clip_offset to clip_offset + duration (%d-%d)" % [bars[0].start, bars[0].end])
	_assert(bars[0].lead_start == -1, "unlooped: no lead-in")
	inst.set_loop(true, 960, 1920)
	bars = strip.bars()
	_assert(bars[0].start == 960 and bars[0].end == 2880, "looped: the loop region")
	inst.set_clip_offset(0)
	inst.set_loop(true, 960, 1920)
	bars = strip.bars()
	_assert(bars[0].lead_start == 0, "looped: the first run before the loop start is a lead-in (got %d)" % bars[0].lead_start)
	strip.unbind()
	_assert(strip.bars().is_empty(), "unbound: no bars")
	strip.free()


func _test_track_mode_bars_and_focus_switch() -> void:
	var f := _project_with_tracks(2)
	var a1: Object = _place(f.project, f.tracks[0], 0)
	var a2: Object = _place(f.project, f.tracks[0], BAR * 2)
	var b1: Object = _place(f.project, f.tracks[1], BAR)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	var got: Array = strip.bars().map(func(b): return b.instance)
	_assert(got == [a1, a2], "track mode shows the focus track's instances")
	_assert(strip.bars()[1].start == BAR * 2 and strip.bars()[1].end == BAR * 3, "bars are in song ticks")
	strip.bind_track(f.tracks[1])
	got = strip.bars().map(func(b): return b.instance)
	_assert(got == [b1], "switching the focus track swaps the bars")
	strip.bind_track(null)
	_assert(strip.bars().is_empty(), "no focus track: empty strip")
	# An instance added later appears without a rebind.
	strip.bind_track(f.tracks[0])
	var a3: Object = _place(f.project, f.tracks[0], BAR * 4)
	_assert(strip.bars().size() == 3 and strip.bars()[2].instance == a3, "a new instance shows up")
	strip.free()


# --- selection ----------------------------------------------------------------------

func _test_selection() -> void:
	var f := _project_with_tracks(2)
	var a1: Object = _place(f.project, f.tracks[0], 0)
	var a2: Object = _place(f.project, f.tracks[0], BAR * 2)
	_place(f.project, f.tracks[1], 0)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	_mouse(strip, _body_x(strip, a1), true)
	_mouse(strip, _body_x(strip, a1), false)
	_assert(strip.selection == [a1], "click selects one clip")
	_mouse(strip, _body_x(strip, a2), true, {"shift": true})
	_mouse(strip, _body_x(strip, a2), false, {"shift": true})
	_assert(strip.selection.size() == 2, "Shift+click adds to the selection")
	_mouse(strip, _body_x(strip, a1), true, {"ctrl": true})
	_mouse(strip, _body_x(strip, a1), false, {"ctrl": true})
	_assert(strip.selection == [a2], "Ctrl+click toggles a clip off")
	_mouse(strip, _x(strip, BAR + 480), true)
	_mouse(strip, _x(strip, BAR + 480), false)
	_assert(strip.selection.is_empty(), "a click on empty space clears the selection")
	strip.selection.assign([a1])
	strip.bind_track(f.tracks[1])
	_assert(strip.selection.is_empty(), "a different focus track clears the selection")
	strip.free()


# --- move ---------------------------------------------------------------------------

func _test_move() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], BAR)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	_recorded.clear()
	var x := _body_x(strip, a)
	_drag(strip, x, x + 4.0 * PX_PER_BEAT)
	_assert(a.start_ticks == BAR * 2, "a one-bar drag adds one bar to start_ticks (got %d)" % a.start_ticks)
	_assert(_recorded.size() == 1, "one gesture, one history entry (got %d)" % _recorded.size())
	if _recorded.size() == 1:
		_assert(_recorded[0].name == "Move Clip", "named like the arranger's move")
		_recorded[0].undo()
		_assert(a.start_ticks == BAR, "undo restores the start")
	# Shift moves freely: 100 px = 480 ticks, not on a grid line
	_recorded.clear()
	x = _body_x(strip, a)
	_mouse(strip, x, true)
	_move_to(strip, x + 100.0, true)
	_mouse(strip, x + 100.0, false)
	_assert(a.start_ticks == BAR + 480, "Shift bypasses the grid (got %d)" % a.start_ticks)
	strip.free()


func _test_move_stops_at_neighbour() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], 0)
	var b: Object = _place(f.project, f.tracks[0], BAR * 2)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	var x := _body_x(strip, a)
	_drag(strip, x, x + 6.0 * PX_PER_BEAT)
	_assert(a.start_ticks == BAR, "a drag that would land on a neighbour stops at it (got %d)" % a.start_ticks)
	_assert(b.start_ticks == BAR * 2, "the neighbour is untouched")
	x = _body_x(strip, a)
	_drag(strip, x, x + 12.0 * PX_PER_BEAT)
	_assert(a.start_ticks == BAR * 4, "a clip can jump past a neighbour into a free gap (got %d)" % a.start_ticks)
	_assert(b.start_ticks == BAR * 2, "the neighbour is still untouched")
	a.set_position(BAR)
	x = _body_x(strip, a)
	_drag(strip, x, x - 20.0 * PX_PER_BEAT)
	_assert(a.start_ticks == 0, "a drag left stops at tick 0 (got %d)" % a.start_ticks)
	strip.free()


func _test_multi_move() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], BAR)
	var b: Object = _place(f.project, f.tracks[0], BAR * 3)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	_mouse(strip, _body_x(strip, a), true)
	_mouse(strip, _body_x(strip, a), false)
	_mouse(strip, _body_x(strip, b), true, {"shift": true})
	_mouse(strip, _body_x(strip, b), false, {"shift": true})
	_recorded.clear()
	var x := _body_x(strip, a)
	_drag(strip, x, x + 4.0 * PX_PER_BEAT)
	_assert(a.start_ticks == BAR * 2 and b.start_ticks == BAR * 4, "dragging one selected clip moves both by the same amount")
	_assert(_recorded.size() == 1, "one undo step for both (got %d)" % _recorded.size())
	if _recorded.size() == 1:
		_recorded[0].undo()
		_assert(a.start_ticks == BAR and b.start_ticks == BAR * 3, "undo restores both")
	strip.free()


func _test_move_with_automation(follows: bool) -> void:
	var f := _project_with_tracks(1)
	f.project.set_arranger_view("automation_follows_clips", follows)
	var track: Object = f.tracks[0]
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	var a: Object = _place(f.project, track, BAR)
	lane.add_point(BAR + 480, 0.5)
	var strip := _strip()
	strip.bind_track(track)
	_recorded.clear()
	var x := _body_x(strip, a)
	_drag(strip, x, x + 4.0 * PX_PER_BEAT)
	var ticks: Array = lane.points.map(func(p): return p.tick)
	var label := "automation follows %s" % ("on" if follows else "off")
	if follows:
		_assert(ticks.has(BAR + 480 + BAR), "%s: the point moved one bar with the clip: %s" % [label, str(ticks)])
	else:
		_assert(ticks == [BAR + 480], "%s: the point stays put: %s" % [label, str(ticks)])
	_assert(_recorded.size() == 1, "%s: one undo step (got %d)" % [label, _recorded.size()])
	if follows and _recorded.size() == 1:
		_recorded[0].undo()
		ticks = lane.points.map(func(p): return p.tick)
		_assert(a.start_ticks == BAR and ticks.has(BAR + 480), "undo restores the clip and the point: %s" % str(ticks))
	strip.free()


# --- trim / resize --------------------------------------------------------------------

func _test_left_trim() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], BAR)
	a.clip.add_midi_note(1, 60, 0.8, 480, 240)
	var song_before: int = a.start_ticks + a.clip.midi_notes[0].start_tick - a.clip_offset
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	_recorded.clear()
	var left_x := _x(strip, a.start_ticks) + 2.0
	_drag(strip, left_x, left_x + PX_PER_BEAT)
	_assert(a.start_ticks == BAR + BEAT, "left trim of a beat adds a beat to start_ticks (got %d)" % a.start_ticks)
	_assert(a.clip_offset == BEAT, "and to clip_offset (got %d)" % a.clip_offset)
	_assert(a.duration_ticks == BAR - BEAT, "and takes a beat off the duration (got %d)" % a.duration_ticks)
	var song_after: int = a.start_ticks + a.clip.midi_notes[0].start_tick - a.clip_offset
	_assert(song_after == song_before, "the notes keep their song position")
	_assert(_recorded.size() == 1 and _recorded[0].name == "Resize Clip", "one 'Resize Clip' step")
	strip.free()


func _test_right_resize() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], BAR)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	_recorded.clear()
	var right_x := _x(strip, a.get_end_ticks()) - 2.0
	_drag(strip, right_x, right_x + 4.0 * PX_PER_BEAT)
	_assert(a.duration_ticks == BAR * 2, "right resize of a bar doubles the length (got %d)" % a.duration_ticks)
	_assert(a.start_ticks == BAR, "the start stays")
	_assert(a.clip.content_length_ticks == BAR * 2, "the clip's content grows with it")
	_assert(_recorded.size() == 1, "one undo step")
	strip.free()


func _test_clip_mode_right_end() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], BAR)
	var strip := _strip()
	strip.bind_clip(a)
	_recorded.clear()
	# Unlooped: the bar spans clip ticks 0 .. BAR.
	var right_x := _x(strip, BAR) - 2.0
	_drag(strip, right_x, right_x + 4.0 * PX_PER_BEAT)
	_assert(a.duration_ticks == BAR * 2, "clip mode: a one-bar drag adds a bar to duration_ticks (got %d)" % a.duration_ticks)
	_assert(a.start_ticks == BAR, "clip mode: start_ticks stays put")
	_assert(_recorded.size() == 1, "clip mode: one undo step")
	# The left end and the body are not draggable.
	_recorded.clear()
	var left_x := _x(strip, 0) + 2.0
	_drag(strip, left_x, left_x + 200.0)
	_drag(strip, _x(strip, BAR), _x(strip, BAR) + 200.0)
	_assert(a.start_ticks == BAR and a.clip_offset == 0 and _recorded.is_empty(), "clip mode: left end and body do nothing")
	# Looped: the bar is the loop region.
	a.set_loop(true, 0, BAR)
	right_x = _x(strip, BAR) - 2.0
	_recorded.clear()
	_drag(strip, right_x, right_x + 4.0 * PX_PER_BEAT)
	_assert(a.loop_length_ticks == BAR * 2, "clip mode, looped: a one-bar drag adds a bar to the loop length (got %d)" % a.loop_length_ticks)
	_assert(a.start_ticks == BAR, "clip mode, looped: start_ticks stays put")
	_assert(_recorded.size() == 1 and _recorded[0].name == "Move Loop Point", "clip mode, looped: a 'Move Loop Point' step")
	strip.free()


# --- create / double-click --------------------------------------------------------------

func _test_double_click() -> void:
	var f := _project_with_tracks(1)
	var track: Object = f.tracks[0]
	var strip := _strip()
	strip.bind_track(track)
	_recorded.clear()
	var x := _x(strip, BAR * 2)  # bar 3
	_mouse(strip, x, true, {"double": true})
	_mouse(strip, x, false)
	_assert(track.clip_instances.size() == 1, "double-click on empty space creates one instance")
	if track.clip_instances.size() == 1:
		var inst: Object = track.clip_instances[0]
		_assert(inst.start_ticks == BAR * 2 and inst.duration_ticks == BAR, "at bar 3, one bar long (got %d, %d)" % [inst.start_ticks, inst.duration_ticks])
		_assert(_recorded.size() == 1, "as one undo step (got %d)" % _recorded.size())
		# A double-click on the new bar changes nothing.
		var bx := _body_x(strip, inst)
		_mouse(strip, bx, true, {"double": true})
		_mouse(strip, bx, false)
		_assert(track.clip_instances.size() == 1 and strip.mode == strip.Mode.TRACK, "double-click on a bar creates nothing and keeps the mode")
		# A short gap before the next clip shortens the new one.
		x = _x(strip, BAR * 4 - BEAT * 2 + BEAT * 2)  # a free spot, then a clip right after
		_place(f.project, track, BAR * 5 + BEAT)
		_mouse(strip, _x(strip, BAR * 5), true, {"double": true})
		_mouse(strip, _x(strip, BAR * 5), false)
		var short: Object = null
		for ci in track.clip_instances:
			if ci.start_ticks == BAR * 5:
				short = ci
		_assert(short != null and short.duration_ticks == BEAT, "a new clip stops at the next clip (got %s)" % str(short.duration_ticks if short else -1))
	strip.free()


# --- context menu -----------------------------------------------------------------------------

func _test_context_menu_signal() -> void:
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], 0)
	var b: Object = _place(f.project, f.tracks[0], BAR * 2)
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	var got: Array = []
	strip.context_menu_requested.connect(func(instances, split_tick, _rect, _from_x): got.append([instances.duplicate(), split_tick]))
	_mouse(strip, _body_x(strip, a), true)
	_mouse(strip, _body_x(strip, a), false)
	_mouse(strip, _body_x(strip, b), true, {"button": MOUSE_BUTTON_RIGHT})
	_mouse(strip, _body_x(strip, b), false, {"button": MOUSE_BUTTON_RIGHT})
	_assert(got.size() == 1 and got[0][0] == [b], "right-click on an unselected clip acts on it alone")
	_assert(strip.selection == [a], "and leaves the selection alone")
	_mouse(strip, _body_x(strip, a), false, {"button": MOUSE_BUTTON_RIGHT})
	_assert(got.size() == 2 and got[1][0] == [a], "right-click on the selected clip acts on the selection")
	strip.free()


# --- range select, copy, duplicate (spec 054 follow-up) ---------------------------------------

func _test_shift_click_range() -> void:
	var f := _project_with_tracks(1)
	var c: Array = []
	for i in 4:
		c.append(_place(f.project, f.tracks[0], BAR * 2 * i))
	var strip := _strip()
	strip.bind_track(f.tracks[0])
	_mouse(strip, _body_x(strip, c[0]), true)
	_mouse(strip, _body_x(strip, c[0]), false)
	_mouse(strip, _body_x(strip, c[2]), true, {"shift": true})
	_mouse(strip, _body_x(strip, c[2]), false, {"shift": true})
	_assert(strip.selection.size() == 3 and strip.selection.has(c[1]), "Shift+click selects every clip from the anchor to the clicked one")
	_mouse(strip, _body_x(strip, c[3]), true)
	_mouse(strip, _body_x(strip, c[3]), false)
	_mouse(strip, _body_x(strip, c[1]), true, {"shift": true})
	_mouse(strip, _body_x(strip, c[1]), false, {"shift": true})
	_assert(strip.selection.size() == 3 and not strip.selection.has(c[0]), "the range also works backwards from a later anchor")
	strip.free()


func _test_ctrl_drag_copies() -> void:
	var f := _project_with_tracks(1)
	var track: Object = f.tracks[0]
	var a: Object = _place(f.project, track, 0)
	var strip := _strip()
	strip.bind_track(track)
	_recorded.clear()
	var x := _body_x(strip, a)
	_drag(strip, x, x + 8.0 * PX_PER_BEAT, {"ctrl": true})
	_assert(track.clip_instances.size() == 2, "Ctrl+drag adds a copy (got %d clips)" % track.clip_instances.size())
	_assert(a.start_ticks == 0, "the original stays")
	var copy: Object = null
	for ci in track.clip_instances:
		if ci != a:
			copy = ci
	_assert(copy != null and copy.start_ticks == BAR * 2 and copy.clip == a.clip, "the copy lands where it was dragged")
	_assert(_recorded.size() == 1, "one undo step (got %d)" % _recorded.size())
	_assert(strip.selection == [copy], "the copy is selected")
	# A copy dragged onto its own original is refused.
	_recorded.clear()
	x = _body_x(strip, a)
	_drag(strip, x, x + 2.0 * PX_PER_BEAT, {"ctrl": true})
	_assert(track.clip_instances.size() == 2 and _recorded.is_empty(), "a copy overlapping its original is refused")
	# A plain Ctrl+click still toggles.
	strip.select_instances(_typed([copy]))
	_mouse(strip, _body_x(strip, a), true, {"ctrl": true})
	_mouse(strip, _body_x(strip, a), false, {"ctrl": true})
	_assert(strip.selection.size() == 2 and track.clip_instances.size() == 2, "Ctrl+click without a drag toggles the selection")
	strip.free()


func _test_duplicate_overwrites() -> void:
	var f := _project_with_tracks(1)
	var track: Object = f.tracks[0]
	var a: Object = _place(f.project, track, 0)
	var inside: Object = _place(f.project, track, BAR + 960, 960)
	var crossing: Object = _place(f.project, track, BAR * 2 - 480, 2000)
	var strip := _strip()
	strip.bind_track(track)
	strip.select_instances(_typed([a]))
	_recorded.clear()
	strip.duplicate_selection()
	var copy: Object = strip.selection[0]
	_assert(copy.start_ticks == BAR and copy.duration_ticks == BAR, "the duplicate sits right after the selection")
	_assert(not track.clip_instances.has(inside), "a clip inside the target is removed")
	_assert(not track.clip_instances.has(crossing) or crossing.start_ticks >= BAR * 2, "a clip crossing the target's end is trimmed or replaced")
	var covered := false
	for ci in track.clip_instances:
		if ci != copy and ci.start_ticks < BAR * 2 and ci.get_end_ticks() > BAR:
			covered = true
	_assert(not covered, "nothing else overlaps the duplicate")
	_assert(_recorded.size() == 1, "one undo step (got %d)" % _recorded.size())
	if _recorded.size() == 1:
		_recorded[0].undo()
		_assert(track.clip_instances.size() == 3 and inside.track == track and crossing.start_ticks == BAR * 2 - 480,
			"undo restores the overwritten clips")
	strip.free()


func _test_strip_actions_helpers() -> void:
	var actions: GDScript = load("res://history/ClipStripActions.gd")
	_assert(actions.paste_tick(960, 480, 100) == 960, "paste: the note range start wins")
	_assert(actions.paste_tick(-1, 480, 100) == 480, "paste: then a pending ruler range start")
	_assert(actions.paste_tick(-1, -1, 100) == 100, "paste: then the playhead")
	var f := _project_with_tracks(1)
	var a: Object = _place(f.project, f.tracks[0], 0)
	var b: Object = _place(f.project, f.tracks[0], BAR * 2)
	var both: Array = _typed([a, b])
	_assert(actions.duplicate_delta(both) == BAR * 3, "duplicate delta is the span of the selection")
	_assert(not actions.copy_delta_valid(both, BAR * 2), "a copy landing on a source is not valid")
	_assert(actions.copy_delta_valid(both, BAR * 3), "a copy after the block is valid")
	_assert(not actions.copy_delta_valid(both, -BAR), "a copy before tick 0 is not valid")
	var range: Array = actions.range_between(f.tracks[0], b, a)
	_assert(range == [a, b], "range_between is in start order whichever end comes first")
