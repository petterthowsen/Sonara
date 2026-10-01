# 012 — Built-in effects suite: implementation plan

Status: approved 2026-09-30, including decisions 1–8. This is a single phased plan, following the format of 011.

Goal: a stock effects suite that people keep on their channels instead of replacing: **Delay**
(a rewrite of the current one), **EQ**, **Compressor**, **Filter**, **Chorus**, **Phaser** and
**Reverb**. Each is simple by default, has a clear signal path, and runs cheaply.

Inputs:
- `docs/daw-device-research.md`, whose "Non-negotiables per device" list sets the feature floor
  for each device below.
- The PolySynth (spec 011) as the model. Devices reuse its parameter-table pattern
  (`polysynth/params.rs`: ID blocks of ten per module, `module`-grouped `ParamInfo`, real
  ranges, `is_logarithmic`/`skew`), its DSP (`dsp/svf.rs`, `dsp/smoothing.rs`), its LFO sync
  list, its CPU test harness and its "done when" checks.

## Decisions (approved)

1. **No backward compatibility for the Delay.** It keeps the ID `sonara.builtin.delay`, but its
   parameters are renumbered. Old projects load it with defaults, as happened with PolySynth v2.
2. **Zero latency for every device in this spec.** `latency_frames()` stays 0 because plugin
   delay compensation isn't built yet (TODO.md: "Plugin latency compensation"). That rules out
   compressor lookahead and linear-phase EQ, which are listed as follow-ups. Oversampling uses
   IIR (polyphase allpass) half-band filters, which add no latency that has to be reported.
3. **Custom views only where the picture is the product.** The EQ (curve editor and analyser)
   and the Compressor (transfer curve and gain-reduction history) get `*DefaultView`s. Delay,
   Filter, Chorus, Phaser and Reverb stay on `SimpleView`: the modules come from
   `ParamInfo.module`, and the existing `Delay`/`Reverb` strategies are reused. A strategy is
   added only where the generated layout reads badly.
