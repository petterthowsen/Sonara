//! The layout seam: a [`Panner`] turns a direction into one gain per output bus. Only stereo is
//! implemented; surround and binaural panners plug in here later.

use super::Vec3;
use std::f32::consts::FRAC_PI_4;

pub trait Panner {
    /// Output buses this panner writes.
    fn channels(&self) -> usize;

    /// Write one gain per output bus into `out` (`out.len() == channels()`) for a unit direction
    /// in the listener's frame (X right, Y forward, Z up). Returns how far behind the listener the
    /// direction lies, 0 (front half) to 1 (straight behind), for a gentle high-frequency cut.
    fn gains(&self, dir: Vec3, out: &mut [f32]) -> f32;
}

/// Constant-power stereo pan from the horizontal azimuth. Sources to the sides pan hard, sources
/// straight ahead or behind sit in the middle; elevation is ignored.
#[derive(Clone, Copy, Debug, Default)]
pub struct StereoPanner;

impl Panner for StereoPanner {
    fn channels(&self) -> usize {
        2
    }

    fn gains(&self, dir: Vec3, out: &mut [f32]) -> f32 {
        let horizontal = (dir.x * dir.x + dir.y * dir.y).sqrt();
        // sin(azimuth), -1 hard left to +1 hard right; overhead has no azimuth.
        let pan = if horizontal > 1e-6 {
            (dir.x / horizontal).clamp(-1.0, 1.0)
        } else {
            0.0
        };
        let angle = (pan + 1.0) * FRAC_PI_4;
        out[0] = angle.cos();
        out[1] = angle.sin();
        (-dir.y).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gains(dir: Vec3) -> (f32, f32, f32) {
        let mut g = [0.0; 2];
        let rear = StereoPanner.gains(dir, &mut g);
        (g[0], g[1], rear)
    }

    #[test]
    fn left_centre_right() {
        let (l, r, _) = gains(Vec3::new(-1.0, 0.0, 0.0));
        assert!((l - 1.0).abs() < 1e-5 && r.abs() < 1e-5);
        let (l, r, _) = gains(Vec3::new(1.0, 0.0, 0.0));
        assert!(l.abs() < 1e-5 && (r - 1.0).abs() < 1e-5);
        let (l, r, rear) = gains(Vec3::new(0.0, 1.0, 0.0));
        assert!((l - std::f32::consts::FRAC_1_SQRT_2).abs() < 1e-5);
        assert!((l - r).abs() < 1e-5);
        assert_eq!(rear, 0.0);
    }

    #[test]
    fn constant_power_within_a_tenth_of_a_db() {
        for deg in (-180..=180).step_by(5) {
            let a = (deg as f32).to_radians();
            let (l, r, _) = gains(Vec3::new(a.sin(), a.cos(), 0.0));
            let db = 10.0 * (l * l + r * r).log10();
            assert!(db.abs() < 0.1, "{deg} deg: {db} dB");
        }
        // Overhead falls back to the centre at full power.
        let (l, r, _) = gains(Vec3::new(0.0, 0.0, 1.0));
        assert!(((l * l + r * r) - 1.0).abs() < 1e-5);
    }

    #[test]
    fn rear_flag_grows_behind_the_listener() {
        assert_eq!(gains(Vec3::new(0.0, 1.0, 0.0)).2, 0.0);
        assert_eq!(gains(Vec3::new(1.0, 0.0, 0.0)).2, 0.0);
        assert!((gains(Vec3::new(0.0, -1.0, 0.0)).2 - 1.0).abs() < 1e-6);
        let half = gains(Vec3::new(0.7071, -0.7071, 0.0)).2;
        assert!(half > 0.5 && half < 0.9);
    }
}
