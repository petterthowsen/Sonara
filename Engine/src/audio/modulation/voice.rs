//! The snapshot a voice-modulating device receives from its [`ModulatedDevice`] wrapper.
//!
//! A poly-capable device (`supports_voice_modulation`) evaluates its modulators per voice, so it
//! needs the modulator *definitions* — kind and parameters — and the routes that target its own
//! parameters. The wrapper owns the runtime (phase, envelope stage, note stream) and hands over a
//! fresh [`VoiceModSpec`] whenever a modulator or route changes (ADR-0014). Routes into the
//! device from an enclosing container are not part of the spec: they arrive as a mono offset
//! through `set_param_mod`.
//!
//! The snapshot is `Copy` and fixed-capacity so the hand-off allocates nothing.

use super::kinds::ModParams;
use super::{ModulatorKind, MAX_MODULATORS, MAX_ROUTES};
use crate::audio::devices::ParamId;

/// One route from a modulator slot to the owning device's own parameter.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VoiceRoute {
    /// Index into the device's modulator array.
    pub mod_slot: usize,
    pub param_id: ParamId,
    /// −1..1, in normalized units per unit of modulator value.
    pub amount: f32,
}

/// One modulator→modulator route (spec 033): a voice evaluates `mod_slot`'s value, scaled by
/// `amount`, as a parameter offset on the modulator in `target_slot`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VoiceModRoute {
    /// The source modulator slot.
    pub mod_slot: usize,
    /// The target modulator slot.
    pub target_slot: usize,
    pub param_id: ParamId,
    /// −1..1, in normalized units per unit of modulator value.
    pub amount: f32,
}

/// A copy of the wrapper's modulator definitions and self-targeting routes.
#[derive(Clone, Copy, Debug)]
pub struct VoiceModSpec {
    /// The kind in each modulator slot, or `None` when the slot is empty.
    pub kinds: [Option<ModulatorKind>; MAX_MODULATORS],
    /// Each slot's normalized parameters (unused slots keep their default block).
    pub params: [ModParams; MAX_MODULATORS],
    pub routes: [VoiceRoute; MAX_ROUTES],
    pub route_len: usize,
    /// Mod→mod routes between per-voice modulators (spec 033).
    pub mod_routes: [VoiceModRoute; MAX_ROUTES],
    pub mod_route_len: usize,
}

impl VoiceModSpec {
    /// The empty spec: no modulators, no routes.
    pub fn empty() -> Self {
        Self {
            kinds: [None; MAX_MODULATORS],
            params: [ModParams::new(ModulatorKind::Lfo); MAX_MODULATORS],
            routes: [VoiceRoute {
                mod_slot: 0,
                param_id: 0,
                amount: 0.0,
            }; MAX_ROUTES],
            route_len: 0,
            mod_routes: [VoiceModRoute {
                mod_slot: 0,
                target_slot: 0,
                param_id: 0,
                amount: 0.0,
            }; MAX_ROUTES],
            mod_route_len: 0,
        }
    }

    pub fn kind(&self, slot: usize) -> Option<ModulatorKind> {
        self.kinds.get(slot).copied().flatten()
    }

    pub fn params(&self, slot: usize) -> Option<&ModParams> {
        self.kinds.get(slot)?.is_some().then(|| &self.params[slot])
    }

    pub fn routes(&self) -> &[VoiceRoute] {
        &self.routes[..self.route_len]
    }

    /// The mod→mod routes between per-voice modulators.
    pub fn mod_routes(&self) -> &[VoiceModRoute] {
        &self.mod_routes[..self.mod_route_len]
    }

    /// True when the modulator kinds and parameters match `other`, so only routes changed. A
    /// poly device can then keep its per-voice states and just re-read the routes.
    pub fn same_definitions(&self, other: &Self) -> bool {
        self.kinds == other.kinds
            && self
                .params
                .iter()
                .zip(other.params.iter())
                .all(|(a, b)| a == b)
    }
}

impl Default for VoiceModSpec {
    fn default() -> Self {
        Self::empty()
    }
}
