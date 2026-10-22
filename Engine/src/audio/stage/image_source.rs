//! Image-source taps for a shoebox room: the direct path, the 6 first-order reflections and the
//! 18 second-order reflections of one point source, heard at the listener.
//!
//! Pure functions, no state: `StageSource` recomputes a [`TapSet`] each block from its smoothed
//! position and ramps between sets.

use super::{RoomModel, Surface, Vec3, MAX_DIRECT_GAIN, MIN_DISTANCE, R_REF, SPEED_OF_SOUND};

pub const FIRST_ORDER_TAPS: usize = 6;
pub const SECOND_ORDER_TAPS: usize = 18;

/// One path from the source to the listener.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Tap {
    /// Arrival time in seconds. With Distance delay off the direct tap is at 0 and a reflection's
    /// delay is how far it lags the direct sound; with it on, both include the flight time.
    pub delay_s: f32,
    /// Level: `R_REF / path` times the surface gains (the direct tap is capped at +6 dB).
    pub gain: f32,
    /// First-order taps: the surface they bounce off. `None` for the direct and second-order taps.
    pub surface: Option<Surface>,
    /// High-frequency damping of the bounces, 0 = bright, 1 = dull. Second-order taps combine
    /// both surfaces.
    pub damping: f32,
    /// Unit vector from the listener to the (image) source, in the listener's frame: X right,
    /// Y forward (toward the front wall), Z up.
    pub dir: Vec3,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TapSet {
    pub direct: Tap,
    pub first: [Tap; FIRST_ORDER_TAPS],
    pub second: [Tap; SECOND_ORDER_TAPS],
}

impl TapSet {
    /// Average second-order arrival, which the tail's pre-delay follows.
    pub fn mean_second_order_delay_s(&self) -> f32 {
        self.second.iter().map(|t| t.delay_s).sum::<f32>() / SECOND_ORDER_TAPS as f32
    }
}

/// Image position along one axis of extent `len` for image index `m`: even indices keep the
/// source's side (`x + m·len`), odd ones mirror it (`-x + (m + 1)·len`). Index -1 is the wall at
/// 0, +1 the wall at `len`, ±2 the two-wall bounce.
fn image_1d(x: f32, len: f32, m: i32) -> f32 {
    if m % 2 == 0 {
        x + m as f32 * len
    } else {
        -x + (m + 1) as f32 * len
    }
}

/// The surface pair an axis' image index bounces off: (axis, index) -> the surfaces crossed.
fn surfaces_crossed(axis: usize, m: i32, out: &mut [Surface; 2], n: &mut usize) {
    let (lo, hi) = match axis {
        0 => (Surface::Left, Surface::Right),
        1 => (Surface::Front, Surface::Back),
        _ => (Surface::Floor, Surface::Ceiling),
    };
    match m {
        -1 => {
            out[*n] = lo;
            *n += 1;
        }
        1 => {
            out[*n] = hi;
            *n += 1;
        }
        // Two bounces along one axis cross both of its walls.
        -2 | 2 => {
            out[*n] = lo;
            out[*n + 1] = hi;
            *n += 2;
        }
        _ => {}
    }
}

fn base_delay_s(direct_r: f32, distance_delay: bool) -> f32 {
    if distance_delay {
        direct_r / SPEED_OF_SOUND
    } else {
        0.0
    }
}

/// Only the direct path of [`taps`].
pub fn direct_tap(point: Vec3, listener: Vec3, distance_delay: bool) -> Tap {
    let r = distance(point, listener);
    Tap {
        delay_s: base_delay_s(r, distance_delay),
        gain: (R_REF / r.max(MIN_DISTANCE)).min(MAX_DIRECT_GAIN),
        surface: None,
        damping: 0.0,
        dir: direction(point, listener),
    }
}

