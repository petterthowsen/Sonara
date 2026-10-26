# 056 — More drums: Tom, Cowbell, Rimshot, Shaker, Cymbal

Five new built-in drum instruments on the spec 013 foundation (`DrumHost` + `DrumVoice`), plus a
bigger Drum Machine "Synth Kit". Single-file plan: no separate requirements/design docs.

Read first: `docs/specs/013-drum-synths/plan.md` (decisions, parameter conventions) and the
existing voices, especially `kick.rs` (pitch sweep, keytrack, click/noise layers) and `hat.rs`
(pulse oscillators, filters, velocity brightness). New voices copy their structure: module doc
comment, ID constants grouped in tens by module, `const` spec arrays flattened with
`GLOBAL_SPECS`, a `ParamValues` table, `sync_params()`, and everything preallocated in `new()`.

## Ground rules (apply to every phase)

- Audio-thread contract: `trigger()`, `render()`, `release()` never allocate, lock or log. Any
  buffer (allpass delay lines) is sized in `new()` for the **maximum** supported sample rate
  (192 kHz), so `set_sample_rate()` never allocates.
- `render()` adds into `out` (never clears it) and must work for any block length (chunk like
  `hat.rs` does if it uses internal scratch).
- Hits are deterministic: reset noise generators to a fixed seed in `trigger()` (as `hat.rs` does
  with `NOISE_SEED`). Per-hit randomness comes only from the `rng` argument (Humanize).
- Humanize: ±10 cents of pitch and ±5 % of decay at full amount. Copy the hat's lines.
- Velocity: handle it exactly as `kick.rs`/`hat.rs` do (amplitude via the host; brightness
  scaled by `params.velocity_sens`, so at sensitivity 0 a hit is velocity-independent).
- Every envelope must reach true idle so `is_active()` goes false and the host can sleep. Use
  `OneShotEnvelope` (ends at −60 dB); filters ringing below −90 dBFS is fine (the host's
  100 ms quiet window handles it).
- Parameter IDs: 0–9 the drum's own module, then tens per module, 90–92 the shared globals.
  `module` strings are the section titles in the simple view, so pick them deliberately.
- Names matter to Godot's `DrumStrategy` role keywords (`Godot/devices/simple_view/strategies/
  DrumStrategy.gd`): "Tune", "Decay", "Tone", "Drive" etc. land in the right groups. New words
  are listed per phase below.
- Build and test with `CARGO_BUILD_JOBS=2` (the laptop has crashed on parallel heavy builds).
  Run tests from `Engine/`: `cargo test drum`, `cargo test <voice>`. Godot:
  `Godot/tests/run_all.sh drum layout`.
- Add a `CHANGELOG.md` line under `## [Unreleased]` per new drum, in the same change.
- MIDI notes below are GM numbers (C3 = 60 convention, so 36 = C1).

## Phase 0: shared groundwork

### 0.1 Fix the Synth Kit hat decay bug
`Godot/data/DrumKit.gd` has `const HAT_DECAY := 11` ("parameters.rs ID 11"), but the Hat's
Decay is **ID 1**; ID 11 is Metal. Today the kit writes 0.06 / 0.6 into Metal (0–100 %), and
both hats keep the default 0.06 s decay. `Godot/tests/test_drum_kit.gd` registers a fake Hat
with Decay as ID 11, so it passes anyway.

Replace the single `"decay"` field with a general per-pad `"params"` dictionary of
**real** values keyed by parameter ID, and apply them all with `_set_real_param`:

```gdscript
{"id": "sonara.builtin.hat", "note": 42, "name": "Closed Hat", "choke": ["Open Hat"],
	"params": {HAT_DECAY: 0.06}},
```

with `const HAT_DECAY := 1`. Fix the test's fake device to use ID 1 and add an assertion that
the open hat's Decay differs from the closed hat's (it already compares them; make sure it now
reads ID 1). Add a CHANGELOG line ("Synth Kit open hat now rings").

