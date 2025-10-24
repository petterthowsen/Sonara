use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, Stream, StreamConfig};
use crossbeam::channel::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use tracing::info;

use super::types::*;
pub use super::commands::{AudioCommand, CommandResponse, EngineStatus, EngineState};
use super::commands::process_command;
use super::processing::process_audio;
use super::mixing::mix_and_output;

/// Audio engine that manages the audio stream and processing
pub struct AudioEngine {
    _stream: Stream,
    command_tx: Sender<AudioCommand>,
    state: Arc<Mutex<EngineState>>,
    status_rx: Receiver<EngineStatus>,
}

impl AudioEngine {
    /// Create and initialize a new audio engine
    pub fn new() -> Result<Self> {
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
        let (status_tx, status_rx) = crossbeam::channel::unbounded();

        // Create shared state
        let state = Arc::new(Mutex::new(EngineState::default()));

        // Store the actual device sample rate and output devices
        {
            let mut state_lock = state.lock().unwrap();
            state_lock.device_sample_rate = sample_rate as f32;
            state_lock.output_devices = output_devices;
        }

        // Build the audio stream
        let stream = Self::build_stream(
            &default_device,
            &config.into(),
            command_rx,
            command_tx.clone(),
            status_tx,
            state.clone(),
        )?;

        // Start the stream
        stream.play()?;
        info!("Audio stream started");

        Ok(Self {
            _stream: stream,
            command_tx,
            state,
            status_rx,
        })
    }

    /// Build the audio output stream
    fn build_stream(
        device: &Device,
        config: &StreamConfig,
        command_rx: Receiver<AudioCommand>,
        command_tx: Sender<AudioCommand>,
        status_tx: Sender<EngineStatus>,
        state: Arc<Mutex<EngineState>>,
    ) -> Result<Stream> {
        let sample_rate = config.sample_rate.0;
        let channels = config.channels as usize;
        
        // Use a safe maximum buffer size for plugin allocation
        // CPAL may request variable buffer sizes, so we allocate generously
        // Most systems use 128-2048 frames, but we allow up to 8192 to be safe
        let max_buffer_size = 8192;

        // Counter for periodic status updates
        let mut samples_since_update = 0;
        let update_interval = sample_rate / 20; // 20 Hz updates

        // Track if we've logged buffer size info
        let mut logged_buffer_info = false;

        let stream = device.build_output_stream(
            config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                // Process any pending commands (lock-free)
                while let Ok(cmd) = command_rx.try_recv() {
                    if let Ok(mut state) = state.lock() {
                        if let Some(status) = process_command(&mut state, cmd, max_buffer_size, &status_tx, &command_tx) {
                            let _ = status_tx.send(status);
                        }
                    }
                }

                // Lock state for audio processing
                let mut state = match state.lock() {
                    Ok(s) => s,
                    Err(_) => return, // Skip this buffer if lock fails
                };

                let frames = data.len() / channels;

                // Resize channel buffers if needed
                for channel in state.channels.values_mut() {
                    if channel.buffer_left.len() != frames {
                        if !logged_buffer_info {
                            info!("Resizing channel {} buffers from {} to {} frames",
                                channel.id, channel.buffer_left.len(), frames);
                        }
                        channel.resize_buffers(frames);
                    }
                    channel.clear_buffers();
                }

                // Log buffer size info once
                if !logged_buffer_info {
                    info!("Audio callback: data.len()={} channels={} frames={} max_buffer_size={}",
                        data.len(), channels, frames, max_buffer_size);
                    logged_buffer_info = true;
                }

                // Process audio if playing
                if state.is_playing {
                    process_audio(&mut state, frames, sample_rate as f32);
                }

                // Mix channels and output
                mix_and_output(&mut state, data, channels, &status_tx);

                // Update peaks
                for channel in state.channels.values_mut() {
                    channel.update_peaks();
                }

                // Send periodic status updates
                samples_since_update += frames;
                if samples_since_update >= update_interval as usize {
                    samples_since_update = 0;

                    // Send playhead update
                    if state.is_playing {
                        let _ = status_tx.send(EngineStatus::PlayheadUpdate(state.current_tick));
                    }

                    // Send meter updates
                    for channel in state.channels.values() {
                        let _ = status_tx.send(EngineStatus::ChannelPeaks {
                            id: channel.id,
                            peak_left: channel.peak_left,
                            peak_right: channel.peak_right,
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

    /// Get status receiver for external use
    pub fn status_receiver(&self) -> Receiver<EngineStatus> {
        self.status_rx.clone()
    }

    /// Check if audio is currently playing
    pub fn is_playing(&self) -> bool {
        self.state.lock().unwrap().is_playing
    }

    /// Get current playhead position
    pub fn current_tick(&self) -> Tick {
        self.state.lock().unwrap().current_tick
    }
}