/// Taps for a point source at `point` heard from `room.listener`. `distance_delay` adds the
/// direct path's flight time to every tap (otherwise only the reflections' extra path counts).
pub fn taps(room: &RoomModel, point: Vec3, listener: Vec3, distance_delay: bool) -> TapSet {
    let dims = [room.width, room.depth, room.height];
    let src = [point.x, point.y, point.z];
    let direct_r = distance(point, listener);
    let base_delay = base_delay_s(direct_r, distance_delay);

    let mut set = TapSet::default();
    set.direct = direct_tap(point, listener, distance_delay);

    let make = |idx: [i32; 3], first: Option<Surface>| -> Tap {
        let image = Vec3::new(
            image_1d(src[0], dims[0], idx[0]),
            image_1d(src[1], dims[1], idx[1]),
            image_1d(src[2], dims[2], idx[2]),
        );
        let r = distance(image, listener);
        let mut crossed = [Surface::Front; 2];
        let mut n = 0;
        for axis in 0..3 {
            surfaces_crossed(axis, idx[axis], &mut crossed, &mut n);
        }
        // Second-order images cross exactly two surfaces (one axis twice, or two axes once).
        let mut gain = R_REF / r.max(MIN_DISTANCE);
        let mut bright = 1.0;
        for s in &crossed[..n] {
            let m = room.surfaces[*s as usize];
            gain *= m.gain;
            bright *= 1.0 - m.hf_damping;
        }
        Tap {
            delay_s: base_delay + (r - direct_r).max(0.0) / SPEED_OF_SOUND,
            gain,
            surface: first,
            damping: 1.0 - bright,
            dir: direction(image, listener),
        }
    };

    // First order: one axis at ±1.
    let mut k = 0;
    for axis in 0..3 {
        for m in [-1, 1] {
            let mut idx = [0; 3];
            idx[axis] = m;
            let surface = match (axis, m) {
                (0, -1) => Surface::Left,
                (0, _) => Surface::Right,
                (1, -1) => Surface::Front,
                (1, _) => Surface::Back,
                (_, -1) => Surface::Floor,
                _ => Surface::Ceiling,
            };
            set.first[k] = make(idx, Some(surface));
            k += 1;
        }
    }

    // Second order: one axis at ±2 (6 images), or two axes at ±1 each (12 images).
    let mut k = 0;
    for axis in 0..3 {
        for m in [-2, 2] {
            let mut idx = [0; 3];
            idx[axis] = m;
            set.second[k] = make(idx, None);
            k += 1;
        }
    }
    for (a, b) in [(0, 1), (0, 2), (1, 2)] {
        for ma in [-1, 1] {
            for mb in [-1, 1] {
                let mut idx = [0; 3];
                idx[a] = ma;
                idx[b] = mb;
                set.second[k] = make(idx, None);
                k += 1;
            }
        }
    }
    set
}

pub fn distance(a: Vec3, b: Vec3) -> f32 {
    Vec3::new(a.x - b.x, a.y - b.y, a.z - b.z).length()
}