### 0.2 Conformance: allow long tails
`check_sleeps_and_wakes` in `Engine/src/audio/devices/instruments/drum_conformance.rs` renders
a hit for 0.5 s then expects sleep within 1 s. The Cymbal's default decay (1.8 s) fails that.
Add `const MAX_TAIL_SECONDS: f32 = 4.0;` and render the hit for that long before the 1 s quiet
section. Every drum's **default** settings must be silent within 4 s (document this on the
constant). Check `check_retrigger_has_no_click` and the others still make sense for long
voices; they should.

### 0.3 Share the 808 metal constants
The Cymbal reuses the Hat's six pulse oscillator ratios and phase offsets. Make `RATIOS` and
`PHASE_OFFSETS` in `hat.rs` `pub(super)` (no move, no behavior change). Hat tests must still
pass unchanged.

## Phase 1: Tom (`sonara.builtin.tom`, name "Tom")

File `drums/tom.rs`, voice `TomVoice`. A tuned membrane: a swept sine fundamental, a second
membrane mode, and a short skin layer. One device covers low/mid/high toms (and congas/bongos
at higher Tune with short Decay).

### Parameters

| ID | Name | Module | Unit | Range | Default |
|---|---|---|---|---|---|
| 0 | Tune | Tom | Hz | log 40–500 | 110 |
| 1 | Decay | Tom | s | log 0.05–2.0 | 0.4 |
| 2 | Drive | Tom | dB | linear 0–24 | 0 |
| 3 | Keytrack | Tom | | Bool | off |
| 10 | Sweep | Sweep | st | linear 0–24 | 5 |
| 11 | Sweep Time | Sweep | s | log 0.01–0.5 | 0.08 |
| 20 | Overtone | Membrane | % | linear 0–100 | 30 |
| 21 | Overtone Ratio | Membrane | × | linear 1.2–2.5 | 1.593 |
| 30 | Click | Skin | % | linear 0–100 | 20 |
| 31 | Noise | Skin | % | linear 0–100 | 15 |
| 32 | Noise Tone | Skin | Hz | log 500–12000 | 3000 |

