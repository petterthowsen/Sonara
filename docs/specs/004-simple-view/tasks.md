# Simple View — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified · `[-]` deferred

## Phase 1 — Engine metadata end to end

- [x] **T-001** [REQ-018] Add flags, module and step labels to both copies of `PluginParameterInfo`, and fill them in the subprocess.
  - _Files_: `Engine/src/plugin_host/protocol.rs`, `Engine/src/audio/ipc/protocol.rs`, `Engine/src/plugin_host/commands.rs`
  - _Output_: `GetParameterInfo` reports `is_stepped`, `is_hidden`, `is_read_only`, `is_bypass`, `module`, and `step_labels` (≤ 64 steps, via `value_to_text`; check the clack API against Context7 `/prokopyl/clack`)
  - _Verify_: `cargo build --release` builds both binaries. Loading Dragonfly Hall logs the parameter count with no IPC decode error in `Engine/logs/last_warn.log`
  - _Depends on_: —

- [x] **T-002** [REQ-018] Add the new fields to `ParamInfo` and map stepped parameters to Bool/Enum.
  - _Files_: `Engine/src/audio/devices/mod.rs`, `Engine/src/audio/devices/clap_host/subprocess_adapter/lifecycle.rs`, every `ParamInfo {` construction site (`grep -rn "ParamInfo {" Engine/src`)
  - _Output_: `ParamInfo` has `is_hidden`, `is_read_only`, `is_bypass`, `module`. A pure helper `plugin_param_to_info(&PluginParameterInfo) -> ParamInfo` does the mapping, with a `mod tests` block
  - _Verify_: `cargo test plugin_param_to_info` (2 steps → Bool, 5 steps with labels → Enum, 200 steps → Float, flags copied); `cargo test` passes; `cargo fmt`
  - _Depends on_: T-001

- [x] **T-003** [REQ-018] Send the new parameter fields over `param/info`.
  - _Files_: `Engine/src/audio/commands.rs` (`EngineStatus::PluginParameterInfo`, both send sites in `GetPluginParameters` handling), `Engine/src/audio/mixing.rs` (sfizz site, defaults only), `Engine/src/osc/server.rs`
  - _Output_: `param/info` = `[id, name, min, max, default, group, param_type, flags, module, enum_count, enum_values…]`
  - _Verify_: `cargo build --release`. With the engine running and Dragonfly loaded, the `param/info` messages Godot receives have ≥ 10 args (temporary debug log in Godot, removed afterwards)
  - _Depends on_: T-002

- [x] **T-004** [REQ-019] Carry plugin feature tags through discovery and `/plugin/info`.
  - _Files_: `Engine/src/audio/devices/clap_host/discovery.rs`, `Engine/src/audio/commands.rs` (`EngineStatus::PluginInfo` and its send site), `Engine/src/osc/server.rs`
  - _Output_: `PluginDescriptor.features`, and `/plugin/info` gets a trailing `features` arg joined with commas
  - _Verify_: `cargo test` and `cargo build --release`. `oscsend localhost 7000 /plugin/scan` while `oscdump 7001` runs shows Dragonfly's info ending in a string that contains `reverb`
  - _Depends on_: —

- [x] **T-005** [REQ-018, REQ-019] Parse the new metadata in Godot and keep features in the plugin cache.
  - _Files_: `Godot/data/DeviceParameter.gd`, `Godot/data/DeviceInstance.gd` (`_on_param_info_received`), `Godot/data/Device.gd` (`features`), `Godot/data/DeviceRegistry.gd` (`/plugin/info`, `_save_plugin_cache`, `_load_plugin_cache`)
  - _Output_: parameters have `param_type`, `enum_values`, `is_hidden`, `is_read_only`, `is_bypass` and `module` from the engine, and missing trailing args get defaults. `plugins.json` stores `"features"`, and a missing key loads as `[]`
  - [x] _Verify_: `Godot/tests/run_all.sh` passes. Live: Dragonfly's stepped parameters show as a checkbox or option button in the parameter list, and after a rescan `~/.config/sonara/plugins.json` has `"features"` containing `"reverb"` for Dragonfly
  - _Depends on_: T-003, T-004

## Phase 2 — Layout model and generator (headless)

