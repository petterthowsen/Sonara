//! IPC Protocol types for plugin host communication
//!
//! This module defines the command/response protocol used for communication
//! between the main engine and the plugin host subprocess via TCP sockets.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Commands sent from engine to plugin host
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginCommand {
    Initialize {
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
        shm_name: String,
    },
    Activate,
    Deactivate,
    StartProcessing,
    StopProcessing,
    SetParameter { param_id: u32, value: f32 },
    GetParameter { param_id: u32 },
    GetParameterInfo,
    OpenGui {
        window_handle: Option<u64>,
    },
    CloseGui,
    HasGui,
    SaveState,
    LoadState { state_base64: String },
    Reset,
    Shutdown,
}

/// Responses sent from plugin host to engine
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginResponse {
    InitializeSuccess {
        device_name: String,
        device_vendor: String,
        device_version: String,
        category: String,
    },
    InitializeError { error: String },
    ActivateResult { success: bool, error: Option<String> },
    DeactivateResult { success: bool, error: Option<String> },
    ProcessingStarted,
    ProcessingStopped,
    ParameterValue { param_id: u32, value: f32 },
    ParameterInfo { params: Vec<PluginParameterInfo> },
    GuiOpened {
        width: u32,
        height: u32,
        is_resizable: bool,
    },
    GuiClosed,
    HasGuiResponse { supported: bool },
    GuiError { error: String },
    StateSaved { state_base64: String },
    StateLoadResult { success: bool, error: Option<String> },
    ResetComplete,
    Error { command: String, error: String },
    ShutdownAck,
    ParameterValueChanged { param_id: u32, value: f32 },
    GuiResizeRequest { width: u32, height: u32 },
}

/// Information about a plugin parameter
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginParameterInfo {
    pub id: u32,
    pub name: String,
    pub unit: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub is_automation_safe: bool,
}
