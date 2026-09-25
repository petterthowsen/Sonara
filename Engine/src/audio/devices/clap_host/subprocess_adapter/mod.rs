//! Subprocess-based CLAP Device Adapter
//!
//! This adapter runs CLAP plugins in separate processes and communicates via IPC.
//! It replaces the in-process ClapDeviceAdapter for better crash isolation and GUI support.

use super::super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::block_clock::BlockClock;
use crate::audio::commands::{AudioCommand, EngineStatus};
use crate::audio::devices::DevicePath;
use crate::audio::ipc::{
    futex, BlockEvent, InstanceId, PluginCommand, ProcessManager, MAX_BLOCK_EVENTS,
};
use crossbeam::channel::Sender;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tracing::{error, info};

mod gui;
mod lifecycle;
mod parameter;
mod plugin_ipc;

pub use lifecycle::{PluginLoad, PluginLoadRequest, PluginShared};
pub use plugin_ipc::PluginIpcHandle;

/// Blocks, across all subprocess plugins, where the plugin missed its callback deadline and the
/// adapter output silence or dry input (audible as a dropout). Reported in `EngineStats`.
pub static PLUGIN_UNDERRUNS: AtomicU64 = AtomicU64::new(0);

/// Parameter writes the audio thread can queue per plugin between command-thread ticks before
/// the queue has to grow.
const QUEUED_PARAM_CAPACITY: usize = 256;

/// Output parameter changes the adapter can hold for the command thread between polls.
const QUEUED_OUTPUT_CAPACITY: usize = 64;

/// Spins this many times before falling back to a futex wait. The host usually answers within a
/// few microseconds, so the common case never enters the kernel.
const HANDSHAKE_SPIN_ITERATIONS: u32 = 400;

/// Consecutive missed deadlines before the failure is logged at WARN.
const MISSES_BEFORE_WARNING: u32 = 8;

/// How long a published block may stay unfinished before the command thread kills the host as
/// hung (Phase 4). Measured in wall time and by progress, not by missed deadlines: a plugin that
/// is merely slower than its deadline still finishes every block late, and must only drop out.
pub const HUNG_STALL_TIMEOUT: Duration = Duration::from_secs(1);

/// How often a plugin whose state changed is asked to save it, so a crash doesn't lose edits.
const STATE_SAVE_INTERVAL: Duration = Duration::from_secs(30);

/// Audio-thread counters for one plugin since the last `take_stats`.
#[derive(Debug, Default, Clone, Copy)]
pub struct PluginBlockStats {
    /// Blocks where the host didn't finish inside the callback deadline.
    pub deadline_misses: u64,
    /// Input events dropped because the block's event array was full.
    pub event_drops: u64,
}

/// CLAP device adapter using subprocess isolation
pub struct SubprocessClapAdapter {
    // Plugin metadata
    device_id: String,
    device_name: String,
    device_vendor: String,
    device_version: String,
    category: DeviceCategory,

    // Process communication
    instance_id: InstanceId,
    process_manager: Arc<ProcessManager>,
    load: Arc<PluginLoad>,

    // Cached parameter info (shared with background loading thread)
    param_info_cache: Arc<Mutex<Vec<ParamInfo>>>,

    // Audio configuration
    sample_rate: f32,
    max_buffer_size: usize,

    /// Plugin bundle path and host key, kept for the reload path (Phase 4).
    plugin_path: PathBuf,
    host_key: String,

    // Plugin position (for sending GUI close notifications)
    channel_id: u32,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,
    command_tx: Option<Sender<AudioCommand>>,
    /// Last state blob the plugin saved, restored after a crash. Shared with the reload thread.
    saved_state: Arc<Mutex<Option<Vec<u8>>>>,
    /// True when the plugin (or a parameter change) made the saved state stale.
    state_dirty: Arc<AtomicBool>,
    /// When the state blob was last refreshed, so saves stay bounded to one per interval.
    last_state_save: Instant,
    /// False once the adapter is dropped. Stops an in-flight load from orphaning a host.
    alive: Arc<AtomicBool>,

    // State
    is_active: bool,
    is_enabled: bool,
    gui_open: bool,
    /// Parameter writes not yet sent to the subprocess: made before it was ready, or queued by
    /// `set_parameter` for the command thread to send. Preallocated.
    pending_param_writes: Vec<(ParamId, ParamValue)>,
    /// Last known value of each parameter, so `get_parameter` never waits on the subprocess.
    /// Filled with defaults on ready, then updated by writes and by changes the plugin reports.
    param_values: HashMap<ParamId, ParamValue>,
    /// Parameter changes the plugin made while processing, read from its output events. Drained
    /// by the command thread, which reports them to Godot.
    pending_output_events: Vec<(ParamId, ParamValue)>,
    /// Input events for the upcoming block (notes and automation), staged so the audio thread
    /// never writes the shared block outside `process_block`.
    input_events: Vec<BlockEvent>,
    stats: PluginBlockStats,
    /// Consecutive blocks that missed the deadline, for rate-limited logging.
    consecutive_misses: u32,
    /// Command thread: the `done_seq` seen while a request was outstanding, and since when. The
    /// host is hung once that stays unchanged for `HUNG_STALL_TIMEOUT`.
    stall: Option<(u64, Instant)>,
    /// One absolute plugin deadline per callback, published by the engine.
    block_clock: Arc<BlockClock>,
}

