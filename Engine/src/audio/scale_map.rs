//! Scale changes along the timeline (spec 034): `(tick, mask)` pairs, held until the next
//! change. Tick-anchored like the tempo map (D1), not bar-anchored like the time signature map.
//! The base scale (before the first change) lives in `ProjectSettings.scale_mask` and is passed
//! to the lookups; the engine only ever sees masks, never root/type. Godot's `KeyChangeMap.gd`
//! sends the whole map on every edit (`/project/scale_map`).

use crate::audio::types::Tick;

/// Hard cap on map size (≈ 2 KB as OSC pairs, well under a UDP datagram). Excess pairs are
/// dropped when the map is built.
pub const MAX_CHANGES: usize = 256;

/// An empty map means "use the base project scale everywhere".
#[derive(Debug, Clone, Default)]
pub struct ScaleMap {
    /// Sorted by tick, ticks ≥ 1, masks already 12-bit.
    changes: Vec<(Tick, u16)>,
}

fn valid(tick: i64) -> bool {
    tick >= 1
}

impl ScaleMap {
    /// Sort by tick, clamp masks to 12 bits, drop `tick < 1` and keep the last of any duplicate
    /// tick. Kept pairs beyond `MAX_CHANGES` are dropped.
    pub fn from_changes(changes: Vec<(Tick, u16)>) -> Self {
        let mut kept: Vec<(Tick, u16)> = Vec::with_capacity(changes.len());
        for (tick, mask) in changes {
            let mask = mask & 0x0FFF;
            if !valid(tick) {
                continue;
            }
            match kept.binary_search_by(|c| c.0.cmp(&tick)) {
                Ok(i) => kept[i] = (tick, mask),
                Err(i) => kept.insert(i, (tick, mask)),
            }
        }
        kept.truncate(MAX_CHANGES);
        Self { changes: kept }
    }

    pub fn changes(&self) -> &[(Tick, u16)] {
        &self.changes
    }

    /// The scale mask in effect at `tick`: the last change at or before it, or `base_mask` before
    /// the first change (and everywhere for an empty map).
    pub fn mask_at(&self, tick: Tick, base_mask: u16) -> u16 {
        match self.changes.partition_point(|c| c.0 <= tick) {
            0 => base_mask,
            i => self.changes[i - 1].1,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.changes.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map() -> ScaleMap {
        ScaleMap::from_changes(vec![(3840, 2741), (7680, 0)])
    }

    #[test]
    fn masks_before_at_after_a_change() {
        let m = map();
        assert_eq!(m.mask_at(0, 2741), 2741);
        assert_eq!(m.mask_at(3839, 2741), 2741);
        assert_eq!(m.mask_at(3840, 2741), 2741);
        assert_eq!(m.mask_at(7679, 2741), 2741);
        assert_eq!(m.mask_at(7680, 2741), 0);
        assert_eq!(m.mask_at(100000, 2741), 0);
    }

    #[test]
    fn empty_map_uses_base_everywhere() {
        let m = ScaleMap::default();
        assert!(m.is_empty());
        assert_eq!(m.mask_at(5000, 2741), 2741);
    }

    #[test]
    fn mask_zero_change_is_kept() {
        let m = ScaleMap::from_changes(vec![(960, 0)]);
        assert_eq!(m.changes(), &[(960, 0)]);
        assert_eq!(m.mask_at(959, 2741), 2741);
        assert_eq!(m.mask_at(960, 2741), 0);
    }

    #[test]
    fn unsorted_input_is_sorted_and_duplicate_tick_keeps_last() {
        let m = ScaleMap::from_changes(vec![(7680, 1000), (3840, 500), (7680, 2000)]);
        assert_eq!(m.changes(), &[(3840, 500), (7680, 2000)]);
    }

    #[test]
    fn invalid_and_out_of_mask_entries_are_dropped_or_clamped() {
        let m = ScaleMap::from_changes(vec![
            (0, 500),      // tick 0 is the base scale: dropped
            (-5, 500),     // dropped
            (960, 0xFFFF), // clamped to 12 bits
        ]);
        assert_eq!(m.changes(), &[(960, 0x0FFF)]);
    }

    #[test]
    fn changes_are_capped() {
        let many: Vec<(Tick, u16)> = (1..=400).map(|t| (t * 960, 2741)).collect();
        let m = ScaleMap::from_changes(many);
        assert_eq!(m.changes().len(), MAX_CHANGES);
    }
}