- [x] **T-006** [REQ-008, REQ-010, REQ-016, REQ-017] Layout model and store.
  - _Files_: `Godot/devices/simple_view/SimpleLayout.gd`, `Godot/devices/simple_view/SimpleLayoutStore.gd`, `Godot/devices/simple_view/SimpleControlKinds.gd`, `Godot/tests/test_simple_layout_model.gd`
  - _Output_:
    - `SimpleLayout`: `from_dict`/`to_dict`, `validate`, `find_free_rect`, `resize_grid`, `reconcile`
    - `SimpleLayoutStore`: `path_for` (sanitized id plus hash), load, save, a parse failure that doesn't overwrite the file, an unknown `version` treated as a parse failure, a base dir that tests can override
  - _Verify_: `godot --headless --path Godot -s tests/test_simple_layout_model.gd -- --test` passes `test_roundtrip_json`, `test_resize_grid_reflows`, `test_reconcile_param_changes`, `test_corrupt_file_not_overwritten` and `test_path_for_distinct_ids`
  - _Depends on_: —

- [x] **T-007** [REQ-002] Device kind inference.
  - _Files_: `Godot/devices/simple_view/DeviceKind.gd`, `Godot/tests/test_simple_layout_generator.gd` (created here)
  - _Output_: `DeviceKind.infer(device)`, which checks features first, then category, then id and name, and falls back to `generic`
  - _Verify_: `test_kind_inference` passes (the REQ-002 examples, plus builtin `delay` → delay and `polysynth` → synth)
  - _Depends on_: T-005

- [x] **T-008** [REQ-003, REQ-004] Parameter classifier and generic strategy.
  - _Files_: `Godot/devices/simple_view/ParamClassifier.gd`, `Godot/devices/simple_view/strategies/GenericStrategy.gd`, `Godot/tests/test_simple_layout_generator.gd`
  - _Output_: each visible parameter gets a control kind, a role and an importance. Hidden and read-only parameters are left out. Bypass is left out too, because the device header already has an enable button
  - _Verify_: `test_control_kinds` and `test_hidden_readonly_excluded` pass
  - _Depends on_: T-007

- [x] **T-009** [REQ-005] Compound detector.
  - _Files_: `Godot/devices/simple_view/CompoundDetector.gd`, `Godot/tests/test_simple_layout_generator.gd`
  - _Output_: stem matching finds xy `[x,y]`, envelope `[a,d,s,r]` (only when every part looks like a time) and eq_band `[freq,gain,q]`. Partial matches stay single controls
  - _Verify_: `test_compounds` passes (the REQ-005 examples, plus an ADSR where one part is missing → 3 knobs)
  - _Depends on_: T-008

- [x] **T-010** [REQ-006, REQ-007, REQ-008] Grouping, grid packer and the generator pipeline.
  - _Files_: `Godot/devices/simple_view/GridPacker.gd`, `Godot/devices/simple_view/SimpleLayoutGenerator.gd`, `Godot/tests/test_simple_layout_generator.gd`
  - _Output_: `SimpleLayoutGenerator.generate(device, params)` groups by module path, falling back to strategy roles. It builds a Main page from the top importance, then pages per group, packed first-fit with no overlaps
  - _Verify_: `test_grouping_module_and_role`, `test_main_page_importance`, `test_no_overlap_in_bounds` and `test_generate_500_params_under_100ms` pass
  - _Depends on_: T-006, T-009

- [x] **T-011** [REQ-002, REQ-006, REQ-007] Strategies for each device kind.
  - _Files_: `Godot/devices/simple_view/strategies/SynthStrategy.gd`, `ReverbStrategy.gd`, `DelayStrategy.gd`, `CompressorStrategy.gd`, `EqStrategy.gd`, `Godot/tests/fixtures/simple_view/dragonfly_hall_params.json` (dumped from a live load), `Godot/tests/test_simple_layout_generator.gd`
  - _Output_: keyword tables and weights for each kind. A Dragonfly Hall parameter fixture
  - _Verify_: `test_dragonfly_hall_fixture` passes: Dry and Wet levels are in the same group, and the Main page holds mix, decay and size. `Godot/tests/run_all.sh` passes
  - _Depends on_: T-010

## Phase 3 — View and integration

- [x] **T-012** [REQ-001, REQ-009, REQ-013] SimpleView rendering and parameter binding.
  - _Files_: `Godot/devices/simple_view/SimpleView.gd`, `Godot/devices/simple_view/SimpleView.tscn`, `Godot/devices/simple_view/SimpleControl.gd`, `Godot/devices/simple_view/SimpleUnits.gd`
  - _Output_: a `DeviceView` that loads through `SimpleLayoutStore.load_or_generate`, shows page tabs when there are 2 or more pages, and renders every control kind. Controls call `set_parameter_normalized`, update from `_on_device_parameter_changed`, and rebuild on `parameters_updated`. Label and unit overrides are shown
  - _Verify_: headless `test_simple_units` in `test_simple_layout_model.gd` (`%` gives 35 for 0.35, s→ms, Hz→kHz). The live check is done in T-013
  - _Depends on_: T-011

