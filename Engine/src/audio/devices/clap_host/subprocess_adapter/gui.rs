//! Plugin GUI Management
//!
//! Handles opening, closing, and querying plugin GUI windows.

use crate::audio::ipc::{InstanceConnection, PluginCommand, PluginResponse, REQUEST_TIMEOUT};
use std::time::Duration;
use tracing::info;

/// Open plugin GUI window
/// Returns (width, height, is_resizable) if successful
pub fn open_gui(
    connection: &InstanceConnection,
    device_name: &str,
    window_handle: Option<u64>,
) -> Result<(u32, u32, bool), String> {
    // Generous timeout: opening a GUI may connect to X11/Wayland and load resources
    match connection.request(
        PluginCommand::OpenGui { window_handle },
        Duration::from_secs(5),
    )? {
        PluginResponse::GuiOpened {
            width,
            height,
            is_resizable,
        } => {
            info!(
                "✅ Plugin GUI opened: {} ({}x{}, resizable: {})",
                device_name, width, height, is_resizable
            );
            Ok((width, height, is_resizable))
        }
        PluginResponse::GuiError { error } => Err(error),
        other => Err(format!("Unexpected response to OpenGui: {:?}", other)),
    }
}

/// Close plugin GUI window
pub fn close_gui(connection: &InstanceConnection, device_name: &str) -> Result<(), String> {
    match connection.request(PluginCommand::CloseGui, Duration::from_secs(2)) {
        Ok(PluginResponse::GuiClosed) => {
            info!("Closed GUI: {}", device_name);
            Ok(())
        }
        Ok(PluginResponse::GuiError { error }) => Err(error),
        Ok(other) => Err(format!("Unexpected response to CloseGui: {:?}", other)),
        Err(e) => {
            // If timeout or other error, still consider GUI closed to avoid blocking
            // The subprocess will clean up the GUI when it processes the command
            tracing::warn!(
                "GUI close response timeout/error (non-fatal): {} - considering GUI closed",
                e
            );
            Ok(())
        }
    }
}

/// Check if plugin supports GUI
pub fn has_gui(connection: &InstanceConnection) -> bool {
    matches!(
        connection.request(PluginCommand::HasGui, REQUEST_TIMEOUT),
        Ok(PluginResponse::HasGuiResponse { supported: true })
    )
}
