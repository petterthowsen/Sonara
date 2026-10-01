//! Conformance checks every built-in drum in `factory::DRUM_IDS` must pass (spec 013, Phase 0).
//!
//! Until the first drum device lands, the checks run against a throwaway [`TestDrum`]: a sine
//! with a decay. A real drum gets the same checks by being added to `DRUM_IDS`, so this file
//! proves the whole `DrumHost` path (`make` builds a fresh device per check, like the effect
//! conformance test, so checks don't leak state).

use super::param_table::{flatten, linear, slot_table, spec, ParamSpec, ParamTable, ParamValues};
use super::{
    create_drum, enum_to_norm, norm_to_enum, real_to_norm, AudioDevice, DrumHost, DrumParams,
    DrumVoice, ParamId, ParamInfo, ParamType, DRUM_IDS, GLOBAL_SPECS,
};
use crate::audio::dsp::test_util::{peak, time_to_db};
use crate::audio::dsp::{OneShotEnvelope, Rng, SweepOsc, SweepShape};

const SR: f32 = 48_000.0;
const MAX_FRAMES: usize = 4_096;

/// Builds a fresh drum (a real one or the throwaway).
type Make = dyn Fn() -> Box<dyn AudioDevice>;

/// Own parameters of the throwaway drum (globals come from [`GLOBAL_SPECS`]).
const TEST_OWN: [ParamSpec; 2] = [
    spec(0, "Tone", "Body", "Hz", linear(50.0, 1000.0), 200.0),
    spec(1, "Decay", "Body", "ms", linear(20.0, 800.0), 200.0),
];
const TEST_SPECS: [ParamSpec; 5] = flatten(&[&TEST_OWN, &GLOBAL_SPECS]);
const TEST_SLOTS: [u8; 93] = slot_table(&TEST_SPECS);
static TEST_TABLE: ParamTable = ParamTable::new(&TEST_SPECS, &TEST_SLOTS);

/// A trivial voice: a sine whose amplitude decays after each hit.
struct TestDrum {
    osc: SweepOsc,
    env: OneShotEnvelope,
    values: ParamValues<5>,
    params: DrumParams,
    sample_rate: f32,
    freq: f32,
    /// `freq` with this hit's humanize jitter applied.
    humanized_freq: f32,
    decay_s: f32,
    level: f32,
}

impl TestDrum {
    fn sync(&mut self) {
        self.freq = self.values.real(0).unwrap_or(200.0);
        self.decay_s = self.values.real(1).unwrap_or(200.0) / 1000.0;
        self.env.set_decay(self.decay_s);
    }
}

impl DrumVoice for TestDrum {
    fn new(sample_rate: f32) -> Self {
        let mut env = OneShotEnvelope::new(sample_rate);
        env.set_attack(0.001);
        env.set_decay(0.2);
        let mut drum = Self {
            osc: SweepOsc::new(),
            env,
            values: ParamValues::new(&TEST_TABLE),
            params: DrumParams::default(),
            sample_rate,
            freq: 200.0,
            humanized_freq: 200.0,
            decay_s: 0.2,
            level: 0.0,
        };
        drum.sync();
        drum
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        self.env.set_sample_rate(sample_rate);
    }

    fn specs() -> &'static [ParamSpec] {
        &TEST_SPECS
    }

    fn set_parameter(&mut self, id: ParamId, norm: f32) {
        if self.values.set(id, norm).is_some() {
            self.sync();
        }
    }

    fn get_parameter(&self, id: ParamId) -> Option<f32> {
        self.values.get(id)
    }

    fn set_params(&mut self, params: &DrumParams) {
        self.params = *params;
    }

    fn trigger(&mut self, _note: u8, velocity: f32, rng: &mut Rng) {
        let humanize = self.params.humanize;
        let cents = humanize * 10.0 * rng.bipolar();
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();
        self.humanized_freq = self.freq * 2f32.powf(cents / 1200.0);
        self.env.set_decay((self.decay_s * decay_scale).max(1.0e-4));
        self.level = 0.5 + 0.5 * velocity.max(0.0);
        self.osc.set_start_phase_deg(0.0);
        self.osc.reset();
        self.env.trigger();
    }

    fn render(&mut self, out: &mut [f32]) {
        for sample in out.iter_mut() {
            let env = self.env.process_sample();
            *sample += self
                .osc
                .next(SweepShape::Sine, self.humanized_freq, self.sample_rate)
                * env
                * self.level;
        }
    }

    fn release(&mut self) {
        self.env.gate_off();
    }

    fn is_active(&self) -> bool {
        self.env.is_active()
    }

    fn reset(&mut self) {
        self.env.reset();
        self.osc.reset();
        self.level = 0.0;
    }

    fn device_id() -> &'static str {
        "test.drum"
    }

    fn device_name() -> &'static str {
        "Test Drum"
    }
}

