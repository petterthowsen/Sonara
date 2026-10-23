# Metronome model (spec 053 T-009): grid helpers, per-signature patterns, JSON round trip, undo
# snapshots, settings defaults and persistence, engine sync and the audition rate limit.
# Headless the OSC client never becomes ready, so sends queue in AudioEngineOSC._pending_sends.
# Run: godot --headless --path Godot -s tests/test_metronome_model.gd -- --test
extends TestBase

var _settings: Node
var _osc: Node
var _project_script: GDScript
var _m: GDScript


func suite_name() -> String:
	return "Metronome model"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_project_script = load("res://data/Project.gd")
	_m = load("res://data/Metronome.gd")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_test_grid_helpers()
	_test_allowed_resolutions()
	_test_default_pattern()
	_test_signature_isolation()
	_test_resolution_conversion()
	_test_json_round_trip()
	_test_state_undo()
	_test_settings_defaults()
	_test_settings_persistence()
	_test_sync_messages()
	_test_project_integration()
	_test_audition_rate_limit()
	_reset_settings()


func _test_grid_helpers() -> void:
	_assert(_m.step_count(4, 4, 8) == 8, "4/4 at 1/8 has 8 steps")
	_assert(_m.group_size(4, 8) == 2, "4/4 at 1/8 groups of 2 (4 groups)")
	_assert(_m.step_count(7, 8, 8) == 7 and _m.group_size(8, 8) == 1, "7/8 at 1/8 has 7 steps")
	_assert(_m.step_count(6, 8, 16) == 12 and _m.group_size(8, 16) == 2, "6/8 at 1/16 has 12 steps in groups of 2")
	_assert(_m.step_count(3, 8, 4) == 0, "3/8 at 1/4 is not a whole step count")
	_assert(_m.step_count(5, 2, 4) == 10, "5/2 at 1/4 has 10 steps")


func _test_allowed_resolutions() -> void:
	_assert(_m.allowed_resolutions(7, 8) == [8, 16], "7/8 offers 1/8 and 1/16 only")
	_assert(_m.allowed_resolutions(4, 4) == [4, 8, 16], "4/4 offers 1/4, 1/8 and 1/16")
	_assert(_m.allowed_resolutions(3, 16) == [16], "3/16 offers only 1/16")
	_assert(_m.allowed_resolutions(3, 32).is_empty(), "x/32 offers nothing (engine takes 4, 8, 16)")
	_assert(_m.allowed_resolutions(32, 1) == [4], "32/1 is capped at the engine's 128 steps")
	var model = _m.new()
	_assert(not model.is_editable(3, 32), "x/32 is not editable")
	model.set_step(3, 32, 0, 3)
	_assert(not model.has_edits(), "editing x/32 is ignored")


func _test_default_pattern() -> void:
	_assert(_m.default_levels(4, 4) == [4, 2, 2, 2], "4/4 default is [4, 2, 2, 2]")
	_assert(_m.default_levels(6, 8) == [4, 2, 2, 2, 2, 2], "6/8 default is [4, 2, 2, 2, 2, 2]")
	_assert(_m.default_levels(2, 2) == [4, 0, 2, 0], "2/2 default is 1/4 with beat starts")
	_assert(_m.default_resolution(2) == 4 and _m.default_resolution(8) == 8, "default resolution is the beat, at least 1/4")
	var model = _m.new()
	_assert(model.levels_of(4, 4) == [4, 2, 2, 2] and model.resolution_of(4, 4) == 4, "an unedited signature reads as the default")


func _test_signature_isolation() -> void:
	var model = _m.new()
	var emitted = [0]
	model.changed.connect(func(): emitted[0] += 1)
	model.set_step(4, 4, 1, 3)
	_assert(emitted[0] == 1, "a step edit emits changed once")
	_assert(model.levels_of(4, 4) == [4, 3, 2, 2], "setting step 2 to level 3 updates 4/4")
	_assert(model.levels_of(3, 4) == _m.default_levels(3, 4), "3/4 stays at the default")
	_assert(model.is_edited(4, 4) and not model.is_edited(3, 4), "only 4/4 is stored")
	model.set_step(4, 4, 99, 3)
	model.set_step(4, 4, 0, 9)
	_assert(model.levels_of(4, 4) == [4, 3, 2, 2] or model.levels_of(4, 4)[0] == 4, "a bad index is ignored and a level clamps")
	model.reset_pattern(4, 4)
	_assert(not model.has_edits() and model.levels_of(4, 4) == _m.default_levels(4, 4), "Reset restores the default")


