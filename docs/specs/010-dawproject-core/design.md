# DAWproject Import and Export (core) — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/data/Project.gd` — `to_json()` / `static from_json(data)` define the `.sonara` shape.
  `from_json` is the one load path: it rebuilds channels, tracks and the clip pool, then runs
  `_relink_folder_buses`, `_migrate_slot_automation`, `_rebuild_channel_child_ids_from_parents`,
  `dedupe_names` and `AuxReturnSync.ensure_all`. `refresh_plugin_states(timeout_sec)` asks every
  ready CLAP plugin for fresh state before a save.
- Model constructors are engine-free: `Channel.new(id)`, `Track.new(id)`, `Clip.new(id)`,
  `ClipInstance.new(id, clip_id)`, `SendConfig.new()`, `AutomationLane.new()`,
  `AutomationPoint.new(...)`, `SongMarker.new()`, `MidiNoteData.new()`. They only talk to the
  engine after `connect_to_engine()` (ADR-0006).
- `Godot/data/Channel.gd` — `volume` in dB (−60…+12), `pan` −1…+1, `pan_mode`
  (`STEREO_COMBINED`, `STEREO_DUAL`, `STEREO_BALANCE`, `MONO`), `mute`, `solo`, `phase_invert`,
  `output_channel_id`, `device_output_id`, `channel_type`, `send_channels: Array[SendConfig]`,
  `devices: Array[DeviceInstance]`. Master is ID 1, routed to 1000.
- `Godot/data/SendConfig.gd` — `target_channel_id`, `amount` (dB), `pre_fader`, `muted`.
- `Godot/data/Track.gd` — `type: TrackType { AUDIO, INSTRUMENT, FOLDER, GROUP }`,
  `default_channel_id`, `parent_track_id`, `child_track_ids`, `order`, `clip_instances`,
  `automation_lanes`, `get_linked_channel()`.
- `Godot/data/Clip.gd` — `content_length_ticks`, `midi_notes: Array[MidiNoteData]`,
  `audio_file_path` (absolute), `recorded_bpm`. One tick of an audio clip covers
  `60 / (recorded_bpm × ppq)` s of the file (`TimelineClip._update_waveform`, engine
  `calculate_stretch_factor`), so beats ↔ file seconds is `s = beats × 60 / recorded_bpm` —
  a constant ratio, which is exactly a two-event `Warps`.
- `Godot/data/ClipInstance.gd` — `start_ticks`, `duration_ticks`, `clip_offset`, `loop_enabled`,
  `loop_start_ticks`, `loop_length_ticks`, `transpose`, `gain_offset`, `muted`,
  `fade_in_ticks`, `fade_out_ticks`.
- `Godot/data/MidiNote.gd` (`MidiNoteData`) — `note`, `velocity` 0–127, `start_tick`,
  `duration_ticks`, relative to the clip.
- `Godot/data/AutomationLane.gd`, `AutomationPoint.gd`, `AutomationTarget.gd`,
  `AutomationCurve.gd` — points are `{tick, value (normalized), curve LINEAR|STEP, tension}`;
  targets `channel/volume`, `channel/pan`, `channel/send/{i}`, `device/{path}/param/{id}`.
  `AutomationTarget.normalized_to_db` / `db_to_normalized` / `normalized_to_pan` /
  `pan_to_normalized` are the unit maps (volume and send both −60…+12 dB).
  `AutomationCurve.evaluate(left, right, tick)` applies tension.
- `Godot/data/TempoMap.gd` — points `{id, tick, bpm}`, linear between points; `add_point`
  replaces a point on the same tick; `tick_at_seconds`, `seconds_at_tick`.
- `Godot/data/TimeSignatureMap.gd` — changes `{bar, numerator, denominator}` (bar ≥ 2);
  `tick_of_bar`, `bar_at_tick`. `Project.time_numerator/denominator` is the base.
- `Godot/data/SongMarker.gd` — `name`, `start_ticks`, `duration_ticks`, `color`.
- `Godot/data/DeviceInstance.gd` — `device.id`, `name`, `enabled`, `children`,
  `loaded_file_path` (the one file a device loads: SFZ, sample), `plugin_state: PackedByteArray`,
  `to_json()` / `from_json()`. `from_json` returns null when `AssetService.get_device` doesn't
  know the id, and base64 `plugin_state` in the JSON is restored when the plugin reports ready.
- `Godot/data/Device.gd` — `device_type` (`BuiltIn`, `LV2`, `CLAP`), `category`
  (`Instrument`, `Effect`, `Utility`), `author`, `version`, `parameters: Array[DeviceParameter]`.
  `DeviceParameter.normalized_to_value` / `value_to_normalized`, `min_value`, `max_value`,
  `is_logarithmic`.
