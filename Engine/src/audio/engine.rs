use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, Stream, StreamConfig};
use crossbeam::channel::{Receiver, Sender};
use std::cell::RefCell;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{info, warn};

use super::commands::process_command;
pub use super::commands::{AudioCommand, CommandResponse, EngineState, EngineStatus};
use super::mixing::mix_and_output;
use super::processing::process_audio;
use super::types::*;

/// Audio engine that manages the audio stream and processing
pub struct AudioEngine {
    _stream: Stream,
    _command_thread: thread::JoinHandle<()>,
    command_tx: Sender<AudioCommand>,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    status_rx: Receiver<EngineStatus>,
}

impl AudioEngine {
    /// Create and initialize a new audio engine with provided status channel
    pub fn with_status_channel(
        status_tx: Sender<EngineStatus>,
        status_rx: Receiver<EngineStatus>,
    ) -> Result<Self> {
        info!("Initializing DAW audio engine...");

        // Get the default audio host
        let host = cpal::default_host();
        info!("Using audio host: {}", host.id().name());

        // Get the default output device first
        let default_device = host
            .default_output_device()
            .context("No output device available")?;
        let default_device_name = default_device.name()?;

        // Enumerate all output devices
        // Strategy: Default device always gets ID 1000, others get 1001+
        let mut output_devices = Vec::new();
        let mut non_default_devices = Vec::new();

        info!("Enumerating output devices:");
        if let Ok(devices) = host.output_devices() {
            for device in devices {
                if let Ok(name) = device.name() {
                    let is_default = name == default_device_name;
                    if is_default {
                        // Default device always gets ID 1000
                        output_devices.push(OutputDevice::new(1000, name.clone(), true));
                        info!("  Output device 1000: {} (default)", name);
                    } else {
                        // Store non-default devices for later assignment
                        non_default_devices.push(name);
                    }
                }
            }
        }

        // Assign IDs 1001+ to non-default devices
        let mut device_id = 1001;
        for name in non_default_devices {
            info!("  Output device {}: {}", device_id, name);
            output_devices.push(OutputDevice::new(device_id, name, false));
            device_id += 1;
        }

        info!("Using output device: {}", default_device_name);

        // Get the default output config
        let config = default_device.default_output_config()?;
        let sample_rate = config.sample_rate().0;
        info!("Sample rate: {} Hz", sample_rate);
        info!("Channels: {}", config.channels());

        // Create command channel for thread-safe communication
        let (command_tx, command_rx) = crossbeam::channel::unbounded();
        let command_rx_for_thread = command_rx.clone();

        // Use a safe maximum buffer size for plugin allocation
        // CPAL may request variable buffer sizes, so we allocate generously
        // Most systems use 128-2048 frames, but we allow up to 8192 to be safe
        let max_buffer_size = 8192;

        // Create shared state
        let state = Arc::new(Mutex::new(EngineState::default()));

        // Store the actual device sample rate and output devices
        {
            let mut state_lock = state.lock().unwrap();
            state_lock.device_sample_rate = sample_rate as f32;
            state_lock.output_devices = output_devices;
        }

        // Create command processing thread
        let command_thread_state = state.clone();
        let command_thread_status_tx = status_tx.clone();
        let command_thread_command_tx = command_tx.clone();
        let command_thread_max_buffer_size = max_buffer_size;
        let command_thread = thread::spawn(move || {
            Self::command_processing_loop(
                command_rx_for_thread,
                command_thread_state,
                command_thread_status_tx,
                command_thread_command_tx,
                command_thread_max_buffer_size,
            );
        });

        // Build the audio stream (pass a clone of status_tx, keep one for log forwarder)
        let stream = Self::build_stream(
            &default_device,
            &config.into(),
            command_rx,
            command_tx.clone(),
            status_tx.clone(),
            state.clone(),
            max_buffer_size,
        )?;

        // Start the stream
        stream.play()?;
        info!("Audio stream started");

        Ok(Self {
            _stream: stream,
            _command_thread: command_thread,
            command_tx,
            status_tx,
            state,
            status_rx,
        })
    }

    /// Create and initialize a new audio engine (convenience method)
    pub fn new() -> Result<Self> {
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        Self::with_status_channel(status_tx, status_rx)
    }

    /// Command processing loop that runs in a separate thread
    fn command_processing_loop(
        command_rx: Receiver<AudioCommand>,
        state: Arc<Mutex<EngineState>>,
        status_tx: Sender<EngineStatus>,
        command_tx: Sender<AudioCommand>,
        max_buffer_size: usize,
    ) {
        loop {
            match command_rx.recv() {
                Ok(cmd) => {
                    let mut state = match state.lock() {
                        Ok(s) => s,
                        Err(e) => {
                            warn!("Failed to lock state in command thread: {}", e);
                            continue;
                        }
                    };

                    if let Some(status) =
                        process_command(&mut state, cmd, max_buffer_size, &status_tx, &command_tx)
                    {
                        let _ = status_tx.send(status);
                    }
                }
                Err(_) => {
                    // Channel closed, exit thread
                    break;
                }
            }
        }
    }