fn make_test_drum() -> Box<dyn AudioDevice> {
    let mut host = DrumHost::<TestDrum>::new(SR, MAX_FRAMES);
    host.prepare(SR, MAX_FRAMES);
    Box::new(host)
}

/// The drums the checks run over: every real drum plus the throwaway one.
fn cases() -> Vec<(&'static str, Box<Make>)> {
    let mut cases: Vec<(&'static str, Box<Make>)> = DRUM_IDS
        .iter()
        .map(|&id| {
            (
                id,
                Box::new(move || create_drum(id, SR, MAX_FRAMES).expect("drum id")) as Box<Make>,
            )
        })
        .collect();
    cases.push(("test.drum", Box::new(make_test_drum)));
    cases
}

/// Render `total` stereo frames in blocks of `block`, sending each `(frame, note, velocity)`
/// hit at its exact absolute frame so different block sizes hit the same sample.
fn render_blocks(
    device: &mut dyn AudioDevice,
    total: usize,
    block: usize,
    hits: &[(usize, u8, u8)],
) -> Vec<f32> {
    let mut out = vec![0.0; total * 2];
    let mut pos = 0;
    while pos < total {
        let frames = block.min(total - pos);
        for &(at, note, velocity) in hits {
            if at >= pos && at < pos + frames {
                device.send_midi_event(note, velocity, true, at - pos);
            }
        }
        device.process_block(&[], &mut out[pos * 2..(pos + frames) * 2], frames);
        pos += frames;
    }
    out
}

/// The normalized value a parameter should read back after being set to `norm`.
fn canonical(info: &ParamInfo, norm: f32) -> f32 {
    match info.param_type {
        ParamType::Float => norm.clamp(0.0, 1.0),
        ParamType::Enum => {
            let count = info.enum_values.len();
            enum_to_norm(norm_to_enum(norm, count), count)
        }
        ParamType::Bool => {
            if norm >= 0.5 {
                1.0
            } else {
                0.0
            }
        }
    }
}

/// The normalized value of a parameter's advertised (real) default.
fn default_norm(info: &ParamInfo) -> f32 {
    match info.param_type {
        ParamType::Float => real_to_norm(
            info.default,
            info.min,
            info.max,
            info.is_logarithmic,
            info.skew,
        ),
        ParamType::Enum => enum_to_norm(info.default.max(0.0) as usize, info.enum_values.len()),
        ParamType::Bool => canonical(info, info.default),
    }
}

fn check_parameters_round_trip(make: &Make) -> Result<(), String> {
    let mut device = make();
    for info in device.parameters() {
        for norm in [0.0, 0.25, 0.5, 0.73, 1.0] {
            device.set_parameter(info.id, norm);
            let got = device
                .get_parameter(info.id)
                .ok_or_else(|| format!("'{}' has no value", info.name))?;
            let expected = canonical(&info, norm);
            if (got - expected).abs() > 1e-4 {
                return Err(format!(
                    "'{}' set to {norm} reads back {got} (expected {expected})",
                    info.name
                ));
            }
        }
    }
    Ok(())
}

fn check_defaults_match_metadata(make: &Make) -> Result<(), String> {
    let device = make();
    for info in device.parameters() {
        let got = device.get_parameter(info.id).unwrap_or(f32::NAN);
        let expected = default_norm(&info);
        if !((got - expected).abs() <= 1e-4) {
            return Err(format!(
                "'{}' starts at {got}, but its advertised default {} is {expected} normalized",
                info.name, info.default
            ));
        }
    }
    Ok(())
}

fn check_finite_at_every_rate(make: &Make) -> Result<(), String> {
    for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
        let mut device = make();
        device.prepare(rate, MAX_FRAMES);
        let out = render_blocks(device.as_mut(), rate as usize / 2, 512, &[(0, 60, 120)]);
        if let Some(bad) = out.iter().find(|x| !x.is_finite()) {
            return Err(format!("{bad} in the output at {rate} Hz"));
        }
        if peak(&out) <= 0.0 {
            return Err(format!("no output from a hit at {rate} Hz"));
        }
    }
    Ok(())
}

