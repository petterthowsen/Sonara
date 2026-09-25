//! The hardware output stream (Phase 7): device enumeration, config selection, and the stream
//! thread that owns the CPAL stream and its watchdog.
//!
//! `Stream` is `!Send`, so one thread owns it and takes requests over a channel. The command
//! thread reconfigures in steps (`stop`, `resolve`, prepare devices, `start`) so devices can be
//! prepared for the new rate while no callback runs.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{
    BufferSize, Device, SampleFormat, SampleRate, Stream, StreamConfig, SupportedBufferSize,
};
use crossbeam::channel::{Receiver, RecvTimeoutError, Sender};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{info, warn};

use super::block_clock::BlockClock;
use super::commands::{EngineState, EngineStatus};
use super::devices::clap_host::subprocess_adapter::PLUGIN_UNDERRUNS;
use super::mixing::mix_and_output;
use super::processing::process_audio;
use super::rt_debug;

/// Largest block the engine renders. Channel, device and plugin buffers are preallocated at this
/// size, so a buffer-size change never reallocates them.
pub const MAX_BLOCK_FRAMES: usize = 8192;

/// cpal 0.15's ALSA backend sets the period to a quarter of `BufferSize::Fixed`, so the engine
/// asks for a buffer of this many periods. The period is the buffer-size setting (frames per
/// callback, which PipeWire adopts as the node latency). Recheck after a cpal upgrade.
pub const ALSA_PERIODS: u32 = 4;

/// Smallest period the engine asks for.
pub const MIN_PERIOD_FRAMES: u32 = 32;

/// Largest period: cpal's ALSA callback can deliver the whole buffer (`ALSA_PERIODS` periods) at
/// once, and that must still fit `MAX_BLOCK_FRAMES`.
pub const MAX_PERIOD_FRAMES: u32 = MAX_BLOCK_FRAMES as u32 / ALSA_PERIODS;

/// Rate and period used until Godot sends the saved settings (and when they can't be opened).
pub const DEFAULT_SAMPLE_RATE: u32 = 48_000;
pub const DEFAULT_PERIOD_FRAMES: u32 = 1024;

/// Rates offered for devices that accept a continuous range (PipeWire, `plughw`).
const COMMON_SAMPLE_RATES: [u32; 8] = [
    22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
];

/// A device reporting at least this many channel counts accepts any count (a plugin device
/// such as `pipewire` or `plughw`; cpal caps the list at 32). Those open with their default
/// count instead of 32 channels.
const ANY_CHANNEL_COUNT: u16 = 32;

/// How long the audio callback keeps retrying the state lock before outputting silence for the
/// buffer. The command thread only holds the lock briefly, so this should rarely be reached.
const STATE_LOCK_BUDGET: Duration = Duration::from_millis(1);

/// Restart the output stream if PipeWire/ALSA stops invoking the callback (idle suspend, xrun).
const CALLBACK_STALL_TIMEOUT: Duration = Duration::from_millis(1500);

/// How often the watchdog samples the callback counter (also the stream thread's request poll).
const WATCHDOG_POLL: Duration = Duration::from_millis(250);

/// How long the command thread waits for the stream thread to open or close a stream.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// How often the callback sends `EngineStatus::EngineStats` (2 Hz).
const STATS_INTERVAL: Duration = Duration::from_millis(500);

/// With a device-default buffer (size unknown), a gap between callback starts longer than this
/// many block durations counts as an xrun. cpal 0.15's ALSA backend recovers underruns without
/// calling the error callback, so callback gaps are the main xrun signal.
const XRUN_GAP_FACTOR: f64 = 1.5;

/// The output configuration the user asked for. An empty `device` is the system default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamRequest {
    pub device: String,
    pub sample_rate: u32,
    pub period_frames: u32,
}

impl Default for StreamRequest {
    fn default() -> Self {
        Self {
            device: String::new(),
            sample_rate: DEFAULT_SAMPLE_RATE,
            period_frames: DEFAULT_PERIOD_FRAMES,
        }
    }
}