impl SubprocessClapAdapter {
    /// Create a new subprocess-based CLAP adapter (non-blocking)
    /// Plugin loads asynchronously in background thread
    pub fn new(
        process_manager: Arc<ProcessManager>,
        channel_id: u32,
        device_path: DevicePath,
        plugin_path: PathBuf,
        plugin_id: &str,
        sample_rate: f32,
        max_buffer_size: usize,
        command_tx: Option<Sender<AudioCommand>>,
        status_tx: Option<Sender<EngineStatus>>,
        block_clock: Arc<BlockClock>,
    ) -> Result<Self, String> {
        info!(
            "🚀 Creating subprocess CLAP adapter (async): {} (SR: {}, buffer: {})",
            plugin_id, sample_rate, max_buffer_size
        );

        let instance_id = process_manager.allocate_instance_id();
        let host_key = ProcessManager::individual_host_key(instance_id);
        let alive = Arc::new(AtomicBool::new(true));

        // Get plugin metadata (immediately available)
        let device_name = plugin_id.to_string();
        let device_vendor = "Unknown".to_string();
        let device_version = "1.0".to_string();
        let category = DeviceCategory::Effect;
        let param_info_cache = Arc::new(Mutex::new(Vec::new()));

        let load = Arc::new(PluginLoad::new());

        // Spawn subprocess loading in background thread (non-blocking!)
        PluginLoadRequest {
            process_manager: Arc::clone(&process_manager),
            instance_id,
            host_key: host_key.clone(),
            plugin_path: plugin_path.clone(),
            plugin_id: plugin_id.to_string(),
            sample_rate,
            max_buffer_size,
            load: Arc::clone(&load),
            param_cache: Arc::clone(&param_info_cache),
            channel_id: channel_id as usize,
            device_path: device_path.clone(),
            command_tx: command_tx.clone(),
            status_tx: status_tx.clone(),
            restore_state: None,
            restore_params: Vec::new(),
            replace_existing: false,
            alive: Arc::clone(&alive),
        }
        .spawn();

        let adapter = Self {
            device_id: plugin_id.to_string(),
            device_name: device_name.clone(),
            device_vendor,
            device_version,
            category,
            instance_id,
            process_manager,
            load,
            param_info_cache,
            sample_rate,
            max_buffer_size,
            plugin_path,
            host_key,
            channel_id,
            device_path,
            status_tx,
            command_tx,
            saved_state: Arc::new(Mutex::new(None)),
            state_dirty: Arc::new(AtomicBool::new(false)),
            last_state_save: Instant::now(),
            alive,
            is_active: false,
            is_enabled: true,
            gui_open: false,
            pending_param_writes: Vec::with_capacity(QUEUED_PARAM_CAPACITY),
            param_values: HashMap::new(),
            pending_output_events: Vec::with_capacity(QUEUED_OUTPUT_CAPACITY),
            input_events: Vec::with_capacity(MAX_BLOCK_EVENTS),
            stats: PluginBlockStats::default(),
            consecutive_misses: 0,
            stall: None,
            block_clock,
        };

        info!(
            "✅ SubprocessClapAdapter created (loading in background): {}",
            device_name
        );
        Ok(adapter)
    }

    /// Handle for blocking round-trips to this plugin's subprocess (GUI, activation) that doesn't
    /// borrow the adapter, so callers can release the engine state lock before waiting.
    pub fn ipc_handle(&self) -> PluginIpcHandle {
        PluginIpcHandle::new(
            Arc::clone(&self.process_manager),
            self.instance_id,
            self.device_name.clone(),
            self.sample_rate,
        )
    }

    /// Record the result of activating or deactivating through an `ipc_handle`.
    pub fn set_active_state(&mut self, active: bool, latency_frames: u32) {
        self.is_active = active;
        if active {
            self.load.set_latency_frames(latency_frames);
        }
    }

    /// Record the result of opening or closing the GUI through an `ipc_handle`.
    pub fn set_gui_open(&mut self, open: bool) {
        self.gui_open = open;
    }
}

impl AudioDevice for SubprocessClapAdapter {
    /// Audio thread. Runs the per-block handshake: fill the instance's shared input planes and
    /// event array, ring the host's doorbell, then wait for the host to finish — bounded by the
    /// callback's absolute deadline. A missed deadline costs this plugin one block (dry input or
    /// silence); the late result is discarded by sequence number on the next block.
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let interleaved = (sample_count * 2).min(outputs.len());
        let copy_len = interleaved.min(inputs.len());

        // Clone the load handle so `shared` doesn't borrow `self` while counters are updated.
        let load = Arc::clone(&self.load);
        let Some(shared) = load.shared() else {
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        };

