# test_clip_text.gd
# Headless tests for clip text time, grids, events, and round-trip apply.
# Run: godot --headless --path Godot -s ai/tests/test_clip_text.gd -- --test
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


# Loaded in run_tests(): these reach Project.gd (AudioEngineOSC), which doesn't resolve at -s parse time.
var _clip_text: GDScript
var _clip_text_time: GDScript
var _grid_helper: GDScript


func suite_name() -> String:
	return "Clip text format tests"


func run_tests() -> void:
	_clip_text = load("res://ai/clip_text/ClipText.gd")
	_clip_text_time = load("res://ai/clip_text/ClipTextTime.gd")
	_grid_helper = load("res://components/GridHelper.gd")
	_test_time()
	_test_key_and_tiers()
	_test_drum_grid_roundtrip()
	_test_grid_diff_preserves_velocity()
	_test_pitched_grid()
	_test_event_ops()
	_test_header_parse()
	_test_format_selection()
	_test_sloppy_model_text()


func _clip(name: String = "Test", bars: int = 1) -> StubClip:
	var c := StubClip.new()
	c.name = name
	c.content_length_ticks = bars * 960 * 4
	return c


func _add(clip: StubClip, id: int, pitch: int, start: int, dur: int, vel: int) -> void:
	var n := MidiNoteData.new()
	n.id = id
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	n.velocity = vel
	clip.midi_notes.append(n)


func _test_time() -> void:
	_assert(_clip_text_time.parse_res("1/16") == 16, "parse res 1/16")
	_assert(_clip_text_time.ticks_per_step(960, 16) == 240, "16th = 240 ticks")
	_assert(_clip_text_time.parse_bbt("5.1.000", 960, 4) == 4 * 3840, "bar 5 start")
	_assert(_clip_text_time.format_bbt(0, 960, 4) == "1.1.000", "tick 0 is 1.1.000")
	_assert(_clip_text_time.ticks_per_bar(960, 6, 8) == 2880, "6/8 bar = six eighths")
	_assert(_clip_text_time.format_bbt(2880 + 480, 960, 6, 8) == "2.2.000", "6/8 bar 2 beat 2")
	_assert(_clip_text_time.parse_bbt("2.2.000", 960, 6, 8) == 3360, "6/8 parse bar 2 beat 2")
	_assert(_grid_helper.bbt_of(3840 + 960 + 240 + 5, 960, 4, 4) == {"bar": 2, "beat": 2, "sixteenth": 2, "tick": 5}, "4/4 bbt")
	_assert(_clip_text_time.parse_duration("1/4", 960) == 960, "quarter = ppq")
	_assert(_clip_text_time.parse_duration("1/4.", 960) == 1440, "dotted quarter")
	_assert(_clip_text_time.parse_duration("1/4t", 960) == 640, "triplet quarter")
	_assert(_clip_text_time.format_duration(960, 960) == "1/4", "format quarter")
	_assert(_clip_text_time.parse_signed_delta("+1/16", 960) == 240, "+16th")
	_assert(_clip_text_time.parse_bars("5-8").bars == 4, "bars 5-8 is 4")
	_assert(_clip_text_time.step_offset(240, 240) == 0, "on-grid offset 0")
	_assert(absi(_clip_text_time.step_offset(250, 240)) == 10, "10-tick offset")


func _test_key_and_tiers() -> void:
	_assert(ClipTextKey.tier_to_velocity(9) == 121, "tier 9")
	_assert(ClipTextKey.velocity_to_tier(100) == 7, "100 → nearest tier 7")
	_assert(ClipTextKey.parse_pitch("C3") == 60, "C3 = 60")
	_assert(ClipTextKey.parse_pitch("Bb3") == 70, "Bb3")
	_assert(ClipTextKey.parse_pitch("KICK") == 36, "KICK = 36")
	_assert(ClipTextKey.guess_drum_note("kick_kick_drum_01") == 36, "guess kick file")
	_assert(ClipTextKey.guess_drum_note("snare_hit_01") == 38, "guess snare file")
	_assert(ClipTextKey.guess_drum_note("hi_hat_closed_hi_hat_01") == 42, "guess closed hat")
	_assert(ClipTextKey.guess_drum_note("HiHat Open") == 46, "guess open hat")
	_assert(ClipTextKey.guess_drum_note("crash_cymbal_crash_01") == 49, "guess crash")
	_assert(ClipTextKey.guess_drum_note("ride_cymbal_ride_cymbal_hit_01") == 51, "guess ride")
	_assert(ClipTextKey.guess_drum_note("polysynth") == -1, "guess unknown")
	var key: Dictionary = ClipTextKey.parse_key("Cmin")
	_assert(not key.is_empty() and int(key.root) == 0, "Cmin root C")
	_assert(ClipTextKey.degree_label(60, key) == "1", "C is 1 in Cmin")
	_assert(ClipTextKey.degree_label(70, key) == "b7", "Bb is b7 in Cmin")
	_assert(ClipTextKey.parse_pitch("b7", key, 3) == 70, "degree b7 → Bb3")