/// The configuration a stream actually runs with, which may differ from the request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamInfo {
    pub device: String,
    pub is_default_device: bool,
    pub sample_rate: u32,
    /// Frames per callback asked of ALSA; 0 when the device only opened with its own default.
    pub period_frames: u32,
    pub channels: u16,
}

impl StreamInfo {
    /// Stereo output pairs on the device: hardware output 1000 is 1/2, 1001 is 3/4, …
    pub fn output_pairs(&self) -> usize {
        (self.channels as usize / 2).max(1)
    }

    /// Latency of one period in milliseconds.
    pub fn latency_ms(&self) -> f32 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.period_frames as f32 * 1000.0 / self.sample_rate as f32
    }

    /// Frames in the whole ALSA buffer.
    pub fn buffer_frames(&self) -> u32 {
        self.period_frames * ALSA_PERIODS
    }
}

/// One output device, for the Settings device list.
#[derive(Debug, Clone)]
pub struct OutputDeviceInfo {
    pub name: String,
    pub is_default: bool,
    /// Empty when the device couldn't be queried (busy, or no f32 support).
    pub sample_rates: Vec<u32>,
    pub min_period: u32,
    pub max_period: u32,
    pub channels: u16,
}

/// Counters shared by every output stream the engine opens, so totals survive a restart or a
/// reconfigure.
#[derive(Default)]
pub struct CallbackCounters {
    /// Incremented on every callback (including lock-miss silence) so the watchdog can tell
    /// hardware is still waking this process.
    pub callbacks: AtomicU64,
    /// Stream errors, callback gaps and PipeWire errors on the engine's node.
    pub xruns: AtomicU64,
    pub lock_misses: AtomicU64,
}

/// What every stream callback needs, cloned into each stream the thread opens.
#[derive(Clone)]
pub struct CallbackContext {
    pub status_tx: Sender<EngineStatus>,
    pub state: Arc<Mutex<EngineState>>,
    pub counters: Arc<CallbackCounters>,
    pub block_clock: Arc<BlockClock>,
}

/// Requests from the command thread to the stream thread.
enum StreamMsg {
    Resolve(StreamRequest, Sender<Result<StreamInfo, String>>),
    Start(Sender<Result<StreamInfo, String>>),
    Stop(Sender<()>),
}

/// A request resolved to a CPAL device and config, waiting for `Start`.
struct Resolved {
    device: Device,
    config: StreamConfig,
    info: StreamInfo,
}

/// Handle to the stream thread. Cheap to clone.
#[derive(Clone)]
pub struct StreamControl {
    tx: Sender<StreamMsg>,
    active: Arc<Mutex<Option<StreamInfo>>>,
}

impl StreamControl {
    /// Spawn the stream thread. No stream runs until `resolve` and `start`.
    pub fn spawn(ctx: CallbackContext) -> Result<Self> {
        let (tx, rx) = crossbeam::channel::unbounded();
        let active = Arc::new(Mutex::new(None));
        let thread_active = Arc::clone(&active);
        thread::Builder::new()
            .name("audio-stream".to_string())
            .spawn(move || run_stream_thread(ctx, rx, thread_active))
            .context("Failed to spawn audio stream thread")?;
        Ok(Self { tx, active })
    }

    /// Pick the device and config for `request` without opening it. The result is what `start`
    /// will open: its rate is the one to prepare devices for.
    pub fn resolve(&self, request: &StreamRequest) -> Result<StreamInfo, String> {
        let (reply_tx, reply_rx) = crossbeam::channel::bounded(1);
        self.send(StreamMsg::Resolve(request.clone(), reply_tx))?;
        Self::wait(reply_rx)?
    }

    /// Open and play the last resolved config.
    pub fn start(&self) -> Result<StreamInfo, String> {
        let (reply_tx, reply_rx) = crossbeam::channel::bounded(1);
        self.send(StreamMsg::Start(reply_tx))?;
        Self::wait(reply_rx)?
    }

