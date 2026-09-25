use anyhow::{Context, Result};
use crossbeam::channel::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use tracing::info;

use super::command_worker::CommandWorker;
pub use super::commands::{AudioCommand, CommandResponse, EngineState, EngineStatus};
use super::pipewire;
use super::stream::{
    CallbackContext, CallbackCounters, StreamControl, StreamRequest, MAX_BLOCK_FRAMES,
};
use super::types::*;

/// Capacity of the engine → OSC status channel (~1.6 MB preallocated at 200 bytes per status):
/// several seconds of meters for 100 channels at 20 Hz. Bounded so sends never allocate. The
/// audio callback uses `try_send` and drops statuses when it's full; other threads block.
pub const STATUS_CHANNEL_CAPACITY: usize = 8_192;

/// Audio engine that manages the audio stream and processing
pub struct AudioEngine {
    _command_thread: thread::JoinHandle<()>,
    command_tx: Sender<AudioCommand>,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    status_rx: Receiver<EngineStatus>,
}

impl AudioEngine {
    /// Create and initialize a new audio engine with provided status channel. The stream opens
    /// on the default device at the default rate and buffer size; Godot then sends the saved
    /// settings (`AudioCommand::SetAudioConfig`).
    pub fn with_status_channel(
        status_tx: Sender<EngineStatus>,
        status_rx: Receiver<EngineStatus>,
    ) -> Result<Self> {
        info!("Initializing DAW audio engine...");
        info!("Using audio host: {}", cpal::default_host().id().name());

        // Create command channel for thread-safe communication
        let (command_tx, command_rx) = crossbeam::channel::unbounded();

        let state = Arc::new(Mutex::new(EngineState::default()));
        let block_clock = state.lock().expect("fresh state lock").block_clock.clone();
        let counters = Arc::new(CallbackCounters::default());

        let stream = StreamControl::spawn(CallbackContext {
            status_tx: status_tx.clone(),
            state: state.clone(),
            counters: counters.clone(),
            block_clock: block_clock.clone(),
        })?;
        let request = StreamRequest::default();
        let resolved = stream
            .resolve(&request)
            .map_err(anyhow::Error::msg)
            .context("No usable output device")?;
        let sample_rate = resolved.sample_rate;
        {
            let mut state_lock = state.lock().unwrap();
            state_lock.device_sample_rate = sample_rate as f32;
            state_lock.settings.sample_rate = sample_rate as i32;
            state_lock.ensure_master_channel(MAX_BLOCK_FRAMES);
        }
        let active = stream
            .start()
            .map_err(anyhow::Error::msg)
            .context("Failed to start the output stream")?;
        info!(
            "Output: {} at {} Hz, {} channels, period {} frames",
            active.device, active.sample_rate, active.channels, active.period_frames
        );

        // Command thread: applies commands, doing slow work outside the state lock
        let worker = CommandWorker::new(
            state.clone(),
            status_tx.clone(),
            command_tx.clone(),
            sample_rate as f32,
            MAX_BLOCK_FRAMES,
            block_clock,
            stream,
            request,
        );
        let command_thread = thread::Builder::new()
            .name("engine-commands".to_string())
            .spawn(move || worker.run(command_rx))
            .context("Failed to spawn command thread")?;

        pipewire::spawn_monitor(command_tx.clone(), counters);

        Ok(Self {
            _command_thread: command_thread,
            command_tx,
            status_tx,
            state,
            status_rx,
        })
    }

    /// Create and initialize a new audio engine (convenience method)
    pub fn new() -> Result<Self> {
        let (status_tx, status_rx) = crossbeam::channel::bounded(STATUS_CHANNEL_CAPACITY);
        Self::with_status_channel(status_tx, status_rx)
    }

    /// Send a command to the audio engine
    pub fn send_command(&self, cmd: AudioCommand) -> Result<()> {
        self.command_tx
            .send(cmd)
            .context("Failed to send command to audio engine")?;
        Ok(())
    }

    /// Hardware callback rate the mixer and devices are running at.
    pub fn device_sample_rate(&self) -> u32 {
        self.state.lock().unwrap().device_sample_rate.round() as u32
    }

    /// Get a clone of the command sender for external use
    pub fn command_sender(&self) -> Sender<AudioCommand> {
        self.command_tx.clone()
    }

    /// Get a handle to send status updates (for log forwarder)
    pub fn status_sender(&self) -> Sender<EngineStatus> {
        self.status_tx.clone()
    }

    /// Get status receiver for external use
    pub fn status_receiver(&self) -> Receiver<EngineStatus> {
        self.status_rx.clone()
    }

    /// Check if audio is currently playing
    pub fn is_playing(&self) -> bool {
        self.state.lock().unwrap().get_is_playing()
    }

    /// Get current playhead position
    pub fn current_tick(&self) -> Tick {
        self.state.lock().unwrap().get_current_tick()
    }
}
