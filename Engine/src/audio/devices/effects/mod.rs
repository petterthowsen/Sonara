//! Built-in effects: the spec 012 effects, the utility and the spectrum analyzer, plus the
//! helpers they share (`effect`).

mod chorus;
pub mod compressor;
mod delay;
pub mod effect;
#[cfg(test)]
mod effect_conformance;
pub mod eq;
mod filter;
mod multiband;
mod phaser;
mod pitch_shifter;
mod reverb;
mod saturator;
mod spectrum_analyzer;
pub mod split;
mod utility;

pub use chorus::ChorusDevice;
pub use delay::DelayDevice;
pub use eq::EqDevice;
pub use filter::FilterDevice;
pub use multiband::MultibandDevice;
pub use phaser::PhaserDevice;
pub use pitch_shifter::PitchShifterDevice;
pub use reverb::ReverbDevice;
pub use saturator::SaturatorDevice;
pub use spectrum_analyzer::SpectrumAnalyzerDevice;
pub use split::SplitDevice;
pub use utility::UtilityDevice;
