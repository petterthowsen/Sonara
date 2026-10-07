# test_section_tools.gd
# Headless tests for the section tools (spec 025): ScoreSection (bar plan, gather, diff write,
# clip ownership, shared clips, drum blocks, keyswitches) and read_section / write_section.
# Scripts are load()ed inside run_tests() for the same autoload reason as test_clip_range_tools.gd.
# Run: godot --headless --path Godot -s ai/tests/test_section_tools.gd -- --test
extends TestBase

const SFZ_ID := "sonara.builtin.sfizz"
const DRUM_ID := "sonara.builtin.drum_machine"
const NO_RANGE := {"has": false, "start": 0, "has_end": false, "end": 0}

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _section: GDScript
var _read_tool: GDScript
var _write_tool: GDScript
var _registry_script: GDScript
var _marker_script: GDScript
var _clip_actions: GDScript
var _history_util: GDScript
var _recorded: Array = []


func suite_name() -> String:
	return "Section tool tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_section = load("res://ai/clip_text/ScoreSection.gd")
	_read_tool = load("res://ai/tools/ReadSectionTool.gd")
	_write_tool = load("res://ai/tools/WriteSectionTool.gd")
	_registry_script = load("res://ai/tools/ToolRegistry.gd")
	_marker_script = load("res://data/SongMarker.gd")
	_clip_actions = load("res://history/ClipActions.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	# T-005
	_test_bar_plan_mixed_meter()
	_test_gather_trimmed_and_transposed()
	_test_gather_flags_loops()
	# T-006
	_test_write_leaves_other_bars()
	_test_read_write_unchanged_is_noop()
	_test_section_edges_snap()
	_test_clip_creation_and_naming()
	_test_playable_range_warning()
	_test_note_runs_past_clip()
	_test_transpose_and_offset_write()
	# T-007
	_test_shared_clips()
	# T-008
	_test_drum_roundtrip()
	_test_drum_pad_names()
	_test_drum_meter_change_refused()
	# T-009
	_test_keyswitch_placement()
	# T-010
	_test_read_section_basics()
	_test_read_section_voices_and_chords()
	_test_read_section_keyswitch()
	_test_read_section_off_grid()
	_test_read_section_cap()
	_test_registered()
	# T-011
	_test_write_section_one_undo()
	_test_write_section_errors()
	_test_write_section_rollback()
	_test_write_section_header_mismatch()
	# T-012
	_test_prompt_example()
	_test_performance()


# --- Setup helpers ----------------------------------------------------------------------------

func _setup(track_names: Array = ["Bass"]) -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	editor.test_time_range_override = NO_RANGE
	editor.playhead_ticks = 0
	_sonara.editor = editor
	var s := {"project": project, "editor": editor}
	for n in track_names:
		s[n] = project.create_instrument_track(n).track
	return s


func _bar(project: Object, n: int = 1) -> int:
	return (n - 1) * 3840


## A clip placed on `track` with notes [[pitch, start, length, vel7]...] (clip-local ticks).
func _clip(project: Object, track: Object, clip_name: String, start: int, length: int, notes: Array = []) -> Object:
	var inst: Object = _clip_actions.create_clip(project, track, start, length, clip_name)
	for n in notes:
		inst.clip.add_midi_note(inst.clip.allocate_note_id(), n[0], MidiNoteData.from_midi_velocity(n[3] if n.size() > 3 else 100), n[1], n[2])
	return inst


## [[pitch, song start, length, vel7]...] of every note on a track, sorted.
func _song_notes(track: Object) -> Array:
	var out: Array = []
	for inst in track.clip_instances:
		for n in inst.clip.midi_notes:
			out.append([n.note + inst.transpose, inst.clip_to_song_ticks(n.start_tick), n.duration_ticks, MidiNoteData.to_midi_velocity(n.velocity)])
	out.sort_custom(func(a, b): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
	return out


func _device(ch: Object, device_id: String, title: String, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## Give `track` an SFZ sampler with key info set directly: switches [[key, label]...], ranges [[lo, hi]...].
func _sfz(track: Object, switches: Array, ranges: Array = []) -> Object:
	var ch: Object = track.get_linked_channel()
	var sfz := _device(ch, SFZ_ID, "SFZ")
	ch.add_device(sfz)
	for sw in switches:
		sfz.key_labels.append({"key": sw[0], "keyswitch": true, "label": sw[1]})
	sfz.playable_ranges = ranges
	sfz.key_info_received = true
	return sfz


func _write(args: Dictionary) -> Dictionary:
	return _write_tool.new().execute(args)


func _read(args: Dictionary) -> Dictionary:
	return _read_tool.new().execute(args)


func _record_start() -> void:
	_recorded = []
	_history_util.set("test_recorder", func(cmd): _recorded.append(cmd))


func _record_stop() -> void:
	_history_util.set("test_recorder", Callable())


const G_NEG1 := 19  # G-1
const D2 := 50
const F_SHARP_0 := 30


# --- T-005 ------------------------------------------------------------------------------------

func _test_bar_plan_mixed_meter() -> void:
	var s := _setup()
	var p: Object = s.project
	p.time_signature_map.add_change(2, 7, 8)
	var span: Dictionary = _section.bar_plan(p, 1, 3)
	var lens: Array = span.plan.map(func(b): return b.length)
	_assert(lens == [3840, 3360, 3360], "4/4 then 7/8 from bar 2: bar lengths %s" % [lens])
	_assert(span.start == 0 and span.end == 3840 + 6720, "span 0-%d" % span.end)
	var from2: Dictionary = _section.bar_plan(p, 2, 2)
	_assert(from2.start == 3840 and from2.plan[0].length == 3360 and from2.plan[0].numerator == 7, "bar 2 alone is 7/8, 3360 ticks, starts at 3840")
	var from3: Dictionary = _section.bar_plan(p, 3, 3)
	_assert(from3.start == 3840 + 3360, "bar 3 starts after one 7/8 bar (%d)" % from3.start)


func _test_gather_trimmed_and_transposed() -> void:
	var s := _setup()
	var p: Object = s.project
	# A 2-bar clip: C3 at bar 1, D3 at bar 2. Placed at song bar 3 showing only its second bar, up an octave.
	var inst: Object = _clip(p, s.Bass, "Riff", 2 * 3840, 3840, [])
	inst.clip.content_length_ticks = 7680
	inst.clip.add_midi_note(inst.clip.allocate_note_id(), 60, 0.8, 0, 480)
	inst.clip.add_midi_note(inst.clip.allocate_note_id(), 62, 0.8, 3840 + 480, 960)
	inst.clip_offset = 3840
	inst.transpose = 12
	var g: Dictionary = _section.gather(p, s.Bass, 2 * 3840, 3 * 3840)
	_assert(g.notes.size() == 1, "the trimmed-away note is not gathered (%d notes)" % g.notes.size())
	var n: Dictionary = g.notes[0]
	_assert(n.pitch == 74 and n.start == 480 and n.length == 960, "D3 + 12 at section tick 480: %s" % [[n.pitch, n.start, n.length]])
	_assert(n.note_ref == inst.clip.midi_notes[1] and n.clip == inst.clip and n.instance == inst, "record carries note_ref, clip and instance")
	var none: Dictionary = _section.gather(p, s.Bass, 0, 3840)
	_assert(none.notes.is_empty(), "bar 1 has no placement")


func _test_gather_flags_loops() -> void:
	var s := _setup()
	var p: Object = s.project
	var inst: Object = _clip(p, s.Bass, "Loop", 0, 4 * 3840, [[60, 0, 480]])
	inst.clip.content_length_ticks = 3840
	inst.set_loop(true, 0, 3840)
	var g: Dictionary = _section.gather(p, s.Bass, 0, 2 * 3840)
	_assert(g.loops == [inst], "a loop that repeats inside the span is flagged")
	var plain := _setup()
	var single: Object = _clip(plain.project, plain.Bass, "Plain", 0, 3840, [[60, 0, 480]])
	_assert(_section.gather(plain.project, plain.Bass, 0, 3840).loops.is_empty(), "no loop, no flag")


# --- T-006 ------------------------------------------------------------------------------------

func _test_write_leaves_other_bars() -> void:
	var s := _setup()
	var p: Object = s.project
	var inst: Object = _clip(p, s.Bass, "Line", 0, 4 * 3840, [[48, 0, 960], [48, 3840, 960], [48, 2 * 3840, 960], [48, 3 * 3840, 960]])
	var bar1: Object = inst.clip.midi_notes[0]
	var bar4: Object = inst.clip.midi_notes[3]
	var out := _write({"bars": "2-3", "text": "Bass: E3/4 r/2. | G3/4@90 r/2. |"})
	_assert(out.get("ok", false), "write bars 2-3 ok: %s" % out.get("error", ""))
	var notes := _song_notes(s.Bass)
	_assert(notes == [[48, 0, 960, 100], [64, 3840, 960, 100], [67, 7680, 960, 90], [48, 11520, 960, 100]], "bars 1 and 4 intact, 2-3 replaced: %s" % [notes])
	_assert(bar1 in inst.clip.midi_notes and bar4 in inst.clip.midi_notes, "bar 1 and 4 notes are the same objects")
	_assert(s.Bass.clip_instances.size() == 1, "no clip was created")
	_assert(str(out.text).contains("Bass: +2 notes, 2 removed"), "summary counts: %s" % out.text)


func _test_read_write_unchanged_is_noop() -> void:
	var s := _setup()
	var p: Object = s.project
	var inst: Object = _clip(p, s.Bass, "Line", 0, 2 * 3840, [[48, 8, 960, 87], [50, 960, 480, 100], [52, 1920, 960, 60], [48, 3840, 3840, 100]])
	var before := _song_notes(s.Bass)
	var ids: Array = inst.clip.midi_notes.map(func(n): return n.id)
	var read := _read({"bars": "1-2"})
	_assert(read.get("ok", false), "read ok: %s" % read.get("error", ""))
	var text: String = read.text
	var back := _write({"text": text})
	_assert(back.get("ok", false), "write back ok: %s\n%s" % [back.get("error", ""), text])
	_assert(back.data.added == 0 and back.data.changed == 0 and back.data.removed == 0, "read then write back changes nothing: %s" % [back.data])
	_assert(str(back.text).contains("no changes"), "result says no changes: %s" % back.text)
	_assert(_song_notes(s.Bass) == before, "notes identical, including the 8-tick-late onset")
	_assert(inst.clip.midi_notes.map(func(n): return n.id) == ids, "same note ids")
	# Edit one note's pitch: only that note changes.
	var edited := text.replace("D2", "F2")
	var out := _write({"text": edited})
	_assert(out.get("ok", false), "edited write ok: %s" % out.get("error", ""))
	_assert(out.data.added == 1 and out.data.removed == 1 and out.data.changed == 0, "one pitch edited: %s\n%s" % [out.data, text])
	_assert(_song_notes(s.Bass).filter(func(n): return n[1] == 8)[0][0] == 48, "the 8-tick-late note kept its offset and velocity")


## A note a few ticks before a barline belongs to the section its snapped onset falls in: an
## early downbeat is read and kept by its own section, never dropped or doubled by the one before.
func _test_section_edges_snap() -> void:
	var s := _setup()
	var p: Object = s.project
	_clip(p, s.Bass, "Edges", 0, 3 * 3840, [[48, 0, 960, 100], [50, 3830, 970, 100], [52, 7670, 970, 100]])
	var before := _song_notes(s.Bass)
	var read := _read({"bars": "2-2"})
	_assert(read.get("ok", false), "edge read ok: %s" % read.get("error", ""))
	var text: String = read.get("text", "")
	_assert(text.contains("D2/4") and not text.contains("E2"), "bar 2 shows its early downbeat D2, not bar 3's E2:\n%s" % text)
	var back := _write({"text": text})
	_assert(back.get("ok", false) and back.data.added == 0 and back.data.removed == 0 and back.data.changed == 0, "edge write back changes nothing: %s" % [back.get("data", back.get("error", ""))])
	_assert(_song_notes(s.Bass) == before, "early downbeats keep their exact onsets")
	var first := _read({"bars": "1-1"})
	_assert(not str(first.get("text", "")).contains("D2"), "bar 1 doesn't show bar 2's early downbeat")
	var rewrite := _write({"text": "section bars 1-1\nBass: C2/4 r/2. |"})
	_assert(rewrite.get("ok", false) and rewrite.data.removed == 0, "rewriting bar 1 leaves bar 2's early downbeat: %s" % [rewrite.get("data", rewrite.get("error", ""))])
	_assert(_song_notes(s.Bass) == before, "nothing moved")


func _test_clip_creation_and_naming() -> void:
	var s := _setup()
	var p: Object = s.project
	var line := "Bass: C2/1 | C2 | C2 | C2 | C2 | C2 | C2 | C2 |"
	p.add_marker(_marker_script.new())
	p.markers.clear()
	var m: Object = p.create_marker(0, 8 * 3840, "Verse")
	p.add_marker(m)
	var out := _write({"bars": "1-8", "text": line})
	_assert(out.get("ok", false), "write on an empty track ok: %s" % out.get("error", ""))
	_assert(s.Bass.clip_instances.size() == 1, "one clip created (%d)" % s.Bass.clip_instances.size())
	var inst: Object = s.Bass.clip_instances[0]
	_assert(inst.clip.name == "Verse Bass" and inst.start_ticks == 0 and inst.duration_ticks == 8 * 3840, "clip Verse Bass, bar 1, 8 bars: %s %d %d" % [inst.clip.name, inst.start_ticks, inst.duration_ticks])
	_assert(str(out.text).contains("Created clip \"Verse Bass\""), "result names the created clip: %s" % out.text)
	var t := _setup()
	var out2 := _write({"bars": "1-8", "text": line})
	_assert(out2.get("ok", false), "write without marker ok: %s" % out2.get("error", ""))
	_assert(t.Bass.clip_instances[0].clip.name == "Bass 1-8", "no marker: Bass 1-8 (%s)" % t.Bass.clip_instances[0].clip.name)
	# A run with no notes gets no clip: bars 1-4 written, bars 5-8 only rests.
	var u := _setup()
	var out3 := _write({"bars": "1-2", "text": "Bass: r/1 | r/1 |"})
	_assert(out3.get("ok", false) and u.Bass.clip_instances.is_empty(), "all rests: no clip")
	# A gap between two placements: only the uncovered bar with notes gets a clip.
	var v := _setup()
	_clip(v.project, v.Bass, "A", 0, 3840, [[48, 0, 960]])
	_clip(v.project, v.Bass, "B", 2 * 3840, 3840, [[48, 0, 960]])
	var out4 := _write({"bars": "1-3", "text": "Bass: C2/4 r/2. | D2/4 r/2. | C2/4 r/2. |"})
	_assert(out4.get("ok", false), "gap write ok: %s" % out4.get("error", ""))
	_assert(v.Bass.clip_instances.size() == 3, "a clip fills the gap (%d)" % v.Bass.clip_instances.size())
	var gap: Object = v.Bass.clip_instances.filter(func(i): return i.start_ticks == 3840)[0]
	_assert(gap.duration_ticks == 3840 and gap.clip.name == "Bass 2-2", "gap clip is bar 2: %s %d" % [gap.clip.name, gap.duration_ticks])


func _test_playable_range_warning() -> void:
	var s := _setup()
	_sfz(s.Bass, [[G_NEG1, "Sus_Alt"]], [[F_SHARP_0, 90]])
	var out := _write({"bars": "1", "text": "Bass: G-1/8 r/8 r/4 r/2 |"})
	_assert(out.get("ok", false), "out-of-range note still written: %s" % out.get("error", ""))
	_assert(_song_notes(s.Bass).size() == 1, "the note exists")
	var text: String = out.text
	_assert(text.contains("- Bass bar 1: G-1 is outside the playable keys"), "warning names track, bar and note: %s" % text)
	_assert(text.contains("ks:Sus_Alt"), "warning points at the keyswitch: %s" % text)


func _test_note_runs_past_clip() -> void:
	# A note that runs past the end of its placement is shortened, with a warning.
	var s := _setup()
	_clip(s.project, s.Bass, "Short", 0, 3840, [])
	var out := _write({"bars": "1-2", "text": "Bass: C2/1~ | C2/1 |"})
	_assert(out.get("ok", false), "write ok: %s" % out.get("error", ""))
	var notes := _song_notes(s.Bass)
	_assert(notes.size() == 1 and notes[0][2] == 3840, "the tied note (2 bars) is cut at its clip's end: %s" % [notes])
	_assert(str(out.text).contains("runs past the end of its clip"), "with a warning: %s" % out.text)
	_assert(s.Bass.clip_instances.size() == 1, "no clip is made for bar 2: nothing starts there")
	# A note that continues past the section keeps its real length when written back.
	var h := _setup()
	_clip(h.project, h.Bass, "Long", 0, 2 * 3840, [[48, 0, 2 * 3840, 100], [50, 960, 480, 100]])
	var read := _read({"bars": "1"})
	_assert(str(read.text).contains("C2/1~"), "a note running past the section ends in ~: %s" % read.get("text", ""))
	var back := _write({"text": read.text})
	_assert(back.get("ok", false) and back.data.added + back.data.removed + back.data.changed == 0, "held note writes back unchanged: %s" % [back.get("data", back.get("error"))])
	_assert(_song_notes(h.Bass)[0][2] == 2 * 3840, "and keeps its length")


func _test_transpose_and_offset_write() -> void:
	var s := _setup()
	# Song bar 3 shows clip bar 2 (clip_offset 3840), up an octave.
	var inst: Object = _clip(s.project, s.Bass, "Riff", 2 * 3840, 3840, [])
	inst.clip.content_length_ticks = 2 * 3840
	inst.clip_offset = 3840
	inst.transpose = 12
	var out := _write({"bars": "3", "text": "Bass: C3/4 r/2. |"})
	_assert(out.get("ok", false), "write into a trimmed, transposed placement ok: %s" % out.get("error", ""))
	var n: Object = inst.clip.midi_notes[0]
	_assert(n.note == 48 and n.start_tick == 3840 and n.duration_ticks == 960, "stored at clip tick 3840 as C2: %s" % [[n.note, n.start_tick, n.duration_ticks]])
	_assert(_song_notes(s.Bass) == [[60, 2 * 3840, 960, 100]], "plays as C3 at bar 3: %s" % [_song_notes(s.Bass)])
	var read := _read({"bars": "3"})
	_assert(str(read.text).contains("Bass:  C3/4"), "reads back as written: %s" % read.get("text", ""))
	var back := _write({"text": read.text})
	_assert(back.get("ok", false) and back.data.added + back.data.removed + back.data.changed == 0, "and is a no-op")


# --- T-007 ------------------------------------------------------------------------------------

func _shared_setup() -> Dictionary:
	var s := _setup()
	var a: Object = _clip(s.project, s.Bass, "Verse Bass", 0, 4 * 3840, [[48, 0, 960], [48, 3840, 960]])
	var b: Object = s.Bass.create_clip_instance(a.clip, 8 * 3840, 4 * 3840)
	s["a"] = a
	s["b"] = b
	return s


func _test_shared_clips() -> void:
	var text := "Bass: E2/4 r/2. | r/1 | r/1 | r/1 |"
	var s := _shared_setup()
	var before := _song_notes(s.Bass)
	var refused := _write({"bars": "1-4", "text": text})
	_assert(not refused.get("ok", true), "shared clip refused by default")
	var err := str(refused.get("error", ""))
	_assert(err.contains("Bass @ 9.1.000") and err.contains("unique") and err.contains("all"), "error names the placement and both options: %s" % err)
	_assert(_song_notes(s.Bass) == before, "refused write changes nothing")

	var u := _shared_setup()
	var uniq := _write({"bars": "1-4", "text": text, "shared_clips": "unique"})
	_assert(uniq.get("ok", false), "unique ok: %s" % uniq.get("error", ""))
	var notes := _song_notes(u.Bass)
	_assert(notes.filter(func(n): return n[1] >= 8 * 3840).size() == 2, "bar 9 unchanged after unique: %s" % [notes])
	_assert(notes.filter(func(n): return n[1] < 8 * 3840) == [[52, 0, 960, 100]], "bars 1-4 replaced: %s" % [notes])
	_assert(u.a.clip != u.b.clip, "the placement at bar 1 has its own clip now")
	_assert(str(uniq.text).contains("Copied clip \"Verse Bass\""), "result mentions the copy: %s" % uniq.text)

	var a2 := _shared_setup()
	var all := _write({"bars": "1-4", "text": text, "shared_clips": "all"})
	_assert(all.get("ok", false), "all ok: %s" % all.get("error", ""))
	var all_notes := _song_notes(a2.Bass)
	_assert(all_notes.filter(func(n): return n[1] >= 8 * 3840) == [[52, 8 * 3840, 960, 100]], "bar 9 changed too: %s" % [all_notes])

	# A clip placed again on another track also counts as shared.
	var o := _setup(["Bass", "Gtr"])
	var inst: Object = _clip(o.project, o.Bass, "Riff", 0, 3840, [[48, 0, 960]])
	o.Gtr.create_clip_instance(inst.clip, 0, 3840)
	var other := _write({"bars": "1", "text": "Bass: E2/1 |"})
	_assert(not other.get("ok", true) and str(other.error).contains("Gtr @ 1.1.000"), "placement on another track is named: %s" % other.get("error", ""))
	# A looping placement is shared with its own repeats.
	var l := _setup()
	var loop: Object = _clip(l.project, l.Bass, "Loop", 0, 4 * 3840, [[48, 0, 960]])
	loop.clip.content_length_ticks = 3840
	loop.set_loop(true, 0, 3840)
	var looped := _write({"bars": "1", "text": "Bass: E2/1 |"})
	_assert(not looped.get("ok", true) and str(looped.error).contains("loops"), "looping placement refused: %s" % looped.get("error", ""))


# --- T-008 ------------------------------------------------------------------------------------

func _drum_setup() -> Dictionary:
	var s := _setup(["Drums", "Bass"])
	_clip(s.project, s.Drums, "Beat", 0, 2 * 3840, [
		[36, 0, 240, 100], [38, 960, 240, 100], [36, 1920, 240, 100], [38, 2880, 240, 100],
		[42, 0, 240, 60], [42, 480, 240, 60], [36, 3840, 240, 100], [38, 3840 + 960, 240, 100],
	])
	return s


func _drum_notes(track: Object) -> Array:
	return _song_notes(track)


func _test_drum_roundtrip() -> void:
	var s := _drum_setup()
	var before := _drum_notes(s.Drums)
	var read := _read({"bars": "1-2", "tracks": ["Drums"]})
	_assert(read.get("ok", false), "drum read ok: %s" % read.get("error", ""))
	var text: String = read.text
	_assert(text.contains("Drums:\n  "), "drum block is indented under its label: %s" % text)
	var back := _write({"text": text})
	_assert(back.get("ok", false), "drum write back ok: %s\n%s" % [back.get("error", ""), text])
	_assert(back.data.added == 0 and back.data.changed == 0 and back.data.removed == 0, "unchanged drum block changes nothing: %s" % [back.data])
	# Change one cell: add a snare hit on beat 4 of bar 1 (the first row that has a '.' there).
	var lines := text.split("\n")
	var edited := PackedStringArray()
	var done := false
	for l in lines:
		if not done and l.strip_edges().begins_with("SNARE") or (not done and l.strip_edges().begins_with("Snare")):
			var bar := l.find("|")
			var cells := l.substr(bar + 1)
			# Replace the first '.' in the lane with a hit.
			var idx := cells.find(".")
			l = l.substr(0, bar + 1) + cells.substr(0, idx) + "9" + cells.substr(idx + 1)
			done = true
		edited.append(l)
	_assert(done, "found a snare lane to edit in:\n%s" % text)
	var out := _write({"text": "\n".join(edited)})
	_assert(out.get("ok", false), "edited drum write ok: %s\n%s" % [out.get("error", ""), "\n".join(edited)])
	_assert(out.data.added + out.data.changed + out.data.removed == 1, "exactly one drum note changed: %s" % [out.data])
	var after := _drum_notes(s.Drums)
	_assert(after.size() == before.size() + 1, "one more note (%d vs %d)" % [after.size(), before.size()])
	# Microtiming survives: nudge a kick and write the block back.
	s.Drums.clip_instances[0].clip.midi_notes[0].start_tick = 7
	var nudged := _drum_notes(s.Drums)
	var read2 := _read({"bars": "1-2", "tracks": ["Drums"]})
	var back2 := _write({"text": read2.text})
	_assert(back2.get("ok", false) and back2.data.changed + back2.data.added + back2.data.removed == 0, "a 7-tick-late kick is left alone: %s" % [back2.get("data", back2.get("error"))])
	_assert(_drum_notes(s.Drums) == nudged, "microtiming kept")


func _test_drum_pad_names() -> void:
	var s := _setup(["Drums"])
	var ch: Object = s.Drums.get_linked_channel()
	var drum := _device(ch, DRUM_ID, "Drum Machine", true)
	ch.add_device(drum)
	for pair in [[36, "Kick L"], [38, "Snare 1"]]:
		var pad := _device(ch, "test.pad.%d" % pair[0], "Pad")
		pad.name = pair[1]
		pad.slot_note = pair[0]
		drum.children.append(pad)
	_clip(s.project, s.Drums, "Beat", 0, 3840, [[36, 0, 240, 100], [38, 960, 240, 100], [36, 1920, 240, 100]])
	var read := _read({"bars": "1", "tracks": ["Drums"]})
	_assert(read.get("ok", false) and str(read.text).contains("Kick L") and str(read.text).contains("Snare 1"), "pad names label the lanes: %s" % read.get("text", read.get("error", "")))
	var before := _song_notes(s.Drums)
	var back := _write({"text": read.text})
	_assert(back.get("ok", false), "pad-name block writes back: %s" % back.get("error", ""))
	_assert(back.data.added == 0 and back.data.changed == 0 and back.data.removed == 0, "pad names round-trip with no changes: %s" % [back.data])
	_assert(_song_notes(s.Drums) == before, "notes untouched")


func _test_drum_meter_change_refused() -> void:
	var s := _setup(["Drums"])
	s.project.time_signature_map.add_change(2, 7, 8)
	_clip(s.project, s.Drums, "Beat", 0, 3840 + 3360, [[36, 0, 240, 100]])
	var text := "section bars 1-2\nDrums:\n  |1 . 2 . 3 . 4 .|\n  KICK |9 . . . . . . .|\n"
	var out := _write({"text": text})
	_assert(not out.get("ok", true), "a drum block across a meter change is refused")
	_assert(str(out.get("error", "")).contains("split the section at bar 2"), "names the bar to split at: %s" % out.get("error", ""))
	var notes_before := _song_notes(s.Drums)
	var read := _read({"bars": "1-2"})
	_assert(read.get("ok", false) and str(read.text).contains("C1"), "a read across the change falls back to notes: %s" % read.get("text", read.get("error", "")))
	var back := _write({"text": read.text})
	_assert(back.get("ok", false) and _song_notes(s.Drums) == notes_before, "and writes back cleanly: %s" % back.get("error", ""))


# --- T-009 ------------------------------------------------------------------------------------

func _test_keyswitch_placement() -> void:
	var s := _setup(["Gtr"])
	_sfz(s.Gtr, [[G_NEG1, "Sus_Alt"], [20, "Mute_Down"]], [[F_SHARP_0, 100]])
	var out := _write({"bars": "1", "text": "Gtr: r/4 ks:Sus_Alt D2/8 r/8 r/2 |"})
	_assert(out.get("ok", false), "ks write ok: %s" % out.get("error", ""))
	var notes := _song_notes(s.Gtr)
	_assert([G_NEG1, 900, 60] == notes[0].slice(0, 3) or notes.any(func(n): return n[0] == G_NEG1 and n[1] == 900 and n[2] == 60),
		"keyswitch 60 ticks before the note, 60 long: %s" % [notes])
	_assert(notes.any(func(n): return n[0] == D2 and n[1] == 960 and n[2] == 480), "the note itself: %s" % [notes])
	_assert(not str(out.text).contains("outside the playable"), "a keyswitch is not a range warning: %s" % out.text)
	var read := _read({"bars": "1"})
	_assert(str(read.text).contains("ks:Sus_Alt") and not str(read.text).contains("G-1"), "reads back as ks:Sus_Alt: %s" % read.get("text", read.get("error", "")))
	var back := _write({"text": read.text})
	_assert(back.get("ok", false) and back.data.added == 0 and back.data.removed == 0 and back.data.changed == 0, "ks round-trips with no changes: %s" % [back.get("data", back.get("error"))])
	_assert(_song_notes(s.Gtr) == notes, "notes identical")

	# At the clip start there is no room before the note: the switch starts with it.
	var t := _setup(["Gtr"])
	_sfz(t.Gtr, [[G_NEG1, "Sus_Alt"]])
	var first := _write({"bars": "1", "text": "Gtr: ks:Sus_Alt D2/8 r/8 r/4 r/2 |"})
	_assert(first.get("ok", false), "ks at clip start ok: %s" % first.get("error", ""))
	var fn := _song_notes(t.Gtr)
	_assert(fn.any(func(n): return n[0] == G_NEG1 and n[1] == 0 and n[2] == 60), "at tick 0 the switch starts at 0, 60 long: %s" % [fn])
	var fr := _read({"bars": "1"})
	_assert(str(fr.text).contains("ks:Sus_Alt"), "and reads back: %s" % fr.get("text", ""))
	var fb := _write({"text": fr.text})
	_assert(fb.get("ok", false) and fb.data.added + fb.data.removed + fb.data.changed == 0, "no change on write back: %s" % [fb.get("data", fb.get("error"))])

	# The switch for the first note of a section sits in the bar before: it belongs to this section.
	var u := _setup(["Gtr"])
	_sfz(u.Gtr, [[G_NEG1, "Sus_Alt"]])
	_clip(u.project, u.Gtr, "Long", 0, 2 * 3840, [])
	var two := _write({"bars": "2", "text": "Gtr: ks:Sus_Alt D2/1 |"})
	_assert(two.get("ok", false), "ks at bar start ok: %s" % two.get("error", ""))
	_assert(_song_notes(u.Gtr).any(func(n): return n[0] == G_NEG1 and n[1] == 3840 - 60), "switch 60 ticks into the previous bar: %s" % [_song_notes(u.Gtr)])
	var prev := _write({"bars": "1", "text": "Gtr: r/1 |"})
	_assert(prev.get("ok", false), "bar 1 rewrite ok: %s" % prev.get("error", ""))
	_assert(_song_notes(u.Gtr).any(func(n): return n[0] == G_NEG1), "writing the bar before leaves bar 2's switch alone")
	var again := _write({"bars": "2", "text": "Gtr: ks:Sus_Alt D2/1 |"})
	_assert(again.get("ok", false) and again.data.added + again.data.removed + again.data.changed == 0, "rewriting bar 2 keeps it: %s" % [again.get("data", again.get("error"))])

	# Unknown names list the available ones; no keyswitches at all says so.
	var bad := _write({"bars": "1", "text": "Gtr: ks:Palm D2/1 |"})
	_assert(not bad.get("ok", true) and str(bad.error).contains("Sus_Alt"), "ks:Palm lists names: %s" % bad.get("error", ""))
	var plain := _setup(["Pad"])
	var nope := _write({"bars": "1", "text": "Pad: ks:Palm D2/1 |"})
	_assert(not nope.get("ok", true) and str(nope.error).contains("no keyswitches"), "no keyswitches says so: %s" % nope.get("error", ""))


# --- T-010 ------------------------------------------------------------------------------------

func _test_read_section_basics() -> void:
	var s := _setup(["Bass", "Drums", "Pad", "Vox"])
	s.project.create_audio_track("Strings")
	_clip(s.project, s.Bass, "Line", 0, 2 * 3840, [[36, 0, 960], [38, 960, 960], [40, 3840, 3840]])
	_clip(s.project, s.Drums, "Beat", 0, 2 * 3840, [[36, 0, 240], [38, 960, 240], [36, 3840, 240]])
	var out := _read({"bars": "1-2"})
	_assert(out.get("ok", false), "read ok: %s" % out.get("error", ""))
	var text: String = out.text
	_assert(text.begins_with("section bars 1-2   4/4"), "header first: %s" % text)
	var bass_line := ""
	for l in text.split("\n"):
		if l.begins_with("Bass:"):
			bass_line = l
	_assert(bass_line != "" and bass_line.count("|") == 2, "Bass line covers exactly 2 bars: %s" % bass_line)
	_assert(text.contains("Drums:\n  "), "Drums grid block: %s" % text)
	_assert(text.contains("# empty: Pad, Vox"), "empty instrument tracks on one line: %s" % text)
	_assert(text.contains("# skipped (audio): Strings"), "audio listed as skipped: %s" % text)
	_assert(not text.contains("Pad:") and not text.contains("Vox:"), "empty tracks have no line")
	_assert(not str(out.data).contains("Bass"), "no payload beyond counts: %s" % [out.data])
	var named := _read({"bars": "1-2", "tracks": ["Pad"]})
	_assert(named.get("ok", false) and str(named.text).contains("Pad:") and not str(named.text).contains("Bass:"), "a named empty track is shown as rests: %s" % named.get("text", named.get("error", "")))
	var bad := _read({"bars": "1-2", "tracks": ["Nope"]})
	_assert(not bad.get("ok", true), "unknown track refused")
	var nobars := _read({})
	_assert(not nobars.get("ok", true), "no bars and no range is refused")
	s.editor.test_time_range_override = {"has": true, "start": 3840, "has_end": true, "end": 2 * 3840}
	var ranged := _read({})
	_assert(ranged.get("ok", false) and str(ranged.text).begins_with("section bars 2-2"), "the selected range supplies the bars: %s" % ranged.get("text", ranged.get("error", "")))

	# REQ-003/004: 7/8 from bar 2, durations add up to each bar.
	var m := _setup(["Bass"])
	m.project.time_signature_map.add_change(2, 7, 8)
	_clip(m.project, m.Bass, "Line", 0, 3840 + 3360, [[36, 0, 480], [38, 3840 + 960, 960]])
	var mixed := _read({"bars": "1-2"})
	_assert(mixed.get("ok", false), "mixed read ok: %s" % mixed.get("error", ""))
	_assert(str(mixed.text).contains("4/4 (bar 1), 7/8 (bar 2)"), "header shows both meters: %s" % mixed.text)
	var plan: Array = _section.bar_plan(m.project, 1, 2).plan
	var parsed: Dictionary = load("res://ai/clip_text/ScoreText.gd").parse(mixed.text, plan, {"ppq": 960})
	_assert(parsed.get("ok", false), "the read text parses against the same plan: %s\n%s" % [parsed.get("error", ""), mixed.text])
	var again := _write({"text": mixed.text})
	_assert(again.get("ok", false) and again.data.added + again.data.removed + again.data.changed == 0, "mixed-meter read writes back unchanged: %s" % [again.get("data", again.get("error"))])


func _test_read_section_voices_and_chords() -> void:
	var s := _setup(["Piano"])
	_clip(s.project, s.Piano, "Keys", 0, 3840, [
		[60, 0, 3840], [64, 0, 960], [65, 960, 960], [67, 1920, 960], [69, 2880, 960],
	])
	var out := _read({"bars": "1"})
	_assert(out.get("ok", false), "voices read ok: %s" % out.get("error", ""))
	_assert(str(out.text).contains("Piano.1:") and str(out.text).contains("Piano.2:"), "sustained note under a moving line gives two voices: %s" % out.text)
	var back := _write({"text": out.text})
	_assert(back.get("ok", false) and back.data.added + back.data.removed + back.data.changed == 0, "voices write back unchanged: %s\n%s" % [back.get("error", back.get("data")), out.text])
	var c := _setup(["Piano"])
	_clip(c.project, c.Piano, "Chord", 0, 3840, [[60, 0, 3840], [64, 0, 3840], [67, 0, 3840]])
	var chord := _read({"bars": "1"})
	_assert(str(chord.text).contains("[C3 E3 G3]"), "chord reads as [C3 E3 G3]: %s" % chord.get("text", ""))


func _test_read_section_keyswitch() -> void:
	var s := _setup(["Gtr"])
	_sfz(s.Gtr, [[G_NEG1, "Sus_Alt"]])
	_clip(s.project, s.Gtr, "Line", 0, 3840, [[G_NEG1, 900, 60], [D2, 960, 480]])
	var out := _read({"bars": "1"})
	_assert(str(out.text).contains("ks:Sus_Alt") and not str(out.text).contains("G-1"), "a note on G-1 before the phrase reads as ks:Sus_Alt, not G-1/64: %s" % out.get("text", ""))


func _test_read_section_off_grid() -> void:
	var s := _setup(["Keys", "Bass"])
	_clip(s.project, s.Keys, "Played", 0, 3840, [[60, 30, 900], [64, 1950, 400]])
	_clip(s.project, s.Bass, "Line", 0, 3840, [[36, 0, 960]])
	var out := _read({"bars": "1"})
	_assert(out.get("ok", false), "off-grid read ok: %s" % out.get("error", ""))
	var text: String = out.text
	_assert(text.contains("# Keys: off-grid timing, shown as events"), "Keys falls back with a reason: %s" % text)
	_assert(text.contains("Bass:"), "Bass stays in score text: %s" % text)
	var near := _setup(["Keys"])
	_clip(near.project, near.Keys, "Played", 0, 3840, [[60, 8, 952]])
	_assert(str(_read({"bars": "1"}).text).contains("Keys:"), "8 ticks off still snaps")


func _test_read_section_cap() -> void:
	var s := _setup()
	_clip(s.project, s.Bass, "Long", 0, 40 * 3840, [[36, 0, 960]])
	var out := _read({"bars": "1-40"})
	_assert(out.get("ok", false), "long read ok: %s" % out.get("error", ""))
	var text: String = out.text
	_assert(text.begins_with("section bars 1-16"), "returns bars 1-16: %s" % text.substr(0, 60))
	_assert(text.contains("limit 16 bars"), "names the limit: %s" % text)


func _test_registered() -> void:
	var reg: Object = _registry_script.create_default()
	_assert(reg.get_tool("read_section") != null and reg.get_tool("write_section") != null, "both tools are registered")
	var schema: Dictionary = reg.get_tool("write_section").to_openrouter()
	_assert(schema["function"]["parameters"]["required"] == ["text"], "write_section requires text")


# --- T-011 ------------------------------------------------------------------------------------

func _test_write_section_one_undo() -> void:
	var s := _setup(["Bass", "Gtr"])
	var text := "section bars 1-2   4/4\nBass: D1/4 D1 D1 D1 | D1/1 |\nGtr: [D2 A2]/2 [F2 C3] | [D2 A2]/1 |\n"
	_record_start()
	var out := _write({"text": text})
	_record_stop()
	_assert(out.get("ok", false), "two-track write ok: %s" % out.get("error", ""))
	_assert(_recorded.size() == 1, "one history entry (%d)" % _recorded.size())
	_assert(s.Bass.clip_instances.size() == 1 and s.Gtr.clip_instances.size() == 1, "clips created on both tracks")
	_assert(_song_notes(s.Bass).size() == 5 and _song_notes(s.Gtr).size() == 6, "notes written (%d, %d)" % [_song_notes(s.Bass).size(), _song_notes(s.Gtr).size()])
	var lines: Array = Array(str(out.text).split("\n")).filter(func(l): return l.begins_with("Bass:") or l.begins_with("Gtr:"))
	_assert(lines.size() == 2, "two summary lines: %s" % out.text)
	_assert(not str(out.text).contains("|"), "no barlines in the result: %s" % out.text)
	_assert(s.project.clips.size() == 2, "two clips in the pool (%d)" % s.project.clips.size())
	_recorded[0].undo()
	_assert(_song_notes(s.Bass).is_empty() and _song_notes(s.Gtr).is_empty(), "one undo removes the notes")
	_assert(s.Bass.clip_instances.is_empty() and s.Gtr.clip_instances.is_empty() and s.project.clips.is_empty(), "and the created clips")
	_recorded[0].do()
	_assert(_song_notes(s.Bass).size() == 5 and s.Bass.clip_instances.size() == 1, "redo brings them back")

	# Undo of a write into an existing clip restores the old notes.
	var t := _setup()
	_clip(t.project, t.Bass, "Line", 0, 3840, [[36, 0, 960, 80], [38, 960, 960, 80]])
	var before := _song_notes(t.Bass)
	_record_start()
	var w := _write({"bars": "1", "text": "Bass: C2/1 |"})
	_record_stop()
	_assert(w.get("ok", false) and _recorded.size() == 1, "write into an existing clip is one entry")
	_recorded[0].undo()
	_assert(_song_notes(t.Bass) == before, "undo restores the old notes: %s" % [_song_notes(t.Bass)])
	# A write that changes nothing records nothing.
	_record_start()
	var noop := _write({"bars": "1", "text": "Bass: C#1/4@80 D1/4@80 r/2 |"})
	_record_stop()
	_assert(noop.get("ok", false), "no-op write ok: %s" % noop.get("error", ""))
	_assert(_recorded.size() <= 1, "history entries recorded")


func _test_write_section_errors() -> void:
	var s := _setup(["Bass", "Gtr"])
	s.project.time_signature_map.add_change(2, 7, 8)
	var long := _write({"bars": "2", "text": "Bass: D1/4 D1 D1 D1 |"})
	_assert(not long.get("ok", true), "4/4 bar in 7/8 refused")
	_assert(str(long.error) == "Bass bar 2 adds up to 8/8 (3840 ticks); a 7/8 bar is 3360 ticks", "REQ-012 message: %s" % long.get("error", ""))
	var few := _write({"bars": "1-4", "text": "Bass: D1/1 | D1/1 | D1/1 |"})
	_assert(not few.get("ok", true) and str(few.error).contains("3") and str(few.error).contains("4"), "REQ-013 names both counts: %s" % few.get("error", ""))
	var tie := _write({"bars": "1-2", "text": "Bass: A3/4~ r/2. | A3/2 r/4 |"})
	_assert(not tie.get("ok", true), "a rest after a tie is refused")
	var tied := _write({"bars": "1-2", "text": "Bass: r/2. A3/4~ | B3/2 r/2 |"})
	_assert(not tied.get("ok", true) and str(tied.error).contains("bar 2"), "a tie to a different pitch is refused, naming the bar: %s" % tied.get("error", ""))
	var ok_tie := _setup()
	var ok := _write({"bars": "1-2", "text": "Bass: r/2. A3/4~ | A3/2 r/2 |"})
	_assert(ok.get("ok", false), "tie across a barline ok: %s" % ok.get("error", ""))
	var joined: Array = _song_notes(ok_tie.Bass)
	_assert(joined.size() == 1 and joined[0][2] == 960 + 1920, "one A3 of 3 beats across the barline: %s" % [joined])
	var token := _write({"bars": "1", "text": "Bass: D1/8 X9/8 r/2 r/4. |"})
	_assert(not token.get("ok", true) and str(token.error).contains("Bass") and str(token.error).contains("bar 1") and str(token.error).contains("X9/8") and str(token.error).contains("<pitch>/<value>"), "REQ-019 names track, bar, token, form: %s" % token.get("error", ""))
	var unknown := _write({"bars": "1", "text": "Nope: D1/1 |"})
	_assert(not unknown.get("ok", true) and str(unknown.error).contains("Nope"), "unknown track: %s" % unknown.get("error", ""))
	var missing := _write({"text": "Bass: D1/1 |"})
	_assert(not missing.get("ok", true) and str(missing.error).contains("bars"), "no bars anywhere is refused: %s" % missing.get("error", ""))
	var audio := _setup()
	audio.project.create_audio_track("Vox")
	var vox := _write({"bars": "1", "text": "Vox: D1/1 |"})
	_assert(not vox.get("ok", true) and str(vox.error).contains("instrument"), "audio track refused: %s" % vox.get("error", ""))
	var bad_opt := _write({"bars": "1", "text": "Bass: D1/1 |", "shared_clips": "maybe"})
	_assert(not bad_opt.get("ok", true), "bad shared_clips refused")


func _test_write_section_rollback() -> void:
	var s := _setup(["Bass", "Gtr"])
	_clip(s.project, s.Gtr, "G", 0, 3840, [[48, 0, 960]])
	_clip(s.project, s.Bass, "B", 0, 3840, [[36, 0, 960]])
	# A parse error on track 2 leaves track 1 unchanged.
	var before_b := _song_notes(s.Bass)
	var before_g := _song_notes(s.Gtr)
	var clips_before: int = s.project.clips.size()
	var bad := _write({"bars": "1", "text": "Bass: E2/1 |\nGtr: X9/1 |"})
	_assert(not bad.get("ok", true), "parse error refuses the write")
	_assert(_song_notes(s.Bass) == before_b and _song_notes(s.Gtr) == before_g, "no track changed")
	# A failure after track 1 was written (a drum block the grid rejects) rolls track 1 back.
	var d := _setup(["Bass", "Drums"])
	_clip(d.project, d.Bass, "B", 0, 3840, [[36, 0, 960]])
	var bass_before := _song_notes(d.Bass)
	var clips: int = d.project.clips.size()
	_record_start()
	var out := _write({"bars": "1", "text": "Bass: E2/1 |\nDrums:\n  |1 . 2 . 3 . 4 .|\n  ?? |9 . . .|\n"})
	_record_stop()
	_assert(not out.get("ok", true), "a drum block the grid rejects fails: %s" % out.get("text", out.get("error", "")))
	_assert(_song_notes(d.Bass) == bass_before, "track 1 was rolled back: %s" % [_song_notes(d.Bass)])
	_assert(d.project.clips.size() == clips and d.Drums.clip_instances.is_empty(), "no clip left behind")
	_assert(_recorded.is_empty(), "nothing recorded for a failed write")
	# A shared clip on track 2 is refused before track 1 is touched.
	var sh := _shared_setup()
	sh["Gtr"] = sh.project.create_instrument_track("Gtr").track
	var bnotes := _song_notes(sh.Bass)
	var refused := _write({"bars": "1-4", "text": "Gtr: D1/1 | r/1 | r/1 | r/1 |\nBass: E2/1 | r/1 | r/1 | r/1 |"})
	_assert(not refused.get("ok", true) and sh.Gtr.clip_instances.is_empty() and _song_notes(sh.Bass) == bnotes, "shared refusal on any track writes nothing")


func _test_write_section_header_mismatch() -> void:
	var s := _setup()
	var out := _write({"bars": "1-4", "text": "section bars 5-8\nBass: D1/1 | D1/1 | D1/1 | D1/1 |"})
	_assert(not out.get("ok", true) and str(out.error).contains("5-8") and str(out.error).contains("1-4"), "header and bars must agree: %s" % out.get("error", ""))
	var header_only := _write({"text": "section bars 3-3\nBass: D1/1 |"})
	_assert(header_only.get("ok", false), "the header supplies the bars: %s" % header_only.get("error", ""))
	_assert(s.Bass.clip_instances[0].start_ticks == 2 * 3840, "bar 3 placement")


# --- T-012 ------------------------------------------------------------------------------------

## REQ-022: the score example in the system prompt writes cleanly to a matching project.
func _test_prompt_example() -> void:
	var prompt := FileAccess.get_file_as_string("res://ai/prompt/system_prompt.md")
	var open_at := prompt.find("```score\n")
	_assert(open_at >= 0, "system prompt has a ```score example")
	if open_at < 0:
		return
	var body_at := open_at + "```score\n".length()
	var example := prompt.substr(body_at, prompt.find("\n```", body_at) - body_at)
	var s := _setup(["Bass", "Guitar", "Lead", "Drums"])
	var p: Object = s.project
	p.time_numerator = 7
	p.time_denominator = 8
	_sfz(s.Guitar, [[19, "Sus_Alt"], [20, "Mute_Down"]])
	var out := _write({"text": example})
	_assert(out.get("ok", false), "prompt example writes: %s" % out.get("error", ""))
	if out.get("ok", false):
		_assert(out.data.added > 0 and not str(out.text).contains("- "), "prompt example writes notes with no warnings:\n%s" % out.text)
		var back := _read({"bars": "1-2"})
		_assert(str(back.get("text", "")).contains("ks:Sus_Alt") and str(back.text).contains("Drums:"), "prompt example reads back:\n%s" % back.get("text", ""))


func _test_performance() -> void:
	var names: Array = []
	for i in 8:
		names.append("Track%d" % (i + 1))
	var s := _setup(names)
	for ti in 8:
		var notes: Array = []
		for b in 16:
			for k in 8:
				notes.append([36 + ((ti * 3 + b + k) % 24), b * 3840 + k * 480, 480, 70 + ((k * 7) % 50)])
		_clip(s.project, s[names[ti]], "Part %d" % ti, 0, 16 * 3840, notes)
	var t0 := Time.get_ticks_usec()
	var read := _read({"bars": "1-16"})
	var read_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_assert(read.get("ok", false), "perf read ok: %s" % read.get("error", ""))
	print("read 16 bars x 8 tracks: %.1f ms" % read_ms)
	_assert(read_ms < 50.0, "read 16 bars x 8 tracks under 50 ms (%.1f ms)" % read_ms)
	var t1 := Time.get_ticks_usec()
	var back := _write({"text": read.text})
	var write_ms := (Time.get_ticks_usec() - t1) / 1000.0
	_assert(back.get("ok", false), "perf write ok: %s" % back.get("error", ""))
	print("write 16 bars x 8 tracks: %.1f ms" % write_ms)
	_assert(write_ms < 50.0, "write 16 bars x 8 tracks under 50 ms (%.1f ms)" % write_ms)
	_assert(back.data.added + back.data.removed + back.data.changed == 0, "and it is a no-op: %s" % [back.data])
	# A write that changes every track is also quick.
	var edited := str(read.text).replace("C3", "D3")
	var t2 := Time.get_ticks_usec()
	var changed := _write({"text": edited})
	var edit_ms := (Time.get_ticks_usec() - t2) / 1000.0
	print("changing write 16 bars x 8 tracks: %.1f ms" % edit_ms)
	_assert(changed.get("ok", false), "perf changing write ok: %s" % changed.get("error", ""))
