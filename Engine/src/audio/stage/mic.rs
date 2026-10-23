//! Mic setups (spec 052): the stereo array the Stage listener records with.
//!
//! A setup is up to [`MAX_CAPSULES`] capsules. Each has an offset from the Listener, an aim, a
//! first-order polar pattern `a + (1 - a) cos(theta)` (omni a = 1, cardioid 0.5, figure-8 0) and a
//! mix into the left and right outputs. Directions are in the listener's frame: X right, Y
//! forward (toward the front wall), Z up.
//!
//! - Pan is not an array: it keeps [`StereoPanner`] untouched.
//! - Coincident setups (XY, Blumlein, M/S) put every capsule at the Listener, so a tap is one
//!   read with the capsule gains summed ([`MicArray::coincident_gains`]).
//! - Spaced setups (AB, ORTF, Decca tree) read every tap once per capsule, with the capsule as the
//!   receiver ([`MicArray::capsule_gains`], [`MicArray::capsule_position`]).
//!
//! Every setup is normalized so a source straight ahead at `R_REF` has `L² + R² = 1`, like the
//! panner, with the distance law applied from each capsule's own position. Coincident capsules add
//! coherently; spaced capsules arrive at different times, so their power adds instead.

use super::panner::{Panner, StereoPanner};
use super::{RoomModel, Vec3, MAX_DIRECT_GAIN, MIN_DISTANCE, R_REF};
use std::f32::consts::FRAC_1_SQRT_2;

pub const MAX_CAPSULES: usize = 3;
/// Upper bound on the extra path (m) a capsule offset can add between a tap's arrival at two
/// receivers: twice the farthest capsule offset (the Decca tree's centre, 1.5 m ahead).
pub const MAX_ARRAY_SPAN_M: f32 = 3.0;

/// The mic setup, with its `/stage/set` values.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MicSetup {
    /// Constant-power stereo pan (spec 051).
    #[default]
    Pan = 0,
    Xy = 1,
    Blumlein = 2,
    MidSide = 3,
    Ab = 4,
    Ortf = 5,
    Decca = 6,
}

impl From<i32> for MicSetup {
    fn from(value: i32) -> Self {
        match value {
            1 => MicSetup::Xy,
            2 => MicSetup::Blumlein,
            3 => MicSetup::MidSide,
            4 => MicSetup::Ab,
            5 => MicSetup::Ortf,
            6 => MicSetup::Decca,
            _ => MicSetup::Pan,
        }
    }
}

impl MicSetup {
    pub const ALL: [MicSetup; 7] = [
        MicSetup::Pan,
        MicSetup::Xy,
        MicSetup::Blumlein,
        MicSetup::MidSide,
        MicSetup::Ab,
        MicSetup::Ortf,
        MicSetup::Decca,
    ];
}

const OMNI: f32 = 1.0;
const CARDIOID: f32 = 0.5;
const FIGURE_8: f32 = 0.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Capsule {
    /// Offset from the Listener, listener frame.
    pub offset: Vec3,
    /// Unit aim, listener frame.
    pub aim: Vec3,
    /// Polar pattern `a`.
    pub pattern: f32,
    /// Level into [left, right].
    pub mix: [f32; 2],
}

const NO_CAPSULE: Capsule = Capsule {
    offset: Vec3::new(0.0, 0.0, 0.0),
    aim: Vec3::new(0.0, 1.0, 0.0),
    pattern: OMNI,
    mix: [0.0, 0.0],
};

/// A unit aim `deg` degrees to the right of straight ahead.
fn aim_deg(deg: f32) -> Vec3 {
    let (s, c) = deg.to_radians().sin_cos();
    Vec3::new(s, c, 0.0)
}

