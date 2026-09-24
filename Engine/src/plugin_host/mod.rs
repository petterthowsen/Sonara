//! Plugin Host Modules
//!
//! This module contains all the components for the plugin host subprocess,
//! organized into logical units for better maintainability.

pub mod commands;
pub mod event_loop;
pub mod host;
pub mod operations;
pub mod state;
pub mod x11_error;

// Re-export commonly used types
pub use commands::process_command;
pub use event_loop::run_plugin_host;
pub use host::{SubprocessHost, SubprocessHostMainThread, SubprocessHostShared};
pub use state::PluginState;
pub use x11_error::install_x11_error_handler;