### DSP
- **Fundamental**: `SweepOsc` (sine), frequency `sweep_hz(tune, sweep_st, pitch_env)` where
  `pitch_env` is an exponential 1 → 0 over Sweep Time (same as the kick's Punch). Amplitude:
  `OneShotEnvelope` with Decay.
- **Overtone**: a second `SweepOsc` at `freq × Overtone Ratio` following the same sweep, its own
  envelope with decay `0.5 × Decay`, level = Overtone. 1.593 is the ideal circular membrane's
  (1,1)/(0,1) ratio.
- **Skin**: `ClickLayer` (from `layers.rs`) at Click level, with its tone at
  `clamp(tune × 8, 1 kHz, 8 kHz)`; plus white noise → `Svf` band-pass at Noise Tone, its own
  envelope with decay `min(0.25 × Decay, 0.08)`.
- Sum body + overtone → `DriveStage` (Drive) → add skin → `DcBlocker` (as the kick).
- Velocity: with sensitivity, softer hits get less Sweep (`× (1 - 0.5·sens·soft)`) and a darker
  Noise Tone (−1 octave at velocity 0, full sens).
- **Keytrack**: copy the kick's implementation, with `REFERENCE_NOTE: u8 = 45` (GM Low Tom), so
  Tune is always the pitch heard on note 45. No Gate/Glide.

### Tests (in `tom.rs` `mod tests`, use `dsp/test_util.rs` helpers like `hat.rs` does)
- Spectral peak of a hit (after the sweep, e.g. frames 0.1–0.3 s) within 3 % of Tune at
  100, 200 and 400 Hz.
- With Overtone 100 %, a peak near Tune × 1.593; with Overtone 0 %, none above the noise floor.
- Keytrack on: note 57 sounds an octave above note 45.
- Sweep 0 st: the pitch at 5 ms equals the pitch at 150 ms (within 2 %).
- Identical hits with a fixed seed are sample-identical.

### Register
Add `pub mod tom;` in `drums/mod.rs`, `"sonara.builtin.tom"` in `DRUM_IDS` and a `create_drum`
arm in `devices/factory.rs`. Conformance now covers it automatically.

## Phase 2: Cowbell and Rimshot

### Cowbell (`sonara.builtin.cowbell`, name "Cowbell", file `drums/cowbell.rs`)
The 808 recipe: two square waves, a band-pass, and a two-stage envelope (sharp strike plus a
longer tail).

| ID | Name | Module | Unit | Range | Default |
|---|---|---|---|---|---|
| 0 | Tune | Cowbell | Hz | log 200–1200 | 540 |
| 1 | Decay | Cowbell | s | log 0.05–1.5 | 0.3 |
| 2 | Spread | Cowbell | × | linear 1.2–1.8 | 1.48 |
| 10 | Tone | Tone | Hz | log 500–8000 | 2000 |
| 11 | Ring | Tone | % | linear 0–100 | 40 |
| 12 | Strike | Tone | % | linear 0–100 | 60 |
| 13 | Drive | Tone | dB | linear 0–24 | 0 |

- Two band-limited pulse `Oscillator`s (PW 0.5, as in `hat.rs`) at Tune and Tune × Spread,
  summed at equal level → `Svf` band-pass at Tone, resonance from Ring (`resonance_to_k`, keep
  the hat's gain compensation) → `DriveStage`.
- Envelope = `Strike × fast + (1 − Strike) × slow`: two `OneShotEnvelope`s, fast decay 0.015 s,
  slow decay = Decay. Both triggered together.
- Velocity brightness: Tone lowered up to 1 octave on soft hits (scaled by sens), like the hat.
- Tests: spectral peaks at Tune and Tune × Spread (±3 %); Strike 100 % has ≥ 20 dB less energy
  at 200 ms than Strike 0 %; identical hits are sample-identical.

### Rimshot (`sonara.builtin.rimshot`, name "Rimshot", file `drums/rimshot.rs`)
The 808 approach: an impulse rings two tuned resonators, then a high-pass and hard drive give
the snap. With high Ring and Tone it also does claves.

| ID | Name | Module | Unit | Range | Default |
|---|---|---|---|---|---|
| 0 | Tune | Rimshot | Hz | log 200–2000 | 455 |
| 1 | Decay | Rimshot | s | log 0.005–0.3 | 0.04 |
| 2 | Drive | Rimshot | dB | linear 0–24 | 9 |
| 10 | Ring | Tone | % | linear 0–100 | 70 |
| 11 | Tone | Tone | Hz | log 50–3000 | 300 |
| 12 | Overtone | Tone | % | linear 0–100 | 50 |

- Excitation: `ClickLayer` (Tick type), triggered on each hit.
- Two `Svf` band-passes (high resonance from Ring) in parallel: one at Tune, one at
  Tune × 3.66 (455 → 1667 Hz, the 808 pair), the second at Overtone level.
- Sum → `Svf` high-pass at Tone → `OneShotEnvelope` (Decay) → `DriveStage` (Drive).
- Tests: peak at Tune (±3 %), peak at Tune × 3.66 present only when Overtone > 0; output silent
  (below −90 dBFS) by Decay + 50 ms at Ring 70 %; identical hits are sample-identical.

Register both as in Phase 1.

## Phase 3: Shaker (`sonara.builtin.shaker`, name "Shaker", file `drums/shaker.rs`)

Maracas or shaker: shaped, filtered noise with an optional grainy "beads" texture. No pitch, so
there is no Tune.

| ID | Name | Module | Unit | Range | Default |
|---|---|---|---|---|---|
| 1 | Decay | Shaker | s | log 0.01–0.5 | 0.06 |
| 2 | Attack | Shaker | s | log 0.001–0.1 | 0.008 |
| 10 | Tone | Tone | Hz | log 1000–14000 | 6000 |
| 11 | Ring | Tone | % | linear 0–100 | 20 |
| 12 | Grain | Tone | % | linear 0–100 | 40 |

(ID 0 is deliberately unused, so Decay keeps ID 1 like every other drum.)

- Source: `(1 − Grain) × white + Grain × beads`, where beads is a sparse impulse train: each
  sample, with probability `p = 0.02 + 0.1 × env` (denser at the peak), output `±rng` scaled ×4,
  else 0. Use the voice's own `Rng`, reseeded to a fixed seed in `trigger()`.
- → `Svf` band-pass at Tone (Ring = resonance) → `Svf` 12 dB high-pass fixed at 800 Hz.
- Envelope: `OneShotEnvelope` with Attack (linear ramp) then Decay.
- Velocity: brightness on Tone as the hat.
- Tests: > 90 % of the energy is above 2 kHz at the default Tone; the envelope peak lands within
  1 ms of Attack at Attack 20 ms and 50 ms; Grain 0 vs 100 % have different crest factor (beads
  peakier); identical hits are sample-identical.

## Phase 4: Cymbal (`sonara.builtin.cymbal`, name "Cymbal", file `drums/cymbal.rs`)

The hard one. Scope: a good synthetic **crash** by default, with splash/ride/china reachable by
parameters. Orchestral cymbals (swells, clashed plates) are out of scope (use the SFZ sampler).
Expect a listening/tuning pass with the user after the tests pass; get the structure right and
the defaults close, don't over-tune blind.

### Parameters

| ID | Name | Module | Unit | Range | Default |
|---|---|---|---|---|---|
| 0 | Tune | Cymbal | st | linear −24–24 | 0 |
| 1 | Decay | Cymbal | s | log 0.2–8.0 | 1.8 |
| 2 | Grab | Cymbal | | Bool | off |
| 10 | Tone | Tone | Hz | log 2000–14000 | 7000 |
| 11 | Body | Tone | % | linear 0–100 | 40 |
| 12 | Trash | Tone | % | linear 0–100 | 10 |
| 13 | Diffusion | Tone | % | linear 0–100 | 50 |
| 20 | Stick | Stick | % | linear 0–100 | 30 |
| 21 | Bloom | Stick | s | log 0.001–0.2 | 0.02 |

### DSP
1. **Metal source**: six band-limited pulse `Oscillator`s at the hat's `RATIOS` × base (same
   base frequency as the hat, transposed by Tune semitones), phases from `PHASE_OFFSETS`, summed
   → `metal`.
2. **Trash**: ring-modulate oscillator pairs `o0·o3 + o1·o4 + o2·o5` (normalized by 1/3) → `ring`.
   Source = `(1 − Trash) × metal + Trash × ring`, plus white noise at a fixed 0.15 level for
   density.
3. **Three bands with their own envelopes** (the 808 cymbal trick: the low end dies first, the
   wash rings):
   - Low: `Svf` band-pass at Tone / 4, envelope decay `0.25 × Decay`, level `Body`.
   - Mid: `Svf` band-pass at Tone / 2, envelope decay `0.6 × Decay`, level `0.5 + 0.5 × Body`.
   - High: `Svf` 12 dB high-pass at Tone, envelope with **attack = Bloom** and decay = Decay,
     level 1. Bloom makes the wash swell in just after the strike.
   All band envelopes use `OneShotEnvelope` with a slightly held curve (`set_curve(0.3)`).
4. **Stick**: `ClickLayer` (Noise type) at Stick level, tone at `clamp(Tone × 1.5, …)`, its own
   short decay (0.01 s). Ride = high Stick.
5. **Diffusion**: four series Schroeder allpasses (delays 1.3, 2.9, 4.7, 7.1 ms; gain
   `0.4 + 0.3 × Diffusion`), mixed `dry·(1 − D) + wet·D`. Smears the oscillators into a wash.
   Check `dsp/delay_line.rs` first; if it doesn't fit, use fixed-size buffers sized for 192 kHz
   in `new()`. Reset the buffers to zero in `trigger()`? **No**: on retrigger the host already
   crossfades between two voice slots, so each slot's allpasses start from their own state; clear
   them in `reset()` only.
6. **Grab**: when on, `release()` (note-off) moves all band envelopes into a 30 ms release (use
   gated envelopes or force a short decay). Off: note-off is ignored like other one-shots.
7. Velocity: softer hits lower Tone up to 1 octave (scaled by sens) and reduce Stick.
8. `DcBlocker` on the output (ring-mod and drive can introduce DC).

### Tests
- Defaults fall silent (below −90 dBFS) within `MAX_TAIL_SECONDS` (4 s).
- Band timing: the energy below Tone/2 in 0.6–0.8 s is at least 12 dB lower, relative to the
  0–0.1 s window, than the energy above Tone over the same windows (the low end dies first).
- Bloom 0.1 s: the high band's envelope peak is ≥ 80 ms after the hit; Bloom 0.001: < 10 ms.
- Grab on: output is below −60 dBFS 50 ms after note-off; Grab off: note-off changes nothing
  (sample-identical to no note-off).
- Trash 0 vs 100 %: spectra differ (ring products present).
- An aliasing check like the hat's `pulse_oscillators_do_not_alias_at_double_tune` at Tune +24.
- Identical hits are sample-identical.

### Variations (put in the module doc comment, and used by the kit in Phase 5)
- Crash: defaults.
- Splash: Tune +7, Decay 0.6, Body 20.
- Ride: Decay 4.0, Tone 9000, Stick 70, Diffusion 25, Bloom 0.001.
- China: Trash 70, Tone 5000, Decay 1.5.

## Phase 5: Godot

### Classification and simple view
- `Godot/devices/simple_view/DeviceKind.gd` `DRUM_NAME_KEYWORDS`: add `"tom*"`, `"cowbell*"`,
  `"rimshot*"`, `"shaker*"`, `"maraca*"`, `"cymbal*"`. Check `ParamClassifier.matches_keyword`
  token matching so these don't hit unrelated device names (e.g. "Tomato" plugins are
  acceptable collateral; substrings inside other words must not match).
