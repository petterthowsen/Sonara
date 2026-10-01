# 013 — Drum synths: implementation plan

Status: approved 2026-10-01, including decisions 1–8. Phase 0 is implemented (2026-10-01);
Phases 1–4 and the wrap-up are implemented and covered headless (2026-10-01) — see `TODO.md`
for the live passes still to do. This is a single phased plan, following the format of 011 and
012.

Goal: four synthesized drum instruments that sound good with their default settings and are
quick to tune: **Kick**, **Snare**, **Hat** and **Clap**. Each is a separate built-in device,
so it can be used on an instrument channel or placed in a Drum Machine pad. They share one
foundation: drum DSP blocks in `audio/dsp/` plus a drum voice host in
`audio/devices/drums/`.

Inputs:
- PolySynth (spec 011) and the effects (spec 012) as models. That covers the shared
  `ParamTable` (`devices/param_table.rs`), ID blocks of ten per module, `module`-grouped
  `ParamInfo`, the `dsp/test_util.rs` measurement helpers, the CPU test harness and the
  "done when" checks.
- Existing DSP that is reused rather than rewritten: `dsp/svf.rs` (noise filtering),
  `dsp/one_pole.rs`, `dsp/oscillator.rs` (the BLEP pulse for the hat), `dsp/oversampler.rs`,
  `dsp/smoothing.rs` and `dsp/gain.rs`.
- `devices/drum_machine.rs`, which routes one note to each pad. The drums do not need to know
  about it.

## Decisions (approved)

1. **One device per drum.** There is no all-in-one drum synth. The Drum Machine composes them,
   so each device stays small and has a clear layout.
2. **Mono voice with a two-slot crossfade.** A retrigger starts a fresh voice (phase reset, so
   every hit sounds the same) while the previous voice fades out over 3 ms. This avoids the
   click a hard reset would make, and caps CPU at two voices.
3. **Note-off is ignored** (one-shot), except in the Kick's optional Gate mode (808 bass).
4. **Mono synthesis, copied to both stereo outputs.** Stereo width can come later.
5. **Zero latency.** Drive stages use the IIR `Oversampler` (2×), and only when drive > 0.
6. **Keytrack is off by default**, so the pad note in a Drum Machine does not change the tune.
   With Keytrack on, Tune becomes an offset in semitones relative to the incoming note.
7. **Instrument sleep.** A drum sleeps once its voices are idle and the output has stayed below
   −90 dBFS for 100 ms. MIDI wakes it. The 3 s instrument timeout is too long for drums.
8. **Choke groups are a Drum Machine feature, not part of a drum device.** They are needed for
   closed and open hats in Phase 3. They change the Drum Machine's persisted state and OSC, so
   they get their own task and an ADR note.

---

## Phase 0: shared drum foundation (engine, plus a little Godot)

This phase produces no device. After it, a drum is a parameter table plus a `DrumVoice` impl.

### DSP blocks (`audio/dsp/`, each with its own tests)

- [x] `one_shot_env.rs`: `OneShotEnvelope` with attack, hold, decay and a curve control
      (−1 = fast exponential drop, 0 = exponential, +1 = closer to linear/held). It is
      triggered with no gate, and `trigger()` restarts from the current level so a retrigger
      has no jump. It has an optional gated mode (`gate_off()` → release) for the Kick's Gate
      mode. Tests: stage times within 5 %, the decay reaches −60 dB at the set time, no
      discontinuity on retrigger, `is_active()` goes false after the tail.
- [x] `one_shot_env.rs`: a burst mode, or a separate `BurstEnvelope`: N short decays spaced
      `spread` ms apart, followed by a tail decay (for the Clap). Tests: the peak count equals
      N, and the spacing is within ±1 sample.
