# test_clip_editor_automation_pane.gd
# The MIDI editor's automation pane in the real ClipEditor scene (spec 055 REQ-001..REQ-014).
# Shallow on purpose: bind, assert what exists, fire one gesture. The point editing itself is the
# Arranger row's shared code, and the models have their own tests.
#
# Run: godot --headless --path Godot -s tests/test_clip_editor_automation_pane.gd -- --test
extends TestBase

const KEY := "clip_editor/automation_pane"

var _project_script: GDScript
var _lane_script: GDScript
var _actions: GDScript
var _util: GDScript
var _scene: PackedScene


func suite_name() -> String:
	return "Clip editor: automation pane"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_actions = load("res://history/AutomationActions.gd")
	_util = load("res://history/HistoryUtil.gd")
	_scene = load("res://clip_editor/ClipEditor.tscn")
	_sonara().set_config(KEY, {})
	await _test_clip_mode_hides_pane()
	await _test_toggle_persists()
	await _test_follows_focus_track()
	await _test_alignment_with_notes()
	await _test_menu_add_close_delete()
	await _test_gestures_and_header()
	await _test_shortcuts_follow_last_press()
	await _test_selection_scope()


func _sonara() -> Node:
	return root.get_node("Sonara")


func _typed(items: Array, base: StringName, script: GDScript) -> Array:
	return Array(items, TYPE_OBJECT, base, script)


## A ClipEditor in track mode over tracks A and B. A holds a Volume and a Pan lane (a point at
## tick 1920 each), B a Pan lane. Every track has a note at tick 1920 in a clip at tick 0.
func _setup(open_lanes := true) -> Dictionary:
	var track_script: GDScript = load("res://data/Track.gd")
	var instance_script: GDScript = load("res://data/ClipInstance.gd")
	var project: Object = _project_script.new()
	var out := {"project": project, "tracks": [], "cis": []}
	for key in ["a", "b"]:
		var pair: Dictionary = project.create_instrument_track(key.to_upper())
		var clip: Object = project.create_clip("Clip" + key)
		project.add_clip(clip)
		var ci: Object = pair.track.create_clip_instance(clip, 0, 3840)
		clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 1920, 480)
		clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 0, 480)
		out[key] = pair.track
		out["ci_" + key] = ci
		out.tracks.append(pair.track)
		out.cis.append(ci)
	var specs := [["a", "va", AutomationTarget.channel_volume()], ["a", "pa", AutomationTarget.channel_pan()],
		["b", "pb", AutomationTarget.channel_pan()]]
	for spec in specs:
		var lane: Object = _lane_script.new(spec[1], spec[2])
		out[spec[0]].add_automation_lane(lane)
		lane.add_point(0, 0.5)
		lane.add_point(1920, 0.25)
		out[spec[1]] = lane
	if open_lanes:
		out.a.set_clip_editor_lanes(_entries([{"id": "va", "height": 96.0}, {"id": "pa", "height": 96.0}]))
		out.b.set_clip_editor_lanes(_entries([{"id": "pb", "height": 96.0}]))
	var ed: Control = _scene.instantiate()
	root.add_child(ed)
	ed.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ed.size = Vector2(1200, 700)
	await process_frame
	out["ed"] = ed
	out["midi"] = ed.midi_editor
	out["pane"] = ed.automation_pane
	return out


func _enter_track_mode(ctx: Dictionary, focus: Object) -> void:
	var midi: Object = ctx.midi
	var tracks := _typed(ctx.tracks, &"RefCounted", load("res://data/Track.gd"))
	var clips := _typed(ctx.cis, &"RefCounted", load("res://data/ClipInstance.gd"))
	midi.bind_to_clips(clips, tracks)
	midi.set_track_views(tracks, clips)
	midi.focus_track = focus
	ctx.ed.track_mode = true
	ctx.ed._update_mode_ui()
	for _i in 3:
		await process_frame


