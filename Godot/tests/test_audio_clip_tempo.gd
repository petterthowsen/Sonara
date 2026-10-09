# test_audio_clip_tempo.gd
# An imported audio clip takes the project tempo at the drop position as its own tempo, and its
# length follows that clip tempo rather than the current project tempo.
#
# Run: godot --headless --path Godot -s tests/test_audio_clip_tempo.gd -- --test
extends TestBase

const DURATION_S := 2.0
const SAMPLE_RATE := 48000


func suite_name() -> String:
	return "Audio clip tempo"


func run_tests() -> void:
	var project_script: GDScript = load("res://data/Project.gd")
	var asset_script: GDScript = load("res://browser/Asset.gd")
	_test_import_takes_project_tempo(project_script, asset_script)
	_test_length_ignores_later_project_tempo(project_script, asset_script)
	_test_set_recorded_bpm()


func _import(project, asset_script: GDScript, drop_tick: int = 0):
	var asset = asset_script.new()
	asset.name = "loop.wav"
	asset.path = "/tmp/loop.wav"
	var clip = project.create_clip_from_asset(asset, Color.WHITE, drop_tick)
	clip.set_audio_metadata(SAMPLE_RATE, 2, int(DURATION_S * SAMPLE_RATE), DURATION_S)
	clip.update_content_length_from_metadata(project.tempo, project.ppq)
	return clip


func _test_import_takes_project_tempo(project_script: GDScript, asset_script: GDScript) -> void:
	var project = project_script.new()
	project.tempo = 140.0
	var clip = _import(project, asset_script)
	_assert(is_equal_approx(clip.recorded_bpm, 140.0), "clip tempo is the project tempo at import (%s)" % clip.recorded_bpm)
	var expected := int(DURATION_S * 140.0 / 60.0 * 960.0)
	_assert(clip.content_length_ticks == expected, "length is duration x 140/60 x 960: %d vs %d" % [clip.content_length_ticks, expected])


func _test_length_ignores_later_project_tempo(project_script: GDScript, asset_script: GDScript) -> void:
	var project = project_script.new()
	project.tempo = 90.0
	var clip = _import(project, asset_script)
	var length: int = clip.content_length_ticks
	project.tempo = 140.0
	clip.update_content_length_from_metadata(project.tempo, project.ppq)
	_assert(clip.content_length_ticks == length, "length unchanged after the project tempo changes")
	_assert(is_equal_approx(clip.recorded_bpm, 90.0), "clip tempo unchanged after the project tempo changes")


func _test_set_recorded_bpm() -> void:
	# Named through the loaded script: a bare `Clip` would compile before the autoloads exist
	var clip = load("res://data/Clip.gd").new("c")
	clip.type = 0  # Clip.ClipType.AUDIO
	var fired := [0]
	clip.clip_modified.connect(func(): fired[0] += 1)
	clip.set_recorded_bpm(100.0)
	_assert(is_equal_approx(clip.recorded_bpm, 100.0) and fired[0] == 1, "set_recorded_bpm stores the value and emits clip_modified")
	clip.set_recorded_bpm(100.0)
	clip.set_recorded_bpm(-5.0)
	_assert(fired[0] == 1 and is_equal_approx(clip.recorded_bpm, 100.0), "same or invalid tempo is ignored")
