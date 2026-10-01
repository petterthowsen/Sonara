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
pub mod one_pole;
pub mod oscillator;
pub mod oversampler;
pub mod simd;
pub mod smoothing;
pub mod spectrum;
pub mod svf;
pub mod tempo_sync;
#[cfg(test)]
pub mod test_util;

pub use envelope::{AdsrEnvelope, AdsrState};
pub use lfo::{Lfo, LfoShape};
pub use oscillator::{Oscillator, Waveform};
pub use simd::mix_blocks;
pub use smoothing::SmoothedParam;
pub use svf::{FilterMode, Svf, SvfCoefs};
