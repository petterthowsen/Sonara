/// Digital Signal Processing (DSP) utilities
///
/// This module contains reusable DSP building blocks for audio synthesis
/// and processing, optimized for real-time performance.
pub mod delay_line;
pub mod denormal;
pub mod env_follower;
pub mod envelope;
pub mod gain;
pub mod ladder;
pub mod lfo;
pub mod linear_svf;
pub mod log_spectrum;
pub mod noise;
pub mod one_pole;
pub mod one_shot_env;
pub mod oscillator;
pub mod oversampler;
pub mod saturate;
pub mod simd;
pub mod smoothing;
pub mod spectrum;
pub mod svf;
pub mod sweep_osc;
pub mod tempo_sync;
#[cfg(test)]
pub mod test_util;

pub use envelope::{AdsrEnvelope, AdsrState};
pub use lfo::{Lfo, LfoShape};
pub use noise::{PinkNoise, Rng, WhiteNoise};
pub use one_shot_env::{BurstEnvelope, OneShotEnvelope};
pub use oscillator::{fast_sin, Oscillator, Waveform};
pub use saturate::{drive, drive_params, fast_tanh, soft_clip};
pub use simd::mix_blocks;
pub use smoothing::SmoothedParam;
pub use svf::{FilterMode, Svf, SvfCoefs};
pub use sweep_osc::{sweep_hz, SweepOsc, SweepShape};
