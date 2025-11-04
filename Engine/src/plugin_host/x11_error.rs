//! X11 Error Handler
//!
//! Installs a custom X11 error handler to prevent plugin crashes when
//! X11 errors occur (e.g., BadWindow when accessing destroyed windows).
//!
//! Without this, the default X11 error handler terminates the process,
//! which is catastrophic for plugin hosting.

#[cfg(target_os = "linux")]
use tracing::{error, warn};

#[cfg(target_os = "linux")]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(target_os = "linux")]
static ERROR_HANDLER_INSTALLED: AtomicBool = AtomicBool::new(false);

/// Install a custom X11 error handler that logs errors instead of crashing
///
/// This must be called early in the plugin_host subprocess, before any
/// X11 operations occur. The handler will log X11 errors but allow
/// execution to continue, preventing plugin crashes.
#[cfg(target_os = "linux")]
pub fn install_x11_error_handler() {
    use x11::xlib;

    // Only install once
    if ERROR_HANDLER_INSTALLED.swap(true, Ordering::SeqCst) {
        warn!("X11 error handler already installed, skipping");
        return;
    }

    unsafe {
        // Open a display connection to ensure XLib is initialized
        let display = xlib::XOpenDisplay(std::ptr::null());
        if display.is_null() {
            error!("Failed to open X11 display, cannot install error handler");
            return;
        }

        // Install custom error handler
        xlib::XSetErrorHandler(Some(x11_error_handler));

        // Close the display - we just needed it to initialize XLib
        xlib::XCloseDisplay(display);

        tracing::info!("✅ X11 error handler installed successfully");
    }
}

/// Custom X11 error handler that logs errors instead of terminating
#[cfg(target_os = "linux")]
unsafe extern "C" fn x11_error_handler(
    display: *mut x11::xlib::Display,
    error_event: *mut x11::xlib::XErrorEvent,
) -> std::os::raw::c_int {
    use x11::xlib;

    if display.is_null() || error_event.is_null() {
        error!("X11 error handler called with null pointers");
        return 0;
    }

    let error = &*error_event;

    // Get error message from X11
    let mut error_text = [0i8; 256];
    xlib::XGetErrorText(
        display,
        error.error_code as i32,
        error_text.as_mut_ptr(),
        error_text.len() as i32,
    );

    // Convert C string to Rust string
    let error_str = std::ffi::CStr::from_ptr(error_text.as_ptr())
        .to_str()
        .unwrap_or("(invalid UTF-8)");

    // Log the error instead of crashing
    error!(
        "X11 Error caught: code={} ({}), request_code={}, minor_code={}, resource_id=0x{:x}",
        error.error_code, error_str, error.request_code, error.minor_code, error.resourceid
    );

    // Return 0 to indicate error was handled (don't terminate)
    0
}

/// No-op for non-Linux platforms
#[cfg(not(target_os = "linux"))]
pub fn install_x11_error_handler() {
    // X11 only exists on Linux
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "linux")]
    fn test_error_handler_installs_once() {
        install_x11_error_handler();
        install_x11_error_handler(); // Should be no-op second time
    }
}
