# test_clip_editor_track_list.gd
# Headless tests for the clip editor track list (spec 007): the TrackToggleState model and,
# in later phases, the list, note editor and ClipEditor integration.
# Run: godot --headless --path Godot -s tests/test_clip_editor_track_list.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Clip editor track list tests"


var _track_script: GDScript
var _state_script: GDScript
var _project_script: GDScript
var _list_scene: PackedScene
var _item_scene: PackedScene
var _instance_script: GDScript
var _clip_editor_scene: PackedScene


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_state_script = load("res://clip_editor/tracklist/TrackToggleState.gd")
	_project_script = load("res://data/Project.gd")
	_list_scene = load("res://clip_editor/tracklist/ClipEditorTrackList.tscn")
	_item_scene = load("res://clip_editor/tracklist/ClipEditorTrackListItem.tscn")
	_instance_script = load("res://data/ClipInstance.gd")
	_clip_editor_scene = load("res://clip_editor/ClipEditor.tscn")
	_test_toggle_state_solo()
	_test_toggle_state_editable()
	await _test_item_style()
	await _test_list_all_instrument_tracks()
	await _test_drag_paint()
	await _test_hidden_track_not_drawn()
	await _test_cross_track_note_press()
	await _test_initial_states()
	await _test_selection_follows_editability()
	await _test_header_clip_name()
	await _test_global_toggles()


