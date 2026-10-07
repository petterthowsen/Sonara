# test_clip_text_regressions.gd
# Regressions from a real assistant transcript: tick overflow, negative octaves,
# multi-word drum lanes, and pasted read_clip listings.
# Run: godot --headless --path Godot -s ai/tests/test_clip_text_regressions.gd -- --test
extends TestBase


## Stand-in for Clip so this script never loads Clip.gd (AudioEngineOSC) in -s.
class StubClip extends RefCounted:
	var name: String = "Test"
	var type: int = 1
	var midi_notes: Array = []
	var content_length_ticks: int = 3840
	func is_synced_to_engine() -> bool:
		return false

	func extend_content_length(end_tick: int) -> void:
		if end_tick > content_length_ticks:
			content_length_ticks = end_tick


var _clip_text: GDScript
var _time: GDScript


func suite_name() -> String:
	return "Clip text regression tests"


func run_tests() -> void:
	_clip_text = load("res://ai/clip_text/ClipText.gd")
	_time = load("res://ai/clip_text/ClipTextTime.gd")
	_test_tick_overflow()
	_test_negative_octaves()
	_test_multiword_drum_lanes()
	_test_duplicate_lanes()
	_test_listing_lines()


func _clip(bars: int = 1, ticks_per_bar: int = 3840) -> StubClip:
	var c := StubClip.new()
	c.content_length_ticks = bars * ticks_per_bar
	return c


func _add(clip: StubClip, id: int, pitch: int, start: int, dur: int, vel: int) -> void:
	var n := MidiNoteData.new()
	n.id = id
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	n.velocity = MidiNoteData.from_midi_velocity(vel)
	clip.midi_notes.append(n)


func _test_tick_overflow() -> void:
	# 7/8: a beat is an eighth (480 ticks).
	_assert(_time.parse_bbt("1.1.480", 960, 7, 8) == -1, "7/8 1.1.480 rejected")
	_assert(_time.parse_bbt("1.2.000", 960, 7, 8) == 480, "7/8 1.2.000 accepted")
	_assert(_time.parse_bbt("1.1.240", 960, 7, 8) == 240, "7/8 1.1.240 accepted")
	_assert(_time.parse_bbt("1.8.000", 960, 7, 8) == -1, "7/8 beat 8 rejected")
	_assert(_time.parse_bbt("1.7.479", 960, 7, 8) == 6 * 480 + 479, "7/8 last tick of bar accepted")
	var r: Dictionary = _time.check_bbt("1.1.480", 960, 7, 8)
	var msg := str(r.get("error", ""))
	_assert(msg.contains("7/8") and msg.contains("480 ticks") and msg.contains("ticks 0–479") and msg.contains("use 1.2.000"), "error states signature, beat length, fix: %s" % msg)
	# 4/4: a beat is a quarter (960 ticks).
	_assert(_time.parse_bbt("1.1.480", 960, 4, 4) == 480, "4/4 1.1.480 accepted")
	_assert(_time.parse_bbt("1.1.960", 960, 4, 4) == -1, "4/4 1.1.960 rejected")
	_assert(_time.parse_bbt("2", 960, 7, 8) == 3360, "bare bar accepted")
	_assert(_time.parse_bbt("2.3", 960, 7, 8) == 3360 + 960, "bar.beat accepted")

	# Through write_clip: the error reaches the model and nothing is written.
	var opts := {"kind": "events", "ppq": 960, "numerator": 7, "denominator": 8}
	var clip := _clip(1, 3360)
	var bad: Dictionary = _clip_text.apply(clip, null, "add 1.1.480 C3 1/8 v90", opts)
	_assert(not bool(bad.get("ok", false)) and str(bad.get("error", "")).contains("use 1.2.000"), "add 1.1.480 in 7/8 errors: %s" % bad)
	_assert(clip.midi_notes.is_empty(), "rejected add writes nothing")
	var good: Dictionary = _clip_text.apply(clip, null, "add 1.2.000 C3 1/8 v90", opts)
	_assert(bool(good.get("ok", false)) and clip.midi_notes.size() == 1 and clip.midi_notes[0].start_tick == 480, "add 1.2.000 in 7/8 lands on tick 480: %s" % good)
	var mv: Dictionary = _clip_text.apply(clip, null, "move n%d 1.1.480" % clip.midi_notes[0].id, opts)
	_assert(not bool(mv.get("ok", false)) and str(mv.get("error", "")).contains("7/8"), "move to 1.1.480 in 7/8 errors: %s" % mv)

	# Tool args (clip/marker placement).
	var project: Object = load("res://data/Project.gd").new()
	project.time_numerator = 7
	project.time_denominator = 8
	var ai_tool: GDScript = load("res://ai/tools/AiTool.gd")
	_assert(not ai_tool.position_error(project, {"start": "1.1.480"}).is_empty(), "tool start 1.1.480 rejected in 7/8")
	_assert(ai_tool.position_error(project, {"start": "1.2.000"}).is_empty(), "tool start 1.2.000 accepted")
	_assert(ai_tool.position_error(project, {"start": "5"}).is_empty(), "tool bare bar accepted")
	_assert(not ai_tool.position_error(project, {"end": "2.8"}, "end").is_empty(), "tool end 2.8 rejected (beat 8)")
	var span: Dictionary = ai_tool.resolve_time_span(project, {"start": "1.1", "end": "2.1.480"})
	_assert(span.has("error") and str(span.error).contains("end:"), "span error names the argument: %s" % span)


