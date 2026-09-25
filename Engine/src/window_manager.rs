//! Window Manager for Plugin GUI Windows
//!
//! Manages winit windows for plugin GUIs in the main engine process.
//! Windows are created on demand when plugins request GUI display,
//! and their handles are passed to plugin subprocesses for embedded rendering.
//!
//! Uses a dedicated thread running winit's event_loop.run() for proper
//! X11 event handling. Plugins create their own child windows and GL contexts.

use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::collections::HashMap;
use std::sync::mpsc::{channel, sync_channel, Receiver, Sender, SyncSender};
use std::thread::{self, JoinHandle};
use tracing::{error, info, warn};
use winit::event::{Event, WindowEvent};
use winit::event_loop::{EventLoopBuilder, EventLoopProxy};
use winit::platform::x11::EventLoopBuilderExtX11;
use winit::window::Window;

/// Commands sent to the window manager thread
enum WindowCommand {
    /// Create a new window
    Create {
        process_key: String,
        width: u32,
        height: u32,
        response: SyncSender<Option<u64>>,
    },
    /// Resize an existing window
    Resize {
        process_key: String,
        width: u32,
        height: u32,
    },
    /// Show a window (make visible)
    Show { process_key: String },
    /// Destroy a window
    Destroy { process_key: String },
}

/// Manages plugin GUI windows using winit
pub struct WindowManager {
    /// Sender for window commands
    command_tx: Sender<WindowCommand>,

    /// Wakes the winit loop after a command is queued. Without it, the loop (ControlFlow::Wait)
    /// only reads commands when X happens to deliver an event, which delayed GUI opens by seconds.
    wake_proxy: Option<EventLoopProxy<()>>,

    /// Receiver for window close events (when user clicks X)
    pub close_event_rx: std::sync::mpsc::Receiver<String>,

    /// Background thread handle (joins on drop)
    _thread_handle: Option<JoinHandle<()>>,
}

impl WindowManager {
    /// Create a new window manager with a background thread running winit
    pub fn new() -> Self {
        info!("Creating WindowManager with dedicated winit thread");

        let (command_tx, command_rx) = channel();
        let (close_event_tx, close_event_rx) = std::sync::mpsc::channel();
        let (proxy_tx, proxy_rx) = sync_channel(1);

        // Spawn background thread for winit event loop
        let thread_handle = thread::spawn(move || {
            run_window_thread(command_rx, close_event_tx, proxy_tx);
        });

        // None if the event loop failed to build; commands then go nowhere, as before.
        let wake_proxy = proxy_rx.recv().ok().flatten();

        Self {
            command_tx,
            wake_proxy,
            close_event_rx,
            _thread_handle: Some(thread_handle),
        }
    }

    /// Queue a command for the winit thread and wake its event loop.
    fn send(&self, cmd: WindowCommand) -> bool {
        if self.command_tx.send(cmd).is_err() {
            return false;
        }
        if let Some(proxy) = &self.wake_proxy {
            let _ = proxy.send_event(());
        }
        true
    }

    /// Create a window and return its X11 handle
    /// This blocks until the window is created (or creation fails)
    pub fn create_window(&mut self, process_key: String, width: u32, height: u32) -> Option<u64> {
        info!(
            "Requesting window creation for process: {} ({}x{})",
            process_key, width, height
        );

        let (response_tx, response_rx) = sync_channel(1);

        if !self.send(WindowCommand::Create {
            process_key: process_key.clone(),
            width,
            height,
            response: response_tx,
        }) {
            return None;
        }

        // Wait for response from winit thread
        match response_rx.recv() {
            Ok(Some(handle)) => {
                info!(
                    "✅ Window created for process: {} (handle: 0x{:x})",
                    process_key, handle
                );
                Some(handle)
            }
            Ok(None) => {
                error!("❌ Failed to create window for process: {}", process_key);
                None
            }
            Err(e) => {
                error!("❌ Window creation channel error: {}", e);
                None
            }
        }
    }

