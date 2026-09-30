/// A parameter that glides linearly to its target instead of jumping, so knob moves don't click.
#[derive(Clone, Copy, Debug)]
pub struct SmoothedParam {
    current: f32,
    target: f32,
    step: f32,
    ramp_samples: f32,
}

impl SmoothedParam {
    /// Default glide time.
    pub const DEFAULT_RAMP_MS: f32 = 5.0;

    pub fn new(value: f32, sample_rate: f32, ramp_ms: f32) -> Self {
        Self {
            current: value,
            target: value,
            step: 0.0,
            ramp_samples: (ramp_ms * 0.001 * sample_rate).max(1.0),
        }
    }

    /// Change the ramp length (e.g. after a sample rate change).
    pub fn set_ramp(&mut self, sample_rate: f32, ramp_ms: f32) {
        self.ramp_samples = (ramp_ms * 0.001 * sample_rate).max(1.0);
        self.retarget();
    }

    /// Glide toward `value`, reaching it in one ramp length from now.
    pub fn set_target(&mut self, value: f32) {
        self.target = value;
        self.retarget();
    }

    /// Jump straight to `value` (initialisation, voice reset).
    pub fn snap(&mut self, value: f32) {
        self.current = value;
        self.target = value;
        self.step = 0.0;
    }

    fn retarget(&mut self) {
        self.step = (self.target - self.current) / self.ramp_samples;
    }

    pub fn target(&self) -> f32 {
        self.target
    }

    pub fn current(&self) -> f32 {
        self.current
    }

    pub fn is_settled(&self) -> bool {
        self.current == self.target
    }

    /// Advance one sample.
    #[inline]
    pub fn next(&mut self) -> f32 {
        if self.current != self.target {
            self.current += self.step;
            // Stop exactly on the target (also covers float overshoot).
            if (self.step > 0.0 && self.current >= self.target)
                || (self.step < 0.0 && self.current <= self.target)
                || self.step == 0.0
            {
                self.current = self.target;
            }
        }
        self.current
    }

    /// Fill `out` with the next `out.len()` values.
    pub fn fill(&mut self, out: &mut [f32]) {
        for v in out.iter_mut() {
            *v = self.next();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_have_no_discontinuity_larger_than_one_ramp_step() {
        let mut p = SmoothedParam::new(0.0, 48_000.0, 5.0);
        p.set_target(1.0);
        let one_step = 1.0 / (0.005 * 48_000.0);
        let mut prev = p.current();
        let mut reached_at = None;
        for i in 0..1_000 {
            let v = p.next();
            assert!((v - prev).abs() <= one_step * 1.001, "jump at {i}");
            if reached_at.is_none() && v == 1.0 {
                reached_at = Some(i + 1);
            }
            prev = v;
        }
        let reached = reached_at.expect("never reached target");
        assert!((239..=242).contains(&reached), "reached after {reached}");
        assert_eq!(p.next(), 1.0);
    }

    #[test]
    fn retargeting_mid_ramp_stays_continuous() {
        let mut p = SmoothedParam::new(0.0, 48_000.0, 5.0);
        p.set_target(1.0);
        for _ in 0..100 {
            p.next();
        }
        let mid = p.current();
        p.set_target(0.0);
        let v = p.next();
        assert!((v - mid).abs() <= 1.0 / 240.0 * 1.001);
        for _ in 0..1_000 {
            p.next();
        }
        assert_eq!(p.current(), 0.0);
    }
}