fn check_block_size_invariance(make: &Make) -> Result<(), String> {
    let hits = [(100usize, 60u8, 100u8)];
    let total = SR as usize;
    let reference = render_blocks(make().as_mut(), total, 512, &hits);
    for block in [1, 37, 256, 4_096] {
        let odd = render_blocks(make().as_mut(), total, block, &hits);
        let worst = reference
            .iter()
            .zip(&odd)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        if worst > 1e-4 {
            return Err(format!(
                "{block}-frame blocks differ from 512-frame blocks by up to {worst}"
            ));
        }
    }
    Ok(())
}

fn check_no_midi_is_exact_silence(make: &Make) -> Result<(), String> {
    let out = render_blocks(make().as_mut(), SR as usize / 4, 256, &[]);
    if let Some(&bad) = out.iter().find(|&&x| x != 0.0) {
        return Err(format!("{bad} with no MIDI (expected exact silence)"));
    }
    Ok(())
}

fn check_sleeps_and_wakes(make: &Make) -> Result<(), String> {
    let mut device = make();
    // A hit, then let the tail die.
    render_blocks(device.as_mut(), SR as usize / 2, 512, &[(0, 60, 120)]);
    let quiet = render_blocks(device.as_mut(), SR as usize, 512, &[]);
    if !device.is_sleeping() {
        return Err("did not sleep after the tail".into());
    }
    if let Some(&bad) = quiet.iter().find(|&&x| x != 0.0) {
        return Err(format!("{bad} while asleep (expected exact 0)"));
    }
    // A new note wakes it.
    device.send_midi_event(60, 120, true, 0);
    if device.is_sleeping() {
        return Err("a hit did not wake the device".into());
    }
    let awake = render_blocks(device.as_mut(), SR as usize / 4, 512, &[]);
    if peak(&awake) <= 0.0 {
        return Err("silent after waking".into());
    }
    Ok(())
}

/// The largest sample-to-sample step of the left channel.
fn max_step(interleaved: &[f32]) -> f32 {
    let left: Vec<f32> = interleaved.iter().step_by(2).copied().collect();
    left.windows(2)
        .map(|w| (w[1] - w[0]).abs())
        .fold(0.0f32, f32::max)
}

fn check_retrigger_has_no_click(make: &Make) -> Result<(), String> {
    let total = SR as usize;
    let single = render_blocks(make().as_mut(), total, 512, &[(0, 60, 127)]);
    let peak_frame = single
        .iter()
        .step_by(2)
        .enumerate()
        .max_by(|a, b| a.1.abs().total_cmp(&b.1.abs()))
        .map(|(i, _)| i)
        .unwrap_or(0);

    let retriggered = render_blocks(
        make().as_mut(),
        total,
        512,
        &[(0, 60, 127), (peak_frame, 60, 127)],
    );

    let own = max_step(&single);
    let both = max_step(&retriggered);
    // The 3 ms crossfade sums two voices for its length, and a noise drum steps by its own noise,
    // so a retriggered signal can step by up to both voices' own largest steps. A hard voice reset
    // (the click this guards against) instead steps by the voice's full amplitude, far above this.
    if both > own * 2.0 * 1.05 + 1e-4 {
        return Err(format!(
            "retrigger steps by {both}, more than twice the voice's own largest step {own}"
        ));
    }
    Ok(())
}

fn check_decay_time_is_measurable(make: &Make) -> Result<(), String> {
    // The shared measurement helper. Only meaningful for the throwaway drum: a real drum's decay
    // is its own parameter, so it must not be pinned to 200 ms.
    let out = render_blocks(make().as_mut(), SR as usize, 512, &[(0, 60, 127)]);
    let left: Vec<f32> = out.iter().step_by(2).copied().collect();
    let t60 = time_to_db(&left, -60.0, SR);
    if !(0.15..=0.35).contains(&t60) {
        return Err(format!("−60 dB at {t60} s, expected about 0.2 s"));
    }
    Ok(())
}

const CHECKS: &[(&str, fn(&Make) -> Result<(), String>)] = &[
    ("parameters round-trip", check_parameters_round_trip),
    ("defaults match metadata", check_defaults_match_metadata),
    ("finite at every rate", check_finite_at_every_rate),
    ("block-size independent", check_block_size_invariance),
    ("no MIDI is exact silence", check_no_midi_is_exact_silence),
    ("sleeps and wakes", check_sleeps_and_wakes),
    ("retrigger has no click", check_retrigger_has_no_click),
];

