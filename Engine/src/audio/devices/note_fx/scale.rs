//! Scale table and snap for note effects (spec 027 REQ-015).
//!
//! The scale types mirror `MusicalScale.TYPES` in `Godot/data/MusicalScale.gd`, minus "None",
//! in the same order and with the same labels. Keep the two in step:
//! `Godot/tests/test_project_scale_sync.gd` checks the labels.

/// Scale type labels, in `MusicalScale.TYPES` order (without "None").
pub const SCALE_TYPE_LABELS: [&str; 12] = [
    "Major",
    "Natural Minor",
    "Harmonic Minor",
    "Melodic Minor",
    "Dorian",
    "Phrygian",
    "Lydian",
    "Mixolydian",
    "Locrian",
    "Major Pentatonic",
    "Minor Pentatonic",
    "Blues",
];

/// Semitones above the root, per entry of [`SCALE_TYPE_LABELS`].
const SCALE_INTERVALS: [&[u8]; 12] = [
    &[0, 2, 4, 5, 7, 9, 11],
    &[0, 2, 3, 5, 7, 8, 10],
    &[0, 2, 3, 5, 7, 8, 11],
    &[0, 2, 3, 5, 7, 9, 11],
    &[0, 2, 3, 5, 7, 9, 10],
    &[0, 1, 3, 5, 7, 8, 10],
    &[0, 2, 4, 6, 7, 9, 11],
    &[0, 2, 4, 5, 7, 9, 10],
    &[0, 1, 3, 5, 6, 8, 10],
    &[0, 2, 4, 7, 9],
    &[0, 3, 5, 7, 10],
    &[0, 3, 5, 6, 7, 10],
];

/// Pitch-class names for a Root parameter, C first.
pub const ROOT_LABELS: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];

/// 12-bit pitch-class mask (bit 0 = C) of scale type `type_index` on `root` (0 = C).
pub fn mask_for(root: usize, type_index: usize) -> u16 {
    let Some(intervals) = SCALE_INTERVALS.get(type_index) else {
        return 0;
    };
    intervals
        .iter()
        .fold(0, |mask, &iv| mask | 1 << ((root + iv as usize) % 12))
}

/// The in-scale pitch nearest `key`, searching outward (0, −1, +1, −2, +2, …) so a tie goes
/// down. A mask of 0 (no scale) leaves the key alone.
pub fn snap(key: i32, mask: u16) -> i32 {
    let mask = mask & 0x0FFF;
    if mask == 0 {
        return key;
    }
    let in_scale = |k: i32| mask & (1 << k.rem_euclid(12)) != 0;
    for distance in 0..=6 {
        if in_scale(key - distance) {
            return key - distance;
        }
        if in_scale(key + distance) {
            return key + distance;
        }
    }
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_major_mask_and_d_minor_mask() {
        assert_eq!(mask_for(0, 0), 2741);
        // D natural minor: D E F G A A# C.
        let d_minor = mask_for(2, 1);
        let expected = [2, 4, 5, 7, 9, 10, 0].iter().fold(0u16, |m, &p| m | 1 << p);
        assert_eq!(d_minor, expected);
        assert_eq!(mask_for(0, 99), 0);
    }

    #[test]
    fn snap_goes_to_nearest_and_ties_down() {
        let c_major = mask_for(0, 0);
        assert_eq!(snap(61, c_major), 60);
        assert_eq!(snap(66, c_major), 65);
        assert_eq!(snap(64, c_major), 64);
        assert_eq!(snap(61, 0), 61);
        // C minor pentatonic (C D# F G A#): C# is nearer C, D nearer D#, and E is a tie
        // between D# and F that goes down.
        let pent = mask_for(0, 10);
        assert_eq!(snap(1, pent), 0);
        assert_eq!(snap(2, pent), 3);
        assert_eq!(snap(4, pent), 3);
        assert_eq!(snap(-1, c_major), -1, "B below 0 is in the scale");
    }
}
