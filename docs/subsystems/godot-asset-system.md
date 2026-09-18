# Godot Asset System

## Overview
- Asset discovery is provider-based: each `AssetProvider` subclasses `AssetProvider.gd`, emits `assets_changed`, and stays free of UI concerns.
- `AssetService.gd` is the sole entry point; it initializes providers at startup, runs scans, merges results, and broadcasts updates to consumers.
- Providers: `FileSystemAssetProvider` (audio/MIDI files) and `SfzAssetProvider` (SFZ instruments), both on `FileScanAssetProvider`, plus `DeviceAssetProvider` (built-in and plugin devices from `DeviceRegistry`).

## Asset & Provider Contracts
- `Asset.gd` wraps identity plus metadata (favorite, tags, last_used, size, modified time) and exposes helpers (`get_display_name`, type guards: `is_audio`, `is_midi`, `is_sfz`, `is_soundfont`).
- Asset types: `Audio` (audio files), `Midi` (MIDI files), `Device` (plugins/instruments), `SFZ` (SFZ instruments), `SoundFont` (SF2/SF3 instruments).
- Providers must populate `Asset.path` with an absolute file path or canonical device ID; `AssetService` keys on this value.
- Change detection flows through the `assets_changed(added, removed, modified)` signal; AssetService reloads metadata and rebroadcasts.

## AssetService Autoload
- Reads `Settings` for enabled providers and scan paths, then calls `initialize(SceneTree)` on each provider.
- Providers emit cached assets during `initialize()` so `_assets_by_path` is populated via `assets_changed` callbacks before any live scan.
- **No automatic scan on startup** – relies on hot-reload timers for first scan (after `scan_interval_seconds`). Users can manually trigger via Edit → Scan Assets.
- `scan()` clears the registry, invokes `provider.scan()`, and consolidates every provider's `get_assets()` result into `_assets_by_path`.
- Metadata cache lives in `~/.config/sonara/assets.json`; the service loads it on startup, applies it to Assets, and persists on every write.
- `get_device(id)` and `scan_plugins()` delegate to `device_registry` (created even when the `devices` provider is disabled, so projects still load their devices).
- `search_assets(query, type, limit)` (used by the AI) and the Browser search box both score with `AssetSearch`. The AI variant also accepts a substring hit on the path.

## FileScanAssetProvider (FileSystemAssetProvider, SfzAssetProvider)
- Subclasses only override `_scan_paths_setting()`, `_cache_file_name()` and `_asset_type_for_extension()`.
- Walks the directories from the setting (`Utils.expand_path` expands `~/` and `$HOME/`) every `assets/scan_interval_seconds`, chaining `SceneTree.create_timer()` so `_ready()` never blocks.
- Diffs against the previous scan by path (Dictionary lookups) and mtime, emits one `assets_changed`, and rewrites the cache only when something changed.
- Caches: `samples_cache.json` (`wav`, `mp3`, `ogg`, `mid`, `midi` from `assets/samples/paths`) and `sfz_cache.json` (`.sfz` from `assets/sfz/paths`). Cached entries are re-typed from their extension on load.
- SFZ files are loaded into the built-in sfizz device via `DeviceDropUtil` (queued `DeviceInstance` file load).

## DeviceRegistry and DeviceAssetProvider
- `DeviceRegistry.start()` loads `plugins.json`, registers OSC listeners and sends `/builtin/request`. It re-requests built-ins on `AudioEngineOSC.engine_connected`.
- `/builtin/info` payloads carry audio/MIDI capabilities, typed parameter descriptors (`param_type`, `syncable`, enum labels, range) and file-loading support. Each registers a `Device` and emits `device_registered`; `/builtin/complete` emits one `devices_changed` batch.
- `is_logarithmic` is still guessed from the parameter name (time, cutoff, frequency, speed) until the engine advertises it.
- `/plugin/info` gives `[id, name, vendor, version, category, description, path]`. `scan_plugins()` drops cached plugins (emitting them as removed) and sends `/plugin/scan`; `/plugin/scan_complete` emits the plugins as added and saves `plugins.json`.
- `DeviceAssetProvider` only maps registry devices to `Asset`s and forwards `devices_changed` as `assets_changed`. AssetService connects the provider before starting the registry so cached plugins reach the browser.

## Metadata Cache
- `AssetService` writes all user metadata (favorite, tags, last_used) to `assets.json` under the same config directory as the plugin cache.
- On provider change events, metadata is re-applied before signals propagate, so UI listeners always receive hydrated assets.
- Providers should avoid duplicating persistence logic; any additional metadata must route through AssetService to keep the cache consistent.
