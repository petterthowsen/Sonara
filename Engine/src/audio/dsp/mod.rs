/// Digital Signal Processing (DSP) utilities
///
/// This module contains reusable DSP building blocks for audio synthesis
/// and processing, optimized for real-time performance.

pub mod envelope;
pub mod oscillator;
pub mod simd;

pub use envelope::{AdsrEnvelope, AdsrState};
pub use oscillator::{Oscillator, Waveform};
pub use simd::mix_blocks;

