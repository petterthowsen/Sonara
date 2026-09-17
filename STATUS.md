# Sonara DAW - Project Status

## Simple View (docs/specs/004-simple-view)

Phase 1 (engine metadata end to end, T-001–T-005) implemented. `PluginParameterInfo` (both IPC
copies) carries `is_stepped`, `is_hidden`, `is_read_only`, `is_bypass`, `module` and `step_labels`;
`plugin_host/commands.rs` fills them from CLAP's `ParamInfoFlags` and `value_to_text` (checked
against Context7 `/prokopyl/clack`: `module: &[u8]` on `ParamInfo`, `value_to_text(plugin, param_id,
value, buffer)` on `PluginParams`). `ParamInfo` gained the same four flags/module fields, mapped by
the new pure helper `plugin_param_to_info` in `lifecycle.rs` (2 steps → Bool, 3–64 → Enum, else
Float), with 4 unit tests. `param/info` now sends `[..., param_type, flags, module, enum_count,
enum_values...]`; `/plugin/info` gets a trailing comma-joined `features` string from
`PluginDescriptor.features` (collected in `discovery.rs`). Godot's `DeviceParameter`, `Device` and
`DeviceRegistry` parse all of this, with `plugins.json` gaining a `"features"` key.

Phase 2 (layout model and generator, T-006–T-011) implemented under `Godot/devices/simple_view/`,
all headless. `SimpleLayout` (JSON model, `validate`, `find_free_rect`, `resize_grid`, `reconcile`),
`SimpleLayoutStore` (`path_for` = sanitized id + md5 prefix, `load_or_generate(device, params)`,
`save` via temp file + rename, `regenerate`, `base_dir_override` for tests), `DeviceKind`,
`ParamClassifier`, `CompoundDetector`, `GridPacker` (groups packed as rectangular blocks, first fit)
and `SimpleLayoutGenerator`, plus five strategies extending `GenericStrategy`.
- Controls carry an optional `"group"` id (added to design.md) so group rects can be recomputed.
- Module paths only drive grouping when they're hierarchical or shared: Dragonfly's modules are one
  flat name per parameter, so it falls back to the reverb strategy's roles.
- Everything fits on one 6×4 page → a single "Main" page; otherwise Main holds the top items
  (importance ≥ 0.6, at most half a page of cells) and the rest go on group pages.
- The Dragonfly fixture was built from the live `param/info` debug lines in `Godot/logs/last.log`.
- `SimpleLayoutStore` looks `Sonara` up at runtime: headless test scripts compile before autoloads
  exist, so a bare `Sonara` identifier fails to compile there.
- Verified: `tests/test_simple_layout_model.gd` and `tests/test_simple_layout_generator.gd` pass
  (500 params generate in ~32 ms), and `tests/run_all.sh` passes.

Phase 3 (view and integration, T-012–T-013) implemented under `Godot/devices/simple_view/`:
- `SimpleUnits.gd`: display formatting for a control's unit override (`%`, `dB`, `ms`, `s`, `Hz`→kHz
  above 1000, empty → `DeviceParameter.format_value`). Covered by the new `test_simple_units` in
  `tests/test_simple_layout_model.gd`.
