# 018: Device modulators

Status: draft, awaiting approval (single phased plan, in place of the usual
requirements/design/tasks split, at Peter's request).

Goal: modulation becomes something a **device instance has**, not something a device is built
with. Any device (builtin, container or CLAP plugin) can carry a small set of modulators, such as
LFOs, envelopes, velocity and keytrack. Each modulator can drive any modulatable parameter of
that device or of any device nested inside it. Modulators are saved with the device in projects
and presets, and are edited in a Modulators foldout in the device panel's left header.

PolySynth stops defining its own modulation sources. It advertises **default modulators**, which
a new instance starts with, and it evaluates modulators per voice where that matters.

## 1. Where things stand (read before starting)

- **ADR-0011** (`docs/adr/0011-modulation-routes-are-device-state.md`): routes are device state,
  sources are owned by the device, and evaluation happens per voice inside the device. Only
  PolySynth implements it. This spec **supersedes the "device owns the sources" half** of that
  ADR (see Phase 0).
- **PolySynth** (`Engine/src/audio/devices/polysynth/`):
  - `modulation.rs` has `ModSource` (six fixed sources) and `ModMatrix`, a fixed-capacity route
    matrix that is already device-agnostic (its header says it should move to
    `audio/modulation.rs`).
  - Filter Env (params 50–53) and LFO 1/2 (60–63, 70–73) are synth parameters. Amp Env (40–43)
    is the synth's VCA.
  - The default patch is Filter Env → Cutoff at +0.35 (`DEFAULT_FILTER_ENV_AMOUNT`).
- **Trait** (`audio/devices/mod.rs`): `mod_sources`, `set_mod_route`, `clear_mod_routes` and
  `mod_routes` all default to "no modulation".
- **Builtin parameters** (`audio/devices/param_table.rs`): `ParamValues<N>` is the source of
  truth for every table-driven builtin. Devices call `params.set(id, norm)` and then convert the
  returned real value into DSP state in a `match` (see `delay.rs` `set_parameter`).
  `ParamSpec::is_modulatable()` already exists (float and automatable).
- **Automation** (`audio/automation.rs`, ADR-0010) writes through `set_parameter_at` and
  restores the captured base when the lane stops. It addresses devices with `DevicePath`
  (`device/{path}/param/{id}`) and resolves them with `channel.device_at_path_mut`.
- **MIDI**: `Channel::dispatch_scheduled_midi` (clip notes) already sends to every top-level
  device. `send_midi_event_to_devices` (live and held notes) sends only to the first device.
  Containers (`chain.rs`) forward to every child.
- **CLAP**: parameters cross IPC as `BlockEvent::param` (`EVENT_PARAM`, normalized) and become
  `ParamValueEvent`s in `plugin_host/audio_thread.rs`. There is no `PARAM_MOD` event anywhere
  yet.
- **Godot**:
  - `DeviceInstance.mod_routes` and `Device.mod_sources` / `default_mod_routes` hold the routes
    and sources.
  - The assign UI lives in `SimpleView` / `SimpleControl`, with the shared drawing and drag
    logic in `components/ModDisplay.gd`.
  - The DAWproject exporter reports `mod_routes`.
  - `DevicePanel.gd`'s LeftHeader has the View / Simple / Parameters / CCs / File tabs (one
    ButtonGroup) above the content panes.
- The engine has **no stable device IDs**. Everything is addressed by `DevicePath`.

## 2. Decisions (settled, don't revisit)

### Model

- A **modulator** belongs to one device instance. It has:
  - a `mod_id` (u8, allocated by Godot, unique within the device and stable across saves);
  - a `kind` (`lfo`, `adsr`, `ad`, `velocity`, `keytrack`, `random`);
  - its own parameters, defined by its kind's `ParamTable`;
  - a list of **routes**.
