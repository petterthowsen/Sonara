//! One-shot envelopes for drums: a click/body envelope with attack, hold, decay and release,
//! and a burst envelope for claps.

use super::noise::Rng;

/// Curve shape table resolution (`shape[i]`, `i` in 0..=1024).
const SHAPE_STEPS: usize = 1024;

/// Attack/hold/decay/release stage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Idle,
    Attack,
    Hold,
    Sustain,
    Decay,
    Release,
}

/// Decay shape table: `shape[i] = 0.001^((i/1024)^q)` with `q = 2^{-curve}`, so it always starts
/// at 1 and ends at −60 dB; `curve` 0 is exponential, +1 keeps the level higher longer, −1 drops
/// faster at first. Rebuilt only when the curve changes (no allocation).
fn shape_table(curve: f32) -> [f32; SHAPE_STEPS + 1] {
    let q = 2f32.powf(-curve.clamp(-1.0, 1.0));
    std::array::from_fn(|i| 0.001f32.powf((i as f32 / SHAPE_STEPS as f32).powf(q)))
}

/// Linearly interpolated lookup into a [`shape_table`], with the argument clamped to 0..1.
#[inline]
fn shape_at(table: &[f32; SHAPE_STEPS + 1], t: f32) -> f32 {
    let x = t.clamp(0.0, 1.0) * SHAPE_STEPS as f32;
    let i = x as usize;
    if i >= SHAPE_STEPS {
        return table[SHAPE_STEPS];
    }
    let frac = x - i as f32;
    table[i] + frac * (table[i + 1] - table[i])
}

/// One-shot envelope for drum hits: no gate unless `set_gated(true)`.
///
/// Stages run `Idle -> Attack -> Hold -> (gated ? Sustain : Decay)`, with `gate_off()` moving a
/// gated envelope into Release. Attack ramps linearly to 1.0; decay and release follow a
/// [`shape_table`] from the level the stage started at down to −60 dB. `trigger()` restarts from
/// the current level, so retriggers don't click.
#[derive(Clone, Debug)]
pub struct OneShotEnvelope {
    sample_rate: f32,
    attack: f32,
    hold: f32,
    decay: f32,
    release: f32,
    curve: f32,
    gated: bool,
    stage: Stage,
    level: f32,
    start_level: f32,
    stage_pos: f32,
    stage_samples: f32,
    shape: [f32; SHAPE_STEPS + 1],
}