4. **Explicit parameters rather than modulation routes for effect LFOs and envelope
   followers.** Phaser and Filter get plain `LFO Depth` and `Env Amount` knobs. The assign UI
   from spec 011 stays reserved for PolySynth. Exposing effect LFOs as modulation sources waits
   for host-level modulators (ADR-0011's follow-up).
5. **One Mix convention.** Every device that has a Mix parameter makes Mix 0 % bit-exact dry.
   Dynamics devices and the Filter use a linear crossfade, which is what parallel compression
   expects. Delay, Reverb, Chorus and Phaser use an equal-power crossfade.
6. **The Compressor's Auto Gain is estimated, not measured.** It is a static makeup computed
   from threshold, ratio and knee. That is predictable, testable, and doesn't pump when
   automated. Measured (RMS-matched) auto gain is a follow-up.
7. **External sidechain is the last phase and may split into its own spec (013).** It changes
   the mixing dependency order, so it needs an ADR. Until it lands, every detector
   (compressor, ducking, envelope followers) listens to the device's own input.
8. **Every continuous parameter is smoothed.** Enum changes that would click (filter type,
   reverb algorithm, delay routing) crossfade over 5–10 ms.

---

## Phase 0: shared effect foundation (engine only)

This phase builds the pieces every device below uses. It produces no new device, but after it
the old Delay could be rebuilt in an afternoon.

- [x] **Denormals:** set flush-to-zero and denormals-are-zero on the audio callback thread
      (x86_64 MXCSR; the equivalent FPCR bit on aarch64). Reverb and delay tails decay into
      denormals, and nothing handles that today. Set it at the top of every callback, which is
      cheap and survives thread reuse by the audio backend.
- [x] **Shared parameter table:** lift PolySynth's `Kind`/`SPECS` pattern out of
      `polysynth/params.rs` into `audio/devices/param_table.rs`, so every built-in declares
      one static table and gets `parameters()`, normalized get/set, defaults and slot lookup
      from it. PolySynth moves onto it too, with no behaviour change; its round-trip tests
      prove that.
- [x] **Tempo sync list:** move `LFO_SYNCS`/`SYNC_DIVISIONS` into
      `audio/dsp/tempo_sync.rs`, with `division_seconds(index, bpm)`. PolySynth, Delay,
      Chorus, Phaser and Filter all use it. Entry 0 stays "Off" (free-running Hz or ms).
- [x] **DSP building blocks** in `audio/dsp/`, each with its own tests:
  - `delay_line.rs`: a preallocated stereo ring with fractional reads (linear and 4-point
    Hermite), sized in `prepare` for a maximum length in seconds.
  - `lfo.rs`: lift PolySynth's phase-accumulator LFO (shapes, S&H, sync, phase offset) so
    effects share it.
  - `env_follower.rs`: a peak/RMS follower with separate attack and release, in the linear or
    dB domain.
  - `biquad.rs` or an extension of `svf.rs`: Simper SVF bell, low shelf, high shelf, notch,
    band-pass and all-pass responses from one `(g, k, a)` form, safe to modulate.
    Plus an analytic `magnitude_db(freq)` for each response, which the EQ view uses and the
    tests check against.
  - `allpass1.rs`: a first-order TPT all-pass stage (for the Phaser).
  - `oversampler.rs`: 2× and 4× polyphase IIR half-band up- and down-sampling with
    preallocated state.
  - `gain.rs`: dB↔linear conversion, a DC blocker, and a `DryWet` helper with the two laws
    from decision 5.
- [x] **Effect sleep with tails:** a shared `TailSleep` helper (built on `DeviceSleepState`).
      An effect sleeps only after its input has been silent *and* its own output has stayed
      below the threshold for 3 s, so reverb and delay tails ring out. Freeze and feedback
      ≥ 100 % never sleep. It is wired through `update_sleep_state`.
- [x] **Effect conformance test** (`audio/devices/effect_conformance.rs`, `#[cfg(test)]`). It
      runs over every built-in effect ID the factory knows, so each new device gets it free:
  - get→set round-trips every parameter, and `ParamInfo.default` equals the initial get;
  - bypass passes audio through bit-exact;
  - Mix 0 is bit-exact dry (when the device has Mix);
  - `prepare` at 44.1, 48, 96 and 192 kHz, then processing, produces no NaN or inf;
  - odd block sizes (1, 37, 256, 4096) give the same output as one large block, within
    floating-point tolerance;
  - `reset` clears the tail;
  - digital silence in produces exact silence out once any tail has finished.
- [x] **Measurement helpers** for tests (`audio/dsp/test_util.rs`): impulse, sine, log sweep,
      pink noise, Goertzel magnitude at a frequency, FFT magnitude, RMS/peak dB, and Schroeder
      T60. They lift what the PolySynth and spectrum-analyser tests already do.
- [x] **Spectrum code:** move the FFT and windowing out of `spectrum_analyzer.rs` into
      `audio/dsp/spectrum.rs` so the EQ can reuse it. The analyser output stays unchanged,
      which its existing tests check.

**Done when:** PolySynth runs on the shared table and sync list with all its tests green, and
the conformance test runs (on the current Delay, which it is expected to fail until Phase 1).

Implementation notes:
- **Delay line** is mono (`DelayLine`); effects hold one per channel. Convention: read, then
  push; `read(1)` is the latest sample. Hermite reads need a delay of at least 2 samples.
- **EQ filters** live in `dsp/linear_svf.rs` (`SvfShape`, `SvfCoefs`, `LinearSvf`), separate from
  the synth's `svf.rs`. `magnitude_db` is exact for the digital filter (bilinear, pre-warped),
  and a test checks it against measured sine gains within 0.1 dB for every shape.
- **All-pass** is part of `dsp/one_pole.rs` (TPT one-pole with LP, HP and AP outputs, plus an
  exact `one_pole_magnitude_db`), not a separate `allpass1.rs`.
- **Envelope follower** works in the linear domain only; detectors convert to dB themselves.
- **Mix** is `gain::dry_wet_gains(mix, MixLaw)` rather than a struct. The ends are exact
  `(1, 0)` and `(0, 1)`.
- **Oversampler:** stage 1 has 12 all-pass sections (transition 0.035) and stage 2 has 6
  (transition 0.2), with coefficients from HIIR's designer. Measured: images and aliases are
  more than 80 dB down at 2× and 4×, and the passband is flat within 0.1 dB to 18 kHz at 48 kHz.
- **Sleep:** `effect::TailSleep` counts processed frames instead of wall-clock time (so it is
  deterministic in tests) and doesn't wrap `DeviceSleepState`. Building it turned up a host bug:
  `run_chain` skipped a sleeping device without looking at its input, so a sleeping effect
  never woke when audio came back (only MIDI or parameter changes woke devices, which is fine
  for instruments, and they were the only devices that slept). `run_chain` now wakes a
  sleeping device when its input has signal. ADR-0008 has an amendment note.
- **Conformance:** effects are built with `factory::create_effect` from `factory::EFFECT_IDS`
  (constructed and prepared, with no `ProcessManager` needed). Tolerances: odd block sizes
  within 1e-3 of 512-frame blocks, output at most 1e-9 after `reset`, and at most 1e-6 after
  19 s of silence. The pre-012 Delay is on `KNOWN_FAILING`.
  `cargo test known_failing -- --ignored --nocapture` shows it failing on exactly the bugs
  Phase 1 fixes: 'Delay Time' starts at 0.774 normalized against an advertised 0.648, and
  'Feedback' set to 1 reads back 0.99.
- **Test helpers:** `test_util::tone_amplitude` (sine/cosine correlation) stands in for
  Goertzel. The PolySynth and oscillator tests keep their private helpers; new tests use the
  shared ones.
- **Spectrum:** the analyser's output is unchanged, but it no longer allocates while
  computing (the FFT scratch is preallocated; only the outgoing blob is allocated, which
  `poll_device_data` requires). Its `static mut` debug logging is gone, and the bins are
  serialized explicitly as little-endian. There were no analyser tests to lean on, so
  `dsp::spectrum` has its own (a bin-centred sine reads −6.02 dBFS in its bin).
- **Tests:** 304 → 338 in the lib, all green, plus 1 ignored test.

## Phase 1: Delay v2

Rewrites `audio/devices/delay.rs`. The current device's bugs are fixed by the rewrite:
- `set_parameter` maps 1–1250 ms but `ParamInfo` advertises 1–5000 ms;
- only a quarter of the ring is usable;
- taps are whole samples, so time changes click;
- `static mut` first-frame logging runs on the audio thread.

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Time | Time L, Time R | 1–5000 ms, log | 375 ms |
| | Sync L, Sync R | shared sync list (Off = use ms) | 1/8. |
| | Link | on/off (R follows L) | on |
| | Routing | Stereo, Ping-Pong, Mono | Stereo |
| Feedback | Feedback | 0–110 % | 40 % |
| | Low Cut | 20 Hz–2 kHz, log | 150 Hz |
| | High Cut | 1–20 kHz, log | 8 kHz |
| Character | Mode | Clean, Tape | Clean |
| | Mod Rate | 0.05–8 Hz, log | 0.5 Hz |
| | Mod Depth | 0–100 % | 0 % |
| | Drive | 0–100 % | 0 % (Tape only) |
| Dynamics | Ducking | 0–100 % | 0 % |
| | Duck Release | 20–2000 ms, log | 250 ms |
| Output | Width | 0–200 % | 100 % |
| | Mix | 0–100 %, equal power | 30 % |

- [x] DSP:
  - uses the Phase 0 `DelayLine` with Hermite reads, and a buffer sized for 5 s at the
    device's rate;
  - time changes: **Clean** crossfades between two read taps over about 50 ms, so the pitch
    doesn't bend. **Tape** glides the read position through a smoothed time, which gives the
    tape pitch bend;
  - a feedback loop of HP (Low Cut) → LP (High Cut) → soft clip. The soft clip lets 100–110 %
    build up without blowing up. Tape adds Drive saturation and wow/flutter;
  - Ping-Pong feeds L into R and R into L, with a mono sum at the input;
  - Ducking: an envelope follower on the dry input turns down the wet signal only.
- [x] Sync reads the tempo from `set_transport` and updates live when the tempo map changes.
- [x] Godot: check the `DelayStrategy` layout. When Sync is not Off, the Time knob shows the
      division, and the ms value is greyed rather than hidden (the research's Timeless 3
      complaint).
- [x] Godot: when a Delay or Reverb is added to a **BUS** channel, Mix defaults to 100 % (the
      send workflow). This is set in the model on creation, not in the engine.
- [x] Tests:
  - the impulse peak lands on the exact sample for a ms time and for 1/8. at 120 BPM (in
    `mod tests`);
  - Ping-Pong alternates L/R repeats;
  - Feedback 110 % stays below +6 dBFS over 60 s;
  - successive repeats lose energy above High Cut and below Low Cut;
  - a Clean time change has no sample-to-sample jump bigger than the input's;
  - Ducking 100 % takes the wet signal down at least 20 dB while input is present;
  - the conformance test passes;
  - CPU (`cpu_delay`, `--ignored`) stays under 0.5 % of a core.

Implementation notes:
- **Parameter table.** 17 parameters in the usual ten-per-module ID blocks (Time 0–5,
  Feedback 10–12, Character 20–23, Dynamics 30–31, Output 40–41) on the Phase 0 `ParamTable`,
  so `parameters()`, normalized get/set and the defaults come from one static `SPECS`. Sync L/R
  are enums over `tempo_sync::SYNC_CHOICES` with "Off" (index 0) meaning "use the ms value".
  The device is registered through `factory::EFFECT_IDS`/`create_effect` (which feeds
  `create_builtin` and `builtin_device_infos`), so the conformance test covers it; `devices/mod.rs`
  already re-exported `DelayDevice` and needed no change.
- **Signal path.** One `DelayLine` per channel, read with Hermite, then Low Cut → High Cut (two
  TPT one-pole stages each, so 12 dB/oct) → Tape Drive → the wet output; the same filtered signal
  times Feedback, soft clipped, is written back with the input. The feedback clip is applied
  *after* the feedback gain, so the loop's small-signal gain is Feedback (100–110 % still builds
  up) while what it feeds back never passes ±1.
- **Routing** is four smoothed coefficients (mono input sum, feedback cross-feed, R from the
  mono sum, mono output) that crossfade over 8 ms, so switching Stereo/Ping-Pong/Mono doesn't
  click. Ping-Pong takes only the mono sum into L and crosses the feedback, so a mono input
  alternates.
- **Time changes** are a `TapState` per channel: Clean crossfades from the current tap to the new
  one over 50 ms (no pitch bend), Tape one-pole glides the read position, clamped to 0.5×–1.5×
  playback speed, which gives the tape bend. Mode and Sync changes need no extra crossfade: they
  only move the target, which the tap logic already handles.
- **Modulation** is explicit (decision 4): a Mod Rate/Mod Depth LFO on the read position in both
  modes (±3 ms at 100 %), plus Tape wow (0.6 Hz, 0.8 ms) and flutter (6.3 Hz, 0.05 ms).
- **Ducking** follows the *dry* input with a peak follower (5 ms attack, Duck Release release)
  and scales the wet signal only; 100 % ducks fully once the input is above −26 dBFS.
- **Sleep:** `effect::TailSleep`, with the tail estimated as the delay time times the repeats
  needed to fall 60 dB (capped at 200), and never sleeping at Feedback ≥ 100 %.
- **Feedback 110 % test level.** The loop is bounded by the soft clip, but the output peak also
  contains the equal-power dry+wet sum and the High Cut one-pole's time-domain overshoot (a
  bilinear one-pole at a near-Nyquist cutoff has Σ|h| ≈ 1.4 on broadband signals, measured: the
  wet path peaks 1.42× the input at High Cut 20 kHz, 1.16× at 5 kHz). With a 0.8-amplitude noise
  burst the peak reached +6.01 dBFS, i.e. the bound, so the test drives the loop with −6 dBFS
  noise (a hot source level) and measures +3.56 dBFS.
