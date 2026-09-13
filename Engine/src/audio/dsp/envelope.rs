/// ADSR envelope state
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AdsrState {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release,
}

/// High-performance ADSR envelope generator
///
/// Features:
/// - Pre-calculated rates (no division per sample)
/// - Block processing
/// - Efficient state machine
#[derive(Clone, Copy, Debug)]
pub struct AdsrEnvelope {
    pub state: AdsrState,
    pub attack: f32,
    pub decay: f32,
    pub sustain: f32,
    pub release: f32,
    pub sample_rate: f32,
    pub current_value: f32,
    // Pre-calculated rates (avoid division per sample!)
    pub attack_rate: f32,
    pub decay_rate: f32,
    pub release_rate: f32,
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
            attack_rate: 0.0,
            decay_rate: 0.0,
            release_rate: 0.0,
        };
        env.recalculate_rates();
        env
    }

    /// Recompute per-sample attack/decay rates from the current stage times.
    fn recalculate_rates(&mut self) {
        let sr = self.sample_rate.max(1.0);
        self.attack_rate = 1.0 / (self.attack * sr).max(1.0);
        self.decay_rate = (1.0 - self.sustain) / (self.decay * sr).max(1.0);
        if matches!(self.state, AdsrState::Release) {
            self.release_rate = self.current_value / (self.release * sr).max(1.0);
        }
    }

    /// Set attack, decay, sustain, and release together and recompute rates.
    pub fn set_adsr(&mut self, attack: f32, decay: f32, sustain: f32, release: f32) {
        self.attack = attack.max(0.001);
        self.decay = decay.max(0.001);
        self.sustain = sustain.clamp(0.0, 1.0);
        self.release = release.max(0.001);
        self.recalculate_rates();
    }

    /// Set attack time in seconds and recompute the attack rate.
    pub fn set_attack(&mut self, seconds: f32) {
        self.attack = seconds.max(0.001);
        self.recalculate_rates();
    }

    /// Set decay time in seconds and recompute the decay rate.
    pub fn set_decay(&mut self, seconds: f32) {
        self.decay = seconds.max(0.001);
        self.recalculate_rates();
    }

    /// Set sustain level (0–1) and recompute the decay rate.
    pub fn set_sustain(&mut self, level: f32) {
        self.sustain = level.clamp(0.0, 1.0);
        self.recalculate_rates();
    }

    /// Set release time in seconds; updates the in-flight release rate if releasing.
    pub fn set_release(&mut self, seconds: f32) {
        self.release = seconds.max(0.001);
        self.recalculate_rates();
    }

    /// Trigger the attack phase (note on)
    pub fn gate_on(&mut self) {
        self.state = AdsrState::Attack;
    }

    /// Trigger the release phase (note off), falling from the current level to zero.
    pub fn gate_off(&mut self) {
        if matches!(self.state, AdsrState::Idle) {
            return;
        }
        self.state = AdsrState::Release;
        let samples = (self.release * self.sample_rate).max(1.0);
        self.release_rate = self.current_value / samples;
    }

    /// Advance one sample and return the current amplitude (0–1).
    pub fn process_sample(&mut self) -> f32 {
        match self.state {
            AdsrState::Idle => {
                self.current_value = 0.0;
            }
            AdsrState::Attack => {
                self.current_value += self.attack_rate;
                if self.current_value >= 1.0 {
                    self.current_value = 1.0;
                    self.state = AdsrState::Decay;
                }
            }
            AdsrState::Decay => {
                self.current_value -= self.decay_rate;
                if self.current_value <= self.sustain {
                    self.current_value = self.sustain;
                    self.state = AdsrState::Sustain;
                }
            }
            AdsrState::Sustain => {
                self.current_value = self.sustain;
            }
            AdsrState::Release => {
                self.current_value -= self.release_rate;
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

    #[test]
    fn attack_starts_near_zero() {
        let mut env = AdsrEnvelope::new(48_000.0);
        env.set_attack(0.001);
        env.gate_on();
        let first = env.process_sample();
        assert!(first > 0.0 && first < 0.1);
        assert_eq!(env.state(), AdsrState::Attack);
    }

    #[test]
    fn release_falls_from_current_level() {
        let mut env = AdsrEnvelope::new(48_000.0);
        env.set_adsr(0.001, 0.001, 0.0, 0.01);
        env.gate_on();
        env.current_value = 0.8;
        env.gate_off();
        assert_eq!(env.state(), AdsrState::Release);
        let first = env.process_sample();
        assert!(first < 0.8 && first > 0.7);
    }

    #[test]
    fn release_with_zero_sustain_still_reaches_idle() {
        let mut env = AdsrEnvelope::new(48_000.0);
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
}
