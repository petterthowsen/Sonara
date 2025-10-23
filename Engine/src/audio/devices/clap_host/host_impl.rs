//! Host handler implementations for CLAP plugins
//!
//! Implements the required host callbacks for clack-host integration.

use clack_host::prelude::*;

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
        tracing::debug!("CLAP plugin requested callback");
    }
}

/// Main thread handler (parameter queries, state save/load)
pub struct SonaraHostMainThread;

impl<'a> MainThreadHandler<'a> for SonaraHostMainThread {
    // Implement callbacks for parameter changes, state updates, etc.
    // Most functionality will be handled through explicit parameter queries
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
}