    /// Resize an existing window and make it visible
    pub fn resize_window(&mut self, process_key: &str, width: u32, height: u32) {
        info!(
            "Requesting window resize for process: {} to {}x{}",
            process_key, width, height
        );

        self.send(WindowCommand::Resize {
            process_key: process_key.to_string(),
            width,
            height,
        });
    }

    /// Show a window (make it visible)
    pub fn show_window(&mut self, process_key: &str) {
        info!("Requesting window show for process: {}", process_key);

        self.send(WindowCommand::Show {
            process_key: process_key.to_string(),
        });
    }

    /// Destroy a window
    pub fn destroy_window(&mut self, process_key: &str) {
        info!("Requesting window destruction for process: {}", process_key);

        self.send(WindowCommand::Destroy {
            process_key: process_key.to_string(),
        });
    }

    /// No-op for compatibility (winit thread handles events automatically)
    pub fn pump_events(&mut self) {
        // Events are handled automatically by the winit thread
    }

    /// No-op for compatibility (window creation now returns handle directly)
    pub fn get_window_handle(&self, _process_key: &str) -> Option<u64> {
        // Window handles are now returned directly from create_window()
        None
    }
}

/// Simplified window holder (plugin creates its own GL context as needed)
struct WindowHolder {
    window: Window,
}

/// Create a simple winit window (plugin creates its own GL context if needed)
fn create_window(
    event_loop_target: &winit::event_loop::ActiveEventLoop,
    process_key: &str,
    width: u32,
    height: u32,
) -> Result<WindowHolder, String> {
    info!("🪟 Creating window: {} ({}x{})", process_key, width, height);

    let window_attributes = Window::default_attributes()
        .with_title(format!("Plugin - {}", process_key))
        .with_inner_size(winit::dpi::PhysicalSize::new(width, height))
        .with_resizable(true)
        .with_visible(false); // Start hidden, will be shown after plugin opens and resizes

    let window = event_loop_target
        .create_window(window_attributes)
        .map_err(|e| format!("Failed to create window: {}", e))?;

    info!("✅ Window created");

    Ok(WindowHolder { window })
}

