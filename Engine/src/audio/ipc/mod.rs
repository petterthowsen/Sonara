//! Generic IPC Infrastructure for Plugin Hosting
//!
//! This module provides reusable components for hosting plugins in separate processes:
//! - Protocol definitions for commands and responses
//! - Process management (spawning, monitoring, communication)
//! - Shared memory ring buffers for lock-free audio/MIDI exchange
//! - Platform-specific shared memory abstractions
//!
//! These components are plugin-format agnostic and can be used for CLAP, VST3, LV2, etc.

pub mod protocol;
pub mod process_manager;
pub mod shared_memory;
pub mod platform_shm;

pub use protocol::{
    PluginCommand, PluginResponse, PluginParameterInfo,
    SharedMemoryLayout, MidiEvent, ControlData, RingBufferStats,
};
pub use process_manager::{ProcessManager, PluginProcess};
pub use shared_memory::{SharedMemory, AudioRingBuffer, MidiEventQueue};
pub use platform_shm::PlatformSharedMemory;

