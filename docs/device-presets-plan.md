# Device presets

Implementation plan for saving and loading device presets: built-ins, CLAP plugins and the container devices (Chain, Layer, Drum Machine). A preset stores everything needed to rebuild the device, including the whole child tree and the return channels behind separate outputs. Presets live as files in a user folder. The browser shows them in their own tab, and they drag and drop like devices. A preset button on the DevicePanel saves and loads them.

## Checklist

- [x?] Phase 1: Preset format, library and settings (no UI)
- [x?] Phase 2: Return channels in presets
- [x?] Phase 3: Browser tab and asset provider
- [x?] Phase 4: Drag and drop (new device from a preset; drop-onto-same-type load in place waits for Phase 5)
- [x?] Phase 5: DevicePanel preset button, save dialog, load in place (CompactDevicePanel gets no button yet)
- [ ] Phase 6 (later): Presets as child entries under devices in the browser
- [ ] Phase 7 (later): Collect samples into a preset bundle
- [ ] Phase 8 (later): CLAP native presets (preset-discovery and preset-load)

Do the phases in order. Run `Godot/tests/run_all.sh` after each phase. Mark tasks `[x?]` when implemented and `[x]` once verified. Phases 1–5 are Godot-only: every engine path they need (parameters, `state/save` and `state/load` for CLAP state, file loads, device add and remove) already exists. Only Phase 8 touches the engine. Before starting, read `docs/subsystems/godot-asset-system.md`, `godot-drag-and-drop.md`, `godot-config-system.md`, `godot-device-views.md` and `docs/specs/001-multi-out-devices`.

## Decisions (already made)

- **A preset is a serialized device tree.** It is built on `DeviceInstance.to_json()` with instance IDs, the channel binding and aux return links removed. Containers store their whole subtree: children, slots, slot settings, note maps, choke groups and mod routes.
- **CLAP state is the opaque `plugin_state` blob,** fetched fresh through `save_plugin_state()` at save time (the same path `Project.refresh_plugin_states()` uses). `parameter_values` are stored as well, but the blob is authoritative for plugins.
- **One JSON file per preset, extension `.sonpreset`.**
- **Folder layout:** `<presets root>/<Device name>/<Preset name>.sonpreset`. The device subfolder is created on save, and users may add their own subfolders anywhere. The browser builds its tree from the folders.
- **Presets root:** setting `presets/path`, default `~/Documents/sonara/presets`, created on first save.
- **Author** is remembered in config (`presets/author`) and prefilled in the save dialog.
- **Tags** are entered comma-separated and stored as a trimmed, lower-cased, de-duplicated array. Browser search matches name, tags, author and device name.
- **Loading into an existing device is supported,** from the preset button menu and by dropping a preset onto a device of the same type. It is one undo step.
- **Separate outputs come back.** A preset stores each return channel's mixer settings (name, colour, volume, pan, mute) and its effect chain. Instantiating the preset creates fresh return channels. Sends and output routing on returns are not stored: they point at project channels.
- **Sample and SFZ paths are stored as paths.** Each path also records which asset root it was under (the `assets/samples/paths` / `assets/sfz/paths` entry) plus the path relative to that root. Loading falls back to resolving the relative path against the current roots, and warns about files that are still missing. Bundling samples comes later (Phase 7).
- **Not stored:** automation, the instance name of the root device, the root's own slot settings (`slot_volume`, `slot_note`, `choke_group` and so on, which belong to whatever container it sits in), and the open or collapsed state of slots.

### Defaults I picked (say if you want them different)

- A device created from a preset is named after the preset (the instance `name` is set to the preset name). Loading in place renames the device to the preset name only if it still has the default name. A name the user typed is kept.
- Saving over an existing preset (same device folder and same name) asks to confirm the overwrite, as `NoteMapSaveDialog` does.
- If a preset's device is missing (a plugin that isn't installed), the browser entry is greyed out, its tooltip says which device it needs, and drops are refused.

## File format

