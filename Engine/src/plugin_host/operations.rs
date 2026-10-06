//! Plugin operations (loading, GUI management)
//!
//! High-level operations for managing plugin lifecycle,
//! including loading, GUI creation, and window management.

use std::path::PathBuf;
use std::sync::Arc;
use tracing::{error, info, warn};

use clack_extensions::gui::{GuiApiType, GuiConfiguration, GuiSize, PluginGui, Window};
use clack_host::prelude::*;

use crate::audio::ipc::{HostMessage, InstanceId};
use crate::plugin_host::host::{SubprocessHost, SubprocessHostMainThread, SubprocessHostShared};

/// Load a CLAP plugin
pub fn load_plugin(
    plugin_path: &PathBuf,
    plugin_id: &str,
    _sample_rate: f32,
    _max_buffer_size: usize,
    instance_id: InstanceId,
    event_tx: std::sync::mpsc::Sender<HostMessage>,
) -> Result<
    (
        PluginBundle,
        PluginInstance<SubprocessHost>,
        Arc<SubprocessHostShared>,
    ),
    String,
> {
    // Load bundle
    let bundle = unsafe {
        PluginBundle::load(plugin_path).map_err(|e| format!("Failed to load bundle: {:?}", e))?
    };

    // Find plugin descriptor
    let factory = bundle
        .get_plugin_factory()
        .ok_or_else(|| "No plugin factory".to_string())?;

    let descriptor = factory
        .plugin_descriptors()
        .find(|d| {
            d.id()
                .and_then(|id| id.to_str().ok())
                .map(|id| id == plugin_id)
                .unwrap_or(false)
        })
        .ok_or_else(|| format!("Plugin {} not found in bundle", plugin_id))?;

    // Create host info
    let host_info = HostInfo::new(
        "Sonara Plugin Host",
        "Sonara Project",
        "https://thowsenmedia.itch.io/sonara",
        "0.1.0",
    )
    .map_err(|e| format!("Failed to create host info: {:?}", e))?;

    let plugin_id_cstr = descriptor
        .id()
        .ok_or_else(|| "Missing plugin ID".to_string())?;

    let plugin_name = descriptor
        .name()
        .and_then(|name| name.to_str().ok())
        .filter(|name| !name.is_empty())
        .unwrap_or(plugin_id)
        .to_string();

    // Create shared state for timer and GUI support
    let shared = Arc::new(SubprocessHostShared::new(
        instance_id,
        &plugin_name,
        event_tx,
    ));
    let shared_for_instance = Arc::clone(&shared);

    // Create plugin instance
    let instance = PluginInstance::<SubprocessHost>::new(
        move |_| shared_for_instance.as_ref().clone(), // Clone the shared state for plugin
        |shared_ref| SubprocessHostMainThread { shared: shared_ref }, // Main thread state
        &bundle,
        plugin_id_cstr,
        &host_info,
    )
    .map_err(|e| format!("Failed to create plugin instance: {:?}", e))?;

    info!("Plugin {} loaded successfully", plugin_name);
    Ok((bundle, instance, shared))
}

/// An opened plugin GUI, as reported back to the engine
#[derive(Debug, Clone, Copy)]
pub struct OpenedGui {
    pub width: u32,
    pub height: u32,
    pub resizable: bool,
    /// The plugin runs in its own window (asked to, or it refused embedded mode)
    pub floating: bool,
}

/// Size and resizability of an open GUI
fn current_gui(
    gui_ext: &PluginGui,
    handle: &mut PluginMainThreadHandle,
    floating: bool,
) -> OpenedGui {
    let size = gui_ext.get_size(handle).unwrap_or(GuiSize {
        width: 800,
        height: 600,
    });
    OpenedGui {
        width: size.width,
        height: size.height,
        resizable: gui_ext.can_resize(handle),
        floating,
    }
}