        let layout = *shared.memory.layout();
        if sample_count > layout.max_frames {
            // Bigger block than the shared region: can't be published.
            self.record_event_drops(1);
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }
        let channels = layout.max_channels.min(2);
        let control = shared.memory.control();

        // Finish a request that timed out on an earlier block before the buffers are reused, even
        // if the plugin has since been bypassed.
        let outstanding = control.request_seq.load(Ordering::Acquire);
        if outstanding != control.done_seq.load(Ordering::Acquire)
            && !self.wait_for_done(shared, outstanding, sample_count)
        {
            self.record_deadline_miss();
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }

        if !self.is_enabled {
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }

        // Fill the planar input planes (interleaved stereo in, planar out).
        let frames = sample_count;
        {
            let plane = shared.memory.input();
            for channel in 0..channels {
                let start = channel * layout.max_frames;
                let dst = &mut plane[start..start + frames];
                for (i, sample) in dst.iter_mut().enumerate() {
                    *sample = inputs.get(i * 2 + channel).copied().unwrap_or(0.0);
                }
            }
        }
        // Stage the notes and automation collected since the last block into the shared event
        // array. Writing it here (while no request is outstanding) keeps the host from reading
        // a half-updated array.
        let staged = self.input_events.len().min(layout.max_events);
        {
            let dst = shared.memory.input_events();
            dst[..staged].copy_from_slice(&self.input_events[..staged]);
        }
        control
            .input_event_count
            .store(staged as u32, Ordering::Relaxed);
        control.input_frames.store(frames as u32, Ordering::Relaxed);
        let seq = outstanding + 1;
        control.request_seq.store(seq, Ordering::Release);
        futex::wake(shared.doorbell.doorbell(), i32::MAX);
        // The events belong to this request now, whether or not it finishes in time.
        self.input_events.clear();