```json
{
  "format": "sonara.device_preset",
  "version": 1,
  "name": "Warm Pad",
  "author": "Peter",
  "tags": ["pad", "warm"],
  "device_id": "sonara.builtin.polysynth",
  "device_name": "PolySynth",
  "plugin": { "vendor": "...", "version": "..." },
  "created": "2026-10-02T12:00:00Z",
  "modified": "2026-10-02T12:00:00Z",
  "device": { "...": "DeviceInstance.to_json() with ids stripped" },
  "returns": [
    { "owner": [0, 3], "index": 0, "channel": { "...": "stripped Channel.to_json()" } }
  ],
  "files": [
    { "path": "/home/peter/Music/Drums/kick.wav", "root_setting": "assets/samples/paths", "root": "/home/peter/Music", "rel": "Drums/kick.wav" }
  ]
}
```

- `plugin` is only present for CLAP devices and is informational only (a version mismatch is logged, not refused).
- `returns[].owner` is the index path from the preset root to the device that owns the return (`[]` is the root itself, `[0, 3]` is child 3 of child 0). For a Drum Machine it points at the pad device. For a Layer it points at the slot chain. For a multi-out plugin it is the plugin, with `index` as the bus.
- `files` is a lookup table only. The device tree keeps its own `loaded_file_path` and sample paths, and on load each one is resolved through this table.
- Readers ignore unknown keys. A newer `version` loads with a warning.

## Phase 1: Preset format, library and settings

- [x?] Settings: register `presets/path` (`Type.PATH`, default `~/Documents/sonara/presets`, category Assets, sub "Presets") in `settings/Settings.gd`. Store `presets/author` with `Sonara.get_config`/`set_config` (no settings row needed, but one under Presets does no harm).
- [x?] Shared fresh-ID helper: move `TrackDuplicateCommand._refresh_device_ids()` into a static `DeviceInstance.refresh_ids_in_json(data, channel_id)` (recursive: new UUIDs, `channel_id` rewritten, `return_channel_id`/`return_channel_ids` cleared). `TrackDuplicateCommand` calls the helper.
- [x?] Shared plugin-state refresh: move `Project._collect_plugin_state_requests()` and the wait loop of `refresh_plugin_states()` into a static helper that takes a list of root instances (`DeviceInstance.refresh_plugin_states(roots, timeout)`). Project calls it with every channel's devices, and presets call it with one root.
- [x?] `data/DevicePreset.gd` (`class_name DevicePreset extends RefCounted`): the fields above, plus:
  - `static func capture(inst: DeviceInstance) -> DevicePreset` (async: refreshes plugin states in the subtree first, then serializes, strips root-only fields and builds the `files` table).
  - `func instantiate(channel_id: int) -> DeviceInstance` (deep-copies `device`, refreshes IDs, resolves file paths, then `DeviceInstance.from_json`). It returns null if the device is unknown and sets `missing_files` and `warnings` for the caller to show.
  - `to_json()` / `static from_json()`, `static read_header(path)` (name, author, tags, device id and name only, for the browser scan).
- [x?] `data/PresetLibrary.gd`: `root_dir()`, `folder_for(device)`, `path_for(device, name)`, `exists()`, `save(preset, overwrite)`, `load(path)`, `list_for_device(device_id)` (scans the device folder and, if needed, the whole root, matching on `device_id` from the header). It has a `dir_override` for tests, like `NoteMapLibrary`. Slugging follows `NoteMapLibrary.slug_for`, but keeps case and spaces (users browse these folders), stripping only `/\:*?"<>|`.
- [x?] Tests (`tests/test_device_presets.gd`): a round-trip of a built-in device with parameters and mod routes; a Chain with nested children; a Drum Machine with pads, choke groups and note maps; a CLAP instance with a fake `plugin_state` blob. Check that IDs are fresh and unique across the tree, that root slot fields and the name are dropped, and that a missing file resolves through the relative-path fallback. Check tag normalization.

## Phase 2: Return channels in presets

Drum Machine pads, Layer slots with separate outputs and multi-out plugins own return channels (`AuxReturnSync`). Removing a device already detaches its returns onto `DeviceInstance.detached_returns`, and `AuxReturnSync.on_device_added` re-adopts them. Presets reuse this path.

