//! Plugin GUI Management
//!
//! Handles opening, closing, and querying plugin GUI windows.

use crate::audio::ipc::{InstanceConnection, PluginCommand, PluginResponse, REQUEST_TIMEOUT};
use std::time::Duration;
use tracing::info;

/// An open plugin GUI
#[derive(Debug, Clone, Copy)]
pub struct OpenedGui {
    pub width: u32,
    pub height: u32,
    pub resizable: bool,
    /// The plugin runs in its own window: it refused the embedded mode it was asked for
    pub floating: bool,
}

/// Open plugin GUI window. On an already-open GUI this reports its current state.
pub fn open_gui(
    connection: &InstanceConnection,
    device_name: &str,
    window_handle: Option<u64>,
) -> Result<OpenedGui, String> {
    // Generous timeout: opening a GUI may connect to X11/Wayland and load resources
    match connection.request(
        PluginCommand::OpenGui { window_handle },
        Duration::from_secs(5),
    )? {
        PluginResponse::GuiOpened {
            width,
            height,
            is_resizable,
            floating,
        } => {
            info!(
                "✅ Plugin GUI opened: {} ({}x{}, resizable: {}, floating: {})",
                device_name, width, height, is_resizable, floating
            );
            Ok(OpenedGui {
                width,
                height,
                resizable: is_resizable,
                floating,
            })
        }
        PluginResponse::GuiError { error } => Err(error),
        other => Err(format!("Unexpected response to OpenGui: {:?}", other)),
    }
}

/// Send a GUI command answered with `GuiSize`; returns that size.
fn request_gui_size(
    connection: &InstanceConnection,
    cmd: PluginCommand,
) -> Result<(u32, u32), String> {
    let name = format!("{:?}", cmd);
    match connection.request(cmd, REQUEST_TIMEOUT)? {
        PluginResponse::GuiSize { width, height } => Ok((width, height)),
        PluginResponse::GuiError { error } => Err(error),
        other => Err(format!("Unexpected response to {}: {:?}", name, other)),
    }
}

/// Show or hide an open GUI. Returns its current size.
pub fn set_gui_visible(
    connection: &InstanceConnection,
    visible: bool,
) -> Result<(u32, u32), String> {
    request_gui_size(connection, PluginCommand::SetGuiVisible { visible })
}

/// Ask a resizable GUI to take this size. Returns the size the plugin settled on.
pub fn set_gui_size(
    connection: &InstanceConnection,
    width: u32,
    height: u32,
) -> Result<(u32, u32), String> {
    request_gui_size(connection, PluginCommand::SetGuiSize { width, height })
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
