# Pitch Shifter — Design

Implements [requirements.md](./requirements.md).

Paths and symbols were checked against the tree on 2026-10-14.

## Context

- `Engine/src/audio/devices/effects/chorus.rs` is **the template for this device**. It has the
  same shape: per-channel `DelayLine`s read with `read_hermite`, a static `ParamTable` in module
  blocks of ten (`flatten`, `slot_table`, `static TABLE`), `SmoothedParam`s, a Sync enum
  resolved through `division_seconds(sync, self.tempo)` with `tempo` taken from
  `set_transport`, coefficient caching (`last_mix`, `last_tone_hz`), a Mix built on
  `dry_wet_gains(mix, MixLaw::EqualPower)` with an `if wet_gain == 0.0 { dry }` short-circuit (Mix
  0 % bit-exact), `prepare` sizing its lines with `prepare_seconds`, and an ignored
  `cpu_chorus` benchmark. Copy the shape.
- `Engine/src/audio/dsp/delay_line.rs`: `DelayLine::{new, prepare, prepare_seconds, max_delay,
  clear, push, read, read_linear, read_hermite}` and `MIN_HERMITE_DELAY = 2.0`. Reads come before
  the push, and `d = 1` is the newest sample.
- `Engine/src/audio/devices/effects/effect.rs`: `pass_through` and `TailSleep` (`new`,
  `set_sample_rate`, `set_tail_seconds`, `on_block`, `wake`, `is_sleeping`, `update`).
  `delay.rs` shows the hookup: `update_tail()` on feedback changes, and `is_sleeping`,
  `mark_activity` and `update_sleep_state` delegate to `TailSleep`. The default `AudioDevice`
  sleep methods (`devices/device.rs`) never sleep.
- `Engine/src/audio/devices/param_table.rs`: `Kind::{Float, Enum, Bool}`, `linear`, `log`,
  `skewed`, `spec`, `flatten`, `slot_table`, `ParamTable`, `ParamValues::{set, set_offset, real,
  get}`. Only floats are modulatable (`ParamSpec::is_modulatable`).
- `Engine/src/audio/dsp/tempo_sync.rs`: `SYNC_CHOICES` (Off, then 4/1 … 1/32T) and
  `division_seconds`.
- `Engine/src/audio/dsp/noise.rs`: `Rng::{new(seed), next_f32, bipolar}` (seeded xorshift32,
  no allocation).
- `Engine/src/audio/dsp/saturate.rs`: `soft_clip` (bounded), as used in the Delay's feedback.
- `Engine/src/audio/dsp/one_pole.rs`: `one_pole_g`, `OnePole::{new, lowpass, highpass}`.
- `Engine/src/audio/dsp/gain.rs`: `dry_wet_gains`, `MixLaw`.
- `Engine/src/audio/dsp/test_util.rs`: `sine`, `impulse`, `white_noise`, `stereo`, `left`,
  `right`, `render`, `peak`, `rms`, `tone_amplitude`, `spectrum_db`, `instantaneous_freq`.
- `Engine/src/audio/devices/factory.rs`: `EFFECT_IDS` and `create_effect`'s match. Being listed
  in `EFFECT_IDS` puts the device in `builtin_device_infos()` and in the conformance battery.
- `Engine/src/audio/devices/effects/effect_conformance.rs`: `every_builtin_effect_conforms` and
  `_wrapped` (parameter round trip, defaults, bypass, Mix 0 % bit-exact, finite at
  44.1–192 kHz, block-size independence, reset clears the tail, the tail dies out, modulation
  offsets).
- `Engine/src/audio/devices/effects/mod.rs`: `mod …;` plus `pub use …Device;` per effect.
- The device's `prepare` runs on the command thread (`command_worker/audio_config.rs`
  `set_device_rate` → `visit_devices_mut` → `device.prepare`), so sizing the buffers there is
  allowed. The audio stream already calls `flush_denormals_to_zero()` (`stream.rs`).