impl OneShotEnvelope {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            attack: 0.0,
            hold: 0.0,
            decay: 0.4,
            release: 0.2,
            curve: 0.0,
            gated: false,
            stage: Stage::Idle,
            level: 0.0,
            start_level: 0.0,
            stage_pos: 0.0,
            stage_samples: 0.0,
            shape: shape_table(0.0),
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
    }

    /// Attack time in seconds (clamped `>= 0`).
    pub fn set_attack(&mut self, seconds: f32) {
        self.attack = seconds.max(0.0);
    }

    /// Hold time in seconds (clamped `>= 0`).
    pub fn set_hold(&mut self, seconds: f32) {
        self.hold = seconds.max(0.0);
    }

    /// Decay time in seconds (clamped 1e-4..30).
    pub fn set_decay(&mut self, seconds: f32) {
        self.decay = seconds.clamp(1e-4, 30.0);
    }

    /// Release time in seconds (clamped 1e-4..30).
    pub fn set_release(&mut self, seconds: f32) {
        self.release = seconds.clamp(1e-4, 30.0);
    }

    /// Decay/release curve, −1 (fast drop) .. +1 (held/linear).
    pub fn set_curve(&mut self, curve: f32) {
        self.curve = curve.clamp(-1.0, 1.0);
        self.shape = shape_table(self.curve);
    }

    /// Enable gated mode: the envelope sustains at 1.0 until [`gate_off`](Self::gate_off).
    pub fn set_gated(&mut self, gated: bool) {
        if self.gated == gated {
            return;
        }
        self.gated = gated;
        match self.stage {
            Stage::Sustain if !gated => self.enter_decay(),
            Stage::Decay if gated => self.enter_sustain(),
            _ => {}
        }
    }

    /// Restart the attack from the current level (so an active retrigger doesn't jump).
    pub fn trigger(&mut self) {
        if self.stage == Stage::Idle {
            self.level = 0.0;
        }
        self.start_level = self.level;
        self.stage = Stage::Attack;
        self.stage_pos = 0.0;
        self.stage_samples = self.attack * self.sample_rate;
    }

    /// Move a gated envelope from Attack/Hold/Sustain into Release. No-op when ungated.
    pub fn gate_off(&mut self) {
        if self.gated && matches!(self.stage, Stage::Attack | Stage::Hold | Stage::Sustain) {
            self.enter_release();
        }
    }

    pub fn process_sample(&mut self) -> f32 {
        loop {
            match self.stage {
                Stage::Idle => return 0.0,
                Stage::Attack => {
                    if self.stage_samples <= 0.0 || self.stage_pos >= self.stage_samples {
                        self.level = 1.0;
                        self.enter_hold();
                        continue;
                    }
                    self.level = self.start_level
                        + (1.0 - self.start_level) * (self.stage_pos / self.stage_samples);
                    self.stage_pos += 1.0;
                    return self.level;
                }
                Stage::Hold => {
                    if self.stage_pos >= self.stage_samples {
                        self.enter_after_hold();
                        continue;
                    }
                    self.level = 1.0;
                    self.stage_pos += 1.0;
                    return self.level;
                }
                Stage::Sustain => return self.level,
                Stage::Decay | Stage::Release => {
                    if self.stage_samples <= 0.0 || self.stage_pos >= self.stage_samples {
                        self.level = 0.0;
                        self.stage = Stage::Idle;
                        return 0.0;
                    }
                    self.level = self.start_level
                        * shape_at(&self.shape, self.stage_pos / self.stage_samples);
                    self.stage_pos += 1.0;
                    return self.level;
                }
            }
        }
    }

    pub fn value(&self) -> f32 {
        self.level
    }

    /// False only while Idle.
    pub fn is_active(&self) -> bool {
        self.stage != Stage::Idle
    }

    pub fn reset(&mut self) {
        self.stage = Stage::Idle;
        self.level = 0.0;
        self.start_level = 0.0;
        self.stage_pos = 0.0;
        self.stage_samples = 0.0;
    }

    fn enter_hold(&mut self) {
        self.stage = Stage::Hold;
        self.stage_pos = 0.0;
        self.stage_samples = self.hold * self.sample_rate;
        self.level = 1.0;
    }

    fn enter_after_hold(&mut self) {
        if self.gated {
            self.enter_sustain();
        } else {
            self.enter_decay();
        }
    }

    fn enter_sustain(&mut self) {
        self.stage = Stage::Sustain;
    }

    fn enter_decay(&mut self) {
        self.stage = Stage::Decay;
        self.start_level = self.level;
        self.stage_pos = 0.0;
        self.stage_samples = self.decay * self.sample_rate;
    }

    fn enter_release(&mut self) {
        self.stage = Stage::Release;
        self.start_level = self.level;
        self.stage_pos = 0.0;
        self.stage_samples = self.release * self.sample_rate;
    }
}

const MAX_BURSTS: usize = 8;

/// Clap burst envelope: `count` short decays spaced `spread_s` apart, the first at sample 0.
///
/// `trigger()` precomputes the burst starts and levels (no allocation); successive bursts sum
/// where they overlap, and the output is 0 between and after them.
#[derive(Clone, Debug)]
pub struct BurstEnvelope {
    sample_rate: f32,
    count: usize,
    spread_s: f32,
    burst_decay_s: f32,
    curve: f32,
    shape: [f32; SHAPE_STEPS + 1],
    starts: [f32; MAX_BURSTS],
    levels: [f32; MAX_BURSTS],
    pos: f32,
    active: bool,
}

