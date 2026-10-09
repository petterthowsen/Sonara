//! Built-in instruments: the PolySynth, the drum instruments, the Sampler and the SFZ sampler.

#[cfg(test)]
mod drum_conformance;
pub mod drums;
mod polysynth;
mod sampler;
pub mod sampler_zones;
mod sfizz_device;
pub mod sfizz_keys;

pub use drums::{DrumHost, DrumParams, DrumVoice, GlobalParams, GLOBAL_SPECS};
pub use polysynth::PolySynthDevice;
pub use sampler::SamplerDevice;
pub use sfizz_device::SfizzDevice;