- A **route** is (`target`, `amount`):
  - `target` is a parameter on the owning device, on a device nested inside it (a relative
    `DevicePath`), or on another modulator of the same device.
  - `amount` is −1..1 in normalized units, as in ADR-0011.
  - The source's polarity comes from the kind: LFO, keytrack and random are bipolar; envelopes
    and velocity are unipolar.
- **Modulator parameters are real parameters.** They can be automated as
  `device/{path}/mod/{mod_id}/param/{id}`, and other modulators can target them (Phase 9). This
  is where LFO speed and sync live.
- **Capacity:** 8 modulators and 64 routes per device instance, preallocated. Enums and bools
  are never modulatable.
- **Macros and "remotes"** (a Bitwig-style knob page for containers) are a separate feature and
  out of scope.

### Evaluation: mono in the host, poly in the device

- **Mono path (any target).** The engine evaluates the device's modulators once per control
  step and applies `effective = clamp(base_or_automation + Σ amount × source, 0, 1)` as a
  **modulation offset** next to the base value.
  - The base value is never written, and the modulated value is never echoed or saved
    (ADR-0010 and ADR-0011).
  - Note-driven modulators on the mono path follow the device's note stream: an envelope
    retriggers per note-on and releases when the last note is released; velocity and keytrack
    take the last note.