- [x?] Capture: for each owner in the tree, look up its return channels (`AuxReturnSync.get_return_channel` and friends) and store a stripped `Channel.to_json()` in `returns`. Keep name, colour, volume, pan, mute and the device chain (with IDs stripped through the Phase 1 helper). Drop sends, output route, track link and channel ID.
- [x?] Instantiate: build fresh `Channel` objects from `returns` (new IDs come from the project when attached) and put them into the owning instance's `detached_returns` with the right key, so `on_device_added` adopts them instead of creating blank returns. Check that the key and the "same Channel objects" assumption hold for all three owner kinds. Where they don't, add a small `AuxReturnSync.adopt_preset_returns()` instead of bending the undo path.
- [x?] Undo: adding a device from a preset and undoing it must remove its returns. Redoing must bring the same Channels back (the existing detach and re-adopt behaviour).
- [x?] Tests: a Drum Machine preset with 3 pads, where one pad return has an EQ and a −6 dB fader, creates 3 returns with those settings on a new channel. A Layer with one separate-out slot creates exactly one return. Undo and redo keep the channel count right.

## Phase 3: Browser tab and asset provider

- [x?] `Asset.TYPE.Preset` (append it to the enum: the asset cache stores ints). Give it an icon in `Asset.get_icon()` and a display name from the header.
- [x?] Add a `device_id` field to `Asset` (or a small `meta: Dictionary`) so presets can be matched to devices without reading the file again. Also add `author`. Tags go in the existing `Asset.tags`.
- [x?] `browser/PresetAssetProvider.gd extends FileScanAssetProvider`: the scan path is the single `presets/path` (override `_scan_paths_setting` handling so a single path works, or register `presets/path` as a one-entry array), the extension is `sonpreset`, and the cache is `preset_cache.json`. `_try_create_asset` reads the header (tolerating broken files with a warning). Add the provider to `assets/enabled_providers` choices and defaults (`"presets"`), and register it in `AssetService`.
- [x?] Rescan on save: `PresetLibrary.save` asks the provider for an immediate rescan (or adds the asset directly), so a new preset shows without waiting for the scan interval. Also rescan when `presets/path` changes.
- [x?] Browser: a new tab button `_create_tab_button("P", "Presets", Asset.TYPE.Preset)` with list and tree populate functions modelled on the SFZ tab (the tree comes from the folder structure under the root). The list view shows `Name — Device` and the tooltip shows the author and tags.
- [x?] Search: check that `AssetSearch.score` covers tags. Add author and device name to the scored text for presets.
- [x?] Missing devices: grey out presets whose `device_id` isn't in `DeviceRegistry`. Refresh them on `devices_changed`.
- [x?] Tests: header parsing, a broken file skipped, tag search hits, a missing device flagged.

## Phase 4: Drag and drop (new device from a preset)

Every device drop target goes through `DeviceDropUtil`, so most targets work once the util understands the new asset type.