func _test_negative_octaves() -> void:
	_assert(Midi.note_name_to_midi("C-2") == 0, "C-2 = 0")
	_assert(Midi.note_name_to_midi("C-1") == 12, "C-1 = 12")
	_assert(Midi.note_name_to_midi("G-1") == 19, "G-1 = 19")
	_assert(Midi.note_name_to_midi("E-2") == 4, "E-2 = 4")
	_assert(Midi.note_name_to_midi("A#-1") == 22, "A#-1 = 22")
	_assert(Midi.note_name_to_midi("Bb-1") == 22, "Bb-1 = 22")
	_assert(Midi.note_name_to_midi("G8") == 127, "G8 = 127")
	_assert(Midi.note_name_to_midi("C3") == 60, "C3 = 60 still")
	_assert(Midi.note_name_to_midi("G-") == -1, "dangling minus rejected")
	_assert(ClipTextKey.parse_pitch("G-1") == 19, "parse_pitch G-1")
	_assert(ClipTextKey.parse_pitch("E-2") == 4, "parse_pitch E-2")
	_assert(ClipTextKey.parse_pitch("A#-1") == 22, "parse_pitch A#-1")
	for m in [0, 4, 19, 22, 59, 60, 127]:
		_assert(Midi.note_name_to_midi(Midi.midi_to_note_name(m)) == m, "name round-trips for %d" % m)
	_assert(Midi.midi_to_note_name(19) == "G-1", "G-1 formats the same way")

	# Event add lines and a pitched grid lane.
	var clip := _clip()
	var r: Dictionary = _clip_text.apply(clip, null, "add 1.1.000 G-1 1/16 v100\nadd 1.2.000 E-2,A#-1 1/16", {"kind": "events", "ppq": 960})
	_assert(bool(r.get("ok", false)), "add lines with negative octaves: %s" % r)
	var pitches: Array = clip.midi_notes.map(func(n): return n.note)
	_assert(pitches == [19, 4, 22], "negative-octave pitches written: %s" % str(pitches))
	var grid := _clip()
	var gr: Dictionary = _clip_text.apply(grid, null, "G-1 |9 . . .|. . . .|. . . .|. . . .|", {"kind": "pitched", "ppq": 960})
	_assert(bool(gr.get("ok", false)) and grid.midi_notes.size() == 1 and grid.midi_notes[0].note == 19, "pitched lane G-1: %s" % gr)
	var ser: Dictionary = _clip_text.serialize(grid, {"kind": "pitched", "ppq": 960})
	var back := _clip()
	var br: Dictionary = _clip_text.apply(back, null, str(ser.text), {"kind": "pitched", "ppq": 960})
	_assert(bool(br.get("ok", false)) and back.midi_notes.size() == 1 and back.midi_notes[0].note == 19, "G-1 lane round-trips: %s" % br)
	# Drum grids label unnamed pitches by note name.
	var dclip := _clip()
	var dr: Dictionary = _clip_text.apply(dclip, null, "C-1 |9 . . .|. . . .|. . . .|. . . .|", {"kind": "drums", "ppq": 960})
	_assert(bool(dr.get("ok", false)) and dclip.midi_notes.size() == 1 and dclip.midi_notes[0].note == 12, "drum lane C-1: %s" % dr)


const KIT := {
	36: "Kick R", 37: "Kick L", 38: "Snare 1", 40: "Snare 2",
	42: "Hat Closed", 46: "Hat Open", 45: "Tom 1", 47: "Tom 2",
}


func _kit_opts() -> Dictionary:
	return {"kind": "drums", "ppq": 960, "drum_names": KIT.duplicate()}