- [x] `sweep_osc.rs`: `SweepOsc`, a phase accumulator that takes a new frequency every
      sample. It has a start phase (0–90°), sine and triangle shapes, and `reset()`.
      Expose `fast_sin` from `oscillator.rs` instead of duplicating it. Add a helper
      `sweep_hz(base_hz, sweep_st, env) = base_hz · 2^(sweep_st · env / 12)` with a fast
      `exp2` approximation (error under 0.1 cent). Tests: the frequency at the end of the
      sweep is within 0.5 % of the base, the phase is continuous across frequency changes,
      and start phase 90° gives a first sample of 1.0.
- [x] `noise.rs`: xorshift32 white noise (seedable and deterministic) and pink noise (Paul
      Kellet's economy filter). Neither allocates. Tests: mean ≈ 0, white is flat within
      ±1.5 dB in octave bands, and pink falls about 3 dB/oct.
- [x] `saturate.rs`: move `soft_clip`/`drive`/`drive_params` out of `svf.rs` and keep
      re-exports so callers don't change. Add `fast_tanh`. Tests: odd symmetry,
      |out| ≤ 1, and the existing SVF tests stay green.

### Drum host (`audio/devices/drums/`)

- [x] `drums/mod.rs`: `trait DrumVoice` with `trigger(note, velocity, rng)`, `render(&mut
      [f32])` (mono, adds into the buffer), `release()` and `is_active()`. It also defines
      the shared `DrumParams` view that each voice reads once per block.
- [x] `drums/host.rs`: a generic `DrumHost<V: DrumVoice>` that implements `AudioDevice`.
  - A preallocated event queue (capacity 64). `send_midi_event` pushes
    `(frame_offset, note, vel, on)`, and `process_block` splits the block at each offset, so
    triggers are sample-accurate. It uses `frame_offset` directly and never converts back to
    ticks.
  - Two voice slots. A trigger moves the active voice to the fading slot (3 ms linear fade)
    and starts the other.
  - Shared parameters: Velocity sensitivity, Output gain (smoothed), Humanize (random pitch
    of ±10 cents and decay of ±5 % per hit, at full amount).
  - The velocity curve is `gain = 1 − sens · (1 − v²)`. Each drum also receives raw `v` for
    brightness routing.
  - Mono → stereo copy, and a final `soft_clip` safety stage on the output.
  - Sleep according to decision 7.
- [x] `drums/params.rs`: a shared parameter block (IDs 90–99) for Velocity, Output and
      Humanize, which each drum's table includes.
- [x] Factory: add a `DRUM_IDS` list and `create_drum(id, sample_rate, max_frames)` in
      `factory.rs`, call it from `create_builtin`, and include it in
      `builtin_device_infos`. Device category is `Instrument`.

### Conformance and tooling

- [x] `devices/drum_conformance.rs` (`#[cfg(test)]`), running over `DRUM_IDS` the way
      `effect_conformance.rs` does:
  - get→set round-trips every parameter, and the `ParamInfo.default` matches the initial get;
  - `prepare` at 44.1, 48, 96 and 192 kHz plus a hit gives no NaN or inf;
  - block-size invariance: the same note at the same absolute sample gives identical output
    (within 1e-4) for block sizes 1, 37, 256 and 4096;
  - no MIDI gives exact silence;
  - after a hit, the device sleeps and the output is exactly 0, then the next note wakes it;
  - a retrigger at full amplitude has no sample-to-sample step larger than the voice's own
    largest step (the click test for decision 2);
  - CPU: one hit per 16th note at 120 BPM, kept under a 0.2 % budget per device.
- [x] Measurement helpers in `dsp/test_util.rs`, if they aren't already there:
      `instantaneous_freq` (zero-crossing or Hilbert based, over a window) and
      `time_to_db(signal, −60)`.

### Godot

- [x] `DeviceKind`: add a `DRUM` kind that matches the feature `"drum"` (declared by the
      drum devices) or the name keywords `kick*`, `snare*`, `hat*`, `hihat*` and `clap*`.
- [x] `simple_view/strategies/DrumStrategy.gd`: Tune and Decay are the large knobs, levels go
      in a row, and the rest is grouped by `ParamInfo.module`. Register it in
      `SimpleLayoutGenerator.strategy_for`.
- [x] `DeviceKind`/browser: add a "Drums" group in the builtin list (look at how instruments
      are grouped today first).

### Docs

- [x] `CONTEXT.md`: add **Hit** (one trigger of a drum voice), **Sweep** (pitch envelope) and
      **Choke group**.
- [x] `AGENTS.md`: list the drum devices under "Built-in devices" as each phase lands.

**Done when:** the conformance test passes on a throwaway `TestDrum` (a sine with a decay),
all existing tests are green, and the SVF tests still pass after the `saturate.rs` move.

Implementation notes:
- **Envelopes.** `OneShotEnvelope` runs `Idle → Attack → Hold → (gated ? Sustain : Decay)`, and
  `gate_off()` releases a gated one. Decay and release read a `[f32; 1025]` shape table
  (`0.001^((t/T)^q)`, `q = 2^-curve`) rebuilt in `set_curve`, so the level is exactly −60 dB at
  the set time for every curve, with no `powf` per sample. `BurstEnvelope` precomputes up to 8
  burst starts (in samples) and per-burst levels at `trigger`; `randomness` jitters each gap by
  ±30 % and each level by up to −30 %. Both hold fixed-size arrays and neither allocates.
  **Deviation:** `BurstEnvelope` covers the N bursts only. The Clap's room tail is a separate
  `OneShotEnvelope` (Phase 4), because it has its own Tail Level and Decay and is summed with the
  bursts, not folded into their envelope.
- **Sweep.** `sweep_hz` uses a bit-trick `2^i` and a degree-5 polynomial for `2^f` on [0,1)
  (max relative error 2.4e-7, about 0.0004 cent). `SweepOsc::next` emits the sample at the
  current phase *before* advancing, so a 90° start phase reads +1.0 on the first sample. The
  phase-continuity test can't use a literal step bound on a sine (2 kHz at 48 kHz steps 0.263 by
  itself), so the sine is checked against its own natural bound and a triangle against the
  literal 0.2; both catch a phase reset.
