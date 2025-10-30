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
    pub fn new(sample_rate: f32) -> Self {
        let attack = 0.01;
        let decay = 0.1;
        let sustain = 0.7;
        let release = 0.3;
        Self {
            state: AdsrState::Idle,
            attack,
            decay,
            sustain,
            release,
            sample_rate,
            current_value: 0.0,
            attack_rate: 1.0 / (attack * sample_rate),
            decay_rate: (1.0 - sustain) / (decay * sample_rate),
            release_rate: sustain / (release * sample_rate),
        }
    }

    pub fn set_attack(&mut self, seconds: f32) {
        self.attack = seconds.max(0.001);
        self.attack_rate = 1.0 / (self.attack * self.sample_rate);
    }

    pub fn set_decay(&mut self, seconds: f32) {
        self.decay = seconds.max(0.001);
        self.decay_rate = (1.0 - self.sustain) / (self.decay * self.sample_rate);
    }

    pub fn set_sustain(&mut self, level: f32) {
        self.sustain = level.clamp(0.0, 1.0);
        self.decay_rate = (1.0 - self.sustain) / (self.decay * self.sample_rate);
        self.release_rate = self.sustain / (self.release * self.sample_rate);
    }

    pub fn set_release(&mut self, seconds: f32) {
        self.release = seconds.max(0.001);
        self.release_rate = self.sustain / (self.release * self.sample_rate);
    }

    /// Trigger the attack phase (note on)
    pub fn gate_on(&mut self) {
        self.state = AdsrState::Attack;
    }

    /// Trigger the release phase (note off)
    pub fn gate_off(&mut self) {
        if matches!(self.state, AdsrState::Idle) {
            return;
        }
        self.state = AdsrState::Release;
    }

    /// Process a block of envelope samples
    pub fn process_block(&mut self, output: &mut [f32], frames: usize) {
        for i in 0..frames {
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
            output[i] = self.current_value;
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

