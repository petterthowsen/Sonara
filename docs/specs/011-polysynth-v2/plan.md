# 011 — PolySynth v2 and device modulation: implementation plan

Status: draft, awaiting approval (single phased plan, in place of the usual
requirements/design/tasks split, at Peter's request).

Goal: a stock synth that covers pads, leads, basses and plucks without becoming a Serum. It
adds a filter, a second envelope, LFOs, unison, glide and noise, plus Bitwig-style modulation
where a source button arms assign mode and dragging a control sets the amount.

Inputs: `docs/synth-research.md` (CPU discipline, anti-aliasing, visible drag-to-assign
modulation, musical filters) and `docs/daw-device-research.md` (resonance compensation, drive,
simple by default).

## Decisions already made

- Modulation routes are **device state**. They cross OSC as a new `{device}/mod/*` message
  family and are stored on `DeviceInstance`. They are not hidden parameters.
- **UI stays on `SimpleView`.** The shared components (`RotaryKnob`, `HorSlider`,
  `VolumeSlider`, `Volumeter`) learn to draw modulation. A custom PolySynth view comes later.
- **No backward compatibility.** Parameter IDs are renumbered freely, and old projects may load
  with defaults.
- **Unison** goes up to 16 per oscillator, with a voice budget of 64 per device. A note costs
  `max(Osc 1 unison, Osc 2 unison)` voices out of the 64 (see Phase 2).
- **Parameter curves:** `ParamInfo` gets `is_logarithmic` (for Hz values) and a new
  `skew: f32` power curve (default 1.0, which is linear) for times and anything that must reach
  exactly 0. The mapping is `real = min + (max − min) · n^skew`. See Phase 1.
- **Every SimpleView envelope** renders as the envelope display with a row of ADSR knobs
  underneath (see Phase 5).

## Target parameter set

Parameters are grouped by `ParamInfo.module` (for example `"Osc 1"` or `"Filter"`), so the
SimpleView sections come out right without relying on name guessing. Ranges are real values.
"log" means the parameter advertises `is_logarithmic`, and "skew" means a power curve (see
Phase 1).

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Osc 1, Osc 2 | Wave | Sine, Triangle, Saw, Pulse | Saw / Pulse |
| | Pulse Width | 5–95 % | 50 % |
| | Octave | −3…+3 | 0 |
| | Semi | −12…+12 | 0 |
| | Fine | ±100 cents | 0 / +7 |
| | Level | 0–1 | 0.8 / 0.0 |
| | Unison | 1–16 | 1 |
| | Unison Detune | 0–100 cents | 20 |
| | Unison Spread | 0–100 % | 50 % |
| Noise | Level | 0–1 | 0 |
| | Color | dark…bright (one-pole tilt) | mid |
| Filter | Type | LP 12, LP 24, HP 12, BP 12 | LP 24 |
| | Cutoff | 20 Hz–20 kHz, log | 2 kHz |
| | Resonance | 0–1 | 0.2 |
| | Drive | 0–24 dB | 0 |
| | Key Track | 0–100 % | 0 |
| Amp Env | Attack, Decay, Release | 0.5 ms–10 s, skew | 2 ms, 300 ms, 200 ms |
| | Sustain | 0–1 | 1.0 |
| Filter Env | Attack, Decay, Release | 0.5 ms–10 s, skew | 2 ms, 400 ms, 300 ms |
| | Sustain | 0–1 | 0.0 |
| LFO 1, LFO 2 | Shape | Sine, Triangle, Saw, Square, S&H | Sine |
| | Rate | 0.02–40 Hz, log | 5 Hz |
| | Sync | Off, 4/1 … 1/32 (straight, dotted, triplet) | Off |
| | Retrigger | Free, Note | Note |
| Voice | Mode | Poly, Mono, Legato | Poly |
| | Polyphony | 1–64 | 16 |
| | Glide | 0–1 s, skew | 0 |
| | Velocity | 0–100 % (amp sensitivity) | 70 % |
| Output | Volume | −inf…+6 dB | −6 dB |

**Modulation sources:** Filter Env, Amp Env, LFO 1, LFO 2, Velocity and Keytrack. All are
per voice. **Destinations:** every `Float` parameter; enums are not modulatable.

**Default patch:** Filter Env → Cutoff at +0.35, so a new instance behaves like a synth
straight away.

---

## Phase 0: fix what's broken (engine only)

Small and independent. Ship it first.

- [x] Fix the waveform round-trip. `get_parameter` divides by 4, but `set_parameter` decodes
      with `* 3.99`, so Saw becomes Square. Add one shared `enum_to_norm`/`norm_to_enum` helper
      pair in `audio/devices/parameter.rs` (or next to `ParamInfo`) and use it for every enum.
- [x] Make the `ParamInfo` defaults match the struct's initial values (Waveform B is currently
      Square in `ParamInfo` and Saw in the struct).
