# Run: godot --headless --path Godot -s tests/test_value_lane_stems.gd -- --test
# Stems sit under their notes through zoom and scroll, at the start (velocity) or the end
# (release), and Drum View, ghosts and selection are reported right (REQ-017 - REQ-019).
extends TestBase

const Rig := preload("res://tests/value_lane_rig.gd")


func suite_name() -> String:
	return "Value lane: stems"


func run_tests() -> void:
	root.get_node("Sonara").set_config("clip_editor/value_lanes", {})
	await _test_alignment()
	await _test_release_at_note_end()
	await _test_selection_and_hover()


func _near(a: float, b: float, eps := 0.6) -> bool:
	return absf(a - b) <= eps


func _aligned(rig, index := 0, use_end := false) -> bool:
	var a = rig.area(index)
	for stem in rig.midi_editor.value_stems():
		var vn = stem["visual"]
		var want: float = (vn.global_position.x + (vn.size.x if use_end else 0.0)) - a.global_position.x
		if not _near(a.stem_x(stem), want):
			return false
	return true


func _test_alignment() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960, 1920, 2880], [0.2, 0.4, 0.6, 0.8])
	_assert(rig.midi_editor.value_stems().size() == 4, "one stem per note")
	_assert(_aligned(rig), "stems start at their notes")
	_assert(_near(rig.stem_x_of(0), 0.0), "the tick 0 stem is on the stem area's left edge, not left of it (%s)" % rig.stem_x_of(0))
	rig.midi_editor.playhead_ticks = 960
	await process_frame
	var ph: Control = rig.midi_editor.playhead
	var mirror: Control = rig.area()._playhead
	_assert(mirror.visible and _near(mirror.global_position.x, ph.global_position.x), "the lane shows the playhead where the note area does")
	rig.midi_editor.playhead_ticks = -1
	await process_frame
	_assert(not mirror.visible, "and hides it with the note area's")
	rig.midi_editor.grid_helper.pixels_per_beat = 120.0
	for _i in 3:
		await process_frame
	_assert(_aligned(rig), "still aligned after zooming")
	rig.midi_editor.h_scroll.scroll_horizontal = 150
	for _i in 3:
		await process_frame
	_assert(_aligned(rig), "still aligned after scrolling")
	await rig.cleanup()


func _test_release_at_note_end() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960], [0.5, 0.5], [0.9, 0.2])
	rig.editor.value_pane.add_lane("rel")
	await process_frame
	_assert(_aligned(rig, 1, true), "release stems sit at the note ends")
	var vel_x := rig.stem_x_of(0, 0)
	var rel_x := rig.stem_x_of(0, 1)
	_assert(rel_x > vel_x, "a release stem is right of its velocity stem (%s > %s)" % [rel_x, vel_x])
	await rig.cleanup()


func _test_selection_and_hover() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960, 1920], [0.3, 0.5, 0.7])
	rig.select([1])
	var stems: Array = rig.midi_editor.value_stems()
	var selected := stems.filter(func(s): return s["selected"])
	_assert(selected.size() == 1 and selected[0]["note_data"] == rig.note(1), "only the selected note's stem is selected")
	_assert(stems.all(func(s): return not s["ghost"]), "no ghosts without loops")
	rig.midi_editor.set_hovered_note(rig.note(2))
	var lit := 0
	for vn in rig.midi_editor.note_editor.get_all_visual_notes():
		if vn.self_modulate.r > 1.0:
			lit += 1
	_assert(lit == 1, "hovering a stem highlights its note")
	rig.midi_editor.set_hovered_note(null)
	await rig.cleanup()

	# A chord: the stem whose head is nearest the pointer is the hovered one.
	var chord = Rig.new(self)
	await chord.build([0, 0], [0.2, 0.9])
	var a = chord.area()
	var cx: float = chord.stem_x_of(0)
	a._update_hover(Vector2(cx, a.stem_top(0.2)))
	_assert(chord.midi_editor.hovered_note_data == chord.note(0), "hovering a chord's low stem picks it")
	a._update_hover(Vector2(cx, a.stem_top(0.9)))
	_assert(chord.midi_editor.hovered_note_data == chord.note(1), "hovering its high stem picks that one")
	await chord.cleanup()
