//! Envelope follower with separate attack and release, for detectors (compressor, ducking,
//! envelope-driven filters).
//!
//! Times are one-pole time constants: after a step, the envelope covers 1 − 1/e (63 %) of the
//! distance in the attack or release time.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Detection {
    /// Follows `|x|`.
    Peak,
    /// Follows `x²` and reports the square root.
    Rms,
}

#[derive(Clone, Copy, Debug)]
pub struct EnvFollower {
    attack_coef: f32,
    release_coef: f32,
    detection: Detection,
    /// Peak level, or mean square for RMS.
    state: f32,
}

/// One-pole coefficient for a time constant of `ms` at `sample_rate` (0 ms = instant).
pub fn time_coef(ms: f32, sample_rate: f32) -> f32 {
    if ms <= 0.0 {
        0.0
    } else {
        (-1.0 / (ms * 0.001 * sample_rate)).exp()
    }
}

impl EnvFollower {
    pub fn new(attack_ms: f32, release_ms: f32, sample_rate: f32, detection: Detection) -> Self {
        let mut follower = Self {
            attack_coef: 0.0,
            release_coef: 0.0,
            detection,
            state: 0.0,
        };
        follower.set_times(attack_ms, release_ms, sample_rate);
        follower
    }

    pub fn set_times(&mut self, attack_ms: f32, release_ms: f32, sample_rate: f32) {
        self.attack_coef = time_coef(attack_ms, sample_rate);
        self.release_coef = time_coef(release_ms, sample_rate);
    }

    pub fn reset(&mut self) {
        self.state = 0.0;
    }

    /// Feed one sample; returns the envelope (linear amplitude).
    #[inline]
    pub fn process(&mut self, x: f32) -> f32 {
        let input = match self.detection {
            Detection::Peak => x.abs(),
            Detection::Rms => x * x,
        };
        let coef = if input > self.state {
            self.attack_coef
        } else {
            self.release_coef
        };
        self.state = input + coef * (self.state - input);
        self.value()
    }

    /// Current envelope (linear amplitude).
    #[inline]
    pub fn value(&self) -> f32 {
        match self.detection {
            Detection::Peak => self.state,
            Detection::Rms => self.state.sqrt(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f32 = 48_000.0;

    fn samples_to_reach(
        follower: &mut EnvFollower,
        input: f32,
        target: f32,
        rising: bool,
    ) -> usize {
        (1..SR as usize * 5)
            .find(|_| {
                let v = follower.process(input);
                if rising {
                    v >= target
                } else {
                    v <= target
                }
            })
            .unwrap()
    }

    #[test]
    fn attack_and_release_hit_their_time_constants() {
        let mut f = EnvFollower::new(10.0, 100.0, SR, Detection::Peak);
        let n = samples_to_reach(&mut f, 1.0, 1.0 - (-1.0f32).exp(), true);
        assert!((n as f32 - 480.0).abs() <= 5.0, "attack {n} samples");
        // Settle at 1, then release toward 0.
        for _ in 0..SR as usize {
            f.process(1.0);
        }
        let n = samples_to_reach(&mut f, 0.0, (-1.0f32).exp(), false);
        assert!((n as f32 - 4800.0).abs() <= 50.0, "release {n} samples");
    }

    #[test]
    fn rms_of_a_sine_settles_near_0_707() {
        let mut f = EnvFollower::new(50.0, 50.0, SR, Detection::Rms);
        let mut v = 0.0;
        for n in 0..SR as usize {
            v = f.process((std::f32::consts::TAU * 100.0 * n as f32 / SR).sin());
        }
        assert!((v - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.03, "{v}");
    }
}
