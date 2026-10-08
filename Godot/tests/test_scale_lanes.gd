# test_scale_lanes.gd
# Scale lane shading (REQ-005/006/007), fold rows (REQ-008) and the folded keyboard header.
# Run: godot --headless --path Godot -s tests/test_scale_lanes.gd -- --test
extends TestBase

const W := Color(0.4, 0.4, 0.4, 1.0)
const B := Color(0.2, 0.2, 0.2, 1.0)
const ACCENT := Color(0.3, 0.55, 1.0, 0.3)

var _clip_script: GDScript
## Loaded at runtime: naming NoteLanes/VPiano as types pulls Project.gd (autoload refs) into the
## compile graph, which fails headless.
var NoteLanes: GDScript
var VPiano: GDScript


func suite_name() -> String:
	return "Scale lanes / fold rows"


func run_tests() -> void:
	_clip_script = load("res://data/Clip.gd")
	NoteLanes = load("res://clip_editor/NoteLanes.gd")
	VPiano = load("res://components/VPiano.gd")
	_test_lane_color()
	_test_none_unchanged()
	_test_mapped_lane_differs()
	_test_highlight_gating()
	_test_scale_rows()
	_test_folded_piano()
	_test_not_drum()
	await _test_midi_editor_fold()


func _c_major() -> PackedInt32Array:
	return MusicalScale.make(0, "major").pitch_classes()


func _test_lane_color() -> void:
	var pcs := _c_major()
	var tint := Color(0.2, 0.85, 0.6, 0.12)  # out-of-scale tint, alpha = strength
	# D3 (62): in scale, not root: plain white key colour.
	_assert(NoteLanes.lane_color(62, W, B, pcs, 0, tint, ACCENT) == W, "REQ-005: in-scale white lane keeps the base colour")
	# C#3 (61): out of scale, black key: dimmed black.
	_assert(NoteLanes.lane_color(61, W, B, pcs, 0, tint, ACCENT) == B.lerp(Color(tint, B.a), tint.a), "REQ-005: out-of-scale black lane is tinted")
	# Out-of-scale and in-scale white lanes differ in a scale where a white key is out (C pentatonic: F).
	var pent := MusicalScale.make(0, "major_pentatonic").pitch_classes()
	_assert(NoteLanes.lane_color(65, W, B, pent, 0, tint, ACCENT) == W.lerp(Color(tint, W.a), tint.a), "REQ-005: out-of-scale white lane is tinted")
	# Root lanes carry the accent in every octave.
	var root_ok := true
	for p in [24, 36, 48, 60, 72]:
		var c = NoteLanes.lane_color(p, W, B, pcs, 0, tint, ACCENT)
		if c == W or c.b <= W.b:
			root_ok = false
	_assert(root_ok, "REQ-005: every C lane is accented")
	_assert(NoteLanes.lane_color(60, W, B, pcs, 0, tint, ACCENT) != NoteLanes.lane_color(62, W, B, pcs, 0, tint, ACCENT), "REQ-005: root differs from other in-scale lanes")
	# A root that is a black key (C# Major, root 1).
	var cs := MusicalScale.make(1, "major")
	var cs_c = NoteLanes.lane_color(61, W, B, cs.pitch_classes(), cs.root, tint, ACCENT)
	_assert(cs_c != B and cs_c != B.lerp(Color(tint, B.a), tint.a), "REQ-005: black-key root is accented")


func _test_none_unchanged() -> void:
	var none := MusicalScale.make(0, "none")
	var ok := true
	for p in 128:
		var base = B if Midi.is_black_key(p) else W
		if NoteLanes.lane_color(p, W, B, none.pitch_classes(), none.root, Color(0.2, 0.85, 0.6, 0.12), ACCENT) != base:
			ok = false
	_assert(ok, "REQ-006: with no scale every lane is the plain white/black key colour")


func _test_mapped_lane_differs() -> void:
	var lanes = NoteLanes.new()
	var ctx := ScaleContext.new()
	ctx.scale = MusicalScale.make(0, "major")
	lanes.scale_context = ctx
	var map := NoteMap.new()
	map.set_entry(61, "Hit", Color.RED)
	lanes.note_map = map
	var base: Color = NoteLanes.lane_color(61, W, B, _c_major(), 0, lanes._out_of_scale_tint(), lanes.root_accent_color)
	var mapped = lanes._tinted(base, 61)
	var unmapped = lanes._tinted(base, 63)
	_assert(mapped != unmapped, "REQ-007: a mapped out-of-scale lane differs from an unmapped one")
	_assert(unmapped == base, "REQ-007: an unmapped lane keeps the scale shading")
	lanes.free()


func _test_highlight_gating() -> void:
	var ctx := ScaleContext.new()
	_assert(not ctx.highlight_active(), "REQ-006: no scale means no highlight")
	ctx.scale = MusicalScale.make(2, "dorian")
	_assert(ctx.highlight_active(), "scale set: highlight active")
	ctx.drum_view = true
	_assert(not ctx.highlight_active(), "Drum View: highlight inactive")
	# Changing the context redraws a connected NoteLanes (signal wired both ways).
	var lanes = NoteLanes.new()
	lanes.scale_context = ctx
	_assert(ctx.changed.is_connected(lanes.queue_redraw), "NoteLanes redraws on scale_context.changed")
	lanes.scale_context = null
	_assert(not ctx.changed.is_connected(lanes.queue_redraw), "old context disconnected")
	lanes.free()


