//! Plugin Host Modules
//!
//! This module contains all the components for the plugin host subprocess,
//! organized into logical units for better maintainability.

pub mod protocol;
pub mod host;
pub mod ipc_utils;
pub mod state;
pub mod operations;
pub mod commands;
pub mod event_loop;

// Re-export commonly used types
pub use protocol::{PluginCommand, PluginResponse, PluginParameterInfo};
pub use host::{SubprocessHost, SubprocessHostShared, SubprocessHostMainThread};
pub use state::PluginState;
pub use commands::process_command;
pub use event_loop::run_plugin_host;