- **Godot.** `DelayStrategy.decorate_control` marks a `Time L`/`Time R` knob with the id of its
  `Sync L`/`Sync R` sibling; `SimpleView` resolves that at bind time (so nothing display-only is
  saved in the layout) and `SimpleControl` leads the knob's readout with the division and dims the
  knob to 0.5 alpha while Sync isn't Off — the ms value stays visible and editable, only greyed.
  `handles_param` also answers for the Sync id, so a Sync change refreshes the Time knob. The
  strategy's roles/groups were also finished off against the real parameter names, because the
  generated layout read badly: Mode (matched by the `mod*` keyword) and Drive sat under
  Modulation, and Link, Routing, Ducking and Duck Release fell into the Controls catch-all. Now
  Character (Mode, Drive) and Dynamics (Ducking, Duck Release) are groups of their own, Link
  joins Delay and Routing joins Stereo, so the page is Delay (Time L/R, Sync L/R, Link,
  Feedback) · Mix · Character · Dynamics · Tone · Stereo · Modulation — one Main page. Built-in
  devices don't advertise `ParamInfo.module` over OSC, so grouping is by name sections plus the
  strategy roles; the delay's changed parameter list regenerates any generated layout, so no
  `SimpleLayoutGenerator.VERSION` bump was needed.
- **Bus default.** `Channel.add_device` sets Mix to 100 % for `sonara.builtin.delay` and
  `sonara.builtin.reverb` on a BUS channel (`BUS_WET_DEVICE_IDS`). It runs only from `add_device`,
  never from `Channel.from_json`, so a saved Mix survives a reload; an insert keeps the device's
  30 % default.
- **Tests.** 12 in the delay module (11 + `cpu_delay` ignored) and the conformance test, plus
  `Godot/tests/test_delay_view.gd` (15 assertions) for the Sync display and the bus Mix default.
  CPU worst case (Tape, Ping-Pong, Drive, modulation, ducking, synced time, 256-frame blocks):
  **0.414 % of a core**.
- **Not done here:** the visual pass over the panel at `DevicePanel.HEIGHT` in both themes (this
  worktree is headless); the layout above was checked by generating it for the real parameter
  list and by the render tests. AGENTS.md and TODO.md are the coordinator's housekeeping.

**Done when:** a dotted-eighth ping-pong on a vocal-like loop sits behind the source with
Ducking on, and dragging Time while playing never clicks in Clean mode.

## Phase 2: EQ (`sonara.builtin.eq`)

Eight bands, each in its own block of ten parameter IDs (band *n* = `n*10`), plus Output at 80.

| Per band | Range / values | Default |
|---|---|---|
| Enabled | on/off | off |
| Type | Bell, Low Shelf, High Shelf, Low Cut, High Cut, Notch, Band Pass, Tilt | Bell (band 1: Low Cut, band 8: High Cut) |
| Freq | 20 Hz–20 kHz, log | spread 50 Hz…12 kHz |
| Gain | ±24 dB | 0 |
| Q | 0.1–30, log | 0.71 |
| Slope | 6, 12, 18, 24, 36, 48 dB/oct (cuts only) | 12 |
| Stereo | Stereo, Left, Right, Mid, Side | Stereo |

Output: **Gain** (±24 dB) and **Listen Band** (Off, 1–8). Listen Band is hidden and not
automatable; the view sets it while you hold a band's node.

**Engine**
- [x] Per-band SVF from Phase 0. Cuts cascade stages for their slope (6 dB is a one-pole).
      Coefficients are recomputed per 32-frame block while a parameter moves, and cached while
      it is steady.
- [x] M/S: encode once when any enabled band uses Mid or Side, and decode once at the end.
- [x] Listen Band: output a band-pass around the band's frequency and Q (a peaked Bell or Band
      Pass shows the region being boosted or cut), at unity gain.
- [x] Disabled bands cost nothing. A band switching on or off crossfades over 5 ms.
- [x] Data stream `"spectrum"`: pre- and post-EQ magnitude frames at about 20 Hz from
      `dsp/spectrum.rs`, while subscribed. Uses the analyser's existing blob format with a
      pre/post flag. Document it in `osc-protocol.md`.
- [x] Near Nyquist, bells cramp. Accept that in v1: the view draws the real response, so it
      stays honest. A decramped response or 2× oversampling is a follow-up.

**Godot**
- [x] `devices/builtin/EqDefaultView` (registered in `DeviceViewFactory`):
  - a log-frequency grid from 20 Hz to 20 kHz, a dB grid (±6/12/24, switchable), and a piano
    strip along the bottom edge (C3 = 60);
  - the analyser behind the curve, with pre faint and post solid. Pre/Post/Off is view state
    kept in the layout config, not a parameter;
  - the combined curve plus each band's own curve in its band colour;
  - nodes: dragging changes freq and gain, the wheel changes Q, Shift gives fine control,
    double-clicking empty space enables the next free band there, and double-clicking a node
    disables it. Right-click opens Type, Slope and Stereo, and holding Alt (or the middle
    button) on a node listens to it;
  - a band strip underneath with Freq, Gain and Q knobs and a type icon per enabled band, for
    exact entry and as automation targets. Hovering a node shows a value tooltip.
- [x] `EqResponse.gd` computes each band's magnitude with the same formulas as the engine.
- [x] Subscribe to `"spectrum"` in `_on_view_shown` and unsubscribe in `_on_view_hidden`.

**Tests**
- [x] Engine:
  - each type's measured magnitude (Goertzel on a sine) matches the analytic
    `magnitude_db` within 0.1 dB below 10 kHz at 48 kHz;
  - cut slopes measure within ±1.5 dB/oct of nominal one octave past the corner;
  - a Mid-only band leaves the Side signal untouched;
  - all bands disabled at 0 dB output is bit-exact.
- [x] Cross-language: a Rust test (`--ignored`, regenerates the file) writes
      `Godot/tests/fixtures/eq_response.json` with engine magnitudes for fixed settings.
      `test_eq_response.gd` checks `EqResponse.gd` against it within 0.05 dB.
- [x] Godot: node drags call `set_parameter` on the right parameters, double-click enables the
      first free band, and the view state survives a save and reload.
- [x] Conformance test, and CPU with 8 bands enabled in stereo under 0.5 %.

- [ ] Optional: DAWproject export writes the EQ as a typed `<Equalizer>` with bands alongside
      the Sonara state, and import creates a Sonara EQ from a foreign `<Equalizer>` instead of
      reporting `generic_device`. See `docs/subsystems/dawproject.md`.

**Done when:** you can shape a vocal entirely on the curve, the analyser shows the result, and
the drawn curve matches what the analyser shows for pink noise.

Implementation notes:
- **Device** is `audio/devices/eq.rs` (parameter IDs: band *n* at `n*10` with offsets Enabled 0, Type 1,
  Freq 2, Gain 3, Q 4, Slope 5, Stereo 6; Output Gain 80, Listen Band 81). Listen Band is `hidden` and
  `not_automatable`, but `/builtin/info` doesn't carry those flags (nor `module`), so Godot's parameter list
  still shows it. Carrying them is a small additive change to `BuiltinParamInfo`, left to the merge.
- **Filter design** is one function (`BandFilter::new`) shared by the audio path and the analytic
  `magnitude_db`: Bell, shelves, Notch and Band Pass are one SVF stage; Tilt is a low shelf of -gain/2 plus a
  high shelf of +gain/2 (positive gain brightens); cuts are an optional one-pole plus Butterworth SVF sections
  (6: pole; 12: 1 section; 18: pole + 1; 24: 2; 36: 3; 48: 4). The Q knob scales the sharpest section's Q, so
  the default 0.71 is exactly Butterworth. Band Pass is normalised to 0 dB at its peak (the raw SVF band output
  peaks at Q); Gain is ignored by cuts, Notch and Band Pass.
- **M/S** deviation: no separate encode/decode pass. A Mid or Side band computes `m = (l+r)/2` or `s = (l-r)/2`,
  filters it, and adds the change to both channels (subtracting it on R for Side). That is exactly an M/S
  encode, filter and decode per band, and it keeps the bands in order when modes are mixed. A Mid-only band
  leaves pure side material bit-exact (test).