func _clip(pitches: Array) -> Object:
	var clip: Object = _clip_script.new()
	var id := 1
	for p in pitches:
		clip.add_midi_note(id, int(p), MidiNoteData.from_midi_velocity(100), 0, 240)
		id += 1
	return clip


func _test_scale_rows() -> void:
	var scale := MusicalScale.make(0, "major_pentatonic")
	var rows := ScaleRows.rows_for(scale, [_clip([60, 61])])
	var expected := PackedInt32Array()
	for p in 128:
		if [0, 2, 4, 7, 9].has(p % 12) or p == 61:
			expected.append(p)
	_assert(rows == expected, "REQ-008: pentatonic rows plus used C#3")
	_assert(rows.has(61) and not rows.has(63), "REQ-008: used out-of-scale pitch shown, unused hidden")
	_assert(ScaleRows.rows_for(MusicalScale.make(0, "none"), [_clip([61])]) == PackedInt32Array([61]),
		"no scale: only used pitches")
	# Folding through a layout is not Drum View.
	var layout := LaneLayout.chromatic()
	layout.set_rows(rows, false)
	_assert(layout.is_folded() and not layout.is_drum(), "scale fold is folded but not drum")


func _test_folded_piano() -> void:
	var scale := MusicalScale.make(2, "dorian")
	var rows := ScaleRows.rows_for(scale, [])
	var layout := LaneLayout.chromatic(20.0)
	layout.set_rows(rows, false)
	var piano = VPiano.new()
	piano.layout = layout
	piano.size = Vector2(100, layout.total_height())
	var y61 := layout.pitch_to_y(62) # D3
	var r = piano.get_note_rect(62)
	_assert(is_equal_approx(r.position.y, y61) and is_equal_approx(r.size.y, 20.0), "REQ-012: key rect is the plain row rect")
	_assert(piano.get_note_at_position(Vector2(10, y61 + 5)) == 62, "REQ-012: hit-test resolves by row")
	# Row above D3 (62) is E3 (64) in D Dorian.
	_assert(piano.get_note_at_position(Vector2(10, y61 - 5)) == 64, "REQ-012: next row up is E3")
	_assert(piano.get_note_at_position(Vector2(200, 5)) == -1, "outside the key column is -1")
	# Chromatic geometry still grows white keys.
	var chrom := LaneLayout.chromatic(20.0)
	piano.layout = chrom
	_assert(piano.get_note_rect(62).size.y > 20.0, "chromatic keyboard unchanged: white D key spans extra height")
	piano.free()


func _test_not_drum() -> void:
	var layout := LaneLayout.chromatic()
	layout.set_rows(PackedInt32Array([36, 38]))
	_assert(layout.is_drum(), "set_rows defaults to drum")


func _test_midi_editor_fold() -> void:
	root.get_node("Sonara").set_config("clip_editor/value_lanes", {})
	var rig = load("res://tests/value_lane_rig.gd").new(self)
	await rig.build([0, 960], [0.5, 0.5], [], [60, 61])
	var me = rig.midi_editor
	var ctx: ScaleContext = me.scale_context
	_assert(me.note_lanes.scale_context == ctx and me.v_piano.scale_context == ctx and me.note_editor.scale_context == ctx,
		"MidiEditor hands one ScaleContext to lanes, piano and note editor")
	_assert(not me.lane_layout.is_folded(), "no scale: chromatic")
	ctx.scale = MusicalScale.make(0, "major_pentatonic")
	_assert(not me.lane_layout.is_folded(), "scale set without fold: still chromatic")
	ctx.fold_enabled = true
	_assert(me.lane_layout.is_folded() and not me.lane_layout.is_drum(), "fold on: folded, not drum")
	_assert(me.lane_layout.row_of_pitch(61) >= 0 and me.lane_layout.row_of_pitch(63) < 0, "used C#3 shown, unused D#3 hidden")
	_assert(me.lane_layout.row_of_pitch(62) >= 0, "in-scale D3 shown")
	ctx.scale = MusicalScale.make(2, "dorian")
	_assert(me.lane_layout.row_of_pitch(62) >= 0 and me.lane_layout.row_of_pitch(64) >= 0 and me.lane_layout.row_of_pitch(66) < 0,
		"scale change while folded rebuilds rows (D dorian: E in, F# out)")
	_assert(not me.drum_view_is_empty(), "drum-only empty hint stays off")
	ctx.fold_enabled = false
	_assert(not me.lane_layout.is_folded(), "fold off: back to chromatic")
	ctx.fold_enabled = true
	me.drum_view = true
	_assert(me.lane_layout.is_drum() and not ctx.fold_active(), "Drum View wins over the fold")
	me.drum_view = false
	_assert(me.lane_layout.is_folded() and not me.lane_layout.is_drum(), "leaving Drum View returns to the scale fold")
	await rig.cleanup()
