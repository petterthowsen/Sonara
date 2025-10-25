//! Window Manager for Plugin GUI Windows
//!
//! Manages winit windows for plugin GUIs in the main engine process.
//! Windows are created on demand when plugins request GUI display,
//! and their handles are passed to plugin subprocesses for embedded rendering.
//!
//! Uses a dedicated thread running winit's event_loop.run() for proper
//! X11 event handling. Plugins create their own child windows and GL contexts.

use std::collections::HashMap;
use std::sync::mpsc::{channel, sync_channel, Sender, Receiver, SyncSender};
use std::thread::{self, JoinHandle};
use tracing::{info, error};
use winit::event::{Event, WindowEvent};
use winit::event_loop::EventLoopBuilder;
use winit::platform::x11::EventLoopBuilderExtX11;
use winit::window::Window;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

/// Commands sent to the window manager thread
enum WindowCommand {
    /// Create a new window
    Create {
        process_key: String,
        width: u32,
        height: u32,
        response: SyncSender<Option<u64>>,
    },
    /// Destroy a window
    Destroy {
        process_key: String,
    },
}

/// Manages plugin GUI windows using winit
pub struct WindowManager {
    /// Sender for window commands
    command_tx: Sender<WindowCommand>,

    /// Background thread handle (joins on drop)
    _thread_handle: Option<JoinHandle<()>>,
}

impl WindowManager {
    /// Create a new window manager with a background thread running winit
    pub fn new() -> Self {
        info!("Creating WindowManager with dedicated winit thread");

        let (command_tx, command_rx) = channel();

        // Spawn background thread for winit event loop
        let thread_handle = thread::spawn(move || {
            run_window_thread(command_rx);
        });

        Self {
            command_tx,
            _thread_handle: Some(thread_handle),
        }
    }

    /// Create a window and return its X11 handle
    /// This blocks until the window is created (or creation fails)
    pub fn create_window(&mut self, process_key: String, width: u32, height: u32) -> Option<u64> {
        info!("Requesting window creation for process: {} ({}x{})", process_key, width, height);

        let (response_tx, response_rx) = sync_channel(1);

        self.command_tx.send(WindowCommand::Create {
            process_key: process_key.clone(),
            width,
            height,
            response: response_tx,
        }).ok()?;

        // Wait for response from winit thread
        match response_rx.recv() {
            Ok(Some(handle)) => {
                info!("✅ Window created for process: {} (handle: 0x{:x})", process_key, handle);
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

    /// Destroy a window
    pub fn destroy_window(&mut self, process_key: &str) {
        info!("Requesting window destruction for process: {}", process_key);

        let _ = self.command_tx.send(WindowCommand::Destroy {
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
        .with_visible(true);

    let window = event_loop_target
        .create_window(window_attributes)
        .map_err(|e| format!("Failed to create window: {}", e))?;

    info!("✅ Window created");

    Ok(WindowHolder { window })
}

/// Background thread function that runs winit event loop
fn run_window_thread(command_rx: Receiver<WindowCommand>) {
    info!("🧵 Window thread starting");

    // Allow event loop on non-main thread (X11 specific)
    let event_loop = match EventLoopBuilder::new()
        .with_any_thread(true)
        .build()
    {
        Ok(el) => el,
        Err(e) => {
            error!("Failed to create EventLoop in window thread: {}", e);
            return;
        }
    };

    let mut windows: HashMap<String, WindowHolder> = HashMap::new();
    let mut pending_creates: Vec<(String, u32, u32, SyncSender<Option<u64>>)> = Vec::new();
    let mut pending_destroys: Vec<String> = Vec::new();

    #[allow(deprecated)]
    let result = event_loop.run(move |event, event_loop_target| {
        // Process commands from main thread
        while let Ok(cmd) = command_rx.try_recv() {
            match cmd {
                WindowCommand::Create { process_key, width, height, response } => {
                    pending_creates.push((process_key, width, height, response));
                }
                WindowCommand::Destroy { process_key } => {
                    pending_destroys.push(process_key);
                }
            }
        }

        match event {
            Event::NewEvents(_) => {
                // Create pending windows
                for (process_key, width, height, response) in pending_creates.drain(..) {
                    match create_window(
                        event_loop_target,
                        &process_key,
                        width,
                        height,
                    ) {
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
                        // User closed window - find and remove it
                        let to_remove = windows.iter()
                            .find(|(_, w)| w.window.id() == window_id)
                            .map(|(k, _)| k.clone());

                        if let Some(key) = to_remove {
                            info!("Window close requested: {}", key);
                            windows.remove(&key);
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