func _test_drum_grid_roundtrip() -> void:
	var clip := _clip("KickLoop", 1)
	_add(clip, 1, 36, 0, 240, 121)
	_add(clip, 2, 38, 960, 240, 108)
	var ser: Dictionary = _clip_text.serialize(clip, {"kind": "drums", "ppq": 960, "numerator": 4, "tempo": 96})
	_assert(bool(ser.get("ok", false)), "serialize drums ok")
	_assert(str(ser.get("text", "")).contains("KICK"), "emits KICK lane")
	_assert(str(ser.get("text", "")).contains("SNARE"), "emits SNARE lane")
	var applied: Dictionary = _clip_text.apply(clip, null, str(ser.get("text", "")), {"kind": "drums", "ppq": 960})
	_assert(bool(applied.get("ok", false)), "unmodified write ok")
	_assert((applied.get("changes", []) as Array).is_empty(), "read → write is a no-op")
	_assert(clip.midi_notes.size() == 2, "still two notes")
	_assert(clip.midi_notes[0].velocity == 121, "velocity preserved")


func _test_grid_diff_preserves_velocity() -> void:
	var clip := _clip("Hats", 1)
	_add(clip, 1, 42, 0, 240, 100)
	var ser: Dictionary = _clip_text.serialize(clip, {"kind": "drums", "ppq": 960})
	var applied: Dictionary = _clip_text.apply(clip, null, str(ser.get("text", "")), {"kind": "drums", "ppq": 960})
	_assert(bool(applied.get("ok", false)) and (applied.get("changes", []) as Array).is_empty(), "off-curve vel kept on no-op")
	_assert(clip.midi_notes[0].velocity == 100, "velocity still 100")
	var empty := _clip("Hats2", 1)
	var grid := """clip Hats2   type drums   res 1/16   bars 1-1
        |1 e & a|2 e & a|3 e & a|4 e & a|
HAT     |3 . . .|. . . .|. . . .|. . . .|
"""
	var add_r: Dictionary = _clip_text.apply(empty, null, grid, {"kind": "drums", "ppq": 960})
	_assert(bool(add_r.get("ok", false)), "new hat ok")
	_assert(empty.midi_notes.size() == 1, "one hat added")
	_assert(empty.midi_notes[0].note == 42, "hat pitch")
	_assert(empty.midi_notes[0].velocity == ClipTextKey.tier_to_velocity(3), "new note uses tier curve")


func _test_pitched_grid() -> void:
	var clip := _clip("Bass", 1)
	_add(clip, 1, 36, 0, 960, 121)
	var ser: Dictionary = _clip_text.serialize(clip, {"kind": "pitched", "ppq": 960, "key": "Cmin"})
	_assert(bool(ser.get("ok", false)), "serialize pitched")
	_assert(str(ser.get("text", "")).contains("C1"), "pitch name present")
	_assert(str(ser.get("text", "")).contains("-"), "quarter note uses holds")
	var applied: Dictionary = _clip_text.apply(clip, null, str(ser.get("text", "")), {"kind": "pitched", "ppq": 960, "key": "Cmin"})
	_assert(bool(applied.get("ok", false)) and (applied.get("changes", []) as Array).is_empty(), "pitched no-op")


func _test_event_ops() -> void:
	var clip := _clip("Wide", 2)
	_add(clip, 7, 36, 0, 960, 104)
	var r: Dictionary = _clip_text.apply(clip, null, "vel n7 88\nmove n7 +1/16\nlen n7 1/8", {"kind": "events", "ppq": 960})
	_assert(bool(r.get("ok", false)), "ops apply")
	_assert(clip.midi_notes[0].velocity == 88, "vel op")
	_assert(clip.midi_notes[0].start_tick == 240, "move +1/16")
	_assert(clip.midi_notes[0].duration_ticks == 480, "len 1/8")
	var del: Dictionary = _clip_text.apply(clip, null, "del n7", {"kind": "events", "ppq": 960})
	_assert(bool(del.get("ok", false)) and clip.midi_notes.is_empty(), "del n7")
	var add: Dictionary = _clip_text.apply(clip, null, "add 1.1.000 C2 1/4 v104", {"kind": "events", "ppq": 960})
	_assert(bool(add.get("ok", false)) and clip.midi_notes.size() == 1, "add note")
	_assert(clip.midi_notes[0].note == 48, "C2 = 48")