- `SimpleControl.gd` + `.tscn`: one grid cell — a title label (the layout's `label` override, else
  the bound parameter's name) plus the inner control for every `SimpleControlKinds` kind: knob,
  slider, toggle (CheckButton), segmented (a row of toggle Buttons on one ButtonGroup), dropdown
  (OptionButton), xy (`XYSlider`), envelope (`EnvelopeControl` + an `Envelope` resource ranged from
  the attack/decay/release parameters' own min/max) and eq_band. Controls call
  `DeviceInstance.set_parameter_normalized` and refresh from `SimpleView._on_device_parameter_changed`
  (inherited from `DeviceView`), never sending OSC directly.
  - **Deviation**: `design.md`'s eq_band sketch ("two knobs over a mini XYSlider") doesn't fit the
    2×1 footprint `SimpleControlKinds.FOOTPRINT` actually gives eq_band. Built as three small knobs
    (freq, gain, q) in a row instead — functional, but worth a design pass once a plugin with real
    EQ-band parameters is available to look at.
- `SimpleView.gd` + `.tscn`: the Panel `DeviceView`. Loads via
  `SimpleLayoutStore.load_or_generate(instance.device, instance.get_parameters())` in `_on_bind`,
  positions one `SimpleControl` per layout control on a plain `Control` grid (`rect * cell_size`,
  no `GridContainer`, since cells must sit at exact `[col,row,w,h]` positions), draws a background
  panel + title label per group, and shows a `TabBar` when there's more than one page. Subscribes to
  `DeviceInstance.parameters_updated` in `_on_view_shown`/unsubscribes in `_on_view_hidden` and
  rebuilds (which re-reconciles the layout, REQ-016) when it fires. Edit mode (T-014/T-015) is not
  implemented — the view is read-only.
- `Device.uses_simple_view(params = [])`: false for containers; otherwise true once at least one
  visible parameter (`ParamClassifier.is_visible`) is found in `params` (an instance's own list) or,
  failing that, `Device.parameters`, so a plugin with no parameters advertised yet correctly reports
  false until they arrive.
- `DeviceViewFactory.create`: for a Panel view, returns the generated `SimpleView` scene instead of
  the registered one when `Device.uses_simple_view()` and either the device has no Panel view of its
  own, or it does but `Sonara.get_config("devices/simple_view/<id>", false)` is on.
- `DevicePanel`: a new "Simple" toggle button (gauge icon) next to View/Window in the left tab
  column, visible only when the device has both its own Panel view and visible parameters. Toggling
  it writes `Sonara.set_config("devices/simple_view/<id>", pressed)` and reloads the panel view via
  the factory. `bind_to_device` and `_on_device_parameters_updated` (the async-parameter-arrival
  path for plugins/SFZ) both now load a Panel view whenever `has_panel_view() or uses_simple_view()`,
  not just `has_panel_view()`, and re-evaluate the two toggles' visibility each time.
- Verified: `tests/run_all.sh` passes (32 scripts including the two Simple View suites); all
  Simple View `.gd`/`.tscn` files load without parse errors in a headless smoke load. Scenes were
  built and saved through the Godot MCP tools, not hand-edited.

UI fixes after the first live look: `SimpleControl` clips to its cell and drops its body minimum
size, titles ellipsize (full name in tooltip), dropdowns don't widen to the longest item, and a
segmented control whose labels don't fit becomes a dropdown. `SimpleView` inserts a 14px header
strip above each row where a titled group starts, so group titles no longer cover control titles.
Verified live: rendering looks right.

Edit mode (T-014/T-015) is deferred to `TODO.md`. `OSC_PROTOCOL.md` (T-016) and the Simple View
section in `.cursor/rules/godot-device-views.mdc` (T-017) are written.

### Not verified (T-013 live checks)
- A device with a registered Panel view (e.g. the Sampler) shows the "Simple" toggle and switches views.
- Restarting Godot logs "loaded layout" for Dragonfly, and a hand-edited `rect` in
  `~/.config/sonara/device_layouts/` shows up after reopening.
- Page tabs on a device with more than 24 cells of controls.
- eq_band rendering against a real plugin.

### Working
- `cargo build --release` builds both `engine` and `plugin_host`; `cargo fmt` clean.
- `cargo test --lib --bins`: all 99 tests pass (1 ignored), including the 4 new
  `plugin_param_to_info` cases. The `SharedMemoryLayout` doctest failure is pre-existing
  (confirmed via `git stash`), unrelated to this change.
- `Godot/tests/run_all.sh`: all existing scripts still pass, confirming no GDScript parse errors.
- Live (T-001, T-003, T-005): loaded Dragonfly Hall Reverb on a channel with the rebuilt engine.
  All 18 parameters arrived with no IPC decode error and no warnings; Godot logged each one's
  `param_type` and `module` (e.g. `module 'dry_level'` — Dragonfly's modules are flat, not
  hierarchical, which is the plugin's own data, not a bug here).
- Live (T-004): `oscsend localhost 7000 /plugin/scan` against the running engine, then
  `~/.config/sonara/plugins.json` for `michaelwillis.dragonfly.hall` shows
  `"features": ["audio-effect", "reverb", "stereo"]`.

### Not verified
- The stepped-parameter UI acceptance from T-005 (checkbox/dropdown in the parameter list) — none
  of Dragonfly Hall's 18 parameters are stepped, so that path wasn't exercised live. Covered by
  the `plugin_param_to_info` unit tests (2→Bool, 5→Enum) but not seen rendered. Needs a plugin
  with stepped parameters to confirm end to end.

## Parameter automation (docs/specs/003-automation)

Phases 1 and 2 (engine) are in. Lanes live on `Track`, resolve once per buffer in
`audio/automation.rs`, and apply as overrides that never write a base value.

### Phase 5 (arranger UI, T-018 – T-026) implemented, not yet live-verified
All rows share the vertical order from `arranger/AutomationRowOrder.gd` so the tracklist
header and the timeline row stay aligned. Point edits go through `history/AutomationActions.gd`
(one undo step per gesture, drags merge), and `Timeline` routes cut/copy/paste/duplicate/delete to
the automation manager whenever a point selection or range is active, else to the clip path.
Unresolved lanes (REQ-024) are marked and drawn distinctly, stop syncing to the engine but keep
every point (`Track.refresh_automation_resolution`, driven by the linked channel's structure
signals), and log one warning per transition.

- `tests/run_all.sh`: all 32 scripts pass, including the new
  `tests/test_automation_range_ops.gd` (T-025: 1-bar copy → paste at bar 3 lands shifted with
  curves intact, overwrite inside the span, undo restores, anchor priority).
- After adding new `class_name` scripts, run `godot --headless --path Godot --editor --quit` once
  or the whole headless suite fails on the stale `global_script_class_cache.cfg` (22 spurious
  failures this session until regenerated).
- Still open: every "Verify: live" item in tasks.md T-018–T-026 (needs the engine running and a
  human ear), plus phase 6 (T-027 docs) and the phase-7 walk (T-028).

### Working
- `cargo test`: 89 unit tests pass, 15 of them new in `audio/automation.rs`. `cargo fmt` clean.
- Live (OSC only, no UI yet): all seven `/track/{id}/automation/*` addresses dispatch and apply
  against the running engine; an unparseable target logs exactly one warning and is dropped; no
  `PluginParameterValueChanged` echo appears in the log.

### T-010 finding — the 5 ms fader smoothing is acceptable, unchanged
`Channel::get_smoothed_gain`'s one-pole has tau = 5 ms, so a full-scale step on an automated
volume lane reaches 90% in ~11.5 ms and 99% in ~23 ms (measured by
`automation_volume_step_settles_within_the_fader_smoothing`, which pins those numbers). At 120 BPM
a sixteenth note is 125 ms, so a step lane reads as a fast fade rather than a gate, and the
smoothing that prevents zipper noise on a moving lane stays in place. No change made to
`types.rs` or `mixing.rs`. **Still to confirm by ear** — a step lane alternating 0.0/1.0 every
beat should sound soft-edged, not smeared; if it smears, shorten the constant only while
`automation_volume` is `Some`.

### Not verified
- Everything audible: no UI exists yet, so nothing has been heard. The phase-7 walk (T-028)
  covers it.
- Plugin IPC under a moving lane (the dedup is unit-tested, the ring is not).

## Audio thread stalls (shared `Arc<Mutex<EngineState>>`)

The audio callback blocked on `state.lock()` while the command thread held the lock for the whole of `process_command`, so anything slow in a command froze audio.

Phase 1 (done, needs live testing): shared state kept, slow work moved outside the lock in `CommandWorker`, bounded `try_lock` (1 ms, then silence) in the callback, per-buffer allocations and debug logging removed from the callback.
Phase 2 (later): audio thread owns its state, lock-free command queue, removed objects dropped off-thread.

### Stalls that were under the lock
- `ScanPlugins`: dlopens every `.clap` bundle
- `OpenPluginGui` / `ClosePluginGui`: IPC round-trip, 5 s / 2 s timeouts
- `SetDeviceActive`: two IPC round-trips with no timeout
- Dropping a `SubprocessClapAdapter` (remove device, clear devices, remove channel, clear project): GUI close + subprocess shutdown
- `LoadAudioClip`: `samples.clone()` of the whole file plus log formatting
- `AdvertiseBuiltinDevices`: builds temporary devices
- On the audio thread itself: blocking `process.lock()` in `poll_parameter_changes`, which GUI IPC holds for seconds

### Working
- `cargo build --release` passes with no new warnings
- `cargo test --release`: all unit tests pass, including 2 new routing tests. The 2 send tests already failed at HEAD (gain warm-up too short) and are fixed.

- Live: audio plays and routes through master after restarting engine + Godot
- Live: Dragonfly Reverb (CLAP) on a bus, and importing a large audio clip into a new track during playback: stable, no dropouts
- Live: mute and solo; reverb tails on send-fed and routed buses keep ringing after pausing playback
- Live: nested buses (track → bus → bus → master)
- Mixing routes in dependency order (fixes routed-bus tails and double bus processing): 3 new unit tests pass

### Not Working / Not verified
- Live: mute on master now silences output (previously master mute only bypassed its devices)
- Godot doesn't resend the project (init, master channel) when the engine restarts, so restart Godot too
- Stress checks not done yet, while audio plays: remove a CLAP plugin, open/close its GUI, scan plugins. Listen for dropouts.
- Doctest in `ipc/protocol.rs` fails (diagram in a doc comment parsed as Rust). Already broken, file untouched.