- [x?] **T-013** [REQ-001, REQ-011] Hook the Simple View into DeviceViewFactory and DevicePanel.
  - _Files_: `Godot/data/Device.gd` (`uses_simple_view`, false for containers and devices with no visible parameters), `Godot/devices/DeviceViewFactory.gd`, `Godot/devices/device_lane/DevicePanel.gd`, `Godot/devices/device_lane/DevicePanel.tscn`
  - _Output_: devices without a Panel view get the Simple View. Devices with one get a "Simple" toggle, remembered through `Sonara.set_config("devices/simple_view/<id>", …)`
  - _Verify_: Live: Dragonfly Hall shows a Simple View, turning a knob is audible, and the parameter-list slider follows. The builtin `delay` shows a Simple View. The Sampler shows the toggle and switches views. Restarting Godot logs "loaded layout" for Dragonfly with the same layout, and moving a `rect` by hand in the JSON shows up after reopening
  - _Depends on_: T-012

- [-] **T-014** _Deferred to `TODO.md` (Simple View edit mode)._ [REQ-010, REQ-012, REQ-015] Edit mode: move, resize, pages, grid size, reset.
  - _Files_: `Godot/devices/simple_view/SimpleEditOverlay.gd`, `Godot/devices/simple_view/SimpleView.gd`, `Godot/devices/simple_view/SimpleView.tscn`
  - _Output_: an edit toggle, drag to move and corner drag to resize (snapped, with overlap rejected), move to page, add or remove page, column and row spinners, and Reset with a confirmation. Leaving edit mode saves and sets `generated: false`
  - _Verify_: Live: move a knob, leave edit mode, reopen the device, and it's still moved. Shrink the grid to 4×4, and nothing overlaps or is lost. Reset and confirm, and the generated layout returns and the file is overwritten
  - _Depends on_: T-013

- [-] **T-015** _Deferred to `TODO.md` (Simple View edit mode)._ [REQ-013, REQ-014] Edit mode: rename, units, remove and add back.
  - _Files_: `Godot/devices/simple_view/SimpleEditOverlay.gd`, `Godot/devices/simple_view/SimpleView.gd`
  - _Output_: a context menu (rename a control or group title, pick a unit, remove) and an "Add parameter" list of visible parameters that aren't in the layout
  - _Verify_: Live: rename Dragonfly's "Early Level" to "ER" with unit `%`, and it shows "ER" with a percentage value, still after a restart. Remove a knob and add it back from the list
  - _Depends on_: T-014

## Phase 4 — docs

- [x] **T-016** [REQ-018, REQ-019] Document the changed OSC messages.
  - _Files_: `OSC_PROTOCOL.md` (new, repo root)
  - _Output_: `<device addr>/param/count`, `<device addr>/param/info` (with the flags bitmask and the optional trailing args) and `/plugin/info` (with `features`) are documented: address, argument types, direction
  - _Verify_: all three messages are in the doc, and the argument lists match `Engine/src/osc/server.rs`
  - _Depends on_: T-003, T-004

- [x] **T-017** [REQ-all] Update the device view rules and the backlog.
  - _Files_: `.cursor/rules/godot-device-views.mdc`, `TODO.md`
  - _Output_: a Simple View section (location, fallback rule, layout file format and path, the strategy extension point). The TODO entry points to this spec
  - _Verify_: the rule file mentions `devices/simple_view/` and `device_layouts/`, and `TODO.md` links `docs/specs/004-simple-view/`
  - _Depends on_: T-013 (T-015 deferred)

## Phase 5 — live verification

- [ ] **T-018** [REQ-all] Full live run with the engine and Godot.
  - _Files_: —
  - _Output_: the `TODO.md` entry is marked `[x]`. `STATUS.md` notes what was and wasn't checked
  - _Verify_: with `Engine/run_release.sh` and `godot --path Godot` running, repeat the live checks from T-005, T-013, T-014 and T-015 in one session. Also check: the page controls appear for a device with more than 24 cells (REQ-009), and a plugin whose parameter set changed (edit ids in the JSON by hand) keeps its placements and logs a warning (REQ-016). No new entries in `Engine/logs/last_warn.log` or dropouts while opening views during playback
  - _Depends on_: T-016, T-017