- [x] Size every scratch buffer in `prepare(max_frames)`. Remove the `resize` calls from
      `process_block`.
- [x] Drop the stale "`polysynth` overrides `set_parameter_at`" claim in
      `audio/devices/mod.rs`, or make it true in Phase 1.
- [x] Tests (`mod tests` in `polysynth.rs`):
  - get → set round-trips every parameter;
  - `ParamInfo.default` equals the initial `get_parameter`;
  - a note on/off pair renders, then releases to silence.

**Done when:** the new tests pass and the existing ones stay green.

## Phase 1: sound quality and parameter metadata

- [x] **Band-limited oscillators** in `audio/dsp/oscillator.rs`: PolyBLEP saw and pulse (with
      variable width), and an integrated-pulse or PolyBLAMP triangle. Keep the sine table.
      Remove the naive square.
- [x] **Exponential envelopes** in `audio/dsp/envelope.rs`: a one-pole approach to overshoot
      targets for attack (so it's still roughly linear-looking), decay and release. Keep the
      API. Add a `retrigger_from_current` behaviour so legato and steals don't click.
- [x] **Parameter smoothing:** a small `SmoothedParam` (one-pole or linear ramp over about
      5 ms) in `audio/dsp/`. Use it for level, volume and cutoff, and for pitch once pitch is
      live.
- [x] **Stereo voice path:** voices render into L/R scratch buffers, and the device writes true
      stereo.
- [x] **Real ranges and scaling in metadata.**
  - `ParamInfo` gets real `min`/`max` and a new `is_logarithmic: bool`, and `/builtin/info`
    carries it (`osc/server.rs` around the `/builtin/info` builder).
  - Godot's `DeviceRegistry` uses the advertised flag and falls back to
    `_guess_logarithmic` only for CLAP. This closes the gap ADR-0005 records.
  - **Skew.** Add `skew: f32` to `ParamInfo` (default 1.0), send it in `/builtin/info`, and
    store it on `DeviceParameter`.
    - `normalized_to_value` maps `min + (max − min) · n^skew`, and `value_to_normalized`
      inverts it with `((v − min) / (max − min))^(1/skew)`.
    - A parameter with `is_logarithmic` set ignores skew.
    - Add a matching engine-side helper next to the enum helpers from Phase 0 so devices decode
      with the same formula.
    - CLAP parameters always get 1.0.
    - Envelope times use skew 4 (0–10 s puts 625 ms at mid-knob). Glide uses skew 3 (0–1 s),
      and Glide 0 is exactly off.
    - `EnvelopeControl` drops its private `time_curve` and uses the parameter's own curve, so
      the display and the Phase 5 knobs move at the same rate.
    - Document it in `godot-device-views.md` and ADR-0005's "Consequences" (as an amendment
      note).
    - Tests: engine and Godot round-trip `n → value → n` for skew 1, 3 and 4 at the ends and
      middle of the range, and a Godot test checks that `/builtin/info` carries the skew into
      `DeviceParameter`.
- [x] Tests:
  - An FFT test shows aliasing energy below 16 kHz is at least 40 dB lower than the naive
    version for a C7 saw and pulse at 48 kHz (full band it's about 26 dB with the 4-point
    PolyBLEP used; 2-point managed only 16 dB).
  - Envelope stage times hit their target within ±5 %.
  - Smoothed steps have no discontinuity larger than one ramp step.

