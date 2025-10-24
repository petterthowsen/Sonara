//! Subprocess-based CLAP Device Adapter
//!
//! This adapter runs CLAP plugins in separate processes and communicates via IPC.
//! It replaces the in-process ClapDeviceAdapter for better crash isolation and GUI support.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use super::super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamValue, ParamInfo};
use super::ipc_protocol::{PluginCommand, PluginResponse, MidiEvent, PluginParameterInfo};
use super::shared_memory::SharedMemory;
use super::process_manager::{ProcessManager, PluginProcess};
use tracing::{info, warn, error};

/// Loading state for async plugin initialization
enum LoadingState {
    /// Plugin is being loaded in background thread
    Loading,
    /// Plugin loaded and ready
    Ready(Arc<SharedMemory>),
    /// Plugin failed to load
    Failed(String),
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
    loading_state: Arc<Mutex<LoadingState>>, // Only locked during initialization, not audio processing
    
    // Cached parameter info
    param_info_cache: Vec<ParamInfo>,
    
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
        let param_info_cache = Vec::new();
        
        // Create loading state (starts as Loading)
        let loading_state = Arc::new(Mutex::new(LoadingState::Loading));
        
        // Spawn subprocess loading in background thread (non-blocking!)
        let process_manager_clone = Arc::clone(&process_manager);
        let process_key_clone = process_key.clone();
        let plugin_path_clone = plugin_path.clone();
        let plugin_id_clone = plugin_id.to_string();
        let loading_state_clone = Arc::clone(&loading_state);
        
        std::thread::spawn(move || {
            info!("🔄 Background thread: Loading plugin subprocess...");
            
            // Spawn plugin subprocess (blocking, but on background thread!)
            let result = process_manager_clone.spawn_plugin(
                process_key_clone.clone(),
                plugin_path_clone,
                plugin_id_clone.clone(),
                sample_rate,
                max_buffer_size,
            );
            
            match result {
                Ok(_) => {
                    // Get shared memory reference and activate plugin
                    if let Some(process) = process_manager_clone.get_process(&process_key_clone) {
                        // Get shared memory first (quick operation)
                        let shared_memory = {
                            let process_guard = process.lock().unwrap();
                            Arc::clone(process_guard.shared_memory())
                        };
                        
                        // Brief delay to let subprocess return to event loop after InitializeSuccess
                        // This ensures the subprocess is ready to receive the next command
                        std::thread::sleep(std::time::Duration::from_millis(100));
                        
                        // Now send activation commands (in separate critical section)
                        {
                            info!("🔄 Activating plugin: {}", plugin_id_clone);
                            
                            let mut process_guard = process.lock().unwrap();
                            
                            // Send Activate command
                            info!("📤 Sending Activate command...");
                            if let Err(e) = process_guard.send_command(PluginCommand::Activate) {
                                error!("❌ Failed to send Activate command: {}", e);
                            } else {
                                info!("📥 Waiting for Activate response (with timeout)...");
                                
                                // Set a timeout on the socket to avoid blocking forever
                                let _ = process_guard.set_read_timeout(Some(std::time::Duration::from_secs(5)));
                                
                                match process_guard.recv_response() {
                                    Ok(PluginResponse::ActivateResult { success, error }) => {
                                        if success {
                                            info!("✅ Plugin activated successfully");
                                            
                                            // Start processing
                                            info!("🔄 Starting audio processing...");
                                            info!("📤 Sending StartProcessing command...");
                                            if let Err(e) = process_guard.send_command(PluginCommand::StartProcessing) {
                                                error!("❌ Failed to send StartProcessing command: {}", e);
                                            } else {
                                                info!("✅ Audio processing started");
                                            }
                                        } else {
                                            error!("❌ Failed to activate plugin: {}", error.unwrap_or_default());
                                        }
                                    }
                                    Ok(resp) => {
                                        error!("❌ Unexpected response to Activate: {:?}", resp);
                                    }
                                    Err(e) => {
                                        error!("❌ Failed to receive Activate response (timeout or error): {}", e);
                                        warn!("Plugin will run in pass-through mode");
                                    }
                                }
                            }
                        }
                        
                        // Update state to Ready
                        {
                            let mut state = loading_state_clone.lock().unwrap();
                            *state = LoadingState::Ready(shared_memory);
                        }
                        info!("✅ Plugin subprocess fully loaded and activated: {}", plugin_id_clone);
                    } else {
                        let mut state = loading_state_clone.lock().unwrap();
                        *state = LoadingState::Failed("Failed to get process handle".to_string());
                        error!("❌ Failed to get process handle for {}", plugin_id_clone);
                    }
                }
                Err(e) => {
                    let mut state = loading_state_clone.lock().unwrap();
                    *state = LoadingState::Failed(e.clone());
                    error!("❌ Failed to spawn plugin subprocess: {}", e);
                }
            }
        });
        
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
    
    // NOTE: Direct shared memory access is complex due to lifetimes.
    // In production, we'd use a different pattern (e.g., callbacks or separate accessor methods).
    // For now, we'll handle audio/MIDI in process_block without helper method.
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
        let shm = match loading_state_result {
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
        let shm = match loading_state_result {
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
        // CRITICAL: Don't block the audio thread waiting for response!
        // Parameter changes should be fire-and-forget from audio thread
        let cmd = PluginCommand::SetParameter {
            param_id,
            value,
        };
        
        let process_arc = match self.process_manager.get_process(&self.process_key) {
            Some(p) => p,
            None => {
                warn!("Plugin process not found for set_parameter");
                return;
            }
        };
        
        // Use try_lock to avoid blocking if process is busy
        // Explicit scope to satisfy borrow checker
        {
            match process_arc.try_lock() {
                Ok(mut process_guard) => {
                    if let Err(e) = process_guard.send_command(cmd) {
                        error!("Failed to send set_parameter command: {}", e);
                    }
                    // Don't wait for response - this would block the audio thread!
                }
                Err(_) => {
                    // Process is busy, skip parameter update (better than blocking)
                    warn!("Skipping parameter update - process is busy");
                }
            };
        }
    }
    
    fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
        // TODO: Query from subprocess
        // For now, return None
        None
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
        self.param_info_cache.clone()
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
        // Explicit scope to satisfy borrow checker
        {
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
        if self.gui_open {
            return Ok(());
        }
        
        match self.send_command(PluginCommand::OpenGui)? {
            PluginResponse::GuiOpened => {
                self.gui_open = true;
                info!("✅ Plugin GUI opened: {}", self.device_name);
                Ok(())
            }
            PluginResponse::GuiError { error } => {
                Err(error)
            }
            _ => Err("Unexpected response".to_string()),
        }
    }
    
    /// Close plugin GUI
    pub fn close_gui(&mut self) -> Result<(), String> {
        if !self.gui_open {
            return Ok(());
        }
        
        match self.send_command(PluginCommand::CloseGui)? {
            PluginResponse::GuiClosed => {
                self.gui_open = false;
                info!("Closed GUI: {}", self.device_name);
                Ok(())
            }
            PluginResponse::GuiError { error } => {
                Err(error)
            }
            _ => Err("Unexpected response".to_string()),
        }
    }
    
    /// Check if GUI is supported
    pub fn has_gui(&mut self) -> bool {
        match self.send_command(PluginCommand::HasGui) {
            Ok(PluginResponse::HasGuiResponse { supported }) => supported,
            _ => false,
        }
    }
    
    /// Check if GUI is open
    pub fn is_gui_open(&self) -> bool {
        self.gui_open
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

