# test_behavior_follow_settings.gd
# Headless tests for the MIDI-editor follow behavior settings:
#   arranger/record_arm_follows_midi_editor_track  (default on: selecting a track in
#       the MIDI editor record-arms it and disarms the others)
#   selection/track_follows_midi_editor_track      (default off: the arranger and
#       mixer track selection follows the MIDI editor's track selection)
# Drives the real Editor scene with a two-track project, so the wiring from
# ClipEditor's track_mode_track_selected signal through Editor's handler is
# exercised. What still needs a running editor: actual mouse clicks on the MIDI
# editor's track list and the visual arm/selection feedback.
# Run: godot --headless --path Godot -s tests/test_behavior_follow_settings.gd -- --test
extends TestBase

const KEY_ARM := "arranger/record_arm_follows_midi_editor_track"
const KEY_SELECT := "selection/track_follows_midi_editor_track"
const KEY_ARM_ACTIVE := "arranger/record_arm_follows_active_track"
const KEY_RENAMED := "selection/track_follows_midi_editor_track_list"

var _settings
var _sonara
var _project_script: GDScript


func suite_name() -> String:
	return "MIDI editor follow settings"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_test_defaults()
	_test_renamed_key_migration()
	await _test_arm_follows_midi_editor_selection()
	await _test_selection_follows_midi_editor_selection()
	await _test_arm_and_selection_together()
	_reset()


func _test_defaults() -> void:
	for pair in [[KEY_ARM, true, "Arranger"], [KEY_SELECT, false, "Selection"]]:
		var key: String = pair[0]
		var s = _settings.get_setting(key)
		_assert(s != null, "%s is registered" % key)
		_assert(s.type == _settings.Type.BOOL, "%s is a bool" % key)
		_assert(s.default == pair[1], "%s defaults to %s" % [key, pair[1]])
		_assert(s.category == _settings.CATEGORY_BEHAVIOR, "%s is a Behavior setting" % key)
		_assert(s.sub_category == pair[2], "%s sits under %s" % [key, pair[2]])
		_assert(_settings.get_value(key) == s.default, "%s reads back its default" % key)
	# The old track-list key is gone; the arm-follow setting sits beside its sibling.
	_assert(_settings.get_setting(KEY_RENAMED) == null, "the old track-list key is unregistered")
	_assert(_settings.get_setting(KEY_ARM_ACTIVE) != null, "the arranger arm-follow setting is still registered")


func _test_renamed_key_migration() -> void:
	# A stored choice under the old key is copied to the new one.
	for stored in [true, false]:
		_sonara.set_config(KEY_RENAMED, stored)
		_sonara.set_config(KEY_SELECT, null)
		_settings._migrate_renamed_keys()
		_assert(_sonara.get_config(KEY_SELECT) == stored,
			"a stored %s under the old key migrates to the new key" % stored)
	# A new key that is already set is not overwritten.
	_sonara.set_config(KEY_RENAMED, true)
	_sonara.set_config(KEY_SELECT, false)
	_settings._migrate_renamed_keys()
	_assert(_sonara.get_config(KEY_SELECT) == false, "an existing new-key value is kept")
	_sonara.set_config(KEY_RENAMED, null)