- **Poly path (only for a poly-capable device's own parameters).** A device that reports
  `supports_voice_modulation()` receives the modulator definitions and the routes into its own
  parameters. It runs one instance of each note-driven modulator per voice, using the shared DSP
  in `audio/modulation/`. Those routes skip the mono path. PolySynth is the only such device in
  v1.
- **Control rate:** 64 frames. Builtin devices with active routes are processed in sub-blocks
  of up to 64 frames, and MIDI offsets are rebased per sub-block. CLAP devices keep whole blocks
  and get frame-stamped `PARAM_MOD` events, so async `begin_block` / `finish_block` is
  untouched.
- **Engine placement:** a transparent wrapper, `ModulatedDevice`, holds the inner device plus
  its modulators and routes.
  - It is inserted when a device gets its first modulator and removed when it loses the last
    one, so devices without modulators cost nothing.
  - It forwards every trait method, and `as_any_mut` and `as_container(_mut)` return the inner
    device's, so the existing downcasts (`SubprocessClapAdapter`, `ClapDeviceAdapter`) keep
    working.
  - It moves with the device on reorder and drag, so routes never need re-keying.

### MIDI flows through everything (as in Bitwig)

- Live and held notes go to every device in the chain, like scheduled notes already do.
- Audio effects ignore notes (the trait default). Future note effects will rely on this.
- Only devices with MIDI ports, or with note-driven modulators, are woken by a note
  (`mark_activity`), so a sleeping reverb stays asleep.

### Targets

- **Builtins** opt in per parameter through `ParamSpec::is_modulatable()`. A new `ParamInfo`
  flag, `is_modulatable`, is sent in `/builtin/info` and `param/info`.
- **CLAP:** a parameter whose flags include `CLAP_PARAM_IS_MODULATABLE` gets `PARAM_MOD` events.
  - The amount is in plain units: `offset_norm × (max − min)`, which needs the linear
    normalization `entry.denormalize` uses (check this in Phase 5).
  - Parameters without the flag are not offered as targets. There is no destructive fallback.
- **Containers' own parameters** (Chain volume, Layer slot volume) are not modulatable in v1.

### UI

- A new **Modulators** tab in the DevicePanel LeftHeader, in the same ButtonGroup as Parameters.
  - Its pane has two columns: a grid of modulator tiles with a **+** button (a menu of kinds)
    on the left, and the selected modulator's settings on the right.
  - Envelope kinds show `EnvelopeControl`. The LFO shows Rate, Sync, Shape, Retrigger and
    Phase knobs. Velocity and keytrack have no settings.
- Each tile has a name, a colour (its `ModDisplay` source colour, by tile order) and a
  **wire button** that toggles assign mode.
  - While assign mode is active, the button pulses. Every modulatable control of the device and
    its descendants (custom views, SimpleView, ParameterList) shows `ModDisplay` drag-to-amount.
  - Esc, the wire button again, or picking another modulator ends it.
- **Right-clicking a tile** opens a context menu: one entry per route (target name and amount)
  with a disconnect action, then Rename, Duplicate and Delete. The pane itself doesn't list
  routes.
- The collapsed header shows a small mark when the device has modulators, so modulation is
  never invisible.
- **Later (Phase 9):** live wave and envelope-position displays, knob animation, right-clicking
  a knob to see its modulators, and modulators driving other modulators.

### Persistence

- `DeviceInstance.modulators` is saved in projects and presets. Each entry is
  `{mod_id, kind, name, params: {id: norm}, routes: [{target, amount}]}`.
- The route target is a string: `param/{id}`, `child/{i.j…}/param/{id}` or
  `mod/{mod_id}/param/{id}`.
- **DAWproject:** modulators stay in Sonara's own `State` JSON. The transfer report entry
  `mod_routes` becomes `modulators`.
- **Migration:** none, as in spec 011 (old projects load PolySynth with its default
  modulators). See Open questions.

### Modulator kinds (v1)

Parameter IDs follow the blocks-of-ten convention inside each kind's own table.

| Kind | Polarity | Parameters (default) |
|---|---|---|
| `lfo` | bipolar | Shape (Sine, Triangle, Saw, Square, S&H; Sine), Rate (0.02–40 Hz, log; 2 Hz), Sync (Off, 4/1 … 1/32 straight, dotted and triplet; Off), Retrigger (Free, Note; Free), Phase (0–360°; 0) |
| `adsr` | unipolar | Attack, Decay, Release (0.5 ms–10 s, skew 4; 5 ms, 300 ms, 300 ms), Sustain (0–1; 0.5) |
| `ad` | unipolar | Attack, Decay (0.5 ms–10 s, skew 4; 5 ms, 300 ms). One-shot: ignores note-off |
| `velocity` | unipolar | none |
| `keytrack` | bipolar | none (C3 = 60 = 0, ±1 at ±60 semitones, as in PolySynth today) |
| `random` | bipolar | none (new value per note-on) |

Synced LFO phase comes from the transport position in beats (`dsp/tempo_sync.rs`), so it stays
locked across seeks. A free LFO advances on its own.

---

## Phase 0: decisions on paper

- [x] New ADR `0014-modulators-are-device-instance-state.md`:
  - Status: accepted. It supersedes ADR-0011's "device owns the sources".
  - Record:
    - modulators belong to the instance, and the device supplies only defaults;
    - the mono and poly evaluation split;
    - the `ModulatedDevice` wrapper and why it was chosen over per-device storage (no stable
      IDs, and it moves with the device);
    - modulation offsets next to the base value;
    - MIDI to every device.
  - Mark ADR-0011 "Superseded in part by 0014".
- [x] `CONTEXT.md`, Modulation section: replace **Modulation source** with **Modulator**, and
  add **Modulator kind**, **Mono / poly modulation** and **Modulation offset**. Keep **Route**
  and **Amount**.
- [x] `TODO.md`: point the Modulation item at this spec.

**Done when:** the ADR and glossary are reviewed.

## Phase 1: shared modulator DSP and kind tables (engine only)

- [x] New module `audio/modulation/`:
  - `kinds.rs`: a `ParamTable` per kind (the table above), plus `ModulatorKind`, `id()`,
    `name()`, `bipolar()` and `from_id()`.
  - `lfo.rs`, `envelope.rs`: move the LFO and envelope state out of `polysynth/voice.rs` and
    `dsp/lfo.rs`.
  - `matrix.rs`: `ModMatrix` moved from `polysynth/modulation.rs`. Its routes point at a
    modulator slot instead of a `ModSource` index.
- [x] `ModulatorState`: a `Copy`, fixed-size block holding the kind, `ParamValues` and the
  runtime state (phase, envelope stage and level, held-note count, last note and velocity,
  random value). It has:
  - `note_on(note, vel, frame)`, `note_off(note, frame)`;
  - `advance(frames, transport) -> f32`, which returns the value at the end of the step;
  - `reset()`.
- [x] Tests:
  - the synced LFO period at 120 BPM (carried over from PolySynth);
  - free vs. note retrigger;
  - ADSR and AD stage times within ±5 %;
  - the mono envelope retriggers per note-on and releases on the last note-off;
  - keytrack and velocity mapping;
  - no allocation in `advance` (the existing `rt_debug` checks).

**Done when:** PolySynth still passes all its tests while using the moved LFO and envelope code.

## Phase 2: modulation offsets on builtin devices (engine only)

- [x] `ParamValues<N>` gets `offset: [f32; N]`:
  - `set()` returns the real value of `clamp(norm + offset)`, and `get()` still returns the
    base;
  - new `set_offset(id, off) -> Option<(slot, real)>`;
  - new `effective_norm_at(slot)`.
- [x] Trait: `fn set_param_mod(&mut self, param_id, offset: f32)` (default: ignore) and
  `ParamInfo.is_modulatable` (default false; table devices take it from the spec).
- [x] Refactor every table-driven builtin so the `match` in `set_parameter` becomes
  `fn apply(&mut self, id, real)`, called from both `set_parameter` and `set_param_mod`.
  - The devices: delay, eq, compressor, filter, chorus, phaser, reverb, utility, multiband,
    the drums (`DrumHost` plus the shared globals), polysynth, and sfizz if it is table-driven
    (otherwise it is left out).
  - The existing smoothers (`set_target`) absorb control-step jumps.
- [x] `effect_conformance.rs` / `drum_conformance.rs` add a check for every modulatable
  parameter: the offset changes the output, `get_parameter` is unchanged, and offset 0 restores
  the base output exactly.
- [x] `/builtin/info` and `param/info` send `is_modulatable`. In `osc-protocol.md`, add the
  field.

**Done when:** conformance passes for every builtin, and automation tests are unchanged.

## Phase 3: `ModulatedDevice`, the mono path and MIDI pass-through (engine only)

- [x] `audio/modulation/host.rs`: `ModulatedDevice { inner, mods: [ModulatorState; 8],
  routes: ModMatrix, resolved targets, control buffer, midi queue }`.
  - **Forwarding:** every `AudioDevice` method forwards to `inner`. `as_any_mut`,
    `as_container` and `as_container_mut` return the inner device's.
  - **Note intake:** `send_midi_event` feeds the modulators and queues the event (fixed
    capacity of 256; overflow is dropped with a rate-limited `warn!`).
  - **Process, builtin inner:**
    1. evaluate the control points for the block (every 64 frames);
    2. for each sub-block, apply the summed offsets per target through `set_param_mod`
       (routes into child devices resolve with `device_at_path_mut` from the inner container);
    3. hand over the queued MIDI with rebased offsets;
    4. call `inner.process_block` on that slice of the input and output buffers.
  - **Process, CLAP inner** (`begin_block` returns true): no splitting; the offsets go out as
    frame-stamped `PARAM_MOD` events (Phase 5). Until Phase 5, CLAP targets are rejected.
  - Modulators keep advancing while the inner device sleeps.
  - `set_transport` keeps a copy for synced LFOs and forwards it.
- [x] Wrap and unwrap happen on the command thread. The wrapper is built with the lock
  released, then the inner box is swapped in under the lock (two pointer moves). Removing the
  last modulator unwraps the same way and resets the offsets to 0 first.
- [x] Routes to a parameter on another modulator are accepted and stored, but not evaluated
  until Phase 9.
- [x] `Channel::send_midi_event_to_devices` sends to every top-level device. `mark_activity` is
  called only where `midi_ports()` is non-empty or the device is a `ModulatedDevice` with a
  note-driven modulator.
- [x] `AutomationTarget` parses and formats `device/{path}/mod/{mod_id}/param/{id}`. Applying
  and releasing it sets the modulator parameter on the wrapper.
- [x] Tests:
  - a wrapped device behaves identically with no routes (run the conformance suites over
    wrapped devices);
  - an LFO on a delay moves the output;
  - routes into a Layer child resolve through `as_container`;
  - sub-block MIDI rebasing is sample-accurate (a drum trigger at frame 100 of a 512-frame
    block);
  - a wrapped device survives a move within the chain;
  - live notes reach an effect without waking a sleeping one that has no modulators.

**Done when:** the engine tests pass and a hand-made OSC session (Phase 4) wobbles a filter
cutoff.

## Phase 4: commands, OSC and state (engine only)

- [x?] `AudioCommand`s and `osc/server.rs` handlers, all under `/channel/{id}/device/{path}`:

  | Address | Args | Effect |
  |---|---|---|
  | `…/modulator/add` | `i:mod_id, s:kind` | Add with default params (wraps the device if needed) |
  | `…/modulator/{mod_id}/remove` | none | Remove it and its routes (unwraps on the last one) |
  | `…/modulator/{mod_id}/param/{id}/value` | `f:norm` | Set a modulator parameter |
  | `…/modulator/{mod_id}/route/set` | `s:target, f:amount` | Add, update or (amount 0) remove a route |
  | `…/modulator/clear` | none | Remove every modulator |
  | `/builtin/modulator_info` → `/builtin/modulator_kind`… → `/builtin/modulator_complete` | | Advertise kinds, polarity and parameter tables, as `/builtin/*` does for devices |

  - Each command echoes the applied state on the same address (the clamped amount, the
    canonical param value), as `mod/set` does today.
  - A route whose target can't resolve or isn't modulatable gets an error `/log` and an echo
    with amount 0.
- [x?] `/builtin/info` replaces `mod_sources` and `default_mod_routes` with `default_modulators`
  (kind, name, params, routes).
- [x?] Remove `mod/set` and `mod/clear` (the four ADR-0011 trait methods go with Phase 6, which
  moves PolySynth over; they are unused by the engine from here).
- [x?] Device `state/get` includes the modulators, for tests and the AI tools.
- [x?] `docs/subsystems/osc-protocol.md`: replace the Modulation routes section.

**Done when:** an `oscsend` script can add an LFO to a filter, route it to cutoff and hear it.

## Phase 5: CLAP targets (engine and plugin_host)

- [x?] Discovery carries `CLAP_PARAM_IS_MODULATABLE` into `ParamInfo.is_modulatable`.
- [x?] `ipc/protocol.rs`: `EVENT_PARAM_MOD = 4`, with `BlockEvent::param_mod(offset, id,
  amount_norm)`.
- [x?] `plugin_host/audio_thread.rs` turns it into a `ParamModEvent`:
  - the amount is `amount_norm × (max − min)` from the param map entry (confirm the
    normalization is linear; if not, use the difference between the denormalized
    `base + offset` and `base`);
  - the Pckn is a wildcard (−1), meaning global, not per note.
- [x?] `SubprocessClapAdapter::set_param_mod_at(id, offset, frame)` queues stamped events into
  the block's input events. Removing a route sends a final 0.
- [x?] After a crash and reload, the wrapper re-sends the current offsets.
- [x?] Test: a unit test in `plugin_host` for the conversion. Manual: an LFO on a modulatable
  parameter of a known plugin (e.g. Surge XT filter cutoff) moves without the plugin's knob
  value changing. *(Unit tests done; the manual plugin check is still pending.)*

**Done when:** CLAP modulation works and parameters without the flag are refused.

## Phase 6: PolySynth on the new system (engine only)

- [x?] New trait method `supports_voice_modulation() -> bool` and
  `set_voice_modulation(&VoiceModSpec)`. `VoiceModSpec` is a `Copy` snapshot of the kinds,
  params and the routes whose target is the device itself (`param/{id}`).
  - The wrapper calls it on every change to a modulator or route, and skips those routes on
    the mono path.
  - Routes into PolySynth from a container above it stay mono.
- [x?] PolySynth:
  - it runs one `ModulatorState` per voice per modulator from the shared DSP;
  - per voice, `mod_norm = clamp(effective_norm (base + mono offset) + Σ poly, 0, 1)`;
  - a free LFO with Retrigger = Free stays phase-locked across voices (one shared phase), as
    it does today.
- [x?] Remove the Filter Env and LFO 1/2 parameters (50–53, 60–63, 70–73), `ModSource` and the
  old route matrix. Amp Env stays a synth parameter.
- [x?] `default_modulators` for PolySynth:
  - "Filter Env" (`adsr`, A 2 ms, D 400 ms, S 0, R 300 ms) → Cutoff +0.35;
  - "LFO 1" and "LFO 2" (`lfo`, 5 Hz, Retrigger Note), with no routes.
- [x?] Tests: port the existing modulation tests. Two notes started 100 ms apart have different
  filter-envelope values on the same block. The CPU benchmark (`cpu_full_budget`) stays within
  10 % of the current number.

**Done when:** a new PolySynth sounds the same as before with its default modulators.

## Phase 7: Godot model, registry and persistence

- [x?] `data/Modulator.gd` (RefCounted): `mod_id`, `kind`, `name`, `params: Dictionary[int,
  float]`, `routes: Dictionary[String, float]` (target → amount). The setters go through the
  owning `DeviceInstance`.
- [x?] `DeviceRegistry`:
  - learns the modulator kinds from `/builtin/modulator_info` and keeps their parameter
    descriptors (as `DeviceParameter`);
  - `Device.default_modulators` replaces `mod_sources` and `default_mod_routes`;
  - `is_modulatable` is stored on `DeviceParameter`.
- [x?] `DeviceInstance`:
  - `modulators: Array[Modulator]`;
  - `add_modulator(kind) -> Modulator` (allocates the lowest free `mod_id`, up to 8),
    `remove_modulator`, `set_modulator_param`, `set_route_amount(mod_id, target, amount)`,
    `get_routes_into(target) -> Array` (for `ModDisplay` and Phase 9);
  - signals `modulator_added`, `modulator_removed`, `modulator_changed`, `route_changed`;
  - echoes are handled like `_pending_mod_echoes` today;
  - `sync_to_engine()` sends `modulator/clear`, then every modulator, its params and its
    routes;
  - new instances copy `default_modulators`;
  - remove `mod_routes` and `get_mod_sources`.
- [x?] Target strings for nested devices are built relative to the owner:
  `child/{i.j}/param/{id}`. Moving or removing a descendant rewrites or drops the affected
  routes in the model, which then re-sends them. The engine wrapper keeps paths relative to
  itself, so only moves *inside* the owner change them.
- [x?] Project save/load, preset save/load (`test_device_presets.gd`), and DAWproject export
  (`State` JSON plus the transfer report key `modulators`). The automation lane target
  `device/{path}/mod/{mod_id}/param/{id}` is handled in the automation lane UI's target list.
- [x?] Tests (`Godot/tests/test_device_modulators.gd`, replacing `test_device_mod_routes.gd`):
  - add, remove and set send the right OSC;
  - an echo doesn't re-send;
  - project and preset round-trip;
  - defaults are applied on create but not on load;
  - moving a child rewrites the route targets;
  - the export report lists modulators.

**Done when:** the model tests pass and a project with modulators reloads identically.

## Phase 8: Modulators UI

- [ ] **Tab:** a Modulators button in the LeftHeader `TabButtons` (in the ButtonGroup, with an
  icon from the existing set) opens a `ModulatorsPane` beside Parameters. The tab is available
  for every device, including plugins and containers. Collapsed headers show a small dot when
  `modulators` is non-empty.
- [ ] **`devices/modulators/ModulatorsPane`**: an `HBox` holding the tile grid
  (`GridContainer`, 2 columns, plus a **+** `MenuButton` listing the registry's kinds) and a
  detail column.
  - The detail column builds controls from the kind's descriptors with the existing component
    set: `EnvelopeControl` for `adsr` and `ad`, and knobs plus an enum selector for `lfo`.
  - Selecting a tile shows its detail. The selection is remembered per instance in memory.
- [ ] **`ModulatorTile`**: name label, colour strip (from `ModDisplay.SOURCE_COLORS` by index),
  wire `Button`.
  - Toggling the wire button starts or ends assign mode.
  - The pulse is a `Tween` on modulate alpha while active.
  - Double-click renames. Right-click opens a `PopupMenu`: one entry per route
    ("Cutoff +35 %", with a submenu or trailing action to disconnect), a separator, then
    Rename / Duplicate / Delete.
- [ ] **Assign mode:** a small shared state object (e.g. `devices/modulators/ModAssign.gd`, an
  autoload-free static holder with a signal) holds `{owner: DeviceInstance, mod_id}`.
  - `SimpleControl`, the custom views' knobs and `ParameterList` rows check whether their
    `DeviceInstance` is the owner or one of its descendants, and whether the parameter
    `is_modulatable`. If so, they enter `ModDisplay` assign mode (drag sets the amount through
    `set_route_amount`).
  - Esc, clicking the wire button again, or deleting the modulator ends assign mode.
  - Move the existing SimpleView assign code over to this state and delete what's left of the
    old per-source buttons.
- [ ] **`ModDisplay` ranges:** controls get their ranges from `get_routes_into(target)` on
  every device between them and the root that has modulators (owner chain lookup), so a
  container's LFO shows on a child's knob.
- [ ] Remove the PolySynth LFO and Filter Env sections from `SynthStrategy` if anything there
  still names them. Because the parameters are gone, SimpleView drops them by itself.
- [ ] Update `docs/subsystems/godot-device-views.md` and `godot-ui-components.md`.
- [ ] Tests:
  - the pane builds tiles from the model and the + menu adds them;
  - the context menu lists the routes;
  - assign mode reaches a child device's controls but not a sibling's;
  - Esc exits assign mode.

**Done when:** a manual check (add an LFO to a Layer, assign it to a child PolySynth cutoff
and to a reverb mix, disconnect one from the tile menu) works.

## Phase 9: later additions (separate follow-ups, not v1)

- [ ] Live displays: the LFO wave with a moving dot, the envelope position, and knobs
  animating their modulated value. This needs a per-device data stream of modulator values
  and summed offsets at about 20 Hz, subscribed in `_on_view_shown`. It replaces spec 011
  Phase 6.
- [ ] Right-clicking any knob lists the modulators affecting it (name, amount, disconnect),
  built on `get_routes_into`.
- [ ] Modulator → modulator routes (an envelope driving LFO rate), evaluated in dependency
  order inside the wrapper, with cycles rejected when the route is set.
- [ ] More kinds: AR and AHDSR envelopes, a step sequencer, an audio-follower, MIDI CC and
  pitch bend as sources.

## 3. Out of scope

- Macros and remotes (a container knob page).
- Per-note polyphonic modulation of CLAP plugins (`PARAM_MOD` with a note ID and voice-info
  tracking).
- Channel-level or track-level modulators, and modulating mixer parameters (volume, pan,
  sends).
- Modulating a container's own parameters.

## 4. Phase dependencies

```
0 → 1 → 2 → 3 → 4 → 6 → 7 → 8 → 9
                  └→ 5 (any time after 4)
```

Between Phase 4 and Phase 8, the old PolySynth assign UI in SimpleView doesn't work (the
`mod/*` messages are gone). That's acceptable on this branch.

## Open questions

1. **Migration:** should old projects and presets with PolySynth `mod_routes` and LFO / Filter
   Env values be converted into modulators on load? It's a small loader shim in Godot. The
   default in this plan is no, as in spec 011.
