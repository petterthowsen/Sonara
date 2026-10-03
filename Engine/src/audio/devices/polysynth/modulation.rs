//! PolySynth's six fixed modulation sources.
//!
//! The route matrix moved to `audio/modulation/matrix.rs` (spec 018 Phase 1); this module keeps
//! the fixed source list that PolySynth still advertises until it migrates to instance
//! modulators (spec 018 Phase 6).

/// Per-voice modulation sources. Envelopes and velocity are unipolar (0..1); LFOs and keytrack
/// are bipolar (−1..1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModSource {
    FilterEnv,
    AmpEnv,
    Lfo1,
    Lfo2,
    Velocity,
    Keytrack,
}

impl ModSource {
    pub const COUNT: usize = 6;
    pub const ALL: [ModSource; Self::COUNT] = [
        ModSource::FilterEnv,
        ModSource::AmpEnv,
        ModSource::Lfo1,
        ModSource::Lfo2,
        ModSource::Velocity,
        ModSource::Keytrack,
    ];

    /// Stable id used over OSC and in saved projects.
    pub fn id(self) -> &'static str {
        match self {
            ModSource::FilterEnv => "filter_env",
            ModSource::AmpEnv => "amp_env",
            ModSource::Lfo1 => "lfo1",
            ModSource::Lfo2 => "lfo2",
            ModSource::Velocity => "velocity",
            ModSource::Keytrack => "keytrack",
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            ModSource::FilterEnv => "Filter Env",
            ModSource::AmpEnv => "Amp Env",
            ModSource::Lfo1 => "LFO 1",
            ModSource::Lfo2 => "LFO 2",
            ModSource::Velocity => "Velocity",
            ModSource::Keytrack => "Keytrack",
        }
    }

    pub fn bipolar(self) -> bool {
        matches!(
            self,
            ModSource::Lfo1 | ModSource::Lfo2 | ModSource::Keytrack
        )
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.id() == id)
    }

    /// Position in `ALL`, and in the per-voice source value array.
    pub fn index(self) -> usize {
        self as usize
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_ids_round_trip() {
        for s in ModSource::ALL {
            assert_eq!(ModSource::from_id(s.id()), Some(s));
            assert_eq!(ModSource::ALL[s.index()], s);
        }
        assert_eq!(ModSource::from_id("nope"), None);
    }
}
