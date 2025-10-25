//! Plugin GUI Management
//!
//! Handles opening, closing, and querying plugin GUI windows.

use crate::audio::ipc::{PluginCommand, PluginResponse, ProcessManager};
use std::sync::Arc;
use tracing::info;

/// Open plugin GUI window
/// Returns (width, height, is_resizable) if successful
pub fn open_gui(
    process_manager: &Arc<ProcessManager>,
    process_key: &str,
    device_name: &str,
    window_handle: Option<u64>,
) -> Result<(u32, u32, bool), String> {
    let process = process_manager.get_process(process_key)
        .ok_or_else(|| "Plugin process not found".to_string())?;

    let mut process = process.lock().unwrap();

    // Set a generous timeout for GUI operations (plugins can take time to open windows)
    // GUI initialization may involve X11/Wayland connection, resource loading, etc.
    process.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;

    process.send_command(PluginCommand::OpenGui { window_handle })?;

    let result = match process.recv_response()? {
        PluginResponse::GuiOpened { width, height, is_resizable } => {
            info!("✅ Plugin GUI opened: {} ({}x{}, resizable: {})", device_name, width, height, is_resizable);
            Ok((width, height, is_resizable))
        }
        PluginResponse::GuiError { error } => Err(error),
        _ => Err("Unexpected response".to_string()),
    };

    // Reset timeout to default (no timeout)
    let _ = process.set_read_timeout(None);

    result
}

/// Close plugin GUI window
pub fn close_gui(
    process_manager: &Arc<ProcessManager>,
    process_key: &str,
    device_name: &str,
) -> Result<(), String> {
    let process = process_manager.get_process(process_key)
        .ok_or_else(|| "Plugin process not found".to_string())?;
    
    let mut process = process.lock().unwrap();
    process.send_command(PluginCommand::CloseGui)?;
    
    match process.recv_response()? {
        PluginResponse::GuiClosed => {
            info!("Closed GUI: {}", device_name);
            Ok(())
        }
        PluginResponse::GuiError { error } => Err(error),
        _ => Err("Unexpected response".to_string()),
    }
}

/// Check if plugin supports GUI
pub fn has_gui(
    process_manager: &Arc<ProcessManager>,
    process_key: &str,
) -> bool {
    let Some(process) = process_manager.get_process(process_key) else {
        return false;
    };
    
    let mut process = match process.lock() {
        Ok(p) => p,
        Err(_) => return false,
    };
    
    if let Ok(PluginResponse::HasGuiResponse { supported }) = 
        process.send_command(PluginCommand::HasGui)
            .and_then(|_| process.recv_response()) 
    {
        supported
    } else {
        false
    }
}

