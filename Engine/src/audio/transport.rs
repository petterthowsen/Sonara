//! Per-block transport snapshot handed to every device.

use super::tempo_map::TempoMap;
use super::types::ProjectSettings;

/// Transport state at a block's first frame.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Transport {
    /// Effective tempo in BPM.
    pub tempo: f64,
    /// BPM change per sample (0 when stopped or outside a ramp).
    pub tempo_inc: f64,
    pub playing: bool,
    pub song_pos_beats: f64,
    pub song_pos_seconds: f64,
    /// Start of the current bar, in beats.
    pub bar_start_beats: f64,
    pub bar_number: i32,
    pub time_sig_num: u16,
    pub time_sig_den: u16,
}

impl Transport {
    /// Snapshot at fractional tick `tick_pos`. The engine has one static time signature, so
    /// bars are a fixed length.
    pub fn at(
        map: &TempoMap,
        settings: &ProjectSettings,
        tick_pos: f64,
        sample_rate: f32,
        playing: bool,
    ) -> Self {
        let ppq = settings.ppq as f64;
        let fallback = settings.tempo as f64;
        let num = settings.time_numerator.max(1);
        let den = settings.time_denominator.max(1);
        let ticks_per_bar = ppq * 4.0 * num as f64 / den as f64;
        let bar = (tick_pos / ticks_per_bar).floor().max(0.0);
        let tempo = map.bpm_at(tick_pos, fallback);
        let tempo_inc = if playing {
            let ticks_per_sample = tempo * ppq / (60.0 * sample_rate as f64);
            map.slope_bpm_per_tick_at(tick_pos) * ticks_per_sample
        } else {
            0.0
        };
        Self {
            tempo,
            tempo_inc,
            playing,
            song_pos_beats: tick_pos / ppq,
            song_pos_seconds: map.seconds_at(tick_pos, fallback, ppq),
            bar_start_beats: bar * ticks_per_bar / ppq,
            bar_number: bar as i32,
            time_sig_num: num as u16,
            time_sig_den: den as u16,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_at_tick_1920() {
        let t = Transport::at(
            &TempoMap::default(),
            &ProjectSettings::default(),
            1920.0,
            48_000.0,
            true,
        );
        assert_eq!(t.tempo, 120.0);
        assert!((t.song_pos_beats - 2.0).abs() < 1e-12);
        assert!((t.song_pos_seconds - 1.0).abs() < 1e-12);
        assert_eq!(t.bar_number, 0);
        assert_eq!(t.bar_start_beats, 0.0);
        assert_eq!((t.time_sig_num, t.time_sig_den), (4, 4));
        assert!(t.playing);
    }

    #[test]
    fn transport_seconds_through_ramp() {
        let map = TempoMap::from_points(vec![(0, 120.0), (3840, 60.0)]);
        let t = Transport::at(&map, &ProjectSettings::default(), 4800.0, 48_000.0, true);
        assert!((t.song_pos_beats - 5.0).abs() < 1e-12);
        assert!((t.song_pos_seconds - 3.773).abs() < 1e-3);
        assert_eq!(t.bar_number, 1);
        assert_eq!(t.bar_start_beats, 4.0);
    }

    #[test]
    fn tempo_inc_on_ramp() {
        let map = TempoMap::from_points(vec![(0, 60.0), (3840, 120.0)]);
        let t = Transport::at(&map, &ProjectSettings::default(), 0.0, 48_000.0, true);
        assert_eq!(t.tempo, 60.0);
        assert!((t.tempo_inc - 3.125e-4).abs() < 1e-9);
    }

    #[test]
    fn stopped_has_zero_inc() {
        let map = TempoMap::from_points(vec![(0, 60.0), (3840, 120.0)]);
        let t = Transport::at(&map, &ProjectSettings::default(), 0.0, 48_000.0, false);
        assert_eq!(t.tempo_inc, 0.0);
        assert!(!t.playing);
    }
}
