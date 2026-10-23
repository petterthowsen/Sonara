//! Metronome patterns (spec 053): one bar of step levels per time signature, and the cursor that
//! walks the steps along the song's bar grid.
//!
//! Everything here is fixed-size and `Copy`, so the audio callback reads and the command thread
//! replaces patterns without allocating.

use crate::audio::project::ProjectSettings;
use crate::audio::time_signature_map::TimeSignatureMap;
use crate::audio::types::Tick;

/// Patterns the table holds (one per edited time signature).
pub const MAX_PATTERNS: usize = 32;
/// Steps in one bar of a pattern.
pub const MAX_STEPS: usize = 128;
/// Strongest emphasis level; 0 is Off.
pub const MAX_LEVEL: u8 = 4;
/// Resolutions a pattern may be sent with, as the denominator of the step's note length.
pub const RESOLUTIONS: [u8; 3] = [4, 8, 16];

/// Steps in one bar of `num/den` at `resolution` (1/`resolution` notes). None when a bar is not
/// a whole number of steps, or has more than [`MAX_STEPS`].
pub fn steps_for(num: u16, den: u16, resolution: u8) -> Option<usize> {
    if num == 0 || den == 0 || resolution == 0 {
        return None;
    }
    let total = num as usize * resolution as usize;
    let den = den as usize;
    if total % den != 0 {
        return None;
    }
    let steps = total / den;
    (1..=MAX_STEPS).contains(&steps).then_some(steps)
}

/// One bar of step levels for a time signature.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pattern {
    pub num: u16,
    pub den: u16,
    /// Each step is a 1/`resolution` note.
    pub resolution: u8,
    pub steps: u8,
    /// Emphasis per step: 0 Off, 1 (weakest) to 4 (strongest). Only `steps` entries count.
    pub levels: [u8; MAX_STEPS],
}

impl Pattern {
    /// The pattern a signature plays when it was never edited (REQ-013): beat resolution (1/4
    /// for denominators 1 and 2), level 4 on the first beat, level 2 on every other beat.
    pub fn default_for(num: u16, den: u16) -> Self {
        let num = num.max(1);
        let den = den.max(1);
        let resolution = den.max(4).min(32) as u8;
        let steps = steps_for(num, den, resolution).unwrap_or(1);
        // Steps per beat: 1 for den >= 4, 2 for 2/2, 4 for 1/1.
        let per_beat = (resolution as usize / den as usize).max(1);
        let mut levels = [0u8; MAX_STEPS];
        for (i, level) in levels.iter_mut().enumerate().take(steps) {
            if i % per_beat == 0 {
                *level = if i == 0 { 4 } else { 2 };
            }
        }
        Self {
            num,
            den,
            resolution,
            steps: steps as u8,
            levels,
        }
    }

    /// Whether `steps` is the right count for this pattern's own signature and resolution.
    fn is_consistent(&self) -> bool {
        steps_for(self.num, self.den, self.resolution) == Some(self.steps as usize)
    }

    /// The level of step `index` (0 past the end).
    pub fn level(&self, index: usize) -> u8 {
        if index < self.steps as usize {
            self.levels[index]
        } else {
            0
        }
    }
}

/// Why a pattern was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PatternError {
    /// The resolution is not 4, 8 or 16.
    BadResolution,
    /// The step count does not fit one bar of the signature at the resolution.
    BadStepCount { expected: Option<usize>, got: usize },
    /// A level above 4.
    BadLevel,
    /// The table already holds a pattern for 32 other signatures.
    TableFull,
}

impl std::fmt::Display for PatternError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadResolution => write!(f, "resolution must be 4, 8 or 16"),
            Self::BadStepCount {
                expected: Some(expected),
                got,
            } => write!(f, "expected {expected} steps, got {got}"),
            Self::BadStepCount {
                expected: None,
                got,
            } => write!(
                f,
                "the signature has no whole-step bar at this resolution (got {got} steps)"
            ),
            Self::BadLevel => write!(f, "levels must be 0 to {MAX_LEVEL}"),
            Self::TableFull => write!(f, "pattern table is full ({MAX_PATTERNS} signatures)"),
        }
    }
}

/// The edited patterns, at most one per signature, in fixed storage.
#[derive(Clone)]
pub struct PatternTable {
    entries: [Pattern; MAX_PATTERNS],
    len: usize,
}

impl Default for PatternTable {
    fn default() -> Self {
        Self {
            entries: [Pattern::default_for(4, 4); MAX_PATTERNS],
            len: 0,
        }
    }
}

