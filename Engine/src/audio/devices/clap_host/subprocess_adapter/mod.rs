//! Subprocess-based CLAP Device Adapter
//!
//! This adapter runs CLAP plugins in separate processes and communicates via IPC.
//! It replaces the in-process ClapDeviceAdapter for better crash isolation and GUI support.

use super::super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::commands::{AudioCommand, EngineStatus};
use crate::audio::devices::DevicePath;
use crate::audio::ipc::{MidiEvent, PluginCommand, ProcessManager, SharedMemory};
use crossbeam::channel::Sender;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tracing::{error, info, warn};

mod gui;
mod lifecycle;
mod parameter;
mod plugin_ipc;

pub use lifecycle::PluginLoad;
pub use plugin_ipc::PluginIpcHandle;

/// Blocks, across all subprocess plugins, where the plugin's output ring buffer didn't hold a
/// full block and the adapter padded it with silence (audible as a dropout). Reported in
/// `EngineStats`.
pub static PLUGIN_UNDERRUNS: AtomicU64 = AtomicU64::new(0);

/// Parameter writes the audio thread can queue per plugin between command-thread ticks before
/// the queue has to grow.
const QUEUED_PARAM_CAPACITY: usize = 256;

/// Audio-thread counters for one plugin since the last `take_stats`.
#[derive(Debug, Default, Clone, Copy)]
pub struct PluginBlockStats {
    /// Blocks whose input didn't fit in the input ring buffer (the subprocess isn't reading).
    pub input_overflows: u64,
    /// Blocks padded with silence because the plugin's output wasn't ready.
    pub output_underruns: u64,
    /// MIDI events dropped because the MIDI queue was full.
    pub midi_drops: u64,
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
    process_key: String,
    process_manager: Arc<ProcessManager>,
    load: Arc<PluginLoad>,

    // Cached parameter info (shared with background loading thread)
    param_info_cache: Arc<Mutex<Vec<ParamInfo>>>,

    // Audio configuration
    sample_rate: f32,
    max_buffer_size: usize,

    // Plugin position (for sending GUI close notifications)
    channel_id: u32,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,

    // State
    is_active: bool,
    is_enabled: bool,
    gui_open: bool,
    /// Parameter writes not yet sent to the subprocess: made before it was ready, or queued by
    /// `set_parameter_at` (automation) for the command thread to send. Preallocated.
    pending_param_writes: Vec<(ParamId, ParamValue)>,
    /// Last known value of each parameter, so `get_parameter` never waits on the subprocess.
    /// Filled with defaults on ready, then updated by writes and by changes the plugin reports.
    param_values: HashMap<ParamId, ParamValue>,
    stats: PluginBlockStats,
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
    ) -> Result<Self, String> {
        info!(
            "🚀 Creating subprocess CLAP adapter (async): {} (SR: {}, buffer: {})",
            plugin_id, sample_rate, max_buffer_size
        );

        // Generate unique key for this plugin instance
        let process_key = device_path.to_process_key(channel_id);

        // Get plugin metadata (immediately available)
        let device_name = plugin_id.to_string();
        let device_vendor = "Unknown".to_string();
        let device_version = "1.0".to_string();
        let category = DeviceCategory::Effect;
        let param_info_cache = Arc::new(Mutex::new(Vec::new()));

        let load = Arc::new(PluginLoad::new());

        // Spawn subprocess loading in background thread (non-blocking!)
        lifecycle::spawn_loading_thread(
            Arc::clone(&process_manager),
            process_key.clone(),
            plugin_path,
            plugin_id.to_string(),
            sample_rate,
            max_buffer_size,
            Arc::clone(&load),
            Arc::clone(&param_info_cache),
            channel_id as usize,
            device_path.clone(),
            command_tx,
            status_tx.clone(),
        );

        let adapter = Self {
            device_id: plugin_id.to_string(),
            device_name: device_name.clone(),
            device_vendor,
            device_version,
            category,
            process_key,
            process_manager,
            load,
            param_info_cache,
            sample_rate,
            max_buffer_size,
            channel_id,
            device_path,
            status_tx,
            is_active: false,
            is_enabled: true,
            gui_open: false,
            pending_param_writes: Vec::with_capacity(QUEUED_PARAM_CAPACITY),
            param_values: HashMap::new(),
            stats: PluginBlockStats::default(),
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
            self.process_key.clone(),
            self.device_name.clone(),
        )
    }

    /// Record the result of activating or deactivating through an `ipc_handle`.
    pub fn set_active_state(&mut self, active: bool) {
        self.is_active = active;
    }

    /// Record the result of opening or closing the GUI through an `ipc_handle`.
    pub fn set_gui_open(&mut self, open: bool) {
        self.gui_open = open;
    }
}

