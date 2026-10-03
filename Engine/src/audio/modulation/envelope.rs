/// ADSR envelope state
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AdsrState {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release,
}

/// How far past its goal each stage aims (as a fraction of the stage's travel). The stage ends
/// when it crosses the goal, so the time is exact, while the curve stays exponential rather than
/// straight. A bigger overshoot is closer to linear.
const ATTACK_OVERSHOOT: f32 = 0.3;
const FALL_OVERSHOOT: f32 = 0.05;

/// Per-sample one-pole coefficient that closes `1 - overshoot/(1+overshoot)` of the gap to an
/// overshoot target in `samples`, i.e. crosses the goal after exactly that many samples.
fn coefficient(samples: f32, overshoot: f32) -> f32 {
    let samples = samples.max(1.0);
    (overshoot / (1.0 + overshoot)).powf(1.0 / samples)
}

/// ADSR envelope generator with exponential segments.
///
/// - Attack, decay and release each move one-pole style toward an overshoot target, so the stage
///   takes exactly its set time but sounds natural (fast start, gentle finish).
/// - `retrigger_from_current` (also what `gate_on` does) restarts the attack from the current
///   level, so stolen and legato notes don't click.
#[derive(Clone, Copy, Debug)]
pub struct AdsrEnvelope {
    pub state: AdsrState,
    pub attack: f32,
    pub decay: f32,
    pub sustain: f32,
    pub release: f32,
    pub sample_rate: f32,
    pub current_value: f32,
    // Per-sample one-pole coefficients (recomputed when times change).
    attack_coef: f32,
    decay_coef: f32,
    release_coef: f32,
    /// Where the release is heading (below zero, so it crosses zero in `release` seconds).
    release_target: f32,
}

impl AdsrEnvelope {
    /// Create an idle envelope using `sample_rate` for stage-rate calculations.
    pub fn new(sample_rate: f32) -> Self {
        let sample_rate = sample_rate.max(1.0);
        let mut env = Self {
            state: AdsrState::Idle,
            attack: 0.01,
            decay: 0.1,
            sustain: 0.7,
            release: 0.3,
            sample_rate,
            current_value: 0.0,
            attack_coef: 0.0,
            decay_coef: 0.0,
            release_coef: 0.0,
            release_target: 0.0,
        };
        env.recalculate_rates();
        env
    }

    /// Recompute the stage coefficients from the current times.
    fn recalculate_rates(&mut self) {
        let sr = self.sample_rate.max(1.0);
        self.attack_coef = coefficient(self.attack * sr, ATTACK_OVERSHOOT);
        self.decay_coef = coefficient(self.decay * sr, FALL_OVERSHOOT);
        self.release_coef = coefficient(self.release * sr, FALL_OVERSHOOT);
    }

    /// Set attack, decay, sustain, and release together and recompute rates. A no-op when
    /// nothing changed, so re-applying the same parameters stays off the powf path.
    pub fn set_adsr(&mut self, attack: f32, decay: f32, sustain: f32, release: f32) {
        let attack = attack.max(0.0005);
        let decay = decay.max(0.0005);
        let sustain = sustain.clamp(0.0, 1.0);
        let release = release.max(0.0005);
        if attack == self.attack
            && decay == self.decay
            && sustain == self.sustain
            && release == self.release
        {
            return;
        }
        self.attack = attack;
        self.decay = decay;
        self.sustain = sustain;
        self.release = release;
        self.recalculate_rates();
    }

    /// Set attack time in seconds.
    pub fn set_attack(&mut self, seconds: f32) {
        self.attack = seconds.max(0.0005);
        self.recalculate_rates();
    }

    /// Set decay time in seconds.
    pub fn set_decay(&mut self, seconds: f32) {
        self.decay = seconds.max(0.0005);
        self.recalculate_rates();
    }

    /// Set sustain level (0–1).
    pub fn set_sustain(&mut self, level: f32) {
        self.sustain = level.clamp(0.0, 1.0);
    }

    /// Set release time in seconds; takes effect immediately even mid-release.
    pub fn set_release(&mut self, seconds: f32) {
        self.release = seconds.max(0.0005);
        self.recalculate_rates();
    }

    /// Trigger the attack phase (note on), continuing from the current level.
    pub fn gate_on(&mut self) {
        self.retrigger_from_current();
    }

    /// Start a new attack from wherever the envelope is now (no jump to zero).
    pub fn retrigger_from_current(&mut self) {
        self.state = AdsrState::Attack;
    }

    /// Trigger the release phase (note off), falling from the current level to zero.
    pub fn gate_off(&mut self) {
        if matches!(self.state, AdsrState::Idle) {
            return;
        }
        self.state = AdsrState::Release;
        self.release_target = -FALL_OVERSHOOT * self.current_value;
    }

