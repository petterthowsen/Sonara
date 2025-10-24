//! CLAP plugin hosting support
//!
//! This module provides CLAP plugin loading and hosting capabilities using the clack-host library.
//! Plugins are adapted to work with Sonara's AudioDevice trait for seamless integration.

pub mod discovery;
pub mod host_impl;
pub mod adapter;
pub mod ipc_protocol;
pub mod platform_shm;
pub mod shared_memory;
pub mod process_manager;
pub mod subprocess_adapter;

pub use discovery::{PluginScanner, PluginDescriptor};
pub use host_impl::SonaraHost;
pub use adapter::ClapDeviceAdapter;
pub use process_manager::ProcessManager;
pub use subprocess_adapter::SubprocessClapAdapter;

use std::fmt;

/// Errors that can occur during plugin operations
#[derive(Debug)]
pub enum PluginError {
    /// Plugin file not found or inaccessible
    NotFound(String),
    /// Failed to load plugin bundle
    LoadError(String),
    /// Plugin doesn't support required features
    UnsupportedPlugin(String),
    /// Plugin initialization failed
    InitializationFailed(String),
    /// Plugin activation failed
    ActivationFailed(String),
    /// Invalid plugin ID
    InvalidPluginId(String),
    /// General error
    Other(String),
}

impl fmt::Display for PluginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PluginError::NotFound(msg) => write!(f, "Plugin not found: {}", msg),
            PluginError::LoadError(msg) => write!(f, "Failed to load plugin: {}", msg),
            PluginError::UnsupportedPlugin(msg) => write!(f, "Unsupported plugin: {}", msg),
            PluginError::InitializationFailed(msg) => write!(f, "Plugin initialization failed: {}", msg),
            PluginError::ActivationFailed(msg) => write!(f, "Plugin activation failed: {}", msg),
            PluginError::InvalidPluginId(msg) => write!(f, "Invalid plugin ID: {}", msg),
            PluginError::Other(msg) => write!(f, "Plugin error: {}", msg),
        }
    }
}

impl std::error::Error for PluginError {}

impl From<Box<dyn std::error::Error>> for PluginError {
    fn from(err: Box<dyn std::error::Error>) -> Self {
        PluginError::Other(err.to_string())
    }
}

