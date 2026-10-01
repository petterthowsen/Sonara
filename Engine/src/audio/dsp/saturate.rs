//! Saturation helpers shared by drive stages: a cheap tanh-shaped transfer curve and the
//! gain/blend pair that applies it without a jump at zero.

/// Drive reaches a fully saturated signal at this many dB; below it the clean and saturated
/// signals are crossfaded, so 0 dB is exactly clean and the knob has no jump.
const DRIVE_BLEND_DB: f32 = 6.0;

/// Rational tanh: exact at 0, within 2 % up to ±3, and ±1 beyond.
#[inline]
pub fn soft_clip(x: f32) -> f32 {
    let x = x.clamp(-3.0, 3.0);
    let x2 = x * x;
    x * (27.0 + x2) / (27.0 + 9.0 * x2)
}

/// tanh-shaped soft saturation for drive stages: a fifth-order rational approximation of `tanh`
/// clamped to ±4 before the curve, so the output stays within ±1 while cost stays a handful of
/// multiplies.
#[inline]
pub fn fast_tanh(x: f32) -> f32 {
    let x = x.clamp(-4.0, 4.0);
    let x2 = x * x;
    (x * (27.0 + x2) / (27.0 + 9.0 * x2)).clamp(-1.0, 1.0)
}

/// Pre-filter drive for `drive_db` (0 and up): `(gain, blend)`, applied by [`drive`].
pub fn drive_params(drive_db: f32) -> (f32, f32) {
    let db = drive_db.max(0.0);
    (10f32.powf(db / 20.0), (db / DRIVE_BLEND_DB).min(1.0))
}

#[inline]
pub fn drive(x: f32, gain: f32, blend: f32) -> f32 {
    x + blend * (soft_clip(x * gain) - x)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn soft_clip_is_odd_and_bounded() {
        for x in [-10.0, -3.0, -1.0, -0.25, 0.0, 0.25, 1.0, 3.0, 10.0] {
            assert!((soft_clip(x) + soft_clip(-x)).abs() < 1e-6, "odd at {x}");
            assert!(soft_clip(x).abs() <= 1.0, "bounded at {x}");
        }
        assert_eq!(soft_clip(0.0), 0.0);
    }

    #[test]
    fn fast_tanh_is_odd_and_bounded() {
        for x in [-10.0, -4.0, -1.5, -0.25, 0.0, 0.25, 1.5, 4.0, 10.0] {
            assert!((fast_tanh(x) + fast_tanh(-x)).abs() < 1e-6, "odd at {x}");
            assert!(fast_tanh(x).abs() <= 1.0, "bounded at {x}");
        }
        assert_eq!(fast_tanh(0.0), 0.0);
    }

    #[test]
    fn zero_drive_is_clean_and_drive_boosts_quiet_input() {
        let (gain, blend) = drive_params(0.0);
        for x in [-1.0, -0.3, 0.0, 0.5, 1.0] {
            assert_eq!(drive(x, gain, blend), x);
        }
        let (gain, blend) = drive_params(24.0);
        assert!(drive(1.0, gain, blend) <= 1.0);
        assert!(drive(0.1, gain, blend) > 0.5, "drive boosts quiet input");
    }
}
