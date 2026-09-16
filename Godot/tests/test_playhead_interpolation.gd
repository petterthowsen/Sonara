# test_playhead_interpolation.gd
# Headless tests for Editor's visual playhead interpolation.
#
# The regression these guard: the old interpolator drove the playhead from the *error*
# against the last tick received from the engine, then clamped it so it could never pass
# that tick. The engine reports at ~20 Hz while the UI renders at 60+, so the visual
# velocity rippled at the update rate instead of holding steady - measured at 10-30%
# standard deviation around the mean, with the slowest and fastest frames differing by
# 2x at 60 fps, 5x at 120 fps, and up to 29x once realistic frame-time jitter was added.
# That ripple is what read as jitter. The replacement free-runs a float clock at tempo
# rate and only corrects phase gradually, holding velocity sd under 4%.
#
# `_test_velocity_is_steady` is the discriminating one: the old implementation measures
# ~0.17 on the ratio it asserts, the new one ~0.02.
#
# Run: godot --headless --path Godot -s tests/test_playhead_interpolation.gd -- --test
extends TestBase


const TEMPO := 120.0
const PPQ := 960
const TICKS_PER_SECOND := (TEMPO * PPQ) / 60.0  # 1920
const FRAME_DELTA := 1.0 / 60.0
const ENGINE_UPDATE_SEC := 1.0 / 20.0


var _editor_script: GDScript
var _project_script: GDScript


func suite_name() -> String:
	return "Playhead interpolation tests"


func run_tests() -> void:
	# Loaded at runtime rather than referenced as bare identifiers: a static reference
	# makes this script depend on Editor.gd/Project.gd at compile time, which fails in
	# `-s` mode because their autoloads (Settings, AudioEngineOSC) aren't resolvable yet.
	_editor_script = load("res://editor/Editor.gd")
	_project_script = load("res://data/Project.gd")
	_test_velocity_is_steady()
	_test_tracks_engine_without_drift()
	_test_large_jump_snaps()
	_test_update_while_stopped_applies_directly()


## Build an Editor with a project, positioned at tick 0 and playing.
func _make_editor() -> Node:
	var editor: Node = _editor_script.new()
	var project: RefCounted = _project_script.new()
	project.tempo = TEMPO
	project.ppq = PPQ
	editor.project = project
	editor.is_playing = true
	editor.playhead_ticks = 0
	editor._reset_playhead_interpolation(0)
	return editor


## Run `seconds` of simulated playback, feeding engine updates at 20 Hz and calling
## _process() at 60 Hz. Returns the per-frame advance in ticks.
func _simulate(editor: Node, seconds: float) -> Array[int]:
	var advances: Array[int] = []
	var elapsed := 0.0
	var next_update := ENGINE_UPDATE_SEC
	while elapsed < seconds:
		elapsed += FRAME_DELTA
		# The engine's own clock is exact; it reports where it actually is.
		if elapsed >= next_update:
			editor._on_playhead_received([int(TICKS_PER_SECOND * next_update)])
			next_update += ENGINE_UPDATE_SEC
		var before: int = editor.playhead_ticks
		editor._process(FRAME_DELTA)
		advances.append(editor.playhead_ticks - before)
	return advances


func _test_velocity_is_steady() -> void:
	var editor: Node = _make_editor()
	var advances := _simulate(editor, 2.0)
	# Skip the startup transient while the corrector settles.
	var steady := advances.slice(10)

	var total := 0
	for a in steady:
		total += a
	var mean := float(total) / steady.size()

	var variance := 0.0
	var min_advance: int = steady[0]
	var max_advance: int = steady[0]
	var backwards := 0
	for a in steady:
		variance += (a - mean) * (a - mean)
		min_advance = mini(min_advance, a)
		max_advance = maxi(max_advance, a)
		if a < 0:
			backwards += 1
	var sd := sqrt(variance / steady.size())
	var ripple := sd / mean

	_assert(backwards == 0, "playhead never moves backwards during steady playback")
	_assert(mean > 0.0, "playhead advances during playback (mean %.1f ticks/frame)" % mean)
	# The old implementation measures ~0.17 here.
	_assert(ripple < 0.08,
		"visual velocity is steady (sd/mean %.3f < 0.08, old implementation ~0.17)" % ripple)
	_assert(float(max_advance) < mean * 1.5 and float(min_advance) > mean * 0.5,
		"no frame is wildly out of step (min %d, max %d, mean %.1f)" % [min_advance, max_advance, mean])
	editor.free()


func _test_tracks_engine_without_drift() -> void:
	var editor: Node = _make_editor()
	var seconds := 4.0
	_simulate(editor, seconds)
	var expected := int(TICKS_PER_SECOND * seconds)
	var error: int = absi(editor.playhead_ticks - expected)
	# Within a 32nd note of where the engine actually is.
	_assert(error < PPQ / 8,
		"no cumulative drift over %.0fs (off by %d ticks, < %d)" % [seconds, error, PPQ / 8])
	editor.free()


func _test_large_jump_snaps() -> void:
	var editor: Node = _make_editor()
	_simulate(editor, 1.0)

	# A loop wrap: the engine jumps far backwards. This must snap, not interpolate.
	editor._on_playhead_received([0])
	editor._process(FRAME_DELTA)
	_assert(editor.playhead_ticks < PPQ / 4,
		"backwards loop wrap snaps immediately (landed at %d)" % editor.playhead_ticks)

	# A forward seek of several bars must also snap.
	var target := PPQ * 16
	editor._on_playhead_received([target])
	editor._process(FRAME_DELTA)
	_assert(absi(editor.playhead_ticks - target) < PPQ / 4,
		"forward seek snaps immediately (landed at %d, target %d)" % [editor.playhead_ticks, target])
	editor.free()


func _test_update_while_stopped_applies_directly() -> void:
	var editor: Node = _make_editor()
	editor.is_playing = false
	editor._on_playhead_received([PPQ * 3])
	_assert(editor.playhead_ticks == PPQ * 3,
		"an update while stopped applies immediately (_process is disabled)")

	# Stop resets to 0 and must be reflected even though _process never runs.
	editor._on_playhead_received([0])
	_assert(editor.playhead_ticks == 0, "stop (tick 0) resets the playhead immediately")

	# Resuming playback from that position must not jump.
	editor.playhead_ticks = PPQ * 2
	editor._reset_playhead_interpolation(PPQ * 2)
	editor.is_playing = true
	editor._process(FRAME_DELTA)
	_assert(editor.playhead_ticks >= PPQ * 2 and editor.playhead_ticks < PPQ * 2 + 100,
		"resuming continues from the current position (at %d)" % editor.playhead_ticks)
	editor.free()