**Done when:** a bright saw played high has no audible fold-back, and knob readouts in
SimpleView show seconds and Hz instead of 0–1.

## Phase 2: voice architecture

A restructure of `polysynth.rs`. It will likely split into
`audio/devices/polysynth/{mod.rs, voice.rs, params.rs}`.

- [x] **Shared parameter block:** one `SynthParams` struct owned by the device, which voices
      read by reference. Remove the per-voice parameter copies and `update_voice_parameters`.
      Phase 3's modulation reads the same struct.
- [x] **Preallocated voice pool:** 64 note slots, each holding 16 unison oscillators per
      oscillator. Everything is allocated in `new`/`prepare`.
- [x] **Voice budget:**
  - A note costs `max(unison1, unison2)` voices.
  - Allocation rejects or steals when the total budget would exceed 64, or when the note count
    would exceed Polyphony.
  - Worst case is 64 × 2 = 128 PolyBLEP oscillators per instance.
- [x] **Stealing policy:**
  1. a voice already in release (the quietest first);
  2. otherwise the oldest held note.
  - Stolen voices get a 3–5 ms fade before the new note starts. The simplest version is a
    per-voice "fast release" state; the retrigger is delayed by the fade (queued inside the
    voice).
- [x] **Note ordering:** a per-note counter, not a per-block one.
- [x] **Pitch per block:** the voice computes its frequency every control block from
      note + octave + semi + fine + glide + (later) modulation. Changing a knob now affects
      held notes.
- [x] **Unison:**
  - Detune spreads symmetrically, with slightly uneven offsets to avoid beating in lockstep.
  - Spread pans the sub-voices across L/R.
  - Phases are randomised on note-on.
  - Gain is normalised by `1/sqrt(n)`.
- [x] **Noise:** a xorshift generator per voice, a one-pole tilt for Color, mixed pre-filter.
- [x] **Voice modes:**
  - Mono/Legato use a single voice plus a note stack, so releasing the top note returns to the
    previous held note.
  - Legato doesn't retrigger envelopes. Mono does.
- [x] **Glide:**
  - An exponential slide in the pitch domain over Glide seconds.
  - Poly glides from the last played note. Mono/Legato glide from the current pitch.
  - Glide 0 means no slide.
- [x] Tests:
  - voice budget accounting;
  - the steal order prefers releasing voices;
  - a legato note stack survives out-of-order releases;
  - glide reaches the target pitch in the set time;
  - unison output is stereo, and mono-sums without cancelling at spread 100 %.

Implementation notes:
- Parameters are renumbered in blocks of ten per module (Osc 1 = 0, Osc 2 = 10, Noise = 20,
  Amp Env = 40, Voice = 80, Output = 90), leaving 30/50/60/70 for Phase 3. Names carry the module
  prefix ("Osc 1 Level", "Amp Attack") so they stay unique for automation lanes and AI tools.
  Octave, Semi, Unison and Polyphony are enums (integers, not modulatable).
- Glide is linear in pitch (so exponential in frequency) and lands exactly on time.
- A voice's unison counts are fixed at note-on, so its budget cost can't change while it sounds.
  A voice fading out with nothing queued (a second steal victim, or a mode change) no longer
  counts against the budget; it is silent within 4 ms.
- Changing Voice Mode fades out every sounding voice.
- CPU at the full budget (16 notes × unison 4 on both oscillators = 128 oscillators, no filter
  yet): 3.3 % of one core at 48 kHz / 256 frames on the dev box
  (`cargo test --release cpu_full_budget -- --ignored --nocapture`).

**Done when:** a Mono/Legato bass with glide plays correctly from the piano roll, and a
16-note chord with unison 7 respects the 64-voice budget without clicks.

## Phase 3: filter, second envelope, LFOs, modulation engine (engine side)

After this phase the synth is feature-complete sonically. Routes exist in the engine but aren't
yet exposed over OSC; the default route and Rust tests exercise them.