- `Godot/browser/AssetService.gd` — `get_device(id)`; built-ins come from the engine
  (`/builtin/info`), CLAP plugins from the scan cache.
- `Godot/editor/Editor.gd` — `open_project(p, path)`, `save_project(path)`, `load_project(path)`,
  `file_dialog`. `Godot/editor/MainMenu.gd` — `FILE` enum, `DialogMode`, `_on_item_pressed`,
  `_set_project_dependent_items_enabled`, `_on_file_dialog_file_selected`.
- Godot has `XMLParser`, `ZIPReader` and `ZIPPacker`; nothing in the app uses them yet.
- Fixture: `sonara_test_01.dawproject` (Bitwig 6.0.11), described in requirements.md.
- ADRs touched: 0005 (normalized parameters — converted at the file boundary only), 0006
  (self-synchronizing models — import goes through `Project.from_json`, never OSC). No conflict.

## Approach

All of it lives in Godot, in a new `Godot/dawproject/` directory. The engine is not involved:
plugin state already reaches Godot through `refresh_plugin_states`, and an imported state reaches
the plugin through the existing `plugin_state` restore on ready.

**Export** reads the live `Project` (it needs device definitions for parameter ranges and roles,
which the JSON alone doesn't carry) and never writes to it. An `XmlWriter` builds `project.xml`
in XSD sequence order with document-scoped ids `id0, id1, …`; a pre-pass assigns ids to every
channel, parameter and shared clip content so forward IDREFs (`destination`, `Target@parameter`,
`Clip@reference`) are known before writing. Files go into a `ZIPPacker` opened on
`<path>.partial`, renamed over `<path>` only on success (REQ-005).

**Import** is a pure function from a `.dawproject` file to a `.sonara`-shaped Dictionary plus a
transfer report. It parses both XML files into a small DOM (`DawXml.Node`), builds the id map,
and walks the arrangement with a scope `{track, time_unit, tick_offset, window}` so nested
`Lanes`/`Clips`, `timeUnit`/`contentTimeUnit` and IDREFs resolve in one place. It creates the
model objects with their engine-free constructors, sets fields, and serializes them with their
own `to_json()` (so defaults like master's output 1000 stay right). Devices are written as JSON
dicts directly, since `DeviceInstance.new` needs a registered `Device`. The editor then calls
`Project.from_json(dict)` and `open_project(project, "")` — exactly the `.sonara` load path, so
folder-bus relinking, name dedupe and aux returns behave as for any saved file.

Rejected alternatives:
- *Building the project with the `Project.create_*` API.* Those methods emit signals and assume
  a connected project; they'd make the importer untestable headless and duplicate the post-load
  fixups `from_json` already does.
- *A Rust converter in the engine.* The engine doesn't own the project model (ADR-0006), and
  large ZIPs would have to cross OSC (ADR-0003).
- *Exporting from `project.to_json()` only.* It lacks device parameter ranges and categories.

### Unit and curve conversion (`DawUnits`)

| Sonara | DAWproject | Map |
|---|---|---|
| channel/send volume dB (−60…+12) | `linear` gain | `g = 10^(dB/20)`; `g = 0` ↔ −60 dB; import clamps to +12 dB (report) |
| pan −1…+1 | `normalized` 0…1 | `n = (p + 1) / 2` |
| ticks | beats | `beats = ticks / 960`; import rounds to the nearest tick |
| velocity 0–127 | 0…1 | `v / 127`; import `round(v × 127)` clamped 1–127 |
| device param normalized | `RealParameter` real value | `DeviceParameter.normalized_to_value`; unknown param → linear over the file's `min`/`max` |

`DawUnits.resample(points, map_fn, tolerance)` turns a Sonara lane into points in the target
domain. For each LINEAR segment it evaluates the true curve (`AutomationCurve.evaluate`, then
`map_fn`) and recursively bisects until linear interpolation between emitted points is within
`tolerance` (1% of the target range) — a straight segment through a linear map emits no extra
points. The importer runs the same routine the other way (a linear-gain ramp becomes dB points).
`STEP` ↔ `hold` pass through unchanged.

### Import walk

1. Unzip; missing `project.xml`, parse errors or a dangling IDREF → error (REQ-008).
2. **Transport and maps.** `Transport/Tempo` → `tempo`; `TimeSignature` → base. `TempoAutomation`
   → `TempoMap` points; points sharing a time keep the last at that tick and move the earlier ones
   one tick back, and a `hold` point adds a copy of its value one tick before the next point
   (REQ-011). `TimeSignatureAutomation` points → `(bar, num, den)`; a point at beat 0 replaces
   the base; off-bar points move to the next bar (report). The tempo map is built first so
   `seconds` positions convert with `TempoMap.tick_at_seconds`.
3. **Structure.** Depth-first over `Structure`. A `Track` with `contentType` containing `tracks`
   → FOLDER (GROUP when its channel has role `submix` and children route to it). A channel with
   role `master` → Sonara channel 1. Role `effect`/`submix` on a non-folder track, or a
   top-level `Channel` → BUS channel with no track. Otherwise `notes` → INSTRUMENT, else AUDIO,
   each with its channel paired through `default_channel_id`. Channel/track ids come from
   Sonara counters; a map `dawproject id → sonara id` serves later IDREFs.
4. **Routing, sends, devices** after all channels exist. Sends that are disabled at volume 0, or
   target their own channel, are skipped (REQ-015). Devices per REQ-021/022, anything else to the
   report (REQ-023).
5. **Arrangement.** Walk `Arrangement/Lanes`. `Clips` under a track scope produce instances;
   `Points` produce lanes; `Markers` produce markers. Nested `Clips` flatten: an inner clip
   `(t, d, p)` inside an outer window `[P, P + D)` at `T` becomes an instance at
   `T + max(t, P) − P`, trimmed to the window, offset `p + max(t, P) − t`. An outer loop that
   would repeat nested content (duration > loop length) is reported and the first pass kept.
   Content types: `Notes` → MIDI clip; `Warps` around `Audio` → audio clip with
   `recorded_bpm = 60 × Δbeats / Δseconds` from the first and last warp (report when > 2);
   bare `Audio` in a `seconds` content scope → `recorded_bpm = 60 × duration_beats /
   (playStop − playStart)` (REQ-018). `Clip@reference` and repeated content ids → one pooled
   Sonara clip.
6. **Automation targets.** `Target@parameter` resolves through the id map to (channel volume |
   pan | send i | device path + param id). Mute, device `Enabled`, send `Pan`, tempo-less
   targets and `expression` targets → report.
7. **Audio files.** Embedded → extract to `<file name> Audio/<in-zip path>` beside the file;
   `external="true"` → resolve relative to the file, or absolute. The extract dir is a parameter,
   so the editor can pass the folder the user picked when the default isn't writable (REQ-009).

### Export mapping

- `Transport`: `Tempo` (`id`, `unit="bpm"`, min 20, max 999), `TimeSignature`.
- `Structure`, in `Project.get_visual_track_list()` order: each root track → `Track` with nested
  child `Track`s for folders/groups; each track's linked channel → its `Channel`. Buses without
  a paired track → `Track contentType="audio"` with a `Channel` of role `effect` (only send
  targets) or `submix` (anything routes into it). Master → `Track name="Master"` with
  `role="master"`, written last as Bitwig does. Hardware outputs (≥ 1000) → master, report.
- `Channel` children in XSD order: `Devices`, `Mute`, `Pan`, `Sends`, `Volume`.
- Devices: CLAP → `ClapPlugin deviceID=<clap id> deviceName deviceRole deviceVendor=author
  pluginVersion=version`, children `Parameters` (one `RealParameter` per automated param id,
  `parameterID`, min/max from `DeviceParameter`, `unit="linear"`), `Enabled`, `State
  path="plugins/<device instance id>.clap-preset"`. Built-in → `BuiltinDevice
  deviceID="sonara.<device id>"`, `State path="plugins/<instance id>.json"` holding
  `DeviceInstance.to_json()` with every `loaded_file_path` (recursively) rewritten to a
  container path under `files/`, and those files (plus SFZ-referenced samples, see `SfzFiles`)
  embedded. `deviceRole`: category Instrument → `instrument`, `spectrum_analyzer` →
  `analyzer`, else `audioFX`.
- `Arrangement/Lanes timeUnit="beats"`: one `Lanes track=…` per track with a `Clips` and one
  `Points` per automation lane. `Markers`, `TempoAutomation`, `TimeSignatureAutomation` when
  non-empty.
- Clip content: first instance of a pooled clip writes the content with an `id`; later instances
  use `reference`. MIDI → `Notes` (`channel="0"`, `vel`); audio → `Warps contentTimeUnit="seconds"
  timeUnit="beats"` with `Audio` (`duration`, `sampleRate`, `channels` from the clip's
  `audio_source`) and two `Warp`s, file in `audio/<basename>` (deduplicated by source path,
  suffix `-2`, `-3` on name clashes). Instances with `transpose ≠ 0` write inline transposed
  content (report); `gain_offset ≠ 0` is dropped (report).
- `metadata.xml`: `Title` = `project_name`.

### `.clap-preset`

`ClapPreset.wrap(clap_id, state) = "clap" + u32_be(len(clap_id)) + clap_id + state`.
`unwrap(bytes)` checks the magic, returns `{clap_id, state}` or an error; a CLAP id that doesn't
match the element's `deviceID` is reported and the state still used.

## Thread and ownership

Everything runs on the Godot main thread; no engine or audio-thread state changes.

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| Export/import working data (DOM, id maps, report) | Godot main thread, local to one call | — | n/a (not on the audio path) |
| Imported plugin state | `DeviceInstance.plugin_state` (Godot) | engine via the existing `{device}/state/load` file hand-off on ready | unchanged |

Export awaits `refresh_plugin_states` (as save does), then runs synchronously. Import runs
synchronously; large files block the UI (accepted in requirements).

## Data and protocol changes

- No OSC messages. No `.sonara` change.
- New file format, read and written: `.dawproject` per `docs/dawproject/specification.md`.
  Sonara-specific content: `BuiltinDevice deviceID="sonara.<id>"` whose `State` is the device's
  `.sonara` JSON with container-relative `loaded_file_path`s under `files/`.
- Menu: `MainMenu.FILE` gains `Import_DAWproject`, `Export_DAWproject` (after `Save_As`, own
  separator); `DialogMode` gains `IMPORT_DAWPROJECT`, `EXPORT_DAWPROJECT`, `IMPORT_AUDIO_DIR`.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/dawproject/DawXml.gd` (new) | `DawXml.Node {tag, attrs, children, parent}`; `parse(buffer) -> Node` via `XMLParser` (error with line on failure); `Writer` building indented XML with attribute escaping and `%.6f`-style numbers. |
| `Godot/dawproject/DawUnits.gd` (new) | Static conversions in the table above; `resample(...)`; `beats_to_ticks`, `ticks_to_beats`. |
| `Godot/dawproject/ClapPreset.gd` (new) | `wrap`, `unwrap`. |
| `Godot/dawproject/SfzFiles.gd` (new) | `collect(sfz_path) -> PackedStringArray` of the SFZ, its `#include`s and every `sample=` resolved against `default_path` and the file's dir; missing files listed separately for the report. |
| `Godot/dawproject/TransferReport.gd` (new) | `add(kind, subject, detail)`, aggregation by `(kind, subject)` with counts, `entries()`, `is_empty()`, `to_text()`. `kind` constants for every item in REQ-023/024. |
| `Godot/dawproject/DawProjectExporter.gd` (new) | `export_project(project, path) -> {ok, error, report}` (async for the plugin refresh). |
| `Godot/dawproject/DawProjectImporter.gd` (new) | `import_file(path, audio_dir := "") -> {ok, error, project_json, report, audio_dir_failed}`. |
| `Godot/dawproject/TransferReportDialog.gd` (new) | `AcceptDialog` with a read-only list; `show_report(title, report)` and `show_error(title, message)`. |
| `Godot/editor/Editor.gd` | `export_dawproject(path) -> bool` and `import_dawproject(path, audio_dir := "") -> Dictionary`; the report dialog node, created in code. Import calls `Project.from_json` + `open_project(p, "")` only on success. |
| `Godot/editor/MainMenu.gd` | New `FILE` items and `DialogMode`s; `_on_export_dawproject`, `_on_import_dawproject`; `_on_file_dialog_file_selected` branches, appending `.dawproject`; export added to `_set_project_dependent_items_enabled`; on `audio_dir_failed` reopen the dialog in `FILE_MODE_OPEN_DIR` and retry. |
| `Godot/tests/fixtures/dawproject/sonara_test_01.dawproject` (new) | The Bitwig fixture. |
| `Godot/tests/fixtures/dawproject/Project.xsd`, `MetaData.xsd` (new) | Verbatim from the spec appendix. |
| `Godot/tests/test_dawproject_units.gd` (new) | Units, resampling, `.clap-preset`, `SfzFiles`, `TransferReport`. |
| `Godot/tests/test_dawproject_export.gd` (new) | Export of built fixtures; writes into `user://dawproject_export/` for the schema check. |
| `Godot/tests/test_dawproject_import.gd` (new) | Bitwig fixture, broken files, report cases, audio extraction. |
| `Godot/tests/test_dawproject_roundtrip.gd` (new) | REQ-025 field-by-field round trip. |
| `Godot/tests/validate_dawproject.sh` (new) | Runs the export test, then `xmllint --noout --schema` on every exported `project.xml`/`metadata.xml`; fails if `xmllint` is missing (package `libxml2-utils`). |
| `docs/subsystems/dawproject.md` (new) | Where the code lives, the mapping tables, the report kinds, the Sonara `BuiltinDevice` convention. |
| `AGENTS.md` | Row for `dawproject.md` in the subsystem table. |
| `docs/dawproject/sonara-gaps.md` | Tick the core items this spec delivers. |
| `TODO.md`, `STATUS.md` | Backlog entry; working/not-working notes. |

## Migration and compatibility

`.sonara` files are unchanged and nothing is persisted in config. Imports tolerate unknown
elements and attributes (the DOM keeps them; the walker ignores what it doesn't know). A
`BuiltinDevice` with a `sonara.` id whose device isn't registered (engine not connected yet) is
reported like a missing plugin — the same limitation `.sonara` loading has.

## Test plan

Tests load `Project`, `DeviceInstance` etc. with `load()` inside `run_tests()`, and register
fake devices in `AssetService.device_registry._devices`, as `test_plugin_state.gd` does.

- **Godot:** `godot --headless --path Godot -s tests/test_dawproject_units.gd -- --test` —
  dB ↔ linear (−6 dB ↔ 0.501187, 0 → −60 dB clamp), pan, velocity, a tension 0.7 segment within
  1% at 100 samples (REQ-019), a linear dB ramp resampled to gain, `.clap-preset` wrap/unwrap on
  the fixture's preset (id `nakst.Apricot`, 16 133 state bytes), SFZ collection with
  `default_path` and `#include`, report aggregation.
- **Godot:** `... -s tests/test_dawproject_export.gd -- --test` — container entries and embedded
  paths (REQ-002), unchanged project (REQ-004), unwritable target leaves no file (REQ-005),
  shared clip → `reference` (REQ-017), one copy of a twice-used WAV (REQ-018), bus roles
  (REQ-014), export report entries (REQ-024).
- **Godot:** `... -s tests/test_dawproject_import.gd -- --test` — the Bitwig fixture: 3 tracks +
  master, *Reverb* as a bus, Apricot −6.02 dB, send −22.85 dB, crash at tick 3840 with
  `recorded_bpm` 110, tempo 110 → 79.02 jump at tick 3840 within one tick, two automation lanes,
  one report entry (*Reverb* BuiltinDevice), Apricot `plugin_state` = the preset's state bytes;
  audio extracted to `<tmp>/sonara_test_01 Audio/audio/crash_cymbal_crash_01.wav`. Broken files
  built in-test with `ZIPPacker` (not a ZIP, no `project.xml`, bad XML, dangling IDREF) each
  fail and leave the editor's project untouched (REQ-008). A synthetic file with one of each
  REQ-023 item yields one entry per item.
- **Godot:** `... -s tests/test_dawproject_roundtrip.gd -- --test` — REQ-010 … REQ-022, REQ-025.
- **Schema:** `Godot/tests/validate_dawproject.sh` — REQ-003.
- **All:** `Godot/tests/run_all.sh` stays green.
- **Live (needs Bitwig and the engine):** import `sonara_test_01.dawproject`, play it: Apricot
  plays *Elder's Wisdom*, crash at bar 2, reverb send ramps up, tempo drops at bar 2. Export a
  Sonara project with Apricot, an audio loop, a bus + send, volume automation and a tempo change;
  open it in Bitwig and check the same. Menu items and report dialog appear (REQ-001/006/023/024,
  REQ-021, REQ-026).

## Risks

| Risk | Mitigation |
|---|---|
| Bitwig rejects something the XSD allows (e.g. send `Volume max="2"`, Sonara `BuiltinDevice`s) | Live export check in Bitwig is a task; follow the Bitwig fixture's conventions where the spec is silent (send volume `max="1"` when every value ≤ 0 dB). |
| Imported `sonara.` built-ins or CLAP plugins dropped because the registry isn't populated yet | Check `AssetService.get_device` in the importer and report it, rather than letting `Channel.from_json` skip silently. |
| Exporting a project with huge SFZ libraries balloons the file | `SfzFiles` embeds only referenced samples; size isn't capped in v1. |
| Tempo steps become 1-tick ramps, shifting later positions a hair | 1 tick at 960 PPQ is < 1 ms at 60 BPM; tested against the fixture. |
| GDScript XML/ZIP speed on large projects | Accepted in requirements; measure once with a 50-track export in the live task. |

## Open questions

- (none)
