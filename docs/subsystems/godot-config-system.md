# Godot Config System

## Overview
- `Godot/Sonara.gd` is the autoload that owns global settings, project directory setup, and access helpers for Sonara UI code.
- Configuration is stored as JSON at `$XDG_CONFIG_HOME/sonara/config.json` (default `~/.config/sonara/config.json`); the autoload caches the parsed dictionary and exposes helper APIs.
- `Godot/settings/Settings.gd` (autoload `Settings`) is a registry layered on top. Each layer calls only the one below it:
  1. **Config (storage):** `Sonara.get_config` / `set_config` / `save_config`. A plain JSON key-value store; knows nothing about defaults, types or meaning. It must never call into Settings.
  2. **Settings (registry):** every user-facing key is declared once in `_register_all_settings()` with its default, type and constraints. This is the only place defaults live.
  3. **Consumers:** user preferences always go through `Settings.get_value(key)` / `Settings.set_value(key, value)`. Only internal, unregistered UI state (dock layout, browser state, disabled MIDI device names) uses `Sonara.get/set_config` directly.

## Settings Access
- `Settings.get_value(key)` reads config and falls back to the registered default. Don't pass or duplicate defaults at call sites.
- `Settings.set_value(key, value)` coerces/clamps the value to the setting's type, writes it, saves `config.json`, and emits `setting_changed(key, value)`.
- Keep local cached copies in sync by connecting to `Settings.setting_changed` instead of updating them alongside the write.
- To add a setting: register it in `Settings.gd` (it then appears in the Settings dialog by category). To rename a key, add it to `_RENAMED_KEYS` so existing values migrate.
- `Settings` is registered before other consumer autoloads in `project.godot` and builds its registry in `_init`.
- Settings that the engine applies live have a model that listens to `Settings.setting_changed` and sends the OSC: `data/Metronome.gd` (the eight `metronome/*` settings, Audio › Metronome, sent as `/metronome/sound` and `/metronome/enabled`; spec 053, with its patterns saved in the project), `data/PluginHosting.gd` (`plugins/hosting_mode`) and the `AudioConfig` autoload (`audio/output_device`, `audio/sample_rate`, `audio/buffer_size`, with the custom control `settings/AudioSettingControl.tscn` filled from the engine's device list). `audio/processing_threads` (CHOICE `Auto`, `1`..cores; Audio › Performance) is also sent by `AudioConfig`, as `/engine/threads/set` (Auto = 0) on change and on `engine_connected`, never through `/audio/config/set`.

## Default folders
- `presets/path` defaults to `Settings.default_presets_path()` = `AppPaths.presets_dir()` (`<Documents>/Sonara/presets`), next to the projects folder. A saved config value always overrides the default. `Settings.migrate_presets_dir()` runs once at startup (`migrations/presets_dir`) for configs without a saved `presets/path`: it renames the old lowercase `~/Documents/sonara/presets` into place if the new folder is absent, otherwise pins `presets/path` to the old folder so no presets are hidden.

## Shortcuts
- Keyboard shortcuts are settings too: `Settings` registers one `shortcuts/<action id>` setting (type `SHORTCUT`, an array of at most two chord strings such as `["Ctrl+D"]`) for every row in `HotkeyActions.ACTIONS`. Defaults live only in that table, never in `project.godot`.
- The `Hotkeys` autoload applies the stored chords to `InputMap` and re-applies them on `setting_changed`. Handlers match with `Hotkeys.pressed(event, "<id>")`, never with `KEY_*` checks or Godot's `ui_*` actions. Matching is exact, so Space does not match Shift+Space.
- To add an action: add one row to `HotkeyActions.ACTIONS` (id, label, group, context, defaults) and call `Hotkeys.pressed` in the handler. It then appears in Settings › Shortcuts with no other work.
- The row control is `settings/ShortcutControl.tscn`: click to capture (Escape cancels, right-click clears), conflict warnings with "Unbind there", and one read-only line per double tap. Cancel in the dialog restores bindings through the normal snapshot. "Reset all shortcuts" calls `Settings.reset_shortcuts()`.
- Search matches the bound chords, so typing `ctrl+d` finds Duplicate.
- Design record: `docs/adr/0017-hotkey-registry.md`.

## Theme
- `Settings.Type.COLOR` stores a colour as an `"#rrggbb"` string (no alpha). `_coerce` accepts a `Color` or a string; an invalid value warns and returns the default. The row widget is a `ColorPickerButton`.
- The theme settings are `appearance/theme/*`: `main_color`, `accent_primary`, `accent_secondary`, `record_color`, `solo_color`, `mute_color`, `corner_radius` (0-4) and `spacing` (1-4). The palette clamps the main colour's brightness so panels stay dark.
- The `UiTheme` autoload listens to `setting_changed` for that prefix and rebuilds the theme once per frame, so everything (including device windows) updates live. `Settings.reset_theme()` restores all eight keys; the Appearance page has a "Reset theme" button for it.
- Details: `godot-ui-components.md` §5 and `docs/adr/0018-theme-generated-from-settings.md`.

## UI scale
- `appearance/ui_scale` (CHOICE: `Auto`, `75%`, `100%`, `125%`, `150%`, `175%`, `200%`; default `Auto`). The `UiScale` autoload (`core/UiScale.gd`, registered after `Settings`) turns it into a factor (`Auto` = `DisplayServer.screen_get_scale()`, which is real only on Wayland and macOS and 1.0 on X11) and sets `Window.content_scale_factor` on the main window, on `FrameWindow`s, and on any other `force_native` window as it enters the tree. Embedded dialogs and popups scale with the main window. It re-applies on `setting_changed` and emits `scale_changed(factor)`. Headless test runs always use 1.0.
- `Window.min_size` and native window sizes are in pixels, not content units: multiply a layout minimum with `UiScale.scaled(Vector2i)` and refresh it on `scale_changed` (`Editor` does this for `MIN_WINDOW_SIZE`, `FrameWindow` for its frame's minimum).

## Window geometry
- Internal state, not a registered setting: `window/main` in `config.json` = `{screen, mode: "windowed"|"maximized", position: [x, y], size: [w, h]}`. `position` and `size` are the last windowed rectangle in pixels. `WindowGeometry` (`core/WindowGeometry.gd`, a child of `Editor`) restores it in `_ready`, samples the window every second, writes only when it changed (every 10 s, for crash safety) and once in `Editor.quit()`. Restore clamps to a connected screen (the screen under the saved centre, else the saved screen, else the primary one, centred) and skips position on Wayland, where clients cannot place windows. Disabled in test mode and when embedded in the Godot editor.
- Floating device frame windows remember their rect only in memory (`FrameWindow.last_rect`); it is not saved across launches.

## Config Access (unregistered internal state)
- Use `Sonara.get_config("section/key", default_value)` to read settings. Slash notation walks nested dictionaries and falls back to the provided default on missing keys.
- Use `Sonara.set_config("section/key", value)` to write settings. It auto-creates intermediate dictionaries; there is no need to pre-check for existence.
- Avoid reaching into `Sonara.config` directly; the getter ensures the cache is hydrated and centralizes future validation.

## Persistence Rules
- After modifying raw config, call `Sonara.save_config()` (`Settings.set_value` already does this) to write `config.json`. The method handles JSON serialization, logging, and error reporting.
- Never write to `config.json` (or other Sonara config files) manually; keep disk I/O inside the autoload to maintain consistent format and messaging.
- For read-heavy systems, pull config values during initialization and cache them locally rather than invoking `get_config` every frame.

## Directory Helpers
`AppPaths` (`Godot/core/AppPaths.gd`, spec 046) is the one place that knows the folder layout. It is a static class with no autoload dependency, because `Log._static_init()` runs before any autoload. Tests set `AppPaths.env_override` (`HOME`, `XDG_*`, and `DOCUMENTS`) instead of touching the real environment.

| Kind | Location | Getter |
|---|---|---|
| User content | `<Documents>/Sonara/{projects,presets,note_maps}` (`<Documents>` = the desktop's XDG documents dir, fallback `~/Documents`) | `projects_dir()`, `presets_dir()`, `note_maps_dir()` |
| Settings and internal state (`config.json`, `assets.json`, `plugins.json`, `device_layouts/`, `startup.sonara`, `aichat/`) | `$XDG_CONFIG_HOME/sonara` (default `~/.config/sonara`) | `config_dir()` |
| Regenerable data (`*_cache.json` asset scans, `aichat/tmp`) | `$XDG_CACHE_HOME/sonara` (default `~/.cache/sonara`) | `cache_dir()` |
| Logs | `$XDG_STATE_HOME/sonara/logs/{ui,engine}` (default `~/.local/state/sonara/logs`) | `log_dir()`, `ui_log_dir()`, `engine_log_dir()` |
| Single-instance PID file | `$XDG_RUNTIME_DIR/sonara/ui.pid` | `runtime_dir()` |

- `Sonara.get_config_dir()` and `Sonara.get_projects_dir()` are thin wrappers over `AppPaths.config_dir()` and `projects_dir()`; `get_config_path()` resolves `config.json`. Never hard-code `~/.config`, `~/Documents` or `logs/` elsewhere.
- Old pre-beta files are moved by hand, there is no migration code (spec 046 design, "Migration").
- The autoload’s `_ensure_config_dir()` and `_ensure_projects_dir()` already run during `_ready()`. Avoid duplicating directory-creation logic elsewhere.
- `BuildInfo` (`core/BuildInfo.gd`) holds the version, commit, release channel and install folder; `EngineProcess` (autoload) starts, attaches to and stops the engine.

## Related Files
- `Godot/browser/AssetService.gd` and `Godot/data/DeviceRegistry.gd` store auxiliary JSON state (e.g., `assets.json`, `plugins.json`) under the same config directory; the rebuildable scan caches (`samples_cache.json`, `sfz_cache.json`, `preset_cache.json`) live in the cache directory. Use the autoload helpers to resolve paths for any additional caches to keep layout consistent.