- [x] **Filter:** `audio/dsp/svf.rs`, a ZDF/TPT state-variable filter (Simper form).
  - LP 24 is two cascaded stages. HP and BP use one stage.
  - Cutoff updates per sample from a smoothed or modulated value. The coefficient comes from a
    `tan` approximation or a lookup, so modulation stays cheap.
  - **Drive:** gain into `tanh` (or a cheap rational approximation) before the filter.
  - **Resonance compensation:** add back some low-passed input in proportion to resonance, so
    the lows don't thin out at high Q.
  - Clamp resonance just below self-oscillation.
- [x] **Key Track:** cutoff offset in octaves = key track × (note − 60) / 12. Middle C, C3 = 60,
      is the pivot.
- [x] **Filter Env:** a second `AdsrEnvelope` per voice, used only as a modulation source.
- [x] **LFOs:**
  - Per voice, with shapes from a phase accumulator. S&H uses the voice's RNG.
  - Retrigger Note resets the phase on note-on.
  - Sync reads the tempo from `set_transport` (`audio/transport.rs`), which the device stores as
    a copy.
- [x] **Modulation engine:** `audio/devices/polysynth/modulation.rs`, written generically enough
      to lift into `audio/modulation.rs` later for other devices.
  - `ModSource` enum: `FilterEnv, AmpEnv, Lfo1, Lfo2, Velocity, Keytrack`. Each has a stable
    string id (`"filter_env"`, `"amp_env"`, `"lfo1"`, `"lfo2"`, `"velocity"`, `"keytrack"`).
  - `ModRoute { source, param_id, amount: f32 /* −1..1 */ }` lives in a fixed-capacity array
    (64 routes), preallocated, with no allocation when adding or removing.
  - Per voice, once per control block (32 frames):
    - sample each source (envelopes and LFOs at the block start, velocity and keytrack
      constant);
    - compute `mod_norm[param] = clamp(base_norm[param] + Σ amount × source, 0, 1)` for every
      parameter that has at least one route;
    - denormalise only those parameters.
  - Pitch, cutoff and level are interpolated across the block. Everything else is block-constant.
  - The modulated value lives next to the base (ADR-0010: base + automation + Σ contributions)
    and is never written back into the base or echoed.
  - Unipolar sources (envelopes, velocity) run 0..1. Bipolar sources (LFOs, keytrack) run −1..1.
- [x] **Device trait additions** in `audio/devices/mod.rs`, all with no-op defaults:
  - `fn mod_sources(&self) -> Vec<ModSourceInfo>`, where `ModSourceInfo` is
    `{ id, name, bipolar }`;
  - `fn set_mod_route(&mut self, source: &str, param_id: ParamId, amount: f32) -> Result<(), String>`
    (amount 0 removes);
  - `fn mod_routes(&self) -> Vec<ModRoute>` (for state/get and tests).
- [x] **CPU check:** a `cargo test --release` benchmark-style test (or a `benches/` entry) of
      16 notes × unison 4 × filter LP 24 × 8 routes at 48 kHz / 256 frames. Record the number in
      the phase PR. The budget is well under 5 % of a core on the dev box.
- [x] Tests:
  - the filter is stable across the full cutoff and resonance sweep at 44.1–192 kHz, with no
    NaN or inf;
  - Filter Env → Cutoff produces a decaying spectral centroid;
  - route add, update and remove never reallocate;
  - modulated values clamp to 0..1;
  - LFO sync period equals the beat length at 120 BPM.

Implementation notes:
- Parameters: Filter = 30 (Type, Cutoff, Resonance, Drive, Key Track), Filter Env = 50,
  LFO 1 = 60, LFO 2 = 70 (Shape, Rate, Sync, Retrigger). Names carry the module prefix
  ("Filter Cutoff", "Filter Env Attack", "LFO 1 Rate"). Sync has 25 choices: Off, then each of
  4/1 … 1/32 straight, dotted (".") and triplet ("T").
- Every parameter has a *slot* (its index in `params::SPECS`); routes and the normalized array
  use slots. A modulated voice decodes a stack copy of `SynthParams` per control block; an
  unmodulated voice reads the shared block.
