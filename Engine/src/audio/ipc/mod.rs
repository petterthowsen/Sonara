//! Generic IPC Infrastructure for Plugin Hosting
//!
//! This module provides reusable components for hosting plugins in separate processes:
//! - Protocol definitions for commands and responses
//! - Process management (spawning, monitoring, communication)
//! - Shared memory for the per-block audio handshake, plus the host doorbell
//! - Platform-specific shared memory abstractions
//!
//! These components are plugin-format agnostic and can be used for CLAP, VST3, LV2, etc.

pub mod futex;
pub mod hosting;
pub mod platform_shm;
pub mod process_manager;
pub mod protocol;
pub mod shared_memory;
pub mod wire;

pub use hosting::{HostAssignment, HostingMode, HostingPolicy};
pub use platform_shm::PlatformSharedMemory;
pub use process_manager::{
    HostCrash, HostExit, InstanceConnection, PluginProcess, ProcessManager, REQUEST_TIMEOUT,
};
pub use protocol::{
    BlockControl, BlockEvent, Doorbell, HostMessage, HostRequest, InstanceId, PluginCommand,
    PluginEvent, PluginParameterInfo, PluginResponse, RequestId, SharedMemoryLayout,
    EVENT_NOTE_OFF, EVENT_NOTE_ON, EVENT_PARAM, MAX_BLOCK_EVENTS, MAX_PLUGIN_CHANNELS, NO_REPLY,
};
pub use shared_memory::{HostSharedMemory, SharedMemory};
