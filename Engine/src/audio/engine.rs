use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{
    BufferSize, Device, SampleFormat, SampleRate, Stream, StreamConfig, SupportedBufferSize,
};
use crossbeam::channel::{Receiver, Sender};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{info, warn};

use super::block_clock::BlockClock;
use super::command_worker::CommandWorker;
pub use super::commands::{AudioCommand, CommandResponse, EngineState, EngineStatus};
use super::devices::clap_host::subprocess_adapter::PLUGIN_UNDERRUNS;
use super::mixing::mix_and_output;
use super::processing::process_audio;
use super::rt_debug;
use super::types::*;

/// Preferred device sample rate in Hz.
const PREFERRED_SAMPLE_RATE: u32 = 48_000;

/// Preferred frames per callback (~21 ms at 48 kHz). This is the ALSA period, which PipeWire
/// also adopts as the graph quantum (`node.latency`).
const PREFERRED_PERIOD_FRAMES: u32 = 1024;

/// cpal 0.15's ALSA backend sets the period to a quarter of `BufferSize::Fixed`, so ask for a
/// buffer of four periods. The buffer must also stay at or above PipeWire's graph quantum or the
/// stream underruns inside PipeWire, invisibly to the engine.
const PREFERRED_BUFFER_FRAMES: u32 = PREFERRED_PERIOD_FRAMES * 4;

/// How long the audio callback keeps retrying the state lock before outputting silence for the
/// buffer. The command thread only holds the lock briefly, so this should rarely be reached.
const STATE_LOCK_BUDGET: Duration = Duration::from_millis(1);

/// Restart the output stream if PipeWire/ALSA stops invoking the callback (idle suspend, xrun).
const CALLBACK_STALL_TIMEOUT: Duration = Duration::from_millis(1500);

/// How often the watchdog thread samples the callback counter.
const WATCHDOG_POLL: Duration = Duration::from_millis(250);

/// Capacity of the engine → OSC status channel (~1.6 MB preallocated at 200 bytes per status):
/// several seconds of meters for 100 channels at 20 Hz. Bounded so sends never allocate. The
/// audio callback uses `try_send` and drops statuses when it's full; other threads block.
pub const STATUS_CHANNEL_CAPACITY: usize = 8_192;

/// How often the callback sends `EngineStatus::EngineStats` (2 Hz).
const STATS_INTERVAL: Duration = Duration::from_millis(500);

/// A gap between callback starts longer than this many block durations counts as an xrun.
/// cpal 0.15's ALSA backend recovers underruns without calling the error callback, so this is
/// the main xrun signal.
const XRUN_GAP_FACTOR: f64 = 1.5;

/// Counters shared by every output stream the engine opens, so totals survive a watchdog restart.
#[derive(Default)]
struct CallbackCounters {
    /// Incremented on every callback (including lock-miss silence) so the watchdog can tell
    /// hardware is still waking this process.
    callbacks: AtomicU64,
    xruns: AtomicU64,
    lock_misses: AtomicU64,
}

/// Per-stream load accounting for one `STATS_INTERVAL`. Lives in the callback closure.
struct LoadWindow {
    started: Instant,
    processing: Duration,
    block_time: Duration,
    peak: f32,
}

impl LoadWindow {
    fn new(now: Instant) -> Self {
        Self {
            started: now,
            processing: Duration::ZERO,
            block_time: Duration::ZERO,
            peak: 0.0,
        }
    }

    fn add(&mut self, processing: Duration, block: Duration) {
        self.processing += processing;
        self.block_time += block;
        if !block.is_zero() {
            self.peak = self
                .peak
                .max((processing.as_secs_f64() / block.as_secs_f64()) as f32);
        }
    }