impl PatternTable {
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn clear(&mut self) {
        self.len = 0;
    }

    /// The edited pattern for `num/den`, if any.
    pub fn get(&self, num: u16, den: u16) -> Option<&Pattern> {
        self.entries[..self.len]
            .iter()
            .find(|p| p.num == num && p.den == den)
    }

    /// Store `levels` for `num/den`, replacing that signature's entry in place. Validates the
    /// resolution, step count and levels first, so a refused pattern changes nothing.
    pub fn set(
        &mut self,
        num: u16,
        den: u16,
        resolution: u8,
        levels: &[u8],
    ) -> Result<(), PatternError> {
        if !RESOLUTIONS.contains(&resolution) {
            return Err(PatternError::BadResolution);
        }
        let expected = steps_for(num, den, resolution);
        if expected != Some(levels.len()) {
            return Err(PatternError::BadStepCount {
                expected,
                got: levels.len(),
            });
        }
        if levels.iter().any(|&l| l > MAX_LEVEL) {
            return Err(PatternError::BadLevel);
        }
        let index = match self.entries[..self.len]
            .iter()
            .position(|p| p.num == num && p.den == den)
        {
            Some(index) => index,
            None if self.len < MAX_PATTERNS => {
                self.len += 1;
                self.len - 1
            }
            None => return Err(PatternError::TableFull),
        };
        let entry = &mut self.entries[index];
        entry.num = num;
        entry.den = den;
        entry.resolution = resolution;
        entry.steps = levels.len() as u8;
        entry.levels = [0; MAX_STEPS];
        entry.levels[..levels.len()].copy_from_slice(levels);
        Ok(())
    }

    /// Drop the edited pattern for `num/den` (it plays the default again). False if it had none.
    pub fn remove(&mut self, num: u16, den: u16) -> bool {
        let Some(index) = self.entries[..self.len]
            .iter()
            .position(|p| p.num == num && p.den == den)
        else {
            return false;
        };
        self.entries.copy_within(index + 1..self.len, index);
        self.len -= 1;
        true
    }

    /// The pattern a bar of `num/den` plays: the edited one, or the default when there is none
    /// or its step count no longer matches the signature.
    pub fn resolve(&self, num: u16, den: u16) -> Pattern {
        match self.get(num, den) {
            Some(pattern) if pattern.is_consistent() => *pattern,
            _ => Pattern::default_for(num, den),
        }
    }
}

/// The next step to fire, on the song's bar grid. `at_or_after` finds it from any tick with one
/// signature lookup; `advance` moves to the following step, looking the next bar up again when
/// the bar ends so each bar uses the pattern of its own signature.
#[derive(Clone, Copy)]
pub struct StepCursor {
    /// Tick of the next step.
    pub tick: Tick,
    /// Level of that step (0 is Off).
    pub level: u8,
    pattern: Pattern,
    bar_start: Tick,
    bar_ticks: Tick,
    index: usize,
    /// `ppq * 4`: ticks in a whole note.
    whole: Tick,
}

impl StepCursor {
    /// The first step at or after `tick`.
    pub fn at_or_after(
        tick: Tick,
        sig_map: &TimeSignatureMap,
        settings: &ProjectSettings,
        table: &PatternTable,
    ) -> Self {
        let whole = settings.ppq.max(1) as Tick * 4;
        let tick = tick.max(0);
        let (bar_start, bar_ticks, pattern) = Self::bar_at(tick, sig_map, settings, table);
        let res = pattern.resolution as Tick;
        // Smallest index whose step tick is >= tick: ceil((tick - bar_start) * res / whole).
        let index = (((tick - bar_start) * res + whole - 1) / whole) as usize;
        if index >= pattern.steps as usize {
            return Self::bar_start_at(bar_start + bar_ticks, sig_map, settings, table, whole);
        }
        Self::at(bar_start, bar_ticks, pattern, index, whole)
    }

    /// Move to the next step.
    pub fn advance(
        &mut self,
        sig_map: &TimeSignatureMap,
        settings: &ProjectSettings,
        table: &PatternTable,
    ) {
        let index = self.index + 1;
        *self = if index < self.pattern.steps as usize {
            Self::at(
                self.bar_start,
                self.bar_ticks,
                self.pattern,
                index,
                self.whole,
            )
        } else {
            Self::bar_start_at(
                self.bar_start + self.bar_ticks,
                sig_map,
                settings,
                table,
                self.whole,
            )
        };
    }