/// Every failed check for `make`, as "check: reason" lines.
fn failures(id: &str, make: &Make) -> Vec<String> {
    CHECKS
        .iter()
        .filter_map(|(name, check)| {
            check(make)
                .err()
                .map(|error| format!("{id} — {name}: {error}"))
        })
        .collect()
}

#[test]
fn every_builtin_drum_conforms() {
    let failed: Vec<String> = cases()
        .iter()
        .flat_map(|(id, make)| failures(id, make.as_ref()))
        .collect();
    assert!(failed.is_empty(), "\n{}", failed.join("\n"));
}

/// The throwaway drum must always be one of the cases, so the checks never pass vacuously.
#[test]
fn the_throwaway_drum_is_in_the_case_list() {
    assert!(cases().iter().any(|(id, _)| *id == "test.drum"));
}

/// The `time_to_db` helper, on the throwaway drum's known 200 ms decay. Real drums have their own
/// decay settings, so this stays out of [`CHECKS`].
#[test]
fn throwaway_drum_decay_time_is_measurable() {
    let make: Box<Make> = Box::new(make_test_drum);
    check_decay_time_is_measurable(make.as_ref()).unwrap();
}

/// CPU budget for one drum, as a percent of a core at one hit per 16th at 120 BPM.
///
/// 0.2 % is the Phase 0 budget, calibrated on the single-layer throwaway drum. Layers cost real
/// CPU: the snare runs a two-oscillator tone, a filtered-noise snares layer and a snap
/// continuously at this hit rate (Tone Decay 150 ms, Snares Decay 220 ms, hits every 125 ms), so
/// it gets 0.25 %; the hat's six oscillators get the 0.3 % the plan's Phase 3 allows.
fn budget_for(id: &str) -> f32 {
    match id {
        "sonara.builtin.snare" => 0.25,
        "sonara.builtin.hat" => 0.3,
        _ => 0.2,
    }
}

/// CPU per built-in drum: one hit per 16th at 120 BPM (see [`budget_for`] for the budgets).
/// `cargo test --release drum_conformance::cpu_test_builtin_drums -- --ignored --nocapture`
#[test]
#[ignore = "CPU benchmark; run with --release"]
fn cpu_test_builtin_drums() {
    let seconds = 10.0;
    let total = (SR * seconds) as usize;
    let step = SR as usize / 8; // 8 sixteenths per second at 120 BPM
    let hits: Vec<(usize, u8, u8)> = (0..(seconds as usize * 8))
        .map(|i| (i * step, 60, 100))
        .collect();
    let mut over: Vec<String> = Vec::new();
    for &id in DRUM_IDS {
        let mut device = create_drum(id, SR, MAX_FRAMES).expect("drum id");
        let start = std::time::Instant::now();
        let out = render_blocks(device.as_mut(), total, 256, &hits);
        let elapsed = start.elapsed().as_secs_f32();
        assert!(
            out.iter().all(|x| x.is_finite()),
            "{id} produced a non-finite sample"
        );
        let cpu = elapsed / seconds * 100.0;
        let budget = budget_for(id);
        println!("{id}, 8 hits/s: {cpu:.4} % of a core (budget {budget} %)");
        if cpu >= budget {
            over.push(format!("{id}: {cpu:.4} % of a core, budget {budget} %"));
        }
    }
    assert!(over.is_empty(), "\n{}", over.join("\n"));
}

/// CPU: one hit per 16th at 120 BPM, under 0.2 % of a core.
/// `cargo test --release drum_conformance::cpu_test_drum -- --ignored --nocapture`
#[test]
#[ignore = "CPU benchmark; run with --release"]
fn cpu_test_drum() {
    let seconds = 10.0;
    let total = (SR * seconds) as usize;
    let step = SR as usize / 8; // 8 sixteenths per second at 120 BPM
    let hits: Vec<(usize, u8, u8)> = (0..(seconds as usize * 8))
        .map(|i| (i * step, 60, 100))
        .collect();
    let start = std::time::Instant::now();
    let out = render_blocks(make_test_drum().as_mut(), total, 256, &hits);
    let elapsed = start.elapsed().as_secs_f32();
    assert!(out.iter().all(|x| x.is_finite()));
    let cpu = elapsed / seconds * 100.0;
    println!("TestDrum, 8 hits/s: {cpu:.4} % of a core");
    assert!(cpu < 0.2, "{cpu:.4} % of a core");
}
