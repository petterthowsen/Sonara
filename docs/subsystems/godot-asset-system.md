# Godot Asset System

## Overview
- Asset discovery is provider-based: each `AssetProvider` subclasses `AssetProvider.gd`, emits `assets_changed`, and stays free of UI concerns.
- `AssetService.gd` is the sole entry point; it initializes providers at startup, runs scans, merges results, and broadcasts updates to consumers.
- Providers: `FileSystemAssetProvider` (audio/MIDI files) and `SfzAssetProvider` (SFZ instruments), both on `FileScanAssetProvider`, plus `DeviceAssetProvider` (built-in and plugin devices from `DeviceRegistry`) and `PresetAssetProvider` (device presets, see below).

## Asset & Provider Contracts
- `Asset.gd` wraps identity plus metadata (favorite, tags, last_used, size, modified time) and exposes helpers (`get_display_name`, type guards: `is_audio`, `is_midi`, `is_sfz`, `is_soundfont`).
- Asset types: `Audio` (audio files), `Midi` (MIDI files), `Device` (plugins/instruments), `SFZ` (SFZ instruments), `SoundFont` (SF2/SF3 instruments), `Preset` (`.sonpreset` device presets; appended last because the asset cache stores the int).
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

## PresetAssetProvider (device presets)
- A `FileScanAssetProvider` that scans the single `presets/path` folder (`_scan_roots()` returns `[]` while the folder doesn't exist yet) for `.sonpreset` files and caches them in `preset_cache.json`. It reads only the header through `DevicePreset.read_header`, skipping broken files with a warning.
- Preset `Asset`s carry `device_id`, `device_name`, `author` and header tags. `Asset.is_unavailable()` is true when the device isn't in `DeviceRegistry`. The Browser greys those rows out, names the missing device in the tooltip and refuses to drag them. It refreshes the Presets tab on `devices_changed`.
- User tags from `assets.json` are merged into the header tags, never replace them.
- `PresetLibrary.save` calls `AssetService.rescan_presets()`, and a change to `presets/path` triggers a rescan too. `presets` is in `assets/enabled_providers`; `Settings` switches it on once for configs that predate it.
- The Browser's Presets tab shows `Name — Device` in the list and the folder structure under the presets root in the tree.

## Browser (`Godot/browser/Browser.gd`)
- Two display modes, toggled by the Options button and persisted under `ui/browser`: `TREE_VIEW` (one hierarchical `Tree` per tab) and `FLAT_LIST` (spec 037), which is the default.
- List mode is a `VSplitContainer` per tab (`_splits`): `_folder_trees` (folders only, root row "All") on top and `_content_trees` (the selected folder's contents) below. Both rebuild together in `_populate_tab_for`; other tabs rebuild lazily via `_dirty_tabs`.
- Folder model (`_build_folder_model`): `key -> {label, parent, children, assets}`. Samples, SFZ and Presets use the directory structure under the scan roots (same prefix stripping as the tree view); the folder key is the absolute folder path. Audio and MIDI stay separate roots, so their keys carry an `audio:` / `midi:` prefix. Devices use the Category / Vendor hierarchy.
- Content tree: "All" lists every asset recursively. A folder lists its subfolders first (rows with a `folder_key` meta; double-click enters them) and then its direct assets. While the search box has text, the content tree lists every ranked match whatever folder is selected, and the folder tree only shows folders with matches (the remembered folder is kept, not overwritten).
- Content rows carry the `Asset` as metadata, exactly like tree view rows, so `_get_drag_data_tree(at_position, tree)`, `_on_tree_item_context_menu(..., tree)` and `asset_selected` work for both kinds of tree. Preset rows read `Name — Device`, are greyed when the device is missing, and carry the preset tooltip.
- Persisted in `ui/browser`: `folder` (selected folder key per tab), `split` (split offset per tab) and `expanded["<Type>/folders"]` (expanded folder keys). A rebuild keeps the selected folder and the selected content row (by path) while they still exist; a vanished folder falls back to All.

## Info panel, preview and audition (spec 037)
- `PreviewPlayer.gd` (a child node of the Browser, `Browser.preview`) is the model for the engine's preview player. `play(path, start_s)`, `stop()`, `seek(pos_s)` and `toggle(path)` send `/preview/*`; it mirrors `/preview/status` (`state_changed(path, state)`, `position_changed(pos_s, duration_s)`) and extrapolates the position between statuses while playing. Statuses for another path are ignored. UI code calls it instead of sending OSC.
- `request_info(path)` asks `/audiofile/waveform/start` with a `browse:<n>` request id and answers `info_ready(path, peak_path, duration_s)`: the duration comes from `/audiofile/decode/ready`, the peak file from `/audiofile/waveform/ready`; answers are cached per path. `Project` skips `browse:` and `preview:` request ids instead of warning about untracked requests.
- `BrowserInfoPanel` (`PanelContainer` under `Content`, hidden when nothing is selected, collapsible via `ui/browser` `info_collapsed`) shows the filename and type, then size and, for audio, sample rate and channels (from the peak header `WaveformData.source_sample_rate` / `channels`) and duration; presets show device and author, devices vendor and category. For audio it holds a `WaveformView` (48 px) with a playhead overlay and a play/stop button. A press on the waveform plays from that point when stopped; a press or drag while playing seeks (`seek_x_to_seconds` maps x to seconds).
- The Browser connects `asset_selected` to `info_panel.show_asset`. Picking a folder or a subfolder row, switching tabs and turning audition off call `preview.stop()`; folder picks and tab switches also clear the panel.
- The audition toggle (headphones button in Options, Samples tab only, persisted as `ui/browser` `audition`): while on, selecting an audio row on the Samples tab calls `preview.play(path)`; any other selection calls `stop()`.
- Space does not toggle the preview: it is bound to `transport_play`.
