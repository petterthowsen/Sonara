//! Modulation sources and a fixed-capacity route matrix.
//!
//! The matrix knows nothing about the synth: routes point at a source index and a parameter
//! slot (an index into the device's parameter table), so it can move to `audio/modulation.rs`
//! when other devices get modulation. Only `ModSource` is PolySynth-specific.
//!
//! Evaluation (per voice, once per control block): the device samples each source, calls
//! [`ModMatrix::accumulate`] to sum `amount × source` per slot, and adds that to the base
//! normalized value (`clamp(base + Σ, 0, 1)`). The result lives next to the base and is never
//! written back into it (ADR-0010: base + automation + Σ contributions).

use super::super::ParamId;

/// Routes one device can hold. Adding, updating and removing never allocate.
pub const MAX_ROUTES: usize = 64;

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

/// One source → parameter connection.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Route {
    /// Index into the device's source value array.
    pub source: usize,
    pub param_id: ParamId,
    /// Index into the device's parameter table.
    pub slot: usize,
    /// −1..1, in normalized units per unit of source.
    pub amount: f32,
}

const EMPTY_ROUTE: Route = Route {
    source: 0,
    param_id: 0,
    slot: 0,
    amount: 0.0,
};

/// Up to [`MAX_ROUTES`] routes over a parameter table of `SLOTS` entries.
pub struct ModMatrix<const SLOTS: usize> {
    routes: [Route; MAX_ROUTES],
    len: usize,
    routed: [bool; SLOTS],
    /// Slots with at least one route, each once.
    dests: [usize; SLOTS],
    dest_len: usize,
}

impl<const SLOTS: usize> ModMatrix<SLOTS> {
    pub fn new() -> Self {
        Self {
            routes: [EMPTY_ROUTE; MAX_ROUTES],
            len: 0,
            routed: [false; SLOTS],
            dests: [0; SLOTS],
            dest_len: 0,
        }
    }

    /// Add, update (same source and slot) or, with amount 0, remove a route. Amounts are
    /// clamped to −1..1. O(`MAX_ROUTES`), no allocation.
    pub fn set(
        &mut self,
        source: usize,
        param_id: ParamId,
        slot: usize,
        amount: f32,
    ) -> Result<(), &'static str> {
        if slot >= SLOTS {
            return Err("parameter slot out of range");
        }
        let amount = if amount.is_finite() {
            amount.clamp(-1.0, 1.0)
        } else {
            0.0
        };
        let existing = self.routes[..self.len]
            .iter()
            .position(|r| r.source == source && r.slot == slot);
        match existing {
            Some(i) if amount == 0.0 => {
                // Keep insertion order (it's what `routes()` reports) rather than swap-remove.
                self.routes.copy_within(i + 1..self.len, i);
                self.len -= 1;
            }
            Some(i) => self.routes[i].amount = amount,
            None if amount == 0.0 => return Ok(()),
            None => {
                if self.len == MAX_ROUTES {
                    return Err("modulation route capacity reached");
                }
                self.routes[self.len] = Route {
                    source,
                    param_id,
                    slot,
                    amount,
                };
                self.len += 1;
            }
        }
        self.rebuild_dests();
        Ok(())
    }

    pub fn clear(&mut self) {
        self.len = 0;
        self.rebuild_dests();
    }

    fn rebuild_dests(&mut self) {
        self.routed = [false; SLOTS];
        self.dest_len = 0;
        for r in &self.routes[..self.len] {
            if !self.routed[r.slot] {
                self.routed[r.slot] = true;
                self.dests[self.dest_len] = r.slot;
                self.dest_len += 1;
            }
        }
    }

    pub fn routes(&self) -> &[Route] {
        &self.routes[..self.len]
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Slots with at least one route.
    pub fn dests(&self) -> &[usize] {
        &self.dests[..self.dest_len]
    }

    pub fn is_routed(&self, slot: usize) -> bool {
        self.routed.get(slot).copied().unwrap_or(false)
    }

    /// Add `amount × sources[route.source]` into `acc[route.slot]` for every route.
    #[inline]
    pub fn accumulate(&self, sources: &[f32], acc: &mut [f32; SLOTS]) {
        for r in &self.routes[..self.len] {
            acc[r.slot] += r.amount * sources[r.source];
        }
    }
}

impl<const SLOTS: usize> Default for ModMatrix<SLOTS> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_update_remove_never_reallocate() {
        let mut m = ModMatrix::<8>::new();
        let ptr = m.routes().as_ptr();
        m.set(0, 31, 3, 0.5).unwrap();
        m.set(2, 31, 3, -0.25).unwrap();
        m.set(0, 31, 3, 0.75).unwrap(); // update in place
        assert_eq!(m.routes().len(), 2);
        assert_eq!(m.routes()[0].amount, 0.75);
        assert_eq!(m.dests(), &[3]);
        m.set(0, 31, 3, 0.0).unwrap(); // remove
        assert_eq!(m.routes().len(), 1);
        assert!(m.is_routed(3));
        m.set(2, 31, 3, 0.0).unwrap();
        assert!(m.is_empty() && !m.is_routed(3) && m.dests().is_empty());
        assert_eq!(m.routes().as_ptr(), ptr);
    }

    #[test]
    fn capacity_is_fixed() {
        let mut m = ModMatrix::<{ MAX_ROUTES + 1 }>::new();
        for slot in 0..MAX_ROUTES {
            m.set(0, slot as ParamId, slot, 0.1).unwrap();
        }
        assert!(m.set(0, 99, MAX_ROUTES, 0.1).is_err());
        // Updating an existing route still works when full.
        assert!(m.set(0, 0, 0, 0.2).is_ok());
    }

    #[test]
    fn amounts_clamp_and_accumulate() {
        let mut m = ModMatrix::<4>::new();
        m.set(0, 1, 1, 3.0).unwrap();
        m.set(1, 1, 1, -0.5).unwrap();
        let mut acc = [0.0; 4];
        m.accumulate(&[1.0, 0.5], &mut acc);
        assert_eq!(acc[1], 1.0 - 0.25);
        assert!(m.set(0, 9, 4, 0.5).is_err(), "slot out of range");
    }

    #[test]
    fn source_ids_round_trip() {
        for s in ModSource::ALL {
            assert_eq!(ModSource::from_id(s.id()), Some(s));
            assert_eq!(ModSource::ALL[s.index()], s);
        }
        assert_eq!(ModSource::from_id("nope"), None);
    }
}