/// Open plugin GUI. With a window handle the GUI is embedded into it; a plugin that only
/// supports floating mode then opens in its own window instead, and `floating` says so.
pub fn open_plugin_gui(
    instance: &mut PluginInstance<SubprocessHost>,
    window_handle: Option<u64>,
) -> Result<OpenedGui, String> {
    let mut handle = instance.plugin_handle();

    info!("🎨 Step 1: Getting GUI extension...");
    let Some(gui_ext): Option<PluginGui> = handle.get_extension() else {
        error!("❌ Plugin does not support GUI extension");
        return Err("Plugin does not support GUI extension".to_string());
    };
    info!("✅ GUI extension available");

    info!("🎨 Step 2: Getting default GUI API for platform...");
    let Some(api_type) = GuiApiType::default_for_current_platform() else {
        error!("❌ No GUI API available for current platform");
        return Err("No GUI API available for current platform".to_string());
    };
    info!("✅ Using GUI API: {:?}", api_type);

    // Embedded when we have a window handle and the plugin supports it, floating otherwise
    let embedded = GuiConfiguration {
        api_type,
        is_floating: false,
    };
    let config = match window_handle {
        Some(_) if gui_ext.is_api_supported(&mut handle, embedded) => {
            info!("🎨 Step 3: Using embedded mode with provided window handle");
            embedded
        }
        Some(_) => {
            warn!(
                "⚠️ Plugin does not support {:?} in embedded mode; falling back to floating",
                api_type
            );
            GuiConfiguration {
                api_type,
                is_floating: true,
            }
        }
        None => {
            info!("🎨 Step 3: Using floating mode (no window handle provided)");
            GuiConfiguration {
                api_type,
                is_floating: true,
            }
        }
    };

    if config.is_floating && !gui_ext.is_api_supported(&mut handle, config) {
        error!("❌ Plugin does not support {:?} in floating mode", api_type);
        return Err(format!(
            "Plugin does not support {:?} GUI API in {} mode",
            api_type,
            if window_handle.is_some() {
                "embedded or floating"
            } else {
                "floating"
            }
        ));
    }
    info!(
        "✅ Plugin supports {:?} with floating={}",
        api_type, config.is_floating
    );

    info!("🎨 Step 5: Creating GUI...");
    gui_ext.create(&mut handle, config).map_err(|e| {
        error!("❌ Failed to create GUI: {}", e);
        format!("Failed to create GUI: {}", e)
    })?;
    info!("✅ GUI created");

    // The engine sizes the window from the size in the `GuiOpened` response
    if let Some(size) = gui_ext.get_size(&mut handle) {
        info!(
            "🎨 Plugin reports preferred size: {}x{}",
            size.width, size.height
        );
    }

    // For embedded mode, use the provided window handle
    if !config.is_floating {
        let handle_value = window_handle.ok_or("No window handle provided for embedded mode")?;
        info!(
            "🎨 Step 6: Setting parent window for embedded plugin (handle: 0x{:x})...",
            handle_value
        );

        let parent_window = Window::from_x11_handle(handle_value);

        unsafe {
            gui_ext
                .set_parent(&mut handle, parent_window)
                .map_err(|e| {
                    error!("❌ Failed to set parent window: {}", e);
                    format!("Failed to set parent window: {}", e)
                })?;
        }
        info!("✅ Parent window set to 0x{:x}", handle_value);

        info!("🎨 Step 7: Setting window title...");
        let title = std::ffi::CString::new("Plugin - Sonara").unwrap();
        gui_ext.suggest_title(&mut handle, &title);

        // show() is advisory for embedded GUIs: the plugin's child window already exists after
        // set_parent. nih-plug always returns false here, and hosts such as Bitwig ignore it.
        info!("🎨 Step 8: Showing GUI window...");
        if let Err(e) = gui_ext.show(&mut handle) {
            warn!(
                "⚠️ Plugin returned false from gui.show() ({}); continuing, as embedded GUIs are already mapped by set_parent",
                e
            );
        }

        info!("✅ Plugin GUI opened successfully (embedded mode)");

        // Return the plugin's actual size and resizability so the engine can configure the window
        let opened = current_gui(&gui_ext, &mut handle, false);
        info!(
            "🎨 Final plugin size: {}x{} (resizable: {})",
            opened.width, opened.height, opened.resizable
        );

        Ok(opened)
    } else {
        // Floating mode - plugin manages its own window
        info!("🎨 Step 5: Setting transient window (for floating mode)...");
        // For floating windows, set_transient tells the plugin which window to float above
        // Pass X11 root window (0) since we don't have a parent window
        let transient_window = Window::from_x11_handle(0);

        unsafe {
            match gui_ext.set_transient(&mut handle, transient_window) {
                Ok(()) => info!("✅ Transient window set"),
                Err(e) => {
                    // Non-fatal - some plugins might not need this
                    warn!("⚠️  Failed to set transient window (non-fatal): {}", e);
                }
            }
        }

        info!("🎨 Step 6: Setting window title...");
        let title = std::ffi::CString::new("Plugin - Sonara").unwrap();
        gui_ext.suggest_title(&mut handle, &title);

        info!("🎨 Step 7: Showing GUI window...");
        gui_ext.show(&mut handle).map_err(|e| {
            error!("❌ Failed to show GUI: {}", e);
            format!("Failed to show GUI: {}", e)
        })?;

        // For floating windows, immediately pump the main thread callback a few times
        // Some plugins need this to actually create/show their window
        info!("🎨 Step 8: Pumping main thread callbacks to ensure window appears...");
        drop(handle); // Release the handle before calling callback
        for _i in 0..10 {
            instance.call_on_main_thread_callback();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        info!("✅ Pumped main thread callbacks");

        info!("✅ Plugin GUI opened successfully (floating mode)");

        // Return the plugin's size and resizability (for consistency)
        let mut handle = instance.plugin_handle();
        let gui_ext: PluginGui = handle.get_extension().unwrap();
        Ok(current_gui(&gui_ext, &mut handle, true))
    }
}

/// Size and resizability of an open GUI (`floating` as it was opened)
pub fn plugin_gui_state(
    instance: &mut PluginInstance<SubprocessHost>,
    floating: bool,
) -> Result<OpenedGui, String> {
    let mut handle = instance.plugin_handle();
    let gui_ext: PluginGui = handle
        .get_extension()
        .ok_or("Plugin does not support GUI extension")?;
    Ok(current_gui(&gui_ext, &mut handle, floating))
}

/// Show or hide an open GUI. Returns its current size.
pub fn set_plugin_gui_visible(
    instance: &mut PluginInstance<SubprocessHost>,
    visible: bool,
) -> Result<GuiSize, String> {
    let mut handle = instance.plugin_handle();
    let gui_ext: PluginGui = handle
        .get_extension()
        .ok_or("Plugin does not support GUI extension")?;
    let result = if visible {
        gui_ext.show(&mut handle)
    } else {
        gui_ext.hide(&mut handle)
    };
    // Advisory for embedded GUIs, like show() at open (the engine also unmaps the host window)
    if let Err(e) = result {
        warn!(
            "⚠️ Plugin returned false from gui.{}() ({}); continuing",
            if visible { "show" } else { "hide" },
            e
        );
    }
    Ok(gui_ext.get_size(&mut handle).unwrap_or(GuiSize {
        width: 800,
        height: 600,
    }))
}

/// Ask a resizable GUI to take `width`×`height`: `adjust_size` picks the closest size the
/// plugin accepts, `set_size` applies it. Returns the size the plugin reports afterwards.
pub fn set_plugin_gui_size(
    instance: &mut PluginInstance<SubprocessHost>,
    width: u32,
    height: u32,
) -> Result<GuiSize, String> {
    let mut handle = instance.plugin_handle();
    let gui_ext: PluginGui = handle
        .get_extension()
        .ok_or("Plugin does not support GUI extension")?;
    let requested = GuiSize { width, height };
    if gui_ext.can_resize(&mut handle) {
        let size = gui_ext
            .adjust_size(&mut handle, requested)
            .unwrap_or(requested);
        if let Err(e) = gui_ext.set_size(&mut handle, size) {
            warn!(
                "⚠️ Plugin refused GUI size {}x{}: {}",
                size.width, size.height, e
            );
        }
    } else {
        info!(
            "Plugin GUI is not resizable; ignoring size request {}x{}",
            width, height
        );
    }
    Ok(gui_ext.get_size(&mut handle).unwrap_or(requested))
}

/// Close plugin GUI
pub fn close_plugin_gui(instance: &mut PluginInstance<SubprocessHost>) -> Result<(), String> {
    let mut handle = instance.plugin_handle();

    let Some(gui_ext): Option<PluginGui> = handle.get_extension() else {
        return Ok(()); // No GUI, nothing to close
    };

    let _ = gui_ext.hide(&mut handle);
    gui_ext.destroy(&mut handle);

    info!("Plugin GUI closed");
    Ok(())
}

/// Check if plugin has GUI
pub fn has_plugin_gui(instance: &mut PluginInstance<SubprocessHost>) -> bool {
    let handle = instance.plugin_handle();
    handle.get_extension::<PluginGui>().is_some()
}
