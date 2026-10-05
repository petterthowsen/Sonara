//! Window Manager for Plugin GUI Windows
//!
//! Manages winit windows for plugin GUIs in the main engine process.
//! Windows are created on demand when plugins request GUI display,
//! and their handles are passed to plugin subprocesses for embedded rendering.
//!
//! Uses a dedicated thread running winit's event_loop.run() for proper
//! X11 event handling. Plugins create their own child windows and GL contexts.

use raw_window_handle::{HasDisplayHandle, HasWindowHandle, RawDisplayHandle, RawWindowHandle};
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
    /// SPIKE: reparent the host window into a foreign X11 window (e.g. Godot's) at a rect
    Embed {
        process_key: String,
        parent_xid: u64,
        rect: EmbedRect,
    },
    /// SPIKE: move/resize an embedded host window; scroll offsets the plugin's child window
    Bounds {
        process_key: String,
        rect: EmbedRect,
    },
    /// SPIKE: reparent the host window back to the root window (floating)
    Unembed { process_key: String },
}

/// Viewport of an embedded host window, in the parent window's coordinates.
/// `scroll_x`/`scroll_y` shift the plugin's own window inside it.
#[derive(Clone, Copy, Debug)]
pub struct EmbedRect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scroll_x: i32,
    pub scroll_y: i32,
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

    /// SPIKE: embed the host window into `parent_xid` (an X11 window from another process)
    pub fn embed_window(&mut self, process_key: &str, parent_xid: u64, rect: EmbedRect) {
        info!(
            "Requesting embed of {} into 0x{:x} at {:?}",
            process_key, parent_xid, rect
        );
        self.send(WindowCommand::Embed {
            process_key: process_key.to_string(),
            parent_xid,
            rect,
        });
    }

    /// SPIKE: update the viewport of an embedded host window
    pub fn set_embed_bounds(&mut self, process_key: &str, rect: EmbedRect) {
        self.send(WindowCommand::Bounds {
            process_key: process_key.to_string(),
            rect,
        });
    }

    /// SPIKE: return an embedded host window to the root window
    pub fn unembed_window(&mut self, process_key: &str) {
        info!("Requesting unembed of {}", process_key);
        self.send(WindowCommand::Unembed {
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
    /// SPIKE: Some while reparented into a foreign window. Plugin resize requests then
    /// leave the host window alone: it is a viewport sized by the embedder.
    embedded: Option<EmbedRect>,
}

fn x11_handle(window: &Window) -> Option<u64> {
    window
        .window_handle()
        .ok()
        .and_then(|wh| match wh.as_raw() {
            RawWindowHandle::Xlib(xlib) => Some(xlib.window as u64),
            RawWindowHandle::Xcb(xcb) => Some(xcb.window.get() as u64),
            _ => None,
        })
}

/// SPIKE: X11 reparenting on winit's own Xlib connection, so our requests are ordered
/// with winit's (map/unmap/resize). winit installs a non-fatal Xlib error handler.
mod x11_embed {
    use super::EmbedRect;
    use std::os::raw::{c_int, c_ulong};
    use std::time::{Duration, Instant};
    use tracing::{info, warn};
    use x11::xlib;

    pub type Display = *mut xlib::Display;

    unsafe fn parent_of(dpy: Display, win: c_ulong) -> Option<(c_ulong, c_ulong, Vec<c_ulong>)> {
        let mut root = 0;
        let mut parent = 0;
        let mut children: *mut c_ulong = std::ptr::null_mut();
        let mut n = 0u32;
        if xlib::XQueryTree(dpy, win, &mut root, &mut parent, &mut children, &mut n) == 0 {
            return None;
        }
        let kids = if children.is_null() {
            Vec::new()
        } else {
            let v = std::slice::from_raw_parts(children, n as usize).to_vec();
            xlib::XFree(children as *mut _);
            v
        };
        Some((root, parent, kids))
    }

    /// Unmap `win` and wait until the WM has let go of it (parent is root again).
    /// A WM reparents managed toplevels into a frame window; reparenting out of that
    /// frame behind its back would race with it reparenting the window back on unmap.
    unsafe fn withdraw(dpy: Display, win: c_ulong) {
        let screen = xlib::XDefaultScreen(dpy);
        xlib::XWithdrawWindow(dpy, win, screen);
        xlib::XSync(dpy, 0);
        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(500) {
            match parent_of(dpy, win) {
                Some((root, parent, _)) if root == parent => {
                    info!("withdrawn after {:?}", start.elapsed());
                    return;
                }
                None => return,
                _ => std::thread::sleep(Duration::from_millis(10)),
            }
        }
        warn!("WM did not release window 0x{:x} within 500 ms", win);
    }

    // XShape (libXext); the x11 crate has no bindings for it.
    const SHAPE_BOUNDING: c_int = 0;
    const SHAPE_SET: c_int = 0;
    const UNSORTED: c_int = 0;
    #[link(name = "Xext")]
    extern "C" {
        fn XShapeCombineRectangles(
            dpy: Display,
            dest: c_ulong,
            dest_kind: c_int,
            x_off: c_int,
            y_off: c_int,
            rects: *mut xlib::XRectangle,
            n_rects: c_int,
            op: c_int,
            ordering: c_int,
        );
        fn XShapeCombineMask(
            dpy: Display,
            dest: c_ulong,
            dest_kind: c_int,
            x_off: c_int,
            y_off: c_int,
            src: c_ulong,
            op: c_int,
        );
    }

    unsafe fn size_of(dpy: Display, win: c_ulong) -> (u32, u32) {
        let (mut root, mut x, mut y, mut w, mut h, mut bw, mut depth) = (0, 0, 0, 0, 0, 0, 0);
        xlib::XGetGeometry(
            dpy, win, &mut root, &mut x, &mut y, &mut w, &mut h, &mut bw, &mut depth,
        );
        (w, h)
    }

    /// Godot (4.7) selects SubstructureNotify on its windows and takes a ConfigureNotify from
    /// any direct child as a resize of the window itself. So the host window always covers the
    /// whole parent at (0,0): its ConfigureNotify then carries Godot's real size and is ignored.
    /// The viewport is a bounding shape (clips drawing and input), and the plugin's own window
    /// (a grandchild, invisible to Godot) moves inside it for position and scrolling.
    pub unsafe fn embed(
        dpy: Display,
        win: c_ulong,
        parent: c_ulong,
        rect: EmbedRect,
        managed: bool,
    ) {
        if managed {
            withdraw(dpy, win);
        }
        // Godot holds SubstructureRedirect on its windows and drops the redirected map and
        // configure requests. Override-redirect windows bypass the redirect.
        set_override_redirect(dpy, win, true);
        // Resize only while the window is not a child of some other Godot window: Godot would
        // take that ConfigureNotify as its own resize. A floating window is sized before the
        // reparent (Godot never sees a wrong size); an embedded one after (its new parent sees
        // its own size and ignores it).
        apply_shape(dpy, win, rect);
        let (pw, ph) = size_of(dpy, parent);
        if managed {
            xlib::XResizeWindow(dpy, win, pw.max(1), ph.max(1));
        }
        // Reparenting a mapped child unmaps and remaps it by itself.
        xlib::XReparentWindow(dpy, win, parent, 0, 0);
        if !managed {
            xlib::XResizeWindow(dpy, win, pw.max(1), ph.max(1));
        }
        if managed {
            xlib::XMapRaised(dpy, win);
        }
        xlib::XSync(dpy, 0);
        info!(
            "embedded 0x{:x} into 0x{:x} ({}x{}, now parent {:?})",
            win,
            parent,
            pw,
            ph,
            parent_of(dpy, win).map(|p| p.1)
        );
    }

    unsafe fn set_override_redirect(dpy: Display, win: c_ulong, on: bool) {
        let mut attrs: xlib::XSetWindowAttributes = std::mem::zeroed();
        attrs.override_redirect = on as i32;
        xlib::XChangeWindowAttributes(dpy, win, xlib::CWOverrideRedirect, &mut attrs);
    }

    /// Clip to the viewport and place the plugin's window in it, offset by the scroll.
    unsafe fn apply_shape(dpy: Display, win: c_ulong, rect: EmbedRect) {
        let mut r = xlib::XRectangle {
            x: rect.x as i16,
            y: rect.y as i16,
            width: rect.width.max(1) as u16,
            height: rect.height.max(1) as u16,
        };
        XShapeCombineRectangles(
            dpy,
            win,
            SHAPE_BOUNDING,
            0,
            0,
            &mut r,
            1,
            SHAPE_SET,
            UNSORTED,
        );
        if let Some((_, _, kids)) = parent_of(dpy, win) {
            for kid in kids {
                xlib::XMoveWindow(dpy, kid, rect.x - rect.scroll_x, rect.y - rect.scroll_y);
            }
        }
    }

    pub unsafe fn apply_bounds(dpy: Display, win: c_ulong, rect: EmbedRect) {
        apply_shape(dpy, win, rect);
        // Track the parent's size (Godot sends bounds after every layout change). Only resize
        // when it differs: the ConfigureNotify then reports the parent's actual size.
        if let Some((_, parent, _)) = parent_of(dpy, win) {
            let (pw, ph) = size_of(dpy, parent);
            if size_of(dpy, win) != (pw, ph) {
                xlib::XResizeWindow(dpy, win, pw.max(1), ph.max(1));
            }
        }
        xlib::XFlush(dpy);
    }

    pub unsafe fn unembed(dpy: Display, win: c_ulong, was_mapped: bool) {
        let root = xlib::XDefaultRootWindow(dpy);
        if was_mapped {
            xlib::XUnmapWindow(dpy, win);
        }
        // Back under the WM: it must manage (and decorate) the window again.
        set_override_redirect(dpy, win, false);
        xlib::XReparentWindow(dpy, win, root, 100, 100);
        // Unshaped, sized to the plugin's window again.
        XShapeCombineMask(dpy, win, SHAPE_BOUNDING, 0, 0, 0, SHAPE_SET);
        if let Some((_, _, kids)) = parent_of(dpy, win) {
            if let Some(&kid) = kids.first() {
                let (w, h) = size_of(dpy, kid);
                xlib::XResizeWindow(dpy, win, w.max(1), h.max(1));
            }
            for kid in kids {
                xlib::XMoveWindow(dpy, kid, 0, 0);
            }
        }
        if was_mapped {
            // Not override-redirect, so the WM picks it up (MapRequest) and decorates it again.
            xlib::XMapRaised(dpy, win);
        }
        xlib::XSync(dpy, 0);
        info!("unembedded 0x{:x}", win);
    }
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

    Ok(WindowHolder {
        window,
        embedded: None,
    })
}

enum EmbedOp {
    Embed(String, u64, EmbedRect),
    Bounds(String, EmbedRect),
    Unembed(String),
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
    let mut pending_embeds: Vec<EmbedOp> = Vec::new();

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
                WindowCommand::Embed {
                    process_key,
                    parent_xid,
                    rect,
                } => {
                    pending_embeds.push(EmbedOp::Embed(process_key, parent_xid, rect));
                }
                WindowCommand::Bounds { process_key, rect } => {
                    pending_embeds.push(EmbedOp::Bounds(process_key, rect));
                }
                WindowCommand::Unembed { process_key } => {
                    pending_embeds.push(EmbedOp::Unembed(process_key));
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
                        if window_holder.embedded.is_some() {
                            info!(
                                "🔄 Plugin {} wants {}x{}; embedded, host viewport unchanged",
                                process_key, width, height
                            );
                            continue;
                        }
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

                // SPIKE: embed / bounds / unembed
                if !pending_embeds.is_empty() {
                    let dpy = match event_loop_target.display_handle().map(|h| h.as_raw()) {
                        Ok(RawDisplayHandle::Xlib(h)) => h
                            .display
                            .map(|d| d.as_ptr() as x11_embed::Display)
                            .unwrap_or(std::ptr::null_mut()),
                        other => {
                            error!("Embedding needs an Xlib display, got {:?}", other);
                            std::ptr::null_mut()
                        }
                    };
                    for op in pending_embeds.drain(..) {
                        if dpy.is_null() {
                            continue;
                        }
                        let key = match &op {
                            EmbedOp::Embed(k, ..) | EmbedOp::Bounds(k, _) | EmbedOp::Unembed(k) => {
                                k
                            }
                        };
                        let Some(holder) = windows.get_mut(key) else {
                            error!("Embed op for unknown window {}", key);
                            continue;
                        };
                        let Some(xid) = x11_handle(&holder.window) else {
                            continue;
                        };
                        let mapped = holder.window.is_visible().unwrap_or(false);
                        unsafe {
                            match op {
                                EmbedOp::Embed(_, parent, rect) => {
                                    // Only a mapped toplevel is WM-managed; an embedded window
                                    // moves between parents without the WM's involvement.
                                    let managed = mapped && holder.embedded.is_none();
                                    x11_embed::embed(dpy, xid as _, parent as _, rect, managed);
                                    holder.embedded = Some(rect);
                                }
                                EmbedOp::Bounds(_, rect) => {
                                    if holder.embedded.is_some() {
                                        x11_embed::apply_bounds(dpy, xid as _, rect);
                                        holder.embedded = Some(rect);
                                    }
                                }
                                EmbedOp::Unembed(_) => {
                                    if holder.embedded.take().is_some() {
                                        x11_embed::unembed(dpy, xid as _, mapped);
                                    }
                                }
                            }
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