impl BurstEnvelope {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            count: 1,
            spread_s: 0.01,
            burst_decay_s: 0.006,
            curve: 0.0,
            shape: shape_table(0.0),
            starts: [0.0; MAX_BURSTS],
            levels: [0.0; MAX_BURSTS],
            pos: 0.0,
            active: false,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
    }

    /// Set the burst count and times; all arguments are clamped to their documented ranges.
    pub fn configure(&mut self, count: usize, spread_s: f32, burst_decay_s: f32, curve: f32) {
        self.count = count.clamp(1, MAX_BURSTS);
        self.spread_s = spread_s.clamp(0.0005, 0.2);
        self.burst_decay_s = burst_decay_s.clamp(1e-4, 0.1);
        self.curve = curve.clamp(-1.0, 1.0);
        self.shape = shape_table(self.curve);
    }

    /// Precompute burst starts and levels. `randomness` (0..1) jitters the gaps and levels.
    pub fn trigger(&mut self, rng: &mut Rng, randomness: f32) {
        let randomness = randomness.clamp(0.0, 1.0);
        let mut t = 0.0f32;
        for i in 0..self.count {
            self.starts[i] = t;
            self.levels[i] = 1.0 - randomness * 0.3 * rng.next_f32();
            if i + 1 < self.count {
                let gap = if randomness == 0.0 {
                    self.spread_s
                } else {
                    (self.spread_s * (1.0 + randomness * 0.3 * rng.bipolar()))
                        .max(1.0 / self.sample_rate)
                };
                t += gap * self.sample_rate;
            }
        }
        self.pos = 0.0;
        self.active = true;
    }

    pub fn process_sample(&mut self) -> f32 {
        if !self.active {
            return 0.0;
        }
        let decay_samples = self.burst_decay_s * self.sample_rate;
        let mut out = 0.0f32;
        for i in 0..self.count {
            let d = self.pos - self.starts[i];
            if d >= 0.0 && d < decay_samples {
                out += self.levels[i] * shape_at(&self.shape, d / decay_samples);
            }
        }
        self.pos += 1.0;
        let end = self.starts[self.count - 1] + decay_samples;
        if self.pos >= end {
            self.active = false;
        }
        out
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn reset(&mut self) {
        self.pos = 0.0;
        self.active = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f32 = 48_000.0;

    fn samples_to_quiet(env: &mut OneShotEnvelope, limit: usize) -> usize {
        for n in 0..limit {
            if env.process_sample() <= 0.001 {
                return n;
            }
        }
        limit
    }

    #[test]
    fn stage_times_are_accurate() {
        let mut env = OneShotEnvelope::new(SR);
        env.set_attack(0.05);
        env.set_hold(0.1);
        env.set_decay(0.4);
        env.trigger();
        // Attack: level first reaches 1.0 after about `attack` seconds.
        let mut attack_samples = 0;
        for n in 0..(SR * 0.2) as usize {
            if env.process_sample() >= 0.9999 {
                attack_samples = n;
                break;
            }
        }
        let want = 0.05 * SR;
        assert!(
            (attack_samples as f32 - want).abs() / want < 0.05,
            "attack {attack_samples} vs {want}"
        );
        // Hold: level stays at 1.0 for about `hold` seconds.
        let mut hold_samples = 0;
        while env.value() >= 0.9999 && hold_samples < (SR * 0.3) as usize {
            env.process_sample();
            hold_samples += 1;
        }
        let want = 0.1 * SR;
        assert!(
            (hold_samples as f32 - want).abs() / want < 0.05,
            "hold {hold_samples} vs {want}"
        );
        // Decay: falls to -60 dB after about `decay` seconds.
        let decay_samples = samples_to_quiet(&mut env, (SR * 1.0) as usize);
        let want = 0.4 * SR;
        assert!(
            (decay_samples as f32 - want).abs() / want < 0.05,
            "decay {decay_samples} vs {want}"
        );
        assert!(!env.is_active());
    }

    #[test]
    fn retrigger_mid_decay_does_not_jump() {
        let mut env = OneShotEnvelope::new(SR);
        env.set_attack(0.005);
        env.set_decay(0.4);
        env.trigger();
        for _ in 0..(SR * 0.2) as usize {
            env.process_sample();
        }
        let before = env.value();
        env.trigger();
        let after = env.process_sample();
        assert!((after - before).abs() <= 0.01, "{before} -> {after}");
        assert!(env.is_active());
    }

    #[test]
    fn curve_holds_the_level_higher() {
        let at_half = |curve: f32| {
            let mut env = OneShotEnvelope::new(SR);
            env.set_curve(curve);
            env.trigger();
            let n = (0.4 * SR * 0.5) as usize;
            let mut v = 0.0;
            for _ in 0..n {
                v = env.process_sample();
            }
            v
        };
        let (fast, exp, held) = (at_half(-1.0), at_half(0.0), at_half(1.0));
        assert!(fast > exp && exp > held, "{fast} {exp} {held}");
    }

    #[test]
    fn gated_mode_sustains_then_releases() {
        let mut env = OneShotEnvelope::new(SR);
        env.set_gated(true);
        env.set_decay(0.05);
        env.set_release(0.2);
        env.trigger();
        // Level stays at 1.0 well past the decay time while the gate is held.
        for _ in 0..(SR * 0.2) as usize {
            env.process_sample();
        }
        assert!(env.value() > 0.99, "{}", env.value());
        env.gate_off();
        let release_samples = samples_to_quiet(&mut env, (SR * 1.0) as usize);
        let want = 0.2 * SR;
        assert!(
            (release_samples as f32 - want).abs() / want < 0.05,
            "release {release_samples} vs {want}"
        );
    }

    #[test]
    fn gate_off_is_a_noop_when_ungated() {
        let mut env = OneShotEnvelope::new(SR);
        env.trigger();
        for _ in 0..100 {
            env.process_sample();
        }
        let before = env.value();
        env.gate_off();
        assert!(env.value() == before);
        assert!(env.is_active());
    }

    fn local_peaks(signal: &[f32]) -> Vec<usize> {
        let mut out = Vec::new();
        for i in 0..signal.len() {
            let prev = if i == 0 {
                f32::NEG_INFINITY
            } else {
                signal[i - 1]
            };
            let next = if i + 1 == signal.len() {
                f32::NEG_INFINITY
            } else {
                signal[i + 1]
            };
            if signal[i] > prev && signal[i] >= next && signal[i] > 0.05 {
                out.push(i);
            }
        }
        out
    }

    fn render(env: &mut BurstEnvelope, samples: usize) -> Vec<f32> {
        (0..samples).map(|_| env.process_sample()).collect()
    }

    #[test]
    fn bursts_are_evenly_spaced_without_randomness() {
        let mut env = BurstEnvelope::new(SR);
        env.configure(4, 0.01, 0.006, 0.0);
        let mut rng = Rng::new(1);
        env.trigger(&mut rng, 0.0);
        let signal = render(&mut env, (SR * 0.1) as usize);
        let peaks = local_peaks(&signal);
        assert_eq!(peaks.len(), 4, "{peaks:?}");
        let want = (0.01 * SR) as i64;
        for pair in peaks.windows(2) {
            let gap = pair[1] as i64 - pair[0] as i64;
            assert!((gap - want).abs() <= 1, "gap {gap} vs {want}");
        }
        assert!(!env.is_active());
    }

    #[test]
    fn zero_randomness_is_repeatable() {
        let mut env = BurstEnvelope::new(SR);
        env.configure(4, 0.01, 0.006, 0.0);
        let mut rng = Rng::new(7);
        env.trigger(&mut rng, 0.0);
        let first = render(&mut env, (SR * 0.1) as usize);
        env.trigger(&mut rng, 0.0);
        let second = render(&mut env, (SR * 0.1) as usize);
        assert_eq!(first, second);
    }

    #[test]
    fn randomness_changes_the_spacing() {
        let mut env = BurstEnvelope::new(SR);
        env.configure(4, 0.01, 0.006, 0.0);
        let mut rng = Rng::new(42);
        env.trigger(&mut rng, 0.5);
        let first = local_peaks(&render(&mut env, (SR * 0.1) as usize));
        env.trigger(&mut rng, 0.5);
        let second = local_peaks(&render(&mut env, (SR * 0.1) as usize));
        assert_eq!(first.len(), 4);
        assert_eq!(second.len(), 4);
        assert_ne!(first, second);
    }
}
