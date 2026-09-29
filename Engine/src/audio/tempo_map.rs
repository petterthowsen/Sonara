//! Tempo automation: BPM points over time, linear in ticks between points and held outside them.
//!
//! The engine gets the whole map from Godot and replaces it on every change. Seconds come from the
//! closed-form integral of a linear ramp, so the same maths as Godot's `TempoMap.gd` applies.

use super::types::{ProjectSettings, Tick};

pub const MIN_BPM: f64 = 20.0;
pub const MAX_BPM: f64 = 999.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TempoPoint {
    pub tick: Tick,
    pub bpm: f64,
}

/// An empty map means "use the static project tempo".
#[derive(Debug, Clone, Default)]
pub struct TempoMap {
    points: Vec<TempoPoint>,
    /// Cumulative seconds × ppq at each point, so it doesn't depend on ppq.
    seconds_ppq: Vec<f64>,
}

/// Seconds × ppq for `len` ticks going from `b0` to `b1` BPM linearly in ticks.
fn segment_seconds_ppq(len: f64, b0: f64, b1: f64) -> f64 {
    if (b1 - b0).abs() < 1e-9 {
        60.0 * len / b0
    } else {
        60.0 * len / (b1 - b0) * (b1 / b0).ln()
    }
}

impl TempoMap {
    /// Build a map from `(tick, bpm)` pairs in any order. BPM is clamped to 20–999 and a point
    /// repeated on a tick keeps the last value.
    pub fn from_points(raw: Vec<(Tick, f32)>) -> Self {
        let mut points: Vec<TempoPoint> = raw
            .into_iter()
            .map(|(tick, bpm)| TempoPoint {
                tick: tick.max(0),
                bpm: (bpm as f64).clamp(MIN_BPM, MAX_BPM),
            })
            .collect();
        points.sort_by_key(|p| p.tick); // stable: later duplicates stay later
        let mut deduped: Vec<TempoPoint> = Vec::with_capacity(points.len());
        for p in points {
            match deduped.last_mut() {
                Some(last) if last.tick == p.tick => *last = p,
                _ => deduped.push(p),
            }
        }
        let mut seconds_ppq = Vec::with_capacity(deduped.len());
        for (i, p) in deduped.iter().enumerate() {
            if i == 0 {
                seconds_ppq.push(60.0 * p.tick as f64 / p.bpm);
            } else {
                let prev = deduped[i - 1];
                seconds_ppq.push(
                    seconds_ppq[i - 1]
                        + segment_seconds_ppq((p.tick - prev.tick) as f64, prev.bpm, p.bpm),
                );
            }
        }
        Self {
            points: deduped,
            seconds_ppq,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    pub fn points(&self) -> &[TempoPoint] {
        &self.points
    }

    /// Number of points at or before `tick`.
    fn upper_index(&self, tick: f64) -> usize {
        self.points.partition_point(|p| p.tick as f64 <= tick)
    }

    fn bpm_with_index(&self, upper: usize, tick: f64) -> f64 {
        if upper == 0 {
            return self.points[0].bpm;
        }
        if upper == self.points.len() {
            return self.points[upper - 1].bpm;
        }
        let (l, r) = (self.points[upper - 1], self.points[upper]);
        let t = (tick - l.tick as f64) / (r.tick - l.tick) as f64;
        l.bpm + (r.bpm - l.bpm) * t
    }

    fn slope_with_index(&self, upper: usize) -> f64 {
        if upper == 0 || upper == self.points.len() {
            return 0.0;
        }
        let (l, r) = (self.points[upper - 1], self.points[upper]);
        (r.bpm - l.bpm) / (r.tick - l.tick) as f64
    }

    /// Tempo at a fractional tick. `fallback` applies when the map is empty.
    pub fn bpm_at(&self, tick: f64, fallback: f64) -> f64 {
        if self.points.is_empty() {
            return fallback;
        }
        self.bpm_with_index(self.upper_index(tick), tick)
    }

    /// BPM change per tick at `tick` (0 outside the points and when empty).
    pub fn slope_bpm_per_tick_at(&self, tick: f64) -> f64 {
        if self.points.is_empty() {
            return 0.0;
        }
        self.slope_with_index(self.upper_index(tick))
    }

    /// Seconds elapsed from tick 0 to `tick`.
    pub fn seconds_at(&self, tick: f64, fallback: f64, ppq: f64) -> f64 {
        if self.points.is_empty() {
            return 60.0 * tick / (fallback * ppq);
        }
        let upper = self.upper_index(tick);
        let sp = if upper == 0 {
            return 60.0 * tick / (self.points[0].bpm * ppq);
        } else {
            let base = self.seconds_ppq[upper - 1];
            let p = self.points[upper - 1];
            let len = tick - p.tick as f64;
            if upper == self.points.len() {
                base + 60.0 * len / p.bpm
            } else {
                let b = self.bpm_with_index(upper, tick);
                base + segment_seconds_ppq(len, p.bpm, b)
            }
        };
        sp / ppq
    }
}

/// Forward-only walk of a map, so a buffer costs one binary search and O(1) per frame.
pub struct TempoCursor<'a> {
    map: &'a TempoMap,
    upper: usize,
}

impl<'a> TempoCursor<'a> {
    pub fn new(map: &'a TempoMap, tick: f64) -> Self {
        let upper = if map.is_empty() {
            0
        } else {
            map.upper_index(tick)
        };
        Self { map, upper }
    }