- **`fast_tanh`** is the same rational tanh as `soft_clip`, clamped to ±4 in and ±1 out. The two
  stay separate so the soft-clip law can move without changing drive voicing; `svf.rs` re-exports
  the three moved functions, so no caller changed.
- **Host.** Trigger events are a fixed 64-entry array; `process_block` sorts it by `frame_offset`
  and renders spans between events, so triggers are sample-accurate and `frame_offset` is never
  converted back to ticks. Two voice slots alternate; the outgoing one keeps its own velocity
  gain and fades linearly over 3 ms, so CPU is capped at two voices. Mono → stereo, then a
  `soft_clip` safety stage, then the smoothed Output gain. The velocity curve is
  `1 − sens·(1 − v²)`; the voice separately gets raw `v` for brightness. **Humanize** is drawn
  from the host RNG at trigger time but applied by the voice, which is the side that owns the
  pitch and decay it jitters.
- **Sleep** is self-managed rather than `DeviceSleepState`: the host counts quiet samples from
  its own output (below −90 dBFS, decision 7) and reports the change through `update_sleep_state`,
  so a drum sleeps after 100 ms instead of 3 s. MIDI or a parameter change wakes it, and the chain
  copies silent input to the output while asleep, so the reported output is exactly 0.
- **`DRUM_IDS` is empty in this phase** because the phase produces no device: `create_drum`
  returns `None`, and `create_builtin` / `builtin_device_infos` already call it, so a Phase 1 drum
  only adds an arm. The conformance test therefore runs over `DRUM_IDS` plus a `#[cfg(test)]`
  `TestDrum`, with an assertion that the throwaway case is always in the list so the checks can
  never pass vacuously.
