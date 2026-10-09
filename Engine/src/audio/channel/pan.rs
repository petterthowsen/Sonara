//! Pan modes and the pan coefficient matrix.

use super::Channel;

/// Pan mode enumeration (matches Godot's PanMode enum)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PanMode {
    /// Cubase-style combined panner: the left and right inputs sit at handles
    /// `position - width` and `position + width`, each constant-power panned.
    StereoCombined = 0,
    /// Independent constant-power pan handles for the left and right inputs.
    StereoDual = 1,
    /// Linear balance: attenuates only the input opposite to the pan direction. The default.
    StereoBalance = 2,
    /// Sums the inputs as (L+R)/2 and constant-power pans the sum.
    Mono = 3,
}

impl Default for PanMode {
    fn default() -> Self {
        PanMode::StereoBalance
    }
}

impl From<i32> for PanMode {
    fn from(value: i32) -> Self {
        match value {
            0 => PanMode::StereoCombined,
            1 => PanMode::StereoDual,
            2 => PanMode::StereoBalance,
            3 => PanMode::Mono,
            _ => PanMode::StereoCombined,
        }
    }
}

/// Pan coefficients for mixing
#[derive(Debug, Clone, Copy)]
pub struct PanCoefficients {
    pub left_to_left: f32,
    pub right_to_right: f32,
    pub left_to_right: f32,
    pub right_to_left: f32,
}

impl Channel {
    /// Pan position in use: the automation override when set, otherwise the base `pan`.
    fn effective_pan(&self) -> f32 {
        match self.automation_pan {
            Some(normalized) => crate::audio::automation::normalized_to_pan(normalized),
            None => self.pan,
        }
    }

    /// Get pan coefficients based on current pan mode
    /// Returns a 4-coefficient matrix for stereo-to-stereo panning
    pub fn get_pan_coefficients(&self) -> PanCoefficients {
        use std::f32::consts::FRAC_PI_2;

        let pan = self.effective_pan();

        match self.pan_mode {
            PanMode::StereoCombined => {
                let left = (pan - self.pan_width).clamp(-1.0, 1.0);
                let right = (pan + self.pan_width).clamp(-1.0, 1.0);
                Self::dual_matrix(left, right)
            }
            PanMode::StereoDual => Self::dual_matrix(self.pan_left, self.pan_right),
            PanMode::StereoBalance => {
                // Simple balance: pan < 0 reduces right, pan > 0 reduces left
                let left_gain = if pan <= 0.0 { 1.0 } else { 1.0 - pan };
                let right_gain = if pan >= 0.0 { 1.0 } else { 1.0 + pan };
                PanCoefficients {
                    left_to_left: left_gain,
                    right_to_right: right_gain,
                    left_to_right: 0.0,
                    right_to_left: 0.0,
                }
            }
            PanMode::Mono => {
                // Sum to (L+R)/2, then constant-power pan the sum.
                let angle = (pan + 1.0) * 0.5 * FRAC_PI_2;
                let (to_left, to_right) = (angle.cos() * 0.5, angle.sin() * 0.5);
                PanCoefficients {
                    left_to_left: to_left,
                    right_to_left: to_left,
                    left_to_right: to_right,
                    right_to_right: to_right,
                }
            }
        }
    }