- [x?] `DeviceDropUtil.instance_for_asset`: `Asset.TYPE.Preset` loads the preset (`PresetLibrary.load`) and returns `preset.instantiate(channel_id)`, positioned like a device. Show any missing-file warnings with `PopupMessage` (one message per drop, listing the files).
- [x?] `new_channel_kind` / `_track_name_for`: presets resolve to their device for the instrument, audio or bus decision, and the new track is named after the preset.
- [x?] `can_drop_asset_on_channel`, `can_drop_on_container`, `can_drop_on_drum_pad`: treat a preset like the device it holds (`device_fits_channel` and so on). A refused drop shows no indicator.
- [ ] Targets to check by hand: track item, empty track list, mixer empty space (track side and bus side), device lane (insert line and container slots), mixer channel compact device list, Drum Machine pad (empty and occupied).
- [x?] Drop onto a device header of the same type (`can_drop_on_device` / `drop_on_device`): load in place (Phase 5's command). A different device type keeps the current behaviour for that target (insert, or refuse).
- [x?] Tests: `instance_for_asset` with a preset asset; `new_channel_kind` for an instrument preset and an effect preset; a drop onto a drum pad creates the preset's device on that note.

## Phase 5: DevicePanel preset button, save dialog, load in place

- [x?] `DevicePresetLoadCommand` (`history/commands/`): replaces a device with a preset instance at the same parent and position, in one undo step. It is built from `DeviceRemoveCommand` and `DeviceAddCommand` (a `MacroCommand`) or written as one command if the slot fields need care. It carries over what belongs to the context and not the preset: the root slot fields (`slot_volume`, `slot_note`, `choke_group`, note map, separate out), the instance name unless it's the default, and the `return_channel_id` for a drum pad or layer slot (that return is the pad's, not the preset's). Automation lanes address devices by index path (`AutomationTarget.device_path`), so lanes on the root survive. Lanes into a container's old children may point at different devices afterwards; this is accepted.
- [x?] Track the current preset: `DeviceInstance.preset_name` and `preset_path` (serialized with the project), set on create or load from a preset and on save. A `preset_changed` signal. No "modified" flag in this phase.
- [x?] Preset button on `DevicePanel` beside `DeviceLight` in the top header (and in `CompactDevicePanel` if there's room; otherwise leave that for later). Its tooltip is the current preset name, or "No preset".
- [x?] Clicking it opens a `PopupMenu` with `theme_type_variation = &"ContextMenuList"`:
  - "Save Preset…" (opens the dialog prefilled with the current preset's name, tags and author)
  - "Save as New Preset…"
  - a separator, then this device's presets from `PresetLibrary.list_for_device` (grouped into submenus by subfolder when there are more than about 15). The current one is checked, and picking one runs `DevicePresetLoadCommand`.
  - "Show in Browser" (switches to the Presets tab and filters by the device name)
- [x?] `devices/DevicePresetSaveDialog.gd`, modelled on `NoteMapSaveDialog`, with Name, Tags (comma-separated) and Author fields. Author is prefilled from `presets/author` and written back on save. Save is disabled while the name is empty. Saving over an existing preset asks to confirm. While the CLAP state is being fetched the dialog shows "Saving…" and disables Save. A timeout or failure is reported, with an offer to save without plugin state.
- [x?] Tests: the load command and its undo restore the exact previous `to_json()` (ignoring IDs); slot fields and the drum pad return survive a load in place; the dialog's tag parsing; author persistence.

## Phase 6 (later): Presets under devices in the browser

- [ ] Devices tab: a device row expands to show its presets (from the Preset provider's assets, matched on `device_id`). Preset rows drag like presets.

## Phase 7 (later): Collect samples into a preset bundle

- [ ] "Collect samples" option in the save dialog: copy each referenced file into `<preset name>.samples/` next to the preset and rewrite the paths as preset-relative (`"rel_to_preset": "..."` in `files`). On load, preset-relative paths take priority.

## Phase 8 (later): CLAP native presets

CLAP 1.2 has two extensions for this, and clack exposes both through the `clack-extensions` `preset-discovery` feature:

- **`preset-discovery` factory**: the host creates a provider from the plugin's factory and indexes its presets. It gets location (a file path or "inside the plugin"), name, creators, tags, categories and a `load_key`. Indexing can run in the scanner without instantiating the plugin.
- **`preset-load` extension** (`clap.preset-load`): the host calls `from_location(location_kind, location, load_key)` on a live plugin, and the plugin reports success or error through the host side of the extension.

Plan sketch:

- [ ] Engine: index presets during the plugin scan (in `plugin_host`, so a crashing provider can't take down the engine). Cache them alongside the plugin cache and expose them over OSC (`/plugin/presets/request` → `/plugin/presets/info` → `/plugin/presets/complete`, following the builtin discovery pattern).
- [ ] Engine: `/device/.../preset/load location_kind location load_key` → IPC → `preset_load.from_location` on the plugin's main thread, then an `/…/preset/loaded ok error` reply.
- [ ] Godot: a `ClapPresetAssetProvider` that lists them in the Presets tab under a "Plugin factory presets" folder per plugin (read-only, not files). Loading one goes through `preset/load`, then refreshes `plugin_state`, so the project and Sonara presets capture the result normally.
- [ ] Update `docs/subsystems/osc-protocol.md` and `engine-plugin-architecture.md`.

## Open questions to settle while implementing

- Whether `CompactDevicePanel` has room for the preset button, or only gets the preset name in its tooltip.
- Whether to show a "modified since load" marker (for example `Warm Pad*`) on the button. This needs a cheap comparison of current state against the preset, and parameter echoes make that fiddly for CLAP, so it is left out of Phase 5.
