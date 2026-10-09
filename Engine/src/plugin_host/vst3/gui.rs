//! VST3 plugin GUIs (spec 028, phase 4).
//!
//! A GUI is an `IPlugView` attached to the X11 window the engine hands over (its host window,
//! ADR 0016), so the engine-side embedding works as it does for CLAP. VST3 on Linux needs a
//! host-provided `IPlugFrame` that also implements `Linux::IRunLoop`: JUCE plugins query the
//! run loop from the frame object, and without it their GUIs never repaint. `PlugFrame` is that
//! one object. The event loop calls `Vst3Gui::pump` to service the registered timers and file
//! descriptors; every call into the view happens on the host's main thread.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ::vst3::com_scrape_types::{ComPtr, ComRef, ComWrapper};
use ::vst3::Class;
use ::vst3::Steinberg::Linux::{
    FileDescriptor, IEventHandler, IEventHandlerTrait, IRunLoop, IRunLoopTrait, ITimerHandler,
    ITimerHandlerTrait, TimerInterval,
};
use ::vst3::Steinberg::Vst::IEditControllerTrait;
use ::vst3::Steinberg::{
    kInvalidArgument, kResultFalse, kResultOk, kResultTrue, tresult, IPlugFrame, IPlugFrameTrait,
    IPlugView, IPlugViewTrait, ViewRect,
};
use tracing::{info, warn};

use super::host_context::Vst3Shared;
use super::instance::Vst3Instance;

const PLATFORM_X11: &[u8] = b"X11EmbedWindowID\0";
const VIEW_EDITOR: &[u8] = b"editor\0";

struct Timer {
    handler: ComPtr<ITimerHandler>,
    interval: Duration,
    last: Instant,
}

#[derive(Default)]
struct RunLoop {
    timers: Vec<Timer>,
    fds: Vec<(FileDescriptor, ComPtr<IEventHandler>)>,
}

/// The `IPlugFrame` and `Linux::IRunLoop` the plugin sees, in one COM object.
pub struct PlugFrame {
    shared: Arc<Vst3Shared>,
    run_loop: Mutex<RunLoop>,
}

impl PlugFrame {
    fn new(shared: Arc<Vst3Shared>) -> Self {
        Self {
            shared,
            run_loop: Mutex::new(RunLoop::default()),
        }
    }

    /// Fire due timers and the handlers of readable file descriptors. Handlers may register
    /// and unregister during a callback, so this works on copies and checks that each handler
    /// is still registered right before calling it.
    fn pump(&self) {
        let fds: Vec<(FileDescriptor, ComPtr<IEventHandler>)> = {
            let run_loop = self.run_loop.lock().unwrap();
            run_loop.fds.clone()
        };
        if !fds.is_empty() {
            let mut polls: Vec<libc::pollfd> = fds
                .iter()
                .map(|(fd, _)| libc::pollfd {
                    fd: *fd,
                    events: libc::POLLIN,
                    revents: 0,
                })
                .collect();
            let ready = unsafe { libc::poll(polls.as_mut_ptr(), polls.len() as libc::nfds_t, 0) };
            if ready > 0 {
                for (poll, (fd, handler)) in polls.iter().zip(&fds) {
                    if poll.revents == 0 || !self.fd_registered(*fd, handler) {
                        continue;
                    }
                    unsafe { handler.onFDIsSet(*fd) };
                }
            }
        }

        let now = Instant::now();
        let due: Vec<ComPtr<ITimerHandler>> = {
            let mut run_loop = self.run_loop.lock().unwrap();
            run_loop
                .timers
                .iter_mut()
                .filter_map(|timer| {
                    if now.duration_since(timer.last) >= timer.interval {
                        timer.last = now;
                        Some(timer.handler.clone())
                    } else {
                        None
                    }
                })
                .collect()
        };
        for handler in due {
            if self.timer_registered(&handler) {
                unsafe { handler.onTimer() };
            }
        }
    }

    fn fd_registered(&self, fd: FileDescriptor, handler: &ComPtr<IEventHandler>) -> bool {
        let run_loop = self.run_loop.lock().unwrap();
        run_loop
            .fds
            .iter()
            .any(|(f, h)| *f == fd && h.as_ptr() == handler.as_ptr())
    }

    fn timer_registered(&self, handler: &ComPtr<ITimerHandler>) -> bool {
        let run_loop = self.run_loop.lock().unwrap();
        run_loop
            .timers
            .iter()
            .any(|timer| timer.handler.as_ptr() == handler.as_ptr())
    }
}

impl Class for PlugFrame {
    type Interfaces = (IPlugFrame, IRunLoop);
}

impl IPlugFrameTrait for PlugFrame {
    /// The plugin wants a different size: tell the engine (which resizes the host window and
    /// Godot's slot), then confirm to the view.
    unsafe fn resizeView(&self, view: *mut IPlugView, new_size: *mut ViewRect) -> tresult {
        if new_size.is_null() {
            return kInvalidArgument;
        }
        let mut rect = *new_size;
        let width = (rect.right - rect.left).max(1) as u32;
        let height = (rect.bottom - rect.top).max(1) as u32;
        info!("Plugin GUI requested a resize to {}x{}", width, height);
        self.shared.request_gui_resize(width, height);
        if let Some(view) = ComRef::from_raw(view) {
            view.onSize(&mut rect);
        }
        kResultOk
    }
}