- **Conformance tolerances:** odd block sizes within 1e-4 of 512-frame blocks, exact 0 with no
  MIDI and while asleep, and the retrigger's largest sample-to-sample step within 1.05× of a
  single hit's own largest step. The CPU check is a separate `#[ignore]` test, as in spec 012.
- **Godot.** `DeviceKind.DRUM` matches the `drum` feature or the name keywords, checked against
  the device *name* only: a CLAP plugin's id contains the token "clap", which would otherwise
  classify every plugin as a drum. Drum parameters carry one `module` per section, so the
  generator's module grouping produces the Body / Punch / Click / Noise / Mode / Global sections
  and `DrumStrategy` only has to rank Tune and Decay as the large knobs. "Levels go in a row" is a
  `Levels` role group, which only applies to a drum whose parameters carry no module, since the
  module grouping wins otherwise. The browser gets its "Drums" group from
  `Device.get_browser_group()`.
- **Tests:** `cargo test --lib dsp::` is 74, of which 21 are new (saturate 3, one_shot_env 9,
  sweep_osc 4, noise 3, test_util 2); `drum_conformance` adds 2 + 1 ignored. The whole suite is
  448 lib + 442 bin tests, all green, and the SVF tests pass unchanged after the `saturate.rs`
  move. Godot: `test_simple_layout_generator.gd` gains drum kind inference and a Kick layout
  check, and `Godot/tests/run_all.sh` passes.
- **CPU:** `cpu_test_drum` (`--release --ignored --nocapture`) renders one hit per 16th at
  120 BPM on the throwaway drum at **0.114 % of a core**, under the 0.2 % budget.

---

## Phase 1: Kick (`sonara.builtin.kick`)

Three layers summed: **Body** (a swept sine), **Click** (a 1–10 ms transient) and **Noise** (a
filtered noise layer with its own decay).

### Parameters

| ID | Module | Name | Range | Default | Notes |
|---|---|---|---|---|---|
| 0 | Body | Tune | 20–200 Hz, log | 41.2 Hz (E0) | Shown as a note name. With Keytrack on: ±24 st |
| 1 | Body | Keytrack | off/on | off | decision 6 |
| 2 | Body | Decay | 30 ms – 3 s, log | 400 ms | |
| 3 | Body | Curve | −1…1 | 0 | 909 punchy ↔ 808 long |
| 4 | Body | Attack | 0–10 ms | 0 | softens the transient |
| 5 | Body | Start Phase | 0–90° | 0° | 90° = built-in knock |
| 6 | Body | Level | 0–1 | 1 | the "Body" amount |
| 7 | Body | Drive | 0–24 dB | 0 | `fast_tanh`, 2× oversampled when > 0 |
| 10 | Punch | Sweep | 0–48 st | 24 | how high the hit starts |
| 11 | Punch | Sweep Time | 5–200 ms, log | 40 ms | pitch envelope decay |
| 20 | Click | Level | 0–1 | 0.3 | |
| 21 | Click | Tone | 1–8 kHz, log | 3 kHz | band-pass center |
| 22 | Click | Type | Noise / Tick | Noise | noise burst vs a short high sine |
| 30 | Noise | Level | 0–1 | 0 | |
| 31 | Noise | Decay | 10 ms – 1 s, log | 80 ms | |
| 32 | Noise | Color | 200 Hz – 12 kHz, log | 4 kHz | SVF band-pass cutoff |
| 40 | Mode | Gate | off/on | off | hold while the note is held, then Release |
| 41 | Mode | Release | 10 ms – 2 s, log | 200 ms | Gate mode only |
| 42 | Mode | Glide | 0–500 ms | 0 | only applies when Gate and Keytrack are both on (808 slides) |
| 90–92 | Global | Velocity, Output, Humanize | shared | 50 %, 0 dB, 0 | Phase 0 |

"Punch" is split into Sweep and Sweep Time. The two together are what people mean by punch.

### Tasks

