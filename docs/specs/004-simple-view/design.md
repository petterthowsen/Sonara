# Simple View — Design

Implements [requirements.md](./requirements.md).

## Context

Engine, parameter metadata:
- `Engine/src/plugin_host/commands.rs`: the `PluginCommand::GetParameterInfo` handler (~L481)
  builds a `PluginParameterInfo` for each CLAP parameter from `params.get_info`. It keeps only
  `IS_AUTOMATABLE` and drops the other `ParamInfoFlags` and `module`.
- `PluginParameterInfo` is defined **twice**, once for each side of the IPC:
  `Engine/src/plugin_host/protocol.rs` (subprocess) and `Engine/src/audio/ipc/protocol.rs` (engine).
  Both are serde structs and must stay identical.
- `Engine/src/audio/devices/clap_host/subprocess_adapter/lifecycle.rs` (~L123) turns them into
  `ParamInfo` (`Engine/src/audio/devices/mod.rs`) with `param_type: ParamType::Float` hardcoded.
- `AudioCommand::GetPluginParameters` (`Engine/src/audio/commands.rs` ~L1949) sends
  `EngineStatus::PluginParameterCount` and `EngineStatus::PluginParameterInfo`. `Engine/src/osc/server.rs`
  (~L1763) turns those into `<device addr>/param/count` and `<device addr>/param/info`
  `[id, name, min, max, default, group]`. `Engine/src/audio/mixing.rs` (~L483) sends the same status
  for sfizz.
- `Godot/data/DeviceInstance.gd` `_on_param_info_received` parses those args into per-instance
  `DeviceParameter`s and already treats trailing args as optional (`group` at index 5).

Engine, plugin discovery:
- `Engine/src/audio/devices/clap_host/discovery.rs`: `PluginDescriptor` plus `infer_category`,
  which reads `descriptor.features()` and throws the tags away afterward.
- `EngineStatus::PluginInfo` (`commands.rs` ~L469) → `/plugin/info`
  `[id, name, vendor, version, category, description, path]` (`server.rs` ~L1696).
- `Godot/data/DeviceRegistry.gd` `_on_plugin_info_received` and `_save_plugin_cache` /
  `_load_plugin_cache` handle `plugins.json` under `Sonara.get_config_dir()`.

Godot, views:
- `Godot/data/Device.gd`: `DeviceCategory`, `ViewType`, `has_panel_view()`, `panel_view_scene`.
- `Godot/data/DeviceParameter.gd`: `param_type` (`float`/`bool`/`enum`), `enum_values`, `unit`,
  `group`, `value_to_normalized` / `normalized_to_value` / `format_value`.
- `Godot/devices/DeviceViewFactory.gd`: `create(instance, view_type)` / `_scene_for`.
- `Godot/devices/DeviceView.gd`: `_on_bind`, `_on_view_shown`, `_on_view_hidden`,
  `_on_device_parameter_changed(param_id, value)`.
- `Godot/devices/device_lane/DevicePanel.gd`: `bind_to_device` calls `_load_panel_view` only when
  `has_panel_view()`, and `view_button.visible` depends on the same check (L229–234).
- `DeviceInstance.set_parameter_normalized(param_id, v)`, `parameter_values`, and the signals
  `parameter_changed` and `parameters_updated`.
- Existing controls to reuse: `Godot/components/RotaryKnob.gd` (`value_changed`,
  `set_value_no_signal`, `value_text_callback`), `Godot/components/XYSlider.gd` (`values_changed`,
  `set_values_no_signal`), `Godot/components/EnvelopeControl.gd` (+ `.tscn`),
  `Godot/components/HSlider.gd`.
- Tests: `Godot/tests/TestBase.gd`, `Godot/tests/run_all.sh`.

## Approach

**Metadata first, generation on top.** The engine passes CLAP's parameter flags, module path and
stepped value labels through to Godot, plus the plugin's feature tags. All the inference then
happens in Godot, on `DeviceParameter` and `Device`. Builtins and plugins look the same to the
generator, and nothing new runs on the engine's real-time path.

**The generator is a pipeline of plain functions with strategies plugged in.** It runs these steps:
1. `DeviceKind.infer(device)` picks a kind.
2. `ParamClassifier` gives every parameter a *role*, a control kind and an importance. The strategy
   for the device kind supplies role keywords and importance weights, and `GenericStrategy` is the
   base class every other strategy extends.