- Filter: LP 24 is a 4-pole Butterworth at resonance 0 (resonance sharpens the first stage only).
  Resonance tops out at Q 20. BP is scaled by `k` so its peak stays at unity. Compensation adds
  back input low-passed an octave below the cutoff (LP modes, up to about +3.5 dB of bass).
  Drive crossfades from clean to `tanh`-like saturation over its first 6 dB, so 0 dB is
  bit-exact clean. `g` is exact `tan` once per block, interpolated per sample; coefficients are
  cached while cutoff and resonance are steady.
- Base cutoff is smoothed per frame in the normalized (octave) domain like levels; modulation adds
  to it. Level, noise level and volume modulation are deltas on top of the smoothed base
  buffers. A mono voice (no unison spread) filters one channel and copies it.
- Key Track uses the gliding pitch, not just the note. The keytrack *source* is
  `(note − 60) / 60`, clamped to ±1.
- LFOs with Retrigger Free start from a device-level free-running phase, so voices stay in step;
  a synced Free LFO follows the song position while the transport plays.
- Glide time is read every control block, so a modulated Glide changes the rate of a slide in
  progress.
- The trait's `set_mod_route` default returns an error (the device has no modulation) rather than
  silently succeeding. `clear_mod_routes` was added for Phase 4's `mod/clear`.
- CPU (`cargo test --release cpu_full_budget -- --ignored --nocapture`): 16 notes × unison 4 on
  both oscillators, spread (so stereo filtering), LP 24 and 8 routes into cutoff, pitch, level,
  pulse width and resonance: **4.9 % of one core** at 48 kHz / 256 frames, about 4.2 % with no
  routes. Measured with the machine under load (load average ≈ 6.8 on 12 threads), so re-measure
  on an idle machine. Routes that switch on noise and drive add roughly 0.5 %. That is under
  5 %, but not "well under"; the remaining cost is mostly the stereo filter and the
  per-sample coefficient rebuild when cutoff is modulated.

**Done when:** the default patch plucks. A short Filter Env decay, Sustain 0 and resonance give
a recognisable pluck from the piano roll.

## Phase 4: modulation over OSC and in the Godot model

- [x] **OSC** (`osc/server.rs`, `audio/commands.rs`, `docs/subsystems/osc-protocol.md`):
  - `{device}/mod/set [s:source_id, i:param_id, f:amount]` becomes
    `AudioCommand::SetModRoute`. Amount 0 removes the route.
  - `{device}/mod/clear` removes all routes.
  - Engine → Godot: `{device}/mod/set` echo, following the param-echo pattern Godot already
    handles in `_expect_echo`/`_consume_echo`.
  - `/builtin/info` gains the device's modulation sources (`id`, `name`, `bipolar`).
  - `{device}/state/get` also re-sends the routes.
  - Apply commands on the command thread under the brief state lock; `set_mod_route` is O(64).
- [x] **Godot model** (`Godot/data/DeviceInstance.gd`, `DeviceRegistry.gd`):
  - `mod_sources: Array[Dictionary]` from the registry;
  - `mod_routes: Dictionary` mapping `"source:param_id"` to the amount;
  - `signal mod_route_changed(source: String, param_id: int, amount: float)`;
  - `set_mod_amount(source, param_id, amount)`, `get_mod_amount(...)` and
    `get_routes_for_param(param_id)`;
  - sent from `sync_to_engine()`, round-tripped through `to_json()`/`from_json()`;
  - follows the self-synchronising model pattern (ADR-0006): the UI never sends OSC.
- [x] **Undo:** mod-amount edits go through the same undo path as parameter edits. Check how
      `set_parameter_normalized` records undo and mirror it, merging one drag into one step.
- [x] **DAWproject** (`docs/subsystems/dawproject.md`): modulation routes aren't representable,
      so export lists them in the transfer report as dropped. Import leaves the default patch.
- [x] **Docs:**
  - add ADR-0011, "Modulation routes are device state; polyphonic sources are evaluated inside
    the device". It records why this isn't the ADR-0010 host-level resolve step, and how a
    later host-level modulator system reuses the same `{device}/mod/*` and UI;
  - add the CONTEXT.md glossary terms **Modulation source**, **Modulation route** and
    **Modulation amount**;
  - update the TODO.md Modulation item.
- [x] Tests:
  - a Godot `test_device_mod_routes.gd` covers set/get, JSON round-trip, and the signal
    firing on echo;
  - an engine OSC parse test for `mod/set` and `mod/clear`.

