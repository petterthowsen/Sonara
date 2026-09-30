//! Time signature changes: `(bar, numerator, denominator)` with 1-based bars, held until the next
//! change. The base signature (before the first change) lives in `ProjectSettings` and is passed
//! to the lookups, as the tempo map takes the static tempo. Godot's `TimeSignatureMap.gd` walks
//! the changes the same way.

pub const MAX_NUMERATOR: u16 = 32;

/// A bar-aligned stretch of constant signature.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SignatureSegment {
    /// 0-based bar index of the bar containing the tick.
    pub bar_index: u32,
    /// Start tick of that bar.
    pub bar_start_tick: f64,
    pub numerator: u16,
    pub denominator: u16,
}

/// An empty map means "use the static project signature".
#[derive(Debug, Clone, Default)]
pub struct TimeSignatureMap {
    changes: Vec<(u32, u16, u16)>,
}

fn valid(bar: u32, num: u16, den: u16) -> bool {
    bar >= 2 && (1..=MAX_NUMERATOR).contains(&num) && matches!(den, 1 | 2 | 4 | 8 | 16 | 32)
}

fn bar_ticks(num: u16, den: u16, ppq: f64) -> f64 {
    ppq * 4.0 * num as f64 / den as f64
}

impl TimeSignatureMap {
    /// Sort by bar, drop invalid entries, and keep the last of any duplicate bar.
    pub fn from_changes(changes: Vec<(u32, u16, u16)>) -> Self {
        let mut kept: Vec<(u32, u16, u16)> = Vec::with_capacity(changes.len());
        for (bar, num, den) in changes {
            if !valid(bar, num, den) {
                continue;
            }
            match kept.iter_mut().find(|c| c.0 == bar) {
                Some(existing) => *existing = (bar, num, den),
                None => kept.push((bar, num, den)),
            }
        }
        kept.sort_by_key(|c| c.0);
        Self { changes: kept }
    }

    pub fn changes(&self) -> &[(u32, u16, u16)] {
        &self.changes
    }

    /// The bar containing `tick` (clamped to 0) and the signature in effect there.
    pub fn segment_at(
        &self,
        tick: f64,
        base_num: u16,
        base_den: u16,
        ppq: f64,
    ) -> SignatureSegment {
        let tick = tick.max(0.0);
        let mut seg_bar = 0u32;
        let mut seg_start = 0.0;
        let (mut num, mut den) = (base_num.max(1), base_den.max(1));
        for &(bar, n, d) in &self.changes {
            let len = bar_ticks(num, den, ppq);
            let change_bar = bar - 1;
            let change_tick = seg_start + (change_bar - seg_bar) as f64 * len;
            if tick < change_tick {
                break;
            }
            seg_bar = change_bar;
            seg_start = change_tick;
            num = n;
            den = d;
        }
        let len = bar_ticks(num, den, ppq);
        let bars_in = ((tick - seg_start) / len).floor().max(0.0);
        SignatureSegment {
            bar_index: seg_bar + bars_in as u32,
            bar_start_tick: seg_start + bars_in * len,
            numerator: num,
            denominator: den,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map() -> TimeSignatureMap {
        TimeSignatureMap::from_changes(vec![(3, 7, 8)])
    }

    #[test]
    fn segments_around_change() {
        let m = map();
        let a = m.segment_at(7679.0, 4, 4, 960.0);
        assert_eq!((a.bar_index, a.numerator, a.denominator), (1, 4, 4));
        assert_eq!(a.bar_start_tick, 3840.0);
        let b = m.segment_at(7680.0, 4, 4, 960.0);
        assert_eq!((b.bar_index, b.numerator, b.denominator), (2, 7, 8));
        assert_eq!(b.bar_start_tick, 7680.0);
        let c = m.segment_at(11040.0, 4, 4, 960.0);
        assert_eq!((c.bar_index, c.bar_start_tick), (3, 11040.0));
    }

    #[test]
    fn empty_map_uses_base() {
        let s = TimeSignatureMap::default().segment_at(5000.0, 3, 4, 960.0);
        assert_eq!((s.bar_index, s.bar_start_tick), (1, 2880.0));
        assert_eq!((s.numerator, s.denominator), (3, 4));
    }

    #[test]
    fn invalid_entries_dropped_and_sorted() {
        let m = TimeSignatureMap::from_changes(vec![
            (5, 3, 4),
            (1, 3, 4),
            (3, 0, 4),
            (4, 4, 3),
            (3, 7, 8),
            (5, 6, 8),
            (6, 33, 4),
        ]);
        assert_eq!(m.changes(), &[(3, 7, 8), (5, 6, 8)]);
    }
}