3. `CompoundDetector` merges matching parameters into XY, envelope and EQ-band controls.
4. Parameters are grouped: by module path if there is one, otherwise by the strategy's role groups.
5. `GridPacker` places the groups: a "Main" page with the top-importance controls, then one page
   (or more) per group, first-fit, with no overlaps.

Each step takes and returns plain data, so each one can be tested headless.

**The layout is data, and the view renders it.** `SimpleLayout` is a `RefCounted` that stores its
content as JSON (see Data and protocol changes). `SimpleView` (a `DeviceView`) draws the current
page from it. Edit mode uses the same view with an overlay on top, and every edit changes the
`SimpleLayout` and redraws the page. The layout is saved when edit mode is left.

**Rejected alternatives:**
- *Inferring in Rust and sending a finished layout over OSC.* Layouts are a UI concern, they get
  edited in Godot, and doing it in Rust would put a second copy of the parameter model in the engine.
- *Generating Godot scenes (`.tscn`) as the saved format.* They're hard to edit by hand, they break
  when components change, and they aren't the "simple JSON" the feature asks for.
- *Free placement instead of a grid.* It was already ruled out in the requirements.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| New `PluginParameterInfo` fields (flags, module, step labels) | plugin subprocess → engine plugin-loading thread (`lifecycle.rs`) | stored in `param_info_cache: Arc<Mutex<Vec<ParamInfo>>>`, the same as today | n/a, not on the audio callback |
| New `ParamInfo` fields | engine command thread (`GetPluginParameters`) | cloned out of the cache, as today | yes. The sfizz path in `mixing.rs` fills them with defaults (`false`, `String::new()`, `Vec::new()`), which don't allocate |
| `PluginDescriptor.features` | plugin scanner (command thread, slow work with the lock released) | `EngineStatus::PluginInfo` | n/a |
| `SimpleLayout` | Godot main thread | `SimpleLayoutStore` cache, keyed by device id | n/a |

The audio callback doesn't gain any work.

## Data and protocol changes

### IPC: `PluginParameterInfo` (both copies)

These fields are added (serde, so the subprocess and engine must be built together, which the run
scripts already do):

```rust
pub is_stepped: bool,
pub is_hidden: bool,
pub is_read_only: bool,
pub is_bypass: bool,
pub module: String,           // CLAP module path, e.g. "Early/Size"; "" if none
pub step_labels: Vec<String>, // only when is_stepped and (max-min+1) <= 64, from value_to_text; else empty
```

`plugin_host/commands.rs` fills them from `clap_info.flags` (`IS_STEPPED`, `IS_HIDDEN`,
`IS_READONLY`, `IS_BYPASS`) and `clap_info.module`. Each step's label comes from the params
extension's `value_to_text` (the exact clack API gets checked against Context7 `/prokopyl/clack`
during implementation). If there's no text, the label is the integer value.

### Engine `ParamInfo`

`is_hidden`, `is_read_only`, `is_bypass: bool` and `module: String` are added. Every constructor in
`delay.rs`, `chain.rs`, `sfizz_device.rs`, `sampler.rs` and the builtin devices gets the defaults.
`lifecycle.rs` maps the plugin fields across:
- stepped with 2 values → `ParamType::Bool`
- stepped with 3–64 values → `ParamType::Enum` with `enum_values = step_labels`
- otherwise → `Float`

### OSC: `<device addr>/param/info` (changed, backward compatible)

`[id:i, name:s, min:f, max:f, default:f, group:s, param_type:s, flags:i, module:s, enum_count:i, enum_values:s…]`

- `param_type` is `"float"`, `"bool"` or `"enum"`.
- `flags` is a bitmask: 1 = hidden, 2 = read-only, 4 = bypass.
- The new args are appended, and Godot treats a missing trailing arg as the default, so an older
  engine still works.
- `EngineStatus::PluginParameterInfo` gains matching fields. Both senders fill them: `commands.rs`
  with real values and `mixing.rs` (sfizz) with defaults.

### OSC: `/plugin/info` (changed, backward compatible)

A new arg is appended: `features:s`, the CLAP feature tags joined with `,`. `PluginDescriptor` gains
`features: Vec<String>`, filled in `discovery.rs` next to `infer_category`, and
`EngineStatus::PluginInfo` gains `features: Vec<String>`.