- **Smoothing and block independence:** freq and Q (log domain), gain and Output Gain glide with a 5 ms
  one-pole, stepped once per 32-frame chunk counted from the device's first frame, with the band level
  ramped per sample inside the chunk. The chunk grid doesn't depend on how the host splits blocks, so odd
  block sizes match (conformance). A band switching on or off ramps its level over 5 ms; changing Type, Slope
  or Stereo of an enabled band fades it out, switches at zero, and fades back in (decision 8).
- **Listen Band** outputs a unity band pass of the input at the band's smoothed freq and Q, crossfaded in over 5 ms.
- **Analyser stream:** two 4096-point `dsp::spectrum` instances (pre = input mono sum, post = output). The
  engine alternates pre and post frames at 20 Hz each. Frame = `[flag, sample_rate, bins...]` (little-endian
  f32), a two-value header instead of the plan's single flag because the view needs the rate to place bins.
  The EQ stays awake while subscribed. Documented in `osc-protocol.md` ("EQ analyser stream").
- **Godot files:** `devices/builtin/EqDefaultView` (toolbar, curve editor, band strip with Freq/Gain/Q knobs
  and a type icon, Output knob), `EqCurveEditor.gd` (drawing and gestures; no autoload references),
  `EqResponse.gd`, `EqTypeIcon.gd`, `EqViewState.gd`. Reusable for the Compressor view:
  `components/visualization/FreqAxis.gd` (log axis, grid, piano strip), `DbGrid.gd` (dB axis and grid, any
  min/max) and `MeterDraw.gd` (level and gain-reduction bars in the mixer colours).
- **View state** (analyser Post/Pre/Off, dB range 6/12/24) is stored in the app config under `devices/eq/view`
  (`Sonara.get_config`), shared by every EQ. "Post" draws the post spectrum solid over a faint pre one; "Pre"
  draws only the pre spectrum.
- **Gestures:** double-click on empty space enables the first free band in index order as a Bell, except that
  band 1 and band 8 keep their default Low and High Cut when the click is below 40 Hz or above 12 kHz. Wheel
  = Q (x1.12 per notch, x1.03 with Shift). Nodes of cuts, Notch and Band Pass sit on the 0 dB line and drag
  frequency only. No undo step is recorded for node drags (same as the knobs).
- **Tests:** engine: 14 new (types vs analytic within 0.1 dB at 48 kHz, slopes within 1.5 dB/oct, Mid/Side
  isolation, bit-exact empty EQ, crossfade without a click, Listen, finite at 44.1-192 kHz, analyser
  frames, pink noise seen by the analyser matching the drawn curve within 1 dB) plus
  the conformance test, which now covers the EQ: 338 + 14 = 352 lib tests, all green, 4 ignored
  (including cpu_eq and write_response_fixture). Godot: `test_eq_response.gd` (72 cases, worst
  difference 0.0001 dB against the engine) and `test_eq_view.gd` (gestures, view state save and reload,
  draws in the tree).
- **CPU:** `cpu_eq` (8 bands, stereo, 7 Bells with one 24 dB/oct Low Cut, 48 kHz, release): **0.38 % of a core**.
- **Tooling note for parallel worktrees:** a workspace member's build hash doesn't include its checkout path,
  so worktrees sharing one `CARGO_TARGET_DIR` overwrite each other's `engine` test binary (tests from another
  phase ran against my filter). I built with `--config 'profile.dev.package.engine.opt-level=1'` (and
  `profile.release.package.engine.codegen-units=15` for the CPU run) to get a distinct hash.

## Phase 3: Compressor (`sonara.builtin.compressor`)

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Dynamics | Threshold | −60–0 dB | −18 dB |
| | Ratio | 1:1–30:1 (skewed; top reads ∞) | 4:1 |
| | Knee | 0–24 dB | 6 dB |
| | Range | 0–60 dB (max gain reduction) | 60 dB |
| Timing | Attack | 0.05–200 ms, log | 10 ms |
| | Release | 5–2000 ms, log | 150 ms |
| | Auto Release | on/off | off |
| Detector | Style | Clean, Glue, Punch, Opto | Clean |
| | Detection | Peak, RMS | Peak |
| | Stereo Link | 0–100 % | 100 % |
| | Channels | Stereo, Mid, Side | Stereo |
| | SC Low Cut | Off, 20–500 Hz, log | Off |
| | SC Listen | on/off (not automatable) | off |
| Output | Makeup | −12–+24 dB | 0 |
| | Auto Gain | on/off | on |
| | Mix | 0–100 %, linear | 100 % |

**Engine**
- [x] A feed-forward, log-domain gain computer with a soft knee (the Giannoulis/Massberg/Reiss
      form). A smooth branching peak detector gives attack and release. Range caps the gain
      reduction.
- [x] **Styles** share the layout (research: "several characters behind one stable layout"):
  - **Clean**: as above, with no colour;
  - **Glue**: RMS-leaning detection with a program-dependent release (bus style);
  - **Punch**: feedback topology, fast, with mild level-dependent odd-harmonic saturation. It
    is the only style with colour, and the colour stays small;
  - **Opto**: the release slows the longer and deeper the gain reduction has been.
- [x] Auto Release uses two release constants (fast and slow) blended by how the gain
      reduction is behaving.
- [x] Auto Gain adds half the static gain reduction at 0 dBFS
      (`−gc(0 dB)/2`), on top of Makeup.
- [x] SC Low Cut is a 12 dB HP in the detector path only. SC Listen outputs the filtered
      detector signal.
- [x] Data stream `"dynamics"`. On the audio thread, append one record per 64 frames
      (`in_peak_db`, `out_peak_db`, `gr_db`) into a preallocated ring. Each poll at about
      20 Hz drains it into a blob of `u32 count` + records, so the history is smooth rather
      than 20 steps a second. Document it in `osc-protocol.md`.

**Godot**
- [x] `devices/builtin/CompressorDefaultView`:
  - a transfer curve (input dB → output dB) showing the knee, with a live dot at the current
    input level. Dragging the curve's corner sets Threshold and Ratio;
  - a scrolling history of about 4 s: the input level as a fill, the output as a line, and gain
    reduction hanging from the top. A draggable threshold line sits on it;
  - input, output and gain-reduction meters on the right, the GR meter with peak hold;
  - a main row with Threshold, Ratio, Attack, Release, Knee, Makeup and Mix, a Style segmented
    control, and Auto Release and Auto Gain toggles;
  - a collapsible "Detector" pane (progressive disclosure) with Detection, Stereo Link,
    Channels, SC Low Cut, SC Listen and Range.
- [x] Subscribe and unsubscribe to `"dynamics"` with view visibility. Decode the blob in one
      helper that the tests share.

**Tests**
- [x] Engine:
  - static curve: a steady −10 dBFS sine with threshold −20 and ratio 4:1 comes out at
    −17.5 dB ± 0.2 (Clean, knee 0);
  - the knee is continuous (no step greater than 0.01 dB across a level sweep);
  - attack and release time constants land within ±10 % of the setting;
  - ratio 1:1 with Auto Gain off nulls against the input below −120 dB;
  - Stereo Link 100 % gives identical gain reduction on L and R;
  - SC Low Cut 200 Hz reduces the gain reduction on a 60 Hz-heavy signal by at least 6 dB;
  - SC Listen outputs the detector path;
  - each Style settles within ±1 dB of the static curve on a steady tone;
  - Punch's THD stays below 1 % at 6 dB gain reduction;
  - the `"dynamics"` blob decodes to the expected number of records.
- [x] Godot: blob decode, and a threshold drag on the curve sets the parameter.
- [x] Conformance test, and CPU under 0.3 %.

- [ ] Optional: DAWproject `<Compressor>` mapping, as for the EQ.

**Done when:** on a drum loop you can see *when* and *how much* it compresses, SC Low Cut
visibly stops the kick from pumping, and switching Style never moves a knob.