## Instantiate the real editor with a fresh two-track project. Track A is armed
## so the tests can see the arm move.
func _setup() -> Dictionary:
	var editor: Control = load("res://editor/Editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	var project: Object = _project_script.new()
	project.create_instrument_track("A")
	project.create_instrument_track("B")
	editor.open_project(project)
	await process_frame
	var a: Object = project.tracks[0]
	var b: Object = project.tracks[1]
	a.set_armed(true)
	return {"editor": editor, "project": project, "a": a, "b": b}


func _free(fx: Dictionary) -> void:
	fx.editor.close_project()
	fx.editor.queue_free()
	await process_frame


## The MIDI editor's view of a track pick: ClipEditor emits its track-selected signal.
func _midi_editor_selects(fx: Dictionary, track: Object) -> void:
	fx.editor.clip_editor.track_mode_track_selected.emit(track)


func _armed(fx: Dictionary, track: Object) -> bool:
	var ch: Object = fx.project.get_channel_by_id(track.default_channel_id)
	return track.armed and ch != null and ch.record_armed


func _test_arm_follows_midi_editor_selection() -> void:
	_settings.set_value(KEY_ARM, true)
	var fx := await _setup()
	var editor: Control = fx.editor
	var a: Object = fx.a
	var b: Object = fx.b
	_assert(_armed(fx, a) and not _armed(fx, b), "setup: only A is armed")

	_midi_editor_selects(fx, b)
	_assert(_armed(fx, b) and not _armed(fx, a), "selecting B in the MIDI editor arms B and disarms A")

	# Live off: the following stops and arms are left alone.
	_settings.set_value(KEY_ARM, false)
	_midi_editor_selects(fx, a)
	_assert(_armed(fx, b) and not _armed(fx, a), "with the setting off, a track pick leaves the arms alone")

	# Live on again: the MIDI editor's current track is armed at once.
	editor.clip_editor.midi_editor.focus_track = a
	_settings.set_value(KEY_ARM, true)
	_assert(_armed(fx, a) and not _armed(fx, b), "enabling the setting arms the MIDI editor's current track at once")
	await _free(fx)


func _test_selection_follows_midi_editor_selection() -> void:
	_settings.set_value(KEY_SELECT, false)
	var fx := await _setup()
	var editor: Control = fx.editor
	var a: Object = fx.a
	var b: Object = fx.b
	_settings.set_value(KEY_ARM, false)

	# Opening the project may pre-select a track; a pick with the setting off
	# must leave whatever selection exists untouched.
	var sel_before: Array = editor.selected_tracks.duplicate()
	var list_before: Array = editor.arranger.track_list.selected_tracks.duplicate()
	var active_before: Object = editor.arranger.track_list.active_track
	var focused_before: Object = editor.focused_track

	_midi_editor_selects(fx, b)
	_assert(editor.selected_tracks == sel_before and editor.focused_track == focused_before,
		"with the setting off, a track pick leaves the arranger selection alone")
	_assert(editor.arranger.track_list.selected_tracks == list_before
			and editor.arranger.track_list.active_track == active_before,
		"with the setting off, the arranger track list keeps its selection")

	_settings.set_value(KEY_SELECT, true)
	_midi_editor_selects(fx, b)
	_assert(editor.selected_tracks.size() == 1 and editor.selected_tracks[0] == b,
		"with the setting on, the arranger selection follows the MIDI editor")
	_assert(editor.focused_track == b, "B becomes the focused track")
	_assert(editor.arranger.track_list.selected_tracks.size() == 1
			and editor.arranger.track_list.selected_tracks[0] == b
			and editor.arranger.track_list.active_track == b,
		"the arranger track list follows as well")
	_assert(_armed(fx, a) and not _armed(fx, b),
		"the selection follow does not touch the record arm (arm-follow is off)")
	await _free(fx)


func _test_arm_and_selection_together() -> void:
	_settings.set_value(KEY_SELECT, true)
	_settings.set_value(KEY_ARM, true)
	var fx := await _setup()
	var editor: Control = fx.editor
	var a: Object = fx.a
	var b: Object = fx.b
	_assert(_armed(fx, a), "setup: A is armed")

	_midi_editor_selects(fx, b)
	_assert(_armed(fx, b) and not _armed(fx, a), "the pick arms B and disarms A")
	_assert(editor.selected_tracks.size() == 1 and editor.selected_tracks[0] == b,
		"the pick also selects B")
	await _free(fx)


func _reset() -> void:
	for key in [KEY_ARM, KEY_SELECT, KEY_ARM_ACTIVE]:
		_settings.set_value(key, _settings.get_setting(key).default)