    fn average(&self) -> f32 {
        if self.block_time.is_zero() {
            0.0
        } else {
            (self.processing.as_secs_f64() / self.block_time.as_secs_f64()) as f32
        }
    }
}

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
        let block_clock = state.lock().expect("fresh state lock").block_clock.clone();

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
            block_clock.clone(),
        );
        let command_thread = thread::Builder::new()
            .name("engine-commands".to_string())
            .spawn(move || worker.run(command_rx))
            .context("Failed to spawn command thread")?;

        let counters = Arc::new(CallbackCounters::default());
        let running = Arc::new(AtomicBool::new(true));

        let stream_thread = spawn_stream_thread(StreamThread {
            device: default_device,
            config,
            status_tx: status_tx.clone(),
            state: state.clone(),
            counters,
            running: running.clone(),
            block_clock,
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
        let (status_tx, status_rx) = crossbeam::channel::bounded(STATUS_CHANNEL_CAPACITY);
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
    counters: Arc<CallbackCounters>,
    running: Arc<AtomicBool>,
    block_clock: Arc<BlockClock>,
}

/// Open a CPAL output stream, falling back from a fixed buffer to the device default.
fn open_output_stream(
    device: &Device,
    config: &StreamConfig,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    counters: Arc<CallbackCounters>,
    block_clock: Arc<BlockClock>,
) -> Result<Stream> {
    match build_stream(
        device,
        config,
        status_tx.clone(),
        state.clone(),
        counters.clone(),
        block_clock.clone(),
    ) {
        Ok(stream) => Ok(stream),
        Err(e) if matches!(config.buffer_size, BufferSize::Fixed(_)) => {
            warn!(
                "Failed to open stream with {:?} ({}), retrying with device default buffer",
                config.buffer_size, e
            );
            let mut fallback = config.clone();
            fallback.buffer_size = BufferSize::Default;
            build_stream(device, &fallback, status_tx, state, counters, block_clock)
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
                ctx.counters.clone(),
                ctx.block_clock.clone(),
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

            let mut last_count = ctx.counters.callbacks.load(Ordering::Relaxed);
            let mut stalled_since: Option<Instant> = None;
            let mut next_restart = Instant::now();
            let mut backoff = CALLBACK_STALL_TIMEOUT;

            while ctx.running.load(Ordering::Acquire) {
                thread::sleep(WATCHDOG_POLL);
                let count = ctx.counters.callbacks.load(Ordering::Relaxed);
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
                    ctx.counters.clone(),
                    ctx.block_clock.clone(),
                ) {
                    Ok(new_stream) => match new_stream.play() {
                        Ok(()) => {
                            let old = std::mem::replace(&mut stream, new_stream);
                            std::mem::forget(old);
                            info!("Audio stream restarted");
                            last_count = ctx.counters.callbacks.load(Ordering::Relaxed);
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

/// Build the audio output stream. Every callback updates `counters` and, every
/// `STATS_INTERVAL`, sends `EngineStatus::EngineStats` (also after a lock miss, so the UI can
/// tell a busy engine from a stalled one).
fn build_stream(
    device: &Device,
    config: &StreamConfig,
    status_tx: Sender<EngineStatus>,
    state: Arc<Mutex<EngineState>>,
    counters: Arc<CallbackCounters>,
    block_clock: Arc<BlockClock>,
) -> Result<Stream> {
    let sample_rate = config.sample_rate.0;
    let channels = config.channels as usize;

    let mut samples_since_update = 0;
    let update_interval = sample_rate / 20;

    let mut load = LoadWindow::new(Instant::now());
    // Start and expected duration of the previous callback, for gap (xrun) detection.
    let mut previous_block: Option<(Instant, Duration)> = None;

    let error_counters = counters.clone();

    let stream = device.build_output_stream(
        config,
        move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
            let processing_start = Instant::now();
            counters.callbacks.fetch_add(1, Ordering::Relaxed);

            let frames = data.len() / channels;
            let block_duration = Duration::from_secs_f64(frames as f64 / sample_rate as f64);

            if let Some((previous_start, previous_duration)) = previous_block {
                let gap = processing_start.duration_since(previous_start);
                if gap.as_secs_f64() > previous_duration.as_secs_f64() * XRUN_GAP_FACTOR {
                    counters.xruns.fetch_add(1, Ordering::Relaxed);
                }
            }
            previous_block = Some((processing_start, block_duration));

            // One absolute deadline for every subprocess plugin in this callback.
            block_clock.publish(processing_start, block_duration);

            rt_debug::check_callback(|| {
                let Some(mut state) = lock_state_for_callback(&state, processing_start) else {
                    counters.lock_misses.fetch_add(1, Ordering::Relaxed);
                    data.fill(0.0);
                    return;
                };

                rt_debug::section("clear buffers", || {
                    for channel in state.channels.values_mut() {
                        channel.clear_buffers();
                    }
                });

                rt_debug::section("process_audio", || {
                    process_audio(&mut state, frames, sample_rate as f32, processing_start)
                });
                rt_debug::section("mix_and_output", || {
                    mix_and_output(&mut state, data, channels, frames, &status_tx)
                });

                rt_debug::section("update_peaks", || {
                    for channel in state.channels.values_mut() {
                        channel.update_peaks(frames, sample_rate as f32);
                    }
                });

                samples_since_update += frames;
                if samples_since_update >= update_interval as usize {
                    // Subtract rather than reset: resetting discards the remainder, which makes
                    // the status cadence slower and less regular than the nominal rate.
                    samples_since_update -= update_interval as usize;
                    rt_debug::section("playhead/meter sends", || {
                        send_meters(&mut state, &status_tx)
                    });
                }
            });

            load.add(processing_start.elapsed(), block_duration);
            if load.started.elapsed() >= STATS_INTERVAL {
                let _ = status_tx.try_send(EngineStatus::EngineStats {
                    load_avg: load.average(),
                    load_peak: load.peak,
                    xruns: counters.xruns.load(Ordering::Relaxed),
                    lock_misses: counters.lock_misses.load(Ordering::Relaxed),
                    callbacks: counters.callbacks.load(Ordering::Relaxed),
                    frames: frames as u32,
                    plugin_underruns: PLUGIN_UNDERRUNS.load(Ordering::Relaxed),
                });
                load = LoadWindow::new(Instant::now());
                rt_debug::report();
            }
        },
        move |err| {
            error_counters.xruns.fetch_add(1, Ordering::Relaxed);
            tracing::warn!("Audio stream error: {}", err);
        },
        None,
    )?;

    Ok(stream)
}

/// Send the playhead (while playing) and every channel's meters.
fn send_meters(state: &mut EngineState, status_tx: &Sender<EngineStatus>) {
    if state.get_is_playing() {
        let _ = status_tx.try_send(EngineStatus::PlayheadUpdate(state.get_current_tick()));
    }

    // Draining the peaks starts a fresh max for the next interval, so a transient
    // in any block between sends still reaches the meter.
    for channel in state.channels.values_mut() {
        let (peak_left, peak_right, rms_left, rms_right) = channel.take_meters();
        let _ = status_tx.try_send(EngineStatus::ChannelPeaks {
            id: channel.id,
            peak_left,
            peak_right,
            rms_left,
            rms_right,
        });
    }
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
