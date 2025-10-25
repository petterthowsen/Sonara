//! Subprocess-based CLAP Device Adapter
//!
//! This adapter runs CLAP plugins in separate processes and communicates via IPC.
//! It replaces the in-process ClapDeviceAdapter for better crash isolation and GUI support.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use super::super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamValue, ParamInfo};
use crate::audio::ipc::{PluginCommand, PluginResponse, MidiEvent, SharedMemory, ProcessManager};
use crossbeam::channel::Sender;
use crate::audio::commands::AudioCommand;
use tracing::{info, warn, error};

mod lifecycle;
mod parameter;
mod gui;

pub use lifecycle::LoadingState;

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
    loading_state: Arc<Mutex<LoadingState>>, // Only locked during initialization, not audio processing
    
    // Cached parameter info (shared with background loading thread)
    param_info_cache: Arc<Mutex<Vec<ParamInfo>>>,
    
    // Audio configuration
    sample_rate: f32,
    max_buffer_size: usize,
    
    // State
    is_active: bool,
    is_enabled: bool,
    gui_open: bool,
}

impl SubprocessClapAdapter {
    /// Create a new subprocess-based CLAP adapter (non-blocking)
    /// Plugin loads asynchronously in background thread
    pub fn new(
        process_manager: Arc<ProcessManager>,
        channel_id: u32,
        device_position: usize,
        plugin_path: PathBuf,
        plugin_id: &str,
        sample_rate: f32,
        max_buffer_size: usize,
        command_tx: Option<Sender<AudioCommand>>,
    ) -> Result<Self, String> {
        info!(
            "🚀 Creating subprocess CLAP adapter (async): {} (SR: {}, buffer: {})",
            plugin_id, sample_rate, max_buffer_size
        );

        // Generate unique key for this plugin instance
        let process_key = format!("ch{}_dev{}", channel_id, device_position);
        
        // Get plugin metadata (immediately available)
        let device_name = plugin_id.to_string();
        let device_vendor = "Unknown".to_string();
        let device_version = "1.0".to_string();
        let category = DeviceCategory::Effect;
        let param_info_cache = Arc::new(Mutex::new(Vec::new()));
        
        // Create loading state (starts as Loading)
        let loading_state = Arc::new(Mutex::new(LoadingState::Loading));
        
        // Spawn subprocess loading in background thread (non-blocking!)
        lifecycle::spawn_loading_thread(
            Arc::clone(&process_manager),
            process_key.clone(),
            plugin_path,
            plugin_id.to_string(),
            sample_rate,
            max_buffer_size,
            Arc::clone(&loading_state),
            Arc::clone(&param_info_cache),
            channel_id as usize,
            device_position,
            command_tx,
        );
        
        let adapter = Self {
            device_id: plugin_id.to_string(),
            device_name: device_name.clone(),
            device_vendor,
            device_version,
            category,
            process_key,
            process_manager,
            loading_state,
            param_info_cache,
            sample_rate,
            max_buffer_size,
            is_active: false,
            is_enabled: true,
            gui_open: false,
        };
        
        info!("✅ SubprocessClapAdapter created (loading in background): {}", device_name);
        Ok(adapter)
    }
    
    /// Send command to subprocess and wait for response
    fn send_command(&mut self, cmd: PluginCommand) -> Result<PluginResponse, String> {
        // Get process handle
        let process = self.process_manager.get_process(&self.process_key)
            .ok_or_else(|| "Plugin process not found".to_string())?;
        
        let mut process = process.lock().unwrap();
        
        // Send command
        process.send_command(cmd)?;
        
        // Receive response
        process.recv_response()
    }
}

impl AudioDevice for SubprocessClapAdapter {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Handle disabled state (for subprocess plugins, is_active is managed in the subprocess)
        if !self.is_enabled {
            // Pass through
            let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }
        
        // CRITICAL: Check loading state with try_lock (non-blocking!)
        // If we can't get the lock, just pass through audio (better than blocking)
        let loading_state_result = self.loading_state.try_lock();
        let shm: Arc<SharedMemory> = match loading_state_result {
            Ok(state) => {
                match &*state {
                    LoadingState::Loading => {
                        // Still loading, pass through audio
                        let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
                        outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
                        return;
                    }
                    LoadingState::Ready(shared_memory) => {
                        // Plugin ready, use shared memory
                        Arc::clone(shared_memory)
                    }
                    LoadingState::Failed(err) => {
                        // Failed to load, pass through and log once
                        warn!("Plugin failed to load: {}", err);
                        let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
                        outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
                        return;
                    }
                }
            }
            Err(_) => {
                // Couldn't get lock (loading in progress), pass through
                let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
                outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
                return;
            }
        };
        
        // Write input audio to shared memory ring buffer
        // Input is interleaved stereo (L, R, L, R, ...), write as-is
        let interleaved_samples = sample_count * 2; // stereo
        let input_slice = &inputs[..interleaved_samples.min(inputs.len())];
        
        let mut input_buffer = shm.input_buffer();
        let written = input_buffer.write(input_slice);
        
        if written < input_slice.len() {
            warn!("Input buffer overflow: wrote {}/{} samples", written, input_slice.len());
        }
        
        // TODO: Signal subprocess that audio is available (eventfd)
        // For now, the subprocess polls the ring buffer in its event loop
        