    /// Tempo at `tick`, which must not be before the previous call's tick.
    pub fn bpm_at(&mut self, tick: f64, fallback: f64) -> f64 {
        if self.map.points.is_empty() {
            return fallback;
        }
        while self.upper < self.map.points.len() && self.map.points[self.upper].tick as f64 <= tick
        {
            self.upper += 1;
        }
        self.map.bpm_with_index(self.upper, tick)
    }
}

/// Fill `out` with ticks-per-sample for each of `frames` frames, starting at fractional tick
/// `start_pos`. Never allocates while `frames` fits the vector's capacity.
pub fn fill_tick_rates(
    map: &TempoMap,
    settings: &ProjectSettings,
    start_pos: f64,
    frames: usize,
    sample_rate: f32,
    out: &mut Vec<f64>,
) {
    out.clear();
    let ppq = settings.ppq as f64;
    let sr = sample_rate as f64;
    let fallback = settings.tempo as f64;
    if map.is_empty() {
        let rate = fallback * ppq / (60.0 * sr);
        out.extend(std::iter::repeat(rate).take(frames));
        return;
    }
    let mut cursor = TempoCursor::new(map, start_pos);
    let mut pos = start_pos;
    for _ in 0..frames {
        let rate = cursor.bpm_at(pos, fallback) * ppq / (60.0 * sr);
        out.push(rate);
        pos += rate;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ramp_down() -> TempoMap {
        TempoMap::from_points(vec![(0, 120.0), (3840, 60.0)])
    }

    #[test]
    fn empty_map_uses_fallback() {
        let mut out = Vec::new();
        fill_tick_rates(
            &TempoMap::default(),
            &ProjectSettings::default(),
            0.0,
            4,
            48_000.0,
            &mut out,
        );
        assert_eq!(out, vec![0.04; 4]);
    }

    #[test]
    fn points_are_sorted_clamped_and_deduped() {
        let map = TempoMap::from_points(vec![(960, 5000.0), (0, 100.0), (960, 90.0)]);
        assert_eq!(map.points().len(), 2);
        assert_eq!(map.points()[0].tick, 0);
        assert_eq!(map.points()[1].bpm, 90.0);
    }

    #[test]
    fn seconds_through_ramp() {
        let map = ramp_down();
        let at_end = map.seconds_at(3840.0, 120.0, 960.0);
        assert!((at_end - 4.0 * 2f64.ln()).abs() < 1e-9);
        let later = map.seconds_at(4800.0, 120.0, 960.0);
        assert!((later - at_end - 1.0).abs() < 1e-9);
        // Held before a late first point
        let late = TempoMap::from_points(vec![(960, 60.0)]);
        assert!((late.seconds_at(480.0, 120.0, 960.0) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn rates_are_continuous_across_buffers() {
        let map = ramp_down();
        let settings = ProjectSettings::default();
        let mut whole = Vec::new();
        fill_tick_rates(&map, &settings, 0.0, 512, 48_000.0, &mut whole);
        let mut a = Vec::new();
        fill_tick_rates(&map, &settings, 0.0, 256, 48_000.0, &mut a);
        let pos: f64 = a.iter().sum();
        let mut b = Vec::new();
        fill_tick_rates(&map, &settings, pos, 256, 48_000.0, &mut b);
        for (x, y) in whole[256..].iter().zip(&b) {
            assert!((x - y).abs() < 1e-12);
        }
    }

    #[test]
    fn cursor_matches_binary_search() {
        let map = TempoMap::from_points(vec![(100, 80.0), (500, 160.0), (900, 100.0)]);
        let mut cursor = TempoCursor::new(&map, 0.0);
        let mut t = 0.0;
        while t < 1200.0 {
            assert!((cursor.bpm_at(t, 120.0) - map.bpm_at(t, 120.0)).abs() < 1e-9);
            t += 7.3;
        }
    }

    #[test]
    fn slope_is_zero_outside_points() {
        let map = ramp_down();
        assert!((map.slope_bpm_per_tick_at(10.0) + 60.0 / 3840.0).abs() < 1e-12);
        assert_eq!(map.slope_bpm_per_tick_at(4000.0), 0.0);
    }
}