        if self.wait_for_done(shared, seq, sample_count) {
            let out_frames = (control.output_frames.load(Ordering::Acquire) as usize).min(frames);
            {
                let plane = shared.memory.output();
                for i in 0..out_frames {
                    for channel in 0..channels {
                        outputs[i * 2 + channel] = plane[channel * layout.max_frames + i];
                    }
                }
            }
            let written = (out_frames * 2).min(interleaved);
            if written < interleaved {
                outputs[written..interleaved].fill(0.0);
            }
            self.read_output_events(shared);
            self.consecutive_misses = 0;
        } else {
            self.record_deadline_miss();
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
        }
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        if self.input_events.len() >= MAX_BLOCK_EVENTS {
            self.stats.event_drops += 1;
            return;
        }
        self.input_events.push(BlockEvent::note(
            frame_offset as u32,
            note,
            velocity as f32 / 127.0,
            is_note_on,
        ));
    }

    /// Command thread: sends the value to the subprocess right away when it can.
    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.param_values.insert(param_id, value);
        self.set_state_dirty();
        self.flush_pending_parameters();

        if !parameter::set_parameter_value(&self.process_manager, self.instance_id, param_id, value)
        {
            self.queue_parameter(param_id, value);
        }
    }

    /// Automation (audio thread, holding the state lock): write the change into the block's input
    /// event array, so the plugin applies it at exactly `frame_offset` in the upcoming block.
    ///
    /// Before the plugin is ready the value is queued for the command thread instead.
    fn set_parameter_at(&mut self, param_id: ParamId, value: ParamValue, frame_offset: usize) {
        if let Some(cached) = self.param_values.get_mut(&param_id) {
            *cached = value;
        }
        self.set_state_dirty();

        if !self.load.is_ready() {
            // Not processing yet: let the command thread apply it over the control channel.
            self.queue_parameter(param_id, value);
            return;
        }
        if self.input_events.len() >= MAX_BLOCK_EVENTS {
            self.stats.event_drops += 1;
            return;
        }
        self.input_events
            .push(BlockEvent::param(frame_offset as u32, param_id, value));
    }

    /// Last known value (no IPC). None until the plugin has reported its parameters.
    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.param_values.get(&param_id).copied()
    }

    fn device_id(&self) -> &str {
        &self.device_id
    }

    fn device_name(&self) -> &str {
        &self.device_name
    }

    fn device_category(&self) -> DeviceCategory {
        self.category
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::Clap
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        parameter::get_parameters(&self.param_info_cache)
    }

    /// Command thread: fire-and-forget, the host answers asynchronously.
    fn reset(&mut self) {
        let Some(connection) = self.process_manager.instance(self.instance_id) else {
            return; // Not loaded yet
        };
        if let Err(e) = connection.send(PluginCommand::Reset) {
            error!("Failed to send reset command: {}", e);
        }
    }

    fn version(&self) -> &str {
        &self.device_version
    }

    /// Frames the plugin reported at activation (0 when it has no latency extension).
    fn latency_frames(&self) -> u32 {
        self.load.latency_frames()
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        if self.is_active {
            return Ok(());
        }
        let latency = self.ipc_handle().activate()?;
        self.load.set_latency_frames(latency);
        self.is_active = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        if !self.is_active {
            return Ok(());
        }
        self.ipc_handle().deactivate()?;
        self.is_active = false;
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

impl SubprocessClapAdapter {
    fn can_send_parameters(&self) -> bool {
        self.load.is_ready() && self.process_manager.instance(self.instance_id).is_some()
    }

    /// Wait until the host has finished request `seq`, spinning first and then futex-waiting on
    /// the host's doorbell. Bounded by the callback's absolute deadline; falls back to 70% of the
    /// block when no clock was published (unit tests, offline use).
    fn wait_for_done(&self, shared: &PluginShared, seq: u64, sample_count: usize) -> bool {
        let deadline = self.block_clock.deadline().unwrap_or_else(|| {
            let block =
                Duration::from_secs_f64(sample_count as f64 / self.sample_rate.max(1.0) as f64);
            Instant::now() + block.mul_f32(0.7)
        });
        let control = shared.memory.control();

        for _ in 0..HANDSHAKE_SPIN_ITERATIONS {
            if control.done_seq.load(Ordering::Acquire) >= seq {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::hint::spin_loop();
        }

        let doorbell = shared.doorbell.doorbell();
        loop {
            if control.done_seq.load(Ordering::Acquire) >= seq {
                return true;
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            // Read the doorbell before re-checking: a wake that lands between the check and the
            // wait bumps the word, so the wait returns immediately instead of blocking.
            let word = doorbell.load(Ordering::Acquire);
            if control.done_seq.load(Ordering::Acquire) >= seq {
                return true;
            }
            futex::wait(doorbell, word, Some(deadline - now));
        }
    }

    /// Read the plugin's output parameter events from the finished block into the queue the
    /// command thread drains.
    fn read_output_events(&mut self, shared: &PluginShared) {
        let control = shared.memory.control();
        let count = (control.output_event_count.load(Ordering::Acquire) as usize)
            .min(shared.memory.layout().max_events);
        let events = shared.memory.output_events();
        for event in &events[..count] {
            if event.kind != crate::audio::ipc::EVENT_PARAM {
                continue;
            }
            if self.pending_output_events.len() >= QUEUED_OUTPUT_CAPACITY {
                break;
            }
            self.pending_output_events.push((event.id, event.value));
        }
    }

    fn record_deadline_miss(&mut self) {
        self.stats.deadline_misses += 1;
        PLUGIN_UNDERRUNS.fetch_add(1, Ordering::Relaxed);
        self.consecutive_misses += 1;
        if self.consecutive_misses == MISSES_BEFORE_WARNING {
            error!(
                "Plugin {} (instance {}) missed its processing deadline {} blocks in a row; \
                 passing audio through. The host process is too slow or stuck.",
                self.device_name, self.instance_id, self.consecutive_misses
            );
        }
    }

    fn record_event_drops(&mut self, count: u64) {
        self.stats.event_drops += count;
    }

    /// Replace a queued write to the same parameter, else append. Doesn't allocate unless more
    /// than `QUEUED_PARAM_CAPACITY` distinct parameters are queued.
    fn queue_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        match self
            .pending_param_writes
            .iter_mut()
            .find(|(pending_id, _)| *pending_id == param_id)
        {
            Some(pending) => pending.1 = value,
            None => self.pending_param_writes.push((param_id, value)),
        }
    }

    fn flush_pending_parameters(&mut self) {
        if self.pending_param_writes.is_empty() {
            return;
        }

        if !self.can_send_parameters() {
            return;
        }

        let mut remaining = Vec::new();
        for (param_id, value) in self.pending_param_writes.drain(..) {
            if !parameter::set_parameter_value(
                &self.process_manager,
                self.instance_id,
                param_id,
                value,
            ) {
                remaining.push((param_id, value));
            }
        }

        if !remaining.is_empty() {
            self.pending_param_writes = remaining;
        }
    }

    /// Command thread, once the subprocess is ready: seed the value cache with defaults (values
    /// already written win) and send writes made while loading.
    pub fn on_device_ready(&mut self) {
        let params = parameter::get_parameters(&self.param_info_cache);
        self.param_values.reserve(params.len());
        for param in &params {
            self.param_values.entry(param.id).or_insert(param.default);
        }
        self.flush_pending_parameters();
    }

    /// Shared load state, so the command thread can mark the plugin failed.
    pub fn load(&self) -> Arc<PluginLoad> {
        Arc::clone(&self.load)
    }

    /// Return and reset the audio-thread counters.
    pub fn take_stats(&mut self) -> PluginBlockStats {
        std::mem::take(&mut self.stats)
    }

    /// Command thread: true once the host has left a published block unfinished for
    /// `HUNG_STALL_TIMEOUT`. A slow host that finishes its blocks late keeps advancing
    /// `done_seq`, so it is never counted as hung, whatever the buffer size.
    pub fn is_host_stalled(&mut self, now: Instant) -> bool {
        let Some(shared) = self.load.shared() else {
            self.stall = None;
            return false;
        };
        let control = shared.memory.control();
        let done = control.done_seq.load(Ordering::Acquire);
        if control.request_seq.load(Ordering::Acquire) == done {
            self.stall = None;
            return false;
        }
        match self.stall {
            Some((seen, since)) if seen == done => now.duration_since(since) >= HUNG_STALL_TIMEOUT,
            _ => {
                self.stall = Some((done, now));
                false
            }
        }
    }

    /// The plugin changed state (it called `mark_dirty`, or a parameter moved): the saved state
    /// is stale.
    pub fn set_state_dirty(&mut self) {
        self.state_dirty.store(true, Ordering::Release);
    }

    /// True when the state blob is stale and hasn't been refreshed for `STATE_SAVE_INTERVAL`.
    /// Also starts the interval, so one poll doesn't ask twice.
    pub fn take_state_save_due(&mut self) -> bool {
        if !self.state_dirty.load(Ordering::Acquire) {
            return false;
        }
        if self.last_state_save.elapsed() < STATE_SAVE_INTERVAL {
            return false;
        }
        self.last_state_save = Instant::now();
        self.state_dirty.store(false, Ordering::Release);
        true
    }

    pub fn set_saved_state(&mut self, state: Vec<u8>) {
        *self.saved_state.lock().unwrap() = Some(state);
    }

    pub fn saved_state(&self) -> Option<Vec<u8>> {
        self.saved_state.lock().unwrap().clone()
    }

    /// Build the request that respawns this plugin after a crash, and install a fresh load state
    /// so the audio thread passes audio through until the new host is ready.
    ///
    /// Runs on the command thread under the engine state lock, which is what makes replacing
    /// `self.load` safe: the audio callback touches the field under the same lock.
    pub fn begin_reload(&mut self) -> PluginLoadRequest {
        let load = Arc::new(PluginLoad::new());
        self.load = Arc::clone(&load);
        self.state_dirty.store(false, Ordering::Release);
        self.last_state_save = Instant::now();
        // The dead host's misses belong to the dead host: a fresh one must not inherit them, or
        // the hung-host check would kill it on its first tick.
        self.consecutive_misses = 0;
        self.stall = None;
        self.stats = PluginBlockStats::default();

        let restore_params: Vec<(ParamId, ParamValue)> = self
            .param_values
            .iter()
            .map(|(param_id, value)| (*param_id, *value))
            .collect();

        info!(
            "Reloading plugin {} (instance {}): {} saved bytes, {} parameter values",
            self.device_name,
            self.instance_id,
            self.saved_state
                .lock()
                .unwrap()
                .as_ref()
                .map_or(0, Vec::len),
            restore_params.len()
        );

        PluginLoadRequest {
            process_manager: Arc::clone(&self.process_manager),
            instance_id: self.instance_id,
            host_key: self.host_key.clone(),
            plugin_path: self.plugin_path.clone(),
            plugin_id: self.device_id.clone(),
            sample_rate: self.sample_rate,
            max_buffer_size: self.max_buffer_size,
            load,
            param_cache: Arc::clone(&self.param_info_cache),
            channel_id: self.channel_id as usize,
            device_path: self.device_path.clone(),
            command_tx: self.command_tx.clone(),
            status_tx: self.status_tx.clone(),
            restore_state: self.saved_state(),
            restore_params,
            replace_existing: true,
            alive: Arc::clone(&self.alive),
        }
    }

    /// Move queued parameter writes into `out` (keeps this queue's capacity). Only once ready;
    /// before that they stay queued for `on_device_ready`.
    pub fn drain_queued_parameters(&mut self, out: &mut Vec<(ParamId, ParamValue)>) {
        if self.load.is_ready() {
            out.extend(self.pending_param_writes.drain(..));
        }
    }

    /// Record a value the plugin reported (its GUI or internal modulation).
    pub fn cache_parameter_value(&mut self, param_id: ParamId, value: ParamValue) {
        if let Some(cached) = self.param_values.get_mut(&param_id) {
            *cached = value;
        }
    }

    /// Move the plugin's output parameter changes (from its audio processing) into `out`. The
    /// command thread runs this under the state lock and reports them to Godot.
    pub fn drain_output_events(&mut self, out: &mut Vec<(ParamId, ParamValue)>) {
        out.extend(self.pending_output_events.drain(..));
    }

    /// Close plugin GUI
    pub fn close_gui(&mut self) -> Result<(), String> {
        if !self.gui_open {
            return Ok(());
        }

        let result = self.ipc_handle().close_gui();

        // Always mark GUI as closed, even if IPC fails
        // The window is being destroyed regardless, and keeping gui_open=true
        // will cause subsequent opens to return stale size data
        self.gui_open = false;

        result
    }

    /// Check if GUI is supported
    pub fn has_gui(&mut self) -> bool {
        self.ipc_handle().has_gui()
    }

    /// Check if GUI is open
    pub fn is_gui_open(&self) -> bool {
        self.gui_open
    }
}

impl Drop for SubprocessClapAdapter {
    fn drop(&mut self) {
        // Stop an in-flight load/reload from respawning a host behind a removed device.
        self.alive.store(false, Ordering::Release);

        // Close GUI if open and notify window manager
        if self.gui_open {
            let _ = self.close_gui();

            // Notify window manager to destroy the window
            if let Some(ref status_tx) = self.status_tx {
                let _ = status_tx.send(EngineStatus::PluginGuiClosed {
                    channel_id: self.channel_id as usize,
                    device_path: self.device_path.clone(),
                });
                info!(
                    "Sent PluginGuiClosed notification during drop: channel={} device={}",
                    self.channel_id, self.device_path
                );
            }
        }

        // Shutdown subprocess
        info!("Shutting down plugin subprocess: {}", self.device_name);
        self.process_manager.shutdown_instance(self.instance_id);
    }
}

// Safety: Communication is done via IPC, no shared memory access from audio thread
unsafe impl Send for SubprocessClapAdapter {}

/// Test-only constructor: exercises the block handshake without loading a real plugin.
#[cfg(test)]
impl SubprocessClapAdapter {
    pub(crate) fn new_for_test(
        load: Arc<PluginLoad>,
        block_clock: Arc<BlockClock>,
        sample_rate: f32,
        max_buffer_size: usize,
    ) -> Self {
        Self {
            device_id: "test.clap".to_string(),
            device_name: "Test CLAP".to_string(),
            device_vendor: "test".to_string(),
            device_version: "1.0".to_string(),
            category: DeviceCategory::Effect,
            instance_id: 1,
            process_manager: Arc::new(ProcessManager::new()),
            load,
            param_info_cache: Arc::new(Mutex::new(Vec::new())),
            sample_rate,
            max_buffer_size,
            plugin_path: PathBuf::from("/tmp/test.clap"),
            host_key: "instance-1".to_string(),
            channel_id: 0,
            device_path: DevicePath::root(0),
            status_tx: None,
            command_tx: None,
            saved_state: Arc::new(Mutex::new(None)),
            state_dirty: Arc::new(AtomicBool::new(false)),
            last_state_save: Instant::now(),
            alive: Arc::new(AtomicBool::new(true)),
            is_active: true,
            is_enabled: true,
            gui_open: false,
            pending_param_writes: Vec::with_capacity(QUEUED_PARAM_CAPACITY),
            param_values: HashMap::new(),
            pending_output_events: Vec::with_capacity(QUEUED_OUTPUT_CAPACITY),
            input_events: Vec::with_capacity(MAX_BLOCK_EVENTS),
            stats: PluginBlockStats::default(),
            consecutive_misses: 0,
            stall: None,
            block_clock,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::{HostSharedMemory, SharedMemory, SharedMemoryLayout};
    use std::sync::atomic::AtomicBool;
    use std::thread;
    use std::time::Duration;

    /// Shared block + doorbell, with a `PluginLoad` already marked ready.
    fn ready_block(
        name: &str,
        frames: usize,
    ) -> (Arc<PluginLoad>, Arc<SharedMemory>, Arc<HostSharedMemory>) {
        let memory = Arc::new(SharedMemory::new(name, SharedMemoryLayout::new(frames)).unwrap());
        let doorbell = Arc::new(HostSharedMemory::new(&format!("{}_bell", name)).unwrap());
        let load = Arc::new(PluginLoad::new());
        load.set_ready(Arc::clone(&memory), Arc::clone(&doorbell));
        (load, memory, doorbell)
    }

    /// A stand-in host process: answers each request by doubling the input planes. While
    /// `release` is false it holds the request, standing in for a stuck plugin. When `observed`
    /// is given, the input events of every request are copied into it.
    fn spawn_fake_host(
        memory: Arc<SharedMemory>,
        doorbell: Arc<HostSharedMemory>,
        stop: Arc<AtomicBool>,
        release: Arc<AtomicBool>,
        observed: Option<Arc<std::sync::Mutex<Vec<BlockEvent>>>>,
    ) -> thread::JoinHandle<()> {
        thread::spawn(move || {
            while !stop.load(Ordering::Acquire) {
                let control = memory.control();
                let seq = control.request_seq.load(Ordering::Acquire);
                let idle = seq == 0
                    || seq == control.done_seq.load(Ordering::Acquire)
                    || !release.load(Ordering::Acquire);
                if idle {
                    std::hint::spin_loop();
                    continue;
                }
                let layout = *memory.layout();
                let frames =
                    (control.input_frames.load(Ordering::Acquire) as usize).min(layout.max_frames);
                if let Some(observed) = &observed {
                    let count = (control.input_event_count.load(Ordering::Acquire) as usize)
                        .min(layout.max_events);
                    let events = memory.input_events();
                    observed.lock().unwrap().extend_from_slice(&events[..count]);
                }
                {
                    let input = memory.input();
                    let output = memory.output();
                    for i in 0..frames * layout.max_channels {
                        output[i] = input[i] * 2.0;
                    }
                }
                control
                    .output_frames
                    .store(frames as u32, Ordering::Relaxed);
                control.output_event_count.store(0, Ordering::Relaxed);
                control.done_seq.store(seq, Ordering::Release);
                doorbell.ring();
            }
        })
    }

    #[test]
    fn blocks_round_trip_through_the_handshake() {
        let (load, memory, doorbell) = ready_block("sonara_test_handshake", 64);
        let stop = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(true));
        let host = spawn_fake_host(memory, doorbell, Arc::clone(&stop), release, None);
        let clock = Arc::new(BlockClock::with_fraction(0.7));
        clock.publish(Instant::now(), Duration::from_millis(500));
        let mut adapter = SubprocessClapAdapter::new_for_test(load, clock, 48_000.0, 64);

        let input: Vec<f32> = (0..64 * 2).map(|i| i as f32 * 0.001).collect();
        let mut output = vec![0.0f32; 64 * 2];
        adapter.process_block(&input, &mut output, 64);
        for (i, sample) in output.iter().enumerate() {
            assert!(
                (sample - input[i] * 2.0).abs() < 1e-6,
                "sample {i} = {sample}, expected {}",
                input[i] * 2.0
            );
        }
        assert_eq!(adapter.take_stats().deadline_misses, 0);
        stop.store(true, Ordering::Release);
        host.join().unwrap();
    }

    #[test]
    fn a_late_host_costs_one_block_and_its_result_is_discarded() {
        let (load, memory, doorbell) = ready_block("sonara_test_handshake_late", 64);
        let stop = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let host = spawn_fake_host(
            Arc::clone(&memory),
            doorbell,
            Arc::clone(&stop),
            Arc::clone(&release),
            None,
        );
        let clock = Arc::new(BlockClock::with_fraction(0.7));
        let mut adapter =
            SubprocessClapAdapter::new_for_test(load, Arc::clone(&clock), 48_000.0, 64);

        // A 200 µs deadline: the held request can't finish in time.
        clock.publish(Instant::now(), Duration::from_micros(200));
        let input = vec![0.5f32; 64 * 2];
        let mut output = vec![0.0f32; 64 * 2];
        adapter.process_block(&input, &mut output, 64);
        assert_eq!(output, input, "a missed deadline passes dry input through");
        assert_eq!(adapter.take_stats().deadline_misses, 1);
        assert_eq!(memory.control().request_seq.load(Ordering::Acquire), 1);
        assert_eq!(memory.control().done_seq.load(Ordering::Acquire), 0);

        // Release the host: the late result is discarded, the next block succeeds.
        release.store(true, Ordering::Release);
        clock.publish(Instant::now(), Duration::from_secs(1));
        let mut output = vec![0.0f32; 64 * 2];
        adapter.process_block(&input, &mut output, 64);
        for (i, sample) in output.iter().enumerate() {
            assert!(
                (sample - input[i] * 2.0).abs() < 1e-6,
                "sample {i} = {sample}"
            );
        }
        assert_eq!(adapter.take_stats().deadline_misses, 0);
        stop.store(true, Ordering::Release);
        host.join().unwrap();
    }

    /// Missing deadlines doesn't make a host hung while it keeps finishing blocks late; a block
    /// left unfinished for `HUNG_STALL_TIMEOUT` does.
    #[test]
    fn only_a_host_that_stops_finishing_blocks_counts_as_stalled() {
        let (load, memory, doorbell) = ready_block("sonara_test_stall", 64);
        let stop = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let host = spawn_fake_host(
            Arc::clone(&memory),
            doorbell,
            Arc::clone(&stop),
            Arc::clone(&release),
            None,
        );
        let clock = Arc::new(BlockClock::with_fraction(0.7));
        let mut adapter =
            SubprocessClapAdapter::new_for_test(load, Arc::clone(&clock), 48_000.0, 64);
        let input = vec![0.5f32; 64 * 2];
        let mut output = vec![0.0f32; 64 * 2];
        let t0 = Instant::now();

        assert!(!adapter.is_host_stalled(t0), "nothing outstanding");

        // Block 1 misses its deadline; the tracker starts timing it.
        clock.publish(Instant::now(), Duration::from_micros(200));
        adapter.process_block(&input, &mut output, 64);
        assert!(!adapter.is_host_stalled(t0));

        // The host finishes block 1 late, then holds block 2: a slow host, not a stuck one.
        release.store(true, Ordering::Release);
        let deadline = Instant::now() + Duration::from_secs(1);
        while memory.control().done_seq.load(Ordering::Acquire) < 1 && Instant::now() < deadline {
            thread::yield_now();
        }
        release.store(false, Ordering::Release);
        clock.publish(Instant::now(), Duration::from_micros(200));
        adapter.process_block(&input, &mut output, 64);
        assert_eq!(adapter.consecutive_misses, 2, "both blocks missed");
        let t1 = t0 + HUNG_STALL_TIMEOUT * 2;
        assert!(
            !adapter.is_host_stalled(t1),
            "done_seq advanced since the last check, so the host is making progress"
        );

        // Block 2 is never finished: stalled once the timeout passes without progress.
        assert!(!adapter.is_host_stalled(t1 + HUNG_STALL_TIMEOUT / 2));
        assert!(adapter.is_host_stalled(t1 + HUNG_STALL_TIMEOUT));

        stop.store(true, Ordering::Release);
        host.join().unwrap();
    }

    #[test]
    fn begin_reload_reinstalls_load_state_and_keeps_saved_state() {
        let (load, _memory, _doorbell) = ready_block("sonara_test_reload", 64);
        let clock = Arc::new(BlockClock::with_fraction(0.7));
        let mut adapter = SubprocessClapAdapter::new_for_test(load, clock, 48_000.0, 64);
        adapter.set_saved_state(vec![1, 2, 3]);
        adapter.set_parameter(4, 0.25);
        // A host that hung before the reload leaves these behind; the new host must not inherit
        // them or the hung-host check would kill it immediately.
        adapter.consecutive_misses = 32;
        adapter.stall = Some((0, Instant::now() - HUNG_STALL_TIMEOUT));
        adapter.stats.deadline_misses = 99;

        assert!(adapter.load().is_ready());
        let request = adapter.begin_reload();

        // A fresh load state means the audio thread passes audio through until the host is back.
        assert!(adapter.load().is_loading());
        assert!(!adapter.load().is_ready());
        assert_eq!(
            adapter.consecutive_misses, 0,
            "reload clears consecutive misses"
        );
        assert!(adapter.stall.is_none(), "reload clears the stall tracker");
        let stats = adapter.take_stats();
        assert_eq!(stats.deadline_misses, 0, "reload clears the miss counter");
        assert_eq!(request.restore_state, Some(vec![1, 2, 3]));
        assert_eq!(request.restore_params, vec![(4, 0.25)]);
        assert!(request.replace_existing);
        assert!(request.alive.load(Ordering::Acquire));
        assert_eq!(request.instance_id, 1);
        assert_eq!(request.host_key, "instance-1");
    }

    /// A stale state blob is only refreshed once per `STATE_SAVE_INTERVAL`.
    #[test]
    fn state_save_is_throttled_and_needs_a_dirty_flag() {
        let (load, _memory, _doorbell) = ready_block("sonara_test_state_save", 64);
        let clock = Arc::new(BlockClock::with_fraction(0.7));
        let mut adapter = SubprocessClapAdapter::new_for_test(load, clock, 48_000.0, 64);

        assert!(!adapter.take_state_save_due(), "clean state needs no save");
        adapter.set_state_dirty();
        assert!(
            !adapter.take_state_save_due(),
            "a first save right after load waits for the interval"
        );

        adapter.last_state_save = Instant::now() - STATE_SAVE_INTERVAL;
        assert!(adapter.take_state_save_due());
        assert!(
            !adapter.take_state_save_due(),
            "the interval restarts after a save"
        );
    }

    #[test]
    fn midi_and_automation_reach_the_host_with_their_sample_offsets() {
        let (load, memory, doorbell) = ready_block("sonara_test_events", 64);
        let stop = Arc::new(AtomicBool::new(false));
        let observed = Arc::new(std::sync::Mutex::new(Vec::new()));
        let host = spawn_fake_host(
            Arc::clone(&memory),
            doorbell,
            Arc::clone(&stop),
            Arc::new(AtomicBool::new(true)),
            Some(Arc::clone(&observed)),
        );
        let clock = Arc::new(BlockClock::with_fraction(0.7));
        clock.publish(Instant::now(), Duration::from_secs(1));
        let mut adapter = SubprocessClapAdapter::new_for_test(load, clock, 48_000.0, 64);

        adapter.send_midi_event(60, 100, true, 12);
        adapter.set_parameter_at(7, 0.75, 3);

        let input = vec![0.0f32; 64 * 2];
        let mut output = vec![0.0f32; 64 * 2];
        adapter.process_block(&input, &mut output, 64);

        let events = observed.lock().unwrap();
        assert_eq!(events.len(), 2, "the host saw both events");
        assert_eq!(events[0].kind, crate::audio::ipc::EVENT_NOTE_ON);
        assert_eq!(events[0].note, 60);
        assert_eq!(events[0].sample_offset, 12);
        assert_eq!(events[1].kind, crate::audio::ipc::EVENT_PARAM);
        assert_eq!(events[1].id, 7);
        assert!((events[1].value - 0.75).abs() < 1e-6);
        assert_eq!(events[1].sample_offset, 3);
        drop(events);

        // Events belong to one block only.
        let mut output = vec![0.0f32; 64 * 2];
        adapter.process_block(&input, &mut output, 64);
        assert_eq!(observed.lock().unwrap().len(), 2, "not replayed next block");
        assert_eq!(adapter.take_stats().event_drops, 0);

        stop.store(true, Ordering::Release);
        host.join().unwrap();
    }
}
