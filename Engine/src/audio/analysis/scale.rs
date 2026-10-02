//! The fixed 0–9 scale the Godot formatter applies to analysis values. Defined here so the
//! engine tests pin it. Bump `SCALE_VERSION` whenever a constant changes, so stored results
//! and the formatter can tell which scale they were made with.

pub const SCALE_VERSION: u32 = 1;

/// Level of digit 0. Each digit is `DIGIT_STEP_DB` louder, so 9 sits at -6.
pub const DIGIT_FLOOR_DB: f32 = -33.0;
pub const DIGIT_STEP_DB: f32 = 3.0;

/// Values at or below this are silence (shown as `.`). It is the BS.1770 absolute gate, and
/// also the floor the analyzer reports for an empty bar.
pub const SILENCE_DB: f32 = -70.0;
pub const FLOOR_DB: f32 = -120.0;

/// Offset between mean square and LUFS.
pub const LUFS_OFFSET_DB: f64 = -0.691;

/// Digit for a loudness or band level in dB, or `None` for silence.
pub fn level_digit(db: f32) -> Option<u8> {
    if !db.is_finite() || db <= SILENCE_DB {
        return None;
    }
    Some((((db - DIGIT_FLOOR_DB) / DIGIT_STEP_DB).round()).clamp(0.0, 9.0) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digits_follow_three_db_steps() {
        assert_eq!(level_digit(-6.0), Some(9));
        assert_eq!(level_digit(0.0), Some(9)); // clamped
        assert_eq!(level_digit(-33.0), Some(0));
        assert_eq!(level_digit(-60.0), Some(0));
        assert_eq!(level_digit(-23.0), Some(3));
        assert_eq!(level_digit(-14.0), Some(6));
        assert_eq!(level_digit(-22.4), Some(4)); // (−22.4+33)/3 = 3.53
    }

    #[test]
    fn silence_has_no_digit() {
        assert_eq!(level_digit(SILENCE_DB), None);
        assert_eq!(level_digit(FLOOR_DB), None);
        assert_eq!(level_digit(f32::NEG_INFINITY), None);
        assert_eq!(level_digit(f32::NAN), None);
        assert_eq!(level_digit(-69.0), Some(0)); // quiet but not silent
    }
}
