//! A phase-accumulator LFO with the shapes PolySynth and the built-in effects share.
//!
//! The LFO only holds its phase and the current sample-and-hold value; the caller advances it
//! (per sample or per control block) and supplies S&H values from its own random source, so
//! voices and channels stay independent.

use std::f32::consts::TAU;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LfoShape {
    Sine,
    Triangle,
    Saw,
    Square,
    SampleHold,
}

impl LfoShape {
    /// Shape for choice `index` of the full list (Sine, Triangle, Saw, Square, S&H).
    pub fn from_index(index: usize) -> Self {
        match index {
            0 => LfoShape::Sine,
            1 => LfoShape::Triangle,
            2 => LfoShape::Saw,
            3 => LfoShape::Square,
            _ => LfoShape::SampleHold,
        }
    }
}

/// Choices for a Shape enum parameter, in `LfoShape::from_index` order.
pub const LFO_SHAPES: &[&str] = &["Sine", "Triangle", "Saw", "Square", "S&H"];

#[derive(Clone, Copy, Debug, Default)]
pub struct Lfo {
    /// 0..1.
    pub phase: f64,
    /// Current sample-and-hold value.
    held: f32,
}

impl Lfo {
    /// Output in −1..1 at the current phase.
    #[inline]
    pub fn value(&self, shape: LfoShape) -> f32 {
        shape_at(shape, self.phase as f32, self.held)
    }

    /// Output in −1..1 at the current phase plus `offset` cycles (e.g. 0.25 for a right channel
    /// 90° ahead). S&H ignores the offset.
    #[inline]
    pub fn value_at(&self, shape: LfoShape, offset: f64) -> f32 {
        shape_at(
            shape,
            (self.phase + offset).rem_euclid(1.0) as f32,
            self.held,
        )
    }

    /// Advance by `cycles` (Hz × seconds). Returns true when the phase wrapped, which is when the
    /// caller should draw a new S&H value.
    #[inline]
    pub fn advance(&mut self, cycles: f64) -> bool {
        self.phase += cycles;
        if self.phase >= 1.0 {
            self.phase = self.phase.fract();
            true
        } else {
            false
        }
    }

    /// Set the sample-and-hold value (−1..1).
    #[inline]
    pub fn set_held(&mut self, value: f32) {
        self.held = value;
    }
}

#[inline]
fn shape_at(shape: LfoShape, p: f32, held: f32) -> f32 {
    match shape {
        LfoShape::Sine => (TAU * p).sin(),
        LfoShape::Triangle => {
            if p < 0.25 {
                4.0 * p
            } else if p < 0.75 {
                2.0 - 4.0 * p
            } else {
                4.0 * p - 4.0
            }
        }
        LfoShape::Saw => 2.0 * p - 1.0,
        LfoShape::Square => {
            if p < 0.5 {
                1.0
            } else {
                -1.0
            }
        }
        LfoShape::SampleHold => held,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_hit_their_extremes() {
        let at = |shape, phase| {
            let lfo = Lfo {
                phase,
                ..Default::default()
            };
            lfo.value(shape)
        };
        assert!((at(LfoShape::Sine, 0.25) - 1.0).abs() < 1e-6);
        assert!((at(LfoShape::Triangle, 0.75) + 1.0).abs() < 1e-6);
        assert_eq!(at(LfoShape::Saw, 0.0), -1.0);
        assert_eq!(at(LfoShape::Square, 0.6), -1.0);
    }

    #[test]
    fn advance_wraps_and_offset_reads_ahead() {
        let mut lfo = Lfo::default();
        assert!(!lfo.advance(0.75));
        assert!(lfo.advance(0.5));
        assert!((lfo.phase - 0.25).abs() < 1e-12);
        // 0.25 + 0.5 offset = 0.75: the sine's trough.
        assert!((lfo.value_at(LfoShape::Sine, 0.5) + 1.0).abs() < 1e-6);
        lfo.set_held(0.3);
        assert_eq!(lfo.value_at(LfoShape::SampleHold, 0.5), 0.3);
    }
}
