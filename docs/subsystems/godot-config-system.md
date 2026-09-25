# Godot Config System

## Overview
- `Godot/Sonara.gd` is the autoload that owns global settings, project directory setup, and access helpers for Sonara UI code.
- Configuration is stored as JSON at `~/.config/sonara/config.json`; the autoload caches the parsed dictionary and exposes helper APIs.
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
- Settings that the engine applies live have a model that listens to `Settings.setting_changed` and sends the OSC: `data/PluginHosting.gd` (`plugins/hosting_mode`) and the `AudioConfig` autoload (`audio/output_device`, `audio/sample_rate`, `audio/buffer_size`, with the custom control `settings/AudioSettingControl.tscn` filled from the engine's device list).

## Config Access (unregistered internal state)
- Use `Sonara.get_config("section/key", default_value)` to read settings. Slash notation walks nested dictionaries and falls back to the provided default on missing keys.
- Use `Sonara.set_config("section/key", value)` to write settings. It auto-creates intermediate dictionaries; there is no need to pre-check for existence.
- Avoid reaching into `Sonara.config` directly; the getter ensures the cache is hydrated and centralizes future validation.

## Persistence Rules
- After modifying raw config, call `Sonara.save_config()` (`Settings.set_value` already does this) to write `config.json`. The method handles JSON serialization, logging, and error reporting.
- Never write to `config.json` (or other Sonara config files) manually; keep disk I/O inside the autoload to maintain consistent format and messaging.
- For read-heavy systems, pull config values during initialization and cache them locally rather than invoking `get_config` every frame.

## Directory Helpers
- `Sonara.get_config_dir()` returns `~/.config/sonara`; `get_config_path()` resolves the `config.json` file. Both values are memoized—reuse them instead of rebuilding paths.
- `Sonara.get_projects_dir()` defaults to `~/Documents/Sonara` and is created on startup. Callers should respect this default unless user-configurable paths are introduced.
- The autoload’s `_ensure_config_dir()` and `_ensure_projects_dir()` already run during `_ready()`. Avoid duplicating directory-creation logic elsewhere.

## Related Files
- `Godot/browser/AssetService.gd` and `Godot/data/DeviceRegistry.gd` store auxiliary JSON caches (e.g., `assets.json`, `plugins.json`) under the same config directory. Use the autoload helpers to resolve paths for any additional caches to keep layout consistent.