/// Background thread function that runs winit event loop
fn run_window_thread(
    command_rx: Receiver<WindowCommand>,
    close_event_tx: std::sync::mpsc::Sender<String>,
    proxy_tx: SyncSender<Option<EventLoopProxy<()>>>,
) {
    info!("🧵 Window thread starting");

    // Allow event loop on non-main thread (X11 specific)
    let event_loop = match EventLoopBuilder::new().with_any_thread(true).build() {
        Ok(el) => el,
        Err(e) => {
            error!("Failed to create EventLoop in window thread: {}", e);
            let _ = proxy_tx.send(None);
            return;
        }
    };
    let _ = proxy_tx.send(Some(event_loop.create_proxy()));

    let mut windows: HashMap<String, WindowHolder> = HashMap::new();
    let mut pending_creates: Vec<(String, u32, u32, SyncSender<Option<u64>>)> = Vec::new();
    let mut pending_resizes: Vec<(String, u32, u32)> = Vec::new();
    let mut pending_destroys: Vec<String> = Vec::new();

    #[allow(deprecated)]
    let result = event_loop.run(move |event, event_loop_target| {
        // Process commands from main thread
        while let Ok(cmd) = command_rx.try_recv() {
            match cmd {
                WindowCommand::Create {
                    process_key,
                    width,
                    height,
                    response,
                } => {
                    pending_creates.push((process_key, width, height, response));
                }
                WindowCommand::Resize {
                    process_key,
                    width,
                    height,
                } => {
                    pending_resizes.push((process_key, width, height));
                }
                WindowCommand::Show { process_key } => {
                    // Show window immediately
                    if let Some(window_holder) = windows.get(&process_key) {
                        window_holder.window.set_visible(true);
                        info!("👁️  Showing window: {}", process_key);
                    }
                }
                WindowCommand::Destroy { process_key } => {
                    pending_destroys.push(process_key);
                }
            }
        }

        match event {
            // UserEvent is the wakeup from WindowManager::send; handle it like NewEvents so a
            // command drained mid-iteration is still applied without waiting for another event.
            Event::NewEvents(_) | Event::UserEvent(()) => {
                // Create pending windows
                for (process_key, width, height, response) in pending_creates.drain(..) {
                    // Check if window already exists (e.g., close failed and window wasn't destroyed)
                    if let Some(existing_window) = windows.get(&process_key) {
                        warn!(
                            "⚠️  Window {} already exists, reusing existing window",
                            process_key
                        );
                        let handle = existing_window.window.window_handle().ok().and_then(|wh| {
                            match wh.as_raw() {
                                RawWindowHandle::Xlib(xlib) => Some(xlib.window as u64),
                                RawWindowHandle::Xcb(xcb) => Some(xcb.window.get() as u64),
                                _ => None,
                            }
                        });

                        if let Some(h) = handle {
                            info!("✅ Reusing existing window: 0x{:x}", h);
                            let _ = response.send(Some(h));
                            // Resize and show the existing window
                            let _ = existing_window
                                .window
                                .request_inner_size(winit::dpi::PhysicalSize::new(width, height));
                            existing_window.window.set_visible(true);
                        } else {
                            error!("Failed to get X11 handle for existing window");
                            let _ = response.send(None);
                        }
                        continue;
                    }

                    match create_window(event_loop_target, &process_key, width, height) {
                        Ok(window_holder) => {
                            // Get X11 handle
                            let handle = window_holder.window.window_handle().ok().and_then(|wh| {
                                match wh.as_raw() {
                                    RawWindowHandle::Xlib(xlib) => Some(xlib.window as u64),
                                    RawWindowHandle::Xcb(xcb) => Some(xcb.window.get() as u64),
                                    _ => None,
                                }
                            });

                            if let Some(h) = handle {
                                info!("✅ Window created successfully: 0x{:x}", h);
                                let _ = response.send(Some(h));
                                windows.insert(process_key, window_holder);
                            } else {
                                error!("Failed to get X11 handle for window");
                                let _ = response.send(None);
                            }
                        }
                        Err(e) => {
                            error!("Failed to create window: {}", e);
                            let _ = response.send(None);
                        }
                    }
                }

                // Resize windows
                for (process_key, width, height) in pending_resizes.drain(..) {
                    if let Some(window_holder) = windows.get(&process_key) {
                        info!(
                            "🔄 Resizing window: {} to {}x{}",
                            process_key, width, height
                        );
                        let _ = window_holder
                            .window
                            .request_inner_size(winit::dpi::PhysicalSize::new(width, height));
                    } else {
                        error!("Cannot resize window {}: not found", process_key);
                    }
                }

                // Destroy windows
                for process_key in pending_destroys.drain(..) {
                    if windows.remove(&process_key).is_some() {
                        info!("🗑️  Destroyed window: {}", process_key);
                    }
                }
            }
            Event::WindowEvent { window_id, event } => {
                match event {
                    WindowEvent::CloseRequested => {
                        // User clicked X - hide window and notify OSC to cleanup plugin
                        // Don't destroy yet - let plugin cleanup first to avoid X errors
                        let key = windows
                            .iter()
                            .find(|(_, w)| w.window.id() == window_id)
                            .map(|(k, _)| k.clone());

                        if let Some(key) = key {
                            info!("Window close requested by user: {}", key);
                            // Hide the window immediately so user sees it close
                            if let Some(window_holder) = windows.get(&key) {
                                window_holder.window.set_visible(false);
                            }
                            // Notify OSC server so it can tell plugin to cleanup
                            // OSC will send Destroy command after plugin confirms close
                            let _ = close_event_tx.send(key);
                        }
                    }
                    WindowEvent::RedrawRequested => {
                        // Plugin handles all rendering in its child window
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    });

    if let Err(e) = result {
        error!("Window thread event loop error: {}", e);
    }

    info!("🧵 Window thread exiting");
}