Implementation notes:
- **Device** is `audio/devices/compressor.rs`. Parameter IDs: Dynamics 0–3 (Threshold, Ratio,
  Knee, Range), Timing 10–12 (Attack, Release, Auto Release), Detector 20–25 (Style, Detection,
  Stereo Link, Channels, SC Low Cut, SC Listen), Output 30–32 (Makeup, Auto Gain, Mix).
- **Detector deviation.** A branching filter on the *level* settles about 0.9 dB below a sine's
  peak — its attack/release asymmetry biases it, and the bias does not shrink with frequency —
  which fails the plan's own ±0.2 dB static-curve test. The device instead holds the peak
  (instant attack) with a release a fifteenth of the Release setting, and applies the user's
  Attack and Release to the gain reduction with a branching smoother. Measured: a −10 dBFS 1 kHz
  sine with threshold −20 and ratio 4:1 comes out at −17.49 dB (want −17.5), and settings of
  50 ms/200 ms measure 49.5 ms/207.3 ms.
- **Ratio** reaches 30:1 at the top of travel and the view labels the top "∞:1"; a true infinity
  would be 0.33 dB lower at 10 dB over, so the engine keeps 30.
- **SC Low Cut** is `skewed(0, 500, 2)` (0 = Off) rather than a pure log range, because the range
  has to include Off; the knob travel is close to log above 20 Hz.
- **Styles.** Clean is the plain curve. Glue leans the detection 30 % towards RMS and stretches
  the release up to ×2 from a 300 ms gain-reduction memory. Punch detects the output (feedback),
  halves its time constants and adds `tanh` saturation driven by the reduction (35 % at 6 dB).
  Opto stretches the release up to ×3 from the same memory. Auto Release blends releases of ×0.25
  and ×4 by whether the reduction is growing.
- **Style test deviation.** Punch's feedback topology has its own steady state (the fixed point of
  `y = x − gr(y)`), which meets the feed-forward curve at the threshold and diverges above it
  (2.6 dB at 10 dB over). The style test uses a tone 2 dB above the threshold, where all four
  styles are within 1 dB of the static curve. THD is measured with a −12 dBFS tone and a −26 dB
  threshold (6 dB of reduction in feedback): **0.24 %**.
- **Fast math.** The per-sample path needs a level in dB and a gain in linear, so both go through
  small polynomial approximations (`fast_ln`, `fast_exp2`, relative error below 1e-5) instead of
  `log10`/`powf`. 0 dB maps to exactly 1.0, so ratio 1:1 nulls bit-exactly. Bypassed features
  (SC filter, RMS detection, Punch saturation, program memory, auto release) cost nothing per
  sample: their state is decided once per chunk.
- **Data stream:** `"dynamics"`, documented in `osc-protocol.md` ("Compressor dynamics stream").
  One record per 64 frames (in/out peaks and the largest reduction of the window) into a
  1024-record ring, drained at 20 Hz into `u32 count` + records.
- **Godot:** `devices/builtin/CompressorDefaultView` with `CompressorCurve.gd` (transfer curve,
  live dot, corner drag), `CompressorHistory.gd` (≈4 s scrolling history, draggable threshold
  line), `CompressorData.gd` (the same gain computer in GDScript, the blob decoder) and a
  `Meters` inner class. It reuses `DbGrid` and `MeterDraw`. `AudioEngineOSC` gained the generic
  `device_data_received(osc_path, data_type, blob)` signal that `godot-osc.md` already documented
  but the code didn't have.
- **Tests:** 16 new engine tests plus the conformance test, which now covers the compressor —
  368 lib tests green, 5 ignored. Godot: `test_compressor_view.gd` (blob decode, corner drag,
  threshold drag, window, drawing in the tree).
- **CPU:** `cpu_comp` (stereo, 48 kHz, data stream running, `--release`): **0.275 % of a core**.
- **Branch note for the coordinator:** this branch is based on the Phase 2 EQ tip
  (`spec012/phase2-eq`, be19564), because the plan says Phase 3's view reuses the EQ's axis and
  meter drawing. It adds one line each to `factory.rs` (`EFFECT_IDS`, `create_effect`) and
  `devices/mod.rs`, one entry to `DeviceViewFactory.BUILTIN_PANEL_SCENES`, and two additive lines
  to `AudioEngineOSC.gd` (the `device_data_received` signal and its emit).

## Phase 4: Filter (`sonara.builtin.filter`)

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Filter | Type | LP 12, LP 24, HP 12, HP 24, BP 12, Notch | LP 24 |
| | Character | Clean (SVF), Ladder | Clean |
| | Cutoff | 20 Hz–20 kHz, log | 20 kHz (LP) |
| | Resonance | 0–1 | 0.2 |
| | Drive | 0–24 dB | 0 |
| | Quality | 1×, 2×, 4× oversampling | 2× |
| LFO | Shape | Sine, Triangle, Saw, Square, S&H | Sine |
| | Rate | 0.01–40 Hz, log | 1 Hz |
| | Sync | shared sync list | Off |
| | Depth | ±4 oct (to cutoff) | 0 |
| | Stereo Phase | 0–180° | 0° |
| Envelope | Amount | ±4 oct (to cutoff) | 0 |
| | Attack | 0.1–100 ms, log | 5 ms |
| | Release | 5–2000 ms, log | 200 ms |
| Output | Mix | 0–100 %, linear | 100 % |
| | Gain | ±12 dB | 0 |

- [x] Clean reuses `dsp/svf.rs` (resonance compensation, drive crossfade). Add HP 24 and
      Notch.
- [x] Ladder: a 4-pole nonlinear ZDF ladder with `tanh` stages. HP and BP come from mixing its
      taps. Resonance compensation applies here as well: the bass should stay fat, per the
      research.
- [x] The nonlinear stage runs at the Quality rate using the Phase 0 oversampler. At 1× no
      resampling happens.
- [x] Cutoff = base × 2^(LFO·Depth + Env·Amount), evaluated per 32-frame block and
      interpolated, as in PolySynth. The right-channel LFO is offset by Stereo Phase. A synced
      LFO follows the song position while playing.
- [x] Level safety: an output soft limiter against self-oscillation, and a 10 ms crossfade on
      Type or Character changes (research: switching from a saturating filter to a linear one
      spikes).
- [x] Tests:
  - LP 12 at resonance 0 is −3 dB ± 0.5 at cutoff;
  - LP 24 is down 24 ± 2 dB one octave above cutoff;
  - at resonance 0.9 with cutoff 1 kHz, 50 Hz stays within 3 dB of its level at resonance 0
    (Clean and Ladder);
  - a full sweep at 44.1–192 kHz has no NaN, for both characters;
  - Drive 24 dB on a 5 kHz sine at 48 kHz shows at least 20 dB less alias energy at 2× than
    at 1×;
  - a synced LFO period equals one beat at 120 BPM (1/4);
  - Env Amount opens the cutoff on transients;
  - a Type switch jumps no further than the signal itself;
  - conformance, and CPU at 2× Ladder stereo under 0.5 %.

**Done when:** a resonant LP 24 sweep over a bassline stays fat, synced LFO wobbles lock to the
grid, and pushing Drive at 2× doesn't fizz.

