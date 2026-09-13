use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{
    BufferSize, Device, SampleFormat, SampleRate, Stream, StreamConfig, SupportedBufferSize,
};
use crossbeam::channel::{Receiver, Sender};
use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{info, warn};

use super::command_worker::CommandWorker;
pub use super::commands::{AudioCommand, CommandResponse, EngineState, EngineStatus};
use super::mixing::mix_and_output;
use super::processing::process_audio;
use super::types::*;

/// Preferred device sample rate in Hz.
const PREFERRED_SAMPLE_RATE: u32 = 48_000;

/// Preferred ALSA buffer size in frames (~21 ms at 48 kHz); cpal uses a quarter of it as the
/// period size. Keep it at or above PipeWire's graph quantum or the stream will underrun.
const PREFERRED_BUFFER_FRAMES: u32 = 1024;

/// How long the audio callback keeps retrying the state lock before outputting silence for the
/// buffer. The command thread only holds the lock briefly, so this should rarely be reached.
const STATE_LOCK_BUDGET: Duration = Duration::from_millis(1);

/// Restart the output stream if PipeWire/ALSA stops invoking the callback (idle suspend, xrun).
const CALLBACK_STALL_TIMEOUT: Duration = Duration::from_millis(1500);

/// How often the watchdog thread samples the callback counter.
const WATCHDOG_POLL: Duration = Duration::from_millis(250);

/// Audio engine that manages the audio stream and processing
pub struct AudioEngine {
    _running: Arc<AtomicBool>,
    _stream_thread: thread::JoinHandle<()>,
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

        let config = Self::select_stream_config(&default_device)?;
        let sample_rate = config.sample_rate.0;
        info!("Sample rate: {} Hz", sample_rate);
        info!("Channels: {}", config.channels);
        info!("Buffer size: {:?}", config.buffer_size);