- [ ] `drums/kick.rs`: parameter table and `KickVoice: DrumVoice`.
- [ ] Body: `SweepOsc` driven by `sweep_hz(base, Sweep, pitch_env)`. `pitch_env` is a
      `OneShotEnvelope` (decay = Sweep Time, exponential), and the amplitude comes from a
      second `OneShotEnvelope` (Attack, Decay, Curve). Drive runs after the amplitude envelope,
      through the oversampler, and only when Drive > 0.
- [ ] Click: Noise type is white noise → SVF band-pass at Tone → a 1–10 ms decay (shorter at
      higher Tone). Tick type is a `SweepOsc` sine at Tone with a 2 ms decay.
- [ ] Noise layer: pink noise → SVF band-pass at Color → its own decay envelope.
- [ ] Velocity also adds brightness: `v` scales Click level (×0.5…1) and Sweep (×0.75…1), in
      proportion to Velocity sensitivity.
- [ ] Tuning: with Keytrack off, `base = Tune`. With it on, `base = note_hz(note) · 2^(Tune_st/12)`,
      using C3 = 60.
- [ ] Gate mode: the amplitude envelope holds at its sustain level while the note is held and
      releases on note-off. Glide slides `base` exponentially between legato notes.
- [ ] A DC blocker (`gain.rs`) on the output, because the 90° start phase and drive both
      introduce DC.
- [ ] Register in `DRUM_IDS` and declare the `"drum"` feature.

### Tests

- [ ] With default settings, the frequency 200 ms after the hit is 41.2 Hz ± 1 %.
- [ ] Sweep 24 st: the frequency in the first 1 ms is about 4× the base (± 3 %).
- [ ] Keytrack: note 60 with Tune 0 st gives 261.6 Hz ± 1 % in the tail.
- [ ] Decay: the time to −60 dB is within 5 % of the setting for Curve 0.
- [ ] Velocity sensitivity 0: the peak is identical at velocity 1 and 127. At 100 %, velocity
      64 gives about −12 dB.
- [ ] Click energy above 1 kHz is concentrated in the first 10 ms (> 90 % of the total).
- [ ] Drive 24 dB on a 200 Hz tune: aliases are more than 60 dB down (with the oversampler on).
- [ ] Gate mode: the level is still above −6 dB at 1 s while the note is held, and decays after
      note-off.
- [ ] Conformance and CPU from Phase 0.

### Godot

- [ ] `DrumStrategy` layout check: Tune shows a note name (E0) and Keytrack sits next to it.
- [ ] Optional: `KickDefaultView` with a small plot of the pitch and amplitude envelopes,
      computed in GDScript with the same formulas as the engine, like `EqResponse.gd`.
- [ ] Live check: in a Drum Machine pad and on a plain instrument channel, play 16ths and
      retrigger fast. Listen for clicks, and confirm it sleeps when stopped.

**Done when:** the kick sounds good at default settings, every test above is green, and the
live check passes.

---

## Phase 2: Snare (`sonara.builtin.snare`)

**Tone** (two sine modes with a short pitch drop, the drumhead) plus **Snares** (band-passed
noise with its own decay, the wires) plus an optional **Snap** (a short noise transient).

### Parameters

The modules are the Simple View sections, using the same vocabulary as the Kick; the synthesis
layers Tone / Snares / Snap map to Body / Noise / Click.

| ID | Module | Name | Range | Default |
|---|---|---|---|---|
| 0 | Body | Tune | 80–400 Hz, log | 180 Hz |
| 1 | Body | Keytrack | off/on | off |
| 2 | Body | Decay | 20–800 ms, log | 150 ms |
| 3 | Body | Mode 2 Ratio | 1.2–2.5 | 1.6 |
| 4 | Body | Mode Balance | 0–1 | 0.4 |
| 5 | Body | Sweep | 0–12 st | 3 |
| 6 | Body | Sweep Time | 5–100 ms, log | 20 ms |
| 7 | Body | Level | 0–1 | 0.7 |
| 10 | Noise | Level | 0–1 | 0.8 |
| 11 | Noise | Decay | 30 ms – 1.5 s, log | 220 ms |
| 12 | Noise | Color | 1–12 kHz, log | 5 kHz |
| 13 | Noise | Width | 0–1 | 0.5 |
| 20 | Click | Level | 0–1 | 0.4 |
| 21 | Click | Tone | 2–10 kHz, log | 6 kHz |
| 30 | Body | Drive | 0–24 dB | 0 |
| 90–92 | Global | Velocity, Output, Humanize | shared | |

