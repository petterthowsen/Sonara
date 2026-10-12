//! Scale table and snap for note effects (spec 027 REQ-015).
//!
//! The scale types mirror `MusicalScale.TYPES` in `Godot/data/MusicalScale.gd` (spec 038), minus
//! "None", in the same order with the same labels and intervals. The test
//! `catalogue_matches_godot` parses that file and fails when the two differ.

/// Scale type labels, in `MusicalScale.TYPES` order (without "None").
pub const SCALE_TYPE_LABELS: [&str; 47] = [
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
    "Dorian b2",
    "Lydian Augmented",
    "Lydian Dominant",
    "Mixolydian b6",
    "Half-Diminished",
    "Altered",
    "Locrian ♮6",
    "Ionian #5",
    "Ukrainian Dorian",
    "Phrygian Dominant",
    "Lydian #2",
    "Harmonic Major",
    "Double Harmonic",
    "Hungarian Minor",
    "Hungarian Major",
    "Neapolitan Major",
    "Neapolitan Minor",
    "Persian",
    "Enigmatic",
    "Whole Tone",
    "Diminished (Half-Whole)",
    "Diminished (Whole-Half)",
    "Augmented",
    "Bebop Dominant",
    "Bebop Major",
    "Bebop Dorian",
    "Major Blues",
    "Spanish 8-Tone",
    "Egyptian",
    "Yo",
    "Hirajoshi",
    "In Sen",
    "Iwato",
    "Kumoi",
    "Pelog",
];

/// Semitones above the root, per entry of [`SCALE_TYPE_LABELS`].
const SCALE_INTERVALS: [&[u8]; 47] = [
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
    &[0, 1, 3, 5, 7, 9, 10],
    &[0, 2, 4, 6, 8, 9, 11],
    &[0, 2, 4, 6, 7, 9, 10],
    &[0, 2, 4, 5, 7, 8, 10],
    &[0, 2, 3, 5, 6, 8, 10],
    &[0, 1, 3, 4, 6, 8, 10],
    &[0, 1, 3, 5, 6, 9, 10],
    &[0, 2, 4, 5, 8, 9, 11],
    &[0, 2, 3, 6, 7, 9, 10],
    &[0, 1, 4, 5, 7, 8, 10],
    &[0, 3, 4, 6, 7, 9, 11],
    &[0, 2, 4, 5, 7, 8, 11],
    &[0, 1, 4, 5, 7, 8, 11],
    &[0, 2, 3, 6, 7, 8, 11],
    &[0, 3, 4, 6, 7, 9, 10],
    &[0, 1, 3, 5, 7, 9, 11],
    &[0, 1, 3, 5, 7, 8, 11],
    &[0, 1, 4, 5, 6, 8, 11],
    &[0, 1, 4, 6, 8, 10, 11],
    &[0, 2, 4, 6, 8, 10],
    &[0, 1, 3, 4, 6, 7, 9, 10],
    &[0, 2, 3, 5, 6, 8, 9, 11],
    &[0, 3, 4, 7, 8, 11],
    &[0, 2, 4, 5, 7, 9, 10, 11],
    &[0, 2, 4, 5, 7, 8, 9, 11],
    &[0, 2, 3, 4, 5, 7, 9, 10],
    &[0, 2, 3, 4, 7, 9],
    &[0, 1, 3, 4, 5, 6, 8, 10],
    &[0, 2, 5, 7, 10],
    &[0, 2, 5, 7, 9],
    &[0, 2, 3, 7, 8],
    &[0, 1, 5, 7, 10],
    &[0, 1, 5, 6, 10],
    &[0, 2, 3, 7, 9],
    &[0, 1, 3, 7, 8],
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

    /// Index of `label` in the catalogue.
    fn index_of(label: &str) -> usize {
        SCALE_TYPE_LABELS.iter().position(|&l| l == label).unwrap()
    }

    fn mask_of(pcs: &[usize]) -> u16 {
        pcs.iter().fold(0u16, |m, &p| m | 1 << p)
    }

    #[test]
    fn new_scale_masks() {
        // C Lydian Dominant: C D E F# G A A#.
        assert_eq!(
            mask_for(0, index_of("Lydian Dominant")),
            mask_of(&[0, 2, 4, 6, 7, 9, 10])
        );
        // D Whole Tone: D E F# G# A# C.
        assert_eq!(
            mask_for(2, index_of("Whole Tone")),
            mask_of(&[2, 4, 6, 8, 10, 0])
        );
        // E Hirajoshi: E F# G B C.
        assert_eq!(
            mask_for(4, index_of("Hirajoshi")),
            mask_of(&[4, 6, 7, 11, 0])
        );
    }

    /// Entries of `TYPES` in the Godot catalogue as (label, intervals), "none" skipped.
    fn parse_godot_catalogue(src: &str) -> Vec<(String, Vec<u8>)> {
        let mut out = Vec::new();
        for line in src.lines() {
            let line = line.trim();
            if !line.starts_with("{\"id\":") {
                continue;
            }
            let label = line
                .split("\"label\": \"")
                .nth(1)
                .and_then(|r| r.split('"').next())
                .expect("label");
            let ivs = line
                .split("\"intervals\": [")
                .nth(1)
                .and_then(|r| r.split(']').next())
                .expect("intervals");
            if label == "None" {
                continue;
            }
            let ivs = ivs
                .split(',')
                .map(|s| s.trim().parse::<u8>().expect("interval"))
                .collect();
            out.push((label.to_string(), ivs));
        }
        out
    }

    #[test]
    fn catalogue_matches_godot() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../Godot/data/MusicalScale.gd");
        let src = std::fs::read_to_string(path).expect("read MusicalScale.gd");
        let godot = parse_godot_catalogue(&src);
        assert!(godot.len() >= 47, "parsed only {} entries", godot.len());
        assert_eq!(godot.len(), SCALE_TYPE_LABELS.len(), "entry count differs");
        for (i, (label, ivs)) in godot.iter().enumerate() {
            assert_eq!(label, SCALE_TYPE_LABELS[i], "label at index {i}");
            assert_eq!(ivs.as_slice(), SCALE_INTERVALS[i], "intervals of {label}");
        }
    }
}