/// Unit vector from `listener` to `p` in the listener's frame (the listener faces the front
/// wall, so forward is -Y in room coordinates). Straight ahead when they coincide.
fn direction(p: Vec3, listener: Vec3) -> Vec3 {
    let v = Vec3::new(p.x - listener.x, -(p.y - listener.y), p.z - listener.z);
    let len = v.length();
    if len < 1e-4 {
        Vec3::new(0.0, 1.0, 0.0)
    } else {
        Vec3::new(v.x / len, v.y / len, v.z / len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn room() -> RoomModel {
        RoomModel {
            width: 20.0,
            depth: 25.0,
            height: 10.0,
            listener: Vec3::new(10.0, 18.0, 1.5),
            ..RoomModel::default()
        }
    }

    fn first_delay(set: &TapSet, surface: Surface) -> f32 {
        set.first
            .iter()
            .find(|t| t.surface == Some(surface))
            .unwrap()
            .delay_s
    }

    #[test]
    fn first_reflection_earlier_near_wall() {
        let r = room();
        let near = taps(&r, Vec3::new(1.0, 8.0, 1.5), r.listener, false);
        let centre = taps(&r, Vec3::new(10.0, 8.0, 1.5), r.listener, false);
        let earliest = |s: &TapSet| s.first.iter().map(|t| t.delay_s).fold(f32::MAX, f32::min);
        assert!(earliest(&near) < earliest(&centre));
        assert!(first_delay(&near, Surface::Left) < first_delay(&centre, Surface::Left));
        // With the flight time included the near-wall reflection also arrives earlier overall.
        let near_abs = taps(&r, Vec3::new(1.0, 8.0, 1.5), r.listener, true);
        let centre_abs = taps(&r, Vec3::new(10.0, 8.0, 1.5), r.listener, true);
        assert!(first_delay(&near_abs, Surface::Left) < first_delay(&centre_abs, Surface::Left));
    }

    #[test]
    fn height_changes_floor_ceiling_taps() {
        let r = room();
        let low = taps(&r, Vec3::new(10.0, 8.0, 1.0), r.listener, false);
        let high = taps(&r, Vec3::new(10.0, 8.0, 6.0), r.listener, false);
        // Higher source: nearer the ceiling, farther from the floor.
        assert!(first_delay(&high, Surface::Floor) > first_delay(&low, Surface::Floor));
        assert!(first_delay(&high, Surface::Ceiling) < first_delay(&low, Surface::Ceiling));
        // The walls are far less affected by height than the floor and ceiling are.
        let floor_shift = first_delay(&high, Surface::Floor) - first_delay(&low, Surface::Floor);
        let wall_shift =
            (first_delay(&high, Surface::Left) - first_delay(&low, Surface::Left)).abs();
        assert!(floor_shift.abs() > wall_shift);
    }

    #[test]
    fn distance_delay_off_keeps_relative_tap_delays() {
        let r = room();
        // 17 m from the listener.
        let p = Vec3::new(10.0, 1.0, 1.5);
        let off = taps(&r, p, r.listener, false);
        let on = taps(&r, p, r.listener, true);
        assert_eq!(off.direct.delay_s, 0.0);
        assert!((on.direct.delay_s - 17.0 / SPEED_OF_SOUND).abs() < 1e-4);
        assert!((on.direct.delay_s - 0.0496).abs() < 1e-3);
        for (a, b) in off
            .first
            .iter()
            .zip(&on.first)
            .chain(off.second.iter().zip(&on.second))
        {
            assert!(a.delay_s >= 0.0);
            let lag_off = a.delay_s - off.direct.delay_s;
            let lag_on = b.delay_s - on.direct.delay_s;
            assert!((lag_off - lag_on).abs() < 1e-6);
        }
    }

    #[test]
    fn tap_counts_and_levels() {
        let r = room();
        let set = taps(&r, Vec3::new(10.0, 8.0, 1.5), r.listener, false);
        assert_eq!(set.first.len(), 6);
        assert_eq!(set.second.len(), 18);
        // Every first-order surface appears once.
        for s in Surface::ALL {
            assert_eq!(set.first.iter().filter(|t| t.surface == Some(s)).count(), 1);
        }
        // Reflections are quieter than the direct sound.
        assert!(set.first.iter().all(|t| t.gain < set.direct.gain));
        assert!(set
            .second
            .iter()
            .all(|t| t.damping >= 0.0 && t.delay_s > 0.0));
    }

    #[test]
    fn direct_gain_follows_distance_and_caps() {
        let r = room();
        let at = |y: f32| {
            taps(&r, Vec3::new(10.0, y, 1.5), r.listener, false)
                .direct
                .gain
        };
        // 5 m is unity, 10 m is half, and very close is capped at +6 dB.
        assert!((at(13.0) - 1.0).abs() < 1e-5);
        assert!((at(8.0) - 0.5).abs() < 1e-5);
        assert!((at(17.9) - MAX_DIRECT_GAIN).abs() < 1e-5);
    }

    #[test]
    fn direction_is_in_the_listener_frame() {
        let r = room();
        // Left of and in front of the listener (toward the front wall).
        let d = taps(&r, Vec3::new(5.0, 8.0, 1.5), r.listener, false)
            .direct
            .dir;
        assert!(d.x < 0.0 && d.y > 0.0);
        assert!((d.length() - 1.0).abs() < 1e-5);
        // Behind the listener.
        let behind = taps(&r, Vec3::new(10.0, 22.0, 1.5), r.listener, false)
            .direct
            .dir;
        assert!(behind.y < 0.0);
    }
}