Width maps to the band-pass Q: 0 is narrow and 1 is a wide high-pass blend.

### Tasks

- [ ] `drums/snare.rs`: two `SweepOsc`s (one at Tune, one at Tune × Ratio) that share one pitch
      envelope, each with its own amplitude envelope. Mode 2 decays 0.7× as fast.
- [ ] Snares: white noise → SVF (band-pass blended with high-pass by Width) → a
      `OneShotEnvelope` with Decay and Curve fixed slightly negative.
- [ ] Snap: reuse the Kick's click path. If it is copied, factor it into
      `drums/layers.rs::ClickLayer` here.
- [ ] Velocity brightness: `v` raises the Snares Color (up to +1 octave) and the Snap level.
- [ ] Drive on the sum of Tone and Snares, oversampled when > 0.
- [ ] Refactor: wherever Kick and Snare share layer code (`ClickLayer`, `NoiseLayer`,
      `BodyLayer`), move it into `drums/layers.rs` with no change in sound. The Kick tests
      prove that.

### Tests

- [ ] Tone partials: Goertzel peaks at Tune and Tune × Ratio (± 1 %) in the tail.
- [ ] The Snares decay to −60 dB within 5 % of the setting.
- [ ] Color moves the spectral centroid of the noise layer up monotonically.
- [ ] Conformance and CPU.

### Godot

- [ ] `DrumStrategy` layout check, then a live check alongside the Kick in a Drum Machine.

**Done when:** a Kick + Snare pattern sounds good with default settings, and the Kick's tests
are still green after the `layers.rs` refactor.

---

## Phase 3: Hat (`sonara.builtin.hat`)

The 808 approach: six square oscillators at inharmonic ratios, summed, then band-passed and
high-passed, with a short decay. A noise blend gives more modern hats.

### Parameters

| ID | Module | Name | Range | Default |
|---|---|---|---|---|
| 0 | Metal | Tune | 0.5–2× | 1× |
| 1 | Metal | Metal/Noise | 0–1 | 0.3 |
| 2 | Metal | Tone | 3–12 kHz, log | 8 kHz |
| 3 | Metal | Resonance | 0–1 | 0.3 |
| 4 | Filter | Low Cut | 2–12 kHz, log | 6 kHz |
| 10 | Amp | Attack | 0–5 ms | 0 |
| 11 | Amp | Decay | 10 ms – 2 s, log | 60 ms |
| 12 | Amp | Curve | −1…1 | −0.3 |
| 90–92 | Global | Velocity, Output, Humanize | shared | |

Closed and open hats are two Hat instances with different Decay, choked together in the Drum
Machine.

### Tasks

- [ ] `drums/hat.rs`: six `dsp::Oscillator` pulse waves (BLEP, so no aliasing) at the 808
      ratios (205.3, 304.4, 369.6, 522.7, 540, 800 Hz) × Tune, summed and mixed with white
      noise by Metal/Noise.
- [ ] SVF band-pass at Tone (with Resonance) → 12 dB high-pass at Low Cut →
      `OneShotEnvelope`.
