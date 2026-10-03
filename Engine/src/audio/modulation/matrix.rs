//! A fixed-capacity route matrix for one device instance.
//!
//! Routes point at a **modulator slot** (an index into the owning device's modulator array, up
//! to [`super::MAX_MODULATORS`]) and at a target parameter slot. The matrix knows nothing about
//! any device: evaluation samples the modulator values, calls [`ModMatrix::accumulate`] to sum
//! `amount × value` per slot, and adds that to the base normalized value
//! (`clamp(base + Σ, 0, 1)`). The result lives next to the base and is never written back into
//! it (ADR-0010, ADR-0014).
//!
//! Adding, updating and removing never allocate.

use crate::audio::devices::ParamId;

/// Routes one device can hold. Adding, updating and removing never allocate.
pub const MAX_ROUTES: usize = 64;

/// One modulator → parameter connection.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Route {
    /// Index into the owning device's modulator array.
    pub mod_slot: usize,
    pub param_id: ParamId,
    /// Index into the device's parameter table.
    pub slot: usize,
    /// −1..1, in normalized units per unit of modulator value.
    pub amount: f32,
}

const EMPTY_ROUTE: Route = Route {
    mod_slot: 0,
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

    /// Add, update (same modulator and slot) or, with amount 0, remove a route. Amounts are
    /// clamped to −1..1. O(`MAX_ROUTES`), no allocation.
    pub fn set(
        &mut self,
        mod_slot: usize,
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
            .position(|r| r.mod_slot == mod_slot && r.slot == slot);
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
                    mod_slot,
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

    /// Add `amount × values[route.mod_slot]` into `acc[route.slot]` for every route.
    #[inline]
    pub fn accumulate(&self, values: &[f32], acc: &mut [f32; SLOTS]) {
        for r in &self.routes[..self.len] {
            acc[r.slot] += r.amount * values[r.mod_slot];
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
}
