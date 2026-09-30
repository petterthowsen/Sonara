//! The tempo-sync choice list shared by every built-in with a synced rate or time (PolySynth
//! LFOs, Delay, Chorus, Phaser, Filter).
//!
//! Entry 0 is "Off" (the device uses its free Hz or ms value). After that come the divisions
//! from 4/1 to 1/32, each straight, dotted (".") and triplet ("T").

/// Choices for a Sync enum parameter, in order.
pub const SYNC_CHOICES: &[&str] = &[
    "Off", "4/1", "4/1.", "4/1T", "2/1", "2/1.", "2/1T", "1/1", "1/1.", "1/1T", "1/2", "1/2.",
    "1/2T", "1/4", "1/4.", "1/4T", "1/8", "1/8.", "1/8T", "1/16", "1/16.", "1/16T", "1/32",
    "1/32.", "1/32T",
];

/// Straight division lengths in quarter-note beats, in `SYNC_CHOICES` order.
const DIVISIONS: [f64; 8] = [16.0, 8.0, 4.0, 2.0, 1.0, 0.5, 0.25, 0.125];

/// Choice index of a straight, dotted or triplet division, for defaults: `index_of("1/8.")`.
pub const fn index_of(choice: &str) -> usize {
    let mut i = 0;
    while i < SYNC_CHOICES.len() {
        if str_eq(SYNC_CHOICES[i], choice) {
            return i;
        }
        i += 1;
    }
    panic!("tempo_sync::index_of: no such choice");
}

const fn str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// Length of choice `index` in quarter-note beats, or None for "Off" (and out-of-range indices).
pub fn sync_beats(index: usize) -> Option<f64> {
    if index == 0 || index >= SYNC_CHOICES.len() {
        return None;
    }
    let division = DIVISIONS[(index - 1) / 3];
    Some(match (index - 1) % 3 {
        0 => division,
        1 => division * 1.5,
        _ => division * 2.0 / 3.0,
    })
}

/// Length of choice `index` in seconds at `bpm`, or None for "Off".
pub fn division_seconds(index: usize, bpm: f64) -> Option<f64> {
    sync_beats(index).map(|beats| beats * 60.0 / bpm.max(1.0))
}

/// Rate in Hz of one cycle per `beats` quarter notes at `bpm`.
pub fn beats_to_hz(beats: f64, bpm: f64) -> f64 {
    bpm / 60.0 / beats
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn divisions_straight_dotted_triplet() {
        assert_eq!(sync_beats(0), None);
        assert_eq!(sync_beats(index_of("1/4")), Some(1.0));
        assert_eq!(sync_beats(index_of("1/4.")), Some(1.5));
        assert!((sync_beats(index_of("1/4T")).unwrap() - 2.0 / 3.0).abs() < 1e-12);
        assert_eq!(sync_beats(index_of("4/1")), Some(16.0));
        assert_eq!(sync_beats(index_of("1/32")), Some(0.125));
        assert_eq!(sync_beats(SYNC_CHOICES.len()), None);
    }

    #[test]
    fn seconds_at_120_bpm() {
        // A quarter note at 120 BPM is 0.5 s; a dotted eighth is 0.375 s.
        assert_eq!(division_seconds(index_of("1/4"), 120.0), Some(0.5));
        assert_eq!(division_seconds(index_of("1/8."), 120.0), Some(0.375));
        assert_eq!(beats_to_hz(1.0, 120.0), 2.0);
    }
}