- [ ] Velocity brightness: `v` raises Tone up to +½ octave.
- [ ] **Choke groups in the Drum Machine** (decision 8):
  - each `DrumSlot` gets `choke_group: u8` (0 = none, 1–8);
  - a note-on in a group calls a new `AudioDevice::choke()` (default no-op) on every other
    slot in that group, at the same `frame_offset`. `DrumHost` implements it as a 3 ms
    fade-out of both voices;
  - OSC: `/device/drum_machine/choke <channel> <path> <slot> <group>`. Update
    `osc/server.rs`, `audio/commands.rs` and `docs/subsystems/osc-protocol.md`;
  - Godot: the model gets a setter and signal (`DrumSlot`/pad data) wired into
    `sync_to_engine()`, plus a choke-group selector in `DrumMachineDefaultView`'s pad
    context menu;
  - persist it in the project format, and in DAWproject if there is a mapping. Otherwise
    record it as lost in the transfer report;
  - add an ADR amendment note to the Drum Machine ADR, or a new ADR if there isn't one.

### Tests

- [ ] There is no energy below Low Cut − 1 octave (> 40 dB down).
- [ ] Alias check: at Tune 2× and 48 kHz, the inharmonic spectrum contains no folded
      components more than 60 dB below the main peaks.
- [ ] Choke: a closed-hat note at frame N makes the open hat's output reach 0 by frame
      N + 3 ms, sample-accurately, across block boundaries.
- [ ] A choke-group round trip through OSC and project save/load (a Godot test in
      `Godot/tests/`).
- [ ] Conformance and CPU (6 oscillators, so the budget is 0.3 %).

**Done when:** an open hat played over a closed hat chokes cleanly in a live pattern, and the
choke group survives save and reload.

---

## Phase 4: Clap (`sonara.builtin.clap`)

Several noise bursts spaced a few milliseconds apart (several hands), followed by a
band-passed tail (the room).

### Parameters

| ID | Module | Name | Range | Default |
|---|---|---|---|---|
| 0 | Burst | Count | 1–6 (stepped) | 4 |
| 1 | Burst | Spread | 3–30 ms | 10 ms |
| 2 | Burst | Burst Decay | 1–20 ms | 6 ms |
| 3 | Burst | Randomness | 0–1 | 0.2 |
| 10 | Tone | Tone | 500 Hz – 5 kHz, log | 1.2 kHz |
| 11 | Tone | Resonance | 0–1 | 0.4 |
| 20 | Tail | Level | 0–1 | 0.6 |
| 21 | Tail | Decay | 30 ms – 2 s, log | 250 ms |
| 30 | Body | Drive | 0–24 dB | 0 |
| 90–92 | Global | Velocity, Output, Humanize | shared | |

Randomness jitters each burst's spacing (±30 % of Spread at full amount) and its level, per hit.

### Tasks

- [ ] `drums/clap.rs`: white noise → SVF band-pass at Tone/Resonance → the `BurstEnvelope`
      from Phase 0 (Count, Spread, Burst Decay) plus the tail envelope (Tail Level, Decay).
- [ ] Randomness draws from the host RNG at trigger time only (nothing random per sample apart
      from the noise).
- [ ] Velocity brightness: `v` raises Tone up to +½ octave.

### Tests

- [ ] The number of detected burst peaks equals Count (with Randomness 0), spaced at Spread
      ± 1 sample.
- [ ] Randomness 0 with a fixed seed gives identical hits. Randomness > 0 gives different
      spacing between hits.
- [ ] The tail decays to −60 dB within 5 % of Decay.
- [ ] Conformance and CPU.

### Wrap-up

- [ ] A default "Synth Kit" preset for the Drum Machine: Kick (C1/36), Snare (D1/38), Clap
      (D#1/39), Closed Hat (F#1/42) and Open Hat (A#1/46), with both hats in choke group 1.
      Note numbers follow the GM drum map, which uses the same numbers whatever the octave
      naming.
- [ ] `AGENTS.md` builtin list, `TODO.md`, and a `docs/subsystems/` note if the drums host
      turns out to need one.

**Done when:** the default kit plays a full four-piece pattern live with no clicks or dropouts,
and all four devices pass conformance and stay within their CPU budgets.
