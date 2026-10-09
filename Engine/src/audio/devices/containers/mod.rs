//! Devices that hold other devices: the Chain, the Layer and the Drum Machine, plus the shared
//! container operations (`container`).

mod chain;
pub mod container;
mod drum_machine;
mod layer;

pub use chain::ChainDevice;
pub use container::{parse_osc_device_addr, DeviceContainer, DevicePath};
pub use drum_machine::DrumMachineDevice;
pub use layer::LayerDevice;