func _tracks(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(_track_script.new(i + 2))
	return _typed(out)


## Builds an Array[Track] (the model's signatures are typed) from plain elements.
func _typed(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _track_script)


func _vis(state: Object, tracks: Array) -> Array:
	return tracks.map(func(t): return state.is_on(t, 0))


func _test_toggle_state_solo() -> void:
	var V := 0  # TrackToggleState.Kind.VISIBLE
	var E := 1  # TrackToggleState.Kind.EDITABLE
	var t: Array = _tracks(3)
	var s: Object = _state_script.new()
	s.init_from_selection(t, _typed([t[0], t[1]]))
	_assert(_vis(s, t) == [true, true, false], "init_from_selection: selected visible, others hidden")

	# REQ-025 / REQ-026: solo and revert.
	s.toggle_solo(t[2], V)
	_assert(_vis(s, t) == [false, false, true], "solo C: only C visible")
	_assert(s.soloed_track(V) == t[2], "solo C: soloed_track is C")
	_assert(s.soloed_track(E) == null, "solo visible leaves edit kind unsoloed")
	s.toggle_solo(t[2], V)
	_assert(_vis(s, t) == [true, true, false], "solo C again: states restored")
	_assert(s.soloed_track(V) == null, "revert ends the solo")

	# REQ-027: solo moves and keeps the original snapshot.
	s.toggle_solo(t[0], V)
	s.toggle_solo(t[1], V)
	_assert(s.soloed_track(V) == t[1], "solo moved to B")
	_assert(_vis(s, t) == [false, true, false], "moved solo: only B visible")
	s.toggle_solo(t[1], V)
	_assert(_vis(s, t) == [true, true, false], "revert after move restores pre-first-solo states")

	# REQ-027: plain click ends solo, keeps current states.
	s.toggle_solo(t[0], V)
	s.set_on(t[1], V, true)
	_assert(_vis(s, t) == [true, true, false], "plain click during solo: A and B visible")
	_assert(s.soloed_track(V) == null, "plain click ends the solo")

	# Setting the value a track already has does not end the solo (drag-paint safety).
	s.toggle_solo(t[0], V)
	s.set_on(t[1], V, false)
	_assert(s.soloed_track(V) == t[0], "no-op set_on keeps the solo")

	# Kinds are independent.
	s.toggle_solo(t[2], E)
	_assert(s.soloed_track(V) == t[0] and s.soloed_track(E) == t[2], "kinds soloed independently")

	# Removing the soloed track restores the snapshot and ends the solo.
	var s2: Object = _state_script.new()
	s2.init_from_selection(t, _typed([t[0], t[1]]))
	s2.toggle_solo(t[2], V)
	var rest: Array = _typed([t[0], t[1]])
	s2.set_tracks(rest)
	_assert(s2.soloed_track(V) == null, "removing soloed track ends solo")
	_assert(_vis(s2, rest) == [true, true], "removing soloed track restores snapshot")


func _test_toggle_state_editable() -> void:
	var V := 0  # TrackToggleState.Kind.VISIBLE
	var E := 1  # TrackToggleState.Kind.EDITABLE
	var t: Array = _tracks(3)
	var s: Object = _state_script.new()
	s.set_tracks(t)
	_assert(not s.is_on(t[0], V) and not s.is_on(t[0], E), "new tracks start hidden and not editable")

	s.set_on(t[0], V, true)
	s.set_on(t[0], E, true)
	_assert(s.is_editable(t[0]), "visible + edit flag => editable")
	s.set_on(t[0], V, false)
	_assert(not s.is_editable(t[0]), "hidden => not editable")
	_assert(s.is_on(t[0], E), "edit flag kept while hidden")
	s.set_on(t[0], V, true)
	_assert(s.is_editable(t[0]), "shown again => edit flag applies again")

	# first_editable follows the order given.
	s.set_on(t[2], V, true)
	s.set_on(t[2], E, true)
	_assert(s.first_editable(t) == t[0], "first_editable: list order")
	var rev: Array = _typed([t[2], t[1], t[0]])
	_assert(s.first_editable(rev) == t[2], "first_editable: respects given order")
	s.set_on(t[0], E, false)
	s.set_on(t[2], E, false)
	_assert(s.first_editable(t) == null, "first_editable: null when none")

	# set_all / all_on drive the header toggles.
	s.set_on(t[1], V, false)
	_assert(not s.all_on(t, V), "all_on: false when one track is off")
	s.toggle_solo(t[0], V)
	s.set_all(t, V, true)
	_assert(s.all_on(t, V) and s.soloed_track(V) == null, "set_all turns every track on and ends a solo")
	s.set_all(t, V, false)
	_assert(not s.is_on(t[0], V) and not s.is_on(t[2], V), "set_all turns every track off")
	_assert(not s.all_on(_typed([]), V), "all_on: false for an empty list")

	# set_tracks keeps known states and drops removed tracks.
	s.set_on(t[1], V, true)
	var sub: Array = _typed([t[1]])
	s.set_tracks(sub)
	_assert(s.is_on(t[1], V), "set_tracks keeps known track state")
	_assert(not s.is_on(t[0], V), "set_tracks drops removed track")


## Project with `instruments` instrument tracks (named A, B, C...) and `audio` audio tracks.
func _make_project(instruments: int, audio: int = 0) -> Object:
	var project: Object = _project_script.new()
	for i in instruments:
		project.create_bare_track(char(65 + i), 1)  # Track.TrackType.INSTRUMENT
	for i in audio:
		project.create_bare_track("Audio%d" % i, 0)  # Track.TrackType.AUDIO
	return project


func _make_list(project: Object, state: Object) -> Node:
	var list: Node = _list_scene.instantiate()
	root.add_child(list)
	# The headless window is tiny; the scroll view needs room to show every item.
	list.set_anchors_preset(Control.PRESET_TOP_LEFT)
	list.size = Vector2(300, 600)
	list.set_toggle_state(state)
	list.set_project(project)
	await process_frame
	await process_frame
	return list


func _item_for(list: Node, track: Object) -> Node:
	for ti in list.items.get_children():
		if ti.track == track:
			return ti
	return null


func _test_item_style() -> void:
	var project := _make_project(2)
	var a: Object = project.tracks[0]
	var b: Object = project.tracks[1]
	var state: Object = _state_script.new()
	state.set_tracks(_typed([a, b]))
	var ia: Node = _item_scene.instantiate()
	var ib: Node = _item_scene.instantiate()
	root.add_child(ia)
	root.add_child(ib)
	ia.track = a
	ib.track = b
	ia.set_selected(true)
	await process_frame

	var sa: StyleBoxFlat = ia.get_theme_stylebox("panel")
	var sb: StyleBoxFlat = ib.get_theme_stylebox("panel")
	_assert(sa.border_color == Color.WHITE, "selected item has a white border")
	_assert(sb.border_color != Color.WHITE, "unselected item has a soft, non-white border")
	_assert(sa.border_width_left > sb.border_width_left, "selected border is thicker")
	_assert(sa.bg_color.a == 1.0 and sb.bg_color.a < 1.0, "unselected background is translucent")

	ia.refresh_toggles(state)
	_assert(ia.visible_toggle.icon == ia.EYE_OFF, "hidden track shows eye-off")
	_assert(ia.edit_toggle.icon == ia.PENCIL_OFF, "not editable shows pencil-off")
	_assert(ia.edit_toggle.modulate.a < 1.0, "edit toggle dimmed while hidden")
	state.set_on(a, 0, true)
	state.set_on(a, 1, true)
	ia.refresh_toggles(state)
	_assert(ia.visible_toggle.icon == ia.EYE_ON and ia.edit_toggle.icon == ia.PENCIL_ON,
		"visible + editable shows eye and pencil")
	_assert(ia.edit_toggle.modulate.a == 1.0, "edit toggle not dimmed while visible")

	state.toggle_solo(a, 0)
	ia.refresh_toggles(state)
	ib.refresh_toggles(state)
	_assert(ia.visible_toggle.get_theme_color("icon_normal_color") == ia.SOLO_COLOR,
		"soloed visibility toggle uses the solo colour")
	_assert(ia.edit_toggle.get_theme_color("icon_normal_color") != ia.SOLO_COLOR,
		"edit toggle not in solo colour when only visibility is soloed")
	_assert(ib.visible_toggle.get_theme_color("icon_normal_color") != ia.SOLO_COLOR,
		"other item not in solo colour")

	# Toggle press reports kind and shift, and does not emit `pressed`.
	var got: Array = []
	var pressed_count := [0]
	ia.toggle_pressed.connect(func(kind, shift): got.append([kind, shift]))
	ia.pressed.connect(func(): pressed_count[0] += 1)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.shift_pressed = true
	ia._on_toggle_gui_input(ev, 1)
	_assert(got == [[1, true]], "toggle press emits (kind, shift)")
	_assert(pressed_count[0] == 0, "toggle press does not select the item")
	ia.queue_free()
	ib.queue_free()


func _test_list_all_instrument_tracks() -> void:
	var project := _make_project(3, 1)
	var state: Object = _state_script.new()
	var list := await _make_list(project, state)
	_assert(list.listed_tracks().size() == 3, "lists the 3 instrument tracks, not the audio track")
	_assert(list.items.get_child_count() == 3, "one item per listed track (no placeholder)")

	var changes := [0]
	list.tracks_changed.connect(func(): changes[0] += 1)
	var d: Object = project.create_bare_track("D", 1)
	await process_frame
	_assert(list.listed_tracks().has(d) and list.listed_tracks().size() == 4, "follows a track add")
	_assert(changes[0] >= 1, "tracks_changed emitted on add")

	var b: Object = project.tracks[1]
	list.select_track_no_signal(b)
	project.create_bare_track("E", 1)
	await process_frame
	_assert(list.selected_track == b, "selection kept across a rebuild")
	_assert(_item_for(list, b)._selected, "selected item still highlighted after rebuild")

	project.remove_track(b.id)
	await process_frame
	_assert(not list.listed_tracks().has(b), "follows a track remove")
	_assert(list.selected_track == null, "selection dropped when its track is removed")
	list.queue_free()


func _test_drag_paint() -> void:
	var project := _make_project(3)
	var a: Object = project.tracks[0]
	var b: Object = project.tracks[1]
	var c: Object = project.tracks[2]
	var state: Object = _state_script.new()
	state.set_tracks(_typed([a, b, c]))
	var list := await _make_list(project, state)

	# Press on A's eye (off -> on), drag over B and C, release.
	list._on_item_toggle_pressed(0, false, a)
	_assert(state.is_on(a, 0), "press turns A's eye on")
	for t in [b, c]:
		var r: Rect2 = _item_for(list, t).get_global_rect()
		var m := InputEventMouseMotion.new()
		m.global_position = r.get_center()
		list._input(m)
	_assert(state.is_on(b, 0) and state.is_on(c, 0), "dragging paints B and C on")

	# Dragging back over B does not flip it.
	var mb := InputEventMouseMotion.new()
	mb.global_position = _item_for(list, b).get_global_rect().get_center()
	list._input(mb)
	_assert(state.is_on(b, 0), "revisiting an item does not flip it")

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	list._input(up)
	state.set_on(c, 0, false)
	var mc := InputEventMouseMotion.new()
	mc.global_position = _item_for(list, c).get_global_rect().get_center()
	list._input(mc)
	_assert(not state.is_on(c, 0), "motion after release paints nothing")

	# Plain press on an "on" toggle paints "off".
	list._on_item_toggle_pressed(0, false, a)
	_assert(not state.is_on(a, 0), "press on an on toggle turns it off")
	list._input(up)

	# Shift press solos and starts no paint.
	list._on_item_toggle_pressed(0, true, b)
	_assert(state.soloed_track(0) == b, "shift+press solos the track")
	var mc2 := InputEventMouseMotion.new()
	mc2.global_position = _item_for(list, c).get_global_rect().get_center()
	list._input(mc2)
	_assert(not state.is_on(c, 0), "shift+press does not paint")

	# Plain press during a solo ends it and applies normally.
	list._on_item_toggle_pressed(0, false, a)
	_assert(state.soloed_track(0) == null and state.is_on(a, 0) and state.is_on(b, 0),
		"plain press during solo ends it and keeps states")
	list._input(up)
	list.queue_free()


func _typed_instances(items: Array) -> Array:
	return Array(items, TYPE_OBJECT, &"RefCounted", _instance_script)


## Two instrument tracks A and B, each with one clip instance at tick 0. A has notes at pitch
## 60 and 64, B at 60 (same spot as A's) and 72. Returns {project, a, b, ci_a, ci_b, midi, clip_editor}.
func _make_midi_setup() -> Dictionary:
	var project: Object = _project_script.new()
	var out := {"project": project}
	for key in ["a", "b"]:
		var pair: Dictionary = project.create_instrument_track(key.to_upper())
		var clip: Object = project.create_clip("Clip" + key)
		project.add_clip(clip)
		var ci: Object = pair.track.create_clip_instance(clip, 0, 3840)
		var pitches := [60, 64] if key == "a" else [60, 72]
		for pitch in pitches:
			clip.add_midi_note(project.allocate_note_id(), pitch, 100, 0, 480)
		out[key] = pair.track
		out["ci_" + key] = ci
	var clip_editor: Control = _clip_editor_scene.instantiate()
	root.add_child(clip_editor)
	out["clip_editor"] = clip_editor
	out["midi"] = clip_editor.midi_editor
	await process_frame
	await process_frame
	return out


func _editor_of(midi: Object, track: Object) -> Object:
	for e in midi.note_editors:
		if midi._editor_track(e) == track:
			return e
	return null


func _note_center(editor: Object, pitch: int) -> Vector2:
	for vn in editor.get_all_visual_notes():
		if vn.midi_note_data.note == pitch:
			return vn.get_global_rect().get_center()
	return Vector2(-99999, -99999)


func _mouse_button(gp: Vector2, button: int, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.global_position = gp
	ev.position = gp
	return ev


func _test_hidden_track_not_drawn() -> void:
	var setup := await _make_midi_setup()
	var midi: Object = setup.midi
	var a: Object = setup.a
	var b: Object = setup.b
	var clips := _typed_instances([setup.ci_a, setup.ci_b])
	midi.bind_to_clips(clips, _typed([a, b]))
	await process_frame
	await process_frame
	var scene_editor: Object = midi.note_editors[0]
	var editor_a: Object = _editor_of(midi, a)
	_assert(editor_a != null and _editor_of(midi, b) != null, "both tracks have an editor after bind")

	# Selection on A must survive B being hidden.
	var first_note: Array[VisualNote] = [editor_a.get_all_visual_notes()[0]]
	editor_a.selection_manager._set_selected_notes(first_note)
	midi.set_track_views(_typed([a]), clips)
	await process_frame
	_assert(_editor_of(midi, b) == null, "hiding B leaves no editor for B")
	_assert(_editor_of(midi, a) == editor_a, "A keeps its editor")
	_assert(editor_a.selection_manager.selected_notes.size() == 1, "A's note selection survives hiding B")
	_assert(midi.note_editors[0] == scene_editor, "the scene editor stays first")
	var drawn := 0
	for e in midi.note_editors:
		if e.visible:
			drawn += e.get_all_visual_notes().size()
	_assert(drawn == 2, "only A's 2 notes are drawn: %d" % drawn)

	midi.set_track_views(_typed([]), clips)
	await process_frame
	_assert(midi.note_editors[0] == scene_editor and not scene_editor.visible,
		"with nothing visible the scene editor is kept but hidden")

	midi.set_track_views(_typed([a, b]), clips)
	await process_frame
	await process_frame
	var editor_b: Object = _editor_of(midi, b)
	_assert(editor_b != null and editor_b.get_all_visual_notes().size() == 2, "showing B draws its 2 notes again")
	_assert(midi.note_editors[0] == scene_editor, "the scene editor is still first")

	# Dimming: active 1.0, editable 0.85, visible but not editable 0.5.
	midi.editable_tracks = _typed([a])
	midi.current_track = a
	_assert(_editor_of(midi, a).modulate.a == 1.0, "active editor is fully opaque")
	_assert(_editor_of(midi, b).modulate.a == 0.5, "visible non-editable track is dimmed to 0.5")
	midi.editable_tracks = _typed([a, b])
	_assert(is_equal_approx(_editor_of(midi, b).modulate.a, 0.85), "editable inactive track is 0.85")
	setup.clip_editor.queue_free()
	await process_frame


func _test_cross_track_note_press() -> void:
	var setup := await _make_midi_setup()
	var midi: Object = setup.midi
	var a: Object = setup.a
	var b: Object = setup.b
	var clips := _typed_instances([setup.ci_a, setup.ci_b])
	midi.bind_to_clips(clips, _typed([a, b]))
	midi.set_track_views(_typed([a, b]), clips)
	midi.editable_tracks = _typed([a, b])
	midi.current_track = a
	await process_frame
	await process_frame
	var ea: Object = _editor_of(midi, a)
	var eb: Object = _editor_of(midi, b)

	var picked: Array = []
	midi.note_track_picked.connect(func(t): picked.append(t))

	# Overlapping notes (both tracks have pitch 60 at tick 0): the active track wins (REQ-035).
	var hit: Array = midi._note_hit(_note_center(ea, 60))
	_assert(hit.size() == 2 and hit[0] == ea, "overlapping notes: the active track's note is hit first")
	midi.current_track = b
	hit = midi._note_hit(_note_center(eb, 60))
	_assert(hit.size() == 2 and hit[0] == eb, "overlapping notes: after switching, B's note wins")
	midi.current_track = a

	# Pressing B's own note picks B (REQ-033, REQ-034).
	var gp := _note_center(eb, 72)
	midi._handle_left_mouse_press(eb.make_canvas_position_local(gp), _mouse_button(gp, MOUSE_BUTTON_LEFT, true))
	_assert(midi.current_track == b, "pressing B's note selects B")
	_assert(picked == [b], "note_track_picked emitted with B")
	midi._handle_left_mouse_release(eb.make_canvas_position_local(gp), _mouse_button(gp, MOUSE_BUTTON_LEFT, false))
	_assert(midi.get_active_note_editor() == eb, "B's editor is now active")

	# The next empty-space press places on B (REQ-036).
	var count_before: int = setup.ci_b.clip.midi_notes.size()
	var empty_gp := _note_center(eb, 72) + Vector2(0, midi.note_height * 5)
	midi._handle_left_mouse_press(eb.make_canvas_position_local(empty_gp), _mouse_button(empty_gp, MOUSE_BUTTON_LEFT, true))
	midi._handle_left_mouse_release(eb.make_canvas_position_local(empty_gp), _mouse_button(empty_gp, MOUSE_BUTTON_LEFT, false))
	_assert(setup.ci_b.clip.midi_notes.size() == count_before + 1, "empty-space press places a note on B")
	_assert(picked == [b], "an empty-space press does not emit note_track_picked")

	# Right-press erases B's note while A stays selected (REQ-037).
	midi.current_track = a
	picked.clear()
	gp = _note_center(eb, 72)
	var n_b: int = setup.ci_b.clip.midi_notes.size()
	midi._handle_right_mouse_press(ea.make_canvas_position_local(gp), _mouse_button(gp, MOUSE_BUTTON_RIGHT, true))
	midi._handle_right_mouse_release()
	_assert(setup.ci_b.clip.midi_notes.size() == n_b - 1, "right-press erased B's note")
	_assert(midi.current_track == a and picked.is_empty(), "erasing does not switch tracks")

	# Box select covers only the active track's notes (REQ-038).
	var boxed: Array = ea.get_notes_in_box(Rect2(-100000, -100000, 200000, 200000))
	var only_a := true
	for vn in boxed:
		if not ea.is_ancestor_of(vn):
			only_a = false
	_assert(only_a and boxed.size() == ea.get_all_visual_notes().size(), "box select covers only A's notes")

	# A non-editable B is not hit (REQ-039).
	midi.editable_tracks = _typed([a])
	var hit_b := false
	for vn in eb.get_all_visual_notes():
		var h: Array = midi._note_hit(vn.get_global_rect().get_center())
		if not h.is_empty() and h[0] == eb:
			hit_b = true
	_assert(not hit_b, "a visible but non-editable track's notes are not hit")

	# No selected track: no active editor, so nothing to place on (REQ-031).
	midi.current_track = null
	_assert(midi.get_active_note_editor() == null, "track mode with no selected track has no active editor")
	setup.clip_editor.queue_free()
	await process_frame


## A ClipEditor over a project with `n` instrument tracks A, B, C... each with one clip instance
## (one note) at tick 0. Returns {project, tracks, cis, editor, midi}.
func _make_editor_setup(n: int) -> Dictionary:
	var project: Object = _project_script.new()
	var tracks: Array = []
	var cis: Array = []
	for i in n:
		var pair: Dictionary = project.create_instrument_track(char(65 + i))
		var clip: Object = project.create_clip("Clip" + char(65 + i))
		project.add_clip(clip)
		cis.append(pair.track.create_clip_instance(clip, 0, 3840))
		clip.add_midi_note(project.allocate_note_id(), 60, 100, 0, 480)
		tracks.append(pair.track)
	var editor: Control = _clip_editor_scene.instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	return {"project": project, "tracks": tracks, "cis": cis, "editor": editor, "midi": editor.midi_editor}


## Opens the clip editor in track mode on the clips at `indices`, like an arranger selection.
func _open_track_mode(setup: Dictionary, indices: Array) -> void:
	var picked: Array = indices.map(func(i): return setup.cis[i])
	setup.editor.pending_clips = _typed_instances(picked)
	setup.editor.pending_multi_track = true
	setup.editor._bind_pending_clips()
	await process_frame
	await process_frame


func _editor_tracks(midi: Object) -> Array:
	var out: Array = []
	for e in midi.note_editors:
		var t: Object = midi._editor_track(e)
		if t:
			out.append(t)
	return out


func _test_initial_states() -> void:
	var setup := await _make_editor_setup(3)
	var ce: Object = setup.editor
	var t: Array = setup.tracks
	await _open_track_mode(setup, [0, 2])
	var st: Object = ce.track_toggles
	_assert(ce.track_selector.listed_tracks().size() == 3, "the list shows all 3 instrument tracks")
	_assert(st.is_editable(t[0]) and st.is_editable(t[2]), "selected tracks A and C start visible and editable")
	_assert(not st.is_on(t[1], 0) and not st.is_on(t[1], 1), "unselected track B starts hidden and not editable")
	var drawn := _editor_tracks(setup.midi)
	_assert(drawn.size() == 2 and drawn.has(t[0]) and drawn.has(t[2]) and not drawn.has(t[1]),
		"only A and C have note editors")
	_assert(setup.midi.current_track == t[0], "the first selected track is the active one")
	_assert(setup.midi.editable_tracks.size() == 2, "MidiEditor knows the editable tracks")

	# Re-entry with no new selection keeps the states.
	st.set_on(t[2], 0, false)
	ce.track_mode_toggle.button_pressed = false
	await process_frame
	ce.track_mode_toggle.button_pressed = true
	await process_frame
	await process_frame
	_assert(not st.is_on(t[2], 0) and st.is_editable(t[0]) and not st.is_on(t[1], 0),
		"re-entering track mode keeps the previous states")
	_assert(not _editor_tracks(setup.midi).has(t[2]), "and C stays undrawn")

	# A new selection resets them.
	await _open_track_mode(setup, [1])
	_assert(st.is_editable(t[1]) and not st.is_on(t[0], 0) and not st.is_on(t[2], 0),
		"a new selection resets the states from it")
	ce.queue_free()
	await process_frame


func _test_selection_follows_editability() -> void:
	var setup := await _make_editor_setup(3)
	var ce: Object = setup.editor
	var midi: Object = setup.midi
	var t: Array = setup.tracks
	await _open_track_mode(setup, [0, 1])
	var st: Object = ce.track_toggles
	var emitted: Array = []
	ce.track_mode_track_selected.connect(func(tr): emitted.append(tr))

	_assert(midi.current_track == t[0], "A starts selected")
	st.toggle_solo(t[1], 1)
	_assert(midi.current_track == t[1], "soloing B's edit toggle selects B")
	_assert(ce.track_selector.selected_track == t[1], "the list highlight follows")
	st.toggle_solo(t[1], 1)

	# Selecting hidden C makes it visible and editable (REQ-030).
	_assert(not st.is_on(t[2], 0), "C starts hidden")
	ce.track_selector._on_item_pressed(t[2])
	_assert(st.is_on(t[2], 0) and st.is_on(t[2], 1), "selecting C makes it visible and editable")
	_assert(midi.current_track == t[2] and _editor_tracks(midi).has(t[2]), "C is active and drawn")
	_assert(emitted.has(t[2]), "track_mode_track_selected emitted for C")

	# Hiding the selected track moves the selection to the first editable one.
	st.set_on(t[2], 0, false)
	_assert(midi.current_track == t[0], "hiding the selected track selects the first editable")

	# Nothing editable: no selection, and a press on empty space places nothing.
	for tr in t:
		st.set_on(tr, 1, false)
	_assert(midi.current_track == null and ce.track_selector.selected_track == null, "no editable track: no selection")
	var notes_before := 0
	for ci in setup.cis:
		notes_before += ci.clip.midi_notes.size()
	var gp: Vector2 = midi.note_area.global_position + Vector2(300, 200)
	var ev := _mouse_button(gp, MOUSE_BUTTON_LEFT, true)
	midi._handle_note_editing_mouse_button(ev)
	var notes_after := 0
	for ci in setup.cis:
		notes_after += ci.clip.midi_notes.size()
	_assert(notes_after == notes_before, "a press on empty grid space places no note")

	# Removing the selected track moves the selection (REQ-032).
	st.set_on(t[0], 1, true)
	st.set_on(t[1], 1, true)
	_assert(midi.current_track == t[0], "A is selected again")
	setup.project.remove_track(t[0].id)
	await process_frame
	await process_frame
	_assert(not ce.track_selector.listed_tracks().has(t[0]), "A left the list")
	_assert(midi.current_track == t[1], "removing the selected track selects another editable one")
	ce.queue_free()
	await process_frame


func _test_header_clip_name() -> void:
	var setup := await _make_editor_setup(2)
	var ce: Object = setup.editor
	var clip: Object = setup.cis[0].clip
	clip.set_name("Bassline")
	ce.pending_clips = _typed_instances([setup.cis[0]])
	ce.pending_multi_track = false
	ce._bind_pending_clips()
	await process_frame
	_assert(ce.clip_name_label.visible and ce.clip_name_label.text == "Bassline", "clip mode header shows the clip name")
	clip.set_name("Bass 2")
	_assert(ce.clip_name_label.text == "Bass 2", "renaming the clip updates the header")
	_assert(ce.track_mode_toggle.icon != null and ce.track_mode_toggle.text == "", "the mode toggle is an icon button")
	_assert(not ce.track_mode_toggle.button_pressed, "the toggle is released in clip mode")
	var tip_clip: String = ce.track_mode_toggle.tooltip_text

	await _open_track_mode(setup, [0, 1])
	_assert(not ce.clip_name_label.visible, "track mode hides the clip name")
	_assert(ce.track_mode_toggle.button_pressed, "the toggle is pressed in track mode")
	_assert(ce.track_mode_toggle.tooltip_text != tip_clip and ce.track_mode_toggle.tooltip_text.contains("Clip"),
		"the tooltip names the mode it switches to")
	ce.queue_free()
	await process_frame


func _test_global_toggles() -> void:
	var setup := await _make_editor_setup(3)
	var ce: Object = setup.editor
	var midi: Object = setup.midi
	var t: Array = setup.tracks
	await _open_track_mode(setup, [0])
	var st: Object = ce.track_toggles
	_assert(st.is_editable(t[0]) and not st.is_on(t[1], 0), "only A starts visible")

	ce.all_visible_toggle.pressed.emit()
	_assert(st.is_on(t[0], 0) and st.is_on(t[1], 0) and st.is_on(t[2], 0), "global eye turns every track on")
	_assert(_editor_tracks(midi).size() == 3, "all three tracks are drawn")
	ce.all_visible_toggle.pressed.emit()
	_assert(not st.is_on(t[0], 0) and not st.is_on(t[1], 0), "global eye again turns every track off")
	_assert(midi.current_track == null, "with everything hidden nothing is selected")

	ce.all_editable_toggle.pressed.emit()
	_assert(st.is_on(t[1], 1) and st.is_on(t[2], 1), "global pencil turns every edit toggle on")
	ce.all_visible_toggle.pressed.emit()
	_assert(midi.current_track == t[0], "showing everything selects the first editable track")
	ce.all_editable_toggle.pressed.emit()
	_assert(not st.is_on(t[0], 1) and midi.current_track == null, "global pencil again turns them all off")

	# The list scrolls, and the header icons follow the state.
	_assert(ce.track_selector.scroll is ScrollContainer and ce.track_selector.items.get_parent() == ce.track_selector.scroll,
		"the items live in a ScrollContainer")
	_assert(ce.all_visible_toggle.icon == load("res://assets/icons/eye.svg"), "global eye shows eye when all are visible")
	ce.queue_free()
	await process_frame