    /// Build the audio output stream
    fn build_stream(
        device: &Device,
        config: &StreamConfig,
        command_rx: Receiver<AudioCommand>,
        command_tx: Sender<AudioCommand>,
        status_tx: Sender<EngineStatus>,
        state: Arc<Mutex<EngineState>>,
        max_buffer_size: usize,
    ) -> Result<Stream> {
        let sample_rate = config.sample_rate.0;
        let channels = config.channels as usize;

        // Counter for periodic status updates
        let mut samples_since_update = 0;
        let update_interval = sample_rate / 20; // 20 Hz updates

        // Performance metrics tracking (using RefCell for interior mutability)
        let perf_metrics_start = RefCell::new(Instant::now());
        let perf_metrics_interval = Duration::from_millis(500); // Send metrics every 500ms
        let cumulative_processing_time = RefCell::new(Duration::ZERO);
        let cumulative_block_duration = RefCell::new(Duration::ZERO);

        // Track if we've logged buffer size info
        let mut logged_buffer_info = false;

        let stream = device.build_output_stream(
            config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                // Start timing the audio processing
                let processing_start = Instant::now();

                // Lock state for audio processing (commands are processed in separate thread)
                let mut state = match state.lock() {
                    Ok(s) => s,
                    Err(_) => return, // Skip this buffer if lock fails
                };

                let frames = data.len() / channels;

                // Calculate block duration (time available for this buffer)
                let block_duration = Duration::from_secs_f64(frames as f64 / sample_rate as f64);

                // Clear channel buffers (pre-allocated to max size, only process first 'frames' samples)
                for channel in state.channels.values_mut() {
                    channel.clear_buffers();
                }

                // Log buffer size info once
                if !logged_buffer_info {
                    info!(
                        "Audio callback: data.len()={} channels={} frames={} max_buffer_size={}",
                        data.len(),
                        channels,
                        frames,
                        max_buffer_size
                    );
                    logged_buffer_info = true;
                }

                // Process audio if playing
                if state.get_is_playing() {
                    process_audio(&mut state, frames, sample_rate as f32);
                }

                // Mix channels and output
                mix_and_output(&mut state, data, channels, frames, &status_tx);

                // Update peaks
                for channel in state.channels.values_mut() {
                    channel.update_peaks();
                }

                // Measure actual processing time
                let processing_time = processing_start.elapsed();

                // Accumulate performance metrics
                *cumulative_processing_time.borrow_mut() += processing_time;
                *cumulative_block_duration.borrow_mut() += block_duration;

                // Send performance metrics every 500ms
                if perf_metrics_start.borrow().elapsed() >= perf_metrics_interval {
                    let cum_proc = *cumulative_processing_time.borrow();
                    let cum_block = *cumulative_block_duration.borrow();

                    // Calculate average load: processing_time / block_duration
                    // If cumulative_block_duration is zero, avoid division by zero
                    let avg_load = if cum_block.as_secs_f64() > 0.0 {
                        (cum_proc.as_secs_f64() / cum_block.as_secs_f64()) as f32
                    } else {
                        0.0
                    };

                    // Send engine load update
                    let _ = status_tx.send(EngineStatus::EngineLoad { load: avg_load });

                    // Reset metrics accumulation
                    *perf_metrics_start.borrow_mut() = Instant::now();
                    *cumulative_processing_time.borrow_mut() = Duration::ZERO;
                    *cumulative_block_duration.borrow_mut() = Duration::ZERO;
                }

                // Advance master sample counter by the number of frames just processed
                state.advance_sample_position(frames as u64);

                // Send periodic status updates
                samples_since_update += frames;
                if samples_since_update >= update_interval as usize {
                    samples_since_update = 0;

                    // Send playhead update
                    if state.get_is_playing() {
                        let _ =
                            status_tx.send(EngineStatus::PlayheadUpdate(state.get_current_tick()));
                        let _ = status_tx.send(EngineStatus::SamplePositionUpdate(
                            state.get_current_sample_position(),
                        ));
                    }

                    // Send meter updates
                    for channel in state.channels.values() {
                        let _ = status_tx.send(EngineStatus::ChannelPeaks {
                            id: channel.id,
                            peak_left: channel.peak_left,
                            peak_right: channel.peak_right,
                            rms_left: channel.rms_left,
                            rms_right: channel.rms_right,
                        });
                    }
                }
            },
            move |err| {
                tracing::warn!("Audio stream error: {}", err);
            },
            None,
        )?;

        Ok(stream)
    }

    /// Send a command to the audio engine
    pub fn send_command(&self, cmd: AudioCommand) -> Result<()> {
        self.command_tx
            .send(cmd)
            .context("Failed to send command to audio engine")?;
        Ok(())
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
