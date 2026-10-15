# test_presets_default_path.gd
# The presets folder defaults to <Documents>/Sonara/presets (#134) and Settings.migrate_presets_dir
# moves or pins the old lowercase folder without losing presets. Uses temp directories only.
# Run: godot --headless --path Godot -s tests/test_presets_default_path.gd -- --test
extends TestBase

var _settings


func suite_name() -> String:
	return "Presets default path tests"


func _fresh_root(tag: String) -> String:
	var dir := OS.get_cache_dir().path_join("sonara_test_presets_%s_%d" % [tag, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _remove_tree(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


## Remove the saved key entirely (set_config(null) would store a null, hiding the default).
func _clear(sonara) -> void:
	if sonara.config.get("presets") is Dictionary:
		sonara.config["presets"].erase("path")


func run_tests() -> void:
	_settings = root.get_node("Settings")
	var sonara = root.get_node("Sonara")
	var saved = sonara.get_config("presets/path")
	_clear(sonara)

	_assert(_settings.get_value("presets/path") == AppPaths.presets_dir() and AppPaths.presets_dir().ends_with("/Sonara/presets"), "the default is <Documents>/Sonara/presets (AppPaths)")

	# Old folder only: renamed into place.
	var a := _fresh_root("move")
	_write(a + "/old/presets/Synth/Lead.sonpreset", "lead")
	_assert(_settings.migrate_presets_dir(a + "/old/presets", a + "/new/presets") == "moved", "old-only is moved")
	_assert(_read(a + "/new/presets/Synth/Lead.sonpreset") == "lead", "the preset arrives in the new folder")
	_assert(not DirAccess.dir_exists_absolute(a + "/old/presets"), "the old folder is gone after the move")
	_assert(sonara.get_config("presets/path") == null, "a move leaves the default in effect")

	# Both exist: nothing moved, setting pinned to the old folder.
	var b := _fresh_root("both")
	_write(b + "/old/presets/Synth/A.sonpreset", "a")
	_write(b + "/new/presets/Synth/B.sonpreset", "b")
	_assert(_settings.migrate_presets_dir(b + "/old/presets", b + "/new/presets") == "pinned", "both existing pins the old path")
	_assert(sonara.get_config("presets/path") == b + "/old/presets", "presets/path now points at the old folder")
	_assert(_read(b + "/old/presets/Synth/A.sonpreset") == "a" and _read(b + "/new/presets/Synth/B.sonpreset") == "b", "no file is touched")

	# A saved value is never touched.
	var c := _fresh_root("saved")
	_write(c + "/old/presets/x.sonpreset", "x")
	sonara.set_config("presets/path", "/somewhere/else")
	_assert(_settings.migrate_presets_dir(c + "/old/presets", c + "/new/presets") == "", "a saved path skips migration")
	_assert(sonara.get_config("presets/path") == "/somewhere/else", "the saved path is kept")
	_assert(DirAccess.dir_exists_absolute(c + "/old/presets"), "the old folder is untouched")

	# Nothing to migrate.
	_clear(sonara)
	var d := _fresh_root("none")
	_assert(_settings.migrate_presets_dir(d + "/old/presets", d + "/new/presets") == "", "no old folder does nothing")

	_clear(sonara)
	if saved != null:
		sonara.set_config("presets/path", saved)
	for r in [a, b, c, d]:
		_remove_tree(r)
