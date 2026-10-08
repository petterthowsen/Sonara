/// Digital Signal Processing (DSP) utilities
///
/// This module contains reusable DSP building blocks for audio synthesis
/// and processing, optimized for real-time performance.
pub mod crossover;
pub mod delay_line;
pub mod denormal;
pub mod env_follower;
pub mod gain;
pub mod ladder;
pub mod linear_svf;
pub mod log_spectrum;
pub mod noise;
pub mod one_pole;
pub mod one_shot_env;
pub mod oscillator;
pub mod oversampler;
pub mod saturate;
pub mod smoothing;
pub mod spectrum;
pub mod svf;
pub mod sweep_osc;
pub mod tempo_sync;
#[cfg(test)]
pub mod test_util;

pub use noise::{PinkNoise, Rng, WhiteNoise};
pub use one_shot_env::{BurstEnvelope, OneShotEnvelope};
pub use oscillator::{fast_sin, Oscillator};
pub use saturate::{drive, drive_params, fast_tanh, soft_clip};
pub use smoothing::SmoothedParam;
pub use svf::{FilterMode, Svf, SvfCoefs};
pub use sweep_osc::{sweep_hz, SweepOsc, SweepShape};
