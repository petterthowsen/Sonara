# test_score_text.gd
# Headless tests for the score text layer of the section tools (spec 025): bar plans, note value
# splitting, parsing (sticky values, ties, chords, keyswitches, errors), rendering (snap, voices,
# ties at barlines) and render → parse round trips.
# Run: godot --headless --path Godot -s ai/tests/test_score_text.gd -- --test
extends TestBase

var _st: GDScript

const D1 := 38
const A3 := 69


func suite_name() -> String:
	return "Score text tests"


func run_tests() -> void:
	_st = load("res://ai/clip_text/ScoreText.gd")
	_test_plan()
	_test_split_span()
	_test_parse_basic()
	_test_sticky_velocity()
	_test_bar_sum_error()
	_test_ties()
	_test_token_errors()
	_test_bar_count()
	_test_chords()
	_test_systems_continue()
	_test_voices()
	_test_snap_and_off_grid()
	_test_keyswitches()
	_test_drum_block()
	_test_header()
	_test_held_past_end()
	_test_round_trips()


func _plan(meters: Array, first_bar: int = 1) -> Array:
	return _st.make_plan(first_bar, meters, 960)


func _bars(sig: Array, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(sig)
	return out


func _parse(text: String, plan: Array, ctx: Dictionary = {}) -> Dictionary:
	return _st.parse(text, plan, ctx)


func _notes_of(res: Dictionary, index: int = 0) -> Array:
	if not res.get("ok", false):
		return []
	return res.lines[index].notes


func _test_plan() -> void:
	var plan := _plan([[4, 4], [7, 8]])
	_assert(plan.size() == 2 and plan[0].length == 3840 and plan[1].length == 3360, "4/4 + 7/8 bar lengths")
	_assert(plan[1].start == 3840 and plan[1].bar == 2, "second bar starts at 3840")
	_assert(_st.plan_length(plan) == 7200, "plan length")
	_assert(_st.bar_index_at(plan, 3839) == 0 and _st.bar_index_at(plan, 3840) == 1, "bar index at tick")


func _test_split_span() -> void:
	_assert(_st.split_span(0, 3840, 960) == PackedStringArray(["/1"]), "whole bar is /1")
	_assert(_st.split_span(240, 720, 960) == PackedStringArray(["/8."]), "dotted eighth from the 2nd 16th")
	_assert(_st.split_span(480, 960, 960) == PackedStringArray(["/4"]), "quarter on an off-beat eighth")
	_assert(_st.split_span(240, 1440, 960) != PackedStringArray(["/4."]), "no dotted quarter on an off-beat 16th")
	_assert(_st.split_span(0, 960, 960) == PackedStringArray(["/4"]), "quarter")
	_assert(_st.split_span(0, 320, 960) == PackedStringArray(["/8t"]), "triplet eighth")
	_assert(_st.split_span(0, 50, 960).is_empty(), "50 ticks can't be written")


func _test_parse_basic() -> void:
	var plan := _plan([[7, 8]])
	var res := _parse("Bass: D1/8 D1 F1 D1 G1 G#1 D1 |", plan)
	var notes := _notes_of(res)
	_assert(res.get("ok", false), "7/8 riff parses: %s" % res.get("error", ""))
	_assert(notes.size() == 7, "seven notes")
	if notes.size() == 7:
		_assert(notes[0].pitch == D1 and notes[0].start == 0 and notes[0].length == 480, "first note D1 at 0, 1/8")
		_assert(notes[6].start == 2880, "seventh note on the 7th eighth")
		_assert(notes[4].velocity == 100, "default velocity 100")
	var no_bar := _parse("Bass: D1/8 D1 F1 D1 G1 G#1 D1", plan)
	_assert(no_bar.get("ok", false), "missing final barline is closed implicitly")
	var flats := _parse("Bass: Bb1/4 Eb2/4 r/4. |", plan)
	_assert(flats.get("ok", false) and _notes_of(flats)[0].pitch == 46, "flats parse (Bb1 = 46)")
	var neg := _parse("Bass: G-1/4 C-2/4 r/4. |", plan)
	_assert(neg.get("ok", false) and _notes_of(neg)[0].pitch == 19 and _notes_of(neg)[1].pitch == 0, "negative octaves")


func _test_sticky_velocity() -> void:
	var res := _parse("Bass: D1/8@80 D1 D1@90 D1 r/4. |", _plan([[7, 8]]))
	var notes := _notes_of(res)
	_assert(notes.size() == 4, "four notes")
	if notes.size() == 4:
		_assert(notes[0].velocity == 80 and notes[1].velocity == 80, "velocity carries forward")
		_assert(notes[2].velocity == 90 and notes[3].velocity == 90, "velocity change carries forward")
	var bad := _parse("Bass: D1/8@200 r/4. r/4 r/8 |", _plan([[7, 8]]))
	_assert(not bad.get("ok", true) and str(bad.error).contains("1-127"), "velocity out of range")


func _test_bar_sum_error() -> void:
	var res := _parse("Bass: D1/4 D1 D1 D1 |", _plan([[7, 8]]))
	_assert(not res.get("ok", true), "4 quarters in 7/8 refused")
	_assert(str(res.get("error", "")) == "Bass bar 1 adds up to 8/8 (3840 ticks); a 7/8 bar is 3360 ticks", "bar sum message: %s" % res.get("error", ""))
	var short := _parse("Bass: D1/4 D1 | D1/1 |", _plan([[4, 4], [4, 4]], 5))
	_assert(str(short.get("error", "")).begins_with("Bass bar 5 adds up to 2/4"), "short bar names the song bar: %s" % short.get("error", ""))


func _test_ties() -> void:
	var plan := _plan(_bars([4, 4], 2))
	var res := _parse("Lead: A3/2 r/4 A3/4~ | A3/2 r/2 |", plan)
	var notes := _notes_of(res)
	_assert(notes.size() == 2, "tie joins into one note: %s" % res.get("error", ""))
	if notes.size() == 2:
		_assert(notes[1].start == 2880 and notes[1].length == 2880, "tied note crosses the barline (960 + 1920)")
	var bad := _parse("Lead: A3/2 r/4 A3/4~ | B3/2 r/2 |", plan)
	_assert(not bad.get("ok", true) and str(bad.error).contains("bar 2") and str(bad.error).contains("tie"), "tie to a different pitch refused: %s" % bad.get("error", ""))
	var rest_after := _parse("Lead: A3/2~ r/2 | r/1 |", plan)
	_assert(not rest_after.get("ok", true), "rest after a tie refused")
	var chord_tie := _parse("Pad: [C3 E3]/1~ | [E3 C3]/1 |", plan)
	_assert(chord_tie.get("ok", false) and _notes_of(chord_tie).size() == 2 and _notes_of(chord_tie)[0].length == 7680, "chord tie (any pitch order)")


func _test_token_errors() -> void:
	var plan := _plan([[7, 8]])
	var res := _parse("Bass: D1/8 X9/8 D1 D1 D1 D1 D1 |", plan)
	var err := str(res.get("error", ""))
	_assert(err.contains("Bass bar 1") and err.contains("X9/8") and err.contains("<pitch>/<value>"), "bad token names track, bar, token, form: %s" % err)
	var amb := _parse("Bass: D13/8 r/4. r/4 r/8 |", plan)
	_assert(str(amb.get("error", "")).contains("out of range") and str(amb.error).contains("<pitch>/<value>"), "D13/8 refused with the form: %s" % amb.get("error", ""))
	var first := _parse("Bass: D1 D1/8 |", plan)
	_assert(str(first.get("error", "")).contains("needs a value"), "first token without a value: %s" % first.get("error", ""))
	var triplet3 := _parse("Bass: D1/3 r/2 |", plan)
	_assert(not triplet3.get("ok", true) and str(triplet3.error).contains("bad value"), "/3 is not a note value")
	var no_label := _parse("D1/8 D1 |", plan)
	_assert(not no_label.get("ok", true) and str(no_label.error).contains("Track: notes"), "line without a label")


func _test_bar_count() -> void:
	var plan := _plan(_bars([4, 4], 2))
	var few := _parse("Bass: C1/1 |", plan)
	_assert(str(few.get("error", "")) == "Bass has 1 bars; the section has 2 (bars 1-2)", "too few bars: %s" % few.get("error", ""))
	var many := _parse("Bass: C1/1 | C1/1 | C1/1 |", plan)
	_assert(str(many.get("error", "")).contains("more bars than the section"), "too many bars: %s" % many.get("error", ""))


func _test_chords() -> void:
	var res := _parse("Gtr: [D2 A2]/8 [F2 C3] r/4. r/4 |", _plan([[7, 8]]))
	var notes := _notes_of(res)
	_assert(notes.size() == 4, "two chords of two: %s" % res.get("error", ""))
	if notes.size() == 4:
		_assert(notes[0].start == 0 and notes[1].start == 0 and notes[2].start == 480, "chord onsets")


func _test_systems_continue() -> void:
	var res := _parse("# bar 1\nBass: C1/1 |\n\n# bar 2\nBass: C1 |", _plan(_bars([4, 4], 2)))
	var notes := _notes_of(res)
	_assert(res.get("ok", false) and res.lines.size() == 1 and notes.size() == 2, "a label continues across systems (and keeps its value)")
	if notes.size() == 2:
		_assert(notes[1].start == 3840 and notes[1].length == 3840, "continued note in bar 2")
	var two := _parse("Piano.1: E3/4 F3 G3 A3 |\nPiano.2: C3/1 |", _plan([[4, 4]]))
	_assert(two.get("ok", false) and two.lines.size() == 2 and two.lines[1].label == "Piano.2", "voice labels are separate lines")


func _test_voices() -> void:
	var notes := [
		{"pitch": 60, "start": 0, "length": 3840, "velocity": 100},
		{"pitch": 64, "start": 0, "length": 960, "velocity": 100},
		{"pitch": 65, "start": 960, "length": 960, "velocity": 100},
		{"pitch": 67, "start": 1920, "length": 960, "velocity": 100},
		{"pitch": 69, "start": 2880, "length": 960, "velocity": 100},
	]
	var r: Dictionary = _st.render_track(notes, [], _plan([[4, 4]]), {"ppq": 960})
	_assert(not r.off_grid and r.voices.size() == 2, "sustained note under a moving line gives two voices")
	if r.voices.size() == 2:
		_assert(r.voices[0][0] == PackedStringArray(["E3/4", "F3", "G3", "A3"]), "voice 1 is the moving line: %s" % [r.voices[0][0]])
		_assert(r.voices[1][0] == PackedStringArray(["C3/1"]), "voice 2 is the whole note: %s" % [r.voices[1][0]])
	var chord := [
		{"pitch": 60, "start": 0, "length": 1920, "velocity": 90},
		{"pitch": 64, "start": 0, "length": 1920, "velocity": 90},
		{"pitch": 67, "start": 0, "length": 1920, "velocity": 90},
	]
	var rc: Dictionary = _st.render_track(chord, [], _plan([[4, 4]]), {"ppq": 960})
	_assert(rc.voices.size() == 1 and rc.voices[0][0] == PackedStringArray(["[C3 E3 G3]/2@90", "r"]), "chord token: %s" % [rc.voices[0][0] if rc.voices.size() > 0 else ""])


func _test_snap_and_off_grid() -> void:
	var plan := _plan([[4, 4]])
	var late := [{"pitch": 60, "start": 8, "length": 952, "velocity": 100}]
	var r: Dictionary = _st.render_track(late, [], plan, {"ppq": 960})
	_assert(not r.off_grid and r.voices[0][0][0] == "C3/4", "8 ticks late snaps")
	var off := [{"pitch": 60, "start": 30, "length": 930, "velocity": 100}]
	var r2: Dictionary = _st.render_track(off, [], plan, {"ppq": 960})
	_assert(r2.off_grid, "30 ticks off is off-grid")
	var sn: Vector2i = _st.snap_note(8, 952, 960, 3840)
	_assert(sn == Vector2i(0, 960), "snap_note rounds start and end")
	_assert(_st.snap_note(3000, 2000, 960, 3840) == Vector2i(3000, 840), "snap_note cuts at the section end")


func _test_keyswitches() -> void:
	var plan := _plan([[7, 8]])
	var maps := {"gtr": {"sus alt": {"key": 19, "name": "Sus_Alt"}, "mute down": {"key": 20, "name": "Mute_Down"}}}
	var res := _parse("Gtr: ks:sus alt D2/8 D2 r/4. r/4 |", plan, {"keyswitch_maps": maps})
	_assert(res.get("ok", false), "unquoted multi-word keyswitch: %s" % res.get("error", ""))
	if res.get("ok", false):
		var ks: Array = res.lines[0].keyswitches
		_assert(ks.size() == 1 and ks[0].key == 19 and ks[0].at == 0, "keyswitch resolves to its key, at the next note")
		_assert(res.lines[0].notes.size() == 2, "keyswitch takes no time and isn't a note")
	var later := _parse("Gtr: D2/8 r/8 ks:\"Mute Down\" D2/8 r/4 r/4 |", plan, {"keyswitch_maps": maps})
	_assert(later.get("ok", false) and later.lines[0].keyswitches[0].at == 960 and later.lines[0].keyswitches[0].key == 20, "quoted keyswitch mid-bar")
	var bad := _parse("Gtr: ks:Palm D2/8 r/4. r/4 r/8 |", plan, {"keyswitch_maps": maps})
	_assert(str(bad.get("error", "")).contains("unknown keyswitch `Palm`") and str(bad.error).contains("Sus_Alt"), "unknown keyswitch lists names: %s" % bad.get("error", ""))
	var dangling := _parse("Gtr: D2/8 r/4. r/4 r/8 ks:Sus_Alt |", plan, {"keyswitch_maps": maps})
	_assert(str(dangling.get("error", "")).contains("no note after it"), "keyswitch with no note after it")
	var unmapped := _parse("Bass: ks:Whatever D1/8 r/4. r/4 r/8 |", plan, {"keyswitch_maps": maps})
	_assert(unmapped.get("ok", false) and unmapped.lines[0].keyswitches[0].key == -1, "no map for the line leaves the key unresolved")
	var notes := [{"pitch": 50, "start": 0, "length": 480, "velocity": 100}]
	var r: Dictionary = _st.render_track(notes, [{"name": "Sus_Alt", "at": -60}], plan, {"ppq": 960})
	_assert(r.voices[0][0][0] == "ks:Sus_Alt" and r.voices[0][0][1] == "D2/8", "keyswitch rendered before its note: %s" % [r.voices[0][0]])
	var spaced: Dictionary = _st.render_track(notes, [{"name": "Mute Down", "at": 0}], plan, {"ppq": 960})
	_assert(spaced.voices[0][0][0] == "ks:\"Mute Down\"", "names with spaces are quoted")


func _test_drum_block() -> void:
	var text := "Bass: D1/8 r/4. r/4 r/8 |\nDrums:\n  |1 . 2 .|\n  KICK |9 . . .|\n\n  # bar 2\nLead: r/8 r/4. r/4 r/8 |"
	var res := _parse(text, _plan([[7, 8]]))
	_assert(res.get("ok", false) and res.lines.size() == 3, "drum block between note lines: %s" % res.get("error", ""))
	if res.lines.size() == 3:
		_assert(res.lines[1].kind == "grid" and str(res.lines[1].text).contains("KICK |9") and str(res.lines[1].text).contains("# bar 2"), "grid text captured")
		_assert(res.lines[2].label == "Lead" and res.lines[2].kind == "notes", "capture ends at the next label")
	_assert(_st.labels(text) == PackedStringArray(["Bass", "Drums", "Lead"]), "labels in order")


func _test_header() -> void:
	var h: Dictionary = _st.parse_header("section bars 5-8   7/8   tempo 105\nBass: …")
	_assert(h.get("first", 0) == 5 and h.get("last", 0) == 8, "header bars")
	var plan := _plan([[4, 4], [4, 4], [7, 8]], 5)
	var text: String = _st.header(plan, {"tempo": 105.0, "key_label": "Dmin"})
	_assert(text == "section bars 5-7   4/4 (bars 5-6), 7/8 (bar 7)   tempo 105   key Dmin", "mixed-meter header: %s" % text)


func _test_held_past_end() -> void:
	var plan := _plan(_bars([4, 4], 2))
	var notes := [{"pitch": A3, "start": 6720, "length": 1920, "velocity": 100}]
	var r: Dictionary = _st.render_track(notes, [], plan, {"ppq": 960})
	_assert(r.voices[0][1][r.voices[0][1].size() - 1] == "A3/4~", "a note running past the section ends with ~: %s" % [r.voices[0][1]])
	var text: String = _st.layout([{"label": "Lead", "bars": r.voices[0]}], plan)
	var back := _parse(text, plan)
	var bn := _notes_of(back)
	_assert(bn.size() == 1 and bn[0].get("held", false) and bn[0].length == 960, "trailing tie parses as held: %s" % back.get("error", ""))


## Render → layout → parse gives back the same notes (start, length, pitch, velocity).
func _test_round_trips() -> void:
	var cases := [
		["7/8 riff", [[7, 8], [7, 8]], [[38, 0, 480, 100], [38, 480, 480, 90], [41, 960, 480, 100], [43, 1440, 960, 100], [38, 2400, 480, 80], [38, 3360, 1440, 100], [41, 5280, 480, 100]]],
		["mixed meter tie", [[4, 4], [7, 8]], [[60, 0, 960, 100], [62, 2880, 1920, 100], [64, 5760, 480, 70]]],
		["triplets", [[4, 4]], [[60, 0, 320, 100], [62, 320, 320, 100], [64, 640, 320, 100], [65, 960, 2880, 100]]],
		["syncopation", [[4, 4], [4, 4]], [[48, 0, 480, 100], [48, 480, 960, 100], [48, 1440, 480, 100], [48, 1920, 1920, 110], [55, 3840, 3840, 100]]],
		["chord and line", [[4, 4]], [[60, 0, 1920, 100], [64, 0, 1920, 100], [67, 0, 1920, 100], [72, 1920, 480, 100], [74, 2400, 1440, 100]]],
	]
	for c in cases:
		var plan := _plan(c[1])
		var notes: Array = []
		for n in c[2]:
			notes.append({"pitch": n[0], "start": n[1], "length": n[2], "velocity": n[3]})
		var r: Dictionary = _st.render_track(notes, [], plan, {"ppq": 960})
		if r.off_grid:
			_assert(false, "%s: rendered off-grid" % c[0])
			continue
		var rows: Array = []
		for vi in r.voices.size():
			rows.append({"label": "T" if r.voices.size() == 1 else "T.%d" % (vi + 1), "bars": r.voices[vi]})
		var text: String = _st.layout(rows, plan, {"ppq": 960})
		var back := _parse(text, plan)
		if not back.get("ok", false):
			_assert(false, "%s: parse failed: %s\n%s" % [c[0], back.get("error", ""), text])
			continue
		var got: Array = []
		for line in back.lines:
			for n in line.notes:
				got.append([n.pitch, n.start, n.length, n.velocity])
		var want: Array = []
		for n in c[2]:
			want.append(n)
		got.sort()
		want.sort()
		_assert(got == want, "%s round-trips:\n%s" % [c[0], text])