### Godot models

- `DeviceParameter.gd` adds `is_hidden`, `is_read_only`, `is_bypass: bool` and `module: String`.
- `Device.gd` adds `features: Array[String]` and `func uses_simple_view() -> bool`, which is true
  when there's no `panel_view_scene`.
- `DeviceRegistry.gd` parses `features` from `/plugin/info` and stores and loads it in
  `plugins.json` as `"features": [...]`. A missing key means `[]`.
- Builtins get no feature tags (there's no protocol change for `/builtin/info`). `DeviceKind`
  falls back to the device id and name for them (`delay` → delay, `polysynth` → synth).

### Layout file

`~/.config/sonara/device_layouts/<sanitized device id>.json`. `SimpleLayoutStore.path_for(id)`
replaces every char outside `[A-Za-z0-9._-]` with `_` and adds a short hash of the raw id, so
different ids can never map to the same file.

```json
{
  "version": 1,
  "device_id": "clap:com.michaelwillis.dragonfly.hall",
  "kind": "reverb",
  "generated": true,
  "grid": { "columns": 6, "rows": 4 },
  "pages": [
    {
      "title": "Main",
      "groups": [ { "id": "mix", "title": "Mix", "rect": [0, 0, 2, 1] } ],
      "controls": [
        { "kind": "knob",  "params": [3],    "rect": [0, 0, 1, 1], "label": "Dry", "unit": "%" },
        { "kind": "xy",    "params": [7, 8], "rect": [2, 0, 2, 2], "label": "Position" },
        { "kind": "toggle","params": [12],   "rect": [4, 0, 1, 1] }
      ]
    }
  ]
}
```

- `rect` is `[col, row, w, h]` in cells.
- `params` holds parameter ids, and their order has a meaning for each control kind:
  - xy: `[x, y]`
  - envelope: `[a, d, s, r]`
  - eq_band: `[freq, gain, q]`
- `group` (optional) is the id of the group a control belongs to. Group rects are recomputed from
  their controls after a grid resize or reconcile.
- `label` and `unit` are optional overrides; when they're missing the view uses the parameter's own
  name and unit.
- A group's `rect` covers its controls. The view draws its background and title in a 14px strip
  inserted above every row where a titled group starts (pixel spacing only; grid rects are unchanged).
- Control kinds: `knob`, `slider`, `toggle`, `segmented`, `dropdown`, `xy`, `envelope`, `eq_band`.
- Footprints come from `SimpleControlKinds.FOOTPRINT`:
  - 1×1: knob, toggle, dropdown
  - 2×1: slider, segmented
  - 2×2: xy
  - 3×2: envelope
  - 2×1: eq_band
- A `segmented` control falls back to a dropdown at render time when its labels don't fit the
  control's width. Controls clip to their cells; titles are ellipsized with the full name as tooltip.
- `generated` becomes false after the first edit that gets saved.

**Display units (REQ-013).** `SimpleUnits.gd` maps a unit to a formatter:
- `%` → `normalized × 100`
- `dB` → the real value with a "dB" suffix
- `ms` → `real × 1000` if the parameter's own unit is `s` (or empty and max ≤ 10), otherwise the real value
- `s`, `Hz` → the real value, with `Hz` switching to `kHz` above 1000
- an empty string → `DeviceParameter.format_value`

A unit only changes how the value is shown. The value sent to the engine is always normalized.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/plugin_host/protocol.rs` | Add the new fields to `PluginParameterInfo` |
| `Engine/src/audio/ipc/protocol.rs` | The same fields on its copy of `PluginParameterInfo` |
| `Engine/src/plugin_host/commands.rs` | Fill flags, module and step labels in `GetParameterInfo` |
| `Engine/src/audio/devices/mod.rs` | Add `is_hidden`, `is_read_only`, `is_bypass`, `module` to `ParamInfo` |
| `Engine/src/audio/devices/delay.rs`, `chain.rs`, `sfizz_device.rs`, `sampler.rs` (+ any other `ParamInfo {` site found by grep) | Default the new fields |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/lifecycle.rs` | Map stepped → Bool/Enum; copy flags and module |
| `Engine/src/audio/commands.rs` | Extend `EngineStatus::PluginParameterInfo` and `EngineStatus::PluginInfo`; fill them in `GetPluginParameters` (both send sites) and wherever `PluginInfo` is sent |
| `Engine/src/audio/mixing.rs` | Sfizz send site: fill the new fields with defaults |
| `Engine/src/audio/devices/clap_host/discovery.rs` | `PluginDescriptor.features`; collect them next to `infer_category` |
| `Engine/src/osc/server.rs` | Append the new args to `param/info` and `/plugin/info` |
| `OSC_PROTOCOL.md` (new, repo root) | Document `param/count`, `param/info` and `/plugin/info`. AGENTS.md already points to this file but it doesn't exist; start it with the messages this spec changes |
| `Godot/data/DeviceParameter.gd` | `is_hidden`, `is_read_only`, `is_bypass`, `module` |
| `Godot/data/DeviceInstance.gd` | `_on_param_info_received`: parse the optional trailing args |
| `Godot/data/Device.gd` | `features`; `uses_simple_view()` |
| `Godot/data/DeviceRegistry.gd` | Parse `features` from `/plugin/info`; store and load them in `plugins.json` |
| `Godot/devices/simple_view/SimpleLayout.gd` (new) | Layout model: `from_dict`/`to_dict`, `validate()` (overlaps, bounds), `find_free_rect(page, w, h)`, `resize_grid(cols, rows)`, `reconcile(params)` (REQ-016) |
| `Godot/devices/simple_view/SimpleLayoutStore.gd` (new) | `path_for`, `load_or_generate(instance)`, `save(layout)`, a parse-failure path that doesn't overwrite (REQ-017), an in-memory cache keyed by device id |
| `Godot/devices/simple_view/SimpleLayoutGenerator.gd` (new) | `generate(device, params) -> SimpleLayout`: runs the pipeline |
| `Godot/devices/simple_view/DeviceKind.gd` (new) | `infer(device) -> String` |
| `Godot/devices/simple_view/ParamClassifier.gd` (new) | Control kind from type and steps (REQ-003); leaves out hidden and read-only parameters (REQ-004) |
| `Godot/devices/simple_view/CompoundDetector.gd` (new) | Stem matching for xy, envelope and eq_band (REQ-005) |
| `Godot/devices/simple_view/GridPacker.gd` (new) | First-fit packing into pages; Main page (REQ-007, REQ-008) |
| `Godot/devices/simple_view/SimpleControlKinds.gd` (new) | Kind constants, `FOOTPRINT` |
| `Godot/devices/simple_view/SimpleUnits.gd` (new) | Unit formatters (REQ-013) |
| `Godot/devices/simple_view/strategies/GenericStrategy.gd` (new) | Base: `role_for(param)`, `importance(role)`, `groups()`; name-keyword defaults |
| `Godot/devices/simple_view/strategies/SynthStrategy.gd`, `ReverbStrategy.gd`, `DelayStrategy.gd`, `CompressorStrategy.gd`, `EqStrategy.gd` (new) | Keyword tables and weights for each kind |
| `Godot/devices/simple_view/SimpleView.gd` + `.tscn` (new) | `DeviceView`. Page tabs; renders controls; two-way param binding through `set_parameter_normalized` / `_on_device_parameter_changed`; rebuilds on `parameters_updated`; edit-mode toggle, grid-size spinners, Reset (with a `ConfirmationDialog`) |
| `Godot/devices/simple_view/SimpleControl.gd` (new) | Cell wrapper: label plus the inner control (`RotaryKnob`, `HSlider`, `CheckButton`, button row, `OptionButton`, `XYSlider`, `EnvelopeControl`, eq_band = three small knobs for freq, gain and q, since the 2×1 footprint has no room for an XY pad) |
| `Godot/devices/simple_view/SimpleEditOverlay.gd` (new) | Grid lines, drag to move, corner drag to resize, snapping to cells, invalid-drop highlight, a context menu (rename, unit, remove, move to page) and an "Add parameter" list (REQ-012–014) |
| `Godot/devices/DeviceViewFactory.gd` | `_scene_for`: for `ViewType.Panel`, return the SimpleView scene when `device.uses_simple_view()`, or when the instance has Simple mode on |
| `Godot/devices/device_lane/DevicePanel.gd` + `.tscn` | Load the panel view when there's a registered one **or** a Simple View. Add a "Simple" toggle to `TabButtons`, shown only when `has_panel_view()`, which swaps between the custom and Simple panel views. The toggle state is stored per device id with `Sonara.set_config("devices/simple_view/<id>", bool)` |
| `Godot/tests/test_simple_layout_generator.gd` (new) | REQ-002–008 |
| `Godot/tests/test_simple_layout_model.gd` (new) | REQ-010, REQ-016, REQ-017, JSON round-trip |
| `.cursor/rules/godot-device-views.mdc` | Section on the Simple View: where it lives, the fallback rule, the layout format |
| `TODO.md` | Backlog entry |

## Migration and compatibility

- **Projects:** unchanged. Layouts aren't stored in projects.
- **`plugins.json`:** entries without `features` load with `[]`. The next scan fills them in.
- **Engine ↔ Godot skew:**
  - An older engine sends short `param/info` and `/plugin/info` messages, and Godot falls back to defaults.
  - A newer engine with an older Godot sends extra trailing args, which the old parsers ignore
    (they index by position and check `size()`).
- **Plugin parameters that were floats and now come through as enum/bool:** automation and
  saved values are normalized already, so the stored values still map correctly.
- **Layout files:** have `"version": 1`. When the version is unknown, the file is treated like one
  that failed to parse (REQ-017).

## Test plan

- **Unit (engine):** `cargo test param_info` — a new test in `lifecycle.rs` (or a helper split
  out of it) checks that the stepped → Bool/Enum mapping and the flags copy correctly.
  `cargo test` overall still passes after the `ParamInfo` field additions.
- **Godot:** `godot --headless --path Godot -s tests/test_simple_layout_generator.gd -- --test`
  - `test_kind_inference`: REQ-002 examples
  - `test_control_kinds`: bool / 4-enum / 12-enum / float (REQ-003)
  - `test_hidden_readonly_excluded` (REQ-004)
  - `test_compounds`: xy, eq_band, a partial pair falls back (REQ-005)
  - `test_grouping_module_and_role` (REQ-006)
  - `test_main_page_importance`: reverb mix/decay/size on page 0; 100-parameter synth (REQ-007)
  - `test_no_overlap_in_bounds`: random parameter sets (REQ-008)
  - `test_generate_500_params_under_100ms` (performance NFR)
- **Godot:** `godot --headless --path Godot -s tests/test_simple_layout_model.gd -- --test`
  - `test_roundtrip_json`
  - `test_resize_grid_reflows` (REQ-010)
  - `test_reconcile_param_changes` (REQ-016)
  - `test_corrupt_file_not_overwritten`: writes to a temp dir through an overridable base path (REQ-017)
- **Live** (the engine running with `./run_release.sh`, plus `godot --path Godot`):
  - Dragonfly Hall on a channel: the Simple View shows up; turning a knob is audible and moves the
    parameter-list slider (REQ-001).
  - Parameters that are stepped or hidden look right (REQ-018); `plugins.json` has `reverb` (REQ-019).
  - Pages, edit mode, rename + unit, remove / add back, restart persistence, reset (REQ-009, REQ-011–015).
  - Builtin `delay` gets a Simple View; `SamplerDefaultView` devices show the "Simple" toggle.

## Risks

| Risk | Mitigation |
|---|---|
| `value_to_text` IPC calls for plugins with many stepped parameters slow down loading | Only for ≤ 64 steps. This runs on the background loading thread; log the time taken |
| Only one plugin to test heuristics against | The generic strategy has to produce something usable by itself; strategies only adjust it. Add fixtures under `Godot/tests/fixtures/` with parameter lists dumped from more plugins as they're added |
| Name heuristics mis-group parameters | That's acceptable: layouts can be edited and reset. Module paths take priority whenever a plugin has them |
| Two `PluginParameterInfo` copies drift apart | One task edits both; the live Dragonfly load fails loudly (bincode decode error) if they don't match |
| The DevicePanel fallback changes the behaviour of every device without a view (for example containers) | `uses_simple_view()` returns false for `is_container` devices, and for devices with no visible parameters |
| Envelope parameters are in plugin-specific ranges, while `EnvelopeControl` expects seconds | Map through `normalized_to_value`. If units are unknown, fall back to four knobs, so envelopes are only built when every part has a time unit or a matching name and a min/max range that looks like seconds |

## Open questions

- None blocking tasks.