    /// Advance one sample and return the current amplitude (0–1).
    pub fn process_sample(&mut self) -> f32 {
        match self.state {
            AdsrState::Idle => {
                self.current_value = 0.0;
            }
            AdsrState::Attack => {
                let target = 1.0 + ATTACK_OVERSHOOT;
                self.current_value = target + (self.current_value - target) * self.attack_coef;
                if self.current_value >= 1.0 {
                    self.current_value = 1.0;
                    self.state = AdsrState::Decay;
                }
            }
            AdsrState::Decay => {
                // Sustain at (or above) full level: nothing to decay.
                let travel = 1.0 - self.sustain;
                let target = self.sustain - FALL_OVERSHOOT * travel;
                self.current_value = target + (self.current_value - target) * self.decay_coef;
                if self.current_value <= self.sustain || travel < 1.0e-4 {
                    self.current_value = self.sustain;
                    self.state = AdsrState::Sustain;
                }
            }
            AdsrState::Sustain => {
                self.current_value = self.sustain;
            }
            AdsrState::Release => {
                let target = self.release_target;
                self.current_value = target + (self.current_value - target) * self.release_coef;
                if self.current_value <= 0.0 {
                    self.current_value = 0.0;
                    self.state = AdsrState::Idle;
                }
            }
        }
        self.current_value
    }

    /// Process a block of envelope samples
    pub fn process_block(&mut self, output: &mut [f32], frames: usize) {
        for i in 0..frames {
            output[i] = self.process_sample();
        }
    }

    /// Check if the envelope is active (not idle)
    pub fn is_active(&self) -> bool {
        !matches!(self.state, AdsrState::Idle) || self.current_value > 0.0
    }

    /// Reset the envelope to idle state
    pub fn reset(&mut self) {
        self.state = AdsrState::Idle;
        self.current_value = 0.0;
    }

    /// Get the current envelope state
    pub fn state(&self) -> AdsrState {
        self.state
    }

    /// Get the current envelope value
    pub fn value(&self) -> f32 {
        self.current_value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f32 = 48_000.0;

    /// Samples until `state` is left, counting from the current state.
    fn samples_in_state(env: &mut AdsrEnvelope, state: AdsrState) -> usize {
        let mut n = 0;
        while env.state() == state && n < 10_000_000 {
            env.process_sample();
            n += 1;
        }
        n
    }

    fn assert_within_5_percent(samples: usize, seconds: f32) {
        let expected = seconds * SR;
        let err = (samples as f32 - expected).abs() / expected;
        assert!(
            err <= 0.05,
            "{samples} samples vs {expected} expected ({err:.3})"
        );
    }

    #[test]
    fn attack_starts_near_zero() {
        let mut env = AdsrEnvelope::new(SR);
        env.set_attack(0.001);
        env.gate_on();
        let first = env.process_sample();
        assert!(first > 0.0 && first < 0.5);
        assert_eq!(env.state(), AdsrState::Attack);
    }

    #[test]
    fn stage_times_hit_their_target() {
        for &t in &[0.001, 0.02, 0.3, 2.0] {
            let mut env = AdsrEnvelope::new(SR);
            env.set_adsr(t, t, 0.4, t);
            env.gate_on();
            assert_within_5_percent(samples_in_state(&mut env, AdsrState::Attack), t);
            assert_within_5_percent(samples_in_state(&mut env, AdsrState::Decay), t);
            assert!((env.value() - 0.4).abs() < 1e-6);
            env.gate_off();
            assert_within_5_percent(samples_in_state(&mut env, AdsrState::Release), t);
            assert!(!env.is_active());
        }
    }

    #[test]
    fn release_time_holds_from_partial_level() {
        let mut env = AdsrEnvelope::new(SR);
        env.set_adsr(0.5, 0.5, 0.5, 0.1);
        env.gate_on();
        for _ in 0..2_000 {
            env.process_sample();
        }
        env.gate_off();
        assert_within_5_percent(samples_in_state(&mut env, AdsrState::Release), 0.1);
    }

    #[test]
    fn release_falls_from_current_level() {
        let mut env = AdsrEnvelope::new(SR);
        env.set_adsr(0.001, 0.001, 0.0, 0.01);
        env.gate_on();
        env.current_value = 0.8;
        env.gate_off();
        assert_eq!(env.state(), AdsrState::Release);
        let first = env.process_sample();
        assert!(first < 0.8 && first > 0.6);
    }

    #[test]
    fn retrigger_continues_from_current_level() {
        let mut env = AdsrEnvelope::new(SR);
        env.set_adsr(0.01, 0.01, 0.5, 0.5);
        env.gate_on();
        samples_in_state(&mut env, AdsrState::Attack);
        env.gate_off();
        for _ in 0..4_000 {
            env.process_sample();
        }
        let before = env.value();
        assert!(before > 0.0 && before < 1.0);
        env.retrigger_from_current();
        let after = env.process_sample();
        assert!(
            after >= before && after - before < 0.1,
            "{before} -> {after}"
        );
    }

    #[test]
    fn release_with_zero_sustain_still_reaches_idle() {
        let mut env = AdsrEnvelope::new(SR);
        env.set_adsr(0.001, 0.001, 0.0, 0.001);
        env.gate_on();
        for _ in 0..200 {
            env.process_sample();
        }
        env.gate_off();
        for _ in 0..200 {
            env.process_sample();
        }
        assert!(!env.is_active());
        assert_eq!(env.state(), AdsrState::Idle);
    }

    #[test]
    fn full_sustain_skips_decay() {
        let mut env = AdsrEnvelope::new(SR);
        env.set_adsr(0.001, 0.5, 1.0, 0.1);
        env.gate_on();
        samples_in_state(&mut env, AdsrState::Attack);
        assert!(samples_in_state(&mut env, AdsrState::Decay) <= 1);
        assert_eq!(env.value(), 1.0);
    }
}