- Godot: no custom view. `DeviceViewFactory.BUILTIN_PANEL_SCENES` has no entry, so the
  generated Simple View (`devices/simple_view/`, `GenericStrategy`) is used, as for the Phaser
  and Chorus. `DeviceParameter.is_whole_number()` already shows and snaps a linear float with
  unit `"st"` and whole-number bounds in whole steps. A Sync enum with 25 choices becomes a
  dropdown (`tests/test_phaser_view.gd`). The Phaser's layout test reads an engine-dumped
  fixture (`phaser.rs` `dump_phaser_view_fixture` → `Godot/tests/fixtures/simple_view/phaser_params.json`).
- Docs: `docs/subsystems/osc-protocol.md` "Built-In Devices" (one entry per device, for example the
  Saturator's), the AGENTS.md built-in list, and `docs/subsystems/engine-architecture.md`'s
  `effects/` line.

## Approach

A new built-in effect, `sonara.builtin.pitch_shifter` ("Pitch Shifter"), in
`devices/effects/pitch_shifter.rs`, built the way `chorus.rs` is. The DSP is a **delay-line
granular shifter**. Each channel has one `DelayLine`. A small number of read taps (`TAPS`) move
through it at the pitch ratio `r` while the write head moves at 1. Each tap is faded in and out by
a window driven by one shared **grain phasor**, with the taps evenly spaced in phase, so the windows
always sum to exactly 1.

**Tap delays are integrated, not computed from a formula.** When a tap restarts (its window is at
zero), its delay is set to a start value:

- pitch up (`r > 1`): `d₀ = D_MIN + (r − 1) · T_max + offset`, where `T_max` is the longest the
  coming grain can last in frames;
- pitch down or none (`r ≤ 1`): `d₀ = D_MIN + offset`.

`offset` is the Jitter offset described below. After the restart, the tap's delay changes by
`1 − r` each sample, clamped to `[D_MIN, max_delay]`. Because the delay is only ever integrated,
changing Pitch, Fine, Spread or Grain mid-grain changes the slope, never the position, so
automation can't click (REQ-012). When `r = 1` the delay stays at `D_MIN` for every tap, and the
weights sum to 1, so the wet is the input delayed by `D_MIN` (REQ-006). `D_MIN =
MIN_HERMITE_DELAY` (2 samples, far under the 5 ms in REQ-011).

**Ratios.** Total cents per channel: `100·Pitch + Fine ± Spread`, with left `+Spread` and right
`−Spread`. Pitch is rounded to whole semitones in `apply`, and the sum is smoothed (5 ms).
`r = 2^(cents/1200)` is recomputed only when the smoothed value moves, using the same caching as
`chorus.rs` `last_*`. Each channel has its own tap delays (`taps[ch][k]`), so Spread is just a
different `r` per channel while both channels share the phasor and the windows.

**Grain.** The phasor advances `f_g / sr` per sample. `f_g` is the smoothed Grain Hz, or, when
Grain Sync is not Off, `1 / division_seconds(sync, tempo)`. Both are **clamped to 1–100 Hz**. The
clamp means that synced divisions longer than one second (for example 1/2 at under 120 BPM, or
1/1 and longer) play as 1 Hz grains. This keeps the worst-case buffer bounded. The REQ-005a check
(1/16 at 120 BPM) is well inside the range. Windows: tap `k` has phase `φ_k = frac(φ + k/TAPS)`
and weight `(2/TAPS)·sin²(π·φ_k)`. Those sum to 1 for `TAPS ≥ 2`, and for `TAPS = 2` they are one
`sin_cos` per sample. `TAPS` is a `const`, starting at 2 (Bitwig's character). The Jitter/comb
listening test decides whether it becomes 4. That is a one-line change, and the buffer and window
code are generic over it.

**Jitter** (0–1). It works through two seeded random draws from `Rng`, so renders are
deterministic (REQ-007):

1. When the phasor wraps, the next cycle's rate is scaled by `1 + 0.5·J·u`, with `u` in [−1, 1].
   The phasor is shared, so the windows still sum to 1. `T_max` in the pitch-up start delay uses
   the slowest possible rate, so a tap never reaches `D_MIN` before its window closes.
2. When a tap restarts, it adds `offset = J · u₀₁ · min(0.25·T, MAX_JITTER_OFFSET)` (with
   `MAX_JITTER_OFFSET` = 30 ms). This decorrelates the taps, which is what breaks up the
   periodic comb.

At `J = 0` both draws are skipped, so nothing changes from the plain shifter.

**Feedback.** `fb_in = soft_clip(lp(hp(wet)))` is a fixed one-pole low cut at 30 Hz (it stops
cascading down-shifts from piling up near DC) followed by a fixed one-pole **high cut at
8 kHz** (the gentle damping agreed at the gate). The line is pushed with `input + feedback ·
fb_in`, after the taps are read, which is the `DelayLine` read-then-push order. `soft_clip` bounds
the loop even with Hermite overshoot, which is the Delay's approach.

**Mix.** Equal-power `dry_wet_gains` with the Chorus's `wet_gain == 0.0` short-circuit (REQ-010).
Non-finite input samples are replaced by 0 before both the dry and the wet path. Finite input is
untouched, so the Mix 0 % null test still holds, and NaN or Inf never reaches the lines (REQ-013).

**Tail and sleep.** A `TailSleep`. `update_tail()` runs whenever Feedback, Pitch, Fine, Spread,
Grain or Sync changes: `loop = D_MIN + |r_max − 1|·T/2 + T` (the average tap delay plus one
grain), `repeats = ceil(ln 0.001 / ln fb)` (1 when fb ≈ 0), and `tail = (repeats + 1)·loop`.
Feedback is capped at 95 %, so the tail is always finite.

**Rejected alternatives.**

- *A phase vocoder / spectral shifter* sounds cleaner but needs latency reporting and is the
  out-of-scope HQ mode.
- *A delay computed directly from the phasor*, `d = D_MIN + |r−1|·T·φ`, is the textbook form, but
  `d` jumps whenever `T` or `r` changes mid-grain. Grain or Pitch automation would click. The
  integrated form avoids that.
- *Pitch as an Enum* like the PolySynth's Semi would display neatly, but enums aren't
  modulatable. A linear float with unit `st` is modulatable, and Godot already snaps and shows it
  as whole numbers.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `lines: [DelayLine; 2]` (sized in `prepare`) | audio callback (`process_block`) | command thread calls `prepare`/`reset`; it holds the state lock, so the callback isn't running | yes. `prepare` allocates on the command thread only; the callback only reads and pushes |
| `taps: [[f32; TAPS]; 2]`, `phasor`, `rate_mult`, `rng` | audio callback | `reset` (command thread, under the lock) | yes, plain fields |
| `params: ParamValues`, the `SmoothedParam`s | command thread sets targets via `set_parameter` / `set_param_mod` | the callback reads them through `next()` under the state lock | yes (existing pattern) |
| `tempo` | `set_transport` (the callback, per block) | the callback | yes |
| `tail: TailSleep` | the callback (`on_block`, `update`) and the command thread (`set_tail_seconds` / `wake` from `set_parameter`) | under the state lock | yes, arithmetic only |

**Buffer size.** The worst-case sweep is `|r − 1| · T` at the largest ratio (±24 st + 100 ct
Fine + 50 ct Spread gives `r ≈ 4.9`) and the longest grain (1 s). That is `MAX_SWEEP_SECONDS ≈
3.9 s`. Jitter's rate scaling is floored at the same 1 Hz clamp (`max(f_g · (1 + 0.5·J·u),
1 Hz)`), so it never lengthens a grain past 1 s. The lines are sized as
`prepare_seconds(MAX_SWEEP_SECONDS + MAX_JITTER_OFFSET + headroom)`, about 4 s. That is a 256 k
power of two (1 MB) per channel at 48 kHz, and 1 M (4 MB) per channel at 192 kHz. That is the same
order as the Delay's 5 s lines.

## Data and protocol changes

- **No new OSC message.** The device is reached through the existing device and parameter
  messages, and it appears in `/builtin/info` because it is listed in `EFFECT_IDS`.
- **Parameter table** (ID blocks of ten; real ranges travel in `/builtin/info`):

| ID | Name | Module | Unit | Kind | Default |
|---|---|---|---|---|---|
| 0 | Pitch | Pitch | st | `linear(-24, 24)`, rounded to whole semitones | 0 |
| 1 | Fine | Pitch | cents | `linear(-100, 100)` | 0 |
| 10 | Grain | Grain | Hz | `log(1, 100)` | 20 |
| 11 | Sync | Grain | | `Enum(SYNC_CHOICES)` | Off |
| 12 | Jitter | Grain | % | `linear(0, 100)` | 0 |
| 20 | Feedback | Feedback | % | `linear(0, 95)` | 0 |
| 30 | Spread | Output | cents | `linear(0, 50)` | 0 |
| 31 | Mix | Output | % | `linear(0, 100)` | 100 |

  The Sync parameter is named plain "Sync" (not "Grain Sync") to match the Phaser's LFO "Sync",
  so the Simple View treats both the same way.
- **Godot:** no model changes. The device is generic.
- **Persisted format:** none. The parameters use the existing device-parameter persistence.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/effects/pitch_shifter.rs` | **New.** `PitchShifterDevice`: the parameter table above, the granular core (`TAPS`, integrated tap delays, shared phasor, windows, Jitter), feedback filters + `soft_clip`, Mix, `TailSleep` hookup, `set_transport`, `prepare`, `reset`, `AudioDevice` impl (id `sonara.builtin.pitch_shifter`, name "Pitch Shifter", `DeviceCategory::Effect`). The `mod tests` block holds the unit tests from the test plan, an ignored `cpu_pitch_shifter`, and an ignored `dump_pitch_shifter_view_fixture`. |
| `Engine/src/audio/devices/effects/mod.rs` | `mod pitch_shifter;` and `pub use pitch_shifter::PitchShifterDevice;` |
| `Engine/src/audio/devices/factory.rs` | Add `"sonara.builtin.pitch_shifter"` to `EFFECT_IDS` and to `create_effect`'s match, and import `PitchShifterDevice`. |
| `Godot/tests/fixtures/simple_view/pitch_shifter_params.json` | **New.** Dumped by `dump_pitch_shifter_view_fixture`. |
| `Godot/tests/test_pitch_shifter_view.gd` | **New**, modelled on `test_phaser_view.gd`: every parameter lands in the Simple View, Pitch is whole-number, and Sync is a dropdown. |
| `docs/subsystems/osc-protocol.md` | A "Pitch Shifter (`sonara.builtin.pitch_shifter`)" entry under Built-In Devices with the parameter IDs. |
| `AGENTS.md` | Add the spec 045 `pitch_shifter` to the built-in devices list. |
| `docs/subsystems/engine-architecture.md` | Add `pitch_shifter` to the `effects/` listing. |
| `CONTEXT.md` | Glossary: **Grain** (Pitch Shifter): one window of the read tap; the Grain rate in Hz is how often each tap restarts. |

## Migration and compatibility

Nothing existing changes. Older projects don't contain the device. A project saved with it opens
in an older engine with the device missing, the same as for every other new built-in.

## Test plan

**Unit tests** go in `pitch_shifter.rs` `mod tests`. Run them with
`cargo test pitch_shifter -- --nocapture` from `Engine/`.

| Test | REQ |
|---|---|
| `pitch_semitones_hit_the_target_frequency`: 440 Hz sine at n ∈ {−24, −12, −7, +7, +12, +24}; the peak is within ±10 cents (`spectrum_db` with parabolic peak interpolation, or `instantaneous_freq` over the steady part) | 003 |
| `fine_cents_offset_the_pitch` | 004 |
| `grain_rate_sets_the_crossfade_period`: AM period of the shifted sine ≈ 1/Grain ±5 %; sidebands at 100 Hz vs 5 Hz | 005 |
| `synced_grain_follows_tempo`: 120 BPM, 1/16 → 125 ms; Sync Off → Hz again; a tempo change produces no step larger than a grain boundary | 005a |
| `zero_shift_is_a_constant_delay`: wet == input delayed `D_MIN` (within 1e-6) at Grain 1, 20 and 100 Hz | 006 |
| `jitter_zero_is_periodic_and_jitter_is_seeded`: periodic at 0; the period varies at 100 %; two renders are bit-identical | 007 |
| `feedback_cascades_and_stays_bounded`: echo pitches rise by an octave at +12; 60 s of full-scale noise at 95 % stays under a fixed bound and is finite | 008 |
| `spread_detunes_left_up_right_down` and mono-in gives L == R at Spread 0 | 009 |
| `pitch_automation_glides_without_clicks`: −12 → +12 over one bar, max sample step bounded (same `max_step` idea as `chorus.rs`) | 012 |
| `non_finite_input_never_leaks`: ±Inf/NaN frames, then a sine → finite output, and the sine is shifted | 013 |
| `prepare_resizes_for_sample_rate`: the REQ-003 test at 44.1/48/96 kHz | 014 |
| `sleep_waits_out_the_feedback_tail` (the Delay test pattern) | 015 |
| `cpu_pitch_shifter` (ignored): `cargo test --release cpu_pitch_shifter -- --ignored --nocapture`, compared with `cpu_chorus` | 016 |

**Conformance:** `cargo test every_builtin_effect_conforms` covers REQ-001, 010 (Mix 0 %), 013
(finite at every rate), block-size independence, reset, tail, modulation offsets and wrapping.
Being in `EFFECT_IDS` puts it there.

**Godot:** `Godot/tests/run_all.sh pitch_shifter` runs `test_pitch_shifter_view.gd` (REQ-018,
layout).

**Live** (needs the engine + Godot):
- REQ-001/018: add Pitch Shifter from the browser and adjust every knob. Check that values show in
  st, cents, Hz and %.
- REQ-002: put it in a channel chain, in the Delay's FB FX at +12 (repeats climb), and in a
  Multiband FX band.
- REQ-011: the latency plan for the channel is unchanged (`latency_frames` = 0).
- REQ-015: at Feedback 80 %, the device sleeps after the tail. Check the sleep status in the device
  header or the logs.
- REQ-017: save and reopen the project.
- **Listening:** `TAPS` = 2 vs 4 on a sustained pad with Jitter 0 and 60 %. This decides the
  constant.

## Risks

| Risk | Mitigation |
|---|---|
| Buffers of 1 MB per channel at 48 kHz (4 MB at 192 kHz) per instance | Allocated once in `prepare` on the command thread. Same order as the Delay's 5 s lines. |
| At Pitch 0, Feedback is a 2-sample comb (the loop delay is just `D_MIN`), which sounds like a bright ring rather than echoes | Documented as a known character. The 8 kHz high cut tames it. If it bothers us live, add a fixed minimum loop delay (a follow-up, not v1). |
| Two taps sound buzzy or comb-like on pads | Jitter exists for this. `TAPS` is a constant decided by the listening test. |
| Jitter rate scaling can make a pitch-up tap reach `D_MIN` before its window closes | `T_max` uses the slowest possible cycle rate, so the start delay always covers it. The clamp keeps it safe either way. |
| Synced divisions longer than 1 s are clamped to 1 Hz | Documented in the parameter doc. The division dropdown still offers them, which matches the shared `SYNC_CHOICES`. |
| Peak-frequency tests are noisy for granular output | Measure the strongest bin with parabolic interpolation over a long window (≥ 1 s) and ignore the first grain. |

## Open questions

None. The gate decisions are folded in: ±24 st, Grain Sync, a fixed feedback high cut, the
generic panel, no reserved Mode parameter, and an internal `TAPS` constant.