        // Read output audio from shared memory ring buffer
        // Output will be interleaved stereo (L, R, L, R, ...)
        let mut output_buffer = shm.output_buffer();
        let output_len = interleaved_samples.min(outputs.len());
        let output_slice = &mut outputs[..output_len];
        let read = output_buffer.read(output_slice);
        
        if read < output_len {
            // Fill remainder with silence if not enough data available
            output_slice[read..].fill(0.0);
        }
        
        // In a real implementation, we'd also:
        // - Signal subprocess via eventfd when audio is available
        // - Wait for subprocess to complete processing (with timeout)
        // - Handle synchronization properly
        // For now, this is fire-and-forget with ring buffer
    }
    
    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool) {
        // Check if plugin is ready (non-blocking try_lock)
        let loading_state_result = self.loading_state.try_lock();
        let shm: Arc<SharedMemory> = match loading_state_result {
            Ok(state) => {
                match &*state {
                    LoadingState::Ready(shared_memory) => Arc::clone(shared_memory),
                    _ => return, // Not ready, drop MIDI event
                }
            }
            Err(_) => return, // Couldn't get lock, drop MIDI event
        };
        
        let event = MidiEvent {
            sample_offset: 0,
            note,
            velocity,
            is_note_on: if is_note_on { 1 } else { 0 },
            _padding: 0,
        };
        
        let mut midi_queue = shm.midi_queue();
        if !midi_queue.write(event) {
            warn!("MIDI queue full, dropping event");
        }
    }
    
    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        parameter::set_parameter_value(
            &self.process_manager,
            &self.process_key,
            param_id,
            value,
        );
    }
    
    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        parameter::get_parameter_value(
            &self.process_manager,
            &self.process_key,
            param_id,
        )
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
        
        match self.send_command(PluginCommand::Activate)? {
            PluginResponse::ActivateResult { success, error } => {
                if success {
                    self.is_active = true;
                    // Start processing
                    self.send_command(PluginCommand::StartProcessing)?;
                    Ok(())
                } else {
                    Err(error.unwrap_or_else(|| "Activation failed".to_string()))
                }
            }
            _ => Err("Unexpected response".to_string()),
        }
    }
    
    fn deactivate(&mut self) -> Result<(), String> {
        if !self.is_active {
            return Ok(());
        }
        
        // Stop processing first
        self.send_command(PluginCommand::StopProcessing)?;
        
        match self.send_command(PluginCommand::Deactivate)? {
            PluginResponse::DeactivateResult { success, error } => {
                if success {
                    self.is_active = false;
                    Ok(())
                } else {
                    Err(error.unwrap_or_else(|| "Deactivation failed".to_string()))
                }
            }
            _ => Err("Unexpected response".to_string()),
        }
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
    /// Open plugin GUI (subprocess will handle event loop)
    pub fn open_gui(&mut self) -> Result<(), String> {
        self.open_gui_with_handle(None)
    }

    /// Open plugin GUI with provided window handle for embedded mode
    pub fn open_gui_with_handle(&mut self, window_handle: Option<u64>) -> Result<(), String> {
        if self.gui_open {
            return Ok(());
        }

        gui::open_gui(&self.process_manager, &self.process_key, &self.device_name, window_handle)?;
        self.gui_open = true;
        Ok(())
    }
    
    /// Close plugin GUI
    pub fn close_gui(&mut self) -> Result<(), String> {
        if !self.gui_open {
            return Ok(());
        }
        
        gui::close_gui(&self.process_manager, &self.process_key, &self.device_name)?;
        self.gui_open = false;
        Ok(())
    }
    
    /// Check if GUI is supported
    pub fn has_gui(&mut self) -> bool {
        gui::has_gui(&self.process_manager, &self.process_key)
    }
    
    /// Check if GUI is open
    pub fn is_gui_open(&self) -> bool {
        self.gui_open
    }
    
    /// Poll for unsolicited parameter change messages from subprocess (non-blocking)
    /// Returns parameter changes as (param_id, normalized_value) pairs
    pub fn poll_parameter_changes(&mut self) -> Option<Vec<(u32, f32)>> {
        use crate::audio::ipc::protocol::PluginResponse;
        
        let process = self.process_manager.get_process(&self.process_key)?;
        let mut process_guard = process.lock().ok()?;
        
        // Try non-blocking read with very short timeout (don't block audio thread!)
        let _ = process_guard.set_read_timeout(Some(std::time::Duration::from_micros(100)));
        
        let mut changes = Vec::new();
        
        // Keep reading while there are messages available (non-blocking)
        loop {
            match process_guard.try_recv_response() {
                Ok(PluginResponse::ParameterValueChanged { param_id, value }) => {
                    changes.push((param_id, value));
                }
                Ok(_) => {
                    // Got some other response - ignore it (shouldn't happen for unsolicited messages)
                    break;
                }
                Err(_) => {
                    // No more messages available or error
                    break;
                }
            }
        }
        
        if !changes.is_empty() {
            Some(changes)
        } else {
            None
        }
    }
}

impl Drop for SubprocessClapAdapter {
    fn drop(&mut self) {
        // Close GUI if open
        if self.gui_open {
            let _ = self.close_gui();
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
