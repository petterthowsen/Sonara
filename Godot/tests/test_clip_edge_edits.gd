# test_clip_edge_edits.gd
# Headless tests for ClipEdgeEdits (loaded with load(), as scripts naming autoloads must be), the edge-resize / loop-length / move-clamp rules shared by the
# arranger's TimelineClip and the clip editor's ClipStrip.
# Run: godot --headless --path Godot -s tests/test_clip_edge_edits.gd -- --test
extends TestBase

var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _edits: GDScript


func suite_name() -> String:
	return "ClipEdgeEdits tests"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_edits = load("res://history/ClipEdgeEdits.gd")
	_test_left_trim_keeps_song_positions()
	_test_right_resize_grows_and_shrinks_content()
	_test_left_trim_past_start_pads()
	_test_left_trim_held_by_neighbour_and_min()
	_test_set_loop_length()
	_test_clamp_move()
	_test_transform_command_null_when_unchanged()


## A track with one MIDI clip instance of `duration` at `start`, holding a note at clip tick `note_tick`.
func _setup(start: int, duration: int, note_tick: int = 0, offset: int = 0) -> Dictionary:
	var track: Object = _track_script.new(2)
	var clip: Object = _clip_script.new()
	clip.content_length_ticks = duration + offset
	clip.add_midi_note(1, 60, 0.8, note_tick, 240)
	var inst: Object = _instance_script.new()
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = duration
	inst.clip_offset = offset
	track.add_clip_instance(inst)
	return {"track": track, "clip": clip, "inst": inst}


func _song_tick_of_first_note(s: Dictionary) -> int:
	var note: Object = s.clip.midi_notes[0]
	return s.inst.start_ticks + note.start_tick - s.inst.clip_offset


func _test_left_trim_keeps_song_positions() -> void:
	var s: Dictionary = _setup(3840, 3840, 960)
	var before: int = _song_tick_of_first_note(s)
	var snap: Dictionary = _edits.snapshot(s.inst)
	_edits.resize_left(s.inst, snap, 960, 1)
	_assert(s.inst.start_ticks == 3840 + 960, "left trim moves start_ticks")
	_assert(s.inst.clip_offset == 960, "left trim moves clip_offset with it")
	_assert(s.inst.duration_ticks == 3840 - 960, "left trim shortens the duration")
	_assert(_song_tick_of_first_note(s) == before, "left trim leaves the note's song position")
	_edits.resize_left(s.inst, snap, 0, 1)
	_assert(s.inst.start_ticks == 3840 and s.inst.clip_offset == 0 and s.inst.duration_ticks == 3840,
		"dragging back restores the clip")


func _test_right_resize_grows_and_shrinks_content() -> void:
	var s: Dictionary = _setup(0, 3840)
	var snap: Dictionary = _edits.snapshot(s.inst)
	_edits.resize_right(s.inst, snap, 3840, 1)
	_assert(s.inst.duration_ticks == 7680, "right resize adds the delta to the duration")
	_assert(s.clip.content_length_ticks == 7680, "right resize past the content grows the clip")
	_edits.resize_right(s.inst, snap, -960, 1)
	_assert(s.inst.duration_ticks == 2880, "right resize can shorten")
	_assert(s.clip.content_length_ticks == 3840, "growth is given up, never below the start length")
	_edits.resize_right(s.inst, snap, -100000, 240)
	_assert(s.inst.duration_ticks == 240, "right resize keeps the minimum duration")


func _test_left_trim_past_start_pads() -> void:
	var s: Dictionary = _setup(3840, 3840, 0)
	var before: int = _song_tick_of_first_note(s)
	var snap: Dictionary = _edits.snapshot(s.inst)
	var added: int = _edits.resize_left(s.inst, snap, -960, 1)
	_assert(added == 960, "pulling the left edge before the content pads it (got %d)" % added)
	_assert(s.inst.start_ticks == 3840 - 960 and s.inst.clip_offset == 0, "start moves back, offset stays 0")
	_assert(s.clip.content_length_ticks == 3840 + 960, "the clip grows by the padding")
	_assert(_song_tick_of_first_note(s) == before, "padding keeps the note's song position")


func _test_left_trim_held_by_neighbour_and_min() -> void:
	var s: Dictionary = _setup(3840, 960)
	var left: Object = _instance_script.new()
	left.clip = s.clip
	left.start_ticks = 0
	left.duration_ticks = 3000
	s.track.add_clip_instance(left)
	var snap: Dictionary = _edits.snapshot(s.inst)
	_edits.resize_left(s.inst, snap, -3840, 1)
	_assert(s.inst.start_ticks == 3000, "left edge stops at the neighbour's end (got %d)" % s.inst.start_ticks)
	_edits.resize_left(s.inst, snap, 100000, 480)
	_assert(s.inst.duration_ticks == 480, "left trim keeps the minimum duration")


func _test_set_loop_length() -> void:
	var s: Dictionary = _setup(0, 3840)
	s.inst.set_loop(true, 0, 1920)
	_edits.set_loop_length(s.inst, 5760, 3840)
	_assert(s.inst.loop_length_ticks == 5760, "loop length is set")
	_assert(s.inst.loop_start_ticks == 0, "loop start stays")
	_assert(s.clip.content_length_ticks == 5760, "the MIDI clip grows past its content")
	_edits.set_loop_length(s.inst, 960, 3840)
	_assert(s.inst.loop_length_ticks == 960, "loop length can shrink")
	_assert(s.clip.content_length_ticks == 3840, "shrinking gives growth back, never below the start length")
	_edits.set_loop_length(s.inst, -5, 3840)
	_assert(s.inst.loop_length_ticks == 1, "loop length is at least 1")


func _test_clamp_move() -> void:
	var s: Dictionary = _setup(0, 960)
	var other: Object = _instance_script.new()
	other.clip = s.clip
	other.start_ticks = 1920
	other.duration_ticks = 960
	s.track.add_clip_instance(other)
	var moving: Array = [s.inst]
	_assert(_edits.clamp_move_on_track(0, 960, s.track, moving, 480) == 480, "free move is untouched")
	_assert(_edits.clamp_move_on_track(0, 960, s.track, moving, 1500) == 960, "move right stops at the neighbour")
	_assert(_edits.clamp_move_on_track(0, 960, s.track, moving, 5000) == 5000, "a jump past the neighbour into a free gap is allowed")
	_assert(_edits.clamp_move_on_track(0, 960, s.track, moving, 2400) == 960, "a move that would land on the neighbour stops at it")
	_assert(_edits.clamp_move_on_track(0, 960, s.track, moving, -480) == 0, "move left stops at tick 0")
	_assert(_edits.clamp_move_on_track(3840, 960, s.track, [], -1500) == -960, "move left stops after the neighbour")
	_assert(_edits.clamp_move_on_track(0, 960, s.track, moving, 0) == 0, "zero delta stays zero")


func _test_transform_command_null_when_unchanged() -> void:
	var s: Dictionary = _setup(0, 3840)
	var snap: Dictionary = _edits.snapshot(s.inst)
	_assert(_edits.transform_command("Resize Clip", s.inst, snap) == null, "no change gives no command")
	_edits.resize_right(s.inst, snap, 960, 1)
	var cmd = _edits.transform_command("Resize Clip", s.inst, snap)
	_assert(cmd != null and cmd.name == "Resize Clip", "a change gives a named command")
	cmd.undo()
	_assert(s.inst.duration_ticks == 3840 and s.clip.content_length_ticks == 3840, "undo restores duration and content length")
