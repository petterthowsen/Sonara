//! CLAP host implementation for subprocess
//!
//! Provides the host implementation that plugins interact with,
//! including timer support, GUI callbacks, and logging.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tracing::{error, info, warn};

use clack_host::prelude::*;
use clack_extensions::gui::{HostGui, HostGuiImpl, GuiSize};
use clack_extensions::timer::{HostTimer, HostTimerImpl, TimerId};
use clack_extensions::log::{HostLog, HostLogImpl, LogSeverity};

use crate::plugin_host::protocol::PluginResponse;

/// Host implementation for subprocess with GUI support
pub struct SubprocessHost;

/// Shared state accessible by all plugin threads
#[derive(Clone)]
pub struct SubprocessHostShared {
    timers: Arc<Mutex<HashMap<TimerId, Timer>>>,
    next_timer_id: Arc<Mutex<u32>>,
    /// Channel to send unsolicited responses (like GUI resize requests)
    response_tx: std::sync::mpsc::Sender<PluginResponse>,
}

impl SubprocessHostShared {
    pub fn new(response_tx: std::sync::mpsc::Sender<PluginResponse>) -> Self {
        Self {
            timers: Arc::new(Mutex::new(HashMap::new())),
            next_timer_id: Arc::new(Mutex::new(0)),
            response_tx,
        }
    }

    /// Tick all timers and return list of IDs that should fire
    pub fn tick_timers(&self) -> Vec<TimerId> {
        let now = Instant::now();
        let mut timers = self.timers.lock().unwrap();
        timers
            .values_mut()
            .filter_map(|timer| {
                if timer.tick(now) {
                    Some(timer.id)
                } else {
                    None
                }
            })
            .collect()
    }
}

/// A single timer instance
struct Timer {
    id: TimerId,
    interval: Duration,
    last_triggered: Option<Instant>,
}

impl Timer {
    fn new(id: TimerId, interval: Duration) -> Self {
        Self {
            id,
            interval,
            last_triggered: None,
        }
    }

    /// Returns true if timer should fire
    fn tick(&mut self, now: Instant) -> bool {
        match self.last_triggered {
            None => {
                self.last_triggered = Some(now);
                true
            }
            Some(last) => {
                if now.duration_since(last) >= self.interval {
                    self.last_triggered = Some(now);
                    true
                } else {
                    false
                }
            }
        }
    }
}

impl HostHandlers for SubprocessHost {
    type Shared<'s> = SubprocessHostShared;
    type MainThread<'a> = SubprocessHostMainThread<'a>;
    type AudioProcessor<'a> = ();

    fn declare_extensions(builder: &mut HostExtensions<Self>, _shared: &Self::Shared<'_>) {
        // Register extensions required by many plugins (e.g., DPF-based plugins)
        builder.register::<HostLog>();
        builder.register::<HostGui>();
        builder.register::<HostTimer>();
    }
}

/// Main thread state - holds mutable timer data
pub struct SubprocessHostMainThread<'a> {
    pub shared: &'a SubprocessHostShared,
}

impl<'a> MainThreadHandler<'a> for SubprocessHostMainThread<'a> {
    // No main thread callbacks needed
}

impl<'a> SharedHandler<'a> for SubprocessHostShared {
    fn request_restart(&self) {
        // We don't support runtime restart
        info!("Plugin requested restart (not supported)");
    }

    fn request_process(&self) {
        // We're already processing continuously
    }

    fn request_callback(&self) {
        // Main thread callbacks are called continuously in our event loop
    }
}

impl HostGuiImpl for SubprocessHostShared {
    fn resize_hints_changed(&self) {
        // We don't support resize hints
        info!("Plugin GUI resize hints changed");
    }

    fn request_resize(&self, new_size: GuiSize) -> Result<(), HostError> {
        info!("Plugin GUI requested resize to {}x{}", new_size.width, new_size.height);

        // Send resize request to main loop
        let _ = self.response_tx.send(PluginResponse::GuiResizeRequest {
            width: new_size.width,
            height: new_size.height,
        });

        Ok(())
    }

    fn request_show(&self) -> Result<(), HostError> {
        info!("Plugin GUI requested show");
        Ok(())
    }

    fn request_hide(&self) -> Result<(), HostError> {
        info!("Plugin GUI requested hide");
        Ok(())
    }

    fn closed(&self, was_destroyed: bool) {
        info!("Plugin GUI closed (destroyed: {})", was_destroyed);
    }
}

impl HostTimerImpl for SubprocessHostMainThread<'_> {
    fn register_timer(&mut self, period_ms: u32) -> Result<TimerId, HostError> {
        // Clamp to reasonable range (10ms minimum for performance)
        let period_ms = period_ms.max(10);
        let interval = Duration::from_millis(period_ms as u64);

        let mut next_id = self.shared.next_timer_id.lock().unwrap();
        *next_id += 1;
        let timer_id = TimerId(*next_id);
        drop(next_id);

        let timer = Timer::new(timer_id, interval);
        self.shared.timers.lock().unwrap().insert(timer_id, timer);

        info!("Registered timer {} with interval {}ms", timer_id.0, period_ms);
        Ok(timer_id)
    }

    fn unregister_timer(&mut self, timer_id: TimerId) -> Result<(), HostError> {
        if self.shared.timers.lock().unwrap().remove(&timer_id).is_some() {
            info!("Unregistered timer {}", timer_id.0);
            Ok(())
        } else {
            Err(HostError::Message("Unknown timer ID"))
        }
    }
}

impl HostLogImpl for SubprocessHostShared {
    fn log(&self, severity: LogSeverity, message: &str) {
        // Route plugin logs through tracing
        match severity {
            LogSeverity::Debug => tracing::debug!("[PLUGIN] {}", message),
            LogSeverity::Info => tracing::info!("[PLUGIN] {}", message),
            LogSeverity::Warning => tracing::warn!("[PLUGIN] {}", message),
            LogSeverity::Error => tracing::error!("[PLUGIN] {}", message),
            LogSeverity::Fatal => tracing::error!("[PLUGIN FATAL] {}", message),
            LogSeverity::HostMisbehaving => tracing::error!("[HOST MISBEHAVING] {}", message),
            LogSeverity::PluginMisbehaving => tracing::error!("[PLUGIN MISBEHAVING] {}", message),
        }
    }
}