- `DrumStrategy.gd` `role_keywords()`: add `"grab"` to `mode`; `"bloom"` and `"attack"` to
  `decay`; `"overtone"` already in `tone`; add `"spread"`/`"trash"`/`"diffusion"`/`"grain"`
  to `character`; `"strike"` and `"stick"` to `level`. Update the header comment's module list.
  `decorate_control` marks Tune in Hz as a note name. That's right for Tom, Cowbell and
  Rimshot; the Cymbal's Tune is in semitones and keeps its unit (already handled).
- `Godot/tests/test_simple_layout_generator.gd`: add a case that "Tom" and "Cymbal" infer
  `DeviceKind.DRUM` and that the Cymbal's Grab lands in the Mode group.

### Synth Kit
Extend `SYNTH_KIT` in `Godot/data/DrumKit.gd` (using the Phase 0 `"params"` field; IDs below
are the engine IDs from this plan, as named constants at the top of the file):

| Note | Name | Device | Params |
|---|---|---|---|
| 36 | Kick | kick | |
| 37 | Rimshot | rimshot | |
| 38 | Snare | snare | |
| 39 | Clap | clap | |
| 42 | Closed Hat | hat | Decay 0.06, chokes Open Hat |
| 46 | Open Hat | hat | Decay 0.6, chokes Closed Hat |
| 45 | Low Tom | tom | Tune 90 |
| 48 | Mid Tom | tom | Tune 130 |
| 50 | High Tom | tom | Tune 180 |
| 49 | Crash | cymbal | defaults |
| 51 | Ride | cymbal | Ride variation |
| 56 | Cowbell | cowbell | |
| 70 | Shaker | shaker | |

Keep the order of the table (pads are added in array order). Update the "Load Synth Kit"
tooltip in `Godot/devices/DeviceContextMenu.gd`, and `test_drum_kit.gd` (pad count, register
the new fake devices with the parameters it asserts on, check one tom's Tune and the ride's
Decay).

## Phase 6: Docs
- `AGENTS.md` "Channels and devices": add the new drums to the spec 013 drum list
  (`kick`, `snare`, `hat`, `clap`, plus spec 056 `tom`, `cowbell`, `rimshot`, `shaker`,
  `cymbal`).
- `docs/subsystems/godot-device-views.md`, if it lists drums.
- `CONTEXT.md`: add "Grab" (cymbal choke on note-off) only if the glossary already covers drum
  terms like Choke.
- `CHANGELOG.md`: one line per drum plus the kit (if not already added per phase).

## Done when
- `cargo test` passes (conformance covers all nine drums), `cargo fmt` clean.
- `Godot/tests/run_all.sh` passes.
- Manual: load the Synth Kit in a Drum Machine, play every pad; open hat rings, closed hat
  chokes it; Crash rings about 2 s; nothing clicks on fast retriggers. Report to the user for
  the cymbal listening pass.
