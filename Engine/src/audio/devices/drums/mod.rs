//! Shared foundation for the drum instruments (spec 013, Phase 0).
//!
//! A drum is a parameter table plus a [`DrumVoice`] implementation. [`DrumHost`] runs it as an
//! [`AudioDevice`](super::AudioDevice): sample-accurate triggers, a two-slot retrigger
//! crossfade, the shared global parameters and instrument sleep. The [`GlobalParams`] block
//! (IDs 90–92) is shared by every drum.

pub mod clap;
pub mod hat;
pub mod host;
pub mod kick;
pub mod layers;
pub mod params;
pub mod snare;

pub use host::DrumHost;
pub use params::{GlobalParams, GLOBAL_SPECS};

use crate::audio::devices::param_table::ParamSpec;
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::Rng;

/// The host-level parameters a drum voice reads once per block.
#[derive(Clone, Copy, Debug)]
pub struct DrumParams {
    /// Velocity sensitivity, 0–1. The host turns it into the velocity curve; the voice uses it
    /// to scale its velocity-driven brightness.
    pub velocity_sens: f32,
    /// Output gain in dB (the host applies it).
    pub output_db: f32,
    /// Humanize amount, 0–1: at full, ±10 cents of pitch and ±5 % of decay per hit.
    pub humanize: f32,
}

impl Default for DrumParams {
    fn default() -> Self {
        // The shared block's defaults: Velocity 50 %, Output 0 dB, Humanize 0.
        Self {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 0.0,
        }
    }
}

/// One drum's synthesis voice. Mono; the host copies the mix to both output channels.
///
/// The host owns two slots and alternates between them, so a retrigger starts a fresh voice
/// (phase reset: every hit sounds the same) while the previous one fades out over 3 ms.
pub trait DrumVoice: Send {
    /// Build a silent voice at `sample_rate`.
    fn new(sample_rate: f32) -> Self
    where
        Self: Sized;

    fn set_sample_rate(&mut self, sample_rate: f32);

    /// The voice's parameter table. Must include [`GLOBAL_SPECS`].
    fn specs() -> &'static [ParamSpec]
    where
        Self: Sized;

    fn set_parameter(&mut self, id: ParamId, norm: ParamValue);

    fn get_parameter(&self, id: ParamId) -> Option<ParamValue>;

    /// Per-block parameter view, applied before the block is rendered.
    fn set_params(&mut self, params: &DrumParams);

    /// Start a hit. `velocity` is the raw 0–1 value (the host applies the velocity curve);
    /// `rng` draws any per-hit humanization.
    fn trigger(&mut self, note: u8, velocity: f32, rng: &mut Rng);

    /// Add this block's output into `out`; must not clear it.
    fn render(&mut self, out: &mut [f32]);

    /// Note-off. One-shot voices ignore it; a gated voice releases.
    fn release(&mut self);

    /// True while the voice can produce output.
    fn is_active(&self) -> bool;

    fn reset(&mut self);

    /// Unique device identifier, e.g. `"sonara.builtin.kick"`.
    fn device_id() -> &'static str
    where
        Self: Sized;

    /// Human-readable device name.
    fn device_name() -> &'static str
    where
        Self: Sized;
}
