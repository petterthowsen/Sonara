//! Window Manager for Plugin GUI Windows
//!
//! Manages winit windows for plugin GUIs in the main engine process.
//! Windows are created on demand when plugins request GUI display,
//! and their handles are passed to plugin subprocesses for embedded rendering.
//!
//! Uses a dedicated thread running winit's event_loop.run() for proper
//! X11 event handling. Plugins create their own child windows and GL contexts.
//!
//! A host window is either a floating toplevel or embedded: reparented into a window of another
//! process (a Godot window), clipped to a viewport inside it (ADR 0016). The plugin's own window
//! stays a child of the host window throughout, so embedding, moving between Godot windows and
//! returning to floating never close the plugin GUI.

use raw_window_handle::{HasDisplayHandle, HasWindowHandle, RawDisplayHandle, RawWindowHandle};
use std::collections::HashMap;
use std::sync::mpsc::{channel, sync_channel, Receiver, Sender, SyncSender};
use std::thread::{self, JoinHandle};
use tracing::{error, info, warn};
use winit::event::{Event, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::platform::x11::EventLoopBuilderExtX11;
use winit::window::Window;

/// Commands sent to the window manager thread. They are applied in the order they were sent.
enum WindowCommand {
    /// Create a host window (or reuse the existing one for this key), embedded into a foreign
    /// window before it is first mapped when `embed` is given
    Create {
        process_key: String,
        width: u32,
        height: u32,
        embed: Option<(u64, EmbedRect)>,
        response: SyncSender<Option<u64>>,
    },
    /// Resize a floating window to the plugin's size (ignored while embedded)
    Resize {
        process_key: String,
        width: u32,
        height: u32,
    },
    /// The plugin GUI is open in this window: map it, unless it was hidden with `SetVisible`
    Show { process_key: String },
    /// Show or hide the window (an embedded GUI on a hidden tab, for instance)
    SetVisible { process_key: String, visible: bool },
    /// Reparent the window into a foreign X11 window at a viewport. `done` is answered once
    /// the X server has the reparent (or dropped when there is no such window).
    Embed {
        process_key: String,
        parent_xid: u64,
        rect: EmbedRect,
        done: SyncSender<()>,
    },
    /// New viewport (and scroll offset) of an embedded window
    Bounds {
        process_key: String,
        rect: EmbedRect,
    },
    /// Back to a floating toplevel
    Unembed {
        process_key: String,
        done: SyncSender<()>,
    },
    /// Unmap the window and, if embedded, reparent it to the root while unmapped. Sent before
    /// the plugin GUI closes, so the embedder can free its window without destroying the
    /// plugin's window under it, and nothing flashes on screen.
    Release {
        process_key: String,
        done: SyncSender<()>,
    },
    /// Destroy the window (after the plugin closed its GUI)
    Destroy { process_key: String },
}

impl WindowCommand {
    fn process_key(&self) -> &str {
        match self {
            WindowCommand::Create { process_key, .. }
            | WindowCommand::Resize { process_key, .. }
            | WindowCommand::Show { process_key }
            | WindowCommand::SetVisible { process_key, .. }
            | WindowCommand::Embed { process_key, .. }
            | WindowCommand::Bounds { process_key, .. }
            | WindowCommand::Unembed { process_key, .. }
            | WindowCommand::Release { process_key, .. }
            | WindowCommand::Destroy { process_key } => process_key,
        }
    }
}

/// Viewport of an embedded host window, in the parent window's coordinates.
/// `scroll_x`/`scroll_y` shift the plugin's own window inside it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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

    /// A manager with no winit thread and no display: every command fails to send, so window
    /// requests return `None`/`false`. Lets tests build a `RouteCtx` without opening anything.
    #[cfg(test)]
    pub(crate) fn detached() -> Self {
        let (command_tx, _command_rx) = channel();
        let (_close_event_tx, close_event_rx) = std::sync::mpsc::channel();
        Self {
            command_tx,
            wake_proxy: None,
            close_event_rx,
            _thread_handle: None,
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

    /// Create a window and return its X11 handle. With `embed` (parent XID and viewport) the
    /// window is reparented into the parent before it is ever mapped, so no floating window
    /// flashes. This blocks until the window is created (or creation fails).
    pub fn create_window(
        &mut self,
        process_key: String,
        width: u32,
        height: u32,
        embed: Option<(u64, EmbedRect)>,
    ) -> Option<u64> {
        info!(
            "Requesting window creation for process: {} ({}x{}, embed: {:?})",
            process_key, width, height, embed
        );

        let (response_tx, response_rx) = sync_channel(1);

        if !self.send(WindowCommand::Create {
            process_key: process_key.clone(),
            width,
            height,
            embed,
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

    /// Resize a floating window to the plugin's size (embedded windows keep their viewport)
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

    /// The plugin GUI opened in this window: map it unless it is hidden
    pub fn show_window(&mut self, process_key: &str) {
        info!("Requesting window show for process: {}", process_key);

        self.send(WindowCommand::Show {
            process_key: process_key.to_string(),
        });
    }

    /// Show or hide a window
    pub fn set_window_visible(&mut self, process_key: &str, visible: bool) {
        info!(
            "Requesting window {} for process: {}",
            if visible { "show" } else { "hide" },
            process_key
        );
        self.send(WindowCommand::SetVisible {
            process_key: process_key.to_string(),
            visible,
        });
    }

    /// Destroy a window
    pub fn destroy_window(&mut self, process_key: &str) {
        info!("Requesting window destruction for process: {}", process_key);

        self.send(WindowCommand::Destroy {
            process_key: process_key.to_string(),
        });
    }

    /// Embed the host window into `parent_xid` (an X11 window from another process). Returns
    /// once the X server has the reparent: true when the window exists and was moved.
    pub fn embed_window(&mut self, process_key: &str, parent_xid: u64, rect: EmbedRect) -> bool {
        info!(
            "Requesting embed of {} into 0x{:x} at {:?}",
            process_key, parent_xid, rect
        );
        let (done, rx) = sync_channel(1);
        self.send(WindowCommand::Embed {
            process_key: process_key.to_string(),
            parent_xid,
            rect,
            done,
        }) && Self::wait_done(rx)
    }

    /// Update the viewport of an embedded host window
    pub fn set_embed_bounds(&mut self, process_key: &str, rect: EmbedRect) {
        self.send(WindowCommand::Bounds {
            process_key: process_key.to_string(),
            rect,
        });
    }

    /// Return an embedded host window to the root window (floating)
    /// Returns once it is out of its embedder (true when the window exists).
    pub fn unembed_window(&mut self, process_key: &str) -> bool {
        info!("Requesting unembed of {}", process_key);
        let (done, rx) = sync_channel(1);
        self.send(WindowCommand::Unembed {
            process_key: process_key.to_string(),
            done,
        }) && Self::wait_done(rx)
    }

    /// Hide the window and take it out of its embedder before the plugin GUI closes. Returns
    /// once it is out (true when the window exists), so the embedder can free its window.
    pub fn release_window(&mut self, process_key: &str) -> bool {
        info!("Requesting release of {}", process_key);
        let (done, rx) = sync_channel(1);
        self.send(WindowCommand::Release {
            process_key: process_key.to_string(),
            done,
        }) && Self::wait_done(rx)
    }

    /// Wait for the winit thread to finish a command. Bounded: the X calls have their own
    /// bounded waits (withdraw), so this only trips if the thread is stuck.
    fn wait_done(rx: Receiver<()>) -> bool {
        match rx.recv_timeout(std::time::Duration::from_secs(1)) {
            Ok(()) => true,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                warn!("Window thread didn't finish an embed command within 1 s");
                false
            }
            // Sender dropped: no such window
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => false,
        }
    }

    /// No-op for compatibility (winit thread handles events automatically)
    pub fn pump_events(&mut self) {
        // Events are handled automatically by the winit thread
    }
}

/// Where an embedded host window lives
#[derive(Clone, Copy, Debug)]
struct Embed {
    parent: u64,
    rect: EmbedRect,
}

/// A plugin's host window (the plugin creates its own child window and GL context in it)
struct HostWindow {
    window: Window,
    xid: u64,
    /// Some while reparented into a foreign window. Plugin resize requests then leave the host
    /// window alone: it is a viewport sized by the embedder.
    embed: Option<Embed>,
    /// Wanted visibility (`SetVisible`); cleared by `Release` and by the user closing it
    visible: bool,
    /// The plugin GUI opened in it (`Show`). The window stays unmapped until then.
    shown: bool,
    /// Whether it is mapped. Tracked here: winit's `is_visible` stays false until the MapNotify.
    mapped: bool,
}

impl HostWindow {
    /// Map or unmap the window to match `visible && shown`. Mapping goes through winit so its
    /// own visibility state stays right; the X11 embedding calls leave the mapped state as is.
    fn update_mapping(&mut self) {
        let want = self.visible && self.shown;
        if want != self.mapped {
            self.window.set_visible(want);
            self.mapped = want;
        }
    }

    unsafe fn embed(&mut self, dpy: x11_embed::Display, parent: u64, rect: EmbedRect) {
        match self.embed {
            // Same parent: only the viewport changes (a reparent would unmap and remap it)
            Some(e) if e.parent == parent => x11_embed::apply_bounds(dpy, self.xid as _, rect),
            current => x11_embed::embed(
                dpy,
                self.xid as _,
                parent as _,
                rect,
                current.is_none(),
                self.mapped,
            ),
        }
        self.embed = Some(Embed { parent, rect });
    }

    unsafe fn unembed(&mut self, dpy: x11_embed::Display) {
        if self.embed.take().is_some() {
            x11_embed::unembed(dpy, self.xid as _, self.mapped);
        }
    }
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

/// winit's Xlib display, for the embedding calls. None (and an error logged) on other backends.
fn xlib_display(event_loop: &ActiveEventLoop) -> Option<x11_embed::Display> {
    match event_loop.display_handle().map(|h| h.as_raw()) {
        Ok(RawDisplayHandle::Xlib(h)) => h.display.map(|d| d.as_ptr() as x11_embed::Display),
        other => {
            error!("Embedding needs an Xlib display, got {:?}", other);
            None
        }
    }
}

/// X11 reparenting on winit's own Xlib connection, so our requests are ordered with winit's
/// (map/unmap/resize). winit installs a non-fatal Xlib error handler.
///
/// None of these functions change whether the window is mapped: `HostWindow::update_mapping`
/// owns that, through winit.
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

    /// Take a toplevel away from the WM: unmap it if `mapped`, then wait until the WM has let
    /// go of it (parent is root again). A WM reparents managed toplevels into a frame window;
    /// reparenting out of that frame behind its back would race with it reparenting the window
    /// back on unmap. A window that was never mapped returns at once.
    unsafe fn withdraw(dpy: Display, win: c_ulong, mapped: bool) {
        if mapped {
            let screen = xlib::XDefaultScreen(dpy);
            xlib::XWithdrawWindow(dpy, win, screen);
        }
        xlib::XSync(dpy, 0);
        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(500) {
            match parent_of(dpy, win) {
                Some((root, parent, _)) if root == parent => {
                    if mapped {
                        info!("withdrawn after {:?}", start.elapsed());
                    }
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

    /// Reparent `win` into `parent` (a window of another process) and clip it to `rect`.
    /// `from_toplevel`: it is a floating window now (otherwise it moves from another embedder).
    ///
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
        from_toplevel: bool,
        mapped: bool,
    ) {
        if from_toplevel {
            withdraw(dpy, win, mapped);
        }
        // Godot holds SubstructureRedirect on its windows and drops the redirected map and
        // configure requests. Override-redirect windows bypass the redirect.
        set_override_redirect(dpy, win, true);
        set_black_background(dpy, win);
        // Resize only while the window is not a child of some other Godot window: Godot would
        // take that ConfigureNotify as its own resize. A floating window is sized before the
        // reparent (Godot never sees a wrong size); an embedded one after (its new parent sees
        // its own size and ignores it).
        apply_shape(dpy, win, rect);
        let (pw, ph) = size_of(dpy, parent);
        if from_toplevel {
            xlib::XResizeWindow(dpy, win, pw.max(1), ph.max(1));
        }
        // Reparenting a mapped child unmaps and remaps it by itself.
        xlib::XReparentWindow(dpy, win, parent, 0, 0);
        if !from_toplevel {
            xlib::XResizeWindow(dpy, win, pw.max(1), ph.max(1));
        }
        // A withdrawn toplevel has to be mapped again, now as a child.
        if from_toplevel && mapped {
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

    /// winit leaves the background unset, so viewport pixels the plugin's window doesn't cover
    /// (a viewport larger than the plugin) would show whatever was drawn there before.
    unsafe fn set_black_background(dpy: Display, win: c_ulong) {
        let mut attrs: xlib::XWindowAttributes = std::mem::zeroed();
        xlib::XGetWindowAttributes(dpy, win, &mut attrs);
        // An ARGB (depth 32) visual needs an opaque alpha, or the gap is see-through
        let black: c_ulong = if attrs.depth == 32 { 0xff00_0000 } else { 0 };
        xlib::XSetWindowBackground(dpy, win, black);
        xlib::XClearWindow(dpy, win);
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

    /// Reparent `win` back to the root as a WM-managed toplevel, unshaped and sized to the
    /// plugin's window. A `mapped` window is mapped again (the WM decorates it); an unmapped
    /// one stays unmapped.
    pub unsafe fn unembed(dpy: Display, win: c_ulong, mapped: bool) {
        let root = xlib::XDefaultRootWindow(dpy);
        if mapped {
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
        if mapped {
            // Not override-redirect, so the WM picks it up (MapRequest) and decorates it again.
            xlib::XMapRaised(dpy, win);
        }
        xlib::XSync(dpy, 0);
        info!("unembedded 0x{:x}", win);
    }
}

/// Create a simple winit window (plugin creates its own GL context if needed)
fn create_window(
    event_loop_target: &ActiveEventLoop,
    process_key: &str,
    width: u32,
    height: u32,
) -> Result<HostWindow, String> {
    info!("🪟 Creating window: {} ({}x{})", process_key, width, height);

    let window_attributes = Window::default_attributes()
        .with_title(format!("Plugin - {}", process_key))
        .with_inner_size(winit::dpi::PhysicalSize::new(width, height))
        .with_resizable(true)
        .with_visible(false); // Start hidden, will be shown after plugin opens and resizes

    let window = event_loop_target
        .create_window(window_attributes)
        .map_err(|e| format!("Failed to create window: {}", e))?;
    let xid = x11_handle(&window).ok_or("Failed to get X11 handle for window")?;

    info!("✅ Window created: 0x{:x}", xid);

    Ok(HostWindow {
        window,
        xid,
        embed: None,
        visible: true,
        shown: false,
        mapped: false,
    })
}

/// Apply one command on the winit thread
fn apply_command(
    cmd: WindowCommand,
    windows: &mut HashMap<String, HostWindow>,
    event_loop_target: &ActiveEventLoop,
) {
    if let WindowCommand::Create {
        process_key,
        width,
        height,
        embed,
        response,
    } = cmd
    {
        // Reuse an existing window (e.g. the GUI is already open, or a close never finished)
        let host = match windows.entry(process_key) {
            std::collections::hash_map::Entry::Occupied(entry) => {
                warn!(
                    "⚠️  Window {} already exists, reusing existing window",
                    entry.key()
                );
                let host = entry.into_mut();
                host.visible = true;
                if host.embed.is_none() && embed.is_none() {
                    let _ = host
                        .window
                        .request_inner_size(winit::dpi::PhysicalSize::new(width, height));
                }
                host
            }
            std::collections::hash_map::Entry::Vacant(entry) => {
                match create_window(event_loop_target, entry.key(), width, height) {
                    Ok(host) => entry.insert(host),
                    Err(e) => {
                        error!("Failed to create window: {}", e);
                        let _ = response.send(None);
                        return;
                    }
                }
            }
        };
        if let Some((parent, rect)) = embed {
            match xlib_display(event_loop_target) {
                Some(dpy) => unsafe { host.embed(dpy, parent, rect) },
                None => error!("Cannot embed 0x{:x}: no Xlib display", host.xid),
            }
        }
        let _ = response.send(Some(host.xid));
        return;
    }

    let key = cmd.process_key().to_string();
    if let WindowCommand::Destroy { .. } = cmd {
        if windows.remove(&key).is_some() {
            info!("🗑️  Destroyed window: {}", key);
        }
        return;
    }
    let Some(host) = windows.get_mut(&key) else {
        // Late commands for a window already destroyed are expected (bounds after close)
        info!("Window command for unknown window {}", key);
        return;
    };

    match cmd {
        WindowCommand::Resize { width, height, .. } => {
            if let Some(embed) = host.embed {
                info!(
                    "🔄 Plugin {} wants {}x{}; embedded, host viewport unchanged",
                    key, width, height
                );
                // A plugin may replace its window when it resizes
                if let Some(dpy) = xlib_display(event_loop_target) {
                    unsafe { x11_embed::apply_bounds(dpy, host.xid as _, embed.rect) };
                }
            } else {
                info!("🔄 Resizing window: {} to {}x{}", key, width, height);
                let _ = host
                    .window
                    .request_inner_size(winit::dpi::PhysicalSize::new(width, height));
            }
        }
        WindowCommand::Show { .. } => {
            // Embedded before the GUI opened: the plugin's window didn't exist yet, so it sits
            // at (0,0) instead of in the viewport
            if let (Some(embed), Some(dpy)) = (host.embed, xlib_display(event_loop_target)) {
                unsafe { x11_embed::apply_bounds(dpy, host.xid as _, embed.rect) };
            }
            host.shown = true;
            host.update_mapping();
            info!("👁️  Showing window: {} (mapped: {})", key, host.mapped);
        }
        WindowCommand::SetVisible { visible, .. } => {
            host.visible = visible;
            host.update_mapping();
        }
        WindowCommand::Embed {
            parent_xid,
            rect,
            done,
            ..
        } => {
            if let Some(dpy) = xlib_display(event_loop_target) {
                unsafe { host.embed(dpy, parent_xid, rect) };
            }
            let _ = done.send(());
        }
        WindowCommand::Bounds { rect, .. } => {
            if let (Some(embed), Some(dpy)) = (host.embed.as_mut(), xlib_display(event_loop_target))
            {
                embed.rect = rect;
                unsafe { x11_embed::apply_bounds(dpy, host.xid as _, rect) };
            }
        }
        WindowCommand::Unembed { done, .. } => {
            if host.embed.is_some() {
                if let Some(dpy) = xlib_display(event_loop_target) {
                    unsafe { host.unembed(dpy) };
                }
            }
            let _ = done.send(());
        }
        WindowCommand::Release { done, .. } => {
            host.visible = false;
            host.update_mapping();
            if host.embed.is_some() {
                if let Some(dpy) = xlib_display(event_loop_target) {
                    unsafe { host.unembed(dpy) };
                }
            }
            let _ = done.send(());
        }
        WindowCommand::Create { .. } | WindowCommand::Destroy { .. } => unreachable!(),
    }
}

/// Background thread function that runs winit event loop
fn run_window_thread(
    command_rx: Receiver<WindowCommand>,
    close_event_tx: std::sync::mpsc::Sender<String>,
    proxy_tx: SyncSender<Option<EventLoopProxy<()>>>,
) {
    info!("🧵 Window thread starting");

    // Allow event loop on non-main thread (X11 specific)
    let event_loop = match EventLoop::builder().with_any_thread(true).build() {
        Ok(el) => el,
        Err(e) => {
            error!("Failed to create EventLoop in window thread: {}", e);
            let _ = proxy_tx.send(None);
            return;
        }
    };
    let _ = proxy_tx.send(Some(event_loop.create_proxy()));

    let mut windows: HashMap<String, HostWindow> = HashMap::new();
    let mut pending: Vec<WindowCommand> = Vec::new();

    #[allow(deprecated)]
    let result = event_loop.run(move |event, event_loop_target| {
        // Collect commands from the main thread; they are applied in order below
        pending.extend(command_rx.try_iter());

        match event {
            // UserEvent is the wakeup from WindowManager::send; handle it like NewEvents so a
            // command drained mid-iteration is still applied without waiting for another event.
            Event::NewEvents(_) | Event::UserEvent(()) => {
                for cmd in pending.drain(..) {
                    apply_command(cmd, &mut windows, event_loop_target);
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
                            if let Some(host) = windows.get_mut(&key) {
                                host.visible = false;
                                host.update_mapping();
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