impl IRunLoopTrait for PlugFrame {
    unsafe fn registerEventHandler(
        &self,
        handler: *mut IEventHandler,
        fd: FileDescriptor,
    ) -> tresult {
        let Some(handler) = ComRef::from_raw(handler) else {
            return kInvalidArgument;
        };
        self.run_loop
            .lock()
            .unwrap()
            .fds
            .push((fd, handler.to_com_ptr()));
        kResultOk
    }

    unsafe fn unregisterEventHandler(&self, handler: *mut IEventHandler) -> tresult {
        let mut run_loop = self.run_loop.lock().unwrap();
        let before = run_loop.fds.len();
        run_loop.fds.retain(|(_, h)| h.as_ptr() != handler);
        if run_loop.fds.len() == before {
            kResultFalse
        } else {
            kResultOk
        }
    }

    unsafe fn registerTimer(
        &self,
        handler: *mut ITimerHandler,
        milliseconds: TimerInterval,
    ) -> tresult {
        let Some(handler) = ComRef::from_raw(handler) else {
            return kInvalidArgument;
        };
        self.run_loop.lock().unwrap().timers.push(Timer {
            handler: handler.to_com_ptr(),
            interval: Duration::from_millis(milliseconds.max(1)),
            last: Instant::now(),
        });
        kResultOk
    }

    unsafe fn unregisterTimer(&self, handler: *mut ITimerHandler) -> tresult {
        let mut run_loop = self.run_loop.lock().unwrap();
        let before = run_loop.timers.len();
        run_loop.timers.retain(|t| t.handler.as_ptr() != handler);
        if run_loop.timers.len() == before {
            kResultFalse
        } else {
            kResultOk
        }
    }
}

/// An open, attached plugin GUI.
pub struct Vst3Gui {
    view: ComPtr<IPlugView>,
    frame: ComWrapper<PlugFrame>,
    pub resizable: bool,
}

fn rect_size(rect: &ViewRect) -> (u32, u32) {
    (
        (rect.right - rect.left).max(1) as u32,
        (rect.bottom - rect.top).max(1) as u32,
    )
}

fn empty_rect() -> ViewRect {
    ViewRect {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    }
}

/// The controller's editor view, or None when it has no GUI.
unsafe fn create_view(instance: &Vst3Instance) -> Option<ComPtr<IPlugView>> {
    let controller = instance.controller()?;
    let view = controller.createView(VIEW_EDITOR.as_ptr() as *const _);
    ComPtr::from_raw(view)
}

/// True when the plugin has an editor view (the view is created and released again).
pub fn has_gui(instance: &Vst3Instance) -> bool {
    unsafe {
        match create_view(instance) {
            Some(view) => {
                view.isPlatformTypeSupported(PLATFORM_X11.as_ptr() as *const _) == kResultTrue
            }
            None => false,
        }
    }
}

impl Vst3Gui {
    /// Create the editor view and attach it to the X11 window `window_handle`. Returns the
    /// GUI and its initial size.
    pub fn open(
        instance: &Vst3Instance,
        shared: &Arc<Vst3Shared>,
        window_handle: u64,
    ) -> Result<(Self, (u32, u32)), String> {
        unsafe {
            let view = create_view(instance).ok_or("the plugin has no editor view")?;
            if view.isPlatformTypeSupported(PLATFORM_X11.as_ptr() as *const _) != kResultTrue {
                return Err("the plugin's editor does not support X11 embedding".to_string());
            }
            let frame = ComWrapper::new(PlugFrame::new(Arc::clone(shared)));
            let frame_ptr = frame
                .to_com_ptr::<IPlugFrame>()
                .ok_or("frame does not implement IPlugFrame")?;
            // The frame goes in before `attached`: plugins look for the run loop there.
            if view.setFrame(frame_ptr.as_ptr()) != kResultOk {
                warn!("IPlugView::setFrame failed");
            }
            let result = view.attached(
                window_handle as usize as *mut std::ffi::c_void,
                PLATFORM_X11.as_ptr() as *const _,
            );
            if result != kResultOk {
                view.setFrame(std::ptr::null_mut());
                return Err(format!(
                    "IPlugView::attached failed with tresult {}",
                    result
                ));
            }
            let mut rect = empty_rect();
            let size = if view.getSize(&mut rect) == kResultOk {
                rect_size(&rect)
            } else {
                (800, 600)
            };
            let resizable = view.canResize() == kResultTrue;
            Ok((
                Self {
                    view,
                    frame,
                    resizable,
                },
                size,
            ))
        }
    }

    /// The view's current size.
    pub fn size(&self) -> (u32, u32) {
        let mut rect = empty_rect();
        if unsafe { self.view.getSize(&mut rect) } == kResultOk {
            rect_size(&rect)
        } else {
            (800, 600)
        }
    }

    /// Ask the view for `width` x `height`; returns the size it settled on.
    pub fn set_size(&self, width: u32, height: u32) -> (u32, u32) {
        unsafe {
            if self.view.canResize() == kResultTrue {
                let mut rect = ViewRect {
                    left: 0,
                    top: 0,
                    right: width as i32,
                    bottom: height as i32,
                };
                self.view.checkSizeConstraint(&mut rect);
                self.view.onSize(&mut rect);
            }
        }
        self.size()
    }

    /// Service the run loop (timers and file descriptors the plugin registered).
    pub fn pump(&self) {
        self.frame.pump();
    }
}

impl Drop for Vst3Gui {
    fn drop(&mut self) {
        unsafe {
            self.view.removed();
            self.view.setFrame(std::ptr::null_mut());
        }
    }
}
