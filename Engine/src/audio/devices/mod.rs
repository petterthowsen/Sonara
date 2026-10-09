//! Audio devices: the `AudioDevice` trait and every built-in device, grouped by kind.
//!
//! This module re-exports everything callers use, so `crate::audio::devices::DevicePath` and
//! `ParamInfo` work wherever the type lives.

pub mod clap_host;
mod containers;
mod device;
mod effects;
mod factory;
mod instruments;
pub mod note_fx;
pub mod param_table;
mod params;
mod sleep;

pub use clap_host::{PluginDescriptor, PluginScanner};
pub use containers::{
    container, parse_osc_device_addr, ChainDevice, DeviceContainer, DevicePath, DrumMachineDevice,
    LayerDevice,
};
pub use device::*;
pub use effects::{
    compressor, effect, eq, ChorusDevice, DelayDevice, EqDevice, FilterDevice, MultibandDevice,
    PhaserDevice, ReverbDevice, SpectrumAnalyzerDevice, UtilityDevice,
};
pub use factory::{
    create_drum, create_effect, create_note_effect, DeviceFactory, DRUM_IDS, EFFECT_IDS,
    NOTE_EFFECT_IDS,
};
pub use instruments::{
    sampler, sfizz_keys, DrumHost, DrumParams, DrumVoice, GlobalParams, PolySynthDevice,
    SamplerDevice, SfizzDevice, GLOBAL_SPECS,
};
pub use params::*;
pub use sleep::*;