Implementation notes:
- `mod/clear` also echoes (`mod/clear`), and `state/get` resends routes as clear + sets, so Godot
  applies an unsolicited clear. Godot's own clear/sets in `sync_to_engine()` carry pending-echo
  counters (`_pending_mod_echoes`) so the echoes of a sync don't wipe the routes.
- `/builtin/info` also advertises the **default patch** (the routes a fresh instance starts with),
  after the sources. A new `DeviceInstance` seeds `mod_routes` from it; a saved `mod_routes` list
  (even an empty one) replaces the defaults, and a project without the key keeps them.
- The engine clamps amounts to −1..1 and echoes the applied value; unknown sources and
  non-modulatable parameters are logged and get no echo.
- Undo: parameter undo is recorded by the UI (`HistoryUtil.record`), never by the model, so
  `DeviceInstance.mod_amount_command()` builds the mergeable command and Phase 5's components
  record it.
- DAWproject: built-ins already export `DeviceInstance.to_json()` as their State, so routes
  survive a Sonara round trip. Export adds a `mod_routes` transfer-report entry saying other
  applications ignore them. Import of foreign projects leaves the default patch.
- Tests: engine `mod_set_and_clear_parse`, `mod_route_commands_apply_and_echo`,
  `get_device_state_resends_mod_routes`; Godot `test_device_mod_routes.gd`.

**Done when:** routes set from a Godot test script audibly change the sound, and save → reload
restores them.

## Phase 5: modulation UI in SimpleView and the shared components

- [x] **Component API.** One mixin-like contract, duplicated per component since GDScript
      has no traits:
  - `var mod_ranges: Array[Dictionary]` holds `{amount, color, source}` for the routes on this
    control. It is drawn as an arc or bar from the base value to base + amount, with bipolar
    amounts drawn both ways.
  - `var mod_assign_active: bool` and `var mod_assign_color: Color`: while true, the control
    is highlighted and **dragging edits the mod amount instead of the value**. The component
    emits `mod_amount_changed(new_amount: float)`, and emits nothing on the value.
  - `var mod_live_values: PackedFloat32Array` (0..1) is drawn as dots or a thin marker during
    playback (Phase 6).
  - Double-click in assign mode removes the route. Shift gives fine drag (reuse `FineDrag`).
  - Tooltips during assign show the amount in real units, e.g. "+1.2 oct" or "+35 %".
- [x] **Components to implement it in:**
  - [x] `components/RotaryKnob.gd`: an arc on the outer ring.
  - [x] `components/HSlider.gd` (`HorSlider`): a bar above the track.
  - [x] `components/VSlider.gd` (`VolumeSlider`, the mixer fader): a bar beside the track.
  - [x] `components/Volumeter.gd`: a bar beside the handle.
  - `VolumeSlider` and `Volumeter` get the drawing and editing API now, but nothing feeds them
    until channel parameters become modulatable (host-level modulation, a later spec).
    Add a Godot test per component that exercises the API headless.
- [x] **SimpleView wiring** (`devices/simple_view/SimpleView.gd`, `SimpleControl.gd`):
  - a **modulation source strip** (one `LightButton` per `mod_sources` entry, each in its own
    colour) that appears for any device advertising sources;
  - clicking a source enters assign mode. Clicking it again, pressing Esc or clicking empty
    space leaves it;
  - in assign mode every modulatable `SimpleControl` sets `mod_assign_active` on its inner
    component and forwards `mod_amount_changed` to `DeviceInstance.set_mod_amount`;
  - `SimpleControl` listens to `mod_route_changed` and refreshes `mod_ranges`;
  - source buttons show a small count of their active routes, and hovering one highlights its
    targets.
