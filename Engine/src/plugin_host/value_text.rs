//! Display curves for CLAP parameters.
//!
//! CLAP has no unit field: a host learns what a value means only from the plugin's
//! `value_to_text`. When parameters are queried, the host samples that text at
//! `DISPLAY_POINTS` evenly spaced plain values and parses each into a number and a unit
//! ("1.20 kHz" → 1200 Hz). The UI interpolates the resulting curve to show real values without
//! asking the plugin again.

/// Samples per curve, spread evenly over the parameter's plain range (both ends included).
pub const DISPLAY_POINTS: usize = 33;
/// A curve is kept only when this share of the samples parse with the curve's unit.
const MIN_PARSED_SHARE: f32 = 0.75;

/// Unit suffixes (lowercase) → the unit a curve carries and the factor into it.
const UNIT_TABLE: &[(&str, &str, f32)] = &[
    ("hz", "Hz", 1.0),
    ("khz", "Hz", 1000.0),
    ("ms", "ms", 1.0),
    ("s", "s", 1.0),
    ("sec", "s", 1.0),
    ("db", "dB", 1.0),
    ("%", "%", 1.0),
];

/// `(value, unit)` for one `value_to_text` label, or `None` when it doesn't start with a number.
/// Known units are normalized ("1.2 kHz" → `(1200.0, "Hz")`); others are kept as written.
/// "-inf dB" parses to negative infinity. Labels whose rest looks like more numbers ("1/4",
/// "1:30") don't parse.
pub fn parse(text: &str) -> Option<(f32, String)> {
    let text = text.trim().replace('\u{2212}', "-");
    let (sign, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (-1.0, rest),
        None => (1.0, text.strip_prefix('+').unwrap_or(&text)),
    };
    let lower = unsigned.to_ascii_lowercase();
    let (value, rest) = if lower.starts_with("inf") {
        (f32::INFINITY, &unsigned[3..])
    } else if let Some(rest) = unsigned.strip_prefix('\u{221e}') {
        (f32::INFINITY, rest)
    } else {
        let end = unsigned
            .find(|c: char| !(c.is_ascii_digit() || c == '.'))
            .unwrap_or(unsigned.len());
        let number = &unsigned[..end];
        if !number.bytes().any(|b| b.is_ascii_digit()) {
            return None;
        }
        (number.parse::<f32>().ok()?, &unsigned[end..])
    };
    let rest = rest.trim();
    if rest.starts_with(|c: char| c.is_ascii_digit() || c == '/' || c == ':' || c == '.') {
        return None;
    }
    let value = sign * value;
    let lower_rest = rest.to_ascii_lowercase();
    for (suffix, unit, factor) in UNIT_TABLE {
        if lower_rest == *suffix {
            return Some((value * factor, unit.to_string()));
        }
    }
    Some((value, rest.to_string()))
}

/// `(unit, curve)` from the labels sampled at `DISPLAY_POINTS` plain values (`None` where the
/// plugin gave no text), or `None` when too few parse with one unit or the values never change.
/// Samples that don't parse with the curve's unit are NaN. A curve mixing "ms" and "s" is in ms.
pub fn display_curve(labels: &[Option<String>]) -> Option<(String, Vec<f32>)> {
    let mut parsed: Vec<Option<(f32, String)>> = labels
        .iter()
        .map(|l| l.as_deref().and_then(parse))
        .collect();
    let has = |unit: &str, parsed: &[Option<(f32, String)>]| {
        parsed.iter().flatten().any(|(_, u)| u == unit)
    };
    if has("ms", &parsed) && has("s", &parsed) {
        for (value, unit) in parsed.iter_mut().flatten() {
            if unit == "s" {
                *value *= 1000.0;
                *unit = "ms".to_string();
            }
        }
    }

    let mut best: Option<(&str, usize)> = None;
    for (_, unit) in parsed.iter().flatten() {
        let count = parsed.iter().flatten().filter(|(_, u)| u == unit).count();
        if best.is_none_or(|(_, n)| count > n) {
            best = Some((unit.as_str(), count));
        }
    }
    let (unit, count) = best?;
    if (count as f32) < MIN_PARSED_SHARE * labels.len() as f32 {
        return None;
    }
    let curve: Vec<f32> = parsed
        .iter()
        .map(|p| match p {
            Some((value, u)) if u == unit => *value,
            _ => f32::NAN,
        })
        .collect();
    let finite: Vec<f32> = curve.iter().copied().filter(|v| v.is_finite()).collect();
    let changes = finite.windows(2).any(|w| w[0] != w[1]);
    changes.then(|| (unit.to_string(), curve))
}

