## Writes the default theme to `assets/Sonara_Theme.tres`, so the Godot editor previews the same
## look the app has with default settings. The file is generated output: change `ThemeBuilder` or
## `ThemePalette`, then run this again (`test_theme_resource_fresh.gd` fails when it is stale):
##
##   godot --headless --path Godot -s core/theme/build_theme_resource.gd
extends SceneTree

const OUTPUT := "res://assets/Sonara_Theme.tres"
## project.godot refers to the theme by this id (`gui/theme/custom`), so it has to survive a rewrite.
const UID := "uid://c77m063o570pp"


func _init() -> void:
	var theme := ThemeBuilder.build(ThemePalette.from_settings({}))
	var err := ResourceSaver.save(theme, OUTPUT)
	if err != OK:
		push_error("build_theme_resource: saving %s failed (%s)" % [OUTPUT, error_string(err)])
	else:
		err = ResourceSaver.set_uid(OUTPUT, ResourceUID.text_to_id(UID))
		if err != OK:
			push_error("build_theme_resource: restoring %s failed (%s)" % [UID, error_string(err)])
		else:
			print("build_theme_resource: wrote ", OUTPUT)
	quit(err)