func _entries(list: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in list:
		out.append(e)
	return out


func _finish(ctx: Dictionary) -> void:
	ctx.ed.queue_free()
	await process_frame


func _record(call: Callable) -> Array:
	var recorded: Array = []
	_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	call.call()
	_util.test_recorder = Callable()
	return recorded


func _ids(pane) -> Array:
	return Array(pane.lane_ids())


func _mouse(row: Control, pos: Vector2, pressed: bool, double := false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.position = pos
	e.global_position = row.get_global_transform() * pos
	return e


func _click(row: Control, pos: Vector2, double := false) -> void:
	row._gui_input(_mouse(row, pos, true, double))
	row._gui_input(_mouse(row, pos, false))


func _key(keycode: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = keycode
	e.physical_keycode = keycode
	e.pressed = true
	return e


# ---------------------------------------------------------------------------

func _test_clip_mode_hides_pane() -> void:
	var ctx := await _setup()
	var ed: Control = ctx.ed
	_assert(not ctx.pane.visible, "clip mode: the pane is hidden")
	_assert(not ed.automation_lanes_toggle.visible, "clip mode: the toggle is hidden")
	await _enter_track_mode(ctx, ctx.a)
	_assert(ctx.pane.visible, "track mode: the pane shows")
	_assert(ed.automation_lanes_toggle.visible, "track mode: the toggle shows")
	_assert(ed.lane_panes.visible, "track mode: the lane container shows")
	ed.track_mode = false
	ed._update_mode_ui()
	_assert(not ctx.pane.visible and not ed.automation_lanes_toggle.visible, "back in clip mode both hide again")
	await _finish(ctx)


func _test_toggle_persists() -> void:
	var ctx := await _setup()
	await _enter_track_mode(ctx, ctx.a)
	ctx.ed.automation_lanes_toggle.button_pressed = false
	_assert(not ctx.pane.visible, "toggling off hides the pane")
	ctx.ed.automation_lanes_toggle.button_pressed = true
	_assert(ctx.pane.visible, "toggling on shows it")
	ctx.ed.automation_lanes_toggle.button_pressed = false
	_assert(_sonara().get_config(KEY).get("visible") == false, "the state is saved in the config")
	await _finish(ctx)
	var again := await _setup()
	_assert(not again.pane.is_lanes_visible(), "a new editor restores the hidden pane")
	_assert(not again.ed.automation_lanes_toggle.button_pressed, "and the toggle")
	_sonara().set_config(KEY, {})
	await _finish(again)


func _test_follows_focus_track() -> void:
	var ctx := await _setup()
	await _enter_track_mode(ctx, ctx.a)
	_assert(_ids(ctx.pane) == ["va", "pa"], "focus A shows A's open lanes in order")
	ctx.midi.focus_track = ctx.b
	_assert(_ids(ctx.pane) == ["pb"], "focus B shows only B's lane")
	ctx.midi.focus_track = null
	_assert(_ids(ctx.pane).is_empty(), "no focus track: no lanes")
	await _finish(ctx)


func _test_alignment_with_notes() -> void:
	var ctx := await _setup()
	await _enter_track_mode(ctx, ctx.a)
	var midi: Object = ctx.midi
	var row: Control = ctx.pane.lanes[0].row
	var scrolled := false
	for round in 3:
		var stem: Dictionary = {}
		for s in midi.value_stems():
			if s["note_data"].start_tick == 1920 and not s["ghost"]:
				stem = s
		_assert(not stem.is_empty(), "round %d: the note at tick 1920 has a stem" % round)
		var note_x: float = midi.h_scroll.global_position.x + stem["x_start"]
		var point_x: float = row.global_position.x + row.tick_to_x(1920)
		_assert(absf(note_x - point_x) < 0.6, "round %d: tick 1920 sits at the note's x (%s vs %s)" % [round, point_x, note_x])
		if round == 0:
			midi.grid_helper.pixels_per_beat *= 1.5
			for _i in 3:
				await process_frame
		elif round == 1:
			midi.h_scroll.scroll_horizontal = 120
			for _i in 3:
				await process_frame
			scrolled = midi.h_scroll.scroll_horizontal > 0
	_assert(scrolled, "the note area did scroll")
	await _finish(ctx)


func _test_menu_add_close_delete() -> void:
	var ctx := await _setup()
	var pane = ctx.pane
	var track: Object = ctx.a
	track.set_clip_editor_lanes(_entries([{"id": "va", "height": 96.0}]))
	await _enter_track_mode(ctx, track)
	_assert(_ids(pane) == ["va"], "Volume is open")
	pane._on_add_lane_pressed()
	var menu: PopupMenu = pane._menu
	_assert(menu != null and menu.view != null, "the add button opens the lane menu with a clip editor view")
	var labels: Array = []
	var checked: Array = []
	for i in menu.item_count:
		labels.append(menu.get_item_text(i))
		checked.append(menu.is_item_checked(i))
	_assert(labels.size() >= 4 and labels[3] == "+ Add new" and labels.has("Save shown lanes as preset…"), "the menu lists both lanes, + Add new, then the presets section (%s)" % [labels])
	_assert(checked[0] and not checked[1], "Volume is checked, Pan is not")
	menu._on_id_pressed(1)
	_assert(_ids(pane) == ["va", "pa"], "choosing Pan opens it")
	menu.hide()

	# Picking a new target creates the lane on the track and opens it, as one undo step.
	var before: int = track.automation_lanes.size()
	var recorded := _record(func(): pane._on_parameter_chosen(track, AutomationTarget.midi_cc(1)))
	_assert(track.automation_lanes.size() == before + 1, "a picked target adds one lane to the track")
	var created: Object = track.automation_lanes[track.automation_lanes.size() - 1]
	_assert(created.points.size() == 1, "seeded with one point")
	_assert(_ids(pane).has(created.id), "and it is open in the pane")
	_assert(recorded.size() == 1, "as one history step (%d)" % recorded.size())
	if not recorded.is_empty():
		recorded[0].undo()
	_assert(not track.automation_lanes.has(created) and not _ids(pane).has(created.id), "undo removes the lane and its pane lane")

	# Close keeps the lane and its points (and the Arranger visibility).
	var pa: Object = ctx.pa
	var points: int = pa.points.size()
	pane.lanes[1].close_requested.emit(pa)
	_assert(_ids(pane) == ["va"], "close removes the lane from the pane")
	_assert(track.automation_lanes.has(pa) and pa.points.size() == points and pa.visible, "the lane keeps its points and Arranger visibility")

	# Height lives in the entry, not in the lane.
	var lane_height: int = ctx.va.height
	pane.lanes[0].set_lane_height(120.0)
	pane._on_lane_height_changed(ctx.va, 120.0)
	_assert(is_equal_approx(track.clip_editor_lanes[0]["height"], 120.0), "the open-lane entry stores 120")
	_assert(ctx.va.height == lane_height, "AutomationLane.height is unchanged")

	# A lane deleted elsewhere leaves the pane.
	_actions.delete_lane(track, ctx.va)
	_assert(_ids(pane).is_empty(), "a deleted lane is removed from the pane")
	_assert(track.clip_editor_lanes.is_empty(), "and from the open-lane list")
	await _finish(ctx)


func _test_gestures_and_header() -> void:
	var ctx := await _setup()
	await _enter_track_mode(ctx, ctx.a)
	var pane = ctx.pane
	var scene = pane.lanes[0]
	var row: Control = scene.row
	_assert(scene.name_label.text == "Volume", "the header shows the target's name (%s)" % scene.name_label.text)
	scene.bypass_button.button_pressed = true
	_assert(ctx.va.bypassed, "the bypass toggle sets lane.bypassed")
	scene.bypass_button.button_pressed = false
	_assert(not ctx.va.bypassed, "and clears it")

	var x: float = row.tick_to_x(960)
	var expected: float = _actions.insert_value_at(ctx.va, 960)
	var recorded := _record(func(): _click(row, Vector2(x, row.size.y * 0.5), true))
	var inserted: Object = null
	for p in ctx.va.points:
		if p.tick == 960:
			inserted = p
	_assert(inserted != null, "a double-click inserts a point at the snapped tick")
	_assert(inserted != null and absf(inserted.value - expected) < 0.001, "holding the lane's own value there")
	_assert(recorded.size() == 1, "as one undo step (%d)" % recorded.size())
	await _finish(ctx)


func _test_shortcuts_follow_last_press() -> void:
	var ctx := await _setup()
	await _enter_track_mode(ctx, ctx.a)
	var pane = ctx.pane
	var midi: Object = ctx.midi
	var row: Control = pane.lanes[0].row
	var note_editor: Control = midi.get_active_note_editor()
	var ref_script: GDScript = load("res://clip_editor/note_editor/NoteRef.gd")
	var plain: Array = []
	for nd in ctx.ci_a.clip.midi_notes:
		plain.append(ref_script.new(ctx.ci_a, nd, 0))
	var refs := _typed(plain, &"RefCounted", ref_script)
	midi.note_selection.select(refs)
	var ids := [ctx.va.points[0].id, ctx.va.points[1].id]

	# A press in the lane takes the shortcuts: Delete removes the points, the notes stay.
	pane.selection.select_ids(ctx.va, ids)
	_click(row, Vector2(row.tick_to_x(480), 4.0))
	pane.selection.select_ids(ctx.va, ids)
	_assert(row.has_focus(), "a press in the lane gives it the keyboard focus")
	pane._gui_input(_key(KEY_DELETE))
	_assert(ctx.va.points.is_empty(), "Delete removes the selected points")
	_assert(midi.note_selection.size() == 2, "and keeps the note selection")

	# A press in the note area takes them back: Delete removes the notes, not the points.
	ctx.va.add_point(0, 0.5)
	ctx.va.add_point(1920, 0.25)
	pane.selection.select_ids(ctx.va, [ctx.va.points[0].id, ctx.va.points[1].id])
	var gp: Vector2 = midi.note_area.global_position + Vector2(40.0, 40.0)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.global_position = gp
	ev.position = gp
	midi._handle_note_editing_mouse_button(ev)
	_assert(not row.has_focus() and note_editor.has_focus(), "a press in the note area takes the focus back")
	pane._gui_input(_key(KEY_DELETE))
	_assert(ctx.va.points.size() == 2, "the pane no longer deletes points")
	midi.note_selection.select(refs)
	note_editor._gui_input(_key(KEY_DELETE))
	_assert(ctx.ci_a.clip.midi_notes.size() < 2 and ctx.va.points.size() == 2, "Delete removes the notes and keeps the points")
	await _finish(ctx)


func _test_selection_scope() -> void:
	var ctx := await _setup()
	await _enter_track_mode(ctx, ctx.a)
	var pane = ctx.pane
	var row_a: Control = pane.lanes[0].row
	var row_b: Control = pane.lanes[1].row
	var pa_point: Object = ctx.pa.points[1]
	pane.selection.select_ids(ctx.va, [ctx.va.points[0].id, ctx.va.points[1].id])
	_click(row_b, Vector2(row_b.tick_to_x(pa_point.tick), row_b.value_to_y(pa_point.value)))
	_assert(pane.selection.lane == ctx.pa and pane.selection.get_selected_ids() == [pa_point.id], "pressing a point of lane B leaves only B's point selected")
	pane.selection.select_ids(ctx.va, [ctx.va.points[0].id])
	ctx.midi.focus_track = ctx.b
	_assert(not pane.selection.has_selection(), "switching the focus track clears the selection")
	await _finish(ctx)