impl AudioDevice for SubprocessClapAdapter {
    /// Audio thread. Never locks, logs or talks to the subprocess: problems are counted in
    /// `stats` and reported by the command thread (`CommandWorker::poll_devices`).
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let interleaved_samples = sample_count * 2; // stereo
        let shm = match self.load.shared_memory() {
            Some(shm) if self.is_enabled => shm,
            // Disabled, loading or failed: pass through
            _ => {
                let copy_len = interleaved_samples.min(inputs.len()).min(outputs.len());
                outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
                return;
            }
        };

        // Input is interleaved stereo (L, R, L, R, ...), written as-is
        let input_slice = &inputs[..interleaved_samples.min(inputs.len())];
        if shm.input_buffer().write(input_slice) < input_slice.len() {
            self.stats.input_overflows += 1;
        }

        // The subprocess polls the input ring and fills the output ring in its own time, so the
        // output is whatever it has produced so far (Phase 3 makes this synchronous).
        let output_len = interleaved_samples.min(outputs.len());
        let output_slice = &mut outputs[..output_len];
        let read = shm.output_buffer().read(output_slice);
        if read < output_len {
            output_slice[read..].fill(0.0);
            self.stats.output_underruns += 1;
            PLUGIN_UNDERRUNS.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        let Some(shm) = self.load.shared_memory() else {
            return; // Not ready: drop the event
        };

        let event = MidiEvent {
            sample_offset: frame_offset as u32,
            note,
            velocity,
            is_note_on: if is_note_on { 1 } else { 0 },
            _padding: 0,
        };

        if !shm.midi_queue().write(event) {
            self.stats.midi_drops += 1;
        }
    }

    /// Command thread: sends the value to the subprocess right away when it can.
    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.param_values.insert(param_id, value);
        self.flush_pending_parameters();

        if !parameter::set_parameter_value(
            &self.process_manager,
            &self.process_key,
            param_id,
            value,
        ) {
            self.queue_parameter(param_id, value);
        }
    }

    /// Automation (audio thread, or the command thread on bypass/delete): queue the value for
    /// the command thread to send, so the callback never touches the socket. Takes effect within
    /// one command-thread tick; the frame offset is ignored until Phase 3.
    fn set_parameter_at(&mut self, param_id: ParamId, value: ParamValue, _frame_offset: usize) {
        if let Some(cached) = self.param_values.get_mut(&param_id) {
            *cached = value;
        }
        self.queue_parameter(param_id, value);
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

    fn reset(&mut self) {
        // CRITICAL: Don't block the audio thread waiting for response!
        // Just send the command and continue (fire-and-forget)
        let process_arc = match self.process_manager.get_process(&self.process_key) {
            Some(p) => p,
            None => {
                warn!("Plugin process not found for reset");
                return;
            }
        };

        // Use try_lock to avoid blocking if process is busy
        match process_arc.try_lock() {
            Ok(mut process_guard) => {
                if let Err(e) = process_guard.send_command(PluginCommand::Reset) {
                    error!("Failed to send reset command: {}", e);
                }
                // Don't wait for response - this would block the audio thread!
            }
            Err(_) => {
                // Process is busy, skip reset (better than blocking)
                warn!("Skipping reset - process is busy");
            }
        };
    }

    fn version(&self) -> &str {
        &self.device_version
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        if self.is_active {
            return Ok(());
        }
        self.ipc_handle().activate()?;
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
        if self
            .process_manager
            .get_process(&self.process_key)
            .is_none()
        {
            return false;
        }

        self.load.is_ready()
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
                &self.process_key,
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
        gui::has_gui(&self.process_manager, &self.process_key)
    }

    /// Check if GUI is open
    pub fn is_gui_open(&self) -> bool {
        self.gui_open
    }
}

impl Drop for SubprocessClapAdapter {
    fn drop(&mut self) {
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
        if let Err(e) = self.process_manager.shutdown_plugin(&self.process_key) {
            error!("Failed to shutdown plugin subprocess: {}", e);
        }
    }
}

// Safety: Communication is done via IPC, no shared memory access from audio thread
unsafe impl Send for SubprocessClapAdapter {}