func _test_header_parse() -> void:
	var h: Dictionary = _clip_text.parse_header("clip Kick Loop   type drums   res 1/16   bars 5-8   key Cmin   tempo 96")
	_assert(str(h.get("name", "")) == "Kick Loop", "header name with space")
	_assert(str(h.get("kind", "")) == "drums", "header type")
	_assert(int(h.get("res_denom", 0)) == 16, "header res")
	_assert(int(h.get("bars", 0)) == 4, "bars 5-8 → 4")
	var bad: Dictionary = _clip_text.parse_header("clip X   type harmonic   res 1/16   bars 1-1")
	_assert(bad.has("error"), "harmonic rejected")


func _test_format_selection() -> void:
	var wide := _clip("Span", 1)
	_add(wide, 1, 36, 0, 240, 100)
	_add(wide, 2, 72, 240, 240, 100)
	var ser: Dictionary = _clip_text.serialize(wide, {"ppq": 960})
	_assert(str(ser.get("kind", "")) == "events", "wide span → events")
	_assert(str(ser.get("text", "")).contains("serving event list"), "fallback reason")
	var rewrite: Dictionary = _clip_text.apply(wide, null, str(ser.get("text", "")), {"ppq": 960})
	_assert(not bool(rewrite.get("ok", false)), "full event list rewrite refused")


func _test_sloppy_model_text() -> void:
	_assert(_clip_text_time.parse_bars("1/16").is_empty(), "1/16 is res, not bars")
	var h: Dictionary = _clip_text.parse_header("clip \"Trance Kick\" drums 2 bars 1/16")
	_assert(str(h.get("name", "")) == "Trance Kick", "quoted name")
	_assert(str(h.get("kind", "")) == "drums", "bare drums type")
	_assert(int(h.get("bars", 0)) == 2, "bare 2 is bar count")
	_assert(int(h.get("res_denom", 0)) == 16, "1/16 after bars is res")
	var xox := _clip("Trance Kick", 2)
	var junk: Dictionary = _clip_text.apply(xox, null,
		"clip \"Trance Kick\" drums 2 bars 1/16\nC1  |k---k---k---k---|k---k---k---k---|",
		{"kind": "drums", "ppq": 960})
	_assert(not bool(junk.get("ok", false)), "k--- is an error, not a silent no-op")
	_assert(str(junk.get("error", "")).contains("Unknown hit"), "error names the bad hit")
	_assert(xox.midi_notes.is_empty(), "junk write leaves notes empty")
	_assert(xox.content_length_ticks == 7680, "1/16 does not grow the clip")
	var xs := _clip("Trance Kick", 2)
	var written: Dictionary = _clip_text.apply(xs, null,
		"clip Trance Kick   type drums   res 1/16   bars 1-2\nSampler  |x . . .|x . . .|x . . .|x . . .|",
		{"kind": "drums", "ppq": 960, "drum_names": {36: "KICK", 38: "SNARE", 42: "HAT"}})
	_assert(bool(written.get("ok", false)), "x hits apply")
	_assert(xs.midi_notes.size() == 4, "four x hits")
	_assert(xs.midi_notes[0].note == 36, "Sampler falls back to first pad / C1")
	var huge := _clip("Empty", 116)
	var ser: Dictionary = _clip_text.serialize(huge, {"kind": "drums", "ppq": 960})
	_assert(str(ser.get("text", "")).contains("empty bars, showing first"), "empty dump is capped")
	_assert(not str(ser.get("text", "")).contains("# bar 9"), "does not emit 116 empty bars")
	var cont := _clip("trance_kick", 2)
	var cont_r: Dictionary = _clip_text.apply(cont, null,
		"C1 |9 . . .|9 . . .|9 . . .|9 . . .|\n   |9 . . .|9 . . .|9 . . .|9 . . .|",
		{"kind": "drums", "ppq": 960})
	_assert(bool(cont_r.get("ok", false)), "unlabeled second line continues C1")
	_assert(cont.midi_notes.size() == 8, "two bars of quarter-note kicks")
	_assert(cont.midi_notes[0].note == 36, "continuation stays on C1")
	var orphan: Dictionary = _clip_text.apply(_clip("x", 1), null, "   |9 . . .|9 . . .|9 . . .|9 . . .|", {"kind": "drums", "ppq": 960})
	_assert(not bool(orphan.get("ok", false)), "unlabeled first line is an error")
