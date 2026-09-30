# DAWproject import and export

Spec: `docs/specs/010-dawproject-core/` (requirements, design, tasks). Format reference:
`docs/dawproject/specification.md`. Gap checklist: `docs/dawproject/sonara-gaps.md`.

Everything runs in Godot on the main thread. The engine and OSC are not involved. Import builds
`.sonara` JSON and goes through `Project.from_json` + `Editor.open_project(p, "")`, so it behaves
like *Open*. Export reads the live `Project` and never changes it.

## Code map

| File | Role |
|---|---|
| `Godot/dawproject/DawXml.gd` | XML DOM (`parse(bytes)`, `El`) and indenting `Writer` with escaping. |
| `Godot/dawproject/DawUnits.gd` | dB/gain, pan, velocity, ticks/beats, param normalized/real, `resample`. |
| `Godot/dawproject/DawEnums.gd` | Integer mirrors of model enums, so the scripts compile headless without autoloads. |
| `Godot/dawproject/ClapPreset.gd` | `wrap(clap_id, state)` / `unwrap(bytes)` for `.clap-preset`. |
| `Godot/dawproject/SfzFiles.gd` | `collect(sfz)`: an SFZ's includes and samples, plus missing files. |
| `Godot/dawproject/TransferReport.gd` | Kinds, aggregation by `(kind, subject)`, `to_text()`. |
| `Godot/dawproject/DawProjectExporter.gd` | `await export_project(project, path) -> {ok, error, report}`. |
| `Godot/dawproject/DawProjectImporter.gd` | `import_file(path, audio_dir := "") -> {ok, error, project_json, report, audio_dir_failed}`. |
| `Godot/dawproject/TransferReportDialog.gd/.tscn` | `AcceptDialog` scene: `show_report(title, report)`, `show_error(title, message)`. Instanced in `Editor.tscn`. |
| `Godot/editor/Editor.gd` | `export_dawproject(path)`, `import_dawproject(path, audio_dir)`, node `transfer_report_dialog`. |
| `Godot/editor/MainMenu.gd` | File items *Import DAWproject…* / *Export DAWproject…*; dialog modes; `.dawproject` appended; folder picker retry. |
| `Godot/tests/test_dawproject_{units,export,import,roundtrip}.gd` | Headless tests. |
| `Godot/tests/validate_dawproject.sh` | Runs the export test, then `xmllint --schema` over its output (needs `libxml2-utils`). |
| `Godot/tests/fixtures/dawproject/` | Bitwig fixture `sonara_test_01.dawproject`, `Project.xsd`, `MetaData.xsd`. |

## Flow

- **Export:** menu → save dialog → `Editor.export_dawproject`. Awaits `refresh_plugin_states`,
  writes `<path>.partial`, renames on success (a failure leaves no file). Failure shows an error
  dialog; a non-empty report shows the report dialog.
- **Import:** menu → open dialog → `Editor.import_dawproject`. On failure the open project stays
  as it was. If the audio folder can't be written (`audio_dir_failed`), the menu asks for another
  folder and retries; cancelling aborts. Success opens an unsaved project (`project_path == ""`),
  named after `Title` or the file name, and shows the report if not empty.
- Embedded audio is extracted to `<file name> Audio/` beside the `.dawproject`, keeping in-ZIP
  paths. `external="true"` paths resolve relative to the file, or as absolute paths.

## Mapping

| Sonara | DAWproject |
|---|---|
| Channel/send volume dB (−60…+12) | linear gain (0 ↔ −60 dB; import clamps to +12 dB, reported) |
| Pan −1…+1 | normalized 0…1 |
| Ticks (960 PPQ) | beats |
| Velocity 0–127 | 0…1 (import rounds) |
| Device param normalized | `RealParameter` real value via `DeviceParameter` range |
| Tempo map / signature map | `TempoAutomation` / `TimeSignatureAutomation` (bar → beat position) |
| Folder / group track | `Track contentType="tracks"` with nested `Track`s |
| Instrument / audio track | `Track` `notes` / `audio` |
| Bus channel | `Track` (`audio`, no clips), channel role `effect` (send target only) or `submix` |
| Master (channel 1) | `Track` with channel role `master`, written last |
| `output_channel_id` | `Channel@destination` |
| Send | `Send` (`Volume`, `Enable`, `type` pre/post, `destination`) |
| Clip instance | `Clip` (`playStart` = left trim, loop, fades, `enable`) |
| Pooled clip | first instance `id`, later ones `reference` |
| MIDI clip | `Notes` (channel 0) |
| Audio clip | `Warps` (seconds content) around `Audio`, two `Warp`s from `recorded_bpm` |
| Automation lane | `Points` targeting the channel/send/device parameter id; STEP ↔ `hold` |
| Song marker | `Markers/Marker` (start only) |
| CLAP device | `ClapPlugin` + `State` (`.clap-preset`) + `Parameters` for automated params |
| Sonara built-in | `BuiltinDevice deviceID="sonara.<device id>"` |

Curved segments (tension ≠ 0) and dB ramps are resampled into extra linear points within 1% of
the true curve. Import runs `resample` the other way for gain ramps.

### The `sonara.` BuiltinDevice convention

Built-ins (`polysynth`, `delay`, sampler, drum machine and the rest) export as `BuiltinDevice`
with `deviceID = "sonara." + <Sonara device id>` and a `State` file `plugins/<instance id>.json`
holding `DeviceInstance.to_json()`, children included. Every `loaded_file_path` (SFZ, samples, an
SFZ's includes and samples) is rewritten to a path under `files/<n>/` and embedded. On import a
`BuiltinDevice` with a `sonara.` id is rebuilt from that JSON, with the files extracted next to
the import. Other vendors' `BuiltinDevice`s are reported and skipped.

## Transfer report kinds

Entries are one per `(kind, subject)` with a count (`TransferReport.TEMPLATES` holds the text).

- **Import:** `plugin_format` (VST2/VST3/AU), `clap_missing`, `generic_device` (Equalizer,
  Compressor, NoiseGate, Limiter), `foreign_builtin`, `sonara_device_missing`, `warp_approximated`,
  `note_channel`, `note_release` (only when it differs from `vel`), `note_expression`,
  `clip_automation`, `expression_automation`, `unsupported_automation`, `crossfade`, `vca`,
  `scene_clip`, `mono_channel`, `bus_clip`, `signature_off_bar`, `send_clamped`,
  `volume_clamped`, `nested_loop`, `audio_missing`, `state_mismatch`.
- **Export:** `marker_duration`, `clip_transpose`, `clip_gain_offset`, `pan_mode`,
  `hardware_output`, `phase_invert`, `plugin_no_state`, `file_missing`, `mod_routes` (a built-in's modulation routes travel only in its `sonara.` State JSON).

Silent by design: Bitwig's default sends (disabled, volume 0, or to their own channel), `rel`
equal to `vel`, and empty scenes.

## Notes

- Model classes are typed `Object` in the exporter/importer (see `DawEnums`), because scripts
  naming `Project`, `Track` or `Channel` don't compile headless before the autoloads exist.
- The round-trip test (`test_dawproject_roundtrip.gd`) is the tolerance reference: volume ±0.01
  dB, pan ±0.001, notes exact, automation within 2% of the range.
- Import runs synchronously, so a very large file blocks the UI.
- No OSC messages were added; `osc-protocol.md` is unchanged. Modulation routes (ADR-0011) are part of a built-in's `DeviceInstance.to_json()`, so they survive a Sonara round trip; importing someone else's project leaves the default patch.
