//! Generic IPC Infrastructure for Plugin Hosting
//!
//! This module provides reusable components for hosting plugins in separate processes:
//! - Protocol definitions for commands and responses
//! - Process management (spawning, monitoring, communication)
//! - Shared memory ring buffers for lock-free audio/MIDI exchange
//! - Platform-specific shared memory abstractions
//!
//! These components are plugin-format agnostic and can be used for CLAP, VST3, LV2, etc.

pub mod platform_shm;
pub mod process_manager;
pub mod protocol;
pub mod shared_memory;
pub mod wire;

pub use platform_shm::PlatformSharedMemory;
pub use process_manager::{InstanceConnection, PluginProcess, ProcessManager, REQUEST_TIMEOUT};
pub use protocol::{
    ControlData, HostMessage, HostRequest, InstanceId, MidiEvent, PluginCommand, PluginEvent,
    PluginParameterInfo, PluginResponse, RequestId, RingBufferStats, SharedMemoryLayout, NO_REPLY,
};
pub use shared_memory::{AudioRingBuffer, MidiEventQueue, SharedMemory};