    /// Constant-power matrix placing the left input at handle `l` and the right input at handle
    /// `r`, both in -1.0..1.0.
    fn dual_matrix(l: f32, r: f32) -> PanCoefficients {
        use std::f32::consts::FRAC_PI_2;

        let angle_l = (l + 1.0) * 0.5 * FRAC_PI_2;
        let angle_r = (r + 1.0) * 0.5 * FRAC_PI_2;
        PanCoefficients {
            left_to_left: angle_l.cos(),
            right_to_right: angle_r.sin(),
            left_to_right: angle_l.sin(),
            right_to_left: angle_r.cos(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn channel(mode: PanMode, pan: f32, width: f32) -> Channel {
        let mut c = Channel::new(2, "T".to_string(), 128, 48_000.0);
        c.pan_mode = mode;
        c.pan = pan;
        c.pan_width = width;
        c
    }

    fn assert_matrix(c: &PanCoefficients, ll: f32, rr: f32, lr: f32, rl: f32) {
        let close = |a: f32, b: f32| (a - b).abs() < 1e-5;
        assert!(
            close(c.left_to_left, ll)
                && close(c.right_to_right, rr)
                && close(c.left_to_right, lr)
                && close(c.right_to_left, rl),
            "got {:?}, expected ll={ll} rr={rr} lr={lr} rl={rl}",
            c
        );
    }

    const H: f32 = std::f32::consts::FRAC_1_SQRT_2;

    #[test]
    fn pan_mode_default_is_balance() {
        assert_eq!(PanMode::default(), PanMode::StereoBalance);
        let c = Channel::new(2, "T".to_string(), 128, 48_000.0);
        assert_eq!(c.pan_mode, PanMode::StereoBalance);
        assert_eq!(c.pan_width, 1.0);
    }

    #[test]
    fn pan_balance_coefficients() {
        assert_matrix(
            &channel(PanMode::StereoBalance, 0.0, 1.0).get_pan_coefficients(),
            1.0,
            1.0,
            0.0,
            0.0,
        );
        assert_matrix(
            &channel(PanMode::StereoBalance, 0.5, 1.0).get_pan_coefficients(),
            0.5,
            1.0,
            0.0,
            0.0,
        );
        assert_matrix(
            &channel(PanMode::StereoBalance, -1.0, 1.0).get_pan_coefficients(),
            1.0,
            0.0,
            0.0,
            0.0,
        );
    }

    #[test]
    fn pan_combined_coefficients() {
        // Width 1 at center: handles -1/+1, identity.
        assert_matrix(
            &channel(PanMode::StereoCombined, 0.0, 1.0).get_pan_coefficients(),
            1.0,
            1.0,
            0.0,
            0.0,
        );
        // Width 0: both handles at center.
        assert_matrix(
            &channel(PanMode::StereoCombined, 0.0, 0.0).get_pan_coefficients(),
            H,
            H,
            H,
            H,
        );
        // Negative width swaps the sides.
        assert_matrix(
            &channel(PanMode::StereoCombined, 0.0, -1.0).get_pan_coefficients(),
            0.0,
            0.0,
            1.0,
            1.0,
        );
        // Position +0.5, width 1: handles -0.5 / +1.0 (right clamped).
        let expected = Channel::dual_matrix(-0.5, 1.0);
        let got = channel(PanMode::StereoCombined, 0.5, 1.0).get_pan_coefficients();
        assert_matrix(
            &got,
            expected.left_to_left,
            expected.right_to_right,
            expected.left_to_right,
            expected.right_to_left,
        );
        assert!((got.right_to_right - 1.0).abs() < 1e-5 && got.right_to_left.abs() < 1e-5);
    }

    #[test]
    fn pan_dual_coefficients_unchanged() {
        use std::f32::consts::FRAC_PI_2;
        let mut c = channel(PanMode::StereoDual, 0.0, 1.0);
        c.pan_left = -1.0;
        c.pan_right = 0.2;
        let al = 0.0_f32;
        let ar = 1.2 * 0.5 * FRAC_PI_2;
        assert_matrix(
            &c.get_pan_coefficients(),
            al.cos(),
            ar.sin(),
            al.sin(),
            ar.cos(),
        );
    }

    #[test]
    fn pan_mono_sums_half() {
        let c = channel(PanMode::Mono, 0.0, 1.0).get_pan_coefficients();
        // Identical L and R content x = 1 sums to 1, then -3 dB to each side.
        assert!((c.left_to_left + c.right_to_left - H).abs() < 1e-5);
        assert!((c.left_to_right + c.right_to_right - H).abs() < 1e-5);
        let r = channel(PanMode::Mono, 1.0, 1.0).get_pan_coefficients();
        assert!((r.left_to_left + r.right_to_left).abs() < 1e-5);
        assert!((r.left_to_right + r.right_to_right - 1.0).abs() < 1e-5);
    }

    #[test]
    fn pan_combined_automation_moves_position() {
        let mut c = channel(PanMode::StereoCombined, 0.0, 0.5);
        c.automation_pan = Some(1.0);
        let expected = Channel::dual_matrix(0.5, 1.0);
        assert_matrix(
            &c.get_pan_coefficients(),
            expected.left_to_left,
            expected.right_to_right,
            expected.left_to_right,
            expected.right_to_left,
        );
        assert_eq!(c.pan_width, 0.5, "width must not be written");
        assert_eq!(c.pan, 0.0, "base pan must not be written");
    }
}