        // Create command channel for thread-safe communication
        let (command_tx, command_rx) = crossbeam::channel::unbounded();

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
            state_lock.ensure_master_channel(max_buffer_size);
        }

        // Command thread: applies commands, doing slow work outside the state lock
        let worker = CommandWorker::new(
            state.clone(),
            status_tx.clone(),
            command_tx.clone(),
            sample_rate as f32,
            max_buffer_size,
        );
        let command_thread = thread::Builder::new()
            .name("engine-commands".to_string())
            .spawn(move || worker.run(command_rx))
            .context("Failed to spawn command thread")?;

        let callback_count = Arc::new(AtomicU64::new(0));
        let running = Arc::new(AtomicBool::new(true));

        let stream_thread = spawn_stream_thread(StreamThread {
            device: default_device,
            config,
            status_tx: status_tx.clone(),
            state: state.clone(),
            callback_count,
            running: running.clone(),
        })?;

        Ok(Self {
            _running: running,
            _stream_thread: stream_thread,
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

    /// Choose an f32 output config at `PREFERRED_SAMPLE_RATE` with a fixed buffer size,
    /// falling back to the device default config when that rate isn't supported.
    fn select_stream_config(device: &Device) -> Result<StreamConfig> {
        let default_config = device.default_output_config()?;
        let preferred_rate = SampleRate(PREFERRED_SAMPLE_RATE);

        let range = device.supported_output_configs()?.find(|range| {
            range.sample_format() == SampleFormat::F32
                && range.channels() == default_config.channels()
                && range.min_sample_rate() <= preferred_rate
                && preferred_rate <= range.max_sample_rate()
        });

        let Some(range) = range else {
            warn!(
                "Device has no {} Hz f32 output config, using default {:?}",
                PREFERRED_SAMPLE_RATE, default_config
            );
            return Ok(default_config.config());
        };

        let buffer_frames = match *range.buffer_size() {
            SupportedBufferSize::Range { min, max } => PREFERRED_BUFFER_FRAMES.clamp(min, max),
            SupportedBufferSize::Unknown => PREFERRED_BUFFER_FRAMES,
        };
        let mut config = range.with_sample_rate(preferred_rate).config();
        config.buffer_size = BufferSize::Fixed(buffer_frames);
        Ok(config)
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

impl Drop for AudioEngine {
    fn drop(&mut self) {
        self._running.store(false, Ordering::Release);
    }
}

/// Owns the CPAL output stream on one thread (`Stream` is `!Send`).
struct StreamThread {
    device: Device,
    config: StreamConfig,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    callback_count: Arc<AtomicU64>,
    running: Arc<AtomicBool>,
}

/// Open a CPAL output stream, falling back from a fixed buffer to the device default.
fn open_output_stream(
    device: &Device,
    config: &StreamConfig,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    callback_count: Arc<AtomicU64>,
) -> Result<Stream> {
    match build_stream(
        device,
        config,
        status_tx.clone(),
        state.clone(),
        callback_count.clone(),
    ) {
        Ok(stream) => Ok(stream),
        Err(e) if matches!(config.buffer_size, BufferSize::Fixed(_)) => {
            warn!(
                "Failed to open stream with {:?} ({}), retrying with device default buffer",
                config.buffer_size, e
            );
            let mut fallback = config.clone();
            fallback.buffer_size = BufferSize::Default;
            build_stream(device, &fallback, status_tx, state, callback_count)
        }
        Err(e) => Err(e),
    }
}

/// Create, play, and watch the output stream on a dedicated thread.
///
/// A stalled ALSA/`poll` can hang `Stream` drop, so a dead stream is leaked with
/// `mem::forget` rather than joined. A new stream is opened on this same thread.
fn spawn_stream_thread(ctx: StreamThread) -> Result<thread::JoinHandle<()>> {
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let handle = thread::Builder::new()
        .name("audio-stream".to_string())
        .spawn(move || {
            let mut stream = match open_output_stream(
                &ctx.device,
                &ctx.config,
                ctx.status_tx.clone(),
                ctx.state.clone(),
                ctx.callback_count.clone(),
            ) {
                Ok(stream) => stream,
                Err(e) => {
                    let _ = ready_tx.send(Err(e.to_string()));
                    return;
                }
            };
            if let Err(e) = stream.play() {
                let _ = ready_tx.send(Err(e.to_string()));
                return;
            }
            info!("Audio stream started");
            let _ = ready_tx.send(Ok(()));

            let mut last_count = ctx.callback_count.load(Ordering::Relaxed);
            let mut stalled_since: Option<Instant> = None;
            let mut next_restart = Instant::now();
            let mut backoff = CALLBACK_STALL_TIMEOUT;

            while ctx.running.load(Ordering::Acquire) {
                thread::sleep(WATCHDOG_POLL);
                let count = ctx.callback_count.load(Ordering::Relaxed);
                if count != last_count {
                    last_count = count;
                    stalled_since = None;
                    backoff = CALLBACK_STALL_TIMEOUT;
                    continue;
                }

                let stalled_at = *stalled_since.get_or_insert_with(Instant::now);
                if stalled_at.elapsed() < CALLBACK_STALL_TIMEOUT || Instant::now() < next_restart {
                    continue;
                }

                warn!(
                    "Audio callback stalled for {:.1}s (PipeWire/ALSA stopped waking CPAL); restarting output stream",
                    stalled_at.elapsed().as_secs_f32()
                );

                match open_output_stream(
                    &ctx.device,
                    &ctx.config,
                    ctx.status_tx.clone(),
                    ctx.state.clone(),
                    ctx.callback_count.clone(),
                ) {
                    Ok(new_stream) => match new_stream.play() {
                        Ok(()) => {
                            let old = std::mem::replace(&mut stream, new_stream);
                            std::mem::forget(old);
                            info!("Audio stream restarted");
                            last_count = ctx.callback_count.load(Ordering::Relaxed);
                            stalled_since = None;
                        }
                        Err(e) => warn!("Failed to play restarted audio stream: {}", e),
                    },
                    Err(e) => warn!("Failed to restart audio stream: {}", e),
                }
                next_restart = Instant::now() + backoff;
                backoff = (backoff * 2).min(Duration::from_secs(10));
            }
        })
        .context("Failed to spawn audio stream thread")?;

    match ready_rx.recv().context("Audio stream thread exited")? {
        Ok(()) => Ok(handle),
        Err(e) => Err(anyhow::anyhow!(e)),
    }
}

/// Build the audio output stream. `callback_count` is incremented on every callback (including
/// lock-fail silence) so the watchdog can tell hardware is still waking this process.
fn build_stream(
    device: &Device,
    config: &StreamConfig,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    callback_count: Arc<AtomicU64>,
) -> Result<Stream> {
    let sample_rate = config.sample_rate.0;
    let channels = config.channels as usize;

    let mut samples_since_update = 0;
    let update_interval = sample_rate / 20;

    let perf_metrics_start = RefCell::new(Instant::now());
    let perf_metrics_interval = Duration::from_millis(500);
    let cumulative_processing_time = RefCell::new(Duration::ZERO);
    let cumulative_block_duration = RefCell::new(Duration::ZERO);

    let stream = device.build_output_stream(
        config,
        move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
            callback_count.fetch_add(1, Ordering::Relaxed);
            let processing_start = Instant::now();

            let Some(mut state) = lock_state_for_callback(&state, processing_start) else {
                data.fill(0.0);
                return;
            };

            let frames = data.len() / channels;
            let block_duration = Duration::from_secs_f64(frames as f64 / sample_rate as f64);

            for channel in state.channels.values_mut() {
                channel.clear_buffers();
            }

            process_audio(&mut state, frames, sample_rate as f32, processing_start);
            mix_and_output(&mut state, data, channels, frames, &status_tx);

            for channel in state.channels.values_mut() {
                channel.update_peaks();
            }

            let processing_time = processing_start.elapsed();
            *cumulative_processing_time.borrow_mut() += processing_time;
            *cumulative_block_duration.borrow_mut() += block_duration;

            if perf_metrics_start.borrow().elapsed() >= perf_metrics_interval {
                let cum_proc = *cumulative_processing_time.borrow();
                let cum_block = *cumulative_block_duration.borrow();
                let avg_load = if cum_block.as_secs_f64() > 0.0 {
                    (cum_proc.as_secs_f64() / cum_block.as_secs_f64()) as f32
                } else {
                    0.0
                };
                let _ = status_tx.send(EngineStatus::EngineLoad { load: avg_load });
                *perf_metrics_start.borrow_mut() = Instant::now();
                *cumulative_processing_time.borrow_mut() = Duration::ZERO;
                *cumulative_block_duration.borrow_mut() = Duration::ZERO;
            }

            state.advance_sample_position(frames as u64);

            samples_since_update += frames;
            if samples_since_update >= update_interval as usize {
                samples_since_update = 0;

                if state.get_is_playing() {
                    let _ = status_tx.send(EngineStatus::PlayheadUpdate(state.get_current_tick()));
                    let _ = status_tx.send(EngineStatus::SamplePositionUpdate(
                        state.get_current_sample_position(),
                    ));
                }

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

/// Lock the engine state from the audio callback without sleeping in the OS.
///
/// Spins on `try_lock` until `STATE_LOCK_BUDGET` has passed since `callback_start` and returns
/// None if the command thread still holds the lock. A poisoned lock is recovered so audio keeps
/// running after a command panicked.
fn lock_state_for_callback(
    state: &Mutex<EngineState>,
    callback_start: Instant,
) -> Option<MutexGuard<'_, EngineState>> {
    loop {
        match state.try_lock() {
            Ok(guard) => return Some(guard),
            Err(TryLockError::Poisoned(poisoned)) => return Some(poisoned.into_inner()),
            Err(TryLockError::WouldBlock) if callback_start.elapsed() < STATE_LOCK_BUDGET => {
                std::hint::spin_loop()
            }
            Err(TryLockError::WouldBlock) => return None,
        }
    }
}
