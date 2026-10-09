//! Built-in instruments: the PolySynth, the drum instruments, the Sampler and the SFZ sampler.

#[cfg(test)]
mod drum_conformance;
pub mod drums;
mod polysynth;
pub mod sampler;
mod sfizz_device;
pub mod sfizz_keys;

pub use drums::{DrumHost, DrumParams, DrumVoice, GlobalParams, GLOBAL_SPECS};
pub use polysynth::PolySynthDevice;
pub use sampler::SamplerDevice;
pub use sfizz_device::SfizzDevice;