    fn bar_start_at(
        tick: Tick,
        sig_map: &TimeSignatureMap,
        settings: &ProjectSettings,
        table: &PatternTable,
        whole: Tick,
    ) -> Self {
        let (bar_start, bar_ticks, pattern) = Self::bar_at(tick, sig_map, settings, table);
        Self::at(bar_start, bar_ticks, pattern, 0, whole)
    }

    fn at(bar_start: Tick, bar_ticks: Tick, pattern: Pattern, index: usize, whole: Tick) -> Self {
        Self {
            tick: bar_start + index as Tick * whole / pattern.resolution as Tick,
            level: pattern.level(index),
            pattern,
            bar_start,
            bar_ticks,
            index,
            whole,
        }
    }

    /// Start tick, length and pattern of the bar containing `tick`.
    fn bar_at(
        tick: Tick,
        sig_map: &TimeSignatureMap,
        settings: &ProjectSettings,
        table: &PatternTable,
    ) -> (Tick, Tick, Pattern) {
        let ppq = settings.ppq.max(1) as f64;
        let base_num = settings.time_numerator.clamp(1, u16::MAX as i32) as u16;
        let base_den = settings.time_denominator.clamp(1, u16::MAX as i32) as u16;
        let seg = sig_map.segment_at(tick as f64, base_num, base_den, ppq);
        let bar_ticks = (ppq * 4.0 * seg.numerator as f64 / seg.denominator as f64).round() as Tick;
        let pattern = table.resolve(seg.numerator, seg.denominator);
        (
            seg.bar_start_tick.round() as Tick,
            bar_ticks.max(1),
            pattern,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> ProjectSettings {
        ProjectSettings::default()
    }

    fn levels(p: &Pattern) -> Vec<u8> {
        p.levels[..p.steps as usize].to_vec()
    }

    #[test]
    fn default_patterns() {
        let p = Pattern::default_for(4, 4);
        assert_eq!((p.resolution, levels(&p)), (4, vec![4, 2, 2, 2]));
        let p = Pattern::default_for(6, 8);
        assert_eq!((p.resolution, levels(&p)), (8, vec![4, 2, 2, 2, 2, 2]));
        // 2/2: quarter steps, a beat is two of them.
        let p = Pattern::default_for(2, 2);
        assert_eq!((p.resolution, levels(&p)), (4, vec![4, 0, 2, 0]));
        let p = Pattern::default_for(3, 16);
        assert_eq!((p.resolution, levels(&p)), (16, vec![4, 2, 2]));
        // Denominator 32 keeps one step per beat (resolution 32, outside the UI's 4/8/16).
        let p = Pattern::default_for(3, 32);
        assert_eq!((p.resolution, levels(&p)), (32, vec![4, 2, 2]));
        // The biggest bar still fits.
        assert_eq!(Pattern::default_for(32, 1).steps, 128);
    }

    #[test]
    fn steps_for_needs_whole_steps() {
        assert_eq!(steps_for(4, 4, 8), Some(8));
        assert_eq!(steps_for(7, 8, 8), Some(7));
        assert_eq!(steps_for(6, 8, 16), Some(12));
        assert_eq!(steps_for(7, 8, 4), None);
        assert_eq!(steps_for(32, 1, 16), None);
        assert_eq!(steps_for(0, 4, 4), None);
    }

    #[test]
    fn table_replace_and_remove() {
        let mut t = PatternTable::default();
        assert!(t.is_empty());
        t.set(4, 4, 8, &[4, 0, 1, 0, 2, 0, 3, 0]).unwrap();
        t.set(7, 8, 8, &[4, 0, 2, 0, 2, 0, 0]).unwrap();
        assert_eq!(t.len(), 2);
        // Replaced in place: still two entries, new resolution and levels.
        t.set(4, 4, 4, &[4, 1, 1, 1]).unwrap();
        assert_eq!(t.len(), 2);
        let p = t.get(4, 4).unwrap();
        assert_eq!((p.resolution, levels(p)), (4, vec![4, 1, 1, 1]));
        assert_eq!(
            p.levels[4], 0,
            "stale steps from the longer pattern are cleared"
        );
        assert!(t.remove(4, 4));
        assert!(!t.remove(4, 4));
        assert_eq!(t.len(), 1);
        assert!(t.get(4, 4).is_none());
        assert_eq!(levels(t.get(7, 8).unwrap()), vec![4, 0, 2, 0, 2, 0, 0]);
        // Removed: the default plays again.
        assert_eq!(t.resolve(4, 4), Pattern::default_for(4, 4));
        t.clear();
        assert!(t.is_empty());
    }

    #[test]
    fn table_refuses_bad_patterns_and_a_full_table() {
        let mut t = PatternTable::default();
        assert_eq!(
            t.set(4, 4, 8, &[1, 2, 3]),
            Err(PatternError::BadStepCount {
                expected: Some(8),
                got: 3
            })
        );
        assert_eq!(t.set(4, 4, 5, &[1]), Err(PatternError::BadResolution));
        assert_eq!(t.set(4, 4, 4, &[1, 5, 1, 1]), Err(PatternError::BadLevel));
        assert!(matches!(
            t.set(7, 8, 4, &[1, 1, 1, 1]),
            Err(PatternError::BadStepCount { expected: None, .. })
        ));
        assert!(t.is_empty());
        for num in 1..=32u16 {
            t.set(num, 4, 4, &vec![1; num as usize]).unwrap();
        }
        assert_eq!(t.set(1, 8, 8, &[1]), Err(PatternError::TableFull));
        // A full table still replaces an existing signature.
        t.set(1, 4, 4, &[3]).unwrap();
    }

    #[test]
    fn mismatched_steps_fall_back_to_the_default() {
        let mut t = PatternTable::default();
        t.set(4, 4, 4, &[4, 1, 1, 1]).unwrap();
        assert_eq!(levels(&t.resolve(4, 4)), vec![4, 1, 1, 1]);
        // Corrupt the stored pattern's step count: the signature falls back.
        t.entries[0].steps = 3;
        assert_eq!(t.resolve(4, 4), Pattern::default_for(4, 4));
    }

    #[test]
    fn cursor_walks_a_bar_and_finds_steps_from_any_tick() {
        let table = PatternTable::default();
        let map = TimeSignatureMap::default();
        let s = settings();
        // 4/4 default: a step every 960 ticks, levels 4 2 2 2.
        let mut c = StepCursor::at_or_after(0, &map, &s, &table);
        assert_eq!((c.tick, c.level), (0, 4));
        c.advance(&map, &s, &table);
        assert_eq!((c.tick, c.level), (960, 2));
        c.advance(&map, &s, &table);
        c.advance(&map, &s, &table);
        assert_eq!((c.tick, c.level), (2880, 2));
        c.advance(&map, &s, &table);
        assert_eq!((c.tick, c.level), (3840, 4), "next bar's downbeat");
        // From the middle of a step: the next one.
        let c = StepCursor::at_or_after(1, &map, &s, &table);
        assert_eq!(c.tick, 960);
        let c = StepCursor::at_or_after(960, &map, &s, &table);
        assert_eq!(c.tick, 960, "a tick exactly on a step is that step");
        let c = StepCursor::at_or_after(2881, &map, &s, &table);
        assert_eq!((c.tick, c.level), (3840, 4), "past the last step: next bar");
    }

    #[test]
    fn cursor_crosses_signature_change() {
        // 4/4 for bar 1, 3/4 from bar 2; 3/4 has its own edited pattern at 1/8.
        let mut table = PatternTable::default();
        table.set(3, 4, 8, &[3, 0, 1, 0, 1, 0]).unwrap();
        let map = TimeSignatureMap::from_changes(vec![(2, 3, 4)]);
        let s = settings();
        let mut c = StepCursor::at_or_after(2880, &map, &s, &table);
        assert_eq!((c.tick, c.level), (2880, 2), "last beat of bar 1 (4/4)");
        c.advance(&map, &s, &table);
        assert_eq!(c.tick, 3840, "bar-2 downbeat");
        assert_eq!(c.level, 3, "uses the 3/4 pattern, not the 4/4 default");
        c.advance(&map, &s, &table);
        assert_eq!((c.tick, c.level), (3840 + 480, 0));
        // Walk the rest of the 3/4 bar: 6 steps, then bar 3 starts (3/4 again).
        for _ in 0..5 {
            c.advance(&map, &s, &table);
        }
        assert_eq!(c.tick, 3840 + 2880);
        assert_eq!(c.level, 3);
        // Starting the cursor inside bar 2 finds the same grid.
        let c = StepCursor::at_or_after(3841, &map, &s, &table);
        assert_eq!((c.tick, c.level), (3840 + 480, 0));
    }
}