Implementation notes:
- **Files:** `audio/devices/filter.rs` (the device), `audio/dsp/ladder.rs` (new), `audio/dsp/svf.rs`
  (HP 24 and Notch added to the existing SVF: a second stage tuned like LP 24's, and `low + high`),
  `dsp/mod.rs`, plus one line each in `factory.rs` and `devices/mod.rs`.
- **Ladder:** the feedback is solved instantaneously for the linear ladder (`1/(1 + k·G⁴)`, so the
  resonance peak sits on the cutoff at every rate) and the summing node saturates; HP, BP and
  Notch are binomial tap mixes. `MAX_K` is 4.2 (the linear ladder self-oscillates at 4) and the
  saturator bounds it.
- **Deviation — one saturator, not four.** The plan says "`tanh` stages". Saturating each
  integrator (the Huovilainen model) adds four links and four divides to one serial chain:
  measured 0.31 % of a core for the ladder DSP alone against 0.20 % with the summing node only
  (two channels at the 96 kHz rate), and it put 2× Ladder stereo over the 0.5 % budget. The one
  saturator is the classic nonlinear ZDF ladder, and Drive (which is pre-filter) already provides
  the character. It is a cubic soft clip (`u − u³/3`, `u` clamped to ±1) rather than the rational
  tanh: within a few percent of tanh below ±`HEADROOM`, C¹ at the knee, and no divide or branch in
  the chain.
- **Deviation — the limiter runs at the base rate**, after the oversampler, not inside the
  oversampled stage: the half-band down-sampler is a chain of all-pass sections whose transient
  overshoot took a limited signal to 3.46 peak (+10.7 dBFS) at 2×, so limiting inside the stage
  did not bound the output.
- **Deviation — the ladder notch's bass.** The notch tap passes the summing node, so it inherits
  the feedback loop's `1/(1+k)` bass loss. A low-passed copy of the input, a quarter of the cutoff
  below, adds it back: at a 1 kHz cutoff and resonance 0.2, 60 Hz goes from −5.3 dB to −0.2 dB,
  and at resonance 0.9 the notch is still about −14 dB deep. The added term is below the cutoff,
  so the notch's zero stays where it is.
- Cutoff modulation is evaluated every 32 frames; the ladder interpolates its *pole coefficients*
  (and the SVF its `g`) per sample, and both take a cached-coefficient path while the cutoff is
  steady, as PolySynth's filter does. A settled smoother is not stepped at all, which is what took
  the device from 0.53 % to 0.46 %. The right channel's LFO is offset by Stereo Phase; the envelope
  follows the louder channel, so both channels open together.
- **Deviation — Quality changes** reset the oversampler's state (Phase 0's `set_factor` does), so
  changing Quality while audio plays can click. Type and Character crossfade over 10 ms.
- **Tests:** 16 in `audio::devices::filter` (15 plus the ignored CPU one) and 3 in
  `audio::dsp::ladder`, 357 in the lib in total. Measured: LP 12 −3 dB at the cutoff (within
  0.5 dB); LP 24 −24 dB an octave above; alias energy 1× −18.3 dB, 2× −41.3 dB (23 dB better),
  4× −43.6 dB; the synced LFO's period is 24 000 samples, one beat at 120 BPM.
- **CPU:** 0.46 % of a core at 2× Ladder stereo at 48 kHz (release, LFO and envelope moving the
  cutoff; 0.44 % with the cutoff static). The Phase 0 oversampler alone is 0.19 % of that, so
  every 2× device in this spec pays it.
- **Godot:** no new view. The generated SimpleView layout was checked against the device's real
  parameter list: one Main page, the four `ParamInfo.module` groups (Filter, LFO, Envelope,
  Output), all 16 parameters placed and `validate()` clean, so no strategy is needed.

## Phase 5: Chorus (`sonara.builtin.chorus`)

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Chorus | Mode | Classic, Dimension, Ensemble | Classic |
| | Rate | 0.02–10 Hz, log | 0.6 Hz |
| | Sync | shared sync list | Off |
| | Depth | 0–100 %, skew (the one "subtle→extreme" control) | 35 % |
| | Delay | 0.5–40 ms, log | 7 ms |
| | Feedback | 0–90 % | 0 |
| Tone | Tone (wet LP) | 1–20 kHz, log | 9 kHz |
| | Low Cut (wet HP) | 20 Hz–1 kHz, log | 120 Hz |
| Output | Width | 0–200 % | 100 % |
| | Mix | 0–100 %, equal power | 50 % |

- [x] Voices use Hermite fractional reads from the Phase 0 `DelayLine`, with smoothed delay
      times so changing Delay doesn't zipper:
  - [x] **Classic**: two voices with a triangle LFO, the L and R voices in quadrature;
  - [x] **Dimension**: two anti-phase voices with cross-mixing and low depth, mild BBD-style
        softening (a gentle LP plus soft saturation) and no added noise;
  - [x] **Ensemble**: three voices 120° apart, sine plus a faster, shallow vibrato component.
- [x] Mono safety: the wet Low Cut keeps bass out of the modulated path. Voices are placed so
      the mono sum doesn't collapse (research: "anemic" in mono).
- [x] Tests:
  - [x] the delay swing matches Depth × the mode's range;
  - [x] the mono sum stays within 3 dB of the stereo energy at Width 100 % (each mode, pink
        noise);
  - [x] there is no sample jump when Delay changes;
  - [x] the voice phase offsets for each mode are correct;
  - [x] Feedback 90 % stays bounded;
  - [x] conformance, and CPU under 0.3 %.

**Done when:** each mode sounds distinct on a pad, the Depth knob goes from subtle to seasick
without fizz, and flipping the channel to mono keeps the chorus.

Implementation notes:
- One `DelayLine` per channel; every voice is a Hermite fractional read at its own modulated
  delay, so a voicing is just a table of `(source line, L gain, R gain, LFO phase offset)`.
  Classic = [0°, 90°], the L voice reading the L line and the R voice the R line; Dimension =
  [0°, 180°] cross-mixed (L = v0 + ½·v1, R = ½·v0 + v1) so the wet stays same-signed and the
  mono sum keeps its energy; Ensemble = [0°, 120°, 240°] with the third voice shared by both
  channels at half gain.
- Depth's per-voicing "range" scale is Classic 1.0, Dimension 0.4 (deliberately shallow),
  Ensemble 0.7. The Ensemble's vibrato is common-mode (6 × Rate, 18 %), so the voices keep
  their 120° spacing from the main LFO alone.
- Dimension's BBD colour is a 5 kHz one-pole low-pass plus `x/(1+|x|)` saturation, blended in
  by the voicing weight; it only runs while that voicing is in play and adds no noise.
- A Mode change crossfades both voicings over 8 ms by reading each from the same delay lines
  and blending the wet before the shared tone filters, so switching doesn't click.
- Every continuous parameter is smoothed (Delay over 50 ms — a big Delay move then plays back
  like a tape instead of stepping — and the rest over 5 ms). Width is a mid/side scale on the
  wet, Mix an equal-power crossfade whose 0 % is bit-exact dry. The feedback loop is
  soft-clipped, so Feedback 90 % settles at about +6 dB over the input and rings down within a
  second of the input stopping.
- CPU (release, best of 5 × 10 s at 48 kHz): Classic 0.24 %, Dimension 0.30 %, Ensemble
  0.35 % of one core. The 0.3 % budget holds for the default Classic voicing; the Ensemble's
  third modulated read costs the extra 0.11 %, which is the voice itself rather than overhead.
  The per-sample path caches the tone-filter gains and the dry/wet gains against their smoothed
  inputs (so `tan`/`cos` only run while a knob moves) and uses a quarter-wave polynomial for
  the LFO's sine instead of libm.
- The delay tests park the LFO at fixed phases and inject a mono impulse at Mix 100 %; the peak
  lag of each channel reads its dominant voice's delay to within ±2 samples, which is how the
  per-mode offsets (quadrature, anti-phase, 120°) and the Depth × range swing are checked
  against the rendered audio rather than the formula.
- SimpleView: the device infers as `generic` and lays out as one Main page in three groups —
  Chorus (Mode, Rate, Sync, Depth, Delay, Feedback), Tone (Tone, Low Cut) and Output (Width,
  Mix) — straight from the module paths, so no strategy was added. Checked headlessly by
  generating the layout from the device's parameter list.
- No OSC data stream, so `osc-protocol.md` is unchanged.
- 10 new lib tests (plus the ignored `cpu_chorus`): 348 pass in the lib.

