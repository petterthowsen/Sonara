use anyhow::{Context, Result};
use crossbeam::channel::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use tracing::info;

use super::command_worker::CommandWorker;
pub use super::commands::{AudioCommand, EngineStatus};
use super::pipewire::{self, ForcedClock};
pub use super::state::EngineState;
use super::stream::{
    CallbackContext, CallbackCounters, StreamControl, StreamRequest, MAX_BLOCK_FRAMES,
};

/// Capacity of the engine → OSC status channel (~1.6 MB preallocated at 200 bytes per status):
/// several seconds of meters for 100 channels at 20 Hz. Bounded so sends never allocate. The
/// audio callback uses `try_send` and drops statuses when it's full; other threads block.
pub const STATUS_CHANNEL_CAPACITY: usize = 8_192;

/// Audio engine that manages the audio stream and processing
pub struct AudioEngine {
    _command_thread: thread::JoinHandle<()>,
    command_tx: Sender<AudioCommand>,
    state: Arc<Mutex<EngineState>>,
    status_rx: Receiver<EngineStatus>,
    forced_clock: Arc<Mutex<ForcedClock>>,
}

impl AudioEngine {
    /// Create and initialize a new audio engine with provided status channel. The stream opens
    /// on the default driver's default device at the default rate and buffer size (falling back
    /// like a settings change does); Godot then sends the saved settings
    /// (`AudioCommand::SetAudioConfig`).
    pub fn with_status_channel(
        status_tx: Sender<EngineStatus>,
        status_rx: Receiver<EngineStatus>,
    ) -> Result<Self> {
        info!("Initializing DAW audio engine...");

        // Create command channel for thread-safe communication
        let (command_tx, command_rx) = crossbeam::channel::unbounded();

        let state = Arc::new(Mutex::new(EngineState::default()));
        let (block_clock, rendering, sample_rate) = {
            let mut fresh = state.lock().expect("fresh state lock");
            fresh.ensure_master_channel(MAX_BLOCK_FRAMES);
            (
                fresh.block_clock.clone(),
                fresh.rendering.clone(),
                fresh.device_sample_rate,
            )
        };
        let counters = Arc::new(CallbackCounters::default());
        let forced_clock = Arc::new(Mutex::new(ForcedClock::system()));

        let stream = StreamControl::spawn(CallbackContext {
            status_tx: status_tx.clone(),
            state: state.clone(),
            counters: counters.clone(),
            block_clock: block_clock.clone(),
            rendering,
        })?;

        // Command thread: applies commands, doing slow work outside the state lock. It opens the
        // first stream before it starts taking commands.
        let request = StreamRequest::default();
        info!("Using audio driver: {}", request.driver.label());
        let mut worker = CommandWorker::new(
            state.clone(),
            status_tx.clone(),
            command_tx.clone(),
            sample_rate,
            MAX_BLOCK_FRAMES,
            block_clock,
            stream,
            request,
            forced_clock.clone(),
        );
        worker.open_output();
        let command_thread = thread::Builder::new()
            .name("engine-commands".to_string())
            .spawn(move || worker.run(command_rx))
            .context("Failed to spawn command thread")?;

        pipewire::spawn_monitor(command_tx.clone(), counters);

        Ok(Self {
            _command_thread: command_thread,
            command_tx,
            state,
            status_rx,
            forced_clock,
        })
    }

    /// The engine's forcing of PipeWire's quantum and rate, for the termination handler to
    /// restore.
    pub fn forced_clock(&self) -> Arc<Mutex<ForcedClock>> {
        self.forced_clock.clone()
    }

    /// Hardware callback rate the mixer and devices are running at.
    pub fn device_sample_rate(&self) -> u32 {
        self.state.lock().unwrap().device_sample_rate.round() as u32
    }

    /// Get a clone of the command sender for external use
    pub fn command_sender(&self) -> Sender<AudioCommand> {
        self.command_tx.clone()
    }

    /// Get status receiver for external use
    pub fn status_receiver(&self) -> Receiver<EngineStatus> {
        self.status_rx.clone()
    }
}