func _test_resolution_conversion() -> void:
	var model = _m.new()
	model.set_step(4, 4, 1, 3)
	model.set_resolution(4, 4, 8)
	_assert(model.resolution_of(4, 4) == 8 and model.levels_of(4, 4) == [4, 0, 3, 0, 2, 0, 2, 0],
			"finer resolution keeps the levels on their beats")
	model.set_resolution(4, 4, 4)
	_assert(model.levels_of(4, 4) == [4, 3, 2, 2], "converting back loses nothing")
	model.set_resolution(7, 8, 4)
	_assert(not model.is_edited(7, 8), "a resolution that is not offered is ignored")
	model.set_resolution(7, 8, 16)
	_assert(model.resolution_of(7, 8) == 16 and model.levels_of(7, 8).size() == 14, "7/8 at 1/16 has 14 steps")


func _test_json_round_trip() -> void:
	var model = _m.new()
	_assert(not model.has_edits(), "a new model has no edits")
	model.set_step(4, 4, 1, 3)
	model.set_resolution(7, 8, 8)
	model.set_step(7, 8, 3, 4)
	var data: Dictionary = JSON.parse_string(JSON.stringify(model.to_json()))
	var loaded = _m.from_json(data)
	_assert(loaded.to_json() == model.to_json(), "to_json / from_json round trip")
	_assert(loaded.levels_of(7, 8) == model.levels_of(7, 8) and loaded.resolution_of(4, 4) == 4, "4/4 and 7/8 patterns restored")
	_assert(_m.from_json({"patterns": {"4/4": {"resolution": 8, "levels": [1, 2]}}}).has_edits() == false,
			"a pattern with the wrong step count is dropped")
	_assert(_m.from_json({"patterns": {"4/4": {"resolution": 4, "levels": [9, 1, 1, 1]}}}).levels_of(4, 4)[0] == 4,
			"a level above 4 is clamped")
	_assert(not _m.from_json({}).has_edits(), "an old project (no metronome block) has no edits")


func _test_state_undo() -> void:
	var model = _m.new()
	var before = model.get_state()
	model.set_step(4, 4, 2, 1)
	var after = model.get_state()
	model.set_state(before)
	_assert(not model.has_edits() and model.levels_of(4, 4)[2] == 2, "undo of a step edit restores the previous level")
	model.set_state(after)
	_assert(model.levels_of(4, 4)[2] == 1, "redo restores the edit")
	var snapshot = model.get_state()
	model.set_step(4, 4, 2, 4)
	_assert(snapshot["patterns"]["4/4"]["levels"][2] == 1, "a snapshot is a copy")


func _test_settings_defaults() -> void:
	var expected = {
		"metronome/enabled": false, "metronome/sound": 0, "metronome/tune": 1000.0,
		"metronome/decay": 0.06, "metronome/tone": 0.5, "metronome/level": -6.0,
		"metronome/emphasis_volume": 12.0, "metronome/emphasis_pitch": 7.0,
	}
	for key in expected:
		var s = _settings.get_setting(key)
		_assert(s != null, "%s is registered" % key)
		if s == null:
			continue
		_assert(s.default == expected[key], "%s defaults to %s" % [key, expected[key]])
		_assert(s.category == _settings.CATEGORY_AUDIO and s.sub_category == "Metronome", "%s is Audio / Metronome" % key)
	_assert(_settings.get_setting("metronome/tune").min_val == 200.0 and _settings.get_setting("metronome/tune").max_val == 4000.0, "tune range")
	_assert(_settings.get_setting("metronome/level").min_val == -60.0 and _settings.get_setting("metronome/level").max_val == 6.0, "level range")


func _test_settings_persistence() -> void:
	var model = _m.new()
	var keys: Array = []
	model.setting_changed.connect(func(key): keys.append(key))
	model.set_enabled(true)
	model.set_param(_m.KEY_SOUND, 1)
	model.set_param(_m.KEY_TUNE, 2000.0)
	model.set_param(_m.KEY_TUNE, 99999.0)
	_assert(model.is_enabled(), "enabled is stored")
	_assert(model.get_param(_m.KEY_SOUND) == 1, "sound is stored")
	_assert(model.get_param(_m.KEY_TUNE) == 4000.0, "tune is clamped to its range")
	_assert(keys == ["metronome/enabled", "metronome/sound", "metronome/tune", "metronome/tune"], "setting_changed per change: %s" % [keys])
	# A second model (a new project) reads the same values: settings are global.
	var other = _m.new()
	_assert(other.is_enabled() and other.sound_args() == [1, 4000.0, 0.06, 0.5, -6.0, 12.0, 7.0], "another model sees the same settings")
	model.set_param("metronome/nonsense", 1)
	_assert(keys.size() == 4, "unknown keys are ignored")
	_reset_settings()