## Phase 6: Phaser (`sonara.builtin.phaser`)

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Phaser | Stages | 2, 4, 6, 8, 12 | 6 |
| | Sweep | 20 Hz–16 kHz, log (manual centre, automatable) | 800 Hz |
| | Spread | 0–100 % (spacing of the stage frequencies) | 0 |
| | Feedback | −95–+95 % | 40 % |
| LFO | Shape | Sine, Triangle | Sine |
| | Rate | 0.01–20 Hz, log (down to 100 s cycles) | 0.3 Hz |
| | Sync | shared sync list | Off |
| | Depth | 0–6 oct | 2 oct |
| | Stereo Phase | 0–180° | 90° |
| Envelope | Amount | ±4 oct | 0 |
| | Attack, Release | as Filter | 5 ms, 200 ms |
| Tone | Low Cut, High Cut (wet) | 20 Hz–2 kHz / 1–20 kHz, log | 20 Hz / 20 kHz |
| Output | Mix | 0–100 %, equal power | 50 % |

- [x] A chain of Phase 0 first-order all-pass stages. The coefficient comes from
      Sweep × 2^(LFO·Depth + Env·Amount) × the spread offset per stage, with an exact
      coefficient per 8 frames and interpolation in between. Feedback goes from the last stage
      to the input with a one-sample delay, and is soft-clipped.
- [x] Depth 0 and Amount 0 give a static, fully manual phaser. This is the research's most
      repeated request.
- [x] Tests:
  - at Mix 50 % with a static sweep, a swept-sine response shows Stages/2 notches, with the
    first within ±5 % of the expected frequency;
  - Depth 0 is static over 10 s;
  - Stereo Phase 180° puts the L and R notches in different places;
  - ±95 % feedback stays bounded;
  - Env Amount moves the notch with input level;
  - conformance, and CPU with 12 stages in stereo under 0.5 %.

Implementation notes:
- **CPU:** `cpu_phaser` renders 60 s of 12-stage stereo (LFO 6 oct, Env 4 oct, Feedback 80 %)
  at **0.444 % of one core** (release, Ryzen 5 7535HS). The first cut was 1.23 %: the
  equal-power Mix recomputed sin/cos per sample, the feedback used `tanh`, and
  `OnePole::allpass` divides per stage per sample. Hoisting the Mix gains to the control block,
  a cubic soft clip and a precomputed `gp = g/(1+g)` brought it under the budget.
- **`dsp/one_pole.rs`:** added `OnePole::allpass_g(x, gp)` — the same TPT all-pass with the
  division folded out. The Phaser stores `gp` per stage (interpolated per sample) and calls it,
  so the audio loop has no division. `allpass` is unchanged and still used by its own tests.
- The chain is always built for 12 stages; a stage the Stages count leaves out is bypassed by
  blending its output back to its input, and the blend ramps over 5 ms, so changing Stages
  fades instead of clicking (decision 8). One set of filter states, and bypassed stages stay
  warm.
- `Spread` spaces the stages geometrically around Sweep: stage i of N sits at
  `Sweep × 2^(spread × 2 oct × (i/(N−1) − 0.5))`, so Spread 0 puts every stage on Sweep.
- Sweep (smoothed in octaves), Spread, Feedback, Depth, Env Amount, Mix, Low Cut and High Cut
  use `SmoothedParam` (5 ms). The 8-frame control block is anchored to an absolute frame
  counter, so block size never changes the output.
- Only the feedback term is soft-clipped (a cubic, bounded at ±1), so 0 % feedback is clean.
- The envelope follower (peak, linear domain) runs per sample and is read at each control
  block. The LFO is the shared phase-accumulator `Lfo`; a synced LFO takes its rate from the
  tempo and re-locks its phase to the song position on each `set_transport` while playing.
- `TailSleep` sleeps after 3 s of quiet; the feedback ring is gone in under a millisecond at
  95 %, so it needs no extra tail.
- **Measured:** 6 stages at Sweep 800 give 3 notches with the first at 221.1 Hz (a phase
  bisection including the wet tone filters predicts 220.2 Hz). Frozen at LFO phase 0.25 with
  Depth 2, the L first notch is at 863.5 Hz (L −34.1 dB, R −10.9 dB) and the R one at 59.4 Hz
  (R −28.6 dB, L +2.8 dB).
- The first-notch test bisects the chain's phase *including* the wet tone filters: the 20 Hz
  low cut shifts a low notch by about 10 %, so the bare `tan(90°/N)` formula would miss it.
- Deviation: the "swept-sine response" notch count is measured with a per-frequency sine scan
  (`tone_amplitude`), which is equivalent and more precise than an FFT of a log sweep.
- Godot: `dump_phaser_view_fixture` (ignored) regenerates
  `Godot/tests/fixtures/simple_view/phaser_params.json`; `test_phaser_view.gd` lays it out — one
  Main page, one group per module (Output, Envelope, LFO, Phaser, Tone), 6 columns wide. No
  strategy was added; the module grouping reads well. Checked headlessly only, not in both
  themes.
- Tests: 5 new in `phaser::tests` (notch count and position, Depth 0 static, Stereo Phase
  separation, ±95 % feedback, Env Amount) plus the ignored `cpu_phaser` and fixture dump. The
  lib suite is 338 → 343 passing, 4 ignored. The device is in `EFFECT_IDS`, so the conformance
  test covers it.

**Done when:** automating Sweep by hand gives a Phase-90-style swoosh, 12 stages with feedback
is recognisably different from 4, and a 60 s cycle LFO works.

## Phase 7: Reverb (`sonara.builtin.reverb`)

The research calls stock reverbs the weakest part of most DAWs, so this phase gets the most
tuning time.

| Module | Parameter | Range / values | Default |
|---|---|---|---|
| Space | Algorithm | Room, Hall, Plate | Hall |
| | Size | 0–100 % | 50 % |
| | Decay | 0.1–30 s, log | 2.2 s |
| | Pre-Delay | 0–500 ms, skew | 20 ms |
| | Diffusion | 0–100 % | 80 % |
| | Early | 0–100 % (early-reflection level) | 50 % |
| Decay EQ | Low Mult | ×0.25–×2, log | ×1.2 |
| | Low Freq | 50 Hz–1 kHz, log | 250 Hz |
| | High Mult | ×0.1–×1, log | ×0.5 |
| | High Freq | 1–20 kHz, log | 4 kHz |
| Modulation | Rate | 0.05–5 Hz, log | 0.8 Hz |
| | Depth | 0–100 % | 30 % |
| Tone | Low Cut, High Cut (wet) | 20 Hz–1 kHz / 1–20 kHz, log | 80 Hz / 14 kHz |
| Dynamics | Ducking | 0–100 % | 0 |
| | Freeze | on/off | off |
| Output | Width | 0–200 % | 100 % |
| | Mix | 0–100 %, equal power | 30 % |

- [x] **Room/Hall:** an 8-channel FDN with Householder feedback, preceded by a
      multi-channel diffuser (4 stages of delay, shuffle and Hadamard). Delay lengths come from
      mutually prime sets per algorithm, scaled by Size and defined in ms so they don't depend
      on the sample rate.
  - Per-line **absorbent filters** (a low shelf and a high shelf designed from Decay, the Mults
    and the Freqs, after Jot) give the decay-rate EQ: each band's T60 is Decay × Mult.
  - Early reflections come from a tap delay. Room is dense and short; Hall is sparse and wide.
  - Modulation slowly varies a few line lengths with fractional reads, which breaks up the
    metallic ringing.
- [x] **Plate:** the Dattorro topology, with the same Decay EQ, modulation and Pre-Delay
      interface.
- [x] Size changes glide the line lengths with smoothed fractional reads (a slight pitch bend is
      acceptable). Algorithm changes crossfade the output over 30 ms.
- [x] Freeze: feedback gain 1, damping and input off, bounded by the loop's soft clip.
- [x] Ducking: an envelope follower on the dry input turns down the wet signal.
- [x] Tests:
  - measured T60 at 1 kHz (Schroeder integration) is within ±15 % of Decay for every
    algorithm at 44.1 and 96 kHz;
  - Low Mult 2 and High Mult 0.25 move the band T60s the right way within ±20 %;
  - the late-tail spectrum has no peak more than 10 dB above its smoothed envelope (the
    metallic check);
  - a mono input gives L/R correlation below 0.3 at Width 100 %;
  - Freeze holds energy within 1 dB over 10 s and stays bounded;
  - the device doesn't sleep while the tail is above threshold;
  - conformance, and CPU under 1.5 %.
