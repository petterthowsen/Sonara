//! Project-wide settings shared by transport, tempo and analysis.

use super::types::Tick;

/// Project settings
#[derive(Debug, Clone)]
pub struct ProjectSettings {
    pub tempo: f32,
    pub time_numerator: i32,
    pub time_denominator: i32,
    pub ppq: i32,
    pub sample_rate: i32,
    /// Project scale as a 12-bit pitch-class mask (bit 0 = C), 0 = none. Only note effects
    /// read it (Transpose following the project scale, spec 027 amending spec 026).
    pub scale_mask: u16,
}

impl Default for ProjectSettings {
    fn default() -> Self {
        Self {
            tempo: 120.0,
            time_numerator: 4,
            time_denominator: 4,
            ppq: 960,
            sample_rate: 48000,
            scale_mask: 0,
        }
    }
}

impl ProjectSettings {
    /// Convert tick position to bars.beats.sixteenths.ticks format
    /// Returns (bars, beats, sixteenths, ticks) - 1-indexed for bars/beats/sixteenths, 0-indexed for ticks
    pub fn tick_to_musical_time(&self, tick: Tick) -> (i64, i32, i32, i32) {
        let ticks_per_beat = self.ppq as i64;
        let ticks_per_bar = ticks_per_beat * self.time_numerator as i64;
        let ticks_per_sixteenth = ticks_per_beat / 4;

        let bars = tick / ticks_per_bar;
        let remaining_after_bars = tick % ticks_per_bar;

        let beats = remaining_after_bars / ticks_per_beat;
        let remaining_after_beats = remaining_after_bars % ticks_per_beat;

        let sixteenths = remaining_after_beats / ticks_per_sixteenth;
        let remaining_ticks = remaining_after_beats % ticks_per_sixteenth;

        (
            bars + 1,
            beats as i32 + 1,
            sixteenths as i32 + 1,
            remaining_ticks as i32,
        )
    }

    /// Format tick position as "bars.beats.sixteenths.ticks" string
    pub fn format_tick_position(&self, tick: Tick) -> String {
        let (bars, beats, sixteenths, ticks) = self.tick_to_musical_time(tick);
        format!("{}.{}.{}.{}", bars, beats, sixteenths, ticks)
    }
}