func _test_sync_messages() -> void:
	var model = _m.new()
	var messages = model.sync_messages()
	_assert(messages.size() == 3 and messages[0][0] == "/metronome/clear" and messages[1][0] == "/metronome/sound"
			and messages[2][0] == "/metronome/enabled", "an unedited model syncs clear, sound, enabled")
	model.set_step(7, 8, 0, 3)
	model.set_step(4, 4, 1, 3)
	messages = model.sync_messages()
	var addresses: Array = messages.map(func(m): return m[0])
	_assert(addresses == ["/metronome/clear", "/metronome/pattern", "/metronome/pattern", "/metronome/sound", "/metronome/enabled"],
			"order: clear, every pattern, sound, enabled")
	_assert(messages[1][1] == [4, 4, 4, 4, 3, 2, 2], "4/4 pattern args: num, den, resolution, levels: %s" % [messages[1][1]])
	_assert(messages[2][1][0] == 7 and messages[2][1][1] == 8 and messages[2][1][2] == 8 and messages[2][1].size() == 10, "7/8 pattern args")
	_assert(messages[3][1] == [0, 1000.0, 0.06, 0.5, -6.0, 12.0, 7.0], "sound args: sound, tune, decay, tone, level, emphasis volume, pitch")
	_assert(messages[4][1] == [0], "enabled arg")
	_osc._pending_sends.clear()
	model.sync_to_engine()
	_assert(_osc._pending_sends.size() == 5 and _osc._pending_sends[0].address == "/metronome/clear",
			"sync_to_engine sends the list")


func _test_project_integration() -> void:
	var project: Object = _project_script.new()
	_assert(not project.to_json().has("metronome"), "a project with no edited pattern saves no metronome block")
	project.metronome.set_step(4, 4, 1, 3)
	project.metronome.set_resolution(7, 8, 8)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	_assert(data.has("metronome"), "an edited project saves its metronome block")
	var loaded: Object = _project_script.from_json(data)
	_assert(loaded.metronome.to_json() == project.metronome.to_json(), "patterns restored on load")
	# Edits send only while connected.
	_osc._pending_sends.clear()
	loaded.metronome.set_step(4, 4, 2, 4)
	_assert(_osc._pending_sends.is_empty(), "no send while disconnected")
	loaded._connection_state = loaded.ConnectionState.CONNECTED
	loaded.metronome.set_step(4, 4, 3, 4)
	_assert(_osc._pending_sends.size() == 1 and _osc._pending_sends[0].address == "/metronome/pattern"
			and _osc._pending_sends[0].args == [4, 4, 4, 4, 3, 4, 4], "an edit sends the whole pattern while connected")
	_osc._pending_sends.clear()
	loaded.metronome.reset_pattern(4, 4)
	_assert(_osc._pending_sends.size() == 1 and _osc._pending_sends[0].args == [4, 4, 4], "Reset sends the pattern with no levels (removes it)")
	_osc._pending_sends.clear()
	loaded.metronome.set_enabled(true)
	_assert(_osc._pending_sends.size() == 1 and _osc._pending_sends[0].address == "/metronome/enabled" and _osc._pending_sends[0].args == [1],
			"enabling sends /metronome/enabled")
	_osc._pending_sends.clear()
	loaded.metronome.set_param(_m.KEY_LEVEL, -12.0)
	_assert(_osc._pending_sends.size() == 1 and _osc._pending_sends[0].address == "/metronome/sound", "a knob change sends /metronome/sound")
	loaded._connection_state = loaded.ConnectionState.DISCONNECTED
	_reset_settings()


func _test_audition_rate_limit() -> void:
	var model = _m.new()
	_assert(model.audition(3, 1000), "the first preview is allowed")
	_assert(not model.audition(3, 1100), "a second one within 150 ms is dropped")
	_assert(model.audition(3, 1150), "one 150 ms later is allowed")
	_assert(model.audition(9, 2000), "an out-of-range level is clamped, not refused")


func _reset_settings() -> void:
	for key in ["metronome/enabled", "metronome/sound", "metronome/tune", "metronome/decay", "metronome/tone",
			"metronome/level", "metronome/emphasis_volume", "metronome/emphasis_pitch"]:
		_settings.set_value(key, _settings.get_setting(key).default)
