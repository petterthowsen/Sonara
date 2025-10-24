//! Host handler implementations for CLAP plugins
//!
//! Implements the required host callbacks for clack-host integration.

use clack_host::prelude::*;
use clack_extensions::gui::{HostGui, HostGuiImpl, GuiSize};
use clack_extensions::log::{HostLog, HostLogImpl, LogSeverity};
use clack_extensions::audio_ports::{HostAudioPortsImpl, RescanType};
use clack_extensions::note_ports::{HostNotePortsImpl, NoteDialects, NotePortRescanFlags};
use clack_extensions::params::{HostParams, HostParamsImplMainThread, HostParamsImplShared, ParamClearFlags, ParamRescanFlags};
use clack_extensions::state::{HostState, HostStateImpl};
use clack_extensions::timer::{HostTimer, HostTimerImpl, TimerId};
use std::sync::atomic::{AtomicU32, Ordering};

/// Shared host state (accessible from all threads)
pub struct SonaraHostShared;

impl<'a> SharedHandler<'a> for SonaraHostShared {
    fn request_restart(&self) {
        // Plugin requesting restart (parameter list changed, etc.)
        // TODO: Send OSC message to Godot to reload plugin UI
        tracing::info!("CLAP plugin requested restart");
    }

    fn request_process(&self) {
        // Plugin requesting processing to start (e.g., tail processing after note off)
        tracing::debug!("CLAP plugin requested process");
    }

    fn request_callback(&self) {
        // Plugin requesting main thread callback (GUI update, etc.)
        tracing::info!("⚠️  CLAP plugin requested main thread callback - but we can't service it asynchronously!");
        // TODO: We need a background thread or integration with Godot's event loop
    }
}

/// GUI extension host implementation
impl HostGuiImpl for SonaraHostShared {
    fn resize_hints_changed(&self) {
        // Plugin's resize hints changed
        tracing::debug!("CLAP plugin GUI resize hints changed");
    }

    fn request_resize(&self, new_size: GuiSize) -> Result<(), HostError> {
        // Plugin requesting to resize its parent window
        // For floating windows, we don't control the window, so this is ignored
        tracing::debug!("CLAP plugin requested resize to {}x{}", new_size.width, new_size.height);
        Ok(())
    }

    fn request_show(&self) -> Result<(), HostError> {
        // Plugin requesting to show its window
        tracing::info!("📺 CLAP plugin requested to SHOW window");
        Ok(())
    }

    fn request_hide(&self) -> Result<(), HostError> {
        // Plugin requesting to hide its window
        tracing::debug!("CLAP plugin requested to hide window");
        Ok(())
    }

    fn closed(&self, was_destroyed: bool) {
        // Plugin notifying that its window was closed
        tracing::info!("❌ CLAP plugin GUI closed (destroyed: {})", was_destroyed);
    }
}

/// Main thread handler (parameter queries, state save/load)
pub struct SonaraHostMainThread {
    next_timer_id: AtomicU32,
}

impl SonaraHostMainThread {
    pub fn new() -> Self {
        Self {
            next_timer_id: AtomicU32::new(1),
        }
    }
}

impl<'a> MainThreadHandler<'a> for SonaraHostMainThread {
    // TODO: Implement callbacks for parameter changes, state updates, etc.
    // Most functionality will be handled through explicit parameter queries
}

/// Logging support implementation
impl HostLogImpl for SonaraHostShared {
    fn log(&self, severity: LogSeverity, message: &str) {
        // Route plugin logs through our tracing system
        match severity {
            LogSeverity::Debug => tracing::debug!(target: "clap_plugin", "{}", message),
            LogSeverity::Info => tracing::info!(target: "clap_plugin", "{}", message),
            LogSeverity::Warning => tracing::warn!(target: "clap_plugin", "{}", message),
            LogSeverity::Error => tracing::error!(target: "clap_plugin", "{}", message),
            LogSeverity::Fatal => tracing::error!(target: "clap_plugin", "FATAL: {}", message),
            _ => tracing::trace!(target: "clap_plugin", "{}", message),
        }
    }
}

/// Audio ports support implementation
impl HostAudioPortsImpl for SonaraHostMainThread {
    fn is_rescan_flag_supported(&self, _flag: RescanType) -> bool {
        false // We don't support dynamic audio port changes
    }

    fn rescan(&mut self, _flag: RescanType) {
        // We don't support audio ports changing on the fly
    }
}

/// Note ports support implementation
impl HostNotePortsImpl for SonaraHostMainThread {
    fn supported_dialects(&self) -> NoteDialects {
        NoteDialects::CLAP // We support CLAP note events
    }

    fn rescan(&mut self, _flags: NotePortRescanFlags) {
        // We don't support note ports changing on the fly
    }
}

/// Parameter support implementation
impl HostParamsImplMainThread for SonaraHostMainThread {
    fn rescan(&mut self, _flags: ParamRescanFlags) {
        // We handle params through explicit queries, not push-based updates
    }

    fn clear(&mut self, _param_id: ClapId, _flags: ParamClearFlags) {
        // We handle params through explicit queries
    }
}

impl HostParamsImplShared for SonaraHostShared {
    fn request_flush(&self) {
        // We process events continuously, no need for explicit flush
    }
}

/// State support implementation
impl HostStateImpl for SonaraHostMainThread {
    fn mark_dirty(&mut self) {
        // Plugin is indicating its state has changed and should be saved
        // TODO: Trigger auto-save or mark project as modified
        tracing::debug!("Plugin marked state as dirty");
    }
}

/// Timer support implementation
/// 
/// NOTE: Timers are registered but callbacks are not actively invoked.
/// Full timer support requires an event loop on the Rust side, which Sonara
/// doesn't have (Godot handles the main UI loop). This allows plugins to
/// initialize without assertions, but GUI features that depend on timer
/// callbacks may not work correctly.
/// 
/// TODO: Consider running a background thread that ticks timers and calls
/// plugin callbacks, or integrate with Godot's process loop via OSC.
impl HostTimerImpl for SonaraHostMainThread {
    fn register_timer(&mut self, period_ms: u32) -> Result<TimerId, HostError> {
        let id = self.next_timer_id.fetch_add(1, Ordering::Relaxed);
        tracing::debug!("Registered timer {} with period {}ms", id, period_ms);
        // TODO: Actually implement timer callbacks
        // For now, we just accept the registration so plugins don't assert
        Ok(TimerId(id))
    }

    fn unregister_timer(&mut self, timer_id: TimerId) -> Result<(), HostError> {
        tracing::debug!("Unregistered timer {}", timer_id);
        // TODO: Actually implement timer cleanup
        Ok(())
    }
}

/// Audio processor handler (transport info, etc.)
pub struct SonaraHostAudioProcessor;

impl<'a> AudioProcessorHandler<'a> for SonaraHostAudioProcessor {
    // Implement audio thread callbacks (rare, mostly informational)
}

/// Top-level host handlers struct
pub struct SonaraHost;

impl HostHandlers for SonaraHost {
    type Shared<'a> = SonaraHostShared;
    type MainThread<'a> = SonaraHostMainThread;
    type AudioProcessor<'a> = SonaraHostAudioProcessor;
    
    fn declare_extensions(builder: &mut HostExtensions<Self>, _shared: &Self::Shared<'_>) {
        // Register extensions that plugins commonly expect
        builder
            .register::<HostLog>()      // Logging support
            .register::<HostGui>()      // GUI support (floating windows)
            .register::<HostTimer>()    // Timer callbacks (stub implementation)
            .register::<HostParams>()   // Parameter notifications
            .register::<HostState>();   // State save/load support
    }
}