    /// Stop and close the running stream, if any. No callback runs once this returns.
    pub fn stop(&self) -> Result<(), String> {
        let (reply_tx, reply_rx) = crossbeam::channel::bounded(1);
        self.send(StreamMsg::Stop(reply_tx))?;
        Self::wait(reply_rx)
    }

    /// The running stream's configuration, None while stopped.
    pub fn active(&self) -> Option<StreamInfo> {
        self.active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn send(&self, msg: StreamMsg) -> Result<(), String> {
        self.tx
            .send(msg)
            .map_err(|_| "audio stream thread exited".to_string())
    }

    fn wait<T>(reply_rx: Receiver<T>) -> Result<T, String> {
        reply_rx
            .recv_timeout(REQUEST_TIMEOUT)
            .map_err(|_| "audio stream thread didn't answer".to_string())
    }
}

/// The running stream and what the watchdog needs to reopen it.
struct ActiveStream {
    stream: Stream,
    device: Device,
    config: StreamConfig,
    info: StreamInfo,
    last_count: u64,
    stalled_since: Option<Instant>,
    next_restart: Instant,
    backoff: Duration,
}

fn run_stream_thread(
    ctx: CallbackContext,
    rx: Receiver<StreamMsg>,
    shared_active: Arc<Mutex<Option<StreamInfo>>>,
) {
    let set_shared = |info: Option<StreamInfo>| {
        *shared_active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = info;
    };
    let mut pending: Option<Resolved> = None;
    let mut active: Option<ActiveStream> = None;

    loop {
        match rx.recv_timeout(WATCHDOG_POLL) {
            Ok(StreamMsg::Resolve(request, reply)) => {
                let result = resolve(&request).map(|resolved| {
                    let info = resolved.info.clone();
                    pending = Some(resolved);
                    info
                });
                let _ = reply.send(result);
            }
            Ok(StreamMsg::Start(reply)) => {
                let result = match pending.take() {
                    None => Err("no stream config resolved".to_string()),
                    Some(_) if active.is_some() => Err("a stream is already running".to_string()),
                    Some(resolved) => match start(&ctx, resolved) {
                        Ok(stream) => {
                            let info = stream.info.clone();
                            set_shared(Some(info.clone()));
                            active = Some(stream);
                            Ok(info)
                        }
                        Err(e) => Err(e),
                    },
                };
                let _ = reply.send(result);
            }
            Ok(StreamMsg::Stop(reply)) => {
                if let Some(running) = active.take() {
                    // Drop a healthy stream properly so the device is released for reopening.
                    // (The watchdog leaks stalled ones instead: their drop can hang.)
                    let _ = running.stream.pause();
                    drop(running.stream);
                    info!("Audio stream stopped ({})", running.info.device);
                }
                set_shared(None);
                let _ = reply.send(());
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Some(running) = active.as_mut() {
                    watchdog(&ctx, running);
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

/// Open and play a resolved config.
fn start(ctx: &CallbackContext, resolved: Resolved) -> Result<ActiveStream, String> {
    let Resolved {
        device,
        mut config,
        mut info,
    } = resolved;
    let stream = open_output_stream(&device, &mut config, ctx).map_err(|e| e.to_string())?;
    if config.buffer_size == BufferSize::Default {
        info.period_frames = 0;
    }
    stream.play().map_err(|e| e.to_string())?;
    info!(
        "Audio stream started: {} at {} Hz, {} channels, period {} frames ({:?})",
        info.device, info.sample_rate, info.channels, info.period_frames, config.buffer_size
    );
    Ok(ActiveStream {
        stream,
        device,
        config,
        info,
        last_count: ctx.counters.callbacks.load(Ordering::Relaxed),
        stalled_since: None,
        next_restart: Instant::now(),
        backoff: CALLBACK_STALL_TIMEOUT,
    })
}

/// Restart the stream if callbacks stopped. A stalled ALSA/`poll` can hang `Stream` drop, so the
/// dead stream is leaked with `mem::forget` rather than dropped.
fn watchdog(ctx: &CallbackContext, running: &mut ActiveStream) {
    let count = ctx.counters.callbacks.load(Ordering::Relaxed);
    if count != running.last_count {
        running.last_count = count;
        running.stalled_since = None;
        running.backoff = CALLBACK_STALL_TIMEOUT;
        return;
    }

    let stalled_at = *running.stalled_since.get_or_insert_with(Instant::now);
    if stalled_at.elapsed() < CALLBACK_STALL_TIMEOUT || Instant::now() < running.next_restart {
        return;
    }

    warn!(
        "Audio callback stalled for {:.1}s (PipeWire/ALSA stopped waking CPAL); restarting output stream",
        stalled_at.elapsed().as_secs_f32()
    );

    let mut config = running.config.clone();
    match open_output_stream(&running.device, &mut config, ctx) {
        Ok(new_stream) => match new_stream.play() {
            Ok(()) => {
                let old = std::mem::replace(&mut running.stream, new_stream);
                std::mem::forget(old);
                info!("Audio stream restarted");
                running.last_count = ctx.counters.callbacks.load(Ordering::Relaxed);
                running.stalled_since = None;
            }
            Err(e) => warn!("Failed to play restarted audio stream: {}", e),
        },
        Err(e) => warn!("Failed to restart audio stream: {}", e),
    }
    running.next_restart = Instant::now() + running.backoff;
    running.backoff = (running.backoff * 2).min(Duration::from_secs(10));
}

/// Find the device for `request` and choose its config.
fn resolve(request: &StreamRequest) -> Result<Resolved, String> {
    let host = cpal::default_host();
    let default_name = host
        .default_output_device()
        .and_then(|device| device.name().ok());
    let device = if request.device.is_empty() {
        host.default_output_device()
            .ok_or_else(|| "no default output device".to_string())?
    } else {
        host.output_devices()
            .map_err(|e| e.to_string())?
            .find(|device| device.name().ok().as_deref() == Some(request.device.as_str()))
            .ok_or_else(|| format!("output device '{}' not found", request.device))?
    };
    let name = device.name().map_err(|e| e.to_string())?;
    let config = select_stream_config(&device, request.sample_rate, request.period_frames)
        .map_err(|e| format!("{}: {}", name, e))?;
    let period_frames = match config.buffer_size {
        BufferSize::Fixed(frames) => frames / ALSA_PERIODS,
        BufferSize::Default => 0,
    };
    let info = StreamInfo {
        is_default_device: request.device.is_empty() || default_name.as_deref() == Some(&name),
        device: name,
        sample_rate: config.sample_rate.0,
        period_frames,
        channels: config.channels,
    };
    Ok(Resolved {
        device,
        config,
        info,
    })
}

/// Choose an f32 output config at `sample_rate` with a fixed buffer of `ALSA_PERIODS` periods,
/// falling back to the device's default rate when it can't run at `sample_rate`.
fn select_stream_config(
    device: &Device,
    sample_rate: u32,
    period_frames: u32,
) -> Result<StreamConfig> {
    let default_config = device.default_output_config()?;
    let ranges: Vec<_> = device
        .supported_output_configs()?
        .filter(|range| range.sample_format() == SampleFormat::F32)
        .collect();
    let rate = if ranges
        .iter()
        .any(|range| range_supports(range, sample_rate))
    {
        sample_rate
    } else {
        let fallback = default_config.sample_rate().0;
        warn!(
            "Device has no {} Hz f32 output config, using {} Hz",
            sample_rate, fallback
        );
        fallback
    };
    let counts: Vec<u16> = ranges
        .iter()
        .filter(|range| range_supports(range, rate))
        .map(|range| range.channels())
        .collect();
    let channels = pick_channels(&counts, default_config.channels());

    let Some(range) = ranges
        .iter()
        .find(|range| range.channels() == channels && range_supports(range, rate))
    else {
        warn!(
            "Device has no f32 output config at {} Hz, using default {:?}",
            rate, default_config
        );
        return Ok(default_config.config());
    };

    let buffer_frames = fixed_buffer_frames(period_frames, range.buffer_size());
    let mut config = range.clone().with_sample_rate(SampleRate(rate)).config();
    config.buffer_size = BufferSize::Fixed(buffer_frames);
    Ok(config)
}

fn range_supports(range: &cpal::SupportedStreamConfigRange, rate: u32) -> bool {
    range.min_sample_rate().0 <= rate && rate <= range.max_sample_rate().0
}

/// `ALSA_PERIODS` periods of `period_frames`, within the device's buffer range.
fn fixed_buffer_frames(period_frames: u32, range: &SupportedBufferSize) -> u32 {
    let period = period_frames.clamp(MIN_PERIOD_FRAMES, MAX_PERIOD_FRAMES);
    let frames = period * ALSA_PERIODS;
    match *range {
        SupportedBufferSize::Range { min, max } if min <= max => frames.clamp(min, max),
        _ => frames,
    }
}

/// Channel count to open: every channel of a hardware device, but the default count on a plugin
/// device that accepts any count (opening 32 channels there would make a 32-channel stream).
fn pick_channels(counts: &[u16], default: u16) -> u16 {
    let Some(&max) = counts.iter().max() else {
        return default;
    };
    if counts.len() >= ANY_CHANNEL_COUNT as usize || max >= ANY_CHANNEL_COUNT {
        if counts.contains(&default) {
            default
        } else {
            2.min(max)
        }
    } else {
        max
    }
}

/// Every output device with the rates and period range it supports. Opens each device to query
/// it, so it's slow: run it off the command and stream threads.
pub fn list_output_devices(active: Option<&StreamInfo>) -> Vec<OutputDeviceInfo> {
    let host = cpal::default_host();
    let default_name = host
        .default_output_device()
        .and_then(|device| device.name().ok());
    let Ok(devices) = host.output_devices() else {
        return Vec::new();
    };

    let mut list = Vec::new();
    for device in devices {
        let Ok(name) = device.name() else {
            continue;
        };
        let is_default = default_name.as_deref() == Some(name.as_str());
        let mut info = OutputDeviceInfo {
            name,
            is_default,
            sample_rates: Vec::new(),
            min_period: MIN_PERIOD_FRAMES,
            max_period: MAX_PERIOD_FRAMES,
            channels: 0,
        };
        match device.supported_output_configs() {
            Ok(configs) => {
                let ranges: Vec<_> = configs
                    .filter(|range| range.sample_format() == SampleFormat::F32)
                    .collect();
                fill_device_info(&mut info, &ranges, device.default_output_config().ok());
            }
            Err(_) => {
                // Busy: a hardware device the engine itself has open reports what it runs.
                if let Some(active) = active.filter(|active| active.device == info.name) {
                    info.sample_rates = vec![active.sample_rate];
                    info.channels = active.channels;
                }
            }
        }
        list.push(info);
    }
    list
}

fn fill_device_info(
    info: &mut OutputDeviceInfo,
    ranges: &[cpal::SupportedStreamConfigRange],
    default: Option<cpal::SupportedStreamConfig>,
) {
    let mut rates: Vec<u32> = Vec::new();
    for range in ranges {
        let (min, max) = (range.min_sample_rate().0, range.max_sample_rate().0);
        if min == max {
            rates.push(min);
        } else {
            rates.extend(
                COMMON_SAMPLE_RATES
                    .iter()
                    .filter(|&&r| min <= r && r <= max),
            );
        }
    }
    rates.sort_unstable();
    rates.dedup();
    info.sample_rates = rates;

    let counts: Vec<u16> = ranges.iter().map(|range| range.channels()).collect();
    let default_channels = default.as_ref().map_or(2, |config| config.channels());
    info.channels = pick_channels(&counts, default_channels);

    if let Some(SupportedBufferSize::Range { min, max }) =
        ranges.first().map(|range| range.buffer_size().clone())
    {
        info.min_period = (min / ALSA_PERIODS).clamp(MIN_PERIOD_FRAMES, MAX_PERIOD_FRAMES);
        info.max_period = (max / ALSA_PERIODS).clamp(info.min_period, MAX_PERIOD_FRAMES);
    }
}

/// Open a CPAL output stream, falling back from a fixed buffer to the device default. `config`
/// is updated to what was opened.
fn open_output_stream(
    device: &Device,
    config: &mut StreamConfig,
    ctx: &CallbackContext,
) -> Result<Stream> {
    match build_stream(device, config, ctx.clone()) {
        Ok(stream) => Ok(stream),
        Err(e) if matches!(config.buffer_size, BufferSize::Fixed(_)) => {
            warn!(
                "Failed to open stream with {:?} ({}), retrying with device default buffer",
                config.buffer_size, e
            );
            config.buffer_size = BufferSize::Default;
            build_stream(device, config, ctx.clone())
        }
        Err(e) => Err(e),
    }
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

/// Build the audio output stream. Every callback updates `counters` and, every
/// `STATS_INTERVAL`, sends `EngineStatus::EngineStats` (also after a lock miss, so the UI can
/// tell a busy engine from a stalled one).
fn build_stream(device: &Device, config: &StreamConfig, ctx: CallbackContext) -> Result<Stream> {
    let CallbackContext {
        status_tx,
        state,
        counters,
        block_clock,
    } = ctx;
    let sample_rate = config.sample_rate.0;
    let channels = config.channels as usize;

    let mut samples_since_update = 0;
    let update_interval = sample_rate / 20;

    let mut load = LoadWindow::new(Instant::now());
    // Start and expected duration of the previous callback, for gap (xrun) detection.
    let mut previous_block: Option<(Instant, Duration)> = None;
    // cpal's ALSA callback fills all free space, so the ring is full after every callback and
    // underruns only if the next one comes later than the whole buffer lasts. Comparing with the
    // previous block instead miscounts when block sizes vary, as they do while PipeWire
    // resamples the stream (1024/1881/2739 frames at 44.1 kHz in a 48 kHz graph).
    let buffer_duration = match config.buffer_size {
        BufferSize::Fixed(frames) => Some(Duration::from_secs_f64(
            frames as f64 / sample_rate.max(1) as f64,
        )),
        BufferSize::Default => None,
    };

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
                let limit =
                    buffer_duration.unwrap_or_else(|| previous_duration.mul_f64(XRUN_GAP_FACTOR));
                if gap > limit {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hardware_devices_open_every_channel() {
        assert_eq!(pick_channels(&[2], 2), 2);
        assert_eq!(pick_channels(&[20], 20), 20);
        assert_eq!(pick_channels(&[2, 4, 6, 8], 2), 8);
    }

    #[test]
    fn plugin_devices_open_their_default_count() {
        let any: Vec<u16> = (1..=32).collect();
        assert_eq!(pick_channels(&any, 2), 2);
        assert_eq!(pick_channels(&[], 2), 2);
    }

    #[test]
    fn buffer_is_four_periods_within_the_device_range() {
        let wide = SupportedBufferSize::Range {
            min: 64,
            max: 1 << 20,
        };
        assert_eq!(fixed_buffer_frames(1024, &wide), 4096);
        assert_eq!(fixed_buffer_frames(256, &wide), 1024);
        // Clamped to the engine's limits…
        assert_eq!(fixed_buffer_frames(8192, &wide), MAX_BLOCK_FRAMES as u32);
        assert_eq!(
            fixed_buffer_frames(1, &wide),
            MIN_PERIOD_FRAMES * ALSA_PERIODS
        );
        // …and to the device's.
        let narrow = SupportedBufferSize::Range {
            min: 2048,
            max: 3000,
        };
        assert_eq!(fixed_buffer_frames(128, &narrow), 2048);
        assert_eq!(fixed_buffer_frames(1024, &narrow), 3000);
    }

    #[test]
    fn output_pairs_and_latency() {
        let info = StreamInfo {
            device: "hw".into(),
            is_default_device: false,
            sample_rate: 48_000,
            period_frames: 480,
            channels: 8,
        };
        assert_eq!(info.output_pairs(), 4);
        assert!((info.latency_ms() - 10.0).abs() < 1e-4);
        assert_eq!(
            StreamInfo {
                channels: 1,
                ..info
            }
            .output_pairs(),
            1
        );
    }
}