- [x] **Envelope compound gets knobs** (generic, applies to every device, not only PolySynth):
  - `SimpleControl._build_envelope()` returns a `VBoxContainer`: the `EnvelopeControl`
    display on top, and underneath a row with one `RotaryKnob` per stage the envelope has
    (`_envelope_stages()`, so an "ads" envelope gets three).
  - Knobs and display stay in sync both ways. Each knob commits through the same
    `_commit`/`_commit_real` path as display drags, and `_refresh` updates both.
  - Grow the `ENVELOPE` footprint in `SimpleControlKinds.gd` (currently `Vector2i(3, 2)`) so
    the row fits. Probably `Vector2i(4, 3)`; check by eye on PolySynth and a CLAP synth. Update
    the packing tests that assume the old size.
  - The knobs are ordinary modulation targets in assign mode, so envelope times and sustain can
    be modulated from the UI. The display itself doesn't take part in assign mode.
  - Update `docs/specs/004-simple-view/design.md` (via its divergence note) and
    `godot-ui-components.md`.
  - Test: an envelope compound builds N knobs for N stages, and a knob change moves the
    display's stage value, and the reverse.
  - **Remaining gap:** the XY and EQ-band compounds don't take part in assign mode yet.
    PolySynth has neither.
- [x] Tests: headless tests that drive assign mode on a SimpleControl knob, check that
      `set_mod_amount` is called, and check that `mod_ranges` updates from the model signal.
- [ ] **Manual check:** click FEG, drag Cutoff up, and a pluck appears. The arc reads
      correctly in both theme modes.

Implementation notes:
- The shared maths is `components/ModDisplay.gd` (span, amount step, source colors). Components
  also keep the contract's `mod_assign_amount` (the route being edited, advanced by drags) and
  `mod_amount_text_callback`.
- Source buttons are toggle `Button`s in the source's color, not `LightButton`s (that one needs a
  texture). Hovering one dims the controls it doesn't modulate.
- Amount drags use the same distance as a value drag: a full knob/slider sweep is amount 1.0.
  Assign tooltips: octaves for logarithmic parameters, otherwise percent of the control's travel.
- Envelope knobs are 22 px and sit under the display; footprint is 3×3 (4×3 pushed ExtraBold's oscillators onto an extra page; 3×3 leaves the generated layouts unchanged). Tests:
  `tests/test_mod_assign_ui.gd` (components, SimpleControl, envelope compound, the SimpleView
  loop). It logs a harmless `Editor` node error from `HistoryUtil.record` in headless.
- The manual check is still open: it needs the running app and engine.

**Done when:** the full Bitwig-style assign loop works in SimpleView.

## Phase 6: live modulation display during playback

- [ ] **Engine:** the PolySynth implements `subscribe_data("modulation")`.
  - At about 20 Hz (the existing data-stream cadence) it sends a blob of
    `(u32 param_id, f32 norm)` pairs for the modulated parameters of up to 4 most recent
    sounding voices.
  - Values are written into a preallocated buffer on the audio thread and picked up through the
    existing data path, with no allocation.
- [ ] **Godot:**
  - `DeviceView`/`SimpleView` subscribe in `_on_view_shown` and unsubscribe in
    `_on_view_hidden`, per `godot-device-views.md`;
  - they decode the blob and push `mod_live_values` to the matching controls;
  - the controls fade the markers out when no voice is sounding.
- [ ] Update `docs/subsystems/godot-osc.md` (data streams) and `osc-protocol.md`.

**Done when:** holding a chord with LFO → Cutoff shows the knob markers moving, and closing the
device view stops the stream (confirmed in the engine log).

---

## Out of scope (follow-ups)

- MIDI CC, pitch bend and channel pressure reaching devices. `send_midi_event` is note-only
  today. After that lands: Mod Wheel, Pressure and Pitch Bend become modulation sources, and a
  Pitch Bend Range parameter is added.
- Host-level modulators (a track LFO modulating any device or channel parameter, including
  CLAP poly-mod). The Phase 4 OSC family and the Phase 5 components are designed to carry it.
- A custom `PolySynthDefaultView`, modulation assign on the XY and EQ-band compounds,
  wavetables, a second filter, an effects section, arpeggiator, and factory presets.

## Phase dependencies

```
0 → 1 → 2 → 3 → 4 → 5 → 6
```

Phases 0–3 are engine-only, and each one is shippable and audible on its own. Phases 4–6 cross
into Godot. Component work in Phase 5 (the drawing API) can start in parallel with Phase 3.