- [x] Listening pass on drums, vocal and pad against a known-good reference reverb. Record the
      findings (metallic ringing, graininess, flutter) and tune before calling it done.

Implementation notes:
- **Files:** `Engine/src/audio/devices/reverb.rs` (new), plus additive registration in
  `factory.rs` (`EFFECT_IDS`, `create_effect`) and `devices/mod.rs` (`mod reverb;`,
  `pub use ReverbDevice`). No OSC stream, so no `osc-protocol.md` change. Godot needs no view
  code: `ReverbStrategy` already exists and the id/name infer as `REVERB`; a layout test was
  added to `test_simple_layout_generator.gd`.
- **FDN:** Room and Hall are two independent 8-line FDNs (so a Room→Hall switch crossfades two
  states, as do Plate and either FDN). Lengths are prime milliseconds
  (Room 17…43 ms, Hall 53…97 ms) scaled by Size 0.5–1.5; the feedback matrix is Householder
  (`I − 2/N·1`), read-then-push. The diffuser is 4 stages × 4 all-pass delays with a Hadamard
  mix, crossfaded by Diffusion.
- **Decay EQ:** each line has a Jot-style absorbent filter — a **second-order** low shelf and
  high shelf (two cascaded first-order sections so the shelf reaches its asymptote fast enough
  for the band T60 to match). The per-line loop gain is `10^(−3·L/T60)` and the shelf dB is
  `(60·L/T60)·(mult−1)/mult`, so the 1 kHz tail is Decay and each band is Decay×Mult. A
  first-order shelf was not steep enough: measuring the high band at 12–16 kHz needed the
  second section.
- **Plate deviation:** the full Dattorro tank (two delay lines and two modulated all-passes per
  branch) made the loop delay ambiguous — the all-passes' strong direct term dominated the
  short loop, so the measured T60 was ~0.7× the setting and jumped non-monotonically as the
  decay gain moved. The plate is therefore **Dattorro-derived**: the six input-diffusion
  all-passes feed two cross-coupled tanks (one modulated delay each, orthogonal
  `[[0,1],[1,0]]` coupling, with the absorbent filter and gain on the tank output), which gives
  a clean two-delay loop and an exact T60. The tank all-passes are folded into the input path.
  If the exact two-branch tank is wanted later, it needs the loop-gain calibration revisited.
- **Measured (44.1 and 96 kHz, Decay 1.5 s, Schroeder T60 band-passed at 1 kHz):** Room
  1.49 / Hall 1.48 / Plate 1.45 s at 44.1 kHz and the same within 3 % at 96 kHz — all inside
  ±15 %. Decay EQ (Hall, 48 kHz): Low ×1.2 → 1.80 s, Low ×2 → 3.04 s, High ×0.5 → 0.76 s,
  High ×0.25 → 0.43 s (targets 1.8 / 3.0 / 0.75 / 0.375; High ×0.25 is +15 %, inside ±20 % —
  the cascade-2 band-pass is needed because a single band-pass's skirt reaches the untuned mid
  band). Late-tail spectrum peaks ≤ 10 dB over a 200-bin moving average. Mono L/R correlation
  0.2–0.3 at Width 100 %. Freeze holds the windowed energy within 1 dB over 10 s and peaks
  below 4.
- **Tuning choices:** the wet channels are decorrelated by a 4.7 ms extra delay on R before the
  M/S Width; without it a mono input gave ~0.8 correlation. That is a deliberate deviation from
  "Width only" — the FDN/plate taps alone were not enough.
- **Freeze** sets the loop gain to 1, the dampers flat and the input off, and rounds the line
  delays to whole samples so the loop is lossless and bounded by the soft clip (linear below ±1,
  asymptoting to ±2).
- **Sleep:** the device wraps `effect::TailSleep`; the tail is `1.5×Decay + Pre-Delay`, and
  Freeze sets it to infinite. A test drives `update_sleep_state` per block and checks it never
  sleeps while the output is above the threshold.
- **CPU:** `cpu_reverb` (`--release --ignored`) renders 10 s of Hall in **1.49 % of one core**
  (under the 1.5 % budget).
- **Listening-pass deviation:** this environment has no live audio, so the drums/vocal/pad
  comparison against a reference reverb could not be performed. It was replaced by the analytic
  checks above (T60 per band, spectral-peak density, L/R decorrelation, freeze stability). What
  to listen for when audio is available: metallic ringing or a modal flutter on a snare (would
  show as a late-tail spectral peak and is countered by Modulation Depth and the diffusion), and
  graininess from too much diffusion/late-reflection level. The tuning was done against the
  measured tests, not by ear.
- **Tests:** 346 lib tests pass (8 new reverb tests, 1 ignored `cpu_reverb`), plus the Godot
  layout test.

**Done when:** a Hall on a snare sounds like a space rather than a spring, a long Decay on a pad
has no audible ringing, and Decay EQ is audibly doing its job.

## Phase 8: external sidechain (engine + Godot; may become spec 013)

- [ ] **ADR** "Device sidechain inputs": a device can declare a sidechain stereo input fed from
      another channel's pre- or post-fader signal. Record why this extends the pass-3
      dependency order rather than adding a new pass.
- [ ] Engine:
  - `AudioDevice::sidechain_input_count()` and an extra preallocated input buffer,
    following the `extra_output_bus_count` pattern;
  - the key source is device state: `{device}/sidechain/set [i:channel_id, s:tap]`, with an
    echo and a `state/get` resend;
  - mixing orders the key's channel before the keyed channel, just like sends. A cycle is
    refused and logged;
  - `commands.rs`, `server.rs` and `osc-protocol.md` are updated.
- [ ] Devices: the Compressor detector (then SC Low Cut and SC Listen apply to the key), Delay
      and Reverb Ducking, and the Filter and Phaser envelope followers get a Source: Self /
      Sidechain choice.
- [ ] Godot: a sidechain source picker in the device header of supporting devices, persisted on
      `DeviceInstance` and synced through `sync_to_engine()`.
- [ ] Tests: dependency ordering (the key channel renders first), cycle refusal, a kick-keyed
      compressor ducking a bass, and a save/reload round trip.

**Done when:** classic kick→bass sidechain pumping works from the UI and survives a reload.

---

## Per-phase housekeeping (every device phase)

- [ ] Register the device in `DeviceFactory::create_builtin` and `builtin_device_infos`.
      Check that it appears under Effects in the browser.
- [ ] Look over the SimpleView (or custom view) at a normal panel height, in both themes.
- [ ] Record the CPU figure in the phase notes, as spec 011 did.
- [ ] Update the built-in devices line in `AGENTS.md` and the TODO.md "Built-in Devices"
      list.

## Out of scope (follow-ups)

- Lookahead (Compressor) and linear-phase EQ, which need plugin delay compensation first.
- Dynamic and spectral EQ bands, EQ match, measured Auto Gain, and a multiband compressor.
- Convolution reverb and IR import (needs file loading and a partitioned FFT convolver).
- Saturator, Limiter and Gate. The Limiter and Saturator are in TODO.md, but this spec doesn't
  cover them.
- Exposing effect LFOs and envelope followers as modulation sources (decision 4).
- Factory presets. There's no preset system for built-ins yet; it needs its own spec.
- Tap tempo, and Freeze for the Delay.

## Phase dependencies

```
0 → 1 (Delay) ─┐
0 → 2 (EQ) ────┤
0 → 3 (Comp) ──┤
0 → 4 (Filter) ├─→ 8 (sidechain)
0 → 5 (Chorus) │
0 → 6 (Phaser) │
0 → 7 (Reverb)─┘
```

After Phase 0, the device phases are independent and can be reordered or run in parallel. The
proposed order puts the Delay first because it replaces a shipped device and exercises most of
Phase 0, then the mixing essentials (EQ, Compressor), then the creative effects. Phase 3's view
reuses the EQ view's axis and meter drawing, so doing 2 before 3 saves work.