/// Plain value of sample `i` of `DISPLAY_POINTS` over `min..=max`.
pub fn sample_value(min: f64, max: f64, i: usize) -> f64 {
    min + (max - min) * i as f64 / (DISPLAY_POINTS - 1) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(texts: &[&str]) -> Vec<Option<String>> {
        texts.iter().map(|t| Some(t.to_string())).collect()
    }

    #[test]
    fn parse_normalizes_known_units() {
        assert_eq!(parse("1.20 kHz"), Some((1200.0, "Hz".to_string())));
        assert_eq!(parse("250Hz"), Some((250.0, "Hz".to_string())));
        assert_eq!(parse(" -6.0 dB "), Some((-6.0, "dB".to_string())));
        assert_eq!(parse("\u{2212}3 dB"), Some((-3.0, "dB".to_string())));
        assert_eq!(parse("+12 st"), Some((12.0, "st".to_string())));
        assert_eq!(parse("50 %"), Some((50.0, "%".to_string())));
        assert_eq!(parse("0.71"), Some((0.71, String::new())));
    }

    #[test]
    fn parse_reads_infinity() {
        assert_eq!(
            parse("-inf dB"),
            Some((f32::NEG_INFINITY, "dB".to_string()))
        );
        assert_eq!(
            parse("-\u{221e} dB"),
            Some((f32::NEG_INFINITY, "dB".to_string()))
        );
    }

    #[test]
    fn parse_rejects_text_and_non_numbers() {
        assert_eq!(parse("Off"), None);
        assert_eq!(parse("C#3"), None);
        assert_eq!(parse("1/4"), None);
        assert_eq!(parse("1:30"), None);
        assert_eq!(parse("."), None);
        assert_eq!(parse(""), None);
    }

    #[test]
    fn curve_switches_units_within_a_family() {
        let (unit, curve) = display_curve(&labels(&["20 Hz", "632 Hz", "20.0 kHz"])).unwrap();
        assert_eq!(unit, "Hz");
        assert_eq!(curve, vec![20.0, 632.0, 20000.0]);

        let (unit, curve) = display_curve(&labels(&["10 ms", "500 ms", "2.5 s"])).unwrap();
        assert_eq!(unit, "ms");
        assert_eq!(curve, vec![10.0, 500.0, 2500.0]);
    }

    #[test]
    fn curve_marks_stray_labels_nan() {
        let (unit, curve) = display_curve(&labels(&["Off", "-12 dB", "-6 dB", "0 dB"])).unwrap();
        assert_eq!(unit, "dB");
        assert!(curve[0].is_nan());
        assert_eq!(&curve[1..], &[-12.0, -6.0, 0.0]);
    }

    #[test]
    fn curve_needs_most_labels_to_parse_and_change() {
        assert_eq!(
            display_curve(&labels(&["Off", "Low", "-6 dB", "0 dB"])),
            None
        );
        assert_eq!(display_curve(&labels(&["1 dB", "1 dB", "1 dB"])), None);
        assert_eq!(display_curve(&[None, None, None]), None);
    }

    #[test]
    fn sample_values_cover_the_range() {
        assert_eq!(sample_value(0.0, 1.0, 0), 0.0);
        assert_eq!(sample_value(0.0, 1.0, DISPLAY_POINTS - 1), 1.0);
        assert_eq!(sample_value(-24.0, 24.0, (DISPLAY_POINTS - 1) / 2), 0.0);
    }
}
