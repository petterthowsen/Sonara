## Keeps the project theme in step with the `appearance/theme/*` settings.
##
## Builds a `ThemePalette` and `Theme` from `Settings` and merges the result into the project
## theme in memory. Every Control and Window resolves theme items on lookup, and a changed project
## theme notifies them all, so a settings change restyles the whole app, including separate device
## windows, without per-view wiring. Changes are coalesced: any number of setting changes in one
## frame cause one rebuild.
##
## Registered after `Settings` in project.godot.
extends Node

## Emitted after the project theme has been rebuilt and merged.
signal theme_applied

## The palette the current theme was built from.
var palette: ThemePalette

var _rebuild_queued := false


func _ready() -> void:
	_apply()
	Settings.setting_changed.connect(_on_setting_changed)


func _on_setting_changed(key: String, _value) -> void:
	if not key.begins_with(Settings.THEME_PREFIX) or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	_apply()


## Palette for the current settings. Missing or invalid values fall back to their defaults.
func palette_from_settings() -> ThemePalette:
	var values := {}
	for name in ThemePalette.DEFAULTS:
		values[name] = Settings.get_value(ThemePalette.PREFIX + name)
	return ThemePalette.from_settings(values)


func _apply() -> void:
	palette = palette_from_settings()
	var built := ThemeBuilder.build(palette)
	var project_theme := ThemeDB.get_project_theme()
	if project_theme != null:
		project_theme.merge_with(built)
	else:
		get_tree().root.theme = built
	RenderingServer.set_default_clear_color(palette.role(&"app_bg"))
	theme_applied.emit()