fn cap(offset: [f32; 3], aim: Vec3, pattern: f32, mix: [f32; 2]) -> Capsule {
    Capsule {
        offset: Vec3::new(offset[0], offset[1], offset[2]),
        aim,
        pattern,
        mix,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MicArray {
    setup: MicSetup,
    capsules: [Capsule; MAX_CAPSULES],
    count: usize,
    /// Gain that puts a straight-ahead direction at `L² + R² = 1`.
    norm: f32,
}

impl MicArray {
    /// No allocation; cheap enough for the command thread's `set_room` under the lock.
    pub fn for_setup(setup: MicSetup) -> Self {
        let fwd = aim_deg(0.0);
        let mut capsules = [NO_CAPSULE; MAX_CAPSULES];
        let count = match setup {
            MicSetup::Pan => 0,
            MicSetup::Xy => {
                capsules[0] = cap([0.0; 3], aim_deg(-45.0), CARDIOID, [1.0, 0.0]);
                capsules[1] = cap([0.0; 3], aim_deg(45.0), CARDIOID, [0.0, 1.0]);
                2
            }
            MicSetup::Blumlein => {
                capsules[0] = cap([0.0; 3], aim_deg(-45.0), FIGURE_8, [1.0, 0.0]);
                capsules[1] = cap([0.0; 3], aim_deg(45.0), FIGURE_8, [0.0, 1.0]);
                2
            }
            MicSetup::MidSide => {
                // L = M + S, R = M - S: the side lobe points left.
                capsules[0] = cap([0.0; 3], fwd, CARDIOID, [1.0, 1.0]);
                capsules[1] = cap([0.0; 3], aim_deg(-90.0), FIGURE_8, [1.0, -1.0]);
                2
            }
            MicSetup::Ab => {
                capsules[0] = cap([-0.30, 0.0, 0.0], fwd, OMNI, [1.0, 0.0]);
                capsules[1] = cap([0.30, 0.0, 0.0], fwd, OMNI, [0.0, 1.0]);
                2
            }
            MicSetup::Ortf => {
                capsules[0] = cap([-0.085, 0.0, 0.0], aim_deg(-55.0), CARDIOID, [1.0, 0.0]);
                capsules[1] = cap([0.085, 0.0, 0.0], aim_deg(55.0), CARDIOID, [0.0, 1.0]);
                2
            }
            MicSetup::Decca => {
                capsules[0] = cap([-1.0, 0.0, 0.0], fwd, OMNI, [1.0, 0.0]);
                capsules[1] = cap([1.0, 0.0, 0.0], fwd, OMNI, [0.0, 1.0]);
                capsules[2] = cap([0.0, 1.5, 0.0], fwd, OMNI, [FRAC_1_SQRT_2, FRAC_1_SQRT_2]);
                3
            }
        };
        let mut array = Self {
            setup,
            capsules,
            count,
            norm: 1.0,
        };
        if count > 0 {
            let power = array.front_power();
            array.norm = if power > 1e-9 {
                1.0 / power.sqrt()
            } else {
                1.0
            };
        }
        array
    }

    pub fn setup(&self) -> MicSetup {
        self.setup
    }

    /// Capsules that are rendered (0 for Pan).
    pub fn capsule_count(&self) -> usize {
        self.count
    }

    /// Capsules at different places: every tap is read once per capsule.
    pub fn is_spaced(&self) -> bool {
        matches!(self.setup, MicSetup::Ab | MicSetup::Ortf | MicSetup::Decca)
    }

    /// Reads per tap: one for Pan and the coincident setups, one per capsule for spaced ones.
    pub fn reads(&self) -> usize {
        if self.is_spaced() {
            self.count
        } else {
            1
        }
    }

    fn pattern_at(&self, c: usize, dir: Vec3) -> f32 {
        let cap = &self.capsules[c];
        let cos = dir.x * cap.aim.x + dir.y * cap.aim.y + dir.z * cap.aim.z;
        cap.pattern + (1.0 - cap.pattern) * cos
    }

    /// Gains into [left, right] of one capsule for a unit direction, normalization included.
    pub fn capsule_gains(&self, c: usize, dir: Vec3) -> [f32; 2] {
        let p = self.pattern_at(c, dir) * self.norm;
        let mix = self.capsules[c].mix;
        [p * mix[0], p * mix[1]]
    }

    /// Gains into [left, right] of a coincident setup (or Pan) for a unit direction, written to
    /// `out`. Returns how far behind the listener the direction lies (0..1) for the high-frequency
    /// cut, as [`StereoPanner`] does.
    pub fn coincident_gains(&self, dir: Vec3, out: &mut [f32; 2]) -> f32 {
        if self.count == 0 {
            return StereoPanner.gains(dir, out);
        }
        *out = [0.0; 2];
        for c in 0..self.count {
            let g = self.capsule_gains(c, dir);
            out[0] += g[0];
            out[1] += g[1];
        }
        rear_amount(dir)
    }

    /// Where capsule `c` sits in room coordinates (X right, Y toward the back wall, Z up) for a
    /// Listener at `listener`. The array faces the front wall, so forward is -Y.
    pub fn capsule_position(&self, c: usize, listener: Vec3) -> Vec3 {
        let o = self.capsules[c].offset;
        Vec3::new(listener.x + o.x, listener.y - o.y, listener.z + o.z)
    }

    /// Capsule `c` clamped into the room.
    pub fn capsule_position_in(&self, c: usize, room: &RoomModel) -> Vec3 {
        room.clamp_point(self.capsule_position(c, room.listener))
    }

    /// `L² + R²` for a direction: coherent for coincident setups, power-summed over capsules for
    /// spaced ones. Pan is constant power.
    pub fn power_at(&self, dir: Vec3) -> f32 {
        if self.count == 0 {
            let mut g = [0.0; 2];
            StereoPanner.gains(dir, &mut g);
            return g[0] * g[0] + g[1] * g[1];
        }
        if self.is_spaced() {
            (0..self.count)
                .map(|c| {
                    let g = self.capsule_gains(c, dir);
                    g[0] * g[0] + g[1] * g[1]
                })
                .sum()
        } else {
            let mut g = [0.0; 2];
            self.coincident_gains(dir, &mut g);
            g[0] * g[0] + g[1] * g[1]
        }
    }

    /// `L² + R²` for a source straight ahead at `R_REF`, with the distance law applied from each
    /// capsule's own position (a spaced capsule nearer the source is louder). Coincident
    /// capsules add coherently, spaced ones in power. `norm` makes this 1.
    pub fn front_power(&self) -> f32 {
        if self.count == 0 {
            return self.power_at(Vec3::new(0.0, 1.0, 0.0));
        }
        let fwd = Vec3::new(0.0, 1.0, 0.0);
        let mut coherent = [0.0f32; 2];
        let mut power = 0.0;
        for c in 0..self.count {
            let o = self.capsules[c].offset;
            let r = Vec3::new(-o.x, R_REF - o.y, -o.z).length();
            let law = (R_REF / r.max(MIN_DISTANCE)).min(MAX_DIRECT_GAIN);
            let g = self.capsule_gains(c, fwd);
            let (l, r_) = (g[0] * law, g[1] * law);
            coherent[0] += l;
            coherent[1] += r_;
            power += l * l + r_ * r_;
        }
        if self.is_spaced() {
            power
        } else {
            coherent[0] * coherent[0] + coherent[1] * coherent[1]
        }
    }
}

/// How far behind the listener `dir` lies, 0 (front half) to 1 (straight behind).
pub fn rear_amount(dir: Vec3) -> f32 {
    (-dir.y).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir_deg(deg: f32) -> Vec3 {
        aim_deg(deg)
    }

    fn coincident(setup: MicSetup, dir: Vec3) -> ([f32; 2], f32) {
        let mut g = [0.0; 2];
        let rear = MicArray::for_setup(setup).coincident_gains(dir, &mut g);
        (g, rear)
    }

    #[test]
    fn mic_setup_from_osc_value() {
        for s in MicSetup::ALL {
            assert_eq!(MicSetup::from(s as i32), s);
        }
        assert_eq!(MicSetup::from(-1), MicSetup::Pan);
        assert_eq!(MicSetup::from(7), MicSetup::Pan);
        assert_eq!(MicSetup::from(99), MicSetup::Pan);
        assert_eq!(MicSetup::default(), MicSetup::Pan);
    }

    #[test]
    fn xy_follows_cardioids() {
        let norm = MicArray::for_setup(MicSetup::Xy).norm;
        let (g, _) = coincident(MicSetup::Xy, dir_deg(-45.0));
        assert!((g[0] - norm).abs() < 1e-5, "{g:?}");
        assert!((g[1] - 0.5 * norm).abs() < 1e-5, "{g:?}");
        let (g, _) = coincident(MicSetup::Xy, dir_deg(45.0));
        assert!((g[1] - norm).abs() < 1e-5 && (g[0] - 0.5 * norm).abs() < 1e-5);
    }

    #[test]
    fn blumlein_rear_swaps_sides() {
        // Behind on the right (135 deg): the left figure-8's rear lobe, inverted.
        let (g, _) = coincident(MicSetup::Blumlein, dir_deg(135.0));
        assert!((g[0] + 1.0).abs() < 1e-5, "{g:?}");
        assert!(g[1].abs() < 1e-5, "{g:?}");
        // And the mirror.
        let (g, _) = coincident(MicSetup::Blumlein, dir_deg(-135.0));
        assert!((g[1] + 1.0).abs() < 1e-5 && g[0].abs() < 1e-5, "{g:?}");
    }

    #[test]
    fn blumlein_sides_are_antiphase() {
        let (g, _) = coincident(MicSetup::Blumlein, dir_deg(90.0));
        assert!(g[0] < -0.1 && g[1] > 0.1, "{g:?}");
        assert!((g[0] + g[1]).abs() < 1e-5);
    }

    #[test]
    fn front_power_matches_pan() {
        for s in MicSetup::ALL {
            let p = MicArray::for_setup(s).front_power();
            assert!((p - 1.0).abs() < 1e-4, "{s:?}: {p}");
        }
    }

    #[test]
    fn mid_side_decodes_width() {
        // Source on the left: side adds to the left output, subtracts from the right.
        let (g, _) = coincident(MicSetup::MidSide, dir_deg(-90.0));
        assert!(g[0] > g[1]);
        let (g, _) = coincident(MicSetup::MidSide, dir_deg(90.0));
        assert!(g[1] > g[0]);
    }

    #[test]
    fn coincident_capsules_have_no_offset() {
        let listener = Vec3::new(10.0, 12.0, 1.5);
        for s in [
            MicSetup::Pan,
            MicSetup::Xy,
            MicSetup::Blumlein,
            MicSetup::MidSide,
        ] {
            let a = MicArray::for_setup(s);
            assert!(!a.is_spaced());
            assert_eq!(a.reads(), 1);
            for c in 0..a.capsule_count() {
                assert_eq!(a.capsule_position(c, listener), listener, "{s:?}");
            }
        }
        for s in [MicSetup::Ab, MicSetup::Ortf, MicSetup::Decca] {
            let a = MicArray::for_setup(s);
            assert!(a.is_spaced());
            assert_eq!(a.reads(), a.capsule_count());
        }
    }

    #[test]
    fn spaced_geometry() {
        let l = Vec3::new(10.0, 12.0, 1.5);
        let ab = MicArray::for_setup(MicSetup::Ab);
        let (a, b) = (ab.capsule_position(0, l), ab.capsule_position(1, l));
        assert!((b.x - a.x - 0.6).abs() < 1e-6);
        let ortf = MicArray::for_setup(MicSetup::Ortf);
        let (a, b) = (ortf.capsule_position(0, l), ortf.capsule_position(1, l));
        assert!((b.x - a.x - 0.17).abs() < 1e-6);
        let decca = MicArray::for_setup(MicSetup::Decca);
        let (a, b, c) = (
            decca.capsule_position(0, l),
            decca.capsule_position(1, l),
            decca.capsule_position(2, l),
        );
        assert!((b.x - a.x - 2.0).abs() < 1e-6);
        // Forward is toward the front wall, -Y.
        assert!((c.y - (l.y - 1.5)).abs() < 1e-6);
    }
}