func _test_multiword_drum_lanes() -> void:
	var clip := _clip()
	_add(clip, 1, 36, 0, 240, 100)
	_add(clip, 2, 37, 960, 240, 100)
	_add(clip, 3, 42, 0, 240, 100)
	_add(clip, 4, 46, 1920, 240, 100)
	_add(clip, 5, 38, 960, 240, 100)
	var ser: Dictionary = _clip_text.serialize(clip, _kit_opts())
	var text := str(ser.text)
	_assert(text.contains("Kick R") and text.contains("Kick L") and text.contains("Hat Open"), "multi-word names are emitted:\n%s" % text)
	var r: Dictionary = _clip_text.apply(clip, null, text, _kit_opts())
	_assert(bool(r.get("ok", false)), "read_clip output writes back: %s" % r)
	_assert((r.get("changes", []) as Array).is_empty(), "round-trip has zero changes: %s" % str(r.get("changes")))
	_assert(clip.midi_notes.size() == 5 and clip.content_length_ticks == 3840, "no phantom notes or bars (%d notes, %d ticks)" % [clip.midi_notes.size(), clip.content_length_ticks])

	# Case and spacing do not matter for the full-name match.
	var fresh := _clip()
	var w: Dictionary = _clip_text.apply(fresh, null, "kick   l |9 . . .|. . . .|. . . .|. . . .|\nHAT open |. . . .|9 . . .|. . . .|. . . .|", _kit_opts())
	_assert(bool(w.get("ok", false)), "sloppy case/space lanes parse: %s" % w)
	var by: Array = fresh.midi_notes.map(func(n): return n.note)
	by.sort()
	_assert(by == [37, 46], "Kick L -> 37, Hat Open -> 46, got %s" % str(by))
	# Single-token names and GM names still work.
	var single := _clip()
	var s: Dictionary = _clip_text.apply(single, null, "KICK |9 . . .|. . . .|. . . .|. . . .|", _kit_opts())
	_assert(bool(s.get("ok", false)) and single.midi_notes.size() == 1 and single.midi_notes[0].note == 36, "GM KICK still resolves: %s" % s)


func _test_duplicate_lanes() -> void:
	var clip := _clip()
	var text := "Kick R |9 . . .|. . . .|. . . .|. . . .|\nKick R |. . . .|9 . . .|. . . .|. . . .|"
	var r: Dictionary = _clip_text.apply(clip, null, text, _kit_opts())
	_assert(not bool(r.get("ok", false)), "same lane twice in one block is an error")
	_assert(clip.midi_notes.is_empty(), "nothing written on duplicate lanes")
	# Two different names that fold to one pitch name both lanes.
	var opts := {"kind": "drums", "ppq": 960, "drum_names": {36: "Kick"}}
	var r2: Dictionary = _clip_text.apply(_clip(), null, "Kick |9 . . .|. . . .|. . . .|. . . .|\nC1 |. . . .|9 . . .|. . . .|. . . .|", opts)
	var e := str(r2.get("error", ""))
	_assert(not bool(r2.get("ok", false)) and e.contains("`Kick`") and e.contains("`C1`"), "error names both lanes: %s" % e)
	# A continuation line (no label) is still fine, and a new bar block may repeat a lane.
	var multi := _clip(2)
	var m: Dictionary = _clip_text.apply(multi, null, "# bar 1\n          |1 e & a|2 e & a|3 e & a|4 e & a|\nKick R    |9 . . .|. . . .|. . . .|. . . .|\n# bar 2\n          |1 e & a|2 e & a|3 e & a|4 e & a|\nKick R    |9 . . .|. . . .|. . . .|. . . .|", _kit_opts())
	_assert(bool(m.get("ok", false)) and multi.midi_notes.size() == 2, "same lane in separate bar blocks is fine: %s" % m)


func _test_listing_lines() -> void:
	var clip := _clip()
	_add(clip, 81, 50, 0, 480, 100)
	var listing := "clip Test   type events   res 1/16   bars 1-1\n# header\nn81  1.1.000  D2  1/8  v100"
	var r: Dictionary = _clip_text.apply(clip, null, listing, {"kind": "events", "ppq": 960})
	var e := str(r.get("error", ""))
	_assert(not bool(r.get("ok", false)), "listing line is an error")
	_assert(e.contains("Line 3") and e.contains("listing") and e.contains("move n81") and e.contains("len n81") and e.contains("del n81") and e.contains("add 1.1.000 D2 1/8 v100"), "message explains conversion: %s" % e)
	_assert(clip.midi_notes.size() == 1 and clip.midi_notes[0].start_tick == 0, "nothing changed")
	# Zero-padded ids and mixing with ops: the whole write is refused before anything applies.
	var mixed: Dictionary = _clip_text.apply(clip, null, "add 1.2.000 C3 1/8\nn089  1.1.000  D2  1/8  v100", {"kind": "events", "ppq": 960})
	_assert(not bool(mixed.get("ok", false)) and str(mixed.get("error", "")).contains("Line 2"), "mixed ops + listing refused: %s" % mixed)
	_assert(clip.midi_notes.size() == 1, "ops before the listing line were not applied")
	# Under a drums/pitched kind hint a pasted listing still gets this message.
	var hinted: Dictionary = _clip_text.apply(clip, null, "n81  1.1.000  D2  1/8  v100", {"kind": "drums", "ppq": 960})
	_assert(str(hinted.get("error", "")).contains("listing line"), "kind hint does not hide it: %s" % hinted)
	# A header line alone with real ops is ignored.
	var ok: Dictionary = _clip_text.apply(clip, null, "clip Test   type events   res 1/16   bars 1-1\nmove n81 1.2.000", {"kind": "events", "ppq": 960})
	_assert(bool(ok.get("ok", false)) and clip.midi_notes[0].start_tick == 960, "clip header line ignored before ops: %s" % ok)
