//! Parameter types and the maths that maps normalized 0..1 values to real ones.

/// Parameter ID (normalized 0.0-1.0, host/device agnostic)
pub type ParamId = u32;

/// Parameter value (always 0.0-1.0, device interprets range)
pub type ParamValue = f32;

/// Normalized value of enum choice `index` out of `count` choices (`0.0..=1.0`, evenly spaced).
///
/// Use this pair for every enum parameter so `get_parameter` and `set_parameter` always agree.
pub fn enum_to_norm(index: usize, count: usize) -> ParamValue {
    if count <= 1 {
        return 0.0;
    }
    index.min(count - 1) as f32 / (count - 1) as f32
}

/// Map a normalized `0..=1` value to a real one: `min * (max/min)^n` when `is_logarithmic`
/// (needs `min > 0`), otherwise `min + (max - min) * n^skew`.
pub fn norm_to_real(norm: f32, min: f32, max: f32, is_logarithmic: bool, skew: f32) -> f32 {
    let n = norm.clamp(0.0, 1.0);
    if is_logarithmic && min > 0.0 && max > min {
        min * (max / min).powf(n)
    } else {
        let curved = if skew == 1.0 {
            n
        } else {
            n.powf(skew.max(f32::EPSILON))
        };
        min + (max - min) * curved
    }
}

/// Inverse of [`norm_to_real`]. The result is clamped to `0..=1`.
pub fn real_to_norm(real: f32, min: f32, max: f32, is_logarithmic: bool, skew: f32) -> f32 {
    if max <= min {
        return 0.0;
    }
    if is_logarithmic && min > 0.0 {
        if real <= min {
            return 0.0;
        }
        return ((real / min).ln() / (max / min).ln()).clamp(0.0, 1.0);
    }
    ((real - min) / (max - min))
        .clamp(0.0, 1.0)
        .powf(1.0 / skew.max(f32::EPSILON))
}

/// Enum choice index for a normalized value: the nearest of `count` evenly spaced choices.
pub fn norm_to_enum(norm: ParamValue, count: usize) -> usize {
    if count <= 1 {
        return 0;
    }
    (norm.clamp(0.0, 1.0) * (count - 1) as f32).round() as usize
}
/// Parameter type for metadata/UI
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamType {
    Float,
    Bool,
    Enum,
}

/// Parameter metadata (for UI and parameter automation)
#[derive(Debug, Clone)]
pub struct ParamInfo {
    pub id: ParamId,
    pub name: String,
    pub unit: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub is_automation_safe: bool,
    pub param_type: ParamType,
    pub syncable: bool,
    pub enum_values: Vec<String>,
    pub is_hidden: bool,
    pub is_read_only: bool,
    pub is_bypass: bool,
    /// Can a modulator drive this parameter (a float, automatable parameter)?
    pub is_modulatable: bool,
    /// CLAP module path, e.g. "Early/Size"; "" if none
    pub module: String,
    /// Real value is `min * (max/min)^n` (Hz-like values). Requires `min > 0`; ignores `skew`.
    pub is_logarithmic: bool,
    /// Power curve for the normalized value: `real = min + (max - min) * n^skew`. 1.0 is linear.
    pub skew: f32,
    /// Display values (in `unit`) sampled evenly over `min..=max`, for UIs to interpolate; empty
    /// when the real value is shown as is. Only CLAP plugins fill it (see `plugin_host::value_text`).
    pub display: Vec<f32>,
}

#[cfg(test)]
mod curve_tests {
    use super::*;

    #[test]
    fn norm_real_round_trips_for_linear_skewed_and_log() {
        let cases = [
            (0.0, 1.0, false, 1.0),
            (0.0005, 10.0, false, 4.0),
            (0.0, 1.0, false, 3.0),
            (20.0, 20_000.0, true, 1.0),
        ];
        for (min, max, log, skew) in cases {
            for n in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let real = norm_to_real(n, min, max, log, skew);
                let back = real_to_norm(real, min, max, log, skew);
                assert!(
                    (back - n).abs() < 1e-4,
                    "{min}..{max} log={log} skew={skew} n={n}: {back}"
                );
            }
            assert_eq!(norm_to_real(0.0, min, max, log, skew), min);
            assert!((norm_to_real(1.0, min, max, log, skew) - max).abs() < max * 1e-5);
        }
    }

    #[test]
    fn skew_four_puts_625ms_at_mid_knob_and_zero_is_exact() {
        assert!((norm_to_real(0.5, 0.0, 10.0, false, 4.0) - 0.625).abs() < 1e-5);
        assert_eq!(norm_to_real(0.0, 0.0, 1.0, false, 3.0), 0.0);
    }

    #[test]
    fn log_ignores_skew() {
        assert_eq!(
            norm_to_real(0.5, 20.0, 20_000.0, true, 4.0),
            norm_to_real(0.5, 20.0, 20_000.0, true, 1.0)
        );
    }

    #[test]
    fn enum_helpers_round_trip() {
        for count in 2..8 {
            for i in 0..count {
                assert_eq!(norm_to_enum(enum_to_norm(i, count), count), i);
            }
        }
    }
}
